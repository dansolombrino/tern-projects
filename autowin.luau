--!strict
-- projects, automations in a window (README "Automations"): reads the model the host half writes
-- (`<data>/autos.json`, autohost.luau) when its signature changed, gives the sidebar its Automations section,
-- starts pane runs' agents (the first window watching the mailbox does, the same leader that delivers mail), tells
-- the host when a pane run's turn ended, and runs the section's and palette's actions (run now, enable, open output,
-- history, stop, new automation, edit the definitions file).
--
-- Every request to the host goes through the spool (`auto_*` ops); the host is the only writer of the state and of
-- automations.json, except the empty template this half writes when the file does not exist yet.

local core = require("./core")
local model = require("./model")
local sched = require("./sched")
local budget = require("./budget")
local sidebar = require("./sidebar")

local S: core.Ctx = nil :: any

local DATA = tern.plugin.data
local SPOOL = DATA .. "/spool"
local VIEW = DATA .. "/autos.json"
local SIGFILE = DATA .. "/autos.sig"
local FILE = DATA .. "/automations.json"
local BYTES = 2097152
-- A pending pane run is started only this long (s) before the host gives up waiting and runs it headless.
local MARGIN = 5
-- A pane run whose agent was never seen working counts as finished once idle this long after it started (s).
local IDLE_DONE = 120
-- The session pane runs of a folder (not a project) open in.
local SESSION = "Automations"

local TEMPLATE = [[{
  "version": 1,
  "max_concurrent": 2,
  "automations": []
}
]]

local spool_seq = 0
local function spool_write(obj: { [string]: any })
	spool_seq += 1
	local name = string.format("%012d-%06d-%04x.json", os.time(), spool_seq, math.random(0, 0xffff))
	pcall(tern.fs.mkdir, SPOOL)
	tern.fs.write(SPOOL .. "/" .. name, tern.json.encode(obj))
end

-- Pane runs this window started (run id → true) and runs whose agent was seen working.
local started: { [string]: boolean } = {}
local seen_working: { [string]: boolean } = {}
-- Runs this window already reported finished.
local reported: { [string]: boolean } = {}
local starting = false
-- Sessions this window made for pane runs, until their first shell is closed.
local fresh: { [number]: boolean } = {}

local function view(): { [string]: any }?
	return S.autos
end

local function auto_of(id: string): { [string]: any }?
	local v = view()
	if v == nil then
		return nil
	end
	for _, a in v.autos or {} do
		if a.id == id then
			return a
		end
	end
	return nil
end

local start_pending: (cx: WindowCx) -> ()
local reconcile: (cx: WindowCx) -> ()

-- Re-reads autos.json (when its signature changed). A missing or half-written file keeps the last model.
local function load_autos()
	local ok, text = pcall(tern.fs.read, VIEW, BYTES)
	if not ok then
		return
	end
	local dok, doc = pcall(tern.json.decode, text)
	if not dok or type(doc) ~= "table" or doc.version ~= 1 then
		return
	end
	S.autos = doc
	S.dirty = true
	S.redraw_soon()
	for id in started do
		local still = false
		for _, p in doc.pending or {} do
			if p.run == id then
				still = true
			end
		end
		for _, p in doc.panes or {} do
			if p.run == id then
				still = true
			end
		end
		if not still then
			started[id] = nil
			seen_working[id] = nil
		end
	end
	if S.mail_leader() and #(doc.pending or {}) > 0 and not starting then
		budget.later("auto start", 0, start_pending)
	end
end

-- Checks the tiny signature file (every mailbox watcher line, about every 3 s, and on host notifies): a change
-- reloads the model in a callback of its own. The leader also reconciles running pane runs.
local function wake()
	local ok, sig = pcall(tern.fs.read, SIGFILE, 256)
	if ok and sig ~= S.auto_sig then
		S.auto_sig = sig
		budget.later("autos load", 0, function(_cx)
			load_autos()
		end)
	end
	local v = view()
	if v and S.mail_leader() and #(v.panes or {}) > 0 then
		budget.later("auto reconcile", 0, reconcile)
	end
end

-- The session a pane run opens in: its project's, else "Automations".
local function session_for(p: { [string]: any }): string
	if type(p.project) == "string" then
		local proj = model.get(model.load(), p.project)
		if proj then
			return proj.name
		end
	end
	return SESSION
end

-- Starts the oldest pending pane run's agent: in its session, without taking the user's view. Steps: make sure the
-- session exists (creating one switches to it: switch back), start the agent as a tab of the current session,
-- tell the host (same callback: a reload never starts it twice), then move it to its session and give focus back.
start_pending = function(cx: WindowCx)
	local v = view()
	if v == nil or not S.mail_leader() then
		return
	end
	local now = os.time()
	local p: { [string]: any }? = nil
	for _, it in v.pending or {} do
		if not started[it.run] and type(it.deadline) == "number" and it.deadline - now > MARGIN then
			p = it
			break
		end
	end
	if p == nil then
		return
	end
	local run = p :: { [string]: any }
	local name = session_for(run)
	local cur = cx.sessions:current()
	local target = core.session_named(cx, name)
	if target == nil then
		-- Creating a session switches to it: switch back on the next turn, then start.
		starting = true
		local made = cx.sessions:create({ name = name, cwd = run.cwd })
		fresh[made.id] = true
		core.defer(function(dcx)
			pcall(function()
				dcx.sessions:switch(cur.id)
			end)
			core.defer(function(scx)
				starting = false
				start_pending(scx)
			end)
		end)
		return
	end
	local focused = cx.session:focused()
	started[run.run] = true
	local ok, pane = pcall(function()
		return cx.agents:start({
			prompt = run.prompt,
			cwd = run.cwd,
			how = "tab",
			command = if run.model then "omp --model " .. run.model else nil,
		})
	end)
	if not ok then
		spool_write({ op = "auto_start_failed", run = run.run, error = tostring(pane) })
		return
	end
	spool_write({ op = "auto_started", run = run.run, pane = pane })
	tern.log.info("projects: automation pane run started", run.run, pane)
	local title = string.format("⏱ %s #%d", run.name, run.n)
	-- Its card in the project: a record titled after the automation.
	if type(run.project) == "string" then
		S.state = model.load()
		local key = model.new_key()
		S.state.agents[key] = {
			project = run.project,
			title = title,
			task = run.prompt,
			started = os.time(),
			pane = pane,
			cwd = run.cwd,
		}
		model.save(S.state)
		S.pane_key[pane] = key
	end
	core.defer(function(mcx)
		local tab = mcx.session:tab_of(pane)
		if tab then
			mcx.layout:name_tab(tab, title)
		end
		local t = target :: ManagedSession
		if not t.current then
			pcall(function()
				mcx.layout:move_to_new_tab(pane, t.id, { focus = false })
			end)
		end
		if fresh[t.id] then
			-- The session made for it: its first shell gives way to the agent (as a new agent's session does).
			fresh[t.id] = nil
			core.defer(function(ccx)
				for _, s in ccx.session:sessions() do
					if s.id == t.id then
						for _, info in ccx.session:panes() do
							if info.pane ~= pane and info.kind == "terminal" and info.tab and table.find(s.tabs, info.tab) then
								ccx.layout:close(info.pane)
							end
						end
					end
				end
			end)
		end
		-- Orca's terminal retention: an automation keeps its latest run's pane; older finished ones close
		-- (unless focused or working again).
		local a = auto_of(run.auto)
		for _, r in (if a then a.runs else nil) or {} do
			local b = if type(r.pane) == "number" then S.blocks[r.pane] else nil
			if r.mode == "pane" and b and r.pane ~= pane and r.pane ~= focused and not sidebar.auto_active(r.status) and b.state ~= "working" then
				pcall(function()
					mcx.agents:stop(r.pane)
				end)
			end
		end
		if focused and focused ~= pane then
			pcall(function()
				mcx.layout:focus(focused :: number)
			end)
		end
		-- A new agent pane holds the window's UI thread for a while (tabs, its process): rescan once that settled,
		-- not in the middle of it (a scan there was measured at 400 ms of wall time).
		budget.later("auto settle", 1500, function(scx)
			S.changed(scx)
		end)
		-- More waiting: the next one on a later turn.
		budget.later("auto start", 1500, start_pending)
	end)
end

local function finished(run: string, result: string, text: string?)
	if reported[run] then
		return
	end
	reported[run] = true
	spool_write({ op = "auto_finished", run = run, result = result, text = text })
end

-- Whether a pane run's turn is over, from its transcript (one read, in a callback of its own): its last message is
-- the answer to the run's prompt. A new omp's own start-up can report a turn end (and idle) before the prompt is
-- even sent, so state alone is not enough. An agent idle with no answer IDLE_DONE after the run started is done
-- too (with no summary).
local function check_done(pane: number, run: string, started: number?, result: string)
	if reported[run] then
		return
	end
	budget.later("auto result", 0, function(rcx)
		local ok, msgs = pcall(function()
			return rcx.agents:transcript(pane, { last = 2 })
		end)
		local last = if ok and #msgs > 0 then msgs[#msgs] else nil
		if last and last.role == "assistant" and not core.blank(last.text) then
			finished(run, result, last.text)
		elseif started and os.time() - started > IDLE_DONE then
			finished(run, result, nil)
		end
	end)
end

-- A pane run's agent ended its turn (window.luau's agent_finished).
local function on_finished(pane: number, result: string)
	local v = view()
	if v == nil then
		return
	end
	for _, p in v.panes or {} do
		if p.pane == pane then
			check_done(pane, p.run, p.started, if result == "failed" then "failed" else "done")
		end
	end
end

local function on_state(pane: number, new: string)
	local v = view()
	if v == nil or new ~= "working" then
		return
	end
	for _, p in v.panes or {} do
		if p.pane == pane then
			seen_working[p.run] = true
		end
	end
end

-- The leader's check of running pane runs (an agent_finished missed while reloading, or in no window): an agent
-- now idle after it worked (or long after it started) may have finished its turn: its transcript says.
reconcile = function(cx: WindowCx)
	local v = view()
	if v == nil or #(v.panes or {}) == 0 then
		return
	end
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if not ok then
		return
	end
	local by: { [number]: AgentBlock } = {}
	for _, b in list do
		by[b.pane] = b
	end
	local now = os.time()
	for _, p in v.panes do
		local b = by[p.pane]
		if b then
			if b.state == "working" then
				seen_working[p.run] = true
			elseif b.state == "idle" or b.state == "exited" then
				if seen_working[p.run] or (type(p.started) == "number" and now - p.started > IDLE_DONE) then
					check_done(p.pane, p.run, p.started, "done")
				end
			end
		end
	end
end

-- Sidebar --------------------------------------------------------------------------

local function snap(): sidebar.AutoSnap?
	local v = view()
	local ui = S.ui
	local list: { sidebar.AutoRow } = {}
	local running = 0
	for _, a in (if v then v.autos else nil) or {} do
		local runs = a.runs or {}
		local active: { [string]: any }? = nil
		local last: { [string]: any }? = nil
		-- Newest first: the active run (at most one per automation) and the latest finished one.
		for _, r in runs do
			if sidebar.auto_active(r.status) then
				active = active or r
			else
				last = last or r
			end
		end
		if active then
			running += 1
		end
		table.insert(list, {
			id = a.id,
			name = a.name,
			enabled = a.enabled == true,
			label = a.label,
			run_in = a.run_in,
			next_at = a.next_at,
			active = active,
			last = last,
		})
	end
	return {
		list = list,
		errors = if v then v.errors or {} else {},
		open = not ui.collapsed.automations,
		running = running,
	}
end

-- Actions ----------------------------------------------------------------------------

local function run_now(cx: WindowCx, id: string)
	local a = auto_of(id)
	spool_write({ op = "auto_run", id = id })
	cx:toast("info", "Running " .. (if a then a.name else id) .. " now")
end

local function toggle(cx: WindowCx, id: string)
	local a = auto_of(id)
	if a == nil then
		return
	end
	spool_write({ op = "auto_enable", id = id, enabled = not a.enabled })
	cx:toast("info", (if a.enabled then "Paused " else "Enabled ") .. a.name)
end

local function open_run(cx: WindowCx, r: { [string]: any })
	if r.mode == "pane" and type(r.pane) == "number" and S.blocks[r.pane] then
		S.goto_pane(cx, r.pane)
		return
	end
	if type(r.out) == "string" and tern.fs.exists(r.out) then
		cx.docs:open(r.out, { how = "tab" })
		return
	end
	cx:toast("info", "No output for run " .. tostring(r.id), r.summary)
end

-- Opens the latest run with output (a pane, or a headless run's output file).
local function open_last(cx: WindowCx, id: string)
	local a = auto_of(id)
	if a == nil then
		return
	end
	for _, r in a.runs or {} do
		if r.out or r.pane then
			open_run(cx, r)
			return
		end
	end
	cx:toast("info", "No runs of " .. a.name .. " yet")
end

local function when(t: number?): string
	return if t then os.date("%a %H:%M", t) :: string else "-"
end

-- A run's history: pick one to open it (or stop it, while it runs).
local function runs_picker(cx: WindowCx, id: string)
	local a = auto_of(id)
	if a == nil then
		return
	end
	local items: { PickItem } = {}
	for _, r in a.runs or {} do
		local label = string.format("#%d  %s", r.n, sidebar.AUTO_LABEL[r.status] or r.status)
		if r.count and r.count > 1 then
			label ..= string.format(" ×%d", r.count)
		end
		local active = sidebar.auto_active(r.status)
		table.insert(items, {
			label = label,
			detail = string.format("%s · %s%s", r.trigger, when(r.started or r.scheduled_for), if r.summary then " · " .. r.summary else ""),
			icon = if active then "refresh" elseif r.status == "done" then "doc" else "x",
			run = r.id,
		})
		if active then
			table.insert(items, { label = string.format("Stop run #%d", r.n), icon = "x", stop = r.id })
		end
	end
	table.insert(items, { label = "Run now", icon = "rocket", now = true })
	table.insert(items, { label = if a.enabled then "Pause (disable)" else "Enable", icon = "settings", toggle = true })
	table.insert(items, { label = "Edit automations.json", icon = "doc", edit = true })
	core.ask_pick(cx, {
		items = items,
		placeholder = string.format("%s · %s · %s", a.name, a.label, if a.enabled then "next " .. when(a.next_at) else "paused"),
		icon = "list",
	}, function(item, pcx)
		if item.now then
			run_now(pcx, id)
		elseif item.toggle then
			toggle(pcx, id)
		elseif item.edit then
			S.auto_edit(pcx)
		elseif item.stop then
			spool_write({ op = "auto_stop", run = item.stop })
			pcx:toast("info", "Stopping run " .. item.stop)
		elseif item.run then
			for _, r in a.runs or {} do
				if r.id == item.run then
					open_run(pcx, r)
				end
			end
		end
	end)
end

local function pick_auto(cx: WindowCx, placeholder: string, fn: (cx: WindowCx, id: string) -> ())
	local v = view()
	local items: { PickItem } = {}
	for _, a in (if v then v.autos else nil) or {} do
		table.insert(items, { label = a.name, detail = a.label .. (if a.enabled then "" else " · paused"), icon = "list", auto = a.id })
	end
	if #items == 0 then
		cx:toast("info", "No automations yet", "Projects: New automation")
		return
	end
	core.ask_pick(cx, { items = items, placeholder = placeholder, icon = "list" }, function(item, pcx)
		fn(pcx, item.auto)
	end)
end

-- Opens the definitions file in a Tern document tab (writing the empty template first when it does not exist).
local function edit_file(cx: WindowCx)
	if not tern.fs.exists(FILE) then
		pcall(tern.fs.write, FILE, TEMPLATE)
	end
	cx.docs:open(FILE, { how = "tab" })
end

-- New automation: name, schedule, prompt, where, how; the host appends it to automations.json.
local function new_auto(cx: WindowCx)
	core.ask_text(cx, { placeholder = "Automation name (e.g. Nightly review)", icon = "sparkle", action = "next" }, function(name, ncx)
		local function ask_schedule(scx: WindowCx, value: string?)
			core.ask_text(scx, {
				placeholder = "Schedule: every 30m · hourly · daily 09:00 · weekdays 09:00 · weekly mon 09:00 · cron 0 9 * * 1-5",
				value = value or "daily 09:00",
				icon = "list",
				action = "next",
			}, function(schedule, s2cx)
				local spec = string.gsub(schedule, "^cron%s+", "")
				local rule, err = sched.parse(spec)
				if rule == nil then
					s2cx:toast("error", "Not a schedule", err)
					ask_schedule(s2cx, schedule)
					return
				end
				core.ask_text(s2cx, { placeholder = "Prompt for the agent", icon = "sparkle", action = "next" }, function(prompt, pcx)
					S.state = model.load()
					local items: { PickItem } = {}
					for _, p in S.state.projects do
						table.insert(items, { label = p.name, detail = core.tilde(p.root), icon = "folder", project = p.id })
					end
					local _, fcwd = core.focused_cwd(pcx)
					if fcwd then
						table.insert(items, { label = "Focused pane's folder", detail = core.tilde(fcwd :: string), icon = "folder-open", cwd = fcwd })
					end
					if #items == 0 then
						pcx:toast("error", "No project or folder", "Add a project or focus a pane in the folder first")
						return
					end
					core.ask_pick(pcx, { items = items, placeholder = "Where it runs", icon = "folder" }, function(where, wcx)
						core.ask_pick(wcx, {
							items = {
								{ label = "Headless (omp -p)", detail = "output saved; runs with no window open", icon = "terminal", mode = "headless" },
								{ label = "In a pane", detail = "an agent tab in the project's session; headless when no window is open", icon = "agent", mode = "pane" },
							},
							placeholder = "How it runs",
							icon = "agent",
						}, function(how, hcx)
							spool_write({
								op = "auto_create",
								def = {
									name = name,
									enabled = true,
									schedule = spec,
									run_in = how.mode,
									project = where.project,
									cwd = where.cwd,
									prompt = prompt,
								},
							})
							hcx:toast("success", "Automation " .. name .. " added", rule.label .. " · edit the rest in automations.json")
						end)
					end)
				end)
			end)
		end
		ask_schedule(ncx, nil)
	end)
end

return function(ctx: core.Ctx)
	S = ctx
	S.autos = nil
	S.auto_sig = nil
	S.load_autos = load_autos
	S.auto_wake = wake
	S.auto_snap = snap
	S.auto_finished = on_finished
	S.auto_state = on_state
	S.auto_run = run_now
	S.auto_toggle = toggle
	S.auto_open = open_last
	S.auto_runs = runs_picker
	S.auto_edit = edit_file
	S.auto_new = new_auto
	S.auto_pick = pick_auto
end
