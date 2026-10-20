"""DD-271 (phase 3): the applications' routes through the real backend handler. Reads come from the records
with live state (Podman, systemctl and journalctl answer from fakes); every write is a job handed to the
broker (its launch is captured, nothing runs) with an audit line uygulama-<verb>. The install plan runs the job's
checks with read-only commands and writes nothing. Every reply is checked against master_api's shapes, and no secret
value reaches a reply or an audit line."""
import json
import os
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
import master_container_binds  # noqa: E402
import master_container_manager  # noqa: E402

panel = test_resources.panel
SECRET = app_fixtures.SECRET
LABELS = {"io.master-stack.managed": "uygulama", "io.master-stack.uygulama": "notlar"}


class RouteTests(Fixture):
    def setUp(self):
        super().setUp()
        self.values = app_fixtures.env(self.root)
        with self.state.open("a") as fh:
            fh.write("".join("%s=%s\n" % kv for kv in self.values.items() if kv[0] not in ("STATE_FILE", "LOCAL_DOMAIN")))
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
        self.launched, self.commands, self.existing, self.podman_version = [], [], set(), "5.4.2\n"
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
        self.commands.append(list(argv))
        if argv[:2] == ["podman", "version"]:
            return 0, self.podman_version, ""
        if argv[:2] in (["podman", "container"], ["podman", "network"], ["podman", "pod"]) and argv[2:3] == ["exists"]:
            return (0 if argv[-1] in self.inspected or argv[-1] in self.existing else 1), "", ""
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
        elif status in route.also:
            master_api.check(route.also[status], answer)
        self.assertNotIn(SECRET, raw.decode())
        return status, answer

    def revision(self):
        return apps.Records(dict(self.values, STATE_FILE=str(self.state))).places("notlar")["revision"]

    def test_the_list_and_the_detail(self):
        _, answer = self.call("uygulamalar", code=200)
        self.assertEqual([(i["ad"], i["durum"]) for i in answer["items"]], [("notlar", "calisiyor")])
        self.assertNotIn("kaynaklar", answer, "a container Obhut did not install is never offered")
        _, detail = self.call("uygulama", "/api/konsol/uygulamalar/notlar", code=200)
        self.assertEqual([s["ad"] for s in detail["servisler"]], ["web", "db"])
        self.assertEqual(detail["yanitlar"]["answers"]["var:DB_PASSWORD"], {"set": True})
        self.assertEqual(detail["servisler"][0]["portlar"][0]["id"], "uygulama:notlar:web:8080/tcp")
        self.assertEqual(detail["servisler"][0]["portlar"][0]["erisim"]["tur"], "adres")
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
        # A Tailscale name another application's row holds is refused by its question before the worker.
        secret = {"metin": app_fixtures.TEXT.replace("notlar", "ikinci"),
                  "yanitlar": {"name": "ikinci", "answers": {k.replace("notlar", "ikinci"): v for k, v in app_fixtures.answers()["answers"].items()}},
                  "kaynak": {"tur": "dosya"}}
        _, refused = self.call("uygulama_kur", data=secret, code=409)
        self.assertEqual(refused["error"], "port:web:8080/tcp: notlar.test adı zaten kullanılıyor.")
        self.assertEqual(len(self.launched), 1)
        # The secret values travel to the worker only, never into the audit line.
        secret["yanitlar"]["answers"]["port:web:8080/tcp"] = {"use": "caddy", "tailscale_name": "ikinci"}
        self.call("uygulama_kur", data=secret, code=202)
        self.assertEqual(self.launched[-1][1]["yanitlar"]["answers"]["var:DB_PASSWORD"], {"value": SECRET})
        self.assertNotIn(SECRET, json.dumps(self.audits))
        self.assertNotIn(SECRET, json.dumps(self.p.containers.jobs))

    def files(self):
        return {str(p): (p.lstat().st_mtime_ns, p.lstat().st_size) for p in self.root.rglob("*")}

    def test_an_install_plan_runs_the_jobs_checks_and_writes_nothing(self):
        request = {"metin": app_fixtures.SIMPLE, "yanitlar": app_fixtures.SIMPLE_ANSWERS, "kaynak": {"tur": "dosya"}, "plan": True}
        before = self.files()
        _, plan = self.call("uygulama_kur", data=request, code=200)
        self.assertEqual(set(plan), {"inceleme", "tanim", "ozet"})
        veri = self.values["UYGULAMA_VERI_DIR"] + "/sayac"
        self.assertEqual(plan["ozet"], {
            "ad": "sayac", "veri": veri, "ag": "ksl-sayac", "pod": None,
            "birimler": ["konsol-sayac.network", "konsol-sayac_app.container"],
            "servisler": [{"ad": "app", "baslangic": "root", "kullanici": None, "imaj": "registry.example/sayac:2",
                           "baglamalar": [{"hedef": "/data", "tur": "app", "yol": veri + "/veri", "salt_okunur": False,
                                           "boyut": None}],
                           "gizliler": []}],
            "erisim": [{"id": "uygulama:sayac:app:9000/tcp", "anahtar": "app:9000/tcp", "servis": "app", "port": 9000,
                        "protokol": "tcp", "satir": {"tur": "adres", "ad": "sayac", "tailscale_portu": None, "internet": ""},
                        "adres": "http://sayac.test"}],
            "klasorler": [veri + "/veri"], "gizliler": [], "uyarilar": [], "imajlar": ["registry.example/sayac:2"]})
        self.assertEqual(self.files(), before, "nothing written")
        self.assertEqual((self.launched, self.audits), ([], []), "no job, no audit line")
        plan_commands = master_container_manager.PLAN_COMMANDS
        self.assertTrue(self.commands)
        self.assertFalse([c for c in self.commands if not any(tuple(c[:len(p)]) == p for p in plan_commands)
                          and c[:2] not in (["podman", "ps"], ["systemctl", "show"])], self.commands)
        # The worker's checks in the backend may run nothing that writes or pulls.
        worker = self.p.containers.worker()
        for argv in (["podman", "pull", "registry.example/sayac:2"], ["podman", "secret", "create", "x", "-"], ["systemctl", "start", "x"]):
            with self.subTest(argv=argv), self.assertRaises(apps.AppError):
                worker.call(argv)
        # A file with a secret, a /srv folder and a dependency: the secret by name only, the folder walked, no value back.
        second = {"metin": app_fixtures.TEXT.replace("notlar", "ikinci"),
                  "yanitlar": {"name": "ikinci", "answers": {k.replace("notlar", "ikinci"): v
                                                             for k, v in app_fixtures.answers()["answers"].items()}},
                  "kaynak": {"tur": "dosya"}, "plan": True}
        second["yanitlar"]["answers"]["port:web:8080/tcp"] = {"use": "caddy", "tailscale_name": "ikinci"}
        walked = []
        with patch.object(master_container_binds, "walk", side_effect=lambda path: walked.append(path) or os.open(self.root, os.O_RDONLY)):
            _, plan = self.call("uygulama_kur", data=second, code=200)
        self.assertEqual(walked, ["/srv/media"])
        ozet = plan["ozet"]
        self.assertEqual(ozet["gizliler"], [{"ad": "ikinci-db-password", "servisler": ["web", "db"]}])
        self.assertEqual([(s["ad"], s["baslangic"], s["kullanici"], s["gizliler"]) for s in ozet["servisler"]],
                         [("web", "direct", "1000:1000", ["ikinci-db-password"]), ("db", "root", None, ["ikinci-db-password"])])
        self.assertEqual(ozet["imajlar"], ["registry.example/ikinci/db:16", "registry.example/ikinci/web:1.4"])
        self.assertEqual(ozet["uyarilar"], [], "a direct start as the Files account with a read-only folder warns of nothing")
        self.assertEqual(self.files(), before, "nothing written")
        # Without plan the same request is the job.
        _, job = self.call("uygulama_kur", data=dict(request, plan=False), code=202)
        self.assertEqual(job["eylem"], "kur")

    def test_an_install_plan_names_every_refusal_by_question(self):
        # A refused file is an inspection; answers that do not check come back by question.
        _, plan = self.call("uygulama_kur", data={"metin": "services: [", "yanitlar": {"name": "x", "answers": {}},
                                                  "kaynak": {"tur": "dosya"}, "plan": True}, code=200)
        self.assertEqual(set(plan), {"inceleme"})
        given = app_fixtures.answers()
        given["answers"].pop("start:db")
        request = {"metin": app_fixtures.TEXT, "yanitlar": given, "kaynak": {"tur": "dosya"}, "plan": True}
        _, plan = self.call("uygulama_kur", data=request, code=200)
        self.assertEqual((set(plan), set(plan["hatalar"])), ({"inceleme", "hatalar"}, {"start:db"}))
        # The state checks: the name is taken, its /srv folder fails DD-226, Podman 4.9 cannot wait for health.
        self.podman_version = "4.9.3\n"
        with patch.object(master_container_binds, "walk",
                          side_effect=master_container_binds.BindError("Bağlanan klasör eksik: /srv/media")):
            _, plan = self.call("uygulama_kur", data=dict(request, yanitlar=app_fixtures.answers()), code=200)
        self.assertEqual(set(plan["hatalar"]), {"name", "mount:web:/media", "podman"})
        self.assertEqual((plan["hatalar"]["name"], plan["hatalar"]["mount:web:/media"]),
                         ("Bu adla bir uygulama zaten var.", "Bağlanan klasör eksik: /srv/media"))
        self.assertIn("Podman 5 gerekir; bu sunucuda 4.9", plan["hatalar"]["podman"])
        self.podman_version = "5.4.2\n"
        simple = {"metin": app_fixtures.SIMPLE, "yanitlar": app_fixtures.SIMPLE_ANSWERS, "kaynak": {"tur": "dosya"}, "plan": True}
        # A Tailscale name another application's row holds; a container or network of the name; no pool port left.
        taken = json.loads(json.dumps(simple).replace('"tailscale_name": "sayac"', '"tailscale_name": "notlar"'))
        _, plan = self.call("uygulama_kur", data=taken, code=200)
        self.assertEqual(plan["hatalar"], {"port:app:9000/tcp": "notlar.test adı zaten kullanılıyor."})
        self.existing = {"ksl-sayac"}
        _, plan = self.call("uygulama_kur", data=simple, code=200)
        self.assertEqual(plan["hatalar"], {"name": "Bu adla bir ağ zaten var: ksl-sayac"})
        self.existing = set()
        with patch.object(apps, "bindable", return_value=False):
            _, plan = self.call("uygulama_kur", data=simple, code=200)
        self.assertEqual(plan["hatalar"], {"portlar": "Yerel port aralığında boş port kalmadı."})
        # An existing container is no source: applications come only from a file, an address or an image.
        self.call("uygulama_kur", data=dict(simple, kaynak={"tur": "konteyner", "konteyner": "eski"}), code=400)
        self.assertEqual((self.launched, self.audits), ([], []))

    def test_the_list_and_the_detail_carry_the_bridge_rate_and_the_first_address(self):
        _, answer = self.call("uygulamalar", code=200)
        self.assertEqual((answer["items"][0]["ag"], answer["items"][0]["adres"]), (None, "http://notlar.test"),
                         "no rate before the sampler measured one")
        self.p.app_net_last["notlar"] = {"t": int(time.time()), "indirme": 2048, "yukleme": 512}
        self.p.app_net_prev["notlar"] = ("ksl-notlar", 0.0, 314572800, 1288490189)
        rate = {"indirme": 2048, "yukleme": 512, "toplam": {"indirme": 1288490189, "yukleme": 314572800}}
        _, answer = self.call("uygulamalar", code=200)
        self.assertEqual(answer["items"][0]["ag"], rate, "the rate with the bridge's counters so far (DD-287)")
        _, detail = self.call("uygulama", "/api/konsol/uygulamalar/notlar", code=200)
        self.assertEqual((detail["uygulama"]["ag"], detail["uygulama"]["adres"]), (rate, "http://notlar.test"))
        # A raw port is no address.
        values = dict(self.values, STATE_FILE=str(self.state))
        rows = apps.Records(values).rows("notlar")
        apps.Records(values).write("notlar", rows={k: {"tur": "ham", "kapsam": "kapali", "port": 8080} for k in rows},
                                   places=dict(apps.Records(values).places("notlar"), ports={}))
        _, answer = self.call("uygulamalar", code=200)
        self.assertIsNone(answer["items"][0]["adres"])

    def test_the_update_view_counts_the_applications_with_an_image_update(self):
        with patch.object(self.p.updates, "status", return_value={"yeni": False}), patch.object(self.p, "unit_active", return_value=False):
            self.assertEqual(self.p.update_info()["uygulamalar"], {"sayi": 0, "adlar": [], "denetlendi": None})
            self.p.containers.update_items = {"notlar": {"web": {"state": "var", "channel": "registry.example/notlar/web:1.4"},
                                                         "db": {"state": "guncel", "channel": "registry.example/notlar/db:16"}}}
            self.p.containers.update_at = 1_800_000_000.0
            self.assertEqual(self.p.update_info()["uygulamalar"], {"sayi": 1, "adlar": ["notlar"], "denetlendi": 1_800_000_000})
        _, answer = self.call("uygulamalar", code=200)
        self.assertEqual(answer["items"][0]["guncelleme"], "yeni", "the list reads the same state")

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
        self.assertEqual((answer["metin"], answer["yeni_sorular"]), (newer, ["var:LOG_LEVEL"]), "a port that stays is no new question")
        self.assertEqual(answer["yanitlar"]["answers"]["port:web:8080/tcp"], {"use": "caddy", "tailscale_name": "notlar"},
                         "the port answers come from the rows")
        self.assertEqual(self.launched, [])

    def test_a_removal_needs_the_name_to_delete_data(self):
        data = {"veri": "sil", "revizyon": self.revision()}
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", data, code=400)
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", dict(data, onay="yanlis"), code=400)
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", dict(data, onay="notlar"), code=202)
        self.call("uygulama_kaldir", "/api/konsol/uygulamalar/notlar/kaldir", {"veri": "sakla", "revizyon": self.revision()}, code=409)
        self.assertEqual(self.launched, [("uygulama-kaldir", {"veri": "sil", "revizyon": self.revision(), "onay": "notlar", "name": "notlar"})])
        self.assertEqual(self.audits, [("uygulama-kaldir", "notlar (veri: sil)", True)])

    def test_drafts_from_an_address_and_an_image(self):
        with patch.object(apps, "fetch", return_value="services: {}\n"):
            _, draft = self.call("uygulama_kaynak", data={"tur": "adres", "adres": "https://dosya.example.org/c.yaml?token=abc"},
                                 code=200)
        self.assertEqual(draft, {"metin": "services: {}\n", "kaynak": {"tur": "adres", "adres": "https://dosya.example.org/c.yaml?token=abc"}})
        self.assertEqual(self.audits[-1], ("uygulama-taslak", "adres dosya.example.org", True), "the address's query is not logged")
        self.call("uygulama_kaynak", data={"tur": "konteyner", "konteyner": "eski"}, code=400)
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
