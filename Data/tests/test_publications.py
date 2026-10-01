"""Publication transactions, rollback and private/public isolation (DD-191)."""
from pathlib import Path
import json
import subprocess
import sys
import unittest
from unittest.mock import patch

import test_https_settings as fixtures
import master_https as tls
import master_settings as settings
import master_publications as pubs
REAL_RUN = subprocess.run


class PublicationTests(unittest.TestCase):
    command = fixtures.HttpsSettingsTests.command

    def setUp(self):
        fixtures.HttpsSettingsTests.setUp(self)
        self.env["TORRENT_UI_PORT"] = "61006"
        self.state.write_text("".join(k + "=" + v + "\n" for k, v in self.env.items()))
        self.m = settings.Manager(self.state)
        self.s.env.update(self.env)
        (self.root / "modules").write_text("paylasim\tcalisiyor\ntorrent\tcalisiyor\n")
        for service, addresses in (("paylasim", "http://paylas.ayc, http://{$TAILSCALE_IPV4}:61010"),
                                   ("torrent", "http://torrent.ayc")):
            directory = self.root / "templates" / service
            directory.mkdir()
            source = "# fixture\n%s {\n\trespond 401\n}\n" % addresses
            (directory / (service + ".caddy")).write_text(source)
            (self.root / "sites" / (service + ".caddy")).write_text(source)
        self.qconf = self.root / "profile/qBittorrent/qBittorrent.conf"
        self.qconf.parent.mkdir()
        self.qconf.write_text("[Preferences]\nWebUI\\Password_PBKDF2=@ByteArray(fixture)\nWebUI\\LocalHostAuth=true\n")
        self.m.apply({"revision": self.m.revision(), "https": {"domain": "dav.example.net"}})

    def payload(self, service="paylasim", tail=True, enabled=True, domain="dav.example.net"):
        return {"revision": self.m.revision(), "web": dict(service=service, tail=tail, enabled=enabled, domain=domain)}

    def test_panel_and_unknown_upstreams_rejected(self):
        for service in ("panel", "wireguard", "localhost:2019", [], None):
            with self.subTest(service=service), self.assertRaises(settings.SettingsError):
                self.m.validate(self.payload(service=service))
        payload = self.payload(); payload["web"]["upstream"] = "localhost:2019"
        with self.assertRaises(settings.SettingsError):
            self.m.validate(payload)

    def test_real_worker_reports_imported_validation_errors_as_json(self):
        for payload in (self.payload(service="panel"), self.payload(domain="https://bad.example.net")):
            p = REAL_RUN([sys.executable, settings.__file__, "--state", str(self.state), "apply"],
                         input=json.dumps(payload), text=True, capture_output=True, timeout=10)
            self.assertEqual(p.returncode, 1)
            self.assertIn("error", json.loads(p.stdout))
            self.assertEqual(p.stderr, "")

    def test_shared_https_port_is_reported_once_and_without_dav(self):
        import test_resources
        panel = test_resources.panel
        import types
        instance = panel.Panel(types.SimpleNamespace(state=str(self.state), allow_host=[], state_env=False))
        with patch.object(pubs, "torrent_active", return_value=True), \
                patch.object(panel.master_settings, "tailnet_ports", return_value=[]), \
                patch.object(instance, "ports", return_value=[]):
            rows = instance.settings_ports(self.env, [])
            self.assertEqual(len(rows), 1)
            self.assertIn("qBittorrent + WebDAV", rows[0]["name"])
            self.assertEqual(rows[0]["port"], 443)
            with patch.object(panel.master_shares.Manager, "wan_active", return_value=False):
                rows = instance.settings_ports(self.env, [])
            self.assertEqual(len(rows), 1)
            self.assertIn("qBittorrent", rows[0]["name"])
            self.assertNotIn("WebDAV", rows[0]["name"])

    def test_tail_disabled_preserves_wan_and_folder_accounts(self):
        accounts = self.s.path and Path(self.s.path).read_bytes()
        self.assertTrue(self.m.apply(self.payload(tail=False))["committed"])
        self.assertIn("respond 403", (self.root / "sites/paylasim.caddy").read_text())
        self.assertIn("http://{$TAILSCALE_IPV4}:61010", (self.root / "sites/paylasim.caddy").read_text())
        self.assertIn("https://dav.example.net:443", (self.root / "sites/paylasim-wan.caddy").read_text())
        self.assertEqual(set(self.s.public()["items"][0]["urls"]), {"wan"})
        self.assertEqual(Path(self.s.path).read_bytes(), accounts)
        self.assertFalse(self.s.public()["tail_enabled"])
        self.m.apply(self.payload())
        self.assertIn("respond 401", (self.root / "sites/paylasim.caddy").read_text())

    def test_wan_off_remembers_domain_without_plaintext_fallback(self):
        self.m.apply(self.payload(enabled=False))
        self.assertEqual(pubs.config(self.env)["paylasim"]["domain"], "dav.example.net")
        self.assertEqual(tls.config(self.env)["mode"], "off")
        self.assertFalse((self.root / "sites/paylasim-wan.caddy").exists())
        self.assertEqual(set(self.s.public()["items"][0]["urls"]), {"tailscale"})
        self.s.publish()
        self.assertFalse((self.root / "sites/paylasim-wan.caddy").exists())

    def test_first_row_certificate_failure_restores_private_file(self):
        private = self.root / "sites/paylasim.caddy"
        old = private.read_bytes()
        with patch.object(tls, "wait_certificate", side_effect=settings.SettingsError("cert failed")):
            with self.assertRaises(settings.SettingsError):
                self.m.apply(self.payload(tail=False))
        self.assertEqual(private.read_bytes(), old)
        self.assertNotIn("web", self.m.config())
        self.assertFalse(self.m.pending_path.exists())

    def test_process_crash_restores_private_file_after_reboot(self):
        old = (self.root / "sites/paylasim.caddy").read_bytes()
        with patch.object(tls, "wait_certificate", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.m.apply(self.payload(tail=False))
        with patch.object(settings, "boot_id", return_value="new"), patch.object(tls, "boot_id", return_value="new"):
            self.m.guard()
        self.assertEqual((self.root / "sites/paylasim.caddy").read_bytes(), old)
        self.assertFalse(self.m.pending_path.exists())

    def test_duplicate_domains_and_mixed_writes_rejected(self):
        with self.assertRaises(settings.SettingsError):
            self.m.validate(self.payload(service="torrent"))
        payload = self.payload(); payload["dns"] = self.m.config()["dns"]
        with self.assertRaises(settings.SettingsError):
            self.m.validate(payload)

    def test_dns_error_is_read_only(self):
        before = self.m.config()
        with patch.object(tls, "check_dns", side_effect=settings.SettingsError("DNS mismatch")):
            with self.assertRaises(settings.SettingsError):
                self.m.apply(self.payload(domain="bad.example.net"))
        self.assertEqual(self.m.config(), before)
        self.assertFalse(self.m.pending_path.exists())

    def test_torrent_https_stops_with_module_and_keeps_own_auth(self):
        before = self.qconf.read_bytes()
        # Only the real network probe is mocked; static qBittorrent auth gates run below.
        with patch.object(pubs, "torrent_security"):
            self.m.apply(self.payload(service="torrent", domain="torrent.example.net"))
        site = self.root / "sites/torrent-wan.caddy"
        self.assertIn("https://torrent.example.net:443", site.read_text())
        self.assertIn("reverse_proxy 127.0.0.1:61006", site.read_text())
        self.assertNotIn("panel", site.read_text())
        self.assertEqual(self.qconf.read_bytes(), before)
        with patch.dict(self.env, SHARE_HTTPS_PORT="18443"):
            custom = pubs.extra_sites(self.env)["torrent-wan.caddy"]
        self.assertIn("header_up Host torrent.example.net\n", custom)
        self.assertIn("header_up X-Forwarded-Host torrent.example.net:18443\n", custom)
        (self.root / "modules").write_text("paylasim\tcalisiyor\ntorrent\tdurduruldu\n")
        self.s.publish()
        self.assertFalse(site.exists())
        self.assertTrue(pubs.config(self.env)["torrent"]["enabled"])

    def test_unsafe_native_auth_fails_closed(self):
        original = self.qconf.read_text()
        pubs.torrent_security(self.env, "torrent.example.net")
        for key, value in (("LocalHostAuth", "false"), ("AuthSubnetWhitelistEnabled", "true"),
                           ("CSRFProtection", "false"), ("HostHeaderValidation", "false"),
                           ("MaxAuthenticationFailCount", "0"), ("BanDuration", "0"), ("ServerDomains", "another.example.net")):
            with self.subTest(key=key):
                self.qconf.write_text(original + "WebUI\\%s=%s\n" % (key, value))
                with self.assertRaises(settings.SettingsError):
                    pubs.torrent_security(self.env, "torrent.example.net")
        self.qconf.write_text("[Preferences]\n")
        with self.assertRaises(settings.SettingsError):
            pubs.torrent_security(self.env, "torrent.example.net")

    def test_private_403_stub_uses_exactly_the_module_template_addresses(self):
        # DD-193: no hard-coded host names; the real templates are the single source.
        self.m.apply(self.payload(service="torrent", tail=False, enabled=False, domain=""))
        self.m.apply(self.payload(tail=False))
        values = {"__LOCAL_DOMAIN__": "ev", "__SHARE_PORT__": "61010", "__TORRENT_UI_PORT__": "61006"}
        for service in ("paylasim", "torrent"):
            with self.subTest(service=service):
                source = (settings.Path(__file__).resolve().parents[1] / "modules" / service / (service + ".caddy")).read_text()
                for key, value in values.items():
                    source = source.replace(key, value)
                first = next(line for line in source.splitlines() if line.startswith("http"))
                stub = pubs.private_site(self.env, service, source)
                self.assertEqual(stub.splitlines()[1], first)
                self.assertIn("\trespond 403\n", stub)
                self.assertNotIn("reverse_proxy", stub)
        extra = "# x\nhttp://torrent.ev, http://torrent-alt.ev {\n\treverse_proxy 127.0.0.1:1\n}\n"
        self.assertIn("http://torrent.ev, http://torrent-alt.ev {", pubs.private_site(self.env, "torrent", extra))
        with self.assertRaises(settings.SettingsError):
            pubs.private_site(self.env, "torrent", "# no site block\n")

    def test_stopped_or_unsafe_torrent_row_reports_the_actual_cause(self):
        with patch.object(pubs, "torrent_security"):
            self.m.apply(self.payload(service="torrent", domain="torrent.example.net"))
        (self.root / "modules").write_text("paylasim\tcalisiyor\ntorrent\tdurduruldu\n")
        row = next(r for r in pubs.status(self.env) if r["service"] == "torrent")
        self.assertEqual(row["status"], "error")
        self.assertIn("durdurulmuş", row["message"])
        (self.root / "modules").write_text("paylasim\tcalisiyor\n")
        row = next(r for r in pubs.status(self.env) if r["service"] == "torrent")
        self.assertIn("kurulu değil", row["message"])
        (self.root / "modules").write_text("paylasim\tcalisiyor\ntorrent\tcalisiyor\n")
        self.qconf.write_text(self.qconf.read_text() + "WebUI\\AuthSubnetWhitelistEnabled=true\n")
        row = next(r for r in pubs.status(self.env) if r["service"] == "torrent")
        self.assertIn("giriş atlama", row["message"])

    def test_unavailable_listener_fails_fast_without_certificate_wait(self):
        # DD-193: no minute-long certificate wait when no public listener could open.
        import master_shares
        cases = (("paylasim", "dav.example.net", "WAN HTTPS dinleyicisi açılamadı",
                  patch.object(master_shares.Manager, "wan_active", return_value=False)),
                 ("torrent", "torrent.example.net", "qBittorrent internet yayını açılamadı",
                  patch.object(pubs, "torrent_active", return_value=False)))
        for service, domain, message, blocked in cases:
            with self.subTest(service=service):
                before = self.m.config()
                tls.wait_certificate.reset_mock()
                with blocked, patch.object(pubs, "torrent_security"), \
                        self.assertRaises(settings.SettingsError) as error:
                    self.m.apply(self.payload(service=service, domain=domain, tail=False))
                self.assertIn(message, str(error.exception))
                tls.wait_certificate.assert_not_called()
                self.assertEqual(self.m.config(), before)
                self.assertFalse(self.m.pending_path.exists())

    def test_reapply_projects_saved_private_choice_and_uninstall_removes_site(self):
        self.m.apply(self.payload(service="torrent", tail=False, enabled=False, domain=""))
        original = (self.root / "templates/torrent/torrent.caddy").read_text()
        self.assertIn("respond 403", pubs.private_site(self.env, "torrent", original))
        (self.root / "sites/torrent.caddy").write_text(original)
        self.s.publish()
        self.assertIn("respond 403", (self.root / "sites/torrent.caddy").read_text())
        (self.root / "modules").write_text("paylasim\tcalisiyor\n")
        self.s.publish()
        self.assertFalse((self.root / "sites/torrent.caddy").exists())


if __name__ == "__main__":
    unittest.main()
