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
-- - GitHub (ghpoll.luau): the PRs and issues of every project's repository and the PR of every branch a card shows,
--   read with `gh` on a rate-limited clock and written to `<data>/gh.json`.
-- - Automations (autohost.luau): the scheduler of Orca-style automations, its headless runs and history.

local mailq = require("./mailq")
local model = require("./model")
local identity = require("./identity")
local fleet = require("./fleet")
local ghpoll = require("./ghpoll")
local autohost = require("./autohost")

local DATA = tern.plugin.data
local SPOOL = DATA .. "/spool"
local STATUS = DATA .. "/status.json"
local FLEET = DATA .. "/fleet.json"
-- The agent-fleet state root (fleet.luau), fixed for the daemon's environment.
local FLEET_ROOT = fleet.state_root(tern.getenv)
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
-- The GitHub clock (ghpoll.luau keeps each repository's own pace).
local GH_MS = 5000
-- The automations' scheduler clock (schedules are whole minutes; runs end by their status files).
local AUTO_MS = 2000

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
-- Every pane (exited ones too) and session from the last poll, for the fleets (fleet.luau).
local live: fleet.Live? = nil

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
	ghpoll.stop()
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
				elseif type(obj.op) == "string" and string.sub(obj.op, 1, 5) == "auto_" then
					autohost.spool(obj)
				else
					ghpoll.spool(obj)
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
-- The first poll came back (until then nothing is known to be gone).
local polled = false
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
		polled = true
		live = fleet.live_of(doc)
	end)
	if not ok then
		inspecting = false
	end
end

-- Fleets: the agent-fleet states (tern_fleet.py writes them; this only reads) with live panes and the mailbox, written
-- to `<data>/fleet.json` when the model changed; `fleet_sig` in status.json counts the changes, so a window re-reads
-- the file only then.
local fleet_cache: fleet.Cache = {}
local fleet_json: string? = nil
-- Unique per host run, so a window never mistakes a restarted count for the one it read.
local FLEET_RUN = string.format("%d-%d", os.time(), math.random(1, 1000000))
local fleet_sig = FLEET_RUN .. ".0"
local fleet_n = 0
-- How long the last fleet scan took and the longest one this run (ms), reported in status.json.
local fleet_ms = 0
local fleet_ms_max = 0
-- The last fleet model: its worktrees and branches get PR badges (ghpoll.luau).
local fleet_model: fleet.Model? = nil

local function mail_live(): { by_id: { [string]: string }, queued: { [number]: number } }
	local by_id: { [string]: string } = {}
	local queued: { [number]: number } = {}
	local by_file: { [string]: number } = {}
	for pane, p in panes do
		if p.session_file then
			by_file[p.session_file :: string] = pane
		end
	end
	for _, m in box.msgs do
		by_id[m.id] = m.state
		if m.state == "queued" then
			local pane = m.target.pane
			if (pane == nil or panes[pane] == nil) and m.target.session_file then
				pane = by_file[m.target.session_file :: string] or pane
			end
			if pane then
				queued[pane] = (queued[pane] or 0) + 1
			end
		end
	end
	return { by_id = by_id, queued = queued }
end

local function scan_fleets()
	if FLEET_ROOT == nil or live == nil then
		return
	end
	local t0 = tern.now()
	local entries, cache = fleet.read_states(FLEET_ROOT :: string, {
		list = tern.fs.list,
		read = function(path: string): string?
			return tern.fs.read(path, 4194304)
		end,
		decode = tern.json.decode,
	}, fleet_cache)
	fleet_cache = cache
	local l = live :: fleet.Live
	l.mail = mail_live()
	local m = fleet.build(entries, l)
	fleet_model = m
	fleet_ms = tern.now() - t0
	fleet_ms_max = math.max(fleet_ms_max, fleet_ms)
	if fleet_ms > 200 then
		tern.log.warn(string.format("projects: host fleet scan took %.1f ms", fleet_ms))
	end
	local text = tern.json.encode(m)
	if text ~= fleet_json then
		local ok, err = pcall(tern.fs.write, FLEET, text)
		if ok then
			fleet_json = text
			fleet_n += 1
			fleet_sig = FLEET_RUN .. "." .. fleet_n
		else
			tern.log.warn("projects: fleet.json not written", err)
		end
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
	local doc: { [string]: any } = {
		at = os.time(),
		panes = out_panes,
		repos = out_repos,
		queued = queued,
		fleet_sig = fleet_sig,
		fleet_ms = math.floor(fleet_ms * 10 + 0.5) / 10,
		fleet_ms_max = math.floor(fleet_ms_max * 10 + 0.5) / 10,
	}
	for k, v in ghpoll.stats() do
		doc[k] = v
	end
	for k, v in autohost.stats() do
		doc[k] = v
	end
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
	local ok, err = pcall(scan_fleets)
	if not ok then
		tern.log.warn("projects: host fleet scan failed", err)
	end
	write_status()
end)

-- GitHub: what the sidebar shows, as folders with the branch each card shows.
ghpoll.start({
	wants = function(): { ghpoll.Want }
		local out: { ghpoll.Want } = {}
		for _, p in model.load().projects do
			table.insert(out, { dir = p.root })
		end
		for cwd, r in repos do
			table.insert(out, { dir = cwd, branch = r.branch })
		end
		local m = fleet_model
		if m then
			for _, f in m.fleets do
				for _, g in f.groups do
					if g.worktree then
						table.insert(out, { dir = g.worktree :: string, branch = g.branch })
					end
					for _, it in g.items do
						if it.worktree then
							table.insert(out, { dir = it.worktree :: string, branch = it.branch })
						end
					end
				end
			end
		end
		return out
	end,
	shown = function(): boolean
		return model.load_ui().visible
	end,
	branch_of = function(cwd: string): string?
		local r = repos[cwd]
		return if r then r.branch else nil
	end,
})
every(GH_MS, "github", ghpoll.tick)

autohost.start({
	notify = notify,
	panes = function(): { [number]: boolean }?
		if not polled then
			return nil
		end
		local out: { [number]: boolean } = {}
		for pane in panes do
			out[pane] = true
		end
		return out
	end,
	projects = function(): { any }
		local out = {}
		for _, p in model.load().projects do
			table.insert(out, { id = p.id, name = p.name, root = p.root })
		end
		return out
	end,
})
every(AUTO_MS, "automations", autohost.tick)

poll_panes()
start_helper()
