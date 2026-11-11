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
	eq(model.slug("Fix the Login bug!!"), "Fix-the-Login-bug", "slug keeps case, punctuation runs become -")
	eq(model.slug("  "), "agent", "empty slug")
	eq(model.slug("-..a..b--c.-"), "a.b-c", "dot and dash runs collapse, ends stripped")
	eq(model.slug("v1.2_rc"), "v1.2_rc", "dots and underscores kept")
	eq(model.slug("Café déjà vu"), "Café-déjà-vu", "accented letters kept")
	eq(model.slug("修复 登录"), "修复-登录", "CJK kept")
	eq(model.slug("fix 🐛 now — ok"), "fix-now-ok", "emoji and dashes are separators")
	eq(model.slug("\255\254abc"), "abc", "invalid UTF-8 keeps the ASCII")
	eq(utf8.len(model.slug(string.rep("é", 60))), 40, "capped at 40 code points")
	eq(#model.slug(string.rep("abc ", 30)) <= 40, true, "slug capped")
	eq(model.title_of("Investigate why the parser fails on nested quotes"), "Investigate why the parser fails", "title cut at a word")
	eq(model.title_of("one\ntwo"), "one", "title first line")
	eq(model.title_of(""), "agent", "empty title")
	eq(model.title_of(string.rep("é", 40)), string.rep("é", 16), "long word cut on a character")
	eq(model.branch_name("dan", "x"), "dan/x", "prefixed branch")
	eq(model.title_of(string.rep("修", 20)), string.rep("修", 10), "3-byte word cut on a character")
	eq(model.title_of("a" .. string.rep("é", 40)), "a" .. string.rep("é", 15), "odd-offset cut on a character")
	eq(model.title_of(string.rep("🐛", 12)), string.rep("🐛", 8), "4-byte word cut on a character")
	eq(#model.title_of("\255" .. string.rep("x", 40)), 32, "invalid UTF-8 cut at 32 bytes")
	eq(model.branch_name(nil, "x"), "x", "no prefix")
	eq(model.branch_name(" ", "x"), "x", "blank prefix")
end)

test("colors and icons", function()
	eq(model.normalize_color(nil), "neutral", "default neutral")
	eq(model.normalize_color("blue"), "neutral", "legacy blue becomes neutral")
	eq(model.normalize_color("Teal"), "teal", "preset, any case")
	eq(model.normalize_color("#abcdef"), "neutral", "hex unsupported")
	eq(model.normalize_color("magenta"), "neutral", "unknown name")
	eq(model.tab_color({ color = "red" } :: any), "red", "preset tab color")
	eq(model.tab_color({ color = "neutral" } :: any), nil, "neutral: no tab color")
	eq(model.normalize_icon({ kind = "icon", name = "rocket" }).name, "rocket", "known icon")
	eq(model.normalize_icon({ kind = "icon", name = "shapes" }), nil, "icon Tern lacks")
	eq(model.normalize_icon({ kind = "icon", name = "bot" }).name, "agent", "legacy bot icon is agent")
	eq(model.normalize_icon({ kind = "emoji", emoji = " 🚀 " }).emoji, "🚀", "emoji trimmed")
	eq(model.normalize_icon({ kind = "emoji", emoji = "" }), nil, "empty emoji")
	local s = model.empty()
	local a = model.add_project(s, { name = "A", root = "/a" })
	check(model.set_color(s, a.id, "purple") and a.color == "purple", "set_color")
	check(model.set_color(s, a.id, "nope") and a.color == "neutral", "invalid color resets")
	check(not model.set_color(s, "x", "red"), "unknown project")
	check(model.set_icon(s, a.id, { kind = "emoji", emoji = "🐙" }) and a.icon.emoji == "🐙", "set emoji")
	check(not model.set_icon(s, a.id, { kind = "icon", name = "pencil" }), "invalid icon refused")
	eq(a.icon.emoji, "🐙", "refused icon leaves it")
	check(model.set_icon(s, a.id, nil) and a.icon == nil, "reset icon")
end)

test("projects", function()
	local s = model.empty()
	local a = model.add_project(s, { name = "Alpha", root = "/w/alpha/" })
	local b = model.add_project(s, { name = "Alpha sub", root = "/w/alpha/sub", worktrees = false })
	eq(a.id, "alpha", "id is a slug")
	eq(a.root, "/w/alpha", "root trimmed")
	eq(a.color, "neutral", "default color")
	eq(b.color, "neutral", "no cycling")
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
	model.add_group(s, "G", a.id)
	s.agents["5"] = { project = a.id, title = "t", started = 1, worktree = "/x", parent = 3, report_back = true, closed = true, closed_at = 9, interrupted = true }
	model.save(s)
	local l = model.load()
	eq(#l.projects, 1, "projects round-trip")
	eq(l.projects[1].group, "g", "group membership round-trips")
	eq(#l.groups, 1, "groups round-trip")
	eq(l.agents["5"].title, "t", "agents round-trip")
	eq(l.agents["5"].parent, 3, "parent kept")
	eq(l.agents["5"].closed_at, 9, "closed_at kept")
	eq(l.agents["5"].interrupted, true, "interrupted kept")
	local removed, keys = model.remove_project(l, a.id)
	check(removed, "remove")
	eq(#l.projects, 0, "removed")
	eq(l.agents["5"], nil, "its agents removed")
	eq(table.concat(keys, ","), "5", "removed agent keys returned")
	check(not model.remove_project(l, "nope"), "remove unknown")
	local n = model.normalize({
		projects = { { id = 1 }, { id = "x", name = "X", root = "/x", color = "blue", group = "gone" } },
		groups = { { id = "g", name = "G" }, { id = "g", name = "dup" }, "junk" },
		agents = { ["1"] = "junk" },
	})
	eq(#n.projects, 1, "junk projects dropped")
	eq(n.projects[1].color, "neutral", "legacy color normalized on load")
	eq(n.projects[1].group, nil, "dangling group id dropped")
	eq(#n.groups, 1, "junk and duplicate groups dropped")
	eq(next(n.agents), nil, "junk agents dropped")
	eq(#model.normalize(nil).projects, 0, "nil is empty")
end)

test("groups", function()
	local s = model.empty()
	local a = model.add_project(s, { name = "A", root = "/a" })
	local b = model.add_project(s, { name = "B", root = "/b" })
	local g = model.add_group(s, "A group", a.id)
	eq(g.id, "a-group", "lowercase id from the name")
	eq(a.group, g.id, "project moved in")
	local g2 = model.add_group(s, "A group", b.id)
	eq(g2.name, "A group 2", "name made unique")
	check(g2.id ~= g.id, "id unique")
	eq(model.add_group(s, "  ").name, "Untitled group", "blank name falls back")
	check(model.move_to_group(s, b.id, g.id) and b.group == g.id, "move")
	check(not model.move_to_group(s, b.id, g.id), "already there")
	check(not model.move_to_group(s, b.id, "nope"), "unknown group")
	check(model.ungroup(s, b.id) and b.group == nil, "ungroup")
	check(not model.ungroup(s, b.id), "ungroup when in none")
	check(model.rename_group(s, g.id, " Work ") and g.name == "Work", "rename trims")
	check(not pcall(model.rename_group, s, g2.id, "Work"), "taken name refused")
	check(not pcall(model.rename_group, s, g2.id, ""), "blank rename falls back to a taken Untitled group")
	eq(model.group_size(s, g.id), 1, "group size")
	check(model.delete_group(s, g.id), "delete")
	eq(a.group, nil, "members ungrouped")
	eq(#s.projects, 2, "projects stay")
	eq(model.get_group(s, g.id), nil, "group gone")
	check(not model.delete_group(s, g.id), "delete unknown")
	local g3 = model.add_group(s, "X", a.id)
	check(model.delete_group(s, g3.id, true), "delete with projects")
	eq(model.get(s, a.id), nil, "contained project removed")
	eq(#s.projects, 1, "others stay")
end)

test("project order", function()
	local s = model.empty()
	local names = { "p1", "p2", "p3", "p4", "p5" }
	for _, n in names do
		model.add_project(s, { name = n, root = "/" .. n })
	end
	local function ids(list)
		local out = {}
		for _, p in list do
			table.insert(out, p.id)
		end
		return table.concat(out, ",")
	end
	local g = model.add_group(s, "G", "p4")
	model.move_to_group(s, "p1", g.id)
	local h = model.add_group(s, "H")
	eq(ids(model.order_projects(s, "manual", {})), "p4,p1,p2,p3,p5", "groups first, a moved project appended to its group")
	local act = { p5 = 50, p1 = 40, p3 = 30 }
	eq(ids(model.order_projects(s, "recent", act)), "p1,p4,p5,p3,p2", "recent inside each run; groups stay first")
	check(model.rename_project(s, "p1", "  Renamed  ") and model.get(s, "p1").name == "Renamed", "project renamed, id kept")
	check(not pcall(model.rename_project, s, "p1", model.get(s, "p2").name), "rename to a taken name errors")
	check(not pcall(model.rename_project, s, "p1", " "), "blank rename errors")
	check(not model.rename_project(s, "nope", "x"), "rename unknown")
	eq(model.name_conflict(s, "Renamed"), "a project named Renamed exists", "name taken")
	eq(model.name_conflict(s, "Renamed", "p1"), nil, "own name is free")
	model.move_to_group(s, "p5", h.id)
	eq(ids(model.order_projects(s, "manual", {})), "p4,p1,p5,p2,p3", "group order follows the groups")
	check(model.move_project(s, "p1", -1), "move project up in its group")
	eq(ids(model.order_projects(s, "manual", {})), "p1,p4,p5,p2,p3", "swapped inside the group")
	check(not model.move_project(s, "p1", -1), "top of its group")
	check(model.move_project(s, "p3", -1), "ungrouped move skips grouped neighbours")
	eq(ids(model.order_projects(s, "manual", {})), "p1,p4,p5,p3,p2", "swapped among ungrouped")
	check(model.ungroup(s, "p4"), "ungroup")
	eq(ids(model.order_projects(s, "manual", {})), "p1,p5,p3,p2,p4", "ungrouped project goes last")
end)

test("card sort, pin and filter", function()
	local function card(pane, title, o)
		local c = { key = tostring(pane), pane = pane, title = title, state = "idle" }
		for k, v in o or {} do
			c[k] = v
		end
		return c
	end
	local id = function(c)
		return c
	end
	local function order(list)
		local out = {}
		for _, c in list do
			table.insert(out, c.title)
		end
		return table.concat(out, ",")
	end
	local t = 10000
	local cards = {
		card(1, "main", { primary = true, started = 100, last_activity = 100 }),
		card(2, "beta", { started = 200, last_activity = 9000 }),
		card(3, "Alpha", { started = 300, last_activity = 9500, state = "working" }),
		card(4, "gamma", { started = 400, last_activity = 5000, state = "waiting_input" }),
		card(5, "delta", { started = 9900, last_activity = 9900 }),
		card(6, "eps", { started = 50, last_activity = 9990, result = "done", unread = true }),
	}
	local list = table.clone(cards)
	model.sort_cards(list, "recent", t, id)
	eq(order(list), "main,delta,eps,Alpha,beta,gamma", "recent: primary first, create grace lifts the new card")
	model.sort_cards(list, "name", t, id)
	eq(order(list), "Alpha,beta,delta,eps,gamma,main", "name, case-insensitive")
	model.sort_cards(list, "activity", t, id)
	eq(order(list), "gamma,eps,Alpha,delta,beta,main", "activity: needs you, unseen done, working, then recent")
	model.sort_cards(list, "manual", t, id)
	eq(order(list), "eps,main,beta,Alpha,gamma,delta", "manual: creation order")
	local ui = model.empty_ui()
	ui.pinned["2"] = true
	ui.pinned["7"] = true
	table.insert(cards, card(7, "sleepy", { state = "sleeping", started = 1 }))
	table.insert(cards, card(8, "zzz", { state = "sleeping", started = 2 }))
	local pinned, rest = model.arrange(cards, ui, t, id)
	eq(order(pinned), "beta,sleepy", "pinned taken out, sorted")
	eq(#rest, 6, "rest keeps the others")
	eq(model.filter_count(ui), 0, "no filter")
	ui.hide_sleeping = true
	pinned, rest = model.arrange(cards, ui, t, id)
	eq(order(pinned), "beta", "hide sleeping hides a pinned sleeper")
	eq(#rest, 5, "and the others")
	eq(model.filter_count(ui), 1, "filter counted")
end)

test("ui state", function()
	local d = model.normalize_ui(nil)
	eq(d.visible, false, "hidden by default")
	eq(d.want_px, nil, "no width by default")
	eq(d.sort_by, "recent", "recent by default")
	eq(d.group_by, "project", "grouped by default")
	eq(d.show_models, true, "models shown by default")
	eq(d.show_branch, false, "branch hidden by default")
	local u = model.normalize_ui({
		visible = true,
		want_px = 301.6,
		collapsed = { a = true, b = false, [3] = true, pinned = true },
		sort_by = "bogus",
		show_branch = true,
		show_agents = false,
		pinned = { ["4"] = true },
		skip_delete_confirm = true,
	})
	eq(u.visible, true, "visible kept")
	eq(u.want_px, 302, "width rounded")
	eq(u.collapsed.a, true, "collapsed kept")
	eq(u.collapsed.pinned, true, "pinned group collapsed")
	eq(u.collapsed.b, nil, "false dropped")
	eq(u.sort_by, "recent", "bad choice falls back")
	eq(u.show_branch, true, "show_branch kept")
	eq(u.show_agents, false, "show_agents off kept")
	eq(u.pinned["4"], true, "pins kept")
	eq(u.skip_delete_confirm, true, "skip confirm kept")
	eq(model.normalize_ui({ want_px = -3 }).want_px, nil, "bad width dropped")
	model.save_ui(u)
	local l = model.load_ui()
	eq(l.want_px, 302, "ui round-trip")
	eq(l.collapsed.a, true, "collapsed round-trip")
	eq(l.show_branch, true, "show_branch round-trip")
	u.unread["4"] = true
	model.rekey_ui(u, "4", "9")
	check(u.pinned["9"] and u.unread["9"] and not u.pinned["4"] and not u.unread["4"], "rekey moves pin and unread")
end)

test("collapse all", function()
	local u = model.empty_ui()
	u.collapsed.a = true
	model.collapse_all(u, { "a", "b" })
	check(u.collapsed.a and u.collapsed.b, "collapses all when some are open")
	model.collapse_all(u, { "a", "b" })
	check(u.collapsed.a == nil and u.collapsed.b == nil, "expands all when all are collapsed")
	model.collapse_all(u, {})
	eq(next(u.collapsed), nil, "no groups: no change")
end)

t.finish("model")
