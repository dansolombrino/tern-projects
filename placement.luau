--!strict
-- projects, sidebar placement: finds the sidebar canvas, docks it at the left edge of the tab the user works in,
-- fits and remembers its px width (Tern sizes splits by ratio, so a window resize or another split moves it),
-- moves it off a tab it is left alone in, runs its refresh ticker, and shows, hides and toggles it.

local model = require("./model")
local sidebar = require("./sidebar")
local core = require("./core")
local ID = core.ID
local K = core.K
local SIDE_TITLE = core.SIDE_TITLE
local defer = core.defer

-- The context: all shared state and the other modules' functions, set by the installer below.
local S: core.Ctx = nil :: any

-- Sidebar --------------------------------------------------------------------------

local function find_side(cx: WindowCx): number?
	-- A canvas just opened can be missing from the canvas replica for a moment; its pane is already there.
	if S.side_pane and (cx.canvas:get(S.side_pane) or cx.session:pane(S.side_pane)) then
		return S.side_pane
	end
	S.side_pane = nil
	for _, c in cx.canvas:list() do
		if c.owner == ID and c.title == SIDE_TITLE then
			S.side_pane = c.pane
			return c.pane
		end
	end
	return nil
end

local function parked(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	return info ~= nil and info.parked == true
end

-- The sidebar when it shows in the current tab.
local function shown_side(cx: WindowCx): number?
	local side = find_side(cx)
	if side == nil or parked(cx, side) then
		return nil
	end
	local focused = cx.session:focused()
	local here = if focused then cx.session:tab_of(focused) else nil
	if here ~= nil and cx.session:tab_of(side) ~= here then
		return nil
	end
	return side
end

-- The first leaf of `tree` other than `except`, left (and top) first.
local function leftmost(tree: TabTree?, except: number?): number?
	if tree == nil then
		return nil
	end
	if tree.pane then
		return if tree.pane == except then nil else tree.pane
	end
	return leftmost(tree[1], except) or leftmost(tree[2], except)
end

local function tab_root(cx: WindowCx, tab: number?): TabTree?
	if tab == nil then
		return nil
	end
	local layout = cx.session:layout(tab)
	return if layout then layout.root else nil
end

-- `pane`'s share of its tab's width when it touches the tab's left edge (left side of every left/right split
-- above it), else nil; with the ratio of the nearest left/right split above it. Tern only splits leaves, so the
-- sidebar moved beside the leftmost leaf can sit in a nested split ([[sidebar | a] | b] draws the same three
-- columns as [sidebar | [a | b]]).
local function share_in(tree: TabTree?, pane: number): (number?, number?)
	if tree == nil then
		return nil, nil
	end
	if tree.pane then
		return if tree.pane == pane then 1 else nil, nil
	end
	for i = 1, 2 do
		local s, near = share_in(tree[i], pane)
		if s then
			if tree.split ~= "right" then
				return s, near
			end
			if i == 2 then
				return nil, nil
			end
			local r = tree.ratio or 0.5
			return s * r, near or r
		end
	end
	return nil, nil
end

-- The left/right splits above `pane` with `pane` in their left part, outermost first (the last is its nearest
-- split, whose divider `resize(pane, "right")` moves), when `pane` touches the tab's left edge; else nil.
local function left_splits(tree: TabTree?, pane: number): { TabTree }?
	if tree == nil or tree.pane then
		return if tree and tree.pane == pane then {} else nil
	end
	for i = 1, 2 do
		local inner = left_splits(tree[i], pane)
		if inner then
			if tree.split ~= "right" then
				return inner
			end
			if i == 2 then
				return nil
			end
			table.insert(inner, 1, tree)
			return inner
		end
	end
	return nil
end

local function side_ratio(cx: WindowCx, side: number): number?
	return (share_in(tab_root(cx, cx.session:tab_of(side)), side))
end

-- The pane the user works in: the focused one, else the last one focused, never the sidebar.
local function main_pane(cx: WindowCx, side: number?): number?
	local focused = cx.session:focused()
	if focused and focused ~= side then
		return focused
	end
	if S.last_main and cx.session:pane(S.last_main) then
		return S.last_main
	end
	if side then
		return leftmost(tab_root(cx, cx.session:tab_of(side)), side)
	end
	return nil
end

local function font_size(cx: WindowCx): number
	local ok, size = pcall(function()
		return cx.settings:get("terminal.font_size")
	end)
	return if ok and type(size) == "number" then size else 13
end

-- The pane width the sidebar wants, in cells.
local function want_cols(cx: WindowCx): number
	return (math.clamp(S.ui.want_px or K.SIDE_PX, K.MIN_PX, K.MAX_PX) + K.CHROME_PX) / (font_size(cx) * model.CELL_EM)
end

-- The sidebar's share of the tab and the ratio of its nearest left/right split.
local function shares(cx: WindowCx, side: number): (number?, number?)
	return share_in(tab_root(cx, cx.session:tab_of(side)), side)
end

-- Tern 0.9.16 resizes a pane by cells of the width it was last drawn at: each `resize(side, "right", c)`
-- multiplies its nearest split's ratio by (1 + c / cols), however far the ratio moved since the last frame,
-- with `cols` the drawn width divided by the ratios of the splits above the nearest one (measured headless:
-- three +10 steps from a 33-cell sidebar alone beside a pane each gave ×1.303; a 20-cell sidebar in a half-tab
-- split gave cols 40). So `cols / ratio` is the tab's width, one small resize tells `cols`, and one more lands
-- any wanted ratio exactly. Returns the ratio after the probe and `cols`.
local function drawn_cols(cx: WindowCx, side: number): (number?, number?)
	local _, n = shares(cx, side)
	if n == nil then
		return nil, nil
	end
	local c = if n < 0.5 then 2 else -2
	if not cx.layout:resize(side, "right", c) then
		return nil, nil
	end
	local _, n2 = shares(cx, side)
	if n2 == nil or math.abs(n2 - n) < 1e-6 then
		return nil, nil
	end
	return n2, n * c / (n2 - n)
end

-- Brings the nearest split's ratio from `cur` to `goal` (`cols` from `drawn_cols`); returns the ratio reached.
local function set_ratio(cx: WindowCx, side: number, cur: number, cols: number, goal: number): number
	for _ = 1, 2 do
		local c = cols * (goal / cur - 1)
		if math.abs(c) < 0.01 or not cx.layout:resize(side, "right", c) then
			break
		end
		local _, n = shares(cx, side)
		if n == nil then
			break
		end
		cur = n
	end
	return cur
end

-- One measure of the nearest split: the sidebar's drawn width `cols` (as `drawn_cols` gives it) at the split's
-- ratio `n`; the ratio is left as it was. Only right when the layout was drawn at its current ratios (settled).
local function measure(cx: WindowCx, side: number): (number?, number?)
	local _, n = shares(cx, side)
	local cur, cols = drawn_cols(cx, side)
	if n == nil or cur == nil or cols == nil or cols <= 0 then
		return nil, nil
	end
	set_ratio(cx, side, cur, cols, n)
	return cols, n
end

-- The nearest split's width in cells. Tern draws a pane at whole cells, so one measure only places it within a
-- cell of `cols / n` (one measure was 4% off): [total_lo, total_hi] intersects the measures taken since the
-- layout last changed and `total_cells` is its middle. A measure outside the bounds means the width changed (a
-- window resize keeps every ratio and sends no event): they restart from it.
local total_lo: number? = nil
local total_hi: number? = nil
local total_cells: number? = nil

-- Adds a measure (`restart`: the layout changed, older measures don't count). Returns whether the estimate
-- started or moved by over 1% (enough to refit), and whether the measure fell outside the bounds: the split's
-- width itself changed.
local function note_total(cols: number, n: number, restart: boolean): (boolean, boolean)
	local lo, hi = (cols - 1) / n, (cols + 1) / n
	local was_lo, was_hi = total_lo, total_hi
	local outside = was_lo ~= nil and was_hi ~= nil and (hi < was_lo or lo > was_hi)
	if restart or outside or was_lo == nil or was_hi == nil then
		total_lo, total_hi = lo, hi
	else
		total_lo, total_hi = math.max(was_lo, lo), math.min(was_hi, hi)
	end
	local old = total_cells
	local now = ((total_lo :: number) + (total_hi :: number)) / 2
	total_cells = now
	return old == nil or math.abs(now - old) > 0.01 * now, outside
end

-- In a nested split ([[sidebar | a] | b]) the sidebar's own divider only trades width with `a`, so once `a` is at
-- its minimum width (a narrower window) Tern refuses to move it. Then the divider above moves instead: `b` (the
-- first leaf right of the sidebar's group) shrinks from its left edge, the group takes that width, `a` keeps its
-- share and the sidebar gets `want` (its share of the tab). A 2-cell probe tells how far a cell of `b` moves that
-- divider, as `drawn_cols` does for the sidebar's.
local function widen_group(cx: WindowCx, side: number, want: number)
	local function above(): TabTree?
		local splits = left_splits(tab_root(cx, cx.session:tab_of(side)), side)
		return if splits and #splits >= 2 then splits[#splits - 1] else nil
	end
	local up = above()
	local s, n = shares(cx, side)
	local b = if up then leftmost(up[2], nil) else nil
	if up == nil or b == nil or s == nil or n == nil then
		return
	end
	-- The group's share is `up`'s ratio times the ratios above it.
	local r = up.ratio or 0.5
	local k = s / n / r
	local goal = math.min((want + (1 - n) * s / n) / k, 0.95)
	if goal <= r + 0.002 or not cx.layout:resize(b, "left", -2) then
		return
	end
	local now = above()
	local cur = if now then now.ratio or 0.5 else r
	if math.abs(cur - r) < 1e-6 then
		return
	end
	-- `b`'s share of `up` (1 - ratio) shrinks by 1 - c / cols per resize.
	local cols = 2 * (1 - r) / (cur - r)
	for _ = 1, 2 do
		local c = cols * ((1 - goal) / (1 - cur) - 1)
		if math.abs(c) < 0.01 or not cx.layout:resize(b, "left", c) then
			break
		end
		now = above()
		if now == nil then
			break
		end
		cur = now.ratio or 0.5
	end
	local near, scols = drawn_cols(cx, side)
	if near and scols and scols > 0 then
		set_ratio(cx, side, near, scols, math.clamp(want / (cur * k), 0.02, 0.9))
	end
end

-- Gives the sidebar its wanted width. A settled layout measures the tab's width in cells; otherwise (a pane just
-- opened, unparked or moved, drawn at an old size) the last settled measure stands.
local function fit(cx: WindowCx, side: number, settled: boolean)
	local s, n = shares(cx, side)
	if s == nil or n == nil or n <= 0 then
		return
	end
	local cur, cols = drawn_cols(cx, side)
	if cur == nil or cols == nil or cols <= 0 then
		return
	end
	if settled then
		note_total(cols, n, true)
	end
	local total = total_cells
	if total == nil then
		set_ratio(cx, side, cur, cols, n)
		return
	end
	-- The nearest split is the tab's width times the ratios above it (s / n).
	local want = want_cols(cx) / total
	local goal = math.clamp(want / (s / n), 0.02, 0.9)
	local near = set_ratio(cx, side, cur, cols, goal)
	if want - s / n * near > 0.002 then
		widen_group(cx, side, want)
	end
	local s2, n2 = shares(cx, side)
	S.fitted = { pane = side, ratio = s2 or s / n * near, near = n2 or near, font = font_size(cx) }
	if settled then
		S.layout_dirty = false
	end
end

-- Fits again once the layout has settled: a pane that just opened, unparked or moved has its old size until then.
-- Only the last request runs.
local fit_gen = 0
local function fit_later(side: number)
	fit_gen += 1
	local gen = fit_gen
	tern.timer(300, function(tcx)
		if tcx and gen == fit_gen and side == S.side_pane and not parked(tcx, side) then
			fit(tcx, side, true)
		end
	end)
end

-- A share off the fitted one with no layout change in between is a divider drag or a window resize (Tern
-- re-ratioes splits to keep panes above their minimum width). A drag of the sidebar's own divider (its nearest
-- split's ratio moved, the split's width did not) is remembered as px; otherwise the px width is restored. True
-- when the share had moved.
local function remember_drag(cx: WindowCx, side: number): boolean
	local f = S.fitted
	if f == nil or total_cells == nil or f.pane ~= side or S.layout_dirty then
		return false
	end
	local r, near = shares(cx, side)
	if r == nil or near == nil or math.abs(r - f.ratio) < 0.002 then
		return false
	end
	local cols, n = measure(cx, side)
	local resized = false
	if cols and n then
		local _, outside = note_total(cols, n, false)
		resized = outside
	end
	if resized or math.abs(near - f.near) < 0.002 then
		fit(cx, side, false)
		return true
	end
	S.fitted = { pane = side, ratio = r, near = near, font = f.font }
	S.ui = model.load_ui()
	local px = r * (total_cells :: number) * font_size(cx) * model.CELL_EM - K.CHROME_PX
	S.ui.want_px = math.floor(math.clamp(px, K.MIN_PX, K.MAX_PX) + 0.5)
	S.save_ui()
	return true
end

-- Refits when the split's width in cells changed under a settled layout (a window resize keeps every ratio, so
-- the sidebar's px width drifted), its estimate sharpened, or the font size changed.
local function refit_if_resized(cx: WindowCx, side: number)
	local font_changed = S.fitted ~= nil and font_size(cx) ~= (S.fitted :: any).font
	local cols, n = measure(cx, side)
	local moved = cols ~= nil and n ~= nil and (note_total(cols, n, false))
	if moved or font_changed then
		fit(cx, side, false)
	end
end

-- Docks the sidebar at the left edge of the tab the user works in, then fits its width; false when Tern refused
-- to unpark or move it (the caller then closes it and opens a new one).
local function place(cx: WindowCx, side: number): boolean
	local main = main_pane(cx, side)
	local tab = if main then cx.session:tab_of(main) else nil
	if parked(cx, side) then
		local ok, err = cx.layout:unpark(side, { focus = false })
		if not ok then
			tern.log.warn("projects: unpark failed", err)
			return false
		end
	else
		remember_drag(cx, side)
	end
	if tab and cx.session:tab_of(side) ~= tab then
		local ok, err = cx.layout:move_to_tab(side, tab, { focus = false })
		if not ok then
			tern.log.warn("projects: move to tab failed", err)
			return false
		end
	end
	if side_ratio(cx, side) == nil then
		local leaf = leftmost(tab_root(cx, cx.session:tab_of(side)), side)
		if leaf then
			cx.layout:move(side, leaf, "left", { focus = false })
		end
	end
	S.layout_dirty = true
	fit(cx, side, false)
	fit_later(side)
	return true
end

-- The sidebar is never a tab's only pane (its last other pane closed): it follows the user to another tab of
-- the session, else waits parked until a pane is focused. True when it moved.
local function rehome_side(cx: WindowCx): boolean
	local side = find_side(cx)
	local here = if side then cx.session:tab_of(side) else nil
	local root = tab_root(cx, here)
	if side == nil or here == nil or root == nil or root.pane ~= side or parked(cx, side) then
		return false
	end
	local target: number? = nil
	if S.last_main and cx.session:pane(S.last_main) and cx.session:tab_of(S.last_main) ~= here then
		target = S.last_main
	end
	for _, s in cx.session:sessions() do
		if target == nil and s.current then
			for _, t in s.tabs do
				target = target or (if t ~= here then leftmost(tab_root(cx, t), side) else nil)
			end
		end
	end
	if target then
		cx.layout:focus(target :: number)
		S.last_main = target
		if not place(cx, side) then
			cx.layout:close(side)
			S.side_pane = nil
		end
	else
		cx.layout:park(side)
	end
	return true
end

local function tick(gen: number)
	tern.timer(K.TICK_MS, function(cx)
		if gen ~= S.side_gen then
			return
		end
		-- Re-armed first: a turn without a window, a sidebar missing for a moment or an error below never ends the
		-- chain; hiding or closing the sidebar bumps `side_gen` instead.
		tick(gen)
		if cx == nil then
			return
		end
		local side = find_side(cx)
		if side == nil or parked(cx, side) or rehome_side(cx) then
			return
		end
		if side_ratio(cx, side) == nil then
			place(cx, side)
		elseif S.layout_dirty then
			fit_later(side)
		elseif not remember_drag(cx, side) then
			-- Every settled tick: no resize event exists, and a measure's probe and restore land within one
			-- callback, so no frame (nor a program's pty) ever sees them.
			refit_if_resized(cx, side)
		end
		-- Reading and drawing get turns of their own.
		defer(function(scx)
			S.scan(scx)
			S.queue_reads()
			defer(S.refresh_side)
		end)
	end)
end

local function start_ticker()
	S.side_gen += 1
	tick(S.side_gen)
end

local function set_visible(visible: boolean)
	S.ui = model.load_ui()
	if S.ui.visible ~= visible then
		S.ui.visible = visible
		S.save_ui()
	end
end

-- Shows the sidebar at the left of the current tab, leaving focus where it is.
local function show_side(cx: WindowCx, retried: boolean?)
	set_visible(true)
	S.scan(cx)
	local main = main_pane(cx, S.side_pane)
	if main == nil and not retried then
		-- A session with no pane left (its last agent slept or closed) has nothing to dock beside: the
		-- sidebar would stay parked and its sleeping cards out of reach. Give it a shell, and dock once
		-- the session has it.
		cx.layout:new_tab()
		tern.timer(200, function(tcx)
			if tcx then
				show_side(tcx, true)
			end
		end)
		return
	end
	local side = find_side(cx)
	if side and not place(cx, side) then
		cx.layout:close(side)
		S.side_pane, side = nil, nil
	end
	if side then
		S.redraw_soon()
	else
		local view, dock = S.draw(cx)
		local spec: CanvasSpec = { title = SIDE_TITLE, about = sidebar.ABOUT, view = view, dock = dock, focus = false }
		local target = if main then leftmost(tab_root(cx, cx.session:tab_of(main)), nil) else nil
		if target then
			spec.how = "beside"
			spec.target = target
			spec.dir = "left"
			-- Its share of the leaf it splits: right for a lone leaf, the tick fixes the rest.
			spec.ratio = math.clamp(if total_cells then want_cols(cx) / (total_cells :: number) else K.SIDE_PX / 1500, 0.05, 0.6)
		else
			spec.how = "tab"
		end
		local pane, err = cx.canvas:open(spec)
		if pane == nil then
			cx:toast("error", "Projects sidebar not opened", err)
			return
		end
		S.side_pane = pane
		fit(cx, pane, false)
		fit_later(pane)
	end
	if main and cx.session:focused() ~= main then
		cx.layout:focus(main)
	end
	S.queue_reads()
	start_ticker()
end

-- Hides the sidebar: parked, so it keeps its pane and comes back at once (closed if it can't park).
local function hide_side(cx: WindowCx)
	set_visible(false)
	local side = find_side(cx)
	if side == nil or parked(cx, side) then
		return
	end
	local main = main_pane(cx, side)
	if not remember_drag(cx, side) then
		-- Measured while it shows, so it comes back at its width (a sidebar shown once and hidden before any
		-- settled fit has no measure yet).
		local cols, n = measure(cx, side)
		if cols and n then
			note_total(cols, n, false)
		end
	end
	local ok, err = cx.layout:park(side)
	if not ok then
		tern.log.warn("projects: park failed, closing the sidebar", err)
		cx.layout:close(side)
		S.side_pane = nil
	end
	S.side_gen += 1
	if main and cx.session:pane(main) and cx.session:focused() ~= main then
		cx.layout:focus(main)
	end
end

local function toggle_side(cx: WindowCx)
	if shown_side(cx) then
		hide_side(cx)
	else
		show_side(cx)
	end
end

-- Gives focus back to the pane the user works in after a click in the sidebar focused it.
local function refocus(cx: WindowCx, side: number)
	if cx.session:focused() ~= side then
		return
	end
	local main = S.last_main
	if main == nil or cx.session:pane(main) == nil or cx.session:tab_of(main) ~= cx.session:tab_of(side) then
		main = leftmost(tab_root(cx, cx.session:tab_of(side)), side)
	end
	if main then
		cx.layout:focus(main)
	end
end

-- Installs this module's functions into the context.
return function(ctx: core.Ctx)
	S = ctx
	S.find_side = find_side
	S.fit_later = fit_later
	S.hide_side = hide_side
	S.main_pane = main_pane
	S.parked = parked
	S.refocus = refocus
	S.rehome_side = rehome_side
	S.show_side = show_side
	S.start_ticker = start_ticker
	S.toggle_side = toggle_side
end
