"""WireGuard as a built-in (DD-271): master_wireguard behind the route table's /api/konsol/wireguard/*
routes. Gates, path parameters, request shapes, the master-wg argument lines, audit lines, the stopped
marker and the read for the other views; no real WireGuard, systemd or network changes. DD-275: the
access-changing actions are settings actions (their transaction is tested in test_settings.py); here
their old routes answer 404 and the settings routes name them in the audit line."""
import hashlib
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

import test_resources as resources

panel = resources.panel
master_api = panel.master_api
master_wireguard = panel.master_wireguard
API = "/api/konsol/wireguard"
NET = "wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfdcc::1\tfdcc::/112\t1.1.1.1\tEv ağı"
PEER = "phone\t10.8.0.2\tfdcc::2\t%d\t500\t700\tvar\t1.1.1.1\t21\t1420\t1"


class Fixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        (self.root / "bin").mkdir()
        self.networks = self.root / "networks"
        self.stopped = self.root / ".durduruldu"
        self.state = self.root / "state.env"
        self.state.write_text("\n".join([
            "LOCAL_DOMAIN=test", "WAN_IPV4=203.0.113.7", "SBIN_DIR=%s" % (self.root / "bin"),
            "DNS_PORT=53", "CADDY_HTTP_PORT=80", "SSH_PUBLIC_PORT=22", "TAILSCALE_UDP_PORT=41641",
            "WG_NETWORKS_FILE=%s" % self.networks, "WG_STOPPED_FILE=%s" % self.stopped, "WG_NETWORKS_MAX=9",
            'WG_CLIENT_DNS_DEFAULT="1.1.1.1, 1.0.0.1"', "WG_CLIENT_KEEPALIVE_DEFAULT=21", "WG_MTU=1420",
            "WG_PORT_DEFAULT=61001", "WG_PORT_NEXT=61020", ""]))
        self.tool = str(self.root / "bin" / "master-wg")
        self.p = panel.Panel(types.SimpleNamespace(state=str(self.state)))

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = resources.start_unix(self, Handler)

    def call(self, path, data=None, headers=None):
        headers = dict({"X-Konsol": "1"}, **(headers or {}))
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(data).encode()
        status, head, raw = resources.unix_get(self.sock, path, headers, "POST" if data is not None else "GET", body)
        return status, head, raw

    def post(self, path, data):
        status, _head, raw = self.call(API + path, data)
        return status, json.loads(raw)

    def calls(self, run, verb=None):
        return [c.args[0] for c in run.call_args_list if verb is None or verb in c.args[0]]


class RouteTests(Fixture):
    """Every WireGuard route is in the table, keeps the old path after the base, and answers its shape."""

    def test_the_table_has_every_route_with_typed_shapes(self):
        routes = {r.name: r for r in master_api.ROUTES if r.path.startswith(API + "/")}
        self.assertEqual({(r.method, r.path[len(API):]) for r in routes.values()}, {
            ("GET", "/state"), ("POST", "/nets/{iface}/peers"), ("POST", "/nets/{iface}/ayarlar"),
            ("POST", "/nets/{iface}/peers/{name}/remove"), ("POST", "/nets/{iface}/peers/{name}/dns"),
            ("POST", "/nets/{iface}/peers/{name}/keepalive"), ("POST", "/nets/{iface}/peers/{name}/durum"),
            ("GET", "/nets/{iface}/peers/{name}/profile"), ("GET", "/nets/{iface}/peers/{name}/qr.png")})
        for route in routes.values():
            self.assertTrue(route.method == "GET" or route.request is not None, route.name)
        self.assertEqual(routes["wireguard_profil"].content, "text/plain")
        self.assertEqual(routes["wireguard_qr"].content, "image/png")
        route, params = master_api.match("POST", API + "/nets/wg3/peers/tel%2Efon/dns")
        self.assertEqual((route.name, params), ("wireguard_cihaz_dns", {"iface": "wg3", "name": "tel.fon"}))
        for path in (API + "/nets/wg10/remove", API + "/nets/eth0/remove", API + "/nets/wg0/peers/-x/remove",
                     API + "/nets/wg0/peers/a%2Fb/remove", API + "/nets/wg0%0A/remove", API + "/nets/wg0/peers/" + "x" * 33 + "/dns"):
            with self.subTest(path=path):
                self.assertEqual(master_api.match("POST", path), (None, None))

    def test_state_answers_its_shape_with_networks_peers_and_defaults(self):
        def run(argv, binary=False, timeout=120):
            if argv[-1] == "nets":
                return 0, NET + "\t1\t1\n", ""
            if argv[1:] == ["--if", "wg0", "info"]:
                return 0, PEER % 0 + "\n", ""
            raise AssertionError(argv)
        with patch.object(self.p, "run_tool", side_effect=run):
            status, head, raw = self.call(API + "/state")
        self.assertEqual(status, 200, raw)
        answer = json.loads(raw)
        master_api.check(master_api.ref("WireGuard"), answer)
        self.assertEqual((answer["kurulu"], answer["durduruldu"], answer["endpoint"], answer["max"]), (True, False, "203.0.113.7", 10))
        # wg0 holds the default port: a later network is offered the first free one from WG_PORT_NEXT.
        self.assertEqual(answer["defaults"], {"dns": "1.1.1.1, 1.0.0.1", "keepalive": 21, "mtu": 1420, "port": 61020})
        self.assertEqual(answer["reserved"], [22, 53, 80, 41641, 61001])
        net = answer["networks"][0]
        self.assertEqual((net["iface"], net["label"], net["active"], net["count"]), ("wg0", "Ev ağı", True, 1))
        self.assertEqual(net["revision"], hashlib.sha256(NET.encode()).hexdigest())
        self.assertEqual((net["peers"][0]["name"], net["peers"][0]["provider"], net["peers"][0]["online"]), ("phone", "Cloudflare", False))
        # DD-275: the settings revision a planned action sends; "" without the settings keys (refused as stale).
        self.assertEqual(answer["revizyon"], "")
        with patch.object(self.p, "run_tool", side_effect=run), patch.object(panel.master_settings, "Manager") as manager:
            manager.return_value.revision.return_value = "a" * 64
            self.assertEqual(json.loads(self.call(API + "/state")[2])["revizyon"], "a" * 64)
        manager.assert_called_once_with(str(self.state))

    def test_kurulu_is_false_only_when_master_wg_does_not_work(self):
        with patch.object(self.p, "run_tool", return_value=(127, "", "master-wg çalıştırılamadı")):
            status, _head, raw = self.call(API + "/state")
        answer = json.loads(raw)
        self.assertEqual((status, answer["kurulu"], answer["networks"]), (200, False, []))
        master_api.check(master_api.ref("WireGuard"), answer)
        # The tool works but cannot list its networks: that is an error, not "not installed".
        with patch.object(self.p, "run_tool", side_effect=lambda argv, **_: (0, "", "") if argv[-1] == "version" else (1, "", "kayıt bozuk")):
            status, _head, raw = self.call(API + "/state")
        self.assertEqual((status, json.loads(raw)["error"]), (502, "kayıt bozuk"))

    def test_missing_keys_answer_503_and_run_nothing(self):
        self.state.write_text("LOCAL_DOMAIN=test\n")
        with patch.object(self.p, "run_tool", side_effect=AssertionError("must not run")):
            status, _head, raw = self.call(API + "/state")
        self.assertEqual(status, 503)
        self.assertIn("kurulumu yeniden çalıştırın", json.loads(raw)["error"])

    def test_the_gates_stay_in_front(self):
        with patch.object(self.p, "run_tool", side_effect=AssertionError("must not run")):
            for headers in ({"X-Konsol": ""}, {"Host": "evil.test"}, {"Sec-Fetch-Site": "cross-site"}):
                with self.subTest(headers=headers):
                    self.assertEqual(self.call(API + "/nets/wg0/peers/phone/durum", {"on": True}, headers)[0], 403)
            for path in ("/nets/notwg/peers/phone/durum", "/nets/wg0/peers/../durum", "/nets/wg0/unknown"):
                with self.subTest(path=path):
                    self.assertIn(self.call(API + path, {"on": True})[0], (400, 404))

    def test_the_planned_actions_have_no_route_of_their_own(self):
        """DD-275: starting, stopping, adding, removing, opening, closing and regenerating are settings
        actions; their old paths are outside the table and answer 404 without running anything."""
        removed = ((API + "/durdur", {}), (API + "/baslat", {}), (API + "/nets", {"port": 61020, "dns": "1.1.1.1"}),
                   (API + "/nets/wg0/remove", {"confirm": "onayla"}), (API + "/nets/wg0/reset", {"confirm": "onayla"}),
                   (API + "/nets/wg0/durum", {"on": True}))
        with patch.object(self.p, "run_tool", side_effect=AssertionError("must not run")), \
                patch.object(self.p, "settings_run", side_effect=AssertionError("must not run")):
            for path, data in removed:
                with self.subTest(path=path):
                    self.assertEqual(master_api.match("POST", path), (None, None))
                    self.assertEqual(self.call(path, data)[0], 404)
        for name in ("halt_all", "resume", "add_network", "remove_network", "switch_network", "reset_network"):
            self.assertFalse(hasattr(master_wireguard.WireGuard, name), name)
        for name in ("WireGuardCalismasi", "WireGuardAgEklendi", "WireGuardAgKaldirildi", "WireGuardAgDurumu",
                     "WireGuardYenidenUretildi", "Onay"):
            self.assertNotIn(name, master_api.SCHEMAS)


class NetworkTests(Fixture):
    def test_settings_go_to_the_tool_once_with_the_revision(self):
        data = {"dns": "9.9.9.9, 2620:fe::fe", "revision": "a" * 64}
        self.p.settings_cache = (1, {"old": True})
        with patch.object(self.p, "run_tool", return_value=(0, "", "")) as run:
            status, answer = self.post("/nets/wg0/ayarlar", data)
            self.assertEqual((status, answer), (200, {"iface": "wg0", "dns": data["dns"]}))
            self.assertEqual(self.calls(run), [[self.tool, "--if", "wg0", "net-settings", data["dns"], data["revision"]]])
            run.reset_mock()
            self.assertEqual(self.post("/nets/wg0/ayarlar", dict(data, label="Ev ağı"))[1]["label"], "Ev ağı")
            self.assertEqual(self.calls(run)[-1][-1], "Ev ağı")
            self.assertEqual(self.post("/nets/wg0/ayarlar", dict(data, label=""))[0], 200, "an empty name is allowed")
        self.assertEqual(self.p.settings_cache, (0, None))
        with patch.object(self.p, "run_tool", side_effect=AssertionError("must not run")):
            for override in ({"label": " baş"}, {"label": "son "}, {"label": "iki\tsütun"}, {"label": "x" * 65},
                             {"label": "ş" * 33}, {"label": None}, {"label": 5}, {"scope": "all"}, {"dns": None},
                             {"dns": "dns.example"}, {"dns": "999.1.1.1"}, {"dns": "1.1.1.1\n9.9.9.9"}, {"dns": "1.1.1.1,,"},
                             {"dns": ":::"}, {"dns": "fe80::1%eth0"}, {"dns": ", ".join(["1.1.1.1"] * 9)},
                             {"revision": None}, {"revision": "bad"}):
                with self.subTest(override=override):
                    self.assertEqual(self.post("/nets/wg0/ayarlar", dict(data, **override))[0], 400)
        with patch.object(self.p, "run_tool", return_value=(1, "", "Ağ ayarları değişmiş")):
            status, answer = self.post("/nets/wg0/ayarlar", data)
        self.assertEqual((status, answer["error"]), (409, "Ağ ayarları değişmiş"))


class DeviceTests(Fixture):
    def test_a_device_is_added_and_its_audit_line_names_it(self):
        with patch.object(self.p, "run_tool", return_value=(0, "phone\t10.8.0.3\n", "")) as run, patch("builtins.print") as out:
            status, answer = self.post("/nets/wg0/peers", {"name": "phone", "dns": "1.1.1.1", "keepalive": 21, "mtu": 1420})
        self.assertEqual((status, answer), (201, {"name": "phone", "ipv4": "10.8.0.3"}))
        self.assertEqual(self.calls(run), [[self.tool, "--if", "wg0", "add", "phone", "1.1.1.1", "21", "1420"]])
        lines = [str(c.args[0]) for c in out.call_args_list if "wireguard-ekle" in str(c.args[0])]
        self.assertEqual(len(lines), 1, out.call_args_list)
        self.assertIn(" wireguard-ekle wg0/phone -> ok", lines[0])
        with patch.object(self.p, "run_tool", side_effect=AssertionError("must not run")):
            for bad in ({"name": "-x", "dns": "1.1.1.1", "keepalive": 21, "mtu": 1420},
                        {"name": "phone", "dns": "1.1.1.1", "keepalive": "21", "mtu": 1420},
                        {"name": "phone", "dns": "", "keepalive": 21, "mtu": 1420},
                        {"name": "phone", "dns": "1.1.1.1", "keepalive": -1, "mtu": 1420},
                        {"name": "phone", "dns": "1.1.1.1", "keepalive": 21, "mtu": 0}):
                with self.subTest(bad=bad):
                    self.assertEqual(self.post("/nets/wg0/peers", bad)[0], 400)

    def test_device_changes_go_to_the_tool(self):
        cases = (("/nets/wg0/peers/phone/remove", {}, ["--if", "wg0", "remove", "phone"], "wireguard-cikar wg0/phone"),
                 ("/nets/wg0/peers/phone/durum", {"on": False}, ["--if", "wg0", "peer", "phone", "kapat"],
                  "wireguard-peer-durum wg0/phone kapatıldı"),
                 ("/nets/wg0/peers/phone/keepalive", {"keepalive": 25}, ["--if", "wg0", "keepalive", "phone", "25"],
                  "wireguard-keepalive wg0/phone 25"),
                 ("/nets/wg0/peers/phone/dns", {"dns": "9.9.9.9"}, ["--if", "wg0", "dns", "phone", "9.9.9.9"], "wireguard-dns wg0/phone"))
        for path, data, argv, line in cases:
            with self.subTest(path=path), patch.object(self.p, "run_tool", return_value=(0, "", "")) as run, \
                    patch("builtins.print") as out:
                self.assertEqual(self.post(path, data), (200, {"ok": True}))
                self.assertEqual(self.calls(run), [[self.tool] + argv])
                self.assertTrue(any(" %s -> ok" % line in str(c.args[0]) for c in out.call_args_list), out.call_args_list)
        with patch.object(self.p, "run_tool", side_effect=AssertionError("must not run")):
            for path, data in (("/nets/wg0/peers/phone/keepalive", {"keepalive": "x"}), ("/nets/wg0/peers/phone/keepalive", {"keepalive": -1}),
                               ("/nets/wg0/peers/phone/dns", {"dns": " "}), ("/nets/wg0/peers/phone/remove", {"x": 1})):
                with self.subTest(path=path, data=data):
                    self.assertEqual(self.post(path, data)[0], 400)
        with patch.object(self.p, "run_tool", return_value=(1, "", "peer yok")):
            self.assertEqual(self.post("/nets/wg0/peers/phone/remove", {}), (400, {"error": "peer yok"}))

    def test_profile_and_qr_are_downloads_only_on_request(self):
        with patch.object(self.p, "run_tool", return_value=(0, "[Interface]\nPrivateKey = SECRET\n", "")) as run, \
                patch("builtins.print") as out:
            status, head, body = self.call(API + "/nets/wg0/peers/phone/profile")
        self.assertEqual((status, head["Content-Type"], head["Content-Disposition"]),
                         (200, "text/plain; charset=utf-8", 'attachment; filename="phone.conf"'))
        self.assertEqual(head["Cache-Control"], "no-store")
        self.assertIn(b"SECRET", body)
        self.assertEqual(self.calls(run), [[self.tool, "--if", "wg0", "profile", "phone"]])
        self.assertTrue(any(" wireguard-profil wg0/phone -> ok" in str(c.args[0]) for c in out.call_args_list))
        self.assertFalse(any("SECRET" in str(c.args) for c in out.call_args_list), "a key never reaches the journal")
        with patch.object(self.p, "run_tool", return_value=(0, b"\x89PNG\r\n\x1a\nDATA", "")) as run:
            status, head, body = self.call(API + "/nets/wg0/peers/phone/qr.png")
        self.assertEqual((status, head["Content-Type"], body[:4]), (200, "image/png", b"\x89PNG"))
        self.assertEqual(run.call_args.kwargs.get("binary"), True)
        with patch.object(self.p, "run_tool", return_value=(0, b"not a png", "")):
            self.assertEqual(self.call(API + "/nets/wg0/peers/phone/qr.png")[0], 404)
        with patch.object(self.p, "run_tool", return_value=(1, "", "profil yok")):
            self.assertEqual(self.call(API + "/nets/wg0/peers/phone/profile")[0], 404)


class SettingsActionTests(Fixture):
    """DD-275: the WireGuard section reaches the settings routes with its shape checked, and the audit line
    names the action (the request's on apply, the pending change's on confirm, rollback and discard)."""

    def settings_post(self, path, data):
        status, _head, raw = self.call("/api/konsol/ayarlar/" + path, data)
        return status, json.loads(raw)

    def test_the_audit_line_names_the_wireguard_action(self):
        with patch.object(self.p, "settings_run", return_value=(200, {"pending": None, "committed": True})) as run, \
                patch("builtins.print") as out:
            body = {"revision": "r", "wireguard": {"eylem": "ag-kaldir", "iface": "wg0", "onay": "onayla"}}
            self.assertEqual(self.settings_post("uygula", body)[0], 200)
            self.assertEqual(run.call_args.args, ("apply", dict(body, kanal="yerel")))
            self.settings_post("uygula", {"revision": "r", "wireguard": {"eylem": "ag-ekle", "ag": {"port": 61020, "dns": "1.1.1.1"}}})
            self.settings_post("uygula", {"revision": "r", "firewall": []})
        lines = [str(c.args[0]) for c in out.call_args_list if " ayar-apply " in str(c.args[0])]
        self.assertEqual([line.split(" ayar-apply ", 1)[1] for line in lines],
                         ["wireguard ag-kaldir wg0 -> ok", "wireguard ag-ekle UDP 61020 -> ok", "ayarlar -> ok"])
        pending = {"bekleyen": {"id": "a" * 32, "phase": "awaiting", "seconds": 40, "wireguard": {"eylem": "ag-ekle", "iface": "wg1"}}}
        with patch.object(self.p, "settings_run", return_value=(400, {"error": "x"})), patch.object(self.p, "pending", return_value=pending), \
                patch("builtins.print") as out:
            self.settings_post("geri-al", {"id": "a" * 32})
        self.assertTrue(any(" ayar-rollback wireguard ag-ekle wg1 -> hata" in str(c.args[0]) for c in out.call_args_list),
                        out.call_args_list)

    def test_apply_carries_caddy_s_channel_and_never_the_body_s(self):
        """The worker refuses a timed change asked from the internet (master_settings.TIMED_FROM_INTERNET): the
        channel it gets is the one Caddy wrote; a body that names one is not a settings request."""
        body = {"revision": "r", "wireguard": {"eylem": "ag-ac", "iface": "wg0"}}
        answers = []
        handler = types.SimpleNamespace(channel=lambda: "internet", panel=self.p, audit=lambda *a: None,
                                        json=lambda code, result: answers.append(code))
        with patch.object(self.p, "settings_run", return_value=(400, {"error": "x"})) as run:
            panel.Handler.settings_action(handler, "konsol", "apply", dict(body, kanal="tailscale"))
        self.assertEqual(run.call_args.args, ("apply", dict(body, kanal="internet")))
        self.assertEqual(answers, [400])
        # Over HTTP a body that names a channel is no settings request: it never reaches the worker.
        with patch.object(self.p, "settings_run", side_effect=AssertionError("must not run")), patch("builtins.print"):
            self.assertEqual(self.settings_post("uygula", dict(body, kanal="tailscale"))[0], 400)

    def test_the_section_shape_is_checked_before_the_worker(self):
        with patch.object(self.p, "settings_run", side_effect=AssertionError("must not run")):
            for item in ({"eylem": "sil"}, {"eylem": "baslat", "x": 1}, {"eylem": "ag-ekle", "ag": {"port": "61020", "dns": "1.1.1.1"}},
                         {"eylem": "ag-kaldir", "iface": 0}, {"eylem": "ag-kaldir", "iface": "wg0", "onay": True}, {}):
                with self.subTest(item=item):
                    self.assertEqual(self.settings_post("uygula", {"revision": "r", "wireguard": item})[0], 400)

    def test_a_stale_page_is_409(self):
        stale = panel.master_settings.SettingsStale("Ayarlar değişmiş. Yenileyip yeniden inceleyin.")
        with patch.object(panel.master_settings.Manager, "__init__", return_value=None), \
                patch.object(panel.master_settings.Manager, "plan", side_effect=stale):
            self.assertEqual(self.settings_post("plan", {"revision": "old", "wireguard": {"eylem": "durdur"}}),
                             (409, {"error": "Ayarlar değişmiş. Yenileyip yeniden inceleyin."}))


class ReadTests(Fixture):
    """The networks the Erişim view, the firewall view, the port catalogue and health read."""

    def test_the_port_offered_for_a_new_network_comes_from_the_base(self):
        """defaults.port: WG_PORT_DEFAULT for the first network while it is free, else the first free port from
        WG_PORT_NEXT (both in config/defaults.env); 0 when none is free."""
        env = {"WG_PORT_DEFAULT": "61001", "WG_PORT_NEXT": "61020"}
        self.assertEqual(master_wireguard.suggest_port(env, [], {22, 53}), 61001)
        self.assertEqual(master_wireguard.suggest_port(env, [], {61001}), 61020)
        self.assertEqual(master_wireguard.suggest_port(env, [{"iface": "wg0"}], {61001, 61020, 61021}), 61022)
        self.assertEqual(master_wireguard.suggest_port(dict(env, WG_PORT_NEXT="65535"), [{"iface": "wg0"}], {65535}), 0)
        self.assertNotIn("61020", (Path(__file__).resolve().parents[1] / "tools/konsol-ui/src/pages/erisim/wg.ts").read_text())

    def test_networks_carry_public_fields_only_and_none_while_stopped(self):
        self.networks.write_text(NET + "\n")
        with patch.object(self.p, "run_tool", return_value=(0, NET + "\t1\t2\n", "")):
            nets = self.p.wireguard.networks()
            self.assertEqual(nets, [{"iface": "wg0", "port": 61001, "label": "Ev ağı", "active": True,
                                     "server4": "10.8.0.1", "server6": "fdcc::1", "open": True}])
            ports = self.p.ports(panel.read_env(str(self.state)), nets)
        self.assertIn({"port": 61001, "proto": "udp", "scope": "internet", "vpn": True, "name": "WireGuard wg0 · Ev ağı"}, ports)
        self.stopped.write_text("wg0\n")
        with patch.object(self.p, "run_tool", side_effect=AssertionError("a stopped WireGuard is not asked")):
            self.assertEqual(self.p.wireguard.networks(), [])
        self.stopped.unlink()
        self.networks.unlink()
        with patch.object(self.p, "run_tool", side_effect=AssertionError("no network, nothing to ask")):
            self.assertEqual(self.p.wireguard.networks(), [])

    def test_the_registry_is_read_strictly(self):
        env = panel.read_env(str(self.state))
        self.assertEqual(master_wireguard.registered(env), [])
        self.networks.write_text(NET + "\n" + NET.replace("wg0", "wg1") + "\n")
        self.assertEqual(master_wireguard.registered(env), ["wg0", "wg1"])
        for bad in ("wg0\t61001\n", NET.replace("inet", "lan"), NET.replace("wg0", "eth0"), NET + "\n" + NET):
            with self.subTest(bad=bad):
                self.networks.write_text(bad + "\n")
                with self.assertRaises(ValueError):
                    master_wireguard.registered(env)
        self.assertFalse(master_wireguard.stopped(env))
        self.stopped.write_text("")
        self.assertTrue(master_wireguard.stopped(env))

    def test_health_requires_each_switched_on_network_unless_stopped(self):
        self.networks.write_text(NET + "\n")
        env = panel.read_env(str(self.state))
        shows = []

        def cmd(argv, timeout=10):
            if argv[:2] == ["systemctl", "show"]:
                shows.append(argv)
                blocks = ["Id=%s\nLoadState=loaded\nActiveState=active\nUnitFileState=enabled" % u for u in argv[4:]]
                return 0, "\n\n".join(blocks)
            return 0, ""
        with patch.object(self.p, "health_cmd", side_effect=cmd):
            self.assertEqual(self.p.health_units(env)[0], "ok")
            self.assertIn("wg-quick@wg0.service", shows[-1])
            self.stopped.write_text("wg0\n")
            self.p.health_units(env)
            self.assertNotIn("wg-quick@wg0.service", shows[-1])
            self.stopped.unlink()
            self.networks.write_text("bozuk\n")
            status, detail = self.p.health_units(env)
        self.assertEqual(status, "warn")
        self.assertIn("WireGuard ağ kaydı okunamadı", detail)


if __name__ == "__main__":
    unittest.main()
