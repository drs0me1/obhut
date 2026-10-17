"""Stage 3 Files JSON and idle cleanup; no system service or host mutations."""
import http.client
import json
import os
from pathlib import Path
import re
import socket
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

import test_files_upload as fixture

fp = fixture.fp

# Rebuild §2.3 and §7.4: the file backend has no route table of its own, so these are every path it answers.
# Nothing else answers, the session check and the sign-in included (Caddy asks the root backend, DD-194). The
# system view (DD-235) answers the same names under /api/sistem/, without the trash and with delete.
GET_ROUTES = {"/api/state", "/api/list", "/api/trash", "/api/text", "/api/download"}
POST_ROUTES = {"/api/upload", "/api/mkdir", "/api/rename", "/api/move", "/api/trash", "/api/trash/restore",
               "/api/trash/purge", "/api/trash/empty", "/api/text/save"}
SYSTEM_GET_ROUTES = {"/api/state", "/api/list", "/api/text", "/api/download"}
SYSTEM_POST_ROUTES = {"/api/upload", "/api/mkdir", "/api/rename", "/api/move", "/api/delete", "/api/text/save"}
PROBES = {"/", "/api", "/api/", "/api/x", "/API/state", "/api/state/", "/api/state/x", "/api/list/x", "/api/trash/x",
          "/api/text/save/x", "/api/download/x", "/oturum-denetle", "/api/konsol/oturum/giris", "/api/konsol/kaynaklar",
          "/api/sistem/state", "/giris.html", "/index.html"}


def unanswered(get_routes, post_routes):
    """Every (method, path) the backend must answer with 404: the probes and each method's routes for the
    other methods (HEAD is GET)."""
    paths = PROBES | GET_ROUTES | POST_ROUTES | SYSTEM_GET_ROUTES | SYSTEM_POST_ROUTES
    return sorted((method, path) for method in ("GET", "HEAD", "POST") for path in paths
                  if path not in (post_routes if method == "POST" else get_routes))


class Stage3FilesTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="stage3-files-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        args = types.SimpleNamespace(root=str(self.root), trash=".cop",
                                     domain="", version="test", temp_dir="")
        self.handler = type("FixtureHandler", (fp.Handler,), {"panel": fp.Panel(args), "timeout": .2})
        self.server = fp.Server(("127.0.0.1", 0), self.handler)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def request(self, method="GET", path="/api/list", body=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        try:
            conn.request(method, path, body=body,
                         headers={"X-Konsol": "1", "Content-Type": "application/json"})
            response = conn.getresponse()
            return response.status, response.read(), response.will_close
        finally:
            conn.close()

    def test_nothing_outside_its_routes_answers(self):
        # A route the lists below do not name fails here first: every quoted /api/ path in the source is one.
        source = fixture.SOURCE.read_text()
        self.assertEqual(set(re.findall(r'"(/api/[a-z/]*)"', source)) - {"/api/", "/api/sistem"},
                         GET_ROUTES | POST_ROUTES | SYSTEM_GET_ROUTES | SYSTEM_POST_ROUTES)
        self.assertEqual({name for name in dir(fp.Handler) if name.startswith("do_")}, {"do_GET", "do_HEAD", "do_POST"})
        (self.root / "a.txt").write_text("x")
        files = Mock(spec=self.handler.panel.files)
        with patch.object(self.handler.panel, "files", files):
            for method, path in unanswered(GET_ROUTES, POST_ROUTES):
                with self.subTest(method=method, path=path):
                    self.assertEqual(self.request(method, path + "?path=a.txt", b"{}" if method == "POST" else None)[0], 404)
        self.assertEqual(files.mock_calls, [], "no file operation runs for a path outside the routes")
        for method in ("PUT", "DELETE", "PATCH", "OPTIONS"):
            with self.subTest(method=method):
                self.assertEqual(self.request(method, "/api/list")[0], 501)

    def test_state_reply_names_the_user_area_only(self):
        code, data, _ = self.request(path="/api/state")
        self.assertEqual(code, 200)
        state = json.loads(data)
        self.assertEqual(set(state), {"host", "version", "root", "downloads", "domain", "writable", "disk",
                                      "trash", "textLimit"})
        self.assertEqual((state["root"], state["version"], state["trash"]), (str(self.root), "test", {"count": 0, "size": 0}))

    def test_deep_json_returns_400_and_closes_then_next_request_succeeds(self):
        body = b'{"path":' + b"[" * 20000 + b"0" + b"]" * 20000 + b"}"
        code, data, _ = self.request("POST", "/api/mkdir", body)
        self.assertEqual(code, 400)
        self.assertIn(b"JSON", data)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertEqual(self.request()[0], 200)

    def test_recursive_trash_metadata_is_ignored(self):
        target = self.root / "meta.json"
        target.write_bytes(b'{"from":' + b"[" * 20000 + b"0" + b"]" * 20000 + b"}")
        with fp.DirFd(os.open(self.root, fp.O_DIR)) as fd:
            self.assertIsNone(fp.read_json_at(fd, target.name))
            target.write_text('{"from":"downloads"}')
            self.assertEqual(fp.read_json_at(fd, target.name), {"from": "downloads"})

    def test_idle_and_incomplete_headers_close_without_blocking_healthy_request(self):
        for partial in (b"", b"GET /api/list HTTP/1.1\r\n"):
            with socket.create_connection(self.server.server_address, timeout=2) as idle:
                if partial:
                    idle.sendall(partial)
                self.assertEqual(self.request()[0], 200)
                self.assertEqual(idle.recv(1024), b"")

    def test_stalled_upload_removes_stage_and_active_upload_can_outlive_idle_timeout(self):
        def headers(name):
            return ("POST /api/upload?name=%s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\n"
                    "X-Konsol: 1\r\nContent-Length: 4\r\n\r\n" %
                    (name, self.server.server_address[1])).encode()

        with socket.create_connection(self.server.server_address, timeout=2) as idle:
            idle.sendall(headers("stalled.bin") + b"x")
            response = http.client.HTTPResponse(idle)
            response.begin()
            self.assertEqual(response.status, 400)
            response.read()
        self.assertFalse((self.root / "stalled.bin").exists())
        self.assertFalse(list(self.root.glob(".yukleniyor-*")))
        with socket.create_connection(self.server.server_address, timeout=2) as active:
            active.sendall(headers("active.bin"))
            for byte in (b"a", b"b", b"c", b"d"):
                time.sleep(.08)
                active.sendall(byte)
            response = http.client.HTTPResponse(active)
            response.begin()
            self.assertEqual(response.status, 201)
            response.read()
        self.assertEqual((self.root / "active.bin").read_bytes(), b"abcd")


if __name__ == "__main__":
    unittest.main()
