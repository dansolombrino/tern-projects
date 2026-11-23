--!strict
-- projects, remote: the window's side of the bridge to remote Tern hosts (the contract in README "Remote hosts").
-- A window half runs on the window's machine only, so a host half on a remote host is reached through a block it
-- defines (`projects.bridge`): this window opens one, parked, on each remote host it is attached to, reads the
-- host's models from the block's view (a JSON header, then status, fleet, gh, autos, mail and replies as JSON in
-- chunks of at most 30000 bytes) and sends requests as TSP action events (`rpc`). Per remote host it
--
-- - finds (or, while that host is current, opens) the bridge, one per host;
-- - polls the header every 2 s and reads only the parts whose signature changed, one chunk per timer callback;
-- - maps host pane ids to this window's (`S.wpane`), from the bridge pane, verified against the host's panes;
-- - runs requests (`S.remote_rpc`), durable spool requests (`S.remote_spool`), liveness (`hello`, leader) and the
--   project list the host needs (`sync`);
-- - merges the host's status into the window's lookups (`S.remote_merge`, called by the scan).
--
-- With no remote host attached it costs one `cx.hosts:list()` per poll.

local core = require("./core")
local budget = require("./budget")
local rp = require("./remotepure")

local S: core.Ctx = nil :: any

local BLOCK = "projects.bridge"
-- Poll period, replies poll while requests wait, hello period (all ms).
local POLL_MS = 2000
local REPLY_MS = 300
local HELLO_MS = 5000
-- A full pane scan for bridges this often even while one is known (another window's extra bridge).
local SCAN_MS = 30000
-- One bridge open attempt per host per OPEN_S; a host without the plugin is retried after NO_PLUGIN_S.
local OPEN_S = 30
local NO_PLUGIN_S = 300
-- A request waiting this long for a bridge fails `no-bridge`; a spool request is resent after SPOOL_MS.
local NO_BRIDGE_MS = 8000
local SPOOL_MS = 3000
local SYNC_MS = 2000
-- Tern's cap on surface text per read.
local MAX_CHARS = 64000

-- This window's run: requests carry it, and the host names its leader by it.
local WIN = string.format("w%x-%04x", os.time(), math.random(0, 0xffff))

type Remote = {
	-- The bridge's window pane, its pane-id base once verified, and the decoded nodes.
	pane: number?,
	base: number?,
	header: any,
	status: any,
	fleet: any,
	gh: any,
	autos: any,
	mail: any,
	replies: any,
	-- From the last hosts list: the host's window panes, whether it is current and connected.
	panes: { [number]: boolean },
	current: boolean,
	connected: boolean,
	-- Signatures of the parts read so far, and the parts being read (chunk by chunk); window pane → host pane seen
	-- mapped.
	seen: { [string]: any },
	asm: { [string]: rp.Asm },
	rmap: { [number]: number },
	why: string?,
	-- tern.now() a poll round / a replies poll was scheduled, -inf when none waits (a timer Tern dropped expires).
	busy: number,
	rloop: number,
	scan_at: number,
	opened_at: number,
	no_plugin_at: number?,
	hello_at: number,
	sync_sig: string?,
	sync_at: number,
	leader: boolean,
	logged: { [string]: boolean },
}

type Pending = {
	host: string,
	req: { [string]: any },
	cb: (reply: any, cx: WindowCx?) -> (),
	deadline: number,
	since: number,
	sent: boolean,
}

local pending: { [string]: Pending } = {}
local spools: { [string]: { host: string, id: string, obj: { [string]: any } } } = {}
local seq = 0
-- tern.now() of the last poll; the loop is started again when it stopped (a turn with no window ends a chain).
local last_tick = -math.huge

local function remotes(): { [string]: Remote }
	return S.remote
end

local function new_remote(): Remote
	return {
		pane = nil,
		base = nil,
		header = nil,
		status = nil,
		fleet = nil,
		gh = nil,
		autos = nil,
		mail = nil,
		replies = nil,
		panes = {},
		current = false,
		connected = false,
		seen = {},
		asm = {},
		rmap = {},
		why = nil,
		busy = -math.huge,
		rloop = -math.huge,
		scan_at = -SCAN_MS,
		opened_at = -OPEN_S,
		no_plugin_at = nil,
		hello_at = -HELLO_MS,
		sync_sig = nil,
		sync_at = -SYNC_MS,
		leader = false,
		logged = {},
	}
end

local function log_once(R: Remote, key: string, ...: any)
	if not R.logged[key] then
		R.logged[key] = true
		tern.log.warn(...)
	end
end

-- Host pane → window pane, nil while the base is unverified or the pane is not one of the host's.
local function wpane(host: string, hpane: number): number?
	local R = remotes()[host]
	if R == nil or R.base == nil then
		return nil
	end
	local w = rp.to_window(R.base :: number, hpane)
	if not R.panes[w] then
		return nil
	end
	R.rmap[w] = hpane
	return w
end

-- Window pane → host pane (a pane just started has no host id seen yet: the base computes it).
local function hpane(host: string, w: number): number?
	local R = remotes()[host]
	if R == nil then
		return nil
	end
	return R.rmap[w] or (if R.base then rp.to_host(R.base :: number, w) else nil)
end

-- The remote host running window pane `w`, from the last hosts list (nil: this machine, or unknown).
local function host_of(w: number): string?
	for name, R in remotes() do
		if R.panes[w] then
			return name
		end
	end
	return nil
end

local function finish(id: string, reply: any, cx: WindowCx?)
	local p = pending[id]
	if p == nil then
		return
	end
	pending[id] = nil
	local ok, err = pcall(p.cb, reply, cx)
	if not ok then
		tern.log.warn("projects: remote reply handler failed", p.req.op, err)
	end
end

-- Sends one request through the host's bridge (a cheap native call). False when it could not.
local function send(cx: WindowCx, R: Remote, req: { [string]: any }): boolean
	if R.pane == nil then
		return false
	end
	local ok, err = pcall(function()
		cx.session:event(R.pane :: number, { ev = "action", id = "rpc", act = "rpc", value = tern.json.encode(req) })
	end)
	if not ok then
		log_once(R, "send", "projects: remote request not sent", req.op, err)
	end
	return ok
end

-- The bridge's header (`main.0`, one text node), decoded; nil when it could not be read.
local function fetch_header(cx: WindowCx, R: Remote): any
	local ok, tree = pcall(function()
		return cx.session:surface(R.pane :: number, { root = "main.0", max_chars = MAX_CHARS })
	end)
	local text = if ok then rp.node_text(tree, "main.0") else nil
	if text == nil then
		return nil
	end
	local dok, h = pcall(tern.json.decode, text)
	return if dok and type(h) == "table" then h else nil
end

type Schedule = (fn: (cx: WindowCx) -> ()) -> ()
type Done = (cx: WindowCx, text: string, sig: string) -> ()

-- Reads the next chunk of part assembly `a` (one surface read per callback), then calls `done` with the part's
-- text. Starts over when the header (re-read meanwhile) names another version of the part; stops when another
-- read replaced it, or a chunk is missing (the next header read starts it again).
local function read_chunk(cx: WindowCx, host: string, a: rp.Asm, schedule: Schedule, done: Done)
	local R = remotes()[host]
	if R == nil or R.pane == nil or R.asm[a.name] ~= a then
		return
	end
	if rp.asm_stale(a, R.header) then
		local fresh = rp.asm_new(a.name, R.header)
		R.asm[a.name] = fresh
		if fresh then
			schedule(function(ncx)
				read_chunk(ncx, host, fresh :: rp.Asm, schedule, done)
			end)
		end
		return
	end
	local id = rp.asm_next(a)
	if id then
		local ok, tree = pcall(function()
			return cx.session:surface(R.pane :: number, { root = id, max_chars = MAX_CHARS })
		end)
		local text = if ok then rp.node_text(tree, id :: string) else nil
		if text == nil then
			R.asm[a.name] = nil
			return
		end
		rp.asm_add(a, text :: string)
	end
	if rp.asm_next(a) then
		schedule(function(ncx)
			read_chunk(ncx, host, a, schedule, done)
		end)
		return
	end
	R.asm[a.name] = nil
	done(cx, rp.asm_text(a) or "", a.sig)
end

-- Starts reading part `name` as the last header describes it, unless that version is being read already.
local function start_part(host: string, name: string, schedule: Schedule, done: Done)
	local R = remotes()[host]
	if R == nil then
		return
	end
	local cur = R.asm[name]
	if cur and not rp.asm_stale(cur, R.header) then
		return
	end
	local a = rp.asm_new(name, R.header)
	R.asm[name] = a
	if a == nil then
		log_once(R, "parts " .. name, "projects: " .. host .. "'s bridge header has no chunk count for " .. name .. " (old host half?)")
		return
	end
	schedule(function(cx)
		read_chunk(cx, host, a :: rp.Asm, schedule, done)
	end)
end

-- Part reads of the poll share the scan's job queue; replies chain on timers of their own (a request waits).
local function in_queue(fn: (cx: WindowCx) -> ())
	S.enqueue(fn)
end
local function on_timer(fn: (cx: WindowCx) -> ())
	budget.later("remote replies", 0, fn)
end

-- The replies part is in: complete the requests it answers.
local function replies_done(host: string): Done
	return function(cx: WindowCx, text: string, sig: string)
		local R = remotes()[host]
		if R == nil then
			return
		end
		R.seen.replies = sig
		local dok, doc = pcall(tern.json.decode, text)
		if not dok or type(doc) ~= "table" then
			return
		end
		R.replies = doc
		for id, reply in doc do
			local p = pending[id]
			if p and p.host == host then
				finish(id, reply, cx)
			end
		end
	end
end

local poll_replies: (cx: WindowCx, host: string) -> ()

local function reply_loop(host: string)
	local R = remotes()[host]
	if R == nil or tern.now() - R.rloop < 2000 then
		return
	end
	R.rloop = tern.now()
	budget.later("remote replies", REPLY_MS, function(cx)
		R.rloop = -math.huge
		poll_replies(cx, host)
	end)
end

-- Sends what waits for `host`, fails what timed out, and reads the replies node while sent requests wait.
poll_replies = function(cx: WindowCx, host: string)
	local R = remotes()[host]
	local now = tern.now()
	local waiting, sent = false, false
	for id, p in pending do
		if p.host == host then
			if R == nil then
				finish(id, { ok = false, error = "no-bridge" }, cx)
			elseif now >= p.deadline then
				finish(id, { ok = false, error = "timeout" }, cx)
			elseif not p.sent and R.pane == nil and now - p.since >= NO_BRIDGE_MS then
				finish(id, { ok = false, error = "no-bridge" }, cx)
			else
				if not p.sent and R.pane then
					p.sent = send(cx, R, p.req)
				end
				waiting = true
				sent = sent or p.sent
			end
		end
	end
	if R == nil or not waiting then
		return
	end
	-- While sent requests wait: the header (one read), then the replies part, chunk by chunk, when it changed.
	if sent and R.pane then
		local h = fetch_header(cx, R)
		if h then
			R.header = h
			local sig = if type(h.sig) == "table" then h.sig.replies else nil
			if sig ~= nil and tostring(sig) ~= tostring(R.seen.replies) then
				start_part(host, "replies", on_timer, replies_done(host))
			end
		end
	end
	for _, p in pending do
		if p.host == host then
			reply_loop(host)
			break
		end
	end
end

-- A request to `host`'s host half; `cb` runs once, with its reply or `{ok=false, error="no-bridge"|"timeout"}`.
local function remote_rpc(host: string, req: { [string]: any }, cb: (reply: any, cx: WindowCx?) -> (), timeout_ms: number?)
	S.remote_start()
	seq += 1
	req.id = req.id or string.format("%s-%d", WIN, seq)
	req.win = WIN
	if remotes()[host] == nil then
		core.defer(function(cx)
			pcall(cb, { ok = false, error = "no-bridge" }, cx)
		end)
		return
	end
	local now = tern.now()
	pending[req.id] = { host = host, req = req, cb = cb, deadline = now + (timeout_ms or 30000), since = now, sent = false }
	-- Sent from a timer callback of its own (a caller may have no cx); replies polled from the next.
	budget.later("remote send", 0, function(cx)
		local R = remotes()[host]
		local p = pending[req.id]
		if R and p and not p.sent then
			p.sent = send(cx, R, req)
		end
		reply_loop(host)
	end)
end

-- A spool request (deliver, ack, gh_*, auto_*): resent with the same id every SPOOL_MS until the host confirms it
-- (it applies an id once), held in memory while there is no bridge.
local function send_spool(id: string)
	local e = spools[id]
	if e == nil then
		return
	end
	remote_rpc(e.host, { op = "spool", id = id, obj = e.obj }, function(reply: any, _cx: WindowCx?)
		if type(reply) == "table" and reply.ok == true then
			spools[id] = nil
		elseif type(reply) == "table" and reply.error ~= "timeout" and reply.error ~= "no-bridge" then
			-- The host refused it: resending would not help.
			spools[id] = nil
			tern.log.warn("projects: remote spool refused", e.host, e.obj.op, reply.error)
		else
			budget.later("remote spool", SPOOL_MS, function()
				send_spool(id)
			end)
		end
	end, SPOOL_MS)
end

local function remote_spool(host: string, obj: { [string]: any })
	seq += 1
	local id = string.format("%s-s%d", WIN, seq)
	spools[id] = { host = host, id = id, obj = obj }
	send_spool(id)
end

-- Spool requests to `host` not confirmed yet.
local function spooling(host: string): number
	local n = 0
	for _, e in spools do
		if e.host == host then
			n += 1
		end
	end
	return n
end

-- Re-checks the base against the host's panes and its status; a change re-maps the fleets.
local function verify(host: string, R: Remote)
	local h = if type(R.header) == "table" then R.header.pane else nil
	local old = R.base
	if R.pane == nil or type(h) ~= "number" then
		R.base = nil
	else
		local base = rp.base_of(R.pane :: number, h)
		local ok, why = rp.verify(base, R.pane :: number, h, R.panes, if R.status then rp.status_panes(R.status) else nil)
		R.base = if ok then base else nil
		if not ok and why ~= R.why then
			tern.log.warn("projects: remote pane ids of " .. host .. " not mapped:", why)
		end
		R.why = why
	end
	if R.base ~= old then
		table.clear(R.rmap)
		S.dirty = true
		if S.fleets_remote then
			S.fleets_remote()
		end
	end
end

-- The host's node `name` changed: tell the module that shows it.
local function on_node(cx: WindowCx, host: string, R: Remote, name: string)
	if name == "status" then
		verify(host, R)
		S.dirty = true
	elseif name == "fleet" then
		if S.fleets_remote then
			S.fleets_remote()
		end
	elseif name == "gh" then
		if S.gh_remote then
			S.gh_remote(cx, host)
		end
	elseif name == "autos" then
		if S.autos_remote then
			S.autos_remote(host)
		end
	elseif name == "mail" then
		if S.mail_remote then
			S.mail_remote(host)
		end
	end
end

-- Part `name` is in: decode it and tell the module that shows it.
local function part_done(host: string, name: string): Done
	return function(cx: WindowCx, text: string, sig: string)
		local R = remotes()[host]
		if R == nil then
			return
		end
		R.seen[name] = sig
		local dok, doc = pcall(tern.json.decode, text)
		if not dok or type(doc) ~= "table" then
			log_once(R, "json " .. name, string.format("projects: %s's %s is not JSON (%d chars)", host, name, #text))
			return
		end
		R.logged["json " .. name] = nil
		(R :: any)[name] = doc
		on_node(cx, host, R, name)
	end
end

local function end_round(host: string)
	S.enqueue(function(_cx)
		local R = remotes()[host]
		if R then
			R.busy = -math.huge
		end
	end)
end

-- Reads the header; queues reads of the nodes it says changed (one per callback); says hello; pushes `sync`.
local function read_header(cx: WindowCx, host: string)
	local R = remotes()[host]
	if R == nil or R.pane == nil then
		return
	end
	local h = fetch_header(cx, R)
	if h == nil then
		return
	end
	R.header = h
	verify(host, R)
	local leader = h.leader == WIN
	if leader ~= R.leader then
		R.leader = leader
		if leader and S.mail_remote then
			S.mail_remote(host)
		end
	end
	local now = tern.now()
	if now - R.hello_at >= HELLO_MS then
		R.hello_at = now
		seq += 1
		send(cx, R, { op = "hello", id = string.format("%s-h%d", WIN, seq), win = WIN })
	end
	if now - R.sync_at >= SYNC_MS then
		local body = rp.sync_body(S.state.projects, S.state.agents :: any, host, S.ui.visible == true)
		local sig = tern.json.encode(body)
		if sig ~= R.sync_sig then
			R.sync_sig = sig
			R.sync_at = now
			remote_rpc(host, body, function(reply: any, _cx: WindowCx?)
				if type(reply) ~= "table" or reply.ok ~= true then
					R.sync_sig = nil
				end
			end, 15000)
		end
	end
	local sigs = if type(h.sig) == "table" then h.sig else {}
	for _, name in rp.changed(R.seen, sigs) do
		-- Replies are read only while requests wait (poll_replies); a part already being read at this version
		-- goes on (start_part), one at another starts over.
		if name ~= "replies" then
			start_part(host, name, in_queue, part_done(host, name))
		end
	end
end

-- Opens a bridge on `host` (the current host) and parks it in the same callback, so it never shows.
local function open_bridge(cx: WindowCx, host: string)
	local R = remotes()[host]
	if R == nil or R.pane ~= nil or not R.current then
		return
	end
	R.opened_at = os.time()
	local ok, pane = pcall(function()
		return cx:new_block(BLOCK, {}, "tab", { focus = false })
	end)
	if not ok or pane == nil then
		R.no_plugin_at = os.time()
		log_once(R, "no plugin", "projects: no bridge on " .. host .. " (is the projects plugin installed there?)", if ok then nil else pane)
		return
	end
	pcall(function()
		cx.layout:park(pane :: number)
	end)
	R.no_plugin_at = nil
	R.logged["no plugin"] = nil
	R.pane = pane :: number
	tern.log.info("projects: bridge opened on", host, pane)
end

-- Finds the host's bridge among this window's panes (the lowest id; extras close, so windows sharing one agree).
local function find_bridge(cx: WindowCx, host: string)
	local R = remotes()[host]
	if R == nil then
		return
	end
	R.scan_at = tern.now()
	local ok, list = pcall(function()
		return cx.session:panes()
	end)
	if not ok then
		return
	end
	local found: { number } = {}
	for _, info in list do
		if info.block == BLOCK and R.panes[info.pane] then
			table.insert(found, info.pane)
		end
	end
	table.sort(found)
	local keep = found[1]
	for i = 2, #found do
		pcall(function()
			cx.layout:close(found[i])
		end)
	end
	if keep ~= R.pane then
		R.pane = keep
		R.base = nil
		R.header = nil
		R.why = nil
		table.clear(R.seen)
		table.clear(R.asm)
		table.clear(R.rmap)
		R.sync_sig = nil
		R.hello_at = -HELLO_MS
		R.leader = false
		S.dirty = true
	end
	if keep == nil and R.current and os.time() - R.opened_at >= OPEN_S and (R.no_plugin_at == nil or os.time() - (R.no_plugin_at :: number) >= NO_PLUGIN_S) then
		S.enqueue(function(ocx)
			open_bridge(ocx, host)
		end)
	end
end

-- One poll of `host`: the bridge (found again when gone, or every SCAN_MS), then the header, each in a callback
-- of its own.
local function round(host: string)
	local R = remotes()[host]
	if R == nil or tern.now() - R.busy < 10000 then
		return
	end
	R.busy = tern.now()
	if R.pane == nil or not R.panes[R.pane :: number] or tern.now() - R.scan_at >= SCAN_MS then
		S.enqueue(function(cx)
			find_bridge(cx, host)
		end)
	end
	S.enqueue(function(cx)
		read_header(cx, host)
	end)
	end_round(host)
end

local function tick(cx: WindowCx)
	budget.later("remote", POLL_MS, tick)
	last_tick = tern.now()
	local seen: { [string]: boolean } = {}
	for _, h in core.hosts_list(cx) do
		if h.kind == "remote" then
			seen[h.name] = true
			local R = remotes()[h.name]
			if R == nil then
				R = new_remote()
				remotes()[h.name] = R
			end
			local set: { [number]: boolean } = {}
			for _, p in h.panes or {} do
				set[p] = true
			end
			R.panes = set
			R.current = h.current == true
			R.connected = h.state == "connected"
		end
	end
	for name in remotes() do
		if not seen[name] then
			remotes()[name] = nil
			S.dirty = true
			if S.fleets_remote then
				S.fleets_remote()
			end
			poll_replies(cx, name)
		end
	end
	for name, R in remotes() do
		if R.connected then
			round(name)
		end
	end
end

local function start()
	if tern.now() - last_tick < 3 * POLL_MS then
		return
	end
	last_tick = tern.now()
	budget.later("remote", 0, tick)
end

-- The scan's hook (core.scan_rest, after the local status): each remote host's panes, branches and queued mail.
local function merge()
	start()
	for name, R in remotes() do
		if R.status then
			S.mail_queued += rp.merge(R.status, function(h: number): number?
				return wpane(name, h)
			end, S.sessions, S.host_repos)
		end
	end
end

return function(ctx: core.Ctx)
	S = ctx
	S.remote = {} :: { [string]: Remote }
	S.remote_win = WIN
	S.remote_start = start
	S.remote_merge = merge
	S.remote_rpc = remote_rpc
	S.remote_spool = remote_spool
	S.remote_spooling = spooling
	S.remote_host_of = host_of
	S.remote_hpane = hpane
	S.wpane = wpane
	S.remote_leader = function(host: string): boolean
		local R = remotes()[host]
		return R ~= nil and R.leader
	end
	S.host_now = core.host_now
	S.host_of_pane = core.host_of_pane
end
