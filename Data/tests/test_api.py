"""DD-259: master_api's route table. Every route has its handler method, the committed OpenAPI
description and TypeScript types are what the table generates, the schema check refuses wrong
shapes, and the table's routes answer through the real handler with replies of their declared shape."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
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

    def get(self, name):
        route = next(r for r in master_api.ROUTES if r.name == name)
        status, headers, body = test_resources.unix_get(self.sock, route.path, {"X-Konsol": "1"})
        self.assertEqual(status, 200, body)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        answer = json.loads(body)
        master_api.check(route.reply, answer)
        return answer

    def test_the_table_routes_answer_with_their_shapes(self):
        self.assertEqual(self.get("kaynaklar")["domain"], "test")
        with patch.object(self.p, "health_compute", return_value={"status": "warn", "read_at": 1,
                                                                    "checks": [{"id": "units", "name": "Servisler", "status": "warn", "detail": "x"}]}):
            self.assertEqual(self.get("saglik")["status"], "warn")
        with patch.object(self.p, "busy_units", return_value=set()):
            self.assertEqual(self.get("etkinlik"), {"items": []})
        self.assertEqual(self.get("bekleyen"), {"bekleyen": None})
        modules = [{"id": "torrent", "runtime": "konteyner", "installed": True, "state": "calisiyor", "live": "running", "busy": False,
                    "progress": None, "durdurulabilir": True, "sayfa": ["sayfa.js"],
                    "konsol": {"ad": "qBittorrent", "neler": [["box", "x"]], "sayfa": {"rota": "torrent", "baslik": "qBittorrent"}},
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

    def test_a_real_health_reply_has_the_declared_shape(self):
        # Commands that do not exist on the test machine read as failed checks, not as a broken reply.
        self.p.args.master_modul = "/fixture/master-modul"
        with patch.object(self.p, "health_cmd", return_value=(None, "")):
            master_api.check(master_api.ref("Saglik"), self.p.health_compute())


if __name__ == "__main__":
    unittest.main()
