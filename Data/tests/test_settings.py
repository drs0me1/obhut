"""Settings worker tests: no root, services or networking required."""
import base64
import contextlib
import copy
import fcntl
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# status() and the publication rows import their siblings (master_https, master_publications).
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
SPEC = importlib.util.spec_from_file_location("master_settings", Path(__file__).resolve().parents[1] / "panel/master_settings.py")
settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(settings)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="settings-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {
            "SETTINGS_FILE": str(self.root / "settings.json"), "SETTINGS_PENDING_FILE": str(self.root / "pending.json"),
            "SETTINGS_DNS_FILE": str(self.root / "dns/konsol.conf"), "DNSMASQ_CONF_FILE": str(self.root / "dns/base.conf"),
            "DNSMASQ_CONF_DIR": str(self.root / "dns"), "UNIT_DIR": str(self.root / "units"),
            "SHARE_CADDY_SOURCE": str(self.root / "share/paylasim.caddy"), "RUNTIME_DIR": str(self.root / "run"),
            "SERVER_ROOT": str(self.root / "srv"), "DOWNLOADS_PATH": str(self.root / "srv/downloads"), "MEDIA_SUBDIR": "media",
            "LOCAL_DOMAIN": "ayc", "TAILSCALE_IF": "tailscale0", "WAN_INTERFACE": "eth0", "WAN_IPV4": "203.0.113.1",
            "TAILSCALE_IPV4": "100.64.0.2", "DOWNLOADS_UID": str(os.getuid()), "DOWNLOADS_GID": str(os.getgid()),
            "SBIN_DIR": str(self.root / "bin"), "DNS_PORT": "53", "CADDY_HTTP_PORT": "80",
            "CADDYFILE": str(self.root / "Caddyfile"), "CADDY_MODULES_DIR": str(self.root / "caddy-modules"),
        }
        for rel in ("dns", "share", "srv/downloads", "srv/media/movies", "srv/.cop", "units", "run"):
            (self.root / rel).mkdir(parents=True, exist_ok=True)
        (self.root / "dns/base.conf").write_text("interface=lo\ninterface=tailscale0\nno-resolv\nlocal=/ayc/\ninterface-name=panel.ayc,tailscale0\ninterface-name=health.ayc,tailscale0\n")
        self.state = self.root / "state.env"
        self.state.write_text("".join(k + "=" + v + "\n" for k, v in self.env.items()))
        self.m = settings.Manager(self.state)
        self.now = 1000
        self.calls = []
        self.fail_cmd = None
        self.addCleanup(patch.stopall)
        patch.object(settings, "boot_id", return_value="boot-a").start()
        patch.object(settings.time, "monotonic", side_effect=lambda: self.now).start()
        patch.object(settings, "run", side_effect=self.fake_run).start()

    def fake_run(self, argv, **kwargs):
        self.calls.append(argv)
        if self.fail_cmd and self.fail_cmd in " ".join(argv):
            self.fail_cmd = None
            raise settings.SettingsError("injected failure")
        return subprocess.CompletedProcess(argv, 0, "", "")

    def payload(self, **kwargs):
        return dict(revision=self.m.revision(), **kwargs)

    def rule(self, **kwargs):
        return dict(dict(id="one", name="Test port", family=4, scope="wan", proto="tcp", port=12345, source="", allow=True), **kwargs)

    def dns(self, **kwargs):
        return dict(copy.deepcopy(settings.DEFAULT["dns"]), **kwargs)

    def confirm(self):
        return self.m.confirm({"id": self.m.pending()["id"], "client": "100.64.0.9", "kanal": "tailscale"})


class SettingsTests(Fixture):
    def test_defaults_and_no_secrets_in_status(self):
        s = self.m.status()
        self.assertEqual(s["config"], settings.DEFAULT)
        # DD-202: the base's status knows no application account or folder.
        self.assertFalse({"username", "save"} & set(s), sorted(s))

    def test_stale_revision_and_external_dns_change(self):
        data = self.payload(firewall=[])
        base = Path(self.env["DNSMASQ_CONF_FILE"])
        base.write_text(base.read_text() + "# changed outside the transaction\n")
        with self.assertRaises(settings.SettingsError):
            self.m.validate(data)
        self.assertFalse(self.m.pending_path.exists())

    def test_firewall_validation(self):
        invalid = [dict(port=0), dict(port=True), dict(port=65536), dict(proto="tcp;id"), dict(scope="lo"),
                   dict(source="1.2.3.4;id"), dict(source="::1/128"), dict(family="4"), dict(id="x y"), dict(allow="yes"), dict(scope="wg9")]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(settings.SettingsError):
                self.m.validate(self.payload(firewall=[self.rule(**change)]))
        with self.assertRaises(settings.SettingsError):
            self.m.validate(self.payload(firewall=[self.rule(), self.rule(id="two")]))

    def test_rules_normalize_source_and_live_wan(self):
        self.m.apply(self.payload(firewall=[self.rule(source="192.0.2.18/24"), self.rule(id="ipv6", family=6, scope="tail", source="2001:db8::/32", allow=False)]))
        args = self.m.rules(4, "ens3")[0]
        self.assertIn("ens3", args)
        self.assertIn("192.0.2.0/24", args)
        self.assertEqual(self.m.rules(6)[0][-1], "DROP")
        self.assertEqual(self.m.rules(6)[0][1], "tailscale0")

    def test_apply_confirm_is_persistent(self):
        self.m.apply(self.payload(firewall=[self.rule()]))
        self.assertEqual(self.m.config()["firewall"], [])
        self.assertEqual(self.m.pending()["phase"], "awaiting")
        self.assertEqual(self.m.pending_path.stat().st_mode & 0o777, 0o600)
        self.confirm()
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.m.config()["firewall"], [self.rule()])
        self.assertEqual(self.m.config_path.stat().st_mode & 0o777, 0o600)

    def test_deadline_and_reboot_rollback(self):
        for reboot in (False, True):
            self.m.apply(self.payload(firewall=[self.rule()]))
            if reboot:
                with patch.object(settings, "boot_id", return_value="boot-b"):
                    self.assertEqual(self.m.current()["firewall"], [])
                    self.m.guard()
            else:
                self.now += 61
                with self.assertRaises(settings.SettingsError):
                    self.confirm()
                self.m.guard()
            self.assertIsNone(self.m.pending())
            self.assertEqual(self.m.current()["firewall"], [])

    def test_pending_blocks_second_apply(self):
        self.m.apply(self.payload(firewall=[self.rule()]))
        with self.assertRaises(settings.SettingsError):
            self.m.apply(self.payload(firewall=[]))

    def test_forged_id_or_local_confirm_rejected(self):
        self.m.apply(self.payload(firewall=[]))
        for data in ({"id": "wrong", "client": "100.64.0.9"}, {"id": self.m.pending()["id"], "client": "127.0.0.1"}):
            with self.assertRaises(settings.SettingsError):
                self.m.confirm(data)

    def test_existing_tcp_connection_is_not_connectivity_proof(self):
        self.m.apply(self.payload(firewall=[self.rule(scope="tail", port=80, allow=False)]))
        with self.assertRaises(settings.SettingsError):
            self.confirm()
        self.m.rollback()
        self.m.apply(self.payload(firewall=[self.rule(scope="tail", port=80, source="100.64.0.20/32", allow=False)]))
        self.confirm()

    def test_plan_changes_nothing_and_says_what_apply_would_do(self):
        """DD-265: the plan runs apply's checks on a copy; no file, lock, timer or service is touched."""
        data = self.payload(firewall=[self.rule(source="192.0.2.18/24")])
        before = sorted(p.name for p in self.root.rglob("*"))
        plan = self.m.plan(data, client="100.64.0.9", kanal="tailscale")
        self.assertEqual(self.calls, [], "no systemctl, no service")
        self.assertEqual(sorted(p.name for p in self.root.rglob("*")), before, "no lock, pending or config file")
        self.assertEqual(data["firewall"][0]["source"], "192.0.2.18/24", "the caller's request is not normalised in place")
        self.assertEqual(plan["onay_sn"], 60)
        self.assertTrue(plan["uygulanabilir"])
        self.assertEqual(plan["degisiklikler"], [{"alan": "guvenlik-duvari", "islem": "ekle", "nesne": "Test port", "once": None,
                                                  "sonra": "TCP 12345 · İnternet · IPv4 · yalnız 192.0.2.0/24 · izin"}])
        self.assertIn("Güvenlik duvarı kuralları yeniden kurulur.", plan["etkiler"])
        self.assertEqual(plan["revizyon"], data["revision"])
        # The same request applies, with the window the plan named.
        self.m.apply(data)
        self.assertEqual(self.m.pending()["until"], self.now + 60)

    def test_plan_raises_what_apply_raises_and_refuses_an_empty_change(self):
        for data in (self.payload(firewall=[self.rule(port=0)]), {"revision": "stale", "firewall": []}):
            with self.subTest(data=data):
                with self.assertRaises(settings.SettingsError) as plan_err:
                    self.m.plan(copy.deepcopy(data))
                with self.assertRaises(settings.SettingsError) as apply_err:
                    self.m.apply(copy.deepcopy(data))
                self.assertEqual(str(plan_err.exception), str(apply_err.exception))
        with self.assertRaisesRegex(settings.SettingsError, "Değişiklik yok"):
            self.m.plan(self.payload(firewall=[]))
        self.m.apply(self.payload(firewall=[self.rule()]))
        with self.assertRaisesRegex(settings.SettingsError, "bekleyen"):
            self.m.plan(self.payload(firewall=[]))

    def test_plan_names_changed_and_removed_rules_and_a_change_that_cannot_be_confirmed(self):
        self.m.apply(self.payload(firewall=[self.rule(), self.rule(id="two", port=2222)]))
        self.confirm()
        plan = self.m.plan(self.payload(firewall=[self.rule(allow=False), self.rule(id="three", name="Yeni", port=3333)]),
                           client="100.64.0.9", kanal="internet")
        self.assertEqual([(i["islem"], i["nesne"]) for i in plan["degisiklikler"]],
                         [("degistir", "Test port"), ("ekle", "Yeni"), ("kaldir", "Test port")])
        self.assertEqual(plan["degisiklikler"][0]["sonra"], "TCP 12345 · İnternet · IPv4 · engel")
        self.assertFalse(plan["uygulanabilir"], "a timed change is confirmed only over Tailscale")
        self.assertIn("bad", [w["seviye"] for w in plan["uyarilar"]])
        # A Tailscale rule that shuts this client out of Konsol can never be confirmed.
        blocked = self.m.plan(self.payload(firewall=[self.rule(scope="tail", port=80, allow=False)]),
                              client="100.64.0.9", kanal="tailscale")
        self.assertFalse(blocked["uygulanabilir"])
        other = self.m.plan(self.payload(firewall=[self.rule(scope="tail", port=80, source="100.64.0.20/32", allow=False)]),
                            client="100.64.0.9", kanal="tailscale")
        self.assertTrue(other["uygulanabilir"])

    def test_plan_of_dns_and_domain_changes(self):
        dns = self.dns(disabled=["health.ayc"], records=[{"name": "nas.ayc", "target": "192.0.2.5", "enabled": True}],
                       forward=True, servers=["9.9.9.9"])
        plan = self.m.plan(self.payload(dns=dns))
        self.assertEqual(plan["onay_sn"], 0, "DNS alone commits at once")
        self.assertEqual([(i["alan"], i["islem"], i["nesne"]) for i in plan["degisiklikler"]],
                         [("dns", "kapat", "health.ayc"), ("dns", "ekle", "nas.ayc"), ("dns", "degistir", "Dış adlar")])
        self.assertEqual(plan["degisiklikler"][2]["sonra"], "Üst DNS: 9.9.9.9")
        Path(self.env["CADDYFILE"]).write_text("http://panel.ayc {\n}\n")
        plan = self.m.plan(self.payload(domain="ev"), client="100.64.0.9", kanal="tailscale")
        self.assertEqual(plan["onay_sn"], 300)
        self.assertEqual(plan["degisiklikler"], [{"alan": "alan-adi", "islem": "degistir", "nesne": "Yerel alan adı",
                                                  "once": "ayc", "sonra": "ev"}])
        self.assertTrue(any("http://panel.ev" in w["metin"] for w in plan["uyarilar"]))
        self.assertEqual(self.calls, [])

    def test_disable_panel_is_rejected_before_mutation(self):
        before = Path(self.env["DNSMASQ_CONF_FILE"]).read_bytes()
        for extra in ({}, {"firewall": []}):
            with self.subTest(extra=extra), self.assertRaises(settings.SettingsError):
                self.m.apply(self.payload(dns=self.dns(disabled=["panel.ayc"]), **extra))
        self.assertEqual(before, Path(self.env["DNSMASQ_CONF_FILE"]).read_bytes())
        self.assertIsNone(self.m.pending())
        self.assertFalse(self.m.config_path.exists())
        self.assertEqual(self.calls, [])

    def test_dns_only_commits_immediately_and_survives_deadline_and_reboot(self):
        dns = self.dns(disabled=["health.ayc"])
        result = self.m.apply(self.payload(dns=dns))
        self.assertEqual(result, {"pending": None, "committed": True})
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.m.config_path.stat().st_mode & 0o777, 0o600)
        self.now += 181
        with patch.object(settings, "boot_id", return_value="boot-b"):
            recovered = settings.Manager(self.state)
            recovered.guard()
            self.assertEqual(recovered.current()["dns"], dns)
        self.assertEqual(self.m.config()["firewall"], [])
        self.assertIn(["systemctl", "restart", "dnsmasq"], self.calls)

    def test_mixed_dns_keeps_confirmation_even_with_unchanged_firewall(self):
        for extra in ({"firewall": []},):
            with self.subTest(extra=extra):
                self.m.apply(self.payload(dns=self.dns(disabled=["health.ayc"]), **extra))
                self.assertEqual(self.m.status()["pending"]["seconds"], 60)
                self.assertEqual(self.m.config()["dns"], settings.DEFAULT["dns"])
                self.now += 61
                self.m.guard()
                self.assertEqual(self.m.current()["dns"], settings.DEFAULT["dns"])

    def test_dns_restart_or_commit_failure_restores_previous_config(self):
        self.m.apply(self.payload(dns=self.dns(records=[dict(name="nas.ayc", target="tailscale", enabled=True)])))
        before = self.m.config()
        for failure in ("restart", "commit"):
            with self.subTest(failure=failure):
                if failure == "restart":
                    self.fail_cmd = "restart dnsmasq"
                    with self.assertRaises(settings.SettingsError):
                        self.m.apply(self.payload(dns=self.dns(disabled=["health.ayc"])))
                else:
                    with patch.object(self.m, "commit", side_effect=OSError("disk failure")), self.assertRaises(OSError):
                        self.m.apply(self.payload(dns=self.dns(disabled=["health.ayc"])))
                self.assertIsNone(self.m.pending())
                self.assertEqual(self.m.config(), before)
                self.assertIn("interface-name=nas.ayc", self.m.dns_file.read_text())

    def test_dns_crash_recovery_before_and_after_durable_commit(self):
        for committed in (False, True):
            with self.subTest(committed=committed):
                dns = self.dns(disabled=["health.ayc"])
                def crash(p):
                    if committed:
                        settings.save_json(self.m.config_path, dict(p["candidate"], _transaction=p["id"]))
                    raise SystemExit("simulated process death")
                with patch.object(self.m, "commit", side_effect=crash), self.assertRaises(SystemExit):
                    self.m.apply(self.payload(dns=dns))
                self.assertEqual(self.m.pending()["phase"], "applying")
                self.now += 181
                self.m.guard()
                self.assertIsNone(self.m.pending())
                self.assertEqual(self.m.config()["dns"], dns if committed else settings.DEFAULT["dns"])

    def test_dns_rejects_client_confirmation_bypass_flag(self):
        with self.assertRaises(settings.SettingsError):
            self.m.apply(self.payload(dns=self.dns(), firewall=[], committed=True))
        self.assertIsNone(self.m.pending())

    def test_dns_projection_survives_rerender_and_private_zone_stays_local(self):
        self.m.apply(self.payload(dns=self.dns(disabled=["health.ayc"], forward=True, servers=["1.1.1.1"],
                         records=[{"name": "nas.ayc", "target": "192.0.2.10", "enabled": True}])))
        base = Path(self.env["DNSMASQ_CONF_FILE"])
        self.assertIn(settings.OFF + "interface-name=health.ayc", base.read_text())
        base.write_text(base.read_text().replace(settings.OFF, ""))
        self.m.project_dns()
        self.assertIn(settings.OFF, base.read_text())
        self.assertIn("local=/ayc/", base.read_text())
        self.assertIn("no-resolv", base.read_text())
        self.assertIn("host-record=nas.ayc,192.0.2.10", self.m.dns_file.read_text())
        self.assertIn("server=1.1.1.1", self.m.dns_file.read_text())
        self.assertEqual(len(self.m.dns_names()), 2)

    def test_dns_invalid_collisions_and_upstream_loops(self):
        for ip in ["127.0.0.1", "100.100.100.100", "192.168.1.1", "::1", "224.0.0.1", "not-an-ip", "1.1.1.1\nserver=evil"]:
            with self.subTest(ip=ip), self.assertRaises(settings.SettingsError):
                self.m.validate(self.payload(dns=self.dns(forward=True, servers=[ip])))
        # WebDAV's name comes from its own DNS file next to the base's.
        (self.root / "dns/modul-paylasim.conf").write_text("interface-name=paylas.ayc,tailscale0/4\n")
        for name in ["panel.ayc", "paylas.ayc"]:
            with self.subTest(name=name), self.assertRaisesRegex(settings.SettingsError, "^Bu DNS adı zaten tanımlı.$"):
                self.m.validate(self.payload(dns=self.dns(records=[{"name": name, "target": "tailscale", "enabled": True}])))
        for name in ["evil.example", "bad..ayc", "-bad.ayc", "*.ayc"]:
            with self.subTest(name=name), self.assertRaises(settings.SettingsError):
                self.m.validate(self.payload(dns=self.dns(records=[{"name": name, "target": "tailscale", "enabled": True}])))
        twice = [{"name": "nas.ayc", "target": "tailscale", "enabled": True}] * 2
        with self.assertRaisesRegex(settings.SettingsError, "^Bu DNS adı zaten tanımlı.$"):
            self.m.validate(self.payload(dns=self.dns(records=twice)))

    def test_apply_failure_restores_dns_and_preserves_pending_on_recovery_failure(self):
        before = Path(self.env["DNSMASQ_CONF_FILE"]).read_bytes()
        self.fail_cmd = "checkconfig"
        # Works on Linux and macOS (the fallback validator is dnsmasq --test).
        with patch.object(self.m, "dns_test", side_effect=[settings.SettingsError("test"), None]):
            with self.assertRaises(settings.SettingsError):
                self.m.apply(self.payload(dns=self.dns(disabled=["health.ayc"])))
        self.assertEqual(before, Path(self.env["DNSMASQ_CONF_FILE"]).read_bytes())
        self.assertIsNone(self.m.pending())

    def test_lock_blocks_mutation(self):
        with self.m.locked():
            with self.assertRaisesRegex(settings.SettingsBusy,
                                        "^Kurulum ya da ayar işlemi sürüyor; biraz sonra yeniden deneyin.$"):
                with self.m.locked():
                    pass
        # The installer's, the settings' and the state file's locks each hold a transaction back; no other is taken.
        for name in ("install.lock", "settings.lock", "state.lock"):
            with self.subTest(lock=name), open(self.root / "run" / name, "a") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(settings.SettingsBusy):
                    with self.m.locked():
                        pass
        self.assertEqual(sorted(p.name for p in (self.root / "run").glob("*.lock")),
                         ["install.lock", "settings.lock", "state.lock"])

    def test_commit_crash_window_does_not_undo_confirmed_transaction(self):
        self.m.apply(self.payload(firewall=[self.rule()]))
        p = self.m.pending()
        settings.save_json(self.m.config_path, dict(p["candidate"], _transaction=p["id"]))
        self.now += 61
        self.m.guard()
        self.assertEqual(self.m.config()["firewall"], [self.rule()])
        self.assertIsNone(self.m.pending())

    def test_recovery_failure_keeps_pending_for_timer_retry(self):
        with patch.object(self.m, "dns_test", side_effect=settings.SettingsError("retry")), self.assertRaises(settings.SettingsError):
            self.m.apply(self.payload(dns=self.dns(disabled=["health.ayc"])))
        self.assertEqual(self.m.pending()["phase"], "rollback")
        self.assertEqual((self.m.pending()["attempts"], self.m.pending()["error"]), (1, "retry"))
        # DD-182: the next automatic attempt waits for the backoff.
        self.m.guard()
        self.assertIsNotNone(self.m.pending())
        self.assertEqual(self.m.status()["pending"]["retry_in"], 15)
        self.now += 15
        self.m.guard()
        self.assertIsNone(self.m.pending())

    def test_rollback_that_keeps_failing_becomes_stuck_and_waits_for_the_operator(self):
        self.m.apply(self.payload(firewall=[self.rule()]))
        self.now += 61
        with patch.object(self.m, "firewall_apply", side_effect=settings.SettingsError("iptables busy")):
            waits = []
            for attempt in range(1, 6):
                with self.assertRaises(settings.SettingsError):
                    self.m.guard()
                p = self.m.pending()
                self.assertEqual(p["attempts"], attempt)
                if attempt < 5:
                    waits.append(p["retry_at"] - self.now)
                    self.now = p["retry_at"]
            self.assertEqual(waits, [15, 30, 60, 120])
            self.assertEqual(self.m.pending()["phase"], "stuck")
            self.assertEqual(self.m.status()["pending"]["error"], "iptables busy")
            calls = len(self.calls)
            self.m.guard()  # no more automatic attempts
            self.assertEqual(len(self.calls), calls)
            with self.assertRaises(settings.SettingsError):
                self.m.rollback(manual=True)  # the operator's retry still runs
            self.assertEqual((self.m.pending()["phase"], self.m.pending()["attempts"]), ("stuck", 6))
        self.m.rollback(manual=True)
        self.assertIsNone(self.m.pending())

    def test_discard_needs_a_stuck_rollback_its_id_and_the_typed_word(self):
        self.m.apply(self.payload(firewall=[self.rule()]))
        p = self.m.pending()
        with self.assertRaises(settings.SettingsError):
            self.m.discard({"id": p["id"], "confirm": "onayla"})  # awaiting, not stuck
        p.update(phase="stuck", attempts=5, error="x")
        settings.save_json(self.m.pending_path, p)
        for data in ({"id": p["id"]}, {"id": p["id"], "confirm": "evet"}, {"id": "other", "confirm": "onayla"}):
            with self.assertRaises(settings.SettingsError):
                self.m.discard(data)
            self.assertIsNotNone(self.m.pending())
        self.assertEqual(self.m.discard({"id": p["id"], "confirm": " ONAYLA "}), {"ok": True})
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.m.config()["firewall"], [])  # nothing was committed

    def test_timer_must_be_active_before_any_mutation(self):
        self.fail_cmd = "master-settings-guard.timer"
        with self.assertRaises(settings.SettingsError):
            self.m.apply(self.payload(firewall=[self.rule()]))
        self.assertEqual(self.m.config()["firewall"], [])
        self.assertEqual([c for c in self.calls if "master-settings-guard.timer" not in c], [])
        self.assertIsNone(self.m.pending())

    def test_apply_starts_the_guard_timer_before_the_pending_file(self):
        start = ["systemctl", "start", "master-settings-guard.timer"]
        written = []
        original = settings.save_json
        with patch.object(settings, "save_json", side_effect=lambda *a, **k: (written.append(len(self.calls)), original(*a, **k))):
            self.m.apply(self.payload(firewall=[self.rule()]))
        self.assertIn(start, self.calls)
        self.assertLess(self.calls.index(start), written[0])

    def run_guard(self):
        with patch("sys.argv", ["master_settings.py", "--state", str(self.state), "guard"]), \
                contextlib.redirect_stdout(io.StringIO()):
            settings.main()

    def test_idle_guard_stops_its_timer_only_when_it_holds_the_locks(self):
        stop = ["systemctl", "stop", "--no-block", "master-settings-guard.timer"]
        with open(self.root / "run/settings.lock", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_guard()
        self.assertNotIn(stop, self.calls)
        self.run_guard()
        self.assertIn(stop, self.calls)
        # Something pending: the timer keeps running.
        self.calls.clear()
        self.m.apply(self.payload(firewall=[self.rule()]))
        self.assertIsNotNone(self.m.pending())
        self.run_guard()
        self.assertNotIn(stop, self.calls)
        # DD-182: a stuck rollback waits for the operator, so the timer sleeps too.
        p = self.m.pending()
        p.update(phase="stuck", attempts=5)
        settings.save_json(self.m.pending_path, p)
        self.run_guard()
        self.assertIn(stop, self.calls)

    def test_symlinked_parent_cannot_redirect_root_file_access(self):
        link = self.root / "redirect"
        link.symlink_to(self.root / "dns", target_is_directory=True)
        conf = self.root / "dns" / "base.conf"
        before = conf.read_bytes()
        target = link / conf.name
        with self.assertRaises(OSError):
            settings.atomic(target, "injected")
        with self.assertRaises(OSError):
            self.m.snapshot(target)
        self.assertEqual(before, conf.read_bytes())

    def domain_fixture(self):
        (self.root / "Caddyfile").write_text('(konsol) {\n\treverse_proxy x {\n\t\theader_up Host panel.ayc\n\t}\n}\n'
                                             'http://panel.ayc {\n respond "test"\n}\n# leave /some.ayc unchanged\n')
        (self.root / "caddy-modules").mkdir(exist_ok=True)
        unit = "[Service]\nExecStart=/bin/backend --domain=ayc --version=test\n"
        for rel in ("units/master-files-panel.service", "units/master-sistem-dosya.service"):
            (self.root / rel).write_text(unit)
        site = 'http://paylas.ayc, http://{$TAILSCALE_IPV4}:61010 {\n respond "test"\n}\n'
        # WebDAV's tailnet site: the installer's rendering and the copy Caddy reads.
        Path(self.env["SHARE_CADDY_SOURCE"]).write_text(site)
        (self.root / "caddy-modules/paylasim.caddy").write_text(site)
        (self.root / "dns/modul-paylasim.conf").write_text("interface-name=paylas.ayc,tailscale0/4\n")
        settings.save_json(self.m.config_path, dict(copy.deepcopy(settings.DEFAULT), dns=self.dns(
            disabled=["paylas.ayc"], records=[dict(name="nas.ayc", target="192.0.2.8", enabled=False)],
            forward=True, servers=["1.1.1.1"])))

    def test_domain_migration_templates_names_and_new_host_confirmation(self):
        self.domain_fixture()
        self.m.apply(self.payload(domain="ev"))
        self.assertEqual(self.m.status()["pending"]["domain"], {"old": "ayc", "new": "ev"})
        self.assertEqual(self.m.status()["pending"]["seconds"], 300)
        self.assertEqual(settings.env_read(self.state)["LOCAL_DOMAIN"], "ev")
        self.assertIn("http://panel.ev", (self.root / "Caddyfile").read_text())
        self.assertIn("\t\theader_up Host panel.ev\n", (self.root / "Caddyfile").read_text())
        self.assertIn("/some.ayc", (self.root / "Caddyfile").read_text())
        self.assertIn("http://paylas.ev, http://{$TAILSCALE_IPV4}:61010", (self.root / "caddy-modules/paylasim.caddy").read_text())
        self.assertIn("http://paylas.ev, http://{$TAILSCALE_IPV4}:61010", Path(self.env["SHARE_CADDY_SOURCE"]).read_text())
        self.assertIn("interface-name=paylas.ev,", (self.root / "dns/modul-paylasim.conf").read_text())
        for unit in ("master-files-panel.service", "master-sistem-dosya.service"):
            self.assertIn("--domain=ev ", (self.root / "units" / unit).read_text())
        self.assertIn("local=/ev/", Path(self.env["DNSMASQ_CONF_FILE"]).read_text())
        self.assertEqual(self.m.current()["dns"]["disabled"], ["paylas.ev"])
        self.assertEqual(self.m.current()["dns"]["records"], [dict(name="nas.ev", target="192.0.2.8", enabled=False)])
        self.assertEqual(self.m.current()["dns"]["servers"], ["1.1.1.1"])
        for host in ("panel.ayc", "127.0.0.1", "panel.ev.evil", ""):
            with self.subTest(host=host), self.assertRaises(settings.SettingsError):
                self.m.confirm({"id": self.m.pending()["id"], "client": "100.64.0.9", "host": host, "kanal": "tailscale"})
        # DD-195: the public Konsol site may not confirm, even from a 100.64/10 (CGNAT) address.
        with self.assertRaises(settings.SettingsError):
            self.m.confirm({"id": self.m.pending()["id"], "client": "100.64.0.9", "host": "panel.ev", "kanal": "internet"})
        self.m.confirm({"id": self.m.pending()["id"], "client": "100.64.0.9", "host": "panel.ev", "kanal": "tailscale"})
        self.assertEqual(settings.saved_domain(self.m.config_path), "ev")
        self.assertIn(["systemctl", "reload", "caddy.service"], self.calls)
        self.assertNotIn(["systemctl", "restart", "master-panel.service"], self.calls)

    def test_domain_timeout_restores_files_but_not_new_tailscale_ip(self):
        self.domain_fixture()
        before = {p: p.read_bytes() for p in [*self.m.domain_paths(), *self.m.dns_paths()]}
        self.m.apply(self.payload(domain="ev"))
        self.state.write_text(self.state.read_text().replace("TAILSCALE_IPV4=100.64.0.2", "TAILSCALE_IPV4=100.64.0.3"))
        self.now += 301
        recovered = settings.Manager(self.state)
        recovered.guard()
        self.assertIsNone(recovered.pending())
        self.assertEqual(settings.env_read(self.state)["LOCAL_DOMAIN"], "ayc")
        self.assertEqual(settings.env_read(self.state)["TAILSCALE_IPV4"], "100.64.0.3")
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(settings.saved_domain(self.m.config_path), "")

    def test_domain_failure_reboot_and_committed_crash_recovery(self):
        for reason in ("validator", "reboot", "commit-crash"):
            with self.subTest(reason=reason):
                self.domain_fixture()
                if reason == "validator":
                    self.fail_cmd = "caddy validate"
                    with self.assertRaises(settings.SettingsError):
                        self.m.apply(self.payload(domain="ev"))
                    self.assertEqual(self.m.e["LOCAL_DOMAIN"], "ayc")
                    self.assertIsNone(self.m.pending())
                    continue
                self.m.apply(self.payload(domain="ev"))
                if reason == "commit-crash":
                    p = self.m.pending()
                    settings.save_json(self.m.config_path, dict(p["candidate"], _transaction=p["id"]))
                with patch.object(settings, "boot_id", return_value="new-boot"):
                    settings.Manager(self.state).guard()
                self.assertEqual(settings.env_read(self.state)["LOCAL_DOMAIN"], "ev" if reason == "commit-crash" else "ayc")
                self.m = settings.Manager(self.state)

    def test_domain_validation_revision_and_stopped_file_backend(self):
        self.domain_fixture()
        for value in ("", "AyC", "new.example", "bad;id", "a\nb", "-bad", "bad-", "x" * 64, "ayc", None):
            with self.subTest(value=value), self.assertRaises(settings.SettingsError):
                self.m.validate(self.payload(domain=value))
        with self.assertRaises(settings.SettingsError):
            self.m.validate(self.payload(domain="ev", firewall=[]))
        stale = self.payload(domain="ev")
        (self.root / "Caddyfile").write_text((self.root / "Caddyfile").read_text() + "# external edit\n")
        with self.assertRaises(settings.SettingsError):
            self.m.validate(stale)
        original = self.fake_run
        def inactive(argv, **kwargs):
            if argv == ["systemctl", "is-active", "--quiet", "master-files-panel.service"]:
                return subprocess.CompletedProcess(argv, 3, "", "")
            return original(argv, **kwargs)
        with patch.object(settings, "run", side_effect=inactive):
            self.m.apply(self.payload(domain="ev"))
            self.m.rollback()
        self.assertNotIn(["systemctl", "restart", "master-files-panel.service"], self.calls)

    def test_saved_domain_only_reads_confirmed_value_and_rejects_corruption(self):
        self.assertEqual(settings.saved_domain(self.m.config_path), "")
        settings.save_json(self.m.config_path, dict(copy.deepcopy(settings.DEFAULT), domain="ev"))
        self.assertEqual(settings.saved_domain(self.m.config_path), "ev")
        settings.save_json(self.m.config_path, {"domain": "ev;id"})
        with self.assertRaises(settings.SettingsError):
            settings.saved_domain(self.m.config_path)



NET0 = "wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc::1\tfdcc::/112\t1.1.1.1\tEv ağı"
NET1 = "wg1\t61020\tinet\t10.8.1.1\t10.8.1.0/24\tfdcc::1:1\tfdcc::1:0/112\t9.9.9.9\t"
# A network's private key: it must never reach the pending file.
KEY = "PRIVATE" + "k" * 36 + "="


class WireGuardSectionTests(Fixture):
    """DD-275: WireGuard's access-changing actions through the settings transaction. master-wg is a fake
    that changes the networks file, the stopped marker and the units the way the real tool does; the
    units answer systemctl from self.units ([enabled, active])."""

    def setUp(self):
        super().setUp()
        self.wgdir = self.root / "wireguard"
        self.wgdir.mkdir(mode=0o700)
        self.networks, self.marker = self.wgdir / "networks", self.wgdir / ".durduruldu"
        extra = {"WG_NETWORKS_FILE": str(self.networks), "WG_STOPPED_FILE": str(self.marker), "WG_NETWORKS_MAX": "9",
                 "WG_CONF_DIR": str(self.wgdir), "WG_ADDR_BASE4": "10.8", "SSH_PUBLIC_PORT": "22", "TAILSCALE_UDP_PORT": "41641",
                 "SHARE_PORT": "61010", "FILES_PANEL_PORT": "61009"}
        with self.state.open("a") as fh:
            fh.write("".join(k + "=" + v + "\n" for k, v in extra.items()))
        self.m = settings.Manager(self.state)
        self.networks.write_text(NET0 + "\n")
        (self.wgdir / "wg0.conf").write_text("[Interface]\nPrivateKey = %s\n" % KEY)
        self.units = {"wg0": [True, True]}
        self.tool_calls, self.tool_fail = [], None
        self.original_tool = settings.Manager.wireguard_tool
        patch.object(settings.Manager, "wireguard_tool", autospec=True, side_effect=self.fake_tool).start()

    def fake_run(self, argv, **kwargs):
        if argv[:1] == ["systemctl"] and argv[-1].startswith("wg-quick@"):
            self.calls.append(argv)
            unit = self.units.setdefault(argv[-1][len("wg-quick@"):-len(".service")], [False, False])
            if argv[1] == "disable":
                unit[:] = [False, False]
            rc = {"is-enabled": 0 if unit[0] else 1, "is-active": 0 if unit[1] else 3}.get(argv[1], 0)
            return subprocess.CompletedProcess(argv, rc, "", "")
        return super().fake_run(argv, **kwargs)

    def lines(self):
        return self.networks.read_text().splitlines() if self.networks.exists() else []

    def fake_tool(self, _manager, pending_id, *argv):
        p = json.loads(self.m.pending_path.read_text())
        self.tool_calls.append((list(argv), p["phase"], pending_id == p["id"]))
        if self.tool_fail and self.tool_fail == list(argv):
            return 1, "", "UDP 61020 sunucuda başka bir program tarafından dinleniyor"
        out = ""
        if argv == ("baslat",):
            listed = self.marker.read_text().split()
            self.marker.unlink()
            for iface in listed:
                self.units[iface] = [True, True]
        elif argv == ("durdur",):
            self.marker.write_text("".join(i + "\n" for i, u in sorted(self.units.items()) if u[0]))
            for unit in self.units.values():
                unit[:] = [False, False]
        elif argv[0] == "net-add":
            names = {line.split("\t")[0] for line in self.lines()}
            iface = next("wg%d" % i for i in range(10) if "wg%d" % i not in names)
            row = [iface, argv[1], "inet", "10.8.9.1", "10.8.9.0/24", "fdcc::9:1", "fdcc::9:0/112", argv[2], argv[3]]
            self.networks.write_text("".join(line + "\n" for line in self.lines() + ["\t".join(row)]))
            self.units[iface] = [True, True]
            out = "%s\t%s\n" % (iface, argv[1])
        elif argv[0] == "net-remove":
            self.networks.write_text("".join(line + "\n" for line in self.lines() if not line.startswith(argv[1] + "\t")))
            self.units[argv[1]] = [False, False]
        elif argv[0] == "--if" and argv[2] == "net":
            self.units[argv[1]] = [argv[3] == "ac"] * 2
        return 0, out, ""

    def wg(self, **item):
        return self.payload(wireguard=item)

    def files(self):
        return {p: p.read_bytes() for p in sorted(self.root.rglob("*")) if p.is_file()}

    def test_plan_items_and_the_window_of_every_action(self):
        """Decision 4: an opening waits 60 s, a closing action commits at once. The plan writes nothing and
        runs no tool; it only reads the units."""
        cases = [({"eylem": "durdur"}, 0, [("kapat", "WireGuard", "çalışıyor", "durduruldu")], None),
                 ({"eylem": "ag-kapat", "iface": "wg0"}, 0, [("kapat", "WireGuard ağı wg0 · Ev ağı", "açık", "kapalı")], None),
                 ({"eylem": "ag-kaldir", "iface": "wg0", "onay": "onayla"}, 0,
                  [("kaldir", "WireGuard ağı wg0 · Ev ağı", "UDP 61001 · açık", None), ("kapat", "WireGuard", "açık", "kapalı")], None),
                 ({"eylem": "yeniden-uret", "iface": "wg0", "onay": "onayla"}, 0,
                  [("degistir", "WireGuard ağı wg0 · Ev ağı · sunucu anahtarı", "mevcut anahtar", "yeni anahtar"),
                   ("kaldir", "WireGuard ağı wg0 · Ev ağı · cihazlar", "bütün cihazlar ve profilleri", None)], None),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1 ,9.9.9.9", "label": " Misafir "}}, 60,
                  [("ekle", "WireGuard ağı wg1 · Misafir", None, "UDP 61020 · 10.8.1.0/24 · DNS 1.1.1.1, 9.9.9.9")], None),
                 ({"eylem": "ag-ac", "iface": "wg0"}, 60, [("ac", "WireGuard ağı wg0 · Ev ağı", "kapalı", "açık")], "closed"),
                 ({"eylem": "baslat"}, 60, [("ac", "WireGuard", "durduruldu", "çalışıyor")], "stopped")]
        for item, seconds, items, state in cases:
            with self.subTest(item=item):
                self.units = {"wg0": [False, False] if state else [True, True]}
                if state == "stopped":
                    self.marker.write_text("wg0\n")
                before, self.calls = self.files(), []
                plan = self.m.plan(self.wg(**item), client="100.64.0.9", kanal="tailscale")
                self.assertEqual(self.files(), before, "the plan writes nothing")
                self.assertEqual(self.tool_calls, [], "the plan runs no tool")
                self.assertTrue(all(c[1] in ("is-enabled", "is-active") for c in self.calls), self.calls)
                self.assertEqual(plan["onay_sn"], seconds)
                self.assertEqual([(i["islem"], i["nesne"], i["once"], i["sonra"]) for i in plan["degisiklikler"]], items)
                self.assertTrue(all(i["alan"] == "wireguard" for i in plan["degisiklikler"]))
                self.assertTrue(plan["uygulanabilir"])
                self.assertTrue(plan["etkiler"])
                timed = [w for w in plan["uyarilar"] if "60 saniye" in w["metin"]]
                self.assertEqual(bool(timed), bool(seconds))
                self.marker.unlink(missing_ok=True)
        # The effects say what opens and closes.
        plan = self.m.plan(self.wg(eylem="durdur"))
        self.assertIn("Güvenlik duvarı yeniden kurulur: WireGuard'ın UDP portları kapanır (61001); yönlendirme ve NAT kalkar.",
                      plan["etkiler"])
        self.networks.unlink()
        (self.wgdir / "wg0.conf").unlink()
        plan = self.m.plan(self.wg(eylem="ag-ekle", ag={"port": 61001, "dns": "1.1.1.1"}))
        self.assertEqual([(i["islem"], i["nesne"]) for i in plan["degisiklikler"]], [("ac", "WireGuard"), ("ekle", "WireGuard ağı wg0")])
        self.assertIn("Güvenlik duvarı yeniden kurulur: UDP 61001 internete açılır; yönlendirme ve NAT gelir.", plan["etkiler"])
        # An opening is confirmed only over Tailscale.
        self.assertFalse(self.m.plan(self.wg(eylem="ag-ekle", ag={"port": 61001, "dns": "1.1.1.1"}), kanal="internet")["uygulanabilir"])

    def test_the_section_is_checked_with_master_wg_rules(self):
        cases = [({"eylem": "sil"}, "eylemi geçersiz"), ({"eylem": "baslat", "iface": "wg0"}, "uyuşmuyor"),
                 ({"eylem": "ag-ac"}, "uyuşmuyor"), ({"eylem": "durdur", "onay": "onayla"}, "uyuşmuyor"),
                 ({"eylem": "ag-kapat", "iface": "wg0", "onay": "onayla"}, "uyuşmuyor"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1"}, "iface": "wg1"}, "uyuşmuyor"),
                 ({"eylem": "ag-kaldir", "iface": "wg0", "onay": True}, "metin olmalı"),
                 ({"eylem": "ag-ac", "iface": "wg10"}, "Geçersiz arayüz"), ({"eylem": "ag-ac", "iface": "wg0\n"}, "Geçersiz arayüz"),
                 ({"eylem": "ag-kaldir", "iface": "wg3"}, "'wg3' diye bir WireGuard ağı yok"),
                 ({"eylem": "baslat"}, "zaten çalışıyor"), ({"eylem": "ag-ac", "iface": "wg0"}, "wg0 zaten açık"),
                 ({"eylem": "ag-ekle", "ag": {"port": "61020", "dns": "1.1.1.1"}}, "1024-65535"),
                 ({"eylem": "ag-ekle", "ag": {"port": True, "dns": "1.1.1.1"}}, "1024-65535"),
                 ({"eylem": "ag-ekle", "ag": {"port": 80, "dns": "1.1.1.1"}}, "1024-65535"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61001, "dns": "1.1.1.1"}}, r"UDP 61001 kullanılıyor \(wg0\)"),
                 ({"eylem": "ag-ekle", "ag": {"port": 41641, "dns": "1.1.1.1"}}, r"kullanılıyor \(tailscale\)"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61010, "dns": "1.1.1.1"}}, r"kullanılıyor \(Paylaşım\)"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020}}, "Port ve DNS gerekli"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1", "scope": "lan"}}, "Port ve DNS gerekli"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "dns.example"}}, "8 geçerli"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1,,"}}, "8 geçerli"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1\n9.9.9.9"}}, "Geçerli DNS"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1", "label": "iki\tsütun"}}, "denetim karakteri"),
                 ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1", "label": "ş" * 33}}, "64 bayt")]
        for item, message in cases:
            with self.subTest(item=item), self.assertRaisesRegex(settings.SettingsError, message):
                self.m.plan(self.wg(**item))
        with self.assertRaisesRegex(settings.SettingsError, "ayrı kaydedin"):
            self.m.plan(self.payload(wireguard={"eylem": "durdur"}, firewall=[]))
        self.units["wg0"] = [False, False]
        with self.assertRaisesRegex(settings.SettingsError, "wg0 zaten kapalı"):
            self.m.plan(self.wg(eylem="ag-kapat", iface="wg0"))
        self.marker.write_text("wg0\n")
        for item, message in (({"eylem": "durdur"}, "zaten durdurulmuş"), ({"eylem": "ag-ac", "iface": "wg0"}, "WireGuard durduruldu"),
                              ({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1"}}, "WireGuard durduruldu")):
            with self.subTest(item=item), self.assertRaisesRegex(settings.SettingsError, message):
                self.m.plan(self.wg(**item))
        self.marker.unlink()
        # Ten networks (and a leftover wgN.conf without a line) leave no interface.
        self.networks.write_text("".join(NET0.replace("wg0", "wg%d" % i).replace("61001", str(61001 + i)) + "\n" for i in range(9)))
        (self.wgdir / "wg9.conf").write_text("")
        with self.assertRaisesRegex(settings.SettingsError, "en çok 10 ağ"):
            self.m.plan(self.wg(eylem="ag-ekle", ag={"port": 61020, "dns": "1.1.1.1"}))
        self.networks.write_text("wg0\t61001\n")
        with self.assertRaisesRegex(settings.SettingsError, "ağ kaydı okunamadı"):
            self.m.plan(self.wg(eylem="durdur"))
        self.assertEqual(self.tool_calls, [])
        self.assertIsNone(self.m.pending())

    def test_removing_or_regenerating_needs_the_typed_word(self):
        for item in ({"eylem": "ag-kaldir", "iface": "wg0"}, {"eylem": "yeniden-uret", "iface": "wg0", "onay": "evet"}):
            with self.subTest(item=item):
                plan = self.m.plan(self.wg(**item))
                self.assertFalse(plan["uygulanabilir"])
                self.assertIn({"seviye": "bad", "metin": "Bu işlem geri alınamaz; uygulamak için onayla yazın."}, plan["uyarilar"])
                with self.assertRaisesRegex(settings.SettingsError, "onayla yazın"):
                    self.m.apply(self.wg(**item))
        self.assertEqual(self.tool_calls, [])
        self.assertEqual([c for c in self.calls if c[1] not in ("is-enabled", "is-active")], [],
                         "refused before the timer and the pending file")
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.m.apply(self.wg(eylem="yeniden-uret", iface="wg0", onay=" ONAYLA ")), {"pending": None, "committed": True})
        self.assertEqual(self.tool_calls, [(["--if", "wg0", "reset", "--onay"], "applying", True)])

    def test_a_closing_action_commits_at_once_and_copies_no_key(self):
        written = []
        original = settings.save_json
        with patch.object(settings, "save_json", side_effect=lambda path, value: (written.append(json.dumps(value)), original(path, value))):
            result = self.m.apply(self.wg(eylem="ag-kaldir", iface="wg0", onay="onayla"))
        self.assertEqual(result, {"pending": None, "committed": True})
        self.assertEqual(self.tool_calls, [(["net-remove", "wg0", "--onay"], "applying", True)])
        self.assertIsNone(self.m.pending())
        self.assertIn("_transaction", self.m.config())
        pending = json.loads(written[0])
        self.assertEqual(sorted(pending["wireguard"]["files"]), sorted([str(self.marker), str(self.networks)]))
        self.assertIsNone(pending["wireguard"]["files"][str(self.marker)])
        self.assertEqual(pending["files"], {})
        self.assertFalse(any(KEY in text or "PrivateKey" in text for text in written), "no key in the pending file")
        self.assertEqual(pending["changes"]["wireguard"]["eylem"], "ag-kaldir")
        self.assertNotIn("onayla", json.dumps(pending["changes"]["wireguard"]), "not even the typed word")

    def test_an_opening_waits_and_commits_on_confirmation(self):
        self.marker.write_text("wg0\n")
        self.units["wg0"] = [False, False]
        self.m.apply(self.wg(eylem="baslat"))
        p = self.m.pending()
        self.assertEqual((p["phase"], p["until"]), ("awaiting", self.now + 60))
        self.assertEqual(self.m.pending_view()["wireguard"], {"eylem": "baslat", "iface": None})
        self.assertFalse(self.marker.exists())
        self.confirm()
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.tool_calls, [(["baslat"], "applying", True)])
        self.assertEqual(self.units["wg0"], [True, True])

    def test_an_unconfirmed_start_is_stopped_again(self):
        self.marker.write_text("wg0\n")
        self.marker.chmod(0o600)
        self.units["wg0"] = [False, False]
        self.m.apply(self.wg(eylem="baslat"))
        self.assertEqual(self.units["wg0"], [True, True])
        self.calls.clear()
        self.now += 61
        self.m.guard()
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.marker.read_text(), "wg0\n", "the list baslat read is back")
        self.assertEqual(self.marker.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.units["wg0"], [False, False])
        self.assertIn(["systemctl", "disable", "--now", "--quiet", "wg-quick@wg0.service"], self.calls)
        firewall = [c for c in self.calls if c[0].endswith("/master-firewall")]
        self.assertEqual(firewall, [[self.env["SBIN_DIR"] + "/master-firewall"], [self.env["SBIN_DIR"] + "/master-firewall", "--check"]])
        self.assertLess(self.calls.index(["systemctl", "disable", "--now", "--quiet", "wg-quick@wg0.service"]),
                        self.calls.index(firewall[0]))
        self.assertEqual(self.tool_calls, [(["baslat"], "applying", True)], "the rollback needs no pending exception")

    def test_an_unconfirmed_network_switch_is_closed_again(self):
        self.units["wg0"] = [False, False]
        self.m.apply(self.wg(eylem="ag-ac", iface="wg0"))
        self.assertEqual(self.m.pending()["phase"], "awaiting")
        self.now += 61
        self.m.guard()
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.tool_calls, [(["--if", "wg0", "net", "ac"], "applying", True),
                                           (["--if", "wg0", "net", "kapat"], "rollback", True)])
        self.assertEqual(self.units["wg0"], [False, False])

    def test_an_unconfirmed_network_is_removed_with_its_keys(self):
        self.networks.unlink()
        (self.wgdir / "wg0.conf").unlink()
        self.m.apply(self.wg(eylem="ag-ekle", ag={"port": 61001, "dns": "1.1.1.1"}))
        self.assertEqual(self.m.pending_view()["wireguard"], {"eylem": "ag-ekle", "iface": "wg0"})
        self.assertEqual(len(self.lines()), 1)
        self.now += 61
        self.m.guard()
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.tool_calls, [(["net-add", "61001", "1.1.1.1", ""], "applying", True),
                                           (["net-remove", "wg0", "--onay"], "rollback", True)])
        self.assertFalse(self.networks.exists(), "the networks file is back to none")
        self.assertIn([self.env["SBIN_DIR"] + "/master-firewall", "--check"], self.calls)
        # Confirmed, the network stays.
        self.tool_calls.clear()
        self.m.apply(self.wg(eylem="ag-ekle", ag={"port": 61020, "dns": "1.1.1.1", "label": "Misafir"}))
        self.confirm()
        self.assertEqual([line.split("\t")[0] for line in self.lines()], ["wg0"])
        self.assertEqual(self.tool_calls, [(["net-add", "61020", "1.1.1.1", "Misafir"], "applying", True)])

    def test_a_failed_opening_is_undone_and_names_its_cause(self):
        self.tool_fail = ["net-add", "61020", "1.1.1.1", ""]
        with self.assertRaisesRegex(settings.SettingsError, "^UDP 61020 sunucuda başka bir program tarafından dinleniyor$"):
            self.m.apply(self.wg(eylem="ag-ekle", ag={"port": 61020, "dns": "1.1.1.1"}))
        self.assertIsNone(self.m.pending())
        self.assertEqual(self.lines(), [NET0])
        self.assertEqual([c[0] for c in self.tool_calls], [self.tool_fail], "nothing was created, nothing is removed")
        self.assertIn([self.env["SBIN_DIR"] + "/master-firewall", "--check"], self.calls)

    def test_a_failed_closing_action_names_the_state_it_left_and_is_not_reopened(self):
        self.tool_fail = ["--if", "wg0", "net", "kapat"]
        with self.assertRaisesRegex(settings.SettingsError, r"^UDP 61020 .* Şu anki durum: wg0 açık\.$"):
            self.m.apply(self.wg(eylem="ag-kapat", iface="wg0"))
        self.assertIsNone(self.m.pending())
        self.assertEqual([c[0] for c in self.tool_calls], [self.tool_fail], "a closing action is never reopened")
        self.assertIn([self.env["SBIN_DIR"] + "/master-firewall"], self.calls)
        self.tool_fail = ["durdur"]
        with self.assertRaisesRegex(settings.SettingsError, "Şu anki durum: wg0 açık"):
            self.m.apply(self.wg(eylem="durdur"))
        self.marker.write_text("")
        self.assertEqual(self.m.wireguard_left(), "Şu anki durum: WireGuard durdurulmuş.")

    def test_the_revision_covers_the_networks_file_and_the_stopped_marker(self):
        stale = self.wg(eylem="durdur")
        first = self.m.revision()
        self.networks.write_text(NET0 + "\n" + NET1 + "\n")
        second = self.m.revision()
        self.assertNotEqual(first, second)
        self.marker.write_text("")
        self.assertNotEqual(self.m.revision(), second)
        with self.assertRaises(settings.SettingsStale) as err:
            self.m.plan(stale)
        self.assertIsInstance(err.exception, settings.SettingsError)
        self.assertEqual(str(err.exception), "Ayarlar değişmiş. Yenileyip yeniden inceleyin.")
        # The worker says so with its own exit status; the backend answers 409.
        out = io.StringIO()
        with patch("sys.argv", ["master_settings.py", "--state", str(self.state), "apply"]), \
                patch("sys.stdin", io.StringIO(json.dumps(stale))), contextlib.redirect_stdout(out), \
                self.assertRaises(SystemExit) as code:
            settings.main()
        self.assertEqual(code.exception.code, settings.STALE_EXIT)
        self.assertEqual(json.loads(out.getvalue()), {"error": "Ayarlar değişmiş. Yenileyip yeniden inceleyin."})
        self.assertEqual(self.tool_calls, [])

    def test_master_wg_inherits_the_held_lock_and_the_pending_id(self):
        tool = Path(self.env["SBIN_DIR"]) / "master-wg"
        tool.parent.mkdir(exist_ok=True)
        tool.write_text("#!/usr/bin/env python3\n"
                        "import json, os, sys\n"
                        "held = os.fstat(int(os.environ['OBHUT_KILIT_FD']))\n"
                        "print(json.dumps({'argv': sys.argv[1:], 'id': os.environ['OBHUT_AYAR_ISLEMI'], 'state': os.environ['STATE_FILE'],\n"
                        "                  'file': [held.st_dev, held.st_ino]}))\n"
                        "if sys.argv[1:] == ['fail']:\n"
                        "    print('UYARI: wg9 kapatılamadı', file=sys.stderr)\n"
                        "    print('HATA: ağ eklenemedi', file=sys.stderr)\n"
                        "    print('Job for master-firewall.service failed.', file=sys.stderr)\n"
                        "    sys.exit(1)\n")
        tool.chmod(0o755)
        with self.assertRaisesRegex(settings.SettingsError, "Kurulum kilidi tutulmuyor"):
            self.original_tool(self.m, "a" * 32, "baslat")
        with self.m.locked():
            rc, out, message = self.original_tool(self.m, "a" * 32, "--if", "wg0", "net", "ac")
            failed = self.original_tool(self.m, "a" * 32, "fail")
        lock = (self.root / "run/install.lock").stat()
        self.assertEqual((rc, message), (0, ""))
        self.assertEqual(json.loads(out), {"argv": ["--if", "wg0", "net", "ac"], "id": "a" * 32, "state": str(self.state),
                                           "file": [lock.st_dev, lock.st_ino]})
        self.assertEqual((failed[0], failed[2]), (1, "ağ eklenemedi"))
        self.assertIsNone(self.m.install_lock)

    def test_the_audit_detail_names_only_checked_words(self):
        self.assertEqual(settings.audit_detail({"eylem": "ag-kaldir", "iface": "wg0", "onay": "onayla"}), "wireguard ag-kaldir wg0")
        self.assertEqual(settings.audit_detail({"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1"}}), "wireguard ag-ekle UDP 61020")
        self.assertEqual(settings.audit_detail({"eylem": "baslat", "iface": None}), "wireguard baslat")
        self.assertEqual(settings.audit_detail({"eylem": "ag-ac", "iface": "wg0\n-> ok"}), "wireguard ag-ac")
        for item in (None, {}, {"eylem": "sil"}, {"eylem": ["baslat"]}, "baslat"):
            self.assertEqual(settings.audit_detail(item), "ayarlar")


if __name__ == "__main__":
    unittest.main()
