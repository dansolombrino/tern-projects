--!strict
-- projects, fleets: the agent-fleet adapter's state (`tern_fleet.py`, the only writer) read into a compact model the
-- sidebar draws as Orca does: fleet → groups (containers) → workers, plus the fleet's coordinator. Pure: file access
-- and JSON decoding come in through `Io`, live panes and the mailbox through `Live`, so tests drive it with tables.
-- The host half (host.luau) calls `read_states` and `build` on its clock and writes the model to `<data>/fleet.json`;
-- window halves read that file (sidebar, snapshot.luau) and add each agent's live state (`item_state`).
--
-- Layout (agent-fleet-tern's defaults.md): the root is `$AGENT_FLEET_STATE_DIR`, else `$XDG_STATE_HOME/agent-fleet`,
-- else `~/.local/state/agent-fleet`; Tern's states sit under its `.tern/`:
--
-- - `<repo id>/chats/<chat key>/state.json`: a coordinator chat (`kind: "chat"`, `adapter: "tern"`) with its `fleet`,
--   `pane` and `groups` (each with `container_path`, `branch`, `session = {id, name}`, `items`). A chat with no group
--   left, or `closed_at`, coordinates nothing. A closed group's files move to `.closed/`, which is never read.
-- - `<repo id>/<group>/state.json`: a legacy `l0-<group>` group, its own fleet (`coordinator_pane`, `session` named
--   `l0-<group>`, `items` at the top level, `worktree_path`).
--
-- Items with status `removed` are closed and not shown. The script replaces a state by writing
-- `.state.json.<pid>.tmp` and renaming it over `state.json`: a missing or unparsable file while that happens keeps the
-- last good read.

local fleet = {}

fleet.VERSION = 1
fleet.TERN_DIR = ".tern"
fleet.CHATS_DIR = "chats"

-- File access and JSON: each returns nil (or raises) when it can't.
export type Io = {
	list: (path: string) -> { string }?,
	read: (path: string) -> string?,
	decode: (text: string) -> any,
}

-- One state file read: its directory, raw text (to skip parsing an unchanged file) and decoded table.
export type Entry = { dir: string, text: string, state: any }
-- The last good read per state directory, kept between scans.
export type Cache = { [string]: Entry }

-- A pane as `tern inspect --json` lists it.
export type LivePane = { cwd: string, exited: number?, working: boolean, session_file: string? }
export type LiveSession = { id: number, name: string, panes: { [number]: boolean } }
export type Live = {
	panes: { [number]: LivePane },
	sessions: { LiveSession },
	-- Mailbox: each message's state by id, and how many wait queued per target pane.
	mail: { by_id: { [string]: string }, queued: { [number]: number } }?,
}

export type Report = { kind: string, at: number?, text: string? }

export type Item = {
	name: string,
	title: string,
	branch: string?,
	worktree: string?,
	pane: number?,
	-- The script's status: starting, start-failed, started, reported, waiting.
	status: string,
	-- live (its pane runs in its worktree), exited (the pane is there, its program ended), gone (no pane), starting.
	liveness: string,
	working: boolean,
	exit_code: number?,
	report: Report?,
	-- The mailbox state of its last report or message that went through the mailbox (queued, delivered, failed).
	mailbox: string?,
	-- Messages queued in the mailbox for its pane.
	queued: number,
}

export type Group = {
	key: string,
	name: string,
	label: string,
	branch: string?,
	worktree: string?,
	session_id: number?,
	session_name: string?,
	-- The group's Tern session exists now.
	session_live: boolean,
	creating: boolean,
	color: string,
	items: { Item },
}

export type Coordinator = {
	pane: number?,
	title: string,
	live: boolean,
	working: boolean,
	-- The name of the Tern session its pane is in now.
	session: string?,
	queued: number,
}

export type Fleet = {
	key: string,
	name: string,
	repo: string,
	main_root: string?,
	legacy: boolean,
	coordinator: Coordinator,
	groups: { Group },
}

export type Model = { version: number, fleets: { Fleet } }

-- The state root from the environment (`getenv` returns nil for unset or empty), else nil when HOME is unknown too.
function fleet.state_root(getenv: (string) -> string?): string?
	local configured = getenv("AGENT_FLEET_STATE_DIR")
	if configured and configured ~= "" then
		local home = getenv("HOME")
		if string.sub(configured, 1, 2) == "~/" and home then
			configured = home .. string.sub(configured, 2)
		end
		return configured
	end
	local xdg = getenv("XDG_STATE_HOME")
	if xdg and xdg ~= "" then
		return xdg .. "/agent-fleet"
	end
	local home = getenv("HOME")
	return if home then home .. "/.local/state/agent-fleet" else nil
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function int(v: any): number?
	return if type(v) == "number" and v == math.floor(v) then v else nil
end

local function tbl(v: any): { [any]: any }?
	return if type(v) == "table" then v else nil
end

local function dot(name: string): boolean
	return string.sub(name, 1, 1) == "."
end

local function has(names: { string }, want: string): boolean
	return table.find(names, want) ~= nil
end

local function writing(names: { string }): boolean
	for _, n in names do
		if string.match(n, "^%.state%.json%..+%.tmp$") then
			return true
		end
	end
	return false
end

-- The state in `dir`: re-read when its text changed, else the cached one. A file missing while a writer's temp file
-- exists, unreadable, or not parsing as an object keeps the last good read (nil when there was none); a file missing
-- with no writer is gone.
local function read_one(io: Io, dir: string, names: { string }, cache: Cache, out: Cache): Entry?
	local prev = cache[dir]
	if not has(names, "state.json") then
		if prev and writing(names) then
			out[dir] = prev
			return prev
		end
		return nil
	end
	local ok, text = pcall(io.read, dir .. "/state.json")
	if not ok or type(text) ~= "string" then
		if prev then
			out[dir] = prev
		end
		return prev
	end
	if prev and prev.text == text then
		out[dir] = prev
		return prev
	end
	local dok, state = pcall(io.decode, text)
	if not dok or type(state) ~= "table" or #state > 0 then
		if prev then
			out[dir] = prev
		end
		return prev
	end
	local entry: Entry = { dir = dir, text = text, state = state }
	out[dir] = entry
	return entry
end

local function list(io: Io, path: string): { string }
	local ok, names = pcall(io.list, path)
	if ok and type(names) == "table" then
		table.sort(names)
		return names
	end
	return {}
end

-- Every Tern fleet state under `<root>/.tern/`: chats first per repo, then legacy groups. Returns the entries and the
-- cache for the next scan (only directories still there).
function fleet.read_states(root: string, io: Io, cache: Cache): ({ Entry }, Cache)
	local base = root .. "/" .. fleet.TERN_DIR
	local out: Cache = {}
	local found: { Entry } = {}
	for _, repo in list(io, base) do
		if not dot(repo) then
			local rdir = base .. "/" .. repo
			for _, name in list(io, rdir) do
				if not dot(name) then
					local dir = rdir .. "/" .. name
					if name == fleet.CHATS_DIR then
						for _, key in list(io, dir) do
							if not dot(key) then
								local cdir = dir .. "/" .. key
								local e = read_one(io, cdir, list(io, cdir), cache, out)
								if e then
									table.insert(found, e)
								end
							end
						end
					else
						local e = read_one(io, dir, list(io, dir), cache, out)
						if e then
							table.insert(found, e)
						end
					end
				end
			end
		end
	end
	return found, out
end

-- Seconds since the epoch of an ISO 8601 time as the script writes it (`2026-11-19T16:20:00+00:00`, or `Z`).
function fleet.iso_epoch(s: any): number?
	if type(s) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, sec, rest = string.match(s, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?%d*(.*)$")
	if y == nil then
		return nil
	end
	local yy, mm, dd = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	-- Days from 1970-01-01 (Howard Hinnant's days_from_civil).
	local yr = if mm <= 2 then yy - 1 else yy
	local era = (if yr >= 0 then yr else yr - 399) // 400
	local yoe = yr - era * 400
	local doy = (153 * (if mm > 2 then mm - 3 else mm + 9) + 2) // 5 + dd - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	local t = days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(sec) :: number)
	local sign, oh, om = string.match(rest or "", "^([+-])(%d%d):?(%d%d)$")
	if sign then
		local off = (tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60
		t -= if sign == "+" then off else -off
	end
	return t
end

-- Whether `path` is `root` or inside it.
local function inside(path: string?, root: string?): boolean
	if path == nil or root == nil or root == "" then
		return false
	end
	local r = string.gsub(root, "/+$", "")
	return path == r or string.sub(path, 1, #r + 1) == r .. "/"
end

-- macOS paths under /tmp and /var are reported by Tern through /private: compare both ways.
local function same_tree(path: string?, root: string?): boolean
	if inside(path, root) then
		return true
	end
	local function priv(p: string?): string?
		if p and (string.sub(p, 1, 5) == "/tmp/" or string.sub(p, 1, 5) == "/var/") then
			return "/private" .. p
		end
		return p
	end
	return inside(priv(path), priv(root))
end

local function first_line(s: string?, n: number): string?
	if s == nil then
		return nil
	end
	local line = string.match(s, "^%s*([^\n]*)") or ""
	line = string.gsub(line, "%s+$", "")
	if line == "" then
		return nil
	end
	if #line > n then
		local cut = utf8.offset(line, n + 1)
		line = string.sub(line, 1, if cut then cut - 1 else n) .. "…"
	end
	return line
end

-- Tern's tab colors; a group keeps one, from a hash of its key.
fleet.COLORS = { "blue", "green", "purple", "orange", "teal", "pink", "yellow", "red" }

function fleet.color_of(key: string): string
	local h = 7
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 2147483647
	end
	return fleet.COLORS[(h % #fleet.COLORS) + 1]
end

local function session_by(live: Live, id: number?, name: string?): LiveSession?
	if id then
		for _, s in live.sessions do
			if s.id == id then
				return s
			end
		end
	end
	if name then
		for _, s in live.sessions do
			if s.name == name then
				return s
			end
		end
	end
	return nil
end

local function session_of_pane(live: Live, pane: number?): string?
	if pane == nil then
		return nil
	end
	for _, s in live.sessions do
		if s.panes[pane] then
			return s.name
		end
	end
	return nil
end

local function queued_for(live: Live, pane: number?): number
	local mail = live.mail
	if pane == nil or mail == nil then
		return 0
	end
	return mail.queued[pane] or 0
end

-- The mailbox state now of an item's last report or message sent through the mailbox: the live box when it knows the
-- id, else what the script recorded.
local function mailbox_of(live: Live, raw: { [any]: any }): string?
	local best: string? = nil
	for _, key in { "last_report", "last_send" } do
		local m = tbl(raw[key])
		if m and m.delivery == "mailbox" then
			local id = str(m.id)
			local state = if id and live.mail and live.mail.by_id[id] then live.mail.by_id[id] else str(m.mailbox_state)
			-- Queued wins: something still waits.
			if state == "queued" or best == nil then
				best = state
			end
		end
	end
	return best
end

local function build_item(live: Live, name: string, group: string, raw: { [any]: any }): Item?
	local status = str(raw.status) or "starting"
	if status == "removed" then
		return nil
	end
	local pane = int(raw.block)
	local worktree = str(raw.worktree)
	local row = if pane then live.panes[pane] else nil
	local liveness = "gone"
	local exit_code: number? = nil
	local working = false
	if row and (worktree == nil or same_tree(row.cwd, worktree)) then
		if row.exited ~= nil then
			liveness = "exited"
			exit_code = row.exited
		else
			liveness = "live"
			working = row.working
		end
	elseif status == "starting" then
		liveness = "starting"
	end
	local report: Report? = nil
	local r = tbl(raw.last_report)
	if r and str(r.kind) then
		report = { kind = r.kind, at = fleet.iso_epoch(r.at), text = first_line(str(r.text), 160) }
	end
	return {
		name = name,
		title = "L1 " .. group .. "/" .. name,
		branch = str(raw.branch),
		worktree = worktree,
		pane = pane,
		status = status,
		liveness = liveness,
		working = working,
		exit_code = exit_code,
		report = report,
		mailbox = mailbox_of(live, raw),
		queued = queued_for(live, pane),
	}
end

local function items_of(live: Live, group: string, raw: any): { Item }
	local out: { Item } = {}
	local names: { string } = {}
	for name, v in tbl(raw) or {} do
		if type(name) == "string" and type(v) == "table" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		local item = build_item(live, name, group, raw[name])
		if item then
			table.insert(out, item)
		end
	end
	return out
end

local function coordinator(live: Live, pane: number?, title: string): Coordinator
	local row = if pane then live.panes[pane] else nil
	return {
		pane = pane,
		title = title,
		live = row ~= nil and row.exited == nil,
		working = row ~= nil and row.exited == nil and row.working,
		session = session_of_pane(live, pane),
		queued = queued_for(live, pane),
	}
end

-- A coordinator chat's fleet, nil when it coordinates nothing (closed, or no group).
local function chat_fleet(live: Live, e: Entry): Fleet?
	local s = e.state
	if s.kind ~= "chat" or s.adapter ~= "tern" or str(s.closed_at) then
		return nil
	end
	local groups = tbl(s.groups)
	if groups == nil or next(groups) == nil then
		return nil
	end
	local repo = str(s.repo_id) or ""
	local name = str(s.fleet) or "fleet"
	local key = repo .. "/" .. (str(s.chat_key) or string.match(e.dir, "[^/]+$") or e.dir)
	local f: Fleet = {
		key = key,
		name = name,
		repo = repo,
		main_root = str(s.main_root),
		legacy = false,
		coordinator = coordinator(live, int(s.pane), "L0 " .. name),
		groups = {},
	}
	local order: { { name: string, at: number } } = {}
	for gname, g in groups do
		if type(gname) == "string" and type(g) == "table" then
			table.insert(order, { name = gname, at = fleet.iso_epoch(g.created_at) or 0 })
		end
	end
	table.sort(order, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.name < b.name
	end)
	for _, o in order do
		local g = groups[o.name]
		local sess = tbl(g.session) or {}
		local label = "G " .. o.name .. " · " .. name
		local sid, sname = int(sess.id), str(sess.name) or label
		local found = session_by(live, sid, sname)
		local gkey = key .. "/" .. o.name
		table.insert(f.groups, {
			key = gkey,
			name = o.name,
			label = label,
			branch = str(g.branch),
			worktree = str(g.container_path),
			session_id = if found then found.id else sid,
			session_name = if found then found.name else sname,
			session_live = found ~= nil,
			creating = g.status == "creating",
			color = fleet.color_of(gkey),
			items = items_of(live, o.name, g.items),
		})
	end
	return f
end

-- A legacy `l0-<group>` group: its own fleet with one group.
local function legacy_fleet(live: Live, e: Entry): Fleet?
	local s = e.state
	if s.kind == "chat" or not (s.adapter == "tern" or (s.adapter == nil and s.coordinator_pane ~= nil)) then
		return nil
	end
	local name = str(s.group)
	if name == nil then
		return nil
	end
	local repo = str(s.repo_id) or ""
	local key = repo .. "/" .. name
	local sname = str(s.session) or ("l0-" .. name)
	local found = session_by(live, nil, sname)
	local items = items_of(live, name, s.items)
	return {
		key = key,
		name = name,
		repo = repo,
		main_root = str(s.main_root),
		legacy = true,
		coordinator = coordinator(live, int(s.coordinator_pane), "L0 " .. name),
		groups = {
			{
				key = key .. "/" .. name,
				name = name,
				label = sname,
				branch = str(s.branch),
				worktree = str(s.worktree_path),
				session_id = if found then found.id else nil,
				session_name = sname,
				session_live = found ~= nil,
				creating = false,
				color = fleet.color_of(key .. "/" .. name),
				items = items,
			},
		},
	}
end

-- The model for the sidebar: open fleets, sorted by name (then key).
function fleet.build(entries: { Entry }, live: Live): Model
	local fleets: { Fleet } = {}
	for _, e in entries do
		if type(e.state) == "table" then
			local f = if e.state.kind == "chat" then chat_fleet(live, e) else legacy_fleet(live, e)
			if f then
				table.insert(fleets, f)
			end
		end
	end
	table.sort(fleets, function(a, b)
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.key < b.key
	end)
	return { version = fleet.VERSION, fleets = fleets }
end

-- Live panes, sessions from a decoded `tern inspect --json` (panes with `exited`, `working`; sessions with tabs of
-- blocks).
function fleet.live_of(doc: any): Live
	local panes: { [number]: LivePane } = {}
	local sessions: { LiveSession } = {}
	if type(doc) ~= "table" then
		return { panes = panes, sessions = sessions }
	end
	for _, p in tbl(doc.panes) or {} do
		if type(p) == "table" and type(p.pane) == "number" then
			local exited = p.exited
			panes[p.pane] = {
				cwd = if type(p.cwd) == "string" then p.cwd else "",
				exited = if type(exited) == "number" then exited else nil,
				working = p.working == true,
				session_file = if type(p.omp_session_file) == "string" then p.omp_session_file else nil,
			}
		end
	end
	for _, s in tbl(doc.sessions) or {} do
		if type(s) == "table" and type(s.id) == "number" and type(s.name) == "string" then
			local set: { [number]: boolean } = {}
			for _, t in tbl(s.tabs) or {} do
				for _, b in (type(t) == "table" and tbl(t.blocks)) or {} do
					if type(b) == "table" and type(b.id) == "number" then
						set[b.id] = true
					end
				end
			end
			table.insert(sessions, { id = s.id, name = s.name, panes = set })
		end
	end
	return { panes = panes, sessions = sessions }
end

-- What a worker's card says, from its record and its agent's live state in the window (`agent`: Tern's agent state of
-- its pane, nil when the window doesn't list it as an agent):
-- working | waiting (its agent needs the user) | ask (it asked the coordinator) | done | failed | idle | starting | gone.
function fleet.item_state(item: Item, agent: string?): string
	if item.status == "start-failed" then
		return "failed"
	end
	if item.liveness == "starting" or (item.status == "starting" and item.liveness ~= "live") then
		return "starting"
	end
	local kind = if item.report then item.report.kind else nil
	if item.liveness == "gone" then
		return "gone"
	end
	if item.liveness == "exited" or agent == "exited" then
		if kind == "failed" or (item.exit_code ~= nil and item.exit_code ~= 0) then
			return "failed"
		end
		return if item.status == "reported" and kind == "done" then "done" else "gone"
	end
	if agent == "working" or (agent == nil and item.working) then
		return "working"
	end
	if agent == "waiting_input" then
		return "waiting"
	end
	if item.status == "waiting" then
		return "ask"
	end
	if item.status == "reported" then
		return if kind == "failed" then "failed" else "done"
	end
	return "idle"
end

-- The coordinator card's state: working | waiting | idle | gone.
function fleet.coordinator_state(c: Coordinator, agent: string?): string
	if not c.live or agent == "exited" then
		return "gone"
	end
	if agent == "working" or (agent == nil and c.working) then
		return "working"
	end
	if agent == "waiting_input" then
		return "waiting"
	end
	return "idle"
end

-- Whether an item's last report is unread: it came after the coordinator was last focused (`seen`, os.time()).
function fleet.unread(item: Item, seen: number?): boolean
	local r = item.report
	return r ~= nil and r.at ~= nil and seen ~= nil and r.at > seen
end

return fleet
