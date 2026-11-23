--!nonstrict
-- luau tests/test_bridge.luau

local t = require("./support")
local bridge = require("../bridge")
local mailq = require("../mailq")

local check, eq, test = t.check, t.eq, t.test

local function env(vars)
	return function(name)
		return vars[name]
	end
end

test("~ expands to the host's HOME only at the start", function()
	eq(bridge.expand("~", "/home/u"), "/home/u", "bare ~")
	eq(bridge.expand("~/src/x", "/home/u"), "/home/u/src/x", "~/…")
	eq(bridge.expand("~other/x", "/home/u"), "~other/x", "~user is left")
	eq(bridge.expand("/a/~/b", "/home/u"), "/a/~/b", "inner ~ is left")
	eq(bridge.expand("~/x", nil), "~/x", "no HOME leaves it")
end)

test("the request comes from value, else from act after rpc=", function()
	eq(bridge.request_text({ ev = "action", act = "rpc", value = '{"op":"hello"}' }), '{"op":"hello"}', "value")
	eq(bridge.request_text({ ev = "action", act = 'rpc={"a":"b=c"}' }), '{"a":"b=c"}', "act")
	eq(bridge.request_text({ ev = "action", act = "other" }), nil, "no request")
	eq(bridge.request_text({ ev = "action", act = "rpc", value = 3 }), nil, "non-string value")
	eq(bridge.request_text(nil), nil, "nil event")
end)

test("validate checks each op's fields and keeps a usable id", function()
	local function code(req)
		local c, _, id = bridge.validate(req)
		return c, id
	end
	eq(code(nil), "bad-request", "not a table")
	eq(code({ op = "hello" }), "bad-request", "hello needs win")
	eq(code({ op = "hello", win = "w" }), nil, "hello without id")
	local c, id = code({ op = "git", win = "w" })
	eq(c, "bad-request", "id required past hello")
	eq(id, nil, "no id")
	c, id = code({ op = "nope", id = "1", win = "w" })
	eq(c, "bad-request", "unknown op")
	eq(id, "1", "unknown op keeps the id for the reply")
	eq(code({ op = "git", id = string.rep("x", 201), win = "w", args = { "status" } }), "bad-request", "long id")
	eq(code({ op = "git", id = "1", win = "w", args = {} }), "bad-request", "empty args")
	eq(code({ op = "git", id = "1", win = "w", args = { "log", 3 } }), "bad-request", "non-string arg")
	eq(code({ op = "git", id = "1", win = "w", args = { "status" }, cwd = "" }), "bad-request", "empty cwd")
	eq(code({ op = "git", id = "1", win = "w", args = { "status" }, timeout_ms = -1 }), "bad-request", "bad timeout")
	eq(code({ op = "git", id = "1", win = "w", args = { "status" }, cwd = "~/x", timeout_ms = 500 }), nil, "git ok")
	eq(code({ op = "fs", id = "1", win = "w", fn = "rm", path = "/" }), "bad-request", "unknown fs fn")
	eq(code({ op = "fs", id = "1", win = "w", fn = "dirs" }), "bad-request", "dirs needs path")
	eq(code({ op = "fs", id = "1", win = "w", fn = "home" }), nil, "home needs no path")
	eq(code({ op = "spool", id = "1", win = "w", obj = {} }), "bad-request", "spool obj needs op")
	eq(code({ op = "spool", id = "1", win = "w", obj = { op = "ack" } }), nil, "spool ok")
	eq(code({ op = "sync", id = "1", win = "w" }), "bad-request", "sync needs projects")
	eq(code({ op = "sync", id = "1", win = "w", projects = {}, worktrees = {} }), nil, "sync ok")
end)

test("git timeouts default and are capped", function()
	eq(bridge.git_timeout(nil), bridge.GIT_TIMEOUT_MS, "default")
	eq(bridge.git_timeout(500), 500, "given")
	eq(bridge.git_timeout(10 ^ 9), bridge.GIT_TIMEOUT_MAX_MS, "capped")
end)

test("replies cap output at whole UTF-8 characters", function()
	eq(bridge.cap("abc", 5), "abc", "short kept")
	eq(bridge.cap("abcdef", 4), "abcd", "ascii cut")
	-- "é" is 2 bytes: cutting at 2 would split it.
	eq(bridge.cap("aéb", 2), "a", "no half character")
	eq(bridge.cap("aéb", 3), "aé", "whole character kept")
	local r = bridge.git_reply({ status = 0, stdout = string.rep("x", bridge.CAP + 10), stderr = "e", timed_out = false })
	eq(#r.stdout, bridge.CAP, "stdout capped at 64 KiB")
	eq(r.stderr, "e", "stderr")
	check(r.ok == true and r.status == 0 and r.timed_out == false, "reply fields")
end)

test("dir_names keeps visible subfolders, sorted", function()
	local names = bridge.dir_names("/r/zeta\n/r/.git\n/r/alpha\n/r/mid dle\n")
	eq(#names, 3, "hidden dropped")
	eq(names[1], "alpha", "sorted 1")
	eq(names[2], "mid dle", "spaces kept")
	eq(names[3], "zeta", "sorted 3")
	eq(#bridge.dir_names(""), 0, "empty")
end)

test("the leader is the live window that said hello first", function()
	local wins = {}
	local seq = 0
	eq(bridge.leader(wins, 0), nil, "nobody")
	seq = bridge.hello(wins, "b", 100, seq)
	seq = bridge.hello(wins, "a", 101, seq)
	eq(bridge.leader(wins, 101), "b", "first hello leads")
	seq = bridge.hello(wins, "b", 110, seq)
	seq = bridge.hello(wins, "a", 112, seq)
	eq(bridge.leader(wins, 112), "b", "repeat hellos keep the order")
	-- b goes silent: past 15 s it no longer leads.
	seq = bridge.hello(wins, "a", 126, seq)
	eq(bridge.leader(wins, 126), "a", "silent leader replaced")
	check(bridge.prune_wins(wins, 126), "silent window forgotten")
	eq(wins.b, nil, "b gone")
	-- b back: it queues behind a.
	seq = bridge.hello(wins, "b", 127, seq)
	eq(bridge.leader(wins, 127), "a", "returning window does not take over")
	check(not bridge.prune_wins(wins, 127), "nothing to prune")
end)

test("spool ids are applied once within 10 minutes", function()
	local seen = {}
	check(not bridge.seen(seen, "x", 0), "first time")
	check(bridge.seen(seen, "x", 100), "repeat")
	check(not bridge.seen(seen, "x", 100 + bridge.SEEN_S + 1), "remembered no longer")
	bridge.prune_seen(seen, 100 + 3 * bridge.SEEN_S)
	eq(seen.x, nil, "pruned")
end)

test("replies stay 120 s", function()
	local replies = {}
	bridge.put_reply(replies, "1", { ok = true }, 0)
	bridge.put_reply(replies, "2", { ok = false, error = "x" }, 100)
	local doc = bridge.replies_doc(replies)
	check(doc["1"].ok == true and doc["2"].error == "x", "doc is id → reply")
	check(not bridge.prune_replies(replies, 120), "120 s still kept")
	check(bridge.prune_replies(replies, 121), "121 s dropped")
	eq(replies["1"], nil, "old gone")
	check(replies["2"] ~= nil, "newer kept")
end)

test("sigs move only when a node's text changes; the header lists them", function()
	local s = bridge.sigs("run")
	check(bridge.track(s, "status", "a"), "first text")
	check(not bridge.track(s, "status", "a"), "same text")
	check(bridge.track(s, "status", "b"), "new text")
	eq(bridge.sig(s, "status"), "run.2", "status sig")
	eq(bridge.sig(s, "gh"), "run.0", "untouched sig")
	local NULL = {}
	local h = bridge.header(s, { host = "rig", home = nil, os = "linux", pane = 7, at = 5, leader = nil, null = NULL })
	eq(h.v, 1, "version")
	eq(h.host, "rig", "host")
	eq(h.home, NULL, "missing home is null")
	eq(h.leader, NULL, "no leader is null")
	eq(h.pane, 7, "pane")
	eq(h.sig.status, "run.2", "header sig")
	for _, name in { "status", "fleet", "gh", "autos", "mail", "replies" } do
		check(h.sig[name] ~= nil, "sig " .. name)
	end
	eq(h.sig.header, nil, "no sig of itself")
	eq(#bridge.NODES, 7, "seven nodes")
	eq(bridge.NODES[1], "header", "main.0")
	eq(bridge.NODES[7], "replies", "main.6")
end)

test("mail_doc keeps only queued messages and reads back with normalize", function()
	local box = mailq.empty()
	local yes = function()
		return true
	end
	mailq.submit(box, { op = "deliver", id = "a", target = { pane = 3 }, text = "hi", from = "f" }, 1, yes)
	mailq.submit(box, { op = "deliver", id = "b", target = { pane = 4 }, text = "yo", from = "f" }, 1, yes)
	box.msgs[1].state = "delivered"
	local doc = bridge.mail_doc(box)
	eq(#doc.msgs, 1, "one queued")
	eq(doc.msgs[1].id, "b", "the queued one")
	local back = mailq.normalize(doc)
	eq(#back.msgs, 1, "normalize reads it")
	eq(back.msgs[1].target.pane, 4, "target kept")
	eq(back.seq, box.seq, "seq kept")
end)

test("payload text is chunked at whole UTF-8 characters; the header counts the parts", function()
	local c = bridge.chunks("")
	eq(#c, 1, "empty is one part")
	eq(c[1], "", "empty part")
	c = bridge.chunks("abcdefg", 3)
	eq(#c, 3, "ascii parts")
	eq(table.concat(c), "abcdefg", "ascii rejoined")
	eq(c[3], "g", "last part")
	-- "é" is 2 bytes and must not straddle a cut.
	c = bridge.chunks("aéééb", 2)
	eq(table.concat(c), "aéééb", "utf-8 rejoined")
	for i, piece in c do
		check(#piece <= 2, "part " .. i .. " within size")
		check(utf8.len(piece) ~= nil, "part " .. i .. " is whole characters")
	end
	local big = string.rep("é", 40000)
	c = bridge.chunks(big)
	eq(#c, 3, "80000 bytes in three parts")
	eq(#c[1], bridge.CHUNK, "full part")
	eq(table.concat(c), big, "big rejoined")
	local s = bridge.sigs("r")
	bridge.track(s, "gh", big)
	bridge.track(s, "mail", "")
	local h = bridge.header(s, { host = "h", os = "linux", pane = 1, at = 0, null = {} })
	eq(h.parts.gh, 3, "gh parts")
	eq(h.parts.mail, 1, "empty mail is one part")
	eq(h.parts.status, 1, "untracked node is one part")
	eq(h.parts.header, nil, "no parts of itself")
end)

test("sync_of cleans the list and union keeps local projects first", function()
	local s = bridge.sync_of({
		projects = { { id = "p1", name = "One", root = "~/one" }, { id = "", root = "/x" }, "bad", { id = "p2", root = "/two" } },
		worktrees = { "~/wt", "", 3 },
		visible = true,
	}, "/home/u", 9)
	eq(#s.projects, 2, "bad projects dropped")
	eq(s.projects[1].root, "/home/u/one", "root expanded")
	eq(s.projects[2].name, "p2", "name defaults to id")
	eq(#s.worktrees, 1, "bad worktrees dropped")
	eq(s.worktrees[1], "/home/u/wt", "worktree expanded")
	eq(s.visible, true, "visible")
	eq(s.at, 9, "at")
	eq(bridge.sync_of(nil, nil, 3).visible, false, "nil is empty")
	local u = bridge.union_projects({ { id = "p1", name = "Local", root = "/l" } }, s)
	eq(#u, 2, "union size")
	eq(u[1].name, "Local", "local wins")
	eq(u[2].id, "p2", "synced added")
	eq(#bridge.union_projects({}, nil), 0, "no sync")
end)

test("tern_cli tries TERN_EXE, the app, the Linux installs, then PATH", function()
	local function exists_of(set)
		return function(p)
			return set[p] == true
		end
	end
	eq(bridge.tern_cli(env({ TERN_EXE = "/x/tern", HOME = "/h" }), exists_of({})), "/x/tern", "TERN_EXE")
	eq(bridge.tern_cli(env({ HOME = "/h" }), exists_of({ ["/Applications/Tern.app/Contents/MacOS/tern"] = true, ["/h/.local/bin/tern"] = true })), "/Applications/Tern.app/Contents/MacOS/tern", "app first")
	eq(bridge.tern_cli(env({ HOME = "/h" }), exists_of({ ["/h/.local/bin/tern"] = true, ["/h/.local/share/tern/build/tern"] = true })), "/h/.local/bin/tern", "~/.local/bin")
	eq(bridge.tern_cli(env({ HOME = "/h" }), exists_of({ ["/h/.local/share/tern/build/tern"] = true })), "/h/.local/share/tern/build/tern", "build")
	eq(bridge.tern_cli(env({ HOME = "/h" }), exists_of({})), "tern", "PATH")
end)

test("the discovery path follows tern_fleet.py's config dir rule", function()
	eq(bridge.config_dir(env({ TERN_CONFIG_DIR = "/c", HOME = "/h" }), "linux"), "/c", "TERN_CONFIG_DIR")
	eq(bridge.config_dir(env({ HOME = "/h" }), "macos"), "/h/Library/Application Support/Tern", "macOS")
	eq(bridge.config_dir(env({ HOME = "/h", XDG_CONFIG_HOME = "/x" }), "linux"), "/x/tern", "XDG")
	eq(bridge.config_dir(env({ HOME = "/h" }), "linux"), "/h/.config/tern", "~/.config")
	eq(bridge.config_dir(env({}), "linux"), nil, "no HOME")
	local data = "/h/.local/state/tern/plugin-data/projects"
	eq(bridge.discovery_path(env({ HOME = "/h" }), "linux", "projects", data), "/h/.config/tern/plugin-data/projects/mailbox.json", "rig")
	local mac = "/h/Library/Application Support/Tern/plugin-data/projects"
	eq(bridge.discovery_path(env({ HOME = "/h" }), "macos", "projects", mac), nil, "same as the data dir's")
end)

t.finish("bridge")
