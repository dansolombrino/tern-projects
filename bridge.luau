--!strict
-- The host half's bridge block (`projects.bridge`), its pure part: a window on another machine reaches this host's
-- half only through a plugin block it opens here, sending requests as block events and reading the block's view
-- (README "Remote hosts"). host.luau owns the processes, files and the block; this module holds what can be tested
-- without Tern: request parsing and validation, reply caps, leader choice, dedupe and reply bookkeeping, node sigs,
-- the mail subset, the synced project list, `~` expansion and the paths that differ between macOS and Linux.

local mailq = require("./mailq")

local bridge = {}

-- The view's layout; remotepure.VERSION must match (2: one node fewer after status, the later nodes moved up).
bridge.VERSION = 2
-- A window that said nothing for this long is gone (it says hello every few seconds).
bridge.LIVE_S = 15
-- How long a reply stays in the view for its window to read it.
bridge.REPLY_S = 120
-- How long a spool id is remembered, so a resent request is applied once.
bridge.SEEN_S = 600
-- Each of a git reply's stdout and stderr is capped at this many bytes.
bridge.CAP = 65536
bridge.MAX_ID = 200
bridge.GIT_TIMEOUT_MS = 30000
bridge.GIT_TIMEOUT_MAX_MS = 120000
-- The kv key of the synced project list.
bridge.SYNC_KEY = "projects.hostsync.v1"
-- The view's text nodes, in their fixed order (main.0 .. main.5).
bridge.NODES = { "header", "status", "gh", "autos", "mail", "replies" }

export type Request = { [string]: any }
export type SyncProject = { id: string, name: string, root: string }
export type Sync = { projects: { SyncProject }, worktrees: { string }, visible: boolean, at: number }
export type Win = { seq: number, last: number }
export type Wins = { [string]: Win }
export type Replies = { [string]: { at: number, reply: any } }
export type Seen = { [string]: number }
export type Sigs = { run: string, n: { [string]: number }, text: { [string]: string }, chunks: { [string]: { string } } }

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- `~` and `~/…` on this host: the host's HOME.
function bridge.expand(path: string, home: string?): string
	if home and (path == "~" or string.sub(path, 1, 2) == "~/") then
		return home .. string.sub(path, 2)
	end
	return path
end

-- The request an event carries: `ev.value` when it is a string (`act = "rpc"`, value split off by Tern), else what
-- follows a leading `rpc=` in `act`. nil when the event is no request.
function bridge.request_text(ev: any): string?
	if type(ev) ~= "table" then
		return nil
	end
	if type(ev.value) == "string" and ev.value ~= "" then
		return ev.value
	end
	if type(ev.act) == "string" and string.sub(ev.act, 1, 4) == "rpc=" then
		return string.sub(ev.act, 5)
	end
	return nil
end

local OPS = { hello = true, spool = true, git = true, fs = true, sync = true }
local FS = { exists = true, mkdir = true, dirs = true, home = true }

-- Checks a decoded request. Returns the error code (`bad-request`) and a message when it is malformed; `id` is
-- returned when the request had a usable one, so the error can be replied to.
function bridge.validate(req: any): (string?, string?, string?)
	if type(req) ~= "table" then
		return "bad-request", "the request must be a JSON object", nil
	end
	local id = if type(req.id) == "string" and req.id ~= "" and #req.id <= bridge.MAX_ID then req.id else nil
	if not str(req.win) then
		return "bad-request", "win must be a string", id
	end
	if req.op == "hello" then
		return nil, nil, id
	end
	if not id then
		return "bad-request", "id must be a string of 1-" .. bridge.MAX_ID .. " bytes", nil
	end
	if not OPS[req.op] then
		return "bad-request", "unknown op " .. tostring(req.op), id
	end
	if req.op == "spool" then
		if type(req.obj) ~= "table" or type(req.obj.op) ~= "string" then
			return "bad-request", "obj must be a spool object", id
		end
	elseif req.op == "git" then
		if type(req.args) ~= "table" or #req.args == 0 then
			return "bad-request", "args must be a list of strings", id
		end
		for i, a in req.args do
			if type(i) ~= "number" or type(a) ~= "string" then
				return "bad-request", "args must be a list of strings", id
			end
		end
		if req.cwd ~= nil and not str(req.cwd) then
			return "bad-request", "cwd must be a string", id
		end
		if req.timeout_ms ~= nil and (type(req.timeout_ms) ~= "number" or req.timeout_ms <= 0) then
			return "bad-request", "timeout_ms must be a positive number", id
		end
	elseif req.op == "fs" then
		if not FS[req.fn] then
			return "bad-request", "fn must be exists, mkdir, dirs or home", id
		end
		if req.fn ~= "home" and not str(req.path) then
			return "bad-request", "path must be a string", id
		end
	elseif req.op == "sync" then
		if type(req.projects) ~= "table" or (req.worktrees ~= nil and type(req.worktrees) ~= "table") then
			return "bad-request", "projects must be a list", id
		end
	end
	return nil, nil, id
end

function bridge.git_timeout(ms: any): number
	if type(ms) ~= "number" or ms <= 0 then
		return bridge.GIT_TIMEOUT_MS
	end
	return math.min(ms, bridge.GIT_TIMEOUT_MAX_MS)
end

-- `s` cut to at most `n` bytes, never inside a UTF-8 sequence (the view is JSON text).
function bridge.cap(s: string, n: number?): string
	local max = n or bridge.CAP
	if #s <= max then
		return s
	end
	local cut = max
	-- Back off continuation bytes so the sequence that starts at cut + 1 is dropped whole.
	while cut > 0 do
		local b = string.byte(s, cut + 1)
		if b == nil or b < 0x80 or b >= 0xC0 then
			break
		end
		cut -= 1
	end
	return string.sub(s, 1, cut)
end

-- The git reply of a process result.
function bridge.git_reply(res: { status: number, stdout: string, stderr: string, timed_out: boolean? }): { [string]: any }
	return {
		ok = true,
		status = res.status,
		stdout = bridge.cap(res.stdout),
		stderr = bridge.cap(res.stderr),
		timed_out = res.timed_out == true,
	}
end

-- The visible subfolder names in `find -L DIR -mindepth 1 -maxdepth 1 -type d` output, sorted.
function bridge.dir_names(stdout: string): { string }
	local out: { string } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local name = string.match(line, "([^/]+)/*$")
		if name and string.sub(name, 1, 1) ~= "." then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

-- Leader election ------------------------------------------------------------------------

-- Records a hello from `win`; a window back after going silent queues behind the live ones. Returns the next seq.
function bridge.hello(wins: Wins, win: string, now: number, seq: number): number
	local w = wins[win]
	if w and now - w.last <= bridge.LIVE_S then
		w.last = now
		return seq
	end
	wins[win] = { seq = seq + 1, last = now }
	return seq + 1
end

-- Forgets silent windows; true when one went.
function bridge.prune_wins(wins: Wins, now: number): boolean
	local gone = false
	for win, w in wins do
		if now - w.last > bridge.LIVE_S then
			wins[win] = nil
			gone = true
		end
	end
	return gone
end

-- The live window that said hello first, or nil.
function bridge.leader(wins: Wins, now: number): string?
	local best: string? = nil
	local best_seq = math.huge
	for win, w in wins do
		if now - w.last <= bridge.LIVE_S and w.seq < best_seq then
			best, best_seq = win, w.seq
		end
	end
	return best
end

-- Dedupe and replies ----------------------------------------------------------------------

-- Whether spool id `id` was applied in the last SEEN_S; records it either way.
function bridge.seen(seen: Seen, id: string, now: number): boolean
	local at = seen[id]
	seen[id] = now
	return at ~= nil and now - at <= bridge.SEEN_S
end

function bridge.prune_seen(seen: Seen, now: number)
	for id, at in seen do
		if now - at > bridge.SEEN_S then
			seen[id] = nil
		end
	end
end

function bridge.put_reply(replies: Replies, id: string, reply: any, now: number)
	replies[id] = { at = now, reply = reply }
end

-- Drops replies older than REPLY_S; true when one went.
function bridge.prune_replies(replies: Replies, now: number): boolean
	local gone = false
	for id, r in replies do
		if now - r.at > bridge.REPLY_S then
			replies[id] = nil
			gone = true
		end
	end
	return gone
end

-- main.5: `{ [id] = reply }`.
function bridge.replies_doc(replies: Replies): { [string]: any }
	local out: { [string]: any } = {}
	for id, r in replies do
		out[id] = r.reply
	end
	return out
end

-- Node text and sigs ----------------------------------------------------------------------

function bridge.sigs(run: string): Sigs
	return { run = run, n = {}, text = {}, chunks = {} }
end

-- A window's surface read is capped at 64000 chars, so each payload node is a col of text children of at most this
-- many bytes each (main.K.I).
bridge.CHUNK = 30000

-- `text` in pieces of at most `n` bytes, cut between UTF-8 characters; "" is one empty piece.
function bridge.chunks(text: string, n: number?): { string }
	local size = n or bridge.CHUNK
	local out: { string } = {}
	local rest = text
	while #rest > size do
		local piece = bridge.cap(rest, size)
		if piece == "" then
			-- Only a size under one character gets here: take the character whole.
			piece = string.sub(rest, 1, size)
		end
		table.insert(out, piece)
		rest = string.sub(rest, #piece + 1)
	end
	table.insert(out, rest)
	return out
end

-- Stores node `name`'s text (and its chunks); true (and a new sig) when it changed.
function bridge.track(s: Sigs, name: string, text: string): boolean
	if s.text[name] == text then
		return false
	end
	s.text[name] = text
	s.chunks[name] = bridge.chunks(text)
	s.n[name] = (s.n[name] or 0) + 1
	return true
end

function bridge.sig(s: Sigs, name: string): string
	return s.run .. "." .. tostring(s.n[name] or 0)
end

-- main.0, the header. `leader` nil is spelled with `null`, which the caller passes (tern.json.null).
function bridge.header(
	s: Sigs,
	info: { host: string, home: string?, os: string, pane: number, at: number, leader: string?, null: any }
): { [string]: any }
	local sig: { [string]: string } = {}
	local parts: { [string]: number } = {}
	local names: { string } = bridge.NODES
	for _, name in names do
		if name ~= "header" then
			sig[name] = s.run .. "." .. tostring(s.n[name] or 0)
			local c = s.chunks[name]
			parts[name] = if c then #c else 1
		end
	end
	return {
		v = bridge.VERSION,
		host = info.host,
		home = info.home or info.null,
		os = info.os,
		pane = info.pane,
		at = info.at,
		leader = info.leader or info.null,
		sig = sig,
		parts = parts,
	}
end

-- main.4: the queued messages only, in kv `mailbox.v1`'s shape (mailq.normalize reads it back).
function bridge.mail_doc(box: mailq.Box): { seq: number, msgs: { mailq.Msg } }
	local msgs: { mailq.Msg } = {}
	for _, m in box.msgs do
		if m.state == "queued" then
			table.insert(msgs, m)
		end
	end
	return { seq = box.seq, msgs = msgs }
end

-- Synced projects ---------------------------------------------------------------------------

-- A `sync` request (or the kv copy) as a Sync, with `~` expanded; bad entries dropped.
function bridge.sync_of(raw: any, home: string?, now: number): Sync
	local out: Sync = { projects = {}, worktrees = {}, visible = false, at = now }
	if type(raw) ~= "table" then
		return out
	end
	if type(raw.projects) == "table" then
		for _, p in raw.projects do
			if type(p) == "table" and str(p.id) and str(p.root) then
				table.insert(out.projects, { id = p.id, name = str(p.name) or p.id, root = bridge.expand(p.root, home) })
			end
		end
	end
	if type(raw.worktrees) == "table" then
		for _, w in raw.worktrees do
			if str(w) then
				table.insert(out.worktrees, bridge.expand(w, home))
			end
		end
	end
	out.visible = raw.visible == true
	if type(raw.at) == "number" then
		out.at = raw.at
	end
	return out
end

-- The local projects, then the synced ones whose id is not among them.
function bridge.union_projects(locals: { SyncProject }, sync: Sync?): { SyncProject }
	local out: { SyncProject } = {}
	local ids: { [string]: boolean } = {}
	for _, p in locals do
		table.insert(out, { id = p.id, name = p.name, root = p.root })
		ids[p.id] = true
	end
	if sync then
		for _, p in sync.projects do
			if not ids[p.id] then
				table.insert(out, p)
				ids[p.id] = true
			end
		end
	end
	return out
end

-- Platform paths ----------------------------------------------------------------------------

local MAC_TERN = "/Applications/Tern.app/Contents/MacOS/tern"

-- The CLI for `tern inspect`: the daemon's own executable when it says, else the app's, else the Linux install's
-- (the rig daemon's PATH lacks ~/.local/bin), else PATH's.
function bridge.tern_cli(getenv: (string) -> string?, exists: (string) -> boolean): string
	local exe = getenv("TERN_EXE")
	if exe and exe ~= "" then
		return exe
	end
	local home = getenv("HOME")
	local candidates = { MAC_TERN }
	if home and home ~= "" then
		table.insert(candidates, home .. "/.local/bin/tern")
		table.insert(candidates, home .. "/.local/share/tern/build/tern")
	end
	for _, c in candidates do
		if exists(c) then
			return c
		end
	end
	return "tern"
end

-- Tern's config dir: $TERN_CONFIG_DIR, else macOS's Application Support, else XDG's.
function bridge.config_dir(getenv: (string) -> string?, os_name: string): string?
	local dir = getenv("TERN_CONFIG_DIR")
	if dir and dir ~= "" then
		return dir
	end
	local home = getenv("HOME")
	if os_name == "macos" then
		return if home and home ~= "" then home .. "/Library/Application Support/Tern" else nil
	end
	local xdg = getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return xdg .. "/tern"
	end
	return if home and home ~= "" then home .. "/.config/tern" else nil
end

-- The mailbox.json scripts look for when it is not `<data>/mailbox.json`, else nil.
function bridge.discovery_path(getenv: (string) -> string?, os_name: string, plugin_id: string, data: string): string?
	local dir = bridge.config_dir(getenv, os_name)
	if not dir then
		return nil
	end
	local path = dir .. "/plugin-data/" .. plugin_id .. "/mailbox.json"
	return if path == data .. "/mailbox.json" then nil else path
end

return bridge
