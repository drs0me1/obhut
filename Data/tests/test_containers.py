"""Read-only Podman mapper (DD-208), reused by the main container manager (DD-211).

Podman is base infrastructure; panel/master_containers.py maps read-only podman output for the
root backend. No real podman: every command answers from canned output, so the tests cover the
mapping, the masking and the gates; a route test runs the real backend handler on a Unix socket. An
application's log is its units' journal (test_container_manager); there is no podman logs read."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "panel"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import master_containers as containers  # noqa: E402
import tempfile  # noqa: E402
import types  # noqa: E402
from test_resources import panel, start_unix, unix_get  # noqa: E402

PS = [{"Id": "2073a1b2c3d4e5f6", "Names": ["deneme-medya"], "Image": "ghcr.io/example/medya:latest", "State": "running",
       "Status": "Up 9 minutes", "Created": 1790972658, "StartedAt": 1790972659, "ExitCode": 0, "Restarts": 2,
       "Labels": {"PODMAN_SYSTEMD_UNIT": "deneme-medya.service"}, "Namespaces": {"Net": "host"}, "Networks": [], "Ports": None,
       "Mounts": ["/config", "/downloads"]},
      {"Id": "ffff000011112222", "Names": ["web"], "Image": "docker.io/library/nginx:1.27", "State": "exited", "Status": "Exited (3) 2 hours ago",
       "Created": 1790900000, "StartedAt": 1790900001, "ExitCode": 3, "Restarts": 0, "Labels": {}, "Networks": ["podman"],
       "Ports": [{"host_ip": "", "host_port": 8081, "container_port": 80, "protocol": "tcp", "range": 1}], "Mounts": []}]
IMAGES = [{"Names": ["ghcr.io/example/medya:latest"], "Size": 228000000, "Created": 1790667122}, {"Names": None, "Size": 5, "Created": 1}]
DF = [{"Type": "Images", "Total": 2, "Active": 1, "RawSize": 228000000, "RawReclaimable": 5},
      {"Type": "Containers", "Total": 2, "Active": 1, "RawSize": 1000, "RawReclaimable": 0}, {"Type": "Local Volumes", "RawSize": 0}]


class Ctx:
    def __init__(self):
        self.calls, self.fail, self.version = [], {}, "5.4.2"

    def run(self, argv, timeout=120, binary=False):
        self.calls.append((list(argv), timeout))
        key = argv[1]
        if key in self.fail:
            return 125, "", self.fail[key]
        if key == "version":
            return 0, self.version + "\n", ""
        if key == "ps":
            return 0, json.dumps(PS), ""
        if key == "images":
            return 0, json.dumps(IMAGES), ""
        if key == "system":
            return 0, json.dumps(DF), ""
        raise AssertionError(argv)


class ContainerViewTests(unittest.TestCase):
    def setUp(self):
        self.ctx = Ctx()
        self.view = containers.Containers(self.ctx.run)

    def call(self, sub, method="GET"):
        """The backend route's logic: GET only, one read path, a ContainerError becomes its status."""
        if method != "GET" or sub != "liste":
            raise RuntimeError("404 bulunamadı")
        try:
            return 200, self.view.liste()
        except containers.ContainerError as err:
            raise RuntimeError("%d %s" % (err.status, err))

    def test_list_maps_containers_images_and_storage(self):
        code, answer = self.call("liste")
        self.assertEqual(code, 200)
        self.assertEqual(answer["runtime"], {"version": "5.4.2", "ok": True, "error": ""})
        medya, web = answer["containers"]
        self.assertEqual((medya["id"], medya["name"], medya["state"], medya["unit"], medya["network"], medya["ports"], medya["mounts"], medya["restarts"]),
                         ("2073a1b2c3d4", "deneme-medya", "running", "deneme-medya.service", "host", [], 2, 2))
        self.assertEqual((medya["uygulama"], web["uygulama"]), ("", ""), "no application's labels")
        self.assertEqual((medya["created"], medya["started"], medya["exit_code"]), (1790972658, 1790972659, 0))
        self.assertEqual((web["state"], web["exit_code"], web["network"], web["unit"]), ("exited", 3, "podman", ""))
        self.assertEqual(web["ports"], [{"host_ip": "0.0.0.0", "host_port": 8081, "container_port": 80, "protocol": "tcp"}])
        self.assertEqual(answer["images"], [{"name": "ghcr.io/example/medya:latest", "size": 228000000, "created": 1790667122},
                                            {"name": "<adsız>", "size": 5, "created": 1}])
        self.assertEqual(answer["storage"], {"images": 2, "containers": 2, "size": 228001000, "types": [
            {"type": "images", "count": 2, "active": 1, "size": 228000000, "reclaimable": 5},
            {"type": "containers", "count": 2, "active": 1, "size": 1000, "reclaimable": 0},
            {"type": "volumes", "count": 0, "active": 0, "size": 0, "reclaimable": None}]}, "DD-289: each kind as Podman counts it")
        self.assertNotIn("Env", json.dumps(answer))
        self.assertEqual([c[0][:2] for c in self.ctx.calls], [["podman", "version"], ["podman", "ps"], ["podman", "images"], ["podman", "system"]])

    def test_list_without_podman_is_a_calm_answer(self):
        self.ctx.fail["version"] = "podman çalıştırılamadı (FileNotFoundError)"
        code, answer = self.call("liste")
        self.assertEqual((code, answer["runtime"]["ok"], answer["containers"], answer["images"]), (200, False, [], []))
        self.assertIn("Podman kullanılamıyor", answer["runtime"]["error"])
        self.ctx.fail = {"ps": "Error: database is locked"}
        code, answer = self.call("liste")
        self.assertEqual((answer["runtime"]["ok"], answer["runtime"]["version"]), (False, "5.4.2"))
        self.assertIn("Konteynerler okunamadı", answer["runtime"]["error"])
        self.ctx.fail = {}
        self.ctx.version = "weird; rm -rf"
        self.assertFalse(self.call("liste")[1]["runtime"]["ok"])

    def test_methods_and_paths(self):
        with self.assertRaises(RuntimeError) as err:
            self.call("liste", method="POST")
        self.assertIn("404", str(err.exception), "the backend has no write route for containers")
        with self.assertRaises(RuntimeError) as err:
            self.call("baslat")
        self.assertIn("404", str(err.exception))
        self.assertEqual([c[0] for c in self.ctx.calls if c[0][1] in ("rm", "stop", "start", "kill", "exec")], [])

    def test_time_parsing(self):
        self.assertEqual(containers.epoch("2026-10-02T22:24:19.081055326+02:00"), 1790972659)
        self.assertEqual(containers.epoch("2026-10-02T20:24:19Z"), 1790972659)
        self.assertIsNone(containers.epoch("0001-01-01T00:00:00Z"))
        self.assertIsNone(containers.epoch(-62135596800))
        self.assertIsNone(containers.epoch("garbage"))
        self.assertEqual(containers.epoch(1790972659.7), 1790972659)


class ContainerRouteTests(unittest.TestCase):
    """The real handler: shared Konsol gates, GET answers, no write route (POST → 404), no podman write verb."""
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        (root / "state.env").write_text(f"SERVER_ROOT={root}\nLOCAL_DOMAIN=test\nV2_VERSION=test\n")
        self.p = panel.Panel(types.SimpleNamespace(state=str(root / "state.env")))

    def test_routes_keep_the_gates_and_never_write(self):
        fake = Ctx()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        # The routes read the container manager's view; here its read-only mapper over the fake runtime.
        view = panel.master_containers.Containers(lambda argv, timeout: fake.run(argv, timeout))
        with patch.object(self.p.containers, "view", return_value=view):
            _server, sock = start_unix(self, Handler)
            self.assertEqual(unix_get(sock, "/api/konsol/konteynerler/liste", {})[0], 403)
            self.assertEqual(unix_get(sock, "/api/konsol/konteynerler/liste", {"X-Konsol": "1", "Host": "evil.test"})[0], 403)
            status, _h, body = unix_get(sock, "/api/konsol/konteynerler/liste", {"X-Konsol": "1"})
            self.assertEqual((status, [c["name"] for c in json.loads(body)["containers"]]), (200, ["deneme-medya", "web"]))
            self.assertEqual(unix_get(sock, "/api/konsol/konteynerler/ayrinti?ad=deneme-medya", {"X-Konsol": "1"})[0], 404)
            self.assertEqual(unix_get(sock, "/api/konsol/konteynerler/baslat", {"X-Konsol": "1"})[0], 404)
            for path in ("/api/konsol/konteynerler/liste", "/api/konsol/konteynerler/durdur"):
                self.assertEqual(unix_get(sock, path, {"X-Konsol": "1", "Content-Type": "application/json"}, "POST", b"{}")[0], 404)
        self.assertEqual([c[0] for c in fake.calls if c[0][1] in ("rm", "stop", "start", "kill", "exec", "pull", "run")], [])


if __name__ == "__main__":
    unittest.main()
