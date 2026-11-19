--!strict
-- projects, GitHub: pull requests and issues for the sidebar, read with the GitHub CLI (`gh`). Pure: the host half
-- (host.luau) runs `git` and `gh` as `tern.process.spawn` children on its own clock, hands their output here to parse
-- into a compact model, and writes it to `<data>/gh.json`; window halves read that file when `gh_sig` in status.json
-- changed and draw a badge per card (gh's PR for the card's branch) and a "PRs & issues" list per project.
--
-- What a repository's entry holds:
--
-- - `open`: its open PRs (`gh pr list --state open`), each compact (`Pr`), with `mine` (authored by the user) and
--   `asked` (a review is requested from the user).
-- - `heads`: branch → the PR found for it by `gh pr list --head <branch> --state all` (or false: none), for branches
--   with no open PR, so a merged or closed PR still badges its worktree.
-- - `issues`: open issues assigned to the user (`gh issue list --assignee @me`).
-- - `ok_at` (os.time() of the last complete refresh), `tried_at`, `fails` and `error` (the last failure's first
--   line; nil after a success). A failure keeps the last good data, marked stale.

local gh = {}

gh.VERSION = 1
-- One refresh of a repository at most this often (s): while the sidebar shows, and while it is hidden.
gh.SHOWN_S = 60
gh.HIDDEN_S = 300
-- A branch's `--head` lookup is repeated at most this often (s), and at most this many run per refresh.
gh.HEAD_TTL = 300
gh.HEADS_PER_REFRESH = 4
-- A refresh asked for (the refresh button) waits at least this long after the last try (s).
gh.MIN_GAP_S = 15
-- Backoff after failures: doubling from the interval up to this (s); a rate limit waits at least RATE_S.
gh.BACKOFF_MAX = 1800
gh.RATE_S = 900
-- Data older than this (s) is stale even without an error (the host stopped refreshing it).
gh.STALE_S = 900
-- How many open PRs one refresh lists (each with its checks), and how many issues.
gh.PR_LIMIT = 50
gh.ISSUE_LIMIT = 30

gh.PR_FIELDS = "number,title,state,isDraft,reviewDecision,statusCheckRollup,url,mergeable,updatedAt,headRefName,isCrossRepository,author,reviewRequests"
gh.ISSUE_FIELDS = "number,title,url,updatedAt"

-- A PR as the sidebar shows it.
export type Pr = {
	n: number,
	title: string,
	-- open | draft | merged | closed
	state: string,
	-- pass | fail | pending, nil without checks; `checks` counts them ("3/4").
	ci: string?,
	checks: string?,
	-- approved | changes | review (required), nil when the repository asks for none.
	review: string?,
	conflicts: boolean?,
	url: string,
	updated: string?,
	branch: string?,
	-- Its head branch is in a fork: never matched to a local branch.
	fork: boolean?,
	author: string?,
	mine: boolean?,
	asked: boolean?,
}

export type Issue = { n: number, title: string, url: string, updated: string? }

export type Repo = {
	open: { Pr },
	heads: { [string]: Pr | false },
	head_at: { [string]: number },
	issues: { Issue },
	ok_at: number?,
	tried_at: number?,
	fails: number,
	error: string?,
}

function gh.empty_repo(): Repo
	return { open = {}, heads = {}, head_at = {}, issues = {}, fails = 0 }
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Remotes ---------------------------------------------------------------------------

-- `owner/repo` of a github.com remote URL (https, ssh, scp-like `git@github.com:o/r.git`), else nil.
function gh.slug_of_url(url: string?): string?
	if type(url) ~= "string" then
		return nil
	end
	local u = string.gsub(url, "%s+$", "")
	local path = string.match(u, "^https?://github%.com/(.+)$")
		or string.match(u, "^https?://[^/@]+@github%.com/(.+)$")
		or string.match(u, "^ssh://[^@/]+@github%.com/(.+)$")
		or string.match(u, "^ssh://github%.com/(.+)$")
		or string.match(u, "^git://github%.com/(.+)$")
		or string.match(u, "^[%w%-_.]+@github%.com:(.+)$")
	if path == nil then
		return nil
	end
	path = string.gsub(path, "/+$", "")
	path = string.gsub(path, "%.git$", "")
	local owner, repo = string.match(path, "^([%w%-_.]+)/([%w%-_.]+)$")
	if owner == nil or repo == nil then
		return nil
	end
	return owner .. "/" .. repo
end

-- The GitHub repository of `git remote -v` output: origin's, else the first github.com remote's; nil when none.
function gh.slug_of_remotes(text: string?): string?
	if type(text) ~= "string" then
		return nil
	end
	local first: string? = nil
	for line in string.gmatch(text, "[^\n]+") do
		local name, url = string.match(line, "^(%S+)%s+(%S+)")
		local slug = gh.slug_of_url(url)
		if slug then
			if name == "origin" then
				return slug
			end
			first = first or slug
		end
	end
	return first
end

-- Parsing gh's JSON --------------------------------------------------------------------

-- Check-run conclusions and status-context states that fail a rollup, and those that are still running.
local FAILED: { [string]: boolean } = {
	FAILURE = true,
	ERROR = true,
	CANCELLED = true,
	TIMED_OUT = true,
	ACTION_REQUIRED = true,
	STARTUP_FAILURE = true,
}
local RUNNING: { [string]: boolean } = {
	PENDING = true,
	EXPECTED = true,
	QUEUED = true,
	IN_PROGRESS = true,
	WAITING = true,
	REQUESTED = true,
}

-- A `statusCheckRollup` summarized: fail when any check failed, else pending when any still runs, else pass; nil
-- with no checks. Skipped and neutral checks count as passed. Also returns "passed/total".
function gh.rollup(list: any): (string?, string?)
	if type(list) ~= "table" or #list == 0 then
		return nil, nil
	end
	local total, passed, failed, running = 0, 0, 0, 0
	for _, c in list do
		if type(c) == "table" then
			total += 1
			-- CheckRun: status + conclusion; StatusContext: state.
			local status = str(c.status)
			local verdict = str(c.conclusion) or str(c.state)
			if status ~= nil and status ~= "COMPLETED" and RUNNING[status] ~= nil then
				running += 1
			elseif verdict == nil then
				running += 1
			elseif FAILED[verdict] then
				failed += 1
			elseif RUNNING[verdict] then
				running += 1
			else
				passed += 1
			end
		end
	end
	if total == 0 then
		return nil, nil
	end
	local counts = string.format("%d/%d", passed, total)
	if failed > 0 then
		return "fail", counts
	elseif running > 0 then
		return "pending", counts
	end
	return "pass", counts
end

local REVIEW: { [string]: string } = {
	APPROVED = "approved",
	CHANGES_REQUESTED = "changes",
	REVIEW_REQUIRED = "review",
}

-- One PR of `gh pr list --json <PR_FIELDS>` made compact; nil when it lacks a number or URL. `me` is the user's login.
function gh.pr_of(raw: any, me: string?): Pr?
	if type(raw) ~= "table" or type(raw.number) ~= "number" or str(raw.url) == nil then
		return nil
	end
	local state = string.upper(str(raw.state) or "OPEN")
	local s = if state == "MERGED" then "merged" elseif state == "CLOSED" then "closed" elseif raw.isDraft == true then "draft" else "open"
	local ci, checks = gh.rollup(raw.statusCheckRollup)
	local author = if type(raw.author) == "table" then str(raw.author.login) else nil
	local asked = false
	if me and type(raw.reviewRequests) == "table" then
		for _, r in raw.reviewRequests do
			if type(r) == "table" and r.login == me then
				asked = true
			end
		end
	end
	local title = str(raw.title) or ""
	if #title > 200 then
		title = string.sub(title, 1, 200)
	end
	return {
		n = raw.number,
		title = title,
		state = s,
		ci = ci,
		checks = checks,
		review = if s == "open" or s == "draft" then REVIEW[str(raw.reviewDecision) or ""] else nil,
		conflicts = if raw.mergeable == "CONFLICTING" and (s == "open" or s == "draft") then true else nil,
		url = raw.url,
		updated = str(raw.updatedAt),
		branch = str(raw.headRefName),
		fork = if raw.isCrossRepository == true then true else nil,
		author = author,
		mine = if me ~= nil and author == me then true else nil,
		asked = if asked then true else nil,
	}
end

-- `gh pr list --json` output → its PRs (malformed entries skipped), or nil and why when it is not a JSON array.
function gh.parse_prs(text: string, decode: (string) -> any, me: string?): ({ Pr }?, string?)
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "gh returned no JSON list"
	end
	local out: { Pr } = {}
	for _, raw in doc do
		local pr = gh.pr_of(raw, me)
		if pr then
			table.insert(out, pr)
		end
	end
	return out, nil
end

function gh.parse_issues(text: string, decode: (string) -> any): ({ Issue }?, string?)
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "gh returned no JSON list"
	end
	local out: { Issue } = {}
	for _, raw in doc do
		if type(raw) == "table" and type(raw.number) == "number" and str(raw.url) then
			local title = str(raw.title) or ""
			table.insert(out, { n = raw.number, title = string.sub(title, 1, 200), url = raw.url, updated = str(raw.updatedAt) })
		end
	end
	return out, nil
end

-- Branch → PR -------------------------------------------------------------------------

local RANK: { [string]: number } = { open = 3, draft = 3, merged = 2, closed = 1 }

-- Whether `a` is the better PR for a branch than `b`: open (or draft) over merged over closed, then the most
-- recently updated, then the higher number.
local function better(a: Pr, b: Pr): boolean
	local ra, rb = RANK[a.state] or 0, RANK[b.state] or 0
	if ra ~= rb then
		return ra > rb
	end
	if (a.updated or "") ~= (b.updated or "") then
		return (a.updated or "") > (b.updated or "")
	end
	return a.n > b.n
end

-- The PR of `branch` among `prs` (never one from a fork: its branch name is someone else's), or nil.
function gh.pick(prs: { Pr }, branch: string?): Pr?
	if branch == nil or branch == "" then
		return nil
	end
	local best: Pr? = nil
	for _, pr in prs do
		if pr.branch == branch and not pr.fork and (best == nil or better(pr, best :: Pr)) then
			best = pr
		end
	end
	return best
end

-- The PR a branch's card shows: its open PR, else what its `--head` lookup found.
function gh.pr_for(repo: Repo, branch: string?): Pr?
	local open = gh.pick(repo.open, branch)
	if open then
		return open
	end
	local h = if branch then repo.heads[branch] else nil
	return if h then h else nil
end

-- Branches of `wanted` that need a `--head` lookup now (no open PR, never looked up or looked up over HEAD_TTL ago),
-- the longest unseen first, at most HEADS_PER_REFRESH.
function gh.heads_due(repo: Repo, wanted: { string }, now: number): { string }
	local due: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, b in wanted do
		if not seen[b] and b ~= "" and gh.pick(repo.open, b) == nil then
			seen[b] = true
			local at = repo.head_at[b]
			if at == nil or now - at >= gh.HEAD_TTL then
				table.insert(due, b)
			end
		end
	end
	table.sort(due, function(a: string, b: string): boolean
		local ta, tb = repo.head_at[a] or -1, repo.head_at[b] or -1
		if ta ~= tb then
			return ta < tb
		end
		return a < b
	end)
	while #due > gh.HEADS_PER_REFRESH do
		table.remove(due)
	end
	return due
end

-- Whether a branch of `wanted` with no open PR was never looked up (a card that just appeared): then its lookup
-- runs before the next refresh. Only once the repository's open PRs are known.
function gh.new_heads(repo: Repo, wanted: { string }): boolean
	if repo.ok_at == nil then
		return false
	end
	for _, b in wanted do
		if b ~= "" and repo.head_at[b] == nil and gh.pick(repo.open, b) == nil then
			return true
		end
	end
	return false
end

-- Drops `--head` results for branches no card shows any more.
function gh.prune_heads(repo: Repo, wanted: { string })
	local keep: { [string]: boolean } = {}
	for _, b in wanted do
		keep[b] = true
	end
	for b in repo.heads do
		if not keep[b] then
			repo.heads[b] = nil
			repo.head_at[b] = nil
		end
	end
end

-- The project's list: open PRs the user authored or is asked to review, most recently updated first.
function gh.mine(repo: Repo): { Pr }
	local out: { Pr } = {}
	for _, pr in repo.open do
		if pr.mine or pr.asked then
			table.insert(out, pr)
		end
	end
	table.sort(out, function(a: Pr, b: Pr): boolean
		if (a.updated or "") ~= (b.updated or "") then
			return (a.updated or "") > (b.updated or "")
		end
		return a.n > b.n
	end)
	return out
end

-- Timing ------------------------------------------------------------------------------

function gh.interval(shown: boolean): number
	return if shown then gh.SHOWN_S else gh.HIDDEN_S
end

-- Whether gh said it hit GitHub's rate limit.
function gh.rate_limited(err: string?): boolean
	if err == nil then
		return false
	end
	local e = string.lower(err)
	return string.find(e, "rate limit", 1, true) ~= nil or string.find(e, "secondary rate", 1, true) ~= nil
end

-- When a repository is next refreshed (os.time()): an interval after the last try, doubled per failure in a row
-- up to BACKOFF_MAX, and at least RATE_S after a rate limit.
function gh.next_at(repo: Repo, shown: boolean): number
	local tried = repo.tried_at
	if tried == nil then
		return 0
	end
	local wait = gh.interval(shown)
	if repo.fails > 0 then
		wait = math.min(wait * 2 ^ repo.fails, gh.BACKOFF_MAX)
		if gh.rate_limited(repo.error) then
			wait = math.max(wait, gh.RATE_S)
		end
	end
	return tried + wait
end

-- Whether what the repository shows is stale: its last refresh failed, or never completed, or is over STALE_S old.
function gh.stale(repo: Repo, now: number): boolean
	if repo.error ~= nil or repo.ok_at == nil then
		return true
	end
	return now - (repo.ok_at :: number) > gh.STALE_S
end

-- Whether `gh issue list` failed only because the repository has issues turned off (then it has none).
function gh.issues_disabled(err: string?): boolean
	return err ~= nil and string.find(string.lower(err :: string), "disabled issues", 1, true) ~= nil
end

-- The first line of a failed run's output, short and with anything shaped like a GitHub token masked.
function gh.error_text(stderr: string?, stdout: string?, status: number?): string
	local text = if type(stderr) == "string" and string.find(stderr, "%S") then stderr else stdout or ""
	local line = string.match(text :: string, "^%s*([^\n]*)") or ""
	line = string.gsub(line, "%s+$", "")
	line = string.gsub(line, "gh[pousr]_[%w_]+", "***")
	line = string.gsub(line, "github_pat_[%w_]+", "***")
	if line == "" then
		line = "gh exited with status " .. tostring(status)
	end
	if #line > 200 then
		line = string.sub(line, 1, 200) .. "…"
	end
	return line
end

-- Commands ---------------------------------------------------------------------------

function gh.pr_list_argv(exe: string, slug: string): { string }
	return { exe, "pr", "list", "--repo", slug, "--state", "open", "--limit", tostring(gh.PR_LIMIT), "--json", gh.PR_FIELDS }
end

function gh.head_argv(exe: string, slug: string, branch: string): { string }
	return { exe, "pr", "list", "--repo", slug, "--head", branch, "--state", "all", "--limit", "5", "--json", gh.PR_FIELDS }
end

function gh.issue_argv(exe: string, slug: string): { string }
	return { exe, "issue", "list", "--repo", slug, "--assignee", "@me", "--state", "open", "--limit", tostring(gh.ISSUE_LIMIT), "--json", gh.ISSUE_FIELDS }
end

-- Creating a PR for `branch` of the worktree: push it to origin (tracking it), then `gh pr create --fill` against
-- `slug`. `dry` adds gh's `--dry-run` (gh may still push).
function gh.create_argvs(exe: string, slug: string, branch: string, dry: boolean?): { { string } }
	local create = { exe, "pr", "create", "--repo", slug, "--head", branch, "--fill" }
	if dry then
		table.insert(create, "--dry-run")
	end
	return {
		{ "git", "push", "--set-upstream", "origin", branch },
		create,
	}
end

-- Only https://github.com/ URLs are opened from the sidebar.
function gh.openable(url: any): boolean
	return type(url) == "string" and string.match(url, "^https://github%.com/[%w%-_.]+/[%w%-_.]+") ~= nil
		and string.find(url, "[%s\"'`]") == nil
end

-- Counts for a project's header.
function gh.counts(repo: Repo): (number, number)
	return #gh.mine(repo), #repo.issues
end

return gh
