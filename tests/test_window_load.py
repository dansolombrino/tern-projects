#!/usr/bin/env python3
"""python3 tests/test_window_load.py: the window entry's staged loading (README, Budget).

Tern counts `require`'s compile toward the load hook's 500 ms of wall time, so window.luau's load may compile only
base.luau and budget.luau; every other module compiles in a timer callback of its own, one file per callback. The
`luau` CLI can't give a module a `tern` global before it runs, so this test embeds the plugin's sources in a Luau
harness with a stub `tern` and its own `require`, loads window.luau, then fires its timers one by one.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# The host half's modules: a window never loads them.
HOST_ONLY = {"host", "autohost", "automate", "ghpoll", "bridge"}

HARNESS = r"""
local SOURCES = SOURCES_TABLE

local passed, failed = 0, 0
local function check(cond, msg)
	if cond then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. msg)
	end
end

-- Every module compiled, in order, with the phase it compiled in.
local order: { { name: string, phase: string } } = {}
local phase = "load"
local loaded = {}
local timers = {}
local commands, hooks, overrides, warnings = {}, {}, {}, {}
local status_fn = nil

local tern = {
	plugin = { id = "projects", data = "/tmp/projects-data", dir = "/tmp/projects" },
	runtime = { os = "macos" },
	getenv = function(_)
		return "/home/me"
	end,
	now = function()
		return os.clock() * 1000
	end,
	log = {
		warn = function(...)
			local parts = {}
			for _, v in { ... } do
				table.insert(parts, tostring(v))
			end
			table.insert(warnings, table.concat(parts, " "))
		end,
		info = function() end,
	},
	command = function(def)
		commands[def.id] = def
	end,
	override = function(id, fn)
		overrides[id] = fn
	end,
	on = function(name, fn)
		hooks[name] = fn
	end,
	chrome = {
		status = function(fn)
			status_fn = fn
		end,
		refresh = function() end,
	},
	timer = function(ms, fn)
		table.insert(timers, { ms = ms, fn = fn })
		return { cancel = function() end }
	end,
	kv = {
		get = function(_)
			return nil
		end,
		set = function() end,
	},
}

local base_env = getfenv(1)
local require_

local function compile(name: string)
	local src = SOURCES[name]
	assert(src, "no module " .. name)
	local f = assert(loadstring(src, "=" .. name .. ".luau"))
	setfenv(f, setmetatable({ tern = tern, require = require_ }, { __index = base_env }))
	return f
end

require_ = function(path: string)
	local name = assert(string.match(path, "^%./([%w_]+)$"), "unexpected require " .. path)
	if loaded[name] == nil then
		table.insert(order, { name = name, phase = phase })
		loaded[name] = compile(name)()
	end
	return loaded[name]
end

-- The load: window.luau's top level.
table.insert(order, { name = "window", phase = "load" })
compile("window")()

local at_load = {}
for _, m in order do
	table.insert(at_load, m.name)
end
table.sort(at_load)
check(table.concat(at_load, " ") == "base budget window", "the load compiles only base and budget (got " .. table.concat(at_load, " ") .. ")")
-- Every stage's timer starts at load (one starting the next would wait a turn each), due in stage order.
check(#timers == STAGE_COUNT + 3, "the load starts a timer per stage: modules, load start, init, queued hooks (" .. #timers .. ")")
local ordered = true
for i = 2, #timers do
	ordered = ordered and timers[i].ms > timers[i - 1].ms
end
check(ordered, "the stage timers are due in stage order")

local n = 0
for _ in commands do
	n += 1
end
check(n == COMMAND_COUNT, "every command registers at load (" .. n .. ")")
for _, name in { "canvas_action", "agent_state", "agent_finished", "budget", "focus", "pane_created", "cwd", "pane_closed", "session_ended" } do
	check(hooks[name] ~= nil, "hook " .. name .. " registers at load")
end
check(overrides.files ~= nil, "the files override registers at load")
check(status_fn ~= nil, "the status segment registers at load")
local seg = status_fn and status_fn({ pane = 1, cwd = "/" })
check(seg ~= nil and seg[1].text == "Projects" and seg[1].command == "plugin.projects.toggle_sidebar", "before loading, the status segment is the sidebar toggle")

-- Hooks before the modules load are queued, not run (they would index a nil context).
local cx = {}
local ok = pcall(commands.toggle_sidebar.run, cx)
check(ok, "a command before loading is queued")
check(hooks.canvas_action({ owner = "projects", pane = 1, act = "search" }, cx) == true, "our click before loading is taken (queued)")
check(hooks.canvas_action({ owner = "other", pane = 1, act = "search" }, cx) == false, "another plugin's click is not")
check(pcall(hooks.focus, { pane = 1, tab = 1 }, cx), "an event before loading is queued")
check(commands.use_orca_keys.available(cx) == false, "Orca shortcut commands are unavailable before loading")

-- The stages: each timer callback compiles exactly one module, then "load start" installs them (compiling none).
-- init and the queued hooks need a real window, so they don't run here.
local stage = 0
while stage < STAGE_COUNT + 1 do
	local before = #order
	stage += 1
	phase = "stage " .. stage
	local t = table.remove(timers, 1)
	t.fn(cx)
	local compiled = #order - before
	if stage <= STAGE_COUNT then
		check(compiled == 1, string.format("stage %d compiles one module (compiled %d: %s)", stage, compiled, if compiled > 0 then order[#order].name else "-"))
	else
		check(compiled == 0, string.format("\"load start\" compiles nothing (compiled %d)", compiled))
	end
end
check(#timers == 2, "init and the queued hooks are left")
for _, w in warnings do
	check(false, "warning while loading: " .. w)
end

local missing = {}
for _, name in WINDOW_MODULES do
	if loaded[name] == nil and name ~= "window" then
		table.insert(missing, name)
	end
end
check(#missing == 0, "every window module loaded (missing: " .. table.concat(missing, " ") .. ")")

print(string.format("window_load: %d passed, %d failed", passed, failed))
if failed > 0 then
	error("window_load failed", 0)
end
"""


def long_string(text: str) -> str:
    level = 1
    while f"]{'=' * level}]" in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[\n{text}]{eq}]"


class WindowLoadTest(unittest.TestCase):
    def test_staged_load(self) -> None:
        names = sorted(
            f[: -len(".luau")]
            for f in os.listdir(ROOT)
            if f.endswith(".luau") and f != "tern.d.luau"
        )
        sources = {}
        for name in names:
            with open(os.path.join(ROOT, f"{name}.luau"), encoding="utf-8") as fh:
                sources[name] = fh.read()
        window = sources["window"]
        stage_count = len(re.findall(r'run = function\(\) require\("\./\w+"\) end', window))
        commands_block = window.split("local COMMANDS", 1)[1].split("\n}\n", 1)[0]
        command_count = len(re.findall(r'^\t(?:\{ |\t)id = "', commands_block, re.M))
        window_modules = [n for n in names if n not in HOST_ONLY]
        table = "{\n" + "".join(f'\t["{n}"] = {long_string(s)},\n' for n, s in sources.items()) + "}"
        harness = (
            HARNESS.replace("COMMAND_COUNT", str(command_count))
            .replace("STAGE_COUNT", str(stage_count))
            .replace("WINDOW_MODULES", "{ " + ", ".join(f'"{n}"' for n in window_modules) + " }")
            .replace("SOURCES_TABLE", table, 1)
        )
        with tempfile.TemporaryDirectory(prefix="tp-window-") as d:
            path = os.path.join(d, "harness.luau")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(harness)
            res = subprocess.run(["luau", path], capture_output=True, text=True, timeout=60)
        print(res.stdout.strip())
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("window_load:", res.stdout)
        self.assertGreaterEqual(command_count, 20)
        self.assertGreaterEqual(stage_count, 15)


if __name__ == "__main__":
    unittest.main()
