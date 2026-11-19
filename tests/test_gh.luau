--!nonstrict
-- luau tests/test_gh.luau: GitHub PRs and issues (gh.luau): remotes, parsing gh's JSON, the CI rollup, branch → PR
-- matching, the refresh clock and staleness, create-PR argv, and how the sidebar draws badges and the list.

local t = require("./support")
local json = require("./support_json")
local gh = require("../gh")
local sidebar = require("../sidebar")

local check, eq, test = t.check, t.eq, t.test

local ROOT_ID = sidebar.ROOT_ID
local LIST = ROOT_ID .. ".list"
local NOW = 1800000000

-- A gh pr list entry shaped like gh 2.98's `--json` output.
local function raw(n, o)
	o = o or {}
	local r = {
		number = n,
		title = o.title or ("PR " .. n),
		state = o.state or "OPEN",
		isDraft = o.draft or false,
		reviewDecision = o.review or "",
		statusCheckRollup = o.checks or {},
		url = "https://github.com/acme/app/pull/" .. n,
		mergeable = o.mergeable or "MERGEABLE",
		updatedAt = o.updated or "2026-11-19T10:00:00Z",
		headRefName = o.branch or ("b" .. n),
		isCrossRepository = o.fork or false,
		author = { login = o.author or "someone", is_bot = false },
		reviewRequests = o.asked or {},
	}
	return r
end

local function run(conclusion, status)
	return { __typename = "CheckRun", name = "ci", status = status or "COMPLETED", conclusion = conclusion or "" }
end

local function ctx(state)
	return { __typename = "StatusContext", context = "ci/legacy", state = state }
end

-- Tiny encoder for gh-shaped fixtures (tables, strings, numbers, booleans).
local function enc(x): string
	local ty = type(x)
	if ty == "string" then
		return '"' .. string.gsub(x, '[\\"]', "\\%0") .. '"'
	elseif ty == "number" or ty == "boolean" then
		return tostring(x)
	elseif ty == "table" then
		if next(x) == nil then
			return "[]"
		end
		if #x > 0 then
			local parts = {}
			for _, v in x do
				table.insert(parts, enc(v))
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
			table.insert(parts, enc(k) .. ":" .. enc(x[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

test("remotes: github.com URLs in every form, nothing else", function()
	eq(gh.slug_of_url("https://github.com/dansolombrino/tern-projects"), "dansolombrino/tern-projects", "https")
	eq(gh.slug_of_url("https://github.com/dansolombrino/tern-projects.git"), "dansolombrino/tern-projects", "https .git")
	eq(gh.slug_of_url("https://github.com/o/r/"), "o/r", "trailing slash")
	eq(gh.slug_of_url("https://x-access-token@github.com/o/r.git"), "o/r", "userinfo")
	eq(gh.slug_of_url("git@github.com:dansolombrino/skills.git"), "dansolombrino/skills", "scp-like ssh")
	eq(gh.slug_of_url("ssh://git@github.com/o/my.repo.git"), "o/my.repo", "ssh URL, dotted name")
	eq(gh.slug_of_url("https://gitlab.com/o/r.git"), nil, "gitlab")
	eq(gh.slug_of_url("https://notgithub.com/o/r"), nil, "look-alike host")
	eq(gh.slug_of_url("https://github.example.com/o/r"), nil, "enterprise host")
	eq(gh.slug_of_url("/srv/git/r.git"), nil, "local path")
	eq(gh.slug_of_url("https://github.com/o"), nil, "no repo")
	eq(gh.slug_of_url(nil), nil, "nil")
	local remotes = "upstream\thttps://github.com/up/r.git (fetch)\nupstream\thttps://github.com/up/r.git (push)\norigin\tgit@github.com:me/r.git (fetch)\norigin\tgit@github.com:me/r.git (push)\n"
	eq(gh.slug_of_remotes(remotes), "me/r", "origin wins")
	eq(gh.slug_of_remotes("mirror\thttps://gitlab.com/a/b (fetch)\nup\thttps://github.com/up/r (fetch)\n"), "up/r", "else the first GitHub remote")
	eq(gh.slug_of_remotes("origin\t/srv/git/r.git (fetch)\n"), nil, "no GitHub remote")
	eq(gh.slug_of_remotes(""), nil, "no remote")
end)

test("CI rollup: fail over pending over pass; skipped counts as passed", function()
	eq(gh.rollup({}), nil, "no checks")
	eq(gh.rollup(nil), nil, "missing")
	local s, c = gh.rollup({ run("SUCCESS"), run("SKIPPED"), run("NEUTRAL") })
	eq(s, "pass", "all green")
	eq(c, "3/3", "counts")
	s, c = gh.rollup({ run("SUCCESS"), run("", "IN_PROGRESS") })
	eq(s, "pending", "one running")
	eq(c, "1/2", "running not passed")
	eq(gh.rollup({ run("SUCCESS"), run("", "QUEUED"), run("FAILURE") }), "fail", "a failure wins over running")
	eq(gh.rollup({ run("TIMED_OUT") }), "fail", "timed out")
	eq(gh.rollup({ run("CANCELLED") }), "fail", "cancelled")
	eq(gh.rollup({ run("ACTION_REQUIRED") }), "fail", "action required")
	eq(gh.rollup({ ctx("SUCCESS"), ctx("PENDING") }), "pending", "status context pending")
	eq(gh.rollup({ ctx("ERROR") }), "fail", "status context error")
	eq(gh.rollup({ ctx("EXPECTED") }), "pending", "expected context")
	eq(gh.rollup({ run(nil, "COMPLETED") }), "pending", "completed without a verdict yet")
end)

test("parsing gh pr list JSON", function()
	local text = enc({
		raw(1, { checks = { run("SUCCESS") }, review = "APPROVED", author = "me" }),
		raw(2, { draft = true, checks = { run("FAILURE") }, review = "REVIEW_REQUIRED", asked = { { __typename = "User", login = "me" } } }),
		raw(3, { state = "MERGED", review = "APPROVED" }),
		raw(4, { state = "CLOSED", mergeable = "CONFLICTING" }),
		raw(5, { mergeable = "CONFLICTING", review = "CHANGES_REQUESTED", fork = true, asked = { { __typename = "Team", slug = "core" } } }),
		{ title = "no number" },
	})
	local prs, err = gh.parse_prs(text, json.decode, "me")
	check(prs ~= nil and err == nil, "parsed")
	eq(#prs, 5, "malformed entry skipped")
	local p1, p2, p3, p4, p5 = prs[1], prs[2], prs[3], prs[4], prs[5]
	eq(p1.state, "open", "open")
	eq(p1.ci, "pass", "ci pass")
	eq(p1.checks, "1/1", "check counts")
	eq(p1.review, "approved", "approved")
	check(p1.mine == true and p1.asked == nil, "authored by me")
	eq(p1.url, "https://github.com/acme/app/pull/1", "url")
	eq(p1.branch, "b1", "head branch")
	eq(p2.state, "draft", "draft")
	eq(p2.ci, "fail", "ci fail")
	eq(p2.review, "review", "review required")
	check(p2.asked == true and p2.mine == nil, "review asked of me")
	eq(p3.state, "merged", "merged")
	eq(p3.review, nil, "no review mark once merged")
	eq(p3.ci, nil, "no checks")
	eq(p4.state, "closed", "closed")
	eq(p4.conflicts, nil, "conflicts only matter while open")
	check(p5.conflicts == true and p5.fork == true and p5.asked == nil, "conflicts, fork, team request isn't me")
	eq(p5.review, "changes", "changes requested")
	local none, why = gh.parse_prs("not json", json.decode, "me")
	check(none == nil and why ~= nil, "garbage → nil and why")
	local empty = gh.parse_prs("[]", json.decode, nil)
	eq(#empty, 0, "empty list")
	local unknown_me = gh.parse_prs(enc({ raw(1, { author = "me" }) }), json.decode, nil)
	eq(unknown_me[1].mine, nil, "no login known: nothing is mine")
end)

test("parsing gh issue list JSON", function()
	local issues = gh.parse_issues(enc({
		{ number = 7, title = "Crash", url = "https://github.com/acme/app/issues/7", updatedAt = "2026-11-18T00:00:00Z" },
		{ number = 8, title = "no url" },
	}), json.decode)
	eq(#issues, 1, "one valid issue")
	eq(issues[1].n, 7, "number")
	eq(issues[1].title, "Crash", "title")
	check(gh.parse_issues("{oops", json.decode) == nil, "garbage")
	check(gh.issues_disabled("the 'acme/app' repository has disabled issues"), "issues off is not a failure")
	check(not gh.issues_disabled("HTTP 502"), "other errors are")
end)

test("branch → PR: open over merged over closed, newest first, never a fork's", function()
	local prs = gh.parse_prs(enc({
		raw(10, { branch = "feat", state = "CLOSED", updated = "2026-11-19T00:00:00Z" }),
		raw(11, { branch = "feat", state = "MERGED", updated = "2026-11-10T00:00:00Z" }),
		raw(12, { branch = "feat", state = "OPEN", updated = "2026-11-01T00:00:00Z" }),
		raw(13, { branch = "other", state = "MERGED", updated = "2026-11-01T00:00:00Z" }),
		raw(14, { branch = "other", state = "MERGED", updated = "2026-11-05T00:00:00Z" }),
		raw(15, { branch = "main", fork = true }),
	}), json.decode, "me")
	eq(gh.pick(prs, "feat").n, 12, "open wins")
	eq(gh.pick(prs, "other").n, 14, "most recently updated")
	eq(gh.pick(prs, "main"), nil, "a fork's branch named like ours is not ours")
	eq(gh.pick(prs, "nope"), nil, "no PR")
	eq(gh.pick(prs, nil), nil, "no branch")
	local repo = gh.empty_repo()
	repo.open = { prs[3] }
	repo.heads = { old = prs[4], none = false }
	eq(gh.pr_for(repo, "feat").n, 12, "open list first")
	eq(gh.pr_for(repo, "old").n, 13, "else the head lookup")
	eq(gh.pr_for(repo, "none"), nil, "looked up, none")
	eq(gh.pr_for(repo, "unknown"), nil, "never looked up")
end)

test("head lookups: only branches without an open PR, TTL, capped, oldest first", function()
	local repo = gh.empty_repo()
	repo.open = gh.parse_prs(enc({ raw(1, { branch = "has-open" }) }), json.decode, nil)
	repo.head_at = { fresh = NOW - 10, old = NOW - gh.HEAD_TTL - 1 }
	repo.heads = { fresh = false, old = false, gone = false }
	repo.head_at.gone = NOW
	local due = gh.heads_due(repo, { "has-open", "fresh", "old", "a", "b", "c", "d", "a" }, NOW)
	eq(#due, gh.HEADS_PER_REFRESH, "capped")
	eq(due[1], "a", "never looked up first (by name)")
	check(table.find(due, "has-open") == nil, "open PR found: no lookup")
	check(table.find(due, "fresh") == nil, "looked up recently")
	local all = gh.heads_due(repo, { "old", "fresh" }, NOW)
	eq(table.concat(all, ","), "old", "TTL expired")
	gh.prune_heads(repo, { "old", "fresh" })
	eq(repo.heads.gone, nil, "a branch no card shows is forgotten")
	eq(repo.head_at.gone, nil, "and its time")
	check(not gh.new_heads(repo, { "fresh", "old", "has-open" }), "every branch looked up or with an open PR")
	check(not gh.new_heads(repo, { "brand-new" }), "open PRs not known yet: wait for the refresh")
	repo.ok_at = NOW
	check(gh.new_heads(repo, { "fresh", "brand-new" }), "a card just appeared: look it up now")
	check(not gh.new_heads(repo, { "has-open" }), "its open PR is known")
end)

test("the project list: mine or asked, newest first", function()
	local repo = gh.empty_repo()
	repo.open = gh.parse_prs(enc({
		raw(1, { author = "me", updated = "2026-11-01T00:00:00Z" }),
		raw(2, { author = "other" }),
		raw(3, { author = "other", asked = { { login = "me" } }, updated = "2026-11-19T00:00:00Z" }),
	}), json.decode, "me")
	local mine = gh.mine(repo)
	eq(#mine, 2, "two of mine")
	eq(mine[1].n, 3, "newest first")
	repo.issues = { { n = 1, title = "x", url = "u" } }
	local p, i = gh.counts(repo)
	eq(p, 2, "PR count")
	eq(i, 1, "issue count")
end)

test("refresh clock: interval, doubling backoff, rate limit floor", function()
	local repo = gh.empty_repo()
	eq(gh.next_at(repo, true), 0, "never tried: now")
	repo.tried_at = NOW
	eq(gh.next_at(repo, true), NOW + 60, "60 s while shown")
	eq(gh.next_at(repo, false), NOW + 300, "5 min while hidden")
	repo.fails = 1
	repo.error = "HTTP 502"
	eq(gh.next_at(repo, true), NOW + 120, "one failure doubles")
	repo.fails = 3
	eq(gh.next_at(repo, true), NOW + 480, "three: 8x")
	repo.fails = 20
	eq(gh.next_at(repo, true), NOW + gh.BACKOFF_MAX, "capped at 30 min")
	repo.fails = 1
	repo.error = "GraphQL: API rate limit exceeded for user ID 1."
	eq(gh.next_at(repo, true), NOW + gh.RATE_S, "rate limit: 15 min")
	check(gh.rate_limited("You have exceeded a secondary rate limit"), "secondary rate limit")
	check(not gh.rate_limited(nil), "no error")
end)

test("staleness: a failed or old refresh, or none yet", function()
	local repo = gh.empty_repo()
	check(gh.stale(repo, NOW), "never refreshed")
	repo.ok_at = NOW - 30
	check(not gh.stale(repo, NOW), "fresh")
	repo.error = "gh: command not found"
	check(gh.stale(repo, NOW), "last refresh failed: stale, data kept")
	repo.error = nil
	repo.ok_at = NOW - gh.STALE_S - 1
	check(gh.stale(repo, NOW), "too old")
end)

test("errors: first line, tokens masked, short", function()
	eq(gh.error_text("error: bad token ghp_abcDEF123_456\nmore", "", 1), "error: bad token ***", "masked, first line")
	eq(gh.error_text("", "github_pat_11AB_cd failed", 1), "*** failed", "pat masked from stdout")
	eq(gh.error_text("", "", 127), "gh exited with status 127", "no output")
	check(#gh.error_text(string.rep("x", 500), nil, 1) <= 204, "truncated")
end)

test("argv: list, head lookup, issues, create (dry run)", function()
	local a = gh.pr_list_argv("gh", "acme/app")
	eq(table.concat(a, " "), "gh pr list --repo acme/app --state open --limit 50 --json " .. gh.PR_FIELDS, "open PRs")
	local h = gh.head_argv("/opt/homebrew/bin/gh", "acme/app", "feat/x")
	eq(h[1], "/opt/homebrew/bin/gh", "executable")
	check(table.find(h, "--head") and h[table.find(h, "--head") + 1] == "feat/x", "branch after --head")
	check(table.find(h, "all") ~= nil, "every state")
	local i = gh.issue_argv("gh", "acme/app")
	check(table.find(i, "@me") ~= nil and table.find(i, "open") ~= nil, "my open issues")
	local c = gh.create_argvs("gh", "acme/app", "dan/feat", true)
	eq(table.concat(c[1], " "), "git push --set-upstream origin dan/feat", "push first")
	eq(table.concat(c[2], " "), "gh pr create --repo acme/app --head dan/feat --fill --dry-run", "create, dry run")
	local live = gh.create_argvs("gh", "acme/app", "dan/feat")
	eq(table.find(live[2], "--dry-run"), nil, "no dry run unless asked")
end)

test("only github.com links open", function()
	check(gh.openable("https://github.com/acme/app/pull/1"), "a PR")
	check(gh.openable("https://github.com/acme/app/pulls"), "the list")
	check(not gh.openable("http://github.com/acme/app"), "not https")
	check(not gh.openable("https://evil.com/github.com/acme/app"), "other host")
	check(not gh.openable("https://github.com/acme/app\"; rm"), "quotes")
	check(not gh.openable(nil), "nil")
end)

-- The sidebar ----------------------------------------------------------------------

local function pr(n, o)
	return gh.pr_of(raw(n, o), "me")
end

local function snap(open)
	return {
		now = NOW,
		projects = {
			{
				project = { id = "app", name = "App", root = "/src/app" },
				session_exists = true,
				current = true,
				agents = {
					{
						pane = 11, project = "app", title = "feat", state = "idle", cwd = "/src/wt/feat", branch = "feat",
						pr = pr(12, { branch = "feat", checks = { run("SUCCESS") }, review = "APPROVED" }),
					},
					{ pane = 12, project = "app", title = "old", state = "idle", cwd = "/src/wt/old", branch = "old", pr = pr(9, { state = "MERGED" }), pr_stale = true },
					{ pane = 13, project = "app", title = "none", state = "idle", cwd = "/src/wt/none", branch = "none" },
				},
				gh = {
					slug = "acme/app",
					prs = { pr(12, { branch = "feat", author = "me" }), pr(20, { asked = { { login = "me" } }, title = "Review me" }) },
					issues = { { n = 7, title = "Crash", url = "https://github.com/acme/app/issues/7" } },
					stale = false,
					ok_at = NOW - 120,
					open = open,
				},
			},
			{ project = { id = "local", name = "Local", root = "/src/local" }, session_exists = false, current = false, agents = {} },
		},
	}
end

local function texts(n): string
	local out = {}
	t.walk(n, "x", function(c)
		if c.p and c.p.text then
			table.insert(out, c.p.text)
		end
	end)
	return table.concat(out, "|")
end

test("card badge: number, state, CI dot, review mark; click opens the PR", function()
	sidebar.ui = nil
	local view = sidebar.build(snap(false)).view
	local badge = t.find(view, ROOT_ID, LIST .. ".g_app.c_11.row.stack.meta.pr")
	check(badge ~= nil, "badge in the card's meta row")
	eq(badge.p.actions.click, "open_url=https://github.com/acme/app/pull/12", "opens the PR")
	check(string.find(badge.p.class, "op-pr-open", 1, true) ~= nil, "open state class")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.c_11.row.stack.meta.pr.n").p.text, "#12 open", "number and state")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.c_11.row.stack.meta.pr.ci").p.class, "op-ci op-ci-pass", "CI dot")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.c_11.row.stack.meta.pr.rv").p.text, "✓", "approved mark")
	check(string.find(badge.p.title, "checks pass 1/1 · approved", 1, true) ~= nil, "tooltip says it all")
	local old = t.find(view, ROOT_ID, LIST .. ".g_app.c_12.row.stack.meta.pr")
	check(string.find(old.p.class, "op-pr-merged", 1, true) ~= nil and string.find(old.p.class, "op-stale", 1, true) ~= nil, "merged, stale")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.c_13.row.stack.meta"), nil, "no PR: no meta row")
	local _, url = sidebar.parse_action({ act = "open_url=https://github.com/acme/app/pulls?q=is%3Aopen+author=me" })
	eq(url, "https://github.com/acme/app/pulls?q=is%3Aopen+author=me", "a URL with `=` survives the split")
end)

test("project: header counts, collapsible PRs & issues, refresh and browser", function()
	sidebar.ui = nil
	local view = sidebar.build(snap(false)).view
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.head.ghc").p.text, "2 PRs · 1 issue", "counts in the header")
	local sec = t.find(view, ROOT_ID, LIST .. ".g_app.prs")
	check(sec ~= nil and string.find(sec.p.class, "collapsed", 1, true) ~= nil, "collapsed by default")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.head").p.actions.click, "toggle_prs=app", "header toggles")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.head.acts.refresh").p.actions.click, "gh_refresh=acme/app", "refresh")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.head.acts.web").p.actions.click, "open_url=https://github.com/acme/app/pulls", "open in browser")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.pr12"), nil, "rows hidden while collapsed")
	eq(t.find(view, ROOT_ID, LIST .. ".g_local.prs"), nil, "no GitHub: nothing")
	eq(t.find(view, ROOT_ID, LIST .. ".g_local.head.ghc"), nil, "no counts either")
	view = sidebar.build(snap(true)).view
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.pr12").p.actions.click, "open_url=https://github.com/acme/app/pull/12", "PR row opens")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.pr20.m").p.text, "review asked", "why it is listed")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.is7").p.actions.click, "open_url=https://github.com/acme/app/issues/7", "issue row opens")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.head.s").p.text, "2m", "age of the data")
end)

test("stale project data is marked, with the error in the tooltip", function()
	sidebar.ui = nil
	local s = snap(true)
	s.projects[1].gh.stale = true
	s.projects[1].gh.error = "exec: \"gh\": executable file not found in $PATH"
	local view = sidebar.build(s).view
	local status = t.find(view, ROOT_ID, LIST .. ".g_app.prs.head.s")
	eq(status.p.text, "stale · 2m", "stale marker with the last good data's age")
	check(string.find(status.p.class, "op-stale", 1, true) ~= nil, "styled stale")
	check(string.find(t.find(view, ROOT_ID, LIST .. ".g_app.prs.head").p.title, "Last refresh failed: exec", 1, true) ~= nil, "why, on hover")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.head.ghc").p.text, "2 PRs · 1 issue · stale", "header says stale")
	check(t.find(view, ROOT_ID, LIST .. ".g_app.prs.pr12") ~= nil, "last good data still listed")
	s.projects[1].gh = { slug = "acme/app", prs = {}, issues = {}, stale = true, error = "gh missing", open = true }
	view = sidebar.build(s).view
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.prs.head.s").p.text, "unavailable", "never fetched and failing")
	eq(t.find(view, ROOT_ID, LIST .. ".g_app.head.ghc"), nil, "no counts, no stale word without data")
	check(string.find(texts(t.find(view, ROOT_ID, LIST .. ".g_app.prs")), "Nothing yet", 1, true) ~= nil, "empty list says so")
end)

test("fleet worker and group badges", function()
	sidebar.ui = nil
	local view = sidebar.build({
		now = NOW,
		projects = {},
		fleets = {
			{
				key = "r/f",
				name = "f",
				coordinator = { title = "L0 f", state = "idle" },
				groups = {
					{
						key = "r/f/g",
						name = "g",
						label = "G g · f",
						branch = "fleet/g",
						pr = pr(30, { branch = "fleet/g", state = "OPEN", draft = true }),
						items = {
							{ name = "w1", title = "L1 g/w1", branch = "g-w1", pane = 5, state = "working", pr = pr(31, { branch = "g-w1", checks = { run("", "IN_PROGRESS") } }) },
						},
					},
				},
			},
		},
	}).view
	local fid = LIST .. ".f_r_2ff"
	local w = t.find(view, ROOT_ID, fid .. ".fg_g.w_w1.row.stack.meta.pr")
	check(w ~= nil, "worker badge")
	eq(t.find(view, ROOT_ID, fid .. ".fg_g.w_w1.row.stack.meta.pr.ci").p.class, "op-ci op-ci-pending", "CI running")
	local g = t.find(view, ROOT_ID, fid .. ".fg_g.head.pr")
	check(g ~= nil and string.find(g.p.class, "op-pr-draft", 1, true) ~= nil, "group badge, draft")
end)

t.finish("gh")
