--!strict
-- projects, sidebar: the Orca-style left sidebar (Search pill, "Projects" header,
-- project groups, one card per top-level agent with its subagents nested under
-- it, the Activity view) and its footer toolbar. Pure: `build` turns a snapshot
-- into `tern.ui.el` nodes (or `sidebar.ui`'s, which tests stub) classed `op-*`
-- for sidebar.css, and reads nothing else.
--
-- Clicks carry `actions = {click = "<act>=<value>"}`; Tern splits the name at
-- the first `=`, so `canvas_action` handlers get `ev.act` and `ev.value`.

local gh = require("./gh")
local subagents = require("./subagents")

export type Subagent = subagents.Subagent & {
	-- os.time() the controller first saw it running.
	first_seen: number?,
}

export type Project = {
	id: string,
	name: string,
	root: string,
	-- A preset name (`neutral red orange yellow green teal purple pink`) or `#rrggbb`.
	color: string?,
	-- nil: the `folder` icon.
	icon: { kind: "icon" | "emoji", name: string?, emoji: string? }?,
	worktrees: boolean?,
	created: number?,
	-- The remote Tern host it lives on (`ManagedHost.name`); nil for this machine.
	host: string?,
}

export type AgentRow = {
	-- Sleeping cards: a negative synthetic id, unique per record.
	pane: number,
	-- The agent's record key (identity.luau), or tostring(pane) for an agent with no record.
	key: string?,
	-- Owning project's id (every row, children included); nil outside projects.
	project: string?,
	title: string,
	-- Tern's agent state (idle | working | waiting_input | exited) or "sleeping".
	state: string,
	-- The last turn's outcome; nil before any turn or once working again.
	result: ("done" | "failed" | "interrupted")?,
	done_at: number?,
	started: number?,
	last_activity: number?,
	model: string?,
	last_message: string?,
	-- The task or latest user prompt (lead of the agent's row).
	prompt: string?,
	-- "tool: intent" while working.
	tool: string?,
	cwd: string,
	branch: string?,
	-- Short sha when HEAD is detached.
	detached: string?,
	-- Works in the project root (no worktree).
	primary: boolean?,
	pinned: boolean?,
	deleting: boolean?,
	-- The PR of its branch (gh.luau), and whether that data is stale (the last refresh failed or is old).
	pr: gh.Pr?,
	pr_stale: boolean?,
	spawned: { AgentRow }?,
	-- Running or pending only, flattened, owners before owned.
	internal: { Subagent }?,
}

export type Group = { id: string, name: string }

export type ProjectSnap = {
	project: Project,
	session_exists: boolean,
	current: boolean,
	agents: { AgentRow },
	group: Group?,
	-- Its remote host's short name (`rig-4090`), shown as a muted tag on its header; nil for this machine.
	host: string?,
	-- Its GitHub repository's PRs and issues; nil outside GitHub.
	gh: GhSnap?,
}

-- A project's "PRs & issues": its open PRs the user authored or is asked to review, open issues assigned to them.
export type GhSnap = {
	slug: string,
	prs: { gh.Pr },
	issues: { gh.Issue },
	-- The last refresh failed (`error`) or is old; data from `ok_at` (os.time(), nil before the first).
	stale: boolean,
	error: string?,
	ok_at: number?,
	busy: boolean?,
	-- The list is expanded.
	open: boolean?,
}

export type Snapshot = {
	-- Ordered, sorted and filtered; a group's projects are contiguous.
	projects: { ProjectSnap },
	-- Every group, so empty ones still get a header.
	groups: { Group }?,
	-- Pinned cards, already removed from their projects.
	pinned: { AgentRow }?,
	unassigned: { AgentRow }?,
	-- Project id, "pinned" or "group:<id>" → collapsed.
	collapsed: { [string]: boolean }?,
	-- Focused agent pane.
	active: number?,
	unread: { [number]: boolean }?,
	-- os.time() for the "now/5m/3h/2d" labels.
	now: number?,
	body: ("workspaces" | "agents")?,
	group_by: ("project" | "none")?,
	-- Card display toggles: branch text row (off), agent rows and their models (on).
	show_branch: boolean?,
	show_agents: boolean?,
	show_models: boolean?,
	-- Parent pane → child list open.
	expanded: { [number]: boolean }?,
	-- Parent pane → "N idle" group open.
	idle_open: { [number]: boolean }?,
	-- Pane whose card glows.
	reveal: number?,
	-- Active filter count.
	filters: number?,
	keys: { search: { string }?, new_agent: { string }?, collapse_all: { string }? }?,
	-- Agents waiting for input, all projects (else counted here).
	waiting: number?,
	-- Automations (autowin.luau): drawn after the projects.
	autos: AutoSnap?,
}

-- One automation: its schedule, next run, active run (queued, precheck, starting, running) and latest finished run.
export type AutoRun = {
	id: string,
	n: number,
	status: string,
	trigger: string?,
	scheduled_for: number?,
	started: number?,
	ended: number?,
	count: number?,
	summary: string?,
	note: string?,
	out: string?,
	pane: number?,
	mode: string?,
}
export type AutoRow = {
	id: string,
	name: string,
	enabled: boolean,
	label: string,
	run_in: string,
	next_at: number?,
	active: AutoRun?,
	last: AutoRun?,
}
export type AutoSnap = {
	list: { AutoRow },
	-- Problems in automations.json, one line each.
	errors: { string },
	open: boolean,
	running: number,
}

local sidebar = {}

-- Builders; nil means the global `tern.ui`. Tests assign a stub.
sidebar.ui = nil :: any

-- Action names (the contract with window.luau); values follow `=`.
sidebar.ACT = {
	-- value: pane
	focus = "focus",
	rename = "rename",
	new_subagent = "new_subagent",
	sleep = "sleep",
	delete = "delete",
	wake = "wake",
	toggle_unread = "toggle_unread",
	toggle_pin = "toggle_pin",
	copy_path = "copy_path",
	copy_name = "copy_name",
	open_finder = "open_finder",
	toggle_kids = "toggle_kids",
	toggle_idle = "toggle_idle",
	-- value: project id (optional for new_agent); toggle_group also takes "pinned" and "group:<id>"
	new_agent = "new_agent",
	open_project = "open_project",
	remove_project = "remove_project",
	toggle_group = "toggle_group",
	project_menu = "project_menu",
	project_settings = "project_settings",
	project_icon = "project_icon",
	new_group = "new_group",
	move_to_group = "move_to_group",
	ungroup = "ungroup",
	-- value: group id
	group_menu = "group_menu",
	rename_group = "rename_group",
	delete_group = "delete_group",
	-- value: a https://github.com/ URL (opened in the system browser)
	open_url = "open_url",
	-- value: `owner/repo`: refresh its PRs and issues now
	gh_refresh = "gh_refresh",
	-- value: project id: expand or collapse its "PRs & issues"
	toggle_prs = "toggle_prs",
	-- value: automation id: run now, enable or pause, open its latest output, its runs
	auto_run = "auto_run",
	auto_toggle = "auto_toggle",
	auto_open = "auto_open",
	auto_runs = "auto_runs",
	-- no value (this and every action below): a new automation, edit automations.json
	auto_new = "auto_new",
	auto_edit = "auto_edit",
	collapse_all = "collapse_all",
	add_project = "add_project",
	search = "search",
	activity = "activity",
	options = "options",
	settings = "settings",
	help = "help",
	reveal = "reveal",
}

-- Actions whose value is a pane number.
local PANE_ACTS: { [string]: boolean } = {
	focus = true,
	rename = true,
	new_subagent = true,
	sleep = true,
	delete = true,
	wake = true,
	toggle_unread = true,
	toggle_pin = true,
	copy_path = true,
	copy_name = true,
	open_finder = true,
	toggle_kids = true,
	toggle_idle = true,
}

-- For cx.canvas:open's `about`.
sidebar.ABOUT = "Projects and their omp agents, Orca-style. Click an agent to focus it, double-click to rename, "
	.. "right-click for more. Group headers collapse; + starts an agent in the project. Nothing runs without a click."

-- Class of the view root (chrome.css scopes the pane with `:has(.op-sidebar)`).
sidebar.ROOT_CLASS = "op-sidebar"
-- Id of the view root in a canvas (`main.<root key>`).
sidebar.ROOT_KEY = "projects"
sidebar.ROOT_ID = "main." .. sidebar.ROOT_KEY

-- Orca's project colors (same hex in both themes); classes `op-c-<name>`.
local PRESETS: { [string]: boolean } = {
	neutral = true,
	red = true,
	orange = true,
	yellow = true,
	green = true,
	teal = true,
	purple = true,
	pink = true,
}

-- The node builders, in plain Lua: they make exactly the tables `tern.ui.el` and `tern.ui.node` return (checked
-- live on Tern 0.9.28), without a native call per node, which made a draw of a few projects take 40-100 ms.
local function copy_props(p: { [string]: any }?, into: { [string]: any }): { [string]: any }
	if p then
		for k, v in p do
			into[k] = v
		end
	end
	return into
end
sidebar.PURE_UI = {
	el = function(tag: string, props: { [string]: any }?, children: { any }?): any
		local n: { [string]: any } = { k = "el", p = copy_props(props, { tag = tag }) }
		if children ~= nil and #children > 0 then
			n.c = children
		end
		return n
	end,
	node = function(k: string, props: { [string]: any }?, children: { any }?): any
		local n: { [string]: any } = { k = k }
		local p = copy_props(props, {})
		if next(p) ~= nil then
			n.p = p
		end
		if children ~= nil and #children > 0 then
			n.c = children
		end
		return n
	end,
}

local function lib(): any
	return sidebar.ui or sidebar.PURE_UI
end

local function act(name: string, value: (string | number)?): string
	if value == nil then
		return name
	end
	if type(value) == "number" then
		return string.format("%s=%d", name, value)
	end
	return name .. "=" .. value
end

-- Keys become id segments: keep them free of `.` and `/`, and distinct ids distinct (`_` escapes too).
local function key_of(prefix: string, s: string): string
	return prefix .. (string.gsub(s, "[^%w%-]", function(c: string): string
		return string.format("_%02x", string.byte(c))
	end))
end

local function pane_key(prefix: string, pane: number): string
	return string.format("%s%d", prefix, pane)
end

local function first_line(s: string?): string?
	if s == nil then
		return nil
	end
	local line = string.match(s, "^%s*([^\n]*)") or ""
	line = string.gsub(line, "%s+$", "")
	if line == "" then
		return nil
	end
	if #line > 160 then
		-- Cut on a code-point boundary: back up over UTF-8 continuation bytes.
		local n = 159
		while n > 0 and (string.byte(line, n + 1) or 0) >= 0x80 and (string.byte(line, n + 1) or 0) < 0xC0 do
			n -= 1
		end
		line = string.sub(line, 1, n) .. "…"
	end
	return line
end

-- Orca's short-time-ago: now, 5m, 3h, 2d.
function sidebar.ago(now: number?, t: number?): string?
	if now == nil or t == nil then
		return nil
	end
	local d = math.max(0, now - t)
	if d < 60 then
		return "now"
	elseif d < 3600 then
		return string.format("%dm", d // 60)
	elseif d < 86400 then
		return string.format("%dh", d // 3600)
	end
	return string.format("%dd", d // 86400)
end

-- Keycaps run together as one tooltip suffix ("⌘N").
local function chord(keys: { string }?): string
	if keys == nil or #keys == 0 then
		return ""
	end
	return "  " .. table.concat(keys)
end

-- Element helpers ------------------------------------------------------------

-- Nodes still allowed in this build (Tern caps a canvas at 2000); `build` resets it.
local nodes_left = math.huge
local NODE_BUDGET = 1800

local function el(tag: string, props: { [string]: any }, children: { any }?): any
	nodes_left -= 1
	return lib().el(tag, props, children)
end

local function icon_node(name: string): any
	nodes_left -= 1
	return lib().node("icon", { name = name })
end

local function span(class: string, text: string?, key: string?): any
	return el("span", { class = class, text = text, key = key })
end

local function icon(name: string, class: string?, key: string?): any
	return el("span", { class = "op-i " .. (class or ""), key = key or "i" }, {
		icon_node(name),
	})
end

-- A lucide glyph Tern lacks, drawn by sidebar.css as a mask (`op-g-<name>`).
local function glyph_mask(name: string, key: string?): any
	return span("op-g op-g-" .. name, nil, key or "i")
end

-- A 24px ghost icon button (20px with `op-sm`); `body` is its glyph node.
local function button(key: string, body: any, title: string?, action: string, extra: string?, menu: { any }?): any
	return el("button", {
		key = key,
		class = "op-ib " .. (extra or ""),
		title = title,
		actions = { click = action, menu = menu },
	}, { body })
end

-- Status ---------------------------------------------------------------------

-- An agent row's dot state: working | waiting | done | failed | interrupted | idle.
local function row_state(r: AgentRow): string
	if r.state == "working" then
		return "working"
	elseif r.state == "waiting_input" then
		return "waiting"
	elseif r.result ~= nil then
		return r.result
	elseif r.state == "exited" then
		return "done"
	end
	return "idle"
end

-- omp's subagent status → dot state.
local SUB_STATE: { [string]: string } = {
	running = "working",
	working = "working",
	waiting_input = "waiting",
	done = "done",
	failed = "failed",
	aborted = "interrupted",
}

local function sub_state(s: Subagent): string
	return SUB_STATE[s.status] or "idle"
end

local ROW_LABEL: { [string]: string } = {
	working = "Working",
	waiting = "Waiting for input",
	done = "Done",
	failed = "Failed",
	interrupted = "Interrupted",
	idle = "Idle",
}

local CARD_LABEL: { [string]: string } = {
	working = "Working",
	waiting = "Needs permission",
	failed = "Failed",
	interrupted = "Interrupted",
	done = "Done",
	active = "Active",
	inactive = "Inactive",
}

-- Most urgent first (Orca's rankWorktreeStatus, minus the hook-only states).
local CARD_ORDER = { "waiting", "failed", "working", "interrupted", "done", "active" }
-- Signal next to a collapsed child count: only states the parent's own dot can't say.
local SIGNAL_ORDER = { "waiting", "failed", "working", "interrupted" }

local function first_of(order: { string }, seen: { [string]: boolean }): string?
	for _, s in order do
		if seen[s] then
			return s
		end
	end
	return nil
end

-- Every dot state under `row` (excluding the row itself), into `seen`.
local function descendant_states(row: AgentRow, seen: { [string]: boolean })
	for _, c in row.spawned or {} do
		seen[row_state(c)] = true
		descendant_states(c, seen)
	end
	for _, s in row.internal or {} do
		seen[sub_state(s)] = true
	end
end

-- The card's status over its agent and every subagent inside it.
function sidebar.card_status(row: AgentRow): string
	if row.state == "sleeping" then
		return "inactive"
	end
	local seen: { [string]: boolean } = { [row_state(row)] = true }
	descendant_states(row, seen)
	-- A live agent with no turn outcome is Orca's `active`.
	if seen.idle then
		seen.active = true
	end
	return first_of(CARD_ORDER, seen) or "active"
end

-- Whether `pane` is a spawned descendant of `row`.
local function holds(row: AgentRow, pane: number?): boolean
	if pane == nil then
		return false
	end
	for _, c in row.spawned or {} do
		if c.pane == pane or holds(c, pane) then
			return true
		end
	end
	return false
end

-- Whether `row` or a spawned descendant is unread.
local function any_unread(snap: Snapshot, row: AgentRow): boolean
	if snap.unread == nil then
		return false
	end
	if snap.unread[row.pane] then
		return true
	end
	for _, c in row.spawned or {} do
		if any_unread(snap, c) then
			return true
		end
	end
	return false
end

-- A status glyph: "md" 12px box (cards), "sm" 10px box (rows).
local function glyph(state: string, size: string, label: string?): any
	local cls = "op-st op-st-" .. size .. " op-" .. state
	local inner: any
	if state == "working" then
		inner = span("op-spin", nil, "spin")
	elseif state == "waiting" then
		inner = icon("help")
	elseif state == "done" and size == "sm" then
		inner = span("op-ring", nil, "ring")
	else
		inner = span("op-dot", nil, "dot")
	end
	return el("span", { class = cls, key = "st", title = label }, { inner })
end

-- Pull requests -----------------------------------------------------------------

local CI_LABEL: { [string]: string } = { pass = "checks pass", fail = "checks fail", pending = "checks running" }
local REVIEW_MARK: { [string]: string } = { approved = "✓", changes = "✗", review = "•" }
local REVIEW_LABEL: { [string]: string } = { approved = "approved", changes = "changes requested", review = "review required" }

-- A PR's tooltip: "PR #12 · open · checks pass 3/3 · approved", its title, and the click's effect.
function sidebar.pr_title(pr: gh.Pr, stale: boolean?): string
	local parts = { string.format("PR #%d · %s", pr.n, pr.state) }
	if pr.ci then
		table.insert(parts, CI_LABEL[pr.ci] .. (if pr.checks then " " .. pr.checks else ""))
	end
	if pr.review then
		table.insert(parts, REVIEW_LABEL[pr.review])
	end
	if pr.conflicts then
		table.insert(parts, "conflicts")
	end
	return table.concat(parts, " · ") .. "\n" .. pr.title .. (if stale then "\n(stale: GitHub not reached lately)" else "") .. "\nClick to open on GitHub"
end

-- The badge: number and state, a CI dot (pass, fail, pending) and the review mark. `click` nil: inert (its row
-- carries the click).
local function pr_badge(pr: gh.Pr, key: string, stale: boolean?, click: boolean): any
	local kids: { any } = { span("op-pr-n", string.format("#%d %s", pr.n, pr.state), "n") }
	if pr.ci then
		table.insert(kids, span("op-ci op-ci-" .. pr.ci, nil, "ci"))
	end
	if pr.review then
		table.insert(kids, span("op-rv op-rv-" .. pr.review, REVIEW_MARK[pr.review], "rv"))
	end
	if pr.conflicts then
		table.insert(kids, span("op-pr-x", "!", "x"))
	end
	return el("span", {
		key = key,
		class = "op-pr op-pr-" .. pr.state .. (if stale then " op-stale" else ""),
		title = sidebar.pr_title(pr, stale),
		actions = if click then { click = act("open_url", pr.url) } else nil,
	}, kids)
end

-- "2 PRs · 1 issue" for a project's header; nil when there is nothing to count and nothing is wrong.
function sidebar.gh_counts(g: GhSnap): string?
	local parts: { string } = {}
	if #g.prs > 0 then
		table.insert(parts, string.format("%d PR%s", #g.prs, if #g.prs == 1 then "" else "s"))
	end
	if #g.issues > 0 then
		table.insert(parts, string.format("%d issue%s", #g.issues, if #g.issues == 1 then "" else "s"))
	end
	if g.stale and g.ok_at ~= nil then
		table.insert(parts, "stale")
	end
	return if #parts > 0 then table.concat(parts, " · ") else nil
end

-- At most this many PRs and issues each are listed; the rest are a "N more" row to the repository's page.
local GH_ROWS = 8

-- A project's "PRs & issues": a header row (chevron, counts, stale marker, refresh, open in browser) and, expanded,
-- one row per PR and issue.
local function gh_section(snap: Snapshot, ps: ProjectSnap, g: GhSnap): any
	local base = "https://github.com/" .. g.slug
	local status: string
	if g.busy then
		status = "refreshing…"
	elseif g.ok_at == nil then
		status = if g.error then "unavailable" else "loading…"
	elseif g.stale then
		status = "stale · " .. (sidebar.ago(snap.now, g.ok_at) or "")
	else
		status = sidebar.ago(snap.now, g.ok_at) or ""
	end
	local tip = g.slug .. (if g.error then "\nLast refresh failed: " .. g.error else "")
	local head_kids: { any } = {
		el("span", { key = "chev", class = "op-chev" }, { icon("chev") }),
		span("op-ghs-t", "PRs & issues", "t"),
		span("op-ghs-n", string.format("%d · %d", #g.prs, #g.issues), "n"),
		span("op-ghs-s" .. (if g.stale then " op-stale" else ""), status, "s"),
		el("div", { key = "acts", class = "op-ghs-acts" }, {
			el("button", { key = "refresh", class = "op-ib op-sm op-txt", title = "Refresh PRs and issues", actions = { click = act("gh_refresh", g.slug) } }, {
				span("op-txt-g", "↻", "g"),
			}),
			el("button", { key = "web", class = "op-ib op-sm op-txt", title = "Open " .. g.slug .. " pull requests in the browser", actions = { click = act("open_url", base .. "/pulls") } }, {
				span("op-txt-g", "↗", "g"),
			}),
		}),
	}
	local children: { any } = {
		el("div", { key = "head", class = "op-ghs-head", title = tip, actions = { click = act("toggle_prs", ps.project.id) } }, head_kids),
	}
	if g.open then
		local function more(key: string, n: number, what: string, url: string)
			children[#children + 1] = el("div", { key = key, class = "op-ghrow op-ghmore", actions = { click = act("open_url", url) } }, {
				span("op-ghrow-t", string.format("%d more %s on GitHub", n, what), "t"),
			})
		end
		for i, pr in g.prs do
			if i > GH_ROWS then
				more("prmore", #g.prs - GH_ROWS, "PRs", base .. "/pulls")
				break
			end
			-- Mine needs no word; a PR in the list only because a review is asked of the user says so.
			local why = if pr.asked and not pr.mine then "review asked" else nil
			local kids: { any } = { pr_badge(pr, "b", g.stale, false), span("op-ghrow-t", pr.title, "t") }
			if why then
				table.insert(kids, span("op-ghrow-m", why, "m"))
			end
			children[#children + 1] = el("div", {
				key = string.format("pr%d", pr.n),
				class = "op-ghrow",
				title = sidebar.pr_title(pr, g.stale),
				actions = { click = act("open_url", pr.url) },
			}, kids)
		end
		for i, it in g.issues do
			if i > GH_ROWS then
				more("ismore", #g.issues - GH_ROWS, "issues", base .. "/issues?q=is%3Aissue+is%3Aopen+assignee%3A%40me")
				break
			end
			children[#children + 1] = el("div", {
				key = string.format("is%d", it.n),
				class = "op-ghrow",
				title = string.format("Issue #%d\n%s\nClick to open on GitHub", it.n, it.title),
				actions = { click = act("open_url", it.url) },
			}, {
				span("op-pr op-issue", string.format("#%d", it.n), "b"),
				span("op-ghrow-t", it.title, "t"),
			})
		end
		if #g.prs == 0 and #g.issues == 0 then
			children[#children + 1] = el("div", { key = "none", class = "op-ghrow op-ghnone" }, {
				span("op-ghrow-t", if g.ok_at then "No open PRs or issues for you" else "Nothing yet", "t"),
			})
		end
	end
	return el("div", { key = "prs", class = "op-ghs" .. (if g.open then "" else " collapsed") }, children)
end

-- Menus ----------------------------------------------------------------------

type Ctx = { snap: Snapshot, project: Project? }

-- The workspace menu, shared by a card and every row inside it.
local function card_menu(ctx: Ctx, row: AgentRow): { any }
	local pane = row.pane
	if row.state == "sleeping" then
		return {
			{ id = act("copy_path", pane), label = "Copy Path", icon = "copy" },
			"-",
			{ id = act("delete", pane), label = "Delete", icon = "trash", danger = true },
		}
	end
	-- Matches the card's own unread look (and toggle_unread, which clears the spawned descendants too).
	local unread = any_unread(ctx.snap, row)
	-- A remote project's folder can't be shown here: its item opens a shell on that host instead.
	local host = if ctx.project then ctx.project.host else nil
	local open = if host then "Open terminal on " .. (string.match(host, "@([^@]+)$") or host) else "Open in Finder"
	local menu: { any } = {
		{ id = act("rename", pane), label = "Rename", icon = "doc" },
		{ id = act("open_finder", pane), label = open, icon = if host then "terminal" else "folder-open" },
		{ id = act("copy_path", pane), label = "Copy Path", icon = "copy" },
		{ id = act("copy_name", pane), label = "Copy Worktree Name", icon = "copy" },
		"-",
		{ id = act("toggle_pin", pane), label = if row.pinned then "Unpin" else "Pin", icon = "pin" },
		{ id = act("toggle_unread", pane), label = if unread then "Mark Read" else "Mark Unread", icon = "bell" },
		"-",
		{ id = act("new_subagent", pane), label = "New Child Agent…", icon = "corner-down-right" },
		"-",
		{ id = act("sleep", pane), label = "Sleep", icon = "moon" },
	}
	if row.primary and ctx.project ~= nil then
		table.insert(menu, { id = act("remove_project", ctx.project.id), label = "Remove Project", icon = "trash", danger = true })
	elseif not row.primary then
		table.insert(menu, { id = act("delete", pane), label = "Delete", icon = "trash", danger = true })
	end
	return menu
end

local function project_menu(snap: Snapshot, ps: ProjectSnap): { any }
	local id = ps.project.id
	local menu: { any } = {
		{ id = act("project_settings", id), label = "Project Settings", icon = "sliders" },
		{ id = act("project_icon", id), label = "Change Project Icon", icon = "palette" },
		{ id = act("new_group", id), label = "New group from project", icon = "folder-plus" },
	}
	if snap.groups ~= nil and #snap.groups > 0 then
		table.insert(menu, { id = act("move_to_group", id), label = "Move to group…", icon = "folder-go" })
	end
	if ps.group ~= nil then
		table.insert(menu, { id = act("ungroup", id), label = "Remove from group", icon = "folder-minus" })
	end
	table.insert(menu, { id = act("open_project", id), label = "Open session", icon = "folder-open" })
	table.insert(menu, "-")
	table.insert(menu, { id = act("remove_project", id), label = "Remove Project", icon = "trash", danger = true })
	return menu
end

local function group_menu(g: Group): { any }
	return {
		{ id = act("rename_group", g.id), label = "Rename group", icon = "doc" },
		{ id = act("delete_group", g.id), label = "Delete group", icon = "trash", danger = true },
	}
end

-- Agent rows -----------------------------------------------------------------

type RowOpts = {
	identity: boolean?,
	on: boolean?,
	unread: boolean?,
	model: string?,
	time: string?,
	-- Child disclosure: count, signal state, open, toggle action.
	kids: { n: number, signal: string?, open: boolean, action: string }?,
	click: string,
	menu: { any },
}

-- One 24px compact row: dot, OMP glyph, lead - trail, model, +N, time or chevron.
local function row_el(key: string, state: string, lead: string, trail: string?, o: RowOpts): any
	local cls = "op-row"
	if o.on then
		cls ..= " on"
	end
	if o.unread then
		cls ..= " unread"
	end
	local text: { any } = { span("op-lead", lead, "lead") }
	if trail ~= nil then
		text[2] = span("op-trail", " - " .. trail, "trail")
	end
	local children: { any } = { glyph(state, "sm", ROW_LABEL[state]) }
	if o.identity then
		table.insert(children, el("span", { class = "op-who", key = "who", title = "OMP" }))
	end
	table.insert(children, el("span", {
		class = "op-text",
		key = "text",
		title = if trail then lead .. " - " .. trail else lead,
	}, text))
	if o.model ~= nil then
		table.insert(children, el("span", { class = "op-model", key = "model", text = o.model, title = o.model }))
	end
	local kids = o.kids
	if kids ~= nil and not kids.open then
		local parts: { any } = {}
		if kids.signal ~= nil then
			parts[1] = glyph(kids.signal, "sm", ROW_LABEL[kids.signal])
		end
		table.insert(parts, span("op-kn", "+" .. tostring(kids.n), "n"))
		table.insert(children, el("span", { class = "op-kids", key = "kids" }, parts))
	end
	if kids ~= nil then
		local slot: { any } = {}
		if o.time ~= nil then
			slot[1] = span("op-time", o.time, "time")
		end
		table.insert(slot, el("button", {
			key = "chev",
			class = "op-ib op-disc-b",
			title = string.format("%s %d child agent%s", if kids.open then "Hide" else "Show", kids.n, if kids.n == 1 then "" else "s"),
			actions = { click = kids.action },
		}, { icon("chev") }))
		table.insert(children, el("span", { class = "op-disc" .. (if kids.open then " open" else ""), key = "disc" }, slot))
	elseif o.time ~= nil then
		table.insert(children, span("op-time", o.time, "time"))
	end
	return el("div", { key = key, class = cls, actions = { click = o.click, menu = o.menu } }, children)
end

-- The time label: since the turn ended when done/failed, else since start.
local function row_time(snap: Snapshot, r: AgentRow, state: string): string?
	if (state == "done" or state == "failed") and r.done_at ~= nil then
		return sidebar.ago(snap.now, r.done_at)
	end
	return sidebar.ago(snap.now, r.started)
end

local function show_models(snap: Snapshot): boolean
	return snap.show_models ~= false
end

type Child = { idle: boolean, build: () -> { any } }

-- Appends `row` (and, when open, its children in a rail) to `out`. `menu` is the card's.
local function agent_rows(snap: Snapshot, row: AgentRow, lead: string, trail: string?, menu: { any }, out: { any })
	local state = row_state(row)
	local nkids = #(row.spawned or {}) + #(row.internal or {})
	-- Open child lists stay collapsed once the node budget couldn't hold their rows.
	local open = nkids > 0 and snap.expanded ~= nil and snap.expanded[row.pane] == true and nodes_left > nkids * 12 + 40
	local kids = nil
	if nkids > 0 then
		local seen: { [string]: boolean } = {}
		descendant_states(row, seen)
		kids = {
			n = nkids,
			signal = first_of(SIGNAL_ORDER, seen),
			open = open,
			action = act("toggle_kids", row.pane),
		}
	end
	out[#out + 1] = row_el(pane_key("a_", row.pane), state, lead, trail, {
		identity = true,
		-- A collapsed list hands its focused descendant's highlight to the parent.
		on = snap.active == row.pane or (not open and holds(row, snap.active)),
		unread = snap.unread ~= nil and snap.unread[row.pane] == true,
		model = if show_models(snap) then row.model else nil,
		time = row_time(snap, row, state),
		kids = kids,
		click = act("focus", row.pane),
		menu = menu,
	})
	if not open then
		return
	end

	local children: { Child } = {}
	for _, c in row.spawned or {} do
		local cstate = row_state(c)
		table.insert(children, {
			idle = cstate == "idle",
			build = function()
				local nested: { any } = {}
				local ctrail = if cstate == "working" or cstate == "waiting" then c.tool else nil
				agent_rows(snap, c, c.title, ctrail or first_line(c.last_message) or "OMP", menu, nested)
				return nested
			end,
		})
	end
	for _, s in row.internal or {} do
		local sstate = sub_state(s)
		table.insert(children, {
			idle = sstate == "idle",
			build = function()
				local strail = if s.tool then s.tool .. (if s.intent then ": " .. s.intent else "") else first_line(s.task)
				return {
					row_el(key_of("s_", s.id), sstate, s.name, strail, {
						model = if show_models(snap) then s.model else nil,
						time = sidebar.ago(snap.now, s.first_seen),
						click = act("focus", row.pane),
						menu = menu,
					}),
				}
			end,
		})
	end

	local idle = 0
	for _, c in children do
		if c.idle then
			idle += 1
		end
	end
	local fold = idle >= 2
	local rail: { any } = {}
	local function add(c: Child)
		for _, n in c.build() do
			rail[#rail + 1] = n
		end
	end
	for _, c in children do
		if not (fold and c.idle) then
			add(c)
		end
	end
	if fold then
		local idle_open = snap.idle_open ~= nil and snap.idle_open[row.pane] == true
		rail[#rail + 1] = el("div", {
			key = "idle",
			class = "op-row op-idle" .. (if idle_open then " open" else ""),
			title = string.format("%s %d idle child agents", if idle_open then "Hide" else "Show", idle),
			actions = { click = act("toggle_idle", row.pane), menu = menu },
		}, {
			glyph("idle", "sm"),
			span("op-lead", string.format("%d idle", idle), "lead"),
			icon("chev", "op-idle-chev", "chev"),
		})
		if idle_open then
			for _, c in children do
				if c.idle then
					add(c)
				end
			end
		end
	end
	out[#out + 1] = el("div", { key = pane_key("l_", row.pane), class = "op-lineage" }, rail)
end

-- Lead and trail of an agent's own (top) row.
local function top_text(r: AgentRow): (string, string)
	local state = row_state(r)
	local trail = if state == "working" or state == "waiting" then r.tool else nil
	return first_line(r.prompt) or r.title, trail or first_line(r.last_message) or "OMP"
end

-- Workspace card (one per top-level agent) -------------------------------------

-- Stands in for Orca's identity hovercard: the title, then the branch (or folder) unless it repeats the title.
local function identity_title(row: AgentRow): string
	local id = row.branch or row.cwd
	return if id == "" or id == row.title then row.title else row.title .. "\n" .. id
end

-- The lane glyph: Moon while sleeping; a quiet card with a branch shows the branch glyph.
local function lane_glyph(row: AgentRow, status: string): any
	if status == "inactive" and row.state == "sleeping" then
		return icon("moon", "op-lg op-lg-moon", "st")
	end
	if (status == "active" or status == "done") and row.branch ~= nil and row.branch ~= "" then
		return icon("branch", "op-lg op-lg-branch", "st")
	end
	-- Orca gives tooltips to the states its lane dot alone can't say.
	local label = if status == "active" or status == "inactive" then nil else CARD_LABEL[status]
	return glyph(status, "md", label)
end

local function card(ctx: Ctx, row: AgentRow): any
	local snap = ctx.snap
	local sleeping = row.state == "sleeping"
	local unread = any_unread(snap, row)
	local status = sidebar.card_status(row)
	local cls = "op-card"
	if snap.active == row.pane or holds(row, snap.active) then
		cls ..= " on"
	end
	if unread then
		cls ..= " unread"
	end
	if sleeping then
		cls ..= " sleeping"
	end
	if row.deleting then
		cls ..= " deleting"
	end
	if snap.reveal == row.pane then
		cls ..= " reveal"
	end
	local menu = card_menu(ctx, row)

	local lane_kids: { any } = { lane_glyph(row, status) }
	-- Working and waiting already own the lane; the unread dot joins only quiet glyphs.
	if unread and status ~= "working" and status ~= "waiting" then
		lane_kids[2] = span("op-udot", nil, "ud")
	end
	local lane = el("div", { key = "lane", class = "op-lane" }, lane_kids)

	local line: { any } = { span("op-title", row.title, "title") }
	if row.primary then
		line[2] = el("span", { class = "op-primary", key = "primary", title = "Primary worktree (original clone directory)" }, {
			icon("home"),
		})
	end
	local stack: { any } = {
		el("div", { key = "line", class = "op-line", title = identity_title(row) }, line),
	}

	local meta: any = nil
	if row.detached ~= nil then
		meta = el("span", { key = "detached", class = "op-detached", title = "Detached HEAD at " .. row.detached }, {
			icon("commit"),
			span("op-detached-t", row.detached, "t"),
		})
	elseif snap.show_branch and row.branch ~= nil then
		meta = span("op-meta-t", row.branch, "t")
	end
	if row.pr ~= nil then
		local badge = pr_badge(row.pr :: gh.Pr, "pr", row.pr_stale, true)
		meta = if meta ~= nil then { meta, badge } else { badge }
	elseif meta ~= nil then
		meta = { meta }
	end
	if meta ~= nil then
		table.insert(stack, el("div", { key = "meta", class = "op-meta" }, meta))
	end

	if snap.show_agents ~= false and not sleeping then
		local agents: { any } = {}
		local lead, trail = top_text(row)
		agent_rows(snap, row, lead, trail, menu, agents)
		table.insert(stack, el("div", { key = "agents", class = "op-agents" .. (if meta then "" else " op-tight") }, agents))
	end
	if #stack == 1 then
		cls ..= " op-solo"
	end

	local children: { any } = {
		el("div", { key = "row", class = "op-pc" }, {
			lane,
			el("div", { key = "stack", class = "op-stack" }, stack),
		}),
	}
	local actions: { [string]: any }? = nil
	if row.deleting then
		children[2] = el("div", { key = "over", class = "op-over" }, {
			el("span", { key = "pill", class = "op-over-p" }, {
				span("op-spin", nil, "spin"),
				span("op-over-t", "Deleting…", "t"),
			}),
		})
	elseif sleeping then
		actions = { click = act("wake", row.pane), menu = menu }
	else
		actions = { click = act("focus", row.pane), dblclick = act("rename", row.pane), menu = menu }
	end
	return el("div", { key = pane_key("c_", row.pane), class = cls, actions = actions }, children)
end

-- Groups -----------------------------------------------------------------------

local function collapsed(snap: Snapshot, key: string): boolean
	return snap.collapsed ~= nil and snap.collapsed[key] == true
end

-- The project's icon: a Tern icon or an emoji, in its color.
local function project_icon(p: Project): any
	-- Presets only: Tern's `el` drops inline `style` (and `attrs.style`), so a hex color can't be drawn.
	local color = if p.color ~= nil and PRESETS[p.color] then p.color else "neutral"
	local props: { [string]: any } = { key = "icon", class = "op-gicon op-c-" .. color }
	local ic = p.icon
	if ic ~= nil and ic.kind == "emoji" and ic.emoji ~= nil then
		props.class ..= " op-emoji"
		props.text = ic.emoji
		return el("span", props)
	end
	local name = if ic ~= nil and ic.kind == "icon" and ic.name ~= nil then ic.name else "folder"
	return el("span", props, { icon_node(name) })
end

-- A section header row: icon, name, hover actions. `toggle` nil: static.
local function header(icon_node: any, name: string, opts: {
	toggle: string?,
	chevron: boolean,
	menu: { any }?,
	more: string?,
	more_title: string?,
	new: string?,
	new_title: string?,
	extra: string?,
}): any
	local acts: { any } = {}
	if opts.chevron then
		acts[1] = el("span", { key = "chev", class = "op-chev" }, { icon("chev") })
	end
	if opts.more ~= nil then
		table.insert(acts, button("more", icon("more"), opts.more_title, opts.more, "op-sm", opts.menu))
	end
	if opts.new ~= nil then
		table.insert(acts, button("new", icon("plus"), opts.new_title, opts.new, "op-sm op-plus"))
	end
	local children: { any } = { icon_node, span("op-gname", name, "name") }
	if #acts > 0 then
		children[3] = el("div", { key = "acts", class = "op-gacts" }, acts)
	end
	local actions = if opts.toggle then { click = opts.toggle, menu = opts.menu } else nil
	return el("div", {
		key = "head",
		class = "op-ghead" .. (if opts.toggle then "" else " op-static") .. (if opts.extra then " " .. opts.extra else ""),
		actions = actions,
	}, children)
end

local function project_section(snap: Snapshot, ps: ProjectSnap): any
	local p = ps.project
	local shut = collapsed(snap, p.id)
	local menu = project_menu(snap, ps)
	local head = header(project_icon(p), p.name, {
		toggle = act("toggle_group", p.id),
		chevron = #ps.agents > 0 or ps.gh ~= nil,
		menu = menu,
		more = act("project_menu", p.id),
		more_title = "Project actions",
		new = act("new_agent", p.id),
		new_title = "New agent in " .. p.name,
	})
	local counts = if ps.gh then sidebar.gh_counts(ps.gh :: GhSnap) else nil
	if counts ~= nil then
		-- After the name, before the hover actions.
		table.insert(head.c, 3, span("op-ghc" .. (if (ps.gh :: GhSnap).stale then " op-stale" else ""), counts, "ghc"))
	end
	if ps.host ~= nil then
		-- Right after the name: which machine the project's folder and agents are on.
		table.insert(head.c, 3, span("op-fb op-host", ps.host :: string, "host"))
	end
	local children: { any } = { head }
	if not shut then
		local ctx: Ctx = { snap = snap, project = p }
		for _, row in ps.agents do
			if nodes_left > 60 then
				children[#children + 1] = card(ctx, row)
			end
		end
		if ps.gh ~= nil and nodes_left > 80 then
			children[#children + 1] = gh_section(snap, ps, ps.gh :: GhSnap)
		end
	end
	return el("div", {
		key = key_of("g_", p.id),
		class = "op-group" .. (if shut then " collapsed" else "") .. (if ps.group then " op-nested" else ""),
	}, children)
end

local function project_group(snap: Snapshot, g: Group, sections: { any }): any
	local key = "group:" .. g.id
	local shut = collapsed(snap, key)
	local menu = group_menu(g)
	local children: { any } = {
		header(glyph_mask("folder-tree", "icon"), g.name, {
			toggle = act("toggle_group", key),
			chevron = #sections > 0,
			menu = menu,
			more = act("group_menu", g.id),
			extra = "op-pghead",
		}),
	}
	if not shut then
		for _, s in sections do
			children[#children + 1] = s
		end
	end
	return el("div", {
		key = key_of("pg_", g.id),
		class = "op-pgroup" .. (if shut then " collapsed" else ""),
	}, children)
end

-- The row's project, from the id the controller stamps on it.
local function project_for(snap: Snapshot, row: AgentRow): Project?
	if row.project == nil then
		return nil
	end
	for _, ps in snap.projects or {} do
		if ps.project.id == row.project then
			return ps.project
		end
	end
	return nil
end

-- A non-project section (Pinned, All, Unassigned) holding cards.
local function card_section(snap: Snapshot, key: string, icon_name: string, name: string, rows: { AgentRow }, toggle: string?): any
	local shut = toggle ~= nil and collapsed(snap, key)
	local children: { any } = {
		header(el("span", { key = "icon", class = "op-gicon op-c-fg" }, { icon_node(icon_name) }), name, {
			toggle = toggle,
			chevron = toggle ~= nil and #rows > 0,
		}),
	}
	if not shut then
		for _, row in rows do
			if nodes_left > 60 then
				children[#children + 1] = card({ snap = snap, project = project_for(snap, row) }, row)
			end
		end
	end
	return el("div", { key = key, class = "op-group" .. (if shut then " collapsed" else "") }, children)
end

-- Automations ------------------------------------------------------------------

-- A run status's label (automate.luau's statuses).
local AUTO_LABEL: { [string]: string } = {
	queued = "Queued",
	precheck = "Precheck",
	waiting_window = "Starting",
	running = "Running",
	done = "Done",
	failed = "Failed",
	timed_out = "Timed out",
	canceled = "Canceled",
	lost = "Lost",
	skipped_missed = "Missed",
	skipped_busy = "Skipped (busy)",
	skipped_precheck = "Skipped (precheck)",
}
sidebar.AUTO_LABEL = AUTO_LABEL

local AUTO_FINAL: { [string]: boolean } = {
	done = true,
	failed = true,
	timed_out = true,
	canceled = true,
	lost = true,
	skipped_missed = true,
	skipped_busy = true,
	skipped_precheck = true,
}

function sidebar.auto_active(status: string): boolean
	return not AUTO_FINAL[status]
end

-- A run status → the row's dot.
local function auto_glyph(status: string): string
	if not AUTO_FINAL[status] then
		return "working"
	elseif status == "done" then
		return "done"
	elseif status == "failed" or status == "timed_out" or status == "lost" then
		return "failed"
	end
	return "interrupted"
end

-- When the next run is: "in 4m", "14:30" (today), "Tue 09:00" (later).
function sidebar.when(now: number, t: number): string
	local d = t - now
	if d < 60 then
		return "in <1m"
	elseif d < 3600 then
		return string.format("in %dm", math.ceil(d / 60))
	end
	local today = os.date("%Y%m%d", now)
	if os.date("%Y%m%d", t) == today then
		return os.date("%H:%M", t) :: string
	end
	return os.date("%a %H:%M", t) :: string
end

local function auto_row(snap: Snapshot, a: AutoRow): any
	local now = snap.now or os.time()
	local r = a.active or a.last
	local state = if not a.enabled and a.active == nil then "inactive" elseif r then auto_glyph(r.status) else "idle"
	local plan = if a.enabled
		then (if a.next_at then "next " .. sidebar.when(now, a.next_at :: number) else "scheduling")
		else "paused"
	local lead: string
	local tip = { a.name, a.label .. " · " .. plan .. " · " .. (if a.run_in == "pane" then "in a pane" else "headless") }
	if a.active then
		local act_run = a.active :: AutoRun
		lead = (AUTO_LABEL[act_run.status] or act_run.status) .. (if act_run.note then " · " .. act_run.note else "")
	elseif a.last then
		local l = a.last :: AutoRun
		lead = (AUTO_LABEL[l.status] or l.status) .. (if l.count and l.count > 1 then string.format(" ×%d", l.count) else "") .. (if l.summary then ": " .. (first_line(l.summary) or "") else "")
	else
		lead = "No runs yet"
	end
	table.insert(tip, lead)
	if r and r.summary and r.summary ~= "" then
		table.insert(tip, r.summary :: string)
	end
	table.insert(tip, "Click for its runs; right-click for more")
	local ago = if r then sidebar.ago(now, r.ended or r.started or r.scheduled_for) else nil
	local menu: { any } = {
		{ id = act("auto_run", a.id), label = "Run now", icon = "rocket" },
		{ id = act("auto_toggle", a.id), label = if a.enabled then "Pause" else "Enable", icon = "settings" },
		{ id = act("auto_open", a.id), label = "Open latest output", icon = "doc" },
		{ id = act("auto_runs", a.id), label = "Runs…", icon = "list" },
		{ id = act("auto_edit"), label = "Edit automations.json", icon = "doc" },
	}
	local acts: { any } = {
		el("button", { key = "run", class = "op-ib op-sm op-txt", title = "Run now", actions = { click = act("auto_run", a.id) } }, {
			span("op-txt-g", "▶", "g"),
		}),
		el("button", { key = "tog", class = "op-ib op-sm op-txt", title = if a.enabled then "Pause" else "Enable", actions = { click = act("auto_toggle", a.id) } }, {
			span("op-txt-g", if a.enabled then "⏸" else "⏵", "g"),
		}),
	}
	if r and (r.out or r.pane) then
		table.insert(acts, el("button", { key = "open", class = "op-ib op-sm op-txt", title = "Open latest output", actions = { click = act("auto_open", a.id) } }, {
			span("op-txt-g", "↗", "g"),
		}))
	end
	local last_kids: { any } = { glyph(state, "sm"), span("op-auto-l", lead, "l") }
	if ago then
		table.insert(last_kids, span("op-time", ago, "time"))
	end
	return el("div", {
		key = key_of("a_", a.id),
		class = "op-auto" .. (if a.enabled then "" else " op-off") .. (if a.active then " op-run" else ""),
		title = table.concat(tip, "\n"),
		actions = { click = act("auto_runs", a.id), menu = menu },
	}, {
		el("div", { key = "top", class = "op-auto-top" }, {
			span("op-auto-n", a.name, "n"),
			span("op-auto-s", plan .. " · " .. a.label, "s"),
			el("div", { key = "acts", class = "op-auto-acts" }, acts),
		}),
		el("div", { key = "last", class = "op-auto-last" }, last_kids),
	})
end

-- The Automations section: header (counts, edit file, new), problems in the file, one row per automation.
local function autos_section(snap: Snapshot, s: AutoSnap): any
	local head_node = header(el("span", { key = "icon", class = "op-gicon op-c-fg" }, { icon_node("clock") }), "Automations", {
		toggle = act("toggle_group", "automations"),
		chevron = true,
		more = act("auto_edit"),
		more_title = "Edit automations.json",
		new = act("auto_new"),
		new_title = "New automation",
	})
	local n = #s.list
	if n > 0 then
		table.insert(head_node.c, 3, span("op-fsum", if s.running > 0 then string.format("%d · %d running", n, s.running) else tostring(n), "sum"))
	end
	local children: { any } = { head_node }
	if s.open then
		for i, e in s.errors do
			if i > 3 then
				break
			end
			children[#children + 1] = el("div", { key = string.format("err%d", i), class = "op-auto-err", title = e }, {
				span("op-auto-l", e, "t"),
			})
		end
		for _, a in s.list do
			if nodes_left > 40 then
				children[#children + 1] = auto_row(snap, a)
			end
		end
		if n == 0 and #s.errors == 0 then
			children[#children + 1] = el("div", { key = "none", class = "op-ghrow op-ghnone", actions = { click = act("auto_new") } }, {
				span("op-ghrow-t", "No automations: + adds one", "t"),
			})
		end
	end
	return el("div", { key = "autos", class = "op-group op-autos" .. (if s.open then "" else " collapsed") }, children)
end

local function workspaces(snap: Snapshot): { any }
	local list: { any } = {}
	local pinned = snap.pinned or {}
	if #pinned > 0 then
		list[#list + 1] = card_section(snap, "pinned", "pin", "Pinned", pinned, act("toggle_group", "pinned"))
	end
	if snap.group_by == "none" then
		local all: { AgentRow } = {}
		for _, ps in snap.projects or {} do
			for _, row in ps.agents do
				table.insert(all, row)
			end
		end
		for _, row in snap.unassigned or {} do
			table.insert(all, row)
		end
		if #all > 0 or #(snap.projects or {}) > 0 then
			list[#list + 1] = card_section(snap, "all", "list", "All", all, nil)
		end
		return list
	end

	-- Orca's order: every group in its saved order (`snap.groups`, empty ones as a bare header; without it, the
	-- order the runs arrive in), each holding its projects, then the ungrouped projects.
	local sections: { [string]: { any } } = {}
	local order: { Group } = {}
	for _, g in snap.groups or {} do
		sections[g.id] = {}
		table.insert(order, g)
	end
	local ungrouped: { any } = {}
	for _, ps in snap.projects or {} do
		local g = ps.group
		if g == nil then
			table.insert(ungrouped, project_section(snap, ps))
		else
			if sections[g.id] == nil then
				sections[g.id] = {}
				table.insert(order, g)
			end
			table.insert(sections[g.id], project_section(snap, ps))
		end
	end
	for _, g in order do
		list[#list + 1] = project_group(snap, g, sections[g.id])
	end
	for _, s in ungrouped do
		list[#list + 1] = s
	end
	local unassigned = snap.unassigned or {}
	if #unassigned > 0 then
		list[#list + 1] = card_section(snap, "unassigned", "terminal", "Unassigned", unassigned, nil)
	end
	return list
end

-- Activity view ----------------------------------------------------------------

local BUCKETS = {
	{ key = "needs", label = "Needs you", dot = "waiting" },
	{ key = "working", label = "Working", dot = "working" },
	{ key = "done", label = "Done", dot = "done" },
	{ key = "idle", label = "Idle", dot = "idle" },
}

local function bucket_of(state: string): string
	if state == "waiting" then
		return "needs"
	elseif state == "working" then
		return "working"
	elseif state == "done" or state == "failed" or state == "interrupted" then
		return "done"
	end
	return "idle"
end

local function activity(snap: Snapshot): { any }
	local rows: { [string]: { any } } = { needs = {}, working = {}, done = {}, idle = {} }
	local function add(ctx: Ctx, r: AgentRow, menu: { any }, where: string?)
		if nodes_left < 40 then
			return
		end
		-- A sleeping agent is idle whatever its last turn did.
		local state = if r.state == "sleeping" then "idle" else row_state(r)
		table.insert(rows[bucket_of(state)], row_el(pane_key("a_", r.pane), state, first_line(r.prompt) or r.title, where, {
			identity = true,
			on = snap.active == r.pane,
			unread = snap.unread ~= nil and snap.unread[r.pane] == true,
			model = if show_models(snap) then r.model else nil,
			time = row_time(snap, r, state),
			click = act(if r.state == "sleeping" then "wake" else "focus", r.pane),
			menu = menu,
		}))
		for _, c in r.spawned or {} do
			add(ctx, c, menu, where)
		end
	end
	local function add_card(r: AgentRow)
		local ctx: Ctx = { snap = snap, project = project_for(snap, r) }
		add(ctx, r, card_menu(ctx, r), if ctx.project then ctx.project.name else nil)
	end
	for _, ps in snap.projects or {} do
		for _, r in ps.agents do
			add_card(r)
		end
	end
	for _, r in snap.pinned or {} do
		add_card(r)
	end
	for _, r in snap.unassigned or {} do
		add_card(r)
	end
	local out: { any } = {}
	for _, b in BUCKETS do
		local list = rows[b.key]
		if #list > 0 then
			local children: { any } = {
				el("div", { key = "head", class = "op-ahead" }, {
					glyph(b.dot, "sm"),
					span("op-ahead-t", b.label, "label"),
					span("op-ahead-n", tostring(#list), "n"),
				}),
			}
			for _, r in list do
				children[#children + 1] = r
			end
			out[#out + 1] = el("div", { key = "b_" .. b.key, class = "op-abucket" }, children)
		end
	end
	if #out == 0 then
		out[1] = el("div", { key = "empty", class = "op-empty" }, { span("op-empty-t", "No agents running", "t") })
	end
	return out
end

-- Shell ------------------------------------------------------------------------

-- Agents needing input and working, all projects.
local function counts(snap: Snapshot): (number, number)
	local waiting, working = 0, 0
	local function go(rows: { AgentRow }?)
		for _, r in rows or {} do
			if r.state == "waiting_input" then
				waiting += 1
			elseif r.state == "working" then
				working += 1
			end
			go(r.spawned)
		end
	end
	for _, ps in snap.projects or {} do
		go(ps.agents)
	end
	go(snap.pinned)
	go(snap.unassigned)
	return snap.waiting or waiting, working
end

local function search_pill(snap: Snapshot): any
	local caps: { any } = {}
	for i, k in (snap.keys and snap.keys.search) or {} do
		caps[i] = span("op-kc", k, string.format("k%d", i))
	end
	local children: { any } = { icon("search"), span("op-search-t", "Search", "label") }
	if #caps > 0 then
		children[3] = el("span", { key = "keys", class = "op-keys" }, caps)
	end
	return el("div", { key = "search", class = "op-search", actions = { click = act("search") } }, children)
end

local function head(snap: Snapshot): any
	local agents_view = snap.body == "agents"
	local waiting, working = counts(snap)
	local projects = snap.projects or {}

	local signal: any
	if waiting > 0 then
		signal = el("span", { key = "sig", class = "op-bsig op-q" }, { icon("help") })
	else
		signal = span("op-bsig " .. (if working > 0 then "op-w" else "op-idle"), nil, "sig")
	end
	local n = if waiting > 0 then waiting else working
	local bell = el("button", {
		key = "bell",
		class = "op-ib op-bell" .. (if agents_view then " on" else ""),
		title = if agents_view then "Turn off activity view" else "View activity",
		actions = { click = act("activity") },
	}, {
		el("span", { key = "box", class = "op-bbox" }, {
			icon("bell"),
			signal,
			span("op-bn" .. (if n > 99 then " op-squeeze" else ""), if n > 99 then "99+" else tostring(n), "n"),
		}),
	})

	local acts: { any } = { bell }
	if not agents_view then
		local filters = snap.filters or 0
		local body: { any } = { icon("sliders") }
		if filters > 0 then
			body[2] = span("op-fbadge", tostring(filters), "badge")
		end
		table.insert(acts, el("button", {
			key = "options",
			class = "op-ib",
			title = if filters > 0
				then string.format("Workspace options (%d filter%s)", filters, if filters == 1 then "" else "s")
				else "Workspace options",
			actions = { click = act("options") },
		}, body))
	end
	table.insert(acts, button("add", icon("folder-plus"), "Add project", act("add_project")))
	local current: string? = nil
	for _, ps in projects do
		if ps.current then
			current = ps.project.id
		end
	end
	-- No project: Add project first; else the current project, or window.luau's picker.
	table.insert(acts, button(
		"new",
		icon("plus"),
		"New agent" .. chord(snap.keys and snap.keys.new_agent),
		if #projects == 0 then act("add_project") else act("new_agent", current)
	))

	local children: { any } = {
		span("op-head-t", if snap.group_by == "none" then "Workspaces" else "Projects", "title"),
	}
	if not agents_view and #projects > 0 then
		local all = true
		for _, ps in projects do
			if not collapsed(snap, ps.project.id) then
				all = false
			end
		end
		children[2] = button(
			"collapse",
			glyph_mask(if all then "chevrons-up-down" else "chevrons-down-up"),
			(if all then "Expand all projects" else "Collapse all projects") .. chord(snap.keys and snap.keys.collapse_all),
			act("collapse_all"),
			"op-collapse"
		)
	end
	children[#children + 1] = el("div", { key = "acts", class = "op-head-acts" }, acts)
	return el("div", { key = "head", class = "op-head" }, children)
end

local function footer(): any
	return el("div", { key = "footer", class = "op-footer" }, {
		el("div", { key = "l", class = "op-fgroup" }, {
			button("settings", icon("gear"), "Settings", act("settings")),
			button("help", icon("help"), "Help", act("help")),
		}),
		el("div", { key = "r", class = "op-fgroup" }, {
			button("reveal", glyph_mask("crosshair"), "Reveal active workspace", act("reveal")),
		}),
	})
end

-- The canvas view and dock for a snapshot.
function sidebar.build(snap: Snapshot): { view: any, dock: any }
	nodes_left = NODE_BUDGET
	local list: { any }
	if snap.body == "agents" then
		list = activity(snap)
	else
		list = workspaces(snap)
		if #list == 0 then
			list[1] = el("div", { key = "empty", class = "op-empty" }, {
				span("op-empty-t", "No projects yet", "t"),
				el("button", { key = "add", class = "op-empty-b", actions = { click = act("add_project") } }, {
					icon("folder-plus"),
					span("op-empty-bt", "Add project", "t"),
				}),
			})
		end
		if snap.autos ~= nil then
			list[#list + 1] = autos_section(snap, snap.autos :: AutoSnap)
		end
	end
	local view = el("div", { key = sidebar.ROOT_KEY, class = sidebar.ROOT_CLASS }, {
		el("div", { key = "nav", class = "op-nav" }, { search_pill(snap) }),
		head(snap),
		el("div", { key = "list", class = "op-list" .. (if snap.body == "agents" then " op-activity" else "") }, list),
	})
	return { view = view, dock = footer() }
end

-- A sidebar canvas found in the window: its pane, the tab holding it (nil when parked or detached) and whether
-- it is parked.
export type CanvasSeen = { pane: number, tab: number?, parked: boolean? }

-- Which one sidebar canvas to keep when the window holds several (a relaunched window or a reload that opened
-- another): the one this run already uses, else one shown in the tab `here`, else any shown one, else the
-- oldest (lowest pane id). Returns it (nil when there is none) and every other one, to close. Duplicates in
-- `seen` count once.
function sidebar.pick_canvas(seen: { CanvasSeen }, current: number?, here: number?): (number?, { number })
	local by: { [number]: CanvasSeen } = {}
	local panes: { number } = {}
	for _, c in seen do
		if by[c.pane] == nil then
			by[c.pane] = c
			table.insert(panes, c.pane)
		end
	end
	table.sort(panes)
	local keep: number? = nil
	if current and by[current] then
		keep = current
	end
	if keep == nil and here then
		for _, p in panes do
			if by[p].tab == here and not by[p].parked then
				keep = p
				break
			end
		end
	end
	if keep == nil then
		for _, p in panes do
			if by[p].tab ~= nil and not by[p].parked then
				keep = p
				break
			end
		end
	end
	if keep == nil then
		keep = panes[1]
	end
	local extras: { number } = {}
	for _, p in panes do
		if p ~= keep then
			table.insert(extras, p)
		end
	end
	return keep, extras
end

-- A canvas_action's action name and value. Clicks arrive split (`ev.act`,
-- `ev.value`); a scripted `cx.session:event(pane, {act = "focus=12"})` arrives
-- unsplit, so split it here too. Panes come back as numbers (negative for
-- sleeping cards), ids as strings.
function sidebar.parse_action(ev: { act: string?, value: string? }): (string?, (string | number)?)
	local name, value = ev.act, ev.value
	if name ~= nil and value == nil then
		local a, v = string.match(name, "^([^=]*)=(.*)$")
		if a ~= nil then
			name, value = a, v
		end
	end
	if value ~= nil and name ~= nil and PANE_ACTS[name] then
		return name, tonumber(value) or value
	end
	return name, value
end

return sidebar
