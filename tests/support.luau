--!strict
-- Test support: assertions, fixture loading and a `tern.ui` stub whose output
-- matches what Tern 0.9.16's builders returned live (button label in `p.text`,
-- card/section head as spans, text as `p.spans`).

local json = require("./support_json")

local support = {}

local failures = 0
local passed = 0

function support.check(cond: any, msg: string)
	if cond then
		passed += 1
	else
		failures += 1
		print("FAIL: " .. msg)
	end
end

function support.eq(got: any, want: any, msg: string)
	support.check(got == want, string.format("%s (got %s, want %s)", msg, tostring(got), tostring(want)))
end

function support.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		print("ERROR in " .. name .. ": " .. tostring(err))
	end
end

function support.finish(suite: string)
	print(string.format("%s: %d passed, %d failed", suite, passed, failures))
	if failures > 0 then
		error(suite .. " failed", 0)
	end
end

-- A fixture's decoded surface tree.
function support.fixture(name: string): any
	local fixtures: { [string]: string } = {
		["omp-subagent-pending"] = require("./fixtures/omp-subagent-pending"),
		["omp-subagents-capped"] = require("./fixtures/omp-subagents-capped"),
		["omp-subagents-fast-done"] = require("./fixtures/omp-subagents-fast-done"),
		["omp-subagents-nested-done"] = require("./fixtures/omp-subagents-nested-done"),
		["omp-subagents-running"] = require("./fixtures/omp-subagents-running"),
		["omp-working-no-subagents"] = require("./fixtures/omp-working-no-subagents"),
	}
	local text = fixtures[name]
	assert(text, "no fixture " .. name)
	return json.decode(text)
end

local function spans(v: any): any
	if type(v) == "string" then
		return { { t = v } }
	elseif type(v) == "table" and v.t ~= nil then
		return { v }
	end
	return v
end

local function copy(t: any): { [string]: any }
	local out = {}
	for k, v in t or {} do
		out[k] = v
	end
	return out
end

local function node(k: string, p: any, c: any): any
	local n: { [string]: any } = { k = k }
	if p ~= nil and next(p) ~= nil then
		n.p = p
	end
	if c ~= nil and #c > 0 then
		n.c = c
	end
	return n
end

support.ui = {
	span = function(t: string, s: string?)
		return { t = t, s = s }
	end,
	text = function(v: any)
		return node("text", { spans = spans(v) })
	end,
	node = function(k: string, p: any?, c: any?)
		return node(k, copy(p), c)
	end,
	col = function(c: any)
		return node("col", nil, c)
	end,
	row = function(c: any)
		return node("row", nil, c)
	end,
	button = function(label: string?, p: any?)
		local props = copy(p)
		props.text = label
		return node("button", props)
	end,
	card = function(head: any, c: any, p: any?)
		local props = copy(p)
		props.head = spans(head)
		return node("card", props, c)
	end,
	section = function(head: any, c: any)
		return node("section", { head = spans(head) }, c)
	end,
	badge = function(t: string, tone: string)
		return node("badge", { text = t, tone = tone })
	end,
}

-- Every node of a tree, depth first, with its parent and its full canvas id
-- (`<parent id>.<key or 0-based index>`), the way Tern names canvas nodes.
function support.walk(root: any, root_id: string, fn: (n: any, id: string, parent: any?) -> ())
	local function go(n: any, id: string, parent: any?)
		fn(n, id, parent)
		for i, child in n.c or {} do
			local key = child.p and child.p.key
			go(child, id .. "." .. (if key ~= nil then tostring(key) else tostring(i - 1)), n)
		end
	end
	go(root, root_id, nil)
end

-- The node with full id `id`, or nil.
function support.find(root: any, root_id: string, id: string): any
	local found = nil
	support.walk(root, root_id, function(n, nid)
		if nid == id then
			found = n
		end
	end)
	return found
end

return support
