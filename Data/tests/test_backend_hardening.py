"""Burst admission and reserved-name regressions; disposable local fixtures only."""
import contextlib
import http.server
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import unittest

DATA = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(DATA / "panel"), str(DATA / "files-panel")]
import master_webdav as dav


def load_script(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


panel = load_script("hardened_panel", DATA / "panel/master-panel")
files = load_script("hardened_files", DATA / "files-panel/master-files-panel")


class ReservedNamesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in (".cop", "dest"):
            (self.root / name).mkdir()
            (self.root / name / "marker").write_text(name)
        (self.root / "ordinary").write_text("keep")
        self.files = files.Files(str(self.root), ".cop")

    def test_reserved_sources_reject_rename_move_and_trash_before_any_mutation(self):
        for name in (".cop",):
            actions = [lambda: self.files.rename([], name, "renamed"),
                       lambda: self.files.move([], ["ordinary", name], ["dest"]),
                       lambda: self.files.to_trash([], ["ordinary", name])]
            for action in actions:
                with self.subTest(name=name, action=action), self.assertRaises(files.PanelError) as err:
                    action()
                self.assertEqual(err.exception.code, 403)
                self.assertEqual((self.root / name / "marker").read_text(), name)
                self.assertEqual((self.root / "ordinary").read_text(), "keep")
                self.assertFalse((self.root / "dest/ordinary").exists())
                self.assertEqual(sorted(p.name for p in (self.root / ".cop").iterdir()), ["marker"])

    def test_moving_nested_reserved_name_cannot_create_a_root_system_area(self):
        for name in (".cop",):
            source = self.root / "dest" / name
            source.mkdir()
            with self.subTest(name=name), self.assertRaises(files.PanelError) as error:
                self.files.move(["dest"], [name], [])
            self.assertIn("kök klasöre", str(error.exception))
            self.assertTrue(source.is_dir())

    def test_ordinary_rename_move_trash_and_restore_still_work(self):
        self.files.rename([], "ordinary", "renamed")
        self.files.move([], ["renamed"], ["dest"])
        tokens = self.files.to_trash(["dest"], ["renamed"])
        self.files.restore(tokens)
        self.assertEqual((self.root / "dest/renamed").read_text(), "keep")

    def test_restore_never_publishes_a_reserved_root_name(self):
        for name in (".cop",):
            # A historical/manually edited trash entry must choose a harmless new name.
            token = "1700000000000-" + "a" * 8
            target = self.root / ".cop" / token
            target.mkdir()
            (target / name).write_text("saved")
            (self.root / ".cop" / (token + ".json")).write_text(json.dumps({"from": ""}))
            result = self.files.restore([token])[0]
            self.assertNotEqual(result["name"], name)
            self.assertEqual((self.root / result["name"]).read_text(), "saved")
            self.assertEqual((self.root / name / "marker").read_text(), name)


class ListenQueueTests(unittest.TestCase):
    def test_all_backends_accept_a_burst_before_the_accept_loop_runs(self):
        # No requests/threads are processed: this isolates the actual kernel listen queue.
        with tempfile.TemporaryDirectory(prefix="queue-", dir="/tmp") as root:
            constructors = [lambda: panel.Server(root + "/api.sock"),
                            lambda: files.Server(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler),
                            lambda: dav.Server(("127.0.0.1", 0), {"items": []})]
            for construct in constructors:
                with contextlib.ExitStack() as cleanup:
                    server = construct()
                    cleanup.callback(server.server_close)
                    for _ in range(24):
                        client = socket.socket(server.address_family, socket.SOCK_STREAM)
                        cleanup.callback(client.close)
                        client.settimeout(.5)
                        client.connect(server.server_address)


if __name__ == "__main__":
    unittest.main()
