--!strict
-- projects, data model: projects, project groups, agent metadata and their
-- persistence in `tern.kv` under `projects.v1`, the sidebar's UI state under
-- `projects.ui.v1`, and the pure ordering/sorting/filtering of sidebar cards.
-- Everything but `load*` and `save*` is pure, so it runs (and is tested)
-- without Tern.

local model = {}

model.KEY = "projects.v1"

-- A project's icon: a Tern icon name from `model.ICONS`, or an emoji. nil draws `folder`.
export type ProjectIcon = { kind: "icon" | "emoji", name: string?, emoji: string? }

export type Project = {
	-- Stable id (a slug of the first name), unique among projects.
	id: string,
	-- Display name; also the exact name of the project's Tern session.
	name: string,
	-- Absolute path of the project's root folder.
	root: string,
	-- One of `model.COLORS` (see `model.normalize_color`).
	color: string,
	icon: ProjectIcon?,
	-- New agents get a git worktree of their own.
	worktrees: boolean,
	-- os.time() when added.
	created: number,
	-- Id of the project group it sits in.
	group: string?,
}

-- A named run of projects in the sidebar (Orca's project groups).
export type Group = {
	id: string,
	name: string,
	created: number,
}

export type AgentMeta = {
	-- Project id.
	project: string,
	-- Short title: the agent's tab name and dashboard label.
	title: string,
	-- The prompt the agent was started with.
	task: string?,
	-- Absolute path of the worktree this agent owns (spawned subagents share their parent's and own none).
	worktree: string?,
	-- Branch the agent's worktree was created on.
	branch: string?,
	-- Pane of the parent agent, for spawned subagents.
	parent: number?,
	-- Ask the parent with the child's last message when the child's turn ends.
	report_back: boolean?,
	-- os.time() when started.
	started: number,
	-- The agent's block closed while it owned a worktree: the sidebar shows it as a sleeping card.
	closed: boolean?,
	-- os.time() when it closed.
	closed_at: number?,
	-- It was interrupted (stopped mid-turn) when it went to sleep.
	interrupted: boolean?,
}

export type State = {
	projects: { Project },
	groups: { Group },
	-- Keyed by tostring(pane).
	agents: { [string]: AgentMeta },
}

-- Orca's project color presets; `neutral` (the default) draws no color.
model.COLORS = { "neutral", "red", "orange", "yellow", "green", "teal", "purple", "pink" }

-- Orca's project icon choices that Tern has an icon for (Package, Work, Company and Shapes have none).
model.ICONS = {
	{ name = "folder", label = "Folder" },
	{ name = "code", label = "Code" },
	{ name = "terminal", label = "Terminal" },
	{ name = "agent", label = "Agent" },
	{ name = "database", label = "Database" },
	{ name = "globe", label = "Web" },
	{ name = "server", label = "Server" },
	{ name = "cpu", label = "Compute" },
	{ name = "layers", label = "Layers" },
	{ name = "braces", label = "API" },
	{ name = "rocket", label = "Launch" },
	{ name = "wrench", label = "Tools" },
	{ name = "palette", label = "Design" },
	{ name = "gauge", label = "Metrics" },
	{ name = "sparkle", label = "AI" },
	{ name = "box", label = "Box" },
}

local function now(): number
	return os.time()
end

local function strip(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

-- `path` without trailing slashes (`/` stays `/`).
function model.trim(path: string): string
	local out = string.gsub(path, "(.)/+$", "%1")
	return out
end

-- Last component of `path`.
function model.basename(path: string): string
	local p = model.trim(path)
	return string.match(p, "([^/]+)$") or p
end

-- `path` without its last component (`/a/b` → `/a`, `/a` → `/`).
function model.dirname(path: string): string
	local p = model.trim(path)
	local dir = string.match(p, "^(.*)/[^/]*$")
	if dir == nil or dir == "" then
		return "/"
	end
	return dir
end

-- `path` with macOS's `/private` prefix of `/tmp`, `/var` and `/etc` dropped, so real and logical paths compare equal.
function model.canon(path: string): string
	local p = model.trim(path)
	local rest = string.match(p, "^/private(/[^/]+)")
	if rest == "/tmp" or rest == "/var" or rest == "/etc" then
		return string.sub(p, 9)
	end
	return p
end

-- Whether `path` is `root` or inside it.
function model.inside(path: string, root: string): boolean
	local p, r = model.canon(path), model.canon(root)
	return p == r or r == "/" or string.sub(p, 1, #r + 1) == r .. "/"
end

-- `path` made absolute against `base` with `.`/`..` folded logically (no symlinks resolved); `~` is `home`.
function model.resolve(base: string, path: string, home: string?): string
	local p = path
	if home and (p == "~" or string.sub(p, 1, 2) == "~/") then
		p = home .. string.sub(p, 2)
	elseif string.sub(p, 1, 1) ~= "/" then
		p = base .. "/" .. p
	end
	local parts: { string } = {}
	for part in string.gmatch(p, "[^/]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- Non-ASCII code points that are punctuation, symbols, emoji or invisible formatting rather than letters or
-- digits: an approximation of `[^\p{L}\p{N}]` (Luau has no Unicode classes) covering the common blocks.
local NOT_WORD: { { number } } = {
	{ 0x80, 0xA9 },
	{ 0xAB, 0xB1 },
	{ 0xB4, 0xB4 },
	{ 0xB6, 0xB8 },
	{ 0xBB, 0xBB },
	{ 0xBF, 0xBF },
	{ 0xD7, 0xD7 },
	{ 0xF7, 0xF7 },
	{ 0x2000, 0x206F },
	{ 0x20A0, 0x20CF },
	{ 0x2190, 0x2BFF },
	{ 0x2E00, 0x2E7F },
	{ 0x3000, 0x3004 },
	{ 0x3008, 0x303F },
	{ 0xFE00, 0xFE0F },
	{ 0xFE30, 0xFE4F },
	{ 0xFF00, 0xFF0F },
	{ 0xFF1A, 0xFF20 },
	{ 0xFF3B, 0xFF40 },
	{ 0xFF5B, 0xFF65 },
	{ 0xFFF0, 0xFFFF },
	{ 0x1F000, 0x1FAFF },
	{ 0xE0000, 0xE007F },
}

local function word_cp(cp: number): boolean
	if cp < 0x80 then
		local c = string.char(cp)
		return string.match(c, "[%w%._%-]") ~= nil
	end
	for _, r in NOT_WORD do
		if cp >= r[1] and cp <= r[2] then
			return false
		end
	end
	return true
end

-- Orca's worktree-name sanitizer: runs of anything but letters, digits, `.`, `_` and `-` become `-`, `-` and
-- `.` runs collapse, leading/trailing `.`/`-` go. Case and non-ASCII letters are kept. At most 40 code points,
-- never empty (`agent`).
function model.slug(text: string): string
	local src = strip(text)
	if utf8.len(src) == nil then
		-- Not UTF-8: keep the ASCII.
		src = string.gsub(src, "[\128-\255]", "-")
	end
	local out: { string } = {}
	local count = 0
	local sep = false
	for _, cp in utf8.codes(src) do
		if word_cp(cp) then
			if sep and #out > 0 then
				table.insert(out, "-")
				count += 1
			end
			sep = false
			if count >= 40 then
				break
			end
			table.insert(out, utf8.char(cp))
			count += 1
		else
			sep = true
		end
		if count >= 40 then
			break
		end
	end
	local s = table.concat(out)
	s = string.gsub(s, "%-%-+", "-")
	s = string.gsub(s, "%.%.+", ".")
	s = string.gsub(s, "^[%.%-]+", "")
	s = string.gsub(s, "[%.%-]+$", "")
	if s == "" then
		return "agent"
	end
	return s
end

-- A short title for a task: its first words, at most 32 bytes (never a cut character).
function model.title_of(task: string): string
	local line = string.match(task, "^%s*([^\n]*)") or ""
	local out = ""
	for word in string.gmatch(line, "%S+") do
		local next_out = if out == "" then word else out .. " " .. word
		if #next_out > 32 then
			break
		end
		out = next_out
	end
	if out == "" and line ~= "" then
		-- n = 0: the start of the character holding byte 33 (never raises on a continuation byte).
		local cut = if utf8.len(line) and #line > 32 then utf8.offset(line, 0, 33) else nil
		out = if cut then string.sub(line, 1, cut - 1) else string.sub(line, 1, 32)
	end
	if out == "" then
		return "agent"
	end
	return out
end

-- Folder holding a project's worktrees: `<root>/../.tern-worktrees/<project id>`.
function model.worktrees_dir(project: Project): string
	local parent = model.dirname(project.root)
	local base = if parent == "/" then "" else parent
	return base .. "/.tern-worktrees/" .. project.id
end

-- Path of the worktree named `name`.
function model.worktree_path(project: Project, name: string): string
	return model.worktrees_dir(project) .. "/" .. name
end

-- Branch for worktree `name`: `<prefix>/<name>`, or just `name` without a prefix (Orca's git-username prefix).
function model.branch_name(prefix: string?, name: string): string
	local p = if prefix then strip(prefix) else ""
	if p == "" then
		return name
	end
	return p .. "/" .. name
end

-- Colors ------------------------------------------------------------------------

-- A stored color made valid: a preset, anything else (legacy `blue`, hex, junk) `neutral`. Tern draws no
-- inline styles, so only the presets render.
function model.normalize_color(v: any): string
	if type(v) ~= "string" then
		return "neutral"
	end
	local s = string.lower(strip(v))
	return if table.find(model.COLORS, s) then s else "neutral"
end

-- The TabColor of a project's agent tabs: its preset, none for neutral.
function model.tab_color(project: Project): string?
	return if project.color == "neutral" then nil else project.color
end

local function icon_known(name: string): boolean
	for _, i in model.ICONS do
		if i.name == name then
			return true
		end
	end
	return false
end

-- A stored icon made valid (nil when unknown or malformed); the old `bot` (which Tern doesn't draw) is `agent`.
function model.normalize_icon(v: any): ProjectIcon?
	if type(v) ~= "table" then
		return nil
	end
	local name = if v.name == "bot" then "agent" else v.name
	if v.kind == "icon" and type(name) == "string" and icon_known(name) then
		return { kind = "icon", name = name }
	end
	if v.kind == "emoji" and type(v.emoji) == "string" then
		local e = strip(v.emoji)
		if e ~= "" and #e <= 32 then
			return { kind = "emoji", emoji = e }
		end
	end
	return nil
end

-- Projects ------------------------------------------------------------------------

-- The project with id `id`.
function model.get(state: State, id: string): Project?
	for _, p in state.projects do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- The project `path` belongs to: inside its root or one of its worktrees; the longest match wins.
function model.project_for_path(state: State, path: string?): Project?
	if path == nil or path == "" then
		return nil
	end
	local best: Project? = nil
	local best_len = -1
	for _, p in state.projects do
		for _, root in { p.root, model.worktrees_dir(p) } do
			if model.inside(path, root) and #root > best_len then
				best, best_len = p, #root
			end
		end
	end
	return best
end

-- An empty state.
function model.empty(): State
	return { projects = {}, groups = {}, agents = {} }
end

-- Repairs a decoded value into a State (unknown shapes become empty, dangling group ids are dropped).
function model.normalize(raw: any): State
	local state = model.empty()
	if type(raw) ~= "table" then
		return state
	end
	local group_ids: { [string]: boolean } = {}
	if type(raw.groups) == "table" then
		for _, g in raw.groups do
			if type(g) == "table" and type(g.id) == "string" and type(g.name) == "string" and not group_ids[g.id] then
				group_ids[g.id] = true
				table.insert(state.groups, { id = g.id, name = g.name, created = if type(g.created) == "number" then g.created else 0 })
			end
		end
	end
	if type(raw.projects) == "table" then
		for _, p in raw.projects do
			if type(p) == "table" and type(p.id) == "string" and type(p.name) == "string" and type(p.root) == "string" then
				table.insert(state.projects, {
					id = p.id,
					name = p.name,
					root = p.root,
					color = model.normalize_color(p.color),
					icon = model.normalize_icon(p.icon),
					worktrees = p.worktrees == true,
					created = if type(p.created) == "number" then p.created else 0,
					group = if type(p.group) == "string" and group_ids[p.group] then p.group else nil,
				})
			end
		end
	end
	if type(raw.agents) == "table" then
		for key, a in raw.agents do
			if type(a) == "table" and type(a.project) == "string" and type(a.title) == "string" then
				state.agents[tostring(key)] = {
					project = a.project,
					title = a.title,
					task = if type(a.task) == "string" then a.task else nil,
					worktree = if type(a.worktree) == "string" then a.worktree else nil,
					branch = if type(a.branch) == "string" then a.branch else nil,
					parent = if type(a.parent) == "number" then a.parent else nil,
					report_back = if type(a.report_back) == "boolean" then a.report_back else nil,
					started = if type(a.started) == "number" then a.started else 0,
					closed = if a.closed == true then true else nil,
					closed_at = if type(a.closed_at) == "number" then a.closed_at else nil,
					interrupted = if a.interrupted == true then true else nil,
				}
			end
		end
	end
	return state
end

-- Reads the state from `tern.kv` (empty when missing or unreadable).
function model.load(): State
	local ok, raw = pcall(tern.kv.get, model.KEY)
	if not ok then
		tern.log.warn("projects: kv read failed", raw)
		return model.empty()
	end
	return model.normalize(raw)
end

-- Writes the state to `tern.kv`.
function model.save(state: State)
	tern.kv.set(model.KEY, {
		projects = tern.json.array(state.projects),
		groups = tern.json.array(state.groups),
		agents = state.agents,
	})
end

export type NewProject = {
	name: string,
	root: string,
	color: string?,
	worktrees: boolean?,
}

-- Why `name` (trimmed) can't name a new project or project `except`: empty or taken; nil when it can.
function model.name_conflict(state: State, name: string, except: string?): string?
	local n = strip(name)
	if n == "" then
		return "project name is empty"
	end
	for _, p in state.projects do
		if p.name == n and p.id ~= except then
			return "a project named " .. n .. " exists"
		end
	end
	return nil
end

-- Renames project `id` (its id stays); errors on an empty or taken name, false for an unknown project.
function model.rename_project(state: State, id: string, name: string): boolean
	local p = model.get(state, id)
	if p == nil then
		return false
	end
	local why = model.name_conflict(state, name, id)
	if why then
		error(why, 0)
	end
	p.name = strip(name)
	return true
end

-- Adds a project; errors when its name or root is taken. Returns it.
function model.add_project(state: State, spec: NewProject): Project
	local name = strip(spec.name)
	local why = model.name_conflict(state, name)
	if why then
		error(why, 0)
	end
	local root = model.trim(spec.root)
	if string.sub(root, 1, 1) ~= "/" then
		error("project root must be an absolute path: " .. root, 0)
	end
	for _, p in state.projects do
		if p.root == root then
			error(p.name .. " already has root " .. root, 0)
		end
	end
	-- Ids stay lowercase (the slug keeps case for worktree names).
	local base = string.lower(model.slug(name))
	local id, n = base, 1
	while model.get(state, id) do
		n += 1
		id = base .. "-" .. n
	end
	local project: Project = {
		id = id,
		name = name,
		root = root,
		color = model.normalize_color(spec.color),
		worktrees = spec.worktrees ~= false,
		created = now(),
	}
	table.insert(state.projects, project)
	return project
end

-- Removes project `id` and its agents' metadata; returns whether it existed and the removed agent keys.
-- Never touches files.
function model.remove_project(state: State, id: string): (boolean, { string })
	local keys: { string } = {}
	for i, p in state.projects do
		if p.id == id then
			table.remove(state.projects, i)
			for key, a in state.agents do
				if a.project == id then
					state.agents[key] = nil
					table.insert(keys, key)
				end
			end
			return true, keys
		end
	end
	return false, keys
end

-- Sets a project's color (normalized); false for an unknown project.
function model.set_color(state: State, id: string, color: string): boolean
	local p = model.get(state, id)
	if p == nil then
		return false
	end
	p.color = model.normalize_color(color)
	return true
end

-- Sets (or with nil resets) a project's icon; false for an unknown project or an invalid icon.
function model.set_icon(state: State, id: string, icon: ProjectIcon?): boolean
	local p = model.get(state, id)
	if p == nil then
		return false
	end
	if icon == nil then
		p.icon = nil
		return true
	end
	local valid = model.normalize_icon(icon)
	if valid == nil then
		return false
	end
	p.icon = valid
	return true
end

-- Groups --------------------------------------------------------------------------

function model.get_group(state: State, id: string): Group?
	for _, g in state.groups do
		if g.id == id then
			return g
		end
	end
	return nil
end

local function group_named(state: State, name: string, except: string?): Group?
	for _, g in state.groups do
		if g.name == name and g.id ~= except then
			return g
		end
	end
	return nil
end

-- Orca's name for a group left blank.
model.UNTITLED_GROUP = "Untitled group"

local function group_name(name: string): string
	local n = strip(name)
	return if n == "" then model.UNTITLED_GROUP else n
end

-- Creates a group named `name` (blank: Untitled group; made unique with ` 2`, ` 3`, …) last among the groups,
-- and moves project `project_id` into it when given. Returns the group.
function model.add_group(state: State, name: string, project_id: string?): Group
	local base_name = group_name(name)
	local unique, n = base_name, 1
	while group_named(state, unique) do
		n += 1
		unique = base_name .. " " .. n
	end
	local base = string.lower(model.slug(unique))
	local id, k = base, 1
	while model.get_group(state, id) do
		k += 1
		id = base .. "-" .. k
	end
	local group: Group = { id = id, name = unique, created = now() }
	table.insert(state.groups, group)
	if project_id then
		model.move_to_group(state, project_id, id)
	end
	return group
end

local function index_of(state: State, id: string): number?
	for i, p in state.projects do
		if p.id == id then
			return i
		end
	end
	return nil
end

-- Puts a project in group `group_id` (nil: ungrouped) at the end of that bucket's manual order. False when
-- either is unknown or it is there already.
function model.move_to_group(state: State, project_id: string, group_id: string?): boolean
	local i = index_of(state, project_id)
	if i == nil or (group_id ~= nil and model.get_group(state, group_id) == nil) then
		return false
	end
	local p = state.projects[i :: number]
	if p.group == group_id then
		return false
	end
	table.remove(state.projects, i)
	p.group = group_id
	-- Manual order is the stored order, so the end of the bucket is after its last member.
	local at = #state.projects + 1
	if group_id ~= nil then
		for j, q in state.projects do
			if q.group == group_id then
				at = j + 1
			end
		end
	end
	table.insert(state.projects, at, p)
	return true
end

-- Takes a project out of its group; false when it was in none.
function model.ungroup(state: State, project_id: string): boolean
	return model.move_to_group(state, project_id, nil)
end

-- Swaps a project with its neighbour `delta` (-1 up, 1 down) in its bucket's manual order; false at an end.
function model.move_project(state: State, project_id: string, delta: number): boolean
	local i = index_of(state, project_id)
	if i == nil then
		return false
	end
	local p = state.projects[i :: number]
	local j = (i :: number) + delta
	while state.projects[j] and state.projects[j].group ~= p.group do
		j += delta
	end
	local q = state.projects[j]
	if q == nil then
		return false
	end
	state.projects[i :: number], state.projects[j] = q, p
	return true
end

-- Renames a group (blank: Untitled group); errors on a taken name, false for an unknown group.
function model.rename_group(state: State, id: string, name: string): boolean
	local g = model.get_group(state, id)
	if g == nil then
		return false
	end
	local new_name = group_name(name)
	if group_named(state, new_name, id) then
		error("a group named " .. new_name .. " exists", 0)
	end
	g.name = new_name
	return true
end

-- Deletes a group. Its projects become ungrouped, or with `remove_projects` are removed (files untouched).
-- False for an unknown group.
function model.delete_group(state: State, id: string, remove_projects: boolean?): boolean
	for i, g in state.groups do
		if g.id == id then
			table.remove(state.groups, i)
			local members: { string } = {}
			for _, p in state.projects do
				if p.group == id then
					table.insert(members, p.id)
				end
			end
			for _, pid in members do
				if remove_projects then
					model.remove_project(state, pid)
				else
					model.ungroup(state, pid)
				end
			end
			return true
		end
	end
	return false
end

-- The number of projects in group `id`.
function model.group_size(state: State, id: string): number
	local n = 0
	for _, p in state.projects do
		if p.group == id then
			n += 1
		end
	end
	return n
end

-- Ordering --------------------------------------------------------------------------

-- What sorting and filtering read of a sidebar card.
export type Card = {
	-- tostring of the pane, or the record key of a sleeping card: the key of pins and unread marks.
	key: string,
	pane: number,
	title: string,
	-- idle | working | waiting_input | exited | sleeping
	state: string,
	result: string?,
	primary: boolean?,
	started: number?,
	last_activity: number?,
	unread: boolean?,
}

-- Orca's Recent create grace: a new card ranks at least `started + CREATE_GRACE` for that long.
model.CREATE_GRACE = 5 * 60

local function recent_of(c: Card, t: number): number
	local last = c.last_activity or c.started or 0
	local s = c.started
	if s == nil or t >= s + model.CREATE_GRACE then
		return last
	end
	return math.max(last, s + model.CREATE_GRACE)
end

-- Orca's Agent Activity classes: needs you, then unseen finished turns, then working, then the rest.
local function activity_class(c: Card): number
	if c.state == "waiting_input" then
		return 1
	end
	if c.unread and (c.result == "done" or c.result == "failed") then
		return 2
	end
	if c.state == "working" then
		return 3
	end
	return 5
end

local function by_label(a: Card, b: Card): boolean
	local la, lb = string.lower(a.title), string.lower(b.title)
	if la ~= lb then
		return la < lb
	end
	return a.pane < b.pane
end

-- Sorts cards in place by `by` (name | activity | recent | manual) at time `t`. Recent puts primary cards
-- first; manual is creation order.
function model.sort_cards<T>(cards: { T }, by: string, t: number, read: (T) -> Card)
	table.sort(cards, function(x: T, y: T): boolean
		local a, b = read(x), read(y)
		if by == "name" then
			return by_label(a, b)
		elseif by == "activity" then
			local ca, cb = activity_class(a), activity_class(b)
			if ca ~= cb then
				return ca < cb
			end
			local ra, rb = recent_of(a, t), recent_of(b, t)
			if ra ~= rb then
				return ra > rb
			end
			return by_label(a, b)
		elseif by == "manual" then
			local sa, sb = a.started or 0, b.started or 0
			if sa ~= sb then
				return sa < sb
			end
			return a.pane < b.pane
		end
		if (a.primary == true) ~= (b.primary == true) then
			return a.primary == true
		end
		local ra, rb = recent_of(a, t), recent_of(b, t)
		if ra ~= rb then
			return ra > rb
		end
		return by_label(a, b)
	end)
end

-- Whether a card passes the sidebar's filters.
function model.visible(c: Card, ui: Ui): boolean
	return not (ui.hide_sleeping and c.state == "sleeping")
end

-- The number of filters on (the badge on the options button).
function model.filter_count(ui: Ui): number
	return if ui.hide_sleeping then 1 else 0
end

-- Filters `cards`, takes the pinned ones out and sorts both lists per `ui`.
function model.arrange<T>(cards: { T }, ui: Ui, t: number, read: (T) -> Card): ({ T }, { T })
	local pinned: { T } = {}
	local rest: { T } = {}
	for _, x in cards do
		local c = read(x)
		if model.visible(c, ui) then
			table.insert(if ui.pinned[c.key] then pinned else rest, x)
		end
	end
	model.sort_cards(pinned, ui.sort_by, t, read)
	model.sort_cards(rest, ui.sort_by, t, read)
	return pinned, rest
end

-- The projects in sidebar order, Orca's: every group's projects (groups in stored order), then the ungrouped
-- ones. Inside each run, `order` manual is the stored order and recent puts the newest `activity[id]` first,
-- projects without activity after, ties in stored order. Groups never sort by recency.
function model.order_projects(state: State, order: string, activity: { [string]: number }): { Project }
	local rank: { [string]: number } = {}
	for i, p in state.projects do
		rank[p.id] = i
	end
	-- A copy by hand: `save` tags the list as a JSON array (a protected metatable `table.clone` refuses).
	local list: { Project } = {}
	for _, p in state.projects do
		table.insert(list, p)
	end
	if order == "recent" then
		table.sort(list, function(a: Project, b: Project): boolean
			local ta, tb = activity[a.id], activity[b.id]
			if (ta ~= nil) ~= (tb ~= nil) then
				return ta ~= nil
			end
			if ta and tb and ta ~= tb then
				return ta > tb
			end
			return rank[a.id] < rank[b.id]
		end)
	end
	local out: { Project } = {}
	for _, g in state.groups do
		for _, p in list do
			if p.group == g.id then
				table.insert(out, p)
			end
		end
	end
	for _, p in list do
		if p.group == nil then
			table.insert(out, p)
		end
	end
	return out
end

-- Sidebar UI state ------------------------------------------------------------------

-- Per user (every window shares it), under `projects.ui.v1`.
model.UI_KEY = "projects.ui.v1"

export type Ui = {
	-- The sidebar shows.
	visible: boolean,
	-- Its width in px; nil until the user drags it (then the default width applies).
	want_px: number?,
	-- Collapsed groups: project id, `pinned` or `group:<id>`.
	collapsed: { [string]: boolean },
	-- The list shown: project cards, or the Activity view of every agent.
	body: string,
	-- project | none
	group_by: string,
	-- name | activity | recent | manual
	sort_by: string,
	-- manual | recent
	project_order: string,
	-- Card display toggles.
	show_branch: boolean,
	show_agents: boolean,
	show_models: boolean,
	hide_sleeping: boolean,
	-- Card key (see Card.key) → pinned.
	pinned: { [string]: boolean },
	-- Card key → marked unread.
	unread: { [string]: boolean },
	-- Delete workspaces without the confirmation.
	skip_delete_confirm: boolean,
}

local CHOICES: { [string]: { string } } = {
	body = { "workspaces", "agents" },
	group_by = { "project", "none" },
	sort_by = { "recent", "name", "activity", "manual" },
	project_order = { "manual", "recent" },
}

function model.empty_ui(): Ui
	return {
		visible = false,
		collapsed = {},
		body = "workspaces",
		group_by = "project",
		sort_by = "recent",
		project_order = "manual",
		show_branch = false,
		show_agents = true,
		show_models = true,
		hide_sleeping = false,
		pinned = {},
		unread = {},
		skip_delete_confirm = false,
	}
end

local function flags(raw: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(raw) == "table" then
		for k, v in raw do
			if type(k) == "string" and v == true then
				out[k] = true
			end
		end
	end
	return out
end

local function choice(raw: any, field: string, default: string): string
	local v = raw[field]
	if type(v) == "string" and table.find(CHOICES[field], v) then
		return v
	end
	return default
end

-- Repairs a decoded value into a Ui (unknown shapes become the defaults).
function model.normalize_ui(raw: any): Ui
	local ui = model.empty_ui()
	if type(raw) ~= "table" then
		return ui
	end
	ui.visible = raw.visible == true
	if type(raw.want_px) == "number" and raw.want_px > 0 then
		ui.want_px = math.floor(raw.want_px + 0.5)
	end
	ui.collapsed = flags(raw.collapsed)
	ui.body = choice(raw, "body", ui.body)
	ui.group_by = choice(raw, "group_by", ui.group_by)
	ui.sort_by = choice(raw, "sort_by", ui.sort_by)
	ui.project_order = choice(raw, "project_order", ui.project_order)
	ui.show_branch = raw.show_branch == true
	ui.show_agents = raw.show_agents ~= false
	ui.show_models = raw.show_models ~= false
	ui.hide_sleeping = raw.hide_sleeping == true
	ui.pinned = flags(raw.pinned)
	ui.unread = flags(raw.unread)
	ui.skip_delete_confirm = raw.skip_delete_confirm == true
	return ui
end

function model.load_ui(): Ui
	local ok, raw = pcall(tern.kv.get, model.UI_KEY)
	if not ok then
		tern.log.warn("projects: kv read failed", raw)
		return model.empty_ui()
	end
	return model.normalize_ui(raw)
end

function model.save_ui(ui: Ui)
	tern.kv.set(model.UI_KEY, ui)
end

-- Collapses every group in `ids`, or expands them all when all already are.
function model.collapse_all(ui: Ui, ids: { string })
	local all = #ids > 0
	for _, id in ids do
		if not ui.collapsed[id] then
			all = false
		end
	end
	for _, id in ids do
		ui.collapsed[id] = if all then nil else true
	end
end

-- Moves a card's pin and unread mark to a new key (a woken sleeping card gets a new pane).
function model.rekey_ui(ui: Ui, old: string, new: string)
	ui.pinned[new], ui.pinned[old] = ui.pinned[old], nil
	ui.unread[new], ui.unread[old] = ui.unread[old], nil
end

-- A terminal cell's width in em of the font size, as a split's share measures it in Tern 0.9.16 (13px font:
-- a 32.1-cell share of a 175-cell tab drew a 275px sidebar).
model.CELL_EM = 0.658

return model
