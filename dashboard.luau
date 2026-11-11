--!strict
-- projects, dashboard: the canvas view of every project, its agents, their
-- spawned subagents and omp's internal subagents. Pure: `build` turns a
-- snapshot into nodes with `tern.ui` (or `dashboard.ui`, which tests stub) and
-- reads nothing else.
--
-- Clicks: buttons and rows carry `actions = {click = "<act>=<value>"}`; Tern
-- splits the name at the first `=`, so `canvas_action` handlers get
-- `ev.act` and `ev.value` (a string: tonumber it for panes).

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
	-- Tern's agent state: idle | working | waiting_input | exited.
	state: string,
	model: string?,
	last_message: string?,
	cwd: string,
	branch: string?,
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
}

local dashboard = {}

-- Builders; nil means the global `tern.ui`. Tests assign a stub.
dashboard.ui = nil :: any

-- Action names (the contract with window.luau); values follow `=`.
dashboard.ACT = {
	focus = "focus", -- value: pane
	new_agent = "new_agent", -- value: project id
	open_project = "open_project", -- value: project id
	new_subagent = "new_subagent", -- value: pane
	stop = "stop", -- value: pane
	add_project = "add_project", -- no value
	refresh = "refresh", -- no value
}

-- For cx.canvas:open's `about`.
dashboard.ABOUT = "Projects and their omp agents. Focus shows an agent, Subagent starts a child agent beside it, "
	.. "Stop closes an agent block, Open switches to the project's session, New agent starts one in the project, "
	.. "Add project and Refresh act on the list. Nothing runs without a click."

-- Id of the view root in a canvas (`main.<root key>`, observed in Tern 0.9.16): a
-- card's `end` names its head-controls child by full id.
dashboard.ROOT_KEY = "projects"
dashboard.ROOT_ID = "main." .. dashboard.ROOT_KEY

-- Internal subagents drawn per agent before an overflow line.
dashboard.MAX_INTERNAL = 12

-- Tern agent state → agent-node status.
local STATUS: { [string]: string } = {
	working = "running",
	waiting_input = "pending",
	idle = "idle",
	exited = "done",
}

local function lib(): any
	local ui = dashboard.ui
	if ui ~= nil then
		return ui
	end
	return tern.ui
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

local function first_line(s: string?, max: number): string?
	if s == nil then
		return nil
	end
	local line = string.match(s, "^%s*([^\n]*)") or ""
	line = string.gsub(line, "%s+$", "")
	if line == "" then
		return nil
	end
	if #line > max then
		line = string.sub(line, 1, max - 1) .. "…"
	end
	return line
end

local function button(ui: any, key: string, label: string, icon: string, action: string, extra: { [string]: any }?): any
	local props: { [string]: any } = {
		key = key,
		icon = icon,
		size = "sm",
		variant = "quiet",
		title = label,
		actions = { click = action },
	}
	if extra then
		for k, v in extra do
			props[k] = v
		end
	end
	return ui.button(label, props)
end

-- Counts of Tern states over agents and their spawned subagents.
local function tally(rows: { AgentRow }?, into: { [string]: number }): { [string]: number }
	for _, row in rows or {} do
		into[row.state] = (into[row.state] or 0) + 1
		tally(row.spawned, into)
	end
	return into
end

local function internal_rows(ui: any, row: AgentRow, depth: number, out: { any })
	local list: { Subagent } = row.internal or {}
	local shown = math.min(#list, dashboard.MAX_INTERNAL)
	for i = 1, shown do
		local s = list[i]
		local stats: { [string]: any } = {}
		stats.tools = s.tools
		stats.cost = s.cost
		stats.context = s.context
		local props: { [string]: any } = {
			key = key_of("s_" .. row.pane .. "_", s.id),
			name = s.name,
			agent = "omp",
			task = s.task,
			status = s.status,
			model = s.model,
			depth = math.min(depth + 1 + s.depth, 6),
			stats = stats,
			title = s.task,
			actions = { click = act("focus", row.pane) },
		}
		if s.tool and s.status == "running" then
			props.tool = { name = s.tool, intent = s.intent }
		end
		local n: any = ui.node("agent", props)
		table.insert(out, n)
	end
	if #list > shown then
		local more = ui.text(ui.span(string.format("… %d more subagents", #list - shown), "muted"))
		more.p = more.p or {}
		more.p.key = "more_" .. row.pane
		table.insert(out, more)
	end
end

-- An agent and, after it as siblings drawn deeper, its spawned and internal subagents.
local function agent_rows(ui: any, row: AgentRow, depth: number, out: { any })
	local pane = row.pane
	local badges: { { [string]: string } } = {}
	if row.state == "waiting_input" then
		badges[#badges + 1] = { text = "needs you", tone = "warning" }
	end
	if row.branch ~= nil then
		badges[#badges + 1] = { text = row.branch }
	end
	local agent = ui.node("agent", {
		key = "agent",
		name = row.title,
		status = STATUS[row.state] or "pending",
		model = row.model,
		task = first_line(row.last_message, 200) or row.cwd,
		badges = badges,
		depth = math.min(depth, 6),
		title = row.cwd,
		grow = 1,
		actions = {
			click = act("focus", pane),
			menu = {
				{ id = act("focus", pane), label = "Focus", icon = "eye" },
				{ id = act("new_subagent", pane), label = "New subagent", icon = "corner-down-right" },
				"-",
				{ id = act("stop", pane), label = "Stop", icon = "stop", danger = true },
			},
		},
	})
	local acts = ui.node("row", { key = "acts", gap = "xs", align = "center" }, {
		button(ui, "focus", "Focus", "eye", act("focus", pane)),
		button(ui, "subagent", "Subagent", "corner-down-right", act("new_subagent", pane)),
		button(ui, "stop", "Stop", "stop", act("stop", pane), {
			disabled = if row.state == "exited" then "Already exited" else nil,
		}),
	})
	out[#out + 1] = ui.node("row", { key = string.format("a_%d", pane), gap = "sm", align = "center" }, {
		agent,
		acts,
	})
	for _, child in row.spawned or {} do
		agent_rows(ui, child, depth + 1, out)
	end
	internal_rows(ui, row, depth, out)
end

local function plural(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

local function project_card(ui: any, snap: ProjectSnap): any
	local p = snap.project
	local key = key_of("p_", p.id)
	local counts = tally(snap.agents, {})
	local meta = { plural(#snap.agents, "agent", "agents") }
	if (counts.working or 0) > 0 then
		table.insert(meta, string.format("%d working", counts.working))
	end
	if (counts.waiting_input or 0) > 0 then
		table.insert(meta, string.format("%d need you", counts.waiting_input))
	end
	if not snap.session_exists then
		table.insert(meta, "no session")
	end

	local children: { any } = {
		ui.node("row", { key = "end", gap = "xs", align = "center" }, {
			button(ui, "open", "Open", "folder-open", act("open_project", p.id), {
				title = if snap.current then "Current session" else "Switch to the project's session",
			}),
			button(ui, "new", "New agent", "plus", act("new_agent", p.id)),
		}),
	}
	if #snap.agents == 0 then
		children[#children + 1] = ui.node("empty", {
			key = "none",
			variant = "inline",
			icon = "sparkle",
			text = "No agents yet",
		}, {
			button(ui, "start", "New agent", "plus", act("new_agent", p.id)),
		})
	else
		for _, row in snap.agents do
			agent_rows(ui, row, 0, children)
		end
	end

	local status: string? = nil
	if (counts.waiting_input or 0) > 0 then
		status = "pending"
	elseif (counts.working or 0) > 0 then
		status = "running"
	end
	return ui.card(p.name, children, {
		key = key,
		icon = "folder",
		meta = table.concat(meta, " · "),
		["end"] = dashboard.ROOT_ID .. "." .. key .. ".end",
		tone = if snap.current then "accent" else nil,
		status = status,
		collapsible = true,
		title = p.root,
	})
end

-- The canvas view and dock for a snapshot.
function dashboard.build(snap: Snapshot): { view: any, dock: any? }
	local ui = lib()
	local projects = snap.projects or {}
	local unassigned = snap.unassigned or {}
	local children: { any } = {}

	if #projects == 0 and #unassigned == 0 then
		children[#children + 1] = ui.node("empty", {
			key = "empty",
			icon = "folder-plus",
			title = "No projects yet",
			text = "Add a folder (its git root) to group its agents.",
			grow = 1,
		}, {
			ui.button("Add project", {
				key = "add",
				variant = "primary",
				icon = "folder-plus",
				actions = { click = act("add_project") },
			}),
		})
	else
		for _, snapp in projects do
			children[#children + 1] = project_card(ui, snapp)
		end
		if #unassigned > 0 then
			local rows: { any } = {}
			for _, row in unassigned do
				agent_rows(ui, row, 0, rows)
			end
			children[#children + 1] = ui.node("section", {
				key = "unassigned",
				head = { ui.span("Unassigned"), ui.span(string.format(" %d", #unassigned), "muted") },
				collapsible = true,
			}, rows)
		end
	end

	local counts: { [string]: number } = {}
	for _, snapp in projects do
		tally(snapp.agents, counts)
	end
	tally(unassigned, counts)
	local summary: { string } = {}
	table.insert(summary, string.format("%d working", counts.working or 0))
	if (counts.waiting_input or 0) > 0 then
		table.insert(summary, string.format("%d need you", counts.waiting_input))
	end

	local view = ui.node("col", { key = dashboard.ROOT_KEY, gap = "sm" }, children)
	local dock = ui.node("row", { key = "dock", gap = "sm", align = "center" }, {
		ui.button("Add project", {
			key = "add",
			icon = "folder-plus",
			size = "sm",
			actions = { click = act("add_project") },
		}),
		ui.button("Refresh", {
			key = "refresh",
			icon = "repeat",
			size = "sm",
			variant = "quiet",
			actions = { click = act("refresh") },
		}),
		ui.node("row", { key = "gap", grow = 1 }),
		ui.text(ui.span(table.concat(summary, " · "), "muted")),
	})
	return { view = view, dock = dock }
end

-- A canvas_action's action name and value. Clicks arrive split (`ev.act`,
-- `ev.value`); a scripted `cx.session:event(pane, {act = "focus=12"})` arrives
-- unsplit, so split it here too. Panes come back as numbers, ids as strings.
function dashboard.parse_action(ev: { act: string?, value: string? }): (string?, (string | number)?)
	local name, value = ev.act, ev.value
	if name ~= nil and value == nil then
		local a, v = string.match(name, "^([^=]*)=(.*)$")
		if a ~= nil then
			name, value = a, v
		end
	end
	if value ~= nil and (name == "focus" or name == "new_subagent" or name == "stop") then
		return name, tonumber(value) or value
	end
	return name, value
end

return dashboard
