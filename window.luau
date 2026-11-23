--!strict
-- projects, window half: projects (one named Tern session each) in project groups, omp agents per project
-- (each in a git worktree of its own when the project allows), spawned and omp-internal subagents per agent,
-- an Orca-style left sidebar (a canvas docked at the left of the current tab, shown and hidden from the title
-- bar), a status segment and toasts. This file registers commands, events and chrome and wires the modules:
-- core.luau (constants, shared state in one context table, base helpers), placement.luau (sidebar docking and
-- width), snapshot.luau (reads and drawing), agents.luau (agent flows, worktrees), projects.luau (project and
-- group flows), pickers.luau (navigation, options, settings, help), events.luau (what the hooks do).
-- model.luau holds the data, subagents.luau and sidebar.luau the pure surface reading and drawing.
--
-- Loading is staged (README, Budget): Tern counts `require`'s compile toward the load's 500 ms of wall time, and
-- compiling every module there took 57-62 ms in a fresh window but 240-470 ms (sometimes over 500) in one that had
-- run a while. So the load requires only base.luau and budget.luau and registers the hooks (1-14 ms); the modules
-- compile one per timer callback (`STAGES`), and a hook arriving before `init` is queued and runs, in order, right
-- after it.

local base = require("./base")
local budget = require("./budget")
local ID = base.ID
local MACOS = base.MACOS
local MOD = base.MOD

-- The context table every module shares (core.luau's `Ctx`) and events.luau's handlers: nil until loaded.
local S: any = nil
local H: any = nil
-- Hooks that arrived before H was set, run in order after `init`.
local queued: { (cx: WindowCx) -> () } = {}

-- Runs `fn(cx)` now once loaded, else queues it.
local function when(cx: WindowCx, fn: (cx: WindowCx) -> ())
	if H then
		fn(cx)
	else
		table.insert(queued, fn)
	end
end

-- Commands --------------------------------------------------------------------------------

local function call(name: string): (cx: WindowCx) -> ()
	return function(cx: WindowCx)
		when(cx, function(c)
			S[name](c)
		end)
	end
end

local function with_agent(name: string): (cx: WindowCx) -> ()
	return function(cx: WindowCx)
		when(cx, function(c)
			local pane = S.focused_agent(c)
			if pane then
				S[name](c, pane)
			end
		end)
	end
end

local COMMANDS: { CommandDef } = {
	{ id = "toggle_sidebar", title = "Toggle sidebar", icon = "sidebar", keys = { if MACOS then "alt+cmd+b" else "ctrl+alt+b" }, run = call("toggle_side") },
	{ id = "search", title = "Search agents and projects", icon = "search", keys = { MOD .. "k" }, run = call("search") },
	{ id = "add", title = "Add project", icon = "folder-plus", run = call("add_project") },
	{ id = "remove", title = "Remove project (keeps files)", icon = "trash", run = call("remove_project") },
	{
		id = "open",
		title = "Open project",
		icon = "folder",
		keys = { MOD .. "l" },
		run = function(cx)
			when(cx, function(c)
				S.pick_project(c, "Project to open", S.open_project)
			end)
		end,
	},
	{ id = "new_agent", title = "New agent in project", icon = "sparkle", keys = { MOD .. "a" }, run = call("new_agent") },
	{ id = "new_subagent", title = "New subagent of focused agent", icon = "sparkle", keys = { MOD .. "u" }, run = with_agent("new_subagent_of") },
	{ id = "next_waiting", title = "Jump to next agent waiting for input", icon = "bell", keys = { MOD .. "j" }, run = call("next_waiting") },
	{
		id = "prev_agent",
		title = "Previous agent",
		icon = "arrow-left",
		keys = { MOD .. "," },
		run = function(cx)
			when(cx, function(c)
				S.step_agent(c, -1)
			end)
		end,
	},
	{
		id = "next_agent",
		title = "Next agent",
		icon = "arrow-down",
		keys = { MOD .. "." },
		run = function(cx)
			when(cx, function(c)
				S.step_agent(c, 1)
			end)
		end,
	},
	{ id = "rename", title = "Rename focused agent", icon = "agent", keys = { MOD .. "r" }, run = with_agent("rename_agent") },
	{ id = "delete", title = "Delete focused agent's workspace", icon = "trash", keys = { MOD .. "backspace" }, run = with_agent("delete_agent") },
	{ id = "collapse_all", title = "Collapse or expand all projects", icon = "list", keys = { MOD .. "p" }, run = call("collapse_all") },
	{ id = "reveal", title = "Reveal active workspace", icon = "search", run = call("reveal_active") },
	{ id = "cleanup", title = "Delete a sleeping workspace", icon = "trash", run = call("cleanup") },
	{ id = "create_pr", title = "Create pull request for focused worktree", icon = "branch", run = call("create_pr") },
	{ id = "new_automation", title = "New automation", icon = "sparkle", run = call("auto_new") },
	{ id = "edit_automations", title = "Edit automations (automations.json)", icon = "doc", run = call("auto_edit") },
	{
		id = "automation_runs",
		title = "Automation runs",
		icon = "list",
		run = function(cx)
			when(cx, function(c)
				S.auto_pick(c, "Automation", S.auto_runs)
			end)
		end,
	},
	{
		id = "run_automation",
		title = "Run automation now",
		icon = "rocket",
		run = function(cx)
			when(cx, function(c)
				S.auto_pick(c, "Automation to run now", S.auto_run)
			end)
		end,
	},
	{ id = "options", title = "Workspace options", icon = "sliders", run = call("options") },
	{ id = "settings", title = "Sidebar settings", icon = "gear", run = call("settings_picker") },
	{
		id = "use_orca_keys",
		title = "Use Orca shortcuts",
		icon = "settings",
		available = function(cx)
			return H ~= nil and not S.orca_keys_bound(cx)
		end,
		run = call("use_orca_keys"),
	},
	{
		id = "release_orca_keys",
		title = "Release Orca shortcuts (back to Tern's)",
		icon = "settings",
		available = function(cx)
			return H ~= nil and S.orca_keys_bound(cx)
		end,
		run = call("release_orca_keys"),
	},
}

local function register_commands()
	for _, def in COMMANDS do
		def.group = "Projects"
		tern.command(def)
	end
end
register_commands()

-- The title bar's Files button (moved to the leading edge by chrome.css) and ⌃⌘E toggle the sidebar.
-- Files stays on ⇧⌘E (focus_files) and the sidebar settings.
tern.override("files", function(cx: WindowCx): boolean?
	when(cx, function(c)
		S.toggle_side(c)
	end)
	return true
end)

-- Events (events.luau) --------------------------------------------------------------------

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if H then
		return H.canvas_action(ev, cx)
	end
	if ev.owner ~= ID then
		return false
	end
	table.insert(queued, function(c)
		H.canvas_action(ev, c)
	end)
	return true
end)

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	when(cx, function(c)
		H.agent_state(ev, c)
	end)
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	when(cx, function(c)
		H.agent_finished(ev, c)
	end)
end)

tern.on("budget", function(ev: BudgetEvent, _cx: WindowCx)
	tern.log.warn(budget.describe(ev))
end)

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	when(cx, function(c)
		H.focus(ev, c)
	end)
end)

tern.on("pane_created", function(ev: PaneEvent, cx: WindowCx)
	when(cx, function(c)
		H.pane_created(ev, c)
	end)
end)

tern.on("cwd", function(ev: CwdEvent, cx: WindowCx)
	when(cx, function(c)
		H.cwd(ev, c)
	end)
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	when(cx, function(c)
		H.pane_closed(ev, c)
	end)
end)

tern.on("session_ended", function(ev: SessionEndedEvent, cx: WindowCx)
	when(cx, function(c)
		H.session_ended(ev, c)
	end)
end)

-- Until loaded, the status segment is the plain sidebar toggle `H.status` shows outside a project.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	if H then
		return H.status(pane)
	end
	return { { text = "Projects", icon = "sidebar", command = base.TOGGLE } }
end)

-- Staged loading --------------------------------------------------------------------------

-- One module compiled per timer callback, dependencies first, so each `require` compiles one file (a module
-- already loaded is cached). The largest, sidebar.luau, takes 10-125 ms of wall time, against 500.
local STAGES: { { label: string, run: (cx: WindowCx) -> () } } = {
	{ label = "load model", run = function() require("./model") end },
	{ label = "load identity", run = function() require("./identity") end },
	{ label = "load subagents", run = function() require("./subagents") end },
	{ label = "load core", run = function() require("./core") end },
	{ label = "load gh", run = function() require("./gh") end },
	{ label = "load sidebar", run = function() require("./sidebar") end },
	{ label = "load placement", run = function() require("./placement") end },
	{ label = "load snapshot", run = function() require("./snapshot") end },
	{ label = "load agents", run = function() require("./agents") end },
	{ label = "load projects", run = function() require("./projects") end },
	{ label = "load pickers", run = function() require("./pickers") end },
	{ label = "load remotepure", run = function() require("./remotepure") end },
	{ label = "load remote", run = function() require("./remote") end },
	{ label = "load mailq", run = function() require("./mailq") end },
	{ label = "load mail", run = function() require("./mail") end },
	{ label = "load fleet", run = function() require("./fleet") end },
	{ label = "load fleets", run = function() require("./fleets") end },
	{ label = "load prs", run = function() require("./prs") end },
	{ label = "load sched", run = function() require("./sched") end },
	{ label = "load autowin", run = function() require("./autowin") end },
	{ label = "load events", run = function() require("./events") end },
}
-- The stages above compile a module each; their callbacks are logged as slow only past SLOW_LOAD_MS.
local MODULE_STAGES = #STAGES

-- Then the context table and every installer (all compiled by now), `init`, and the hooks queued until then.
local handlers: any = nil
table.insert(STAGES, {
	label = "load start",
	run = function(_cx)
		S = require("./core").new()
		require("./placement")(S)
		require("./snapshot")(S)
		require("./agents")(S)
		require("./projects")(S)
		require("./pickers")(S)
		require("./remote")(S)
		require("./mail")(S)
		require("./fleets")(S)
		require("./prs")(S)
		require("./autowin")(S)
		S.COMMANDS = COMMANDS
		S.register_commands = register_commands
		handlers = require("./events")(S)
	end,
})
table.insert(STAGES, {
	label = "init",
	run = function(cx)
		-- From here hooks run directly.
		H = handlers
		handlers.init(cx)
		tern.chrome.refresh()
	end,
})
table.insert(STAGES, {
	label = "queued hooks",
	run = function(cx)
		local fns = queued
		queued = {}
		for _, fn in fns do
			fn(cx)
		end
	end,
})

-- Stages run so far, and whether one failed (budget.run logs its error; the rest don't run).
local done = 0
local broken = false

-- Runs the next stage, labelled. Every stage's timer starts at load, `i` ms out, so they run in order and several
-- per turn, each in a callback of its own (its own budget); a stage starting the next would wait a turn each, about
-- a second when the window is idle.
local function advance(cx: WindowCx?)
	if broken or done >= #STAGES then
		return
	end
	if cx == nil then
		tern.timer(0, advance)
		return
	end
	done += 1
	local s = STAGES[done]
	local ok = false
	budget.run(s.label, function(rcx: WindowCx)
		s.run(rcx)
		ok = true
	end, cx, if done <= MODULE_STAGES then budget.SLOW_LOAD_MS else nil)
	broken = not ok
end
for i = 1, #STAGES do
	tern.timer(i, advance)
end
