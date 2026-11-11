--!strict
-- projects, sidebar contents: the background surface and transcript reads, live git branches, keycaps of our
-- chords, the snapshot sidebar.luau draws, redraws (now, coalesced, after a change) and the reveal glow.

local model = require("./model")
local subagents = require("./subagents")
local sidebar = require("./sidebar")
local core = require("./core")
local K = core.K
local MACOS = core.MACOS
local action_id = core.action_id
local blank = core.blank
local clean = core.clean
local firstline = core.firstline
local key_of = core.key_of
local short = core.short

type AgentRow = core.AgentRow
type Repo = core.Repo

-- The context: all shared state and the other modules' functions, set by the installer below.
local S: core.Ctx = nil :: any

-- Reads -----------------------------------------------------------------------------

-- Reads one agent's surface: its listed internal subagents (first-seen times kept) and its own running tool.
local function read_surface(cx: WindowCx, pane: number)
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { as = "table", nodes = K.SURFACE_NODES })
	end)
	if not ok then
		return
	end
	local got, list = pcall(subagents.extract, tree)
	if not got then
		tern.log.warn("projects: subagents.extract failed", list)
		list = {}
	end
	local t = os.time()
	local seen = S.first_seen[pane] or {}
	local live = subagents.running(list :: { subagents.Subagent })
	local ids: { [string]: boolean } = {}
	for _, s in live do
		seen[s.id] = seen[s.id] or t
		s.first_seen = seen[s.id]
		ids[s.id] = true
	end
	for id in seen do
		if not ids[id] then
			seen[id] = nil
		end
	end
	S.first_seen[pane] = seen
	S.internal[pane] = live
	S.tools[pane] = subagents.tool(tree)
end

-- Reads one agent's latest user prompt from its omp transcript.
local function read_prompt(cx: WindowCx, pane: number)
	local ok, msgs = pcall(function()
		return cx.agents:transcript(pane, { last = 20 })
	end)
	S.prompt_stale[pane] = false
	if not ok then
		return
	end
	for i = #msgs, 1, -1 do
		local m = msgs[i]
		if m.role == "user" and not blank(m.text) then
			S.prompts[pane] = short(firstline(m.text), 200) :: string
			return
		end
	end
end

-- Re-reads, at most once per pane, the surfaces of working agents (the rest every IDLE_READ_MS) and stale
-- prompts, one read per timer turn.
local function queue_reads()
	local t = tern.now()
	for pane, b in S.blocks do
		local due = b.state == "working" or S.internal_at[pane] == nil or t - (S.internal_at[pane] :: number) >= K.IDLE_READ_MS
		local skey = "s" .. pane
		if due and b.state ~= "exited" and not S.queued[skey] then
			S.queued[skey] = true
			S.internal_at[pane] = t
			S.enqueue(function(cx)
				S.queued[skey] = nil
				if S.blocks[pane] then
					read_surface(cx, pane)
				end
			end)
		end
		local pkey = "p" .. pane
		if (S.prompt_stale[pane] or S.prompts[pane] == nil and S.prompt_stale[pane] == nil) and not S.queued[pkey] then
			S.queued[pkey] = true
			S.prompt_stale[pane] = false
			S.enqueue(function(cx)
				S.queued[pkey] = nil
				if S.blocks[pane] then
					read_prompt(cx, pane)
				end
			end)
		end
	end
end

-- The live branch (or detached short sha) of `cwd`, read in the background when missing or old.
local function repo_of(cx: WindowCx, cwd: string): (string?, string?)
	local r = S.repos[cwd]
	if (r == nil or os.time() - r.at >= K.REPO_TTL) and not (r and r.pending) then
		local entry: Repo = r or { at = 0 }
		entry.pending = true
		S.repos[cwd] = entry
		local ok, req = pcall(function()
			return cx.git:repo(cwd)
		end)
		if ok then
			req:next(function(repo, _err, _gcx)
				entry.pending = nil
				entry.at = os.time()
				entry.branch = if repo then clean(repo.branch) else nil
				entry.head = if repo then clean(repo.head) else nil
			end)
		else
			entry.pending = nil
			entry.at = os.time()
		end
	end
	if r == nil then
		return nil, nil
	end
	if r.branch then
		return r.branch, nil
	end
	return nil, if r.head then string.sub(r.head :: string, 1, 7) else nil
end

-- Snapshot --------------------------------------------------------------------------

-- What the sidebar shows of a pane's chords: keycaps of its shortest effective chord.
local CAPS: { [string]: string } = if MACOS
	then { cmd = "⌘", alt = "⌥", shift = "⇧", ctrl = "⌃", up = "↑", down = "↓", left = "←", right = "→", backspace = "⌫", enter = "↵", escape = "⎋", tab = "⇥" }
	else { cmd = "Super", alt = "Alt", shift = "Shift", ctrl = "Ctrl", up = "↑", down = "↓", left = "←", right = "→", backspace = "Backspace", enter = "Enter", escape = "Esc", tab = "Tab" }

local function keycaps(chord: string): { string }
	local stroke = string.match(chord, "^[^>]+") or chord
	local mods: { [string]: boolean } = {}
	local key = ""
	for part in string.gmatch(stroke, "[^+]+") do
		if part == "cmd" or part == "alt" or part == "shift" or part == "ctrl" then
			mods[part] = true
		else
			key = part
		end
	end
	local out: { string } = {}
	for _, m in { "ctrl", "alt", "shift", "cmd" } do
		if mods[m] then
			table.insert(out, CAPS[m])
		end
	end
	table.insert(out, CAPS[key] or string.upper(key))
	return out
end

-- Each of our commands' shortest effective chord, by command id, from the effective keymap (Tern 0.9.16's
-- `actions:describe` doesn't know plugin commands). A chord counts when our command is its first action.
local function chords(cx: WindowCx): { [string]: string }
	local ok, keys = pcall(function()
		return cx.actions:keys()
	end)
	local out: { [string]: string } = {}
	if not ok then
		return out
	end
	local prefix = action_id("")
	for chord, ids in keys do
		local id = ids[1]
		if type(id) == "string" and string.sub(id, 1, #prefix) == prefix then
			local cmd = string.sub(id, #prefix + 1)
			local best = out[cmd]
			local _, n = string.gsub(chord, "[+>]", "")
			local _, bn = string.gsub(best or "", "[+>]", "")
			if best == nil or n < bn or (n == bn and chord < (best :: string)) then
				out[cmd] = chord
			end
		end
	end
	return out
end

local function caps_of(map: { [string]: string }, cmd: string): { string }?
	local c = map[cmd]
	return if c then keycaps(c) else nil
end

local function card_of(row: AgentRow): model.Card
	return {
		key = row.key,
		pane = row.pane,
		title = row.title,
		state = row.state,
		result = row.result,
		primary = row.primary,
		started = row.started,
		last_activity = row.last_activity,
		unread = S.ui.unread[row.key],
	}
end

local function snapshot(cx: WindowCx): any
	local current = cx.sessions:current()
	local names: { [string]: boolean } = {}
	for _, s in cx.sessions:list() do
		names[s.name] = true
	end
	local t = os.time()
	local rows: { [number]: AgentRow } = {}
	local panes: { number } = {}
	local waiting = 0
	for pane, b in S.blocks do
		local meta = S.meta_of(pane)
		local p = S.project_of(pane, b.cwd)
		if b.state == "waiting_input" then
			waiting += 1
		end
		local res = if b.state ~= "working" then S.results[pane] else nil
		local branch, detached = nil, nil
		if b.cwd ~= "" then
			branch, detached = repo_of(cx, b.cwd)
		end
		local key = tostring(pane)
		rows[pane] = {
			pane = pane,
			key = key,
			title = S.title_of(pane, b.cwd),
			state = b.state,
			result = if res then res.result else nil,
			done_at = if res then res.at else nil,
			started = if meta and meta.started > 0 then meta.started else nil,
			last_activity = S.last_activity[pane] or (if meta and meta.started > 0 then meta.started else nil),
			model = b.model,
			last_message = b.last_message,
			prompt = S.prompts[pane] or (if meta and meta.task then short(firstline(meta.task :: string), 200) else nil),
			tool = if b.state == "working" then S.tools[pane] else nil,
			cwd = b.cwd,
			branch = branch or (if detached == nil and meta then meta.branch else nil),
			detached = detached,
			primary = p ~= nil and b.cwd ~= "" and model.inside(b.cwd, p.root),
			project = if p then p.id else nil,
			pinned = S.ui.pinned[key],
			deleting = S.deleting[key],
			spawned = {},
			internal = S.internal[pane] or {},
		}
		table.insert(panes, pane)
	end
	-- Closed agents that still own a worktree: sleeping cards.
	for key, meta in S.state.agents do
		local n = tonumber(key)
		if meta.closed and meta.worktree and meta.parent == nil and n and S.blocks[n] == nil then
			local pane = -n
			local wt = meta.worktree :: string
			local branch, detached = repo_of(cx, wt)
			local sp = S.project_of(pane, wt)
			rows[pane] = {
				pane = pane,
				key = key,
				title = meta.title,
				state = "sleeping",
				result = if meta.interrupted or S.interrupted[key] then "interrupted" else nil,
				started = if meta.started > 0 then meta.started else nil,
				last_activity = meta.closed_at or (if meta.started > 0 then meta.started else nil),
				prompt = if meta.task then short(firstline(meta.task :: string), 200) else nil,
				cwd = wt,
				branch = branch or (if detached == nil then meta.branch else nil),
				detached = detached,
				pinned = S.ui.pinned[key],
				deleting = S.deleting[key],
				spawned = {},
				internal = {},
				project = if sp then sp.id else nil,
			}
			table.insert(panes, pane)
		end
	end
	table.sort(panes)
	-- Spawned subagents nest under their live parent; everything else is a card.
	local cards: { AgentRow } = {}
	for _, pane in panes do
		local row = rows[pane]
		local meta = S.meta_of(pane)
		local parent = if pane > 0 and meta and meta.parent then rows[meta.parent] else nil
		if parent then
			table.insert(parent.spawned, row)
		else
			table.insert(cards, row)
		end
	end
	local card_by: { [AgentRow]: model.Card } = {}
	for _, row in cards do
		card_by[row] = card_of(row)
	end
	local read = function(row: AgentRow): model.Card
		return card_by[row]
	end
	local pinned, rest = model.arrange(cards, S.ui, t, read)
	local by_project: { [string]: { AgentRow } } = {}
	local unassigned: { AgentRow } = {}
	local activity: { [string]: number } = {}
	for _, row in cards do
		local p = S.project_of(row.pane, row.cwd)
		local a = row.last_activity or row.started
		if p and a and a > (activity[p.id] or -1) then
			activity[p.id] = a
		end
	end
	local grouped = S.ui.group_by ~= "none"
	for _, row in rest do
		local p = S.project_of(row.pane, row.cwd)
		if p and grouped then
			local list = by_project[p.id] or {}
			table.insert(list, row)
			by_project[p.id] = list
		else
			table.insert(unassigned, row)
		end
	end
	local groups: { { id: string, name: string } } = {}
	local group_of: { [string]: { id: string, name: string } } = {}
	if grouped then
		for _, g in S.state.groups do
			local entry = { id = g.id, name = g.name }
			table.insert(groups, entry)
			group_of[g.id] = entry
		end
	end
	local projects = {}
	local order: { number } = {}
	if not S.ui.collapsed.pinned then
		for _, row in pinned do
			table.insert(order, row.pane)
		end
	end
	for _, p in model.order_projects(S.state, S.ui.project_order, activity) do
		local agents = by_project[p.id] or {}
		local g = if p.group then group_of[p.group :: string] else nil
		table.insert(projects, {
			project = p,
			session_exists = names[p.name] == true,
			current = current.name == p.name,
			agents = agents,
			group = g,
		})
		if not S.ui.collapsed[p.id] and not (g and S.ui.collapsed["group:" .. g.id]) then
			for _, row in agents do
				table.insert(order, row.pane)
			end
		end
	end
	for _, row in unassigned do
		table.insert(order, row.pane)
	end
	S.rendered = order
	local unread_panes: { [number]: boolean } = {}
	for _, row in rows do
		if S.ui.unread[row.key] then
			unread_panes[row.pane] = true
		end
	end
	return {
		projects = projects,
		groups = if grouped then groups else nil,
		pinned = pinned,
		unassigned = unassigned,
		collapsed = S.ui.collapsed,
		active = S.main_pane(cx, S.side_pane),
		unread = unread_panes,
		now = t,
		body = S.ui.body,
		group_by = S.ui.group_by,
		show_branch = S.ui.show_branch,
		show_agents = S.ui.show_agents,
		show_models = S.ui.show_models,
		expanded = S.expanded,
		idle_open = S.idle_open,
		reveal = if S.reveal_pane and tern.now() < S.reveal_until then S.reveal_pane else nil,
		filters = model.filter_count(S.ui),
		keys = (function()
			local map = chords(cx)
			return {
				search = caps_of(map, "search"),
				new_agent = caps_of(map, "new_agent"),
				collapse_all = caps_of(map, "collapse_all"),
			}
		end)(),
		waiting = waiting,
	}
end

local function draw(cx: WindowCx): (Node, Node)
	local out = sidebar.build(snapshot(cx))
	return out.view, out.dock
end

local function refresh_side(cx: WindowCx)
	local side = S.find_side(cx)
	if side == nil or S.parked(cx, side) then
		return
	end
	local view, dock = draw(cx)
	cx.canvas:set(side, { view = view, dock = dock })
end

-- A pending coalesced redraw.
local refresh_pending = false

-- Redraws soon, coalesced, in a callback of its own.
local function redraw_soon()
	if S.side_pane == nil or refresh_pending then
		return
	end
	refresh_pending = true
	tern.timer(150, function(tcx)
		refresh_pending = false
		if tcx then
			refresh_side(tcx)
		end
	end)
end

-- Refreshes everything event-driven: a scan now (unless the caller just did one), reads queued, a redraw soon.
local function changed(cx: WindowCx, scanned: boolean?)
	if not scanned then
		S.scan(cx)
	end
	queue_reads()
	redraw_soon()
end

-- Reveal ---------------------------------------------------------------------------

-- The generation of the reveal glow's timer.
local reveal_gen = 0
-- Expands the groups holding `pane`'s card and lets it glow for K.REVEAL_MS (Orca's reveal; Tern can't scroll a
-- canvas, so a card below the fold stays there).
local function reveal(cx: WindowCx, pane: number)
	local card = S.card_pane(pane)
	S.ui = model.load_ui()
	local keys: { string } = {}
	if S.ui.pinned[key_of(card)] then
		table.insert(keys, "pinned")
	else
		local p = S.project_of(card, S.cwd_of(card))
		if p then
			table.insert(keys, p.id)
			if p.group then
				table.insert(keys, "group:" .. p.group)
			end
		end
	end
	local opened = false
	for _, k in keys do
		if S.ui.collapsed[k] then
			S.ui.collapsed[k] = nil
			opened = true
		end
	end
	if opened then
		S.save_ui()
	end
	reveal_gen += 1
	local gen = reveal_gen
	S.reveal_pane = card
	S.reveal_until = tern.now() + K.REVEAL_MS
	refresh_side(cx)
	tern.timer(K.REVEAL_MS, function(tcx)
		if gen == reveal_gen then
			S.reveal_pane = nil
			if tcx then
				refresh_side(tcx)
			end
		end
	end)
end

-- Installs this module's functions into the context.
return function(ctx: core.Ctx)
	S = ctx
	S.changed = changed
	S.chords = chords
	S.draw = draw
	S.keycaps = keycaps
	S.queue_reads = queue_reads
	S.redraw_soon = redraw_soon
	S.refresh_side = refresh_side
	S.reveal = reveal
	S.snapshot = snapshot
end
