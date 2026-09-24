"""Real ZIP/filesystem tests; only TemporaryDirectory fixtures are modified."""
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch
import zipfile

SOURCE = Path(os.environ.get("KONSOL_FILES_BACKEND", str(Path(__file__).resolve().parents[1] / "files-panel" / "master-files-panel")))
loader = importlib.machinery.SourceFileLoader("files_archive_test", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
files_module = importlib.util.module_from_spec(spec)
loader.exec_module(files_module)
import master_archives as ar


def zip_bytes(entries):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in entries:
            archive.writestr(name, content)
    return out.getvalue()


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="konsol-archive-test-")
        self.root = Path(self.tmp.name)
        self.files = files_module.Files(str(self.root), ".cop", ".pay", ".arsiv")
        self.manager = ar.Archives(self.files, ".arsiv", files_module.rename_noreplace, files_module.rmtree_at)
        (self.root / "source").mkdir()
        (self.root / "source" / "hello.txt").write_text("Merhaba İstanbul\n" * 50)

    def tearDown(self):
        if self.manager.thread:
            self.manager.thread.join(5)
        self.tmp.cleanup()

    def request(self, operation="zip", **overrides):
        values = dict(operation=operation, path="", names=["source"] if operation == "zip" else ["input.zip"],
                      target="", name="output.zip" if operation == "zip" else "output", nested=True, layers=3, conflict="rename")
        values.update(overrides)
        return values

    def run_job(self, operation="zip", **overrides):
        job = self.manager.submit(self.request(operation, **overrides))
        self.manager.thread.join(5)
        self.assertFalse(self.manager.thread.is_alive())
        return next(j for j in self.manager.status()["items"] if j["id"] == job["id"])

    def input(self, entries):
        (self.root / "input.zip").write_bytes(zip_bytes(entries))

    def assert_failed_clean(self, result):
        self.assertEqual(result["status"], "failed", result)
        self.assertFalse((self.root / "output").exists())
        self.assertEqual(sorted(p.name for p in (self.root / ".arsiv").iterdir()), ["jobs.json"])

    def test_round_trip_unicode_and_source_preserved(self):
        (self.root / "source" / "Boş klasör").mkdir()
        result = self.run_job()
        self.assertEqual(result["status"], "done", result)
        original = (self.root / "source" / "hello.txt").read_bytes()
        result = self.run_job("unzip", names=["output.zip"])
        self.assertEqual(result["status"], "done", result)
        self.assertEqual((self.root / "output" / "source" / "hello.txt").read_bytes(), original)
        self.assertTrue((self.root / "output" / "source" / "Boş klasör").is_dir())
        self.assertTrue((self.root / "source" / "hello.txt").exists())

    def test_nested_off_depth_two_and_three(self):
        inner = zip_bytes([("photo.jpg", b"picture")])
        middle = zip_bytes([("year.zip", inner)])
        self.input([("pictures.zip", middle)])
        for nested, layers, name in [(False, 3, "flat"), (True, 2, "two"), (True, 3, "three")]:
            result = self.run_job("unzip", nested=nested, layers=layers, name=name)
            self.assertEqual(result["status"], "done", result)
        self.assertFalse((self.root / "flat" / "pictures").exists())
        self.assertTrue((self.root / "two" / "pictures" / "year.zip").is_file())
        self.assertFalse((self.root / "two" / "pictures" / "year").exists())
        self.assertEqual((self.root / "three" / "pictures" / "year" / "photo.jpg").read_bytes(), b"picture")
        self.assertTrue((self.root / "input.zip").is_file())

    def test_conflicts_never_overwrite(self):
        self.input([("hello", b"new")])
        (self.root / "output").mkdir()
        (self.root / "output" / "keep").write_text("original")
        self.assertEqual(self.run_job("unzip", conflict="stop")["status"], "failed")
        self.assertEqual(self.run_job("unzip", conflict="skip")["status"], "skipped")
        self.assertEqual(self.run_job("unzip")["result"], "output (2)")
        self.assertEqual((self.root / "output" / "keep").read_text(), "original")

    def test_traversal_absolute_drive_backslash_internal_and_duplicate(self):
        for name in ["../escape", "/escape", "C:/escape", "a\\b", ".arsiv/jobs.json", ".cop/trash", ".pay/accounts"]:
            with self.subTest(name=name):
                self.input([(name, b"bad")])
                self.assert_failed_clean(self.run_job("unzip"))
        self.input([("a", b"one"), ("a", b"two")])
        self.assert_failed_clean(self.run_job("unzip"))

    def test_zip_symlink_rejected(self):
        info = zipfile.ZipInfo("link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.input([(info, b"/etc/passwd")])
        self.assert_failed_clean(self.run_job("unzip"))

    def test_source_symlink_hardlink_and_target_symlink_rejected(self):
        (self.root / "source" / "link").symlink_to("/etc/passwd")
        self.assertEqual(self.run_job()["status"], "failed")
        self.assertFalse((self.root / "output.zip").exists())
        (self.root / "source" / "link").unlink()
        os.link(self.root / "source" / "hello.txt", self.root / "source" / "hardlink")
        self.assertEqual(self.run_job()["status"], "failed")
        (self.root / "target").symlink_to(self.root / "source")
        with self.assertRaises(OSError):
            self.manager.submit(self.request(target="target"))

    def test_global_bytes_entries_and_deadline(self):
        self.input([("first", b"x" * 100), ("second", b"x" * 100)])
        with patch.object(ar, "MAX_BYTES", 150):
            self.assert_failed_clean(self.run_job("unzip"))
        with patch.object(ar, "MAX_ENTRIES", 1):
            self.assert_failed_clean(self.run_job("unzip"))
        with patch.object(ar, "MAX_SECONDS", -1):
            self.assert_failed_clean(self.run_job("unzip"))

    def test_corrupt_nested_rolls_back_whole_result(self):
        self.input([("valid.txt", b"valid"), ("broken.zip", b"not a zip")])
        self.assert_failed_clean(self.run_job("unzip"))
        self.assertTrue((self.root / "input.zip").is_file())

    def test_nested_layers_share_one_uncompressed_budget(self):
        inner = zip_bytes([("expanded", b"a" * 5000)])
        self.input([("one.zip", inner), ("two.zip", inner)])
        with patch.object(ar, "MAX_BYTES", 7000):
            result = self.run_job("unzip")
        self.assert_failed_clean(result)
        self.assertGreaterEqual(result["archives"], 2)

    def test_created_zip_rejects_nonportable_source_names(self):
        (self.root / "source" / "drive:name").write_text("not portable")
        self.assertEqual(self.run_job()["status"], "failed")
        self.assertFalse((self.root / "output.zip").exists())

    def test_crc_failure_rolls_back(self):
        data = bytearray(zip_bytes([("data", b"distinct data for corruption")]))
        data[35] ^= 0xff
        (self.root / "input.zip").write_bytes(data)
        self.assert_failed_clean(self.run_job("unzip"))

    def test_central_directory_rejected_before_zipfile(self):
        (self.root / "input.zip").write_bytes(struct.pack("<4s4H2LH", b"PK\x05\x06", 0, 0, 12000, 12000, 0, 0, 0))
        with patch.object(ar.zipfile, "ZipFile", side_effect=AssertionError("must reject before allocation")):
            result = self.run_job("unzip")
        self.assertIn("öge sayısı", result["message"])
        self.assert_failed_clean(result)

    def test_cancel_and_single_worker(self):
        entered, release = threading.Event(), threading.Event()
        original = self.manager.pack
        def block(*args, **kwargs):
            entered.set()
            release.wait(3)
            return original(*args, **kwargs)
        with patch.object(self.manager, "pack", block):
            job = self.manager.submit(self.request())
            self.assertTrue(entered.wait(2))
            with self.assertRaises(ar.ArchiveError) as err:
                self.manager.submit(self.request())
            self.assertEqual(err.exception.code, 409)
            self.manager.cancel(job["id"])
            release.set()
            self.manager.thread.join(5)
        self.assertEqual(self.manager.status()["items"][0]["status"], "cancelled")
        self.assertFalse((self.root / "output.zip").exists())
        self.assertTrue((self.root / "source" / "hello.txt").exists())

    def test_invalid_options_and_internal_api_paths(self):
        for values in [dict(operation="tar"), dict(layers=True), dict(layers=6), dict(nested="yes"), dict(conflict="overwrite"), dict(name="../bad.zip"), dict(target=".arsiv"), dict(path=".arsiv"), dict(names=[".arsiv"]), dict(target="source")]:
            with self.subTest(values=values), self.assertRaises((ar.ArchiveError, files_module.PanelError)):
                self.manager.submit(self.request(**values))
        self.assertNotIn(".arsiv", [e["name"] for e in self.files.listing([], False)["entries"]])

    def test_restart_marks_interrupted_cleans_only_owned_job(self):
        job_id = "a" * 24
        (self.root / ".arsiv" / job_id).mkdir()
        (self.root / ".arsiv" / job_id / "partial").write_text("partial")
        (self.root / ".arsiv" / "unrelated").write_text("keep")
        self.manager.jobs = [{"id": job_id, "status": "running"}]
        self.manager.persist()
        recovered = ar.Archives(self.files, ".arsiv", files_module.rename_noreplace, files_module.rmtree_at)
        self.assertEqual(recovered.status()["items"][0]["status"], "interrupted")
        self.assertFalse((self.root / ".arsiv" / job_id).exists())
        self.assertEqual((self.root / ".arsiv" / "unrelated").read_text(), "keep")
        self.assertEqual(stat.S_IMODE((self.root / ".arsiv").stat().st_mode), 0o700)


if __name__ == "__main__":
    unittest.main()
