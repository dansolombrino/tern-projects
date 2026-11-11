--!strict
-- projects, window half: projects (one named Tern session each), omp agents per
-- project (each in a git worktree of its own when the project allows), spawned
-- and omp-internal subagents per agent, an Orca-style left sidebar (a canvas
-- docked at the left of the current tab, shown and hidden from the title bar),
-- a status segment and toasts. Everything lives here; model.luau holds the data,
-- subagents.luau and sidebar.luau the pure surface reading and drawing.

local model = require("./model")
local subagents = require("./subagents")
local sidebar = require("./sidebar")

local ID = tern.plugin.id
local HOME = tern.getenv("HOME")
local MACOS = tern.runtime.os == "macos"
local SIDE_TITLE = "Projects"
local TOGGLE = "plugin." .. ID .. ".toggle_sidebar"
local MOD = if MACOS then "cmd+alt+shift+" else "ctrl+alt+shift+"
-- Orca's sidebar shortcut (Mod+B), bound only on request: Tern's presets use it.
local ORCA_CHORD = if MACOS then "cmd+b" else "ctrl+b"
-- Orca's default sidebar width and its drag limits, in pixels.
local SIDE_PX, MIN_PX, MAX_PX = 280, 220, 500
-- Sidebar refresh period while it shows, and how often idle agents' surfaces are re-read.
local TICK_MS = 2000
local IDLE_READ_MS = 10000
-- Surface nodes read per agent for its omp-internal subagents.
local SURFACE_NODES = 2000
-- Longest last message a report-back carries.
local REPORT_CHARS = 6000

type AgentBlock = {
	pane: number,
	cwd: string,
	state: string,
	model: string?,
	last_message: string?,
}

type AgentRow = {
	pane: number,
	title: string,
	state: string,
	model: string?,
	last_message: string?,
	cwd: string,
	branch: string?,
	primary: boolean?,
	started: number?,
	spawned: { AgentRow },
	internal: { subagents.Subagent },
}

type Counts = { working: number, waiting: number }

-- In-memory caches. `state` and `ui` are re-read from kv before every change (other windows share them).
local state: model.State = model.load()
local ui: model.Ui = model.load_ui()
-- Agent blocks by pane, from the last `cx.agents:list()`.
local blocks: { [number]: AgentBlock } = {}
-- omp-internal subagents by parent pane, and when each was last read (tern.now()).
local internal: { [number]: { subagents.Subagent } } = {}
local internal_at: { [number]: number } = {}
-- Status-line inputs: agent counts per project id and each agent pane's project id.
local counts: { [string]: Counts } = {}
local pane_project: { [number]: string } = {}
-- Agents that finished or asked for input while not focused, until focused.
local unread: { [number]: boolean } = {}
-- The last focused pane other than the sidebar.
local last_main: number? = nil
-- The sidebar canvas, the generation of its refresh timer and a pending coalesced redraw.
local side_pane: number? = nil
local side_gen = 0
local refresh_pending = false
-- The sidebar's split width in cells at the last settled fit: the share a fresh fit starts from.
local fit_total: number? = nil
-- The last answer each spawned subagent reported, and reports waiting for their busy parent.
local reported: { [number]: string } = {}
local pending: { [number]: { string } } = {}

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
	return string.sub(s, 1, n) .. "…"
end

local function meta_of(pane: number): model.AgentMeta?
	return state.agents[tostring(pane)]
end

local function project_of(pane: number, cwd: string?): model.Project?
	local meta = meta_of(pane)
	if meta then
		local p = model.get(state, meta.project)
		if p then
			return p
		end
	end
	return model.project_for_path(state, cwd)
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

-- Reads every agent block and recomputes the status-line inputs.
local function scan(cx: WindowCx)
	state = model.load()
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
	blocks = fresh
	local new_counts: { [string]: Counts } = {}
	local new_panes: { [number]: string } = {}
	for pane, b in blocks do
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
	for pane in internal do
		if blocks[pane] == nil then
			internal[pane] = nil
			internal_at[pane] = nil
		end
	end
	-- Intra-tab clicks send no `focus` event: the focused agent counts as read here too.
	for pane in unread do
		if blocks[pane] == nil then
			unread[pane] = nil
		end
	end
	local focused = cx.session:focused()
	if focused then
		unread[focused] = nil
	end
	counts, pane_project = new_counts, new_panes
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

local function git(args: { string }, cb: (res: ProcessResult, cx: WindowCx?) -> ())
	local argv = { "git" }
	for _, a in args do
		table.insert(argv, a)
	end
	tern.process.run(argv, { timeout_ms = 30000 }, cb)
end

local function trimmed(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
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

-- Shows and focuses `pane`, switching session when another one holds it.
local function goto_pane(cx: WindowCx, pane: number)
	local s = session_of(cx, pane)
	if s and not s.current then
		cx.sessions:switch(s.id)
	end
	cx.layout:focus(pane)
	last_main = pane
	unread[pane] = nil
end

local function session_named(cx: WindowCx, name: string): ManagedSession?
	for _, s in cx.sessions:list() do
		if s.name == name then
			return s
		end
	end
	return nil
end

-- Shows the project's session, creating it at the root when missing; true when created.
local function ensure_session(cx: WindowCx, project: model.Project): boolean
	local s = session_named(cx, project.name)
	if s then
		if not s.current then
			cx.sessions:switch(s.id)
		end
		return false
	end
	cx.sessions:create({ name = project.name, cwd = project.root })
	return true
end

-- Sidebar ----------------------------------------------------------------------

local function find_side(cx: WindowCx): number?
	-- A canvas just opened can be missing from the canvas replica for a moment; its pane is already there.
	if side_pane and (cx.canvas:get(side_pane) or cx.session:pane(side_pane)) then
		return side_pane
	end
	side_pane = nil
	for _, c in cx.canvas:list() do
		if c.owner == ID and c.title == SIDE_TITLE then
			side_pane = c.pane
			return c.pane
		end
	end
	return nil
end

local function parked(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	return info ~= nil and info.parked == true
end

-- The sidebar when it shows in the current tab.
local function shown_side(cx: WindowCx): number?
	local side = find_side(cx)
	if side == nil or parked(cx, side) then
		return nil
	end
	local focused = cx.session:focused()
	local here = if focused then cx.session:tab_of(focused) else nil
	if here ~= nil and cx.session:tab_of(side) ~= here then
		return nil
	end
	return side
end

-- The first leaf of `tree` other than `except`, left (and top) first.
local function leftmost(tree: TabTree?, except: number?): number?
	if tree == nil then
		return nil
	end
	if tree.pane then
		return if tree.pane == except then nil else tree.pane
	end
	return leftmost(tree[1], except) or leftmost(tree[2], except)
end

-- The split holding leaf `pane` and which side of it the leaf is.
local function split_of(tree: TabTree?, pane: number): (TabTree?, number?)
	if tree == nil or tree.pane then
		return nil, nil
	end
	for i = 1, 2 do
		local child = tree[i]
		if child and child.pane == pane then
			return tree, i
		end
		local s, side = split_of(child, pane)
		if s then
			return s, side
		end
	end
	return nil, nil
end

local function tab_root(cx: WindowCx, tab: number?): TabTree?
	if tab == nil then
		return nil
	end
	local layout = cx.session:layout(tab)
	return if layout then layout.root else nil
end

-- The sidebar's share of its split (nil unless it is the left side of a left/right split).
local function side_ratio(cx: WindowCx, side: number): number?
	local split, i = split_of(tab_root(cx, cx.session:tab_of(side)), side)
	if split == nil or split.split ~= "right" or i ~= 1 then
		return nil
	end
	return split.ratio or 0.5
end

-- The pane the user works in: the focused one, else the last one focused, never the sidebar.
local function main_pane(cx: WindowCx, side: number?): number?
	local focused = cx.session:focused()
	if focused and focused ~= side then
		return focused
	end
	if last_main and cx.session:pane(last_main) then
		return last_main
	end
	if side then
		return leftmost(tab_root(cx, cx.session:tab_of(side)), side)
	end
	return nil
end

local function default_cols(cx: WindowCx): number
	local ok, size = pcall(function()
		return cx.settings:get("terminal.font_size")
	end)
	return model.cols_for_px(SIDE_PX, if ok and type(size) == "number" then size else 13)
end

local function clamp_cols(cx: WindowCx, cols: number): number
	local ok, size = pcall(function()
		return cx.settings:get("terminal.font_size")
	end)
	local fs = if ok and type(size) == "number" then size else 13
	return math.clamp(cols, model.cols_for_px(MIN_PX, fs), model.cols_for_px(MAX_PX, fs))
end

-- The layout's width of the sidebar's split in cells, measured by growing the sidebar a few cells and
-- reading its share change; with the share after the probe and before it.
local function measure(cx: WindowCx, side: number): (number?, number?, number?)
	local r = side_ratio(cx, side)
	if r == nil then
		return nil, nil, nil
	end
	local probe = if r < 0.5 then 4 else -4
	if not cx.layout:resize(side, "right", probe) then
		return nil, nil, nil
	end
	local r2 = side_ratio(cx, side) :: number
	if math.abs(r2 - r) < 1e-4 then
		return nil, nil, nil
	end
	return r2, probe / (r2 - r), r
end

-- Brings the sidebar's share from `r` to `target` in a split `total` cells wide. Resizes take fractions of
-- a cell, so a split the layout still thinks narrow (just unparked or moved) gets the share exactly too.
local function resize_to(cx: WindowCx, side: number, r: number, total: number, target: number)
	for _ = 1, 2 do
		local d = (target - r) * total
		if math.abs(d) < 0.25 or not cx.layout:resize(side, "right", d) then
			break
		end
		r = side_ratio(cx, side) or r
	end
end

-- Sizes the sidebar to the remembered width in cells. A pane that just opened, unparked or moved still has
-- its old size in the layout, so this sets the share the last settled fit found right for the width, and
-- `fit_settled` corrects it once the layout has the real size.
local function fit(cx: WindowCx, side: number)
	local r, total = measure(cx, side)
	if r == nil or total == nil then
		return
	end
	local want = ui.want_cols or default_cols(cx)
	local target = if fit_total then want / (fit_total :: number) else 0.2
	resize_to(cx, side, r, total, math.clamp(target, 0.05, 0.6))
end

local function fit_settled(cx: WindowCx, side: number)
	local r, total = measure(cx, side)
	if r == nil or total == nil then
		return
	end
	local want = ui.want_cols or default_cols(cx)
	resize_to(cx, side, r, total, want / total)
	fit_total = total
end

-- Runs `fit_settled` after the next layout pass.
local function fit_later(side: number)
	tern.timer(80, function(tcx)
		if tcx and side == side_pane and not parked(tcx, side) then
			fit_settled(tcx, side)
		end
	end)
end

-- Keeps a width the user dragged the sidebar to (any width off the fitted one by more than a cell and a half),
-- once a fit has settled (an unsettled width is the layout's, not the user's). Undoes the measuring probe.
local function remember_width(cx: WindowCx, side: number)
	if fit_total == nil then
		return
	end
	local r2, total, r = measure(cx, side)
	if r2 == nil or total == nil or r == nil then
		return
	end
	resize_to(cx, side, r2, total, r)
	local cols = r * total
	ui = model.load_ui()
	if math.abs(cols - (ui.want_cols or default_cols(cx))) <= 1.5 then
		return
	end
	ui.want_cols = clamp_cols(cx, math.floor(cols + 0.5))
	model.save_ui(ui)
end

-- Docks the sidebar at the left of the tab the user works in, then fits its width; false when Tern refused to
-- unpark or move it (the caller then closes it and opens a new one).
local function place(cx: WindowCx, side: number): boolean
	local main = main_pane(cx, side)
	local tab = if main then cx.session:tab_of(main) else nil
	local moved = false
	if parked(cx, side) then
		local ok, err = cx.layout:unpark(side, { focus = false })
		if not ok then
			tern.log.warn("projects: unpark failed", err)
			return false
		end
		moved = true
	else
		remember_width(cx, side)
	end
	if tab and cx.session:tab_of(side) ~= tab then
		local ok, err = cx.layout:move_to_tab(side, tab, { focus = false })
		if not ok then
			tern.log.warn("projects: move to tab failed", err)
			return false
		end
		moved = true
	end
	local root = tab_root(cx, cx.session:tab_of(side))
	if root and not (root.split == "right" and root[1] and root[1].pane == side) then
		local leaf = leftmost(root, side)
		if leaf then
			cx.layout:move(side, leaf, "left", { focus = false })
			moved = true
		end
	end
	if moved then
		fit(cx, side)
		fit_later(side)
	end
	return true
end

-- Re-reads the omp-internal subagents of working agents (and of the rest every IDLE_READ_MS).
local function read_internal(cx: WindowCx)
	local t = tern.now()
	for pane, b in blocks do
		local due = b.state == "working" or internal_at[pane] == nil or t - (internal_at[pane] :: number) >= IDLE_READ_MS
		if due and b.state ~= "exited" then
			internal_at[pane] = t
			local ok, tree = pcall(function()
				return cx.session:surface(pane, { as = "table", nodes = SURFACE_NODES })
			end)
			if ok then
				local got, list = pcall(subagents.extract, tree)
				internal[pane] = if got then list else {}
				if not got then
					tern.log.warn("projects: subagents.extract failed", list)
				end
			end
		end
	end
end

local function snapshot(cx: WindowCx): any
	local current = cx.sessions:current()
	local names: { [string]: boolean } = {}
	for _, s in cx.sessions:list() do
		names[s.name] = true
	end
	local panes: { number } = {}
	for pane in blocks do
		table.insert(panes, pane)
	end
	table.sort(panes)
	local rows: { [number]: AgentRow } = {}
	local waiting = 0
	for _, pane in panes do
		local b = blocks[pane]
		local meta = meta_of(pane)
		local p = project_of(pane, b.cwd)
		if b.state == "waiting_input" then
			waiting += 1
		end
		rows[pane] = {
			pane = pane,
			title = title_of(pane, b.cwd),
			state = b.state,
			model = b.model,
			last_message = b.last_message,
			cwd = b.cwd,
			branch = if meta then meta.branch else nil,
			primary = p ~= nil and b.cwd ~= "" and model.inside(b.cwd, p.root),
			started = if meta and meta.started > 0 then meta.started else nil,
			spawned = {},
			internal = internal[pane] or {},
		}
	end
	local by_project: { [string]: { AgentRow } } = {}
	local unassigned: { AgentRow } = {}
	for _, pane in panes do
		local row = rows[pane]
		local meta = meta_of(pane)
		local parent = if meta and meta.parent then rows[meta.parent] else nil
		if parent then
			table.insert(parent.spawned, row)
		else
			local p = project_of(pane, row.cwd)
			if p then
				local list = by_project[p.id] or {}
				table.insert(list, row)
				by_project[p.id] = list
			else
				table.insert(unassigned, row)
			end
		end
	end
	local projects = {}
	for _, p in state.projects do
		table.insert(projects, {
			project = p,
			session_exists = names[p.name] == true,
			current = current.name == p.name,
			agents = by_project[p.id] or {},
		})
	end
	return {
		projects = projects,
		unassigned = unassigned,
		collapsed = ui.collapsed,
		active = main_pane(cx, side_pane),
		unread = unread,
		now = os.time(),
		waiting = waiting,
	}
end

local function draw(cx: WindowCx): (Node, Node)
	read_internal(cx)
	local out = sidebar.build(snapshot(cx))
	return out.view, out.dock
end

local function refresh_side(cx: WindowCx)
	local side = find_side(cx)
	if side == nil or parked(cx, side) then
		return
	end
	local view, dock = draw(cx)
	cx.canvas:set(side, { view = view, dock = dock })
end

-- Refreshes everything event-driven: a scan now (unless the caller just did one), a sidebar
-- redraw soon (coalesced).
local function changed(cx: WindowCx, scanned: boolean?)
	if not scanned then
		scan(cx)
	end
	if side_pane == nil or refresh_pending then
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

local function tick(gen: number)
	tern.timer(TICK_MS, function(cx)
		if gen ~= side_gen or cx == nil then
			return
		end
		local side = find_side(cx)
		if side == nil or parked(cx, side) then
			return
		end
		scan(cx)
		refresh_side(cx)
		tick(gen)
	end)
end

local function start_ticker()
	side_gen += 1
	tick(side_gen)
end

local function set_visible(visible: boolean)
	ui = model.load_ui()
	if ui.visible ~= visible then
		ui.visible = visible
		model.save_ui(ui)
	end
end

-- Shows the sidebar at the left of the current tab, leaving focus where it is.
local function show_side(cx: WindowCx)
	set_visible(true)
	scan(cx)
	local main = main_pane(cx, side_pane)
	local side = find_side(cx)
	if side and not place(cx, side) then
		cx.layout:close(side)
		side_pane, side = nil, nil
	end
	if side then
		refresh_side(cx)
	else
		local view, dock = draw(cx)
		local spec: CanvasSpec = { title = SIDE_TITLE, about = sidebar.ABOUT, view = view, dock = dock, focus = false }
		local target = if main then leftmost(tab_root(cx, cx.session:tab_of(main)), nil) else nil
		if target then
			spec.how = "beside"
			spec.target = target
			spec.dir = "left"
			spec.ratio = 0.2
		else
			spec.how = "tab"
		end
		local pane, err = cx.canvas:open(spec)
		if pane == nil then
			cx:toast("error", "Projects sidebar not opened", err)
			return
		end
		side_pane = pane
		fit(cx, pane)
		fit_later(pane)
	end
	if main and cx.session:focused() ~= main then
		cx.layout:focus(main)
	end
	start_ticker()
end

-- Hides the sidebar: parked, so it keeps its pane and comes back at once (closed if it can't park).
local function hide_side(cx: WindowCx)
	set_visible(false)
	local side = find_side(cx)
	if side == nil or parked(cx, side) then
		return
	end
	local main = main_pane(cx, side)
	remember_width(cx, side)
	local ok, err = cx.layout:park(side)
	if not ok then
		tern.log.warn("projects: park failed, closing the sidebar", err)
		cx.layout:close(side)
		side_pane = nil
	end
	side_gen += 1
	if main and cx.session:pane(main) and cx.session:focused() ~= main then
		cx.layout:focus(main)
	end
end

local function toggle_side(cx: WindowCx)
	if shown_side(cx) then
		hide_side(cx)
	else
		show_side(cx)
	end
end

-- Gives focus back to the pane the user works in after a click in the sidebar focused it.
local function refocus(cx: WindowCx, side: number)
	if cx.session:focused() ~= side then
		return
	end
	local main = last_main
	if main == nil or cx.session:pane(main) == nil or cx.session:tab_of(main) ~= cx.session:tab_of(side) then
		main = leftmost(tab_root(cx, cx.session:tab_of(side)), side)
	end
	if main then
		cx.layout:focus(main)
	end
end

-- Agents ---------------------------------------------------------------------

type Launch = {
	project: model.Project,
	task: string,
	cwd: string,
	worktree: string?,
	branch: string?,
	parent: number?,
}

-- Starts the agent and records it. Top-level agents open as a named, colored tab in the project's
-- session; subagents split beside their parent.
local function launch(cx: WindowCx, l: Launch): number?
	local how: "split" | "tab" | "replace_if_alone" = "tab"
	if l.parent then
		goto_pane(cx, l.parent)
		how = "split"
	elseif ensure_session(cx, l.project) then
		how = "replace_if_alone"
	end
	local ok, pane = pcall(function()
		return cx.agents:start({ prompt = l.task, cwd = l.cwd, how = how })
	end)
	if not ok then
		cx:toast("error", "Agent not started", tostring(pane))
		return nil
	end
	local title = model.title_of(l.task)
	state = model.load()
	state.agents[tostring(pane)] = {
		project = l.project.id,
		title = title,
		task = l.task,
		worktree = l.worktree,
		branch = l.branch,
		parent = l.parent,
		report_back = if l.parent then true else nil,
		started = os.time(),
	}
	model.save(state)
	if l.parent == nil then
		local tab = cx.session:tab_of(pane)
		if tab then
			cx.layout:name_tab(tab, title)
			cx.layout:color_tab(tab, l.project.color :: any)
		end
	end
	changed(cx)
	return pane
end

-- Creates a worktree on a fresh `agent/<slug>` branch, trying `-2`, `-3`, … when taken.
local function make_worktree(project: model.Project, base: string, n: number, done: (path: string?, branch: string?, err: string?, cx: WindowCx?) -> ())
	local slug = if n == 1 then base else base .. "-" .. n
	local path = model.worktree_path(project, slug)
	local branch = "agent/" .. slug
	if tern.fs.exists(path) then
		make_worktree(project, base, n + 1, done)
		return
	end
	git({ "-C", project.root, "worktree", "add", "-b", branch, path }, function(res, cx)
		if res.status == 0 then
			done(path, branch, nil, cx)
		elseif n < 20 and string.find(res.stderr, "already exists", 1, true) then
			make_worktree(project, base, n + 1, done)
		else
			done(nil, nil, trimmed(res.stderr ~= "" and res.stderr or res.stdout), cx)
		end
	end)
end

-- Asks for a line of text; `fn` runs with a fresh cx unless the user dismissed it or left it blank.
local function ask_text(cx: WindowCx, opts: PromptOptions, fn: (text: string, cx: WindowCx) -> ())
	cx:prompt(opts):next(function(text, _err, ncx)
		if ncx and text and not blank(text) then
			fn(trimmed(text :: string), ncx)
		end
	end)
end

-- Asks for one of `opts.items`; `fn` gets the chosen item unless the user dismissed the picker.
local function ask_pick(cx: WindowCx, opts: PickOptions, fn: (item: PickItem, cx: WindowCx) -> ())
	cx:pick(opts):next(function(item, _err, ncx)
		if ncx and item then
			fn(item :: PickItem, ncx)
		end
	end)
end

local function new_agent_in(cx: WindowCx, project: model.Project)
	ask_text(cx, { placeholder = "Task for a new agent in " .. project.name, icon = "sparkle", action = "start agent" }, function(task, pcx)
		if not project.worktrees then
			launch(pcx, { project = project, task = task, cwd = project.root })
			return
		end
		make_worktree(project, model.slug(model.title_of(task)), 1, function(path, branch, err, wcx)
			if wcx == nil then
				return
			end
			if path == nil then
				wcx:toast("error", "Worktree not created for " .. project.name, err)
				return
			end
			launch(wcx, { project = project, task = task, cwd = path, worktree = path, branch = branch })
		end)
	end)
end

local function pick_project(cx: WindowCx, placeholder: string, fn: (cx: WindowCx, project: model.Project) -> ())
	state = model.load()
	if #state.projects == 0 then
		cx:toast("info", "No projects yet", "Add one with Projects: Add project")
		return
	end
	local current = cx.sessions:current().name
	local items: { PickItem } = {}
	for _, p in state.projects do
		table.insert(items, { label = p.name, detail = tilde(p.root), icon = "folder", current = p.name == current, project = p.id })
	end
	ask_pick(cx, { items = items, placeholder = placeholder, icon = "folder" }, function(item, pcx)
		local p = model.get(model.load(), (item :: any).project)
		if p then
			fn(pcx, p)
		end
	end)
end

local function new_agent(cx: WindowCx)
	state = model.load()
	local pane, cwd = focused_cwd(cx)
	local p = if pane then project_of(pane, cwd) else nil
	if p then
		new_agent_in(cx, p)
	else
		pick_project(cx, "Project for the new agent", new_agent_in)
	end
end

local function new_subagent_of(cx: WindowCx, parent: number)
	scan(cx)
	local b = blocks[parent]
	if b == nil then
		cx:toast("error", "Not an agent", "Focus an agent block to start a subagent of it")
		return
	end
	local project = project_of(parent, b.cwd)
	if project == nil then
		cx:toast("error", "Agent is in no project", tilde(b.cwd))
		return
	end
	local pmeta = meta_of(parent)
	local ptitle = title_of(parent, b.cwd)
	ask_text(cx, { placeholder = "Task for a subagent of " .. ptitle, icon = "sparkle", action = "start subagent" }, function(task, pcx)
		launch(pcx, {
			project = project :: model.Project,
			task = task,
			cwd = b.cwd,
			branch = if pmeta then pmeta.branch else nil,
			parent = parent,
		})
	end)
end

-- The agent's answer to its latest prompt: the last assistant message after the last user message in
-- the omp transcript, without omp's `·` stats footer; nil while the turn has no answer yet.
local function answer_of(cx: WindowCx, pane: number): string?
	local ok, msgs = pcall(function()
		return cx.agents:transcript(pane, { last = 8 })
	end)
	if not ok then
		local b = blocks[pane]
		return if b then b.last_message else nil
	end
	for i = #msgs, 1, -1 do
		local m = msgs[i]
		if m.role == "user" then
			return nil
		end
		if m.role == "assistant" and not blank(m.text) then
			local text = string.gsub(m.text, "\n·\n[^\n]*%s*$", "")
			return text
		end
	end
	return nil
end

-- Sends the parent its oldest queued report unless it is busy (the rest wait for its next idle).
local function deliver(cx: WindowCx, parent: number)
	local queue = pending[parent]
	if queue == nil then
		return
	end
	local pb = blocks[parent]
	if pb == nil or pb.state == "exited" then
		pending[parent] = nil
		return
	end
	if pb.state == "working" then
		return
	end
	local text = table.remove(queue, 1) :: string
	if #queue == 0 then
		pending[parent] = nil
	end
	local ok, err = pcall(function()
		cx.agents:ask(parent, text)
	end)
	if not ok then
		local q = pending[parent] or {}
		table.insert(q, 1, text)
		pending[parent] = q
		cx:toast("error", "Report to " .. title_of(parent, pb.cwd) .. " not sent yet", tostring(err))
	end
end

-- Queues the spawned subagent's answer for its parent once its turn ended. The answer can trail the
-- event, so a turn without one is looked at again a few times.
local function report_back(cx: WindowCx, pane: number, result: string, tries: number)
	local meta = meta_of(pane)
	if meta == nil or meta.parent == nil or meta.report_back == false then
		return
	end
	local parent = meta.parent :: number
	local msg = answer_of(cx, pane)
	if msg == nil then
		if tries < 5 then
			tern.timer(1000, function(tcx)
				if tcx then
					scan(tcx)
					report_back(tcx, pane, result, tries + 1)
				end
			end)
		end
		return
	end
	if reported[pane] == msg then
		return
	end
	reported[pane] = msg
	local q = pending[parent] or {}
	table.insert(q, string.format("Subagent %s finished (%s):\n\n%s", meta.title, result, short(msg, REPORT_CHARS) or ""))
	pending[parent] = q
	deliver(cx, parent)
end

-- Commands -------------------------------------------------------------------

local function add_project(cx: WindowCx)
	local _, cwd = focused_cwd(cx)
	local base = cwd or HOME or "/"
	local function ask_root(acx: WindowCx, default: string)
		ask_text(acx, { value = tilde(default), placeholder = "Project root folder", icon = "folder", action = "next" }, function(text, rcx)
			local root = model.resolve(base, text, HOME)
			if not tern.fs.exists(root) then
				rcx:toast("error", "No such folder", tilde(root))
				return
			end
			-- A project with worktrees must be a repository's top folder.
			git({ "-C", root, "rev-parse", "--show-prefix" }, function(res, gcx)
				if gcx == nil then
					return
				end
				local is_top = res.status == 0 and trimmed(res.stdout) == ""
				ask_text(gcx, { value = model.basename(root), placeholder = "Project name (its session's name)", icon = "folder", action = "add project" }, function(name, ncx)
					state = model.load()
					local ok, p = pcall(model.add_project, state, { name = name, root = root, worktrees = is_top })
					if not ok then
						ncx:toast("error", "Project not added", tostring(p))
						return
					end
					model.save(state)
					local project = p :: model.Project
					ncx:toast("success", "Added " .. project.name, tilde(project.root) .. (if project.worktrees then " · agents get worktrees" else " · no worktrees (not a repository root)"))
					changed(ncx)
				end)
			end)
		end)
	end
	if cwd == nil then
		ask_root(cx, base)
		return
	end
	-- Default: the git root above the focused pane's folder, kept logical (no symlinks resolved).
	git({ "-C", cwd, "rev-parse", "--show-cdup" }, function(res, gcx)
		if gcx == nil then
			return
		end
		if res.status == 0 then
			ask_root(gcx, model.resolve(cwd, trimmed(res.stdout)))
		else
			ask_root(gcx, cwd)
		end
	end)
end

local function open_project(cx: WindowCx, p: model.Project)
	local created = ensure_session(cx, p)
	if created then
		cx:toast("info", "Opened " .. p.name, tilde(p.root))
	end
	changed(cx)
end

local function next_waiting(cx: WindowCx)
	scan(cx)
	local waiting: { number } = {}
	for pane, b in blocks do
		if b.state == "waiting_input" then
			table.insert(waiting, pane)
		end
	end
	if #waiting == 0 then
		cx:toast("info", "No agent is waiting for input")
		return
	end
	table.sort(waiting)
	local cur = cx.session:focused() or 0
	local target = waiting[1]
	for _, pane in waiting do
		if pane > cur then
			target = pane
			break
		end
	end
	goto_pane(cx, target)
end

local function remove_worktree(cx: WindowCx, key: string, meta: model.AgentMeta, force: boolean)
	local project = model.get(state, meta.project)
	local wt = meta.worktree :: string
	local root = if project then project.root else wt
	local args = { "-C", root, "worktree", "remove" }
	if force then
		table.insert(args, "--force")
	end
	table.insert(args, wt)
	git(args, function(res, gcx)
		if gcx == nil then
			return
		end
		if res.status ~= 0 then
			gcx:toast("error", "Worktree not removed", trimmed(res.stderr))
			return
		end
		state = model.load()
		local m = state.agents[key]
		if m then
			if m.closed then
				state.agents[key] = nil
			else
				m.worktree = nil
			end
			model.save(state)
		end
		gcx:toast("success", "Removed worktree " .. model.basename(wt), if meta.branch then "Branch " .. meta.branch .. " is kept" else nil)
		changed(gcx)
	end)
end

-- Whether an agent that hasn't exited works inside `dir` (a subagent shares its parent's worktree).
local function in_use(dir: string): boolean
	for _, b in blocks do
		if b.state ~= "exited" and b.cwd ~= "" and model.inside(b.cwd, dir) then
			return true
		end
	end
	return false
end

local function cleanup(cx: WindowCx)
	scan(cx)
	local items: { PickItem } = {}
	for key, meta in state.agents do
		local wt = meta.worktree
		if wt and not in_use(wt) then
			local p = model.get(state, meta.project)
			table.insert(items, {
				label = meta.title,
				detail = (if p then p.name .. " · " else "") .. tilde(wt),
				icon = "trash",
				key = key,
			})
		end
	end
	if #items == 0 then
		cx:toast("info", "No finished agent owns a worktree", "Close the agent (and its subagents) first, then clean up its worktree")
		return
	end
	ask_pick(cx, { items = items, placeholder = "Worktree to remove", icon = "trash", action = "remove" }, function(item, pcx)
		local key = (item :: any).key :: string
		state = model.load()
		local meta = state.agents[key]
		if meta == nil or meta.worktree == nil then
			return
		end
		local m = meta :: model.AgentMeta
		local wt = m.worktree :: string
		if not tern.fs.exists(wt) then
			-- Already gone: let git forget it, then drop the record.
			git({ "-C", (model.get(state, m.project) or { root = wt }).root, "worktree", "prune" }, function(_res, gcx)
				state = model.load()
				state.agents[key] = nil
				model.save(state)
				if gcx then
					gcx:toast("info", "Worktree was already gone", tilde(wt))
					changed(gcx)
				end
			end)
			return
		end
		git({ "-C", wt, "status", "--porcelain" }, function(res, gcx)
			if gcx == nil then
				return
			end
			if res.status == 0 and trimmed(res.stdout) == "" then
				remove_worktree(gcx, key, m, false)
				return
			end
			ask_pick(gcx, {
				items = {
					{ label = "Remove anyway, discarding its changes", icon = "trash", confirm = true },
					{ label = "Keep it", icon = "x", confirm = false },
				},
				placeholder = model.basename(wt) .. " has uncommitted changes",
				icon = "trash",
			}, function(choice, ccx)
				if (choice :: any).confirm then
					remove_worktree(ccx, key, m, true)
				end
			end)
		end)
	end)
end

local function confirm_remove(cx: WindowCx, p: model.Project)
	ask_pick(cx, {
		items = {
			{ label = "Remove " .. p.name, detail = "its files, session and worktrees stay", icon = "trash", confirm = true },
			{ label = "Keep it", icon = "x", confirm = false },
		},
		placeholder = "Remove project " .. p.name .. "?",
		icon = "trash",
	}, function(choice, ccx)
		if not (choice :: any).confirm then
			return
		end
		state = model.load()
		if model.remove_project(state, p.id) then
			model.save(state)
			ui = model.load_ui()
			if ui.collapsed[p.id] then
				ui.collapsed[p.id] = nil
				model.save_ui(ui)
			end
			ccx:toast("success", "Removed " .. p.name, "Its files, session and worktrees are untouched")
			changed(ccx)
		end
	end)
end

local function remove_project(cx: WindowCx)
	pick_project(cx, "Project to remove (files are kept)", confirm_remove)
end

local function rename_agent(cx: WindowCx, pane: number)
	scan(cx)
	local b = blocks[pane]
	local cwd = if b then b.cwd else nil
	ask_text(cx, { value = title_of(pane, cwd), placeholder = "New name for the agent", icon = "agent", action = "rename" }, function(text, rcx)
		state = model.load()
		local key = tostring(pane)
		local meta = state.agents[key]
		if meta then
			meta.title = text
		else
			-- An agent started by hand: keep its name under the project its folder belongs to (if any).
			local p = model.project_for_path(state, cwd)
			state.agents[key] = { project = if p then p.id else "", title = text, started = 0 }
		end
		model.save(state)
		local top = meta == nil or meta.parent == nil
		local tab = rcx.session:tab_of(pane)
		if top and tab then
			rcx.layout:name_tab(tab, text)
		end
		changed(rcx)
	end)
end

local function toggle_group(cx: WindowCx, id: string)
	ui = model.load_ui()
	ui.collapsed[id] = if ui.collapsed[id] then nil else true
	model.save_ui(ui)
	refresh_side(cx)
end

local function collapse_all(cx: WindowCx)
	state = model.load()
	ui = model.load_ui()
	local ids: { string } = {}
	for _, p in state.projects do
		table.insert(ids, p.id)
	end
	model.collapse_all(ui, ids)
	model.save_ui(ui)
	refresh_side(cx)
end

-- Orca's switcher: every agent (subagents included) and every project, filtered as you type.
local function search(cx: WindowCx)
	scan(cx)
	local snap = snapshot(cx)
	local items: { PickItem } = {}
	local function add_rows(rows: { AgentRow }, pname: string?, depth: number)
		for _, row in rows do
			local where = row.branch or (if row.cwd ~= "" then model.basename(row.cwd) else nil)
			local detail = { pname, where, (string.gsub(row.state, "_", " ")) }
			local parts: { string } = {}
			for i = 1, 3 do
				if detail[i] then
					table.insert(parts, detail[i] :: string)
				end
			end
			table.insert(items, {
				label = string.rep("  ", depth) .. row.title,
				detail = table.concat(parts, " · "),
				group = "Agents",
				icon = if row.state == "waiting_input" then "bell" else "agent",
				current = row.pane == snap.active,
				pane = row.pane,
			})
			add_rows(row.spawned, pname, depth + 1)
		end
	end
	for _, ps in snap.projects do
		add_rows(ps.agents, ps.project.name, 0)
	end
	add_rows(snap.unassigned, nil, 0)
	for _, ps in snap.projects do
		table.insert(items, {
			label = ps.project.name,
			detail = tilde(ps.project.root),
			group = "Projects",
			icon = "folder",
			current = ps.current,
			project = ps.project.id,
		})
	end
	if #items == 0 then
		cx:toast("info", "No agents or projects yet", "Add a project with Projects: Add project")
		return
	end
	ask_pick(cx, { items = items, placeholder = "Jump to an agent or project", icon = "search", action = "go" }, function(item, pcx)
		local it = item :: any
		if it.pane then
			goto_pane(pcx, it.pane)
		elseif it.project then
			local p = model.get(model.load(), it.project)
			if p then
				open_project(pcx, p)
			end
		end
	end)
end

-- Whether ⌘B (Ctrl+B) runs the sidebar toggle by the user's keybind override.
local function orca_chord_bound(cx: WindowCx): boolean
	local ok, binds = pcall(function()
		return cx.settings:keybinds()
	end)
	if not ok then
		return false
	end
	local v = binds[ORCA_CHORD]
	if type(v) == "table" then
		return table.find(v, TOGGLE) ~= nil
	end
	return v == TOGGLE
end

-- Set below: registers the palette commands (again).
local register_commands: () -> ()

-- A keybinds change rebuilds the keymap without plugin command chords (Tern 0.9.16); registering the
-- commands again brings them back.
local function use_orca_chord(cx: WindowCx)
	cx.settings:bind(ORCA_CHORD, TOGGLE)
	register_commands()
	cx:toast("success", (if MACOS then "⌘B" else "Ctrl+B") .. " now toggles the sidebar", "Projects: Release ⌘B gives it back to Tern")
end

-- Drops only our override, so the chord goes back to Tern's presets.
local function release_orca_chord(cx: WindowCx)
	local binds = cx.settings:keybinds()
	binds[ORCA_CHORD] = nil
	cx.settings:set("keybinds", binds)
	register_commands()
	cx:toast("info", (if MACOS then "⌘B" else "Ctrl+B") .. " is Tern's again")
end

local function options(cx: WindowCx)
	local bound = orca_chord_bound(cx)
	local chord = if MACOS then "⌘B" else "Ctrl+B"
	local items: { PickItem } = {
		{ label = "Add project", icon = "folder-plus", run = "add" },
		{ label = "Remove project", detail = "keeps its files", icon = "trash", run = "remove" },
		{ label = "Clean up worktrees", detail = "of finished agents", icon = "worktree", run = "cleanup" },
		{ label = "Collapse or expand all projects", icon = "list", run = "collapse_all" },
		{
			label = if bound then "Stop using " .. chord .. " for the sidebar" else "Use " .. chord .. " for the sidebar",
			detail = if bound then "back to Tern's " .. chord else "like Orca; replaces Tern's " .. chord,
			icon = "settings",
			run = if bound then "release" else "use",
		},
		{ label = "Show/hide Files", detail = "Tern's Files pane", icon = "folder", run = "files" },
		{ label = "Refresh", icon = "refresh", run = "refresh" },
		{ label = "Hide sidebar", icon = "sidebar", run = "hide" },
	}
	ask_pick(cx, { items = items, placeholder = "Projects sidebar", icon = "settings", action = "run" }, function(item, pcx)
		local run = (item :: any).run
		if run == "add" then
			add_project(pcx)
		elseif run == "remove" then
			remove_project(pcx)
		elseif run == "cleanup" then
			cleanup(pcx)
		elseif run == "collapse_all" then
			collapse_all(pcx)
		elseif run == "use" then
			use_orca_chord(pcx)
		elseif run == "release" then
			release_orca_chord(pcx)
		elseif run == "files" then
			-- The built-in, past our override of `files`.
			pcx:command("files")
		elseif run == "refresh" then
			changed(pcx)
		elseif run == "hide" then
			hide_side(pcx)
		end
	end)
end

-- A group header's … button: its right-click menu as a picker.
local function project_menu(cx: WindowCx, p: model.Project)
	ask_pick(cx, {
		items = {
			{ label = "New agent", detail = "in " .. p.name, icon = "plus", run = "new" },
			{ label = "Open session", detail = p.name, icon = "folder-open", run = "open" },
			{ label = "Remove project", detail = "keeps its files", icon = "trash", run = "remove" },
		},
		placeholder = p.name,
		icon = "folder",
		action = "run",
	}, function(item, pcx)
		local run = (item :: any).run
		if run == "new" then
			new_agent_in(pcx, p)
		elseif run == "open" then
			open_project(pcx, p)
		elseif run == "remove" then
			confirm_remove(pcx, p)
		end
	end)
end

local function new_agent_for(cx: WindowCx, id: string?)
	local p = if id then model.get(model.load(), id) else nil
	if p then
		new_agent_in(cx, p)
	else
		new_agent(cx)
	end
end

local COMMANDS: { CommandDef } = {
	{ id = "toggle_sidebar", title = "Toggle sidebar", icon = "sidebar", keys = { if MACOS then "alt+cmd+b" else "ctrl+alt+b" }, run = toggle_side },
	{ id = "search", title = "Search agents and projects", icon = "search", keys = { MOD .. "k" }, run = search },
	{ id = "add", title = "Add project", icon = "folder-plus", run = add_project },
	{ id = "remove", title = "Remove project (keeps files)", icon = "trash", run = remove_project },
	{
		id = "open",
		title = "Open project",
		icon = "folder",
		keys = { MOD .. "l" },
		run = function(cx)
			pick_project(cx, "Project to open", open_project)
		end,
	},
	{ id = "new_agent", title = "New agent in project", icon = "sparkle", keys = { MOD .. "a" }, run = new_agent },
	{
		id = "new_subagent",
		title = "New subagent of focused agent",
		icon = "sparkle",
		keys = { MOD .. "u" },
		run = function(cx)
			local pane = cx.session:focused()
			if pane == nil then
				cx:toast("error", "Not an agent", "Focus an agent block to start a subagent of it")
				return
			end
			new_subagent_of(cx, pane)
		end,
	},
	{ id = "next_waiting", title = "Jump to next agent waiting for input", icon = "bell", keys = { MOD .. "j" }, run = next_waiting },
	{ id = "cleanup", title = "Remove a finished agent's worktree", icon = "trash", run = cleanup },
	{ id = "options", title = "Sidebar options", icon = "settings", run = options },
	{
		id = "use_cmd_b",
		title = if MACOS then "Use ⌘B to toggle the sidebar" else "Use Ctrl+B to toggle the sidebar",
		icon = "sidebar",
		available = function(cx)
			return not orca_chord_bound(cx)
		end,
		run = use_orca_chord,
	},
	{
		id = "release_cmd_b",
		title = if MACOS then "Release ⌘B (back to Tern's)" else "Release Ctrl+B (back to Tern's)",
		icon = "sidebar",
		available = orca_chord_bound,
		run = release_orca_chord,
	},
}

function register_commands()
	for _, def in COMMANDS do
		def.group = "Projects"
		tern.command(def)
	end
end
register_commands()

-- The title bar's Files button (moved to the leading edge by chrome.css) and ⌃⌘E toggle the sidebar.
-- Files stays on ⇧⌘E (focus_files) and the sidebar options.
tern.override("files", function(cx: WindowCx): boolean?
	toggle_side(cx)
	return true
end)

-- Events ---------------------------------------------------------------------

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.owner ~= ID then
		return false
	end
	-- A click focused the sidebar: give focus back first (synchronously, so it never shows).
	refocus(cx, ev.pane)
	-- Real clicks arrive split at `=` (act, value); scripted events arrive whole: parse_action takes both.
	local act, parsed = sidebar.parse_action(ev)
	local pane = if type(parsed) == "number" then parsed else nil
	local value = if type(parsed) == "string" then parsed else nil
	if act == "focus" and pane then
		goto_pane(cx, pane)
	elseif act == "rename" and pane then
		rename_agent(cx, pane)
	elseif act == "stop" and pane then
		pcall(function()
			cx.agents:stop(pane)
		end)
		changed(cx)
	elseif act == "new_subagent" and pane then
		new_subagent_of(cx, pane)
	elseif act == "new_agent" then
		new_agent_for(cx, value)
	elseif act == "open_project" and value then
		local p = model.get(model.load(), value)
		if p then
			open_project(cx, p)
		end
	elseif act == "remove_project" and value then
		local p = model.get(model.load(), value)
		if p then
			confirm_remove(cx, p)
		end
	elseif act == "toggle_group" and value then
		toggle_group(cx, value)
	elseif act == "collapse_all" then
		collapse_all(cx)
	elseif act == "add_project" then
		add_project(cx)
	elseif act == "search" then
		search(cx)
	elseif act == "cleanup" then
		cleanup(cx)
	elseif act == "next_waiting" then
		next_waiting(cx)
	elseif act == "refresh" then
		scan(cx)
		refresh_side(cx)
	elseif act == "hide" then
		hide_side(cx)
	elseif act == "options" then
		options(cx)
	elseif act == "project_menu" and value then
		local p = model.get(model.load(), value)
		if p then
			project_menu(cx, p)
		end
	else
		return false
	end
	return true
end)

-- An agent the user isn't looking at that finished or needs input is unread until focused.
local function mark_unread(cx: WindowCx, pane: number)
	if main_pane(cx, side_pane) ~= pane then
		unread[pane] = true
	end
end

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	scan(cx)
	if ev.new == "waiting_input" and ev.old ~= "waiting_input" and cx.session:focused() ~= ev.pane then
		mark_unread(cx, ev.pane)
		local b = blocks[ev.pane]
		local cwd = if b then b.cwd else nil
		local p = project_of(ev.pane, cwd)
		local who = (if p then p.name .. " · " else "") .. title_of(ev.pane, cwd)
		local msg = if b and b.last_message then short(firstline(b.last_message), 120) else nil
		cx:toast("info", who .. " needs input", msg)
	end
	if pending[ev.pane] and ev.new ~= "working" then
		deliver(cx, ev.pane)
	end
	changed(cx, true)
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	scan(cx)
	if (ev.result == "done" or ev.result == "failed") and cx.session:focused() ~= ev.pane then
		mark_unread(cx, ev.pane)
		local b = blocks[ev.pane]
		local cwd = if b then b.cwd else nil
		local p = project_of(ev.pane, cwd)
		local who = (if p then p.name .. " · " else "") .. title_of(ev.pane, cwd)
		local msg = if b and b.last_message then short(firstline(b.last_message), 120) else nil
		if ev.result == "done" then
			cx:toast("success", who .. " finished", msg)
		else
			cx:toast("error", who .. " failed", msg)
		end
	end
	if ev.result == "done" or ev.result == "failed" then
		report_back(cx, ev.pane, ev.result, 0)
	end
	changed(cx, true)
end)

-- Focus moved: the focused agent is read, and the sidebar follows the user to another tab or session.
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	local side = find_side(cx)
	if ev.pane == side then
		return
	end
	last_main = ev.pane
	unread[ev.pane] = nil
	if side and ui.visible and not parked(cx, side) and cx.session:tab_of(side) ~= ev.tab then
		show_side(cx)
	end
	changed(cx, true)
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if ev.pane == side_pane then
		side_pane = nil
		side_gen += 1
		return
	end
	if ev.pane == last_main then
		last_main = nil
	end
	unread[ev.pane] = nil
	state = model.load()
	local key = tostring(ev.pane)
	local meta = state.agents[key]
	if meta then
		if meta.worktree then
			meta.closed = true
		else
			state.agents[key] = nil
		end
		model.save(state)
	end
	reported[ev.pane] = nil
	pending[ev.pane] = nil
	changed(cx)
end)

tern.on("session_ended", function(_ev: SessionEndedEvent, cx: WindowCx)
	changed(cx)
end)

-- Once per plugin run: at window_start, or (after a reload, which runs no window_start) on the first timer.
local started = false
local function init(cx: WindowCx)
	if started then
		return
	end
	started = true
	ui = model.load_ui()
	scan(cx)
	local side = find_side(cx)
	if ui.visible then
		show_side(cx)
	elseif side and not parked(cx, side) then
		-- Shown by an earlier run that didn't persist it: keep it live.
		refresh_side(cx)
		start_ticker()
	end
end

tern.on("window_start", init)

tern.timer(0, function(cx)
	if cx then
		init(cx)
	end
end)

-- Pure: reads only the caches `scan` fills, which calls tern.chrome.refresh() on change.
-- Always shows one segment, so the sidebar is one click away from any pane: the focused
-- pane's project with its counts, else "Projects" with the waiting count across all projects.
local function status_segments(pane: StatusPaneInfo): { StatusSegment }?
	local id = pane_project[pane.pane]
	local p = if id then model.get(state, id) else model.project_for_path(state, pane.cwd)
	if p == nil then
		local waiting = 0
		for _, c in counts do
			waiting += c.waiting
		end
		return {
			{
				text = if waiting > 0 then string.format("Projects · %d waiting", waiting) else "Projects",
				icon = "sidebar",
				tone = if waiting > 0 then "warn" else nil,
				command = TOGGLE,
			},
		}
	end
	local c = counts[p.id] or { working = 0, waiting = 0 }
	return {
		{
			text = string.format("%s · %d working · %d waiting", p.name, c.working, c.waiting),
			icon = "sidebar",
			tone = if c.waiting > 0 then "warn" else nil,
			command = TOGGLE,
		},
	}
end

tern.chrome.status(status_segments)
