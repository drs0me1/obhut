"""Files uploads keep the disk reserve (DD-180); temporary files only."""
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "files-panel" / "master-files-panel"
loader = importlib.machinery.SourceFileLoader("files_panel", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
fp = importlib.util.module_from_spec(spec)
loader.exec_module(fp)

GIB = 1024 ** 3


def vfs(total, free):
    return types.SimpleNamespace(f_frsize=1, f_blocks=total, f_bavail=free)


class UploadReserveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "Filmler").mkdir()
        self.files = fp.Files(str(self.root), ".cop")

    def test_handler_disables_nagle_for_kept_alive_caddy_connections(self):
        self.assertTrue(fp.Handler.disable_nagle_algorithm)

    def test_reserve_is_five_gib_or_a_tenth_of_a_small_disk(self):
        with patch.object(fp.os, "fstatvfs", return_value=vfs(1000 * GIB, 6 * GIB)):
            fp.disk_room(0, GIB)
            with self.assertRaises(fp.PanelError) as err:
                fp.disk_room(0, 2 * GIB)
        self.assertEqual(err.exception.code, 507)
        self.assertIn("5.0 GB", err.exception.message)
        with patch.object(fp.os, "fstatvfs", return_value=vfs(20 * GIB, 3 * GIB)):
            fp.disk_room(0, GIB)
            with self.assertRaises(fp.PanelError):
                fp.disk_room(0, GIB + 1)

    def test_upload_is_refused_before_the_body_and_stopped_while_streaming(self):
        with patch.object(fp, "disk_room", side_effect=fp.PanelError(507, "dolu")):
            with self.assertRaises(fp.PanelError) as err:
                self.files.upload_check(["Filmler"], "a.bin", 10)
        self.assertEqual(err.exception.code, 507)
        calls = []

        def room(_fd, incoming=0):
            calls.append(incoming)
            if len(calls) > 1:
                raise fp.PanelError(507, "dolu")
        with patch.object(fp, "DISK_CHECK_EVERY", 4), patch.object(fp, "disk_room", side_effect=room):
            with self.assertRaises(fp.PanelError):
                self.files.upload(["Filmler"], "b.bin", io.BytesIO(b"12345678"), 8)
        self.assertEqual(calls, [8, 0])
        self.assertEqual(list((self.root / "Filmler").iterdir()), [])
        self.assertEqual(self.files.upload(["Filmler"], "c.bin", io.BytesIO(b"ok"), 2), 2)
        self.assertEqual((self.root / "Filmler" / "c.bin").read_bytes(), b"ok")


if __name__ == "__main__":
    unittest.main()


class WriteAndTrashTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "Filmler").mkdir()
        self.files = fp.Files(str(self.root), ".cop")

    def test_short_writes_are_continued(self):
        real = fp.os.write
        with patch.object(fp, "disk_room"), \
             patch.object(fp.os, "write", side_effect=lambda fd, data: real(fd, bytes(data[:3]))):
            self.assertEqual(self.files.upload(["Filmler"], "a.txt", io.BytesIO(b"0123456789"), 10), 10)
        self.assertEqual((self.root / "Filmler/a.txt").read_bytes(), b"0123456789")

    def trash_with_a_disk_inside(self):
        (self.root / "Filmler/disk").mkdir()
        (self.root / "Filmler/disk/film.mkv").write_bytes(b"x")
        token = self.files.to_trash([], ["Filmler"])[0]
        real = fp.os.stat

        def fake(path, *args, **kwargs):
            st = real(path, *args, **kwargs)
            if path == "disk":
                return types.SimpleNamespace(st_dev=st.st_dev + 1, st_mode=st.st_mode)
            return st
        return token, patch.object(fp.os, "stat", side_effect=fake)

    def test_emptying_the_trash_never_enters_a_mounted_disk(self):
        # rename() moves a folder with a disk mounted inside it; the trash must not empty the disk.
        token, other_device = self.trash_with_a_disk_inside()
        with other_device:
            with self.assertRaises(fp.PanelError) as err:
                self.files.empty()
        self.assertEqual(err.exception.code, 409)
        self.assertTrue((self.root / ".cop" / token / "Filmler/disk/film.mkv").exists())

    def test_purging_an_item_never_enters_a_mounted_disk(self):
        token, other_device = self.trash_with_a_disk_inside()
        with other_device:
            with self.assertRaises(fp.PanelError):
                self.files.purge([token])
        self.assertTrue((self.root / ".cop" / token / "Filmler/disk/film.mkv").exists())
        self.files.purge([token])
        self.assertFalse((self.root / ".cop" / token).exists())
