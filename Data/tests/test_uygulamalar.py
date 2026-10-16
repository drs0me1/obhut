"""DD-261: the Uygulamalar read model and its route. Until the application engine (DD-271, phase 3)
the list holds Konsol's containers only. master_uygulamalar.build() is fed the shapes the backend's own
sources return; every result is checked against master_api's Uygulamalar schema."""
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
CONTAINERS = {
    "runtime": {"ok": True, "version": "5.4.2", "error": ""},
    "containers": [
        {"name": "medya", "source": "konsol", "state": "running", "busy": None,
         "cpu_percent": 3.25, "memory_bytes": 210000000, "image": "ghcr.io/ornek/medya@sha256:" + "a" * 64,
         "actions": ["stop", "restart", "remove", "image-update", "save"], "revision": "r" * 64,
         "update": {"state": "var", "channel": "ghcr.io/ornek/medya:latest", "checked_at": NOW}},
        {"name": "notlar", "source": "konsol", "state": "running", "busy": None,
         "cpu_percent": 0.5, "memory_bytes": 84000000, "image": "ghcr.io/ornek/notlar@sha256:" + "b" * 64,
         "actions": ["stop", "restart", "save", "remove", "image-update"], "revision": "k" * 32,
         "update": {"state": "guncel", "channel": "ghcr.io/ornek/notlar:latest", "checked_at": NOW}},
        {"name": "gece", "source": "external", "state": "exited", "busy": None, "cpu_percent": None,
         "memory_bytes": None, "image": "docker.io/library/alpine:3", "actions": ["start", "remove"], "revision": None,
         "update": None},
    ],
    "images": [{"id": "i1", "name": "a", "used_by": ["medya"]}, {"id": "i2", "name": "b", "used_by": ["notlar"]},
               {"id": "i3", "name": "c", "used_by": []}],
    "volumes": [{"name": "notlar-db"}, {"name": "notlar-config"}],
    "networks": [{"name": "podman"}, {"name": "medya"}, {"name": "ksl-konsol"}],
}
ITEM_KEYS = {"id", "ad", "tur", "aciklama", "konteyner", "durum", "tailscale", "internet", "kaynak", "guncelleme", "adres",
             "eylemler", "revizyon"}


def erisim():
    return master_erisim.build(dict(test_erisim.ENV), copy.deepcopy(test_erisim.SETTINGS), copy.deepcopy(test_erisim.SHARES),
                               copy.deepcopy(test_erisim.CONTAINERS), copy.deepcopy(test_erisim.TAILSCALE),
                               copy.deepcopy(test_erisim.NETWORKS), False, NOW)


class ReadModelTests(unittest.TestCase):
    def build(self, containers=CONTAINERS, view="default", errors=()):
        result = master_uygulamalar.build(copy.deepcopy(containers), erisim() if view == "default" else view, NOW, errors)
        master_api.check(master_api.ref("Uygulamalar"), result)
        return result

    @staticmethod
    def item(result, sid):
        return next(i for i in result["items"] if i["id"] == sid)

    def test_every_container_in_one_list(self):
        result = self.build()
        self.assertEqual([i["id"] for i in result["items"]], ["konteyner:medya", "konteyner:notlar", "konteyner:gece"])
        self.assertEqual(set(result), {"read_at", "items", "altyapi", "hatalar"}, "DD-271: no catalogue")
        self.assertTrue(all(set(i) == ITEM_KEYS and i["tur"] == "konteyner" for i in result["items"]))
        self.assertEqual(result["altyapi"], {"podman": "5.4.2", "calisiyor": True, "imaj": 3, "kullanilmayan_imaj": 1, "birim": 2, "ag": 3})
        self.assertEqual((result["read_at"], result["hatalar"]), (NOW, []))

    def test_a_container_with_its_access_resources_and_update(self):
        medya = self.item(self.build(), "konteyner:medya")
        self.assertEqual((medya["ad"], medya["konteyner"], medya["durum"], medya["aciklama"]),
                         ("medya", "medya", "calisiyor", "Konteyner · ghcr.io/ornek/medya"))
        self.assertEqual(medya["kaynak"], {"cpu": 3.25, "bellek": 210000000})
        self.assertEqual((medya["guncelleme"], medya["eylemler"]), ("yeni", ["durdur", "yeniden-baslat", "kaldir", "guncelle"]))
        self.assertEqual(medya["adres"], {"tailscale": None, "internet": None}, "raw ports are not addresses")
        self.assertEqual((medya["tailscale"]["durum"], medya["internet"]["durum"]), ("kapali", "kapali"))
        self.assertEqual(medya["revizyon"], "r" * 64)

    def test_a_konsol_container_with_its_manual_address(self):
        notlar = self.item(self.build(), "konteyner:notlar")
        self.assertEqual((notlar["konteyner"], notlar["aciklama"]), ("notlar", "Konteyner · ghcr.io/ornek/notlar"))
        self.assertEqual(notlar["adres"], {"tailscale": "http://notlar.ev", "internet": "https://notlar.example.org"})
        self.assertEqual((notlar["tailscale"]["durum"], notlar["internet"]["durum"]), ("acik", "acik"))
        self.assertEqual((notlar["guncelleme"], notlar["eylemler"]), ("guncel", ["durdur", "yeniden-baslat", "kaldir"]))
        gece = self.item(self.build(), "konteyner:gece")
        self.assertEqual((gece["durum"], gece["eylemler"], gece["kaynak"]), ("durduruldu", ["baslat", "kaldir"], {"cpu": None, "bellek": None}))
        self.assertIn("Konsol dışında", gece["aciklama"])

    def test_states_and_running_operations(self):
        containers = copy.deepcopy(CONTAINERS)
        containers["containers"][0]["busy"] = "c" * 32
        containers["containers"][1]["state"] = "paused"
        result = self.build(containers)
        self.assertEqual((self.item(result, "konteyner:medya")["durum"], self.item(result, "konteyner:medya")["eylemler"]),
                         ("islemde", []), "a running operation offers no action")
        self.assertEqual(self.item(result, "konteyner:notlar")["durum"], "bilinmiyor")

    def test_an_image_that_can_move_but_was_not_checked_is_unknown_not_fixed(self):
        containers = copy.deepcopy(CONTAINERS)
        containers["containers"][0]["update"] = None
        medya = self.item(self.build(containers=containers), "konteyner:medya")
        self.assertEqual((medya["guncelleme"], medya["eylemler"]), ("bilinmiyor", ["durdur", "yeniden-baslat", "kaldir"]))
        self.assertEqual(self.item(self.build(containers=containers), "konteyner:gece")["guncelleme"], "sabit")

    def test_unreadable_sources(self):
        broken = self.build({"runtime": {"ok": False, "version": "", "error": "Podman kullanılamıyor: x"}, "containers": []},
                            view=None, errors=["Konteyner yönetim kayıtları okunamadı."])
        self.assertEqual(broken["items"], [])
        self.assertEqual(broken["hatalar"], ["Konteyner yönetim kayıtları okunamadı.", "Podman kullanılamıyor: x"])
        self.assertFalse(broken["altyapi"]["calisiyor"])
        none = self.build(None, view=None)
        self.assertEqual((none["items"], none["hatalar"]), ([], []), "no container state: nothing to list, nothing failed")
        self.assertEqual(none["altyapi"], {"podman": "", "calisiyor": False, "imaj": 0, "kullanilmayan_imaj": 0, "birim": 0, "ag": 0})


class FakeView:
    def __init__(self, calls):
        self.calls = calls

    def liste(self):
        return copy.deepcopy(CONTAINERS)

    def ayrinti(self, name):
        self.calls.append(("ayrinti", name))
        return {"name": name, "image": "ghcr.io/ornek/notlar@sha256:" + "b" * 64, "network": "notlar", "user": "1000:1000",
                "started": NOW - 3600, "health": "healthy", "restarts": 1,
                "ports": [{"host_ip": "127.0.0.1", "host_port": 8093, "container_port": 8080, "protocol": "tcp", "scope": "local"}],
                "mounts": [{"type": "bind", "source": "/srv/media", "destination": "/srv/media", "rw": True, "name": ""},
                           {"type": "volume", "source": "/var/lib/containers/storage/volumes/notlar-db/_data", "destination": "/database",
                            "rw": True, "name": "notlar-db"}]}

    def gunluk(self, name, tail):
        self.calls.append(("gunluk", name, tail))
        return {"name": name, "lines": ["satır 1", "satır 2"], "truncated": False}


class RouteTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)
        with self.state.open("a") as fh:
            fh.write("KONTEYNER_STATE_DIR=%s\n" % (self.root / "konteyner"))
        patch.object(self.p, "update_check_soon").start()  # no registry check from a test
        patch.object(self.p, "erisim", return_value=erisim()).start()
        self.addCleanup(patch.stopall)

    def test_the_route_answers_with_the_read_model(self):
        with patch.object(self.p.containers, "view", return_value=FakeView([])):
            status, _, body = test_resources.unix_get(self.sock, "/api/konsol/uygulamalar", {"X-Konsol": "1"})
        self.assertEqual(status, 200)
        answer = json.loads(body)
        master_api.check(master_api.ref("Uygulamalar"), answer)
        self.assertEqual([i["id"] for i in answer["items"]], ["konteyner:medya", "konteyner:notlar", "konteyner:gece"])
        with patch.object(self.p.containers, "view", side_effect=panel.master_containers.ContainerError(
                503, "Konteyner yönetim kayıtları okunamadı.")):
            answer = json.loads(test_resources.unix_get(self.sock, "/api/konsol/uygulamalar", {"X-Konsol": "1"})[2])
        self.assertEqual((answer["items"], answer["hatalar"]), ([], ["Konteyner yönetim kayıtları okunamadı."]))
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
        patch.object(self.p, "erisim", return_value=erisim()).start()
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
        answer = self.get("/api/konsol/uygulamalar/ayrinti?id=konteyner:notlar")
        master_api.check(master_api.ref("UygulamaAyrinti"), answer)
        self.assertEqual((answer["uygulama"]["id"], answer["konteyner"]["saglik"], answer["konteyner"]["baslangic"]),
                         ("konteyner:notlar", "healthy", NOW - 3600))
        self.assertEqual([(m["tur"], m["hedef"], m["ad"]) for m in answer["konteyner"]["baglamalar"]],
                         [("bind", "/srv/media", ""), ("volume", "/database", "notlar-db")])
        self.assertEqual(answer["erisim"]["id"], "konteyner:notlar")
        self.assertEqual(self.calls, [("ayrinti", "notlar")])
        self.get("/api/konsol/uygulamalar/ayrinti?id=konteyner:yok", 404)
        self.get("/api/konsol/uygulamalar/ayrinti?id=uygulama:notlar", 400)
        self.get("/api/konsol/uygulamalar/ayrinti?id=../etc", 400)
        self.get("/api/konsol/uygulamalar/ayrinti", 400)

    def test_logs_come_from_the_container(self):
        answer = self.get("/api/konsol/uygulamalar/gunluk?id=konteyner:notlar&satir=50")
        master_api.check(master_api.ref("UygulamaGunlugu"), answer)
        self.assertEqual((answer, self.calls[-1]), ({"satirlar": ["satır 1", "satır 2"], "kesik": False}, ("gunluk", "notlar", "50")))
        with patch.object(FakeView, "gunluk", side_effect=panel.master_containers.ContainerError(404, "Konteyner bulunamadı.")):
            self.assertEqual(self.get("/api/konsol/uygulamalar/gunluk?id=konteyner:yok", 404)["error"], "Konteyner bulunamadı.")
        self.get("/api/konsol/uygulamalar/gunluk?id=uygulama:notlar", 400)

    def test_one_action_entry_for_containers(self):
        jobs = []

        def submit(data):
            jobs.append(data)
            return {"id": "c" * 32, "action": data["action"], "name": data["name"], "state": "running"}
        with patch.object(self.p.containers, "submit", side_effect=submit):
            self.assertEqual(self.post({"id": "konteyner:notlar", "eylem": "yeniden-baslat", "revizyon": "k" * 32}),
                             (202, {"id": "konteyner:notlar", "eylem": "yeniden-baslat", "is": "c" * 32}))
            self.assertEqual(self.post({"id": "konteyner:medya", "eylem": "guncelle", "revizyon": "r" * 64})[0], 202)
            self.assertEqual(self.post({"id": "konteyner:gece", "eylem": "kaldir"})[0], 202)
        self.assertEqual(jobs, [{"action": "restart", "name": "notlar", "revision": "k" * 32},
                                {"action": "image-update", "name": "medya", "revision": "r" * 64},
                                {"action": "remove", "name": "gece", "revision": ""}])
        with patch.object(self.p.containers, "submit", side_effect=panel.master_containers.ContainerError(409, "Revizyon değişti.")):
            self.assertEqual(self.post({"id": "konteyner:notlar", "eylem": "durdur", "revizyon": "x"}), (409, {"error": "Revizyon değişti."}))
        self.assertEqual(self.post({"id": "uygulama:notlar", "eylem": "baslat"})[0], 404, "only a container is an application")
        for bad in ({"id": "konteyner:notlar"}, {"id": "konteyner:notlar", "eylem": "sil"}, {"id": 5, "eylem": "baslat"},
                    {"id": "konteyner:notlar", "eylem": "baslat", "fazla": 1}, {"id": "konteyner:notlar", "eylem": "kaldir", "veri": True}):
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
