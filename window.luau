--!strict
-- projects, window half: projects (one named Tern session each), omp agents per
-- project (each in a git worktree of its own when the project allows), spawned
-- and omp-internal subagents per agent, a dashboard canvas, a status segment and
-- toasts. Everything lives here; model.luau holds the data, subagents.luau and
-- dashboard.luau the pure surface reading and drawing.

local model = require("./model")
local subagents = require("./subagents")
local dashboard = require("./dashboard")

local ID = tern.plugin.id
local HOME = tern.getenv("HOME")
local DASH_TITLE = "Projects"
local MOD = if tern.runtime.os == "macos" then "cmd+alt+shift+" else "ctrl+alt+shift+"
-- Dashboard refresh period while it is open, and how often idle agents' surfaces are re-read.
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
	spawned: { AgentRow },
	internal: { subagents.Subagent },
}

type Counts = { working: number, waiting: number }

-- In-memory caches. `state` is re-read from kv before every change (other windows share it).
local state: model.State = model.load()
-- Agent blocks by pane, from the last `cx.agents:list()`.
local blocks: { [number]: AgentBlock } = {}
-- omp-internal subagents by parent pane, and when each was last read (tern.now()).
local internal: { [number]: { subagents.Subagent } } = {}
local internal_at: { [number]: number } = {}
-- Status-line inputs: agent counts per project id and each agent pane's project id.
local counts: { [string]: Counts } = {}
local pane_project: { [number]: string } = {}
-- The dashboard canvas and the generation of its refresh timer.
local dash_pane: number? = nil
local dash_gen = 0
local refresh_pending = false
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

-- Dashboard ------------------------------------------------------------------

local function find_dash(cx: WindowCx): number?
	if dash_pane and cx.canvas:get(dash_pane) then
		return dash_pane
	end
	dash_pane = nil
	for _, c in cx.canvas:list() do
		if c.owner == ID and c.title == DASH_TITLE then
			dash_pane = c.pane
			return c.pane
		end
	end
	return nil
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
	for _, pane in panes do
		local b = blocks[pane]
		local meta = meta_of(pane)
		rows[pane] = {
			pane = pane,
			title = title_of(pane, b.cwd),
			state = b.state,
			model = b.model,
			last_message = b.last_message,
			cwd = b.cwd,
			branch = if meta then meta.branch else nil,
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
	return { projects = projects, unassigned = unassigned }
end

local function draw(cx: WindowCx): (Node, Node?)
	read_internal(cx)
	local out = dashboard.build(snapshot(cx))
	return out.view, out.dock
end

local function refresh_dashboard(cx: WindowCx)
	local pane = find_dash(cx)
	if pane == nil then
		return
	end
	local view, dock = draw(cx)
	local change: CanvasChange = { view = view }
	if dock then
		change.dock = dock
	end
	cx.canvas:set(pane, change)
end

-- Refreshes everything event-driven: a scan now (unless the caller just did one), a dashboard
-- redraw soon (coalesced).
local function changed(cx: WindowCx, scanned: boolean?)
	if not scanned then
		scan(cx)
	end
	if dash_pane == nil or refresh_pending then
		return
	end
	refresh_pending = true
	tern.timer(150, function(tcx)
		refresh_pending = false
		if tcx then
			refresh_dashboard(tcx)
		end
	end)
end

local function tick(gen: number)
	tern.timer(TICK_MS, function(cx)
		if gen ~= dash_gen or cx == nil then
			return
		end
		if find_dash(cx) == nil then
			return
		end
		scan(cx)
		refresh_dashboard(cx)
		tick(gen)
	end)
end

local function start_ticker()
	dash_gen += 1
	tick(dash_gen)
end

local function toggle_dashboard(cx: WindowCx)
	local open = find_dash(cx)
	if open then
		cx.layout:close(open)
		dash_pane = nil
		dash_gen += 1
		return
	end
	scan(cx)
	local view, dock = draw(cx)
	local target = cx.session:focused()
	local spec: CanvasSpec = {
		title = DASH_TITLE,
		about = dashboard.ABOUT,
		view = view,
		focus = false,
	}
	if dock then
		spec.dock = dock
	end
	if target then
		spec.how = "beside"
		spec.target = target
		spec.dir = "left"
		spec.ratio = 0.28
	else
		spec.how = "tab"
	end
	local pane, err = cx.canvas:open(spec)
	if pane == nil then
		cx:toast("error", "Projects dashboard not opened", err)
		return
	end
	dash_pane = pane
	start_ticker()
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

local function remove_project(cx: WindowCx)
	pick_project(cx, "Project to remove (files are kept)", function(pcx, p)
		state = model.load()
		if model.remove_project(state, p.id) then
			model.save(state)
			pcx:toast("success", "Removed " .. p.name, "Its files, session and worktrees are untouched")
			changed(pcx)
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

local COMMANDS: { CommandDef } = {
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
	{ id = "dashboard", title = "Toggle projects dashboard", icon = "sidebar", keys = { MOD .. "d" }, run = toggle_dashboard },
	{ id = "next_waiting", title = "Jump to next agent waiting for input", icon = "bell", keys = { MOD .. "j" }, run = next_waiting },
	{ id = "cleanup", title = "Remove a finished agent's worktree", icon = "trash", run = cleanup },
}

for _, def in COMMANDS do
	def.group = "Projects"
	tern.command(def)
end

-- Events ---------------------------------------------------------------------

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.owner ~= ID then
		return false
	end
	-- Real clicks arrive split at `=` (act, value); scripted events arrive whole: parse_action takes both.
	local act, parsed = dashboard.parse_action(ev)
	local pane = if type(parsed) == "number" then parsed else nil
	local value = if type(parsed) == "string" then parsed else nil
	if act == "focus" and pane then
		goto_pane(cx, pane)
	elseif act == "stop" and pane then
		pcall(function()
			cx.agents:stop(pane)
		end)
		changed(cx)
	elseif act == "new_subagent" and pane then
		new_subagent_of(cx, pane)
	elseif act == "new_agent" and value then
		local p = model.get(model.load(), value)
		if p then
			new_agent_in(cx, p)
		end
	elseif act == "open_project" and value then
		local p = model.get(model.load(), value)
		if p then
			open_project(cx, p)
		end
	elseif act == "add_project" then
		add_project(cx)
	elseif act == "refresh" then
		scan(cx)
		refresh_dashboard(cx)
	else
		return false
	end
	return true
end)

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	scan(cx)
	if ev.new == "waiting_input" and ev.old ~= "waiting_input" and cx.session:focused() ~= ev.pane then
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

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if ev.pane == dash_pane then
		dash_pane = nil
		dash_gen += 1
		return
	end
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

local function init(cx: WindowCx)
	scan(cx)
	if find_dash(cx) then
		refresh_dashboard(cx)
		start_ticker()
	end
end

tern.on("window_start", init)

-- A reload doesn't run window_start again: pick up the open dashboard and agents now.
tern.timer(0, function(cx)
	if cx then
		init(cx)
	end
end)

-- Pure: reads only the caches `scan` fills, which calls tern.chrome.refresh() on change.
local function status_segments(pane: StatusPaneInfo): { StatusSegment }?
	local id = pane_project[pane.pane]
	local p = if id then model.get(state, id) else model.project_for_path(state, pane.cwd)
	if p == nil then
		return nil
	end
	local c = counts[p.id] or { working = 0, waiting = 0 }
	return {
		{
			text = string.format("%s · %d working · %d waiting", p.name, c.working, c.waiting),
			icon = "folder",
			tone = if c.waiting > 0 then "warn" else nil,
			command = "plugin." .. ID .. ".dashboard",
		},
	}
end

tern.chrome.status(status_segments)
