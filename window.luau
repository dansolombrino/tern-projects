--!strict
-- projects, window half: projects (one named Tern session each) in project groups, omp agents per project
-- (each in a git worktree of its own when the project allows), spawned and omp-internal subagents per agent,
-- an Orca-style left sidebar (a canvas docked at the left of the current tab, shown and hidden from the title
-- bar), a status segment and toasts. This file registers commands, events and chrome and wires the modules:
-- core.luau (constants, shared state in one context table, base helpers), placement.luau (sidebar docking and
-- width), snapshot.luau (reads and drawing), agents.luau (agent flows, worktrees), projects.luau (project and
-- group flows), pickers.luau (navigation, options, settings, help). model.luau holds the data, subagents.luau
-- and sidebar.luau the pure surface reading and drawing.

local model = require("./model")
local sidebar = require("./sidebar")
local core = require("./core")
local ID = core.ID
local MACOS = core.MACOS
local MOD = core.MOD
local TOGGLE = core.TOGGLE
local defer = core.defer
local firstline = core.firstline
local short = core.short

-- The one context table every module shares; each installer adds its functions to it.
local S = core.new()
require("./placement")(S)
require("./snapshot")(S)
require("./agents")(S)
require("./projects")(S)
require("./pickers")(S)

-- Commands --------------------------------------------------------------------------------

local function with_agent(fn: (cx: WindowCx, pane: number) -> ()): (cx: WindowCx) -> ()
	return function(cx: WindowCx)
		local pane = S.focused_agent(cx)
		if pane then
			fn(cx, pane)
		end
	end
end

S.COMMANDS = {
	{ id = "toggle_sidebar", title = "Toggle sidebar", icon = "sidebar", keys = { if MACOS then "alt+cmd+b" else "ctrl+alt+b" }, run = S.toggle_side },
	{ id = "search", title = "Search agents and projects", icon = "search", keys = { MOD .. "k" }, run = S.search },
	{ id = "add", title = "Add project", icon = "folder-plus", run = S.add_project },
	{ id = "remove", title = "Remove project (keeps files)", icon = "trash", run = S.remove_project },
	{
		id = "open",
		title = "Open project",
		icon = "folder",
		keys = { MOD .. "l" },
		run = function(cx)
			S.pick_project(cx, "Project to open", S.open_project)
		end,
	},
	{ id = "new_agent", title = "New agent in project", icon = "sparkle", keys = { MOD .. "a" }, run = S.new_agent },
	{ id = "new_subagent", title = "New subagent of focused agent", icon = "sparkle", keys = { MOD .. "u" }, run = with_agent(S.new_subagent_of) },
	{ id = "next_waiting", title = "Jump to next agent waiting for input", icon = "bell", keys = { MOD .. "j" }, run = S.next_waiting },
	{
		id = "prev_agent",
		title = "Previous agent",
		icon = "arrow-left",
		keys = { MOD .. "," },
		run = function(cx)
			S.step_agent(cx, -1)
		end,
	},
	{
		id = "next_agent",
		title = "Next agent",
		icon = "arrow-down",
		keys = { MOD .. "." },
		run = function(cx)
			S.step_agent(cx, 1)
		end,
	},
	{ id = "rename", title = "Rename focused agent", icon = "agent", keys = { MOD .. "r" }, run = with_agent(S.rename_agent) },
	{ id = "delete", title = "Delete focused agent's workspace", icon = "trash", keys = { MOD .. "backspace" }, run = with_agent(S.delete_agent) },
	{ id = "collapse_all", title = "Collapse or expand all projects", icon = "list", keys = { MOD .. "p" }, run = S.collapse_all },
	{ id = "reveal", title = "Reveal active workspace", icon = "search", run = S.reveal_active },
	{ id = "cleanup", title = "Delete a sleeping workspace", icon = "trash", run = S.cleanup },
	{ id = "options", title = "Workspace options", icon = "sliders", run = S.options },
	{ id = "settings", title = "Sidebar settings", icon = "gear", run = S.settings_picker },
	{
		id = "use_orca_keys",
		title = "Use Orca shortcuts",
		icon = "settings",
		available = function(cx)
			return not S.orca_keys_bound(cx)
		end,
		run = S.use_orca_keys,
	},
	{
		id = "release_orca_keys",
		title = "Release Orca shortcuts (back to Tern's)",
		icon = "settings",
		available = S.orca_keys_bound,
		run = S.release_orca_keys,
	},
}

function S.register_commands()
	for _, def in S.COMMANDS do
		def.group = "Projects"
		tern.command(def)
	end
end
S.register_commands()

-- The title bar's Files button (moved to the leading edge by chrome.css) and ⌃⌘E toggle the sidebar.
-- Files stays on ⇧⌘E (focus_files) and the sidebar settings.
tern.override("files", function(cx: WindowCx): boolean?
	S.toggle_side(cx)
	return true
end)

-- Events ------------------------------------------------------------------------------------

local function project_arg(value: string?): model.Project?
	return if value then model.get(model.load(), value) else nil
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.owner ~= ID then
		return false
	end
	-- A click focused the sidebar: give focus back first (synchronously, so it never shows).
	S.refocus(cx, ev.pane)
	-- Real clicks arrive split at `=` (act, value); scripted events arrive whole: parse_action takes both.
	local act, parsed = sidebar.parse_action(ev)
	local pane = if type(parsed) == "number" then parsed else nil
	local value = if type(parsed) == "string" then parsed else nil
	local alt = ev.mods ~= nil and table.find(ev.mods, "alt") ~= nil
	if pane then
		if act == "focus" then
			if pane < 0 then
				S.wake(cx, pane)
			else
				S.goto_pane(cx, pane)
				S.redraw_soon()
			end
		elseif act == "wake" then
			S.wake(cx, pane)
		elseif act == "rename" then
			S.rename_agent(cx, pane)
		elseif act == "new_subagent" then
			S.new_subagent_of(cx, pane)
		elseif act == "sleep" then
			S.sleep_agent(cx, pane)
		elseif act == "delete" then
			S.delete_agent(cx, pane)
		elseif act == "toggle_unread" then
			S.toggle_unread(cx, pane)
		elseif act == "toggle_pin" then
			S.toggle_pin(cx, pane)
		elseif act == "copy_path" then
			S.copy_path(cx, pane)
		elseif act == "copy_name" then
			S.copy_name(cx, pane)
		elseif act == "open_finder" then
			S.open_in_finder(cx, S.cwd_of(pane))
		elseif act == "toggle_kids" then
			S.expanded[pane] = if S.expanded[pane] then nil else true
			S.refresh_side(cx)
		elseif act == "toggle_idle" then
			S.idle_open[pane] = if S.idle_open[pane] then nil else true
			S.refresh_side(cx)
		else
			return false
		end
		return true
	end
	if act == "new_agent" then
		S.new_agent_for(cx, value)
	elseif act == "toggle_group" and value then
		if alt then
			S.collapse_all(cx)
		else
			S.toggle_group(cx, value)
		end
	elseif act == "open_project" and project_arg(value) then
		S.open_project(cx, project_arg(value) :: model.Project)
	elseif act == "remove_project" and project_arg(value) then
		S.confirm_remove(cx, project_arg(value) :: model.Project)
	elseif act == "project_menu" and value then
		S.project_menu(cx, value)
	elseif act == "project_settings" and value then
		S.project_settings(cx, value)
	elseif act == "project_icon" and value then
		S.project_icon(cx, value)
	elseif act == "new_group" and value then
		S.new_group(cx, value)
	elseif act == "move_to_group" and value then
		S.move_to_group(cx, value)
	elseif act == "ungroup" and value then
		S.ungroup(cx, value)
	elseif act == "group_menu" and value then
		S.group_menu(cx, value)
	elseif act == "rename_group" and value then
		S.rename_group(cx, value)
	elseif act == "delete_group" and value then
		S.delete_group(cx, value)
	elseif act == "collapse_all" then
		S.collapse_all(cx)
	elseif act == "add_project" then
		S.add_project(cx)
	elseif act == "search" then
		S.search(cx)
	elseif act == "activity" then
		S.toggle_activity(cx)
	elseif act == "options" then
		S.options(cx)
	elseif act == "settings" then
		S.settings_picker(cx)
	elseif act == "help" then
		S.help_picker(cx)
	elseif act == "reveal" then
		S.reveal_active(cx)
	else
		return false
	end
	return true
end)

-- An agent the user isn't looking at that finished or needs input is unread until focused or marked read.
local function mark_unread(cx: WindowCx, pane: number)
	if S.main_pane(cx, S.side_pane) ~= pane then
		S.set_unread(tostring(pane), true)
	end
end

local function who(pane: number): string
	local b = S.blocks[pane]
	local cwd = if b then b.cwd else nil
	local p = S.project_of(pane, cwd)
	return (if p then p.name .. " · " else "") .. S.title_of(pane, cwd)
end

local function last_line(pane: number): string?
	local b = S.blocks[pane]
	return if b and b.last_message then short(firstline(b.last_message :: string), 120) else nil
end

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	S.scan(cx)
	S.last_activity[ev.pane] = os.time()
	if ev.new == "working" then
		S.results[ev.pane] = nil
		S.prompt_stale[ev.pane] = true
	end
	if ev.new == "waiting_input" and ev.old ~= "waiting_input" and S.main_pane(cx, S.side_pane) ~= ev.pane then
		mark_unread(cx, ev.pane)
		cx:toast("info", who(ev.pane) .. " needs input", last_line(ev.pane))
	end
	if S.pending[ev.pane] and ev.new ~= "working" then
		S.deliver(cx, ev.pane)
	end
	S.changed(cx, true)
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	S.scan(cx)
	if ev.result ~= "done" and ev.result ~= "failed" then
		S.changed(cx, true)
		return
	end
	local t = os.time()
	S.results[ev.pane] = { result = ev.result, at = t }
	S.last_activity[ev.pane] = t
	local meta = S.meta_of(ev.pane)
	-- A spawned subagent's result goes to its parent, which reports it (Orca's coordinator rule).
	local reports = meta ~= nil and meta.parent ~= nil and meta.report_back ~= false
	if S.main_pane(cx, S.side_pane) ~= ev.pane then
		mark_unread(cx, ev.pane)
		if not reports then
			if ev.result == "done" then
				cx:toast("success", who(ev.pane) .. " finished", last_line(ev.pane))
			else
				cx:toast("error", who(ev.pane) .. " failed", last_line(ev.pane))
			end
		end
	end
	defer(function(dcx)
		S.report_back(dcx, ev.pane, ev.result, 0)
	end)
	S.changed(cx, true)
end)

-- Focus moved: the focused agent is read, and the sidebar follows the user to another tab or session.
tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	local side = S.find_side(cx)
	if ev.pane == side then
		-- Focus lands on the sidebar when it is left alone in its tab.
		S.rehome_side(cx)
		return
	end
	S.last_main = ev.pane
	S.clear_unread(if S.card_pane(ev.pane) == ev.pane then S.unread_keys(ev.pane) else { tostring(ev.pane) })
	-- (Parked while shown: it waited for a tab with a pane to work in.)
	if side and S.ui.visible and (S.parked(cx, side) or cx.session:tab_of(side) ~= ev.tab) then
		S.show_side(cx)
	end
	S.redraw_soon()
end)

tern.on("pane_created", function(_ev: PaneEvent, _cx: WindowCx)
	S.layout_dirty = true
end)

tern.on("cwd", function(ev: CwdEvent, _cx: WindowCx)
	S.repos[ev.path] = nil
	if S.blocks[ev.pane] then
		S.redraw_soon()
	end
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if ev.pane == S.side_pane then
		S.side_pane = nil
		S.fitted = nil
		S.side_gen += 1
		return
	end
	S.layout_dirty = true
	if ev.pane == S.last_main then
		S.last_main = nil
	end
	S.state = model.load()
	local key = tostring(ev.pane)
	local meta = S.state.agents[key]
	if meta and meta.worktree then
		-- It sleeps as a card: its pin and unread mark stay, and whether it was cut off mid-turn persists.
		meta.closed = true
		meta.closed_at = os.time()
		meta.interrupted = if S.interrupted[key] then true else nil
		model.save(S.state)
	else
		if meta then
			S.state.agents[key] = nil
			model.save(S.state)
		end
		-- A later pane can get this id: drop the closed one's pin and unread mark.
		S.ui = model.load_ui()
		if S.ui.pinned[key] or S.ui.unread[key] then
			S.ui.pinned[key], S.ui.unread[key] = nil, nil
			S.save_ui()
		end
	end
	S.interrupted[key] = nil
	S.reported[ev.pane] = nil
	S.pending[ev.pane] = nil
	S.changed(cx)
	-- The layout may still hold the closed pane: then look again on the next turn.
	if not S.rehome_side(cx) then
		defer(function(dcx)
			S.rehome_side(dcx)
		end)
	end
end)

tern.on("session_ended", function(_ev: SessionEndedEvent, cx: WindowCx)
	S.changed(cx)
end)

-- Once per plugin run: at window_start, or (after a reload, which runs no window_start) on the first timer.
local started = false
local function init(cx: WindowCx)
	if started then
		return
	end
	started = true
	S.ui = model.load_ui()
	S.scan(cx)
	local side = S.find_side(cx)
	if S.ui.visible then
		S.show_side(cx)
	elseif side and not S.parked(cx, side) then
		-- Shown by an earlier run that didn't persist it: keep it live.
		S.redraw_soon()
		S.start_ticker()
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
	local id = S.pane_project[pane.pane]
	local p = if id then model.get(S.state, id) else model.project_for_path(S.state, pane.cwd)
	if p == nil then
		local waiting = 0
		for _, c in S.counts do
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
	local c = S.counts[p.id] or { working = 0, waiting = 0 }
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