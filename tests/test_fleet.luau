--!nonstrict
-- luau tests/test_fleet.luau: the agent-fleet state parser (fleet.luau) and the fleet section of the sidebar.

local t = require("./support")
local json = require("./support_json")
local fleet = require("../fleet")
local sidebar = require("../sidebar")

local check, eq, test = t.check, t.eq, t.test

local ROOT = "/st"
local T = ROOT .. "/.tern"

-- A fake file tree: path → text (files) and the directory listings derived from it.
local function tree(files)
	local io = { files = files, reads = 0 }
	function io.list(path)
		local seen, out = {}, {}
		local prefix = path .. "/"
		for p in io.files do
			if string.sub(p, 1, #prefix) == prefix then
				local name = string.match(string.sub(p, #prefix + 1), "^[^/]+")
				if name and not seen[name] then
					seen[name] = true
					table.insert(out, name)
				end
			end
		end
		if #out == 0 then
			return nil
		end
		return out
	end
	function io.read(path)
		io.reads += 1
		return io.files[path]
	end
	io.decode = json.decode
	return io
end

local function enc(v): string
	-- A tiny encoder for the fixtures (objects, arrays of scalars, strings, numbers, booleans).
	local function go(x): string
		local ty = type(x)
		if ty == "string" then
			return string.format("%q", x)
		elseif ty == "number" or ty == "boolean" then
			return tostring(x)
		elseif ty == "table" then
			if #x > 0 then
				local parts = {}
				for _, v in x do
					table.insert(parts, go(v))
				end
				return "[" .. table.concat(parts, ",") .. "]"
			end
			local keys = {}
			for k in x do
				table.insert(keys, k)
			end
			table.sort(keys)
			local parts = {}
			for _, k in keys do
				table.insert(parts, string.format("%q", k) .. ":" .. go(x[k]))
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		return "null"
	end
	return go(v)
end

local function chat(extra)
	local s = {
		version = 2,
		kind = "chat",
		adapter = "tern",
		repo_id = "repo-1234abcd",
		main_root = "/r/repo",
		chat_key = "s-abc",
		pane = 100,
		fleet = "tf",
		groups = {
			ga = {
				container_path = "/r/.tern-worktrees/repo/ga",
				branch = "ga",
				created_at = "2026-11-19T16:00:00+00:00",
				session = { id = 7, name = "G ga · tf" },
				items = {
					w1 = {
						worktree = "/r/.tern-worktrees/repo/ga-w1",
						branch = "ga-w1",
						block = 101,
						status = "waiting",
						last_report = { kind = "ask", text = "which file?\nmore", at = "2026-11-19T16:10:00+00:00", delivery = "mailbox", mailbox_state = "queued", id = "m1" },
					},
					w2 = {
						worktree = "/r/.tern-worktrees/repo/ga-w2",
						branch = "ga-w2",
						block = 102,
						status = "reported",
						last_report = { kind = "done", text = "all done", at = "2026-11-19T16:20:00Z" },
					},
					w3 = { worktree = "/r/.tern-worktrees/repo/ga-w3", status = "removed", block = 103 },
				},
			},
			gb = {
				container_path = "/r/.tern-worktrees/repo/gb",
				branch = "gb",
				created_at = "2026-11-19T17:00:00+00:00",
				session = { id = 99, name = "G gb · tf" },
				items = {
					x = { worktree = "/r/.tern-worktrees/repo/gb-x", status = "starting" },
				},
			},
		},
	}
	for k, v in extra or {} do
		s[k] = v
	end
	return s
end

local function legacy()
	return {
		group = "old",
		repo_id = "repo-1234abcd",
		main_root = "/r/repo",
		worktree_path = "/r/.tern-worktrees/repo/l0-old",
		branch = "l0-old",
		session = "l0-old",
		coordinator_pane = 200,
		items = { a = { worktree = "/r/.tern-worktrees/repo/old-a", block = 201, status = "started" } },
	}
end

local function live()
	return {
		panes = {
			[100] = { cwd = "/r/repo", working = false },
			[101] = { cwd = "/r/.tern-worktrees/repo/ga-w1", working = false },
			[102] = { cwd = "/r/.tern-worktrees/repo/ga-w2/sub", working = false },
			[200] = { cwd = "/r/.tern-worktrees/repo/l0-old", working = true },
			[201] = { cwd = "/somewhere/else", working = false },
		},
		sessions = {
			{ id = 7, name = "G ga · tf", panes = { [101] = true, [102] = true, [100] = true } },
			{ id = 8, name = "l0-old", panes = { [200] = true } },
		},
		mail = { by_id = { m1 = "delivered" }, queued = { [100] = 2 } },
	}
end

local function files()
	return {
		[T .. "/repo-1234abcd/chats/s-abc/state.json"] = enc(chat()),
		[T .. "/repo-1234abcd/chats/s-abc/groups/ga/brief.md"] = "brief",
		[T .. "/repo-1234abcd/chats/s-old/state.json"] = enc(chat({ chat_key = "s-old", fleet = "gone", closed_at = "2026-11-19T15:00:00+00:00" })),
		[T .. "/repo-1234abcd/chats/s-empty/state.json"] = enc(chat({ chat_key = "s-empty", fleet = "empty", groups = {} })),
		[T .. "/repo-1234abcd/chats/s-abc/.closed/gz-2026/state.json"] = enc(chat({ fleet = "archived" })),
		[T .. "/repo-1234abcd/.closed/l0-x/state.json"] = enc(legacy()),
		[T .. "/repo-1234abcd/old/state.json"] = enc(legacy()),
		[T .. "/repo-1234abcd/notastate/readme.txt"] = "hi",
		[T .. "/.hidden/chats/s-z/state.json"] = enc(chat({ fleet = "hidden" })),
		[ROOT .. "/orca-repo/state.json"] = enc(chat({ fleet = "orca" })),
	}
end

local function by_name(list, name)
	for _, v in list do
		if v.name == name then
			return v
		end
	end
	return nil
end

test("state root from the environment", function()
	local env = { HOME = "/h" }
	local function getenv(k)
		return env[k]
	end
	eq(fleet.state_root(getenv), "/h/.local/state/agent-fleet", "default under HOME")
	env.XDG_STATE_HOME = "/x"
	eq(fleet.state_root(getenv), "/x/agent-fleet", "XDG_STATE_HOME")
	env.AGENT_FLEET_STATE_DIR = "~/s"
	eq(fleet.state_root(getenv), "/h/s", "AGENT_FLEET_STATE_DIR wins, ~ expanded")
end)

test("iso times", function()
	eq(fleet.iso_epoch("1970-01-01T00:00:00+00:00"), 0, "epoch")
	eq(fleet.iso_epoch("2026-11-19T16:20:00+00:00"), 1795105200, "a +00:00 time")
	eq(fleet.iso_epoch("2026-11-19T16:20:00Z"), 1795105200, "Z")
	eq(fleet.iso_epoch("2026-11-19T17:20:00+01:00"), 1795105200, "an offset")
	eq(fleet.iso_epoch("2000-02-29T00:00:00.123+00:00"), 951782400, "leap day with fraction")
	eq(fleet.iso_epoch("garbage"), nil, "garbage")
	eq(fleet.iso_epoch(nil), nil, "nil")
end)

test("reads chats and legacy groups; skips closed, empty, archived and dot folders", function()
	local io = tree(files())
	local entries, cache = fleet.read_states(ROOT, io, {})
	eq(#entries, 4, "four state files read (abc, empty, old chat, legacy old)")
	local m = fleet.build(entries, live())
	eq(#m.fleets, 2, "two open fleets")
	local names = {}
	for _, f in m.fleets do
		table.insert(names, f.name)
	end
	eq(table.concat(names, ","), "old,tf", "sorted by name; closed, empty, archived, hidden and Orca's not shown")
	check(cache[T .. "/repo-1234abcd/chats/s-abc"] ~= nil, "cached")
end)

test("a chat fleet: coordinator, groups in creation order, items, liveness, mailbox", function()
	local entries = fleet.read_states(ROOT, tree(files()), {})
	local f = by_name(fleet.build(entries, live()).fleets, "tf")
	eq(f.key, "repo-1234abcd/s-abc", "key")
	eq(f.coordinator.title, "L0 tf", "coordinator title")
	eq(f.coordinator.pane, 100, "coordinator pane")
	check(f.coordinator.live, "coordinator live")
	eq(f.coordinator.session, "G ga · tf", "coordinator's session")
	eq(f.coordinator.queued, 2, "mail queued for the coordinator")
	eq(#f.groups, 2, "two groups")
	eq(f.groups[1].name, "ga", "ga first (older)")
	local ga, gb = f.groups[1], f.groups[2]
	eq(ga.label, "G ga · tf", "container label")
	check(ga.session_live, "ga's session lives")
	check(not gb.session_live, "gb's session is gone")
	eq(ga.color, fleet.color_of(ga.key), "stable color")
	eq(#ga.items, 2, "removed w3 hidden")
	local w1, w2 = ga.items[1], ga.items[2]
	eq(w1.title, "L1 ga/w1", "worker title")
	eq(w1.liveness, "live", "w1 live")
	eq(w1.report.kind, "ask", "w1 asked")
	eq(w1.report.text, "which file?", "first line of the report")
	eq(w1.report.at, fleet.iso_epoch("2026-11-19T16:10:00+00:00"), "report time")
	eq(w1.mailbox, "delivered", "the live box knows m1 was delivered since")
	eq(w2.liveness, "live", "a pane in a subfolder of the worktree is its worker")
	eq(w2.mailbox, nil, "a pasted report has no mailbox state")
	eq(gb.items[1].liveness, "starting", "an item with no pane yet is starting")
end)

test("a legacy l0 group is its own fleet", function()
	local entries = fleet.read_states(ROOT, tree(files()), {})
	local f = by_name(fleet.build(entries, live()).fleets, "old")
	check(f.legacy, "legacy")
	eq(f.coordinator.pane, 200, "coordinator pane")
	check(f.coordinator.working, "coordinator working")
	eq(#f.groups, 1, "one group")
	eq(f.groups[1].label, "l0-old", "its session")
	check(f.groups[1].session_live, "session lives")
	eq(f.groups[1].items[1].liveness, "gone", "a pane that left the worktree is not the worker")
end)

test("mid-rename and corrupt files keep the last good read; a deleted one goes", function()
	local fs = files()
	local io = tree(fs)
	local path = T .. "/repo-1234abcd/chats/s-abc/state.json"
	local _, cache = fleet.read_states(ROOT, io, {})
	local reads = io.reads
	local _, cache2 = fleet.read_states(ROOT, io, cache)
	check(cache2[T .. "/repo-1234abcd/chats/s-abc"] == cache[T .. "/repo-1234abcd/chats/s-abc"], "unchanged text reuses the parse")
	check(io.reads > reads, "still re-read (no mtime)")
	-- Mid-rename: state.json gone, the writer's temp file there.
	local text = fs[path]
	fs[path] = nil
	fs[T .. "/repo-1234abcd/chats/s-abc/.state.json.4242.tmp"] = "{"
	local entries3, cache3 = fleet.read_states(ROOT, io, cache2)
	check(by_name(fleet.build(entries3, live()).fleets, "tf") ~= nil, "kept while the temp file exists")
	-- Half-written state.json.
	fs[T .. "/repo-1234abcd/chats/s-abc/.state.json.4242.tmp"] = nil
	fs[path] = string.sub(text, 1, 40)
	local entries4, cache4 = fleet.read_states(ROOT, io, cache3)
	check(by_name(fleet.build(entries4, live()).fleets, "tf") ~= nil, "a file that doesn't parse keeps the last read")
	-- Not an object.
	fs[path] = "[1,2]"
	local entries5, cache5 = fleet.read_states(ROOT, io, cache4)
	check(by_name(fleet.build(entries5, live()).fleets, "tf") ~= nil, "a non-object keeps the last read")
	-- Gone with no writer.
	fs[path] = nil
	local entries6 = fleet.read_states(ROOT, io, cache5)
	check(by_name(fleet.build(entries6, live()).fleets, "tf") == nil, "a deleted state is gone")
	-- Corrupt with no earlier read: skipped, the rest still read.
	local fs2 = files()
	fs2[path] = "{not json"
	local entries7 = fleet.read_states(ROOT, tree(fs2), {})
	local m = fleet.build(entries7, live())
	eq(#m.fleets, 1, "the corrupt chat skipped")
	eq(m.fleets[1].name, "old", "the legacy one still there")
end)

test("a missing root reads nothing", function()
	local entries, cache = fleet.read_states("/nope", tree({}), {})
	eq(#entries, 0, "no entries")
	eq(next(cache), nil, "empty cache")
end)

test("a group closed out disappears; a closed-out chat is hidden", function()
	local fs = files()
	local io = tree(fs)
	local s = chat()
	s.groups.ga = nil
	fs[T .. "/repo-1234abcd/chats/s-abc/state.json"] = enc(s)
	local f = by_name(fleet.build((fleet.read_states(ROOT, io, {})), live()).fleets, "tf")
	eq(#f.groups, 1, "only gb left")
	eq(f.groups[1].name, "gb", "gb")
	s.groups = {}
	s.closed_at = "2026-11-19T18:00:00+00:00"
	fs[T .. "/repo-1234abcd/chats/s-abc/state.json"] = enc(s)
	check(by_name(fleet.build((fleet.read_states(ROOT, io, {})), live()).fleets, "tf") == nil, "closed chat hidden")
end)

test("exited and macOS /private paths", function()
	local l = live()
	l.panes[101] = { cwd = "/private/r/x", working = false }
	l.panes[102] = { cwd = "/r/.tern-worktrees/repo/ga-w2", working = false, exited = 1 }
	local s = chat()
	s.groups.ga.items.w1.worktree = "/tmp/wt"
	l.panes[101] = { cwd = "/private/tmp/wt", working = true }
	local entries = { { dir = "/d", text = "", state = s } }
	local ga = fleet.build(entries, l).fleets[1].groups[1]
	eq(ga.items[1].liveness, "live", "/private/tmp matches /tmp")
	check(ga.items[1].working, "working")
	eq(ga.items[2].liveness, "exited", "exited pane")
	eq(ga.items[2].exit_code, 1, "exit code")
end)

test("live_of reads tern inspect", function()
	local l = fleet.live_of({
		panes = { { pane = 1, cwd = "/a", working = true, exited = nil }, { pane = 2, cwd = "/b", exited = 0 }, { nope = true } },
		sessions = { { id = 6, name = "Default", tabs = { { blocks = { { id = 1 }, { id = 2 } } } } } },
	})
	check(l.panes[1].working, "working")
	eq(l.panes[2].exited, 0, "exited")
	check(l.sessions[1].panes[2], "session holds pane 2")
	eq(#fleet.live_of(nil).sessions, 0, "nil doc")
end)

test("item and coordinator states", function()
	local function item(o)
		local base = { name = "w", title = "L1 g/w", status = "started", liveness = "live", working = false, queued = 0 }
		for k, v in o do
			base[k] = v
		end
		return base
	end
	eq(fleet.item_state(item({}), "working"), "working", "working agent")
	eq(fleet.item_state(item({ working = true }), nil), "working", "host says working")
	eq(fleet.item_state(item({}), "idle"), "idle", "idle")
	eq(fleet.item_state(item({}), "waiting_input"), "waiting", "needs the user")
	eq(fleet.item_state(item({ status = "waiting", report = { kind = "ask" } }), "idle"), "ask", "asked the coordinator")
	eq(fleet.item_state(item({ status = "waiting", report = { kind = "ask" } }), "working"), "working", "working again after an answer")
	eq(fleet.item_state(item({ status = "reported", report = { kind = "done" } }), "idle"), "done", "done")
	eq(fleet.item_state(item({ status = "reported", report = { kind = "failed" } }), "idle"), "failed", "failed report")
	eq(fleet.item_state(item({ status = "start-failed", liveness = "gone" }), nil), "failed", "start failed")
	eq(fleet.item_state(item({ status = "starting", liveness = "starting" }), nil), "starting", "starting")
	eq(fleet.item_state(item({ liveness = "gone" }), nil), "gone", "gone")
	eq(fleet.item_state(item({ liveness = "exited", exit_code = 0 }), nil), "gone", "exited without a report")
	eq(fleet.item_state(item({ liveness = "exited", exit_code = 0, status = "reported", report = { kind = "done" } }), nil), "done", "exited after done")
	eq(fleet.item_state(item({ liveness = "exited", exit_code = 2 }), nil), "failed", "exited non-zero")
	eq(fleet.item_state(item({}), "exited"), "gone", "window says the agent exited")
	local fresh = item({ liveness = "gone", worktree = "/wt/g-w" })
	eq(fleet.item_state(fresh, "working", "/wt/g-w"), "working", "the window lists its agent before the host polled its pane")
	eq(fresh.liveness, "gone", "the record itself is untouched")
	eq(fleet.item_state(fresh, "idle", "/elsewhere"), "gone", "an agent outside its worktree is not its worker")
	eq(fleet.item_state(item({ status = "starting", liveness = "starting", worktree = "/wt/g-w" }), "working", "/wt/g-w/sub"), "working", "started before the host saw it")
	eq(fleet.coordinator_state({ live = true, working = false, title = "L0", queued = 0 }, "working"), "working", "coordinator working")
	eq(fleet.coordinator_state({ live = true, working = false, title = "L0", queued = 0 }, nil), "idle", "coordinator idle")
	eq(fleet.coordinator_state({ live = false, working = false, title = "L0", queued = 0 }, nil), "gone", "coordinator gone")
	check(fleet.unread(item({ report = { kind = "done", at = 10 } }), 5), "report after the last look")
	check(not fleet.unread(item({ report = { kind = "done", at = 10 } }), 10), "seen in the same second")
	check(not fleet.unread(item({}), 5), "no report")
end)

test("colors are stable and Tern's", function()
	local c = fleet.color_of("repo/s-abc/ga")
	eq(fleet.color_of("repo/s-abc/ga"), c, "same key, same color")
	check(table.find(fleet.COLORS, c) ~= nil, "a TabColor")
	local seen = {}
	for i = 1, 40 do
		seen[fleet.color_of("k" .. i)] = true
	end
	local n = 0
	for _ in seen do
		n += 1
	end
	check(n >= 6, "spread over the palette")
end)

-- The sidebar's fleet section ------------------------------------------------------------

local ROOT_ID = sidebar.ROOT_ID
local LIST = ROOT_ID .. ".list"
local NOW = 1795105200 + 300

local function snap(collapsed)
	return {
		now = NOW,
		active = 101,
		collapsed = collapsed or {},
		projects = {},
		fleets = {
			{
				key = "repo/s-abc",
				name = "tf",
				coordinator = { pane = 100, title = "L0 tf", state = "idle", session = "G ga · tf", queued = 2 },
				groups = {
					{
						key = "repo/s-abc/ga",
						name = "ga",
						label = "G ga · tf",
						session_live = true,
						items = {
							{ name = "w1", title = "L1 ga/w1", branch = "ga-w1", pane = 101, state = "ask", report = { kind = "ask", at = NOW - 120, text = "which file?" }, unread = true },
							{ name = "w2", title = "L1 ga/w2", pane = 102, state = "working" },
							{ name = "w3", title = "L1 ga/w3", pane = 103, state = "gone" },
						},
					},
					{ key = "repo/s-abc/gb", name = "gb", label = "G gb · tf", session_live = false, items = {} },
				},
			},
		},
	}
end

local function texts(node)
	local out = {}
	t.walk(node, "x", function(n)
		if n.p and n.p.text then
			table.insert(out, n.p.text)
		end
	end)
	return table.concat(out, "|")
end

test("fleet section: fleet → coordinator → groups → workers", function()
	sidebar.ui = nil
	local view = sidebar.build(snap()).view
	local fid = LIST .. ".f_repo_2fs-abc"
	local sec = t.find(view, ROOT_ID, fid)
	check(sec ~= nil, "fleet section keyed by fleet")
	check(string.find(sec.p.class, "op-fleet", 1, true) ~= nil, "classed")
	local head = t.find(view, ROOT_ID, fid .. ".head")
	eq(head.p.actions.click, "toggle_group=fleet:repo/s-abc", "header collapses the fleet")
	eq(t.find(view, ROOT_ID, fid .. ".head.sum").p.text, "1 asks · 1 working · 1 gone", "summary")
	local coord = t.find(view, ROOT_ID, fid .. ".coord")
	eq(coord.p.actions.click, "fleet_focus=100", "coordinator click focuses its pane")
	check(string.find(texts(coord), "2 queued", 1, true) ~= nil, "coordinator's queue depth")
	check(string.find(texts(coord), "coordinator · G ga · tf", 1, true) ~= nil, "coordinator's session")
	local ga = t.find(view, ROOT_ID, fid .. ".fg_ga")
	check(ga ~= nil and string.find(ga.p.class, "op-fgrp", 1, true) ~= nil, "group container")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.head").p.actions.click, "fleet_group=repo/s-abc/ga", "group row shows its session")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.head.name").p.text, "G ga · tf", "group label")
	eq(t.find(view, ROOT_ID, fid .. ".fg_gb.head.name").p.text, "G gb · tf (no session)", "a group without its session")
	local w1 = t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1")
	eq(w1.p.actions.click, "fleet_focus=101", "worker click focuses its pane")
	check(string.find(w1.p.class, "unread", 1, true) ~= nil, "unread report")
	check(string.find(w1.p.class, " on", 1, true) ~= nil, "the focused worker")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1.row.lane.ud").p.class, "op-udot", "unread dot")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1.row.stack.meta.badge").p.text, "Asks", "ask badge")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1.row.stack.meta.t").p.text, "ga-w1", "branch")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1.row.stack.agents.report.text.lead").p.text, "ask: which file?", "last report")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1.row.stack.agents.report.time").p.text, "2m", "report age")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1.row.stack.line.title").p.text, "L1 ga/w1", "L1 title")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w2.row.stack.meta.badge").p.text, "Working", "working badge")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w2.row.lane.st").p.class, "op-st op-st-md op-working", "spinner lane")
	local w3 = t.find(view, ROOT_ID, fid .. ".fg_ga.w_w3")
	eq(w3.p.actions.click, "fleet_group=repo/s-abc/ga", "a gone worker's click shows its group")
	check(string.find(w3.p.class, "sleeping", 1, true) ~= nil, "gone is dimmed")
	-- Fleets come before the projects' empty state.
	eq(t.find(view, ROOT_ID, LIST .. ".empty"), nil, "no empty placeholder with a fleet")
end)

test("fleet section collapses, by fleet and by group", function()
	local view = sidebar.build(snap({ ["fgroup:repo/s-abc/ga"] = true })).view
	local fid = LIST .. ".f_repo_2fs-abc"
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga.w_w1"), nil, "collapsed group hides its workers")
	check(t.find(view, ROOT_ID, fid .. ".fg_ga.head") ~= nil, "its row stays")
	view = sidebar.build(snap({ ["fleet:repo/s-abc"] = true })).view
	eq(t.find(view, ROOT_ID, fid .. ".coord"), nil, "collapsed fleet hides its cards")
	eq(t.find(view, ROOT_ID, fid .. ".fg_ga"), nil, "and its groups")
end)

test("actions parse: fleet_focus takes a pane, fleet_group a key", function()
	local a, v = sidebar.parse_action({ act = "fleet_focus=101" })
	eq(a, "fleet_focus", "act")
	eq(v, 101, "pane number")
	a, v = sidebar.parse_action({ act = "fleet_group", value = "repo/s-abc/ga" })
	eq(v, "repo/s-abc/ga", "key string")
end)

t.finish("fleet")
