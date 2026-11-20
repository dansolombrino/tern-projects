--!strict
-- projects, automations in the host half (README "Automations"): the scheduler clock, the runs and their files.
--
-- - Reads `<data>/automations.json` (the definitions) when its text changed, and keeps the last good parse.
-- - Ticks every 2 s (automate.plan): due runs, missed runs (catch-up or skip), the concurrency cap.
-- - Headless runs: `omp -p` as a `tern.process.run` child through a small sh wrapper that writes the agent's pid,
--   stdout (`<data>/autoruns/<run>.md`, after a header), stderr (`<run>.err`) and finally its exit code
--   (`<run>.status`). The status file ends the run, so a run that outlives a plugin reload or a daemon upgrade
--   still ends right; a run whose agent is gone with no status file is `lost`.
-- - Pane runs wait (`waiting_window`) for a window half to start their agent in a pane (autowin.luau); with no
--   window within automate.WINDOW_WAIT seconds they run headless instead. Windows report through the spool.
-- - This half is the only writer of kv `automations.v1` and of the definitions file (enable switch, palette add).
-- - Windows read `<data>/autos.json` (automate.view) when `auto_sig` (status.json, and `<data>/autos.sig`) changed.

local automate = require("./automate")

local autohost = {}

local DATA = tern.plugin.data
local FILE = DATA .. "/automations.json"
local VIEW = DATA .. "/autos.json"
local SIGFILE = DATA .. "/autos.sig"
local RUNS = DATA .. "/autoruns"
local FILE_BYTES = 1048576
-- Output read back for a summary.
local OUT_BYTES = 262144
local HOME = tern.getenv("HOME")
-- `<config>/plugin-data/projects` → `<config>`: Tern installs omp under it.
local CONFIG = string.match(DATA, "^(.*)/plugin%-data/[^/]+$")

-- The wrapper: runs the agent in the background with stdin closed, notes its pid, waits, writes its exit code.
local WRAP = [[out=$1; err=$2; st=$3; pf=$4; shift 4
"$@" </dev/null >>"$out" 2>>"$err" &
echo $! >"$pf"
wait $!
echo $? >"$st"]]

export type Hooks = {
	-- Wakes the windows (the mailbox helper's notify).
	notify: () -> (),
	-- Live panes: id → true, from the host's last poll; nil before the first poll.
	panes: () -> { [number]: boolean }?,
	-- Projects, to resolve `project` in definitions.
	projects: () -> { automate.ProjectRef },
}

local hooks: Hooks = nil :: any
local state: automate.State = automate.normalize(nil)
local cfg: automate.Config = { max_concurrent = automate.MAX_CONCURRENT, defs = {}, errors = {} }
local file_text: string? = nil
local file_error: string? = nil
local dirty = false
local view_json: string? = nil
local RUN_ID = string.format("%d-%d", os.time(), math.random(1, 1000000))
local view_n = 0
local sig = RUN_ID .. ".0"
-- Pane runs: consecutive polls their pane was missing.
local missing: { [string]: number } = {}
-- Runs whose liveness was checked this host run (lost-run detection after a restart).
local checked: { [string]: boolean } = {}
local tick_ms = 0
local tick_ms_max = 0

local function save()
	tern.kv.set(automate.KEY, automate.encode(state, tern.json.array))
	dirty = false
end

local function omp_path(): string
	local candidates = { "/opt/homebrew/bin/omp", "/usr/local/bin/omp", (HOME or "") .. "/.local/bin/omp", (HOME or "") .. "/.bun/bin/omp" }
	if CONFIG then
		table.insert(candidates, 1, CONFIG .. "/omp/bin/omp")
	end
	for _, p in candidates do
		if tern.fs.exists(p) then
			return p
		end
	end
	return "omp"
end
local OMP = omp_path()

local function read_file(path: string, max: number): string?
	local ok, text = pcall(tern.fs.read, path, max)
	return if ok then text else nil
end

-- Re-reads the definitions when the file's text changed; a broken file keeps the last good definitions.
local function load_defs()
	local text = read_file(FILE, FILE_BYTES)
	local projects = hooks.projects()
	-- Projects can change what `project` resolves to: fold them into the comparison.
	local key = (text or "") .. "\0" .. tern.json.encode(projects)
	if key == file_text then
		return
	end
	file_text = key
	if text == nil then
		cfg = { max_concurrent = automate.MAX_CONCURRENT, defs = {}, errors = {} }
		file_error = nil
		dirty = true
		return
	end
	local ok, doc = pcall(tern.json.decode, text)
	if not ok then
		file_error = "automations.json is not valid JSON: " .. string.gsub(tostring(doc), "\n.*", "")
		dirty = true
		return
	end
	file_error = nil
	cfg = automate.parse(doc, projects, HOME, os.time())
	dirty = true
end

local function out_paths(id: string): (string, string, string, string)
	local base = RUNS .. "/" .. id
	return base .. ".md", base .. ".err", base .. ".status", base .. ".pid"
end

local function stamp(t: number?): string
	return if t then os.date("%Y-%m-%d %H:%M", t) :: string else "-"
end

local check_run: (id: string) -> ()

-- Starts `r` as a headless print-mode run.
local function start_headless(r: automate.Run, d: automate.Def, now: number, note: string?)
	pcall(tern.fs.mkdir, RUNS)
	local out, err, st, pf = out_paths(r.id)
	if not tern.fs.exists(d.cwd) then
		automate.finish(r, "failed", now, "folder missing: " .. d.cwd)
		return
	end
	local argv = automate.headless_argv(d, OMP)
	local header = string.format(
		"# %s · run %d\n\n> %s · scheduled %s · started %s%s\n> %s\n> %s\n\n---\n\n",
		d.name,
		r.n,
		r.trigger,
		stamp(r.scheduled_for),
		stamp(now),
		if note then " · " .. note else "",
		d.cwd,
		"omp -p" .. (if d.model then " --model " .. d.model else "")
	)
	pcall(tern.fs.remove, st)
	pcall(tern.fs.remove, pf)
	tern.fs.write(out, header)
	tern.fs.write(err, "")
	local full = { "/bin/sh", "-c", WRAP, "sh", out, err, st, pf }
	for _, a in argv do
		table.insert(full, a)
	end
	local id = r.id
	local ok, e = pcall(tern.process.run, full, {
		cwd = d.cwd,
		env = { TERN_PROJECTS_AUTOMATION = d.id, TERN_PROJECTS_RUN = id },
	}, function(_res: ProcessResult)
		check_run(id)
	end)
	if not ok then
		automate.finish(r, "failed", now, "not started: " .. tostring(e))
		return
	end
	r.status = "running"
	r.mode = "headless"
	r.started = now
	r.out = out
	r.body = #header
	r.deadline = nil
	if note then
		r.note = note
	end
	tern.log.info("projects: automation run started", id, d.cwd)
end

-- A run past its precheck (or with none) goes: a pane run waits for a window, a headless one starts.
local function launch(r: automate.Run, d: automate.Def, now: number)
	if r.mode == "pane" then
		r.status = "waiting_window"
		r.deadline = now + automate.WINDOW_WAIT
		hooks.notify()
	else
		start_headless(r, d, now)
	end
end

local function begin(r: automate.Run, now: number)
	local d = automate.def_of(cfg, r.auto)
	if d == nil then
		automate.finish(r, "canceled", now, "automation removed")
		return
	end
	local def = d :: automate.Def
	-- Orca's precheck gates scheduled runs only; Run now skips it.
	if def.precheck and r.trigger ~= "manual" then
		r.status = "precheck"
		r.started = now
		local id = r.id
		local ok = pcall(tern.process.run, { "/bin/sh", "-c", def.precheck :: string }, {
			cwd = def.cwd,
			timeout_ms = math.floor(def.precheck_timeout * 1000),
		}, function(res: ProcessResult)
			local run = automate.find_run(state, id)
			if run == nil or run.status ~= "precheck" then
				return
			end
			local t = os.time()
			if res.status == 0 then
				launch(run, def, t)
			else
				automate.finish(run, "skipped_precheck", t, if res.timed_out then "precheck timed out" else string.format("precheck exited %d", res.status))
			end
			dirty = true
		end)
		if not ok then
			automate.finish(r, "skipped_precheck", now, "precheck not started")
		end
		return
	end
	launch(r, def, now)
end

local function summary_of(r: automate.Run): string?
	if r.out == nil then
		return nil
	end
	local text = read_file(r.out :: string, OUT_BYTES)
	if text == nil then
		return nil
	end
	local body = string.sub(text, ((r :: any).body or 0) + 1)
	return automate.summarize(body)
end

-- Ends a headless run whose status file exists.
check_run = function(id: string)
	local r = automate.find_run(state, id)
	if r == nil or r.status ~= "running" or r.mode ~= "headless" then
		return
	end
	local _, err, st = out_paths(id)
	local text = read_file(st, 64)
	if text == nil then
		return
	end
	local code = tonumber(string.match(text, "%-?%d+") or "")
	local now = os.time()
	local summary = summary_of(r)
	local cause: string? = nil
	if summary == nil then
		-- No answer: the error output's last line says why (omp's MCP warnings and progress lines say nothing).
		local etext = read_file(err, OUT_BYTES) or ""
		for line in string.gmatch(etext, "[^\n]+") do
			if not string.find(line, "^Working") and not string.find(line, "^Warning: MCP") then
				cause = line
			end
		end
		cause = if cause then automate.summarize(cause) else nil
	end
	if code == 0 then
		-- omp can end well with no answer (seen offline, after a wake from sleep).
		automate.finish(r, "done", now, summary or ("no answer" .. (if cause then ": " .. cause else "")), 0)
	else
		local why = if code == 3 then "cost limit reached" else nil
		automate.finish(r, "failed", now, why or summary or cause or string.format("exited %s", tostring(code)), code)
	end
	tern.log.info("projects: automation run ended", id, r.status)
	dirty = true
end

local function kill(pid: number)
	pcall(tern.process.run, { "/bin/kill", "-TERM", tostring(pid) }, { timeout_ms = 5000 }, function() end)
end

local function pid_of(id: string): number?
	local _, _, _, pf = out_paths(id)
	local text = read_file(pf, 64)
	return if text then tonumber(string.match(text, "%d+") or "") else nil
end

-- Running runs: ended headless ones (status file), lost ones, timeouts; pane runs whose window never came or whose
-- pane went.
local function watch_runs(now: number)
	local live = hooks.panes()
	for _, r in state.runs do
		local d = automate.def_of(cfg, r.auto)
		if r.status == "running" and r.mode == "headless" then
			check_run(r.id)
			if r.status ~= "running" then
				continue
			end
			local limit = (if d then d.timeout else automate.TIMEOUT_MIN * 60) + 120
			if r.started and now - (r.started :: number) > limit then
				local pid = pid_of(r.id)
				if pid then
					kill(pid)
				end
				automate.finish(r, "timed_out", now, string.format("stopped after %d min", (now - (r.started :: number)) // 60))
				dirty = true
			elseif not checked[r.id] and r.started and now - (r.started :: number) > 5 then
				-- Once per host run: is its agent still there (a daemon restart ends it with no status file)?
				checked[r.id] = true
				local pid = pid_of(r.id)
				if pid == nil then
					if now - (r.started :: number) > 60 then
						automate.finish(r, "lost", now, "its process is gone")
						dirty = true
					else
						checked[r.id] = nil
					end
				else
					local id = r.id
					pcall(tern.process.run, { "/bin/kill", "-0", tostring(pid) }, { timeout_ms = 5000 }, function(res: ProcessResult)
						if res.status ~= 0 then
							check_run(id)
							local run = automate.find_run(state, id)
							if run and run.status == "running" then
								automate.finish(run, "lost", os.time(), "its process is gone")
								dirty = true
							end
						end
					end)
				end
			end
		elseif r.status == "waiting_window" then
			if r.deadline and now > (r.deadline :: number) then
				if d then
					r.mode = "headless"
					start_headless(r, d, now, "no Tern window: ran headless")
				else
					automate.finish(r, "canceled", now, "automation removed")
				end
				dirty = true
			end
		elseif r.status == "running" and r.mode == "pane" then
			if live and r.pane then
				if live[r.pane :: number] then
					missing[r.id] = nil
				else
					missing[r.id] = (missing[r.id] or 0) + 1
					if missing[r.id] >= 3 then
						missing[r.id] = nil
						automate.finish(r, "canceled", now, "its pane closed before the turn ended")
						dirty = true
					end
				end
			end
			local limit = if d then d.timeout else automate.TIMEOUT_MIN * 60
			if r.status == "running" and r.started and now - (r.started :: number) > limit then
				automate.finish(r, "timed_out", now, string.format("still working after %d min (the agent keeps its pane)", limit // 60))
				dirty = true
			end
		elseif r.status == "precheck" then
			-- A precheck whose callback went with an earlier VM (its process was killed at its timeout): again.
			if r.started and now - (r.started :: number) > (if d then d.precheck_timeout else 60) + 10 then
				r.status = "queued"
				dirty = true
			end
		end
	end
end

local function write_view(now: number)
	local v = automate.view(state, cfg, now)
	if file_error then
		table.insert(v.errors, 1, file_error)
	end
	v.file = FILE
	-- Lists stay lists when empty.
	for _, a in v.autos do
		a.runs = tern.json.array(a.runs)
	end
	for _, k in { "errors", "autos", "pending", "panes" } do
		v[k] = tern.json.array(v[k])
	end
	-- `at` changes every tick: compare without it.
	v.at = nil
	local text = tern.json.encode(v)
	if text == view_json then
		return
	end
	v.at = now
	local ok, err = pcall(tern.fs.write, VIEW, tern.json.encode(v))
	if not ok then
		tern.log.warn("projects: autos.json not written", err)
		return
	end
	view_json = text
	view_n += 1
	sig = RUN_ID .. "." .. view_n
	pcall(tern.fs.write, SIGFILE, sig)
	hooks.notify()
end

-- One scheduler tick.
function autohost.tick()
	local t0 = tern.now()
	local now = os.time()
	load_defs()
	watch_runs(now)
	local plan = automate.plan(state, cfg, now)
	if plan.changed then
		dirty = true
	end
	for _, r in plan.start do
		begin(r, now)
		dirty = true
	end
	local removed = automate.prune(state, cfg)
	for _, r in removed do
		local out, err, st, pf = out_paths(r.id)
		for _, p in { out, err, st, pf } do
			pcall(tern.fs.remove, p)
		end
		dirty = true
	end
	if dirty then
		save()
	end
	tick_ms = tern.now() - t0
	tick_ms_max = math.max(tick_ms_max, tick_ms)
	if tick_ms > 200 then
		tern.log.warn(string.format("projects: automation tick took %.1f ms", tick_ms))
	end
	write_view(now)
end

-- The raw definitions document, for a rewrite; nil and why when the file is broken.
local function raw_doc(): ({ [string]: any }?, string?)
	local text = read_file(FILE, FILE_BYTES)
	if text == nil then
		return { version = 1, max_concurrent = automate.MAX_CONCURRENT, automations = {} }, nil
	end
	local ok, doc = pcall(tern.json.decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "automations.json is not valid JSON"
	end
	if doc.automations == nil then
		doc.automations = {}
	end
	return doc, nil
end

local function write_doc(doc: { [string]: any })
	local text = automate.pretty(doc, function(v: any): string
		return tern.json.encode(v)
	end, tern.json.array)
	tern.fs.write(FILE, text)
	-- Picked up by the next tick's load_defs.
end

local function entry_id(a: any): string?
	if type(a) ~= "table" then
		return nil
	end
	if type(a.id) == "string" and a.id ~= "" then
		return a.id
	end
	return if type(a.name) == "string" then automate.slug(a.name) else nil
end

-- Spool requests from windows (`op` starting with `auto_`).
function autohost.spool(obj: { [string]: any })
	local op = obj.op
	local now = os.time()
	if op == "auto_run" and type(obj.id) == "string" then
		local d = automate.def_of(cfg, obj.id)
		if d then
			automate.enqueue(state, d, "manual", now, now)
			dirty = true
		end
	elseif op == "auto_enable" and type(obj.id) == "string" then
		local doc, err = raw_doc()
		if doc == nil then
			tern.log.warn("projects: automation not switched", err)
			return
		end
		for _, a in doc.automations do
			if entry_id(a) == obj.id then
				a.enabled = obj.enabled == true
			end
		end
		write_doc(doc)
	elseif op == "auto_create" and type(obj.def) == "table" then
		local doc, err = raw_doc()
		if doc == nil then
			tern.log.warn("projects: automation not added", err)
			return
		end
		local def = obj.def
		local base = automate.slug(tostring(def.name or "automation"))
		local id, n = base, 1
		local taken: { [string]: boolean } = {}
		for _, a in doc.automations do
			local e = entry_id(a)
			if e then
				taken[e] = true
			end
		end
		while taken[id] do
			n += 1
			id = base .. "-" .. n
		end
		def.id = id
		table.insert(doc.automations, def)
		write_doc(doc)
	elseif op == "auto_started" and type(obj.run) == "string" and type(obj.pane) == "number" then
		local r = automate.find_run(state, obj.run)
		if r and r.status == "waiting_window" then
			r.status = "running"
			r.pane = obj.pane
			r.started = now
			r.deadline = nil
			dirty = true
		end
	elseif op == "auto_start_failed" and type(obj.run) == "string" then
		local r = automate.find_run(state, obj.run)
		if r and r.status == "waiting_window" then
			automate.finish(r, "failed", now, "agent not started: " .. tostring(obj.error))
			dirty = true
		end
	elseif op == "auto_finished" and type(obj.run) == "string" then
		local r = automate.find_run(state, obj.run)
		if r and r.status == "running" and r.mode == "pane" then
			local text = if type(obj.text) == "string" then automate.summarize(obj.text) else nil
			automate.finish(r, if obj.result == "failed" then "failed" else "done", now, text or (if obj.result == "failed" then "failed" else "finished"))
			dirty = true
		end
	elseif op == "auto_stop" and type(obj.run) == "string" then
		local r = automate.find_run(state, obj.run)
		if r and automate.active(r.status) then
			if r.status == "running" and r.mode == "headless" then
				local pid = pid_of(r.id)
				if pid then
					kill(pid)
				end
			end
			automate.finish(r, "canceled", now, "stopped by you")
			dirty = true
		end
	end
end

function autohost.start(h: Hooks)
	hooks = h
	local ok, raw = pcall(tern.kv.get, automate.KEY)
	state = automate.normalize(if ok then raw else nil)
	pcall(tern.fs.mkdir, RUNS)
end

-- For status.json.
function autohost.stats(): { [string]: any }
	-- The scheduler tick's last and longest run time this host run (ms).
	return {
		auto_sig = sig,
		auto_ms = math.floor(tick_ms * 10 + 0.5) / 10,
		auto_ms_max = math.floor(tick_ms_max * 10 + 0.5) / 10,
	}
end

return autohost
