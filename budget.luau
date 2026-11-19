--!strict
-- projects, budget: living with Tern's window budget (50 ms of Lua per callback, 500 ms of wall time with native
-- calls; in practice native calls count toward the 50 ms too, Overseer measured on 0.9.26). A callback over either
-- pauses its whole hook (every timer callback shares hook "timer") for 5 s, doubling up to 5 min. Rules, after
-- Overseer's budget.luau:
--
-- - Work runs in labelled timer callbacks started by `later`; event, click and command hooks only queue it.
-- - One callback does one heavy thing: an agent scan, one surface or transcript read, one draw, one delivery.
-- - `cx.agents:list()` (7-20 ms) runs in the scan and the mailbox's delivery pass only; draws read the scan's cache.
-- - Git runs in the host half or as `tern.process.spawn` children, never `process.run` on the window's UI thread.
-- - Every callback is timed: one past `SLOW_MS` is logged with its label, and a `budget` pause names the label of
--   the callback that ran last, so the log says which one ran over.

local M = {}

-- A callback taking longer than this is logged (well under the 50 ms that pauses the hook).
M.SLOW_MS = 25

-- The label of the timer callback that started last.
local last_label: string? = nil

-- Runs `fn(arg)` (pcall'd and timed) under `label`; errors are logged, never raised.
function M.run(label: string, fn: (any) -> (), arg: any)
	last_label = label
	local t0 = tern.now()
	local ok, err = pcall(fn, arg)
	local ms = tern.now() - t0
	if ms > M.SLOW_MS then
		tern.log.warn(string.format("projects: %s took %.1f ms", label, ms))
	end
	if not ok then
		tern.log.warn("projects: " .. label .. " failed", err)
	end
end

-- Runs `fn(cx)` in a timer callback of its own after `ms`, labelled; a turn without a window is skipped.
function M.later(label: string, ms: number, fn: (cx: WindowCx) -> ()): TimerHandle
	return tern.timer(ms, function(cx)
		if cx then
			M.run(label, fn, cx)
		end
	end)
end

-- The log line for a `budget` event: which hook paused, for how long, and the timer callback that ran last.
function M.describe(ev: BudgetEvent): string
	if ev.state ~= "paused" then
		return "projects: Tern resumed the " .. ev.hook .. " hook"
	end
	local culprit = if ev.hook == "timer" and last_label then " (last timer callback: " .. last_label .. ")" else ""
	return string.format("projects: Tern paused the %s hook for %.0f s after it ran over %.0f ms%s", ev.hook, (ev.paused_ms or 0) / 1000, ev.ms or 0, culprit)
end

return M
