--!strict
-- projects, core: constants, the types every module shares, pure helpers, and `new()`, which builds the one
-- context table (`Ctx`) holding all shared mutable state together with the stateful base helpers (scan, card
-- lookups, the read queue, unread marks). window.luau passes that table to every other module's installer.
--
-- Tern pauses a plugin whose callback runs over 50 ms, so heavy work never shares a callback: surface and
-- transcript reads run one per timer turn from a queue (`enqueue`), and flows hand each step to the next turn.

local base = require("./base")
local model = require("./model")
local subagents = require("./subagents")
local identity = require("./identity")

-- The context `new()` builds: the stateful helpers below read and write the shared state through it.
local S: Ctx = nil :: any

local ID = base.ID
local HOME = tern.getenv("HOME")
local MACOS = base.MACOS
local SIDE_TITLE = "Projects"
local action_id = base.action_id
local TOGGLE = base.TOGGLE
local MOD = base.MOD
local PRIMARY = base.PRIMARY
-- Constants in one table.
local K = {
	-- Orca's default sidebar width and its drag limits, in px of the sidebar's content (`.op-sidebar`).
	SIDE_PX = 280,
	MIN_PX = 220,
	MAX_PX = 500,
	-- The canvas pane's chrome around `.op-sidebar` (chrome.css drops Tern's inset, so none).
	CHROME_PX = 0,
	-- Sidebar tick period while it shows. Each tick re-reads the agents and the host's status and draws only when
	-- something shown changed (or every DRAW_MS, for the "2m ago" labels).
	TICK_MS = 2000,
	DRAW_MS = 20000,
	-- How often a tick re-measures the sidebar's width against a window resize (no event exists for one).
	FIT_MS = 10000,
	-- How often a shown sidebar checks that it is the only sidebar canvas.
	DEDUPE_MS = 30000,
	-- How often a working agent's surface is re-read, and an idle one's.
	WORK_READ_MS = 6000,
	IDLE_READ_MS = 30000,
	-- Surface nodes read per agent for its omp-internal subagents, and transcript messages per prompt read.
	SURFACE_NODES = 600,
	TRANSCRIPT_LAST = 6,
	-- The host half's status file is read at most this big.
	STATUS_BYTES = 1048576,
	-- Longest last message a report-back carries.
	REPORT_CHARS = 6000,
	-- How long a revealed card glows (Orca's flash).
	REVEAL_MS = 1500,
	-- A new session's shell is polled this often, this long, before its first agent starts.
	SESSION_POLL_MS = 150,
	SESSION_WAIT_MS = 3000,
}

export type AgentBlock = {
	pane: number,
	cwd: string,
	state: string,
	model: string?,
	last_message: string?,
}

export type AgentRow = {
	pane: number,
	key: string,
	title: string,
	state: string,
	result: string?,
	done_at: number?,
	started: number?,
	last_activity: number?,
	model: string?,
	last_message: string?,
	prompt: string?,
	tool: string?,
	cwd: string,
	branch: string?,
	detached: string?,
	primary: boolean?,
	pinned: boolean?,
	deleting: boolean?,
	-- Its branch's PR (prs.luau) and whether that is stale.
	pr: any?,
	pr_stale: boolean?,
	spawned: { AgentRow },
	-- The owning project's id.
	project: string?,
	internal: { subagents.Subagent },
}

export type Counts = { working: number, waiting: number }

local function clean<T>(v: T?): T?
	if v == (tern.json.null :: any) then
		return nil
	end
	return v
end

local function blank(s: string?): boolean
	return s == nil or string.match(s, "^%s*$") ~= nil
end

local function tilde(path: string): string
	if HOME and path == HOME then
		return "~"
	end
	if HOME and string.sub(path, 1, #HOME + 1) == HOME .. "/" then
		return "~" .. string.sub(path, #HOME + 1)
	end
	return path
end

local function firstline(s: string): string
	return (string.match(s, "^%s*([^\n]*)") or s)
end

local function short(s: string?, n: number): string?
	if s == nil then
		return nil
	end
	if #s <= n then
		return s
	end
	local cut = utf8.offset(s, n + 1)
	return string.sub(s, 1, if cut then cut - 1 else n) .. "…"
end

local function trimmed(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

-- Runs `fn` on the next timer turn with a fresh cx: work that must not share the current callback's budget.
local function defer(fn: (cx: WindowCx) -> ())
	tern.timer(0, function(cx)
		if cx then
			fn(cx)
		end
	end)
end

-- One job per timer turn, in order; each does at most one surface or transcript read.
local jobs: { (cx: WindowCx) -> () } = {}
local pumping = false
local function pump()
	if pumping or #jobs == 0 then
		return
	end
	pumping = true
	tern.timer(0, function(cx)
		pumping = false
		if cx == nil then
			table.clear(jobs)
			table.clear(S.queued)
			return
		end
		local job = table.remove(jobs, 1)
		if job then
			local ok, err = pcall(job, cx)
			if not ok then
				tern.log.warn("projects: job failed", err)
			end
		end
		pump()
	end)
end

local function enqueue(job: (cx: WindowCx) -> ())
	table.insert(jobs, job)
	pump()
end

-- The record key of the card for `pane`: a live agent's bound record (identity.luau), a sleeping card's record
-- (its pane is a negative id of this run, `S.sleep_key`), else the pane id as text (an agent with no record).
local function key_of(pane: number): string
	if pane < 0 then
		return S.sleep_key[pane] or tostring(-pane)
	end
	return S.pane_key[pane] or tostring(pane)
end

local function meta_of(pane: number): model.AgentMeta?
	return S.state.agents[key_of(pane)]
end

-- The live pane of record `key`, else nil.
local function pane_of(key: string?): number?
	if key == nil then
		return nil
	end
	local m = S.state.agents[key :: string]
	local p = if m then m.pane else nil
	return if p and S.pane_key[p] == key then p else nil
end

-- The pane a card shows for record `key`: its live pane, else its sleeping id (assigned once per run).
local function card_of_key(key: string): number
	local live = pane_of(key)
	if live then
		return live
	end
	local id = S.sleep_pane[key]
	if id == nil then
		S.sleep_next -= 1
		id = S.sleep_next
		S.sleep_pane[key] = id
		S.sleep_key[id] = key
	end
	return id
end

local function project_of(pane: number, cwd: string?): model.Project?
	local meta = meta_of(pane)
	if meta then
		local p = model.get(S.state, meta.project)
		if p then
			return p
		end
	end
	return model.project_for_path(S.state, cwd)
end

local function title_of(pane: number, cwd: string?): string
	local meta = meta_of(pane)
	if meta then
		return meta.title
	end
	if cwd and cwd ~= "" then
		return model.basename(cwd)
	end
	return "agent " .. pane
end

-- The folder a card works in: a live agent's cwd, a sleeping card's worktree.
local function cwd_of(pane: number): string?
	local b = S.blocks[pane]
	if b then
		return if b.cwd ~= "" then b.cwd else nil
	end
	local meta = meta_of(pane)
	return if meta then meta.worktree else nil
end

local function save_ui()
	model.save_ui(S.ui)
end

-- The host half's status (host.luau `write_status`): omp session file per pane, branch per folder, queued mail.
-- Read every scan; a missing or half-written file keeps the last one.
local function read_status()
	local ok, text = pcall(tern.fs.read, tern.plugin.data .. "/status.json", K.STATUS_BYTES)
	if not ok then
		return
	end
	local dok, doc = pcall(tern.json.decode, text)
	if not dok or type(doc) ~= "table" then
		return
	end
	local sessions: { [number]: string } = {}
	if type(doc.panes) == "table" then
		for k, p in doc.panes do
			local pane = tonumber(k)
			if pane and type(p) == "table" and type(p.session_file) == "string" then
				sessions[pane] = p.session_file
			end
		end
	end
	S.sessions = sessions
	S.host_repos = if type(doc.repos) == "table" then doc.repos else {}
	S.mail_queued = if type(doc.queued) == "number" then doc.queued else 0
	S.status_at = if type(doc.at) == "number" then doc.at else 0
	-- The fleet model is re-read only when the host wrote a new one.
	if doc.fleet_sig ~= nil and doc.fleet_sig ~= S.fleet_sig and S.load_fleets then
		S.fleet_sig = doc.fleet_sig
		S.load_fleets()
	end
	-- Likewise the GitHub model (prs.luau), in a callback of its own (it may toast).
	if doc.gh_sig ~= nil and doc.gh_sig ~= S.gh_sig and S.load_gh then
		S.gh_sig = doc.gh_sig
		tern.timer(0, function(cx)
			local t0 = tern.now()
			local ok, err = pcall(S.load_gh, cx)
			if not ok then
				tern.log.warn("projects: gh.json load failed", err)
			end
			local ms = tern.now() - t0
			if ms > 25 then
				tern.log.warn(string.format("projects: gh load took %.1f ms", ms))
			end
			S.dirty = true
		end)
	end
	-- And the automations model (autowin.luau), when the host wrote a new one.
	if doc.auto_sig ~= nil and doc.auto_sig ~= S.auto_sig and S.load_autos then
		S.auto_sig = doc.auto_sig
		tern.timer(0, function(_cx)
			S.load_autos()
		end)
	end
end

-- The scan's first half, one native call: every agent block (`cx.agents:list()`), and whether any shown field of
-- them changed. False when the list failed (the last one stands).
local function scan_list(cx: WindowCx): boolean
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if not ok then
		return false
	end
	local fresh: { [number]: AgentBlock } = {}
	local sig: { string } = {}
	for _, b in list do
		local block: AgentBlock = {
			pane = b.pane,
			cwd = b.cwd or "",
			state = b.state,
			model = clean(b.model),
			last_message = clean(b.last_message),
		}
		fresh[b.pane] = block
		table.insert(sig, string.format("%d|%s|%s|%s|%s", b.pane, block.state, block.cwd, block.model or "", block.last_message or ""))
	end
	S.blocks = fresh
	table.sort(sig)
	local asig = table.concat(sig, "\n")
	if asig ~= S.agents_sig then
		S.agents_sig = asig
		S.dirty = true
	end
	return true
end

-- The scan's second half, on the blocks `scan_list` read: the state from kv, the host's status, records bound
-- to panes (saved when that changed), and the status-line inputs.
local function scan_rest()
	S.state = model.load()
	read_status()
	-- Remote hosts' status (remote.luau): their panes' omp session files, branches and queued mail join this host's.
	if S.remote_merge then
		S.remote_merge()
	end
	local live: { [number]: { cwd: string } } = {}
	for pane, b in S.blocks do
		live[pane] = { cwd = b.cwd }
	end
	local by_pane, changed = identity.bind(S.state.agents :: any, live, S.sessions, os.time())
	S.pane_key = by_pane
	if changed then
		model.save(S.state)
		S.dirty = true
	end
	local new_counts: { [string]: Counts } = {}
	local new_panes: { [number]: string } = {}
	for pane, b in S.blocks do
		local p = project_of(pane, b.cwd)
		if p then
			new_panes[pane] = p.id
			local c = new_counts[p.id] or { working = 0, waiting = 0 }
			if b.state == "working" then
				c.working += 1
			elseif b.state == "waiting_input" then
				c.waiting += 1
			end
			new_counts[p.id] = c
		end
	end
	for _, cache in { S.internal, S.internal_at, S.tools, S.first_seen, S.prompts, S.prompt_stale, S.results, S.last_activity, S.expanded, S.idle_open, S.surface_sig } :: { { [number]: any } } do
		for pane in cache do
			if S.blocks[pane] == nil and pane > 0 then
				cache[pane] = nil
			end
		end
	end
	local count_sig: { string } = {}
	for id, c in new_counts do
		table.insert(count_sig, string.format("%s=%d/%d", id, c.working, c.waiting))
	end
	table.sort(count_sig)
	local csig = table.concat(count_sig, ",")
	S.counts, S.pane_project = new_counts, new_panes
	-- The status segment only reads these: refresh it only when they changed.
	if csig ~= S.counts_sig then
		S.counts_sig = csig
		tern.chrome.refresh()
	end
end

-- The whole scan in one call, for user actions that need it now (timers split it, `scan_list` then `scan_rest`).
local function scan(cx: WindowCx)
	if scan_list(cx) then
		scan_rest()
	end
end

local function focused_cwd(cx: WindowCx): (number?, string?)
	local id = cx.session:focused()
	if id == nil then
		return nil, nil
	end
	local info = cx.session:pane(id)
	local cwd = if info then info.cwd else nil
	if cwd == "" then
		cwd = nil
	end
	return id, cwd
end

-- Runs git as a `tern.process.spawn` child: its output streams in (in chunks) and `cb` gets the whole result once
-- it ended, like `tern.process.run` without holding the window's UI thread for the run.
local function git(args: { string }, cb: (res: ProcessResult, cx: WindowCx?) -> (), timeout_ms: number?)
	local argv = { "git" }
	for _, a in args do
		table.insert(argv, a)
	end
	local out, err = {}, {}
	local timed_out = false
	local done = false
	local ok, child = pcall(tern.process.spawn, argv, {
		split = "chunks",
		stdout = function(data: string)
			table.insert(out, data)
		end,
		stderr = function(data: string)
			table.insert(err, data)
		end,
		exit = function(res: SpawnExit, cx: WindowCx?)
			done = true
			cb({ status = if timed_out then -1 else res.status, stdout = table.concat(out), stderr = table.concat(err), timed_out = timed_out }, cx)
		end,
	})
	if not ok then
		cb({ status = -1, stdout = "", stderr = tostring(child), timed_out = false }, nil)
		return
	end
	tern.timer(timeout_ms or 30000, function()
		if not done then
			timed_out = true
			(child :: Child):kill()
		end
	end)
end

-- Host dispatch. `host` is nil for this machine (the window's own), else a remote Tern host's name
-- (`ManagedHost.name`); remote work goes through that host's bridge block (remote.luau, `S.remote_rpc`).

-- Runs git on `host`: here as `git` above, there through the bridge (same result shape; a transport failure is
-- status -1 with the reason in stderr). `cwd` is passed as `git -C`.
local function git_on(ctx: any, host: string?, args: { string }, cb: (res: ProcessResult, cx: WindowCx?) -> (), timeout_ms: number?, cwd: string?)
	if host == nil then
		if cwd then
			local full = { "-C", cwd }
			for _, a in args do
				table.insert(full, a)
			end
			git(full, cb, timeout_ms)
		else
			git(args, cb, timeout_ms)
		end
		return
	end
	ctx.remote_rpc(host, { op = "git", args = args, cwd = cwd, timeout_ms = timeout_ms or 30000 }, function(reply: any, cx: WindowCx?)
		if type(reply) == "table" and reply.ok == true then
			cb({
				status = if type(reply.status) == "number" then reply.status else -1,
				stdout = if type(reply.stdout) == "string" then reply.stdout else "",
				stderr = if type(reply.stderr) == "string" then reply.stderr else "",
				timed_out = reply.timed_out == true,
			}, cx)
		else
			local why = if type(reply) == "table" then tostring(reply.message or reply.error) else "no reply"
			cb({ status = -1, stdout = "", stderr = host .. ": " .. why, timed_out = false }, cx)
		end
	end, (timeout_ms or 30000) + 15000)
end

-- A file check on `host`: fn "exists" (value: boolean), "mkdir" (mkdir -p), "dirs" (value: sorted subfolder names;
-- extra: the reply, `git` = whether the folder is in a git work tree), "home" (value: the host's HOME).
-- `cb(ok, value, err, extra, cx)`; on this machine it runs before `fs_on` returns.
local function fs_on(ctx: any, host: string?, fn: string, path: string, cb: (ok: boolean, value: any, err: string?, extra: any, cx: WindowCx?) -> ())
	if host == nil then
		local ok, value = pcall(function(): any
			if fn == "exists" then
				return tern.fs.exists(path)
			elseif fn == "mkdir" then
				tern.fs.mkdir(path)
				return true
			elseif fn == "home" then
				return HOME
			elseif fn == "dirs" then
				local out = {}
				for _, name in tern.fs.list(path) do
					if string.sub(name, 1, 1) ~= "." and tern.fs.exists(path .. "/" .. name .. "/.") then
						table.insert(out, name)
					end
				end
				table.sort(out)
				return out
			end
			error("unknown fs op " .. fn)
		end)
		cb(ok, if ok then value else nil, if ok then nil else tostring(value), nil, nil)
		return
	end
	ctx.remote_rpc(host, { op = "fs", fn = fn, path = path }, function(reply: any, cx: WindowCx?)
		if type(reply) == "table" and reply.ok == true then
			cb(true, reply.value, nil, reply, cx)
		else
			local why = if type(reply) == "table" then tostring(reply.message or reply.error) else "no reply"
			cb(false, nil, host .. ": " .. why, nil, cx)
		end
	end, 20000)
end

-- A window → host request (the host half's spool ops: deliver, ack, gh_*, auto_*): a file in `<data>/spool/` here,
-- a bridge request there (remote.luau retries it until the host confirms it).
local spool_seq = 0
local function spool_on(ctx: any, host: string?, obj: { [string]: any })
	if host ~= nil then
		ctx.remote_spool(host, obj)
		return
	end
	spool_seq += 1
	local dir = tern.plugin.data .. "/spool"
	local name = string.format("%012d-%06d-%04x.json", os.time(), spool_seq, math.random(0, 0xffff))
	pcall(tern.fs.mkdir, dir)
	tern.fs.write(dir .. "/" .. name, tern.json.encode(obj))
end

local function errtext(res: ProcessResult): string
	return trimmed(if res.stderr ~= "" then res.stderr else res.stdout)
end

-- The session holding `pane`, when it is not the current one.
local function session_of(cx: WindowCx, pane: number): SessionInfo?
	local tab = cx.session:tab_of(pane)
	if tab == nil then
		return nil
	end
	for _, s in cx.session:sessions() do
		if table.find(s.tabs, tab) then
			return s
		end
	end
	return nil
end

-- Hosts -----------------------------------------------------------------------------
-- A host is named by `ManagedHost.name`; nil stands for the window's own machine (the local host).

local function hosts_list(cx: WindowCx): { ManagedHost }
	local ok, list = pcall(function()
		return cx.hosts:list()
	end)
	return if ok and type(list) == "table" then list else {}
end

-- The current session's host, nil when it is this machine.
local function host_now(cx: WindowCx): string?
	local ok, h = pcall(function()
		return cx.hosts:current()
	end)
	if ok and type(h) == "table" and h.kind == "remote" then
		return h.name
	end
	return nil
end

-- The host `ManagedHost.id` names, nil when local or unknown.
local function host_name(cx: WindowCx, id: number): string?
	for _, h in hosts_list(cx) do
		if h.id == id then
			return if h.kind == "remote" then h.name else nil
		end
	end
	return nil
end

-- The `ManagedHost` record of `host` (nil: the local one), nil when not attached.
local function host_record(cx: WindowCx, host: string?): ManagedHost?
	for _, h in hosts_list(cx) do
		if (host == nil and h.kind == "local") or (host ~= nil and h.kind == "remote" and h.name == host) then
			return h
		end
	end
	return nil
end

-- The remote host running `pane` (a window pane id), nil when it runs here.
local function host_of_pane(cx: WindowCx, pane: number): string?
	for _, h in hosts_list(cx) do
		if h.kind == "remote" and table.find(h.panes, pane) then
			return h.name
		end
	end
	return nil
end

-- The session named `name` on `host` (nil: this machine). With no hosts listed (an old Tern) any host matches.
local function session_named(cx: WindowCx, name: string, host: string?): ManagedSession?
	local rec = host_record(cx, host)
	for _, s in cx.sessions:list() do
		if s.name == name and (rec == nil or s.host == rec.id) then
			return s
		end
	end
	return nil
end

-- Shows the project's session (on the project's host), creating it at the root when missing; the created
-- session's id, else nil. Raises when the project's host is not connected (nothing would start there).
local function ensure_session(cx: WindowCx, project: model.Project): number?
	local host = project.host
	local s = session_named(cx, project.name, host)
	if s then
		if not s.current then
			cx.sessions:switch(s.id)
		end
		return nil
	end
	if host_now(cx) ~= host then
		local rec = host_record(cx, host)
		if rec == nil or rec.state ~= "connected" then
			error(string.format("%s is not connected (Switch host first)", host or "this machine"), 0)
		end
		cx.hosts:switch(rec.id)
	end
	return cx.sessions:create({ name = project.name, cwd = project.root }).id
end

-- Unread ---------------------------------------------------------------------------

local function set_unread(key: string, on: boolean)
	S.ui = model.load_ui()
	if (S.ui.unread[key] == true) ~= on then
		S.ui.unread[key] = if on then true else nil
		save_ui()
	end
end

-- Cards ----------------------------------------------------------------------------

-- The top-level card holding `pane` (itself, or the live ancestor a spawned subagent hangs under).
local function card_pane(pane: number): number
	local p = pane
	for _ = 1, 32 do
		local meta = meta_of(p)
		local up = if meta then pane_of(meta.parent) else nil
		if up == nil then
			return p
		end
		p = up :: number
	end
	return p
end

-- The card keys of `pane` and every live spawned descendant: a card is unread while any of them is.
local function unread_keys(pane: number): { string }
	local keys: { string } = { key_of(pane) }
	local i = 1
	while i <= #keys do
		local parent = keys[i]
		for k, m in S.state.agents do
			if m.parent == parent and pane_of(k) and not table.find(keys, k) then
				table.insert(keys, k)
			end
		end
		i += 1
	end
	return keys
end

local function clear_unread(keys: { string })
	S.ui = model.load_ui()
	local any = false
	for _, k in keys do
		if S.ui.unread[k] then
			S.ui.unread[k] = nil
			any = true
		end
	end
	if any then
		save_ui()
	end
end

-- Pickers ---------------------------------------------------------------------------

-- Asks for a line of text; `fn` runs on a fresh timer turn unless the user dismissed it or left it blank.
local function ask_text(cx: WindowCx, opts: PromptOptions, fn: (text: string, cx: WindowCx) -> ())
	cx:prompt(opts):next(function(text, _err, ncx)
		if ncx and text and not blank(text) then
			local value = trimmed(text :: string)
			defer(function(dcx)
				fn(value, dcx)
			end)
		end
	end)
end

-- Asks for one of `opts.items`; `fn` runs on a fresh timer turn with the chosen item unless dismissed.
local function ask_pick(cx: WindowCx, opts: PickOptions, fn: (item: PickItem, cx: WindowCx) -> ())
	cx:pick(opts):next(function(item, _err, ncx)
		if ncx and item then
			defer(function(dcx)
				fn(item :: PickItem, dcx)
			end)
		end
	end)
end

-- The one context table: every piece of shared mutable state (fields below), plus the functions each module's
-- installer adds (`S.show_side`, `S.snapshot`, …), called late so modules never require each other.
export type Ctx = {
	-- In-memory caches. `state` and `ui` are re-read from kv before every change (other windows share them).
	state: model.State,
	ui: model.Ui,
	-- Agent blocks by pane, from the last `cx.agents:list()`.
	blocks: { [number]: AgentBlock },
	-- Per agent pane: its listed omp-internal subagents, when its surface was last read (tern.now()), its own
	-- running tool line, when each subagent id was first seen (os.time()) and its latest prompt.
	internal: { [number]: { subagents.Subagent } },
	internal_at: { [number]: number },
	tools: { [number]: string? },
	first_seen: { [number]: { [string]: number } },
	prompts: { [number]: string },
	-- Panes whose latest prompt must be read again.
	prompt_stale: { [number]: boolean },
	-- Reads queued per pane, so a pane is never queued twice.
	queued: { [string]: boolean },
	-- The last turn's result per pane until it works again, and when the turn ended.
	results: { [number]: { result: string, at: number } },
	-- os.time() of each agent's last state change.
	last_activity: { [number]: number },
	-- Record keys of agents put to sleep while working, until their block closes (then the record carries it).
	interrupted: { [string]: boolean },
	-- Card keys being deleted.
	deleting: { [string]: boolean },
	-- Parent pane → its child list / "N idle" fold is open.
	expanded: { [number]: boolean },
	idle_open: { [number]: boolean },
	-- The card glowing after a reveal; tern.now() after which the glow is off, whatever happens to its timer.
	reveal_pane: number?,
	reveal_until: number,
	-- From the host half's status file: omp session file per live pane, branch per folder, queued mail count.
	sessions: { [number]: string },
	host_repos: { [string]: { branch: string?, head: string? } },
	mail_queued: number,
	-- Live pane → bound record key (identity.luau), and the negative ids sleeping cards get in this run.
	pane_key: { [number]: string },
	sleep_pane: { [string]: number },
	sleep_key: { [number]: string },
	sleep_next: number,
	-- Something the sidebar shows changed since its last draw; signatures of the last scan.
	dirty: boolean,
	agents_sig: string?,
	counts_sig: string?,
	-- Status-line inputs: agent counts per project id and each agent pane's project id.
	counts: { [string]: Counts },
	pane_project: { [number]: string },
	-- Top-level card panes in rendered order (previous/next agent), from the last snapshot.
	rendered: { number },
	-- The last focused pane other than the sidebar.
	last_main: number?,
	-- The sidebar canvas and the generation of its refresh timer.
	side_pane: number?,
	side_gen: number,
	-- The sidebar's share when last fitted with the ratio of its nearest split and the font size it was fitted at,
	-- and whether the layout changed since the last settled fit.
	fitted: { pane: number, ratio: number, near: number, font: number }?,
	layout_dirty: boolean,
	-- The last answer each spawned subagent reported (report-backs go through the mailbox, mail.luau).
	reported: { [number]: string },
	[string]: any,
}

-- Builds the context once per plugin run.
local function new(): Ctx
	S = {
	-- In-memory caches. `state` and `ui` are re-read from kv before every change (other windows share them).
	state = model.load(),
	ui = model.load_ui(),
	-- Agent blocks by pane, from the last `cx.agents:list()`.
	blocks = {} :: { [number]: AgentBlock },
	-- Per agent pane: its listed omp-internal subagents, when its surface was last read (tern.now()), its own
	-- running tool line, when each subagent id was first seen (os.time()) and its latest prompt.
	internal = {} :: { [number]: { subagents.Subagent } },
	internal_at = {} :: { [number]: number },
	tools = {} :: { [number]: string? },
	first_seen = {} :: { [number]: { [string]: number } },
	prompts = {} :: { [number]: string },
	-- Panes whose latest prompt must be read again.
	prompt_stale = {} :: { [number]: boolean },
	-- Reads queued per pane, so a pane is never queued twice.
	queued = {} :: { [string]: boolean },
	-- The last turn's result per pane until it works again, and when the turn ended.
	results = {} :: { [number]: { result: string, at: number } },
	-- os.time() of each agent's last state change.
	last_activity = {} :: { [number]: number },
	-- Record keys of agents put to sleep while working, until their block closes (then the record carries it).
	interrupted = {} :: { [string]: boolean },
	-- Card keys being deleted.
	deleting = {} :: { [string]: boolean },
	-- Parent pane → its child list / "N idle" fold is open.
	expanded = {} :: { [number]: boolean },
	idle_open = {} :: { [number]: boolean },
	-- The card glowing after a reveal; tern.now() after which the glow is off, whatever happens to its timer.
	reveal_pane = nil :: number?,
	reveal_until = 0,
	sessions = {} :: { [number]: string },
	host_repos = {} :: { [string]: any },
	mail_queued = 0,
	pane_key = {} :: { [number]: string },
	sleep_pane = {} :: { [string]: number },
	sleep_key = {} :: { [number]: string },
	sleep_next = 0,
	dirty = true,
	surface_sig = {} :: { [number]: string },
	-- Status-line inputs: agent counts per project id and each agent pane's project id.
	counts = {} :: { [string]: Counts },
	pane_project = {} :: { [number]: string },
	-- Top-level card panes in rendered order (previous/next agent), from the last snapshot.
	rendered = {} :: { number },
	-- The last focused pane other than the sidebar.
	last_main = nil :: number?,
	-- The sidebar canvas and the generation of its refresh timer.
	side_pane = nil :: number?,
	side_gen = 0,
	-- The sidebar's share when last fitted with the ratio of its nearest split and the font size it was fitted at,
	-- and whether the layout changed since the last settled fit.
	fitted = nil :: { pane: number, ratio: number, near: number, font: number }?,
	layout_dirty = false,
	-- The last answer each spawned subagent reported.
	reported = {} :: { [number]: string },
	} :: any
	S.card_pane = card_pane
	S.card_of_key = card_of_key
	S.pane_of = pane_of
	S.clear_unread = clear_unread
	S.cwd_of = cwd_of
	S.enqueue = enqueue
	S.meta_of = meta_of
	S.project_of = project_of
	S.save_ui = save_ui
	S.scan = scan
	S.scan_list = scan_list
	S.scan_rest = scan_rest
	S.set_unread = set_unread
	S.title_of = title_of
	S.unread_keys = unread_keys
	return S
end

return {
	new = new,
	HOME = HOME,
	ID = ID,
	K = K,
	MACOS = MACOS,
	MOD = MOD,
	PRIMARY = PRIMARY,
	SIDE_TITLE = SIDE_TITLE,
	TOGGLE = TOGGLE,
	action_id = action_id,
	ask_pick = ask_pick,
	ask_text = ask_text,
	blank = blank,
	clean = clean,
	defer = defer,
	ensure_session = ensure_session,
	errtext = errtext,
	fs_on = fs_on,
	firstline = firstline,
	focused_cwd = focused_cwd,
	git = git,
	git_on = git_on,
	spool_on = spool_on,
	key_of = key_of,
	plural = plural,
	session_named = session_named,
	host_now = host_now,
	host_name = host_name,
	host_record = host_record,
	host_of_pane = host_of_pane,
	hosts_list = hosts_list,
	session_of = session_of,
	short = short,
	tilde = tilde,
	trimmed = trimmed,
}
