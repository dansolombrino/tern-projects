--!strict
-- projects, host half: runs in Tern's daemon (one VM, 2 s budget, timers that never stall, alive with no window
-- open). It owns what must not run on a window's UI thread or must outlive a window:
--
-- - The fleet mailbox (README "Fleet mailbox"): the durable queue in kv key `mailbox.v1` (this half is its only
--   writer) and the socket helper `mailbox.py serve`, a `tern.process.spawn` child that serves protocol v1 on a
--   Unix socket and relays each request here as a stdout line. Window halves deliver, then report each delivery
--   (and queue subagent report-backs) through files in `<data>/spool/`, which this half applies.
-- - Polling: every pane's omp session file, and the branch of every folder an agent card shows (git runs here,
--   not in a window), written to `<data>/status.json` for the window halves to read.

local mailq = require("./mailq")
local model = require("./model")
local identity = require("./identity")

local DATA = tern.plugin.data
local SPOOL = DATA .. "/spool"
local STATUS = DATA .. "/status.json"
local HELPER = tern.plugin.dir .. "/mailbox.py"
-- The CLI for `tern inspect`: the daemon's own executable when it says, else the app's, else PATH's.
local TERN_CLI = tern.getenv("TERN_EXE")
	or (if tern.fs.exists("/Applications/Tern.app/Contents/MacOS/tern") then "/Applications/Tern.app/Contents/MacOS/tern" else "tern")

-- How often the spool is applied and pane sessions are polled, and how long a branch read stays fresh.
local SPOOL_MS = 400
local PANES_MS = 2000
local REPO_TTL = 15
-- A spool file that still does not parse after this many looks is dropped.
local SPOOL_TRIES = 10

pcall(tern.fs.mkdir, SPOOL)

-- The mailbox -----------------------------------------------------------------------

local box: mailq.Box = (function()
	local ok, raw = pcall(tern.kv.get, mailq.KEY)
	return mailq.normalize(if ok then raw else nil)
end)()

local function save_box()
	tern.kv.set(mailq.KEY, mailq.encode(box, tern.json.array))
end

-- Live panes: id → cwd and omp session file (when it runs omp), from the last poll.
type PaneSeen = { cwd: string, session_file: string?, agent: boolean }
local panes: { [number]: PaneSeen } = {}

local function agents_now(): ({ mailq.Agent }, { [number]: string })
	local agents: { mailq.Agent } = {}
	local sessions: { [number]: string } = {}
	for pane, p in panes do
		if p.agent then
			table.insert(agents, { pane = pane, cwd = p.cwd, state = "idle" })
		end
		if p.session_file then
			sessions[pane] = p.session_file :: string
		end
	end
	return agents, sessions
end

local function resolvable(target: mailq.Target): boolean
	local agents, sessions = agents_now()
	return mailq.resolve(target, agents, sessions, identity.canon) ~= nil
end

-- The socket helper -----------------------------------------------------------------

local helper: Child? = nil
local unloading = false
local backoff = 1000
-- Watchers learn about new mail through the helper.
local function notify()
	if helper then
		pcall(function()
			(helper :: Child):write('{"t":"notify"}\n')
		end)
	end
end

local function handle(msg: any): { [string]: any }
	if type(msg) ~= "table" then
		return { ok = false, error = "bad-request", message = "the request must be a JSON object" }
	end
	local op = msg.op
	if op == "ping" then
		return { ok = true, version = mailq.VERSION }
	elseif op == "deliver" then
		local reply, changed = mailq.submit(box, msg, os.time(), resolvable)
		if changed then
			-- Persisted before the reply says `queued`.
			save_box()
			notify()
		end
		return reply
	elseif op == "status" then
		local reply = mailq.status(box, msg)
		if reply.ok and reply.error == nil then
			-- The protocol spells a missing error as null.
			reply.error = tern.json.null
		end
		return reply
	end
	return { ok = false, error = "bad-request", message = "unknown op " .. tostring(op) .. " (ping, deliver, status)" }
end

local start_helper: () -> ()

local function on_line(line: string)
	local ok, obj = pcall(tern.json.decode, line)
	if not ok or type(obj) ~= "table" then
		return
	end
	if obj.t == "req" then
		local rok, reply = pcall(handle, obj.msg)
		if not rok then
			tern.log.warn("projects: mailbox request failed", reply)
			reply = { ok = false, error = "busy", message = "the plugin failed on this request: " .. tostring(reply) }
		end
		if helper then
			(helper :: Child):write(tern.json.encode({ t = "reply", n = obj.n, reply = reply }) .. "\n")
		end
	elseif obj.t == "ready" then
		backoff = 1000
		tern.log.info("projects: mailbox listening", obj.socket, obj.pid)
	elseif obj.t == "log" then
		tern.log.info("projects: mailbox", obj.msg)
	end
end

start_helper = function()
	if unloading or helper then
		return
	end
	local ok, child = pcall(tern.process.spawn, { "/usr/bin/env", "python3", HELPER, "serve", "--data", DATA }, {
		stdout = function(line: string)
			on_line(line)
		end,
		stderr = function(line: string)
			tern.log.warn("projects: mailbox helper", line)
		end,
		exit = function(res: SpawnExit)
			helper = nil
			if unloading then
				return
			end
			tern.log.warn("projects: mailbox helper exited", res.status, res.stderr)
			tern.timer(backoff, start_helper)
			backoff = math.min(backoff * 2, 60000)
		end,
	})
	if ok then
		helper = child
	else
		tern.log.warn("projects: mailbox helper not started", child)
		tern.timer(backoff, start_helper)
		backoff = math.min(backoff * 2, 60000)
	end
end

tern.on("unload", function()
	unloading = true
	if helper then
		pcall(function()
			(helper :: Child):kill()
		end)
		helper = nil
	end
end)

-- The spool: window halves' reports ------------------------------------------------------

local tries: { [string]: number } = {}

local function apply_spool()
	local ok, names = pcall(tern.fs.list, SPOOL)
	if not ok then
		pcall(tern.fs.mkdir, SPOOL)
		return
	end
	local changed = false
	local now = os.time()
	for _, name in names do
		if string.sub(name, -5) == ".json" then
			local path = SPOOL .. "/" .. name
			local rok, text = pcall(tern.fs.read, path, 1048576)
			local dok, obj = false, nil
			if rok then
				dok, obj = pcall(tern.json.decode, text)
			end
			if dok and type(obj) == "table" then
				if obj.op == "deliver" then
					-- A report-back from a window: stored whatever the target's state (its parent was alive).
					local _, c = mailq.submit(box, obj, now, function()
						return true
					end)
					changed = changed or c
				elseif obj.op == "ack" then
					changed = mailq.apply(box, obj, now) or changed
				end
				pcall(tern.fs.remove, path)
				tries[name] = nil
			else
				-- Being written still, or broken: look again, then drop it.
				tries[name] = (tries[name] or 0) + 1
				if tries[name] >= SPOOL_TRIES then
					tern.log.warn("projects: dropping unreadable spool file", name)
					pcall(tern.fs.remove, path)
					tries[name] = nil
				end
			end
		end
	end
	changed = mailq.prune(box, now) or changed
	if changed then
		save_box()
		notify()
	end
end

-- Status for the windows: pane sessions and branches ----------------------------------------

type Repo = { branch: string?, head: string?, at: number, pending: boolean? }
local repos: { [string]: Repo } = {}

local function read_repo(cwd: string)
	local r = repos[cwd]
	if r and (r.pending or os.time() - r.at < REPO_TTL) then
		return
	end
	local entry: Repo = r or { at = 0 }
	entry.pending = true
	repos[cwd] = entry
	local ok = pcall(tern.process.run, { "git", "-C", cwd, "rev-parse", "HEAD", "--abbrev-ref", "HEAD" }, { timeout_ms = 10000 }, function(res: ProcessResult)
		entry.pending = nil
		entry.at = os.time()
		if res.status == 0 then
			local sha, name = string.match(res.stdout, "^([0-9a-f]+)\n([^\n]*)")
			entry.branch = if name and name ~= "HEAD" then name else nil
			entry.head = sha
		else
			entry.branch, entry.head = nil, nil
		end
	end)
	if not ok then
		entry.pending = nil
		entry.at = os.time()
	end
end

-- Whether a pane runs omp: its command line names it or it has an omp session.
local function runs_omp(p: any): boolean
	if type(p.omp_session_file) == "string" then
		return true
	end
	local function names(s: any): boolean
		return type(s) == "string" and string.find(s, "omp", 1, true) ~= nil
	end
	if names(p.program) or names(p.command) then
		return true
	end
	if type(p.args) == "table" then
		for _, a in p.args do
			if names(a) then
				return true
			end
		end
	end
	return false
end

-- Panes from `tern inspect --json` (it names each pane's omp session file; `tern.pane.list` does not).
local inspecting = false
local function poll_panes()
	if inspecting then
		return
	end
	inspecting = true
	local ok = pcall(tern.process.run, { TERN_CLI, "inspect", "--json" }, { timeout_ms = 10000 }, function(res: ProcessResult)
		inspecting = false
		if res.status ~= 0 then
			return
		end
		local dok, doc = pcall(tern.json.decode, res.stdout)
		if not dok or type(doc) ~= "table" or type(doc.panes) ~= "table" then
			return
		end
		local fresh: { [number]: PaneSeen } = {}
		for _, p in doc.panes do
			if type(p) == "table" and type(p.pane) == "number" and p.exited == nil then
				fresh[p.pane] = {
					cwd = if type(p.cwd) == "string" then p.cwd else "",
					session_file = if type(p.omp_session_file) == "string" then p.omp_session_file else nil,
					agent = runs_omp(p),
				}
			end
		end
		panes = fresh
	end)
	if not ok then
		inspecting = false
	end
end

local function write_status()
	local out_panes: { [string]: any } = {}
	local cwds: { [string]: boolean } = {}
	for pane, p in panes do
		out_panes[tostring(pane)] = { cwd = p.cwd, session_file = p.session_file }
		if p.agent and p.cwd ~= "" then
			cwds[p.cwd] = true
		end
	end
	local state = model.load()
	for _, m in state.agents do
		if m.worktree then
			cwds[m.worktree :: string] = true
		end
	end
	local out_repos: { [string]: any } = {}
	for cwd in cwds do
		read_repo(cwd)
		local r = repos[cwd]
		if r and r.at > 0 then
			out_repos[cwd] = { branch = r.branch, head = r.head }
		end
	end
	for cwd in repos do
		if not cwds[cwd] then
			repos[cwd] = nil
		end
	end
	local queued = 0
	for _, m in box.msgs do
		if m.state == "queued" then
			queued += 1
		end
	end
	local doc = { at = os.time(), panes = out_panes, repos = out_repos, queued = queued }
	pcall(tern.fs.write, STATUS, tern.json.encode(doc))
end

-- Clocks -------------------------------------------------------------------------------

local function every(ms: number, label: string, fn: () -> ())
	local function tick()
		if unloading then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			tern.log.warn("projects: host " .. label .. " failed", err)
		end
		tern.timer(ms, tick)
	end
	tern.timer(ms, tick)
end

every(SPOOL_MS, "spool", apply_spool)
every(PANES_MS, "status", function()
	poll_panes()
	write_status()
end)

poll_panes()
start_helper()
