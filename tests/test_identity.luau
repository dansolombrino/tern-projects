--!nonstrict
-- luau tests/test_identity.luau

local t = require("./support")
local identity = require("../identity")

local check, eq, test = t.check, t.eq, t.test

local NOW = 1000000

test("a record stays on its live pane and learns its session file", function()
	local r = { a = { pane = 5, cwd = "/w", started = 1 } }
	local by, changed = identity.bind(r, { [5] = { cwd = "/w" } }, { [5] = "/s/a.jsonl" }, NOW)
	eq(by[5], "a", "bound")
	check(changed, "session file is a change")
	eq(r.a.session_file, "/s/a.jsonl", "session file stored")
	local _, again = identity.bind(r, { [5] = { cwd = "/w" } }, { [5] = "/s/a.jsonl" }, NOW)
	check(not again, "nothing changes the second time")
end)

test("after a restart a record follows its omp session file to a new pane", function()
	local r = { a = { pane = 5, session_file = "/s/a.jsonl", cwd = "/w", started = 1 } }
	local by, changed = identity.bind(r, { [900] = { cwd = "/w" }, [901] = { cwd = "/w" } }, { [900] = "/s/b.jsonl", [901] = "/s/a.jsonl" }, NOW)
	eq(by[901], "a", "re-attached by session file")
	eq(by[900], nil, "the other pane stays unclaimed")
	eq(r.a.pane, 901, "pane updated")
	check(changed, "changed")
end)

test("a worktree owner re-attaches by its worktree when the session file is unknown", function()
	local r = { a = { pane = 5, worktree = "/private/tmp/wt", started = 1 } }
	local by = identity.bind(r, { [700] = { cwd = "/tmp/wt" } }, {}, NOW)
	eq(by[700], "a", "worktree match across /private/tmp")
	-- Two panes in the worktree: ambiguous, so it sleeps instead.
	local r2 = { a = { pane = 5, worktree = "/wt", started = 1 } }
	local by2 = identity.bind(r2, { [1] = { cwd = "/wt" }, [2] = { cwd = "/wt" } }, {}, NOW)
	eq(by2[1], nil, "ambiguous not bound")
	eq(r2.a.closed, true, "unbound worktree owner sleeps")
end)

test("a pane running another record's session never goes to a folder match", function()
	local r = {
		a = { pane = 5, worktree = "/wt", started = 1 },
		b = { pane = 6, session_file = "/s/b.jsonl", started = 1 },
	}
	local by = identity.bind(r, { [700] = { cwd = "/wt" } }, { [700] = "/s/b.jsonl" }, NOW)
	eq(by[700], "b", "the session file owner wins")
	eq(r.a.closed, true, "the worktree owner sleeps")
end)

test("omp /new in a pane keeps the record on the pane", function()
	local r = { a = { pane = 5, session_file = "/s/old.jsonl", started = 1 } }
	local by = identity.bind(r, { [5] = { cwd = "/w" } }, { [5] = "/s/new.jsonl" }, NOW)
	eq(by[5], "a", "still bound")
	eq(r.a.session_file, "/s/new.jsonl", "follows the new file")
end)

test("folder match for records without a session file, only when unique", function()
	local r = { a = { pane = 5, cwd = "/f", started = 1 }, b = { pane = 6, cwd = "/g", started = 1 }, c = { pane = 7, cwd = "/g", started = 1 } }
	local by = identity.bind(r, { [50] = { cwd = "/f" }, [60] = { cwd = "/g" } }, {}, NOW)
	eq(by[50], "a", "unique folder bound")
	eq(by[60], nil, "two records want /g: none bound")
end)

test("lost records: young ones wait, old ones are forgotten", function()
	local r = { young = { pane = 5, started = NOW - 3 }, old = { pane = 6, started = 1 } }
	local _, changed = identity.bind(r, {}, {}, NOW)
	check(changed, "lost_at set")
	eq(r.young.lost_at, nil, "young record untouched")
	eq(r.old.lost_at, NOW, "lost since now")
	identity.bind(r, {}, {}, NOW + identity.FORGET_AFTER)
	eq(r.old, nil, "forgotten after FORGET_AFTER")
	-- Coming back before that clears the mark.
	local r2 = { k = { pane = 6, cwd = "/f", started = 1, lost_at = NOW } }
	local by = identity.bind(r2, { [6] = { cwd = "/f" } }, {}, NOW + 10)
	eq(by[6], "k", "back")
	eq(r2.k.lost_at, nil, "mark cleared")
end)

test("a sleeping card wakes when an agent opens in its worktree", function()
	local r = { a = { pane = 5, worktree = "/wt", closed = true, closed_at = 3, started = 1 } }
	local by = identity.bind(r, { [9] = { cwd = "/wt" } }, {}, NOW)
	eq(by[9], "a", "bound")
	eq(r.a.closed, nil, "awake")
end)

t.finish("identity")
