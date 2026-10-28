"""What a running application's processes run as (master_containers.process_users) and what an application's /srv
warning says about it now (master_applications.warning_now): read from the container's cgroup and /proc, its own
/etc/passwd for the names, never through a link inside the container. Unknown stays unknown (None)."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

PANEL = Path(__file__).resolve().parents[1] / "panel"
sys.path.insert(0, str(PANEL))
import master_applications as apps  # noqa: E402
import master_containers as containers  # noqa: E402

PAYLOAD = "/system.slice/app.service/libpod-payload-" + "cd" * 32


class Tree:
    """A minimal /proc and cgroup v2 tree: processes with their user and command, the container's root."""

    def __init__(self, root):
        self.proc, self.cgroups = root / "proc", root / "cgroup"
        self.root = root / "kok"
        (self.root / "etc").mkdir(parents=True)

    def process(self, pid, uid, comm, cgroup=PAYLOAD):
        d = self.proc / str(pid)
        d.mkdir(parents=True)
        (d / "cgroup").write_text("0::%s\n" % cgroup)
        (d / "status").write_text("Name:\t%s\nUid:\t%d\t%d\t%d\t%d\nGid:\t0\t0\t0\t0\n" % (comm, uid, uid, uid, uid))
        (d / "comm").write_text(comm + "\n")
        os.symlink(self.root, d / "root")

    def group(self, *pids):
        d = self.cgroups / PAYLOAD.lstrip("/")
        d.mkdir(parents=True, exist_ok=True)
        (d / "cgroup.procs").write_text("".join("%d\n" % p for p in pids))

    def users(self, pid=10):
        return containers.process_users(pid, proc=str(self.proc), cgroups=str(self.cgroups))


class ProcessUsersTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tree = Tree(Path(tmp.name))
        (self.tree.root / "etc" / "passwd").write_text("root:x:0:0:root:/root:/bin/sh\nabc:x:1000:1000::/config:/bin/false\n")

    def test_a_root_start_that_switched_shows_its_own_user_first_and_root_after(self):
        self.tree.process(10, 0, "s6-svscan")
        for pid, comm in ((11, "s6-supervise"), (12, "s6-supervise"), (13, "s6-linux-init-s")):
            self.tree.process(pid, 0, comm)
        self.tree.process(14, 1000, "qbittorrent-nox")
        self.tree.group(10, 11, 12, 13, 14)
        self.assertEqual(self.tree.users(), [
            {"uid": 1000, "ad": "abc", "surec": 1, "komutlar": ["qbittorrent-nox"]},
            {"uid": 0, "ad": "root", "surec": 4, "komutlar": ["s6-svscan", "s6-supervise", "s6-linux-init-s"]}])

    def test_a_name_comes_only_from_the_containers_own_passwd_never_through_a_link(self):
        outside = self.tree.root.parent / "host-passwd"
        outside.write_text("gizli:x:1000:1000::/:/bin/sh\n")
        (self.tree.root / "etc" / "passwd").unlink()
        os.symlink(outside, self.tree.root / "etc" / "passwd")
        self.tree.process(10, 1000, "app")
        self.tree.group(10)
        self.assertEqual(self.tree.users(), [{"uid": 1000, "ad": None, "surec": 1, "komutlar": ["app"]}])

    def test_unknown_stays_unknown(self):
        self.assertIsNone(self.tree.users(pid=0))
        self.assertIsNone(self.tree.users(pid=99), "no readable process")


class WarningNowTests(unittest.TestCase):
    ENV = {"DOWNLOADS_UID": "1000"}
    ABC = {"uid": 1000, "ad": "abc", "surec": 1, "komutlar": ["app"]}
    ROOT = {"uid": 0, "ad": "root", "surec": 7, "komutlar": ["s6-svscan"]}

    def test_switched_to_the_files_account_settles_it(self):
        now, resolved = apps.warning_now(self.ENV, [self.ABC, self.ROOT])
        self.assertTrue(resolved)
        self.assertEqual(now, "Şu an uygulama abc (uid 1000) olarak çalışıyor: Dosyalar hesabıyla aynı kullanıcı, /srv'ye "
                              "yazdıkları Dosyalar'dan açılır. Başlatıcının 7 süreci root olarak kalıyor.")

    def test_still_root_or_another_user_does_not(self):
        self.assertEqual(apps.warning_now(self.ENV, [self.ROOT]),
                         ("Şu an bütün süreçleri root olarak çalışıyor: /srv'ye yazdıkları root'a ait olur ve Dosyalar "
                          "hesabı açamaz.", False))
        self.assertEqual(apps.warning_now(self.ENV, [{"uid": 911, "ad": None, "surec": 2, "komutlar": []}]),
                         ("Şu an uygulama uid 911 olarak çalışıyor; Dosyalar hesabı (uid 1000) bu dosyaları açamayabilir.", False))
        self.assertEqual(apps.warning_now(self.ENV, None), (None, False), "not running: nothing to say")


if __name__ == "__main__":
    unittest.main()
