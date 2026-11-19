#!/usr/bin/env python3
"""Fleet mailbox socket helper for the Tern plugin `projects` (protocol v1; README "Fleet mailbox").

Two modes, standard library only:

serve --data DIR [--socket PATH]
    Started by the plugin's host half with `tern.process.spawn`. Listens on a Unix stream socket (0600), one JSON
    request per line and connection, and relays each request to the host half as a line on stdout:
        {"t": "req", "n": <int>, "msg": <request>}
    The host answers on stdin with {"t": "reply", "n": <int>, "reply": {...}}, which goes back to the client before
    the connection closes. {"t": "notify"} on stdin tells every watcher the queue changed. Writes DIR/mailbox.json
    once listening and removes it (when it still names this process) on exit. Exits when stdin closes: the plugin
    was reloaded or unloaded, and its new host half starts a new helper.

watch --data DIR
    Started by each window half. Connects to the socket mailbox.json names, sends {"op": "watch"} and prints every
    event line the helper pushes ({"event": "hello"|"leader"|"mail", ...}), plus {"event": "tick"} every few
    seconds. Each printed line runs a callback in the window, which also keeps an idle window's timers going
    (Tern stalls them in a window nothing redraws). Prints {"event": "nohelper"} while no helper answers.
    Exits when stdin closes.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import select
import signal
import socket
import sys
import tempfile
import threading
import time

VERSION = 1
# A client must send its request line within this long, and the host must answer within REPLY_S.
READ_S = 10.0
REPLY_S = 8.0
MAX_LINE = 1 << 20
TICK_S = 3.0
# macOS caps a Unix socket path at 104 bytes (Linux 108).
MAX_SOCKET_PATH = 100


def write_json_atomic(path: str, value: dict) -> None:
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".mailbox.", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(value, fh)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def default_socket(data: str) -> str:
    path = os.path.join(data, "mailbox.sock")
    if len(path.encode()) <= MAX_SOCKET_PATH:
        return path
    base = os.path.join(tempfile.gettempdir(), f"tern-projects-{os.getuid()}")
    os.makedirs(base, mode=0o700, exist_ok=True)
    return os.path.join(base, "mailbox.sock")


class Server:
    def __init__(self, data: str, path: str) -> None:
        self.data = data
        self.path = path
        self.discovery = os.path.join(data, "mailbox.json")
        self.out_lock = threading.Lock()
        self.lock = threading.Lock()
        self.next_n = 0
        self.waiting: dict[int, tuple[threading.Event, list]] = {}
        self.watchers: list[socket.socket] = []
        self.inode: int | None = None

    # stdout to the host half, one JSON object per line.
    def emit(self, obj: dict) -> None:
        line = json.dumps(obj, separators=(",", ":")) + "\n"
        with self.out_lock:
            sys.stdout.write(line)
            sys.stdout.flush()

    def log(self, msg: str) -> None:
        self.emit({"t": "log", "msg": msg})

    def ask_host(self, msg: dict) -> dict:
        ev = threading.Event()
        box: list = []
        with self.lock:
            self.next_n += 1
            n = self.next_n
            self.waiting[n] = (ev, box)
        self.emit({"t": "req", "n": n, "msg": msg})
        if not ev.wait(REPLY_S):
            with self.lock:
                self.waiting.pop(n, None)
            return {"ok": False, "error": "busy", "message": "the plugin's host half did not answer in time; retry"}
        return box[0]

    def push(self, event: dict) -> None:
        line = (json.dumps(event, separators=(",", ":")) + "\n").encode()
        with self.lock:
            dead = []
            for w in self.watchers:
                try:
                    w.sendall(line)
                except OSError:
                    dead.append(w)
            for w in dead:
                self.drop_watcher_locked(w)

    def drop_watcher_locked(self, w: socket.socket) -> None:
        if w in self.watchers:
            lead = self.watchers[0] is w
            self.watchers.remove(w)
            try:
                w.close()
            except OSError:
                pass
            if lead and self.watchers:
                try:
                    self.watchers[0].sendall(b'{"event":"leader","leader":true}\n')
                except OSError:
                    pass

    def read_request(self, conn: socket.socket) -> bytes | None:
        conn.settimeout(READ_S)
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            if len(buf) > MAX_LINE:
                return None
        return buf.split(b"\n", 1)[0]

    def handle(self, conn: socket.socket) -> None:
        keep = False
        try:
            msg = None
            raw = self.read_request(conn)
            if raw is None:
                reply = {"ok": False, "error": "bad-request", "message": f"request line over {MAX_LINE} bytes"}
            else:
                try:
                    msg = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    msg = None
                    reply = {"ok": False, "error": "bad-request", "message": f"not one JSON object per line: {exc}"}
                if isinstance(msg, dict) and msg.get("op") == "watch":
                    conn.settimeout(None)
                    with self.lock:
                        lead = not self.watchers
                        self.watchers.append(conn)
                    conn.sendall((json.dumps({"event": "hello", "leader": lead, "version": VERSION}) + "\n").encode())
                    keep = True
                    self.hold_watcher(conn)
                    return
                if msg is not None and not isinstance(msg, dict):
                    reply = {"ok": False, "error": "bad-request", "message": "the request must be a JSON object"}
                elif isinstance(msg, dict):
                    reply = self.ask_host(msg)
            conn.sendall((json.dumps(reply, separators=(",", ":")) + "\n").encode())
        except OSError:
            pass
        finally:
            if not keep:
                try:
                    conn.close()
                except OSError:
                    pass

    def hold_watcher(self, conn: socket.socket) -> None:
        # A watcher sends nothing more; its EOF (window gone) frees its slot.
        try:
            while conn.recv(4096):
                pass
        except OSError:
            pass
        with self.lock:
            self.drop_watcher_locked(conn)

    def read_stdin(self) -> None:
        for line in sys.stdin:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict):
                continue
            if obj.get("t") == "reply":
                with self.lock:
                    slot = self.waiting.pop(obj.get("n"), None)
                if slot:
                    slot[1].append(obj.get("reply") or {"ok": False, "error": "busy", "message": "empty reply"})
                    slot[0].set()
            elif obj.get("t") == "notify":
                self.push({"event": "mail"})

    def cleanup(self) -> None:
        try:
            with open(self.discovery) as fh:
                if json.load(fh).get("pid") == os.getpid():
                    os.unlink(self.discovery)
        except (OSError, ValueError, AttributeError):
            pass
        try:
            if self.inode is not None and os.stat(self.path).st_ino == self.inode:
                os.unlink(self.path)
        except OSError:
            pass

    def run(self) -> int:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            srv.bind(self.path)
        finally:
            os.umask(old)
        os.chmod(self.path, 0o600)
        srv.listen(64)
        self.inode = os.stat(self.path).st_ino
        started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        write_json_atomic(self.discovery, {"version": VERSION, "socket": self.path, "pid": os.getpid(), "started_at": started})
        self.emit({"t": "ready", "socket": self.path, "pid": os.getpid()})
        reader = threading.Thread(target=self.read_stdin, daemon=True)
        reader.start()
        try:
            while reader.is_alive():
                r, _, _ = select.select([srv], [], [], 0.5)
                if not r:
                    continue
                conn, _ = srv.accept()
                threading.Thread(target=self.handle, args=(conn,), daemon=True).start()
        finally:
            self.cleanup()
            srv.close()
        return 0


def discover(data: str) -> str | None:
    try:
        with open(os.path.join(data, "mailbox.json")) as fh:
            info = json.load(fh)
        return info.get("socket") if isinstance(info, dict) else None
    except (OSError, ValueError):
        return None


def watch(data: str) -> int:
    def say(obj: dict) -> None:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    stdin = sys.stdin.fileno()
    conn: socket.socket | None = None
    buf = b""
    last_tick = 0.0
    told_missing = False
    while True:
        if conn is None:
            path = discover(data)
            if path:
                try:
                    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    c.settimeout(2.0)
                    c.connect(path)
                    c.sendall(b'{"op":"watch"}\n')
                    c.settimeout(None)
                    conn, buf, told_missing = c, b"", False
                except OSError:
                    conn = None
            if conn is None and not told_missing:
                say({"event": "nohelper"})
                told_missing = True
        fds = [stdin] + ([conn] if conn else [])
        timeout = max(0.0, TICK_S - (time.monotonic() - last_tick))
        r, _, _ = select.select(fds, [], [], timeout if conn else min(timeout, 1.0))
        if stdin in r and not os.read(stdin, 4096):
            return 0
        if conn is not None and conn in r:
            try:
                chunk = conn.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                conn.close()
                conn = None
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    say(json.loads(line))
                except ValueError:
                    pass
        if time.monotonic() - last_tick >= TICK_S:
            last_tick = time.monotonic()
            say({"event": "tick", "helper": conn is not None})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--data", required=True)
    s.add_argument("--socket")
    w = sub.add_parser("watch")
    w.add_argument("--data", required=True)
    args = ap.parse_args()
    # SIGTERM (the plugin's child:kill) and SIGHUP end through `finally`, so mailbox.json and the socket go.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(0))
    if args.mode == "serve":
        return Server(args.data, args.socket or default_socket(args.data)).run()
    return watch(args.data)


if __name__ == "__main__":
    sys.exit(main())
