"""Independent, gated host resources for the Model A shell."""
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
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

    def test_legacy_system_keeps_ports(self):
        self.assertIn("ports", self.p.system([]))

    def test_http_resources_have_same_host_header_and_origin_gates(self):
        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        server = panel.Server(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/api/konsol/kaynaklar"
            for headers in ({}, {"X-Konsol": "1", "Host": "evil.test"},
                            {"X-Konsol": "1", "Sec-Fetch-Site": "cross-site"}):
                with self.assertRaises(urllib.error.HTTPError) as err:
                    urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=3)
                self.assertEqual(err.exception.code, 403)
                err.exception.close()
            with patch.object(self.p, "net_rows", side_effect=RuntimeError("WG failed")):
                with urllib.request.urlopen(urllib.request.Request(url, headers={"X-Konsol": "1"}), timeout=3) as response:
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
                    self.assertNotIn("ports", json.load(response))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(3)


if __name__ == "__main__":
    unittest.main()
