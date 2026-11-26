#!/usr/bin/env python3
"""Mailbox socket helper for the Tern plugin `projects` (protocol v1; README "Mailbox").

Two modes, standard library only:

serve --data DIR [--socket PATH] [--discovery PATH]
    Started by the plugin's host half with `tern.process.spawn`. Listens on a Unix stream socket (0600), one JSON
    request per line and connection, and relays each request to the host half as a line on stdout:
        {"t": "req", "n": <int>, "msg": <request>}
    The host answers on stdin with {"t": "reply", "n": <int>, "reply": {...}}, which goes back to the client before
    the connection closes. {"t": "notify"} on stdin tells every watcher the queue changed. Writes DIR/mailbox.json
    (and the same file at each --discovery PATH, where scripts look when the data dir is elsewhere, as on Linux)
    once listening and removes each (when it still names this process) on exit. Exits when stdin closes: the plugin
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
import hashlib
import json
import os
import select
import signal
import socket
import stat
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


def private_dir(path: str) -> bool:
    """Whether `path` is (or now is) a real directory of ours that only we can enter."""
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            return False
        if st.st_mode & 0o077:
            os.chmod(path, 0o700)
            st = os.lstat(path)
        return st.st_mode & 0o777 == 0o700
    except OSError:
        return False


def fallback_sockets(data: str) -> list[str]:
    """Private places for the socket when the data dir's filesystem keeps no modes (a FUSE/NTFS mount answers 0777
    whatever chmod says). Named after the data dir, so two helpers never share one."""
    name = f"mailbox-{hashlib.sha1(os.path.realpath(data).encode()).hexdigest()[:12]}.sock"
    bases = []
    if os.environ.get("XDG_RUNTIME_DIR"):
        bases.append(os.path.join(os.environ["XDG_RUNTIME_DIR"], "tern-projects"))
    bases.append(f"/tmp/tern-projects-{os.getuid()}")
    bases.append(os.path.join(tempfile.gettempdir(), f"tern-projects-{os.getuid()}"))
    out = []
    for b in bases:
        p = os.path.join(b, name)
        if p not in out and len(p.encode()) <= MAX_SOCKET_PATH:
            out.append(p)
    return out


class Server:
    def __init__(self, data: str, path: str | None, extra: list[str] | None = None) -> None:
        self.data = data
        # None: the default place, which may move to a private fallback (an explicit --socket never moves).
        self.explicit = path is not None
        self.path = path or default_socket(data)
        self.discovery = os.path.join(data, "mailbox.json")
        # Every mailbox.json this helper publishes: the data dir's, then each --discovery one.
        self.discoveries = [self.discovery] + [p for p in (extra or []) if os.path.abspath(p) != os.path.abspath(self.discovery)]
        self.out_lock = threading.Lock()
        self.lock = threading.Lock()
        self.next_n = 0
        self.waiting: dict[int, tuple[threading.Event, list]] = {}
        self.watchers: list[socket.socket] = []
        self.inode: int | None = None
        # Said to the host after `ready`, the first line it reads.
        self.moved: str | None = None

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
        for path in self.discoveries:
            try:
                with open(path) as fh:
                    if json.load(fh).get("pid") == os.getpid():
                        os.unlink(path)
            except (OSError, ValueError, AttributeError):
                pass
        try:
            if self.inode is not None and os.stat(self.path).st_ino == self.inode:
                os.unlink(self.path)
        except OSError:
            pass

    def bind(self, path: str) -> socket.socket | None:
        """A socket listening at `path` with mode 0600, or None when that filesystem cannot keep the mode."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            srv.bind(path)
        finally:
            os.umask(old)
        os.chmod(path, 0o600)
        if os.stat(path).st_mode & 0o777 != 0o600:
            srv.close()
            os.unlink(path)
            return None
        return srv

    def listen(self) -> socket.socket:
        srv = self.bind(self.path)
        if srv is None and not self.explicit:
            for path in fallback_sockets(self.data):
                if private_dir(os.path.dirname(path)):
                    srv = self.bind(path)
                    if srv is not None:
                        self.moved = f"{self.path}: that filesystem keeps no file modes; listening at {path}"
                        self.path = path
                        break
        if srv is None:
            raise SystemExit(f"mailbox: no place keeps the socket private (mode 0600): {self.path}")
        return srv

    def run(self) -> int:
        srv = self.listen()
        # From here on every exit (SIGTERM included, even one right after `ready`) goes through cleanup.
        try:
            self.inode = os.stat(self.path).st_ino
            srv.listen(64)
            started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
            info = {"version": VERSION, "socket": self.path, "pid": os.getpid(), "started_at": started}
            write_json_atomic(self.discovery, info)
            notes = [self.moved] if self.moved else []
            for path in self.discoveries[1:]:
                try:
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    write_json_atomic(path, info)
                except OSError as exc:
                    notes.append(f"{path} not written: {exc}")
            self.emit({"t": "ready", "socket": self.path, "pid": os.getpid()})
            for note in notes:
                self.log(note)
            reader = threading.Thread(target=self.read_stdin, daemon=True)
            reader.start()
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
    s.add_argument("--discovery", action="append", default=[], help="also publish mailbox.json at this path")
    w = sub.add_parser("watch")
    w.add_argument("--data", required=True)
    args = ap.parse_args()
    # SIGTERM (the plugin's child:kill) and SIGHUP end through `finally`, so mailbox.json and the socket go.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(0))
    if args.mode == "serve":
        return Server(args.data, args.socket, args.discovery).run()
    return watch(args.data)


if __name__ == "__main__":
    sys.exit(main())
