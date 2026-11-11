--!strict
-- projects, omp-internal subagents: reads the `agent`-kind nodes omp draws
-- (one per task-tool subagent) out of an agent block's TSP surface tree, as
-- `cx.session:surface(pane, {as = "table"})` returns it. Pure: no `tern`.
--
-- Shape captured from omp 18.18.8 in Tern 0.9.16 (tests/fixtures): each task
-- tool call is a `tool` node (role `omp.tool.task`) under `main`; its children
-- are a `text` and one `agent` node per subagent (id `<tool>.<Name>`). A
-- subagent's own subagents are `agent` children of its node, with `p.depth`
-- set (1, 2, …) and ids `<tool>.<Parent>/<Parent>.<Name>`. Props: name, agent
-- ("task"), task (one line), status (pending|running|done|failed|aborted…),
-- model, thinking, badges, stats {tools, requests, context, contextLabel,
-- tokens, cost, age, took}, tool {name, intent, age} while running.

local subagents = {}

export type Subagent = {
	-- The node's TSP id (stable per subagent within one omp session).
	id: string,
	name: string,
	-- One-line assignment.
	task: string?,
	-- omp's status, verbatim (pending, running, done, failed, aborted, idle, parked).
	status: string,
	model: string?,
	-- Nesting: 0 for the agent's own subagents, 1 for theirs, …
	depth: number,
	-- Tool calls made so far.
	tools: number?,
	-- Dollars spent.
	cost: number?,
	-- Context fill, 0–1.
	context: number?,
	-- Tool running now (while running).
	tool: string?,
	-- That tool's intent line, when omp sends one.
	intent: string?,
}

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

-- A TspText (string, span `{t = …}` or list of spans and strings) as plain text.
local function text(v: any): string?
	local s: string? = nil
	if type(v) == "string" then
		s = v
	elseif type(v) == "table" then
		if type(v.t) == "string" then
			s = v.t
		else
			local parts = {}
			for _, part in v do
				if type(part) == "string" then
					table.insert(parts, part)
				elseif type(part) == "table" and type(part.t) == "string" then
					table.insert(parts, part.t)
				end
			end
			s = table.concat(parts)
		end
	end
	if s == nil or s == "" then
		return nil
	end
	return s
end

local function walk(node: any, depth: number, out: { Subagent }, seen: { [string]: boolean })
	if type(node) ~= "table" then
		return
	end
	local below = depth
	if node.k == "agent" then
		local p = if type(node.p) == "table" then node.p else {}
		-- omp sets depth on nested subagents; nesting under an agent node implies it too.
		local d = math.max(num(p.depth) or 0, depth)
		local name = text(p.name) or "subagent"
		local id = if type(node.id) == "string" and node.id ~= ""
			then node.id
			elseif type(p.key) == "string" then p.key
			else string.format("%s#%d", name, #out + 1)
		if not seen[id] then
			seen[id] = true
			local stats = if type(p.stats) == "table" then p.stats else {}
			local tool = if type(p.tool) == "table" then p.tool else {}
			table.insert(out, {
				id = id,
				name = name,
				task = text(p.task),
				status = if type(p.status) == "string" and p.status ~= "" then p.status else "pending",
				model = text(p.model),
				depth = d,
				tools = num(stats.tools),
				cost = num(stats.cost),
				context = num(stats.context),
				tool = text(tool.name),
				intent = text(tool.intent),
			})
		end
		below = d + 1
	end
	local children = node.c
	if type(children) == "table" then
		for _, child in children do
			walk(child, below, out, seen)
		end
	end
end

-- The subagents in a surface tree, in document order (parents before their
-- children). Accepts a SurfaceTree ({main, dock, layer}), a bare TSP node, or
-- anything else (nil, a text read, a capped tree whose `more` hid nodes): it
-- returns what it can find and never raises.
function subagents.extract(tree: any): { Subagent }
	local out: { Subagent } = {}
	if type(tree) ~= "table" then
		return out
	end
	local seen: { [string]: boolean } = {}
	if tree.k ~= nil then
		walk(tree, 0, out, seen)
	else
		walk(tree.main, 0, out, seen)
		walk(tree.dock, 0, out, seen)
		walk(tree.layer, 0, out, seen)
	end
	return out
end

-- Counts by omp status, for summaries: {running = 2, done = 1, …}.
function subagents.counts(list: { Subagent }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, s in list do
		counts[s.status] = (counts[s.status] or 0) + 1
	end
	return counts
end

return subagents
