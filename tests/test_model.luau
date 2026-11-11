--!nonstrict
-- luau tests/test_model.luau

local t = require("./support")
local model = require("../model")

local check, eq, test = t.check, t.eq, t.test

-- load/save use the `tern` global: give the module an in-memory kv.
local store = {}
getfenv(model.save).tern = {
	kv = {
		get = function(k)
			return store[k]
		end,
		set = function(k, v)
			store[k] = v
		end,
	},
	log = { warn = function() end },
	json = {
		array = function(x)
			return x
		end,
	},
}

test("paths", function()
	eq(model.trim("/a/b/"), "/a/b", "trim")
	eq(model.trim("/"), "/", "trim root")
	eq(model.basename("/tmp/a/"), "a", "basename")
	eq(model.dirname("/tmp/a"), "/tmp", "dirname")
	eq(model.dirname("/a"), "/", "dirname of top")
	eq(model.canon("/private/tmp/x"), "/tmp/x", "canon /private/tmp")
	eq(model.canon("/private/home"), "/private/home", "canon leaves others")
	check(model.inside("/tmp/a/b", "/tmp/a"), "inside")
	check(model.inside("/private/tmp/a/b", "/tmp/a"), "inside across /private")
	check(not model.inside("/tmp/ab", "/tmp/a"), "prefix is not inside")
	eq(model.resolve("/r/s/t", "../.."), "/r", "resolve ..")
	eq(model.resolve("/r", "~/x", "/home/u"), "/home/u/x", "resolve ~")
	eq(model.resolve("/r", "/a/./b/../c"), "/a/c", "resolve absolute")
end)

test("slug and title", function()
	eq(model.slug("Fix the Login bug!!"), "fix-the-login-bug", "slug")
	eq(model.slug("  "), "agent", "empty slug")
	eq(#model.slug(string.rep("abc ", 30)) <= 40, true, "slug capped")
	eq(model.title_of("Investigate why the parser fails on nested quotes"), "Investigate why the parser fails", "title cut at a word")
	eq(model.title_of("one\ntwo"), "one", "title first line")
	eq(model.title_of(""), "agent", "empty title")
end)

test("projects", function()
	local s = model.empty()
	local a = model.add_project(s, { name = "Alpha", root = "/w/alpha/" })
	local b = model.add_project(s, { name = "Alpha sub", root = "/w/alpha/sub", worktrees = false })
	eq(a.id, "alpha", "id is a slug")
	eq(a.root, "/w/alpha", "root trimmed")
	eq(a.color, "blue", "first color")
	eq(b.color, "green", "second color")
	eq(b.worktrees, false, "worktrees off")
	eq(model.worktree_path(a, "x"), "/w/.tern-worktrees/alpha/x", "worktree path beside the root")
	eq(model.project_for_path(s, "/w/alpha/src"), a, "inside root")
	eq(model.project_for_path(s, "/w/alpha/sub/x"), b, "longest root wins")
	eq(model.project_for_path(s, "/w/.tern-worktrees/alpha/x/y"), a, "inside a worktree")
	eq(model.project_for_path(s, "/w/alphabet"), nil, "no prefix match")
	eq(model.project_for_path(s, ""), nil, "unknown cwd")
	check(not pcall(model.add_project, s, { name = "Alpha", root = "/z" }), "duplicate name refused")
	check(not pcall(model.add_project, s, { name = "Z", root = "/w/alpha" }), "duplicate root refused")
	check(not pcall(model.add_project, s, { name = "Z", root = "rel" }), "relative root refused")
	local c = model.add_project(s, { name = "alpha!", root = "/w/c" })
	eq(c.id, "alpha-2", "id made unique")
end)

test("persistence", function()
	local s = model.empty()
	local a = model.add_project(s, { name = "A", root = "/a" })
	s.agents["5"] = { project = a.id, title = "t", started = 1, worktree = "/x", parent = 3, report_back = true }
	model.save(s)
	local l = model.load()
	eq(#l.projects, 1, "projects round-trip")
	eq(l.agents["5"].title, "t", "agents round-trip")
	eq(l.agents["5"].parent, 3, "parent kept")
	check(model.remove_project(l, a.id), "remove")
	eq(#l.projects, 0, "removed")
	eq(l.agents["5"], nil, "its agents removed")
	check(not model.remove_project(l, "nope"), "remove unknown")
	local n = model.normalize({ projects = { { id = 1 }, { id = "x", name = "X", root = "/x" } }, agents = { ["1"] = "junk" } })
	eq(#n.projects, 1, "junk projects dropped")
	eq(next(n.agents), nil, "junk agents dropped")
	eq(#model.normalize(nil).projects, 0, "nil is empty")
end)

t.finish("model")
