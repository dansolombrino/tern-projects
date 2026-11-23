--!strict
-- projects, projects and groups: opening, adding (browse, clone, create), removing and editing projects
-- (settings, color, icon, rename, order), project groups and their menus, and collapsing headers.

local model = require("./model")
local core = require("./core")
local HOME = core.HOME
local MACOS = core.MACOS
local ask_pick = core.ask_pick
local ask_text = core.ask_text
local defer = core.defer
local ensure_session = core.ensure_session
local errtext = core.errtext
local focused_cwd = core.focused_cwd
local git_on = core.git_on
local fs_on = core.fs_on
local host_now = core.host_now
local plural = core.plural
local session_named = core.session_named
local tilde = core.tilde
local trimmed = core.trimmed

-- The context: all shared state and the other modules' functions, set by the installer below.
local S: core.Ctx = nil :: any

-- Projects -------------------------------------------------------------------------

local function open_project(cx: WindowCx, p: model.Project)
	local ok, created = pcall(ensure_session, cx, p)
	if not ok then
		cx:toast("error", "Not opened: " .. p.name, tostring(created))
		return
	end
	if created then
		cx:toast("info", "Opened " .. p.name, tilde(p.root))
	end
	S.changed(cx)
end

-- A file check on `host` (core.fs_on) whose callback always gets a window context: the caller's when the answer
-- came at once (this machine, so local use keeps its single turn), the reply's, else the next turn's.
local function fs_at(cx: WindowCx, host: string?, fn: string, path: string, cb: (ok: boolean, value: any, err: string?, extra: any, cx: WindowCx) -> ())
	local sync = true
	fs_on(S, host, fn, path, function(ok, value, err, extra, rcx)
		if sync then
			cb(ok, value, err, extra, cx)
		elseif rcx then
			cb(ok, value, err, extra, rcx)
		else
			defer(function(dcx)
				cb(ok, value, err, extra, dcx)
			end)
		end
	end)
	sync = false
end

-- `path` with `home` shown as `~` (the host's HOME: a remote one is not this machine's).
local function tilde_at(path: string, host: string?, home: string?): string
	if host == nil or home == nil then
		return tilde(path)
	end
	if path == home then
		return "~"
	end
	if string.sub(path, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

-- Adds the folder `root` on `host` as a project (a repository's top folder gets worktrees) and opens its session.
local function admit(cx: WindowCx, root: string, as_folder: boolean, host: string?)
	S.state = model.load()
	local ok, p = pcall(model.add_project, S.state, { name = model.basename(root), root = root, worktrees = not as_folder, host = host })
	if not ok then
		cx:toast("error", "Project not added", tostring(p))
		return
	end
	model.save(S.state)
	open_project(cx, p :: model.Project)
end

local function admit_path(cx: WindowCx, root: string, host: string?)
	fs_at(cx, host, "exists", root, function(ok, found, err, _, ecx)
		if not ok then
			ecx:toast("error", "Folder not checked", err)
			return
		end
		if not found then
			ecx:toast("error", "No such folder", tilde(root))
			return
		end
		git_on(S, host, { "rev-parse", "--show-prefix" }, function(res, _)
			defer(function(gcx)
				if res.status == 0 then
					-- Inside a repository: only its top folder can hold worktrees.
					admit(gcx, root, trimmed(res.stdout) ~= "", host)
					return
				end
				ask_pick(gcx, {
					items = {
						{
							label = "Open as Folder",
							detail = "This folder isn't a Git repository. You'll have the editor, terminal, and search, but Git-based features won't be available.",
							icon = "folder-open",
							open = true,
						},
						{ label = "Cancel", icon = "x", open = false },
					},
					placeholder = "Open as Folder",
					icon = "folder",
				}, function(item, pcx)
					if (item :: any).open then
						admit(pcx, root, true, host)
					end
				end)
			end)
		end, nil, root)
	end)
end

-- Asks for a path on `host` (`~` is `home`, that host's HOME), relative ones resolved against `default`.
local function ask_path(cx: WindowCx, placeholder: string, default: string, fn: (path: string, cx: WindowCx) -> (), host: string?, home: string?)
	ask_text(cx, { value = tilde_at(default, host, home), placeholder = placeholder, icon = "folder", action = "next" }, function(text, rcx)
		fn(model.resolve(default, text, if host then home else HOME), rcx)
	end)
end

-- Runs `fn` with the HOME of `host` (this machine's at once; a remote one's asked of its host half).
local function with_home(cx: WindowCx, host: string?, fn: (home: string?, cx: WindowCx) -> ())
	if host == nil then
		fn(HOME, cx)
		return
	end
	fs_at(cx, host, "home", "~", function(ok, home, err, _, hcx)
		if not ok or type(home) ~= "string" then
			hcx:toast("error", "Can't reach " .. host, err)
			return
		end
		fn(home, hcx)
	end)
end

-- Browses the remote `host`'s folders from `path`: up, use this folder, type a path, then its subfolders.
local function browse_remote(cx: WindowCx, host: string, home: string, path: string)
	fs_at(cx, host, "dirs", path, function(ok, names, err, extra, dcx)
		if not ok then
			dcx:toast("error", "Folder not listed", err)
			return
		end
		local is_git = type(extra) == "table" and extra.git == true
		local items: { PickItem } = {}
		if path ~= "/" then
			table.insert(items, { label = ".. (up)", detail = tilde_at(model.dirname(path), host, home), icon = "arrow-left", go = model.dirname(path) })
		end
		table.insert(items, {
			label = "Use this folder: " .. tilde_at(path, host, home),
			detail = if is_git then "Git repository" else nil,
			icon = if is_git then "branch" else "check",
			use = true,
		})
		table.insert(items, { label = "Type a path…", icon = "edit", typed = true })
		if type(names) == "table" then
			for _, name in names do
				if type(name) == "string" then
					table.insert(items, { label = name, icon = "folder", go = (if path == "/" then "" else path) .. "/" .. name })
				end
			end
		end
		ask_pick(dcx, { items = items, placeholder = (model.host_short(host) or host) .. ": " .. tilde_at(path, host, home), icon = "folder" }, function(item, pcx)
			local it = item :: any
			if it.use then
				admit_path(pcx, path, host)
			elseif it.typed then
				ask_path(pcx, "Project folder on " .. host, path, function(typed, tcx)
					admit_path(tcx, typed, host)
				end, host, home)
			elseif type(it.go) == "string" then
				browse_remote(pcx, host, home, it.go)
			end
		end)
	end)
end

local function browse_folder(cx: WindowCx)
	local host = host_now(cx)
	if host then
		with_home(cx, host, function(home, hcx)
			browse_remote(hcx, host :: string, home :: string, home :: string)
		end)
		return
	end
	local _, cwd = focused_cwd(cx)
	if not MACOS then
		ask_path(cx, "Project folder", cwd or HOME or "/", function(path, pcx)
			admit_path(pcx, path)
		end)
		return
	end
	tern.process.run({ "osascript", "-e", "POSIX path of (choose folder)" }, { timeout_ms = 600000 }, function(res, _)
		local path = trimmed(res.stdout)
		if res.status ~= 0 or path == "" then
			return
		end
		defer(function(dcx)
			admit_path(dcx, model.trim(path))
		end)
	end)
end

-- Whether the project `root` would become is named like one already there (said in a toast): checked before a
-- folder is made or cloned.
local function name_taken(cx: WindowCx, root: string): boolean
	local why = model.name_conflict(model.load(), model.basename(root))
	if why then
		cx:toast("error", "Project not added", why)
		return true
	end
	return false
end

-- Clones on the current host, into a folder of its HOME by default.
local function clone_project(cx: WindowCx)
	local host = host_now(cx)
	ask_text(cx, { placeholder = "https://github.com/user/repo.git", icon = "globe", action = "next" }, function(url, ucx)
		with_home(ucx, host, function(home, hcx)
			ask_path(hcx, "Parent folder", home or "/", function(parent, pcx)
				local name = string.gsub(string.match(url, "([^/:]+)/*$") or "project", "%.git$", "")
				local dest = parent .. "/" .. name
				if name_taken(pcx, dest) then
					return
				end
				pcx:toast("info", "Cloning...", url)
				git_on(S, host, { "clone", "--", url, dest }, function(res, _)
					defer(function(gcx)
						if res.timed_out then
							gcx:toast("error", "Clone timed out", "After 10 minutes; " .. tilde_at(dest, host, home) .. " may hold a partial clone to remove before retrying")
							return
						end
						if res.status ~= 0 then
							gcx:toast("error", "Clone failed", errtext(res))
							return
						end
						admit_path(gcx, dest, host)
					end)
				end, 600000)
			end, host, home)
		end)
	end)
end

-- Makes an empty repository on the current host, in its HOME by default.
local function create_project(cx: WindowCx)
	local host = host_now(cx)
	ask_text(cx, { placeholder = "my-project", icon = "plus", action = "next" }, function(name, ncx)
		with_home(ncx, host, function(home, hcx)
			ask_path(hcx, "Parent folder", home or "/", function(parent, pcx)
				local dest = parent .. "/" .. model.slug(name)
				if name_taken(pcx, dest) then
					return
				end
				fs_at(pcx, host, "exists", dest, function(eok, exists, eerr, _, ecx)
					if not eok then
						ecx:toast("error", "Project not created", eerr)
						return
					end
					if exists then
						ecx:toast("error", "Folder exists", tilde_at(dest, host, home))
						return
					end
					fs_at(ecx, host, "mkdir", dest, function(ok, _, err, _, mcx)
						if not ok then
							mcx:toast("error", "Project not created", err)
							return
						end
						git_on(S, host, { "init", "-q" }, function(res, _)
							defer(function(gcx)
								if res.status ~= 0 then
									gcx:toast("error", "Project not created", errtext(res))
									return
								end
								admit_path(gcx, dest, host)
							end)
						end, nil, dest)
					end)
				end)
			end, host, home)
		end)
	end)
end

-- Orca's "Add a project" start: browse, clone or create (on the current host).
local function add_project(cx: WindowCx)
	local host = host_now(cx)
	local where = if host then "on " .. host else "on this host"
	ask_pick(cx, {
		items = {
			{ label = "Browse folder", detail = "Existing Git repository or folder " .. where, icon = "folder-open", run = "browse" },
			{ label = "Clone from URL", detail = "Clone a remote Git repository" .. (if host then " " .. where else ""), icon = "globe", run = "clone" },
			{ label = "Create new project", detail = "Start from an empty folder" .. (if host then " " .. where else ""), icon = "plus", run = "create" },
		},
		placeholder = "Add a project",
		icon = "folder-plus",
	}, function(item, pcx)
		local run = (item :: any).run
		if run == "browse" then
			browse_folder(pcx)
		elseif run == "clone" then
			clone_project(pcx)
		else
			create_project(pcx)
		end
	end)
end

-- Orca's Remove Project: forgets it; its files, session and worktrees stay.
local function confirm_remove(cx: WindowCx, p: model.Project)
	ask_pick(cx, {
		items = {
			{ label = "Remove", detail = "This only removes " .. p.name .. " from Projects. It is still on your disk.", icon = "trash", confirm = true },
			{ label = "Cancel", icon = "x", confirm = false },
		},
		placeholder = "Remove Project",
		icon = "trash",
	}, function(choice, ccx)
		if not (choice :: any).confirm then
			return
		end
		S.state = model.load()
		local removed, keys = model.remove_project(S.state, p.id)
		if removed then
			model.save(S.state)
			S.ui = model.load_ui()
			S.ui.collapsed[p.id] = nil
			for _, k in keys do
				S.ui.pinned[k], S.ui.unread[k] = nil, nil
			end
			S.save_ui()
			S.changed(ccx)
		end
	end)
end

local function remove_project(cx: WindowCx)
	S.pick_project(cx, "Project to remove (files are kept)", confirm_remove)
end

-- Saves `edit` applied to project `id`, recolors its open agent tabs and redraws.
local function edit_project(cx: WindowCx, id: string, edit: (s: model.State) -> ())
	S.state = model.load()
	edit(S.state)
	model.save(S.state)
	local p = model.get(S.state, id)
	if p then
		for pane, pid in S.pane_project do
			local m = S.meta_of(pane)
			if pid == id and (m == nil or m.parent == nil) then
				S.color_tab(cx, pane, p)
			end
		end
	end
	S.refresh_side(cx)
end

local function color_items(p: model.Project): { PickItem }
	local items: { PickItem } = {}
	for _, c in model.COLORS do
		table.insert(items, {
			label = string.upper(string.sub(c, 1, 1)) .. string.sub(c, 2),
			group = "Color",
			icon = "palette",
			current = p.color == c,
			color = c,
		})
	end
	return items
end

-- Runs a color choice; true when it was handled (the caller reopens its picker).
local function apply_color(cx: WindowCx, p: model.Project, it: any, reopen: (cx: WindowCx) -> ()): boolean
	if it.color then
		edit_project(cx, p.id, function(s)
			model.set_color(s, p.id, it.color)
		end)
		reopen(cx)
		return true
	end
	return false
end

local function project_icon(cx: WindowCx, id: string)
	local p = model.get(model.load(), id)
	if p == nil then
		return
	end
	local project = p :: model.Project
	local function reopen(rcx: WindowCx)
		project_icon(rcx, id)
	end
	local items = color_items(project)
	local icon = project.icon
	for _, i in model.ICONS do
		table.insert(items, {
			label = i.label,
			group = "Icon",
			icon = i.name,
			current = if icon then icon.kind == "icon" and icon.name == i.name else i.name == "folder",
			set_icon = i.name,
		})
	end
	table.insert(items, { label = "Emoji…", detail = if icon and icon.kind == "emoji" then icon.emoji else nil, group = "Icon", icon = "sparkle", current = icon ~= nil and icon.kind == "emoji", run = "emoji" })
	table.insert(items, { label = "Reset", detail = "folder icon, no color", group = "Icon", icon = "refresh", run = "reset" })
	ask_pick(cx, { items = items, placeholder = "Change Project Icon · " .. project.name, icon = "palette" }, function(item, pcx)
		local it = item :: any
		if apply_color(pcx, project, it, reopen) then
			return
		end
		if it.set_icon then
			edit_project(pcx, id, function(s)
				model.set_icon(s, id, { kind = "icon", name = it.set_icon })
			end)
			reopen(pcx)
		elseif it.run == "emoji" then
			ask_text(pcx, { value = if icon and icon.kind == "emoji" then icon.emoji else nil, placeholder = "Emoji", icon = "sparkle", action = "set icon" }, function(text, tcx)
				edit_project(tcx, id, function(s)
					model.set_icon(s, id, { kind = "emoji", emoji = text })
				end)
				reopen(tcx)
			end)
		elseif it.run == "reset" then
			edit_project(pcx, id, function(s)
				model.set_icon(s, id, nil)
				model.set_color(s, id, "neutral")
			end)
			reopen(pcx)
		end
	end)
end

-- Renames a project (its id stays) and its session, which is named like it.
local function rename_project(cx: WindowCx, id: string)
	local p = model.get(model.load(), id)
	if p == nil then
		return
	end
	local old = (p :: model.Project).name
	local host = (p :: model.Project).host
	ask_text(cx, { value = old, placeholder = "Rename project", icon = "folder", action = "rename" }, function(name, rcx)
		if name == old then
			return
		end
		local session = session_named(rcx, old, host)
		if session and session_named(rcx, name, host) then
			rcx:toast("error", "Project not renamed", "a session named " .. name .. " exists")
			return
		end
		S.state = model.load()
		local ok, err = pcall(model.rename_project, S.state, id, name)
		if not ok then
			rcx:toast("error", "Project not renamed", tostring(err))
			return
		end
		model.save(S.state)
		if session then
			local renamed, rerr = pcall(function()
				rcx.sessions:rename((session :: ManagedSession).id, (model.get(S.state, id) :: model.Project).name)
			end)
			if not renamed then
				rcx:toast("error", "Session not renamed", tostring(rerr))
			end
		end
		S.changed(rcx)
	end)
end

local function project_settings(cx: WindowCx, id: string)
	local p = model.get(model.load(), id)
	if p == nil then
		return
	end
	local project = p :: model.Project
	local function reopen(rcx: WindowCx)
		project_settings(rcx, id)
	end
	local items: { PickItem } = { { label = "Rename", detail = project.name, group = "Project", icon = "doc", run = "rename" } }
	for _, c in color_items(project) do
		table.insert(items, c)
	end
	table.insert(items, {
		label = "New agents get a git worktree",
		detail = "beside the project, on a branch of their own",
		group = "Agents",
		icon = "branch",
		current = project.worktrees,
		run = "worktrees",
	})
	table.insert(items, { label = "Move up", group = "Order", icon = "arrow-left", run = "up" })
	table.insert(items, { label = "Move down", group = "Order", icon = "arrow-down", run = "down" })
	table.insert(items, { label = "Copy Path", detail = tilde(project.root), group = "Folder", icon = "copy", run = "copy" })
	if project.host then
		table.insert(items, { label = "Open terminal on " .. (model.host_short(project.host) or ""), detail = project.root, group = "Folder", icon = "terminal", run = "finder" })
	else
		table.insert(items, { label = "Open in Finder", group = "Folder", icon = "folder-open", run = "finder" })
	end
	ask_pick(cx, { items = items, placeholder = "Project Settings · " .. project.name, icon = "sliders" }, function(item, pcx)
		local it = item :: any
		if apply_color(pcx, project, it, reopen) then
			return
		end
		if it.run == "rename" then
			rename_project(pcx, id)
		elseif it.run == "worktrees" then
			edit_project(pcx, id, function(s)
				local q = model.get(s, id)
				if q then
					q.worktrees = not q.worktrees
				end
			end)
			reopen(pcx)
		elseif it.run == "up" or it.run == "down" then
			edit_project(pcx, id, function(s)
				model.move_project(s, id, if it.run == "up" then -1 else 1)
			end)
			reopen(pcx)
		elseif it.run == "copy" then
			pcx:copy(project.root)
		elseif it.run == "finder" then
			S.open_in_finder(pcx, project.root, project.host)
		end
	end)
end

-- Project groups -----------------------------------------------------------------------

local function new_group(cx: WindowCx, project_id: string)
	local p = model.get(model.load(), project_id)
	if p == nil then
		return
	end
	ask_text(cx, { value = (p :: model.Project).name .. " group", placeholder = "New Project Group", icon = "folder", action = "create" }, function(name, ncx)
		edit_project(ncx, project_id, function(s)
			model.add_group(s, name, project_id)
		end)
	end)
end

local function ungroup(cx: WindowCx, project_id: string)
	edit_project(cx, project_id, function(s)
		model.ungroup(s, project_id)
	end)
end

local function move_to_group(cx: WindowCx, project_id: string)
	S.state = model.load()
	local p = model.get(S.state, project_id)
	if p == nil or #S.state.groups == 0 then
		return
	end
	local items: { PickItem } = {}
	for _, g in S.state.groups do
		table.insert(items, { label = g.name, icon = "folder", current = p.group == g.id, group_id = g.id })
	end
	if p.group then
		table.insert(items, { label = "Remove from group", icon = "x", run = "ungroup" })
	end
	ask_pick(cx, { items = items, placeholder = "Move to group", icon = "folder-go" }, function(item, pcx)
		local it = item :: any
		if it.run == "ungroup" then
			ungroup(pcx, project_id)
		elseif it.group_id then
			edit_project(pcx, project_id, function(s)
				model.move_to_group(s, project_id, it.group_id)
			end)
		end
	end)
end

local function rename_group(cx: WindowCx, gid: string)
	local g = model.get_group(model.load(), gid)
	if g == nil then
		return
	end
	local old = (g :: model.Group).name
	ask_text(cx, { value = old, placeholder = "Rename Project Group", icon = "folder", action = "rename" }, function(name, rcx)
		if name == old then
			return
		end
		S.state = model.load()
		local ok, err = pcall(model.rename_group, S.state, gid, name)
		if not ok then
			rcx:toast("error", "Failed to rename group", tostring(err))
			return
		end
		model.save(S.state)
		S.refresh_side(rcx)
	end)
end

local function delete_group(cx: WindowCx, gid: string)
	S.state = model.load()
	local g = model.get_group(S.state, gid)
	if g == nil then
		return
	end
	local name = (g :: model.Group).name
	local n = model.group_size(S.state, gid)
	local items: { PickItem } = {
		{ label = "Delete group", detail = "Delete " .. name .. ". Its projects become ungrouped.", icon = "trash", run = "delete" },
	}
	if n > 0 then
		table.insert(items, {
			label = "Delete group and remove its " .. plural(n, "project"),
			detail = "Project folders on disk are not deleted.",
			icon = "trash",
			run = "remove",
		})
	end
	table.insert(items, { label = "Cancel", icon = "x", run = "cancel" })
	ask_pick(cx, { items = items, placeholder = "Delete Project Group", icon = "trash" }, function(item, pcx)
		local run = (item :: any).run
		if run == "cancel" then
			return
		end
		S.state = model.load()
		if model.delete_group(S.state, gid, run == "remove") then
			model.save(S.state)
			S.ui = model.load_ui()
			S.ui.collapsed["group:" .. gid] = nil
			S.save_ui()
			S.changed(pcx)
		end
	end)
end

local function group_menu(cx: WindowCx, gid: string)
	local g = model.get_group(model.load(), gid)
	if g == nil then
		return
	end
	ask_pick(cx, {
		items = {
			{ label = "Rename group", icon = "doc", run = "rename" },
			{ label = "Delete group", icon = "trash", run = "delete" },
		},
		placeholder = (g :: model.Group).name,
		icon = "folder",
	}, function(item, pcx)
		local run = (item :: any).run
		if run == "rename" then
			rename_group(pcx, gid)
		elseif run == "delete" then
			delete_group(pcx, gid)
		end
	end)
end

-- A project header's … button: its right-click menu as a picker.
local function project_menu(cx: WindowCx, id: string)
	S.state = model.load()
	local p = model.get(S.state, id)
	if p == nil then
		return
	end
	local project = p :: model.Project
	local items: { PickItem } = {
		{ label = "Project Settings", icon = "sliders", run = "settings" },
		{ label = "Change Project Icon", icon = "palette", run = "icon" },
		{ label = "New group from project", icon = "folder-plus", run = "new_group" },
	}
	if #S.state.groups > 0 then
		table.insert(items, { label = "Move to group…", icon = "folder-go", run = "move" })
	end
	if project.group then
		table.insert(items, { label = "Remove from group", icon = "x", run = "ungroup" })
	end
	local on = model.host_short(project.host)
	table.insert(items, { label = "Open session", detail = if on then project.name .. " · " .. on else project.name, icon = "folder-open", run = "open" })
	table.insert(items, { label = "Remove Project", icon = "trash", run = "remove" })
	ask_pick(cx, { items = items, placeholder = project.name, icon = "folder", action = "run" }, function(item, pcx)
		local run = (item :: any).run
		if run == "settings" then
			project_settings(pcx, id)
		elseif run == "icon" then
			project_icon(pcx, id)
		elseif run == "new_group" then
			new_group(pcx, id)
		elseif run == "move" then
			move_to_group(pcx, id)
		elseif run == "ungroup" then
			ungroup(pcx, id)
		elseif run == "open" then
			open_project(pcx, project)
		elseif run == "remove" then
			confirm_remove(pcx, project)
		end
	end)
end

-- List ---------------------------------------------------------------------------------

local function toggle_group(cx: WindowCx, id: string)
	S.ui = model.load_ui()
	S.ui.collapsed[id] = if S.ui.collapsed[id] then nil else true
	S.save_ui()
	S.refresh_side(cx)
end

-- Collapses every header (projects, groups, Pinned), or expands them all when all are collapsed.
local function collapse_all(cx: WindowCx)
	S.state = model.load()
	S.ui = model.load_ui()
	local ids: { string } = { "pinned" }
	for _, p in S.state.projects do
		table.insert(ids, p.id)
	end
	for _, g in S.state.groups do
		table.insert(ids, "group:" .. g.id)
	end
	model.collapse_all(S.ui, ids)
	S.save_ui()
	S.refresh_side(cx)
end

-- Installs this module's functions into the context.
return function(ctx: core.Ctx)
	S = ctx
	S.add_project = add_project
	S.collapse_all = collapse_all
	S.confirm_remove = confirm_remove
	S.delete_group = delete_group
	S.group_menu = group_menu
	S.move_to_group = move_to_group
	S.new_group = new_group
	S.open_project = open_project
	S.project_icon = project_icon
	S.project_menu = project_menu
	S.project_settings = project_settings
	S.remove_project = remove_project
	S.rename_group = rename_group
	S.toggle_group = toggle_group
	S.ungroup = ungroup
end
