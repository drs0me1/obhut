"""DD-271 (phase 3): the applications' routes through the real backend handler. Reads come from the records
with live state (Podman, systemctl and journalctl answer from fakes); every write is a job handed to the
broker (its launch is captured, nothing runs) with an audit line uygulama-<verb>. Every reply is checked
against master_api's shapes, and no secret value reaches a reply or an audit line."""
import json
from pathlib import Path
import sys
import time
import types
import unittest
from unittest.mock import patch

import app_fixtures
import test_resources
from test_overview import Fixture

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_api  # noqa: E402
import master_applications as apps  # noqa: E402
import master_container_manager  # noqa: E402

panel = test_resources.panel
SECRET = app_fixtures.SECRET
LABELS = {"io.master-stack.managed": "uygulama", "io.master-stack.uygulama": "notlar"}


class RouteTests(Fixture):
    def setUp(self):
        super().setUp()
        self.values = app_fixtures.env(self.root)
        with self.state.open("a") as fh:
            fh.write("".join("%s=%s\n" % kv for kv in self.values.items() if kv[0] != "STATE_FILE"))
        self.record = app_fixtures.record(dict(self.values, STATE_FILE=str(self.state)))

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        self.audits = []
        Handler.audit = lambda handler, user, action, detail, ok: self.audits.append((action, detail, ok))
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)
        self.ps, self.inspected, self.units = [], {}, {}
        for svc in ("web", "db"):
            self.container("notlar_" + svc, dict(LABELS, PODMAN_SYSTEMD_UNIT="konsol-notlar_%s.service" % svc))
            self.units["konsol-notlar_%s.service" % svc] = "active"
        self.container("eski", {})
        self.launched = []
        patch.object(self.p, "run_tool", side_effect=self.run_tool).start()
        patch.object(self.p.containers, "_launch", side_effect=lambda ident, action, data: self.launched.append((action, data))).start()
        patch.object(self.p, "update_check_soon").start()  # no registry check from a test
        patch.object(apps, "bindable", return_value=True).start()
        self.addCleanup(patch.stopall)

    def container(self, name, labels):
        ident = "%064x" % (len(self.ps) + 1)
        self.ps.append({"Id": ident, "Names": [name], "Image": "registry.example/x:1", "State": "running", "Labels": labels})
        self.inspected[name] = {"Id": ident, "Name": name, "ImageName": "registry.example/x:1", "Image": "registry.example/x:1",
                                "State": {"Running": True, "Status": "running"},
                                "Config": {"Labels": labels, "Env": ["DB_PASSWORD=" + SECRET, "MODE=prod"]},
                                "HostConfig": {"NetworkMode": "bridge"}, "Mounts": []}

    def run_tool(self, argv, binary=False, timeout=120):
        if argv[:2] == ["podman", "version"]:
            return 0, "5.4.2\n", ""
        if argv[:2] == ["podman", "ps"]:
            return 0, json.dumps(self.ps), ""
        if argv[:2] == ["podman", "inspect"]:
            return (0, json.dumps([self.inspected[argv[-1]]]), "") if argv[-1] in self.inspected else (125, "", "no such")
        if argv[:3] == ["podman", "image", "inspect"]:
            return 0, json.dumps([{"Config": {"Env": [], "Cmd": None}}]), ""
        if argv[:2] in (["podman", "images"], ["podman", "volume"], ["podman", "network"]):
            return 0, "[]", ""
        if argv[:2] == ["systemctl", "show"]:
            names = [a for a in argv[2:] if not a.startswith("--")]
            return 0, "\n\n".join("Id=%s\nActiveState=%s" % (n, self.units.get(n, "inactive")) for n in names), ""
        if argv[0] == "journalctl":
            return 0, "satır 1\nsatır 2\n", ""
        raise AssertionError(argv)

    def call(self, name, path=None, data=None, query="", code=None):
        route = next(r for r in master_api.ROUTES if r.name == name)
        path = path or route.path
        headers = {"X-Konsol": "1"}
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(data).encode()
        status, _, raw = test_resources.unix_get(self.sock, path + query, headers, route.method, body)
        answer = json.loads(raw)
        if code is not None:
            self.assertEqual(status, code, answer)
        if status == route.status:
            master_api.check(route.reply, answer)
        self.assertNotIn(SECRET, raw.decode())
        return status, answer

    def revision(self):
        return apps.Records(dict(self.values, STATE_FILE=str(self.state))).places("notlar")["revision"]

    def test_the_list_and_the_detail(self):
        _, answer = self.call("uygulamalar", code=200)
        self.assertEqual([(i["ad"], i["durum"]) for i in answer["items"]], [("notlar", "calisiyor")])
        self.assertEqual(answer["kaynaklar"], [{"ad": "eski", "imaj": "registry.example/x:1", "durum": "running"}])
        _, detail = self.call("uygulama", "/api/konsol/uygulamalar/notlar", code=200)
        self.assertEqual([s["ad"] for s in detail["servisler"]], ["web", "db"])
        self.assertEqual(detail["yanitlar"]["answers"]["var:DB_PASSWORD"], {"set": True})
        self.call("uygulama", "/api/konsol/uygulamalar/yok", code=404)
        for bad in ("Notlar", "a_b", "..", "%2e%2e"):
            status, _, _ = test_resources.unix_get(self.sock, "/api/konsol/uygulamalar/" + bad, {"X-Konsol": "1"})
            self.assertIn(status, (400, 404), bad)
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/uygulamalar/notlar", {})[0], 403)

    def test_a_services_log(self):
        _, log = self.call("uygulama_gunlugu", "/api/konsol/uygulamalar/notlar/gunluk", query="?servis=web&satir=100", code=200)
        self.assertEqual(log, {"satirlar": ["satır 1", "satır 2"], "kesik": False})
        self.call("uygulama_gunlugu", "/api/konsol/uygulamalar/notlar/gunluk", query="?servis=yok", code=404)

    def test_an_install_is_checked_here_and_handed_to_the_worker(self):
        request = {"metin": app_fixtures.SIMPLE, "yanitlar": app_fixtures.SIMPLE_ANSWERS, "kaynak": {"tur": "dosya"}}
        _, job = self.call("uygulama_kur", data=request, code=202)
        self.assertEqual((job["eylem"], job["ad"]), ("kur", "sayac"))
        [(action, data)] = self.launched
        self.assertEqual((action, data["name"], data["kaynak"], data["metin"]), ("uygulama-kur", "sayac", {"tur": "dosya"}, app_fixtures.SIMPLE))
        self.assertEqual(self.audits, [("uygulama-kur", "sayac", True)])
        # A refused file, wrong answers or a taken name never reach the worker.
        wrong = dict(request, yanitlar={"name": "sayac", "answers": {}})
        for data, code in ((dict(request, metin="services: ["), 400), (wrong, 400),
                           ({"metin": app_fixtures.TEXT, "yanitlar": app_fixtures.answers(), "kaynak": {"tur": "dosya"}}, 409),
                           (dict(request, kaynak={"tur": "adres", "adres": "http://x.example/a"}), 400)):
            with self.subTest(code=code):
                self.call("uygulama_kur", data=data, code=code)
        self.assertEqual(len(self.launched), 1)
        # The secret values travel to the worker only, never into the audit line.
        secret = {"metin": app_fixtures.TEXT.replace("notlar", "ikinci"),
                  "yanitlar": {"name": "ikinci", "answers": {k.replace("notlar", "ikinci"): v for k, v in app_fixtures.answers()["answers"].items()}},
                  "kaynak": {"tur": "dosya"}}
        self.call("uygulama_kur", data=secret, code=202)
        self.assertEqual(self.launched[-1][1]["yanitlar"]["answers"]["var:DB_PASSWORD"], {"value": SECRET})
        self.assertNotIn(SECRET, json.dumps(self.audits))
        self.assertNotIn(SECRET, json.dumps(self.p.containers.jobs))

    def test_the_actions_carry_the_revision_shown(self):
        self.call("uygulama_islemi", "/api/konsol/uygulamalar/notlar/islem", {"eylem": "durdur", "revizyon": "b" * 32}, code=409)
        _, job = self.call("uygulama_islemi", "/api/konsol/uygulamalar/notlar/islem", {"eylem": "durdur", "revizyon": self.revision()}, code=202)
        self.assertEqual((job["eylem"], job["ad"]), ("durdur", "notlar"))
        self.assertEqual(self.launched, [("uygulama-durdur", {"revizyon": self.revision(), "name": "notlar"})])
        self.assertEqual(self.audits, [("uygulama-durdur", "notlar", True)])
        self.call("uygulama_islemi", "/api/konsol/uygulamalar/yok/islem", {"eylem": "durdur", "revizyon": "b" * 32}, code=404)
        self.call("uygulama_islemi", "/api/konsol/uygulamalar/notlar/islem", {"eylem": "sil", "revizyon": "b" * 32}, code=400)

    def test_an_edit_is_planned_without_a_write_and_applied_as_a_job(self):
        given = app_fixtures.answers()
        given["answers"]["var:DB_PASSWORD"] = {"keep": True}
        text = app_fixtures.TEXT.replace("LOG_LEVEL: info", "LOG_LEVEL: debug")
        data = {"metin": text, "yanitlar": given, "plan": True, "revizyon": self.revision()}
        _, plan = self.call("uygulama_tanim", "/api/konsol/uygulamalar/notlar/tanim", data, code=200)
        self.assertEqual((plan["fark"]["ortam"], plan["fark"]["gizliler"]["korunan"]), (["web"], ["notlar-db-password"]))
        self.assertEqual(self.launched, [])
        _, job = self.call("uygulama_tanim", "/api/konsol/uygulamalar/notlar/tanim", dict(data, plan=False), code=200)
        self.assertEqual((job["eylem"], job["ad"]), ("tanim", "notlar"))
        self.assertEqual(self.launched[0][0], "uygulama-tanim")
        self.assertNotIn("plan", self.launched[0][1])
        given["answers"]["var:DB_PASSWORD"] = {"value": ""}
        _, plan = self.call("uygulama_tanim", "/api/konsol/uygulamalar/notlar/tanim", dict(data, yanitlar=given), code=200)
        self.assertIn("var:DB_PASSWORD", plan["hatalar"])
        self.call("uygulama_tanim", "/api/konsol/uygulamalar/notlar/tanim", dict(data, yanitlar=given, plan=False), code=400)
        self.call("uygulama_tanim", "/api/konsol/uygulamalar/notlar/tanim", dict(data, revizyon="b" * 32), code=409)
        self.assertEqual(len(self.launched), 1)

    def test_a_refresh_works_only_for_an_address_source(self):
        self.call("uygulama_yenile", "/api/konsol/uygulamalar/notlar/yenile", {}, code=409)
        values = dict(self.values, STATE_FILE=str(self.state))
        apps.Records(values).write("notlar", source=apps.source_record({"tur": "adres", "adres": "https://dosya.example.org/c.yaml"},
                                                                       app_fixtures.TEXT, 1))
        newer = app_fixtures.TEXT.replace("      LOG_LEVEL: info\n", "      LOG_LEVEL: ${LOG_LEVEL}\n")
        with patch.object(apps, "fetch", return_value=newer) as fetch:
            _, answer = self.call("uygulama_yenile", "/api/konsol/uygulamalar/notlar/yenile", {}, code=200)
        fetch.assert_called_once()
        self.assertEqual(fetch.call_args.args[0], "https://dosya.example.org/c.yaml")
        self.assertEqual((answer["metin"], answer["yeni_sorular"]), (newer, ["var:LOG_LEVEL"]))
        self.assertEqual(self.launched, [])

    def test_a_removal_needs_the_name_to_delete_data(self):
        data = {"veri": "sil", "revizyon": self.revision()}
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", data, code=400)
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", dict(data, onay="yanlis"), code=400)
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", dict(data, onay="notlar"), code=202)
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", {"veri": "sakla", "revizyon": self.revision()}, code=409)
        self.assertEqual(self.launched, [("uygulama-kaldir", {"veri": "sil", "revizyon": self.revision(), "onay": "notlar", "name": "notlar"})])
        self.assertEqual(self.audits, [("uygulama-kaldir", "notlar (veri: sil)", True)])

    def test_drafts_from_an_address_a_container_and_an_image(self):
        with patch.object(apps, "fetch", return_value="services: {}\n"):
            _, draft = self.call("uygulama_kaynak", data={"tur": "adres", "adres": "https://dosya.example.org/c.yaml?token=abc"},
                                 code=200)
        self.assertEqual(draft, {"metin": "services: {}\n", "kaynak": {"tur": "adres", "adres": "https://dosya.example.org/c.yaml?token=abc"}})
        self.assertEqual(self.audits[-1], ("uygulama-taslak", "adres dosya.example.org", True), "the address's query is not logged")
        _, draft = self.call("uygulama_kaynak", data={"tur": "konteyner", "konteyner": "eski"}, code=200)
        self.assertIn("MODE: \"prod\"", draft["metin"])
        self.assertIn("DB_PASSWORD: \"\"", draft["metin"])
        self.call("uygulama_kaynak", data={"tur": "konteyner", "konteyner": "notlar_web"}, code=409)
        self.call("uygulama_kaynak", data={"tur": "konteyner", "konteyner": "yok"}, code=404)
        _, job = self.call("uygulama_kaynak", data={"tur": "imaj", "imaj": "registry.example/sayac:2"}, code=200)
        self.assertEqual(self.launched, [("uygulama-taslak", {"imaj": "registry.example/sayac:2", "name": "registry.example/sayac:2"})])
        self.assertEqual(set(job), {"is"})
        self.call("uygulama_kaynak", data={"tur": "imaj", "imaj": "Kötü"}, code=400)
        self.call("uygulama_kaynak", data={"tur": "dosya"}, code=400)
        with patch.object(apps, "fetch", side_effect=apps.AppError(400, "yerel bir adrese çözümleniyor")):
            self.call("uygulama_kaynak", data={"tur": "adres", "adres": "https://ic.example.org/c.yaml"}, code=400)


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


class RepairRouteTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)

    def post(self, body, path, headers=None):
        status, _, answer = test_resources.unix_get(self.sock, path, {"X-Konsol": "1", "Content-Type": "application/json", **(headers or {})},
                                                    method="POST", body=json.dumps(body).encode())
        return status, json.loads(answer)

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
