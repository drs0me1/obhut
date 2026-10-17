"""DD-233: Konsol's update button backend: the GitHub version check (pinned commit, cache, failure
back-off, forced re-check gap), the comparison with the installed version, the unit's job state
and stage, the start rules, the systemd-run call and the Tailscale-only start route. DD-277: the
remote generation (another one is a clean install, never an update) and master-guncelle's refusal.
Temporary directories, a fake fetcher and fake systemd tools only; no network, no host changes."""
import json
import os
from pathlib import Path
import subprocess
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
    def __init__(self, sha=SHA, version=NEW, surum=None, nesil=None):
        self.sha, self.version, self.surum, self.nesil, self.calls, self.fail = sha, version, surum, nesil, [], None

    def __call__(self, url, accept):
        self.calls.append((url, accept))
        if self.fail:
            raise self.fail
        if url.startswith("https://api.github.com/"):
            return self.sha + "\n"
        text = '#!/usr/bin/env bash\nset -Eeuo pipefail\n\nV2_VERSION="%s"\n' % self.version
        text += '# yorum\nOBHUT_SURUM="%s"\n' % self.surum if self.surum is not None else ""
        return text + ('OBHUT_NESIL="%s"\n' % self.nesil if self.nesil is not None else "")


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def env_for(root, version=OLD):
    return {"V2_VERSION": version, "GUNCELLEME_REPO": "drs0me1/obhut", "GUNCELLEME_DAL": "main",
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

    def test_a_commit_without_a_generation_is_generation_one_and_offered_as_before(self):
        # DD-277: every 1.x commit lacks OBHUT_NESIL; an explicit "1" is the same line.
        for nesil in (None, "1"):
            with self.subTest(nesil=nesil):
                u = mu.Updates(Fetcher(nesil=nesil), Clock())
                info = u.status(self.env, False)
                self.assertEqual((info["yeni"], info["yeni_nesil"], info["hata"]), (True, None, ""))
                self.assertEqual(u.check_start(self.env, {"surum": NEW, "commit": SHA}, False, ""), (SHA, NEW))

    def test_another_generation_is_a_clean_install_never_an_update(self):
        # DD-277: a newer build of generation 2 is shown, not offered, and the start route refuses it.
        u = mu.Updates(Fetcher(version="2026.08.06-v2-300", surum="2.0.0", nesil="2"), Clock())
        info = u.status(self.env, False)
        self.assertEqual((info["son"], info["son_surum"], info["commit"], info["yeni"], info["hata"]),
                         ("2026.08.06-v2-300", "2.0.0", SHA, False, ""))
        self.assertEqual(info["yeni_nesil"], {"nesil": 2, "metin": mu.YENI_NESIL_METNI})
        for word in ("yeni bir nesli", "temiz bir işletim sistemine", "güncelleme olarak gelmez", "hiçbir şey değişmez",
                     "yedekleyin", "kur.sh"):
            self.assertIn(word, mu.YENI_NESIL_METNI)
        with self.assertRaises(mu.UpdateError) as err:
            u.check_start(self.env, {"surum": "2026.08.06-v2-300", "commit": SHA}, False, "")
        self.assertEqual((err.exception.status, str(err.exception)), (409, mu.YENI_NESIL_METNI))
        # Even an older build number of another generation is reported, not compared.
        u = mu.Updates(Fetcher(version=OLD, nesil="3"), Clock())
        self.assertEqual(u.status(env_for(self.root, NEW), False)["yeni_nesil"]["nesil"], 3)

    def test_another_generation_is_reported_whatever_its_build_number_looks_like(self):
        # A later generation may number its builds differently; it still needs a clean install.
        for version in ("3.0.0", "2026.08.06-v3-1"):
            with self.subTest(version=version):
                info = mu.Updates(Fetcher(version=version, nesil="2"), Clock()).status(self.env, False)
                self.assertEqual((info["son"], info["yeni"], info["hata"], info["yeni_nesil"]["nesil"]), (None, False, "", 2))
        # The same line with such a number is still a failed read.
        info = mu.Updates(Fetcher(version="3.0.0"), Clock()).status(self.env, False)
        self.assertEqual((info["yeni"], info["yeni_nesil"]), (False, None))
        self.assertIn("GitHub", info["hata"])

    def test_a_malformed_generation_line_counts_as_absent(self):
        # Read exactly as the generation-2 module reads it; master-guncelle refuses such a target itself.
        for line in ('OBHUT_NESIL=2', 'OBHUT_NESIL="0"', 'OBHUT_NESIL="2" # x', ' OBHUT_NESIL="2"', 'OBHUT_NESIL="1234"'):
            with self.subTest(line=line):
                fetch = Fetcher()
                fetch_text = fetch.__call__

                def fetcher(url, accept, fetch_text=fetch_text, line=line):
                    out = fetch_text(url, accept)
                    return out if url.startswith("https://api.github.com/") else out + line + "\n"

                info = mu.Updates(fetcher, Clock()).status(self.env, False)
                self.assertEqual((info["yeni"], info["yeni_nesil"]), (True, None))

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
            self.u.check_start(self.env, offer, False, "Bir uygulama işlemi sürüyor")
        self.assertEqual(str(err.exception), "Bir uygulama işlemi sürüyor")
        for bad in [{}, {"surum": NEW}, {"surum": NEW, "commit": "f" * 40}, {"surum": "2026.08.06-v2-999", "commit": SHA}]:
            with self.assertRaises(mu.UpdateError, msg=bad):
                self.u.check_start(self.env, bad, False, "")
        self.assertEqual(self.u.check_start(self.env, offer, False, ""), (SHA, NEW))
        with self.assertRaises(mu.UpdateError):
            self.u.check_start(env_for(self.root, NEW), offer, False, "")


class UpdaterGenerationTests(unittest.TestCase):
    """DD-277: master-guncelle reads the target's install.sh before its kur.sh and refuses another
    generation. A fake `id` stands in for root; the downloads are file:// URLs (KUR_KURULUM_URL,
    KUR_BETIK_URL), so nothing reaches the network or the host."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake_id = self.bin / "id"
        fake_id.write_text('#!/bin/sh\n[ "$1" = "-u" ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n')
        fake_id.chmod(0o755)
        self.status, self.log, self.ran = self.root / "log" / "guncelleme.durum", self.root / "log" / "guncelleme.log", self.root / "ran"
        self.state = self.root / "state.env"
        self.state.write_text("GUNCELLEME_REPO=drs0me1/obhut\nGUNCELLEME_DURUM_FILE=%s\nGUNCELLEME_LOG_FILE=%s\n" % (self.status, self.log))
        (self.root / "kur.sh").write_text('touch "%s"\necho "ref=$KUR_REF surum=$KUR_GUNCELLE"\n' % self.ran)

    def run_tool(self, install_text):
        install = self.root / "install.sh"
        if install_text is None:
            install.unlink(missing_ok=True)
        else:
            install.write_text(install_text)
        env = dict(os.environ, PATH="%s:%s" % (self.bin, os.environ["PATH"]), STATE_FILE=str(self.state),
                   KUR_KURULUM_URL="file://%s" % install, KUR_BETIK_URL="file://%s" % (self.root / "kur.sh"))
        proc = subprocess.run(["bash", str(ROOT / "scripts" / "master-guncelle"), "uygula", SHA, NEW], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        state = dict(line.split("=", 1) for line in self.status.read_text().splitlines())
        return proc.returncode, state

    def test_generation_one_targets_run_their_kur_sh(self):
        for text in ('V2_VERSION="%s"\n' % NEW, 'V2_VERSION="%s"\nOBHUT_NESIL="1"\n' % NEW):
            with self.subTest(text=text):
                self.ran.unlink(missing_ok=True)
                rc, state = self.run_tool(text)
                self.assertEqual((rc, state["durum"]), (0, "tamam"))
                self.assertTrue(self.ran.exists())
                self.assertIn("ref=%s surum=%s" % (SHA, NEW), self.log.read_text())

    def test_another_generation_stops_before_kur_sh(self):
        for line in ('OBHUT_NESIL="2"', 'OBHUT_NESIL=2', 'OBHUT_NESIL="1" # x', 'OBHUT_NESIL="10"', '  OBHUT_NESIL="2"',
                     'OBHUT_NESIL="1"\nOBHUT_NESIL="2"'):
            with self.subTest(line=line):
                rc, state = self.run_tool('V2_VERSION="%s"\n%s\n' % (NEW, line))
                self.assertNotEqual(rc, 0)
                self.assertFalse(self.ran.exists(), "kur.sh never ran")
                self.assertEqual((state["durum"], state["hedef"], state["commit"]), ("hata", NEW, SHA))
                self.assertTrue(state["mesaj"].startswith("Hedef sürüm Obhut'un yeni neslinden; yalnız temiz bir işletim sistemine kurulur"))
                self.assertTrue(state["mesaj"].endswith("Bu sunucuda hiçbir şey değişmedi."))

    def test_an_unreadable_target_is_refused_too(self):
        rc, state = self.run_tool(None)
        self.assertNotEqual(rc, 0)
        self.assertFalse(self.ran.exists())
        self.assertEqual(state["durum"], "hata")
        self.assertEqual(state["mesaj"], "Hedef sürümün kurulum betiği indirilemedi; bu sunucuda hiçbir şey değişmedi.")


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
            "systemctl": 'for u in $(cat "$(dirname "$0")/active"); do case "$u" in $(eval echo \\${$#})) echo "$u loaded active running x";; esac; done',
            "master-modul": "exit 0"}.items():
            path = self.bin / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        self.pending = self.root / "bekleyen.json"
        env = env_for(self.root)
        env.update(SETTINGS_PENDING_FILE=str(self.pending))
        self.state = self.root / "state.env"
        self.state.write_text("".join("%s=%s\n" % kv for kv in env.items()))
        self.p = panel.Panel(types.SimpleNamespace(state=str(self.state), allow_host=["panel.test"], state_env=True,
                                                   master_modul=str(self.bin / "master-modul")))
        self.p.updates = mu.Updates(Fetcher(), Clock())

    def calls(self):
        path = self.bin / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_starts_the_unit_with_the_pinned_commit(self):
        self.assertEqual(self.p.update_start({"surum": NEW, "commit": SHA}), NEW)
        self.assertEqual(self.calls(), ["--unit=master-guncelle.service --collect --quiet --description=Konsol güncellemesi: %s "
                                        "--setenv=STATE_FILE=%s %s uygula %s %s" % (NEW, self.state, self.bin / "master-guncelle", SHA, NEW)])

    def test_refuses_beside_a_running_update_a_package_operation_or_a_pending_setting(self):
        for active, pending, word in [("master-guncelle.service", False, "zaten"), ("master-modul-torrent.service", False, "uygulama"),
                                      ("", True, "bekleyen bir ayar")]:
            self.active.write_text(active)
            if pending:
                self.pending.write_text("{}")
            with self.assertRaises(mu.UpdateError) as err:
                self.p.update_start({"surum": NEW, "commit": SHA})
            self.assertIn(word, str(err.exception))
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
