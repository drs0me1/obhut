"""DD-233: Konsol's update button backend: the GitHub version check (pinned commit, cache, failure
back-off, forced re-check gap), the comparison with the installed version, the generation gate
(DD-271, S3), the unit's job state and stage, the start rules, the systemd-run call and the
Tailscale-only start route.
Temporary directories, a fake fetcher and fake systemd tools only; no network, no host changes."""
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "panel"))
import master_update as mu
import test_resources

panel = test_resources.panel
OLD, NEW, SHA = "2026.08.06-v2-211", "2026.08.06-v2-212", "0123456789abcdef0123456789abcdef01234567"


class Fetcher:
    """GitHub: the tip commit, then that commit's install.sh. `nesil` is its OBHUT_NESIL value (None:
    no line, generation 1); `extra` is appended verbatim."""

    def __init__(self, sha=SHA, version=NEW, surum=None, nesil="2", extra=""):
        self.sha, self.version, self.surum, self.calls, self.fail = sha, version, surum, [], None
        self.nesil, self.extra = nesil, extra

    def __call__(self, url, accept):
        self.calls.append((url, accept))
        if self.fail:
            raise self.fail
        if url.startswith("https://api.github.com/"):
            return self.sha + "\n"
        text = '#!/usr/bin/env bash\nset -Eeuo pipefail\n\nV2_VERSION="%s"\n' % self.version
        text += '# yorum\nOBHUT_SURUM="%s"\n' % self.surum if self.surum is not None else ""
        text += 'OBHUT_NESIL="%s"\n' % self.nesil if self.nesil is not None else ""
        return text + self.extra


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def env_for(root, version=OLD):
    return {"V2_VERSION": version, "OBHUT_NESIL": "2", "GUNCELLEME_REPO": "drs0me1/obhut", "GUNCELLEME_DAL": "main",
            "GUNCELLEME_UNIT": "master-guncelle.service",
            "GUNCELLEME_DURUM_FILE": str(root / "guncelleme.durum"), "GUNCELLEME_LOG_FILE": str(root / "guncelleme.log")}


class CheckTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.fetch, self.clock = Fetcher(), Clock()
        self.u = mu.Updates(self.fetch, self.clock)
        self.env = env_for(self.root)

    def test_numbers_only_from_installer_versions(self):
        self.assertEqual(mu.number(NEW), 212)
        for bad in ["", None, "test", "v2-212", "2026.08.06-v3-1", NEW + "x", "2026.08.06-v2-"]:
            self.assertIsNone(mu.number(bad), bad)

    def test_reads_the_tip_commit_then_the_version_at_that_commit(self):
        info = self.u.status(self.env, False)
        self.assertEqual((info["son"], info["commit"], info["yeni"], info["hata"]), (NEW, SHA, True, ""))
        self.assertEqual(self.fetch.calls, [
            ("https://api.github.com/repos/drs0me1/obhut/commits/main", "application/vnd.github.sha"),
            ("https://raw.githubusercontent.com/drs0me1/obhut/%s/Data/install.sh" % SHA, "text/plain")])

    def test_release_versions_are_shown_beside_the_build_numbers_that_decide(self):
        # DD-260: an installer without OBHUT_SURUM (any build before it) still offers by build number.
        info = self.u.status(self.env, False)
        self.assertEqual((info["kurulu_surum"], info["son_surum"], info["yeni"]), ("", None, True))
        u = mu.Updates(Fetcher(surum="1.1.0"), Clock())
        info = u.status(dict(self.env, OBHUT_SURUM="1.0.0"), False)
        self.assertEqual((info["kurulu"], info["kurulu_surum"], info["son"], info["son_surum"], info["yeni"]),
                         (OLD, "1.0.0", NEW, "1.1.0", True))
        # The build number decides: a newer release name on an older build is not offered.
        u = mu.Updates(Fetcher(version=OLD, surum="9.0.0"), Clock())
        self.assertFalse(u.status(dict(self.env, OBHUT_SURUM="1.0.0"), False)["yeni"])
        for bad in ("1.0", "v1.0.0", "1.0.0-beta", "1.0.0\nx", "1.0.0\n", "12345.0.0"):
            with self.subTest(bad=bad):
                self.assertEqual(mu.Updates(Fetcher(surum=bad), Clock()).status(dict(self.env, OBHUT_SURUM=bad), False)
                                 ["kurulu_surum"], "")
                self.assertIsNone(mu.Updates(Fetcher(surum=bad), Clock()).status(self.env, False)["son_surum"])

    def test_same_or_older_or_unknown_installed_version_is_not_offered_blindly(self):
        for installed, expected in [(NEW, False), ("2026.08.06-v2-213", False), ("test", False), (OLD, True)]:
            self.u.cache = None
            self.assertEqual(self.u.status(env_for(self.root, installed), False)["yeni"], expected, installed)

    def test_answers_are_cached_and_failures_back_off(self):
        self.u.status(self.env, False)
        self.u.status(self.env, False)
        self.assertEqual(len(self.fetch.calls), 2)
        self.clock.t += mu.CHECK_SECONDS + 1
        self.fetch.fail = OSError("down")
        info = self.u.status(self.env, False)
        self.assertEqual((info["yeni"], info["son"]), (False, None))
        self.assertIn("GitHub", info["hata"])
        calls = len(self.fetch.calls)
        self.clock.t += mu.FAIL_SECONDS - 1
        self.u.status(self.env, False)
        self.assertEqual(len(self.fetch.calls), calls)
        self.clock.t += 2
        self.fetch.fail = None
        self.assertTrue(self.u.status(self.env, False)["yeni"])

    def test_forced_check_is_limited_to_once_a_minute(self):
        self.u.status(self.env, False)
        self.clock.t += 1
        self.u.status(self.env, False, force=True)
        self.assertEqual(len(self.fetch.calls), 4)
        self.clock.t += 1
        self.u.status(self.env, False, force=True)
        self.assertEqual(len(self.fetch.calls), 4)
        self.clock.t += mu.FORCE_GAP_SECONDS
        self.u.status(self.env, False, force=True)
        self.assertEqual(len(self.fetch.calls), 6)

    def test_malformed_answers_are_failures(self):
        for sha, version in [("not-a-sha", NEW), (SHA, "bozuk"), (SHA, '1"\nV2_VERSION="x')]:
            self.u.cache, self.fetch.sha, self.fetch.version = None, sha, version
            info = self.u.status(self.env, False)
            self.assertFalse(info["yeni"])
            self.assertIsNone(info["commit"])
            self.assertTrue(info["hata"])

    def test_without_a_repository_nothing_is_fetched(self):
        for key, value in [("GUNCELLEME_REPO", ""), ("GUNCELLEME_REPO", "../x"), ("GUNCELLEME_DAL", "a/../b")]:
            env = dict(self.env, **{key: value})
            info = self.u.status(env, False)
            self.assertFalse(info["yeni"])
            self.assertIn("kurulumu", info["hata"])
        self.assertEqual(self.fetch.calls, [])

    def test_job_state_and_stage(self):
        self.assertEqual(self.u.job(self.env, False)["durum"], "yok")
        status = self.root / "guncelleme.durum"
        status.write_text("durum=calisiyor\nhedef=%s\ncommit=%s\nbaslangic=5\n" % (NEW, SHA))
        log = self.root / "guncelleme.log"
        log.write_text("==> indiriliyor\n")
        job = self.u.job(self.env, True)
        self.assertEqual((job["durum"], job["asama"], job["hedef"]), ("calisiyor", "İndiriliyor", NEW))
        log.write_text("[10:00:00] Aşama 0/7 — kapılar ve girdi\n[10:01:00] Aşama 3/7 — servisler\n")
        self.assertEqual(self.u.job(self.env, True)["asama"], "Aşama 3/7 — servisler")
        # The unit is gone without a result (reboot, killed run).
        job = self.u.job(self.env, False)
        self.assertEqual(job["durum"], "hata")
        self.assertIn("yarıda", job["mesaj"])
        status.write_text("durum=hata\nhedef=%s\nbitis=9\nmesaj=Tailscale oturumu açık değil\n" % NEW)
        job = self.u.job(self.env, False)
        self.assertEqual((job["durum"], job["mesaj"], job["bitis"]), ("hata", "Tailscale oturumu açık değil", 9))
        status.write_text("durum=tamam\nhedef=%s\nbitis=9\nmesaj=eski\n" % NEW)
        self.assertEqual(self.u.job(self.env, False)["mesaj"], "")
        status.write_text("durum=bilinmez\n")
        self.assertEqual(self.u.job(self.env, False)["durum"], "yok")

    def test_start_rules(self):
        offer = {"surum": NEW, "commit": SHA}
        with self.assertRaises(mu.UpdateError) as err:
            self.u.check_start(self.env, offer, True, "")
        self.assertEqual(err.exception.status, 409)
        with self.assertRaises(mu.UpdateError) as err:
            self.u.check_start(self.env, offer, False, "Konsol'da bekleyen bir ayar işlemi var")
        self.assertEqual((err.exception.status, str(err.exception)), (409, "Konsol'da bekleyen bir ayar işlemi var"))
        for bad in [{}, {"surum": NEW}, {"surum": NEW, "commit": "f" * 40}, {"surum": "2026.08.06-v2-999", "commit": SHA}]:
            with self.assertRaises(mu.UpdateError, msg=bad):
                self.u.check_start(self.env, bad, False, "")
        self.assertEqual(self.u.check_start(self.env, offer, False, ""), (SHA, NEW))
        with self.assertRaises(mu.UpdateError):
            self.u.check_start(env_for(self.root, NEW), offer, False, "")


class GenerationTests(unittest.TestCase):
    """DD-271 (S3): only a build of the host's own generation is an update; another generation needs a
    clean install. The remote generation is install.sh's OBHUT_NESIL (absent: 1), the local one state.env's."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.env = env_for(self.root)
        self.offer = {"surum": NEW, "commit": SHA}

    def check(self, env, **remote):
        u = mu.Updates(Fetcher(**remote), Clock())
        info = u.status(env, False)
        return u, info

    def refused(self, u, env):
        with self.assertRaises(mu.UpdateError) as err:
            u.check_start(env, self.offer, False, "")
        self.assertEqual(err.exception.status, 409)

    def test_a_newer_build_of_the_same_generation_is_offered(self):
        u, info = self.check(self.env, nesil="2")
        self.assertEqual((info["son"], info["commit"], info["yeni"], info["hata"]), (NEW, SHA, True, ""))
        self.assertEqual(u.latest(self.env)["nesil"], 2)
        self.assertEqual(u.check_start(self.env, self.offer, False, ""), (SHA, NEW))
        # The generation must match, not be a fixed number.
        env = dict(self.env, OBHUT_NESIL="3")
        u, info = self.check(env, nesil="3")
        self.assertTrue(info["yeni"])
        # The same generation without a newer build is still not an update.
        u, info = self.check(self.env, nesil="2", version=OLD)
        self.assertEqual((info["yeni"], info["hata"]), (False, ""))

    def test_a_remote_without_the_line_is_generation_one_and_never_offered(self):
        for extra in ("", 'OBHUT_NESIL=2\n', 'OBHUT_NESIL="0"\n', 'OBHUT_NESIL="02"\n', '# OBHUT_NESIL="2"\n'):
            with self.subTest(extra=extra):
                u, info = self.check(self.env, nesil=None, extra=extra)
                self.assertEqual(u.latest(self.env)["nesil"], 1)
                self.assertEqual((info["son"], info["commit"], info["yeni"]), (NEW, SHA, False))
                self.assertIn("başka bir nesilden (1)", info["hata"])
                self.assertIn("temiz", info["hata"])
                self.refused(u, self.env)

    def test_another_generation_is_never_offered(self):
        for remote in ("1", "3", "10"):
            with self.subTest(remote=remote):
                u, info = self.check(self.env, nesil=remote, version="2026.08.06-v2-999")
                self.assertFalse(info["yeni"])
                self.assertIn("başka bir nesilden (%s)" % remote, info["hata"])
                self.assertIn("temiz bir işletim sistemine", info["hata"])
                self.refused(u, self.env)

    def test_a_host_without_a_generation_is_never_offered(self):
        for local in (None, "", "0", "02", "x", "1000", "2 "):
            with self.subTest(local=local):
                env = dict(self.env)
                if local is None:
                    del env["OBHUT_NESIL"]
                else:
                    env["OBHUT_NESIL"] = local
                u, info = self.check(env, nesil="2")
                self.assertFalse(info["yeni"])
                self.assertIn("nesil yok", info["hata"])
                self.refused(u, env)

    def test_an_unreachable_github_keeps_its_own_message(self):
        u = mu.Updates(Fetcher(), Clock())
        u.fetcher.fail = OSError("down")
        info = u.status(self.env, False)
        self.assertFalse(info["yeni"])
        self.assertIn("GitHub", info["hata"])
        self.assertNotIn("nesil", info["hata"])
        self.assertIsNone(u.latest(self.env)["nesil"])
        self.assertIsNone(mu.Updates(Fetcher(), Clock()).latest(dict(self.env, GUNCELLEME_REPO=""))["nesil"])


class PanelStartTests(unittest.TestCase):
    """update_start → systemd-run with the pinned commit and version, after the busy checks."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.bin = self.root / "sbin"
        self.bin.mkdir()
        self.active = self.bin / "active"
        self.active.write_text("")
        for name, body in {
            "systemd-run": 'printf "%s\\n" "$*" >> "$(dirname "$0")/calls"',
            # list-units prints the units named in the "active" file that match the pattern.
            "systemctl": 'for u in $(cat "$(dirname "$0")/active"); do case "$u" in $(eval echo \\${$#})) echo "$u loaded active running x";; esac; done'}.items():
            path = self.bin / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        self.pending = self.root / "bekleyen.json"
        env = env_for(self.root)
        env.update(SETTINGS_PENDING_FILE=str(self.pending), SBIN_DIR=str(self.bin))
        self.state = self.root / "state.env"
        self.state.write_text("".join("%s=%s\n" % kv for kv in env.items()))
        self.p = panel.Panel(types.SimpleNamespace(state=str(self.state), allow_host=["panel.test"], state_env=True))
        self.p.updates = mu.Updates(Fetcher(), Clock())

    def calls(self):
        path = self.bin / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_starts_the_unit_with_the_pinned_commit(self):
        self.assertEqual(self.p.update_start({"surum": NEW, "commit": SHA}), NEW)
        self.assertEqual(self.calls(), ["--unit=master-guncelle.service --collect --quiet --description=Konsol güncellemesi: %s "
                                        "--setenv=STATE_FILE=%s %s uygula %s %s" % (NEW, self.state, self.bin / "master-guncelle", SHA, NEW)])

    def test_refuses_beside_a_running_update_or_a_pending_setting(self):
        for active, pending, word in [("master-guncelle.service", False, "zaten"), ("", True, "bekleyen bir ayar")]:
            self.active.write_text(active)
            if pending:
                self.pending.write_text("{}")
            with self.assertRaises(mu.UpdateError) as err:
                self.p.update_start({"surum": NEW, "commit": SHA})
            self.assertEqual(err.exception.status, 409)
            self.assertIn(word, str(err.exception))
        self.assertEqual(self.calls(), [])

    def test_another_generation_is_not_started(self):
        self.p.updates = mu.Updates(Fetcher(nesil=None), Clock())
        self.assertFalse(self.p.update_info()["yeni"])
        with self.assertRaises(mu.UpdateError) as err:
            self.p.update_start({"surum": NEW, "commit": SHA})
        self.assertEqual(err.exception.status, 409)
        self.assertEqual(self.calls(), [])

    def test_info_reports_the_running_unit(self):
        self.active.write_text("master-guncelle.service")
        (self.root / "guncelleme.durum").write_text("durum=calisiyor\nhedef=%s\n" % NEW)
        self.assertEqual(self.p.update_info()["is"]["durum"], "calisiyor")
        self.active.write_text("")
        self.assertEqual(self.p.update_info()["is"]["durum"], "hata")


class RouteTests(unittest.TestCase):
    """GET reports; POST starts only from the tailnet (or root on the socket)."""

    def setUp(self):
        started = self.started = []

        class FakePanel:
            def update_info(self, force=False):
                return {"yeni": True, "force": force}

            def update_start(self, data):
                started.append(data)
                return NEW

        class Handler(panel.Handler):
            def gate(self):
                return panel.ACTOR

            def channel(self):
                return self.headers.get("X-Test-Kanal", "tailscale")

        Handler.panel = FakePanel()
        _server, self.sock = test_resources.start_unix(self, Handler)

    def request(self, method, path, kanal, body=None):
        headers = {"X-Konsol": "1", "X-Test-Kanal": kanal}
        if body is not None:
            headers["Content-Type"] = "application/json"
        status, _headers, raw = test_resources.unix_get(self.sock, path, headers, method, json.dumps(body) if body is not None else None)
        return status, json.loads(raw)

    def test_get_marks_whether_this_channel_may_start(self):
        self.assertEqual(self.request("GET", "/api/konsol/guncelleme", "tailscale"), (200, {"yeni": True, "force": False, "baslatilabilir": True}))
        self.assertEqual(self.request("GET", "/api/konsol/guncelleme?yenile=1", "internet")[1]["baslatilabilir"], False)
        self.assertEqual(self.request("GET", "/api/konsol/guncelleme?yenile=1", "internet")[1]["force"], True)

    def test_internet_cannot_start(self):
        status, body = self.request("POST", "/api/konsol/guncelleme", "internet", {"surum": NEW, "commit": SHA})
        self.assertEqual(status, 403)
        self.assertIn("Tailscale", body["error"])
        self.assertEqual(self.started, [])
        self.assertEqual(self.request("POST", "/api/konsol/guncelleme", "tailscale", {"surum": NEW, "commit": SHA}), (202, {"surum": NEW}))
        self.assertEqual(self.started, [{"surum": NEW, "commit": SHA}])


if __name__ == "__main__":
    unittest.main()
