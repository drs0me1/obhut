"""DD-265: the Yayınla flow's read model and plan (master_yayin), and the phase 3 routes of the root backend:
the settings transaction's plan and writes from the route table, the firewall and DNS-name views, the
publication candidates and plan. No real Caddy, systemd, Podman or DNS: the backend's sources are faked
with the shapes they return; documentation addresses only."""
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import test_resources
from test_overview import Fixture

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_api  # noqa: E402
import master_settings  # noqa: E402
import master_yayin  # noqa: E402

panel = test_resources.panel
ENV = {"LOCAL_DOMAIN": "ev", "WAN_IPV4": "203.0.113.10", "YAYIN_PORT_ILK": "62100", "YAYIN_PORT_SON": "62102"}
ROWS = [
    {"service": "panel", "name": "Panel", "local": "panel.ev", "tail": True, "enabled": False, "domain": "", "installed": True,
     "running": True, "account": False, "status": "disabled", "message": "İnternet yayını kapalı.", "expires": None},
    {"service": "torrent", "name": "qBittorrent", "local": "torrent.ev", "tail": True, "enabled": True,
     "domain": "torrent.example.org", "installed": True, "running": True, "status": "ready", "message": "Sertifika doğrulandı.",
     "expires": 1790000000},
    {"service": "gezgin", "name": "Gezgin", "local": "gezgin.ev", "tail": True, "enabled": False, "domain": "",
     "installed": True, "running": False, "status": "disabled", "message": "İnternet yayını kapalı.", "expires": None},
    {"service": "elle-notlar", "name": "Notlar", "local": "notlar.ev", "manual": True, "upstream": "127.0.0.1:8090",
     "tail": True, "enabled": False, "domain": "", "installed": True, "running": True, "answers": True,
     "status": "disabled", "message": "İnternet yayını kapalı.", "expires": None},
    {"service": "elle-yazici", "name": "Yazıcı", "local": "yazici.ev", "manual": True, "upstream": "127.0.0.1:631",
     "tail": True, "enabled": False, "domain": "", "installed": True, "running": True, "answers": False,
     "status": "disabled", "message": "Hedef yanıt vermiyor.", "expires": None},
    {"service": "paylasim", "name": "WebDAV", "local": "paylas.ev", "tail": True, "enabled": False, "domain": "",
     "installed": True, "running": True, "status": "disabled", "message": "İnternet yayını kapalı.", "expires": None, "mode": "off"},
]
PACKAGES = {"torrent": {"name": "qBittorrent", "local": "torrent", "upstream": "127.0.0.1:62947", "check": "yayin.py", "order": 20},
            "gezgin": {"name": "Gezgin", "local": "gezgin", "upstream": "127.0.0.1:62983", "check": "yayin.py", "order": 30}}
CONTAINERS = {"runtime": {"ok": True}, "containers": [
    {"name": "qbittorrent", "module_id": "torrent", "source": "appstore", "state": "running", "ports": []},
    {"name": "notlar", "module_id": None, "source": "konsol", "state": "running",
     "ports": [{"scope": "local", "host_ip": "127.0.0.1", "host_port": 8090, "container_port": 80, "protocol": "tcp"}]},
    {"name": "medya", "module_id": None, "source": "konsol", "state": "running",
     "ports": [{"scope": "tailscale", "host_ip": "100.64.0.2", "host_port": 8096, "container_port": 8096, "protocol": "tcp"},
               {"scope": "tailscale", "host_ip": "100.64.0.2", "host_port": 7359, "container_port": 7359, "protocol": "udp"}]},
    {"name": "dis", "module_id": None, "source": "external", "state": "running", "ports": []},
]}
DETAIL = {"config": {"name": "medya", "image": "docker.io/library/nginx:1.27", "network": "bridge", "user": "downloads",
                     "ports": [{"scope": "tailscale", "host_port": 8096, "container_port": 8096, "protocol": "tcp", "public_ack": False}],
                     "environment": [{"name": "TOKEN", "secret": True, "present": True}]},
          "revision": "r" * 32, "actions": ["stop", "restart", "save", "remove", "image-update"]}


def cands(rows=ROWS, containers=CONTAINERS, wan=True):
    return master_yayin.candidates(ENV, copy.deepcopy(rows), PACKAGES, copy.deepcopy(containers), wan)


def by_id(items, cid):
    return next(i for i in items if i["id"] == cid)


class CandidateTests(unittest.TestCase):
    def test_every_publication_and_container_in_one_list(self):
        items = cands()
        for c in items:
            master_api.check(master_api.ref("YayinAdayi"), c)
        self.assertEqual([c["id"] for c in items], ["panel", "paket:torrent", "paket:gezgin", "konteyner:notlar",
                                                    "konteyner:medya", "konteyner:dis", "elle:yazici", "paylasim"])
        panel_row = by_id(items, "panel")
        self.assertEqual((panel_row["onay_kelimesi"], panel_row["giris"]), (True, master_yayin.GUARD_KONSOL))
        self.assertIn("Konsol hesabı", panel_row["internet_engel"], "no account: the public name cannot open")
        torrent = by_id(items, "paket:torrent")
        self.assertEqual((torrent["servis"], torrent["internet"], torrent["alan_adi"], torrent["durum"], torrent["hedef"]),
                         ("torrent", True, "torrent.example.org", "ready", "127.0.0.1:62947"))
        self.assertIn("denetler", torrent["giris"], "a package with a login check")
        self.assertIn("durdurulmuş", by_id(items, "paket:gezgin")["internet_engel"])
        self.assertEqual(by_id(items, "paylasim")["giris"], master_yayin.GUARD_SHARES)

    def test_containers_join_their_manual_address_or_offer_a_loopback_port(self):
        items = cands()
        notes = by_id(items, "konteyner:notlar")
        self.assertEqual((notes["servis"], notes["hedef"], notes["konteyner"]["yerel_portlar"]),
                         ("elle-notlar", "127.0.0.1:8090", [{"host_port": 8090, "container_port": 80}]))
        self.assertNotIn("elle:notlar", [c["id"] for c in items], "joined, not listed twice")
        media = by_id(items, "konteyner:medya")
        self.assertEqual((media["servis"], media["kullanilabilir"], media["konteyner"]["port_eklenebilir"],
                          media["konteyner"]["onerilen_port"]), (None, True, True, 8096))
        self.assertEqual(media["konteyner"]["diger_portlar"], [{"kapsam": "tailscale", "host_port": 8096, "container_port": 8096}],
                         "a UDP port is not a web interface")
        outside = by_id(items, "konteyner:dis")
        self.assertEqual((outside["kullanilabilir"], outside["konteyner"]["kaynak"]), (False, "dis"))
        self.assertIn("sahiplenin", outside["neden"])

    def test_no_public_address_blocks_every_internet_name(self):
        items = cands(wan=False)
        self.assertTrue(all("IPv4" in c["internet_engel"] for c in items))

    def test_default_tailnet_names(self):
        for name, local in (("medya", "medya"), ("Media_Server 2", "media-server-2"), ("1password", "k-1password"),
                            ("___", "k"), ("x" * 40, "x" * 31)):
            with self.subTest(name=name):
                self.assertEqual(master_yayin.default_local(name), local)
                self.assertRegex(master_yayin.default_local(name), master_yayin.PUB_LOCAL_RE)


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.items = cands()
        self.seen = []

    def settings_plan(self, data):
        self.seen.append(data)
        return {"revizyon": data["revision"], "onay_sn": 0, "degisiklikler": [], "etkiler": [], "uyarilar": [], "uygulanabilir": True}

    def plan(self, request, settings_plan=None, detail=lambda name: copy.deepcopy(DETAIL), port=lambda: 62101):
        result = master_yayin.plan(ENV, request, self.items, settings_plan or self.settings_plan, detail, port)
        master_api.check(master_api.ref("YayinPlani"), result)
        return result

    def request(self, hedef, **kw):
        return dict(dict(hedef=hedef, revizyon="v1", tailscale=True, internet=True, alan_adi="Medya.Example.org"), **kw)

    def test_a_publication_row_is_one_settings_step(self):
        result = self.plan(self.request("paket:torrent", alan_adi="torrent2.example.org"))
        self.assertEqual([s["tur"] for s in result["adimlar"]], ["ayar"])
        self.assertEqual(result["adimlar"][0]["istek"], {"revision": "v1", "web": {
            "service": "torrent", "tail": True, "enabled": True, "domain": "torrent2.example.org"}})
        self.assertEqual(result["dns"], {"ad": "torrent2.example.org", "tur": "A", "deger": "203.0.113.10"})
        self.assertEqual(result["engel"], "")
        # The console needs the typed word; it travels only for the console.
        result = self.plan(self.request("panel", onay="onayla"))
        self.assertEqual(result["adimlar"][-1]["istek"]["web"]["confirm"], "onayla")
        self.assertIn("Konsol hesabı", result["engel"], "no account: the plan says why it cannot open")
        closing = self.plan(self.request("panel", internet=False, alan_adi="", onay="onayla"))
        self.assertEqual((closing["engel"], closing["dns"]), ("", None))

    def test_a_container_without_a_loopback_port_gets_one_first(self):
        result = self.plan(self.request("konteyner:medya", yerel="medya"))
        container, row = result["adimlar"]
        self.assertEqual(container["tur"], "konteyner")
        self.assertEqual(container["istek"]["action"], "save")
        self.assertEqual((container["istek"]["name"], container["istek"]["revision"]), ("medya", "r" * 32))
        self.assertEqual(container["istek"]["config"]["ports"][-1],
                         {"scope": "local", "host_port": 62101, "container_port": 8096, "protocol": "tcp", "public_ack": False})
        self.assertEqual(container["istek"]["config"]["environment"], DETAIL["config"]["environment"],
                         "a secret value stays on the server; the save keeps it")
        self.assertEqual(row["istek"]["web"], {"service": "elle-medya", "tail": True, "enabled": True, "domain": "medya.example.org",
                                               "elle": {"name": "medya", "local": "medya", "upstream": "127.0.0.1:62101"}})
        self.assertIn(master_yayin.GUARD_APP, [w["metin"] for w in result["uyarilar"]])
        self.assertTrue(any("İki adım" in w["metin"] for w in result["uyarilar"]))
        self.assertFalse(any("çalışmıyor" in w["metin"] for w in result["uyarilar"]))
        stopped = copy.deepcopy(CONTAINERS)
        stopped["containers"][2]["state"] = "exited"
        self.items = cands(containers=stopped)
        self.assertTrue(any("çalışmıyor" in w["metin"] for w in self.plan(self.request("konteyner:medya"))["uyarilar"]),
                        "a stopped container keeps its state; the name answers once it runs")
        self.items = cands()
        # A container with a loopback port and its manual address: only the row.
        result = self.plan(self.request("konteyner:notlar"))
        self.assertEqual([s["tur"] for s in result["adimlar"]], ["ayar"])
        self.assertEqual(result["adimlar"][0]["istek"]["web"]["service"], "elle-notlar")

    def test_refusals_and_a_failing_check(self):
        for request, text in ((self.request("konteyner:yok"), "bulunamadı"),
                              (self.request("konteyner:dis"), "sahiplenin"),
                              (self.request("konteyner:medya", yerel="Medya!"), "Tailscale adı"),
                              (self.request("konteyner:medya", ad=""), None)):
            with self.subTest(request=request):
                if text is None:
                    self.plan(request)  # an empty display name falls back to the container's
                    continue
                with self.assertRaisesRegex(master_settings.SettingsError, text):
                    self.plan(request)
        no_hint = copy.deepcopy(CONTAINERS)
        no_hint["containers"][2]["ports"] = []
        self.items = cands(containers=no_hint)
        with self.assertRaisesRegex(master_settings.SettingsError, "konteyner içinde dinlediği port"):
            self.plan(self.request("konteyner:medya"))
        self.assertEqual(self.plan(self.request("konteyner:medya", konteyner_portu=3000))["adimlar"][0]["istek"]["config"]["ports"][-1]
                         ["container_port"], 3000)
        none = copy.deepcopy(DETAIL)
        none["config"]["network"] = "none"
        with self.assertRaisesRegex(master_settings.SettingsError, "Ağsız"):
            self.plan(self.request("konteyner:medya", konteyner_portu=3000), detail=lambda name: none)

        def refuse(data):
            raise master_settings.SettingsError("torrent.example.org adı 203.0.113.10 adresine çözülmüyor.")
        self.items = cands()
        result = self.plan(self.request("paket:torrent"), settings_plan=refuse)
        self.assertEqual((result["plan"], result["engel"]), (None, "torrent.example.org adı 203.0.113.10 adresine çözülmüyor."))

    def test_free_port_skips_used_and_held_ports(self):
        self.assertEqual(master_yayin.free_port(ENV, {62100}, bind=lambda port: port != 62101), 62102)
        with self.assertRaisesRegex(master_settings.SettingsError, "boş port"):
            master_yayin.free_port(ENV, {62100, 62101, 62102}, bind=lambda port: True)
        with self.assertRaisesRegex(master_settings.SettingsError, "aralığı"):
            master_yayin.free_port({}, set(), bind=lambda port: True)


class RouteTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)
        with self.state.open("a") as fh:  # the settings manager's own files (never written here)
            for key, name in (("SETTINGS_FILE", "settings.json"), ("SETTINGS_PENDING_FILE", "pending.json"),
                              ("SETTINGS_DNS_FILE", "dns.conf")):
                fh.write("%s=%s\n" % (key, self.root / name))
        self.addCleanup(patch.stopall)

    def call(self, path, data=None, headers=None):
        route = master_api.find("POST" if data is not None else "GET", path.split("?")[0])
        body = None if data is None else json.dumps(data).encode()
        status, _, raw = test_resources.unix_get(self.sock, path, {"X-Konsol": "1", "Content-Type": "application/json", **(headers or {})},
                                                 "POST" if data is not None else "GET", body)
        answer = json.loads(raw)
        if status == route.status:
            master_api.check(route.reply, answer)
        return status, answer

    def test_settings_writes_go_to_the_same_workers_from_the_table(self):
        calls = []

        def run(action, data, shares=False):
            calls.append((action, dict(data)))
            return 200, {"pending": None, "committed": True} if action == "apply" else {"ok": True}
        patch.object(self.p, "settings_run", side_effect=run).start()
        self.assertEqual(self.call("/api/konsol/ayarlar/uygula", {"revision": "r", "dns": {"disabled": [], "records": [],
                                                                                              "forward": False, "servers": []}}),
                         (200, {"pending": None, "committed": True}))
        self.call("/api/konsol/ayarlar/onayla", {"id": "x"}, {"X-Forwarded-For": "100.64.0.9", "X-Forwarded-Host": "Panel.Test"})
        self.call("/api/konsol/ayarlar/geri-al", {"id": "x"})
        self.call("/api/konsol/ayarlar/birak", {"id": "x", "confirm": "onayla"})
        self.assertEqual([a for a, _ in calls], ["apply", "confirm", "rollback", "discard"])
        self.assertEqual(calls[1][1], {"id": "x", "client": "100.64.0.9", "host": "panel.test", "kanal": "tailscale"},
                         "only the confirmation carries the operator's address, name and channel")
        # A shape the transaction never takes is refused before the worker; the old page's https key passes.
        status, answer = self.call("/api/konsol/ayarlar/uygula", {"revision": "r", "firewall": [{"id": "x"}]})
        self.assertEqual(status, 400)
        self.assertIn("İstek biçimi geçersiz", answer["error"])
        self.call("/api/konsol/ayarlar/uygula", {"revision": "r", "https": {"domain": ""}})
        self.assertEqual(len(calls), 5)

    def test_plan_route_runs_the_managers_plan_with_the_channel(self):
        seen = []

        def plan(self_, data, client="", kanal=""):
            seen.append((data, client, kanal))
            return {"revizyon": "r", "onay_sn": 60, "degisiklikler": [], "etkiler": [], "uyarilar": [], "uygulanabilir": True}
        patch.object(master_settings.Manager, "plan", plan).start()
        # (The internet site's gate refuses a closed publication first; the channel's effect is a Manager test.)
        status, answer = self.call("/api/konsol/ayarlar/plan", {"revision": "r", "firewall": []}, {"X-Forwarded-For": "100.64.0.9"})
        self.assertEqual((status, answer["onay_sn"]), (200, 60))
        self.assertEqual(seen, [({"revision": "r", "firewall": []}, "100.64.0.9", "tailscale")])
        patch.object(master_settings.Manager, "plan", side_effect=master_settings.SettingsError("Değişiklik yok.")).start()
        self.assertEqual(self.call("/api/konsol/ayarlar/plan", {"revision": "r"}), (400, {"error": "Değişiklik yok."}))

    def test_firewall_and_names_views(self):
        view = {"firewall": {
            "ok": False, "check": "HATA: Konteyner yönlendirme koruması eksik veya güncel değil.", "vpn_name": "WireGuard",
            "networks": [{"app": "WireGuard", "iface": "wg0", "label": "home", "active": True, "server4": "10.8.0.1", "server6": ""}],
            "ports": [{"name": "SSH", "family": 4, "proto": "tcp", "port": 22, "scope": "wan", "baseline": True},
                      {"name": "qBittorrent", "family": 4, "proto": "tcp", "port": 63851, "scope": "wan", "baseline": True, "fixed": True},
                      {"name": "Diğer", "family": 6, "proto": "udp", "port": 5353, "scope": "lo", "baseline": True}],
            "listeners": [{"proto": "tcp", "family": 4, "port": 22, "address": "0.0.0.0", "scope": "any"}],
            "rules": {"rows": [{"family": 4, "table": "filter", "chain": "MASTER-INPUT", "position": 1, "packets": 5, "bytes": 300,
                                "spec": "-p tcp --dport 22 -j ACCEPT", "owner": "Konsol"}], "errors": ["IPv6 kuralları okunamadı"]}},
            "manage": {"revision": "rev-1", "config": {"firewall": [
                {"id": "r1", "name": "Oyun", "family": 4, "scope": "wan", "proto": "udp", "port": 27015, "source": "", "allow": True}]}}}
        patch.object(self.p, "settings", return_value=view).start()
        status, fw = self.call("/api/konsol/guvenlik-duvari")
        self.assertEqual(status, 200)
        self.assertEqual((fw["revizyon"], fw["denetim"]["ok"], fw["vpn"]), ("rev-1", False, "WireGuard"))
        self.assertEqual([(k["ad"], k["kapsam"], k["sabit"]) for k in fw["katalog"]],
                         [("SSH", "wan", False), ("qBittorrent", "wan", True), ("Diğer", "lo", False)])
        self.assertEqual(fw["teknik"][0]["sira"], "1")
        self.assertEqual(fw["kurallar"][0]["name"], "Oyun")
        self.assertEqual(fw["hatalar"], ["IPv6 kuralları okunamadı"])
        names = [{"name": "panel.test", "iface": "tailscale0", "family": None, "target": "tailscale", "source": "base"},
                 {"name": "torrent.test", "iface": "tailscale0", "family": 4, "target": "tailscale", "source": "torrent"}]
        patch.object(master_settings.Manager, "dns_names", return_value=names).start()
        patch.object(master_settings.Manager, "current", return_value={"firewall": [], "dns": {
            "disabled": ["torrent.test"], "records": [{"name": "nas.test", "target": "192.0.2.5", "enabled": True}],
            "forward": True, "servers": ["9.9.9.9"]}}).start()
        patch.object(master_settings.Manager, "revision", return_value="rev-2").start()
        status, adlar = self.call("/api/konsol/adlar")
        self.assertEqual(status, 200)
        self.assertEqual([(a["ad"], a["kapali"], a["kilitli"]) for a in adlar["adlar"]],
                         [("panel.test", False, True), ("torrent.test", True, False)])
        self.assertEqual((adlar["revizyon"], adlar["yonlendirme"], adlar["sunucular"]), ("rev-2", True, ["9.9.9.9"]))

    def test_publication_routes(self):
        patch.object(panel.master_publications, "status", return_value=copy.deepcopy(ROWS)).start()
        patch.object(panel.master_publications, "packages", return_value=PACKAGES).start()
        patch.object(panel.master_publications, "wan_ready", return_value=True).start()
        patch.object(master_settings.Manager, "revision", return_value="rev-3").start()
        status, listing = self.call("/api/konsol/yayinlar")
        self.assertEqual(status, 200)
        self.assertEqual((listing["revizyon"], listing["alan"]), ("rev-3", "test"))
        self.assertIn("paket:torrent", [c["id"] for c in listing["adaylar"]])
        seen = []

        def plan(self_, data, client="", kanal=""):
            seen.append(data)
            return {"revizyon": "rev-3", "onay_sn": 0, "degisiklikler": [], "etkiler": [], "uyarilar": [], "uygulanabilir": True}
        patch.object(master_settings.Manager, "plan", plan).start()
        status, result = self.call("/api/konsol/yayinlar/plan", {"hedef": "paket:torrent", "revizyon": "rev-3", "tailscale": True,
                                                                 "internet": False, "alan_adi": ""})
        self.assertEqual((status, result["engel"], [s["tur"] for s in result["adimlar"]]), (200, "", ["ayar"]))
        self.assertEqual(seen[0]["web"]["service"], "torrent")
        self.assertEqual(self.call("/api/konsol/yayinlar/plan", {"hedef": "paket:yok", "revizyon": "rev-3", "tailscale": True,
                                                                 "internet": False, "alan_adi": ""})[0], 400)
        self.assertEqual(self.call("/api/konsol/yayinlar/plan", {"hedef": "paket:torrent"})[0], 400, "the request's shape")

    def test_the_podman_pages_container_requests_pass_the_table(self):
        jobs = []
        patch.object(self.p.containers, "submit", side_effect=lambda data: jobs.append(data) or
                     {"id": "a" * 32, "action": data["action"], "name": data.get("name") or data.get("image"),
                      "state": "running", "step": "Başlatılıyor"}).start()
        for data in ({"action": "start", "name": "medya", "revision": None}, {"action": "image-remove", "image": "b" * 64},
                     {"action": "adopt", "name": "dis", "preview": True}):
            with self.subTest(data=data):
                self.assertEqual(self.call("/api/konsol/konteynerler/islem", data)[0], 202)
        self.assertEqual(jobs[0], {"action": "start", "name": "medya", "revision": None})


if __name__ == "__main__":
    unittest.main()
