--!strict
-- projects, sidebar contents: the background surface and transcript reads, live git branches, keycaps of our
-- chords, the snapshot sidebar.luau draws, redraws (now, coalesced, after a change) and the reveal glow.

local model = require("./model")
local subagents = require("./subagents")
local sidebar = require("./sidebar")
local core = require("./core")
local budget = require("./budget")
local K = core.K
local MACOS = core.MACOS
local action_id = core.action_id
local blank = core.blank
local clean = core.clean
local firstline = core.firstline
local key_of = core.key_of
local short = core.short

type AgentRow = core.AgentRow

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
	local tool = subagents.tool(tree)
	local sig = { tool or "" }
	for _, s in live do
		table.insert(sig, string.format("%s|%s|%s|%s|%s", s.id, s.status, s.task or "", tostring(s.tools), tostring(s.cost)))
	end
	local joined = table.concat(sig, "\n")
	if S.surface_sig[pane] ~= joined then
		S.surface_sig[pane] = joined
		S.dirty = true
	end
	S.internal[pane] = live
	S.tools[pane] = tool
end

-- Reads one agent's latest user prompt from its omp transcript (the last few messages only).
local function read_prompt(cx: WindowCx, pane: number)
	local ok, msgs = pcall(function()
		return cx.agents:transcript(pane, { last = K.TRANSCRIPT_LAST })
	end)
	S.prompt_stale[pane] = false
	if not ok then
		return
	end
	for i = #msgs, 1, -1 do
		local m = msgs[i]
		if m.role == "user" and not blank(m.text) then
			local p = short(firstline(m.text), 200) :: string
			if S.prompts[pane] ~= p then
				S.prompts[pane] = p
				S.dirty = true
			end
			return
		end
	end
end

-- Re-reads, at most once per pane, the surfaces of working agents every WORK_READ_MS (the rest every
-- IDLE_READ_MS) and stale prompts, one read per timer turn.
local function queue_reads()
	local t = tern.now()
	for pane, b in S.blocks do
		local every = if b.state == "working" then K.WORK_READ_MS else K.IDLE_READ_MS
		local due = S.internal_at[pane] == nil or t - (S.internal_at[pane] :: number) >= every
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

-- The branch (or detached short sha) of `cwd`, from the host half's status file (git runs there).
local function repo_of(cwd: string): (string?, string?)
	local r = S.host_repos[cwd]
	if type(r) ~= "table" then
		return nil, nil
	end
	if type(r.branch) == "string" then
		return r.branch, nil
	end
	return nil, if type(r.head) == "string" then string.sub(r.head, 1, 7) else nil
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
-- Cached: the keymap is read at most every CHORDS_MS (the read lists every chord Tern knows).
local CHORDS_MS = 30000
local chords_cache: { [string]: string }? = nil
local chords_at = -math.huge
local function chords(cx: WindowCx): { [string]: string }
	if chords_cache and tern.now() - chords_at < CHORDS_MS then
		return chords_cache :: { [string]: string }
	end
	chords_at = tern.now()
	local ok, keys = pcall(function()
		return cx.actions:keys()
	end)
	local out: { [string]: string } = {}
	chords_cache = out
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
			branch, detached = repo_of(b.cwd)
		end
		local key = key_of(pane)
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
		if meta.closed and meta.worktree and meta.parent == nil and S.pane_of(key) == nil then
			local pane = S.card_of_key(key)
			local wt = meta.worktree :: string
			local branch, detached = repo_of(wt)
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
	-- Each card's PR (prs.luau, from the host's gh.json), by the folder and branch it shows.
	for _, row in rows do
		if row.cwd ~= "" and row.branch then
			row.pr, row.pr_stale = S.pr_for(row.cwd, row.branch)
		end
	end
	table.sort(panes)
	-- Spawned subagents nest under their live parent; everything else is a card.
	local cards: { AgentRow } = {}
	for _, pane in panes do
		local row = rows[pane]
		local meta = S.meta_of(pane)
		local up = if pane > 0 and meta then S.pane_of(meta.parent) else nil
		local parent = if up then rows[up] else nil
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
			host = model.host_short(p.host),
			gh = S.gh_project(p),
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
		autos = S.auto_snap(),
	}
end

local function draw(cx: WindowCx): (Node, Node)
	local out = sidebar.build(snapshot(cx))
	return out.view, out.dock
end

-- What the sidebar canvas shows now: its pane, the key order of the view's top level and of its list, and the
-- JSON of each top-level part, list section and the dock, so a redraw sends only what changed.
type Drawn = { pane: number, order: string, parts: { [string]: string }, dock: string }
local drawn: Drawn? = nil

local function kids(node: any): { any }
	return if type(node) == "table" and type(node.c) == "table" then node.c else {}
end
local function key_of_node(node: any): string?
	return if type(node) == "table" and type(node.p) == "table" and type(node.p.key) == "string" then node.p.key else nil
end

-- Splits the view into its parts, by the path `canvas:set{set = …}` takes (keys below the root, dot-joined; checked
-- on Tern 0.9.28): the top-level children other than the list, and each child of the list (`list.<key>`).
local function parts_of(view: any): (string?, { [string]: any })
	local order: { string } = {}
	local parts: { [string]: any } = {}
	for _, top in kids(view) do
		local k = key_of_node(top)
		if k == nil then
			return nil, parts
		end
		if k == "list" then
			table.insert(order, "list[" .. ((top.p and top.p.class) or "") .. "]")
			for _, sec in kids(top) do
				local sk = key_of_node(sec)
				local id = "list." .. (sk or "")
				if sk == nil or parts[id] then
					return nil, parts
				end
				table.insert(order, id)
				parts[id] = sec
			end
			table.insert(order, "/list")
		else
			local id = k
			table.insert(order, id)
			parts[id] = top
		end
	end
	return table.concat(order, ","), parts
end

-- Draws the sidebar: a full `canvas:set` when its shape changed (another pane, sections added, removed or
-- reordered), else only the changed sections (`set` by key), else nothing.
local function refresh_side(cx: WindowCx)
	local side = S.find_side(cx)
	if side == nil or S.parked(cx, side) then
		return
	end
	S.dirty = false
	S.drawn_at = tern.now()
	local view, dock = draw(cx)
	local order, nodes = parts_of(view)
	local json: { [string]: string } = {}
	for k, n in nodes do
		json[k] = tern.json.encode(n)
	end
	local dock_json = tern.json.encode(dock)
	local d = drawn
	if order == nil or d == nil or d.pane ~= side or d.order ~= order then
		cx.canvas:set(side, { view = view, dock = dock })
		drawn = if order then { pane = side, order = order :: string, parts = json, dock = dock_json } else nil
		return
	end
	local change: { [string]: any } = {}
	local any = false
	for k, j in json do
		if d.parts[k] ~= j then
			change[k] = nodes[k]
			any = true
		end
	end
	local spec: CanvasChange = {}
	if any then
		spec.set = change
	end
	if d.dock ~= dock_json then
		spec.dock = dock
		any = true
	end
	if any then
		local ok, err = pcall(function()
			cx.canvas:set(side, spec)
		end)
		if ok then
			d.parts, d.dock = json, dock_json
		else
			-- The canvas no longer holds what we drew (replaced elsewhere): send it whole.
			tern.log.warn("projects: partial sidebar update refused, redrawing whole", err)
			cx.canvas:set(side, { view = view, dock = dock })
			drawn = { pane = side, order = order :: string, parts = json, dock = dock_json }
		end
	end
end

-- A pending coalesced redraw.
local refresh_pending = false

-- Redraws soon, coalesced, in a callback of its own.
local function redraw_soon()
	if S.side_pane == nil or refresh_pending then
		return
	end
	refresh_pending = true
	budget.later("draw", 150, function(tcx)
		refresh_pending = false
		refresh_side(tcx)
	end)
end

-- Refreshes everything event-driven, never in the caller's callback: a scan, reads queued, then a redraw.
local scan_pending = false
local function changed(_cx: WindowCx?, _scanned: boolean?)
	S.dirty = true
	if scan_pending then
		return
	end
	scan_pending = true
	budget.later("scan", 0, function(scx)
		scan_pending = false
		if S.scan_list(scx) then
			budget.later("bind", 0, function(_bcx)
				S.scan_rest()
				queue_reads()
				redraw_soon()
			end)
		end
	end)
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
