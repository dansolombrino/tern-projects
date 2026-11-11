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

local function snapshot(): any
	return {
		now = NOW,
		active = 12,
		unread = { [13] = true },
		collapsed = { beta = true },
		projects = {
			{
				project = { id = "alpha", name = "Alpha app", root = "/tmp/zz-test-alpha", color = "orange" },
				session_exists = true,
				current = true,
				agents = {
					{
						pane = 11, title = "fix login", state = "working", model = "anthropic/claude-opus-5-5",
						last_message = "  Looking at auth.ts\nsecond line", cwd = "/tmp/zz-test-alpha/wt/fix-login",
						branch = "agent/fix-login", started = NOW - 5 * 60,
						internal = subagents.extract(t.fixture("omp-subagents-nested-done")),
						spawned = {
							{ pane = 12, title = "write tests", state = "waiting_input", cwd = "/tmp/zz-test-alpha", started = NOW - 30 },
						},
					},
					{ pane = 13, title = "docs", state = "exited", cwd = "/tmp/zz-test-alpha", primary = true, last_message = "Done." },
				},
			},
			{
				project = { id = "beta", name = "Beta", root = "/tmp/zz-test-beta" },
				session_exists = false,
				current = false,
				agents = { { pane = 15, title = "hidden", state = "idle", cwd = "/tmp/zz-test-beta" } },
			},
			{
				project = { id = "gamma.x/y", name = "Gamma", root = "/tmp/zz-test-gamma" },
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

-- Text of every el under `n`, concatenated.
local function text_of(n: any): string
	local out = {}
	t.walk(n, "x", function(m)
		if m.p and type(m.p.text) == "string" then
			table.insert(out, m.p.text)
		end
	end)
	return table.concat(out, "|")
end

local CARD = LIST .. ".g_alpha.c_11"

test("empty snapshot: Add project CTA, header and footer", function()
	local built = sidebar.build({ projects = {}, unassigned = {} })
	eq(built.view.p.key, sidebar.ROOT_KEY, "root key matches ROOT_ID")
	check(has_class(built.view, sidebar.ROOT_CLASS), "root carries ROOT_CLASS")
	eq(click(built.view, LIST .. ".empty.add"), "add_project", "empty state offers Add project")
	eq(click(built.view, ROOT .. ".head.acts.new"), "add_project", "header + adds a project when there are none")
	eq(node(built.view, ROOT .. ".head.collapse"), nil, "no collapse-all without projects")
	eq(click(built.view, ROOT .. ".nav.search"), "search", "Search pill")
	eq(click(built.dock, "footer.l.options", "footer"), "options", "footer options")
	eq(click(built.dock, "footer.l.cleanup", "footer"), "cleanup", "footer cleanup")
	eq(click(built.dock, "footer.r.next", "footer"), "next_waiting", "footer next waiting")
	eq(click(built.dock, "footer.r.hide", "footer"), "hide", "footer hide")
	check(node(built.dock, "footer.r.next.cross", "footer") ~= nil, "crosshair when nobody waits")
	check(sidebar.build({ projects = {} }).view ~= nil, "unassigned optional")
end)

test("section header", function()
	local view = sidebar.build(snapshot()).view
	eq(node(view, ROOT .. ".head.title").p.text, "Projects", "title")
	eq(click(view, ROOT .. ".head.collapse"), "collapse_all", "collapse all")
	eq(click(view, ROOT .. ".head.acts.options"), "options", "options")
	eq(click(view, ROOT .. ".head.acts.add"), "add_project", "add project")
	eq(click(view, ROOT .. ".head.acts.new"), "new_agent=alpha", "+ targets the current project")
	eq(click(view, ROOT .. ".head.acts.bell"), "next_waiting", "bell")
	eq(node(view, ROOT .. ".head.acts.bell.badge.n").p.text, "1", "waiting count on the bell")
	local snap = snapshot()
	snap.projects[1].current = false
	eq(click(sidebar.build(snap).view, ROOT .. ".head.acts.new"), "new_agent", "no current project: bare new_agent")
	snap.waiting = 4
	local built = sidebar.build(snap)
	eq(node(built.view, ROOT .. ".head.acts.bell.badge.n").p.text, "4", "snapshot waiting count wins")
	check(has_class(node(built.dock, "footer.r.next", "footer"), "op-alert"), "footer alerts when agents wait")
end)

test("group headers", function()
	local view = sidebar.build(snapshot()).view
	local head = node(view, LIST .. ".g_alpha.head")
	eq(head.p.actions.click, "toggle_group=alpha", "header click toggles")
	eq(head.p.actions.menu[1].id, "new_agent=alpha", "menu: New agent")
	eq(head.p.actions.menu[2].id, "open_project=alpha", "menu: Open session")
	eq(head.p.actions.menu[3], "-", "menu separator")
	eq(head.p.actions.menu[4].id, "remove_project=alpha", "menu: Remove project")
	check(head.p.actions.menu[4].danger == true, "remove is destructive")
	eq(node(view, LIST .. ".g_alpha.head.name").p.text, "Alpha app", "name")
	check(has_class(node(view, LIST .. ".g_alpha.head.icon"), "op-c-orange"), "folder in the project color")
	eq(click(view, LIST .. ".g_alpha.head.acts.chev"), "toggle_group=alpha", "chevron toggles")
	eq(click(view, LIST .. ".g_alpha.head.acts.more"), "project_menu=alpha", "… opens the project menu")
	eq(node(view, LIST .. ".g_alpha.head.acts.more").p.actions.menu[4].id, "remove_project=alpha", "… right-click menu")
	eq(click(view, LIST .. ".g_alpha.head.acts.new"), "new_agent=alpha", "+ starts an agent")

	local beta = node(view, LIST .. ".g_beta")
	check(has_class(beta, "collapsed"), "collapsed group marked")
	eq(node(view, LIST .. ".g_beta.c_15"), nil, "collapsed group hides its cards")

	eq(click(view, LIST .. ".g_gamma_x_y.none"), "new_agent=gamma.x/y", "empty project offers New agent; id kept")

	local un = node(view, LIST .. ".unassigned")
	check(un ~= nil, "Unassigned group")
	eq(node(view, LIST .. ".unassigned.head.name").p.text, "Unassigned", "Unassigned title")
	eq(node(view, LIST .. ".unassigned.head.acts"), nil, "Unassigned has no actions")
	eq(click(view, LIST .. ".unassigned.c_14"), "focus=14", "unassigned card focuses")
	local menu = node(view, LIST .. ".unassigned.c_14").p.actions.menu
	for _, item in menu do
		check(type(item) ~= "table" or not string.find(item.id, "^open_project"), "no Open project for unassigned")
	end
end)

test("worktree cards", function()
	local view = sidebar.build(snapshot()).view
	local c11 = node(view, CARD)
	eq(c11.p.actions.click, "focus=11", "card click focuses")
	eq(c11.p.actions.dblclick, "rename=11", "card double-click renames")
	local labels = {}
	for _, item in c11.p.actions.menu do
		table.insert(labels, if type(item) == "table" then item.id else item)
	end
	eq(table.concat(labels, ","), "focus=11,rename=11,new_subagent=11,-,open_project=alpha,-,stop=11", "card menu")
	eq(node(view, CARD .. ".line.title").p.text, "fix login", "title")
	eq(node(view, CARD .. ".meta.chip.t").p.text, "agent/fix-login", "branch line")
	check(has_class(node(view, CARD .. ".line.st"), "op-waiting"), "a waiting child rolls up to the card")
	check(has_class(c11, "on2"), "card of the focused child is secondary-active")
	eq(node(view, CARD .. ".line.primary"), nil, "worktree agent has no primary mark")

	local c13 = node(view, LIST .. ".g_alpha.c_13")
	check(has_class(c13, "unread"), "unread card")
	check(has_class(node(view, LIST .. ".g_alpha.c_13.line.st"), "op-unread"), "unread bell replaces the status")
	check(node(view, LIST .. ".g_alpha.c_13.line.primary") ~= nil, "primary mark")
	eq(node(view, LIST .. ".g_alpha.c_13.meta.chip.t").p.text, "zz-test-alpha", "no branch: cwd basename")

	local snap = snapshot()
	snap.active = 11
	snap.unread = {}
	snap.projects[1].agents[1].spawned[1].state = "idle"
	view = sidebar.build(snap).view
	check(has_class(node(view, CARD), "on"), "focused card active")
	check(node(view, CARD .. ".line.st.spin") ~= nil, "working spinner")
	check(has_class(node(view, LIST .. ".g_alpha.c_13.line.st"), "op-done"), "exited: done dot")
	check(has_class(node(view, LIST .. ".unassigned.c_14.line.st"), "op-idle"), "idle: neutral dot")
end)

test("nested agent rows", function()
	local view = sidebar.build(snapshot()).view
	local lead = node(view, CARD .. ".agents.a_11")
	eq(lead.p.actions.click, "focus=11", "lead row focuses")
	eq(node(view, CARD .. ".agents.a_11.text.lead").p.text, "Looking at auth.ts", "first line of the last message")
	eq(node(view, CARD .. ".agents.a_11.model").p.text, "anthropic/claude-opus-5-5", "model")
	eq(node(view, CARD .. ".agents.a_11.time").p.text, "5m", "time label")
	check(node(view, CARD .. ".agents.a_11.who") ~= nil, "agent icon")

	local child = node(view, CARD .. ".agents.l_11.a_12")
	check(child ~= nil, "spawned subagent in the lineage rail")
	check(has_class(child, "on"), "focused child row highlighted")
	eq(child.p.actions.click, "focus=12", "child focuses")
	eq(child.p.actions.dblclick, "rename=12", "child renames")
	eq(node(view, CARD .. ".agents.l_11.a_12.time").p.text, "now", "now")
	check(has_class(node(view, CARD .. ".agents.l_11.a_12.st"), "op-waiting"), "question glyph")

	local rail = node(view, CARD .. ".agents.l_11")
	local internal: { any } = {}
	for _, c in rail.c do
		if string.sub(c.p.key, 1, 2) == "s_" then
			table.insert(internal, c)
		end
	end
	eq(#internal, 3, "three internal subagents from the fixture")
	eq(rail.c[1].p.key, "a_12", "spawned rows before internal ones")
	check(string.find(text_of(internal[1]), "Beta", 1, true) ~= nil, "order kept: Beta first")
	check(not has_class(internal[1], "op-d1"), "top internal subagent not indented")
	check(has_class(internal[2], "op-d1"), "nested internal subagent indented")
	check(has_class(node(view, CARD .. ".agents.l_11." .. internal[1].p.key .. ".st"), "op-done"), "omp done → done")
	eq(internal[1].p.actions.click, "focus=11", "internal row focuses its agent")
	eq(node(view, CARD .. ".agents.l_11." .. internal[1].p.key .. ".who"), nil, "no identity icon on subagent rows")
	eq(node(view, LIST .. ".g_alpha.c_13.agents.l_13"), nil, "no rail without children")
end)

test("running internal subagent shows its tool; overflow row", function()
	local snap = snapshot()
	snap.projects[1].agents[1].internal = subagents.extract(t.fixture("omp-subagents-running"))
	local view = sidebar.build(snap).view
	local found = false
	t.walk(node(view, CARD .. ".agents.l_11"), "r", function(n)
		if n.p and n.p.class == "op-trail" and string.find(n.p.text, "bash", 1, true) then
			found = true
		end
	end)
	check(found, "tool line while running")

	local many = {}
	for i = 1, sidebar.MAX_INTERNAL + 3 do
		table.insert(many, { id = "x." .. i, name = "s" .. i, status = "running", depth = 0 })
	end
	snap.projects[1].agents[1].internal = many
	local rail = node(sidebar.build(snap).view, CARD .. ".agents.l_11")
	local rows, more = 0, nil
	for _, c in rail.c do
		if string.sub(c.p.key, 1, 2) == "s_" then
			rows += 1
		elseif c.p.key == "more" then
			more = c
		end
	end
	eq(rows, sidebar.MAX_INTERNAL, "capped")
	check(more ~= nil and string.find(text_of(more), "3 more", 1, true) ~= nil, "overflow row")
	eq(more.p.actions.click, "focus=11", "overflow row focuses the agent")
end)

test("ago", function()
	eq(sidebar.ago(NOW, NOW - 10), "now", "now")
	eq(sidebar.ago(NOW, NOW - 5 * 60), "5m", "minutes")
	eq(sidebar.ago(NOW, NOW - 3 * 3600), "3h", "hours")
	eq(sidebar.ago(NOW, NOW - 2 * 86400), "2d", "days")
	eq(sidebar.ago(nil, NOW), nil, "no clock")
	eq(sidebar.ago(NOW, nil), nil, "no start")
end)

test("canvas-safe tree", function()
	for _, snap in { snapshot(), { projects = {} } } do
		local built = sidebar.build(snap)
		local count = 0
		for _, root in { { built.view, ROOT }, { built.dock, "footer" } } do
			t.walk(root[1], root[2], function(n, id, _parent)
				count += 1
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
						check(type(acts.menu) == "table", "menu is a list at " .. id)
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
		check(count < 2000, "under the canvas node cap")
	end
end)

test("big snapshot stays under the node cap", function()
	local snap = snapshot()
	for i = 1, 20 do
		table.insert(snap.projects[1].agents, {
			pane = 100 + i, title = "a" .. i, state = "working", cwd = "/tmp", internal = subagents.extract(t.fixture("omp-subagents-nested-done")),
		})
	end
	local count = 0
	t.walk(sidebar.build(snap).view, ROOT, function()
		count += 1
	end)
	check(count < 2000, "under the canvas node cap with 22 agents (" .. count .. ")")
end)

test("parse_action", function()
	local a, v = sidebar.parse_action({ act = "focus", value = "11" })
	eq(a, "focus", "split act")
	eq(v, 11, "pane value is a number")
	a, v = sidebar.parse_action({ act = "stop=7" })
	eq(a, "stop", "unsplit act (scripted event)")
	eq(v, 7, "unsplit value")
	a, v = sidebar.parse_action({ act = "rename", value = "9" })
	eq(v, 9, "rename takes a pane")
	a, v = sidebar.parse_action({ act = "new_agent", value = "my-proj" })
	eq(v, "my-proj", "project id stays a string")
	a, v = sidebar.parse_action({ act = "toggle_group=12" })
	eq(v, "12", "project ids stay strings even when numeric")
	a, v = sidebar.parse_action({ act = "refresh" })
	eq(a, "refresh", "plain")
	eq(v, nil, "no value")
end)

t.finish("sidebar")
