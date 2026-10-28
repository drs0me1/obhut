"""Read-only firewall categories and socket bindings; never invoke host networking."""
import importlib.machinery
import importlib.util
from pathlib import Path
import types
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "panel" / "master-panel"
loader = importlib.machinery.SourceFileLoader("firewall_view_panel", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
panel = importlib.util.module_from_spec(spec)
loader.exec_module(panel)


class FirewallViewTests(unittest.TestCase):
    def setUp(self):
        self.tailnet = patch.object(panel.master_settings, "tailnet_ports", return_value=[]).start()
        self.addCleanup(patch.stopall)
        self.p = panel.Panel(types.SimpleNamespace(state="/unused"))
        self.env = {"TAILSCALE_IF": "tailscale0", "TAILSCALE_IPV4": "100.64.0.2",
                    "TAILSCALE_IPV6": "fd7a:115c:a1e0::2", "WAN_INTERFACE": "eth0",
                    "WAN_IPV4": "192.0.2.1", "WAN_IPV6": "2001:db8::1", "FILES_PANEL_PORT": "61009"}
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
        # DD-271: the Files backend's loopback row is a base row of the port catalogue.
        rows = self.p.settings_ports(self.env, [], [{"family": 4, "proto": "tcp", "port": 61009},
                                                   {"family": 4, "proto": "tcp", "port": 54321}])
        keys = [(r["family"], r["proto"], r["port"], r["scope"]) for r in rows]
        self.assertEqual(len(keys), len(set(keys)))
        by_scope = {r["scope"]: r for r in rows if r["port"] == 61009 and r["family"] == 4}
        self.assertNotIn("tail", by_scope)
        self.assertEqual(by_scope["lo"]["name"], "Konsol · dosya arka ucu")
        self.assertNotIn("wan", by_scope)
        self.assertTrue(by_scope["lo"]["baseline"])
        self.assertEqual(next(r["name"] for r in rows if r["port"] == 54321), "Diğer dinleyici")
        # No base row is a fixed publication.
        self.assertFalse(any(r.get("fixed") for r in rows))

    def test_base_rows_come_only_from_configured_keys(self):
        self.assertEqual(self.p.ports({}, []), [])
        env = {"SHARE_PORT": "61010", "FILES_PANEL_PORT": "61009", "SSH_PUBLIC_PORT": "not-a-port"}
        self.assertEqual(self.p.ports(env, []), [
            {"port": 61010, "proto": "tcp", "scope": "tailscale",
             "name": "Paylaşım WebDAV — yalnız Konsol'dan paylaşılanlar (Infuse)"},
            {"port": 61009, "proto": "tcp", "scope": "loopback", "name": "Konsol · dosya arka ucu"}])
        names = [r["name"] for r in self.p.ports({}, self.nets)]
        self.assertEqual(names, ["WireGuard wg0 · Home", "WireGuard wg1 · Mobile"])
        self.assertEqual([r["name"] for r in self.p.ports({}, [{**self.nets[0], "label": ""}])], ["WireGuard wg0"])

    def test_settings_network_metadata_is_public_only_and_includes_inactive_networks(self):
        nets = [{**n, "private_key": "must-not-leak"} for n in self.nets]
        with patch.object(panel, "read_env", return_value=self.env), \
             patch.object(self.p.wireguard, "networks", return_value=nets) as networks, \
             patch.object(self.p, "firewall_check", return_value={}), \
             patch.object(self.p, "web_view", return_value={}), \
             patch.object(self.p, "dns_view", return_value={}):
            fw = self.p.settings(fresh=True)["firewall"]
        networks.assert_called_once_with()
        self.assertNotIn("vpn_name", fw)
        self.assertEqual(len(fw["networks"]), 2)
        self.assertEqual(set(fw["networks"][0]), {"iface", "label", "active"})
        self.assertFalse(fw["networks"][1]["active"])

    def test_a_closed_network_has_no_port_or_listener_scope_in_the_view(self):
        """The firewall admits only an open network (its unit enabled): the ports and listener scopes follow it, the
        list of networks shows them all."""
        nets = [dict(self.nets[0], open=True), dict(self.nets[1], open=False)]
        env = dict(self.env, SETTINGS_FILE="/unused/ayarlar.json")
        with patch.object(panel, "read_env", return_value=env), \
             patch.object(self.p.wireguard, "networks", return_value=nets), \
             patch.object(self.p, "firewall_check", return_value={}), \
             patch.object(self.p, "web_view", return_value={}), \
             patch.object(self.p, "dns_view", return_value={}), \
             patch.object(panel.master_settings.Manager, "__init__", return_value=None), \
             patch.object(panel.master_settings.Manager, "status", return_value={}), \
             patch.object(self.p, "all_firewall_rules", return_value={"rows": [], "errors": []}), \
             patch.object(self.p, "listeners", return_value=[]) as listeners, \
             patch.object(self.p, "settings_ports", return_value=[]) as ports:
            fw = self.p.settings(fresh=True)["firewall"]
        self.assertEqual([n["iface"] for n in fw["networks"]], ["wg0", "wg1"])
        self.assertEqual([n["iface"] for n in listeners.call_args.args[1]], ["wg0"])
        self.assertEqual([n["iface"] for n in ports.call_args.args[1]], ["wg0"])

    def test_firewall_page_names_ports_and_networks_without_application_fields(self):
        view = {"firewall": {"ok": True, "check": "firewall: tamam",
                             "networks": [{"iface": "wg0", "label": "Home", "active": True},
                                          {"iface": "wg1", "label": "", "active": False}],
                             "ports": [{"name": "WireGuard wg0 · Home", "family": 4, "proto": "udp", "port": 51820,
                                        "scope": "wan", "baseline": True},
                                       {"name": "Konsol · dosya arka ucu", "family": 6, "proto": "tcp", "port": 61009,
                                        "scope": "lo", "baseline": True},
                                       {"name": "unknown scope", "family": 4, "proto": "tcp", "port": 1, "scope": "wg0"}],
                             "listeners": None, "rules": {"rows": [], "errors": ["IPv6 kuralları okunamadı"]}},
                "manage": {"revision": "r1", "config": {"firewall": []}}}
        with patch.object(self.p, "settings", return_value=view):
            fw = self.p.guvenlik_duvari()
        self.assertEqual(set(fw), {"revizyon", "denetim", "kurallar", "portlar", "dinleyiciler", "teknik", "aglar", "hatalar"})
        self.assertEqual(fw["portlar"], [
            {"ad": "WireGuard wg0 · Home", "aile": 4, "proto": "udp", "port": 51820, "kapsam": "wan", "sabit": False, "satir": None},
            {"ad": "Konsol · dosya arka ucu", "aile": 6, "proto": "tcp", "port": 61009, "kapsam": "lo", "sabit": False,
             "satir": None}])
        self.assertEqual(fw["aglar"], [{"arayuz": "wg0", "ad": "Home", "etkin": True},
                                       {"arayuz": "wg1", "ad": "", "etkin": False}])
        self.assertIsNone(fw["dinleyiciler"])
        self.assertEqual((fw["revizyon"], fw["denetim"], fw["hatalar"]),
                         ("r1", {"ok": True, "metin": "firewall: tamam"}, ["IPv6 kuralları okunamadı"]))

    def test_wireguard_endpoints_have_no_tunnel_host_service(self):
        rows = self.p.settings_ports(self.env, self.nets)
        endpoints = [r for r in rows if r["port"] in (51820, 51821)]
        self.assertTrue(endpoints)
        self.assertTrue(all(r["scope"] in ("wan", "tail") and r["proto"] == "udp" for r in endpoints))
        # Registered networks remain in the tailnet catalogue even with no sockets/peers.
        self.assertEqual({(r["family"], r["port"]) for r in endpoints if r["scope"] == "tail"},
                         {(f, p) for f in (4, 6) for p in (51820, 51821)})
        self.assertTrue(all(r["baseline"] for r in endpoints if r["scope"] == "tail"))
        self.assertFalse(any(r["scope"].startswith("wg") for r in rows))

    def test_tailnet_catalogue_excludes_unconfigured_listeners_in_both_families(self):
        self.tailnet.return_value = [dict(family=f, proto="tcp", port=80, name="Caddy") for f in (4, 6)]
        self.tailnet.return_value.append(dict(family=4, proto="tcp", port=54321, name="Tailscale PeerAPI"))
        sockets = [dict(family=f, proto=p, port=n) for f in (4, 6) for p in ("tcp", "udp")
                   for n in (20902, 61006, 61008, 61009, 2019, 54321, 49876)]
        rows = self.p.settings_ports(self.env, self.nets, sockets)
        tail = {(r["family"], r["proto"], r["port"]): r for r in rows if r["scope"] == "tail"}
        self.assertEqual(set(tail), {(4, "tcp", 80), (6, "tcp", 80), (4, "tcp", 54321)} |
                         {(f, "udp", p) for f in (4, 6) for p in (51820, 51821)})
        self.assertTrue(all(r["baseline"] for r in tail.values()))
        self.assertEqual(tail[(4, "tcp", 54321)]["name"], "Tailscale PeerAPI")
        for port in (20902, 61006, 61008, 61009, 2019, 49876):
            for family in (4, 6):
                self.assertFalse(any(r["scope"] == "wan" and r["family"] == family and r["port"] == port for r in rows))
                self.assertTrue(any(r["scope"] == "lo" and r["baseline"] and
                                    r["family"] == family and r["port"] == port for r in rows))
        self.assertEqual(len(rows), len({(r["family"], r["proto"], r["port"], r["scope"]) for r in rows}))
        # The endpoint permission is preserved on WAN regardless of peer count.
        self.assertTrue(next(r["baseline"] for r in rows if r["scope"] == "wan" and r["family"] == 4 and r["port"] == 51821))

    def test_tailnet_uses_configured_ports_and_families_without_socket_discovery(self):
        env = {**self.env, "CADDY_HTTP_PORT": "8081", "SHARE_PORT": "61011", "DNS_PORT": "5353"}
        self.tailnet.return_value = [dict(family=4, proto="tcp", port=p, name=n)
                                    for p, n in ((8081, "Caddy"), (61011, "Paylaşım WebDAV"))]
        self.tailnet.return_value += [dict(family=f, proto=p, port=5353, name="dnsmasq")
                                     for f in (4, 6) for p in ("tcp", "udp")]
        for sockets in (None, [], [dict(family=6, proto="tcp", port=8081)]):
            with self.subTest(sockets=sockets):
                rows = self.p.settings_ports(env, [], sockets)
            tail = {(r["family"], r["proto"], r["port"]) for r in rows if r["scope"] == "tail"}
            self.assertEqual(tail, {(r["family"], r["proto"], r["port"]) for r in self.tailnet.return_value})

    def test_wan_catalogue_has_only_configured_per_family_ingress(self):
        env = {**self.env, "SSH_PUBLIC_PORT": "2222", "TAILSCALE_UDP_PORT": "41642"}
        sockets = [dict(family=f, proto=p, port=n) for f in (4, 6) for p in ("tcp", "udp")
                   for n in (53, 80, 61004, 61008, 61009, 61010, 2019, 20902, 55221)]
        self.tailnet.return_value = [dict(family=4, proto="tcp", port=55221, name="Tailscale PeerAPI")]
        for discovered in (None, [], sockets):
            with self.subTest(discovered=bool(discovered)):
                rows = self.p.settings_ports(env, self.nets, discovered)
            wan = [r for r in rows if r["scope"] == "wan"]
            self.assertEqual({(r["family"], r["proto"], r["port"]) for r in wan},
                             {(f, p, n) for f in (4, 6) for p, n in (("tcp", 2222), ("udp", 41642))} |
                             {(4, "udp", 51820), (4, "udp", 51821)})
            self.assertTrue(all(r["baseline"] for r in wan))

    def test_tunnel_catalogue_has_no_host_services(self):
        for active in (True, False):
            nets = [{**n, "active": active, "count": 0} for n in self.nets]
            with self.subTest(active=active):
                rows = self.p.settings_ports(self.env, nets, [])
            tunnel = [r for r in rows if r["scope"].startswith("wg")]
            self.assertEqual(tunnel, [])
            self.assertTrue(any(r["scope"] == "wan" and r["port"] == 51821 for r in rows))

    def test_no_networks_means_no_wireguard_placeholder_ports(self):
        rows = self.p.settings_ports(self.env, [])
        self.assertFalse(any(r["scope"].startswith("wg") or r["name"].startswith("WireGuard ") for r in rows))

    def test_the_firewall_check_reports_its_last_line_and_a_failure_is_never_healthy(self):
        with patch.object(panel.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout=b"a\nfirewall: tamam\n", stderr=b"")):
            self.assertEqual(self.p.firewall_check(), {"ok": True, "check": "firewall: tamam"})
        with patch.object(panel.subprocess, "run", return_value=types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"failed")):
            self.assertEqual(self.p.firewall_check(), {"ok": False, "check": "failed"})
        with patch.object(panel.subprocess, "run", side_effect=OSError("no master-firewall")):
            self.assertEqual(self.p.firewall_check(), {"ok": False, "check": "denetim çalıştırılamadı"})


if __name__ == "__main__":
    unittest.main()
