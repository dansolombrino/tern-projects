--!strict
-- projects, events: what the window's event hooks, sidebar clicks and status segment do, and the start of a plugin
-- run (`init`). window.luau registers the hooks at load and calls these once its modules have loaded (a hook
-- arriving earlier is queued until then), so this file is compiled in a timer callback, not in the load.

local model = require("./model")
local sidebar = require("./sidebar")
local core = require("./core")
local budget = require("./budget")
local ID = core.ID
local TOGGLE = core.TOGGLE
local defer = core.defer
local firstline = core.firstline
local short = core.short

local S: core.Ctx = nil :: any

export type Handlers = {
	canvas_action: (ev: CanvasAction, cx: WindowCx) -> boolean?,
	agent_state: (ev: AgentStateEvent, cx: WindowCx) -> (),
	agent_finished: (ev: AgentFinishedEvent, cx: WindowCx) -> (),
	focus: (ev: FocusEvent, cx: WindowCx) -> (),
	pane_created: (ev: PaneEvent, cx: WindowCx) -> (),
	cwd: (ev: CwdEvent, cx: WindowCx) -> (),
	pane_closed: (ev: PaneEvent, cx: WindowCx) -> (),
	session_ended: (ev: SessionEndedEvent, cx: WindowCx) -> (),
	init: (cx: WindowCx) -> (),
	status: (pane: StatusPaneInfo) -> { StatusSegment }?,
}

local H = {} :: Handlers

local function project_arg(value: string?): model.Project?
	return if value then model.get(model.load(), value) else nil
end

function H.canvas_action(ev: CanvasAction, cx: WindowCx): boolean?
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
		if act == "fleet_focus" then
			S.fleet_focus(cx, pane)
		elseif act == "focus" then
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
			-- A remote agent's folder opens as a shell on its host.
			S.open_in_finder(cx, S.cwd_of(pane), S.agent_host(cx, pane))
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
	if act == "fleet_group" and value then
		S.fleet_group(cx, value)
	elseif act == "open_url" and value then
		S.open_url(cx, value)
	elseif act == "gh_refresh" and value then
		S.gh_refresh(cx, value)
	elseif act == "toggle_prs" and value then
		S.toggle_prs(cx, value)
	elseif act == "auto_run" and value then
		S.auto_run(cx, value)
	elseif act == "auto_toggle" and value then
		S.auto_toggle(cx, value)
	elseif act == "auto_open" and value then
		S.auto_open(cx, value)
	elseif act == "auto_runs" and value then
		S.auto_runs(cx, value)
	elseif act == "auto_new" then
		S.auto_new(cx)
	elseif act == "auto_edit" then
		S.auto_edit(cx)
	elseif act == "new_agent" then
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
end

-- An agent the user isn't looking at that finished or needs input is unread until focused or marked read.
local function mark_unread(cx: WindowCx, pane: number)
	if S.main_pane(cx, S.side_pane) ~= pane then
		S.set_unread(core.key_of(pane), true)
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

-- Event hooks stay small (budget.luau): they note what happened from the last scan's cache and leave the scan,
-- reads and drawing to labelled timer callbacks (`S.changed`).
function H.agent_state(ev: AgentStateEvent, cx: WindowCx)
	S.last_activity[ev.pane] = os.time()
	local b = S.blocks[ev.pane]
	if b then
		b.state = ev.new
	end
	if ev.new == "working" then
		S.results[ev.pane] = nil
		S.prompt_stale[ev.pane] = true
	end
	if ev.new == "waiting_input" and ev.old ~= "waiting_input" and S.main_pane(cx, S.side_pane) ~= ev.pane then
		mark_unread(cx, ev.pane)
		cx:toast("info", who(ev.pane) .. " needs input", last_line(ev.pane))
	end
	S.mail_state(ev.pane, ev.old, ev.new)
	S.auto_state(ev.pane, ev.new)
	S.changed(cx)
end

function H.agent_finished(ev: AgentFinishedEvent, cx: WindowCx)
	if ev.result ~= "done" and ev.result ~= "failed" then
		S.changed(cx)
		return
	end
	S.auto_finished(ev.pane, ev.result)
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
	if reports then
		budget.later("report_back", 0, function(dcx)
			S.report_back(dcx, ev.pane, ev.result, 0)
		end)
	end
	S.changed(cx)
end

-- Focus moved: the focused agent is read, and the sidebar follows the user to another tab or session.
function H.focus(ev: FocusEvent, cx: WindowCx)
	local side = S.find_side(cx)
	if ev.pane == side then
		-- Focus lands on the sidebar when it is left alone in its tab.
		S.rehome_side(cx)
		return
	end
	S.last_main = ev.pane
	S.fleet_focused(ev.pane)
	S.clear_unread(if S.card_pane(ev.pane) == ev.pane then S.unread_keys(ev.pane) else { core.key_of(ev.pane) })
	-- (Parked while shown: it waited for a tab with a pane to work in.)
	if side and S.ui.visible and (S.parked(cx, side) or cx.session:tab_of(side) ~= ev.tab) then
		S.show_side(cx)
	end
	S.redraw_soon()
end

function H.pane_created(_ev: PaneEvent, _cx: WindowCx)
	S.layout_dirty = true
end

function H.cwd(ev: CwdEvent, cx: WindowCx)
	if S.blocks[ev.pane] then
		S.changed(cx)
	end
end

function H.pane_closed(ev: PaneEvent, cx: WindowCx)
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
	local key = core.key_of(ev.pane)
	local meta = S.state.agents[key]
	if meta and meta.worktree and meta.parent == nil then
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
		S.ui = model.load_ui()
		if S.ui.pinned[key] or S.ui.unread[key] then
			S.ui.pinned[key], S.ui.unread[key] = nil, nil
			S.save_ui()
		end
	end
	S.pane_key[ev.pane] = nil
	S.interrupted[key] = nil
	S.reported[ev.pane] = nil
	S.changed(cx)
	-- The layout may still hold the closed pane: then look again on the next turn.
	if not S.rehome_side(cx) then
		defer(function(dcx)
			S.rehome_side(dcx)
		end)
	end
end

function H.session_ended(_ev: SessionEndedEvent, cx: WindowCx)
	S.changed(cx)
end

-- Once per plugin run, when the modules have loaded (window.luau).
function H.init(cx: WindowCx)
	S.ui = model.load_ui()
	S.state = model.load()
	if model.migrate_ui(S.ui, S.state) then
		S.save_ui()
	end
	S.mail_start()
	S.changed(cx)
	-- A plugin load, reload or window relaunch never opens a sidebar: it takes up the one that exists (closing any
	-- extra), once the canvas replica has caught up, and only the user's toggle opens a new one.
	budget.later("adopt sidebar", 1500, function(acx)
		local side = S.find_side(acx)
		if side == nil then
			return
		end
		if S.ui.visible then
			S.show_side(acx)
		elseif not S.parked(acx, side) then
			-- Shown by an earlier run that didn't persist it: keep it live.
			S.redraw_soon()
			S.start_ticker()
		end
	end)
	-- A relaunched window can list another canvas late: look again once.
	budget.later("dedupe sidebar", 6000, S.dedupe_side)
end

-- Pure: reads only the caches `scan` fills, which calls tern.chrome.refresh() on change.
-- Always shows one segment, so the sidebar is one click away from any pane: the focused
-- pane's project with its counts, else "Projects" with the waiting count across all projects.
function H.status(pane: StatusPaneInfo): { StatusSegment }?
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

return function(ctx: core.Ctx): Handlers
	S = ctx
	return H
end
