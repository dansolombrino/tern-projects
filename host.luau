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
-- - The bridge block (`projects.bridge`, bridge.luau): how a window on another machine reaches this half. Its view
--   carries this host's status, fleets, GitHub data, automations, queued mail and request replies; its events are
--   requests (spool reports, git, folder reads, the window's projects on this host).

local mailq = require("./mailq")
local model = require("./model")
local identity = require("./identity")
local fleet = require("./fleet")
local ghpoll = require("./ghpoll")
local autohost = require("./autohost")
local bridge = require("./bridge")

local DATA = tern.plugin.data
local SPOOL = DATA .. "/spool"
local STATUS = DATA .. "/status.json"
local FLEET = DATA .. "/fleet.json"
-- The agent-fleet state root (fleet.luau), fixed for the daemon's environment.
local FLEET_ROOT = fleet.state_root(tern.getenv)
local HELPER = tern.plugin.dir .. "/mailbox.py"
local HOME = tern.getenv("HOME")
-- The CLI for `tern inspect` (bridge.tern_cli: the daemon's own executable, the app's, the Linux install's, PATH's).
local TERN_CLI = bridge.tern_cli(tern.getenv, tern.fs.exists)
-- Where agent-fleet scripts look for mailbox.json when that is not `<data>/mailbox.json` (Linux: the daemon's data
-- dir is under ~/.local/state, the scripts look under the config dir); the helper publishes it there too.
local DISCOVERY = bridge.discovery_path(tern.getenv, tern.runtime.os, tern.plugin.id, DATA)

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

-- The bridge's mail node is rebuilt only after the queue changed.
local mail_dirty = true

local function save_box()
	tern.kv.set(mailq.KEY, mailq.encode(box, tern.json.array))
	mail_dirty = true
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
	local argv = { "/usr/bin/env", "python3", HELPER, "serve", "--data", DATA }
	if DISCOVERY then
		table.insert(argv, "--discovery")
		table.insert(argv, DISCOVERY :: string)
	end
	local ok, child = pcall(tern.process.spawn, argv, {
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

-- Applies one spool object (a spool file's, or a remote window's through the bridge); true when the mailbox changed
-- (the caller saves it).
local function apply_one(obj: { [string]: any }, now: number): boolean
	if obj.op == "deliver" then
		-- A report-back from a window: stored whatever the target's state (its parent was alive).
		local _, c = mailq.submit(box, obj, now, function()
			return true
		end)
		return c
	elseif obj.op == "ack" then
		return mailq.apply(box, obj, now)
	elseif type(obj.op) == "string" and string.sub(obj.op, 1, 5) == "auto_" then
		autohost.spool(obj)
	else
		ghpoll.spool(obj)
	end
	return false
end

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
				changed = apply_one(obj, now) or changed
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

-- Projects the windows of another machine keep on this host (the bridge's `sync`), kept across restarts: GitHub
-- wants, branch reads and automations' `project` see them beside this machine's own model.
local synced: bridge.Sync? = (function(): bridge.Sync?
	local ok, raw = pcall(tern.kv.get, bridge.SYNC_KEY)
	return if ok and type(raw) == "table" then bridge.sync_of(raw, HOME, os.time()) else nil
end)()

local function all_projects(): { bridge.SyncProject }
	local locals: { bridge.SyncProject } = {}
	for _, p in model.load().projects do
		table.insert(locals, { id = p.id, name = p.name, root = p.root })
	end
	return bridge.union_projects(locals, synced)
end

-- status.json's text, for the bridge's status node.
local status_text = "{}"

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
	if synced then
		for _, w in (synced :: bridge.Sync).worktrees do
			cwds[w] = true
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
	status_text = tern.json.encode(doc)
	pcall(tern.fs.write, STATUS, status_text)
end

-- The bridge block ------------------------------------------------------------------------

-- Every live bridge block (one per window that opened one), by its pane id here.
local blocks: { [number]: BlockCx } = {}
local sigs = bridge.sigs(string.format("%d-%d", os.time(), math.random(1, 1000000)))
local wins: bridge.Wins = {}
local win_seq = 0
local leader: string? = nil
local replies: bridge.Replies = {}
local replies_dirty = true
local seen: bridge.Seen = {}
local gh_seen: string? = nil
local autos_seen: string? = nil
-- A node changed since the blocks last rendered.
local render_pending = false
local refresh_queued = false
local hostname = tern.getenv("HOSTNAME") or ""

local function read_text(path: string): string
	local ok, text = pcall(tern.fs.read, path, 4194304)
	return if ok and type(text) == "string" and text ~= "" then text else "{}"
end

-- Rebuilds the node texts that may have changed; marks a render when one did.
local function update_nodes()
	local now = os.time()
	local changed = bridge.track(sigs, "status", status_text)
	changed = bridge.track(sigs, "fleet", fleet_json or "{}") or changed
	-- gh.json and autos.json are re-read only when their writer's sig moved.
	local gs = ghpoll.stats().gh_sig
	if gs ~= gh_seen then
		gh_seen = gs
		changed = bridge.track(sigs, "gh", read_text(DATA .. "/gh.json")) or changed
	end
	local as = autohost.stats().auto_sig
	if as ~= autos_seen then
		autos_seen = as
		changed = bridge.track(sigs, "autos", read_text(DATA .. "/autos.json")) or changed
	end
	if mail_dirty then
		mail_dirty = false
		local doc = bridge.mail_doc(box)
		changed = bridge.track(sigs, "mail", tern.json.encode({ seq = doc.seq, msgs = tern.json.array(doc.msgs) })) or changed
	end
	if bridge.prune_replies(replies, now) or replies_dirty then
		replies_dirty = false
		changed = bridge.track(sigs, "replies", tern.json.encode(bridge.replies_doc(replies))) or changed
	end
	bridge.prune_wins(wins, now)
	bridge.prune_seen(seen, now)
	leader = bridge.leader(wins, now)
	-- The header's `at` and `pane` are filled at view time; what else it says changes rarely.
	changed = bridge.track(sigs, "header", hostname .. "\n" .. (HOME or "") .. "\n" .. (leader or "")) or changed
	if changed then
		render_pending = true
	end
end

local function bridge_refresh()
	refresh_queued = false
	if next(blocks) == nil then
		return
	end
	update_nodes()
	if not render_pending then
		return
	end
	render_pending = false
	for pane, cx in blocks do
		-- A block whose pane closed raises: forget it.
		if not pcall(cx.render, cx) then
			blocks[pane] = nil
		end
	end
end

-- Refreshes in a callback of its own, once however many changes asked for it.
local function bridge_soon()
	if refresh_queued or unloading then
		return
	end
	refresh_queued = true
	tern.timer(0, bridge_refresh)
end

local function reply(id: string, r: { [string]: any })
	bridge.put_reply(replies, id, r, os.time())
	replies_dirty = true
	bridge_soon()
end

local function fail(id: string, err: any)
	reply(id, { ok = false, error = tostring(err) })
end

local function op_spool(req: bridge.Request)
	local id = req.id :: string
	local now = os.time()
	-- A resend (the window timed out waiting) is answered without applying it again.
	if bridge.seen(seen, id, now) then
		reply(id, { ok = true })
		return
	end
	local ok, changed = pcall(apply_one, req.obj, now)
	if not ok then
		fail(id, changed)
		return
	end
	if changed then
		save_box()
		notify()
	end
	reply(id, { ok = true })
end

local function op_git(req: bridge.Request)
	local id = req.id :: string
	local argv = { "git" }
	for _, a in req.args do
		table.insert(argv, a)
	end
	local opts: ProcessOptions = { timeout_ms = bridge.git_timeout(req.timeout_ms) }
	if req.cwd then
		opts.cwd = bridge.expand(req.cwd, HOME)
	end
	local ok, err = pcall(tern.process.run, argv, opts, function(res: ProcessResult)
		reply(id, bridge.git_reply(res))
	end)
	if not ok then
		fail(id, err)
	end
end

-- `dirs`: the subfolders (find) and whether the folder is in a git work tree (git), two processes, one reply.
local function op_dirs(id: string, path: string)
	if not tern.fs.exists(path) then
		fail(id, "no such folder: " .. path)
		return
	end
	local names: { string }? = nil
	local find_err: string? = nil
	local in_git: boolean? = nil
	local function done()
		if names == nil and find_err == nil or in_git == nil then
			return
		end
		if find_err then
			fail(id, find_err)
		else
			reply(id, { ok = true, value = tern.json.array(names :: { string }), git = in_git })
		end
	end
	local fok, ferr = pcall(tern.process.run, { "find", "-L", path, "-mindepth", "1", "-maxdepth", "1", "-type", "d" }, { timeout_ms = 10000 }, function(res: ProcessResult)
		-- find says 1 when some entry was unreadable; what it listed still counts.
		if res.status ~= 0 and res.stdout == "" then
			find_err = if res.stderr ~= "" then bridge.cap(res.stderr, 2000) else "find failed"
		else
			names = bridge.dir_names(res.stdout)
		end
		done()
	end)
	if not fok then
		fail(id, ferr)
		return
	end
	local gok = pcall(tern.process.run, { "git", "-C", path, "rev-parse", "--is-inside-work-tree" }, { timeout_ms = 10000 }, function(res: ProcessResult)
		in_git = res.status == 0 and string.match(res.stdout, "^true") ~= nil
		done()
	end)
	if not gok then
		in_git = false
		done()
	end
end

local function op_fs(req: bridge.Request)
	local id = req.id :: string
	if req.fn == "home" then
		reply(id, { ok = true, value = HOME or tern.json.null })
		return
	end
	local path = bridge.expand(req.path, HOME)
	if req.fn == "exists" then
		reply(id, { ok = true, value = tern.fs.exists(path) })
	elseif req.fn == "mkdir" then
		local ok, err = pcall(tern.fs.mkdir, path)
		reply(id, if ok then { ok = true } else { ok = false, error = tostring(err) })
	else
		op_dirs(id, path)
	end
end

local function op_sync(req: bridge.Request)
	local s = bridge.sync_of(req, HOME, os.time())
	synced = s
	local ok, err = pcall(tern.kv.set, bridge.SYNC_KEY, {
		projects = tern.json.array(s.projects),
		worktrees = tern.json.array(s.worktrees),
		visible = s.visible,
		at = s.at,
	})
	if not ok then
		tern.log.warn("projects: synced projects not saved", err)
	end
	reply(req.id :: string, { ok = true })
end

local function on_request(text: string)
	local dok, req = pcall(tern.json.decode, text)
	local code, message, id = bridge.validate(if dok then req else nil)
	if code then
		if id then
			reply(id :: string, { ok = false, error = code, message = message })
		end
		return
	end
	if req.op == "hello" then
		win_seq = bridge.hello(wins, req.win, os.time(), win_seq)
		bridge_soon()
	elseif req.op == "spool" then
		op_spool(req)
	elseif req.op == "git" then
		op_git(req)
	elseif req.op == "fs" then
		op_fs(req)
	else
		op_sync(req)
	end
end

type BridgeState = {}

tern.block.define("bridge", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): BridgeState
		blocks[cx.pane] = cx
		update_nodes()
		bridge_soon()
		return {}
	end,
	title = function(_state: BridgeState): string?
		return "Projects bridge"
	end,
	view = function(_state: BridgeState, cx: BlockCx): BlockView
		local header = bridge.header(sigs, {
			host = hostname,
			home = HOME,
			os = tern.runtime.os,
			pane = cx.pane,
			at = os.time(),
			leader = leader,
			null = tern.json.null,
		})
		local nodes = { tern.ui.text(tern.json.encode(header)) }
		-- main.1 .. main.6: a col each, of text children of at most bridge.CHUNK bytes (main.K.I).
		for i = 2, #bridge.NODES do
			local parts: { Node } = {}
			for _, piece in sigs.chunks[bridge.NODES[i]] or { "{}" } do
				table.insert(parts, tern.ui.text(piece))
			end
			table.insert(nodes, tern.ui.col(parts))
		end
		return { main = tern.ui.col(nodes) }
	end,
	event = function(_state: BridgeState, ev: UiEvent, cx: BlockCx)
		blocks[cx.pane] = cx
		local text = bridge.request_text(ev)
		if text then
			local ok, err = pcall(on_request, text)
			if not ok then
				tern.log.warn("projects: bridge request failed", err)
			end
		end
	end,
} :: BlockDef<BridgeState>)

-- The header names the host; the daemon's environment rarely has HOSTNAME.
if hostname == "" then
	pcall(tern.process.run, { "hostname" }, { timeout_ms = 5000 }, function(res: ProcessResult)
		local name = string.match(res.stdout, "^%s*(.-)%s*$")
		if res.status == 0 and name and name ~= "" then
			hostname = name
			bridge_soon()
		end
	end)
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

every(SPOOL_MS, "spool", function()
	apply_spool()
	if mail_dirty then
		bridge_soon()
	end
end)
every(PANES_MS, "status", function()
	poll_panes()
	local ok, err = pcall(scan_fleets)
	if not ok then
		tern.log.warn("projects: host fleet scan failed", err)
	end
	write_status()
	bridge_soon()
end)

-- GitHub: what the sidebar shows, as folders with the branch each card shows.
ghpoll.start({
	wants = function(): { ghpoll.Want }
		local out: { ghpoll.Want } = {}
		for _, p in all_projects() do
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
		-- A remote window's sidebar counts while that window is live.
		local remote = synced ~= nil and (synced :: bridge.Sync).visible and bridge.leader(wins, os.time()) ~= nil
		return remote or model.load_ui().visible
	end,
	branch_of = function(cwd: string): string?
		local r = repos[cwd]
		return if r then r.branch else nil
	end,
})
every(GH_MS, "github", function()
	ghpoll.tick()
	bridge_soon()
end)

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
		return all_projects()
	end,
})
every(AUTO_MS, "automations", function()
	autohost.tick()
	bridge_soon()
end)

poll_panes()
start_helper()
