"""Read-only firewall categories and socket bindings; never invoke host networking."""
import importlib.machinery
import importlib.util
from pathlib import Path
import types
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "panel" / "master-wg-panel"
loader = importlib.machinery.SourceFileLoader("firewall_view_panel", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
panel = importlib.util.module_from_spec(spec)
loader.exec_module(panel)


class FirewallViewTests(unittest.TestCase):
    def setUp(self):
        self.p = panel.Panel(types.SimpleNamespace(state="/unused", state_env=False))
        self.env = {"TAILSCALE_IF": "tailscale0", "TAILSCALE_IPV4": "100.64.0.2",
                    "TAILSCALE_IPV6": "fd7a:115c:a1e0::2", "WAN_INTERFACE": "eth0",
                    "WAN_IPV4": "192.0.2.1", "WAN_IPV6": "2001:db8::1", "TORRENT_UI_PORT": "61004", "FILES_PANEL_PORT": "61009"}
        self.nets = [{"iface": "wg0", "server4": "10.8.0.1", "server6": "fd00::1",
                      "label": "Home", "active": True, "scope": "ui", "port": 51820},
                     {"iface": "wg1", "server4": "10.9.0.1", "server6": "fd01::1",
                      "label": "Mobile", "active": False, "scope": "inet", "port": 51821}]

    def test_bindings_use_addresses_and_interfaces_not_private_prefix_guesses(self):
        cases = {"0.0.0.0": "any", "::": "any", "*": "any", "127.0.0.2": "lo", "::1": "lo",
                 "100.64.0.2": "tail", "fd7a:115c:a1e0:0:0:0:0:2": "tail",
                 "fe80::123%tailscale0": "tail", "fe80::123%eth0": "wan",
                 "192.0.2.1": "wan", "2001:db8:0:0:0:0:0:1": "wan",
                 "10.8.0.1": "wg0", "fd01::1": "wg1", "fe80::123%wg1": "wg1",
                 "100.64.0.99": "unknown", "fd7a:115c:a1e0::99": "unknown",
                 "fe80::123%other0": "unknown", "10.10.0.1": "unknown", "not-ip": "unknown"}
        for address, expected in cases.items():
            with self.subTest(address=address):
                self.assertEqual(self.p.binding_scope(address, self.env, self.nets), expected)

    def test_ss_ipv6_zone_outside_brackets_and_normal_brackets(self):
        outputs = [b"tcp LISTEN 0 10 0.0.0.0:22 0.0.0.0:*\nignored\n",
                   b"udp UNCONN 0 0 [fe80::123]%tailscale0:53 [::]:*\n"
                   b"tcp LISTEN 0 10 [::1]:61008 [::]:*\n"
                   b"tcp LISTEN 0 10 [fd01::1]:61004 [::]:*\n"]
        with patch.object(panel.subprocess, "run", side_effect=[types.SimpleNamespace(returncode=0, stdout=o) for o in outputs]) as run:
            rows = self.p.listeners(self.env, self.nets)
        self.assertEqual([(r["address"], r["scope"]) for r in rows],
                         [("0.0.0.0", "any"), ("fe80::123%tailscale0", "tail"), ("::1", "lo"), ("fd01::1", "wg1")])
        self.assertEqual([c.args[0] for c in run.call_args_list],
                         [["ss", "-H", "-lntu", "-4"], ["ss", "-H", "-lntu", "-6"]])

    def test_failed_socket_read_is_not_an_empty_listener_list(self):
        for result in (types.SimpleNamespace(returncode=1), OSError("missing"),
                       panel.subprocess.TimeoutExpired("ss", 10)):
            with self.subTest(result=result), patch.object(panel.subprocess, "run") as run:
                if isinstance(result, Exception):
                    run.side_effect = result
                else:
                    run.return_value = result
                self.assertIsNone(self.p.listeners(self.env, []))

    def test_known_service_names_are_retained_across_scopes(self):
        with patch.object(self.p, "module_state", return_value="calisiyor"):
            rows = self.p.settings_ports(self.env, [], [{"family": 4, "proto": "tcp", "port": 61009},
                                                       {"family": 4, "proto": "tcp", "port": 54321}])
        keys = [(r["family"], r["proto"], r["port"], r["scope"]) for r in rows]
        self.assertEqual(len(keys), len(set(keys)))
        by_scope = {r["scope"]: r for r in rows if r["port"] == 61009 and r["family"] == 4}
        self.assertIn("Konsol", by_scope["tail"]["name"])
        self.assertFalse(by_scope["wan"]["baseline"])
        self.assertTrue(by_scope["lo"]["baseline"])
        self.assertEqual(next(r["name"] for r in rows if r["port"] == 54321), "Diğer dinleyici")

    def test_settings_network_metadata_is_public_only_and_includes_stopped_install(self):
        nets = [{**n, "private_key": "must-not-leak"} for n in self.nets]
        with patch.object(panel, "read_env", return_value=self.env), \
             patch.object(self.p, "net_rows", return_value=nets), \
             patch.object(self.p, "module_state", return_value="durduruldu"), \
             patch.object(self.p, "firewall_view", return_value={}), \
             patch.object(self.p, "web_view", return_value={}), \
             patch.object(self.p, "dns_view", return_value={}), \
             patch.object(self.p, "torrent_view", return_value={}):
            fw = self.p.settings(fresh=True)["firewall"]
        self.assertTrue(fw["wireguard_installed"])
        self.assertEqual(len(fw["networks"]), 2)
        self.assertEqual(set(fw["networks"][0]), {"iface", "label", "active", "server4", "server6"})
        self.assertFalse(fw["networks"][1]["active"])

    def test_wireguard_endpoint_is_wan_but_application_is_tunnel_scope(self):
        with patch.object(self.p, "module_state", return_value="calisiyor"):
            rows = self.p.settings_ports(self.env, self.nets)
        endpoints = [r for r in rows if r["port"] in (51820, 51821)]
        self.assertTrue(endpoints)
        self.assertTrue(all(r["scope"] == "wan" and r["proto"] == "udp" for r in endpoints))
        self.assertTrue(any(r["scope"] == "wg0" and r["baseline"] and r["port"] == 61004 for r in rows))


if __name__ == "__main__":
    unittest.main()
