--!strict
-- projects, identity: which live agent pane each agent record belongs to. Pane ids are not stable (a Tern restart
-- or cold restore gives every pane a new one), so records are keyed by an opaque id of their own and carry what
-- does survive: the omp session file the agent writes, its worktree and its folder. `bind` re-attaches records to
-- panes after every agent scan, in this order:
--
-- 1. the pane the record was last bound to, while that pane is live (omp's /new in it changes the file: the
--    record follows), unless another record owns the session file that pane runs now;
-- 2. the live pane whose omp session file is the record's (`omp --restore` reopens the same file);
-- 3. for a top-level record that owns a worktree, the one unclaimed live pane working in that worktree;
-- 4. for any other record with a folder and no session file yet, the one unclaimed live pane in that folder,
--    when exactly one such record wants it.
--
-- Pure: no `tern` calls, so tests run it as is.

local identity = {}

export type Record = {
	pane: number?,
	session_file: string?,
	worktree: string?,
	cwd: string?,
	parent: string?,
	started: number?,
	closed: boolean?,
	closed_at: number?,
	lost_at: number?,
	[string]: any,
}

export type Live = { [number]: { cwd: string } }

-- A record this young (seconds since `started`) is never put to sleep or marked lost: its pane may not be listed
-- as an agent yet.
identity.GRACE = 20
-- Records lost (no live pane) this long without a worktree to sleep in are forgotten, in seconds.
identity.FORGET_AFTER = 3600

-- /private/tmp and /tmp (and /private/var, /var) are one folder on macOS.
local function canon(path: string?): string?
	if path == nil or path == "" then
		return nil
	end
	local p = string.gsub(path, "/+$", "")
	if p == "" then
		p = "/"
	end
	local rest = string.match(p, "^/private(/.*)$")
	if rest and (string.sub(rest, 1, 5) == "/tmp/" or rest == "/tmp" or string.sub(rest, 1, 5) == "/var/" or rest == "/var") then
		p = rest
	end
	return p
end
identity.canon = canon

-- Binds records to live panes (see the header); mutates `records` (pane, session_file, closed, lost_at) and
-- returns pane → record key and whether any record changed (the caller saves them).
-- `sessions` maps a live pane to its omp session file when known; `now` is os.time().
function identity.bind(records: { [string]: Record }, live: Live, sessions: { [number]: string }, now: number): ({ [number]: string }, boolean)
	local by_pane: { [number]: string } = {}
	local changed = false
	local keys: { string } = {}
	for k in records do
		table.insert(keys, k)
	end
	-- Deterministic order: lower keys win ties.
	table.sort(keys)
	local function claim(key: string, pane: number)
		local r = records[key]
		by_pane[pane] = key
		if r.pane ~= pane then
			r.pane = pane
			changed = true
		end
		if r.closed or r.closed_at or r.lost_at then
			r.closed, r.closed_at, r.lost_at = nil, nil, nil
			changed = true
		end
		local sf = sessions[pane]
		if sf and r.session_file ~= sf then
			r.session_file = sf
			changed = true
		end
	end
	local bound: { [string]: boolean } = {}
	local owner_of_session: { [string]: string } = {}
	for _, k in keys do
		local sf = records[k].session_file
		if sf and owner_of_session[sf :: string] == nil then
			owner_of_session[sf :: string] = k
		end
	end
	-- 1. Still on its pane.
	for _, k in keys do
		local r = records[k]
		local p = r.pane
		if p and live[p] and by_pane[p] == nil then
			local sf = sessions[p]
			local owner = if sf then owner_of_session[sf] else nil
			if owner == nil or owner == k then
				claim(k, p)
				bound[k] = true
			end
		end
	end
	-- 2. Its omp session file is open in another pane.
	local pane_of_session: { [string]: number } = {}
	for p, sf in sessions do
		if live[p] and by_pane[p] == nil then
			pane_of_session[sf] = p
		end
	end
	for _, k in keys do
		local r = records[k]
		if not bound[k] and r.session_file then
			local p = pane_of_session[r.session_file :: string]
			if p and by_pane[p] == nil then
				claim(k, p)
				bound[k] = true
			end
		end
	end
	-- 3 and 4: by folder, when exactly one unclaimed pane works there.
	local unclaimed: { [string]: { number } } = {}
	for p, b in live do
		local c = canon(b.cwd)
		if by_pane[p] == nil and c then
			local list = unclaimed[c] or {}
			table.insert(list, p)
			unclaimed[c] = list
		end
	end
	local function only(c: string?): number?
		local list = if c then unclaimed[c] else nil
		return if list and #list == 1 then list[1] else nil
	end
	-- A pane running a session file some record owns belongs to that record, never to a folder match.
	local function free(p: number): boolean
		local sf = sessions[p]
		return sf == nil or owner_of_session[sf] == nil
	end
	for _, k in keys do
		local r = records[k]
		if not bound[k] and r.worktree and r.parent == nil then
			local c = canon(r.worktree)
			local p = only(c)
			if p and free(p) then
				claim(k, p)
				bound[k] = true
				unclaimed[c :: string] = nil
			end
		end
	end
	local wanting: { [string]: { string } } = {}
	for _, k in keys do
		local r = records[k]
		if not bound[k] and not r.closed and r.session_file == nil then
			local c = canon(r.cwd)
			if c then
				local list = wanting[c] or {}
				table.insert(list, k)
				wanting[c] = list
			end
		end
	end
	for c, list in wanting do
		local p = only(c)
		if p and #list == 1 and free(p) then
			claim(list[1], p)
			bound[list[1]] = true
			unclaimed[c] = nil
		end
	end
	-- The rest have no live pane: worktree owners sleep as cards, others are forgotten after a while (a restart
	-- restores panes late, so they get time to come back).
	for _, k in keys do
		local r = records[k]
		local young = type(r.started) == "number" and now - (r.started :: number) < identity.GRACE
		if not bound[k] and not young then
			if r.worktree and r.parent == nil then
				if not r.closed then
					r.closed, r.closed_at = true, now
					changed = true
				end
			elseif r.lost_at == nil then
				r.lost_at = now
				changed = true
			elseif now - (r.lost_at :: number) >= identity.FORGET_AFTER then
				records[k] = nil
				changed = true
			end
		end
	end
	return by_pane, changed
end

return identity
