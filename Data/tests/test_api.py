"""DD-259: master_api's route table. Every route has its handler method, the committed OpenAPI
description and TypeScript types are what the table generates, the schema check refuses wrong
shapes, and the table's routes answer through the real handler with replies of their declared shape."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import unittest.mock
from unittest.mock import patch

import test_resources
from test_overview import Fixture

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_api  # noqa: E402

panel = test_resources.panel


class TableTests(unittest.TestCase):
    def test_every_route_has_its_handler_and_a_unique_name(self):
        names = [r.name for r in master_api.ROUTES]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(len({(r.method, r.path) for r in master_api.ROUTES}), len(names))
        for route in master_api.ROUTES:
            self.assertTrue(callable(getattr(panel.Handler, "api_" + route.name, None)), route.name)
            self.assertTrue(route.path.startswith("/api/konsol/"), route.path)
            self.assertIs(master_api.find(route.method, route.path), route)
            self.assertTrue((route.reply is None) != (route.events is None), route.name)
        self.assertIsNone(master_api.find("POST", "/api/konsol/erisim"))

    def test_the_committed_descriptions_are_generated_from_the_table(self):
        # Regenerate: python3 panel/master_api.py openapi > docs/konsol-api.json (and ts > ...sema.ts).
        for argument, path in (("openapi", DATA / "docs/konsol-api.json"), ("ts", DATA / "tools/konsol-ui/src/api/sema.ts")):
            with self.subTest(path=path.name):
                out = subprocess.run([sys.executable, "-I", str(DATA / "panel/master_api.py"), argument],
                                     capture_output=True, text=True, check=True).stdout
                self.assertEqual(path.read_text(encoding="utf-8"), out)
        document = json.loads((DATA / "docs/konsol-api.json").read_text(encoding="utf-8"))
        self.assertEqual(document["openapi"], "3.1.0")
        self.assertEqual(sorted(document["paths"]), sorted({r.path for r in master_api.ROUTES}))
        for route in master_api.ROUTES:
            operation = document["paths"][route.path][route.method.lower()]
            self.assertIn(str(route.status), operation["responses"])
            self.assertEqual("requestBody" in operation, route.request is not None, route.name)
        refs = set()

        def walk(value):
            if isinstance(value, dict):
                if "$ref" in value:
                    refs.add(value["$ref"].rsplit("/", 1)[1])
                for item in value.values():
                    walk(item)
            elif isinstance(value, list):
                for item in value:
                    walk(item)
        walk(document)
        self.assertLessEqual(refs, set(document["components"]["schemas"]), "every reference resolves")

    def test_the_check_refuses_wrong_shapes(self):
        schema = master_api.obj({"n": master_api.INT, "s": master_api.enum("a", "b"), "x": master_api.null(master_api.NUM)},
                                optional=("x",))
        master_api.check(schema, {"n": 1, "s": "a"})
        master_api.check(schema, {"n": 1, "s": "b", "x": None})
        master_api.check(schema, {"n": 1, "s": "b", "x": 1.5})
        for bad in ({"n": True, "s": "a"}, {"n": 1.0, "s": "a"}, {"n": 1, "s": "c"}, {"s": "a"}, {"n": 1, "s": "a", "y": 0},
                    {"n": 1, "s": "a", "x": "1"}, [], None):
            with self.subTest(bad=bad), self.assertRaises(master_api.SchemaError):
                master_api.check(schema, bad)
        with self.assertRaises(master_api.SchemaError):
            master_api.check(master_api.arr(master_api.STR), ["a", 1])


class RouteReplyTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)

    def get(self, name, query=""):
        route = next(r for r in master_api.ROUTES if r.name == name)
        status, headers, body = test_resources.unix_get(self.sock, route.path + query, {"X-Konsol": "1"})
        self.assertEqual(status, 200, body)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        answer = json.loads(body)
        master_api.check(route.reply, answer)
        return answer

    def post(self, name, data):
        route = next(r for r in master_api.ROUTES if r.name == name)
        status, _headers, body = test_resources.unix_get(
            self.sock, route.path, {"X-Konsol": "1", "Content-Type": "application/json"}, method="POST",
            body=json.dumps(data).encode())
        answer = json.loads(body)
        if status == route.status:
            master_api.check(route.reply, answer)
        return status, answer

    def test_the_table_routes_answer_with_their_shapes(self):
        self.assertEqual(self.get("kaynaklar")["domain"], "test")
        with patch.object(self.p, "health_compute", return_value={"status": "warn", "read_at": 1,
                                                                    "checks": [{"id": "units", "name": "Servisler", "status": "warn", "detail": "x"}]}):
            self.assertEqual(self.get("saglik")["status"], "warn")
        with patch.object(self.p, "busy_units", return_value=set()):
            self.assertEqual(self.get("etkinlik"), {"items": []})
        self.assertEqual(self.get("bekleyen"), {"bekleyen": None})
        modules = [{"id": "torrent", "runtime": "konteyner", "installed": True, "state": "calisiyor", "live": "running", "busy": False,
                    "progress": None, "durdurulabilir": True,
                    "konsol": {"ad": "qBittorrent", "neler": [["box", "x"]]},
                    "urls": {"tailscale": "http://torrent.test", "internet": None}},
                   {"id": "wireguard", "runtime": "servis", "installed": False, "state": "", "live": "-", "busy": True,
                    "progress": {"action": "kur", "step": "1", "total": 4, "text": "Paketler"}, "durdurulabilir": False}]
        with patch.object(self.p, "modules", return_value=modules):
            self.assertEqual(self.get("moduller"), {"items": modules})
        with patch.object(self.p.updates, "latest", return_value={"at": 7, "ok": True, "son": "2026.08.06-v2-300",
                                                                  "commit": "a" * 40, "hata": ""}), \
             patch.object(self.p, "unit_active", return_value=False):
            update = self.get("guncelleme")
        self.assertEqual((update["son"], update["baslatilabilir"], update["is"]["durum"]), ("2026.08.06-v2-300", True, "yok"))

    def test_phase_4a_routes_answer_with_their_shapes(self):
        # DD-266: Sistem. No account yet, and the Unix socket is the local channel.
        self.assertEqual(self.get("oturum"), {"durum": "kurulum", "kanal": "yerel"})
        rows = [{"at": 1, "source": "panel", "user": "-", "client": "100.64.0.9", "action": "onarim", "detail": "x", "ok": True}]
        with patch.object(self.p, "actions", return_value=rows):
            self.assertEqual(self.get("islemler"), {"items": rows})
        with patch.object(self.p, "repair_log", return_value="satır 1\n") as log:
            status, headers, body = test_resources.unix_get(self.sock, "/api/konsol/onarim/gunluk?sure=7g", {"X-Konsol": "1"})
        self.assertEqual((status, headers["Content-Type"], body.decode()), (200, "text/plain; charset=utf-8", "satır 1\n"))
        log.assert_called_once_with("7g")
        with patch.object(panel.master_settings, "Manager") as manager:
            manager.return_value.folders.return_value = [{"path": "/srv/downloads", "free": 5}]
            self.assertEqual(self.get("klasorler", "?path=/srv")["items"][0]["path"], "/srv/downloads")
        manager.return_value.folders.assert_called_once_with("/srv")
        # Gelişmiş: the settings view's Caddy and dnsmasq parts.
        view = {"read_at": 3, "web": {"entries": [{"address": "panel.test:80", "routes": [{"path": "/", "kind": "proxy", "to": "x"}], "source": "base",
                                                    "access": "tailscale", "scheme": "http"}],
                                       "raw": [{"file": "/etc/caddy/Caddyfile", "text": "panel.test:80 {}"}]},
                "dns": {"listen": ["100.64.0.1"], "domains": ["test"], "names": [], "dhcp": False, "raw": []}}
        with patch.object(self.p, "settings", return_value=view) as settings:
            self.assertEqual(self.get("gelismis", "?yenile=1"), {"read_at": 3, "caddy": view["web"], "dnsmasq": view["dns"]})
        settings.assert_called_once_with(fresh=True)
        # Podman reads go to the same view as the current Konsol's.
        row = {"id": "abc", "name": "notlar", "image": "docker.io/library/nginx:alpine", "state": "running", "status": "Up",
               "unit": "konsol-notlar.service", "network": "konsol", "created": 1, "started": 2, "exit_code": 0, "restarts": 0,
               "ports": [{"host_ip": "127.0.0.1", "host_port": 8090, "container_port": 80, "protocol": "tcp", "scope": "local"}],
               "mounts": 1, "health": "", "live": True, "source": "konsol", "management_id": "konsol:notlar", "module_id": None,
               "revision": "r1", "actions": ["stop", "restart", "save", "remove", "image-update"], "restricted_reason": "",
               "cpu_percent": None, "memory_bytes": 1024, "busy": None, "listening": None,
               "update": {"state": "guncel", "channel": "alpine", "error": "", "checked_at": 5}}
        listing = {"read_at": 1, "runtime": {"version": "5.4.2", "ok": True, "error": ""}, "containers": [row],
                   "images": [{"id": "i1", "name": "docker.io/library/nginx:alpine", "size": 10, "created": 1, "used_by": ["notlar"],
                               "managed": True, "pinned": False}],
                   "volumes": [{"name": "v", "driver": "local", "size": None, "used_by": [], "managed": True}],
                   "networks": [{"name": "konsol", "id": "n1", "driver": "bridge", "subnets": ["10.89.1.0/24"], "used_by": ["notlar"],
                                 "managed": True, "internal": False}],
                   "storage": {"images": 1, "containers": 1, "size": None}, "resource_errors": {}}
        detail = dict(row, mounts=[{"type": "volume", "source": "v", "destination": "/data", "rw": True, "name": "v"}],
                      config={"name": "notlar"}, editable=["ports"], protected_mounts=[], effective_autostart=True,
                      user="", command="nginx")
        fake = unittest.mock.Mock()
        fake.liste.return_value, fake.ayrinti.return_value = listing, detail
        fake.gunluk.return_value = {"name": "notlar", "lines": ["a"], "truncated": False}
        with patch.object(panel.Handler, "container_view", return_value=fake):
            self.assertEqual(self.get("konteyner_listesi"), listing)
            self.assertEqual(self.get("konteyner_ayrintisi", "?ad=notlar")["command"], "nginx")
            self.assertEqual(self.get("konteyner_gunlugu", "?ad=notlar&satir=500")["lines"], ["a"])
        fake.gunluk.assert_called_once_with("notlar", "500")
        status, _headers, body = test_resources.unix_get(self.sock, "/api/konsol/konteynerler/ayrinti?ad=../x", {"X-Konsol": "1"})
        self.assertEqual(status, 400, body)

    def test_a_package_account_and_an_install_from_the_table(self):
        self.package("torrent", manifest_extra='PAKET_HESAP="1"\n')
        with patch.object(self.p, "modul", return_value=(0, "admin\tgecici\tgizli-deneme\n", "")) as modul:
            self.assertEqual(self.get("uygulama_hesabi", "?id=paket:torrent"), {"user": "admin", "temp": True, "host": ""})
            modul.assert_called_with("hesap", "torrent")
            self.assertEqual(self.get("uygulama_hesabi", "?id=paket:torrent&parola=1")["pass"], "gizli-deneme")
            modul.assert_called_with("hesap", "torrent", "--parola")
        for bad in ("?id=torrent", "?id=konteyner:torrent", "?id=paket:yok"):
            status, _headers, _body = test_resources.unix_get(self.sock, "/api/konsol/uygulamalar/hesap" + bad, {"X-Konsol": "1"})
            self.assertEqual(status, 404, bad)
        # "kur" installs a catalogue package with its form, as App Store does.
        with patch.object(self.p, "modules", return_value=[{"id": "torrent", "installed": False}]), \
             patch.object(self.p, "module_install", return_value=(202, "")) as install:
            self.assertEqual(self.post("uygulama_islemi", {"id": "paket:torrent", "eylem": "kur", "form": {"kullanici": "admin"}}),
                             (202, {"id": "paket:torrent", "eylem": "kur", "is": None}))
            install.assert_called_once_with("torrent", {"kullanici": "admin"})
            self.assertEqual(self.post("uygulama_islemi", {"id": "paket:yok", "eylem": "kur"})[0], 404)
            self.assertEqual(self.post("uygulama_islemi", {"id": "konteyner:x", "eylem": "kur"})[0], 404)
        # The account routes keep their shapes; a body of another shape is refused before the handler.
        self.assertEqual(self.post("oturum_cikis", {}), (200, {"durum": "cikis"}))
        status, answer = self.post("oturum_cikis", {"x": 1})
        self.assertEqual(status, 400)
        self.assertIn("İstek biçimi geçersiz", answer["error"])
        self.assertEqual(self.post("hesap_parola", {"yeni": 5})[0], 400)

    def test_shares_and_storage_from_the_table(self):
        # DD-267: Dosyalar → Paylaşımlar reads the share manager's own view; a pause request is gone.
        conn = {"enabled": True, "permission": "ro", "expires": 1900000000, "expired": False, "available": True, "active": True,
                "reason": "", "url": "http://100.64.0.1:61010/s/abc/"}
        view = {"enabled": True, "running": True, "host": "http://100.64.0.1:61010", "max": 32, "tail_enabled": True,
                "items": [{"id": "abc", "path": "media/filmler", "name": "filmler", "username": "film", "created": 1, "changed": 2,
                           "type": "dir", "available": True, "connections": {"tailscale": conn}, "urls": {"tailscale": conn["url"]},
                           "url": conn["url"]}],
                "wan": {"available": False, "address": "", "reason": "x", "mode": "off", "domain": "", "port": 443}, "limits": {}}
        with patch.object(panel.master_shares, "Manager") as manager:
            manager.return_value.public.return_value = view
            self.assertEqual(self.get("paylasimlar"), view)
        status, _headers, _body = test_resources.unix_get(self.sock, "/api/konsol/paylasim/durum", {"X-Konsol": "1", "Content-Type": "application/json"},
                                                          method="POST", body=b'{"id": "abc"}')
        self.assertEqual(status, 404, "pausing is a connection switch since DD-192")
        with patch.object(self.p, "settings_run", return_value=(200, view)) as run:
            self.assertEqual(self.post("paylasim_kaldir", {"id": "abc"}), (200, view))
        run.assert_called_once_with("remove", {"id": "abc"}, shares=True)
        self.assertEqual(self.post("paylasim_kaldir", {"id": "abc", "x": 1})[0], 400)
        # Depolama: an application's bind mounts under the user area and each share.
        root = str(self.root)
        apps = {"items": [{"id": "konteyner:notlar", "ad": "notlar", "tur": "konteyner", "konteyner": "notlar"},
                          {"id": "yerlesik:dosyalar", "ad": "Dosyalar", "tur": "yerlesik", "konteyner": None}], "hatalar": []}
        mounts = [{"type": "bind", "source": root + "/media", "destination": "/media", "rw": False, "name": ""},
                  {"type": "bind", "source": "/etc/localtime", "destination": "/etc/localtime", "rw": False, "name": ""},
                  {"type": "volume", "source": "/var/lib/containers/v", "destination": "/data", "rw": True, "name": "v"}]
        fake = unittest.mock.Mock()
        fake.ayrinti.return_value = {"mounts": mounts}
        registry = {"root": root, "items": [{"id": "abc", "path": "media/filmler", "name": "filmler",
                                             "connections": {"tailscale": {"enabled": True, "permission": "rw", "expires": None}}}]}
        with patch.object(self.p, "uygulamalar", return_value=apps), patch.object(self.p.containers, "view", return_value=fake), \
             patch.object(panel.master_shares, "Manager") as manager:
            manager.return_value.read.return_value = registry
            answer = self.get("depolama")
        self.assertEqual(answer["kok"], os.path.realpath(root))
        self.assertEqual(answer["kullananlar"], [
            {"yol": root + "/media", "id": "konteyner:notlar", "ad": "notlar", "tur": "konteyner", "hedef": "/media", "yazilabilir": False},
            {"yol": root + "/media/filmler", "id": "yerlesik:paylasim", "ad": "filmler", "tur": "paylasim", "hedef": "/s/abc/", "yazilabilir": True}])
        self.assertEqual(answer["hatalar"], [])

    def test_a_real_health_reply_has_the_declared_shape(self):
        # Commands that do not exist on the test machine read as failed checks, not as a broken reply.
        self.p.args.master_modul = "/fixture/master-modul"
        with patch.object(self.p, "health_cmd", return_value=(None, "")):
            master_api.check(master_api.ref("Saglik"), self.p.health_compute())


if __name__ == "__main__":
    unittest.main()
