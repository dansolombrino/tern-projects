#!/usr/bin/env python3
"""python3 tests/test_mailbox.py: the socket helper (mailbox.py) with this test playing the plugin's host half."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "mailbox.py")


def ask(path: str, obj, raw: bytes | None = None) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(5)
        c.connect(path)
        c.sendall(raw if raw is not None else (json.dumps(obj) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf)


class HelperTest(unittest.TestCase):
    def setUp(self) -> None:
        self.data = tempfile.mkdtemp(prefix="tp-")
        self.proc = subprocess.Popen(
            [sys.executable, HELPER, "serve", "--data", self.data],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        ready = json.loads(self.proc.stdout.readline())
        self.assertEqual(ready["t"], "ready")
        self.socket = ready["socket"]
        self.seen: list = []
        # The fake host half: answers ping, echoes others, counts requests.
        self.host = threading.Thread(target=self.serve_host, daemon=True)
        self.host.start()

    def serve_host(self) -> None:
        for line in self.proc.stdout:
            msg = json.loads(line)
            if msg.get("t") != "req":
                continue
            self.seen.append(msg["msg"])
            op = msg["msg"].get("op")
            reply = {"ok": True, "version": 1} if op == "ping" else {"ok": True, "id": msg["msg"].get("id"), "state": "queued"}
            self.proc.stdin.write(json.dumps({"t": "reply", "n": msg["n"], "reply": reply}) + "\n")
            self.proc.stdin.flush()
            if op == "deliver":
                self.proc.stdin.write('{"t":"notify"}\n')
                self.proc.stdin.flush()

    def tearDown(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()

    def test_discovery_ping_deliver_and_cleanup(self) -> None:
        info = json.load(open(os.path.join(self.data, "mailbox.json")))
        self.assertEqual(info["version"], 1)
        self.assertEqual(info["socket"], self.socket)
        self.assertEqual(info["pid"], self.proc.pid)
        self.assertEqual(os.stat(self.socket).st_mode & 0o777, 0o600)
        self.assertEqual(ask(self.socket, {"op": "ping"}), {"ok": True, "version": 1})
        r = ask(self.socket, {"op": "deliver", "id": "x1", "target": {"pane": 3}, "text": "hi", "from": "t"})
        self.assertEqual(r["state"], "queued")
        self.assertEqual(self.seen[-1]["id"], "x1")
        # Stdin closing (a plugin reload) stops the helper and removes what it published.
        self.proc.stdin.close()
        self.proc.wait(5)
        self.assertFalse(os.path.exists(os.path.join(self.data, "mailbox.json")))
        self.assertFalse(os.path.exists(self.socket))

    def test_bad_json_never_reaches_the_host(self) -> None:
        r = ask(self.socket, None, raw=b"{not json\n")
        self.assertEqual(r["error"], "bad-request")
        r = ask(self.socket, None, raw=b"[1,2]\n")
        self.assertEqual(r["error"], "bad-request")
        self.assertEqual(self.seen, [])

    def test_watchers_get_leader_and_mail(self) -> None:
        a = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        a.settimeout(5)
        a.connect(self.socket)
        a.sendall(b'{"op":"watch"}\n')
        fa = a.makefile()
        self.assertEqual(json.loads(fa.readline())["leader"], True)
        b = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        b.settimeout(5)
        b.connect(self.socket)
        b.sendall(b'{"op":"watch"}\n')
        fb = b.makefile()
        self.assertEqual(json.loads(fb.readline())["leader"], False)
        ask(self.socket, {"op": "deliver", "id": "x2", "target": {"pane": 3}, "text": "hi"})
        self.assertEqual(json.loads(fa.readline())["event"], "mail")
        self.assertEqual(json.loads(fb.readline())["event"], "mail")
        # The leader goes: the next watcher leads.
        fa.close()
        a.close()
        self.assertEqual(json.loads(fb.readline()), {"event": "leader", "leader": True})
        b.close()

    def test_sigterm_cleans_up(self) -> None:
        self.proc.terminate()
        self.proc.wait(5)
        self.assertFalse(os.path.exists(os.path.join(self.data, "mailbox.json")))


class DiscoveryTest(unittest.TestCase):
    """--discovery: the same mailbox.json where scripts look when the data dir is elsewhere (Linux)."""

    def start(self) -> subprocess.Popen:
        p = subprocess.Popen(
            [sys.executable, HELPER, "serve", "--data", self.data, "--discovery", self.extra],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        self.procs.append(p)
        self.assertEqual(json.loads(p.stdout.readline())["t"], "ready")
        return p

    def setUp(self) -> None:
        self.data = tempfile.mkdtemp(prefix="tp-")
        # A folder that does not exist yet: the helper makes it.
        self.extra = os.path.join(tempfile.mkdtemp(prefix="tc-"), "plugin-data", "projects", "mailbox.json")
        self.procs: list[subprocess.Popen] = []

    def tearDown(self) -> None:
        for p in self.procs:
            if p.poll() is None:
                p.kill()
                p.wait()
            for f in (p.stdin, p.stdout):
                if f and not f.closed:
                    f.close()

    def read(self, path: str) -> dict:
        with open(path) as fh:
            return json.load(fh)

    def test_extra_file_matches_and_goes_on_stop(self) -> None:
        p = self.start()
        primary = self.read(os.path.join(self.data, "mailbox.json"))
        self.assertEqual(self.read(self.extra), primary)
        self.assertEqual(primary["pid"], p.pid)
        self.assertEqual(os.stat(primary["socket"]).st_mode & 0o777, 0o600)
        p.stdin.close()
        p.wait(15)
        self.assertFalse(os.path.exists(self.extra))
        self.assertFalse(os.path.exists(os.path.join(self.data, "mailbox.json")))

    def test_restart_replaces_and_stop_spares_another_helpers_file(self) -> None:
        first = self.start()
        # A killed helper leaves its files; the next one replaces them.
        first.kill()
        first.wait(5)
        self.assertEqual(self.read(self.extra)["pid"], first.pid)
        second = self.start()
        self.assertEqual(self.read(self.extra)["pid"], second.pid)
        # Another helper took the extra file over: stopping this one leaves it.
        with open(self.extra, "w") as fh:
            json.dump({"version": 1, "socket": "/nowhere", "pid": 1}, fh)
        second.terminate()
        second.wait(5)
        self.assertEqual(self.read(self.extra)["pid"], 1)
        self.assertFalse(os.path.exists(os.path.join(self.data, "mailbox.json")))


class WatchTest(unittest.TestCase):
    def test_watch_without_helper_says_so_and_ticks(self) -> None:
        data = tempfile.mkdtemp(prefix="tp-")
        p = subprocess.Popen([sys.executable, HELPER, "watch", "--data", data], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            first = json.loads(p.stdout.readline())
            second = json.loads(p.stdout.readline())
            self.assertEqual({first["event"], second["event"]}, {"nohelper", "tick"})
            p.stdin.close()
            self.assertEqual(p.wait(5), 0)
        finally:
            if p.poll() is None:
                p.kill()


if __name__ == "__main__":
    unittest.main()
