--!strict
-- luau tests/test_dashboard.luau

local t = require("./support")
local dashboard = require("../dashboard")
local subagents = require("../subagents")

local check, eq, test = t.check, t.eq, t.test

dashboard.ui = t.ui

local ROOT = dashboard.ROOT_ID

local function snapshot(): any
	return {
		projects = {
			{
				project = { id = "alpha", name = "Alpha app", root = "/tmp/zz-test-alpha" },
				session_exists = true,
				current = true,
				agents = {
					{
						pane = 11, title = "fix login", state = "working", model = "anthropic/claude-opus-5-5",
						last_message = "  Looking at auth.ts\nsecond line", cwd = "/tmp/zz-test-alpha", branch = "agent/fix-login",
						internal = subagents.extract(t.fixture("omp-subagents-nested-done")),
						spawned = {
							{ pane = 12, title = "write tests", state = "waiting_input", cwd = "/tmp/zz-test-alpha" },
						},
					},
					{ pane = 13, title = "docs", state = "exited", cwd = "/tmp/zz-test-alpha", last_message = "Done." },
				},
			},
			{
				project = { id = "beta", name = "Beta", root = "/tmp/zz-test-beta" },
				session_exists = false,
				current = false,
				agents = {},
			},
		},
		unassigned = { { pane = 14, title = "scratch", state = "idle", cwd = "/tmp" } },
	}
end

-- Click action of the node with id `id` (under root id `root`, default the view's).
local function click(view: any, id: string, root: string?): string?
	local n = t.find(view, root or ROOT, id)
	return n and n.p and n.p.actions and n.p.actions.click
end

local function agent(view: any, pane: number): any
	return t.find(view, ROOT, string.format("%s.p_alpha.a_%d.agent", ROOT, pane))
end

test("empty snapshot: empty state and dock", function()
	local built = dashboard.build({ projects = {}, unassigned = {} })
	local empty = t.find(built.view, ROOT, ROOT .. ".empty")
	check(empty ~= nil and empty.k == "empty", "empty node")
	eq(click(built.view, ROOT .. ".empty.add"), "add_project", "Add project button in empty state")
	eq(click(built.dock, "dock.add", "dock"), "add_project", "dock Add project")
	eq(click(built.dock, "dock.refresh", "dock"), "refresh", "dock Refresh")
	eq(built.view.p.key, dashboard.ROOT_KEY, "root key matches ROOT_ID")
	-- unassigned omitted entirely is fine too
	check(dashboard.build({ projects = {} }).view ~= nil, "unassigned optional")
end)

test("project card with head actions", function()
	local view = dashboard.build(snapshot()).view
	local card = t.find(view, ROOT, ROOT .. ".p_alpha")
	check(card ~= nil and card.k == "card", "card per project")
	eq(card.p.head[1].t, "Alpha app", "head is the name")
	eq(card.p["end"], ROOT .. ".p_alpha.end", "end names its own child by full id")
	check(t.find(view, ROOT, card.p["end"]) ~= nil, "end child exists")
	eq(click(view, ROOT .. ".p_alpha.end.open"), "open_project=alpha", "Open")
	eq(click(view, ROOT .. ".p_alpha.end.new"), "new_agent=alpha", "New agent")
	eq(card.p.tone, "accent", "current project accented")
	eq(card.p.status, "pending", "a waiting agent marks the card pending")
	check(string.find(card.p.meta, "2 agents", 1, true) ~= nil, "meta counts top-level agents")
	check(string.find(card.p.meta, "1 need you", 1, true) ~= nil, "meta counts waiting")
	local beta = t.find(view, ROOT, ROOT .. ".p_beta")
	check(string.find(beta.p.meta, "no session", 1, true) ~= nil, "no session noted")
	eq(beta.p.tone, nil, "not current, not accented")
	eq(click(view, ROOT .. ".p_beta.none.start"), "new_agent=beta", "empty project offers New agent")
end)

test("agent rows: states, badges, buttons", function()
	local view = dashboard.build(snapshot()).view
	local a11 = agent(view, 11)
	eq(a11.k, "agent", "agent kind")
	eq(a11.p.status, "running", "working -> running")
	eq(a11.p.name, "fix login", "name")
	eq(a11.p.task, "Looking at auth.ts", "first line of last message")
	eq(a11.p.depth, 0, "top level depth")
	eq(a11.p.badges[1].text, "agent/fix-login", "branch badge")
	eq(a11.p.actions.click, "focus=11", "row click focuses")
	eq(click(view, ROOT .. ".p_alpha.a_11.acts.focus"), "focus=11", "Focus")
	eq(click(view, ROOT .. ".p_alpha.a_11.acts.subagent"), "new_subagent=11", "Subagent")
	eq(click(view, ROOT .. ".p_alpha.a_11.acts.stop"), "stop=11", "Stop")

	local a12 = agent(view, 12)
	eq(a12.p.status, "pending", "waiting_input -> pending")
	eq(a12.p.badges[1].text, "needs you", "needs-you badge")
	eq(a12.p.badges[1].tone, "warning", "warning tone")
	eq(a12.p.depth, 1, "spawned subagent nested")
	eq(a12.p.task, "/tmp/zz-test-alpha", "cwd when no message")

	local a13 = agent(view, 13)
	eq(a13.p.status, "done", "exited -> done")
	eq(t.find(view, ROOT, ROOT .. ".p_alpha.a_13.acts.stop").p.disabled, "Already exited", "Stop disabled once exited")

	local u = t.find(view, ROOT, ROOT .. ".unassigned.a_14.agent")
	eq(u.p.status, "idle", "idle -> idle")
	eq(click(view, ROOT .. ".unassigned.a_14.acts.subagent"), "new_subagent=14", "unassigned rows have buttons")
end)

test("internal subagents nested under their agent", function()
	local view = dashboard.build(snapshot()).view
	local card = t.find(view, ROOT, ROOT .. ".p_alpha")
	local internal = {}
	for _, c in card.c do
		if c.k == "agent" then
			table.insert(internal, c)
		end
	end
	eq(#internal, 3, "three internal subagents from the fixture")
	eq(internal[1].p.name, "Beta", "order kept")
	eq(internal[1].p.depth, 1, "internal subagent one deeper than its agent")
	eq(internal[2].p.depth, 2, "nested internal subagent deeper still")
	eq(internal[1].p.status, "done", "omp status passed through")
	eq(internal[1].p.actions.click, "focus=11", "click focuses the parent agent")
	eq(internal[1].p.tool, nil, "no tool line when done")
	eq(internal[1].p.stats.tools, 3, "stats")
	-- spawned rows come right after their parent, internal ones after those
	local order = {}
	for _, c in card.c do
		table.insert(order, if c.p and c.p.key then c.p.key else c.k)
	end
	eq(order[2], "a_11", "agent 11 row")
	eq(order[3], "a_12", "spawned child next")
	eq(order[4], internal[1].p.key, "internal subagents after spawned")
end)

test("running internal subagent shows its tool; overflow line", function()
	local snap = snapshot()
	snap.projects[1].agents[1].internal = subagents.extract(t.fixture("omp-subagents-running"))
	local card = t.find(dashboard.build(snap).view, ROOT, ROOT .. ".p_alpha")
	local found = nil
	for _, c in card.c do
		if c.k == "agent" and c.p.name == "Alpha" then
			found = c
		end
	end
	check(found ~= nil and found.p.tool.name == "bash", "tool line while running")

	local many = {}
	for i = 1, dashboard.MAX_INTERNAL + 3 do
		table.insert(many, { id = "x." .. i, name = "s" .. i, status = "running", depth = 0 })
	end
	snap.projects[1].agents[1].internal = many
	card = t.find(dashboard.build(snap).view, ROOT, ROOT .. ".p_alpha")
	local agents, more = 0, nil
	for _, c in card.c do
		if c.k == "agent" then
			agents += 1
		elseif c.k == "text" then
			more = c
		end
	end
	eq(agents, dashboard.MAX_INTERNAL, "capped")
	check(more ~= nil and string.find(more.p.spans[1].t, "3 more", 1, true) ~= nil, "overflow line")
end)

test("canvas-safe tree", function()
	local built = dashboard.build(snapshot())
	local count = 0
	for _, root in { { built.view, ROOT }, { built.dock, "dock" } } do
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
			local a = n.p and n.p.actions and n.p.actions.click
			if a then
				local name = string.match(a, "^([^=]+)")
				check((dashboard.ACT :: any)[name] ~= nil, "known action " .. a)
			end
		end)
	end
	check(count < 2000, "under the canvas node cap")
end)

test("parse_action", function()
	local a, v = dashboard.parse_action({ act = "focus", value = "11" })
	eq(a, "focus", "split act")
	eq(v, 11, "pane value is a number")
	a, v = dashboard.parse_action({ act = "stop=7" })
	eq(a, "stop", "unsplit act (scripted event)")
	eq(v, 7, "unsplit value")
	a, v = dashboard.parse_action({ act = "new_agent", value = "my-proj" })
	eq(v, "my-proj", "project id stays a string")
	a, v = dashboard.parse_action({ act = "refresh" })
	eq(a, "refresh", "plain")
	eq(v, nil, "no value")
end)

t.finish("dashboard")
