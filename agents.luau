--!strict
-- projects, agents: starting top-level agents (in a git worktree when the project allows) and spawned
-- subagents, subagent report-back, and the card menu's workspace actions (rename, sleep, wake, pin, unread,
-- copy, delete with its worktree and branch).

local model = require("./model")
local core = require("./core")
local K = core.K
local MACOS = core.MACOS
local ask_pick = core.ask_pick
local ask_text = core.ask_text
local blank = core.blank
local defer = core.defer
local ensure_session = core.ensure_session
local errtext = core.errtext
local focused_cwd = core.focused_cwd
local git = core.git
local key_of = core.key_of
local plural = core.plural
local session_of = core.session_of
local short = core.short
local tilde = core.tilde
local trimmed = core.trimmed

-- The context: all shared state and the other modules' functions, set by the installer below.
local S: core.Ctx = nil :: any

-- Shows and focuses `pane`, switching session when another one holds it; it is read now.
local function goto_pane(cx: WindowCx, pane: number)
	local s = session_of(cx, pane)
	if s and not s.current then
		cx.sessions:switch(s.id)
	end
	cx.layout:focus(pane)
	S.last_main = pane
	S.clear_unread(if S.card_pane(pane) == pane then S.unread_keys(pane) else { key_of(pane) })
end

-- Agents ---------------------------------------------------------------------------

type NewAgent = {
	project: model.Project,
	task: string,
	cwd: string,
	worktree: string?,
	branch: string?,
	parent: number?,
}

local function color_tab(cx: WindowCx, pane: number, project: model.Project)
	local tab = cx.session:tab_of(pane)
	if tab then
		cx.layout:color_tab(tab, model.tab_color(project) :: any)
	end
end

-- Starts the agent and records it. Top-level agents open as a named, colored tab in the project's session;
-- subagents split beside their parent. Switching session, starting the agent and naming its tab each take
-- a turn of their own: each can take tens of milliseconds. A session just created first gets its shell to a
-- prompt: starting an agent in it before blocked for over 50 ms in Tern 0.9.16.

-- The panes of the current session other than the sidebar.
local function session_panes(cx: WindowCx): { number }
	local out: { number } = {}
	local cur = nil
	for _, s in cx.session:sessions() do
		if s.current then
			cur = s
		end
	end
	if cur == nil then
		return out
	end
	for _, p in cx.session:panes() do
		if p.tab and table.find(cur.tabs, p.tab) and p.pane ~= S.side_pane then
			table.insert(out, p.pane)
		end
	end
	return out
end

type Start = {
	-- The project whose session a top-level agent opens in.
	project: model.Project,
	-- Split beside this agent instead.
	parent: number?,
	prompt: string,
	cwd: string,
}

-- Starts an agent (in the project's session, or split beside its parent) and runs `started` with its pane on
-- the next turn; `failed` runs when Tern refused to start it.
local function start_agent(cx: WindowCx, s: Start, started: (pane: number, cx: WindowCx) -> (), failed: (() -> ())?)
	local how: "split" | "tab" = "tab"
	-- The session created for a top-level agent, else nil.
	local created: number? = nil
	if s.parent then
		goto_pane(cx, s.parent :: number)
		how = "split"
	else
		created = ensure_session(cx, s.project)
	end
	local switches = 0
	local function start_step(scx: WindowCx)
		-- The user can switch session while its shell starts: the agent still starts in the session created for
		-- it (and only that session's lone shell is closed).
		if created and scx.sessions:current().id ~= created then
			switches += 1
			local ok = switches <= 3 and pcall(function()
				scx.sessions:switch(created :: number)
			end)
			if ok then
				defer(start_step)
			else
				scx:toast("error", "Agent not started", "Session " .. s.project.name .. " is gone")
				if failed then
					failed()
				end
			end
			return
		end
		-- A new session's lone shell gives way to the agent, as `replace_if_alone` would (which blocked too long).
		local initial = if created then session_panes(scx) else {}
		local ok, pane = pcall(function()
			return scx.agents:start({ prompt = s.prompt, cwd = s.cwd, how = how })
		end)
		if not ok then
			scx:toast("error", "Agent not started", tostring(pane))
			if failed then
				failed()
			end
			return
		end
		if #initial > 0 then
			defer(function(ccx)
				for _, p in initial do
					local info = ccx.session:pane(p)
					if info and info.kind == "terminal" then
						ccx.layout:close(p)
					end
				end
			end)
		end
		S.last_activity[pane] = os.time()
		S.layout_dirty = true
		defer(function(rcx)
			started(pane, rcx)
			defer(function(dcx)
				S.changed(dcx)
			end)
			-- Its new split (and a closed initial shell) changed the layout: fit again once it settles.
			if S.side_pane then
				S.fit_later(S.side_pane :: number)
			end
		end)
	end
	if not created then
		defer(start_step)
		return
	end
	local waited = 0
	local function poll()
		tern.timer(K.SESSION_POLL_MS, function(pcx)
			if pcx == nil then
				return
			end
			waited += K.SESSION_POLL_MS
			local ready = true
			for _, p in session_panes(pcx) do
				local info = pcx.session:pane(p)
				if info and info.kind == "terminal" and info.at_prompt ~= true then
					ready = false
				end
			end
			if ready or waited >= K.SESSION_WAIT_MS then
				defer(start_step)
			else
				poll()
			end
		end)
	end
	poll()
end

-- Names a top-level agent's tab and colors it as its project.
local function dress_tab(cx: WindowCx, pane: number, title: string, project: model.Project)
	local tab = cx.session:tab_of(pane)
	if tab then
		cx.layout:name_tab(tab, title)
	end
	color_tab(cx, pane, project)
end

local function launch(cx: WindowCx, l: NewAgent)
	start_agent(cx, { project = l.project, parent = l.parent, prompt = l.task, cwd = l.cwd }, function(pane, rcx)
		local title = model.title_of(l.task)
		S.state = model.load()
		S.state.agents[tostring(pane)] = {
			project = l.project.id,
			title = title,
			task = l.task,
			worktree = l.worktree,
			branch = l.branch,
			parent = l.parent,
			report_back = if l.parent then true else nil,
			started = os.time(),
		}
		model.save(S.state)
		if l.parent == nil then
			dress_tab(rcx, pane, title, l.project)
		end
	end)
end

type GitSetup = { prefix: string?, base: string }

-- Orca's branch prefix (`github.user`, else `user.username`, else none) and base ref (origin/HEAD's target,
-- origin/main, origin/master, main, master, else HEAD), one git call per callback.
local function git_setup(root: string, done: (setup: GitSetup, cx: WindowCx?) -> ())
	local function base_of(prefix: string?)
		git({ "-C", root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD" }, function(res, _)
			local head = trimmed(res.stdout)
			if res.status == 0 and head ~= "" then
				done({ prefix = prefix, base = head }, nil)
				return
			end
			local wanted = { "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master" }
			local args = { "-C", root, "for-each-ref", "--format=%(refname)" }
			for _, r in wanted do
				table.insert(args, r)
			end
			git(args, function(fres, fcx)
				local have: { [string]: boolean } = {}
				for line in string.gmatch(fres.stdout, "[^\n]+") do
					have[trimmed(line)] = true
				end
				for _, r in wanted do
					if have[r] then
						local short_ref = string.gsub(string.gsub(r, "^refs/remotes/", ""), "^refs/heads/", "")
						done({ prefix = prefix, base = short_ref }, fcx)
						return
					end
				end
				done({ prefix = prefix, base = "HEAD" }, fcx)
			end)
		end)
	end
	git({ "-C", root, "config", "github.user" }, function(res, _)
		local user = trimmed(res.stdout)
		if res.status == 0 and user ~= "" then
			base_of(user)
			return
		end
		git({ "-C", root, "config", "user.username" }, function(ures, _)
			local u = trimmed(ures.stdout)
			base_of(if ures.status == 0 and u ~= "" then u else nil)
		end)
	end)
end

-- Creates worktree `<name>` (then `<name>-2`, … when taken) on a new branch from the base ref.
local function make_worktree(project: model.Project, setup: GitSetup, name: string, n: number, done: (path: string?, branch: string?, err: string?) -> ())
	local slug = if n == 1 then name else name .. "-" .. n
	local path = model.worktree_path(project, slug)
	local branch = model.branch_name(setup.prefix, slug)
	if tern.fs.exists(path) then
		make_worktree(project, setup, name, n + 1, done)
		return
	end
	git({ "-C", project.root, "worktree", "add", "--no-track", "-b", branch, path, setup.base }, function(res, _)
		if res.status == 0 then
			done(path, branch, nil)
		elseif n < 20 and string.find(res.stderr, "already exists", 1, true) then
			make_worktree(project, setup, name, n + 1, done)
		else
			done(nil, nil, errtext(res))
		end
	end, 120000)
end

local function new_agent_in(cx: WindowCx, project: model.Project)
	ask_text(cx, { placeholder = "Task for a new agent in " .. project.name, icon = "sparkle", action = "start agent" }, function(task, pcx)
		if not project.worktrees then
			launch(pcx, { project = project, task = task, cwd = project.root })
			return
		end
		git_setup(project.root, function(setup)
			make_worktree(project, setup, model.slug(model.title_of(task)), 1, function(path, branch, err)
				defer(function(wcx)
					if path == nil then
						wcx:toast("error", "Worktree not created for " .. project.name, err)
						return
					end
					launch(wcx, { project = project, task = task, cwd = path, worktree = path, branch = branch })
				end)
			end)
		end)
	end)
end

local function pick_project(cx: WindowCx, placeholder: string, fn: (cx: WindowCx, project: model.Project) -> ())
	S.state = model.load()
	if #S.state.projects == 0 then
		cx:toast("info", "No projects yet", "Add one with Projects: Add project")
		return
	end
	local current = cx.sessions:current().name
	local items: { PickItem } = {}
	for _, p in S.state.projects do
		table.insert(items, { label = p.name, detail = tilde(p.root), icon = "folder", current = p.name == current, project = p.id })
	end
	ask_pick(cx, { items = items, placeholder = placeholder, icon = "folder" }, function(item, pcx)
		local p = model.get(model.load(), (item :: any).project)
		if p then
			fn(pcx, p)
		end
	end)
end

local function new_agent(cx: WindowCx)
	S.state = model.load()
	local pane, cwd = focused_cwd(cx)
	local p = if pane then S.project_of(pane, cwd) else nil
	if p then
		new_agent_in(cx, p)
	else
		pick_project(cx, "Project for the new agent", new_agent_in)
	end
end

local function new_agent_for(cx: WindowCx, id: string?)
	local p = if id then model.get(model.load(), id) else nil
	if p then
		new_agent_in(cx, p)
	else
		new_agent(cx)
	end
end

local function new_subagent_of(cx: WindowCx, parent: number)
	S.scan(cx)
	local b = S.blocks[parent]
	if b == nil then
		cx:toast("error", "Not an agent", "Focus an agent block to start a subagent of it")
		return
	end
	local project = S.project_of(parent, b.cwd)
	if project == nil then
		cx:toast("error", "Agent is in no project", tilde(b.cwd))
		return
	end
	local pmeta = S.meta_of(parent)
	local ptitle = S.title_of(parent, b.cwd)
	ask_text(cx, { placeholder = "Task for a subagent of " .. ptitle, icon = "sparkle", action = "start subagent" }, function(task, pcx)
		launch(pcx, {
			project = project :: model.Project,
			task = task,
			cwd = b.cwd,
			branch = if pmeta then pmeta.branch else nil,
			parent = parent,
		})
	end)
end

-- The agent's answer to its latest prompt: the last assistant message after the last user message in
-- the omp transcript, without omp's `·` stats footer; nil while the turn has no answer yet.
local function answer_of(cx: WindowCx, pane: number): string?
	local ok, msgs = pcall(function()
		return cx.agents:transcript(pane, { last = 8 })
	end)
	if not ok then
		local b = S.blocks[pane]
		return if b then b.last_message else nil
	end
	for i = #msgs, 1, -1 do
		local m = msgs[i]
		if m.role == "user" then
			return nil
		end
		if m.role == "assistant" and not blank(m.text) then
			local text = string.gsub(m.text, "\n·\n[^\n]*%s*$", "")
			return text
		end
	end
	return nil
end

-- Sends the parent its oldest queued report unless it is busy (the rest wait for its next idle).
local function deliver(cx: WindowCx, parent: number)
	local queue = S.pending[parent]
	if queue == nil then
		return
	end
	local pb = S.blocks[parent]
	if pb == nil or pb.state == "exited" then
		S.pending[parent] = nil
		return
	end
	if pb.state == "working" then
		return
	end
	local text = table.remove(queue, 1) :: string
	if #queue == 0 then
		S.pending[parent] = nil
	end
	local ok, err = pcall(function()
		cx.agents:ask(parent, text)
	end)
	if not ok then
		local q = S.pending[parent] or {}
		table.insert(q, 1, text)
		S.pending[parent] = q
		cx:toast("error", "Report to " .. S.title_of(parent, pb.cwd) .. " not sent yet", tostring(err))
	end
end

-- Queues the spawned subagent's answer for its parent once its turn ended. The answer can trail the
-- event, so a turn without one is looked at again a few times.
local function report_back(cx: WindowCx, pane: number, result: string, tries: number)
	local meta = S.meta_of(pane)
	if meta == nil or meta.parent == nil or meta.report_back == false then
		return
	end
	local parent = meta.parent :: number
	local msg = answer_of(cx, pane)
	if msg == nil then
		if tries < 5 then
			tern.timer(1000, function(tcx)
				if tcx then
					S.scan(tcx)
					report_back(tcx, pane, result, tries + 1)
				end
			end)
		end
		return
	end
	if S.reported[pane] == msg then
		return
	end
	S.reported[pane] = msg
	local q = S.pending[parent] or {}
	table.insert(q, string.format("Subagent %s finished (%s):\n\n%s", meta.title, result, short(msg, K.REPORT_CHARS) or ""))
	S.pending[parent] = q
	deliver(cx, parent)
end

-- Workspace actions (card menu) ------------------------------------------------------

local function rename_agent(cx: WindowCx, pane: number)
	S.scan(cx)
	local cwd = S.cwd_of(pane)
	local old = S.title_of(pane, cwd)
	ask_text(cx, { value = old, placeholder = "Rename workspace", icon = "agent", action = "rename" }, function(text, rcx)
		if text == old then
			return
		end
		S.state = model.load()
		local key = key_of(pane)
		local meta = S.state.agents[key]
		if meta then
			meta.title = text
		else
			-- An agent started by hand: keep its name under the project its folder belongs to (if any).
			local p = model.project_for_path(S.state, cwd)
			S.state.agents[key] = { project = if p then p.id else "", title = text, started = 0 }
		end
		model.save(S.state)
		local top = meta == nil or meta.parent == nil
		local tab = if pane > 0 then rcx.session:tab_of(pane) else nil
		if top and tab then
			rcx.layout:name_tab(tab, text)
		end
		S.changed(rcx)
	end)
end

-- Closes an agent (and the subagents it spawned): it sleeps as a card while it owns a worktree.
local function sleep_agent(cx: WindowCx, pane: number)
	if pane < 0 then
		return
	end
	S.scan(cx)
	local b = S.blocks[pane]
	if b and b.state == "working" then
		S.interrupted[tostring(pane)] = true
	end
	for p in S.blocks do
		local m = S.meta_of(p)
		if m and m.parent == pane then
			pcall(function()
				cx.agents:stop(p)
			end)
		end
	end
	pcall(function()
		cx.agents:stop(pane)
	end)
	S.changed(cx)
end

-- Restarts a sleeping card's agent on its task in its worktree, in the project's session.
local waking: { [string]: boolean } = {}
local function wake(cx: WindowCx, pane: number)
	local key = key_of(pane)
	S.state = model.load()
	local meta = S.state.agents[key]
	if meta == nil or not meta.closed or meta.worktree == nil or waking[key] or S.deleting[key] then
		return
	end
	local m = meta :: model.AgentMeta
	local wt = m.worktree :: string
	if not tern.fs.exists(wt) then
		cx:toast("error", "Worktree is gone", tilde(wt))
		return
	end
	local project = model.get(S.state, m.project)
	if project == nil then
		cx:toast("error", "Its project was removed", m.title)
		return
	end
	waking[key] = true
	start_agent(cx, { project = project :: model.Project, prompt = m.task or m.title, cwd = wt }, function(new, rcx)
		waking[key] = nil
		local nkey = tostring(new)
		S.state = model.load()
		local rec = S.state.agents[key] or m
		S.state.agents[key] = nil
		rec.closed, rec.closed_at, rec.interrupted, rec.started = nil, nil, nil, os.time()
		S.state.agents[nkey] = rec
		model.save(S.state)
		S.ui = model.load_ui()
		model.rekey_ui(S.ui, key, nkey)
		-- Waking is opening it: the woken agent is read.
		S.ui.unread[nkey] = nil
		S.save_ui()
		S.interrupted[key] = nil
		dress_tab(rcx, new, rec.title, project :: model.Project)
	end, function()
		waking[key] = nil
	end)
end

local function copy_path(cx: WindowCx, pane: number)
	local path = S.cwd_of(pane)
	if path then
		cx:copy(path)
	end
end

local function copy_name(cx: WindowCx, pane: number)
	cx:copy(S.title_of(pane, S.cwd_of(pane)))
end

local function open_in_finder(cx: WindowCx, path: string?)
	if path == nil then
		return
	end
	tern.process.run({ if MACOS then "open" else "xdg-open", path }, { timeout_ms = 10000 }, function(res, rcx)
		if res.status ~= 0 and rcx then
			rcx:toast("error", "Not opened", errtext(res))
		end
	end)
end

local function toggle_pin(cx: WindowCx, pane: number)
	local key = key_of(pane)
	S.ui = model.load_ui()
	if S.ui.pinned[key] then
		S.ui.pinned[key] = nil
	else
		S.ui.pinned[key] = true
		S.ui.collapsed.pinned = nil
	end
	S.save_ui()
	S.refresh_side(cx)
end

-- An unread card is read once its own pane and every spawned descendant are; a read card gets its own mark.
local function toggle_unread(cx: WindowCx, pane: number)
	S.ui = model.load_ui()
	local keys = S.unread_keys(pane)
	local any = false
	for _, k in keys do
		if S.ui.unread[k] then
			any = true
		end
	end
	if any then
		for _, k in keys do
			S.ui.unread[k] = nil
		end
	else
		S.ui.unread[keys[1]] = true
	end
	S.save_ui()
	S.refresh_side(cx)
end

-- Forgets a deleted card's record, pin and unread mark.
local function forget(key: string)
	S.state = model.load()
	S.state.agents[key] = nil
	model.save(S.state)
	S.ui = model.load_ui()
	S.ui.pinned[key], S.ui.unread[key] = nil, nil
	S.save_ui()
	S.interrupted[key] = nil
end

local function offer_force_branch(cx: WindowCx, root: string, branch: string)
	ask_pick(cx, {
		items = {
			{ label = "Force Delete Branch", detail = branch, icon = "trash", force = true },
			{ label = "Keep Branch", icon = "x", force = false },
		},
		placeholder = "Branch " .. branch .. " kept",
		icon = "branch",
	}, function(item, pcx)
		if not (item :: any).force then
			return
		end
		git({ "-C", root, "branch", "-D", "--", branch }, function(res, gcx)
			if gcx and res.status ~= 0 then
				gcx:toast("error", "Branch not deleted", errtext(res))
			end
		end)
	end)
end

-- Stops every agent in the workspace, removes its worktree (forced: the user confirmed losing changes) and
-- deletes its branch the safe way, offering a forced delete when git keeps it.
local function run_delete(cx: WindowCx, pane: number)
	local key = key_of(pane)
	S.state = model.load()
	local meta = S.state.agents[key]
	local title = S.title_of(pane, S.cwd_of(pane))
	local wt = if meta then meta.worktree else nil
	S.scan(cx)
	local live = if pane > 0 and S.blocks[pane] then pane else nil
	for p, b in S.blocks do
		local m = S.meta_of(p)
		local inside = wt ~= nil and b.cwd ~= "" and model.inside(b.cwd, wt :: string)
		if p == live or (live and m and m.parent == live) or inside then
			pcall(function()
				cx.agents:stop(p)
			end)
		end
	end
	if wt == nil then
		forget(key)
		S.changed(cx)
		return
	end
	local m = meta :: model.AgentMeta
	local project = model.get(S.state, m.project)
	local root = if project then project.root else model.dirname(wt :: string)
	S.deleting[key] = true
	S.changed(cx)
	local function finish(gcx: WindowCx?)
		S.deleting[key] = nil
		forget(key)
		if gcx then
			S.changed(gcx)
		end
		local branch = m.branch
		if branch == nil then
			return
		end
		git({ "-C", root, "branch", "-d", "--", branch }, function(res, bcx)
			if res.status ~= 0 and bcx then
				bcx:toast("info", "Worktree deleted, branch kept", string.format(
					'Git could not safely delete branch "%s" after deleting worktree "%s", so it was kept to avoid losing local commits.',
					branch :: string,
					model.basename(wt :: string)
				))
				offer_force_branch(bcx, root, branch :: string)
			end
		end)
	end
	if not tern.fs.exists(wt :: string) then
		git({ "-C", root, "worktree", "prune" }, function(_res, gcx)
			finish(gcx)
		end)
		return
	end
	git({ "-C", root, "worktree", "remove", "--force", wt :: string }, function(res, gcx)
		if res.status ~= 0 then
			S.deleting[key] = nil
			if gcx then
				gcx:toast("error", "Failed to delete workspace " .. title, errtext(res))
				S.changed(gcx)
			end
			return
		end
		finish(gcx)
	end)
end

-- Orca's delete funnel: a primary card removes its project instead; otherwise confirm (unless the user chose
-- not to be asked) with the dirty count, then delete.
local function delete_agent(cx: WindowCx, pane: number)
	S.scan(cx)
	-- A spawned subagent owns no workspace: deleting from it deletes its card's.
	pane = S.card_pane(pane)
	local cwd = S.cwd_of(pane)
	local p = S.project_of(pane, cwd)
	if pane > 0 and p and cwd and model.inside(cwd, p.root) then
		S.confirm_remove(cx, p)
		return
	end
	local key = key_of(pane)
	if S.deleting[key] then
		return
	end
	S.ui = model.load_ui()
	if S.ui.skip_delete_confirm then
		run_delete(cx, pane)
		return
	end
	local meta = S.meta_of(pane)
	local title = S.title_of(pane, cwd)
	local function confirm(ccx: WindowCx, dirty: number)
		local detail = "Remove " .. title .. " from git and delete its workspace folder."
		if dirty > 0 then
			detail = detail
				.. " "
				.. plural(dirty, "uncommitted or untracked change")
				.. ". Any uncommitted or untracked changes in Git workspaces will be permanently deleted."
		end
		ask_pick(ccx, {
			items = {
				{ label = "Delete Workspace", detail = detail, icon = "trash", run = "delete" },
				{ label = "Cancel", icon = "x", run = "cancel" },
				{ label = "Delete and don't ask again", icon = "trash", run = "always" },
			},
			placeholder = "Delete Workspace",
			icon = "trash",
		}, function(item, pcx)
			local run = (item :: any).run
			if run == "always" then
				S.ui = model.load_ui()
				S.ui.skip_delete_confirm = true
				S.save_ui()
				pcx:toast("info", "We'll skip this confirmation next time.", "You can change this in Settings.")
			end
			if run == "delete" or run == "always" then
				run_delete(pcx, pane)
			end
		end)
	end
	local wt = if meta then meta.worktree else nil
	if wt == nil or not tern.fs.exists(wt :: string) then
		confirm(cx, 0)
		return
	end
	git({ "-C", wt :: string, "status", "--porcelain" }, function(res, _)
		local n = 0
		if res.status == 0 then
			for _ in string.gmatch(res.stdout, "[^\n]+") do
				n += 1
			end
		end
		defer(function(dcx)
			confirm(dcx, n)
		end)
	end)
end

-- Installs this module's functions into the context.
return function(ctx: core.Ctx)
	S = ctx
	S.color_tab = color_tab
	S.copy_name = copy_name
	S.copy_path = copy_path
	S.delete_agent = delete_agent
	S.deliver = deliver
	S.goto_pane = goto_pane
	S.new_agent = new_agent
	S.new_agent_for = new_agent_for
	S.new_subagent_of = new_subagent_of
	S.open_in_finder = open_in_finder
	S.pick_project = pick_project
	S.rename_agent = rename_agent
	S.report_back = report_back
	S.sleep_agent = sleep_agent
	S.toggle_pin = toggle_pin
	S.toggle_unread = toggle_unread
	S.wake = wake
end
