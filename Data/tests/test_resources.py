"""Independent, gated host resources for the Model A shell."""
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

SOURCE = Path(__file__).resolve().parents[1] / "panel" / "master-wg-panel"
loader = importlib.machinery.SourceFileLoader("resources_panel", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
panel = importlib.util.module_from_spec(spec)
loader.exec_module(panel)


def unix_get(sock, path, headers, method="GET", body=None):
    """DD-180: the backend listens on a Unix socket only; Host defaults to the Konsol name."""
    conn = panel.UnixConnection(sock, 3)
    try:
        # Like urllib: one request per connection, so an unread body is never parsed as the next request.
        conn.request(method, path, body=body, headers={"Host": "panel.test", "Connection": "close", **headers})
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        conn.close()


def start_unix(test, handler):
    folder = tempfile.mkdtemp(prefix="wgp", dir="/tmp")
    test.addCleanup(shutil.rmtree, folder, True)
    sock = folder + "/api.sock"
    server = panel.Server(sock, handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def stop():
        server.shutdown()
        server.server_close()
        thread.join(3)
    test.addCleanup(stop)
    return server, sock


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state = Path(self.tmp.name) / "state.env"
        state.write_text(f"SERVER_ROOT={self.tmp.name}\nLOCAL_DOMAIN=test\nV2_VERSION=test\n")
        self.p = panel.Panel(types.SimpleNamespace(state=str(state), allow_host=[]))

    def test_resources_do_not_enumerate_wireguard_ports_or_processes(self):
        with patch.object(self.p, "net_rows", side_effect=AssertionError("WG")), \
             patch.object(self.p, "ports", side_effect=AssertionError("ports")), \
             patch.object(panel.subprocess, "run", side_effect=AssertionError("process")):
            data = self.p.system()
        self.assertNotIn("ports", data)
        self.assertEqual(data["version"], "test")
        self.assertGreater(data["disk"]["total"], 0)
        self.assertIsNone(data["sampled_at"])
        self.assertEqual(data["cpu"], [])
        self.assertGreater(data["read_at"], 0)

    def test_missing_disk_is_unknown_not_zero_percent(self):
        with patch.object(panel.os, "statvfs", side_effect=OSError()):
            self.assertIsNone(self.p.system()["disk"])

    def test_sample_excludes_guest_time_and_keeps_timestamp(self):
        with patch("builtins.open", side_effect=[io.BytesIO(b"cpu 100 0 0 100 0 0 0 0 50 0\n"),
                                                io.BytesIO(b"cpu 120 0 0 120 0 0 0 0 70 0\n")]), \
             patch.object(self.p, "meminfo", return_value=(1000, 200)):
            self.p.sample_system()
            self.assertEqual(self.p.samples, [])
            self.p.sample_system()
        self.assertEqual(self.p.samples[-1]["cpu"], 50)
        self.assertEqual(self.p.samples[-1]["mem"], 20)
        self.assertGreater(self.p.samples[-1]["t"], 0)

    def test_short_proc_record_does_not_crash(self):
        with patch("builtins.open", return_value=io.BytesIO(b"cpu 1 2\n")):
            self.p.sample_system()
        self.assertEqual(self.p.samples, [])

    def test_resource_sampler_does_not_wait_for_wireguard(self):
        with patch.object(self.p, "state", side_effect=AssertionError("WG")) as wg, \
             patch.object(self.p, "sample_system") as sample, \
             patch.object(panel.time, "sleep", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.p.sample_resources_forever()
        wg.assert_not_called()
        sample.assert_called_once()

    def test_port_rows_follow_installed_modules(self):
        modules = Path(self.tmp.name) / "moduller"
        env = {"MODULES_FILE": str(modules), "TORRENT_UI_PORT": "61006", "FILES_PANEL_PORT": "61009",
               "SHARE_PORT": "61010", "SSH_PUBLIC_PORT": "22", "TAILSCALE_UDP_PORT": "41641"}
        rows = lambda: {(r["name"], r["scope"]) for r in self.p.ports(env, [])}  # noqa: E731
        modules.write_text("wireguard\tcalisiyor\n")
        names = {n for n, _ in rows()}
        self.assertFalse({n for n in names if "qBittorrent" in n or n.startswith("WireGuard") or "dosya" in n})
        modules.write_text("torrent\tcalisiyor\ndosya\tcalisiyor\n")
        self.assertIn(("qBittorrent arayüzü", "loopback"), rows())
        self.assertIn(("Konsol · dosya arka ucu", "loopback"), rows())
        self.assertNotIn("share", self.p.system())
        self.assertNotIn("ports", self.p.system())

    def test_http_resources_have_same_host_header_and_origin_gates(self):
        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, sock = start_unix(self, Handler)
        url = "/api/konsol/kaynaklar"
        for headers in ({}, {"X-Konsol": "1", "Host": "evil.test"},
                        {"X-Konsol": "1", "Sec-Fetch-Site": "cross-site"},
                        {"X-Konsol": "1", "Host": "127.0.0.1:61008"}):
            self.assertEqual(unix_get(sock, url, headers)[0], 403)
        with patch.object(self.p, "net_rows", side_effect=RuntimeError("WG failed")):
            status, headers, body = unix_get(sock, url, {"X-Konsol": "1"})
            self.assertEqual(status, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertNotIn("ports", json.loads(body))

    def test_socket_is_private_and_the_group_is_opt_in(self):
        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, sock = start_unix(self, Handler)
        self.assertEqual(stat.S_IMODE(os.stat(sock).st_mode), 0o600)
        folder = tempfile.mkdtemp(prefix="wgp", dir="/tmp")
        self.addCleanup(shutil.rmtree, folder, True)
        grouped = panel.Server(folder + "/api.sock", Handler, group_gid=os.getgid())
        self.addCleanup(grouped.server_close)
        st = os.stat(folder + "/api.sock")
        self.assertEqual((stat.S_IMODE(st.st_mode), st.st_gid), (0o660, os.getgid()))

    def test_serve_refuses_tcp_and_relative_sockets(self):
        for listen in ("127.0.0.1:61008", "unix:api.sock", "unix:/" + "x" * 120, "tcp:/run/x"):
            args = types.SimpleNamespace(listen=listen, socket_group="")
            with self.subTest(listen=listen), patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                panel.cmd_serve(args)

    @unittest.skipUnless(hasattr(socket, "SO_PEERCRED"), "Linux peer credentials")
    def test_peer_credentials_limit_who_may_connect(self):
        server = types.SimpleNamespace(uids={0}, group_gid=None)
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        with patch("sys.stderr", io.StringIO()):
            allowed = panel.Server.verify_request(server, left, "")
        self.assertEqual(allowed, os.geteuid() == 0)
        server.group_gid = os.getgid()
        self.assertTrue(panel.Server.verify_request(server, left, ""))

    def test_relayed_requests_must_come_from_another_tailnet_device(self):
        with patch.object(panel, "own_address", side_effect=lambda ip: str(ip) == "100.66.81.14"):
            self.assertTrue(panel.remote_tailnet("100.64.0.9"))
            self.assertTrue(panel.remote_tailnet("fd7a:115c:a1e0::9"))
            self.assertTrue(panel.remote_tailnet("::ffff:100.64.0.9"))
            for value in ("100.66.81.14", "::ffff:100.66.81.14", "203.0.113.5", "10.8.0.2", "", "x"):
                self.assertFalse(panel.remote_tailnet(value), value)
        for value in ("127.0.0.1", "::1", "fe80::1", "0.0.0.0"):
            self.assertTrue(panel.own_address(panel.ipaddress.ip_address(value)))
        self.assertFalse(panel.own_address(panel.ipaddress.ip_address("192.0.2.77")))

    def test_rejected_body_is_never_read_as_a_second_request(self):
        class Handler(panel.Handler):
            seen = []

            def log_message(self, *_args):
                pass

            def gate(self):
                user = super().gate()
                if user:
                    Handler.seen.append(self.path)
                return user
        Handler.panel = self.p
        _server, sock = start_unix(self, Handler)
        inner = (b"POST /api/konsol/paylasim/kaydet HTTP/1.1\r\nHost: panel.test\r\nX-Konsol: 1\r\n"
                 b"X-Forwarded-For: 100.64.0.9\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        outer = (b"POST /api/wg/peers HTTP/1.1\r\nHost: panel.test\r\nContent-Type: text/plain\r\n"
                 b"Sec-Fetch-Site: cross-site\r\nX-Forwarded-For: 100.64.0.8\r\nContent-Length: %d\r\n\r\n" % len(inner)) + inner
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(sock)
            client.sendall(outer)
            reply = b""
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                reply += chunk
        self.assertEqual(reply.count(b"HTTP/1.1 "), 1, reply[:300])
        self.assertIn(b"403", reply.split(b"\r\n", 1)[0])
        self.assertIn(b"Connection: close", reply)
        self.assertEqual(Handler.seen, [])

    def test_address_probe_fails_closed_unless_the_address_is_not_local(self):
        ip = panel.ipaddress.ip_address("100.66.81.14")
        for code, own in ((panel.errno.EADDRNOTAVAIL, False), (panel.errno.EADDRINUSE, True),
                          (panel.errno.EMFILE, True), (panel.errno.EACCES, True)):
            with self.subTest(code=code), patch.object(panel.socket.socket, "bind", side_effect=OSError(code, "fixture")):
                self.assertEqual(panel.own_address(ip), own)
                self.assertEqual(panel.remote_tailnet(str(ip)), not own)

    def health_with(self, outputs, reboot=False, pending=None):
        def cmd(argv, timeout=10):
            return outputs.get(argv[0], (0, ""))
        real_exists = panel.os.path.exists
        with patch.object(self.p, "health_cmd", side_effect=cmd), \
                patch.object(panel.os.path, "exists", side_effect=lambda path: reboot if path == "/run/reboot-required" else real_exists(path)), \
                patch.object(panel.master_settings, "Manager") as manager:
            manager.return_value.status.return_value = {"pending": pending}
            self.p.health_cache = (0.0, None)
            return self.p.health()

    def test_health_is_green_when_every_check_passes(self):
        expiry = (panel.datetime.datetime.now(panel.datetime.timezone.utc) + panel.datetime.timedelta(days=90)).isoformat()
        data = self.health_with({"tailscale": (0, json.dumps({"BackendState": "Running", "Self": {"Online": True, "KeyExpiry": expiry}})),
                                 "timedatectl": (0, "yes\n")})
        by = {c["id"]: c for c in data["checks"]}
        self.assertEqual(data["status"], "ok", data)
        self.assertRegex(by["tailscale"]["detail"], r"anahtar (89|90) gün sonra doluyor")
        for key in ("units", "tailscale", "firewall", "reboot", "clock", "settings"):
            self.assertEqual(by[key]["status"], "ok", by[key])
        self.assertTrue(any(k.startswith("disk:") for k in by))

    def test_health_reports_failures_warnings_and_a_stuck_rollback(self):
        soon = (panel.datetime.datetime.now(panel.datetime.timezone.utc) + panel.datetime.timedelta(days=3)).isoformat()
        data = self.health_with({"systemctl": (0, "caddy.service loaded failed failed Caddy\n"),
                                 "tailscale": (0, json.dumps({"BackendState": "Running", "Self": {"Online": True, "KeyExpiry": soon}})),
                                 "master-firewall": (1, "HATA"), "timedatectl": (0, "no\n")},
                                reboot=True, pending={"id": "x", "phase": "stuck", "seconds": 0})
        by = {c["id"]: c for c in data["checks"]}
        self.assertEqual(data["status"], "bad")
        self.assertEqual((by["units"]["status"], by["firewall"]["status"], by["settings"]["status"]), ("bad", "bad", "bad"))
        self.assertIn("caddy.service", by["units"]["detail"])
        self.assertEqual((by["tailscale"]["status"], by["reboot"]["status"], by["clock"]["status"]), ("warn", "warn", "warn"))
        # Unreadable Tailscale is a problem, never silently green.
        data = self.health_with({"tailscale": (None, ""), "timedatectl": (0, "yes\n")})
        self.assertEqual({c["id"]: c for c in data["checks"]}["tailscale"]["status"], "bad")

    def test_health_is_cached_and_its_endpoint_keeps_the_gates(self):
        with patch.object(self.p, "health_compute", return_value={"status": "ok", "checks": [], "read_at": 1}) as compute:
            self.p.health_cache = (0.0, None)
            self.p.health(); self.p.health()
            self.assertEqual(compute.call_count, 1)
            class Handler(panel.Handler):
                def log_message(self, *_args):
                    pass
            Handler.panel = self.p
            _server, sock = start_unix(self, Handler)
            self.assertEqual(unix_get(sock, "/api/konsol/saglik", {})[0], 403)
            self.assertEqual(unix_get(sock, "/api/konsol/saglik", {"X-Konsol": "1", "Host": "evil.test"})[0], 403)
            status, _headers, body = unix_get(sock, "/api/konsol/saglik", {"X-Konsol": "1"})
            self.assertEqual((status, json.loads(body)["status"]), (200, "ok"))
        self.assertEqual(panel.human_bytes(0), "0 B")
        self.assertEqual(panel.human_bytes(5 * 1024 ** 3), "5,0 GB")


if __name__ == "__main__":
    unittest.main()
