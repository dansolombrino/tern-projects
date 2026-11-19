--!nonstrict
-- luau tests/test_canvas.luau: which one sidebar canvas a window keeps (sidebar.pick_canvas).

local t = require("./support")
local sidebar = require("../sidebar")

local eq, test = t.eq, t.test

test("none: nothing to keep or close", function()
	local keep, extras = sidebar.pick_canvas({}, nil, 7)
	eq(keep, nil, "nothing kept")
	eq(#extras, 0, "nothing closed")
end)

test("one: reused, never closed", function()
	local keep, extras = sidebar.pick_canvas({ { pane = 5, tab = 1 } }, nil, 9)
	eq(keep, 5, "reused even in another tab")
	eq(#extras, 0, "nothing closed")
	keep = sidebar.pick_canvas({ { pane = 5, parked = true } }, nil, 9)
	eq(keep, 5, "a parked one is reused")
end)

test("the one this run uses wins", function()
	local keep, extras = sidebar.pick_canvas({ { pane = 3, tab = 7 }, { pane = 8, tab = 2 } }, 8, 7)
	eq(keep, 8, "current kept")
	eq(table.concat(extras, ","), "3", "the other closed")
end)

test("after a relaunch: the shown one in this tab, else any shown one, else the oldest", function()
	local seen = {
		{ pane = 30, parked = true },
		{ pane = 20, tab = 4 },
		{ pane = 10 }, -- detached
		{ pane = 40, tab = 9 },
	}
	local keep, extras = sidebar.pick_canvas(seen, nil, 9)
	eq(keep, 40, "shown in this tab")
	eq(table.concat(extras, ","), "10,20,30", "the rest closed, in pane order")
	keep = sidebar.pick_canvas(seen, nil, 1)
	eq(keep, 20, "else the first shown one")
	keep = sidebar.pick_canvas({ { pane = 30, parked = true }, { pane = 10 } }, nil, 1)
	eq(keep, 10, "else the oldest")
	keep = sidebar.pick_canvas(seen, 99, 9)
	eq(keep, 40, "a current pane that is gone does not count")
end)

test("duplicates from the replica and the pane list count once", function()
	local keep, extras = sidebar.pick_canvas({ { pane = 5, tab = 1 }, { pane = 5, tab = 1 } }, nil, 1)
	eq(keep, 5, "kept")
	eq(#extras, 0, "not closed against itself")
end)

t.finish("canvas")
