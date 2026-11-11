--!strict
-- projects, data model: projects, agent metadata and their persistence in
-- `tern.kv` under `projects.v1`. Everything but `load` and `save` is pure, so
-- it runs (and is tested) without Tern.

local model = {}

model.KEY = "projects.v1"

export type Project = {
	-- Stable id (a slug of the first name), unique among projects.
	id: string,
	-- Display name; also the exact name of the project's Tern session.
	name: string,
	-- Absolute path of the project's root folder.
	root: string,
	-- Tab color of the project's agent tabs (a TabColor).
	color: string,
	-- New agents get a git worktree of their own on branch `agent/<slug>`.
	worktrees: boolean,
	-- os.time() when added.
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
	-- Branch the agent works on, `agent/<slug>`.
	branch: string?,
	-- Pane of the parent agent, for spawned subagents.
	parent: number?,
	-- Ask the parent with the child's last message when the child's turn ends.
	report_back: boolean?,
	-- os.time() when started.
	started: number,
	-- The agent's block closed; kept only while it still owns a worktree to clean up.
	closed: boolean?,
}

export type State = {
	projects: { Project },
	-- Keyed by tostring(pane).
	agents: { [string]: AgentMeta },
}

model.COLORS = { "blue", "green", "purple", "orange", "teal", "pink", "yellow", "red" }

local function now(): number
	return os.time()
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

-- A lowercase ASCII slug of `text`: words joined by `-`, at most 40 bytes, never empty.
function model.slug(text: string): string
	local s = string.lower(text)
	s = string.gsub(s, "[^%w]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.sub(s, 1, 40)
	s = string.gsub(s, "%-+$", "")
	if s == "" then
		return "agent"
	end
	return s
end

-- A short title for a task: its first words, at most 32 bytes.
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
	if out == "" then
		out = string.sub(line, 1, 32)
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

-- Path of the worktree for agent slug `slug`.
function model.worktree_path(project: Project, slug: string): string
	return model.worktrees_dir(project) .. "/" .. slug
end

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
	return { projects = {}, agents = {} }
end

-- Repairs a decoded value into a State (unknown shapes become empty).
function model.normalize(raw: any): State
	local state = model.empty()
	if type(raw) ~= "table" then
		return state
	end
	if type(raw.projects) == "table" then
		for _, p in raw.projects do
			if type(p) == "table" and type(p.id) == "string" and type(p.name) == "string" and type(p.root) == "string" then
				table.insert(state.projects, {
					id = p.id,
					name = p.name,
					root = p.root,
					color = if type(p.color) == "string" then p.color else "blue",
					worktrees = p.worktrees == true,
					created = if type(p.created) == "number" then p.created else 0,
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
	tern.kv.set(model.KEY, { projects = tern.json.array(state.projects), agents = state.agents })
end

export type NewProject = {
	name: string,
	root: string,
	color: string?,
	worktrees: boolean?,
}

-- Adds a project; errors when its name or root is taken. Returns it.
function model.add_project(state: State, spec: NewProject): Project
	local name = string.match(spec.name, "^%s*(.-)%s*$") or ""
	if name == "" then
		error("project name is empty", 0)
	end
	local root = model.trim(spec.root)
	if string.sub(root, 1, 1) ~= "/" then
		error("project root must be an absolute path: " .. root, 0)
	end
	for _, p in state.projects do
		if p.name == name then
			error("a project named " .. name .. " exists", 0)
		end
		if p.root == root then
			error(p.name .. " already has root " .. root, 0)
		end
	end
	local base = model.slug(name)
	local id, n = base, 1
	while model.get(state, id) do
		n += 1
		id = base .. "-" .. n
	end
	local project: Project = {
		id = id,
		name = name,
		root = root,
		color = spec.color or model.COLORS[(#state.projects % #model.COLORS) + 1],
		worktrees = spec.worktrees ~= false,
		created = now(),
	}
	table.insert(state.projects, project)
	return project
end

-- Removes project `id` and its agents' metadata; true when it existed. Never touches files.
function model.remove_project(state: State, id: string): boolean
	for i, p in state.projects do
		if p.id == id then
			table.remove(state.projects, i)
			for key, a in state.agents do
				if a.project == id then
					state.agents[key] = nil
				end
			end
			return true
		end
	end
	return false
end

-- Sidebar UI state, stored per user (every window shares it) under `projects.ui.v1`.
model.UI_KEY = "projects.ui.v1"

export type Ui = {
	-- The sidebar shows.
	visible: boolean,
	-- Its width in terminal cells; nil until fitted or dragged (then the default width applies).
	want_cols: number?,
	-- Project id → its group is collapsed.
	collapsed: { [string]: boolean },
}

function model.empty_ui(): Ui
	return { visible = false, collapsed = {} }
end

-- Repairs a decoded value into a Ui (unknown shapes become the defaults).
function model.normalize_ui(raw: any): Ui
	local ui = model.empty_ui()
	if type(raw) ~= "table" then
		return ui
	end
	ui.visible = raw.visible == true
	if type(raw.want_cols) == "number" and raw.want_cols > 0 then
		ui.want_cols = math.floor(raw.want_cols + 0.5)
	end
	if type(raw.collapsed) == "table" then
		for id, v in raw.collapsed do
			if type(id) == "string" and v == true then
				ui.collapsed[id] = true
			end
		end
	end
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
	tern.kv.set(model.UI_KEY, { visible = ui.visible, want_cols = ui.want_cols, collapsed = ui.collapsed })
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

-- A terminal cell's width in em of the font size, as a split's share measures it in Tern 0.9.16 (13px font:
-- 36 cells made a 313px pane, its gutter included).
model.CELL_EM = 0.67

-- Width in cells of `px` pixels for a monospace font of `font_size` px.
function model.cols_for_px(px: number, font_size: number): number
	return math.max(1, math.floor(px / (font_size * model.CELL_EM) + 0.5))
end

return model
