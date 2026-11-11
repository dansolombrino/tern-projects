--!strict
-- luau tests/test_subagents.luau

local t = require("./support")
local subagents = require("../subagents")

local check, eq, test = t.check, t.eq, t.test

local function by_name(list: { any }): { [string]: any }
	local out = {}
	for _, s in list do
		out[s.name] = s
	end
	return out
end

test("tolerates nil and junk", function()
	eq(#subagents.extract(nil), 0, "nil")
	eq(#subagents.extract("omp text read"), 0, "string")
	eq(#subagents.extract({}), 0, "empty table")
	eq(#subagents.extract({ main = { k = "col", more = 40 } }), 0, "capped col with no children")
	eq(#subagents.extract({ main = { k = "agent" } }), 1, "agent without props")
	eq(subagents.extract({ main = { k = "agent" } })[1].status, "pending", "missing status reads pending")
	eq(#subagents.extract({ main = { k = "col", c = { 1, "x", false } } }), 0, "non-table children")
end)

test("fixture: working, no subagents yet", function()
	eq(#subagents.extract(t.fixture("omp-working-no-subagents")), 0, "no agent nodes")
end)

test("fixture: one subagent pending", function()
	local list = subagents.extract(t.fixture("omp-subagent-pending"))
	eq(#list, 1, "one subagent")
	eq(list[1].name, "Alpha", "name")
	eq(list[1].status, "pending", "status")
	eq(list[1].depth, 0, "depth")
end)

test("fixture: two running subagents with tools", function()
	local list = subagents.extract(t.fixture("omp-subagents-running"))
	eq(#list, 2, "two subagents")
	local s = by_name(list)
	eq(s.Alpha.status, "running", "Alpha running")
	eq(s.Alpha.tool, "bash", "Alpha tool")
	eq(s.Alpha.intent, "Sleeping 20 seconds", "Alpha intent")
	eq(s.Alpha.tools, 1, "Alpha tool count")
	eq(s.Alpha.model, "anthropic/claude-opus-5-5", "Alpha model")
	eq(s.Beta.tool, "wait", "Beta waits for its own subagent")
	eq(s.Alpha.id, "z.Alpha", "id is the TSP node id")
	check(type(s.Alpha.task) == "string" and string.find(s.Alpha.task, "sleep 20", 1, true) ~= nil, "Alpha task")
end)

test("fixture: nested subagent, all done", function()
	local list = subagents.extract(t.fixture("omp-subagents-nested-done"))
	eq(#list, 3, "Beta, its Gamma and Alpha")
	eq(list[1].name, "Beta", "document order: Beta first")
	eq(list[2].name, "Beta>Gamma", "then Beta's child")
	eq(list[3].name, "Alpha", "then Alpha")
	eq(list[1].depth, 0, "Beta depth")
	eq(list[2].depth, 1, "Gamma depth")
	eq(list[2].id, "z.Beta/Beta.Gamma", "nested id")
	eq(list[1].status, "done", "Beta done")
	eq(list[3].status, "done", "Alpha done")
	-- omp 18.18.8 leaves the nested row "pending" after its parent finished; kept verbatim.
	eq(list[2].status, "pending", "Gamma status verbatim")
	eq(list[1].tools, 3, "Beta tools")
	check((list[1].cost or 0) > 0, "Beta cost")
	check((list[1].context or 0) > 0 and (list[1].context or 1) < 1, "Beta context fraction")
	eq(list[1].tool, nil, "no running tool once done")
	local counts = subagents.counts(list)
	eq(counts.done, 2, "counts.done")
	eq(counts.pending, 1, "counts.pending")
end)

test("fixture: fast run done", function()
	local list = subagents.extract(t.fixture("omp-subagents-fast-done"))
	eq(#list, 2, "two subagents")
	eq(list[1].name, "Alpha", "Alpha")
	eq(list[2].name, "Beta", "Beta")
	eq(list[1].status, "done", "done")
end)

test("fixture: node-capped read", function()
	local tree = t.fixture("omp-subagents-capped")
	check((tree.more or 0) > 0 and (tree.main.more or 0) > 0, "capture is really capped")
	local list = subagents.extract(tree)
	eq(#list, 3, "agents still found in what the cap kept")
end)

test("synthetic: depth from nesting, dedup, spans, bare node", function()
	local tree = {
		k = "col",
		c = {
			{ id = "a", k = "agent", p = { name = { { t = "Lead" } }, task = { t = "plan" }, status = "running" }, c = {
				{ id = "a.b", k = "agent", p = { name = "Kid", status = "done" }, c = {
					{ id = "a.b.c", k = "agent", p = { name = "Grandkid", depth = 1 } },
				} },
			} },
			{ id = "a", k = "agent", p = { name = "Lead again" } },
			{ k = "agent", p = { key = "k1", name = "Keyed" } },
			{ k = "agent", p = { name = "Anon" } },
		},
	}
	local list = subagents.extract(tree)
	eq(#list, 5, "duplicate id dropped")
	eq(list[1].name, "Lead", "span name")
	eq(list[1].task, "plan", "span task")
	eq(list[2].depth, 1, "child without depth prop nests one deeper")
	eq(list[3].depth, 2, "nesting wins over a smaller depth prop")
	eq(list[4].id, "k1", "key as id fallback")
	check(list[5].id ~= "" and list[5].id ~= list[4].id, "generated id for id-less node")
end)

test("running: live ones, flattened owners first", function()
	local function mk(name, depth, status)
		return { id = name, name = name, depth = depth, status = status }
	end
	local function names(list)
		local out = {}
		for _, s in list do
			table.insert(out, s.name)
		end
		return table.concat(out, ",")
	end
	local list = {
		mk("A", 0, "done"),
		mk("A1", 1, "running"),
		mk("A2", 1, "pending"),
		mk("B", 0, "running"),
		mk("B1", 1, "pending"),
		mk("C", 0, "failed"),
		mk("C1", 1, "done"),
		mk("D", 0, "pending"),
		mk("E", 0, "aborted"),
		mk("E1", 1, "done"),
		mk("E2", 2, "running"),
	}
	eq(names(subagents.running(list)), "A,A1,B,B1,D,E,E1,E2", "settled owners only above running work; stale pending dropped")
	eq(#subagents.running({}), 0, "empty")
	eq(#subagents.running(subagents.extract(t.fixture("omp-subagents-nested-done"))), 0, "all done: nothing (stale nested pending dropped)")
	eq(#subagents.running(subagents.extract(t.fixture("omp-subagents-running"))), 2, "running fixture keeps both")
	eq(#subagents.running(subagents.extract(t.fixture("omp-subagent-pending"))), 1, "pending kept")
end)

test("tool: the agent's own running tool", function()
	eq(subagents.tool(t.fixture("omp-subagents-running")), "task: Spawning Alpha and Beta subagents", "running task tool, not the subagents' tools")
	eq(subagents.tool(t.fixture("omp-subagents-nested-done")), nil, "nothing running")
	eq(subagents.tool(nil), nil, "nil")
	eq(subagents.tool({ k = "col", c = { { k = "tool", p = { status = "running", name = "bash" } } } }), "bash", "no intent")
	eq(subagents.tool({ k = "agent", c = { { k = "tool", p = { status = "running", name = "bash" } } } }), nil, "inside a subagent: not the agent's")
end)

t.finish("subagents")
