--!strict
-- projects, schedules (pure): parses an automation's schedule and finds its occurrences.
--
-- Forms (README "Automations"): `every 2m`, `every 90m`, `every 2h` (absolute intervals counted from the Unix
-- epoch, so `every 2m` fires on even minutes whatever the zone); `hourly` (at :00) and `hourly :15`;
-- `daily 09:00`; `weekdays 09:00`; `weekly mon 09:00` (or `weekly 1 09:00`, Sunday 0); and 5-field cron
-- (`0 9 * * 1-5`: lists, ranges, steps, `*`, month and day names, 7 = Sunday; when both day fields are
-- restricted either one matches, as in Vixie cron).
--
-- Wall-clock forms follow the calendar `cal` gives (the machine's local zone by default). Daylight saving: a
-- wall time the spring-forward gap skips does not occur that day; a wall time the fall-back hour repeats occurs
-- once, at its first (earlier) instant. Occurrences are whole minutes.

local sched = {}

-- Wall-clock fields of an instant: what `os.date("*t", t)` gives (month 1-12, wday 1 = Sunday).
export type Fields = { year: number, month: number, day: number, hour: number, min: number, sec: number, wday: number }
export type Calendar = { fields: (t: number) -> Fields }

export type Rule = {
	kind: "every" | "cron",
	-- every: the period in seconds.
	period: number?,
	-- cron: allowed values as sets.
	minutes: { [number]: boolean }?,
	hours: { [number]: boolean }?,
	doms: { [number]: boolean }?,
	months: { [number]: boolean }?,
	-- 0 = Sunday.
	dows: { [number]: boolean }?,
	dom_any: boolean?,
	dow_any: boolean?,
	label: string,
}

-- The machine's local calendar (Luau's os.date reads the process zone, `TZ` included).
sched.LOCAL = {
	fields = function(t: number): Fields
		return os.date("*t", t) :: any
	end,
} :: Calendar

local DOW_NAMES = { sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6 }
local MONTH_NAMES = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }
local DAY_LABEL = { [0] = "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays" }

local function clock(h: number, m: number): string
	return string.format("%02d:%02d", h, m)
end

local function parse_hm(s: string): (number?, number?)
	local h, m = string.match(s, "^(%d%d?):(%d%d)$")
	if h == nil then
		return nil, nil
	end
	local hn, mn = tonumber(h) :: number, tonumber(m) :: number
	if hn > 23 or mn > 59 then
		return nil, nil
	end
	return hn, mn
end

local function value_of(tok: string, lo: number, names: { [string]: number }?): number?
	local n = tonumber(tok)
	if n == nil and names then
		n = names[string.lower(tok)]
	end
	if n == nil or n ~= math.floor(n) then
		return nil
	end
	return n
end

-- One cron field → its set; nil and an error on a bad field.
local function field(text: string, lo: number, hi: number, names: { [string]: number }?, what: string): ({ [number]: boolean }?, string?)
	local set: { [number]: boolean } = {}
	for part in string.gmatch(text, "[^,]+") do
		local range, step = string.match(part, "^([^/]+)/(%d+)$")
		if range == nil then
			range = part
		end
		local stepn = if step then tonumber(step) :: number else 1
		if stepn < 1 then
			return nil, what .. ": step must be at least 1"
		end
		local a, b
		if range == "*" then
			a, b = lo, hi
		else
			local x, y = string.match(range :: string, "^([^-]+)-([^-]+)$")
			if x then
				a, b = value_of(x :: string, lo, names), value_of(y :: string, lo, names)
			else
				a = value_of(range :: string, lo, names)
				-- `5/15` means 5 to the end, every 15.
				b = if step then hi else a
			end
		end
		if a == nil or b == nil then
			return nil, string.format("%s: bad value %q", what, part)
		end
		local top = hi
		if what == "day of week" then
			-- 7 is Sunday too.
			top = 7
		end
		if (a :: number) < lo or (b :: number) > top or (a :: number) > (b :: number) then
			return nil, string.format("%s: %q is out of range %d-%d", what, part, lo, hi)
		end
		for v = a :: number, b :: number, stepn do
			set[if what == "day of week" and v == 7 then 0 else v] = true
		end
	end
	if next(set) == nil then
		return nil, what .. ": empty"
	end
	return set, nil
end

local function all(lo: number, hi: number): { [number]: boolean }
	local s: { [number]: boolean } = {}
	for v = lo, hi do
		s[v] = true
	end
	return s
end

local function single(v: number): { [number]: boolean }
	return { [v] = true }
end

local function cron(minutes, hours, doms, months, dows, dom_any: boolean, dow_any: boolean, label: string): Rule
	return {
		kind = "cron",
		minutes = minutes,
		hours = hours,
		doms = doms,
		months = months,
		dows = dows,
		dom_any = dom_any,
		dow_any = dow_any,
		label = label,
	}
end

-- Parses a schedule; nil and a message when it is not one of the forms above.
function sched.parse(spec: any): (Rule?, string?)
	if type(spec) ~= "string" then
		return nil, "schedule must be a string"
	end
	local s = string.lower(string.match(spec, "^%s*(.-)%s*$") or "")
	s = string.gsub(s, "%s+", " ")
	local n, unit = string.match(s, "^every (%d+) ?([mh])$")
	if n == nil then
		n, unit = string.match(s, "^every (%d+) ?(min)u?t?e?s?$")
	end
	if n == nil then
		n, unit = string.match(s, "^every (%d+) ?(hours?)$")
	end
	if n then
		local count = tonumber(n) :: number
		local per = if string.sub(unit :: string, 1, 1) == "h" then 3600 else 60
		if count < 1 or count * per > 7 * 86400 then
			return nil, "every: between 1 minute and 7 days"
		end
		local label = if per == 3600
			then (if count == 1 then "Every hour" else string.format("Every %d hours", count))
			else (if count == 1 then "Every minute" else string.format("Every %d min", count))
		return { kind = "every", period = count * per, label = label }, nil
	end
	if s == "hourly" then
		return cron(single(0), all(0, 23), all(1, 31), all(1, 12), all(0, 6), true, true, "Hourly at :00"), nil
	end
	local hm = string.match(s, "^hourly a?t? ?:(%d%d?)$")
	if hm then
		local m = tonumber(hm) :: number
		if m > 59 then
			return nil, "hourly: minute out of range"
		end
		return cron(single(m), all(0, 23), all(1, 31), all(1, 12), all(0, 6), true, true, string.format("Hourly at :%02d", m)), nil
	end
	local kind, rest = string.match(s, "^(%a+) (.+)$")
	if kind == "daily" or kind == "weekdays" then
		local h, m = parse_hm(rest :: string)
		if h == nil then
			return nil, kind .. ": time must be HH:MM"
		end
		local dows = if kind == "daily" then all(0, 6) else { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
		local label = (if kind == "daily" then "Daily at " else "Weekdays at ") .. clock(h :: number, m :: number)
		return cron(single(m :: number), single(h :: number), all(1, 31), all(1, 12), dows, true, kind == "daily", label), nil
	end
	if kind == "weekly" then
		local day, time = string.match(rest :: string, "^(%w+) (%S+)$")
		local d = if day then value_of(day, 0, DOW_NAMES) else nil
		if d == 7 then
			d = 0
		end
		local h, m = parse_hm(time or "")
		if d == nil or (d :: number) < 0 or (d :: number) > 6 or h == nil then
			return nil, "weekly: `weekly mon 09:00` (day name or 0-6, Sunday 0)"
		end
		return cron(single(m :: number), single(h :: number), all(1, 31), all(1, 12), single(d :: number), true, false, DAY_LABEL[d :: number] .. " at " .. clock(h :: number, m :: number)), nil
	end
	local f: { string } = {}
	for tok in string.gmatch(s, "%S+") do
		table.insert(f, tok)
	end
	if #f ~= 5 then
		return nil, "unknown schedule (every 30m, hourly, daily 09:00, weekdays 09:00, weekly mon 09:00, or 5-field cron)"
	end
	local minutes, e1 = field(f[1], 0, 59, nil, "minute")
	local hours, e2 = field(f[2], 0, 23, nil, "hour")
	local doms, e3 = field(f[3], 1, 31, nil, "day of month")
	local months, e4 = field(f[4], 1, 12, MONTH_NAMES, "month")
	local dows, e5 = field(f[5], 0, 6, DOW_NAMES, "day of week")
	local err = e1 or e2 or e3 or e4 or e5
	if err then
		return nil, err
	end
	-- Vixie cron: a field starting with `*` is unrestricted.
	local dom_any = string.sub(f[3], 1, 1) == "*"
	local dow_any = string.sub(f[5], 1, 1) == "*"
	return cron(minutes, hours, doms, months, dows, dom_any, dow_any, "cron " .. table.concat(f, " ")), nil
end

local function date_matches(r: Rule, w: Fields): boolean
	if not (r.months :: { [number]: boolean })[w.month] then
		return false
	end
	local dom = (r.doms :: { [number]: boolean })[w.day] == true
	local dow = (r.dows :: { [number]: boolean })[w.wday - 1] == true
	if not r.dom_any and not r.dow_any then
		return dom or dow
	end
	return dom and dow
end

-- Wall time as one comparable number (YYYYMMDDHHMM).
local function wall_key(w: Fields): number
	return ((((w.year * 100 + w.month) * 100 + w.day) * 100 + w.hour) * 100) + w.min
end

-- Scan limit: hour steps over about 8 years.
local MAX_STEPS = 80000

-- The first occurrence strictly after `after`, nil when none comes within the scan limit.
function sched.next_after(r: Rule, after: number, cal: Calendar?): number?
	if r.kind == "every" then
		local p = r.period :: number
		return (math.floor(after / p) + 1) * p
	end
	local c = cal or sched.LOCAL
	local floor_key = wall_key(c.fields(after))
	local t = math.floor(after / 60) * 60 + 60
	local mins = r.minutes :: { [number]: boolean }
	local hours = r.hours :: { [number]: boolean }
	for _ = 1, MAX_STEPS do
		local w = c.fields(t)
		if not date_matches(r, w) or not hours[w.hour] then
			-- To the next wall hour boundary.
			t += (60 - w.min) * 60 - w.sec
		elseif not mins[w.min] then
			local m = w.min + 1
			while m < 60 and not mins[m] do
				m += 1
			end
			t += (m - w.min) * 60 - w.sec
		elseif wall_key(w) <= floor_key then
			-- A repeated (fall-back) wall minute already passed: once per wall time.
			t += 60 - w.sec
		else
			return t
		end
	end
	return nil
end

-- The latest occurrence at or before `now` and after `since` (exclusive), and how many there were (capped at
-- `cap`, default 1000). nil, 0 when none.
function sched.latest(r: Rule, since: number, now: number, cal: Calendar?, cap: number?): (number?, number)
	local limit = cap or 1000
	if r.kind == "every" then
		local p = r.period :: number
		local last = math.floor(now / p) * p
		if last <= since then
			return nil, 0
		end
		local first = (math.floor(since / p) + 1) * p
		return last, math.min(limit, (last - first) // p + 1)
	end
	local count = 0
	local last: number? = nil
	local t = since
	while true do
		local nxt = sched.next_after(r, t, cal)
		if nxt == nil or nxt > now then
			break
		end
		last = nxt
		count += 1
		t = nxt
		if count >= limit then
			-- Jump: only the latest matters past the cap.
			local probe = now - 8 * 86400
			if probe > t then
				t = probe
			end
		end
		if count > limit + 20000 then
			break
		end
	end
	return last, math.min(count, limit)
end

return sched
