--!strict
-- projects, fleets in a window: reads the fleet model the host half writes (`<data>/fleet.json`, fleet.luau) when its
-- signature in status.json changed, adds each card's live agent state and unread mark for the sidebar, focuses a
-- worker's or coordinator's pane and shows (or reopens) a group's session on a click, marks a fleet's reports read
-- when its coordinator is focused, and gives each group session's tabs the group's color. Remote hosts' fleets
-- (their bridge's fleet node, remote.luau) show after this machine's, their panes mapped to this window's, their
-- keys and rows tagged with the host.

local fleet = require("./fleet")
local model = require("./model")
local sidebar = require("./sidebar")
local core = require("./core")
local budget = require("./budget")

-- The context: all shared state and the other modules' functions, set by the installer below.
local S: core.Ctx = nil :: any

local FLEET_FILE = tern.plugin.data .. "/fleet.json"
local FLEET_BYTES = 4194304

-- Tabs this run colored once: a color the user changes or clears afterwards stays theirs.
local colored: { [number]: boolean } = {}

-- Gives every tab of each live group session its group's color (fleet.color_of), once per tab and only to a tab
-- with no color.
local function color_tabs(cx: WindowCx)
	local by_name: { [string]: number } = {}
	for _, s in cx.session:sessions() do
		by_name[s.name] = s.id
	end
	local want: { [number]: string } = {}
	for _, f in S.fleets :: { fleet.Fleet } do
		for _, g in f.groups do
			local id = if g.session_name and by_name[g.session_name] then by_name[g.session_name] else g.session_id
			if g.session_live and id then
				want[id] = g.color
			end
		end
	end
	if next(want) == nil then
		return
	end
	for _, t in cx.session:tabs() do
		local c = want[t.session]
		if c and t.color == nil and not colored[t.id] then
			colored[t.id] = true
			pcall(function()
				cx.layout:color_tab(t.id, c :: any)
			end)
		end
	end
end

-- This machine's fleets, from fleet.json; remote hosts' join them in `rebuild`.
local local_list: { fleet.Fleet } = {}

-- A remote host's fleets as this window shows them: pane ids mapped (nil while unmapped), keys `<host>|<key>`, the
-- host's short name after the fleet's, and no session id (the host's ids are not this window's; names are).
local function remote_fleets(host: string, doc: any): { fleet.Fleet }
	local out: { fleet.Fleet } = {}
	if type(doc) ~= "table" or type(doc.fleets) ~= "table" then
		return out
	end
	local function wp(p: any): number?
		return if type(p) == "number" then S.wpane(host, p) else nil
	end
	for _, f in doc.fleets do
		if type(f) == "table" and type(f.groups) == "table" and type(f.coordinator) == "table" then
			local c = table.clone(f.coordinator)
			c.pane = wp(c.pane)
			local groups: { fleet.Group } = {}
			for _, g in f.groups do
				local ng: any = table.clone(g)
				ng.key = host .. "|" .. g.key
				ng.host = host
				ng.session_id = nil
				ng.items = {}
				for _, it in (if type(g.items) == "table" then g.items else {}) :: { fleet.Item } do
					local ni = table.clone(it)
					ni.pane = wp(it.pane)
					table.insert(ng.items, ni)
				end
				table.insert(groups, ng)
			end
			local nf: any = table.clone(f)
			nf.key = host .. "|" .. f.key
			nf.name = f.name .. " · " .. (model.host_short(host) or host)
			nf.host = host
			nf.coordinator = c
			nf.groups = groups
			table.insert(out, nf)
		end
	end
	return out
end

-- The fleet list and its lookups from this machine's fleets and every remote host's.
local function rebuild()
	local list = local_list
	if next(S.remote) ~= nil then
		list = table.clone(local_list)
		for host, R in S.remote do
			for _, f in remote_fleets(host, R.fleet) do
				table.insert(list, f)
			end
		end
	end
	local groups: { [string]: fleet.Group } = {}
	local coords: { [number]: string } = {}
	local claimed: { [number]: boolean } = {}
	local fresh: { string } = {}
	for _, f in list do
		if type(f) == "table" and type(f.groups) == "table" and type(f.coordinator) == "table" then
			if f.coordinator.pane then
				coords[f.coordinator.pane] = f.key
				claimed[f.coordinator.pane] = true
			end
			for _, g in f.groups do
				groups[g.key] = g
				g.items = if type(g.items) == "table" then g.items else {}
				for _, it in g.items do
					if it.pane then
						claimed[it.pane] = true
					end
				end
			end
			if S.ui.fleet_seen[f.key] == nil then
				table.insert(fresh, f.key)
			end
		end
	end
	S.fleets = list
	S.fleet_groups = groups
	S.fleet_coords = coords
	S.fleet_claimed = claimed
	S.dirty = true
	if #fresh > 0 then
		-- A fleet seen for the first time: its reports so far are read.
		S.ui = model.load_ui()
		for _, k in fresh do
			S.ui.fleet_seen[k] = os.time()
		end
		S.save_ui()
	end
	budget.later("fleet colors", 0, color_tabs)
end

-- Re-reads fleet.json (called by the scan when status.json's `fleet_sig` changed). A missing or half-written file keeps
-- the last model.
local function load_fleets()
	local ok, text = pcall(tern.fs.read, FLEET_FILE, FLEET_BYTES)
	if not ok then
		return
	end
	local dok, doc = pcall(tern.json.decode, text)
	if not dok or type(doc) ~= "table" then
		return
	end
	local_list = if type(doc.fleets) == "table" then doc.fleets else {}
	rebuild()
end

-- The pane `pane` was focused: when it is a fleet's coordinator, that fleet's reports so far are read.
local function fleet_focused(pane: number?)
	local key = if pane then S.fleet_coords[pane] else nil
	if key == nil then
		return
	end
	S.ui = model.load_ui()
	S.ui.fleet_seen[key] = os.time()
	S.save_ui()
	S.dirty = true
end

local function agent_state(pane: number?): (string?, string?)
	local b = if pane then S.blocks[pane] else nil
	if b == nil then
		return nil, nil
	end
	return b.state, b.cwd
end

-- Whether a worker of `f` has a report its coordinator hasn't seen.
local function any_unread(f: fleet.Fleet): boolean
	local seen = S.ui.fleet_seen[f.key]
	for _, g in f.groups do
		for _, it in g.items do
			if fleet.unread(it, seen) then
				return true
			end
		end
	end
	return false
end

-- The fleets as the sidebar draws them (sidebar.FleetSnap). `active` is the pane the user works in: a report that
-- arrives while its coordinator is focused is read at once.
local function fleet_snap(active: number?): { sidebar.FleetSnap }
	local out: { sidebar.FleetSnap } = {}
	for _, f in S.fleets :: { fleet.Fleet } do
		local c = f.coordinator
		if active ~= nil and active == c.pane and any_unread(f) then
			fleet_focused(c.pane)
		end
		local seen = S.ui.fleet_seen[f.key]
		local groups: { sidebar.FleetGroupSnap } = {}
		for _, g in f.groups do
			local items: { sidebar.FleetItemSnap } = {}
			for _, it in g.items do
				local pr, pr_stale = S.pr_for(it.worktree, it.branch)
				table.insert(items, {
					name = it.name,
					title = it.title,
					branch = it.branch,
					pane = it.pane,
					state = fleet.item_state(it, agent_state(it.pane)),
					report = it.report,
					mailbox = it.mailbox,
					queued = it.queued,
					unread = fleet.unread(it, seen),
					pr = pr,
					pr_stale = pr_stale,
				})
			end
			local gpr, gpr_stale = S.pr_for(g.worktree, g.branch)
			table.insert(groups, {
				key = g.key,
				name = g.name,
				label = g.label,
				branch = g.branch,
				session_live = g.session_live,
				creating = g.creating,
				items = items,
				pr = gpr,
				pr_stale = gpr_stale,
			})
		end
		table.insert(out, {
			key = f.key,
			name = f.name,
			legacy = f.legacy,
			coordinator = {
				pane = c.pane,
				title = c.title,
				state = fleet.coordinator_state(c, agent_state(c.pane)),
				session = c.session,
				queued = c.queued,
			},
			groups = groups,
		})
	end
	return out
end

-- A click on a worker's or coordinator's card: focus its pane.
local function fleet_focus(cx: WindowCx, pane: number)
	if cx.session:pane(pane) == nil then
		cx:toast("info", "That fleet agent's pane is gone")
		return
	end
	S.goto_pane(cx, pane)
	fleet_focused(pane)
	S.redraw_soon()
end

-- A click on a group's row: show its session, or open it again (as tern_fleet.py names it) when it is gone. A remote
-- group's session is found and made on its host (making one needs that host current: it is switched to first).
local function fleet_group(cx: WindowCx, key: string)
	local g = S.fleet_groups[key]
	if g == nil then
		return
	end
	local name = g.session_name or g.label
	local host: string? = (g :: any).host
	if host then
		local s = core.session_named(cx, name, host)
		if s then
			if not s.current then
				cx.sessions:switch(s.id)
			end
			return
		end
		if core.host_now(cx) ~= host then
			local rec = core.host_record(cx, host)
			if rec == nil or rec.state ~= "connected" then
				cx:toast("error", host .. " is not connected", "Can't open " .. name .. " again")
				return
			end
			cx.hosts:switch(rec.id)
		end
		cx.sessions:create({ name = name, cwd = g.worktree })
		cx:toast("info", "Opened " .. name .. " again on " .. (model.host_short(host) or host :: string), g.worktree)
		return
	end
	for _, s in cx.sessions:list() do
		if s.id == g.session_id or s.name == g.session_name then
			if not s.current then
				cx.sessions:switch(s.id)
			end
			return
		end
	end
	cx.sessions:create({ name = g.session_name or g.label, cwd = g.worktree })
	cx:toast("info", "Opened " .. (g.session_name or g.label) .. " again", g.worktree)
end

-- Installs this module's functions into the context.
return function(ctx: core.Ctx)
	S = ctx
	S.fleets = {}
	S.fleet_groups = {}
	S.fleet_coords = {}
	S.fleet_claimed = {}
	S.fleet_sig = nil
	S.load_fleets = load_fleets
	S.fleet_focused = fleet_focused
	S.fleet_snap = fleet_snap
	S.fleet_focus = fleet_focus
	S.fleet_group = fleet_group
	S.fleets_remote = rebuild
end
