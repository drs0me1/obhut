#!/usr/bin/env python3
"""Real flock and ownership tests; only private temporary files are changed.

Run as root on Linux: python3 Data/tests/install-hardening-linux.py
No services, accounts, installed state or host firewall are changed: master-wg runs against a
private state file with a stand-in systemctl. Missing Linux/root/util-linux prerequisites are
errors, never skipped passing tests.
"""
import fcntl
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

from test_install_hardening import DATA, PermissionRepairTests, metadata, permissions


class OwnershipTests(unittest.TestCase):
    setUp = PermissionRepairTests.setUp
    file = PermissionRepairTests.file

    def test_uid_gid_and_mode_changes_count_each_entry_once(self):
        uid, gid = 65534, 65534
        self.root.chmod(0o775)
        os.chown(self.root, uid, gid)
        owner_only = self.file(self.root / "owner-only", 0o664)
        mode_only = self.file(self.root / "mode-only", 0o600)
        os.chown(mode_only, uid, gid)
        both = self.file(self.root / "both", 0o600)
        folder = self.root / "folder"
        folder.mkdir(mode=0o700)
        good = self.file(self.root / "good", 0o664)
        os.chown(good, uid, gid)
        before = metadata(good)
        self.assertEqual(permissions.repair(self.root, uid, gid), 4)
        for path in (owner_only, mode_only, both, folder, good):
            st = path.stat()
            self.assertEqual((st.st_uid, st.st_gid), (uid, gid))
            self.assertEqual(stat.S_IMODE(st.st_mode), 0o775 if path.is_dir() else 0o664)
        self.assertEqual(metadata(good), before)
        self.assertEqual(permissions.repair(self.root, uid, gid), 0)

    def test_root_never_chowns_links_or_devices(self):
        os.link(self.target, self.root / "hardlink")
        (self.root / "symlink").symlink_to(self.target)
        os.mkfifo(self.root / "fifo", 0o600)
        # A real device entry must be neither opened nor repaired.
        os.mknod(self.root / "device", stat.S_IFCHR | 0o600, os.makedev(1, 3))
        watched = list(self.root.iterdir()) + [self.target]
        before = [metadata(p) for p in watched]
        self.assertEqual(permissions.repair(self.root, 65534, 65534), 1)
        self.assertEqual([metadata(p) for p in watched], before)


class LockTests(unittest.TestCase):
    """master-wg's whole-WireGuard switches (DD-229, DD-271) and the installer share install.lock."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="installer-locks-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.runtime = self.root / "run"
        self.runtime.mkdir()
        self.install = self.runtime / "install.lock"
        self.wg = self.root / "wireguard"
        self.wg.mkdir(mode=0o700)
        self.stopped = self.wg / ".durduruldu"
        (self.wg / "networks").write_text(
            "wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tTest\n")
        self.pending = self.root / "pending.json"
        values = dict(V2_VERSION="2026.08.06-v2-test", RUNTIME_DIR=self.runtime, WAN_IPV4="203.0.113.7",
                      WG_CONF_DIR=self.wg, WG_CLIENTS_DIR=self.wg / "clients", WG_ADDR_BASE4="10.8",
                      WG_ADDR_BASE6="fd00", WG_CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0",
                      WG_NETWORKS_FILE=self.wg / "networks", WG_STOPPED_FILE=self.stopped,
                      SETTINGS_PENDING_FILE=self.pending)
        self.state = self.root / "state.env"
        self.state.write_text("".join(k + "=" + shlex.quote(str(v)) + "\n" for k, v in values.items()))
        # The stand-in systemctl logs its calls; with the gate file present, restarting the firewall
        # waits until the test removes it (so master-wg is caught while it holds the lock).
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.gate = self.root / "gate"
        self.calls = self.root / "calls"
        systemctl = self.bin / "systemctl"
        systemctl.write_text('#!/bin/bash\nprintf "%%s\\n" "$*" >>%s\n'
                             'if [ "$1" = restart ]; then while [ -e %s ]; do sleep 0.05; done; fi\n'
                             'case "$1" in is-enabled|list-unit-files|list-units) exit 0 ;; esac\nexit 0\n'
                             % (shlex.quote(str(self.calls)), shlex.quote(str(self.gate))))
        systemctl.chmod(0o755)
        self.env = dict(os.environ, STATE_FILE=str(self.state), PATH=str(self.bin) + ":" + os.environ["PATH"])

    def master_wg(self, *args, **kwargs):
        return subprocess.run(["bash", str(DATA / "scripts/master-wg"), *args], env=self.env,
                              capture_output=True, text=True, timeout=30, **kwargs)

    def hold(self, path):
        stream = path.open("a+")
        self.addCleanup(stream.close)
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return stream

    def locked(self, path):
        with path.open("a+") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            return False

    def spawn(self, *args):
        process = subprocess.Popen(list(map(str, args)), env=self.env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)

        def cleanup():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
        self.addCleanup(cleanup)
        return process

    def test_a_running_installer_blocks_both_switches_and_nothing_changes(self):
        holder = self.hold(self.install)
        for verb in ("durdur", "baslat"):
            result = self.master_wg(verb)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("kurulum ya da başka bir peer işlemi sürüyor", result.stderr)
        self.assertFalse(self.stopped.exists())
        self.assertFalse(self.calls.exists())
        fcntl.flock(holder, fcntl.LOCK_UN)
        result = self.master_wg("durdur")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "durduruldu\t1\n")
        self.assertTrue(self.stopped.exists())
        self.assertFalse(self.locked(self.install))

    def test_the_installer_cannot_start_while_master_wg_applies_the_firewall(self):
        self.gate.touch()
        process = self.spawn("bash", DATA / "scripts/master-wg", "durdur")
        deadline = time.monotonic() + 8
        while not (self.calls.exists() and "restart master-firewall.service" in self.calls.read_text()):
            self.assertLess(time.monotonic(), deadline, "master-wg never reached the firewall")
            self.assertIsNone(process.poll(), process.stderr.read() if process.poll() is not None else "")
            time.sleep(.02)
        self.assertTrue(self.locked(self.install), "master-wg applies the firewall without the install lock")
        result = subprocess.run(["bash", "-c", 'set -Eeuo pipefail; source "$1"; acquire_lock "$2" 0',
                                 "installer", str(DATA / "common.sh"), str(self.install)],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("kilit alınamadı", result.stderr)
        self.gate.unlink()
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stdout, "durduruldu\t1\n")
        self.assertFalse(self.locked(self.install))

    def test_a_held_installer_lock_from_common_sh_blocks_master_wg(self):
        process = self.spawn("bash", "-c", 'set -Eeuo pipefail; source "$1"; acquire_lock "$2" 1; '
                             'printf "ready\\n"; read -r release', "installer", DATA / "common.sh", self.install)
        self.assertTrue(select.select([process.stdout], [], [], 8)[0], "installer did not become ready")
        self.assertEqual(process.stdout.readline().strip(), "ready")
        result = self.master_wg("baslat")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("kurulum ya da başka bir peer işlemi sürüyor", result.stderr)
        process.communicate("release\n", timeout=8)
        self.assertEqual(process.returncode, 0)
        self.assertFalse(self.locked(self.install))

    def test_pending_settings_are_refused_and_the_lock_is_released(self):
        self.pending.write_text("{}")
        for verb in ("durdur", "baslat"):
            result = self.master_wg(verb)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("bekleyen ayar", result.stderr)
            self.assertFalse(self.locked(self.install))
        self.assertFalse(self.stopped.exists())
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    if sys.platform != "linux" or os.geteuid() != 0 or shutil.which("flock") is None:
        raise SystemExit("Requires Linux, root and util-linux flock; no tests were run")
    subprocess.run(["bash", "-c", "(( BASH_VERSINFO[0] >= 4 ))"], check=True)
    unittest.main(verbosity=2)
