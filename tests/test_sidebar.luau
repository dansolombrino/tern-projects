--!strict
-- luau tests/test_sidebar.luau

local t = require("./support")
local sidebar = require("../sidebar")
local subagents = require("../subagents")

local check, eq, test = t.check, t.eq, t.test

-- support.ui plus `el` (a generic element: `{k = "el", p = {tag, …}, c}`).
local ui: { [string]: any } = {}
for k, v in (t.ui :: any) do
	ui[k] = v
end
ui.el = function(tag: string, p: any?, c: any?)
	local props: { [string]: any } = { tag = tag }
	for k, v in p or {} do
		props[k] = v
	end
	local n: { [string]: any } = { k = "el", p = props }
	if c ~= nil and #c > 0 then
		n.c = c
	end
	return n
end
sidebar.ui = ui

local ROOT = sidebar.ROOT_ID
local LIST = ROOT .. ".list"
local NOW = 1800000000

local function running(): { any }
	local list = subagents.extract(t.fixture("omp-subagents-running"))
	for _, s in list do
		(s :: any).first_seen = NOW - 120
	end
	return list
end

local function snapshot(): any
	return {
		now = NOW,
		active = 12,
		unread = { [13] = true },
		collapsed = { beta = true },
		groups = { { id = "work", name = "Work" }, { id = "empty", name = "Empty group" } },
		projects = {
			{
				project = { id = "alpha", name = "Alpha app", root = "/tmp/zz-test-alpha", color = "orange" },
				session_exists = true,
				current = true,
				group = { id = "work", name = "Work" },
				agents = {
					{
						pane = 11, project = "alpha", title = "fix login", state = "working", model = "anthropic/claude-opus-5-5",
						prompt = "Fix the login flow", tool = "bash: run tests",
						last_message = "  Looking at auth.ts\nsecond line", cwd = "/tmp/zz-test-alpha/wt/fix-login",
						branch = "agent/fix-login", started = NOW - 5 * 60,
						spawned = {
							{ pane = 12, project = "alpha", title = "write tests", state = "waiting_input", cwd = "/tmp/zz-test-alpha", started = NOW - 30 },
						},
					},
					{ pane = 13, project = "alpha", title = "docs", state = "idle", result = "done", done_at = NOW - 3600, cwd = "/tmp/zz-test-alpha", primary = true, last_message = "Done." },
				},
			},
			{
				project = { id = "beta", name = "Beta", root = "/tmp/zz-test-beta", icon = { kind = "emoji", emoji = "📚" } },
				session_exists = false,
				current = false,
				group = { id = "work", name = "Work" },
				agents = { { pane = 15, project = "beta", title = "hidden", state = "idle", cwd = "/tmp/zz-test-beta" } },
			},
			{
				project = { id = "gamma.x/y", name = "Gamma", root = "/tmp/zz-test-gamma", color = "#123abc" },
				session_exists = false,
				current = false,
				agents = {},
			},
		},
		unassigned = { { pane = 14, title = "scratch", state = "idle", cwd = "/tmp" } },
	}
end

local function node(root: any, id: string, root_id: string?): any
	return t.find(root, root_id or ROOT, id)
end

local function click(root: any, id: string, root_id: string?): string?
	local n = node(root, id, root_id)
	return n and n.p and n.p.actions and n.p.actions.click
end

local function has_class(n: any, cls: string): boolean
	local s = " " .. ((n and n.p and n.p.class) or "") .. " "
	return string.find(s, " " .. cls .. " ", 1, true) ~= nil
end

local function ids(menu: { any }): string
	local out = {}
	for _, item in menu do
		table.insert(out, if type(item) == "table" then item.id else item)
	end
	return table.concat(out, ",")
end

local function has_text(n: any, s: string): boolean
	return n ~= nil and type(n.p.text) == "string" and string.find(n.p.text, s, 1, true) ~= nil
end

local function count(root: any, root_id: string): number
	local n = 0
	t.walk(root, root_id, function()
		n += 1
	end)
	return n
end

-- Keys of a node's children, in order.
local function keys(n: any): string
	local out = {}
	for _, c in n.c or {} do
		table.insert(out, c.p.key)
	end
	return table.concat(out, ",")
end

local GROUP = LIST .. ".pg_work"
local ALPHA = GROUP .. ".g_alpha"
local CARD = ALPHA .. ".c_11"
local GAMMA = LIST .. ".g_gamma_2ex_2fy"

test("empty snapshot: Add project CTA, header and footer", function()
	local built = sidebar.build({ projects = {} })
	eq(built.view.p.key, sidebar.ROOT_KEY, "root key matches ROOT_ID")
	check(has_class(built.view, sidebar.ROOT_CLASS), "root carries ROOT_CLASS")
	eq(click(built.view, LIST .. ".empty.add"), "add_project", "empty state offers Add project")
	eq(click(built.view, ROOT .. ".head.acts.new"), "add_project", "header + adds a project when there are none")
	eq(node(built.view, ROOT .. ".head.collapse"), nil, "no collapse-all without projects")
	eq(click(built.view, ROOT .. ".nav.search"), "search", "Search pill")
	eq(node(built.view, ROOT .. ".nav.search.keys"), nil, "no keycaps without keys")
	eq(click(built.dock, "footer.l.settings", "footer"), "settings", "footer settings")
	eq(click(built.dock, "footer.l.help", "footer"), "help", "footer help")
	eq(click(built.dock, "footer.r.reveal", "footer"), "reveal", "footer reveal")
end)

test("section header", function()
	local snap = snapshot()
	snap.keys = { search = { "⌘", "J" } }
	local view = sidebar.build(snap).view
	eq(node(view, ROOT .. ".nav.search.keys.k2").p.text, "J", "search keycaps from the snapshot")
	eq(click(view, ROOT .. ".head.collapse"), "collapse_all", "collapse all")
	eq(click(view, ROOT .. ".head.acts.options"), "options", "options")
	eq(node(view, ROOT .. ".head.acts.options.badge"), nil, "no filter badge without filters")
	eq(click(view, ROOT .. ".head.acts.add"), "add_project", "add project")
	eq(click(view, ROOT .. ".head.acts.new"), "new_agent=alpha", "+ targets the current project")
	eq(click(view, ROOT .. ".head.acts.bell"), "activity", "bell toggles the activity view")
	eq(node(view, ROOT .. ".head.acts.bell.box.n").p.text, "1", "waiting count on the bell")
	check(has_class(node(view, ROOT .. ".head.acts.bell.box.sig"), "op-q"), "question signal while someone waits")

	snap.projects[1].current = false
	snap.waiting = 0
	snap.projects[1].agents[1].spawned[1].state = "idle"
	snap.filters = 2
	snap.group_by = "none"
	view = sidebar.build(snap).view
	eq(click(view, ROOT .. ".head.acts.new"), "new_agent", "no current project: bare new_agent")
	eq(node(view, ROOT .. ".head.acts.bell.box.n").p.text, "1", "snapshot waiting wins; count falls back to working")
	check(has_class(node(view, ROOT .. ".head.acts.bell.box.sig"), "op-w"), "working-only signal")
	eq(node(view, ROOT .. ".head.acts.options.badge").p.text, "2", "filter count badge")
	eq(node(view, ROOT .. ".head.title").p.text, "Workspaces", "group by none: Workspaces")

	snap.body = "agents"
	view = sidebar.build(snap).view
	check(has_class(node(view, ROOT .. ".head.acts.bell"), "on"), "bell pressed in the activity view")
	eq(node(view, ROOT .. ".head.acts.options"), nil, "no options in the activity view")
	eq(node(view, ROOT .. ".head.collapse"), nil, "no collapse-all in the activity view")
end)

test("bell count boundaries", function()
	local snap = snapshot()
	snap.projects[1].agents[1].state = "idle"
	snap.projects[1].agents[1].spawned[1].state = "idle"
	local view = sidebar.build(snap).view
	eq(node(view, ROOT .. ".head.acts.bell.box.n").p.text, "0", "nothing live: 0 shown")
	check(has_class(node(view, ROOT .. ".head.acts.bell.box.sig"), "op-idle"), "idle signal")
	snap.waiting = 99
	local n = node(sidebar.build(snap).view, ROOT .. ".head.acts.bell.box.n")
	eq(n.p.text, "99", "99 in full")
	check(not has_class(n, "op-squeeze"), "99 not squeezed")
	snap.waiting = 100
	n = node(sidebar.build(snap).view, ROOT .. ".head.acts.bell.box.n")
	eq(n.p.text, "99+", "100 caps at 99+")
	check(has_class(n, "op-squeeze"), "99+ squeezed")
end)

test("collapse-all state", function()
	local snap = snapshot()
	local expand = node(sidebar.build(snap).view, ROOT .. ".head.collapse").p.title
	snap.collapsed = { alpha = true, beta = true, ["gamma.x/y"] = true }
	local collapse = node(sidebar.build(snap).view, ROOT .. ".head.collapse").p.title
	check(expand ~= collapse, "all collapsed flips the button")
end)

test("keys stay distinct", function()
	local function proj(id: string): any
		return { project = { id = id, name = id, root = "/tmp/" .. id }, session_exists = false, current = false, agents = {} }
	end
	local view = sidebar.build({ projects = { proj("a.b"), proj("a_b"), proj("日本"), proj("中国") } }).view
	local list = node(view, LIST)
	local seen: { [string]: boolean } = {}
	for _, c in list.c do
		check(not seen[c.p.key], "distinct key " .. c.p.key)
		check(not string.find(c.p.key, "[%./]"), "key without . or /")
		seen[c.p.key] = true
	end
	eq(#list.c, 4, "four sections")
end)

test("project groups and headers", function()
	local view = sidebar.build(snapshot()).view
	eq(keys(node(view, LIST)), "pg_work,pg_empty,g_gamma_2ex_2fy,unassigned", "groups in saved order, then ungrouped, then unassigned")
	local mid = snapshot()
	mid.groups = { { id = "first", name = "First" }, { id = "empty", name = "Empty" }, { id = "work", name = "Work" } }
	mid.projects[3].group = { id = "first", name = "First" }
	table.insert(mid.projects, 1, table.remove(mid.projects, 3))
	eq(keys(node(sidebar.build(mid).view, LIST)), "pg_first,pg_empty,pg_work,unassigned", "empty group keeps its slot between groups")
	eq(node(view, GROUP .. ".head").p.actions.click, "toggle_group=group:work", "group header toggles")
	eq(click(view, GROUP .. ".head.acts.more"), "group_menu=work", "group … click")
	eq(ids(node(view, GROUP .. ".head").p.actions.menu), "rename_group=work,delete_group=work", "group menu")
	eq(node(view, LIST .. ".pg_empty.head.acts.chev"), nil, "empty group: no chevron")
	eq(node(view, GROUP .. ".head.acts.new"), nil, "manual groups have no +")

	local snap = snapshot()
	snap.collapsed = { ["group:work"] = true }
	view = sidebar.build(snap).view
	eq(node(view, ALPHA), nil, "collapsed group hides its projects")
	check(node(view, GROUP .. ".head.acts.chev") ~= nil, "collapsed group keeps its chevron")

	snap = snapshot()
	snap.groups = nil
	eq(keys(node(sidebar.build(snap).view, LIST)), "pg_work,g_gamma_2ex_2fy,unassigned", "groups list absent: headers from the runs")

	view = sidebar.build(snapshot()).view
	local head = node(view, ALPHA .. ".head")
	eq(head.p.actions.click, "toggle_group=alpha", "header click toggles")
	eq(
		ids(head.p.actions.menu),
		"project_settings=alpha,project_icon=alpha,new_group=alpha,move_to_group=alpha,ungroup=alpha,open_project=alpha,-,remove_project=alpha",
		"project menu"
	)
	eq(ids(node(view, GAMMA .. ".head").p.actions.menu), "project_settings=gamma.x/y,project_icon=gamma.x/y,new_group=gamma.x/y,move_to_group=gamma.x/y,open_project=gamma.x/y,-,remove_project=gamma.x/y", "ungrouped: no Remove from group")
	snap = snapshot()
	snap.groups = {}
	snap.projects[1].group, snap.projects[2].group = nil, nil
	eq(ids(node(sidebar.build(snap).view, LIST .. ".g_alpha.head").p.actions.menu), "project_settings=alpha,project_icon=alpha,new_group=alpha,open_project=alpha,-,remove_project=alpha", "no groups: no Move to group")

	eq(node(view, ALPHA .. ".head.name").p.text, "Alpha app", "name")
	check(has_class(node(view, ALPHA .. ".head.icon"), "op-c-orange"), "icon in the project color")
	eq(node(view, GROUP .. ".g_beta.head.icon").p.text, "📚", "emoji icon")
	check(has_class(node(view, GAMMA .. ".head.icon"), "op-c-neutral"), "non-preset color: neutral")
	check(node(view, ALPHA .. ".head.acts.chev") ~= nil, "chevron with rows")
	eq(click(view, ALPHA .. ".head.acts.more"), "project_menu=alpha", "… opens the project menu")
	eq(click(view, ALPHA .. ".head.acts.new"), "new_agent=alpha", "+ starts an agent")
	check(has_class(node(view, GROUP .. ".g_beta"), "collapsed"), "collapsed project marked")
	eq(node(view, GROUP .. ".g_beta.c_15"), nil, "collapsed project hides its cards")
	eq(#node(view, GAMMA).c, 1, "empty project: header only")
	eq(node(view, GAMMA .. ".head.acts.chev"), nil, "empty project: no chevron")
	eq(click(view, GAMMA .. ".head.acts.new"), "new_agent=gamma.x/y", "id kept")
	eq(click(view, LIST .. ".unassigned.c_14"), "focus=14", "unassigned card focuses")
end)

test("pinned and group by none", function()
	local snap = snapshot()
	local pinned = table.remove(snap.projects[1].agents, 2)
	pinned.pinned = true
	snap.pinned = { pinned }
	local view = sidebar.build(snap).view
	eq(node(view, LIST).c[1].p.key, "pinned", "Pinned first")
	eq(node(view, LIST .. ".pinned.head").p.actions.click, "toggle_group=pinned", "Pinned collapses")
	local menu = ids(node(view, LIST .. ".pinned.c_13").p.actions.menu)
	check(string.find(menu, "remove_project=alpha", 1, true) ~= nil, "pinned primary resolves its project by id")
	snap.collapsed = { pinned = true }
	eq(node(sidebar.build(snap).view, LIST .. ".pinned.c_13"), nil, "collapsed Pinned")

	-- Nested roots: the stamped id wins over any path match.
	snap = snapshot()
	table.insert(snap.projects, 1, {
		project = { id = "outer", name = "Outer", root = "/tmp" }, session_exists = false, current = false, agents = {},
	})
	pinned = table.remove(snap.projects[2].agents, 2)
	snap.pinned = { pinned }
	menu = ids(node(sidebar.build(snap).view, LIST .. ".pinned.c_13").p.actions.menu)
	check(string.find(menu, "remove_project=alpha", 1, true) ~= nil, "nested roots: owning project")
	pinned.project = nil
	menu = ids(node(sidebar.build(snap).view, LIST .. ".pinned.c_13").p.actions.menu)
	check(not string.find(menu, "remove_project", 1, true) and not string.find(menu, "delete", 1, true), "no project: neither Remove Project nor Delete")

	snap = snapshot()
	snap.group_by = "none"
	snap.pinned = { table.remove(snap.projects[1].agents, 2) }
	view = sidebar.build(snap).view
	eq(keys(node(view, LIST)), "pinned,all", "Pinned stays above All")
	eq(node(view, LIST .. ".all.head.name").p.text, "All", "one All header")
	eq(#node(view, LIST .. ".all").c, 4, "header + every other card")
	check(string.find(ids(node(view, LIST .. ".all.c_11").p.actions.menu), "delete=11", 1, true) ~= nil, "All card keeps its menu")
end)

test("cards", function()
	local view = sidebar.build(snapshot()).view
	local c11 = node(view, CARD)
	eq(c11.p.actions.click, "focus=11", "card click focuses")
	eq(c11.p.actions.dblclick, "rename=11", "card double-click renames")
	eq(
		ids(c11.p.actions.menu),
		"rename=11,open_finder=11,copy_path=11,copy_name=11,-,toggle_pin=11,toggle_unread=11,-,new_subagent=11,-,sleep=11,delete=11",
		"card menu"
	)
	eq(c11.p.title, nil, "no card tooltip")
	eq(node(view, CARD .. ".row.stack.line.title").p.text, "fix login", "title")
	eq(node(view, CARD .. ".row.stack.line").p.title, "fix login\nagent/fix-login", "identity tooltip: title, branch")
	eq(node(view, CARD .. ".row.stack.meta"), nil, "no meta row by default")
	check(has_class(node(view, CARD .. ".row.lane.st"), "op-waiting"), "a waiting child rolls up to the card")
	check(has_class(c11, "on"), "card of the focused child is active")
	eq(node(view, CARD .. ".row.stack.line.primary"), nil, "worktree agent has no primary mark")

	local c13 = node(view, ALPHA .. ".c_13")
	check(has_class(c13, "unread"), "unread card")
	check(node(view, ALPHA .. ".c_13.row.lane.ud") ~= nil, "unread dot on a quiet lane")
	check(node(view, ALPHA .. ".c_13.row.stack.line.primary") ~= nil, "primary mark")
	local menu = c13.p.actions.menu
	eq(menu[7].label, "Mark Read", "unread card offers Mark Read")
	eq(menu[#menu].id, "remove_project=alpha", "primary: Remove Project instead of Delete")

	local snap = snapshot()
	snap.active = 11
	snap.unread = { [12] = true }
	snap.show_branch = true
	snap.projects[1].agents[1].spawned[1].state = "idle"
	view = sidebar.build(snap).view
	check(has_class(node(view, CARD), "on"), "focused card active")
	check(has_class(node(view, CARD), "unread"), "a child's unread marks the card")
	eq(node(view, CARD).p.actions.menu[7].label, "Mark Read", "a child's unread: menu offers Mark Read")
	eq(node(view, CARD .. ".row.lane.ud"), nil, "working owns the lane: no unread dot")
	check(node(view, CARD .. ".row.lane.st.spin") ~= nil, "working spinner")
	eq(node(view, CARD .. ".row.stack.meta.t").p.text, "agent/fix-login", "branch text when enabled")
	eq(node(view, ALPHA .. ".c_13.row.stack.meta"), nil, "no branch: no meta row")
	check(has_class(node(view, ALPHA .. ".c_13.row.lane.st"), "op-done"), "finished turn without branch: done dot")
	check(has_class(node(view, LIST .. ".unassigned.c_14.row.lane.st"), "op-active"), "live idle agent: active dot")
	snap.projects[1].agents[1].state = "idle"
	snap.projects[1].agents[1].detached = "abc1234"
	view = sidebar.build(snap).view
	check(not has_class(node(view, CARD .. ".row.lane.st"), "op-st"), "quiet card with a branch: no status dot")
	eq(node(view, CARD .. ".row.stack.meta.detached.t").p.text, "abc1234", "detached badge")
	snap.show_agents = false
	view = sidebar.build(snap).view
	eq(node(view, CARD .. ".row.stack.agents"), nil, "agents hidden by option")
	check(not has_class(node(view, CARD), "op-solo"), "a meta row is not title-only")
	snap.projects[1].agents[1].detached = nil
	snap.show_branch = false
	check(has_class(node(sidebar.build(snap).view, CARD), "op-solo"), "title-only card")
end)

test("identity tooltip", function()
	local snap = snapshot()
	snap.projects[1].agents[1].title = "agent/fix-login"
	eq(node(sidebar.build(snap).view, CARD .. ".row.stack.line").p.title, "agent/fix-login", "title equal to the branch: once")
	snap.unassigned[1].cwd = ""
	eq(node(sidebar.build(snap).view, LIST .. ".unassigned.c_14.row.stack.line").p.title, "scratch", "no branch, no cwd: title only")
	eq(node(sidebar.build(snapshot()).view, LIST .. ".unassigned.c_14.row.stack.line").p.title, "scratch\n/tmp", "no branch: cwd")
end)

test("card states: sleeping, deleting, reveal", function()
	local snap = snapshot()
	snap.unassigned = { { pane = -3, key = "rec", title = "old", state = "sleeping", cwd = "/tmp/wt/old", branch = "me/old" } }
	snap.projects[1].agents[1].deleting = true
	snap.reveal = 13
	local view = sidebar.build(snap).view
	local s = node(view, LIST .. ".unassigned.c_-3")
	eq(s.p.actions.click, "wake=-3", "sleeping card wakes")
	eq(ids(s.p.actions.menu), "copy_path=-3,-,delete=-3", "sleeping menu")
	check(not has_class(node(view, LIST .. ".unassigned.c_-3.row.lane.st"), "op-st"), "sleeping: no status dot")
	eq(node(view, LIST .. ".unassigned.c_-3.row.stack.agents"), nil, "sleeping: no rows")
	check(has_class(s, "op-solo"), "sleeping card is title-only")
	local d = node(view, CARD)
	check(has_class(d, "deleting"), "deleting card")
	eq(d.p.actions, nil, "deleting card is inert")
	check(node(view, CARD .. ".over.pill") ~= nil, "deleting overlay")
	check(has_class(node(view, ALPHA .. ".c_13"), "reveal"), "reveal glow")
end)

test("status rollup", function()
	local st = sidebar.card_status
	local function with(state: string, result: string?, kids: { any }?): any
		return { pane = 1, title = "a", cwd = "/", state = state, result = result, spawned = kids }
	end
	local function internal(status: string): any
		local r = with("idle")
		r.internal = { { id = "x", name = "x", status = status, depth = 0 } }
		return r
	end
	eq(st(with("idle")), "active", "idle live agent")
	eq(st(with("idle", "done")), "done", "done")
	eq(st(with("exited")), "done", "exited")
	eq(st(with("idle", nil, { with("idle", "done") })), "done", "done child over an idle root")
	eq(st(with("idle", "done", { with("idle") })), "done", "done over active")
	eq(st(with("idle", "interrupted")), "interrupted", "interrupted")
	eq(st(with("idle", "done", { with("idle", "interrupted") })), "interrupted", "interrupted > done")
	eq(st(with("idle", "interrupted", { with("working") })), "working", "working > interrupted")
	eq(st(with("working", nil, { with("idle", "failed") })), "failed", "failed > working")
	eq(st(with("idle", "failed", { with("waiting_input") })), "waiting", "waiting first")
	eq(st(with("idle", nil, { with("idle", nil, { with("waiting_input") }) })), "waiting", "two levels down")
	eq(st(with("sleeping")), "inactive", "sleeping")
	eq(st(internal("running")), "working", "internal running")
	eq(st(internal("failed")), "failed", "internal failed")
	eq(st(internal("aborted")), "interrupted", "internal aborted → interrupted")
	eq(st(internal("waiting_input")), "waiting", "internal waiting")
	eq(st(internal("pending")), "active", "internal pending is idle")
	eq(st(internal("whatever")), "active", "unknown internal status is idle")

	-- Active and unread pass up through two levels.
	local snap = snapshot()
	snap.projects[1].agents[1].spawned[1].spawned = { { pane = 30, title = "deep", state = "idle", cwd = "/" } }
	snap.active, snap.unread = 30, { [30] = true }
	local view = sidebar.build(snap).view
	check(has_class(node(view, CARD), "on"), "grandchild focused: card active")
	check(has_class(node(view, CARD), "unread"), "grandchild unread: card unread")
	check(has_class(node(view, CARD .. ".row.stack.agents.a_11"), "on"), "collapsed parent row takes the highlight")
end)

test("agent rows", function()
	local view = sidebar.build(snapshot()).view
	local AG = CARD .. ".row.stack.agents"
	local top = node(view, AG .. ".a_11")
	eq(top.p.actions.click, "focus=11", "top row focuses")
	eq(top.p.actions.dblclick, nil, "rows have no double-click")
	eq(ids(top.p.actions.menu), ids(node(view, CARD).p.actions.menu), "row menu = card menu")
	eq(node(view, AG .. ".a_11.text.lead").p.text, "Fix the login flow", "lead = prompt")
	check(has_text(node(view, AG .. ".a_11.text.trail"), "bash: run tests"), "trail = tool while working")
	eq(node(view, AG .. ".a_11.model").p.text, "anthropic/claude-opus-5-5", "model")
	check(node(view, AG .. ".a_11.who") ~= nil, "identity glyph")
	eq(node(view, AG .. ".a_11.disc.time").p.text, "5m", "time in the disclosure slot")
	eq(node(view, AG .. ".a_11.disc.chev").p.actions.click, "toggle_kids=11", "chevron toggles children")
	eq(node(view, AG .. ".a_11.kids.n").p.text, "+1", "collapsed: child count")
	check(has_class(node(view, AG .. ".a_11.kids.st"), "op-waiting"), "collapsed: signal of the waiting child")
	eq(node(view, AG .. ".l_11"), nil, "children collapsed by default")
	check(has_class(top, "on"), "collapsed parent takes the focused child's highlight")

	local AG13 = ALPHA .. ".c_13.row.stack.agents"
	check(has_text(node(view, AG13 .. ".a_13.text.trail"), "Done."), "trail = last message when not working")
	eq(node(view, AG13 .. ".a_13.time").p.text, "1h", "time since done")
	eq(node(view, AG13 .. ".a_13.disc"), nil, "no disclosure without children")

	local snap = snapshot()
	snap.projects[1].agents[1].spawned[1].state = "idle"
	snap.projects[1].agents[1].spawned[1].result = "done"
	eq(node(sidebar.build(snap).view, AG .. ".a_11.kids.st"), nil, "done children: no signal")

	snap = snapshot()
	snap.expanded = { [11] = true }
	snap.show_models = false
	snap.projects[1].agents[1].internal = running()
	view = sidebar.build(snap).view
	local rail = node(view, AG .. ".l_11")
	check(rail ~= nil, "expanded: rail")
	eq(node(view, AG .. ".a_11.kids"), nil, "expanded: no count")
	eq(node(view, AG .. ".a_11.disc.chev").p.title, "Hide 3 child agents", "count covers spawned and internal")
	check(not has_class(node(view, AG .. ".a_11"), "on"), "expanded: highlight on the child")
	eq(node(view, AG .. ".a_11.model"), nil, "models hidden by option")
	check(has_class(node(view, AG .. ".l_11.a_12"), "on"), "focused child row highlighted")
	eq(node(view, AG .. ".l_11.a_12.text.lead").p.text, "write tests", "spawned lead = title")
	check(has_text(node(view, AG .. ".l_11.a_12.text.trail"), "OMP"), "spawned row with nothing to say: OMP")
	local internal: any = nil
	for _, c in rail.c do
		if string.sub(c.p.key, 1, 2) == "s_" then
			internal = c
		end
	end
	check(internal ~= nil, "internal subagent row")
	eq(internal.p.actions.click, "focus=11", "internal row focuses its agent")
	eq(t.find(internal, "r", "r.who"), nil, "no identity glyph on subagent rows")
	eq(t.find(internal, "r", "r.time").p.text, "2m", "internal: time since first seen")
	check(has_text(t.find(internal, "r", "r.text.trail"), "Waiting for Gamma"), "internal: tool intent while running")
end)

test("idle children fold", function()
	local snap = snapshot()
	snap.expanded = { [11] = true }
	local kids = snap.projects[1].agents[1].spawned
	kids[2] = { pane = 20, title = "i1", state = "idle", cwd = "/" }
	kids[3] = { pane = 21, title = "i2", state = "idle", cwd = "/" }
	local AG = CARD .. ".row.stack.agents"
	local view = sidebar.build(snap).view
	eq(keys(node(view, AG .. ".l_11")), "a_12,idle", "active children first, then the idle group")
	eq(node(view, AG .. ".l_11.idle.lead").p.text, "2 idle", "idle group row")
	eq(node(view, AG .. ".l_11.idle").p.actions.click, "toggle_idle=11", "idle group toggles")
	snap.idle_open = { [11] = true }
	eq(keys(node(sidebar.build(snap).view, AG .. ".l_11")), "a_12,idle,a_20,a_21", "open idle group lists its rows after it")
	kids[3] = nil
	eq(keys(node(sidebar.build(snap).view, AG .. ".l_11")), "a_12,a_20", "one idle child is not folded")

	-- A pending internal subagent and an idle spawned agent fold together.
	snap.idle_open = nil
	snap.projects[1].agents[1].internal = { { id = "p.Q", name = "Q", status = "pending", depth = 0 }, { id = "p.R", name = "R", status = "running", depth = 0 } }
	view = sidebar.build(snap).view
	eq(keys(node(view, AG .. ".l_11")), "a_12,s_p_2eR,idle", "mixed children: running first, idle folded")
	eq(node(view, AG .. ".l_11.idle.lead").p.text, "2 idle", "spawned and internal idle counted together")
end)

test("activity view", function()
	local snap = snapshot()
	snap.body = "agents"
	snap.pinned = { { pane = 40, project = "alpha", title = "pinned", state = "idle", result = "failed", cwd = "/tmp/zz-test-alpha/wt/p", pinned = true } }
	snap.unassigned = { { pane = -4, title = "slept", state = "sleeping", result = "interrupted", cwd = "/tmp/wt/s" } }
	local view = sidebar.build(snap).view
	local list = node(view, LIST)
	check(has_class(list, "op-activity"), "activity list")
	eq(keys(list), "b_needs,b_working,b_done,b_idle", "status buckets in order")
	eq(node(view, LIST .. ".b_needs.head.n").p.text, "1", "bucket count")
	eq(click(view, LIST .. ".b_needs.a_12"), "focus=12", "spawned agents listed")
	check(has_text(node(view, LIST .. ".b_working.a_11.text.trail"), "Alpha app"), "project name as trail")
	check(node(view, LIST .. ".b_done.a_40") ~= nil, "failed pinned row under Done")
	check(has_text(node(view, LIST .. ".b_done.a_40.text.trail"), "Alpha app"), "pinned row resolves its project")
	eq(click(view, LIST .. ".b_idle.a_-4"), "wake=-4", "sleeping row wakes")
	eq(node(view, LIST .. ".b_done.a_-4"), nil, "sleeping row is idle whatever its last turn")
	eq(node(view, LIST .. ".b_idle.c_15"), nil, "no cards in the activity view")
	local empty = sidebar.build({ projects = {}, body = "agents" }).view
	check(node(empty, LIST .. ".empty") ~= nil, "empty activity view")
end)

test("ago", function()
	eq(sidebar.ago(NOW, NOW - 59), "now", "59s")
	eq(sidebar.ago(NOW, NOW - 60), "1m", "60s")
	eq(sidebar.ago(NOW, NOW - 3599), "59m", "3599s")
	eq(sidebar.ago(NOW, NOW - 3600), "1h", "3600s")
	eq(sidebar.ago(NOW, NOW - 86399), "23h", "86399s")
	eq(sidebar.ago(NOW, NOW - 86400), "1d", "86400s")
	eq(sidebar.ago(NOW, NOW + 30), "now", "clock skew")
	eq(sidebar.ago(nil, NOW), nil, "no clock")
	eq(sidebar.ago(NOW, nil), nil, "no start")
end)

test("long first lines cut on a character", function()
	local snap = snapshot()
	snap.projects[1].agents[1].state = "idle"
	snap.projects[1].agents[1].last_message = string.rep("a", 158) .. string.rep("é", 10)
	local trail = node(sidebar.build(snap).view, CARD .. ".row.stack.agents.a_11.text.trail").p.text
	check(utf8.len(trail) ~= nil, "valid UTF-8 after the cut")
end)

test("canvas-safe tree", function()
	local expanded = snapshot()
	expanded.expanded = { [11] = true }
	expanded.projects[1].agents[1].internal = running()
	local agents = snapshot()
	agents.body = "agents"
	for _, snap in { snapshot(), expanded, agents, { projects = {} } } do
		local built = sidebar.build(snap)
		for _, root in { { built.view, ROOT }, { built.dock, "footer" } } do
			t.walk(root[1], root[2], function(n, id, _parent)
				check(n.k ~= "input" and n.k ~= "editor" and n.k ~= "image", "kind not allowed in canvas at " .. id)
				check(not (n.k == "el" and n.p and n.p.tag == "input"), "no input element at " .. id)
				local seen = {}
				for _, c in n.c or {} do
					local key = c.p and c.p.key
					if key ~= nil then
						check(not seen[key], "duplicate key " .. key .. " under " .. id)
						check(not string.find(key, "[%./]"), "key without . or / at " .. id)
						seen[key] = true
					end
				end
				local acts = n.p and n.p.actions
				if acts then
					for _, a in { acts.click, acts.dblclick } do
						local name = string.match(a, "^([^=]+)")
						check((sidebar.ACT :: any)[name] ~= nil, "known action " .. a)
					end
					if acts.menu ~= nil then
						for _, item in acts.menu do
							if type(item) == "table" then
								local name = string.match(item.id, "^([^=]+)")
								check((sidebar.ACT :: any)[name] ~= nil, "known menu action " .. item.id)
							else
								eq(item, "-", "menu separator")
							end
						end
					end
				end
			end)
		end
	end
end)

test("node budget", function()
	local snap = snapshot()
	snap.expanded = {}
	local many = {}
	for i = 1, 40 do
		table.insert(many, { id = "m." .. i, name = "s" .. i, status = "running", depth = 0, tool = "read", first_seen = NOW })
	end
	for i = 1, 22 do
		snap.expanded[100 + i] = true
		table.insert(snap.projects[1].agents, { pane = 100 + i, title = "a" .. i, state = "working", cwd = "/tmp", internal = many })
	end
	local view = sidebar.build(snap).view
	check(count(view, ROOT) < 2000, "workspaces under the cap (" .. count(view, ROOT) .. ")")
	check(node(view, ALPHA .. ".c_101.row.stack.agents.l_101") ~= nil, "early rails still open")
	snap.body = "agents"
	for i = 1, 200 do
		table.insert(snap.unassigned, { pane = 1000 + i, title = "u" .. i, state = "idle", cwd = "/" })
	end
	view = sidebar.build(snap).view
	check(count(view, ROOT) < 2000, "activity under the cap (" .. count(view, ROOT) .. ")")
end)

test("parse_action", function()
	local a, v = sidebar.parse_action({ act = "focus", value = "11" })
	eq(a, "focus", "split act")
	eq(v, 11, "pane value is a number")
	a, v = sidebar.parse_action({ act = "wake=-7" })
	eq(a, "wake", "unsplit act (scripted event)")
	eq(v, -7, "negative pane round-trips")
	for _, name in { "rename", "sleep", "delete", "toggle_unread", "toggle_pin", "copy_path", "copy_name", "open_finder", "toggle_kids", "toggle_idle", "new_subagent" } do
		a, v = sidebar.parse_action({ act = name, value = "-9" })
		eq(v, -9, name .. " takes a pane")
	end
	a, v = sidebar.parse_action({ act = "new_agent", value = "my-proj" })
	eq(v, "my-proj", "project id stays a string")
	a, v = sidebar.parse_action({ act = "toggle_group=12" })
	eq(v, "12", "project ids stay strings even when numeric")
	a, v = sidebar.parse_action({ act = "toggle_group=group:a=b" })
	eq(a, "toggle_group", "split at the first =")
	eq(v, "group:a=b", "later = kept in the value")
	a, v = sidebar.parse_action({ act = "focus=abc" })
	eq(v, "abc", "non-numeric pane stays a string")
	a, v = sidebar.parse_action({ act = "focus=" })
	eq(a, "focus", "empty value: name")
	eq(v, "", "empty value kept")
	a, v = sidebar.parse_action({})
	eq(a, nil, "no act")
	eq(v, nil, "no value")
	a, v = sidebar.parse_action({ act = "reveal" })
	eq(a, "reveal", "plain")
	eq(v, nil, "no value")
end)

t.finish("sidebar")
