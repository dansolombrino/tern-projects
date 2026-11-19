--!strict
-- projects, GitHub polling in the host half (README "Pull requests and issues"): finds the GitHub repository of every
-- folder the sidebar shows (`git remote -v`), refreshes each repository's PRs and issues with `gh` on a rate-limited
-- clock, and writes the compact model (gh.luau) to `<data>/gh.json`; `sig()` changes with every write, and the host
-- puts it in status.json so window halves re-read the file only then.
--
-- Rate policy: one `gh` process at a time, plugin-wide; a repository is refreshed at most every 60 s while the sidebar
-- shows (5 min while hidden), as 2 calls (open PRs, assigned issues) plus at most 4 `--head` lookups for branches
-- with no open PR (each branch at most every 5 min); failures back off (doubling, up to 30 min; 15 min after a
-- rate limit). The refresh button asks for a refresh no sooner than 15 s after the last try. `gh` keeps its own
-- token: nothing here reads, stores or logs one.

local gh = require("./gh")

local DATA = tern.plugin.data
local FILE = DATA .. "/gh.json"
-- kv key of the GitHub settings: `{ path = "<gh executable>"?, off = true? }`.
local SETTINGS_KEY = "projects.gh.v1"
-- A folder's remote is looked up again after this long (s).
local DIR_TTL = 600
-- Killed after this long (ms).
local RUN_MS = 30000
-- At most this many `git remote` lookups start per tick.
local DIRS_PER_TICK = 4

export type Want = { dir: string, branch: string? }
export type Deps = {
	-- Every folder the sidebar shows, with the branch its card shows (nil for a project root without a card).
	wants: () -> { Want },
	-- Whether the sidebar shows (faster refreshes).
	shown: () -> boolean,
	-- The branch the host last read for `cwd` (create-PR checks the request against it).
	branch_of: (cwd: string) -> string?,
}

type Dir = { slug: string | false, at: number, pending: boolean? }
type Created = { ok: boolean, url: string?, error: string?, at: number }

local deps: Deps = nil :: any
local dirs: { [string]: Dir } = {}
local repos: { [string]: gh.Repo } = {}
local busy: { [string]: boolean } = {}
local forced: { [string]: boolean } = {}
local created: { [string]: Created } = {}
local me: string? = nil
local me_at = 0
local me_pending = false
local running = false
local queue: { () -> () } = {}
local unloading = false
-- Write counter (status.json `gh_sig`), unique per host run.
local RUN = string.format("%d-%d", os.time(), math.random(1, 1000000))
local n_writes = 0
local last_json: string? = nil
-- gh processes started: in total and their start times over the last hour.
local calls_total = 0
local calls_hour: { number } = {}
local last_ms = 0

local function settings(): { path: string?, off: boolean }
	local ok, raw = pcall(tern.kv.get, SETTINGS_KEY)
	if not ok or type(raw) ~= "table" then
		return { off = false }
	end
	return { path = if type(raw.path) == "string" and raw.path ~= "" then raw.path else nil, off = raw.off == true }
end

local function exe(): string
	return settings().path or "gh"
end

-- Runs `argv` as a spawn child, collecting its output; `cb` gets {status, stdout, stderr}. A child that never
-- started answers status -1.
local function run(argv: { string }, cwd: string?, cb: (res: { status: number, stdout: string, stderr: string }) -> ())
	local out, err = {}, {}
	local done = false
	local t0 = tern.now()
	local ok, child = pcall(tern.process.spawn, argv, {
		cwd = cwd,
		split = "chunks",
		stdout = function(data: string)
			table.insert(out, data)
		end,
		stderr = function(data: string)
			table.insert(err, data)
		end,
		exit = function(res: SpawnExit)
			if done then
				return
			end
			done = true
			last_ms = tern.now() - t0
			cb({ status = res.status, stdout = table.concat(out), stderr = table.concat(err) })
		end,
	})
	if not ok then
		done = true
		cb({ status = -1, stdout = "", stderr = tostring(child) })
		return
	end
	tern.timer(RUN_MS, function()
		if not done then
			pcall(function()
				(child :: Child):kill()
			end)
		end
	end)
end

-- One gh call at a time: queued jobs run in order, each calling `next_job` when its process ended.
local function next_job()
	running = false
	if unloading then
		return
	end
	local job = table.remove(queue, 1)
	if job then
		running = true
		job()
	end
end

local function enqueue(job: () -> ())
	table.insert(queue, job)
	if not running then
		next_job()
	end
end

-- Runs gh with `args` (after the executable) in the queue; `cb` gets the result, then the next job starts.
local function gh_run(argv: { string }, cwd: string?, cb: (res: { status: number, stdout: string, stderr: string }) -> ())
	enqueue(function()
		calls_total += 1
		local t = os.time()
		table.insert(calls_hour, t)
		while calls_hour[1] and t - calls_hour[1] > 3600 do
			table.remove(calls_hour, 1)
		end
		run(argv, cwd, function(res)
			local ok, e = pcall(cb, res)
			if not ok then
				tern.log.warn("projects: gh result failed", e)
			end
			next_job()
		end)
	end)
end

-- gh.json -----------------------------------------------------------------------------

local function write()
	local out_repos: { [string]: any } = {}
	for slug, r in repos do
		out_repos[slug] = {
			open = tern.json.array(r.open),
			heads = r.heads,
			head_at = r.head_at,
			issues = tern.json.array(r.issues),
			ok_at = r.ok_at,
			tried_at = r.tried_at,
			fails = r.fails,
			error = r.error,
			busy = if busy[slug] then true else nil,
		}
	end
	local out_dirs: { [string]: string } = {}
	for dir, d in dirs do
		if d.slug then
			out_dirs[dir] = d.slug :: string
		end
	end
	local doc = { version = gh.VERSION, me = me, repos = out_repos, dirs = out_dirs, created = created }
	local text = tern.json.encode(doc)
	if text == last_json then
		return
	end
	local ok, err = pcall(tern.fs.write, FILE, text)
	if ok then
		last_json = text
		n_writes += 1
	else
		tern.log.warn("projects: gh.json not written", err)
	end
end

-- The last good data of an earlier run, so a reload or restart shows it (stale until refreshed).
local function load()
	local ok, text = pcall(tern.fs.read, FILE, 4194304)
	if not ok or type(text) ~= "string" then
		return
	end
	local dok, doc = pcall(tern.json.decode, text)
	if not dok or type(doc) ~= "table" or doc.version ~= gh.VERSION or type(doc.repos) ~= "table" then
		return
	end
	for slug, r in doc.repos do
		if type(slug) == "string" and type(r) == "table" then
			local repo = gh.empty_repo()
			repo.open = if type(r.open) == "table" then r.open else {}
			repo.issues = if type(r.issues) == "table" then r.issues else {}
			repo.heads = if type(r.heads) == "table" then r.heads else {}
			repo.head_at = if type(r.head_at) == "table" then r.head_at else {}
			repo.ok_at = if type(r.ok_at) == "number" then r.ok_at else nil
			repo.tried_at = if type(r.tried_at) == "number" then r.tried_at else nil
			repo.fails = if type(r.fails) == "number" then r.fails else 0
			repo.error = if type(r.error) == "string" then r.error else nil
			repos[slug] = repo
		end
	end
	if type(doc.dirs) == "table" then
		for dir, slug in doc.dirs do
			if type(dir) == "string" and type(slug) == "string" then
				-- Known, but looked up again soon.
				dirs[dir] = { slug = slug, at = os.time() - DIR_TTL + 30 }
			end
		end
	end
	me = if type(doc.me) == "string" then doc.me else nil
end

-- Refreshing -----------------------------------------------------------------------------

local function fail(slug: string, repo: gh.Repo, res: { status: number, stdout: string, stderr: string })
	repo.fails += 1
	repo.error = gh.error_text(res.stderr, res.stdout, res.status)
	busy[slug] = nil
	tern.log.warn(string.format("projects: gh refresh of %s failed (%d in a row): %s", slug, repo.fails, repo.error :: string))
	write()
end

-- The `--head` lookups due for `branches`, one after another; `done` runs after the last succeeded.
local function lookup_heads(slug: string, repo: gh.Repo, branches: { string }, x: string, done: () -> ())
	gh.prune_heads(repo, branches)
	local due = gh.heads_due(repo, branches, os.time())
	local i = 0
	local function step()
		i += 1
		local b = due[i]
		if b == nil then
			done()
			return
		end
		gh_run(gh.head_argv(x, slug, b), nil, function(hres)
			if hres.status ~= 0 then
				return fail(slug, repo, hres)
			end
			local list = gh.parse_prs(hres.stdout, tern.json.decode, me)
			if list == nil then
				return fail(slug, repo, { status = 0, stdout = "gh returned no JSON list", stderr = "" })
			end
			repo.heads[b] = gh.pick(list, b) or false
			repo.head_at[b] = os.time()
			step()
		end)
	end
	step()
end

-- One refresh of `slug`: open PRs, assigned issues, then `--head` lookups for `branches`; each step after the last
-- succeeded. A failure keeps everything from before. `heads_only`: just the lookups of branches never looked up
-- (a card that just appeared), leaving the refresh clock and the data's age alone.
local function refresh(slug: string, branches: { string }, heads_only: boolean?)
	local repo = repos[slug] or gh.empty_repo()
	repos[slug] = repo
	busy[slug] = true
	local x = exe()
	if heads_only then
		lookup_heads(slug, repo, branches, x, function()
			busy[slug] = nil
			write()
		end)
		return
	end
	forced[slug] = nil
	repo.tried_at = os.time()
	write()
	gh_run(gh.pr_list_argv(x, slug), nil, function(res)
		if res.status ~= 0 then
			return fail(slug, repo, res)
		end
		local prs, perr = gh.parse_prs(res.stdout, tern.json.decode, me)
		if prs == nil then
			return fail(slug, repo, { status = res.status, stdout = perr or "", stderr = "" })
		end
		repo.open = prs
		gh_run(gh.issue_argv(x, slug), nil, function(ires)
			if ires.status ~= 0 then
				if gh.issues_disabled(gh.error_text(ires.stderr, ires.stdout, ires.status)) then
					repo.issues = {}
				else
					return fail(slug, repo, ires)
				end
			else
				local issues, ierr = gh.parse_issues(ires.stdout, tern.json.decode)
				if issues == nil then
					return fail(slug, repo, { status = ires.status, stdout = ierr or "", stderr = "" })
				end
				repo.issues = issues
			end
			lookup_heads(slug, repo, branches, x, function()
				repo.ok_at = os.time()
				repo.fails = 0
				repo.error = nil
				busy[slug] = nil
				write()
			end)
		end)
	end)
end

local function lookup_me()
	if me_pending or os.time() - me_at < gh.SHOWN_S then
		return
	end
	me_pending = true
	me_at = os.time()
	gh_run({ exe(), "api", "user", "--jq", ".login" }, nil, function(res)
		me_pending = false
		local login = string.match(res.stdout, "^%s*([%w%-]+)%s*$")
		if res.status == 0 and login then
			me = login
		end
	end)
end

local function resolve(dir: string)
	local d = dirs[dir]
	if d and (d.pending or os.time() - d.at < DIR_TTL) then
		return
	end
	local entry: Dir = d or { slug = false, at = 0 }
	entry.pending = true
	dirs[dir] = entry
	-- git, not gh: local and free; outside the gh queue.
	run({ "git", "-C", dir, "remote", "-v" }, nil, function(res)
		entry.pending = nil
		entry.at = os.time()
		entry.slug = if res.status == 0 then gh.slug_of_remotes(res.stdout) or false else false
	end)
end

-- The host's clock: resolves folders, then queues a refresh of every repository that is due.
local function tick()
	if unloading then
		return
	end
	if settings().off then
		return
	end
	local wants = deps.wants()
	local branches: { [string]: { string } } = {}
	local wanted_dirs: { [string]: boolean } = {}
	local started = 0
	local unresolved = false
	for _, w in wants do
		wanted_dirs[w.dir] = true
		local d = dirs[w.dir]
		if d == nil or (not d.pending and os.time() - d.at >= DIR_TTL) then
			if started < DIRS_PER_TICK then
				resolve(w.dir)
				started += 1
			end
		end
		d = dirs[w.dir]
		if d == nil or (d.pending and d.at == 0) then
			unresolved = true
		elseif d.slug then
			local list = branches[d.slug :: string] or {}
			if w.branch and w.branch ~= "" and not table.find(list, w.branch) then
				table.insert(list, w.branch :: string)
			end
			branches[d.slug :: string] = list
		end
	end
	for dir in dirs do
		if not wanted_dirs[dir] then
			dirs[dir] = nil
		end
	end
	if not unresolved then
		local dropped = false
		for slug in repos do
			if branches[slug] == nil and not busy[slug] then
				repos[slug] = nil
				dropped = true
			end
		end
		if dropped then
			write()
		end
	end
	if next(branches) ~= nil and me == nil then
		lookup_me()
	end
	local shown = deps.shown()
	local now = os.time()
	for slug, list in branches do
		local repo = repos[slug]
		if not busy[slug] then
			local due = repo == nil or now >= gh.next_at(repo, shown)
			if not due and forced[slug] and repo then
				due = now - (repo.tried_at or 0) >= gh.MIN_GAP_S
			end
			if due then
				refresh(slug, list)
			elseif repo and repo.fails == 0 and gh.new_heads(repo, list) then
				refresh(slug, list, true)
			end
		end
	end
end

-- Spool requests from windows: `gh_refresh` (the refresh button) and `gh_create` (create a PR for a worktree's branch).
local function spool(obj: any): boolean
	if obj.op == "gh_refresh" then
		if type(obj.repo) == "string" and repos[obj.repo] then
			forced[obj.repo] = true
			-- Repeated failures stop backing off: the user asked.
			repos[obj.repo].fails = math.min(repos[obj.repo].fails, 1)
		end
		return true
	elseif obj.op == "gh_create" then
		local id, cwd, branch, slug = obj.id, obj.cwd, obj.branch, obj.repo
		if type(id) ~= "string" or type(cwd) ~= "string" or type(branch) ~= "string" or type(slug) ~= "string" then
			return true
		end
		local d = dirs[cwd]
		if created[id] or d == nil or d.slug ~= slug or deps.branch_of(cwd) ~= branch then
			created[id] = created[id] or { ok = false, error = "the worktree's branch or repository changed; nothing created", at = os.time() }
			write()
			return true
		end
		local argvs = gh.create_argvs(exe(), slug, branch, obj.dry == true)
		local function done(c: Created)
			created[id] = c
			-- Keep the last few.
			local ids: { string } = {}
			for k in created do
				table.insert(ids, k)
			end
			table.sort(ids, function(a: string, b: string): boolean
				return created[a].at > created[b].at
			end)
			for i = 6, #ids do
				created[ids[i]] = nil
			end
			forced[slug] = true
			write()
		end
		enqueue(function()
			run(argvs[1], cwd, function(pres)
				if pres.status ~= 0 then
					done({ ok = false, error = "git push: " .. gh.error_text(pres.stderr, pres.stdout, pres.status), at = os.time() })
					next_job()
					return
				end
				calls_total += 1
				table.insert(calls_hour, os.time())
				run(argvs[2], cwd, function(cres)
					if cres.status ~= 0 then
						done({ ok = false, error = gh.error_text(cres.stderr, cres.stdout, cres.status), at = os.time() })
					else
						local url = string.match(cres.stdout, "(https://github%.com/%S+)")
						done({ ok = true, url = url, at = os.time() })
					end
					next_job()
				end)
			end)
		end)
		return true
	end
	return false
end

local function stats(): { [string]: any }
	local t = os.time()
	local n = 0
	for _, at in calls_hour do
		if t - at <= 3600 then
			n += 1
		end
	end
	return { gh_sig = RUN .. "." .. n_writes, gh_calls = calls_total, gh_calls_hour = n, gh_last_ms = math.floor(last_ms + 0.5) }
end

return {
	start = function(d: Deps)
		deps = d
		load()
	end,
	tick = tick,
	spool = spool,
	stats = stats,
	stop = function()
		unloading = true
	end,
}
