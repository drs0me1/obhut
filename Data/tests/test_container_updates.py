"""DD-214: explicit image updates. The base compares an application's pinned digest of each service with
what the tag in its file points to now (registry manifests only, cached); the applications' list shows the
state per service and ?yenile asks again (DD-271, phase 3)."""
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

PANEL = Path(__file__).resolve().parents[1] / "panel"
sys.path.insert(0, str(PANEL))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_fixtures  # noqa: E402
import master_containers as containers  # noqa: E402
import master_container_manager as manager  # noqa: E402

REPO = "registry.example/medya"
OLD = REPO + "@sha256:" + "b5" * 32
AMD, ARM, OTHER = "sha256:" + "11" * 32, "sha256:" + "22" * 32, "sha256:" + "33" * 32
INDEX = {"mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
    {"digest": AMD, "platform": {"architecture": "amd64", "os": "linux"}},
    {"digest": ARM, "platform": {"architecture": "arm64", "os": "linux", "variant": "v8"}},
    {"digest": "sha256:" + "44" * 32, "platform": {"architecture": "unknown", "os": "unknown"}}]}


class Registry:
    """podman as the update check sees it: one local image, one remote channel answer."""
    def __init__(self, local=(AMD,), remote=INDEX, image_id="f" * 64):
        self.local, self.remote, self.image_id, self.calls = list(local), remote, image_id, []

    def __call__(self, argv, timeout):
        self.calls.append(list(argv))
        if argv[:3] == ["podman", "image", "inspect"]:
            if argv[3] != OLD:
                return 125, "", "Error: image not known"
            return 0, json.dumps([{"Id": self.image_id, "Digest": "sha256:" + "b5" * 32,
                                   "RepoDigests": [REPO + "@" + d for d in self.local] + [OLD]}]), ""
        if argv[:3] == ["podman", "manifest", "inspect"]:
            if self.remote is None:
                return 125, "", "Error: reading manifest latest: dial tcp: i/o timeout"
            return 0, json.dumps(self.remote), ""
        raise AssertionError(argv)


class UpdateStatusTests(unittest.TestCase):
    def test_index_compares_this_hosts_platform_digest(self):
        reg = Registry(local=(AMD,))
        self.assertEqual(containers.update_status(reg, OLD, REPO + ":latest", "amd64"),
                         {"state": "guncel", "channel": REPO + ":latest", "candidate": REPO + "@" + AMD, "error": ""})
        reg = Registry(local=(OTHER,))
        status = containers.update_status(reg, OLD, REPO + ":latest", "amd64")
        self.assertEqual((status["state"], status["candidate"]), ("var", REPO + "@" + AMD))
        self.assertEqual(containers.update_status(reg, OLD, REPO + ":latest", "arm64")["candidate"], REPO + "@" + ARM)
        self.assertEqual(containers.update_status(reg, OLD, REPO + ":latest", "riscv64")["state"], "denetlenemedi")
        # Manifests only: no pull, no run, no layer download.
        self.assertFalse([c for c in reg.calls if c[1] not in ("image", "manifest")])

    def test_single_manifest_compares_the_config_digest_with_the_image_id(self):
        single = {"schemaVersion": 2, "config": {"digest": "sha256:" + "f" * 64}, "layers": []}
        self.assertEqual(containers.update_status(Registry(remote=single), OLD, REPO + ":5", "amd64")["state"], "guncel")
        self.assertEqual(containers.update_status(Registry(remote=single, image_id="e" * 64), OLD, REPO + ":5", "amd64")["state"], "var")
        self.assertEqual(containers.update_status(Registry(remote={"odd": 1}), OLD, REPO + ":5", "amd64")["state"], "denetlenemedi")

    def test_pinned_unreachable_and_missing_are_calm_answers(self):
        reg = Registry()
        for channel in ("", REPO + "@" + AMD):
            self.assertEqual(containers.update_status(reg, OLD, channel, "amd64")["state"], "sabit")
        self.assertEqual(reg.calls, [], "a pinned reference never asks the registry")
        down = containers.update_status(Registry(remote=None), OLD, REPO + ":latest", "amd64")
        self.assertEqual(down["state"], "denetlenemedi")
        self.assertIn("Kayıt defterine ulaşılamadı", down["error"])
        self.assertEqual(containers.update_status(Registry(), REPO + "@sha256:" + "0" * 64, REPO + ":latest", "amd64")["state"], "denetlenemedi")

    def test_image_repo_drops_tag_and_digest_but_keeps_a_registry_port(self):
        self.assertEqual(containers.image_repo(REPO + ":latest"), REPO)
        self.assertEqual(containers.image_repo(OLD), REPO)
        self.assertEqual(containers.image_repo("localhost:5000/a/b:1"), "localhost:5000/a/b")


MEDYA = """name: medya
services:
  web:
    image: registry.example/medya:latest
  pinned:
    image: registry.example/medya@sha256:%s
""" % ("b5" * 32)
MEDYA_ANSWERS = {"name": "medya", "answers": {"start:web": {"mode": "root"}, "start:pinned": {"mode": "root"}}}


class ManagerUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name).resolve()
        self.env = app_fixtures.env(root)
        app_fixtures.write_state(root, self.env)
        record = app_fixtures.record(self.env, text=MEDYA, given=MEDYA_ANSWERS, app="medya")
        assert record["places"]["images"]["web"].startswith(REPO + "@")
        # The pinned digest is the old one the registry fake knows.
        places = dict(record["places"], images={"web": OLD, "pinned": OLD})
        app_fixtures.apps.Records(self.env).write("medya", places=places)
        self.registry = Registry(local=(OTHER,))
        self.calls = []

        def run_tool(argv, timeout=30, binary=False):
            self.calls.append(list(argv))
            if argv[:2] == ["podman", "info"]:
                return 0, "amd64\n", ""
            if argv[:2] in (["podman", "image"], ["podman", "manifest"]):
                return self.registry(argv, timeout)
            if argv[:2] == ["podman", "version"]:
                return 0, "5.4.2", ""
            return 0, "[]", ""
        self.p = types.SimpleNamespace(args=types.SimpleNamespace(state=str(root / "state.env")), run_tool=run_tool, env=lambda: {})
        self.s = manager.Service(self.p)

    def remote_calls(self):
        return [c for c in self.calls if c[:3] == ["podman", "manifest", "inspect"]]

    def test_each_service_of_an_application_reports_its_cached_status(self):
        self.assertIsNone(self.s.update_of("medya"), "no registry call while nothing asked")
        self.assertEqual(self.remote_calls(), [])
        answer = self.s.updates()
        self.assertEqual(answer["items"]["medya"], {"web": {"state": "var", "channel": REPO + ":latest", "error": ""},
                                                    "pinned": {"state": "sabit", "channel": "", "error": ""}})
        self.assertNotIn("candidate", json.dumps(answer), "the browser never receives a pull target")
        self.assertEqual(self.s.update_of("medya")["web"]["state"], "var")
        self.assertEqual(len(self.remote_calls()), 1, "a service whose file pins a digest never asks the registry")

    def test_cache_ttl_forced_refresh_min_interval_and_forget(self):
        self.s.updates()
        self.s.updates()
        self.assertEqual(len(self.remote_calls()), 1, "cached within the TTL")
        self.s.updates(force=True)
        self.assertEqual(len(self.remote_calls()), 1, "a forced check is still rate-limited to one a minute")
        self.s.update_at -= manager.UPDATE_MIN_INTERVAL + 1
        self.s.updates(force=True)
        self.assertEqual(len(self.remote_calls()), 2)
        self.s.update_at -= manager.UPDATE_TTL + 1
        self.s.updates()
        self.assertEqual(len(self.remote_calls()), 3, "stale after the TTL")
        self.s.forget_updates()
        self.assertIsNone(self.s.update_of("medya"))
        self.s.updates()
        self.assertEqual(len(self.remote_calls()), 4)

    def test_a_successful_application_job_invalidates_the_cache(self):
        self.s.updates()
        self.s.jobs["a" * 32] = {"id": "a" * 32, "state": "running", "name": "medya", "action": "uygulama-guncelle"}
        with patch.object(self.s, "operation", return_value={"id": "a" * 32, "state": "done"}), \
             patch.object(manager.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout='{"ok": true}')):
            self.s._execute("a" * 32, "uygulama-guncelle", {"name": "medya"})
        self.assertIsNone(self.s.update_of("medya"))


class RouteTests(unittest.TestCase):
    def test_the_list_asks_again_only_when_told(self):
        from test_resources import panel, start_unix, unix_get
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        (root / "state").write_text(f"SERVER_ROOT={root}\nLOCAL_DOMAIN=test\nKONTEYNER_STATE_DIR={root}/containers\n")
        p = panel.Panel(types.SimpleNamespace(state=str(root / "state")))

        class Handler(panel.Handler):
            def log_message(self, *_):
                pass
        Handler.panel = p
        _server, sock = start_unix(self, Handler)
        empty = {"read_at": 1, "items": [], "kaynaklar": [], "hatalar": []}
        view = types.SimpleNamespace(applications=lambda: empty)
        with patch.object(manager.Service, "updates") as updates, patch.object(p.containers, "view", return_value=view):
            code, _, raw = unix_get(sock, "/api/konsol/uygulamalar", {"X-Konsol": "1"})
            self.assertEqual((code, json.loads(raw)), (200, empty))
            updates.assert_not_called()
            unix_get(sock, "/api/konsol/uygulamalar?yenile=1", {"X-Konsol": "1"})
            self.assertEqual(updates.call_args.kwargs, {"force": True})
            self.assertEqual(unix_get(sock, "/api/konsol/konteynerler/guncellemeler", {"X-Konsol": "1"})[0], 404,
                             "the per-container route is gone")


if __name__ == "__main__":
    unittest.main()
