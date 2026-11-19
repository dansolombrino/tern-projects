--!strict
-- projects, mailq: the fleet mailbox's queue (protocol v1, README "Fleet mailbox"). The host half owns it: it is
-- the only writer of kv key `mailbox.v1`, so a reply of `queued` means the message is in kv.json. The window half
-- reads it, delivers with `cx.agents:ask` when the target is idle, and reports each delivery back through a spool
-- file the host applies.
--
-- Pure: no `tern` calls, so tests run it as is.

local mailq = {}

mailq.VERSION = 1
mailq.KEY = "mailbox.v1"

-- Limits: a message's text in bytes, an id's length, queued messages in all and per target.
mailq.MAX_TEXT = 65536
mailq.MAX_ID = 200
mailq.MAX_QUEUED = 500
mailq.MAX_PER_TARGET = 50
-- Delivered and failed records (their text dropped) are kept this long, so `status` answers and a repeated id is
-- still one delivery, then dropped (seconds); at most MAX_KEPT of them, oldest dropped first.
mailq.KEEP = 7 * 24 * 3600
mailq.MAX_KEPT = 5000
-- A message still queued after this long fails as `expired` (seconds).
mailq.EXPIRE = 7 * 24 * 3600

export type Target = { pane: number?, cwd: string?, session_file: string? }

export type Msg = {
	id: string,
	seq: number,
	target: Target,
	text: string,
	from: string,
	state: "queued" | "delivered" | "failed",
	created: number,
	updated: number,
	error: string?,
	-- The pane it was delivered to.
	pane: number?,
}

export type Box = { seq: number, msgs: { Msg } }

export type Agent = { pane: number, cwd: string, state: string }

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- An empty queue.
function mailq.empty(): Box
	return { seq = 0, msgs = {} }
end

-- Repairs a decoded kv value into a Box (bad entries dropped).
function mailq.normalize(raw: any): Box
	local box = mailq.empty()
	if type(raw) ~= "table" then
		return box
	end
	box.seq = if type(raw.seq) == "number" then raw.seq else 0
	if type(raw.msgs) == "table" then
		for _, m in raw.msgs do
			if type(m) == "table" and str(m.id) and type(m.text) == "string" and type(m.seq) == "number" then
				local t = if type(m.target) == "table" then m.target else {}
				local state = if m.state == "delivered" or m.state == "failed" then m.state else "queued"
				table.insert(box.msgs, {
					id = m.id,
					seq = m.seq,
					target = { pane = if type(t.pane) == "number" then t.pane else nil, cwd = str(t.cwd), session_file = str(t.session_file) },
					text = m.text,
					from = str(m.from) or "",
					state = state,
					created = if type(m.created) == "number" then m.created else 0,
					updated = if type(m.updated) == "number" then m.updated else 0,
					error = str(m.error),
					pane = if type(m.pane) == "number" then m.pane else nil,
				})
				if m.seq > box.seq then
					box.seq = m.seq
				end
			end
		end
	end
	table.sort(box.msgs, function(a, b)
		return a.seq < b.seq
	end)
	return box
end

local function find(box: Box, id: string): Msg?
	for _, m in box.msgs do
		if m.id == id then
			return m
		end
	end
	return nil
end
mailq.find = find

-- A request's target, or nil plus why it is malformed.
local function target_of(raw: any): (Target?, string?)
	if type(raw) ~= "table" then
		return nil, "target must be an object"
	end
	local pane = raw.pane
	if pane == (nil :: any) or type(pane) ~= "number" then
		pane = nil
	elseif pane ~= math.floor(pane) or pane <= 0 then
		return nil, "target.pane must be a positive integer"
	end
	local t: Target = { pane = pane, cwd = str(raw.cwd), session_file = str(raw.session_file) }
	if t.pane == nil and t.cwd == nil and t.session_file == nil then
		return nil, "target needs pane, cwd or session_file"
	end
	for _, p in { t.cwd, t.session_file } do
		if p and string.sub(p :: string, 1, 1) ~= "/" then
			return nil, "target paths must be absolute"
		end
	end
	return t, nil
end

-- The pane `target` names now: its live agent pane, else the agent running its omp session file, else the one
-- agent whose folder is `cwd`. `agents` lists live agents; `sessions` maps panes to omp session files;
-- `canon` normalizes folders.
function mailq.resolve(target: Target, agents: { Agent }, sessions: { [number]: string }, canon: (string?) -> string?): number?
	if target.pane then
		for _, a in agents do
			if a.pane == target.pane and a.state ~= "exited" then
				return a.pane
			end
		end
	end
	if target.session_file then
		for _, a in agents do
			if sessions[a.pane] == target.session_file and a.state ~= "exited" then
				return a.pane
			end
		end
	end
	if target.cwd then
		local want = canon(target.cwd)
		local hit: number? = nil
		for _, a in agents do
			if a.state ~= "exited" and canon(a.cwd) == want then
				if hit then
					return nil
				end
				hit = a.pane
			end
		end
		return hit
	end
	return nil
end

local function same_target(a: Target, b: Target): boolean
	return a.pane == b.pane and a.cwd == b.cwd and a.session_file == b.session_file
end

local function reply_of(m: Msg): { [string]: any }
	return { ok = true, id = m.id, state = m.state }
end

local function fail(code: string, message: string): { [string]: any }
	return { ok = false, error = code, message = message }
end

-- Handles a `deliver` request (already decoded). `resolvable(target)` says whether something matches the target
-- now; the message is stored only then. Returns the reply and whether the box changed (to save before replying).
function mailq.submit(box: Box, req: any, now: number, resolvable: (Target) -> boolean): ({ [string]: any }, boolean)
	local id = str(req.id)
	if id == nil or #(id :: string) > mailq.MAX_ID then
		return fail("bad-request", "id must be a non-empty string of at most " .. mailq.MAX_ID .. " bytes"), false
	end
	if type(req.text) ~= "string" or string.match(req.text, "^%s*$") then
		return fail("bad-request", "text must be a non-blank string"), false
	end
	if #req.text > mailq.MAX_TEXT then
		return fail("bad-request", "text is over " .. mailq.MAX_TEXT .. " bytes"), false
	end
	local target, why = target_of(req.target)
	if target == nil then
		return fail("bad-request", why or "bad target"), false
	end
	local known = find(box, id :: string)
	if known then
		-- Same id twice is one delivery: the first message stands.
		return reply_of(known), false
	end
	if not resolvable(target :: Target) then
		return fail("no-target", "no live agent matches the target now; the message was not stored"), false
	end
	local queued, here = 0, 0
	for _, m in box.msgs do
		if m.state == "queued" then
			queued += 1
			if same_target(m.target, target :: Target) then
				here += 1
			end
		end
	end
	if queued >= mailq.MAX_QUEUED or here >= mailq.MAX_PER_TARGET then
		return fail("busy", string.format("%d messages queued (%d for this target); retry later", queued, here)), false
	end
	box.seq += 1
	local m: Msg = {
		id = id :: string,
		seq = box.seq,
		target = target :: Target,
		text = req.text,
		from = str(req.from) or "",
		state = "queued",
		created = now,
		updated = now,
	}
	table.insert(box.msgs, m)
	return reply_of(m), true
end

-- Handles a `status` request.
function mailq.status(box: Box, req: any): { [string]: any }
	local id = str(req.id)
	if id == nil then
		return fail("bad-request", "id must be a non-empty string")
	end
	local m = find(box, id :: string)
	if m == nil then
		return { ok = true, id = id, state = "unknown", error = nil }
	end
	return { ok = true, id = m.id, state = m.state, error = m.error }
end

-- Applies the window's report on a message: `{id, state = "delivered" | "failed", pane?, error?}`. True when the
-- box changed. A message already delivered or failed stays as it is.
function mailq.apply(box: Box, ack: any, now: number): boolean
	local id = str(ack.id)
	local m = if id then find(box, id :: string) else nil
	if m == nil or m.state ~= "queued" then
		return false
	end
	if ack.state == "delivered" then
		m.state = "delivered"
		m.pane = if type(ack.pane) == "number" then ack.pane else nil
	elseif ack.state == "failed" then
		m.state = "failed"
		m.error = str(ack.error) or "failed"
	else
		return false
	end
	m.updated = now
	m.text = ""
	return true
end

-- Drops delivered and failed records past KEEP (or past MAX_KEPT of them) and fails messages queued past EXPIRE.
-- True when it changed.
function mailq.prune(box: Box, now: number): boolean
	local changed = false
	local finished = 0
	for _, m in box.msgs do
		if m.state == "queued" and now - m.created >= mailq.EXPIRE then
			m.state, m.error, m.updated, m.text = "failed", "expired", now, ""
			changed = true
		end
		if m.state ~= "queued" then
			finished += 1
		end
	end
	local drop = finished - mailq.MAX_KEPT
	local kept: { Msg } = {}
	for _, m in box.msgs do
		if m.state ~= "queued" and (now - m.updated >= mailq.KEEP or drop > 0) then
			drop -= 1
			changed = true
		else
			table.insert(kept, m)
		end
	end
	box.msgs = kept
	return changed
end

-- The queued messages that can go out now, one per target pane: the oldest message resolving to each pane whose
-- agent is idle or waiting for input and is not in `hold` (a pane asked recently). FIFO per pane by `seq`.
function mailq.deliverable(box: Box, agents: { Agent }, sessions: { [number]: string }, canon: (string?) -> string?, hold: { [number]: boolean }): { { msg: Msg, pane: number } }
	local state_of: { [number]: string } = {}
	for _, a in agents do
		state_of[a.pane] = a.state
	end
	local first: { [number]: Msg } = {}
	local order: { number } = {}
	for _, m in box.msgs do
		if m.state == "queued" then
			local p = mailq.resolve(m.target, agents, sessions, canon)
			if p and first[p] == nil then
				first[p] = m
				table.insert(order, p)
			end
		end
	end
	local out: { { msg: Msg, pane: number } } = {}
	for _, p in order do
		local s = state_of[p]
		if (s == "idle" or s == "waiting_input") and not hold[p] then
			table.insert(out, { msg = first[p], pane = p })
		end
	end
	return out
end

-- Whether any message is queued.
function mailq.pending(box: Box): boolean
	for _, m in box.msgs do
		if m.state == "queued" then
			return true
		end
	end
	return false
end

-- The box as kv stores it.
function mailq.encode(box: Box, array: <T>(T) -> T): any
	return { seq = box.seq, msgs = array(box.msgs) }
end

return mailq
