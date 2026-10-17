"""DD-259: master_api's route table. Every route has its handler method, the committed OpenAPI
description and TypeScript types are what the table generates, the schema check refuses wrong
shapes, and the table's routes answer through the real handler with replies of their declared shape.
DD-271: the backend answers nothing outside the table but the session check and the sign-in POST."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import unittest.mock
from unittest.mock import patch

import app_fixtures
import test_resources
from test_overview import Fixture

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_api  # noqa: E402

FIXTURES = DATA / "tests" / "fixtures" / "uygulama"

panel = test_resources.panel
SAMPLES = {"app": "notlar", "iface": "wg0", "name": "telefon"}


def concrete(route):
    """A request path for a route: each {param} filled with a valid sample."""
    path = route.path
    for name in route.params:
        path = path.replace("{%s}" % name, SAMPLES[name])
    return path


class TableTests(unittest.TestCase):
    def test_every_route_has_its_handler_and_a_unique_name(self):
        names = [r.name for r in master_api.ROUTES]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(len({(r.method, r.path) for r in master_api.ROUTES}), len(names))
        for route in master_api.ROUTES:
            self.assertTrue(callable(getattr(panel.Handler, "api_" + route.name, None)), route.name)
            self.assertTrue(route.path.startswith("/api/konsol/"), route.path)
            self.assertIs(master_api.find(route.method, concrete(route)), route)
            self.assertTrue((route.reply is None) != (route.events is None), route.name)
            self.assertLessEqual(set(route.params), set(master_api.PATH_PARAMS), route.name)
        self.assertIsNone(master_api.find("POST", "/api/konsol/erisim"))
        # A handler method without a route would be dead code, or a way in that the table does not show.
        handlers = {name[len("api_"):] for name in dir(panel.Handler) if name.startswith("api_")}
        self.assertEqual(handlers, set(names))

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
        self.assertEqual(self.get("etkinlik"), {"items": []})
        self.assertEqual(self.get("bekleyen"), {"bekleyen": None})
        with patch.object(self.p.updates, "latest", return_value={"at": 7, "ok": True, "son": "2026.08.06-v2-300", "nesil": 2,
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
        row = {"id": "abc", "name": "notlar_web", "image": "registry.example/notlar/web@sha256:" + "a" * 64, "state": "running",
               "status": "Up", "unit": "konsol-notlar_web.service", "network": "ksl-notlar", "created": 1, "started": 2, "exit_code": 0,
               "restarts": 0, "ports": [{"host_ip": "127.0.0.1", "host_port": 62100, "container_port": 80, "protocol": "tcp",
                                          "scope": "local"}],
               "mounts": 1, "health": "", "live": True, "source": "uygulama", "uygulama": "notlar",
               "cpu_percent": None, "memory_bytes": 1024, "busy": None, "listening": None}
        listing = {"read_at": 1, "runtime": {"version": "5.4.2", "ok": True, "error": ""}, "containers": [row],
                   "images": [{"id": "i1", "name": "docker.io/library/nginx:alpine", "size": 10, "created": 1, "used_by": ["notlar"],
                               "managed": True}],
                   "volumes": [{"name": "v", "driver": "local", "size": None, "used_by": [], "managed": True}],
                   "networks": [{"name": "ksl-notlar", "id": "n1", "driver": "bridge", "subnets": ["10.89.1.0/24"], "used_by": ["notlar"],
                                 "managed": True, "internal": False}],
                   "storage": {"images": 1, "containers": 1, "size": None}, "resource_errors": {}}
        detail = dict(row, mounts=[{"type": "volume", "source": "v", "destination": "/data", "rw": True, "name": "v"}],
                      user="", command="nginx")
        fake = unittest.mock.Mock()
        fake.liste.return_value, fake.ayrinti.return_value = listing, detail
        with patch.object(panel.Handler, "container_view", return_value=fake):
            self.assertEqual(self.get("konteyner_listesi"), listing)
            self.assertEqual(self.get("konteyner_ayrintisi", "?ad=notlar_web")["command"], "nginx")
        status, _headers, body = test_resources.unix_get(self.sock, "/api/konsol/konteynerler/ayrinti?ad=../x", {"X-Konsol": "1"})
        self.assertEqual(status, 400, body)

    def test_a_body_of_another_shape_is_refused_before_the_handler(self):
        self.assertEqual(self.post("oturum_cikis", {}), (200, {"durum": "cikis"}))
        status, answer = self.post("oturum_cikis", {"x": 1})
        self.assertEqual(status, 400)
        self.assertIn("İstek biçimi geçersiz", answer["error"])
        self.assertEqual(self.post("hesap_parola", {"yeni": 5})[0], 400)

    def test_shares_and_storage_from_the_table(self):
        # DD-267: Dosyalar → Paylaşımlar reads the share manager's own view; a pause request is gone.
        conn = {"enabled": True, "permission": "ro", "expires": 1900000000, "expired": False, "available": True, "active": True,
                "reason": "", "url": "http://100.64.0.1:61010/s/abc/"}
        view = {"host": "http://100.64.0.1:61010", "max": 32, "tail_enabled": True,
                "items": [{"id": "abc", "path": "media/filmler", "name": "filmler", "username": "film", "created": 1, "changed": 2,
                           "type": "dir", "available": True, "connections": {"tailscale": conn}, "urls": {"tailscale": conn["url"]},
                           "url": conn["url"]}],
                "wan": {"available": False, "address": "", "reason": "x", "mode": "off", "domain": "", "port": 443}, "limits": {}}
        with patch.object(panel.master_shares, "Manager") as manager:
            manager.return_value.public.return_value = view
            self.assertEqual(self.get("paylasimlar"), view)
        with patch.object(self.p, "settings_run", return_value=(200, view)) as run:
            self.assertEqual(self.post("paylasim_kaldir", {"id": "abc"}), (200, view))
        run.assert_called_once_with("remove", {"id": "abc"}, shares=True)
        self.assertEqual(self.post("paylasim_kaldir", {"id": "abc", "x": 1})[0], 400)
        # Depolama (K7): each application's /srv folders from its record, and each share.
        values = app_fixtures.env(self.root)
        with self.state.open("a") as fh:
            fh.write("UYGULAMA_STATE_DIR=%s\n" % values["UYGULAMA_STATE_DIR"])
        app_fixtures.record(dict(values, STATE_FILE=str(self.state)))
        registry = {"root": "/srv", "items": [{"id": "abc", "path": "media/filmler", "name": "filmler",
                                               "connections": {"tailscale": {"enabled": True, "permission": "rw", "expires": None}}}]}
        with patch.object(panel.master_shares, "Manager") as manager, patch.object(panel.subprocess, "run",
                                                                                   side_effect=AssertionError("no command")):
            manager.return_value.read.return_value = registry
            answer = self.get("depolama")
        self.assertEqual(answer["kok"], os.path.realpath(str(self.root)))
        self.assertEqual(answer["kullananlar"], [
            {"yol": "/srv/media", "id": "notlar", "ad": "notlar", "tur": "uygulama", "hedef": "web: /media", "yazilabilir": False},
            {"yol": "/srv/media/filmler", "id": "paylasim", "ad": "filmler", "tur": "paylasim", "hedef": "/s/abc/", "yazilabilir": True}])
        self.assertEqual(answer["hatalar"], [])

    def raw_post(self, path, body):
        status, _headers, raw = test_resources.unix_get(
            self.sock, path, {"X-Konsol": "1", "Content-Type": "application/json"}, method="POST", body=body)
        return status, raw

    def test_the_inspector_dry_run_from_the_table(self):
        # DD-271 (phase 2): a whole file fits in the request, nothing is run or written, no secret value comes back.
        text = (FIXTURES / "notlar-compose.yaml").read_text()
        answers = {"name": "notlar", "answers": {
            "var:NOTLAR_VERSION": {"value": "1.5"}, "var:BASE_URL": {"value": ""}, "var:DB_PASSWORD": {"value": "Gizli-7f3a9"},
            "var:LOG_LEVEL": {"value": "debug"}, "port:web:3000/tcp": {"use": "caddy", "tailscale_name": "notlar"},
            "mount:web:/app/uploads": {"to": "app"},
            "mount:web:/media/notlar": {"to": "srv", "path": "/srv/media/notlar", "read_only": True},
            "start:web": {"mode": "direct"}, "mount:db:/var/lib/postgresql/data": {"to": "app"}, "start:db": {"mode": "root"}}}
        route = next(r for r in master_api.ROUTES if r.name == "uygulama_denetle")
        handler = panel.Handler.api_uygulama_denetle

        def guarded(self, user, data):
            # While the handler runs (the gates before it read state.env), no file is opened.
            with patch("builtins.open", side_effect=AssertionError("nothing is read or written")), \
                    patch.object(panel.os, "open", side_effect=AssertionError("nothing is read or written")):
                return handler(self, user, data)
        with patch.object(panel.subprocess, "run", side_effect=AssertionError("no command may run")), \
                patch.object(panel.subprocess, "Popen", side_effect=AssertionError("no command may run")), \
                patch.object(panel.Handler, "api_uygulama_denetle", guarded):
            status, answer = self.post("uygulama_denetle", {"metin": text})
            self.assertEqual((status, set(answer)), (200, {"inceleme"}))
            self.assertEqual((answer["inceleme"]["format"], answer["inceleme"]["refusals"]), ("compose", []))
            self.assertIn("var:DB_PASSWORD", [q["id"] for q in answer["inceleme"]["questions"]])
            status, raw = self.raw_post(route.path, json.dumps({"metin": text, "yanitlar": answers}).encode())
        self.assertEqual(status, 200, raw)
        reply = json.loads(raw)
        master_api.check(route.reply, reply)
        self.assertEqual(set(reply), {"inceleme", "tanim"})
        self.assertNotIn(b"Gizli-7f3a9", raw)
        env = {e["name"]: e for e in reply["tanim"]["services"][0]["environment"]}
        self.assertEqual((env["DB_PASSWORD"], env["LOG_LEVEL"]),
                         ({"name": "DB_PASSWORD", "secret": "notlar-db-password"}, {"name": "LOG_LEVEL", "value": "debug"}))
        # Answers the checker refuses come back by question, without a definition.
        answers["answers"]["port:web:3000/tcp"] = {"use": "caddy", "tailscale_name": "panel"}
        answers["answers"].pop("start:db")
        status, answer = self.post("uygulama_denetle", {"metin": text, "yanitlar": answers})
        self.assertEqual((status, set(answer)), (200, {"inceleme", "hatalar"}))
        self.assertEqual(set(answer["hatalar"]), {"port:web:3000/tcp", "start:db"})
        # A refused file is an inspection, not an error.
        status, answer = self.post("uygulama_denetle", {"metin": (FIXTURES / "unsafe-compose.yaml").read_text()})
        self.assertEqual((status, len(answer["inceleme"]["refusals"])), (200, 8))
        status, answer = self.post("uygulama_denetle", {"metin": "services: ["})
        self.assertEqual((status, answer["inceleme"]["format"], answer["inceleme"]["refusals"][0]["line"]), (200, None, 1))

    def test_the_inspector_takes_a_whole_file_and_no_more(self):
        route = next(r for r in master_api.ROUTES if r.name == "uygulama_denetle")
        padding = "# %s\n" % ("x" * 76)
        big = (FIXTURES / "ornek-compose.yaml").read_text() + padding * 2500
        self.assertGreater(len(big), 3 * 65536)
        status, answer = self.post("uygulama_denetle", {"metin": big})
        self.assertEqual((status, answer["inceleme"]["refusals"]), (200, []), "larger than the usual body limit")
        status, answer = self.post("uygulama_denetle", {"metin": "#" * (256 * 1024 + 1)})
        self.assertEqual(status, 400)
        self.assertIn("256 KiB", answer["error"])
        status, raw = self.raw_post(route.path, json.dumps({"metin": "\n" * (route.body_limit // 2)}).encode())
        self.assertEqual(status, 400, "the body limit holds before anything is parsed")
        self.assertIn("JSON", json.loads(raw)["error"])
        status, raw = self.raw_post(route.path, b'{"metin": "\\ud800"}')
        self.assertEqual(status, 400, raw)
        for bad in ({"metin": 5}, {"metin": "x", "extra": 1}, {"metin": "x", "yanitlar": {"name": "x"}},
                    {"metin": "x", "yanitlar": {"name": "x", "answers": {"start:a": {"mode": 1}}}}):
            with self.subTest(bad=bad):
                self.assertEqual(self.post("uygulama_denetle", bad)[0], 400)
        # Every other route keeps the usual limit.
        status, raw = self.raw_post("/api/konsol/oturum/cikis", json.dumps({"x": "y" * 70000}).encode())
        self.assertEqual(status, 400)
        self.assertIn("JSON", json.loads(raw)["error"])

    def test_a_real_health_reply_has_the_declared_shape(self):
        # Commands that do not exist on the test machine read as failed checks, not as a broken reply.
        with patch.object(self.p, "health_cmd", return_value=(None, "")):
            master_api.check(master_api.ref("Saglik"), self.p.health_compute())


class OnlyTheTableAnswers(Fixture):
    """DD-271 (rebuild.md §2.3, §7.4): no request reaches the backend outside the route table except the
    session check Caddy asks and the sign-in POST. With the table emptied, every other path is 404 and
    no handler runs."""

    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)

    def request(self, method, path, body=None):
        headers = {"X-Konsol": "1"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        status, _headers, raw = test_resources.unix_get(self.sock, path, headers, method=method, body=body)
        return status, raw

    def test_nothing_outside_the_table_answers(self):
        paths = sorted({concrete(r) for r in master_api.ROUTES} | {
            "/", "/api", "/api/konsol", "/api/konsol/", "/api/x/y", "/api/state", "/giris.html",
            "/api/konsol/oturum/giris", "/oturum-denetle/x", "/api/konsol/erisim/x", "/api/konsol/wireguard/nets/wg0"})
        empty = (None, None)
        with patch.object(panel.master_api, "match", return_value=empty) as match, \
                patch.object(panel.subprocess, "run", side_effect=AssertionError("no handler may run")):
            for path in paths:
                for method, body in (("GET", None), ("HEAD", None), ("POST", b"{}")):
                    if (method, path) == ("POST", "/api/konsol/oturum/giris"):
                        continue
                    with self.subTest(method=method, path=path):
                        self.assertEqual(self.request(method, path, body)[0], 404)
        self.assertTrue(match.called)

    def test_the_two_exceptions_answer_without_the_table(self):
        with patch.object(panel.master_api, "match", side_effect=AssertionError("not through the table")):
            status, _raw = self.request("GET", "/oturum-denetle")
            self.assertNotEqual(status, 404)
            status, raw = self.request("POST", "/api/konsol/oturum/giris", b'{"kullanici": "x", "parola": "y"}')
            self.assertNotEqual(status, 404, raw)

    def test_other_methods_are_not_implemented(self):
        self.assertEqual({name for name in dir(panel.Handler) if name.startswith("do_")}, {"do_GET", "do_HEAD", "do_POST"})
        for method in ("PUT", "DELETE", "PATCH", "OPTIONS"):
            with self.subTest(method=method):
                self.assertEqual(self.request(method, "/api/konsol/erisim")[0], 501)


if __name__ == "__main__":
    unittest.main()
