--!strict
-- projects, core: constants, the types every module shares, pure helpers, and `new()`, which builds the one
-- context table (`Ctx`) holding all shared mutable state together with the stateful base helpers (scan, card
-- lookups, the read queue, unread marks). window.luau passes that table to every other module's installer.
--
-- Tern pauses a plugin whose callback runs over 50 ms, so heavy work never shares a callback: surface and
-- transcript reads run one per timer turn from a queue (`enqueue`), and flows hand each step to the next turn.

local model = require("./model")
local subagents = require("./subagents")

-- The context `new()` builds: the stateful helpers below read and write the shared state through it.
local S: Ctx = nil :: any

local ID = tern.plugin.id
local HOME = tern.getenv("HOME")
local MACOS = tern.runtime.os == "macos"
local SIDE_TITLE = "Projects"
local function action_id(cmd: string): string
	return "plugin." .. ID .. "." .. cmd
end
local TOGGLE = action_id("toggle_sidebar")
local MOD = if MACOS then "cmd+alt+shift+" else "ctrl+alt+shift+"
local PRIMARY = if MACOS then "cmd+" else "ctrl+"
-- Constants in one table.
local K = {
	-- Orca's default sidebar width and its drag limits, in px of the sidebar's content (`.op-sidebar`).
	SIDE_PX = 280,
	MIN_PX = 220,
	MAX_PX = 500,
	-- The canvas pane's chrome around `.op-sidebar` (chrome.css drops Tern's inset, so none).
	CHROME_PX = 0,
	-- Sidebar refresh period while it shows, and how often idle agents' surfaces are re-read.
	TICK_MS = 2000,
	IDLE_READ_MS = 10000,
	-- How long a git branch read stays fresh, in seconds.
	REPO_TTL = 15,
	-- Surface nodes read per agent for its omp-internal subagents.
	SURFACE_NODES = 2000,
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
	spawned: { AgentRow },
	-- The owning project's id.
	project: string?,
	internal: { subagents.Subagent },
}

export type Counts = { working: number, waiting: number }

export type Repo = { branch: string?, head: string?, at: number, pending: boolean? }

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

-- The kv key of the card for `pane` (a sleeping card's pane is its record key, negated).
local function key_of(pane: number): string
	return tostring(if pane < 0 then -pane else pane)
end

local function meta_of(pane: number): model.AgentMeta?
	return S.state.agents[key_of(pane)]
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

-- Reads every agent block and recomputes the status-line inputs.
local function scan(cx: WindowCx)
	S.state = model.load()
	local fresh: { [number]: AgentBlock } = {}
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		for _, b in list do
			fresh[b.pane] = {
				pane = b.pane,
				cwd = b.cwd or "",
				state = b.state,
				model = clean(b.model),
				last_message = clean(b.last_message),
			}
		end
	end
	S.blocks = fresh
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
	for _, cache in { S.internal, S.internal_at, S.tools, S.first_seen, S.prompts, S.prompt_stale, S.results, S.last_activity, S.expanded, S.idle_open } :: { { [number]: any } } do
		for pane in cache do
			if S.blocks[pane] == nil and pane > 0 then
				cache[pane] = nil
			end
		end
	end
	-- Branch reads only for folders a card shows: live agents' cwds and sleeping cards' worktrees.
	local used: { [string]: boolean } = {}
	for _, b in S.blocks do
		used[b.cwd] = true
	end
	for _, m in S.state.agents do
		if m.closed and m.worktree then
			used[m.worktree :: string] = true
		end
	end
	for cwd, r in S.repos do
		if not used[cwd] and not r.pending then
			S.repos[cwd] = nil
		end
	end
	S.counts, S.pane_project = new_counts, new_panes
	tern.chrome.refresh()
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

local function git(args: { string }, cb: (res: ProcessResult, cx: WindowCx?) -> (), timeout_ms: number?)
	local argv = { "git" }
	for _, a in args do
		table.insert(argv, a)
	end
	tern.process.run(argv, { timeout_ms = timeout_ms or 30000 }, cb)
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

local function session_named(cx: WindowCx, name: string): ManagedSession?
	for _, s in cx.sessions:list() do
		if s.name == name then
			return s
		end
	end
	return nil
end

-- Shows the project's session, creating it at the root when missing; the created session's id, else nil.
local function ensure_session(cx: WindowCx, project: model.Project): number?
	local s = session_named(cx, project.name)
	if s then
		if not s.current then
			cx.sessions:switch(s.id)
		end
		return nil
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
		if meta == nil or meta.parent == nil or S.blocks[meta.parent :: number] == nil then
			return p
		end
		p = meta.parent :: number
	end
	return p
end

-- The card keys of `pane` and every live spawned descendant: a card is unread while any of them is.
local function unread_keys(pane: number): { string }
	local keys: { string } = { key_of(pane) }
	local i = 1
	while i <= #keys do
		local parent = tonumber(keys[i])
		for k, m in S.state.agents do
			if m.parent == parent and S.blocks[tonumber(k) or 0] then
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
	-- Live git branch per cwd.
	repos: { [string]: Repo },
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
	-- The last answer each spawned subagent reported, and reports waiting for their busy parent.
	reported: { [number]: string },
	pending: { [number]: { string } },
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
	-- Live git branch per cwd.
	repos = {} :: { [string]: Repo },
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
	-- The last answer each spawned subagent reported, and reports waiting for their busy parent.
	reported = {} :: { [number]: string },
	pending = {} :: { [number]: { string } },
	} :: any
	S.card_pane = card_pane
	S.clear_unread = clear_unread
	S.cwd_of = cwd_of
	S.enqueue = enqueue
	S.meta_of = meta_of
	S.project_of = project_of
	S.save_ui = save_ui
	S.scan = scan
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
	firstline = firstline,
	focused_cwd = focused_cwd,
	git = git,
	key_of = key_of,
	plural = plural,
	session_named = session_named,
	session_of = session_of,
	short = short,
	tilde = tilde,
	trimmed = trimmed,
}
