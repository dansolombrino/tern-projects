--!strict
-- projects, sidebar: the Orca-style left sidebar (Search pill, "Projects" header,
-- project groups, one card per top-level agent with its subagents nested under
-- it) and its footer toolbar. Pure: `build` turns a snapshot into `tern.ui.el`
-- nodes (or `sidebar.ui`'s, which tests stub) classed `op-*` for sidebar.css,
-- and reads nothing else.
--
-- Clicks carry `actions = {click = "<act>=<value>"}`; Tern splits the name at
-- the first `=`, so `canvas_action` handlers get `ev.act` and `ev.value`.

local subagents = require("./subagents")

type Subagent = subagents.Subagent

export type Project = {
	id: string,
	name: string,
	root: string,
	color: string?,
	worktrees: boolean?,
	created: number?,
}

export type AgentRow = {
	pane: number,
	title: string,
	-- Tern's agent state: idle | working | waiting_input | exited (failed when known).
	state: string,
	model: string?,
	last_message: string?,
	cwd: string,
	branch: string?,
	-- Works in the project root (no worktree).
	primary: boolean?,
	-- os.time() when started.
	started: number?,
	spawned: { AgentRow }?,
	internal: { Subagent }?,
}

export type ProjectSnap = {
	project: Project,
	session_exists: boolean,
	current: boolean,
	agents: { AgentRow },
}

export type Snapshot = {
	projects: { ProjectSnap },
	unassigned: { AgentRow }?,
	-- Project id → group collapsed.
	collapsed: { [string]: boolean }?,
	-- Focused agent pane.
	active: number?,
	-- Pane → finished or needs input while not focused.
	unread: { [number]: boolean }?,
	-- os.time() for the "now/5m/3h/2d" labels.
	now: number?,
	-- Agents waiting for input, all projects.
	waiting: number?,
}

local sidebar = {}

-- Builders; nil means the global `tern.ui`. Tests assign a stub.
sidebar.ui = nil :: any

-- Action names (the contract with window.luau); values follow `=`.
sidebar.ACT = {
	focus = "focus", -- value: pane
	rename = "rename", -- value: pane
	new_subagent = "new_subagent", -- value: pane
	stop = "stop", -- value: pane
	new_agent = "new_agent", -- value: project id; none: the focused pane's project, else a picker
	open_project = "open_project", -- value: project id
	remove_project = "remove_project", -- value: project id
	toggle_group = "toggle_group", -- value: project id
	project_menu = "project_menu", -- value: project id; picker of the group's "…" menu items
	collapse_all = "collapse_all",
	add_project = "add_project",
	search = "search",
	cleanup = "cleanup",
	next_waiting = "next_waiting",
	refresh = "refresh",
	hide = "hide",
	options = "options",
}

-- Actions whose value is a pane number.
local PANE_ACTS: { [string]: boolean } = { focus = true, rename = true, new_subagent = true, stop = true }

-- For cx.canvas:open's `about`.
sidebar.ABOUT = "Projects and their omp agents, Orca-style. Click an agent to focus it, double-click to rename, "
	.. "right-click for more. Group headers collapse; + starts an agent in the project. Nothing runs without a click."

-- Class of the view root (chrome.css scopes the pane with `:has(.op-sidebar)`).
sidebar.ROOT_CLASS = "op-sidebar"
-- Id of the view root in a canvas (`main.<root key>`).
sidebar.ROOT_KEY = "projects"
sidebar.ROOT_ID = "main." .. sidebar.ROOT_KEY

-- Internal subagents drawn per agent before an overflow row.
sidebar.MAX_INTERNAL = 12

-- Keycaps of the `search` command (window.luau binds cmd+alt+shift+k).
sidebar.SEARCH_KEYS = { "⌘", "⌥", "⇧", "K" }

local function lib(): any
	return sidebar.ui or tern.ui
end

local function act(name: string, value: (string | number)?): string
	if value == nil then
		return name
	end
	if type(value) == "number" then
		return string.format("%s=%d", name, value)
	end
	return name .. "=" .. value
end

-- Keys become id segments: keep them free of `.` and `/`.
local function key_of(prefix: string, s: string): string
	return prefix .. (string.gsub(s, "[^%w_-]", "_"))
end

local function first_line(s: string?): string?
	if s == nil then
		return nil
	end
	local line = string.match(s, "^%s*([^\n]*)") or ""
	line = string.gsub(line, "%s+$", "")
	if line == "" then
		return nil
	end
	if #line > 160 then
		line = string.sub(line, 1, 159) .. "…"
	end
	return line
end

local function basename(path: string): string
	local trimmed = string.gsub(path, "/+$", "")
	return string.match(trimmed, "([^/]+)$") or path
end

-- Orca's short-time-ago: now, 5m, 3h, 2d.
function sidebar.ago(now: number?, t: number?): string?
	if now == nil or t == nil then
		return nil
	end
	local d = math.max(0, now - t)
	if d < 60 then
		return "now"
	elseif d < 3600 then
		return string.format("%dm", d // 60)
	elseif d < 86400 then
		return string.format("%dh", d // 3600)
	end
	return string.format("%dd", d // 86400)
end

-- Element helpers ------------------------------------------------------------

local function el(tag: string, props: { [string]: any }, children: { any }?): any
	return lib().el(tag, props, children)
end

local function span(class: string, text: string?, key: string?): any
	return el("span", { class = class, text = text, key = key })
end

local function icon(name: string, class: string?, key: string?): any
	return el("span", { class = "op-i " .. (class or ""), key = key or "i" }, {
		lib().node("icon", { name = name }),
	})
end

-- A 24px (or 20px with `small`) ghost icon button.
local function icon_button(key: string, name: string, title: string, action: string, extra: string?): any
	return el("button", {
		key = key,
		class = "op-ib " .. (extra or ""),
		title = title,
		actions = { click = action },
	}, { icon(name) })
end

-- Status glyphs ----------------------------------------------------------------

-- Tern agent state (or omp subagent status) → Orca dot state.
local DOT: { [string]: string } = {
	working = "working",
	running = "working",
	waiting_input = "waiting",
	pending = "idle",
	idle = "idle",
	parked = "idle",
	exited = "done",
	done = "done",
	failed = "failed",
	aborted = "failed",
}

local LABEL: { [string]: string } = {
	working = "Working",
	waiting = "Waiting for input",
	idle = "Idle",
	done = "Done",
	failed = "Failed",
	unread = "Unread",
}

-- A status glyph in a `size` box ("md" 12px on cards, "sm" 10px on rows).
local function glyph(state: string, size: string): any
	local cls = "op-st op-st-" .. size .. " op-" .. state
	if state == "working" then
		return el("span", { class = cls, key = "st", title = LABEL.working }, { span("op-spin", nil, "spin") })
	elseif state == "waiting" then
		return el("span", { class = cls, key = "st", title = LABEL.waiting }, { icon("help") })
	elseif state == "unread" then
		return el("span", { class = cls, key = "st", title = LABEL.unread }, { icon("bell") })
	elseif state == "done" and size == "sm" then
		return el("span", { class = cls, key = "st", title = LABEL.done }, { span("op-ring", nil, "ring") })
	end
	return el("span", { class = cls, key = "st", title = LABEL[state] }, { span("op-dot", nil, "dot") })
end

-- The most urgent state over an agent and its spawned subagents.
local function rollup(row: AgentRow): string
	local seen: { [string]: boolean } = {}
	local function go(r: AgentRow)
		seen[DOT[r.state] or "idle"] = true
		for _, c in r.spawned or {} do
			go(c)
		end
	end
	go(row)
	for _, s in { "waiting", "failed", "working" } do
		if seen[s] then
			return s
		end
	end
	return DOT[row.state] or "idle"
end

-- Whether `pane` or any spawned descendant of `row` is it.
local function holds(row: AgentRow, pane: number?): boolean
	if pane == nil then
		return false
	end
	for _, c in row.spawned or {} do
		if c.pane == pane or holds(c, pane) then
			return true
		end
	end
	return false
end

-- Nested agent rows ------------------------------------------------------------

type Ctx = { snap: Snapshot, project: Project? }

local function agent_menu(row: AgentRow, project: Project?): { any }
	local menu: { any } = {
		{ id = act("focus", row.pane), label = "Focus", icon = "eye" },
		{ id = act("rename", row.pane), label = "Rename", icon = "pencil" },
		{ id = act("new_subagent", row.pane), label = "New subagent", icon = "corner-down-right" },
	}
	if project ~= nil then
		table.insert(menu, "-")
		table.insert(menu, { id = act("open_project", project.id), label = "Open project session", icon = "folder-open" })
	end
	table.insert(menu, "-")
	table.insert(menu, { id = act("stop", row.pane), label = "Stop", icon = "stop", danger = true })
	return menu
end

-- One 24px row: state dot, identity icon, lead + trail text, model, time.
local function row_el(
	key: string,
	state: string,
	lead: string,
	trail: string?,
	model: string?,
	time: string?,
	opts: { [string]: any }
): any
	local cls = "op-row"
	if opts.on then
		cls ..= " on"
	end
	if opts.unread then
		cls ..= " unread"
	end
	if opts.depth and opts.depth > 0 then
		cls ..= " op-d" .. math.min(opts.depth, 4)
	end
	local text: { any } = { span("op-lead", lead, "lead") }
	if trail ~= nil then
		text[2] = span("op-trail", " - " .. trail, "trail")
	end
	local children: { any } = { glyph(state, "sm") }
	if opts.identity then
		table.insert(children, icon("omp", "op-who", "who"))
	end
	table.insert(children, el("span", { class = "op-text", key = "text" }, text))
	if model ~= nil then
		table.insert(children, span("op-model", model, "model"))
	end
	if time ~= nil then
		table.insert(children, span("op-time", time, "time"))
	end
	return el("div", { key = key, class = cls, title = opts.title, actions = opts.actions }, children)
end

local function internal_rows(row: AgentRow, out: { any })
	local list: { Subagent } = row.internal or {}
	local shown = math.min(#list, sidebar.MAX_INTERNAL)
	for i = 1, shown do
		local s = list[i]
		local trail = first_line(s.task)
		if s.status == "running" and s.tool ~= nil then
			trail = s.tool .. (if s.intent then ": " .. s.intent else "")
		end
		out[#out + 1] = row_el(key_of("s_", s.id), DOT[s.status] or "idle", s.name, trail, s.model, nil, {
			depth = s.depth,
			title = s.task,
			actions = { click = act("focus", row.pane) },
		})
	end
	if #list > shown then
		out[#out + 1] = el("div", {
			key = "more",
			class = "op-row op-more",
			actions = { click = act("focus", row.pane) },
		}, { span("op-lead", string.format("… %d more subagents", #list - shown), "lead") })
	end
end

-- An agent's own row, then its spawned and internal subagents inside a lineage rail.
local function agent_rows(ctx: Ctx, row: AgentRow, out: { any })
	local snap = ctx.snap
	local unread = snap.unread ~= nil and snap.unread[row.pane] == true
	local state = DOT[row.state] or "idle"
	out[#out + 1] = row_el(
		string.format("a_%d", row.pane),
		state,
		first_line(row.last_message) or LABEL[state] or row.title,
		nil,
		row.model,
		sidebar.ago(snap.now, row.started),
		{
			identity = true,
			on = snap.active == row.pane,
			unread = unread,
			title = row.cwd,
			actions = { click = act("focus", row.pane), menu = agent_menu(row, ctx.project) },
		}
	)
	local kids: { any } = {}
	for _, child in row.spawned or {} do
		local cstate = DOT[child.state] or "idle"
		kids[#kids + 1] = row_el(
			string.format("a_%d", child.pane),
			cstate,
			child.title,
			first_line(child.last_message),
			child.model,
			sidebar.ago(snap.now, child.started),
			{
				identity = true,
				on = snap.active == child.pane,
				unread = snap.unread ~= nil and snap.unread[child.pane] == true,
				title = child.cwd,
				actions = {
					click = act("focus", child.pane),
					dblclick = act("rename", child.pane),
					menu = agent_menu(child, ctx.project),
				},
			}
		)
		if (child.spawned and #child.spawned > 0) or (child.internal and #child.internal > 0) then
			local nested: { any } = {}
			for _, grand in child.spawned or {} do
				agent_rows(ctx, grand, nested)
			end
			internal_rows(child, nested)
			kids[#kids + 1] = el("div", { key = string.format("l_%d", child.pane), class = "op-lineage" }, nested)
		end
	end
	internal_rows(row, kids)
	if #kids > 0 then
		out[#out + 1] = el("div", { key = string.format("l_%d", row.pane), class = "op-lineage" }, kids)
	end
end

-- Worktree card (one per top-level agent) ---------------------------------------

local function card(ctx: Ctx, row: AgentRow): any
	local snap = ctx.snap
	local unread = snap.unread ~= nil and snap.unread[row.pane] == true
	local cls = "op-card"
	if snap.active == row.pane then
		cls ..= " on"
	elseif holds(row, snap.active) then
		cls ..= " on2"
	end
	if unread then
		cls ..= " unread"
	end
	local state = if unread then "unread" else rollup(row)
	local title: { any } = {
		glyph(state, "md"),
		span("op-title", row.title, "title"),
	}
	if row.primary then
		title[3] = el("span", { class = "op-primary", key = "primary", title = "Primary: works in the project root" }, {
			icon("home"),
		})
	end
	local meta = row.branch or basename(row.cwd)
	local agents: { any } = {}
	agent_rows(ctx, row, agents)
	return el("div", {
		key = string.format("c_%d", row.pane),
		class = cls,
		title = row.cwd,
		actions = {
			click = act("focus", row.pane),
			dblclick = act("rename", row.pane),
			menu = agent_menu(row, ctx.project),
		},
	}, {
		el("div", { key = "line", class = "op-line" }, title),
		el("div", { key = "meta", class = "op-meta" }, {
			el("span", { key = "chip", class = "op-chip", title = if row.branch then "Branch" else "Folder" }, {
				span("op-chip-t", meta, "t"),
			}),
		}),
		el("div", { key = "agents", class = "op-agents" }, agents),
	})
end

-- Project group -----------------------------------------------------------------

local function group(snap: Snapshot, ps: ProjectSnap): any
	local p = ps.project
	local collapsed = snap.collapsed ~= nil and snap.collapsed[p.id] == true
	local toggle = act("toggle_group", p.id)
	local menu = {
		{ id = act("new_agent", p.id), label = "New agent", icon = "plus" },
		{ id = act("open_project", p.id), label = "Open session", icon = "folder-open" },
		"-",
		{ id = act("remove_project", p.id), label = "Remove Project", icon = "trash", danger = true },
	}
	local head = el("div", {
		key = "head",
		class = "op-ghead",
		title = p.root,
		actions = { click = toggle, menu = menu },
	}, {
		el("span", { class = "op-gicon op-c-" .. (p.color or "blue"), key = "icon" }, {
			lib().node("icon", { name = if ps.current then "folder-open" else "folder" }),
		}),
		span("op-gname", p.name, "name"),
		el("div", { key = "acts", class = "op-gacts" }, {
			icon_button(
				"chev",
				"chev",
				if collapsed then "Expand " .. p.name else "Collapse " .. p.name,
				toggle,
				"op-sm op-chev"
			),
			el("button", {
				key = "more",
				class = "op-ib op-sm",
				title = "Project actions",
				actions = { click = act("project_menu", p.id), menu = menu },
			}, { icon("more") }),
			icon_button("new", "plus", "New agent in " .. p.name, act("new_agent", p.id), "op-sm"),
		}),
	})
	local children: { any } = { head }
	if not collapsed then
		local ctx: Ctx = { snap = snap, project = p }
		for _, row in ps.agents do
			children[#children + 1] = card(ctx, row)
		end
		if #ps.agents == 0 then
			children[#children + 1] = el("div", {
				key = "none",
				class = "op-none",
				actions = { click = act("new_agent", p.id) },
			}, {
				icon("plus"),
				span("op-none-t", "New agent", "t"),
			})
		end
	end
	return el("div", {
		key = key_of("g_", p.id),
		class = "op-group" .. (if collapsed then " collapsed" else ""),
	}, children)
end

-- Agents outside every project: a plain header, no actions.
local function unassigned_group(snap: Snapshot, rows: { AgentRow }): any
	local children: { any } = {
		el("div", { key = "head", class = "op-ghead op-static" }, {
			el("span", { class = "op-gicon op-c-none", key = "icon" }, { lib().node("icon", { name = "terminal" }) }),
			span("op-gname", "Unassigned", "name"),
		}),
	}
	local ctx: Ctx = { snap = snap, project = nil }
	for _, row in rows do
		children[#children + 1] = card(ctx, row)
	end
	return el("div", { key = "unassigned", class = "op-group" }, children)
end

-- Whole view --------------------------------------------------------------------

local function count_waiting(snap: Snapshot): (number, number)
	local waiting, working = 0, 0
	local function go(rows: { AgentRow }?)
		for _, r in rows or {} do
			if r.state == "waiting_input" then
				waiting += 1
			elseif r.state == "working" then
				working += 1
			end
			go(r.spawned)
		end
	end
	for _, ps in snap.projects or {} do
		go(ps.agents)
	end
	go(snap.unassigned)
	return snap.waiting or waiting, working
end

local function header(snap: Snapshot, waiting: number, working: number): any
	local projects = snap.projects or {}
	local all_collapsed = #projects > 0
	for _, ps in projects do
		if not (snap.collapsed and snap.collapsed[ps.project.id]) then
			all_collapsed = false
		end
	end
	local current: string? = nil
	for _, ps in projects do
		if ps.current then
			current = ps.project.id
		end
	end
	local bell_badge: any
	if waiting > 0 then
		bell_badge = el("span", { key = "badge", class = "op-badge op-q" }, { span("op-bdot", nil, "dot"), span("op-bn", tostring(waiting), "n") })
	elseif working > 0 then
		bell_badge = el("span", { key = "badge", class = "op-badge op-w" }, { span("op-bdot", nil, "dot"), span("op-bn", tostring(working), "n") })
	end
	local bell = el("button", {
		key = "bell",
		class = "op-ib op-bell",
		title = if waiting > 0
			then string.format("%d waiting for input: jump to the next", waiting)
			else "Jump to the next agent waiting for input",
		actions = { click = act("next_waiting") },
	}, { icon("bell"), bell_badge })
	local children: { any } = { span("op-head-t", "Projects", "title") }
	if #projects > 0 then
		children[2] = icon_button(
			"collapse",
			if all_collapsed then "unfold" else "shrink",
			if all_collapsed then "Expand all projects" else "Collapse all projects",
			act("collapse_all"),
			"op-collapse"
		)
	end
	children[#children + 1] = el("div", { key = "acts", class = "op-head-acts" }, {
		bell,
		icon_button("options", "sliders", "Options", act("options")),
		icon_button("add", "folder-plus", "Add project", act("add_project")),
		-- No project: Add project first; else the current project, or window.luau's picker.
		icon_button("new", "plus", "New agent", if #projects == 0 then act("add_project") else act("new_agent", current)),
	})
	return el("div", { key = "head", class = "op-head" }, children)
end

local function search_pill(): any
	local caps: { any } = {}
	for i, k in sidebar.SEARCH_KEYS do
		caps[i] = span("op-kc", k, string.format("k%d", i))
	end
	return el("div", {
		key = "search",
		class = "op-search",
		title = "Search agents and projects",
		actions = { click = act("search") },
	}, {
		icon("search"),
		span("op-search-t", "Search", "label"),
		el("span", { key = "keys", class = "op-keys" }, caps),
	})
end

local function footer(waiting: number): any
	return el("div", { key = "footer", class = "op-footer" }, {
		el("div", { key = "l", class = "op-fgroup" }, {
			icon_button("options", "gear", "Options", act("options")),
			icon_button("cleanup", "trash", "Clean up worktrees", act("cleanup")),
		}),
		el("div", { key = "r", class = "op-fgroup" }, {
			el("button", {
				key = "next",
				class = "op-ib" .. (if waiting > 0 then " op-alert" else ""),
				title = if waiting > 0
					then string.format("Jump to the next agent waiting for input (%d)", waiting)
					else "Jump to the next agent waiting for input",
				actions = { click = act("next_waiting") },
			}, {
				if waiting > 0
					then icon("bell")
					else el("span", { class = "op-cross", key = "cross" }, { span("op-cross-c", nil, "c") }),
			}),
			icon_button("hide", "sidebar", "Hide sidebar", act("hide")),
		}),
	})
end

-- The canvas view and dock for a snapshot.
function sidebar.build(snap: Snapshot): { view: any, dock: any }
	local projects = snap.projects or {}
	local unassigned = snap.unassigned or {}
	local waiting, working = count_waiting(snap)

	local list: { any } = {}
	for _, ps in projects do
		list[#list + 1] = group(snap, ps)
	end
	if #unassigned > 0 then
		list[#list + 1] = unassigned_group(snap, unassigned)
	end
	if #projects == 0 and #unassigned == 0 then
		list[#list + 1] = el("div", { key = "empty", class = "op-empty" }, {
			span("op-empty-t", "No projects yet", "t"),
			el("button", { key = "add", class = "op-empty-b", actions = { click = act("add_project") } }, {
				icon("folder-plus"),
				span("op-empty-bt", "Add project", "t"),
			}),
		})
	end

	local view = el("div", { key = sidebar.ROOT_KEY, class = sidebar.ROOT_CLASS }, {
		el("div", { key = "nav", class = "op-nav" }, { search_pill() }),
		header(snap, waiting, working),
		el("div", { key = "list", class = "op-list" }, list),
	})
	return { view = view, dock = footer(waiting) }
end

-- A canvas_action's action name and value. Clicks arrive split (`ev.act`,
-- `ev.value`); a scripted `cx.session:event(pane, {act = "focus=12"})` arrives
-- unsplit, so split it here too. Panes come back as numbers, ids as strings.
function sidebar.parse_action(ev: { act: string?, value: string? }): (string?, (string | number)?)
	local name, value = ev.act, ev.value
	if name ~= nil and value == nil then
		local a, v = string.match(name, "^([^=]*)=(.*)$")
		if a ~= nil then
			name, value = a, v
		end
	end
	if value ~= nil and name ~= nil and PANE_ACTS[name] then
		return name, tonumber(value) or value
	end
	return name, value
end

return sidebar
