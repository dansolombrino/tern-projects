--!strict
-- projects, mail: the window half of the mailbox (README "Mailbox"). The host half keeps the queue
-- (kv `mailbox.v1`) and serves the socket; this half
--
-- - runs a `mailbox.py watch` child whose output lines wake this window (Tern stalls an idle window's timers) as
--   mail arrives, and every few seconds anyway;
-- - delivers: the oldest queued message of each target agent goes out with `cx.agents:ask` (one atomic omp send)
--   only while that agent is idle or waiting for input, never mid-turn (tern-sdk#320), one per turn of the agent;
-- - reports each delivery to the host through a spool file, written in the same callback as the ask, so a reload
--   can never send one message twice;
-- - queues subagent report-backs (`S.mail_enqueue`) through the same spool, durable once the file is written;
-- - delivers a remote host's queue (its bridge's mail node, remote.luau) the same way while this window is that
--   host's leader, acking through the bridge's spool requests (held in memory until the host confirms; a reload
--   in between can send that one message again).
--
-- Only one window delivers this machine's queue: the first one watching (the helper names it the leader).

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

-- Queues a message durably (the host applies the spool within a second). Safe to call twice with one id. A target
-- pane on a remote host queues it on that host, under the host's pane id.
local function enqueue(msg: { id: string, target: mailq.Target, text: string, from: string })
	local t = msg.target
	local host = if t.pane then S.remote_host_of(t.pane :: number) else nil
	if host then
		local target = { pane = S.remote_hpane(host, t.pane :: number), cwd = t.cwd, session_file = t.session_file }
		core.spool_on(S, host, { op = "deliver", id = msg.id, target = target, text = msg.text, from = msg.from })
		return
	end
	spool_write({ op = "deliver", id = msg.id, target = msg.target, text = msg.text, from = msg.from })
end

local pass_pending = false
local pass: (cx: WindowCx) -> ()
local pass_soon: () -> ()
local remote_soon: (host: string) -> ()

-- Per remote host: ids asked whose ack that host has not applied (`sent` is this host's), and a pass queued.
local rsent: { [string]: { [string]: boolean } } = {}
local rpending: { [string]: boolean } = {}

-- A remote host's queue with its targets' host pane ids mapped to this window's (nil when unmapped: the session
-- file and folder still resolve).
local function mapped_box(host: string, raw: any): mailq.Box
	local box = mailq.normalize(raw)
	for _, m in box.msgs do
		local t = m.target
		if t.pane then
			m.target = { pane = S.wpane(host, t.pane :: number), cwd = t.cwd, session_file = t.session_file }
		end
	end
	return box
end

-- Asks for the oldest deliverable message of `box`, one per callback: lists the agents fresh (never trusting a
-- 2 s old state, tern-sdk#320), then one `ask`. Another pass follows while more could go out. `host` is the
-- remote host whose queue `box` is (nil: this machine's): only that host's agents are its targets.
local function ask_one(cx: WindowCx, box: mailq.Box, host: string?)
	local lok, list = pcall(function()
		return cx.agents:list()
	end)
	if not lok then
		return
	end
	local done = sent
	if host then
		done = rsent[host] or {}
		rsent[host] = done
	end
	local remote = next(S.remote) ~= nil
	local agents: { mailq.Agent } = {}
	for _, b in list do
		if not remote or S.remote_host_of(b.pane) == host then
			table.insert(agents, { pane = b.pane, cwd = b.cwd or "", state = b.state })
		end
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
		if not done[d.msg.id] then
			table.insert(todo, d)
		end
	end
	local d = todo[1]
	if d == nil then
		return
	end
	local id = d.msg.id
	local function report(state: string, err: string?)
		if host then
			-- The host's queue names its own pane ids.
			core.spool_on(S, host, { op = "ack", id = id, state = state, pane = S.remote_hpane(host, d.pane), error = err })
		else
			ack(id, state, d.pane, err)
		end
	end
	local aok, err = pcall(function()
		cx.agents:ask(d.pane, d.msg.text)
	end)
	hold[d.pane] = tern.now()
	if aok then
		-- Same callback as the ask: a reload cannot come between them.
		done[id] = true
		report("delivered", nil)
		tern.log.info("projects: mailbox delivered", id, d.pane, host)
	else
		local tk = if host then host .. "|" .. id else id
		tries[tk] = (tries[tk] or 0) + 1
		tern.log.warn("projects: mailbox ask failed", id, d.pane, err)
		if tries[tk] >= MAX_TRIES then
			done[id] = true
			report("failed", tostring(err))
		else
			hold[d.pane] = tern.now() - HOLD_MS + RETRY_MS
		end
	end
	if #todo > 1 then
		-- More to send: another pass (it waits for the host to apply this one's report first).
		if host then
			remote_soon(host)
		else
			pass_soon()
		end
	end
end

-- A remote host's pass, when this window is that host's leader: as `pass`, with the queue its bridge shows and
-- acks waiting in the bridge's spool instead of the spool folder.
local function pass_remote(cx: WindowCx, host: string)
	local R = S.remote[host]
	if R == nil or R.mail == nil or not S.remote_leader(host) then
		return
	end
	if S.remote_spooling(host) > 0 then
		remote_soon(host)
		return
	end
	local box = mapped_box(host, R.mail)
	local done = rsent[host]
	if done then
		for id in done do
			local m = mailq.find(box, id)
			if m == nil or m.state ~= "queued" then
				done[id] = nil
			end
		end
	end
	if mailq.pending(box) then
		budget.later("mail ask", 0, function(acx)
			ask_one(acx, box, host)
		end)
	end
end

remote_soon = function(host: string)
	if rpending[host] then
		return
	end
	rpending[host] = true
	budget.later("mail remote", 500, function(cx)
		rpending[host] = nil
		pass_remote(cx, host)
	end)
end

-- One delivery pass, in two callbacks: this one reads the queue; `ask_one` lists the agents and asks.
pass = function(cx: WindowCx)
	for host in S.remote do
		if S.remote_leader(host) then
			remote_soon(host)
		end
	end
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
			ask_one(acx, box, nil)
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
	-- Remote hosts' bridges are polled whether or not the sidebar shows (remote.luau; started once).
	S.remote_start()
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
	S.mail_remote = remote_soon
	S.mail_state = on_state
	S.mail_start = start_watch
	S.mail_leader = function(): boolean
		return leader
	end
end
