"""Internet-only upgrade boundaries; systemd is mocked, keys are opaque fixtures."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PANEL = Path(__file__).resolve().parents[1] / "panel"
sys.path.insert(0, str(PANEL))
import master_settings as settings
import master_wg_upgrade as upgrade


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(WG_NETWORKS_MAX="9", LOCAL_DOMAIN="test", WAN_INTERFACE="eth0", TAILSCALE_IF="tailscale0")
        for name in ("WG_NETWORKS_FILE", "SETTINGS_FILE", "SETTINGS_PENDING_FILE", "UNIT_DIR",
                     "WG_CONF_DIR", "CADDYFILE", "SETTINGS_DNS_FILE", "TORRENT_PROFILE_DIR", "DNSMASQ_CONF_DIR"):
            self.env[name] = str(self.root / name.lower())
        self.path = lambda name: Path(self.env[name])
        self.path("WG_CONF_DIR").mkdir()
        self.path("UNIT_DIR").mkdir()
        self.line = "wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tAna ağ\n"
        self.path("WG_NETWORKS_FILE").write_text(self.line)
        self.key = self.path("WG_CONF_DIR") / "wg0.conf"
        self.key.write_bytes(b"opaque unchanged server fixture")
        self.profiles = self.path("WG_CONF_DIR") / "clients-wg0"
        self.profiles.mkdir()
        (self.profiles / "device.conf").write_bytes(b"opaque unchanged client fixture")
        self.artifacts = [self.path("UNIT_DIR") / "caddy-wg@.service", self.root / "Caddyfile.wg",
                          self.path("WG_CONF_DIR") / "caddy-wg-wg0.env", self.path("WG_CONF_DIR") / "caddy-wg-wg9.env"]
        for p in self.artifacts:
            p.write_text("retired")
        self.unrelated = self.path("UNIT_DIR") / "caddy.service"
        self.unrelated.write_text("keep")
        rule = dict(id="test",name="Test",family=4,scope="tail",proto="tcp",port=9000,source="",allow=True)
        self.config = dict(firewall=[rule,dict(rule,id="old",scope="wg0")],
                           dns=dict(disabled=[],records=[],forward=False,servers=[]), domain="test")
        self.path("SETTINGS_FILE").write_text(json.dumps(self.config))
        self.loaded = {"caddy-wg@wg0.service", "caddy-wg@wg9.service"}
        self.calls = []
        self.fail = False
        self.addCleanup(patch.stopall)
        patch.object(upgrade, "run", side_effect=self.run_cmd).start()

    def run_cmd(self, argv, **_kwargs):
        self.calls.append(argv)
        if argv[1] == "show":
            return subprocess.CompletedProcess(argv, 0, "loaded" if argv[-1] in self.loaded else "not-found")
        if argv[1] == "disable":
            if self.fail:
                raise settings.SettingsError("stop failed")
            self.loaded.discard(argv[-1])
        return subprocess.CompletedProcess(argv, 3 if argv[1] == "is-active" else 0, "")

    def retire(self):
        with contextlib.redirect_stdout(io.StringIO()):
            upgrade.retire(self.env)

    def test_upgrade_and_repeat_preserve_everything_except_retired_access(self):
        opaque = {p: p.read_bytes() for p in (self.key, self.profiles / "device.conf", self.unrelated)}
        self.retire()
        self.assertEqual(self.path("WG_NETWORKS_FILE").read_text(), self.line.replace("\tui\t","\tinet\t"))
        for p, before in opaque.items():
            self.assertEqual(p.read_bytes(), before)
        self.assertTrue(all(not p.exists() for p in self.artifacts))
        saved = json.loads(self.path("SETTINGS_FILE").read_text())
        self.assertEqual(saved, dict(self.config,firewall=self.config["firewall"][:1]))
        disabled = [c[-1] for c in self.calls if c[1] == "disable"]
        self.assertEqual(disabled, ["caddy-wg@wg0.service","caddy-wg@wg9.service"])
        stamps = {p:p.stat().st_mtime_ns for p in (self.path("WG_NETWORKS_FILE"),self.path("SETTINGS_FILE"),*opaque)}
        self.calls.clear()
        self.retire()
        self.assertEqual(stamps,{p:p.stat().st_mtime_ns for p in stamps})
        self.assertTrue(all(c[1]=="show" for c in self.calls))

    def test_fresh_install_creates_no_network_or_listener(self):
        for p in self.artifacts+[self.path("WG_NETWORKS_FILE"),self.path("SETTINGS_FILE")]:
            p.unlink()
        self.loaded.clear()
        self.retire()
        self.assertFalse(self.path("WG_NETWORKS_FILE").exists())
        self.assertFalse(self.path("SETTINGS_FILE").exists())
        self.assertTrue(all(c[1]=="show" for c in self.calls))

    def test_invalid_pending_and_symlink_fail_before_any_service_change(self):
        for condition in ("registry","pending","link"):
            with self.subTest(condition=condition):
                self.path("WG_NETWORKS_FILE").write_text("invalid" if condition=="registry" else self.line)
                if condition=="pending":
                    self.path("SETTINGS_PENDING_FILE").write_text("{}")
                if condition=="link":
                    self.artifacts[0].unlink()
                    self.artifacts[0].symlink_to(self.unrelated)
                with self.assertRaises(settings.SettingsError):
                    self.retire()
                self.assertEqual(self.calls,[])
                self.path("SETTINGS_PENDING_FILE").unlink(missing_ok=True)

    def test_failed_stop_does_not_publish_new_registry_or_remove_files(self):
        self.fail=True
        with self.assertRaises(settings.SettingsError):
            self.retire()
        self.assertEqual(self.path("WG_NETWORKS_FILE").read_text(),self.line)
        self.assertTrue(all(p.exists() for p in self.artifacts))

    def test_legacy_settings_cannot_override_or_reintroduce_tunnel_permissions(self):
        state=self.root/"state.env"
        state.write_text("".join(k+"="+v+"\n" for k,v in self.env.items()))
        manager=settings.Manager(state)
        self.assertEqual(manager.config()["firewall"],self.config["firewall"][:1])
        with patch.object(manager,"revision",return_value="rev"):
            for scope in ("wg0","wg9","ui","inet"):
                with self.subTest(scope=scope), self.assertRaises(settings.SettingsError):
                    manager.validate(dict(revision="rev",firewall=[dict(self.config["firewall"][0],scope=scope)]))
        with patch.object(manager,"current",return_value=self.config):
            rules=manager.rules(4)
            self.assertTrue(all("wg0" not in " ".join(r) for r in rules))


if __name__ == "__main__":
    unittest.main()
