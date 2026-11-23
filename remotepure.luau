--!strict
-- projects, remotepure: the pure half of remote.luau (the window's side of the bridge to a remote Tern host's
-- host half; README "Remote hosts"). Pane-id mapping between a host and this window, the text of a TSP node, which
-- bridge nodes changed, merging a host's status into the window's lookups, and the `sync` request. No `tern` here,
-- so tests load it with the plain `luau` CLI.

local M = {}

-- The bridge view's nodes after the header (`main.0`), in their fixed order: `main.<n>`.
M.NODES = { "status", "fleet", "gh", "autos", "mail", "replies" }
M.INDEX = { status = 1, fleet = 2, gh = 3, autos = 4, mail = 5, replies = 6 } :: { [string]: number }

local P32 = 4294967296
local P24 = 16777216

-- A host pane id h = hi·2^32 + lo shows in the window as base + hi·2^24 + lo (Tern 0.9.32, measured).
local function offset(hpane: number): number
	return (hpane // P32) * P24 + hpane % P32
end

-- The per-host base from one pane known on both sides (the bridge's).
function M.base_of(wpane: number, hpane: number): number
	return wpane - offset(hpane)
end

function M.to_window(base: number, hpane: number): number
	return base + offset(hpane)
end

-- The inverse, for a window pane with no host id seen yet (a pane just started): assumes lo < 2^24, which every
-- pane measured had (hi·2^24 + lo would be ambiguous otherwise).
function M.to_host(base: number, wpane: number): number
	local x = wpane - base
	return (x // P24) * P32 + x % P24
end

-- Whether `base` is right for this host: the bridge maps onto itself and is one of the host's window panes, and
-- at least half of the panes the host's status names map onto that host's window panes. `why` on failure.
function M.verify(base: number, bridge_w: number, bridge_h: number, host_panes: { [number]: boolean }, status_panes: { number }?): (boolean, string?)
	if M.to_window(base, bridge_h) ~= bridge_w then
		return false, "bridge does not map onto itself"
	end
	if not host_panes[bridge_w] then
		return false, "bridge pane is not one of the host's panes"
	end
	if status_panes and #status_panes > 0 then
		local hits = 0
		for _, h in status_panes do
			if host_panes[M.to_window(base, h)] then
				hits += 1
			end
		end
		if hits * 2 < #status_panes then
			return false, string.format("%d of %d status panes map onto the host's panes", hits, #status_panes)
		end
	end
	return true, nil
end

-- The host pane ids a decoded status document names (its `panes` keys).
function M.status_panes(status: any): { number }
	local out: { number } = {}
	if type(status) == "table" and type(status.panes) == "table" then
		for k in status.panes do
			local n = tonumber(k)
			if n then
				table.insert(out, n)
			end
		end
	end
	table.sort(out)
	return out
end

-- The text of TSP node `id` in what `cx.session:surface` returned (a SurfaceTree, a node, or nil): its spans' `t`
-- concatenated. Nil when the node is absent.
function M.node_text(tree: any, id: string): string?
	if type(tree) ~= "table" then
		return nil
	end
	local function find(n: any, depth: number): any
		if type(n) ~= "table" or depth > 8 then
			return nil
		end
		if n.id == id then
			return n
		end
		if type(n.c) == "table" then
			for _, ch in n.c do
				local hit = find(ch, depth + 1)
				if hit then
					return hit
				end
			end
		end
		return nil
	end
	local node = find(tree, 0)
	if node == nil then
		for _, region in { tree.main, tree.dock, tree.layer } do
			node = find(region, 0)
			if node then
				break
			end
		end
	end
	if node == nil or type(node.p) ~= "table" then
		return nil
	end
	local p = node.p
	if type(p.spans) == "table" then
		local parts: { string } = {}
		for _, s in p.spans do
			if type(s) == "table" and type(s.t) == "string" then
				table.insert(parts, s.t)
			elseif type(s) == "string" then
				table.insert(parts, s)
			end
		end
		return table.concat(parts)
	end
	if type(p.text) == "string" then
		return p.text
	end
	return nil
end

-- The nodes whose signature in the header changed since `old` (nil: never read), in view order.
function M.changed(old: { [string]: any }?, new: { [string]: any }?): { string }
	local out: { string } = {}
	if type(new) ~= "table" then
		return out
	end
	for _, name in M.NODES do
		local n = new[name]
		if n ~= nil and (old == nil or tostring(old[name]) ~= tostring(n)) then
			table.insert(out, name)
		end
	end
	return out
end

-- Merges a host's decoded status into the window's lookups: omp session files by window pane (`wpane` maps host
-- pane ids; unmapped panes are left out), branches by folder (this host's own entries win), and returns the
-- host's queued mail count.
function M.merge(status: any, wpane: (number) -> number?, sessions: { [number]: string }, repos: { [string]: any }): number
	if type(status) ~= "table" then
		return 0
	end
	if type(status.panes) == "table" then
		for k, p in status.panes do
			local h = tonumber(k)
			local w = if h then wpane(h) else nil
			if w and type(p) == "table" and type(p.session_file) == "string" then
				sessions[w] = p.session_file
			end
		end
	end
	if type(status.repos) == "table" then
		for cwd, r in status.repos do
			if type(cwd) == "string" and repos[cwd] == nil then
				repos[cwd] = r
			end
		end
	end
	return if type(status.queued) == "number" then status.queued else 0
end

-- The `sync` request's body for `host`: the projects living there and their agents' worktrees.
function M.sync_body(projects: { any }, agents: { [string]: any }, host: string, visible: boolean): { [string]: any }
	local list = {}
	local ids: { [string]: boolean } = {}
	for _, p in projects do
		if p.host == host then
			table.insert(list, { id = p.id, name = p.name, root = p.root })
			ids[p.id] = true
		end
	end
	local seen: { [string]: boolean } = {}
	local worktrees: { string } = {}
	for _, m in agents do
		if ids[m.project] and type(m.worktree) == "string" and not seen[m.worktree] then
			seen[m.worktree] = true
			table.insert(worktrees, m.worktree)
		end
	end
	table.sort(worktrees)
	return { op = "sync", projects = list, worktrees = worktrees, visible = visible }
end

-- A part (`status` … `replies`) arrives in chunks: `main.K` is a column of text nodes `main.K.0` … `main.K.<n-1>`
-- (the header's `parts[name]` = n), each one span; their texts in order are the part's JSON. An assembly is read one
-- chunk at a time and starts over when the header names another signature or count for the part.
export type Asm = { name: string, sig: string, n: number, chunks: { string } }

function M.chunk_id(name: string, i: number): string
	return string.format("main.%d.%d", M.INDEX[name], i)
end

-- A new assembly of part `name` as `header` describes it; nil when the header has no signature or count for it.
function M.asm_new(name: string, header: any): Asm?
	if type(header) ~= "table" or type(header.sig) ~= "table" or type(header.parts) ~= "table" then
		return nil
	end
	local sig, n = header.sig[name], header.parts[name]
	if sig == nil or type(n) ~= "number" or n < 0 then
		return nil
	end
	return { name = name, sig = tostring(sig), n = n, chunks = {} }
end

-- Whether `header` (read since `a` started) describes another version of the part.
function M.asm_stale(a: Asm, header: any): boolean
	local now = M.asm_new(a.name, header)
	return now == nil or now.sig ~= a.sig or now.n ~= a.n
end

-- The node id of the next chunk to read, nil once all are in.
function M.asm_next(a: Asm): string?
	if #a.chunks >= a.n then
		return nil
	end
	return M.chunk_id(a.name, #a.chunks)
end

function M.asm_add(a: Asm, text: string)
	table.insert(a.chunks, text)
end

-- The part's text once every chunk is in, else nil.
function M.asm_text(a: Asm): string?
	if #a.chunks < a.n then
		return nil
	end
	return table.concat(a.chunks)
end

-- Sidebar ids of a remote host's items (automations): `<host>|<id>`; a local id has no `|`.
function M.join_id(host: string?, id: string): string
	return if host then host .. "|" .. id else id
end

function M.split_id(s: string): (string?, string)
	local host, id = string.match(s, "^(.*)|([^|]*)$")
	if host and host ~= "" then
		return host, id :: string
	end
	return nil, s
end

return M
