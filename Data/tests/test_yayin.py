"""DD-265: the Yayınla flow's read model and plan (master_yayin), and the routes of the root backend:
the settings transaction's plan and writes from the route table, the firewall and DNS-name views, the
publication candidates and plan. DD-271 (phase 3): a container is published from a port it already listens on
at 127.0.0.1 (an application's address port); the step that added one to a container is gone. No real
Caddy, systemd, Podman or DNS: the backend's sources are faked with the shapes they return; documentation
addresses only."""
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
    {"service": "elle-notlar", "name": "Notlar", "local": "notlar.ev", "manual": True, "upstream": "127.0.0.1:8090",
     "tail": True, "enabled": False, "domain": "", "installed": True, "running": True, "answers": True,
     "status": "disabled", "message": "İnternet yayını kapalı.", "expires": None},
    {"service": "elle-yazici", "name": "Yazıcı", "local": "yazici.ev", "manual": True, "upstream": "127.0.0.1:631",
     "tail": True, "enabled": False, "domain": "", "installed": True, "running": True, "answers": False,
     "status": "disabled", "message": "Hedef yanıt vermiyor.", "expires": None},
    {"service": "paylasim", "name": "WebDAV", "local": "paylas.ev", "tail": True, "enabled": True,
     "domain": "dav.example.org", "installed": True, "running": True, "status": "ready", "message": "Sertifika doğrulandı.",
     "expires": 1790000000},
]
CONTAINERS = {"runtime": {"ok": True}, "containers": [
    {"name": "notlar_web", "source": "uygulama", "uygulama": "notlar", "state": "running",
     "ports": [{"scope": "local", "host_ip": "127.0.0.1", "host_port": 8090, "container_port": 80, "protocol": "tcp"}]},
    {"name": "medya_web", "source": "uygulama", "uygulama": "medya", "state": "running",
     "ports": [{"scope": "local", "host_ip": "127.0.0.1", "host_port": 62101, "container_port": 8096, "protocol": "tcp"},
               {"scope": "local", "host_ip": "127.0.0.1", "host_port": 62102, "container_port": 7359, "protocol": "udp"}]},
    {"name": "dis", "source": "external", "uygulama": None, "state": "running",
     "ports": [{"scope": "tailscale", "host_ip": "100.64.0.2", "host_port": 8097, "container_port": 80, "protocol": "tcp"}]},
]}


def cands(rows=ROWS, containers=CONTAINERS, wan=True):
    return master_yayin.candidates(ENV, copy.deepcopy(rows), copy.deepcopy(containers), wan)


def by_id(items, cid):
    return next(i for i in items if i["id"] == cid)


class CandidateTests(unittest.TestCase):
    def test_every_publication_and_container_in_one_list(self):
        items = cands()
        for c in items:
            master_api.check(master_api.ref("YayinAdayi"), c)
        self.assertEqual([c["id"] for c in items], ["panel", "konteyner:notlar_web", "konteyner:medya_web", "konteyner:dis",
                                                    "elle:yazici", "paylasim"])
        panel_row = by_id(items, "panel")
        self.assertEqual((panel_row["onay_kelimesi"], panel_row["giris"]), (True, master_yayin.GUARD_KONSOL))
        self.assertIn("Konsol hesabı", panel_row["internet_engel"], "no account: the public name cannot open")
        dav = by_id(items, "paylasim")
        self.assertEqual((dav["servis"], dav["internet"], dav["alan_adi"], dav["durum"], dav["giris"]),
                         ("paylasim", True, "dav.example.org", "ready", master_yayin.GUARD_SHARES))
        printer = by_id(items, "elle:yazici")
        self.assertEqual((printer["tur"], printer["servis"], printer["hedef"], printer["giris"]),
                         ("elle", "elle-yazici", "127.0.0.1:631", master_yayin.GUARD_APP))
        self.assertEqual({c["giris"] for c in items if c["tur"] == "konteyner"}, {master_yayin.GUARD_APP},
                         "only the application's own login guards a container")

    def test_containers_join_their_manual_address_or_offer_their_loopback_port(self):
        items = cands()
        notes = by_id(items, "konteyner:notlar_web")
        self.assertEqual((notes["servis"], notes["hedef"], notes["konteyner"]["yerel_portlar"], notes["konteyner"]["uygulama"]),
                         ("elle-notlar", "127.0.0.1:8090", [{"host_port": 8090, "container_port": 80}], "notlar"))
        self.assertNotIn("elle:notlar", [c["id"] for c in items], "joined, not listed twice")
        media = by_id(items, "konteyner:medya_web")
        self.assertEqual((media["servis"], media["kullanilabilir"], media["konteyner"]["kaynak"], media["konteyner"]["yerel_portlar"]),
                         (None, True, "uygulama", [{"host_port": 62101, "container_port": 8096}]), "a UDP port is not a web interface")
        outside = by_id(items, "konteyner:dis")
        self.assertEqual((outside["kullanilabilir"], outside["konteyner"]["kaynak"]), (False, "dis"))
        self.assertIn("127.0.0.1", outside["neden"])
        self.assertNotIn("port_eklenebilir", outside["konteyner"])

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

    def plan(self, request, settings_plan=None):
        result = master_yayin.plan(ENV, request, self.items, settings_plan or self.settings_plan)
        master_api.check(master_api.ref("YayinPlani"), result)
        return result

    def request(self, hedef, **kw):
        return dict(dict(hedef=hedef, revizyon="v1", tailscale=True, internet=True, alan_adi="Medya.Example.org"), **kw)

    def test_a_publication_row_is_one_settings_step(self):
        result = self.plan(self.request("paylasim", alan_adi="Dav2.example.org"))
        self.assertEqual([s["tur"] for s in result["adimlar"]], ["ayar"])
        self.assertEqual(result["adimlar"][0]["istek"], {"revision": "v1", "web": {
            "service": "paylasim", "tail": True, "enabled": True, "domain": "dav2.example.org"}})
        self.assertEqual(result["dns"], {"ad": "dav2.example.org", "tur": "A", "deger": "203.0.113.10"})
        self.assertEqual((result["engel"], result["uyarilar"]), ("", []), "the folder accounts guard WebDAV")
        # The console needs the typed word; it travels only for the console.
        result = self.plan(self.request("panel", onay="onayla"))
        self.assertEqual(result["adimlar"][-1]["istek"]["web"]["confirm"], "onayla")
        self.assertIn("Konsol hesabı", result["engel"], "no account: the plan says why it cannot open")
        closing = self.plan(self.request("panel", internet=False, alan_adi="", onay="onayla"))
        self.assertEqual((closing["engel"], closing["dns"]), ("", None))

    def test_a_container_is_published_from_its_loopback_port_in_one_step(self):
        result = self.plan(self.request("konteyner:medya_web", yerel="medya"))
        [row] = result["adimlar"]
        self.assertEqual(row["istek"]["web"], {"service": "elle-medya", "tail": True, "enabled": True, "domain": "medya.example.org",
                                               "elle": {"name": "medya_web", "local": "medya", "upstream": "127.0.0.1:62101"}})
        self.assertIn(master_yayin.GUARD_APP, [w["metin"] for w in result["uyarilar"]])
        self.assertFalse(any("çalışmıyor" in w["metin"] for w in result["uyarilar"]))
        stopped = copy.deepcopy(CONTAINERS)
        stopped["containers"][1]["state"] = "exited"
        self.items = cands(containers=stopped)
        self.assertTrue(any("çalışmıyor" in w["metin"] for w in self.plan(self.request("konteyner:medya_web"))["uyarilar"]),
                        "a stopped container keeps its state; the name answers once it runs")
        self.items = cands()
        # A container with a loopback port and its manual address: only the row.
        result = self.plan(self.request("konteyner:notlar_web"))
        self.assertEqual(result["adimlar"][0]["istek"]["web"]["service"], "elle-notlar")

    def test_refusals_and_a_failing_check(self):
        for request, text in ((self.request("konteyner:yok"), "bulunamadı"),
                              (self.request("konteyner:dis"), "127.0.0.1"),
                              (self.request("konteyner:medya_web", yerel="Medya!"), "Tailscale adı"),
                              (self.request("konteyner:medya_web", ad=""), None)):
            with self.subTest(request=request):
                if text is None:
                    self.plan(request)  # an empty display name falls back to the container's
                    continue
                with self.assertRaisesRegex(master_settings.SettingsError, text):
                    self.plan(request)

        def refuse(data):
            raise master_settings.SettingsError("dav.example.org adı 203.0.113.10 adresine çözülmüyor.")
        self.items = cands()
        result = self.plan(self.request("paylasim", alan_adi="dav.example.org"), settings_plan=refuse)
        self.assertEqual((result["plan"], result["engel"]), (None, "dav.example.org adı 203.0.113.10 adresine çözülmüyor."))


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
            "ok": False, "check": "HATA: Konteyner yönlendirme koruması eksik veya güncel değil.",
            "networks": [{"iface": "wg0", "label": "home", "active": True, "server4": "10.8.0.1", "server6": ""}],
            "ports": [{"name": "SSH", "family": 4, "proto": "tcp", "port": 22, "scope": "wan", "baseline": True},
                      {"name": "WireGuard wg0 · home", "family": 4, "proto": "udp", "port": 61001, "scope": "wan", "baseline": True,
                       "fixed": True},
                      {"name": "Diğer", "family": 6, "proto": "udp", "port": 5353, "scope": "lo", "baseline": True}],
            "listeners": [{"proto": "tcp", "family": 4, "port": 22, "address": "0.0.0.0", "scope": "any"}],
            "rules": {"rows": [{"family": 4, "table": "filter", "chain": "MASTER-INPUT", "position": 1, "packets": 5, "bytes": 300,
                                "spec": "-p tcp --dport 22 -j ACCEPT", "owner": "Konsol"}], "errors": ["IPv6 kuralları okunamadı"]}},
            "manage": {"revision": "rev-1", "config": {"firewall": [
                {"id": "r1", "name": "Oyun", "family": 4, "scope": "wan", "proto": "udp", "port": 27015, "source": "", "allow": True}]}}}
        patch.object(self.p, "settings", return_value=view).start()
        status, fw = self.call("/api/konsol/guvenlik-duvari")
        self.assertEqual(status, 200)
        self.assertEqual((fw["revizyon"], fw["denetim"]["ok"]), ("rev-1", False))
        self.assertEqual([(k["ad"], k["kapsam"], k["sabit"]) for k in fw["portlar"]],
                         [("SSH", "wan", False), ("WireGuard wg0 · home", "wan", True), ("Diğer", "lo", False)])
        self.assertEqual(fw["aglar"], [{"arayuz": "wg0", "ad": "home", "etkin": True}])
        self.assertEqual(fw["teknik"][0]["sira"], "1")
        self.assertEqual(fw["kurallar"][0]["name"], "Oyun")
        self.assertEqual(fw["hatalar"], ["IPv6 kuralları okunamadı"])
        names = [{"name": "panel.test", "iface": "tailscale0", "family": None, "target": "tailscale", "source": "base"},
                 {"name": "notlar.test", "iface": "tailscale0", "family": 4, "target": "tailscale", "source": "elle"}]
        patch.object(master_settings.Manager, "dns_names", return_value=names).start()
        patch.object(master_settings.Manager, "current", return_value={"firewall": [], "dns": {
            "disabled": ["notlar.test"], "records": [{"name": "nas.test", "target": "192.0.2.5", "enabled": True}],
            "forward": True, "servers": ["9.9.9.9"]}}).start()
        patch.object(master_settings.Manager, "revision", return_value="rev-2").start()
        status, adlar = self.call("/api/konsol/adlar")
        self.assertEqual(status, 200)
        self.assertEqual([(a["ad"], a["kapali"], a["kilitli"]) for a in adlar["adlar"]],
                         [("panel.test", False, True), ("notlar.test", True, False)])
        self.assertEqual((adlar["revizyon"], adlar["yonlendirme"], adlar["sunucular"]), ("rev-2", True, ["9.9.9.9"]))

    def test_publication_routes(self):
        patch.object(panel.master_publications, "status", return_value=copy.deepcopy(ROWS)).start()
        patch.object(panel.master_publications, "wan_ready", return_value=True).start()
        patch.object(master_settings.Manager, "revision", return_value="rev-3").start()
        status, listing = self.call("/api/konsol/yayinlar")
        self.assertEqual(status, 200)
        self.assertEqual((listing["revizyon"], listing["alan"]), ("rev-3", "test"))
        self.assertEqual([c["id"] for c in listing["adaylar"]], ["panel", "elle:notlar", "elle:yazici", "paylasim"],
                         "no container state: a manual address is its own row")
        seen = []

        def plan(self_, data, client="", kanal=""):
            seen.append(data)
            return {"revizyon": "rev-3", "onay_sn": 0, "degisiklikler": [], "etkiler": [], "uyarilar": [], "uygulanabilir": True}
        patch.object(master_settings.Manager, "plan", plan).start()
        status, result = self.call("/api/konsol/yayinlar/plan", {"hedef": "elle:notlar", "revizyon": "rev-3", "tailscale": True,
                                                                 "internet": False, "alan_adi": ""})
        self.assertEqual((status, result["engel"], [s["tur"] for s in result["adimlar"]]), (200, "", ["ayar"]))
        self.assertEqual(seen[0]["web"]["service"], "elle-notlar")
        self.assertEqual(self.call("/api/konsol/yayinlar/plan", {"hedef": "elle:yok", "revizyon": "rev-3", "tailscale": True,
                                                                 "internet": False, "alan_adi": ""})[0], 400)
        self.assertEqual(self.call("/api/konsol/yayinlar/plan", {"hedef": "elle:notlar"})[0], 400, "the request's shape")

    def test_only_gelismis_resource_jobs_pass_the_container_route(self):
        jobs = []
        patch.object(self.p.containers, "submit", side_effect=lambda data: jobs.append(data) or
                     {"id": "a" * 32, "action": data["action"], "name": data.get("name") or data.get("image"),
                      "state": "running", "step": "Başlatılıyor"}).start()
        for data in ({"action": "image-remove", "image": "b" * 64}, {"action": "network-create", "name": "ag", "subnet": "",
                                                                    "internal": False}):
            with self.subTest(data=data):
                self.assertEqual(self.call("/api/konsol/konteynerler/islem", data)[0], 202)
        for data in ({"action": "start", "name": "medya", "revision": None}, {"action": "adopt", "name": "dis", "preview": True},
                     {"action": "save", "name": "medya", "config": {}}):
            with self.subTest(data=data):
                self.assertEqual(self.call("/api/konsol/konteynerler/islem", data)[0], 400)
        self.assertEqual(len(jobs), 2)


if __name__ == "__main__":
    unittest.main()
