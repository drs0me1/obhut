"""DD-261: the Uygulamalar read model (packages, Konsol's containers and the built-ins in one list) and
its route. master_uygulamalar.build() is fed the shapes the backend's own sources return; every result
is checked against master_api's Uygulamalar schema."""
import copy
import json
from pathlib import Path
import sys
import time
import types
import unittest
from unittest.mock import patch

import test_erisim
import test_resources
from test_overview import Fixture

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_api  # noqa: E402
import master_container_manager  # noqa: E402
import master_erisim  # noqa: E402
import master_uygulamalar  # noqa: E402

panel = test_resources.panel
NOW = test_erisim.NOW
MODULES = [
    {"id": "wireguard", "runtime": "konsol", "installed": True, "state": "calisiyor", "live": "-", "busy": False, "progress": None,
     "durdurulabilir": True, "konsol": {"ad": "WireGuard", "alt": "VPN ağları ve cihazlar.", "simge": "shield"}},
    {"id": "torrent", "runtime": "konteyner", "installed": True, "state": "calisiyor", "live": "running", "busy": False, "progress": None,
     "durdurulabilir": True, "konsol": {"ad": "qBittorrent", "alt": "Torrent indirmelerini yönetin.", "simge": "download",
                                        "durdur_notu": "Süren indirmeler duraklar.",
                                        "kaldir": {"neler": [["box", "Konteyner durur."], ["bad"], [1, "x"]], "veri_etiket": "Profili de sil",
                                                   "veri_kalir": "indirilenler kalır.", "veri_silinir": "Profil silinir."}},
     "urls": {"tailscale": "http://torrent.ev", "internet": None}},
    {"id": "gezgin", "runtime": "konteyner", "installed": False, "state": "", "live": "-", "busy": False, "progress": None,
     "durdurulabilir": True, "konsol": {"ad": "Gezgin", "alt": "Dosya yöneticisi.", "simge": "compass"}},
]
CONTAINERS = {
    "runtime": {"ok": True, "version": "5.4.2", "error": ""},
    "containers": [
        {"name": "qbittorrent", "source": "appstore", "module_id": "torrent", "state": "running", "busy": None,
         "cpu_percent": 3.25, "memory_bytes": 210000000, "image": "lscr.io/linuxserver/qbittorrent@sha256:" + "a" * 64,
         "actions": ["stop", "restart", "remove", "image-update", "save"], "revision": "r" * 64,
         "update": {"state": "var", "channel": "lscr.io/linuxserver/qbittorrent:latest", "checked_at": NOW}},
        {"name": "gezgin", "source": "konsol", "module_id": None, "state": "running", "busy": None,
         "cpu_percent": 0.5, "memory_bytes": 84000000, "image": "ghcr.io/drs0me1/gezgin@sha256:" + "b" * 64,
         "actions": ["stop", "restart", "save", "remove", "image-update"], "revision": "k" * 32,
         "update": {"state": "guncel", "channel": "ghcr.io/drs0me1/gezgin:latest", "checked_at": NOW}},
        {"name": "gece", "source": "external", "module_id": None, "state": "exited", "busy": None, "cpu_percent": None,
         "memory_bytes": None, "image": "docker.io/library/alpine:3", "actions": ["start", "remove", "adopt"], "revision": None,
         "update": None},
    ],
    "images": [{"id": "i1", "name": "a", "used_by": ["qbittorrent"]}, {"id": "i2", "name": "b", "used_by": ["gezgin"]},
               {"id": "i3", "name": "c", "used_by": []}],
    "volumes": [{"name": "gezgin-db"}, {"name": "gezgin-config"}],
    "networks": [{"name": "podman"}, {"name": "torrent"}, {"name": "ksl-konsol"}],
}


def erisim():
    return master_erisim.build(dict(test_erisim.ENV), copy.deepcopy(test_erisim.SETTINGS), copy.deepcopy(test_erisim.SHARES),
                               copy.deepcopy(test_erisim.CONTAINERS), copy.deepcopy(test_erisim.TAILSCALE),
                               copy.deepcopy(test_erisim.NETWORKS), copy.deepcopy(test_erisim.PACKAGES), test_erisim.NAMES, NOW)


class ReadModelTests(unittest.TestCase):
    def build(self, modules=MODULES, containers=CONTAINERS, view="default", errors=()):
        result = master_uygulamalar.build(copy.deepcopy(modules), copy.deepcopy(containers),
                                          erisim() if view == "default" else view, NOW, errors)
        master_api.check(master_api.ref("Uygulamalar"), result)
        return result

    @staticmethod
    def item(result, sid):
        return next(i for i in result["items"] if i["id"] == sid)

    def test_every_application_in_one_list(self):
        result = self.build()
        self.assertEqual([i["id"] for i in result["items"]],
                         ["paket:wireguard", "paket:torrent", "konteyner:gezgin", "konteyner:gece", "yerlesik:dosya", "yerlesik:paylasim"])
        self.assertEqual(result["katalog"], [{"id": "gezgin", "ad": "Gezgin", "aciklama": "Dosya yöneticisi.", "simge": "compass"}])
        self.assertEqual(result["altyapi"], {"podman": "5.4.2", "calisiyor": True, "imaj": 3, "kullanilmayan_imaj": 1, "birim": 2, "ag": 3})
        self.assertEqual(result["hatalar"], [])
        # DD-267: no item names a page of the old interface any more.
        self.assertFalse([i["id"] for i in result["items"] if "sayfa" in i])

    def test_a_package_with_its_container_access_and_update(self):
        torrent = self.item(self.build(), "paket:torrent")
        self.assertEqual((torrent["ad"], torrent["tur"], torrent["modul"], torrent["konteyner"], torrent["durum"]),
                         ("qBittorrent", "paket", "torrent", "qbittorrent", "calisiyor"))
        self.assertEqual(torrent["kaynak"], {"cpu": 3.25, "bellek": 210000000})
        self.assertEqual((torrent["guncelleme"], torrent["eylemler"]), ("yeni", ["durdur", "yeniden-baslat", "guncelle", "kaldir"]))
        self.assertEqual(torrent["adres"], {"tailscale": "http://torrent.ev", "internet": None})
        self.assertEqual((torrent["tailscale"]["durum"], torrent["internet"]["durum"]), ("acik", "kismen"))
        self.assertEqual(torrent["revizyon"], "r" * 64)
        # The package's own stop and removal words, malformed pairs left out.
        self.assertEqual(torrent["metinler"], {"durdur": "Süren indirmeler duraklar.", "kaldir": [["box", "Konteyner durur."]],
                                               "veri_etiket": "Profili de sil", "veri_kalir": "indirilenler kalır.",
                                               "veri_silinir": "Profil silinir."})
        self.assertEqual(self.item(self.build(), "paket:wireguard")["metinler"],
                         {"durdur": "", "kaldir": [], "veri_etiket": "", "veri_kalir": "", "veri_silinir": ""})
        self.assertIsNone(self.item(self.build(), "konteyner:gezgin")["metinler"])
        self.assertIsNone(self.item(self.build(), "yerlesik:dosya")["metinler"])

    def test_a_konsol_container_with_its_manual_address(self):
        gezgin = self.item(self.build(), "konteyner:gezgin")
        self.assertEqual((gezgin["tur"], gezgin["konteyner"], gezgin["aciklama"]), ("konteyner", "gezgin", "Konteyner · ghcr.io/drs0me1/gezgin"))
        self.assertEqual(gezgin["adres"], {"tailscale": "http://gezgin.ev", "internet": "https://gezgin.example.org"})
        self.assertEqual((gezgin["guncelleme"], gezgin["eylemler"]), ("guncel", ["durdur", "yeniden-baslat", "kaldir"]))
        gece = self.item(self.build(), "konteyner:gece")
        self.assertEqual((gece["durum"], gece["eylemler"]), ("durduruldu", ["baslat", "kaldir"]))
        self.assertIn("Konsol dışında", gece["aciklama"])

    def test_states_and_running_operations(self):
        modules = copy.deepcopy(MODULES)
        modules[1].update(busy=True, progress={"action": "kur", "step": "2", "total": 5, "text": "İmaj indiriliyor"})
        modules[0].update(state="durduruldu")
        result = self.build(modules)
        torrent = self.item(result, "paket:torrent")
        self.assertEqual((torrent["durum"], torrent["islem"], torrent["eylemler"]),
                         ("islemde", {"eylem": "kur", "adim": "2", "metin": "İmaj indiriliyor"}, []))
        self.assertEqual(self.item(result, "paket:wireguard")["eylemler"], ["baslat", "kaldir"])
        modules[1].update(busy=False, progress=None, live="exited")
        self.assertEqual(self.item(self.build(modules), "paket:torrent")["durum"], "hata")

    def test_an_image_that_can_move_but_was_not_checked_is_unknown_not_fixed(self):
        containers = copy.deepcopy(CONTAINERS)
        containers["containers"][0]["update"] = None
        torrent = self.item(self.build(containers=containers), "paket:torrent")
        self.assertEqual((torrent["guncelleme"], torrent["eylemler"]), ("bilinmiyor", ["durdur", "yeniden-baslat", "kaldir"]))
        self.assertEqual(self.item(self.build(containers=containers), "konteyner:gece")["guncelleme"], "sabit")

    def test_built_ins_and_unreadable_sources(self):
        result = self.build()
        share = self.item(result, "yerlesik:paylasim")
        self.assertEqual((share["durum"], share["aciklama"]), ("calisiyor", "WebDAV · yerleşik · 2 klasör"))
        self.assertEqual(self.item(result, "yerlesik:dosya")["durum"], "calisiyor")
        broken = self.build(None, {"runtime": {"ok": False, "version": "", "error": "Podman kullanılamıyor: x"}, "containers": []},
                            view=None, errors=["Uygulama listesi okunamadı."])
        self.assertEqual([i["id"] for i in broken["items"]], ["yerlesik:dosya", "yerlesik:paylasim"])
        self.assertEqual(broken["hatalar"], ["Uygulama listesi okunamadı.", "Podman kullanılamıyor: x"])
        self.assertEqual(self.item(broken, "yerlesik:paylasim")["durum"], "bilinmiyor")


class RouteTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)
        patch.object(self.p, "update_check_soon").start()  # no registry check from a test
        self.addCleanup(patch.stopall)

    def test_the_route_answers_with_the_read_model(self):
        with patch.object(self.p, "modules", return_value=copy.deepcopy(MODULES)), \
             patch.object(self.p, "erisim", return_value=erisim()):
            status, _, body = test_resources.unix_get(self.sock, "/api/konsol/uygulamalar", {"X-Konsol": "1"})
        self.assertEqual(status, 200)
        answer = json.loads(body)
        master_api.check(master_api.ref("Uygulamalar"), answer)
        self.assertEqual([i["id"] for i in answer["items"]][:2], ["paket:wireguard", "paket:torrent"])
        with patch.object(self.p, "modules", side_effect=RuntimeError("modül listesi okunamadı")), \
             patch.object(self.p, "erisim", return_value=erisim()):
            answer = json.loads(test_resources.unix_get(self.sock, "/api/konsol/uygulamalar", {"X-Konsol": "1"})[2])
        self.assertEqual(answer["hatalar"], ["modül listesi okunamadı"])
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/uygulamalar", {})[0], 403)


class UpdateCheckTests(Fixture):
    """DD-261: the listing refreshes a stale image-update cache (DD-214) in the background, at most once a minute."""
    def test_a_stale_cache_starts_one_background_check(self):
        started = []

        def thread(target, name, daemon):
            self.assertTrue(daemon)
            return types.SimpleNamespace(start=lambda: started.append((target, name)))
        with patch.object(panel.threading, "Thread", side_effect=thread):
            self.p.containers.update_at = 0.0
            self.p.update_check_soon()
            self.p.update_check_soon()
            self.assertEqual(started, [(self.p.update_check_run, "guncelleme-denetimi")], "at most once a minute")
            self.p.update_kick_at -= panel.UPDATE_KICK_SECONDS
            self.p.containers.update_at = time.time()
            self.p.update_check_soon()
            self.assertEqual(len(started), 1, "a fresh cache needs no check")
            self.p.containers.update_at = time.time() - master_container_manager.UPDATE_TTL - 1
            self.p.update_check_soon()
            self.assertEqual(len(started), 2)

    def test_a_failing_check_stays_in_its_thread(self):
        with patch.object(self.p.containers, "updates", side_effect=panel.master_containers.ContainerError(503, "x")) as updates:
            self.p.update_check_run()
        updates.assert_called_once_with()


class FakeView:
    def __init__(self, calls):
        self.calls = calls

    def liste(self):
        return copy.deepcopy(CONTAINERS)

    def ayrinti(self, name):
        self.calls.append(("ayrinti", name))
        return {"name": name, "image": "ghcr.io/drs0me1/gezgin@sha256:" + "b" * 64, "network": "gezgin", "user": "1000:1000",
                "started": NOW - 3600, "health": "healthy", "restarts": 1,
                "ports": [{"host_ip": "127.0.0.1", "host_port": 8093, "container_port": 8080, "protocol": "tcp", "scope": "local"}],
                "mounts": [{"type": "bind", "source": "/srv/media", "destination": "/srv/media", "rw": True, "name": ""},
                           {"type": "volume", "source": "/var/lib/containers/storage/volumes/gezgin-db/_data", "destination": "/database",
                            "rw": True, "name": "gezgin-db"}]}

    def gunluk(self, name, tail):
        self.calls.append(("gunluk", name, tail))
        return {"name": name, "lines": ["satır 1", "satır 2"], "truncated": False}


class DetailAndActionTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)
        with self.state.open("a") as fh:
            fh.write("KONTEYNER_STATE_DIR=%s\n" % (self.root / "konteyner"))
        self.calls = []
        for name, value in (("modules", copy.deepcopy(MODULES)), ("erisim", erisim())):
            patch.object(self.p, name, return_value=value).start()
        patch.object(self.p.containers, "view", return_value=FakeView(self.calls)).start()
        patch.object(self.p, "update_check_soon").start()  # no registry check from a test
        self.addCleanup(patch.stopall)

    def get(self, path, code=200):
        status, _, body = test_resources.unix_get(self.sock, path, {"X-Konsol": "1"})
        self.assertEqual(status, code, body)
        return json.loads(body)

    def post(self, body, path="/api/konsol/uygulamalar/islem", headers=None):
        status, _, answer = test_resources.unix_get(self.sock, path, {"X-Konsol": "1", "Content-Type": "application/json", **(headers or {})},
                                                    method="POST", body=json.dumps(body).encode())
        return status, json.loads(answer)

    def test_the_detail_of_a_container_application(self):
        answer = self.get("/api/konsol/uygulamalar/ayrinti?id=konteyner:gezgin")
        master_api.check(master_api.ref("UygulamaAyrinti"), answer)
        self.assertEqual((answer["uygulama"]["id"], answer["konteyner"]["saglik"], answer["konteyner"]["baslangic"]),
                         ("konteyner:gezgin", "healthy", NOW - 3600))
        self.assertEqual([(m["tur"], m["hedef"], m["ad"]) for m in answer["konteyner"]["baglamalar"]],
                         [("bind", "/srv/media", ""), ("volume", "/database", "gezgin-db")])
        self.assertEqual(answer["erisim"]["id"], "konteyner:gezgin")
        share = self.get("/api/konsol/uygulamalar/ayrinti?id=yerlesik:paylasim")
        self.assertEqual((share["konteyner"], share["erisim"]["id"]), (None, "paylasim"))
        self.assertIsNone(self.get("/api/konsol/uygulamalar/ayrinti?id=yerlesik:dosya")["erisim"])
        self.get("/api/konsol/uygulamalar/ayrinti?id=konteyner:yok", 404)
        self.get("/api/konsol/uygulamalar/ayrinti?id=../etc", 400)
        self.get("/api/konsol/uygulamalar/ayrinti", 400)

    def test_logs_come_from_the_container_or_the_engine(self):
        answer = self.get("/api/konsol/uygulamalar/gunluk?id=konteyner:gezgin&satir=50")
        master_api.check(master_api.ref("UygulamaGunlugu"), answer)
        self.assertEqual((answer, self.calls[-1]), ({"satirlar": ["satır 1", "satır 2"], "kesik": False}, ("gunluk", "gezgin", "50")))
        with patch.object(self.p, "package_container", return_value=None), \
             patch.object(self.p, "module_state", return_value="calisiyor"), \
             patch.object(self.p, "modul", return_value=(0, "a\nb\n\nc\n", "")) as modul:
            answer = self.get("/api/konsol/uygulamalar/gunluk?id=paket:wireguard&satir=2")
        modul.assert_called_once_with("gunluk", "wireguard", "2")
        self.assertEqual(answer, {"satirlar": ["b", "c"], "kesik": True})
        self.assertIn("Sistem → Günlük", self.get("/api/konsol/uygulamalar/gunluk?id=yerlesik:dosya", 404)["error"])

    def test_one_action_entry_for_packages_and_containers(self):
        with patch.object(self.p, "module_spawn", return_value=(202, "")) as spawn:
            self.assertEqual(self.post({"id": "paket:torrent", "eylem": "kaldir", "veri": True}),
                             (202, {"id": "paket:torrent", "eylem": "kaldir", "is": None}))
        spawn.assert_called_once_with("torrent", "kaldir", True)
        jobs = []

        def submit(data):
            jobs.append(data)
            return {"id": "c" * 32, "action": data["action"], "name": data["name"], "state": "running"}
        with patch.object(self.p.containers, "submit", side_effect=submit), \
             patch.object(self.p, "package_container", return_value="qbittorrent"):
            self.assertEqual(self.post({"id": "konteyner:gezgin", "eylem": "yeniden-baslat", "revizyon": "k" * 32})[1]["is"], "c" * 32)
            self.assertEqual(self.post({"id": "paket:torrent", "eylem": "guncelle", "revizyon": "r" * 64})[0], 202)
        self.assertEqual(jobs, [{"action": "restart", "name": "gezgin", "revision": "k" * 32},
                                {"action": "image-update", "name": "qbittorrent", "revision": "r" * 64}])
        self.assertEqual(self.post({"id": "paket:gezgin", "eylem": "baslat"})[0], 404, "a package that is not installed")
        self.assertEqual(self.post({"id": "yerlesik:dosya", "eylem": "durdur"})[0], 409)
        for bad in ({"id": "paket:torrent"}, {"id": "paket:torrent", "eylem": "sil"}, {"id": 5, "eylem": "baslat"},
                    {"id": "paket:torrent", "eylem": "baslat", "fazla": 1}, {"id": "paket:torrent", "eylem": "kaldir", "veri": "evet"}):
            status, answer = self.post(bad)
            self.assertEqual(status, 400, bad)
            self.assertIn("İstek biçimi geçersiz", answer["error"])
        self.assertEqual(self.post({"id": "konteyner:../x", "eylem": "baslat"})[0], 404)

    def test_repair_starts_only_from_the_tailnet(self):
        with patch.object(self.p, "repair_start", return_value="denetle") as start:
            self.assertEqual(self.post({"kip": "denetle"}, "/api/konsol/onarim"), (202, {"kip": "denetle"}))
            start.assert_called_once_with("denetle")
            status, _ = self.post({"kip": "onar"}, "/api/konsol/onarim",
                                  {"X-Forwarded-For": "198.51.100.7", "X-Konsol-Kanal": "internet"})
        self.assertEqual(status, 403)
        self.assertEqual(self.post({"kip": "sil"}, "/api/konsol/onarim")[0], 400)


if __name__ == "__main__":
    unittest.main()
