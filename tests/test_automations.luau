--!nonstrict
-- luau tests/test_automations.luau: Orca-style automations. Schedule parsing and occurrences (sched.luau) across
-- daylight saving on a fixed calendar (America/New_York and Australia/Lord_Howe rules of 2026, so the result does not
-- depend on the machine's zone), the definitions file (automate.parse), the scheduler tick (catch-up and skip of
-- missed runs, one run at a time per automation, the concurrency cap), history retention, the headless command,
-- the definitions file's rewrite, and the sidebar section.

local t = require("./support")
local json = require("./support_json")
local sched = require("../sched")
local automate = require("../automate")
local sidebar = require("../sidebar")

local check, eq, test = t.check, t.eq, t.test

-- Seconds since the epoch of a UTC wall time (days from civil, proleptic Gregorian).
local function utc(y, m, d, h, mi)
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + (h or 0) * 3600 + (mi or 0) * 60
end

-- A zone with one DST period: `std` and `dst` offsets (seconds east), DST between two UTC instants.
local function zone(std, dst, from, to)
	return {
		fields = function(at)
			local off = if at >= from and at < to then dst else std
			return os.date("!*t", at + off)
		end,
		-- The instant of a wall time, for the offset in force (tests only use unambiguous times).
		at = function(y, m, d, h, mi)
			local guess = utc(y, m, d, h, mi)
			for _, off in { std, dst } do
				local cand = guess - off
				local f = os.date("!*t", cand + (if cand >= from and cand < to then dst else std))
				if f.year == y and f.month == m and f.day == d and f.hour == h and f.min == mi then
					return cand
				end
			end
			error("no such wall time")
		end,
	}
end

-- New York 2026: EDT from 2026-03-08 07:00Z (02:00 EST) to 2026-11-01 06:00Z (02:00 EDT).
local NY = zone(-5 * 3600, -4 * 3600, utc(2026, 3, 8, 7, 0), utc(2026, 11, 1, 6, 0))
-- Lord Howe 2026: +10:30 standard, +11 summer; summer ends 2026-04-05 02:00 local (15:00Z on the 4th), starts
-- 2026-10-04 02:00 local (15:30Z on the 3rd). Modeled as summer outside [Apr 4 15:00Z, Oct 3 15:30Z).
local LH = {
	fields = function(at)
		local std_from, std_to = utc(2026, 4, 4, 15, 0), utc(2026, 10, 3, 15, 30)
		local off = if at >= std_from and at < std_to then 10 * 3600 + 1800 else 11 * 3600
		return os.date("!*t", at + off)
	end,
}

local function wall(cal, at)
	local f = cal.fields(at)
	return string.format("%04d-%02d-%02d %02d:%02d", f.year, f.month, f.day, f.hour, f.min)
end

local function rule(spec)
	local r, err = sched.parse(spec)
	assert(r, tostring(err))
	return r
end

-- Schedules ----------------------------------------------------------------------------

test("parses every form and labels it", function()
	eq(rule("every 2m").label, "Every 2 min", "every 2m")
	eq(rule("every 1 minute").label, "Every minute", "every 1 minute")
	eq(rule("every 2h").period, 7200, "every 2h period")
	eq(rule("hourly").label, "Hourly at :00", "hourly")
	eq(rule("hourly :15").label, "Hourly at :15", "hourly :15")
	eq(rule("daily 9:05").label, "Daily at 09:05", "daily")
	eq(rule("weekdays 09:00").label, "Weekdays at 09:00", "weekdays")
	eq(rule("weekly mon 08:30").label, "Mondays at 08:30", "weekly name")
	eq(rule("weekly 0 08:30").label, "Sundays at 08:30", "weekly number")
	eq(rule("  0 9 * * 1-5 ").label, "cron 0 9 * * 1-5", "cron label")
	eq(rule("Daily 09:00").label, "Daily at 09:00", "case-insensitive")
end)

test("rejects what is not a schedule", function()
	for _, bad in { "", "daily", "daily 25:00", "every 0m", "every 8d", "weekly funday 09:00", "61 * * * *", "* * *", "*/0 * * * *", "5-1 * * * *", 42 } do
		local r, err = sched.parse(bad)
		check(r == nil and type(err) == "string", "rejects " .. tostring(bad))
	end
end)

test("every N is absolute: even minutes, any zone", function()
	local r = rule("every 2m")
	local t0 = utc(2026, 6, 1, 10, 0) + 30
	eq(sched.next_after(r, t0, NY), utc(2026, 6, 1, 10, 2), "next even minute")
	eq(sched.next_after(r, utc(2026, 6, 1, 10, 2), NY), utc(2026, 6, 1, 10, 4), "strictly after")
end)

test("daily, weekdays, weekly, hourly", function()
	local mon = NY.at(2026, 6, 1, 8, 0) -- a Monday
	eq(wall(NY, sched.next_after(rule("daily 09:00"), mon, NY)), "2026-06-01 09:00", "daily later today")
	eq(wall(NY, sched.next_after(rule("daily 07:00"), mon, NY)), "2026-06-02 07:00", "daily tomorrow")
	local fri = NY.at(2026, 6, 5, 10, 0)
	eq(wall(NY, sched.next_after(rule("weekdays 09:00"), fri, NY)), "2026-06-08 09:00", "weekdays skip the weekend")
	eq(wall(NY, sched.next_after(rule("weekly wed 18:30"), mon, NY)), "2026-06-03 18:30", "weekly")
	eq(wall(NY, sched.next_after(rule("hourly :15"), NY.at(2026, 6, 1, 8, 15), NY)), "2026-06-01 09:15", "hourly strictly after")
end)

test("cron lists, ranges, steps, names and the day-field OR", function()
	local from = NY.at(2026, 6, 1, 0, 0)
	eq(wall(NY, sched.next_after(rule("*/20 9-10 * * *"), NY.at(2026, 6, 1, 9, 40), NY)), "2026-06-01 10:00", "step and range")
	eq(wall(NY, sched.next_after(rule("0 12 * jul *"), from, NY)), "2026-07-01 12:00", "month name")
	eq(wall(NY, sched.next_after(rule("0 12 * * sun"), from, NY)), "2026-06-07 12:00", "day name")
	eq(wall(NY, sched.next_after(rule("0 12 * * 7"), from, NY)), "2026-06-07 12:00", "7 is Sunday")
	-- Both day fields restricted: the 15th or a Friday, whichever comes first.
	eq(wall(NY, sched.next_after(rule("0 6 15 * fri"), from, NY)), "2026-06-05 06:00", "dom OR dow: Friday first")
	eq(wall(NY, sched.next_after(rule("0 6 15 * fri"), NY.at(2026, 6, 13, 0, 0), NY)), "2026-06-15 06:00", "dom OR dow: the 15th")
	eq(wall(NY, sched.next_after(rule("0 0 29 2 *"), from, NY)), "2028-02-29 00:00", "Feb 29 two years on")
	eq(sched.next_after(rule("0 0 31 2 *"), from, NY), nil, "Feb 31 never comes")
end)

test("DST spring forward: a skipped wall time does not occur that day", function()
	local r = rule("daily 02:30")
	local before = NY.at(2026, 3, 7, 3, 0)
	eq(wall(NY, sched.next_after(r, before, NY)), "2026-03-09 02:30", "02:30 on Mar 8 does not exist")
	-- 09:00 still lands at 09:00 wall time on both sides (13:00Z then 14:00Z... reversed: EST 14:00Z, EDT 13:00Z).
	local d = rule("daily 09:00")
	local a = sched.next_after(d, NY.at(2026, 3, 7, 10, 0), NY)
	local b = sched.next_after(d, a, NY)
	eq(a, utc(2026, 3, 8, 13, 0), "09:00 EDT is 13:00Z")
	eq(b - a, 86400, "a calendar day apart")
	eq(sched.next_after(d, NY.at(2026, 3, 6, 10, 0), NY), utc(2026, 3, 7, 14, 0), "09:00 EST is 14:00Z")
	-- An hourly schedule runs 23 times on the short day.
	local h = rule("hourly")
	local _, n = sched.latest(h, NY.at(2026, 3, 7, 23, 59), NY.at(2026, 3, 8, 23, 59), NY)
	eq(n, 23, "23 hours on Mar 8")
end)

test("DST fall back: a repeated wall time occurs once, at its first instant", function()
	local r = rule("daily 01:30")
	local at = sched.next_after(r, NY.at(2026, 10, 31, 12, 0), NY)
	eq(at, utc(2026, 11, 1, 5, 30), "01:30 EDT (05:30Z), the first one")
	local again = sched.next_after(r, at, NY)
	eq(wall(NY, again), "2026-11-02 01:30", "not again at 01:30 EST")
	-- Every minute: the repeated hour's minutes are not run twice.
	local m = rule("* * * * *")
	local _, n = sched.latest(m, utc(2026, 11, 1, 5, 0) - 1, utc(2026, 11, 1, 7, 0) - 60, NY)
	-- 05:00Z..06:59Z is 01:00-01:59 EDT then 01:00-01:59 EST: 60 wall minutes once each.
	eq(n, 60, "60 wall minutes in the 2 h the clock repeats")
	local h = rule("hourly")
	local _, hn = sched.latest(h, NY.at(2026, 10, 31, 23, 59), utc(2026, 11, 2, 4, 59), NY)
	eq(hn, 24, "24 wall hours on the 25 h day")
end)

test("DST of 30 minutes (Lord Howe)", function()
	-- Summer starts 2026-10-04 02:00 local → 02:30.
	local r = rule("daily 02:15")
	local after = utc(2026, 10, 3, 0, 0)
	eq(wall(LH, sched.next_after(r, after, LH)), "2026-10-05 02:15", "02:15 skipped on Oct 4")
	-- Summer ends 2026-04-05 02:00 → 01:30: 01:45 occurs once.
	local r2 = rule("daily 01:45")
	local first = sched.next_after(r2, utc(2026, 4, 4, 0, 0), LH)
	eq(first, utc(2026, 4, 4, 14, 45), "01:45 summer time (14:45Z)")
	eq(wall(LH, sched.next_after(r2, first, LH)), "2026-04-06 01:45", "not twice")
end)

test("latest counts missed occurrences and caps them", function()
	local r = rule("every 2m")
	local last, n = sched.latest(r, utc(2026, 6, 1, 10, 0), utc(2026, 6, 1, 11, 0) + 30, NY)
	eq(last, utc(2026, 6, 1, 11, 0), "latest")
	eq(n, 30, "30 in an hour")
	local _, capped = sched.latest(rule("every 1m"), utc(2026, 6, 1, 0, 0), utc(2026, 6, 3, 0, 0), NY, 100)
	eq(capped, 100, "capped")
	local none, zero = sched.latest(r, utc(2026, 6, 1, 10, 0), utc(2026, 6, 1, 10, 1), NY)
	check(none == nil and zero == 0, "none yet")
end)

-- Definitions --------------------------------------------------------------------------------

local PROJECTS = { { id = "app", name = "App", root = "/src/app" } }

local function cfg_of(list, extra)
	local doc = { automations = list }
	for k, v in extra or {} do
		doc[k] = v
	end
	return automate.parse(doc, PROJECTS, "/Users/me")
end

local function def(o)
	local d = { name = o.name or "Job", schedule = o.schedule or "every 2m", prompt = o.prompt or "do it", project = "app" }
	for k, v in o do
		d[k] = v
	end
	return d
end

test("parse: defaults, project, cwd and ~, ids", function()
	local c = cfg_of({
		def({ name = "Nightly review" }),
		{ name = "Here", schedule = "hourly", prompt = "p", cwd = "~/x", run_in = "pane", model = "haiku", args = { "--thinking", "low" } },
		{ id = "custom_1", name = "Named", schedule = "daily 09:00", prompt = "p", project = "App", enabled = false },
	})
	eq(#c.errors, 0, "no errors")
	eq(#c.defs, 3, "three")
	local a = c.defs[1]
	eq(a.id, "nightly-review", "id from the name")
	eq(a.cwd, "/src/app", "project root")
	eq(a.run_in, "headless", "headless by default")
	eq(a.missed, "run_once", "catch-up by default")
	eq(a.timeout, automate.TIMEOUT_MIN * 60, "default timeout")
	check(a.enabled, "enabled by default")
	eq(c.defs[2].cwd, "/Users/me/x", "~ expanded")
	eq(c.defs[2].args[2], "low", "args")
	eq(c.defs[3].project, "app", "project by name")
	check(not c.defs[3].enabled, "disabled")
	eq(c.max_concurrent, automate.MAX_CONCURRENT, "default cap")
	eq(cfg_of({}, { max_concurrent = 99 }).max_concurrent, automate.MAX_CONCURRENT_LIMIT, "cap bounded")
end)

test("parse: a bad entry is reported and left out, the rest run", function()
	local c = cfg_of({
		def({ name = "Good" }),
		def({ name = "Bad schedule", schedule = "sometimes" }),
		def({ name = "No prompt", prompt = "" }),
		def({ name = "Good" }),
		{ name = "Nowhere", schedule = "hourly", prompt = "p" },
		{ name = "Relative", schedule = "hourly", prompt = "p", cwd = "x" },
		def({ name = "Mode", run_in = "window" }),
		def({ name = "Ghost project", project = "nope" }),
		def({ name = "Short", timeout_minutes = 0.5 }),
	})
	eq(#c.defs, 1, "one good")
	eq(#c.errors, 8, "eight problems")
	check(string.find(c.errors[1], "Bad schedule", 1, true) ~= nil, "names the entry")
	check(string.find(c.errors[3], "duplicate id good", 1, true) ~= nil, "duplicate id")
	eq(#automate.parse("nope", PROJECTS).errors, 1, "not an object")
	local never = automate.parse({ automations = { def({ name = "Feb 31", schedule = "0 0 31 2 *" }) } }, PROJECTS, nil, utc(2026, 6, 1, 0, 0), NY)
	check(#never.defs == 0 and string.find(never.errors[1], "never comes", 1, true) ~= nil, "a schedule that never comes")
end)

-- The scheduler ------------------------------------------------------------------------------

local T0 = utc(2026, 6, 1, 10, 0) + 30

local function runs_of(st, auto)
	local out = {}
	for _, r in st.runs do
		if auto == nil or r.auto == auto then
			table.insert(out, r)
		end
	end
	return out
end

test("first tick schedules; an on-time tick queues and starts one run", function()
	local c = cfg_of({ def({ name = "A" }) })
	local st = automate.normalize(nil)
	local p = automate.plan(st, c, T0, NY)
	check(p.changed, "changed")
	eq(#st.runs, 0, "never retroactive")
	eq(st.slots.a.next_at, utc(2026, 6, 1, 10, 2), "next at")
	p = automate.plan(st, c, utc(2026, 6, 1, 10, 2) + 3, NY)
	eq(#p.start, 1, "starts")
	eq(p.start[1].trigger, "scheduled", "scheduled")
	eq(p.start[1].id, "a-1", "run id")
	eq(st.slots.a.next_at, utc(2026, 6, 1, 10, 4), "advanced")
end)

test("missed runs: run once on start (catch-up), with the count", function()
	local c = cfg_of({ def({ name = "A" }) })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	-- Tern was down for an hour; back 105 s after the latest occurrence (on time is within 90 s).
	local back = utc(2026, 6, 1, 11, 1) + 45
	local p = automate.plan(st, c, back, NY)
	eq(#p.start, 1, "one run")
	local r = p.start[1]
	eq(r.trigger, "catchup", "catch-up")
	eq(r.scheduled_for, utc(2026, 6, 1, 11, 0), "for the latest missed occurrence")
	eq(r.note, "catch-up for 30 missed runs", "count")
	eq(st.slots.a.next_at, utc(2026, 6, 1, 11, 2), "then on schedule")
end)

test("missed runs: skip policy and grace record one folded row", function()
	local c = cfg_of({ def({ name = "A", missed = "skip" }), def({ name = "B", schedule = "hourly", grace_minutes = 10 }) })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	-- Back at 11:31:45: A's latest (11:30) is 105 s late, B's (11:00) 31 min, beyond its 10 min grace.
	local p = automate.plan(st, c, utc(2026, 6, 1, 11, 31) + 45, NY)
	eq(#p.start, 0, "nothing runs")
	local a = runs_of(st, "a")
	eq(#a, 1, "one row")
	eq(a[1].status, "skipped_missed", "missed")
	eq(a[1].count, 45, "45 folded")
	eq(runs_of(st, "b")[1].status, "skipped_missed", "beyond grace")
	-- Down again: the same row folds the next batch.
	automate.plan(st, c, utc(2026, 6, 1, 12, 31) + 45, NY)
	eq(#runs_of(st, "a"), 1, "still one row")
	eq(runs_of(st, "a")[1].count, 75, "75 folded")
	-- Within grace it runs, once, as a catch-up.
	local cb = cfg_of({ def({ name = "B", schedule = "hourly", grace_minutes = 10 }) })
	local st2 = automate.normalize(nil)
	automate.plan(st2, cb, T0, NY)
	local p2 = automate.plan(st2, cb, utc(2026, 6, 1, 11, 8), NY)
	eq(#p2.start, 1, "b within grace runs")
	eq(p2.start[1].trigger, "catchup", "as a catch-up")
end)

test("one run at a time per automation: a busy occurrence is skipped, folded", function()
	local c = cfg_of({ def({ name = "A" }) })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	local p = automate.plan(st, c, utc(2026, 6, 1, 10, 2) + 2, NY)
	p.start[1].status = "running"
	automate.plan(st, c, utc(2026, 6, 1, 10, 4) + 2, NY)
	automate.plan(st, c, utc(2026, 6, 1, 10, 6) + 2, NY)
	local a = runs_of(st, "a")
	eq(#a, 2, "running + one skipped row")
	eq(a[2].status, "skipped_busy", "busy")
	eq(a[2].count, 2, "two occurrences")
	-- A manual run while one runs is skipped too.
	eq(automate.enqueue(st, c.defs[1], "manual", T0, T0), nil, "manual skipped")
end)

test("the concurrency cap holds queued runs until a slot frees", function()
	local c = cfg_of({ def({ name = "A" }), def({ name = "B" }), def({ name = "C" }) }, { max_concurrent = 2 })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	local due = utc(2026, 6, 1, 10, 2) + 2
	local p = automate.plan(st, c, due, NY)
	eq(#p.start, 2, "two start")
	for _, r in p.start do
		r.status = "running"
	end
	p = automate.plan(st, c, due + 2, NY)
	eq(#p.start, 0, "third waits")
	eq(runs_of(st, "c")[1].status, "queued", "queued")
	automate.finish(runs_of(st, "a")[1], "done", due + 30, "ok", 0)
	p = automate.plan(st, c, due + 32, NY)
	eq(#p.start, 1, "slot freed")
	eq(p.start[1].auto, "c", "c starts")
	-- waiting_window and precheck hold slots too.
	p.start[1].status = "waiting_window"
	automate.plan(st, c, due + 34, NY)
	local m = automate.enqueue(st, c.defs[1], "manual", due + 35, due + 35)
	p = automate.plan(st, c, due + 36, NY)
	eq(#p.start, 0, "cap counts waiting_window")
	check(m ~= nil and m.status == "queued", "manual queued")
end)

test("disable, enable and a changed schedule never run retroactively", function()
	local doc = { def({ name = "A" }) }
	local c = cfg_of(doc)
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	doc[1].enabled = false
	c = cfg_of(doc)
	automate.plan(st, c, T0 + 10, NY)
	eq(st.slots.a.next_at, nil, "disabled: no next run")
	doc[1].enabled = true
	c = cfg_of(doc)
	local back = utc(2026, 6, 1, 12, 0) + 30
	local p = automate.plan(st, c, back, NY)
	eq(#p.start, 0, "re-enabled: nothing for the paused time")
	eq(st.slots.a.next_at, utc(2026, 6, 1, 12, 2), "from now")
	doc[1].schedule = "hourly"
	c = cfg_of(doc)
	automate.plan(st, c, back + 1, NY)
	eq(st.slots.a.next_at, utc(2026, 6, 1, 13, 0), "rescheduled")
end)

test("removing an automation cancels its queued runs; prune drops its history", function()
	local c = cfg_of({ def({ name = "A" }), def({ name = "B" }) }, { max_concurrent = 1 })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	local p = automate.plan(st, c, utc(2026, 6, 1, 10, 2) + 2, NY)
	p.start[1].status = "running"
	c = cfg_of({ def({ name = "A" }) }, { max_concurrent = 1 })
	automate.plan(st, c, utc(2026, 6, 1, 10, 2) + 4, NY)
	eq(runs_of(st, "b")[1].status, "canceled", "b's queued run canceled")
	local removed = automate.prune(st, c)
	eq(#removed, 1, "b's run removed")
	eq(st.slots.b, nil, "b's slot removed")
	eq(#runs_of(st, "a"), 1, "a's running run kept")
end)

test("retention keeps the newest finished runs and every active one", function()
	local c = cfg_of({ def({ name = "A" }) })
	local st = automate.normalize(nil)
	for i = 1, 60 do
		local r = automate.enqueue(st, c.defs[1], "manual", T0 + i, T0 + i)
		automate.finish(r, if i % 2 == 0 then "done" else "failed", T0 + i, "r" .. i, 0)
	end
	local live = automate.enqueue(st, c.defs[1], "manual", T0 + 100, T0 + 100)
	local removed = automate.prune(st, c, 50)
	eq(#removed, 10, "ten oldest go")
	eq(removed[1].id, "a-1", "oldest first")
	eq(#st.runs, 51, "50 finished + the active one")
	eq(st.runs[1].id, "a-11", "a-11 is now the oldest")
	check(automate.find_run(st, live.id) ~= nil, "active kept")
	eq(#automate.prune(st, c, 50), 0, "stable")
end)

test("state survives the kv round trip", function()
	local c = cfg_of({ def({ name = "A" }) })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	local r = automate.enqueue(st, c.defs[1], "manual", T0, T0)
	r.status, r.pid, r.out = "running", 42, "/tmp/x.md"
	local back = automate.normalize(json.decode(t.encode_json(automate.encode(st, function(x)
		return x
	end))))
	eq(back.slots.a.next_at, st.slots.a.next_at, "slot")
	eq(back.runs[1].status, "running", "run")
	eq(back.runs[1].out, "/tmp/x.md", "out")
	eq(#automate.normalize({ runs = { { id = 1 } }, slots = 5 }).runs, 0, "junk dropped")
end)

-- Runs -----------------------------------------------------------------------------------------

test("headless command: print mode, time limit, model, args, then the prompt", function()
	local c = cfg_of({ def({ name = "A", model = "haiku", args = { "--thinking", "low" }, timeout_minutes = 5, prompt = "-x go" }) })
	local argv = automate.headless_argv(c.defs[1], "/bin/omp")
	eq(table.concat(argv, "|"), "/bin/omp|-p|--max-time|300|--model|haiku|--thinking|low| -x go", "argv")
end)

test("summary: the first line of the answer, headings unmarked, cut", function()
	eq(automate.summarize("\n\n## Result\nall good"), "Result", "heading text")
	eq(automate.summarize("  pong  \nmore"), "pong", "first line")
	eq(automate.summarize(string.rep("x", 300), 10), string.rep("x", 9) .. "…", "cut")
	eq(automate.summarize("\n \n"), nil, "nothing")
end)

test("the definitions file is rewritten stably and decodes back", function()
	local doc = {
		version = 1,
		max_concurrent = 2,
		automations = {
			{ prompt = "p \"q\"", name = "A", schedule = "every 2m", enabled = false, id = "a", args = { "--x" }, zzz = 1 },
		},
	}
	local text = automate.pretty(doc, t.encode_json, function(x)
		return x
	end)
	local back = json.decode(text)
	eq(back.automations[1].prompt, 'p "q"', "prompt")
	eq(back.automations[1].enabled, false, "enabled")
	eq(back.automations[1].args[1], "--x", "args")
	eq(back.automations[1].zzz, 1, "unknown keys kept")
	check(string.find(text, '"id": "a",\n      "name": "A"', 1, true) ~= nil, "id then name")
	eq(automate.pretty(doc, t.encode_json, function(x)
		return x
	end), text, "stable")
	eq(json.decode(automate.pretty({ version = 1 }, t.encode_json, function(x)
		return x
	end)).automations[1], nil, "empty list")
end)

-- The view and the sidebar -------------------------------------------------------------------

test("view: pending pane runs, running panes, recent runs newest first", function()
	local c = cfg_of({ def({ name = "A", run_in = "pane" }), def({ name = "B" }) })
	local st = automate.normalize(nil)
	automate.plan(st, c, T0, NY)
	local r1 = automate.enqueue(st, c.defs[1], "manual", T0, T0)
	r1.status, r1.pane, r1.started = "running", 7, T0
	local r2 = automate.enqueue(st, c.defs[2], "manual", T0, T0)
	automate.finish(r2, "done", T0 + 5, "ok", 0)
	local r3 = automate.enqueue(st, c.defs[2], "manual", T0 + 6, T0 + 6)
	automate.finish(r3, "failed", T0 + 9, "boom", 1)
	local v = automate.view(st, c, T0 + 10)
	eq(#v.panes, 1, "one running pane")
	eq(v.panes[1].pane, 7, "its pane")
	eq(v.autos[2].runs[1].id, r3.id, "newest first")
	eq(v.autos[1].next_at, st.slots.a.next_at, "next")
	r1.status, r1.pane = "waiting_window", nil
	r1.deadline = T0 + 20
	v = automate.view(st, c, T0 + 10)
	eq(#v.pending, 1, "pending")
	eq(v.pending[1].prompt, "do it", "carries the prompt")
	eq(v.pending[1].project, "app", "and the project")
end)

-- support.ui plus `el`.
local ui = {}
for k, v in t.ui do
	ui[k] = v
end
ui.el = function(tag, p, c)
	local props = { tag = tag }
	for k, v in p or {} do
		props[k] = v
	end
	local n = { k = "el", p = props }
	if c ~= nil and #c > 0 then
		n.c = c
	end
	return n
end
sidebar.ui = ui

local function autos_snap()
	return {
		list = {
			{
				id = "nightly",
				name = "Nightly",
				enabled = true,
				label = "Daily at 09:00",
				run_in = "headless",
				next_at = T0 + 240,
				last = { id = "nightly-3", n = 3, status = "done", summary = "all good", ended = T0 - 120, out = "/tmp/o.md" },
			},
			{
				id = "pr",
				name = "PR sweep",
				enabled = false,
				label = "Every 2 min",
				run_in = "pane",
				active = { id = "pr-9", n = 9, status = "running", started = T0 - 60, pane = 12, mode = "pane" },
			},
		},
		errors = { "automations[3] (X): schedule: unknown schedule" },
		open = true,
		running = 1,
	}
end

local function find(view, id)
	return t.find(view, sidebar.ROOT_ID, sidebar.ROOT_ID .. ".list." .. id)
end

test("sidebar: the Automations section", function()
	local snap = { projects = {}, now = T0, autos = autos_snap() }
	local out = sidebar.build(snap)
	local sec = find(out.view, "autos")
	check(sec ~= nil, "section drawn")
	local head = find(out.view, "autos.head")
	eq(head.p.actions.click, "toggle_group=automations", "header collapses")
	eq(find(out.view, "autos.head.sum").p.text, "2 · 1 running", "summary")
	eq(find(out.view, "autos.head.acts.new").p.actions.click, "auto_new", "new")
	eq(find(out.view, "autos.head.acts.more").p.actions.click, "auto_edit", "edit file")
	check(find(out.view, "autos.err1") ~= nil, "file problems shown")
	local row = find(out.view, "autos.a_nightly")
	eq(row.p.actions.click, "auto_runs=nightly", "row opens its runs")
	eq(find(out.view, "autos.a_nightly.top.s").p.text, "next in 4m · Daily at 09:00", "next run")
	eq(find(out.view, "autos.a_nightly.last.l").p.text, "Done: all good", "last result")
	eq(find(out.view, "autos.a_nightly.last.time").p.text, "2m", "its age")
	eq(find(out.view, "autos.a_nightly.top.acts.run").p.actions.click, "auto_run=nightly", "run now")
	eq(find(out.view, "autos.a_nightly.top.acts.tog").p.actions.click, "auto_toggle=nightly", "pause")
	eq(find(out.view, "autos.a_nightly.top.acts.open").p.actions.click, "auto_open=nightly", "open output")
	local pr = find(out.view, "autos.a_pr")
	check(string.find(pr.p.class, "op-off", 1, true) ~= nil and string.find(pr.p.class, "op-run", 1, true) ~= nil, "paused and running")
	eq(find(out.view, "autos.a_pr.top.s").p.text, "paused · Every 2 min", "paused")
	eq(find(out.view, "autos.a_pr.last.l").p.text, "Running", "running")
	eq(find(out.view, "autos.a_pr.last.st").p.class, "op-st op-st-sm op-working", "spinner")
	-- Collapsed: the header only.
	snap.autos.open = false
	out = sidebar.build(snap)
	eq(find(out.view, "autos.a_nightly"), nil, "collapsed")
	check(string.find(find(out.view, "autos").p.class, "collapsed", 1, true) ~= nil, "collapsed class")
	-- None yet: a hint row that adds one.
	out = sidebar.build({ projects = {}, now = T0, autos = { list = {}, errors = {}, open = true, running = 0 } })
	eq(find(out.view, "autos.none").p.actions.click, "auto_new", "hint adds one")
	eq(sidebar.parse_action({ act = "auto_run", value = "nightly" }), "auto_run", "auto actions parse")
end)

test("next-run labels", function()
	eq(sidebar.when(T0, T0 + 30), "in <1m", "<1m")
	eq(sidebar.when(T0, T0 + 600), "in 10m", "minutes")
	check(string.match(sidebar.when(T0, T0 + 3 * 86400), "^%a%a%a %d%d:%d%d$") ~= nil, "a later day")
end)

t.finish("automations")
