--!strict
-- projects, mail: the window half of the fleet mailbox (README "Fleet mailbox"). The host half keeps the queue
-- (kv `mailbox.v1`) and serves the socket; this half
--
-- - runs a `mailbox.py watch` child whose output lines wake this window (Tern stalls an idle window's timers) as
--   mail arrives, and every few seconds anyway;
-- - delivers: the oldest queued message of each target agent goes out with `cx.agents:ask` (one atomic omp send)
--   only while that agent is idle or waiting for input, never mid-turn (tern-sdk#320), one per turn of the agent;
-- - reports each delivery to the host through a spool file, written in the same callback as the ask, so a reload
--   can never send one message twice;
-- - queues subagent report-backs (`S.mail_enqueue`) through the same spool, durable once the file is written.
--
-- Only one window delivers: the first one watching (the helper names it the leader).

local mailq = require("./mailq")
local identity = require("./identity")
local budget = require("./budget")
local core = require("./core")

local S: core.Ctx = nil :: any

local DATA = tern.plugin.data
local SPOOL = DATA .. "/spool"
local HELPER = tern.plugin.dir .. "/mailbox.py"

-- A pane just asked is held this long unless its turn visibly ran and ended first (ms).
local HOLD_MS = 120000
-- A pane whose ask failed is retried after this long (ms), and the message fails after this many failures.
local RETRY_MS = 10000
local MAX_TRIES = 5

local watcher: Child? = nil
local unloading = false
-- This window delivers: the helper made it the leader, or no helper answers (then every window would; a single
-- window is the common case and the queue stays durable either way).
local leader = false
-- Pane → when it was asked (tern.now()); message id → failed asks; ids asked whose ack the host has not applied.
local hold: { [number]: number } = {}
local tries: { [string]: number } = {}
local sent: { [string]: boolean } = {}
local spool_seq = 0

local function spool_write(obj: { [string]: any })
	spool_seq += 1
	local name = string.format("%012d-%06d-%04x.json", os.time(), spool_seq, math.random(0, 0xffff))
	pcall(tern.fs.mkdir, SPOOL)
	tern.fs.write(SPOOL .. "/" .. name, tern.json.encode(obj))
end

local function ack(id: string, state: string, pane: number?, err: string?)
	spool_write({ op = "ack", id = id, state = state, pane = pane, error = err })
end

-- Queues a message durably (the host applies the spool within a second). Safe to call twice with one id.
local function enqueue(msg: { id: string, target: mailq.Target, text: string, from: string })
	spool_write({ op = "deliver", id = msg.id, target = msg.target, text = msg.text, from = msg.from })
end

local pass_pending = false
local pass: (cx: WindowCx) -> ()
local pass_soon: () -> ()

-- Asks for the oldest deliverable message of `box`, one per callback: lists the agents fresh (never trusting a
-- 2 s old state, tern-sdk#320), then one `ask`. Another pass follows while more could go out.
local function ask_one(cx: WindowCx, box: mailq.Box)
	local lok, list = pcall(function()
		return cx.agents:list()
	end)
	if not lok then
		return
	end
	local agents: { mailq.Agent } = {}
	for _, b in list do
		table.insert(agents, { pane = b.pane, cwd = b.cwd or "", state = b.state })
	end
	local now = tern.now()
	local held: { [number]: boolean } = {}
	for pane, at in hold do
		if now - at < HOLD_MS then
			held[pane] = true
		else
			hold[pane] = nil
		end
	end
	local todo: { { msg: mailq.Msg, pane: number } } = {}
	for _, d in mailq.deliverable(box, agents, S.sessions, identity.canon, held) do
		if not sent[d.msg.id] then
			table.insert(todo, d)
		end
	end
	local d = todo[1]
	if d == nil then
		return
	end
	local id = d.msg.id
	local aok, err = pcall(function()
		cx.agents:ask(d.pane, d.msg.text)
	end)
	hold[d.pane] = tern.now()
	if aok then
		-- Same callback as the ask: a reload cannot come between them.
		sent[id] = true
		ack(id, "delivered", d.pane)
		tern.log.info("projects: mailbox delivered", id, d.pane)
	else
		tries[id] = (tries[id] or 0) + 1
		tern.log.warn("projects: mailbox ask failed", id, d.pane, err)
		if tries[id] >= MAX_TRIES then
			sent[id] = true
			ack(id, "failed", d.pane, tostring(err))
		else
			hold[d.pane] = tern.now() - HOLD_MS + RETRY_MS
		end
	end
	if #todo > 1 then
		-- More to send: another pass (it waits for the host to apply this one's report first).
		pass_soon()
	end
end

-- One delivery pass, in two callbacks: this one reads the queue; `ask_one` lists the agents and asks.
pass = function(cx: WindowCx)
	if not leader then
		return
	end
	-- Reports the host has not applied yet could be sends of this very queue (a reload of this window loses
	-- `sent`): wait until the spool is empty, so no message goes out twice.
	local lsok, names = pcall(tern.fs.list, SPOOL)
	if lsok and #names > 0 then
		budget.later("mail", 500, pass)
		return
	end
	local ok, raw = pcall(tern.kv.get, mailq.KEY)
	local box = mailq.normalize(if ok then raw else nil)
	-- Forget sends the host has applied.
	for id in sent do
		local m = mailq.find(box, id)
		if m == nil or m.state ~= "queued" then
			sent[id] = nil
		end
	end
	if mailq.pending(box) then
		budget.later("mail ask", 0, function(acx)
			ask_one(acx, box)
		end)
	end
end

pass_soon = function()
	if pass_pending then
		return
	end
	pass_pending = true
	budget.later("mail", 0, function(cx)
		pass_pending = false
		pass(cx)
	end)
end

local start_watch: () -> ()

local function on_line(line: string)
	local ok, ev = pcall(tern.json.decode, line)
	if not ok or type(ev) ~= "table" then
		return
	end
	local kind = ev.event
	if kind == "hello" or kind == "leader" then
		leader = ev.leader == true
	elseif kind == "nohelper" then
		leader = true
	end
	if kind == "tick" then
		-- The tick keeps this window's timers going; deliver only when something waits.
		if (S.mail_queued or 0) > 0 or next(sent) ~= nil then
			pass_soon()
		end
	else
		pass_soon()
	end
	-- Automations: a new model, pane runs to start or to check (autowin.luau).
	S.auto_wake()
end

start_watch = function()
	if unloading or watcher then
		return
	end
	local ok, child = pcall(tern.process.spawn, { "/usr/bin/env", "python3", HELPER, "watch", "--data", DATA }, {
		stdout = function(line: string)
			on_line(line)
		end,
		stderr = function(line: string)
			tern.log.warn("projects: mailbox watcher", line)
		end,
		exit = function(_res: SpawnExit)
			watcher = nil
			leader = false
			if not unloading then
				tern.timer(3000, start_watch)
			end
		end,
	})
	if ok then
		watcher = child
	else
		tern.log.warn("projects: mailbox watcher not started", child)
		tern.timer(10000, start_watch)
	end
end

tern.on("unload", function()
	unloading = true
	if watcher then
		pcall(function()
			(watcher :: Child):kill()
		end)
		watcher = nil
	end
end)

-- An agent's turn ended (or it now waits for input): it may take its next message.
local function on_state(pane: number, old: string?, new: string)
	if new == "working" then
		-- Its turn runs: release the hold once it ends.
		if hold[pane] then
			hold[pane] = tern.now() - HOLD_MS + 1000
		end
	elseif old == "working" then
		hold[pane] = nil
		pass_soon()
	end
end

return function(ctx: core.Ctx)
	S = ctx
	S.mail_enqueue = enqueue
	S.mail_state = on_state
	S.mail_start = start_watch
	S.mail_leader = function(): boolean
		return leader
	end
end
