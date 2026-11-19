--!strict
-- projects, pull requests and issues in a window: reads the GitHub model the host half writes (`<data>/gh.json`,
-- ghpoll.luau) when `gh_sig` in status.json changed, gives the sidebar each card's PR badge and each project's "PRs &
-- issues", opens PRs and issues in the system browser, asks the host for a refresh, and creates a PR for the focused
-- worktree's branch (the host runs `git push` and `gh pr create --fill`; gh runs only in the host half).

local gh = require("./gh")
local model = require("./model")
local sidebar = require("./sidebar")
local core = require("./core")

local S: core.Ctx = nil :: any

local DATA = tern.plugin.data
local FILE = DATA .. "/gh.json"
local SPOOL = DATA .. "/spool"
local BYTES = 4194304

type Model = { me: string?, repos: { [string]: gh.Repo & { busy: boolean? } }, dirs: { [string]: string }, created: { [string]: any } }

local spool_seq = 0
local function spool_write(obj: { [string]: any })
	spool_seq += 1
	local name = string.format("%012d-%06d-%04x.json", os.time(), spool_seq, math.random(0, 0xffff))
	pcall(tern.fs.mkdir, SPOOL)
	tern.fs.write(SPOOL .. "/" .. name, tern.json.encode(obj))
end

-- Create requests this window sent, by id, until the host answers.
local asked: { [string]: { branch: string, slug: string } } = {}

-- Re-reads gh.json (called by the scan when status.json's `gh_sig` changed). A missing or half-written file keeps the
-- last model.
local function load_gh(cx: WindowCx?)
	local ok, text = pcall(tern.fs.read, FILE, BYTES)
	if not ok then
		return
	end
	local dok, doc = pcall(tern.json.decode, text)
	if not dok or type(doc) ~= "table" or doc.version ~= gh.VERSION then
		return
	end
	S.gh = {
		me = if type(doc.me) == "string" then doc.me else nil,
		repos = if type(doc.repos) == "table" then doc.repos else {},
		dirs = if type(doc.dirs) == "table" then doc.dirs else {},
		created = if type(doc.created) == "table" then doc.created else {},
	} :: Model
	S.dirty = true
	S.redraw_soon()
	if cx then
		for id, req in asked do
			local c = (S.gh :: Model).created[id]
			if type(c) == "table" then
				asked[id] = nil
				if c.ok then
					cx:toast("success", "Pull request created for " .. req.branch, c.url)
				else
					cx:toast("error", "No pull request created for " .. req.branch, c.error)
				end
			end
		end
	end
end

local function repo_of(dir: string?): (string?, gh.Repo?)
	local m: Model? = S.gh
	if m == nil or dir == nil then
		return nil, nil
	end
	local slug = m.dirs[dir :: string]
	if type(slug) ~= "string" then
		return nil, nil
	end
	local r = m.repos[slug]
	return slug, if type(r) == "table" then r else nil
end

-- The PR badge of a card working in `dir` on `branch`, and whether it is stale.
local function pr_for(dir: string?, branch: string?): (gh.Pr?, boolean?)
	local _, r = repo_of(dir)
	if r == nil or branch == nil then
		return nil, nil
	end
	local repo = r :: gh.Repo
	if type(repo.open) ~= "table" or type(repo.heads) ~= "table" then
		return nil, nil
	end
	local pr = gh.pr_for(repo, branch)
	if pr == nil then
		return nil, nil
	end
	return pr, gh.stale(repo, os.time())
end

-- A project's "PRs & issues" for the sidebar; nil outside GitHub.
local function gh_project(p: model.Project): sidebar.GhSnap?
	local slug, r = repo_of(p.root)
	if slug == nil then
		return nil
	end
	local repo: gh.Repo = r or gh.empty_repo()
	if type(repo.open) ~= "table" or type(repo.issues) ~= "table" then
		repo = gh.empty_repo()
	end
	return {
		slug = slug :: string,
		prs = gh.mine(repo),
		issues = repo.issues,
		stale = gh.stale(repo, os.time()),
		error = repo.error,
		ok_at = repo.ok_at,
		busy = (repo :: any).busy == true,
		open = S.ui.prs_open[p.id] == true,
	}
end

-- Opens a GitHub URL in the system browser (never a Tern pane: one would open in whatever session is current).
local function open_url(cx: WindowCx, url: string)
	if not gh.openable(url) then
		cx:toast("error", "Not opened", "Only github.com links open from the sidebar")
		return
	end
	tern.process.run({ if core.MACOS then "open" else "xdg-open", url }, { timeout_ms = 10000 }, function(res, rcx)
		if res.status ~= 0 and rcx then
			rcx:toast("error", "Not opened", core.errtext(res))
		end
	end)
end

local function gh_refresh(cx: WindowCx, slug: string)
	spool_write({ op = "gh_refresh", repo = slug })
	-- Shows "refreshing…" once the host starts (within its 5 s clock and the 15 s floor).
	cx:toast("info", "Refreshing " .. slug)
end

local function toggle_prs(cx: WindowCx, id: string)
	S.ui = model.load_ui()
	S.ui.prs_open[id] = if S.ui.prs_open[id] then nil else true
	S.save_ui()
	S.refresh_side(cx)
end

-- Create a PR for the focused agent's worktree branch, after a confirmation.
local function create_pr(cx: WindowCx)
	local pane = S.focused_agent(cx)
	if pane == nil then
		return
	end
	local cwd = S.cwd_of(pane)
	local r = if cwd then S.host_repos[cwd :: string] else nil
	local branch = if type(r) == "table" and type(r.branch) == "string" then r.branch else nil
	local slug, repo = repo_of(cwd)
	if cwd == nil or branch == nil then
		cx:toast("error", "No branch", "The focused agent's folder is not on a git branch")
		return
	end
	if slug == nil then
		cx:toast("error", "Not a GitHub repository", "The focused agent's folder has no github.com remote")
		return
	end
	local existing = if repo then gh.pr_for(repo :: gh.Repo, branch) else nil
	if existing and (existing.state == "open" or existing.state == "draft") then
		cx:toast("info", string.format("%s already has PR #%d", branch :: string, existing.n), existing.url)
		return
	end
	core.ask_pick(cx, {
		placeholder = string.format("Create a PR for %s on %s? (pushes the branch, then gh pr create --fill)", branch :: string, slug :: string),
		icon = "branch",
		items = {
			{ id = "create", label = "Create pull request", detail = "git push --set-upstream origin " .. branch :: string .. "; gh pr create --fill", icon = "rocket" },
			{ id = "cancel", label = "Cancel", icon = "x" },
		},
	}, function(item, _pcx)
		if item.id ~= "create" then
			return
		end
		local id = string.format("c%d-%04x", os.time(), math.random(0, 0xffff))
		asked[id] = { branch = branch :: string, slug = slug :: string }
		spool_write({ op = "gh_create", id = id, cwd = cwd, branch = branch, repo = slug })
	end)
end

return function(ctx: core.Ctx)
	S = ctx
	S.gh = nil
	S.gh_sig = nil
	S.load_gh = load_gh
	S.pr_for = pr_for
	S.gh_project = gh_project
	S.open_url = open_url
	S.gh_refresh = gh_refresh
	S.toggle_prs = toggle_prs
	S.create_pr = create_pr
end
