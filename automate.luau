--!strict
-- projects, automations (pure): Orca-style scheduled agent runs (README "Automations").
--
-- - Definitions live in `<data>/automations.json`, a file the user edits (the palette's New automation and the
--   sidebar's enable switch write it too, through the host half). `parse` validates it into a `Config`.
-- - Runtime state lives in kv key `automations.v1` (written by the host half only): each automation's next run
--   (`slots`) and the run history (`runs`).
-- - `plan` is the scheduler's tick: what became due, missed runs (catch-up or skip), one run at a time per
--   automation, and which queued runs may start under the concurrency cap. `prune` bounds the history.
-- - `view` is the compact model the window halves draw (`<data>/autos.json`).
--
-- Nothing here touches Tern: the host half (autohost.luau) does the processes, files and kv.

local sched = require("./sched")

local automate = {}

automate.KEY = "automations.v1"
automate.VERSION = 1
-- Finished runs kept per automation (Orca keeps 100; each kv write rewrites the whole history).
automate.KEEP_RUNS = 50
-- Default and largest concurrency cap.
automate.MAX_CONCURRENT = 2
automate.MAX_CONCURRENT_LIMIT = 8
-- A due run this late (s) still counts as on time: the host's clock ticks every few seconds and a busy daemon
-- can be late; later than this it was missed (Tern was not running, the machine slept).
automate.ON_TIME = 90
-- How long a pane run waits for a window to start its agent before it runs headless instead (s).
automate.WINDOW_WAIT = 20
-- Default run time limit (minutes) and precheck limit (seconds).
automate.TIMEOUT_MIN = 30
automate.PRECHECK_S = 60

export type Def = {
	id: string,
	name: string,
	enabled: boolean,
	schedule: string,
	rule: sched.Rule,
	prompt: string,
	cwd: string,
	-- The project it runs in, when it names one (its session holds pane runs).
	project: string?,
	run_in: "headless" | "pane",
	model: string?,
	args: { string },
	missed: "run_once" | "skip",
	-- Seconds; nil: any age (with missed = run_once).
	grace: number?,
	-- Seconds.
	timeout: number,
	precheck: string?,
	precheck_timeout: number,
}

export type Config = {
	max_concurrent: number,
	defs: { Def },
	-- One line per problem; a bad entry is left out, the rest run.
	errors: { string },
}

export type Slot = {
	-- Next occurrence (os.time()); nil while disabled.
	next_at: number?,
	-- The schedule text next_at was computed for: a changed schedule starts afresh.
	sched: string?,
	-- Runs numbered so far.
	n: number,
}

export type Status = string

export type Run = {
	id: string,
	auto: string,
	n: number,
	-- scheduled | manual | catchup
	trigger: string,
	scheduled_for: number,
	created: number,
	status: Status,
	mode: "headless" | "pane",
	started: number?,
	ended: number?,
	-- Folded skipped rows: how many occurrences this row stands for.
	count: number?,
	pane: number?,
	pid: number?,
	-- Headless output file.
	out: string?,
	summary: string?,
	exit: number?,
	-- waiting_window: os.time() after which it runs headless.
	deadline: number?,
	-- Why it ran as it did (catch-up count, headless for want of a window).
	note: string?,
	-- Headless: where the agent's output starts in `out` (after the host's header).
	body: number?,
}

export type State = { slots: { [string]: Slot }, runs: { Run } }

-- Statuses a run never leaves.
local FINAL: { [string]: boolean } = {
	done = true,
	failed = true,
	timed_out = true,
	canceled = true,
	lost = true,
	skipped_missed = true,
	skipped_busy = true,
	skipped_precheck = true,
}
automate.FINAL = FINAL
-- Statuses that hold one of the concurrency slots.
local BUSY: { [string]: boolean } = { precheck = true, waiting_window = true, running = true }

function automate.final(status: string): boolean
	return FINAL[status] == true
end

function automate.active(status: string): boolean
	return not FINAL[status]
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function slug(s: string): string
	local out = string.lower(s)
	out = string.gsub(out, "[^%w]+", "-")
	out = string.gsub(out, "^%-+", "")
	out = string.gsub(out, "%-+$", "")
	if out == "" then
		out = "automation"
	end
	return string.sub(out, 1, 48)
end
automate.slug = slug

export type ProjectRef = { id: string, name: string, root: string }

-- Validates the definitions file's decoded JSON. `projects` resolves `project` (an id or a name) to its root;
-- `home` expands a leading `~` in `cwd`; with `now`, a schedule that never comes (Feb 31) is refused here rather
-- than rescanned every tick.
function automate.parse(doc: any, projects: { ProjectRef }, home: string?, now: number?, cal: sched.Calendar?): Config
	local cfg: Config = { max_concurrent = automate.MAX_CONCURRENT, defs = {}, errors = {} }
	if type(doc) ~= "table" then
		table.insert(cfg.errors, "automations.json: not a JSON object")
		return cfg
	end
	local mc = doc.max_concurrent
	if mc ~= nil then
		if type(mc) == "number" and mc >= 1 and mc == math.floor(mc) then
			cfg.max_concurrent = math.min(mc, automate.MAX_CONCURRENT_LIMIT)
		else
			table.insert(cfg.errors, "max_concurrent: a whole number from 1")
		end
	end
	local list = doc.automations
	if list == nil then
		return cfg
	end
	if type(list) ~= "table" then
		table.insert(cfg.errors, "automations: must be a list")
		return cfg
	end
	local seen: { [string]: boolean } = {}
	for i, a in list do
		local where = string.format("automations[%d]", i)
		local function bad(msg: string)
			table.insert(cfg.errors, where .. ": " .. msg)
		end
		if type(a) ~= "table" then
			bad("must be an object")
			continue
		end
		if type(a.name) == "string" and trim(a.name) ~= "" then
			where = string.format("%s (%s)", where, a.name :: string)
		else
			bad("name is required")
			continue
		end
		local id = if type(a.id) == "string" and trim(a.id) ~= "" then trim(a.id) else slug(a.name)
		if not string.match(id, "^[%w%-_]+$") then
			bad("id may hold letters, digits, - and _ only")
			continue
		end
		if seen[id] then
			bad("duplicate id " .. id)
			continue
		end
		local rule, err = sched.parse(a.schedule)
		if rule == nil then
			bad("schedule: " .. (err or "invalid"))
			continue
		end
		if now ~= nil and sched.next_after(rule :: sched.Rule, now, cal) == nil then
			bad("schedule: never comes")
			continue
		end
		if type(a.prompt) ~= "string" or trim(a.prompt) == "" then
			bad("prompt is required")
			continue
		end
		local cwd: string? = nil
		local project: string? = nil
		if a.project ~= nil then
			for _, p in projects do
				if p.id == a.project or p.name == a.project then
					cwd, project = p.root, p.id
				end
			end
			if cwd == nil then
				bad("no project " .. tostring(a.project))
				continue
			end
		elseif type(a.cwd) == "string" and a.cwd ~= "" then
			local c = a.cwd :: string
			if home and (c == "~" or string.sub(c, 1, 2) == "~/") then
				c = home .. string.sub(c, 2)
			end
			if string.sub(c, 1, 1) ~= "/" then
				bad("cwd must be an absolute path")
				continue
			end
			cwd = c
		else
			bad("project or cwd is required")
			continue
		end
		local run_in = a.run_in or "headless"
		if run_in ~= "headless" and run_in ~= "pane" then
			bad("run_in: headless or pane")
			continue
		end
		local args: { string } = {}
		if a.args ~= nil then
			local ok = type(a.args) == "table"
			if ok then
				for _, v in a.args do
					if type(v) ~= "string" then
						ok = false
					else
						table.insert(args, v)
					end
				end
			end
			if not ok then
				bad("args: a list of strings")
				continue
			end
		end
		local missed = a.missed or "run_once"
		if missed ~= "run_once" and missed ~= "skip" then
			bad("missed: run_once or skip")
			continue
		end
		local function minutes(v: any, name: string): (number?, boolean)
			if v == nil then
				return nil, true
			end
			if type(v) ~= "number" or v < 0 then
				bad(name .. ": minutes, a number from 0")
				return nil, false
			end
			return v * 60, true
		end
		local grace, gok = minutes(a.grace_minutes, "grace_minutes")
		local timeout, tok = minutes(a.timeout_minutes, "timeout_minutes")
		if not gok or not tok then
			continue
		end
		if timeout ~= nil and timeout < 60 then
			bad("timeout_minutes: at least 1")
			continue
		end
		local precheck: string? = nil
		if a.precheck ~= nil then
			if type(a.precheck) ~= "string" or trim(a.precheck) == "" then
				bad("precheck: a shell command")
				continue
			end
			precheck = a.precheck
		end
		local pt = a.precheck_timeout
		if pt ~= nil and (type(pt) ~= "number" or pt < 1) then
			bad("precheck_timeout: seconds, at least 1")
			continue
		end
		if a.enabled ~= nil and type(a.enabled) ~= "boolean" then
			bad("enabled: true or false")
			continue
		end
		if a.model ~= nil and type(a.model) ~= "string" then
			bad("model: a string")
			continue
		end
		seen[id] = true
		table.insert(cfg.defs, {
			id = id,
			name = trim(a.name),
			enabled = a.enabled ~= false,
			schedule = a.schedule,
			rule = rule :: sched.Rule,
			prompt = a.prompt,
			cwd = cwd :: string,
			project = project,
			run_in = run_in,
			model = if a.model and trim(a.model) ~= "" then trim(a.model) else nil,
			args = args,
			missed = missed,
			grace = grace,
			timeout = timeout or automate.TIMEOUT_MIN * 60,
			precheck = precheck,
			precheck_timeout = pt or automate.PRECHECK_S,
		})
	end
	return cfg
end

-- The kv state, normalized (anything malformed dropped).
function automate.normalize(raw: any): State
	local st: State = { slots = {}, runs = {} }
	if type(raw) ~= "table" then
		return st
	end
	if type(raw.slots) == "table" then
		for id, s in raw.slots do
			if type(id) == "string" and type(s) == "table" then
				st.slots[id] = {
					next_at = if type(s.next_at) == "number" then s.next_at else nil,
					sched = if type(s.sched) == "string" then s.sched else nil,
					n = if type(s.n) == "number" then s.n else 0,
				}
			end
		end
	end
	if type(raw.runs) == "table" then
		for _, r in raw.runs do
			if type(r) == "table" and type(r.id) == "string" and type(r.auto) == "string" and type(r.status) == "string" then
				local run: { [string]: any } = {}
				for k, v in r do
					if type(k) == "string" and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
						run[k] = v
					end
				end
				run.n = if type(r.n) == "number" then r.n else 0
				run.trigger = if type(r.trigger) == "string" then r.trigger else "scheduled"
				run.scheduled_for = if type(r.scheduled_for) == "number" then r.scheduled_for else 0
				run.created = if type(r.created) == "number" then r.created else 0
				run.mode = if r.mode == "pane" then "pane" else "headless"
				table.insert(st.runs, run :: any)
			end
		end
	end
	return st
end

-- The kv form: an empty map stays a map, and the run list a list.
function automate.encode(st: State, array: (t: any) -> any): any
	return { slots = st.slots, runs = array(st.runs) }
end

local function def_of(cfg: Config, id: string): Def?
	for _, d in cfg.defs do
		if d.id == id then
			return d
		end
	end
	return nil
end
automate.def_of = def_of

function automate.find_run(st: State, id: string): Run?
	for _, r in st.runs do
		if r.id == id then
			return r
		end
	end
	return nil
end

local function last_of(st: State, auto: string): Run?
	for i = #st.runs, 1, -1 do
		if st.runs[i].auto == auto then
			return st.runs[i]
		end
	end
	return nil
end

local function active_of(st: State, auto: string): Run?
	for _, r in st.runs do
		if r.auto == auto and not FINAL[r.status] then
			return r
		end
	end
	return nil
end
automate.active_of = active_of

local function new_run(st: State, d: Def, trigger: string, at: number, now: number, status: string): Run
	local slot = st.slots[d.id]
	if slot == nil then
		slot = { n = 0 } :: Slot
		st.slots[d.id] = slot
	end
	slot.n += 1
	local r: Run = {
		id = string.format("%s-%d", d.id, slot.n),
		auto = d.id,
		n = slot.n,
		trigger = trigger,
		scheduled_for = at,
		created = now,
		status = status,
		mode = d.run_in,
	}
	if FINAL[status] then
		r.ended = now
	end
	table.insert(st.runs, r)
	return r
end

-- A skipped occurrence: folded into the automation's last row when that is the same kind of skip, so a long run
-- or a long downtime makes one row, not one per occurrence.
local function skip(st: State, d: Def, status: string, trigger: string, at: number, now: number, count: number, why: string)
	local last = last_of(st, d.id)
	if last and last.status == status then
		last.count = (last.count or 1) + count
		last.scheduled_for = at
		last.ended = now
		last.summary = why
		return
	end
	local r = new_run(st, d, trigger, at, now, status)
	r.count = count
	r.summary = why
end

-- Queues a run of `d` unless one is active already (then the occurrence is skipped, as Orca's one lane per
-- automation); the run, or nil when skipped.
function automate.enqueue(st: State, d: Def, trigger: string, at: number, now: number): Run?
	local busy = active_of(st, d.id)
	if busy then
		skip(st, d, "skipped_busy", trigger, at, now, 1, "previous run " .. busy.id .. " still " .. busy.status)
		return nil
	end
	return new_run(st, d, trigger, at, now, "queued")
end

export type Plan = {
	-- Queued runs to start now, oldest first, within the cap.
	start: { Run },
	changed: boolean,
}

-- One scheduler tick at `now`.
function automate.plan(st: State, cfg: Config, now: number, cal: sched.Calendar?): Plan
	local changed = false
	for _, d in cfg.defs do
		local slot = st.slots[d.id]
		if slot == nil then
			slot = { n = 0 } :: Slot
			st.slots[d.id] = slot
			changed = true
		end
		if not d.enabled then
			if slot.next_at ~= nil then
				slot.next_at = nil
				changed = true
			end
			continue
		end
		if slot.next_at == nil or slot.sched ~= d.schedule then
			-- Newly defined, enabled or rescheduled: from now on, never retroactively.
			slot.sched = d.schedule
			slot.next_at = sched.next_after(d.rule, now, cal)
			changed = true
			continue
		end
		local due = slot.next_at :: number
		if due > now then
			continue
		end
		changed = true
		local latest, count = sched.latest(d.rule, due - 1, now, cal)
		local at = latest or due
		local n = math.max(count, 1)
		local late = now - at
		if late <= automate.ON_TIME then
			local r = automate.enqueue(st, d, "scheduled", at, now)
			if r and n > 1 then
				r.note = string.format("%d earlier run%s missed", n - 1, if n == 2 then "" else "s")
			end
		elseif d.missed == "skip" or (d.grace ~= nil and late > (d.grace :: number)) then
			skip(st, d, "skipped_missed", "scheduled", at, now, n, string.format("missed %d run%s while Tern was not running", n, if n == 1 then "" else "s"))
		else
			-- Catch-up: the latest missed occurrence runs once.
			local r = automate.enqueue(st, d, "catchup", at, now)
			if r and n > 1 then
				r.note = string.format("catch-up for %d missed runs", n)
			end
		end
		slot.next_at = sched.next_after(d.rule, now, cal)
	end
	-- Runs of automations no longer defined: queued ones are canceled (running ones finish).
	for _, r in st.runs do
		if r.status == "queued" and def_of(cfg, r.auto) == nil then
			r.status = "canceled"
			r.ended = now
			r.summary = "automation removed"
			changed = true
		end
	end
	local busy = 0
	for _, r in st.runs do
		if BUSY[r.status] then
			busy += 1
		end
	end
	local start: { Run } = {}
	for _, r in st.runs do
		if busy >= cfg.max_concurrent then
			break
		end
		if r.status == "queued" then
			table.insert(start, r)
			busy += 1
		end
	end
	return { start = start, changed = changed }
end

-- Ends a run.
function automate.finish(r: Run, status: string, now: number, summary: string?, exit: number?)
	r.status = status
	r.ended = now
	if summary ~= nil then
		r.summary = summary
	end
	if exit ~= nil then
		r.exit = exit
	end
	r.deadline = nil
end

-- Bounds the history: at most `keep` finished runs per automation (the newest), and no finished runs of
-- automations no longer defined. Returns the removed runs (their output files go too). Slots of removed
-- automations go when they have no runs left.
function automate.prune(st: State, cfg: Config, keep: number?): { Run }
	local limit = keep or automate.KEEP_RUNS
	local defined: { [string]: boolean } = {}
	for _, d in cfg.defs do
		defined[d.id] = true
	end
	local finals: { [string]: number } = {}
	for _, r in st.runs do
		if FINAL[r.status] then
			finals[r.auto] = (finals[r.auto] or 0) + 1
		end
	end
	local removed: { Run } = {}
	local kept: { Run } = {}
	local dropped: { [string]: number } = {}
	for _, r in st.runs do
		local drop = false
		if FINAL[r.status] then
			if not defined[r.auto] then
				drop = true
			else
				local over = (finals[r.auto] or 0) - limit
				-- Oldest first: the list is in creation order.
				if (dropped[r.auto] or 0) < over then
					drop = true
				end
			end
		end
		if drop then
			dropped[r.auto] = (dropped[r.auto] or 0) + 1
			table.insert(removed, r)
		else
			table.insert(kept, r)
		end
	end
	st.runs = kept
	local has: { [string]: boolean } = {}
	for _, r in kept do
		has[r.auto] = true
	end
	for id in st.slots do
		if not defined[id] and not has[id] then
			st.slots[id] = nil
		end
	end
	return removed
end

-- A one-line summary of a run's output: its first non-empty line (print mode prints the final answer), cut.
function automate.summarize(text: string?, n: number?): string?
	if text == nil then
		return nil
	end
	for line in string.gmatch(text, "[^\n]+") do
		-- Markdown heading and quote marks say nothing.
		local l = trim((string.gsub(trim(line), "^[#>]+%s*", "")))
		if l ~= "" and l ~= "---" then
			local max = n or 160
			if #l > max then
				local cut = utf8.offset(l, max) or max
				l = string.sub(l, 1, cut - 1) .. "…"
			end
			return l
		end
	end
	return nil
end

-- The headless omp command for `d`: print mode, a time limit, the model and extra arguments, then the prompt.
function automate.headless_argv(d: Def, omp: string): { string }
	local argv = { omp, "-p", "--max-time", tostring(math.floor(d.timeout)) }
	if d.model then
		table.insert(argv, "--model")
		table.insert(argv, d.model :: string)
	end
	for _, a in d.args do
		table.insert(argv, a)
	end
	-- A prompt starting with `-` would read as a flag.
	local prompt = d.prompt
	if string.sub(prompt, 1, 1) == "-" then
		prompt = " " .. prompt
	end
	table.insert(argv, prompt)
	return argv
end

-- The view model the windows draw (`<data>/autos.json`).
function automate.view(st: State, cfg: Config, now: number, recent: number?): { [string]: any }
	local autos: { any } = {}
	local pending: { any } = {}
	local panes: { any } = {}
	local by: { [string]: { Run } } = {}
	for _, r in st.runs do
		local l = by[r.auto] or {}
		table.insert(l, r)
		by[r.auto] = l
		if r.status == "waiting_window" and r.mode == "pane" then
			local d = def_of(cfg, r.auto)
			if d then
				table.insert(pending, {
					run = r.id,
					auto = d.id,
					name = d.name,
					n = r.n,
					prompt = d.prompt,
					cwd = d.cwd,
					project = d.project,
					model = d.model,
					deadline = r.deadline,
				})
			end
		elseif r.status == "running" and r.mode == "pane" and r.pane then
			table.insert(panes, { run = r.id, pane = r.pane, started = r.started })
		end
	end
	for _, d in cfg.defs do
		local runs = by[d.id] or {}
		local list: { any } = {}
		local limit = recent or 10
		for i = #runs, math.max(1, #runs - limit + 1), -1 do
			local r = runs[i]
			table.insert(list, {
				id = r.id,
				n = r.n,
				status = r.status,
				trigger = r.trigger,
				scheduled_for = r.scheduled_for,
				started = r.started,
				ended = r.ended,
				count = r.count,
				summary = r.summary,
				note = r.note,
				out = r.out,
				pane = r.pane,
				mode = r.mode,
			})
		end
		local slot = st.slots[d.id]
		table.insert(autos, {
			id = d.id,
			name = d.name,
			enabled = d.enabled,
			label = d.rule.label,
			run_in = d.run_in,
			cwd = d.cwd,
			project = d.project,
			next_at = if slot and d.enabled then slot.next_at else nil,
			runs = list,
		})
	end
	return {
		version = automate.VERSION,
		at = now,
		max_concurrent = cfg.max_concurrent,
		errors = cfg.errors,
		autos = autos,
		pending = pending,
		panes = panes,
	}
end

-- The definitions file, pretty-printed with a stable key order (the host rewrites it to flip `enabled` and to
-- add an automation from the palette). `enc` encodes one scalar or flat value as JSON.
local ORDER = {
	"id",
	"name",
	"enabled",
	"schedule",
	"run_in",
	"project",
	"cwd",
	"prompt",
	"model",
	"args",
	"missed",
	"grace_minutes",
	"timeout_minutes",
	"precheck",
	"precheck_timeout",
}
function automate.pretty(doc: { [string]: any }, enc: (v: any) -> string, array: (t: any) -> any): string
	local out: { string } = { "{" }
	local top: { string } = {}
	for k in doc do
		if k ~= "automations" then
			table.insert(top, k)
		end
	end
	table.sort(top)
	for _, k in top do
		table.insert(out, string.format("  %s: %s,", enc(k), enc(doc[k])))
	end
	local list = doc.automations or {}
	if #list == 0 then
		table.insert(out, '  "automations": []')
	else
		table.insert(out, '  "automations": [')
		for i, a in list do
			local keys: { string } = {}
			local known: { [string]: boolean } = {}
			for _, k in ORDER do
				known[k] = true
				if type(a) == "table" and a[k] ~= nil then
					table.insert(keys, k)
				end
			end
			local extra: { string } = {}
			if type(a) == "table" then
				for k in a do
					if type(k) == "string" and not known[k] then
						table.insert(extra, k)
					end
				end
			end
			table.sort(extra)
			for _, k in extra do
				table.insert(keys, k)
			end
			table.insert(out, "    {")
			for j, k in keys do
				local v = a[k]
				if k == "args" and type(v) == "table" then
					v = array(v)
				end
				table.insert(out, string.format("      %s: %s%s", enc(k), enc(v), if j < #keys then "," else ""))
			end
			table.insert(out, "    }" .. (if i < #list then "," else ""))
		end
		table.insert(out, "  ]")
	end
	table.insert(out, "}")
	return table.concat(out, "\n") .. "\n"
end

return automate
