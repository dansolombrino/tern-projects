--!strict
-- projects, fleets in a window: reads the fleet model the host half writes (`<data>/fleet.json`, fleet.luau) when its
-- signature in status.json changed, adds each card's live agent state and unread mark for the sidebar, focuses a
-- worker's or coordinator's pane and shows (or reopens) a group's session on a click, marks a fleet's reports read
-- when its coordinator is focused, and gives each group session's tabs the group's color.

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
	local list: { fleet.Fleet } = if type(doc.fleets) == "table" then doc.fleets else {}
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
					if it.pane and it.liveness ~= "gone" then
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

local function agent_state(pane: number?): string?
	local b = if pane then S.blocks[pane] else nil
	return if b then b.state else nil
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
				})
			end
			table.insert(groups, {
				key = g.key,
				name = g.name,
				label = g.label,
				branch = g.branch,
				session_live = g.session_live,
				creating = g.creating,
				items = items,
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

-- A click on a group's row: show its session, or open it again (as tern_fleet.py names it) when it is gone.
local function fleet_group(cx: WindowCx, key: string)
	local g = S.fleet_groups[key]
	if g == nil then
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
end
