--!nonstrict
-- luau tests/test_mailq.luau

local t = require("./support")
local mailq = require("../mailq")
local identity = require("../identity")

local check, eq, test = t.check, t.eq, t.test

local function yes()
	return true
end
local function no()
	return false
end

local function req(id, target, text)
	return { op = "deliver", id = id, target = target, text = text or "hello", from = "agent-fleet g/item" }
end

test("deliver validates, stores once per id, and refuses unmatched targets", function()
	local box = mailq.empty()
	local r, c = mailq.submit(box, req("", { pane = 1 }), 1, yes)
	eq(r.error, "bad-request", "empty id")
	check(not c, "nothing stored")
	eq(mailq.submit(box, req("x", { cwd = "rel" }), 1, yes).error, "bad-request", "relative cwd")
	eq(mailq.submit(box, req("x", {}), 1, yes).error, "bad-request", "empty target")
	eq(mailq.submit(box, req("x", { pane = 1 }, "   "), 1, yes).error, "bad-request", "blank text")
	eq(mailq.submit(box, req("x", { pane = 1.5 }), 1, yes).error, "bad-request", "fractional pane")
	r, c = mailq.submit(box, req("x", { pane = 1 }), 1, no)
	eq(r.error, "no-target", "unmatched target")
	check(not c and #box.msgs == 0, "not stored")
	r, c = mailq.submit(box, req("x", { pane = 1, session_file = "/s.jsonl" }), 1, yes)
	check(r.ok and r.state == "queued" and c, "queued")
	r, c = mailq.submit(box, req("x", { pane = 2 }, "other"), 2, yes)
	check(r.ok and r.state == "queued" and not c, "same id again: the first stands")
	eq(#box.msgs, 1, "one message")
end)

test("status answers for known and unknown ids; acks finish messages once", function()
	local box = mailq.empty()
	mailq.submit(box, req("m1", { pane = 1 }), 1, yes)
	eq(mailq.status(box, { id = "m1" }).state, "queued", "queued")
	eq(mailq.status(box, { id = "nope" }).state, "unknown", "unknown")
	check(mailq.apply(box, { id = "m1", state = "delivered", pane = 1 }, 5), "applied")
	local s = mailq.status(box, { id = "m1" })
	eq(s.state, "delivered", "delivered")
	eq(box.msgs[1].text, "", "text dropped once delivered")
	check(not mailq.apply(box, { id = "m1", state = "failed", error = "x" }, 6), "a finished message stays")
	local r = mailq.submit(box, req("m1", { pane = 1 }), 7, yes)
	eq(r.state, "delivered", "a delivered id is never queued again")
end)

test("backpressure", function()
	local box = mailq.empty()
	for i = 1, mailq.MAX_PER_TARGET do
		mailq.submit(box, req("a" .. i, { pane = 1 }), 1, yes)
	end
	eq(mailq.submit(box, req("over", { pane = 1 }), 1, yes).error, "busy", "per-target cap")
	check(mailq.submit(box, req("other", { pane = 2 }), 1, yes).ok, "another target is fine")
end)

test("resolve: pane, then session file, then the single agent in the folder", function()
	local agents = {
		{ pane = 10, cwd = "/private/tmp/a", state = "idle" },
		{ pane = 11, cwd = "/b", state = "idle" },
		{ pane = 12, cwd = "/b", state = "working" },
	}
	local sessions = { [11] = "/s/11.jsonl" }
	local canon = identity.canon
	eq(mailq.resolve({ pane = 10 }, agents, sessions, canon), 10, "live pane")
	eq(mailq.resolve({ pane = 99, session_file = "/s/11.jsonl" }, agents, sessions, canon), 11, "restarted: session file")
	eq(mailq.resolve({ pane = 99, cwd = "/tmp/a" }, agents, sessions, canon), 10, "single agent in folder")
	eq(mailq.resolve({ cwd = "/b" }, agents, sessions, canon), nil, "two agents in folder: ambiguous")
	eq(mailq.resolve({ pane = 99 }, agents, sessions, canon), nil, "nothing")
end)

test("deliverable: FIFO per pane, idle or waiting only, holds respected", function()
	local box = mailq.empty()
	mailq.submit(box, req("1", { pane = 10 }, "first"), 1, yes)
	mailq.submit(box, req("2", { pane = 10 }, "second"), 2, yes)
	mailq.submit(box, req("3", { pane = 11 }, "busy one"), 3, yes)
	mailq.submit(box, req("4", { pane = 12 }, "held"), 4, yes)
	local agents = {
		{ pane = 10, cwd = "/a", state = "idle" },
		{ pane = 11, cwd = "/b", state = "working" },
		{ pane = 12, cwd = "/c", state = "waiting_input" },
	}
	local out = mailq.deliverable(box, agents, {}, identity.canon, { [12] = true })
	eq(#out, 1, "one deliverable")
	eq(out[1].msg.id, "1", "oldest first")
	mailq.apply(box, { id = "1", state = "delivered", pane = 10 }, 5)
	out = mailq.deliverable(box, agents, {}, identity.canon, {})
	eq(#out, 2, "pane 10's next and pane 12")
	eq(out[1].msg.id, "2", "then the second")
	eq(out[2].msg.id, "4", "waiting_input counts as deliverable")
end)

test("prune keeps queued, drops old finished, expires stale", function()
	local box = mailq.empty()
	mailq.submit(box, req("old", { pane = 1 }), 0, yes)
	mailq.submit(box, req("done", { pane = 1 }), 0, yes)
	mailq.apply(box, { id = "done", state = "delivered" }, 0)
	check(mailq.prune(box, mailq.KEEP), "pruned")
	eq(mailq.find(box, "done"), nil, "old delivered dropped")
	eq(mailq.find(box, "old").state, "failed", "stale queued expired")
	eq(mailq.find(box, "old").error, "expired", "expired error")
end)

test("normalize round-trips and repairs", function()
	local box = mailq.empty()
	mailq.submit(box, req("a", { pane = 3, cwd = "/x" }), 1, yes)
	local again = mailq.normalize(mailq.encode(box, function(x)
		return x
	end))
	eq(again.seq, 1, "seq")
	eq(again.msgs[1].target.cwd, "/x", "target")
	eq(#mailq.normalize({ msgs = { "junk", { id = "x" } } }).msgs, 0, "junk dropped")
end)

t.finish("mailq")
