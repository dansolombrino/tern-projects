--!strict
-- projects, automations in a window (README "Automations"): reads the model the host half writes
-- (`<data>/autos.json`, autohost.luau) when its signature changed, gives the sidebar its Automations section,
-- starts pane runs' agents (the first window watching the mailbox does, the same leader that delivers mail), tells
-- the host when a pane run's turn ended, and runs the section's and palette's actions (run now, enable, open output,
-- history, stop, new automation, edit the definitions file).
--
-- Every request to the host goes through the spool (`auto_*` ops); the host is the only writer of the state and of
-- automations.json, except the empty template this half writes when the file does not exist yet.
--
-- Remote hosts' automations (their bridge's autos node, remote.luau) show after this machine's, each row tagged
-- with its host (sidebar id `<host>|<id>`); their requests go to that host. A remote pane run is started only by
-- that host's leader window while that host is current (its pane ids are the host's: mapped both ways); otherwise
-- the host runs it headless after its 20 s wait.

local core = require("./core")
local model = require("./model")
local sched = require("./sched")
local budget = require("./budget")
local sidebar = require("./sidebar")
local rp = require("./remotepure")

local S: core.Ctx = nil :: any

local DATA = tern.plugin.data
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

-- Pane runs this window started and runs whose agent was seen working, by `rp.join_id(host, run)`.
local started: { [string]: boolean } = {}
local seen_working: { [string]: boolean } = {}
-- Runs this window already reported finished (same keys).
local reported: { [string]: boolean } = {}
local starting = false
-- Sessions this window made for pane runs, until their first shell is closed.
local fresh: { [number]: boolean } = {}

-- The model of `host` (nil: this machine's).
local function view_of(host: string?): { [string]: any }?
	if host == nil then
		return S.autos
	end
	local R = S.remote[host]
	local v = if R then R.autos else nil
	return if type(v) == "table" and v.version == 1 then v else nil
end

-- Every model shown, this machine's first.
local function views(): { { host: string?, v: { [string]: any } } }
	local out = {}
	if S.autos then
		table.insert(out, { host = nil, v = S.autos })
	end
	for host in S.remote do
		local v = view_of(host)
		if v then
			table.insert(out, { host = host, v = v })
		end
	end
	return out
end

-- Whether this window starts and watches `host`'s pane runs: the mail leader here; that host's leader while it is
-- the current host there.
local function runs_here(host: string?): boolean
	if host == nil then
		return S.mail_leader()
	end
	local R = S.remote[host]
	return R ~= nil and R.current and S.remote_leader(host)
end

-- A model's pane id as this window's.
local function wp(host: string?, pane: any): number?
	if type(pane) ~= "number" then
		return nil
	end
	return if host then S.wpane(host, pane) else pane
end

-- The automation a sidebar id names, and its host.
local function auto_of(sid: string): ({ [string]: any }?, string?)
	local host, id = rp.split_id(sid)
	local v = view_of(host)
	if v == nil then
		return nil, host
	end
	for _, a in v.autos or {} do
		if a.id == id then
			return a, host
		end
	end
	return nil, host
end

local start_pending: (cx: WindowCx) -> ()
local reconcile: (cx: WindowCx) -> ()

-- Forgets pane runs of `host` this window started once its model no longer lists them.
local function forget_started(host: string?, doc: { [string]: any })
	for key in started do
		local khost, id = rp.split_id(key)
		if khost == host then
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
				started[key] = nil
				seen_working[key] = nil
			end
		end
	end
end

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
	forget_started(nil, doc)
	if S.mail_leader() and #(doc.pending or {}) > 0 and not starting then
		budget.later("auto start", 0, start_pending)
	end
end

-- A remote host's autos node changed (remote.luau).
local function autos_remote(host: string)
	local v = view_of(host)
	if v == nil then
		return
	end
	S.dirty = true
	S.redraw_soon()
	forget_started(host, v)
	if runs_here(host) and #(v.pending or {}) > 0 and not starting then
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
	for _, e in views() do
		if runs_here(e.host) and #(e.v.panes or {}) > 0 then
			budget.later("auto reconcile", 0, reconcile)
			break
		end
	end
	-- A remote pending run waits for its host to be current: look again now and then.
	for host in S.remote do
		local v = view_of(host)
		if v and #(v.pending or {}) > 0 and runs_here(host) and not starting then
			budget.later("auto start", 0, start_pending)
			break
		end
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
-- A remote host's run starts only while that host is current (sessions and agents start on the current host).
start_pending = function(cx: WindowCx)
	local now = os.time()
	local p: { [string]: any }? = nil
	local host: string? = nil
	for _, e in views() do
		if runs_here(e.host) then
			for _, it in e.v.pending or {} do
				if not started[rp.join_id(e.host, it.run)] and type(it.deadline) == "number" and it.deadline - now > MARGIN then
					p = it
					host = e.host
					break
				end
			end
		end
		if p then
			break
		end
	end
	if p == nil then
		return
	end
	if host and core.host_now(cx) ~= host then
		return
	end
	local run = p :: { [string]: any }
	local name = session_for(run)
	local cur = cx.sessions:current()
	local target = core.session_named(cx, name, host)
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
	started[rp.join_id(host, run.run)] = true
	local ok, pane = pcall(function()
		return cx.agents:start({
			prompt = run.prompt,
			cwd = run.cwd,
			how = "tab",
			command = if run.model then "omp --model " .. run.model else nil,
		})
	end)
	if not ok then
		core.spool_on(S, host, { op = "auto_start_failed", run = run.run, error = tostring(pane) })
		return
	end
	-- The host knows its panes by its own ids.
	core.spool_on(S, host, { op = "auto_started", run = run.run, pane = if host then S.remote_hpane(host, pane) else pane })
	tern.log.info("projects: automation pane run started", run.run, pane, host)
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
		local a = auto_of(rp.join_id(host, run.auto))
		for _, r in (if a then a.runs else nil) or {} do
			local rpane = wp(host, r.pane)
			local b = if rpane then S.blocks[rpane :: number] else nil
			if r.mode == "pane" and b and rpane ~= pane and rpane ~= focused and not sidebar.auto_active(r.status) and b.state ~= "working" then
				pcall(function()
					mcx.agents:stop(rpane :: number)
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

local function finished(host: string?, run: string, result: string, text: string?)
	local key = rp.join_id(host, run)
	if reported[key] then
		return
	end
	reported[key] = true
	core.spool_on(S, host, { op = "auto_finished", run = run, result = result, text = text })
end

-- Whether a pane run's turn is over, from its transcript (one read, in a callback of its own): its last message is
-- the answer to the run's prompt. A new omp's own start-up can report a turn end (and idle) before the prompt is
-- even sent, so state alone is not enough. An agent idle with no answer IDLE_DONE after the run started is done
-- too (with no summary). `pane` is this window's id.
local function check_done(host: string?, pane: number, run: string, started: number?, result: string)
	if reported[rp.join_id(host, run)] then
		return
	end
	budget.later("auto result", 0, function(rcx)
		local ok, msgs = pcall(function()
			return rcx.agents:transcript(pane, { last = 2 })
		end)
		local last = if ok and #msgs > 0 then msgs[#msgs] else nil
		if last and last.role == "assistant" and not core.blank(last.text) then
			finished(host, run, result, last.text)
		elseif started and os.time() - started > IDLE_DONE then
			finished(host, run, result, nil)
		end
	end)
end

-- A pane run's agent ended its turn (window.luau's agent_finished).
local function on_finished(pane: number, result: string)
	for _, e in views() do
		for _, p in e.v.panes or {} do
			if wp(e.host, p.pane) == pane then
				check_done(e.host, pane, p.run, p.started, if result == "failed" then "failed" else "done")
			end
		end
	end
end

local function on_state(pane: number, new: string)
	if new ~= "working" then
		return
	end
	for _, e in views() do
		for _, p in e.v.panes or {} do
			if wp(e.host, p.pane) == pane then
				seen_working[rp.join_id(e.host, p.run)] = true
			end
		end
	end
end

-- The leader's check of running pane runs (an agent_finished missed while reloading, or in no window): an agent
-- now idle after it worked (or long after it started) may have finished its turn: its transcript says.
reconcile = function(cx: WindowCx)
	local todo = {}
	for _, e in views() do
		if runs_here(e.host) and #(e.v.panes or {}) > 0 then
			table.insert(todo, e)
		end
	end
	if #todo == 0 then
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
	for _, e in todo do
		for _, p in e.v.panes do
			local pane = wp(e.host, p.pane)
			local b = if pane then by[pane :: number] else nil
			local key = rp.join_id(e.host, p.run)
			if b then
				if b.state == "working" then
					seen_working[key] = true
				elseif b.state == "idle" or b.state == "exited" then
					if seen_working[key] or (type(p.started) == "number" and now - p.started > IDLE_DONE) then
						check_done(e.host, pane :: number, p.run, p.started, "done")
					end
				end
			end
		end
	end
end

-- Sidebar --------------------------------------------------------------------------

local function snap(): sidebar.AutoSnap?
	local ui = S.ui
	local list: { sidebar.AutoRow } = {}
	local errors: { string } = {}
	local running = 0
	local all = views()
	if #all == 0 then
		all = { { host = nil, v = {} :: { [string]: any } } }
	end
	for _, e in all do
		local v = e.v
		local tag = if e.host then " · " .. (model.host_short(e.host) or e.host :: string) else ""
		for _, a in v.autos or {} do
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
				id = rp.join_id(e.host, a.id),
				name = a.name .. tag,
				enabled = a.enabled == true,
				label = a.label,
				run_in = a.run_in,
				next_at = a.next_at,
				active = active,
				last = last,
			})
		end
		for _, err in v.errors or {} do
			table.insert(errors, if e.host then (model.host_short(e.host) or e.host :: string) .. ": " .. err else err)
		end
	end
	return {
		list = list,
		errors = errors,
		open = not ui.collapsed.automations,
		running = running,
	}
end

-- Actions ----------------------------------------------------------------------------

local function run_now(cx: WindowCx, sid: string)
	local a, host = auto_of(sid)
	local _, id = rp.split_id(sid)
	core.spool_on(S, host, { op = "auto_run", id = id })
	cx:toast("info", "Running " .. (if a then a.name else id) .. " now")
end

local function toggle(cx: WindowCx, sid: string)
	local a, host = auto_of(sid)
	if a == nil then
		return
	end
	core.spool_on(S, host, { op = "auto_enable", id = a.id, enabled = not a.enabled })
	cx:toast("info", (if a.enabled then "Paused " else "Enabled ") .. a.name)
end

-- Opens a file of `host` (nil: this machine) in a Tern tab; a remote file opens only while its host is current
-- (Tern opens paths on the current host).
local function open_file(cx: WindowCx, host: string?, path: string)
	if host == nil then
		cx.docs:open(path, { how = "tab" })
	elseif core.host_now(cx) == host then
		cx:open(path)
	else
		cx:toast("info", "Switch to " .. (model.host_short(host) or host :: string) .. " first", path)
	end
end

local function open_run(cx: WindowCx, r: { [string]: any }, host: string?)
	local pane = wp(host, r.pane)
	if r.mode == "pane" and pane and S.blocks[pane :: number] then
		S.goto_pane(cx, pane :: number)
		return
	end
	if type(r.out) == "string" and (host ~= nil or tern.fs.exists(r.out)) then
		open_file(cx, host, r.out)
		return
	end
	cx:toast("info", "No output for run " .. tostring(r.id), r.summary)
end

-- Opens the latest run with output (a pane, or a headless run's output file).
local function open_last(cx: WindowCx, sid: string)
	local a, host = auto_of(sid)
	if a == nil then
		return
	end
	for _, r in a.runs or {} do
		if r.out or r.pane then
			open_run(cx, r, host)
			return
		end
	end
	cx:toast("info", "No runs of " .. a.name .. " yet")
end

local function when(t: number?): string
	return if t then os.date("%a %H:%M", t) :: string else "-"
end

-- A run's history: pick one to open it (or stop it, while it runs).
local function runs_picker(cx: WindowCx, sid: string)
	local a, host = auto_of(sid)
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
	local where = if host then " · " .. (model.host_short(host) or host :: string) else ""
	core.ask_pick(cx, {
		items = items,
		placeholder = string.format("%s%s · %s · %s", a.name, where, a.label, if a.enabled then "next " .. when(a.next_at) else "paused"),
		icon = "list",
	}, function(item, pcx)
		if item.now then
			run_now(pcx, sid)
		elseif item.toggle then
			toggle(pcx, sid)
		elseif item.edit then
			S.auto_edit(pcx, host)
		elseif item.stop then
			core.spool_on(S, host, { op = "auto_stop", run = item.stop })
			pcx:toast("info", "Stopping run " .. item.stop)
		elseif item.run then
			for _, r in a.runs or {} do
				if r.id == item.run then
					open_run(pcx, r, host)
				end
			end
		end
	end)
end

local function pick_auto(cx: WindowCx, placeholder: string, fn: (cx: WindowCx, id: string) -> ())
	local items: { PickItem } = {}
	for _, e in views() do
		local tag = if e.host then " · " .. (model.host_short(e.host) or e.host :: string) else ""
		for _, a in e.v.autos or {} do
			table.insert(items, { label = a.name, detail = a.label .. (if a.enabled then "" else " · paused") .. tag, icon = "list", auto = rp.join_id(e.host, a.id) })
		end
	end
	if #items == 0 then
		cx:toast("info", "No automations yet", "Projects: New automation")
		return
	end
	core.ask_pick(cx, { items = items, placeholder = placeholder, icon = "list" }, function(item, pcx)
		fn(pcx, item.auto)
	end)
end

-- Opens the definitions file in a Tern document tab (writing the empty template first when it does not exist). A
-- remote host's file (the path its model names) opens while that host is current.
local function edit_file(cx: WindowCx, host: string?)
	if host then
		local v = view_of(host)
		local path = if v and type(v.file) == "string" then v.file else nil
		if path == nil then
			cx:toast("info", "No automations from " .. (model.host_short(host) or host :: string) .. " yet")
			return
		end
		open_file(cx, host, path :: string)
		return
	end
	if not tern.fs.exists(FILE) then
		pcall(tern.fs.write, FILE, TEMPLATE)
	end
	cx.docs:open(FILE, { how = "tab" })
end

-- New automation: name, schedule, prompt, where, how; the host the place is on appends it to its automations.json.
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
						local tag = if p.host then " · " .. (model.host_short(p.host) or p.host :: string) else ""
						table.insert(items, { label = p.name, detail = core.tilde(p.root) .. tag, icon = "folder", project = p.id, host = p.host })
					end
					local fpane, fcwd = core.focused_cwd(pcx)
					if fcwd then
						local fhost = if next(S.remote) ~= nil and fpane then core.host_of_pane(pcx, fpane :: number) else nil
						table.insert(items, { label = "Focused pane's folder", detail = core.tilde(fcwd :: string), icon = "folder-open", cwd = fcwd, host = fhost })
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
							core.spool_on(S, where.host, {
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
	S.autos_remote = autos_remote
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
