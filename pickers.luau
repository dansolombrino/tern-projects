--!strict
-- projects, pickers: agent navigation (reveal, previous/next, next waiting), the search switcher, worktree
-- cleanup, Workspace options, Orca's shortcuts, Settings and Help.

local model = require("./model")
local core = require("./core")
local PRIMARY = core.PRIMARY
local TOGGLE = core.TOGGLE
local action_id = core.action_id
local ask_pick = core.ask_pick
local tilde = core.tilde

type AgentRow = core.AgentRow

-- The context: all shared state and the other modules' functions, set by the installer below.
local S: core.Ctx = nil :: any

local function reveal_active(cx: WindowCx)
	local active = S.main_pane(cx, S.side_pane)
	if active and (S.blocks[active] or S.meta_of(active)) then
		S.reveal(cx, active)
	end
end

-- Focuses the previous (-1) or next (1) agent card in sidebar order, wrapping; sleeping cards are skipped.
local function step_agent(cx: WindowCx, delta: number)
	S.scan(cx)
	S.snapshot(cx)
	local list: { number } = {}
	for _, pane in S.rendered do
		if pane > 0 then
			table.insert(list, pane)
		end
	end
	if #list == 0 then
		return
	end
	local active = S.main_pane(cx, S.side_pane)
	local at = if active then table.find(list, S.card_pane(active)) else nil
	local i = if at then ((at - 1 + delta) % #list) + 1 else (if delta > 0 then 1 else #list)
	S.goto_pane(cx, list[i])
	S.reveal(cx, list[i])
end

-- The focused agent, for commands; toasts when the focus is no agent.
local function focused_agent(cx: WindowCx): number?
	S.scan(cx)
	local pane = S.main_pane(cx, S.side_pane)
	if pane and S.blocks[pane] then
		return pane
	end
	cx:toast("error", "Not an agent", "Focus an agent block first")
	return nil
end

local function next_waiting(cx: WindowCx)
	S.scan(cx)
	local waiting: { number } = {}
	for pane, b in S.blocks do
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
	S.goto_pane(cx, target)
	S.reveal(cx, target)
end

-- Orca's switcher: every agent (subagents included) and every project, filtered as you type.
local function search(cx: WindowCx)
	S.scan(cx)
	local snap = S.snapshot(cx)
	local items: { PickItem } = {}
	local function add_rows(rows: { AgentRow }, depth: number)
		for _, row in rows do
			local p = S.project_of(row.pane, row.cwd)
			local where = row.branch or (if row.cwd ~= "" then model.basename(row.cwd) else nil)
			local detail = { if p then p.name else nil, where, (string.gsub(row.state, "_", " ")) }
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
				icon = if row.state == "waiting_input" then "bell" elseif row.state == "sleeping" then "moon" else "agent",
				current = row.pane == snap.active,
				pane = row.pane,
			})
			add_rows(row.spawned, depth + 1)
		end
	end
	add_rows(snap.pinned, 0)
	for _, ps in snap.projects do
		add_rows(ps.agents, 0)
	end
	add_rows(snap.unassigned, 0)
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
		if it.pane and it.pane < 0 then
			S.wake(pcx, it.pane)
		elseif it.pane then
			S.goto_pane(pcx, it.pane)
			S.reveal(pcx, it.pane)
		elseif it.project then
			local p = model.get(model.load(), it.project)
			if p then
				S.open_project(pcx, p)
			end
		end
	end)
end

-- Every sleeping card, then Orca's delete funnel on the chosen one.
local function cleanup(cx: WindowCx)
	S.scan(cx)
	local items: { PickItem } = {}
	for key, meta in S.state.agents do
		local n = tonumber(key)
		if meta.closed and meta.worktree and n and S.blocks[n] == nil then
			local p = model.get(S.state, meta.project)
			table.insert(items, {
				label = meta.title,
				detail = (if p then p.name .. " · " else "") .. tilde(meta.worktree :: string),
				icon = "moon",
				pane = -n,
			})
		end
	end
	if #items == 0 then
		cx:toast("info", "No sleeping workspace", "Sleep an agent from its card menu first")
		return
	end
	ask_pick(cx, { items = items, placeholder = "Sleeping workspace to delete", icon = "trash", action = "delete" }, function(item, pcx)
		S.delete_agent(pcx, (item :: any).pane)
	end)
end

-- Options (D3) ---------------------------------------------------------------------------

local OPTIONS: { { group: string, field: string, value: any, label: string } } = {
	{ group = "Group by", field = "group_by", value = "project", label = "Project" },
	{ group = "Group by", field = "group_by", value = "none", label = "None" },
	{ group = "Sort by", field = "sort_by", value = "name", label = "Name" },
	{ group = "Sort by", field = "sort_by", value = "activity", label = "Agent Activity" },
	{ group = "Sort by", field = "sort_by", value = "recent", label = "Recent" },
	{ group = "Sort by", field = "sort_by", value = "manual", label = "Manual" },
	{ group = "Project order", field = "project_order", value = "manual", label = "Manual" },
	{ group = "Project order", field = "project_order", value = "recent", label = "Recent" },
	{ group = "Card display", field = "show_branch", value = true, label = "Branch name" },
	{ group = "Card display", field = "show_agents", value = true, label = "Agent statuses" },
	{ group = "Card display", field = "show_models", value = true, label = "Agent model" },
	{ group = "Filters", field = "hide_sleeping", value = true, label = "Hide sleeping" },
}

-- Orca's Workspace options: radio groups and toggles with checks, reopened after each choice.
local function options(cx: WindowCx)
	S.ui = model.load_ui()
	local u = S.ui :: any
	local items: { PickItem } = {}
	for i, o in OPTIONS do
		table.insert(items, { label = o.label, group = o.group, icon = "sliders", current = u[o.field] == o.value, option = i })
	end
	ask_pick(cx, { items = items, placeholder = "Workspace options", icon = "sliders" }, function(item, pcx)
		local o = OPTIONS[(item :: any).option]
		S.ui = model.load_ui()
		local cur = S.ui :: any
		if type(o.value) == "boolean" then
			cur[o.field] = not cur[o.field]
		else
			cur[o.field] = o.value
		end
		S.save_ui()
		S.refresh_side(pcx)
		options(pcx)
	end)
end

local function toggle_activity(cx: WindowCx)
	S.ui = model.load_ui()
	S.ui.body = if S.ui.body == "agents" then "workspaces" else "agents"
	S.save_ui()
	S.refresh_side(cx)
end

-- Orca keys (D12) -------------------------------------------------------------------------

-- Orca's chords, bound together on request (Tern's presets own most of them).
local ORCA_KEYS: { { chord: string, cmd: string } } = {
	{ chord = PRIMARY .. "b", cmd = "toggle_sidebar" },
	{ chord = PRIMARY .. "j", cmd = "search" },
	{ chord = PRIMARY .. "n", cmd = "new_agent" },
	{ chord = PRIMARY .. "shift+up", cmd = "prev_agent" },
	{ chord = PRIMARY .. "shift+down", cmd = "next_agent" },
	{ chord = PRIMARY .. "alt+r", cmd = "rename" },
	{ chord = PRIMARY .. "shift+backspace", cmd = "delete" },
	{ chord = PRIMARY .. "alt+p", cmd = "collapse_all" },
}

local function binds_of(cx: WindowCx): { [string]: string | { string } }
	local ok, binds = pcall(function()
		return cx.settings:keybinds()
	end)
	return if ok then binds else {}
end

local function bound_to(v: any, action: string): boolean
	if type(v) == "table" then
		return table.find(v, action) ~= nil
	end
	return v == action
end

-- Whether Orca's chords run our commands by the user's keybind overrides.
local function orca_keys_bound(cx: WindowCx): boolean
	local binds = binds_of(cx)
	return bound_to(binds[ORCA_KEYS[1].chord], TOGGLE)
end

-- A keybinds change rebuilds the keymap without plugin command chords (Tern 0.9.16); registering the
-- commands again brings them back.
local function use_orca_keys(cx: WindowCx)
	for _, k in ORCA_KEYS do
		cx.settings:bind(k.chord, action_id(k.cmd))
	end
	S.register_commands()
	cx:toast("success", "Orca's shortcuts are on", "Projects: Release Orca shortcuts gives them back to Tern")
	S.redraw_soon()
end

-- Drops only our overrides, so the chords go back to Tern's presets.
local function release_orca_keys(cx: WindowCx)
	local binds = binds_of(cx)
	for _, k in ORCA_KEYS do
		if bound_to(binds[k.chord], action_id(k.cmd)) then
			binds[k.chord] = nil
		end
	end
	cx.settings:set("keybinds", binds)
	S.register_commands()
	cx:toast("info", "Orca's shortcuts are Tern's again")
	S.redraw_soon()
end

-- Settings and Help (D2) ---------------------------------------------------------------

local function settings_picker(cx: WindowCx)
	S.ui = model.load_ui()
	local bound = orca_keys_bound(cx)
	local items: { PickItem } = {
		{ label = "Add project", icon = "folder-plus", run = "add" },
		{ label = "Clean up worktrees", detail = "delete a sleeping workspace", icon = "trash", run = "cleanup" },
		{
			label = if bound then "Release Orca shortcuts" else "Use Orca shortcuts",
			detail = if bound then "back to Tern's chords" else "⌘B ⌘J ⌘N ⇧⌘↑↓ ⌥⌘R ⇧⌘⌫ ⌥⌘P; replaces Tern's",
			icon = "settings",
			run = if bound then "release" else "use",
		},
	}
	if S.ui.skip_delete_confirm then
		table.insert(items, { label = "Ask before deleting workspaces", detail = "show the Delete Workspace confirmation again", icon = "trash", run = "ask_delete" })
	end
	table.insert(items, { label = "Show/hide Files", detail = "Tern's Files pane", icon = "folder", run = "files" })
	table.insert(items, { label = "Refresh", icon = "refresh", run = "refresh" })
	table.insert(items, { label = "Hide sidebar", icon = "sidebar", run = "hide" })
	ask_pick(cx, { items = items, placeholder = "Settings", icon = "gear", action = "run" }, function(item, pcx)
		local run = (item :: any).run
		if run == "add" then
			S.add_project(pcx)
		elseif run == "cleanup" then
			cleanup(pcx)
		elseif run == "use" then
			use_orca_keys(pcx)
		elseif run == "release" then
			release_orca_keys(pcx)
		elseif run == "ask_delete" then
			S.ui = model.load_ui()
			S.ui.skip_delete_confirm = false
			S.save_ui()
		elseif run == "files" then
			-- The built-in, past our override of `files`.
			pcx:command("files")
		elseif run == "refresh" then
			S.changed(pcx)
		elseif run == "hide" then
			S.hide_side(pcx)
		end
	end)
end

-- Every command with its effective chord; choosing one runs it.
local function shortcuts(cx: WindowCx)
	local items: { PickItem } = {}
	local map = S.chords(cx)
	for _, def in S.COMMANDS do
		local chord = map[def.id]
		table.insert(items, {
			label = def.title,
			detail = if chord then table.concat(S.keycaps(chord :: string)) else nil,
			icon = def.icon,
			id = def.id,
		})
	end
	ask_pick(cx, { items = items, placeholder = "Keyboard shortcuts", icon = "help", action = "run" }, function(item, pcx)
		pcx:action(action_id((item :: any).id))
	end)
end

local function help_picker(cx: WindowCx)
	ask_pick(cx, {
		items = {
			{ label = "Keyboard shortcuts", icon = "help", run = "keys" },
			{ label = "Open README", detail = "what the sidebar does and its limits", icon = "doc", run = "readme" },
			{ label = "Refresh", icon = "refresh", run = "refresh" },
		},
		placeholder = "Help",
		icon = "help",
		action = "run",
	}, function(item, pcx)
		local run = (item :: any).run
		if run == "keys" then
			shortcuts(pcx)
		elseif run == "readme" then
			pcx:open(tern.plugin.dir .. "/README.md")
		else
			S.changed(pcx)
		end
	end)
end

-- Installs this module's functions into the context.
return function(ctx: core.Ctx)
	S = ctx
	S.cleanup = cleanup
	S.focused_agent = focused_agent
	S.help_picker = help_picker
	S.next_waiting = next_waiting
	S.options = options
	S.orca_keys_bound = orca_keys_bound
	S.release_orca_keys = release_orca_keys
	S.reveal_active = reveal_active
	S.search = search
	S.settings_picker = settings_picker
	S.step_agent = step_agent
	S.toggle_activity = toggle_activity
	S.use_orca_keys = use_orca_keys
end
