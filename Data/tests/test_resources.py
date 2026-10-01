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
        try:
            conn.request(method, path, body=body, headers={"Host": "panel.test", "Connection": "close", **headers})
        except BrokenPipeError:
            # A header gate can send 403 and close before the separate body write.
            # Still require a real HTTP response; disconnects are not successful tests.
            pass
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
        root = Path(self.tmp.name).resolve()
        state = root / "state.env"
        (root / "modules").write_text("")
        state.write_text(f"SERVER_ROOT={root}\nLOCAL_DOMAIN=test\nV2_VERSION=test\nMODULES_FILE={root / 'modules'}\n")
        self.p = panel.Panel(types.SimpleNamespace(state=str(state), allow_host=[], master_modul="/fixture/master-modul"))

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
        # DD-198: package port rows come from the rendered manifests, only while registered.
        mods_dir = Path(self.tmp.name).resolve() / "mods"  # the no-follow reader refuses a symlinked /var
        repo = Path(__file__).resolve().parents[1] / "magaza"
        for mid in ("wireguard", "torrent", "paylasim", "dosya"):
            (mods_dir / mid).mkdir(parents=True)
            (mods_dir / mid / "paket.env").write_bytes((repo / mid / "paket.env").read_bytes())
        env = {"MODULES_FILE": str(modules), "MODULES_DIR": str(mods_dir), "TORRENT_UI_PORT": "61006", "FILES_PANEL_PORT": "61009",
               "SHARE_PORT": "61010", "SSH_PUBLIC_PORT": "22", "TAILSCALE_UDP_PORT": "41641"}
        rows = lambda: {(r["name"], r["scope"]) for r in self.p.ports(env, [])}  # noqa: E731
        modules.write_text("wireguard\tcalisiyor\n")
        names = {n for n, _ in rows()}
        self.assertFalse({n for n in names if "qBittorrent" in n or n.startswith("WireGuard") or "dosya" in n})
        modules.write_text("torrent\tcalisiyor\ndosya\tcalisiyor\n")
        self.assertIn(("qBittorrent arayüzü", "loopback"), rows())
        self.assertIn(("Konsol · dosya arka ucu", "loopback"), rows())
        self.assertNotIn(("Paylaşım WebDAV — yalnız Konsol'dan paylaşılanlar (Infuse)", "tailscale"), rows())
        modules.write_text("paylasim\tcalisiyor\n")
        self.assertIn(("Paylaşım WebDAV — yalnız Konsol'dan paylaşılanlar (Infuse)", "tailscale"), rows())
        # A malformed manifest line disables that package's rows instead of guessing.
        (mods_dir / "torrent" / "paket.env").write_text('PAKET_PORTLAR="x"\nbroken line\n')
        modules.write_text("torrent\tcalisiyor\n")
        self.assertFalse({n for n, _ in rows() if "qBittorrent" in n})
        self.assertNotIn("share", self.p.system())
        self.assertNotIn("ports", self.p.system())

    def test_module_listing_carries_qbittorrent_addresses(self):
        # DD-195 (v2-168): the tailnet name always; the public name only while that publication is active.
        state = Path(self.p.args.state)
        state.write_text(state.read_text() + "SHARE_HTTPS_PORT=443\n")
        rows = {"torrent": {"tail": True, "enabled": True, "domain": "qbit.example.net"}}
        # DD-199: the package declares its publication; the manifest gives the local and public names.
        pkgs = {"torrent": {"name": "qBittorrent", "local": "torrent", "upstream": "127.0.0.1:61006", "check": "", "order": 20}}
        listing = (0, "torrent\thost\tcalisiyor\trunning\t-\t-\t-\t-\nwireguard\tkonsol\tyok\t-\t-\t-\t-\t-\n", "")
        with patch.object(self.p, "modul", return_value=listing), patch.object(self.p, "busy_units", return_value=set()), \
                patch.object(panel.master_publications, "packages", return_value=pkgs), \
                patch.object(panel.master_publications, "config", return_value=rows), \
                patch.object(panel.master_publications, "package_active", return_value=True):
            items = {m["id"]: m for m in self.p.modules()}
            self.assertEqual(items["torrent"]["urls"], {"tailscale": "http://torrent.test", "internet": "https://qbit.example.net"})
            self.assertNotIn("urls", items["wireguard"])
        with patch.object(self.p, "modul", return_value=listing), patch.object(self.p, "busy_units", return_value=set()), \
                patch.object(panel.master_publications, "packages", return_value=pkgs), \
                patch.object(panel.master_publications, "package_active", return_value=False):
            self.assertEqual(self.p.modules()[0]["urls"], {"tailscale": "http://torrent.test", "internet": None})
        # A broken publication record never hides the module list or the tailnet name.
        with patch.object(self.p, "modul", return_value=listing), patch.object(self.p, "busy_units", return_value=set()), \
                patch.object(panel.master_publications, "packages", return_value=pkgs), \
                patch.object(panel.master_publications, "config", side_effect=panel.master_settings.SettingsError("bozuk")):
            self.assertIsNone(self.p.modules()[0]["urls"]["internet"])
        # A package without a publication row has no addresses to show.
        with patch.object(self.p, "modul", return_value=listing), patch.object(self.p, "busy_units", return_value=set()), \
                patch.object(panel.master_publications, "packages", return_value={}):
            self.assertNotIn("urls", self.p.modules()[0])

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

    def test_unix_helper_reads_early_rejection_after_body_write_breaks(self):
        class Handler(panel.Handler):
            def body_json(self):
                raise AssertionError("a rejected body must not be read")
        Handler.panel = self.p
        server, sock = start_unix(self, Handler)
        closed = threading.Event()
        shutdown = server.shutdown_request
        send = panel.UnixConnection.send
        body = b'{}'
        attempted = []

        def finish(request):
            shutdown(request)
            closed.set()

        def send_after_rejection(conn, data):
            if data == body:
                self.assertTrue(closed.wait(2), "server did not reject the headers")
                attempted.append(True)
                raise BrokenPipeError("server closed before the separate body write")
            return send(conn, data)

        with patch.object(server, "shutdown_request", side_effect=finish), \
                patch.object(panel.UnixConnection, "send", new=send_after_rejection), \
                patch.object(self.p, "run", side_effect=AssertionError("must not mutate")):
            status, headers, raw = unix_get(sock, "/api/wg/nets", {"Content-Type": "application/json"}, "POST", body)
        self.assertEqual(attempted, [True])
        self.assertEqual(status, 403)
        self.assertEqual(headers["Connection"], "close")
        self.assertIn("error", json.loads(raw))

    def test_unix_helper_does_not_treat_broken_pipe_without_response_as_success(self):
        with patch.object(panel, "UnixConnection") as connection:
            conn = connection.return_value
            conn.request.side_effect = BrokenPipeError("write closed")
            conn.getresponse.side_effect = panel.http.client.RemoteDisconnected("no HTTP response")
            with self.assertRaises(panel.http.client.RemoteDisconnected):
                unix_get("unused", "/api/wg/nets", {}, "POST", b'{}')
            conn.close.assert_called_once()

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
            if argv[:2] == ["systemctl", "show"]:
                return 0, "\n\n".join("Id=%s\nLoadState=loaded\nActiveState=active\nUnitFileState=enabled" % unit
                                      for unit in argv[4:])
            return outputs.get(argv[0], (0, ""))
        with patch.object(self.p, "health_cmd", side_effect=cmd), \
                patch.object(self.p, "health_reboot", return_value=("warn", "reboot") if reboot else ("ok", "same kernel")), \
                patch.object(panel.master_settings, "Manager") as manager, \
                patch.object(panel.master_shares, "Manager") as shares:
            manager.return_value.status.return_value = {"pending": pending}
            shares.return_value.wan_info.return_value = {"available": True}
            shares.return_value.read.return_value = {"items": []}
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
