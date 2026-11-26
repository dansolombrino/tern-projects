--!nonstrict
-- luau tests/test_remote.luau

local t = require("./support")
local json = require("./support_json")
local rp = require("../remotepure")

local check, eq, test = t.check, t.eq, t.test

-- Measured on the rig: base 0x10100000000000, host pane hi·2^32 + lo.
local BASE = 0x10100000000000
local P32 = 4294967296

test("pane ids map host → window and back", function()
	local h = 3 * P32 + 17
	local w = rp.to_window(BASE, h)
	eq(w, BASE + 3 * 16777216 + 17, "window id")
	eq(rp.to_host(BASE, w), h, "inverse")
	eq(rp.base_of(w, h), BASE, "base from one known pane")
	eq(rp.to_window(BASE, 5), BASE + 5, "hi = 0")
end)

test("verify: bridge and status panes", function()
	local bh = 2 * P32 + 9
	local bw = rp.to_window(BASE, bh)
	local s1, s2 = 2 * P32 + 10, 4 * P32 + 1
	local panes = { [bw] = true, [rp.to_window(BASE, s1)] = true, [rp.to_window(BASE, s2)] = true }
	local base = rp.base_of(bw, bh)
	check(rp.verify(base, bw, bh, panes, { s1, s2 }), "all map")
	check(rp.verify(base, bw, bh, panes, nil), "no status yet: the bridge alone")
	check(rp.verify(base, bw, bh, panes, { s1, s2, 7 * P32 }), "2 of 3 map")
	local ok, why = rp.verify(base, bw, bh, panes, { 7 * P32, 8 * P32, s1 })
	check(not ok and why ~= nil, "1 of 3 fails")
	ok, why = rp.verify(base, bw, bh, { [rp.to_window(BASE, s1)] = true }, nil)
	check(not ok and string.find(why, "bridge") ~= nil, "bridge not among the host's panes")
	ok = rp.verify(base + 1, bw, bh, panes, nil)
	check(not ok, "a wrong base fails")
end)

test("status_panes reads keys", function()
	local p = rp.status_panes({ panes = { ["5"] = {}, ["4294967297"] = {}, x = {} } })
	eq(#p, 2, "numeric keys only")
	eq(p[1], 5, "sorted")
	eq(#rp.status_panes(nil), 0, "nil status")
end)

test("node_text: spans of the node, wherever it is", function()
	local node = { id = "main.0", k = "text", p = { spans = { { t = '{"v":' }, { t = "1}" } } } }
	eq(rp.node_text(node, "main.0"), '{"v":1}', "node itself")
	local tree = { surface = { id = "s", mode = "screen" }, main = { id = "main", k = "col", c = { { id = "main.1", k = "text", p = { spans = { { t = "a" } } } }, node } } }
	eq(rp.node_text(tree, "main.0"), '{"v":1}', "inside a SurfaceTree")
	eq(rp.node_text(tree, "main.1"), "a", "sibling")
	eq(rp.node_text(tree, "main.6"), nil, "absent")
	eq(rp.node_text(nil, "main.0"), nil, "no tree")
	eq(rp.node_text("error text", "main.0"), nil, "string reply")
	eq(rp.node_text({ id = "main.2", k = "text", p = { spans = {} } }, "main.2"), "", "empty node")
end)

test("changed: header signatures", function()
	local new = { status = 1, gh = 3, autos = 4, mail = 5, replies = 6 }
	local all = rp.changed(nil, new)
	eq(#all, 5, "first read: every node")
	eq(all[1], "status", "view order")
	eq(all[5], "replies", "replies last")
	local some = rp.changed({ status = 1, gh = 2, autos = 4, mail = 5, replies = 6 }, new)
	eq(#some, 1, "one changed")
	eq(some[1], "gh", "gh")
	eq(#rp.changed(new, new), 0, "same")
	eq(#rp.changed({ status = "1" }, { status = 1 }), 0, "number vs its text is the same signature")
	eq(#rp.changed(new, nil), 0, "no sig table")
	eq(rp.INDEX.replies, 5, "replies is main.5")
end)

test("merge: a remote status into sessions, repos, queued", function()
	local h1, h2 = 1 * P32 + 2, 1 * P32 + 3
	local status = json.decode(string.format([[{"panes":{"%d":{"session_file":"/r/a.jsonl"},"%d":{"session_file":"/r/b.jsonl"},"99":{}},"repos":{"/home/u/x":{"branch":"main"},"/shared":{"branch":"remote"}},"queued":3}]], h1, h2))
	local sessions = { [7] = "/l/local.jsonl" }
	local repos = { ["/shared"] = { branch = "local" } }
	local panes = { [rp.to_window(BASE, h1)] = true }
	local q = rp.merge(status, function(h)
		local w = rp.to_window(BASE, h)
		return if panes[w] then w else nil
	end, sessions, repos)
	eq(q, 3, "queued")
	eq(sessions[rp.to_window(BASE, h1)], "/r/a.jsonl", "mapped pane")
	eq(sessions[rp.to_window(BASE, h2)], nil, "unmapped pane left out")
	eq(sessions[7], "/l/local.jsonl", "local kept")
	eq(repos["/home/u/x"].branch, "main", "remote folder added")
	eq(repos["/shared"].branch, "local", "this machine's entry wins")
	eq(rp.merge(nil, function() return nil end, sessions, repos), 0, "no status")
end)

test("sync body and ids", function()
	local projects = { { id = "a", name = "A", root = "/r/a", host = "u@rig" }, { id = "b", name = "B", root = "/l/b" } }
	local agents = { k1 = { project = "a", worktree = "/r/wt1" }, k2 = { project = "a", worktree = "/r/wt1" }, k3 = { project = "b", worktree = "/l/wt" } }
	local body = rp.sync_body(projects, agents, "u@rig", true)
	eq(body.op, "sync", "op")
	eq(#body.projects, 1, "only that host's projects")
	eq(body.projects[1].root, "/r/a", "root")
	eq(#body.worktrees, 1, "worktrees deduped, other hosts' left out")
	eq(body.visible, true, "visible")
	eq(rp.join_id("u@rig", "x"), "u@rig|x", "join")
	local h, id = rp.split_id("u@rig|x")
	eq(h, "u@rig", "split host")
	eq(id, "x", "split id")
	h, id = rp.split_id("nightly")
	eq(h, nil, "local id has no host")
	eq(id, "nightly", "local id")
	eq(rp.join_id(nil, "x"), "x", "local join")
end)

test("chunks: assembly in order, restart on a new version", function()
	local header = { sig = { gh = "s1", replies = 7 }, parts = { gh = 3, replies = 0 } }
	local a = rp.asm_new("gh", header)
	check(a ~= nil, "assembly from the header")
	eq(rp.asm_next(a), "main.2.0", "first chunk id")
	rp.asm_add(a, '{"prs":')
	eq(rp.asm_text(a), nil, "not complete")
	eq(rp.asm_next(a), "main.2.1", "second chunk id")
	rp.asm_add(a, '[{"key":"k"}')
	rp.asm_add(a, "]}")
	eq(rp.asm_next(a), nil, "all in")
	local doc = json.decode(rp.asm_text(a))
	eq(doc.prs[1].key, "k", "chunks concatenated in order decode")
	check(not rp.asm_stale(a, header), "same header: not stale")
	check(rp.asm_stale(a, { sig = { gh = "s2" }, parts = { gh = 3 } }), "new signature: stale")
	check(rp.asm_stale(a, { sig = { gh = "s1" }, parts = { gh = 4 } }), "new chunk count: stale")
	check(rp.asm_stale(a, { sig = { gh = "s1" } }), "no counts: stale")
	-- Restart: a new assembly from the newer header reads from chunk 0 again.
	local b = rp.asm_new("gh", { sig = { gh = "s2" }, parts = { gh = 1 } })
	eq(rp.asm_next(b), "main.2.0", "restart reads chunk 0")
	rp.asm_add(b, "[]")
	eq(json.decode(rp.asm_text(b))[1], nil, "an empty part may be []")
	local r = rp.asm_new("replies", header)
	eq(r.sig, "7", "numeric signature kept as text")
	eq(rp.asm_next(r), nil, "no chunks: complete at once")
	eq(rp.asm_text(r), "", "empty text")
	eq(rp.asm_new("autos", header), nil, "part missing from the header")
	eq(rp.asm_new("gh", { sig = { gh = "x" } }), nil, "header without parts")
	eq(rp.chunk_id("replies", 4), "main.5.4", "replies chunk id")
end)

t.finish("remote")
