"""Rebuild phase 4: an application's access rows through the settings transaction (the "erisim" section), their
projection (Caddy sites, local names, the 443 gate), the firewall (K5 entries, fixed rows, refused operator
rules), Yerel adlar and the audit line.

The records are real (master_applications, written through app_fixtures); the share publisher is the real one
with every host command faked; the container side is a fake Manager that writes the rows as row_change does.
Neutral names only (registry.example, example.net)."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

import app_fixtures
import test_https_settings as fixtures
import test_resources

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_api  # noqa: E402
import master_applications as apps  # noqa: E402
import master_https as tls  # noqa: E402
import master_publications as pubs  # noqa: E402
import master_settings as settings  # noqa: E402
import master_shares as shares  # noqa: E402
import master_wireguard  # noqa: E402

panel = test_resources.panel
TEXT = """name: notlar
services:
  web:
    image: registry.example/notlar/web:1.4
    ports:
      - "8080"
      - "6881/udp"
      - "7000"
"""
ANSWERS = {"name": "notlar", "answers": {"port:web:8080/tcp": {"use": "caddy", "tailscale_name": "notlar"},
                                         "port:web:6881/udp": {"use": "raw"}, "port:web:7000/tcp": {"use": "raw"},
                                         "start:web": {"mode": "root"}}}
WEB, PEER, RAW = "web:8080/tcp", "web:6881/udp", "web:7000/tcp"
RID = {key: "uygulama:notlar:" + key for key in (WEB, PEER, RAW)}
UNITS = ("konsol-notlar.network", "konsol-notlar_web.container")


def address(ad="notlar", port=None, internet=""):
    return {"tur": "adres", "ad": ad, "tailscale_portu": port, "internet": internet}


def raw(scope="kapali", port=7000):
    return {"tur": "ham", "kapsam": scope, "port": port}


class FakeContainers:
    """The container worker's side of a row change, as master_container_worker.Manager offers it to the settings
    worker: row_files, row_change (writes the rows and a pool port, a unit file when the publications change),
    row_restore. fail: the step that raises ("before", "after", "restore")."""

    def __init__(self, env):
        self.env, self.calls, self.fail = env, [], None

    def unit(self, name):
        return Path(self.env["KONTEYNER_BIRIM_DIR"]) / name

    def row_files(self, app):
        folder = apps.Records(self.env).dir(app)
        return [str(folder / apps.ROWS_FILE), str(folder / "yerler.json")] + [str(self.unit(n)) for n in UNITS]

    def row_change(self, app, key, row):
        self.calls.append(("row_change", app, key, copy.deepcopy(row)))
        if self.fail == "before":
            raise apps.AppError(409, "Erişim satırları çakışıyor.")
        records = apps.Records(self.env)
        record = records.load(app)
        rows = dict(record["rows"], **{key: row})
        places = dict(record["places"], ports=apps.allocate(self.env, app, apps.address_keys(rows), record["places"]["ports"],
                                                            records, bind=lambda port: True))
        records.write(app, rows=rows, places=places)
        change = pubs.publications(key, record["rows"][key]) != pubs.publications(key, row)
        if change:
            settings.atomic(self.unit("konsol-notlar_web.container"), "[Container]\n# %s\n" % json.dumps(row, sort_keys=True))
        if self.fail == "after":
            raise apps.AppError(502, "web 300 saniyede başlamadı ya da sağlık denetimini geçmedi.")
        restarted = ["konsol-notlar_web.service"] if change else []
        return {"uygulama": app, "anahtar": key, "birimler": ["konsol-notlar_web.container"] if change else [],
                "yeniden_baslatilan": restarted}

    def row_restore(self, app, restarted=None):
        self.calls.append(("row_restore", app, restarted))
        if self.fail == "restore":
            raise apps.AppError(502, "web yeniden başlamadı.")
        return list(restarted or [])


class AccessFixture(unittest.TestCase):
    confirm = fixtures.HttpsSettingsTests.confirm
    commit = fixtures.HttpsSettingsTests.commit

    def setUp(self):
        fixtures.HttpsSettingsTests.setUp(self)
        values = app_fixtures.env(self.root)
        for key in ("LOCAL_DOMAIN", "WAN_IPV4", "TAILSCALE_IPV4", "RUNTIME_DIR", "SBIN_DIR", "SERVER_ROOT", "STATE_FILE"):
            values.pop(key)
        self.env.update(values, SSH_PUBLIC_PORT="22", TAILSCALE_UDP_PORT="41641", FILES_PANEL_PORT="61009",
                        WG_NETWORKS_FILE=str(self.root / "wg/networks"), WG_STOPPED_FILE=str(self.root / "wg/stopped"))
        (self.root / "wg").mkdir()
        self.state.write_text("".join(k + "=" + v + "\n" for k, v in self.env.items()))
        self.m = settings.Manager(self.state)
        self.s = shares.Manager(self.state)
        self.s.env.update(self.env)
        # WebDAV over HTTPS: the folders' plaintext mode is closed, so an application may take an internet name.
        self.commit(fixtures.HttpsSettingsTests.payload(self))
        self.record = app_fixtures.record(self.env, text=TEXT, given=ANSWERS)
        app_fixtures.record(self.env, text=app_fixtures.SIMPLE, given=app_fixtures.SIMPLE_ANSWERS, app="sayac",
                            ports={"app:9000/tcp": 62101})
        Path(self.env["KONTEYNER_BIRIM_DIR"]).mkdir(parents=True, exist_ok=True)
        for name in UNITS:
            settings.atomic(Path(self.env["KONTEYNER_BIRIM_DIR"]) / name, "[Unit]\n# %s\n" % name)
        self.containers = FakeContainers(self.env)
        patcher = patch.object(settings.Manager, "container_manager", return_value=self.containers)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.listening = ""

    def command(self, argv, **kwargs):
        if argv[:1] == ["ss"]:
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, self.listening, "")
        return fixtures.HttpsSettingsTests.command(self, argv, **kwargs)

    def request(self, key, row, consent=None, app="notlar"):
        item = {"uygulama": app, "anahtar": key, "satir": row}
        if consent is not None:
            item["internet_onayi"] = consent
        return {"revision": self.m.revision(), "erisim": item}

    def rows(self, app="notlar"):
        return apps.Records(self.env).load(app)["rows"]

    def set_row(self, key, row, app="notlar"):
        """Writes a row directly (a stored state to start from), with its pool port."""
        records = apps.Records(self.env)
        record = records.load(app)
        rows = dict(record["rows"], **{key: row})
        records.write(app, rows=rows, places=dict(record["places"], ports=apps.allocate(
            self.env, app, apps.address_keys(rows), record["places"]["ports"], records, bind=lambda port: True)))

    def site(self, name):
        path = self.root / "sites" / name
        return path.read_text() if path.exists() else None

    def refused(self, request, text):
        with self.assertRaises(settings.SettingsError) as err:
            self.m.plan(request)
        self.assertIn(text, str(err.exception))
        return err.exception


class SectionTests(AccessFixture):
    def test_the_request_names_an_application_and_one_of_its_ports(self):
        for item, text in (({"uygulama": "notlar", "anahtar": RAW}, "alanları geçersiz"),
                           ({"uygulama": "notlar", "anahtar": RAW, "satir": raw("tailscale"), "fazla": 1}, "alanları geçersiz"),
                           ({"uygulama": "Not Lar", "anahtar": RAW, "satir": raw("tailscale")}, "Uygulama adı geçersiz"),
                           ({"uygulama": "yok", "anahtar": RAW, "satir": raw("tailscale")}, "Uygulama bulunamadı"),
                           ({"uygulama": "notlar", "anahtar": "web:9/tcp", "satir": raw("tailscale")}, "böyle bir portu yok"),
                           ({"uygulama": "notlar", "anahtar": PEER, "satir": address("notlar2")}, "UDP portu yalnız doğrudan port"),
                           ({"uygulama": "notlar", "anahtar": RAW, "satir": raw("acik")}, "kapsamını"),
                           ({"uygulama": "notlar", "anahtar": RAW, "satir": raw()}, "Değişiklik yok"),
                           ({"uygulama": "notlar", "anahtar": RAW, "satir": raw("tailscale"), "internet_onayi": "evet"},
                            "İnternet onayı")):
            with self.subTest(item=item):
                self.refused({"revision": self.m.revision(), "erisim": item}, text)
        with self.assertRaisesRegex(settings.SettingsError, "ayrı kaydedin"):
            self.m.validate(dict(self.request(RAW, raw("tailscale")), dns=settings.DEFAULT["dns"]))
        with self.assertRaises(settings.SettingsStale):
            self.m.validate(dict(self.request(RAW, raw("tailscale")), revision="eski"))

    def test_a_tailscale_name_must_be_free_everywhere(self):
        (self.root / "dns/modul-baska.conf").write_text("interface-name=baska.ayc,tailscale0/4\n")
        cfg = self.m.config()
        cfg["dns"]["records"] = [{"name": "yazici.ayc", "target": "tailscale", "enabled": True}]
        settings.save_json(self.m.config_path, cfg)
        for name, text in (("panel", "Obhut'undur"), ("paylas", "Obhut'undur"), ("sayac", "sayac.ayc adı zaten kullanılıyor"),
                           ("baska", "baska.ayc adı zaten kullanılıyor"), ("yazici", "yazici.ayc adı zaten kullanılıyor"),
                           ("-x", "Tailscale adı küçük harf")):
            with self.subTest(name=name):
                self.refused(self.request(WEB, address(name)), text)
        # "Adres aç" on a raw TCP port checks the name the same way; a free name passes.
        self.refused(self.request(RAW, address("sayac")), "sayac.ayc adı zaten kullanılıyor")
        self.assertEqual(self.m.plan(self.request(WEB, address("defter")))["degisiklikler"][0]["sonra"], "defter.ayc")
        # The applications' own DNS file is the projection's: a stale line there blocks nothing.
        (self.root / "dns" / apps.DNS_FILE).write_text("interface-name=defter.ayc,tailscale0/4\n")
        self.m.plan(self.request(WEB, address("defter")))

    def test_internet_names_follow_dd252(self):
        self.refused(self.request(WEB, address(internet="dav.example.net")), "Konsol'da ya da WebDAV'da kullanılıyor")
        self.set_row("app:9000/tcp", address("sayac", internet="sayac.example.net"), app="sayac")
        self.refused(self.request(WEB, address(internet="sayac.example.net")), "İnternet adı sayac.example.net iki satırda")
        with patch.object(tls, "check_dns", side_effect=settings.SettingsError("DNS yalnız 8.8.8.8 adresine yönlenmeli.")):
            self.refused(self.request(WEB, address(internet="notlar.example.net")), "DNS yalnız 8.8.8.8")
        self.refused(self.request(WEB, address(internet="https://notlar.example.net")), "Tam internet alan adını")
        with patch.object(pubs, "plain_http_active", return_value=True):
            self.refused(self.request(WEB, address(internet="notlar.example.net")), "şifresiz HTTP ile açık")
        tls.check_dns.reset_mock()
        plan = self.m.plan(self.request(WEB, address(internet="notlar.example.net")))
        tls.check_dns.assert_called_once_with(self.m.e, "notlar.example.net")
        # DD-275: Konsol puts no sign-in in front of an application's internet name; the plan says so.
        self.assertIn({"seviye": "warn", "metin": pubs.APP_GUARD_TEXT}, plan["uyarilar"])
        self.assertNotIn(pubs.APP_GUARD_TEXT, [w["metin"] for w in self.m.plan(self.request(WEB, address(port=6881)))["uyarilar"]])
        # A fixed row may not take an application's internet name either.
        self.set_row(WEB, address(internet="notlar.example.net"))
        with self.assertRaisesRegex(settings.SettingsError, "uygulamanın erişim satırında"):
            self.m.validate(fixtures.HttpsSettingsTests.payload(self, "notlar.example.net"))

    def test_host_ports_are_refused_for_every_conflict_class(self):
        Path(self.env["WG_NETWORKS_FILE"]).write_text("wg0\t61001\tinet\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/64\t1.1.1.1\tev\n")
        self.set_row("app:9000/tcp", address("sayac", port=9100), app="sayac")
        cfg = self.m.config()
        cfg["firewall"] = [{"id": "r1", "name": "Yazıcı", "family": 4, "scope": "tail", "proto": "tcp", "port": 9200,
                            "source": "", "allow": True},
                           {"id": "r2", "name": "Oyun", "family": 4, "scope": "wan", "proto": "tcp", "port": 9400,
                            "source": "", "allow": True}]
        settings.save_json(self.m.config_path, cfg)
        self.listening = ("tcp LISTEN 0 4096 100.64.0.2:9300 0.0.0.0:*\ntcp LISTEN 0 4096 0.0.0.0:9301 0.0.0.0:*\n"
                          "tcp LISTEN 0 4096 [::]:9303 [::]:*\ntcp LISTEN 0 4096 127.0.0.1:9302 0.0.0.0:*\n"
                          "udp UNCONN 0 0 8.8.8.8:9500 0.0.0.0:*\n")
        cases = ((raw("tailscale", 22), "Obhut'un kendi portu"), (raw("tailscale", 41641), "Obhut'un kendi portu"),
                 (raw("tailscale", 443), "Obhut'un kendi portu"), (raw("tailscale", 62105), "yerel port aralığında"),
                 (raw("tailscale", 61001), "bir WireGuard ağının (wg0) portu"), (raw("tailscale", 9100), "iki satırda"),
                 (raw("tailscale", 9200), "güvenlik duvarı kuralı var (Yazıcı)"),
                 (raw("internet", 9400), "güvenlik duvarı kuralı var (Oyun)"),
                 (raw("tailscale", 9300), "dinleyen bir servis var"), (raw("tailscale", 9301), "dinleyen bir servis var"),
                 (raw("tailscale", 9303), "dinleyen bir servis var"))
        for row, text in cases:
            with self.subTest(row=row):
                self.refused(self.request(RAW, row, consent=True), text)
        self.m.plan(self.request(RAW, raw("tailscale", 9302)))  # a loopback listener is another address
        self.m.plan(self.request(RAW, raw("internet", 9200), consent=True))  # the tail rule is another scope
        self.refused(self.request(PEER, raw("internet", 9500), consent=True), "dinleyen bir servis var")
        self.m.plan(self.request(RAW, raw("internet", 9500), consent=True))  # TCP is not the UDP listener
        # K5: Caddy listens on the Tailscale IPv4, TCP.
        for port, text in ((80, "Obhut'un kendi portu"), (9100, "iki satırda"), (9200, "güvenlik duvarı kuralı"),
                           (9300, "dinleyen bir servis var"), (6881, None)):
            with self.subTest(k5=port):
                if text:
                    self.refused(self.request(WEB, address(port=port)), text)
                else:
                    self.m.plan(self.request(WEB, address(port=port)))
        # An unchanged port is the row's own: a scope change of a raw port does not check its old address.
        self.set_row(RAW, raw("tailscale", 9310))
        self.listening = "tcp LISTEN 0 4096 100.64.0.2:9310 0.0.0.0:*\n"
        self.assertEqual(self.m.plan(self.request(RAW, raw("kapali", 9310)))["onay_sn"], 0)
        # Fail closed: the listeners cannot be read.
        with patch.object(settings, "run", side_effect=lambda argv, **kw: subprocess.CompletedProcess(argv, 1, "", "")):
            self.refused(self.request(RAW, raw("tailscale", 9320)), "Dinleyen portlar okunamadı")

    def test_opening_a_raw_port_to_the_internet_needs_the_consent(self):
        plan = self.m.plan(self.request(RAW, raw("internet", 7000)))
        self.assertFalse(plan["uygulanabilir"])
        self.assertIn({"seviye": "warn", "metin": pubs.CONSENT_TEXT}, plan["uyarilar"])
        self.assertIn({"seviye": "bad", "metin": pubs.CONSENT_MISSING}, plan["uyarilar"])
        before = (self.rows(), [c for c in self.calls if c[:1] != ["ss"]])
        with self.assertRaisesRegex(settings.SettingsError, "internet onayı"):
            self.m.apply(self.request(RAW, raw("internet", 7000)))
        self.assertEqual((self.rows(), [c for c in self.calls if c[:1] != ["ss"]]), before, "refused before the timer or any write")
        self.assertFalse(self.m.pending_path.exists())
        plan = self.m.plan(self.request(RAW, raw("internet", 7000), consent=True))
        self.assertTrue(plan["uygulanabilir"])
        self.assertNotIn({"seviye": "bad", "metin": pubs.CONSENT_MISSING}, plan["uyarilar"])
        # Already open to the internet on the same port: closing it needs no consent.
        self.set_row(RAW, raw("internet", 7000))
        self.assertTrue(self.m.plan(self.request(RAW, raw("tailscale", 7000)))["uygulanabilir"])
        self.assertFalse(self.m.plan(self.request(RAW, raw("internet", 7001)))["uygulanabilir"], "another port is a new opening")


class PlanTests(AccessFixture):
    def plan(self, key, row, before=None, consent=True, **kw):
        if before is not None:
            self.set_row(key, before)
        return self.m.plan(self.request(key, row, consent=consent if row.get("kapsam") == "internet" else None), **kw)

    def test_plan_items_and_the_window_of_every_change_kind(self):
        name = "notlar · web"
        cases = (
            (WEB, address(), address("defter"), [("degistir", name + " 8080/tcp · Tailscale adı", "notlar.ayc", "defter.ayc")], 60),
            (WEB, address(), address(port=9000), [("ac", name + " 8080/tcp · Tailscale portu", "kapalı", "TCP 9000")], 60),
            (WEB, address(port=9000), address(), [("kapat", name + " 8080/tcp · Tailscale portu", "TCP 9000", "kapalı")], 0),
            (WEB, address(port=9000), address(port=9001), [("degistir", name + " 8080/tcp · Tailscale portu", "TCP 9000", "TCP 9001")], 60),
            (WEB, address(), address(internet="notlar.example.net"),
             [("ac", name + " 8080/tcp · internet adı", "kapalı", "notlar.example.net")], 60),
            (WEB, address(internet="notlar.example.net"), address(),
             [("kapat", name + " 8080/tcp · internet adı", "notlar.example.net", "kapalı")], 0),
            (WEB, address(internet="notlar.example.net"), address(internet="defter.example.net"),
             [("degistir", name + " 8080/tcp · internet adı", "notlar.example.net", "defter.example.net")], 60),
            (RAW, raw(), raw("tailscale"), [("ac", name + " 7000/tcp · doğrudan port", "Doğrudan port · kapalı", "Doğrudan port · Tailscale TCP 7000")], 60),
            (RAW, raw("tailscale"), raw(), [("kapat", name + " 7000/tcp · doğrudan port", "Doğrudan port · Tailscale TCP 7000", "Doğrudan port · kapalı")], 0),
            (RAW, raw("tailscale"), raw("internet"),
             [("degistir", name + " 7000/tcp · doğrudan port", "Doğrudan port · Tailscale TCP 7000", "Doğrudan port · İnternet TCP 7000")], 60),
            (RAW, raw("internet"), raw("tailscale"),
             [("degistir", name + " 7000/tcp · doğrudan port", "Doğrudan port · İnternet TCP 7000", "Doğrudan port · Tailscale TCP 7000")], 0),
            (RAW, raw("tailscale"), raw("tailscale", 7001),
             [("degistir", name + " 7000/tcp · doğrudan port", "Doğrudan port · Tailscale TCP 7000", "Doğrudan port · Tailscale TCP 7001")], 60),
            (RAW, raw(), raw(port=7005),
             [("degistir", name + " 7000/tcp · doğrudan port", "Doğrudan port · kapalı · port 7000", "Doğrudan port · kapalı · port 7005")], 0),
            (RAW, raw(), address("defter"),
             [("ekle", name + " 7000/tcp · adres", "Doğrudan port · kapalı", "Adres · defter.ayc · internet: kapalı")], 60),
            (WEB, address(), raw(port=8080),
             [("kaldir", name + " 8080/tcp · adres", "Adres · notlar.ayc · internet: kapalı", "Doğrudan port · kapalı")], 0),
            (WEB, address(), raw("tailscale", 8080),
             [("kaldir", name + " 8080/tcp · adres", "Adres · notlar.ayc · internet: kapalı", "Doğrudan port · Tailscale TCP 8080")], 60),
        )
        for key, before, after, items, seconds in cases:
            with self.subTest(before=before, after=after):
                self.set_row(key, before)
                sites, calls = sorted(p.name for p in (self.root / "sites").iterdir()), len(self.calls)
                plan = self.m.plan(self.request(key, after, consent=True if after.get("kapsam") == "internet" else None))
                self.assertEqual([(i["alan"], i["islem"], i["nesne"], i["once"], i["sonra"]) for i in plan["degisiklikler"]],
                                 [("erisim",) + item for item in items])
                self.assertEqual(plan["onay_sn"], seconds)
                self.assertEqual(plan["revizyon"], self.m.revision())
                self.assertEqual(self.rows()[key], before, "a plan writes nothing")
                self.assertEqual(sorted(p.name for p in (self.root / "sites").iterdir()), sites)
                self.assertFalse([c for c in self.calls[calls:] if c[:1] != ["ss"]], "no reload, no restart")
                self.assertEqual(self.containers.calls, [])
                master_api.check(master_api.ref("AyarPlani"), plan)
                self.set_row(key, address() if key == WEB else raw())

    def test_the_effects_and_warnings_say_what_happens(self):
        plan = self.plan(RAW, raw("tailscale"))
        self.assertIn("web servisi (ve ona bağlı servisler) yeniden başlar; birkaç saniye yanıt vermez.", plan["etkiler"])
        self.assertIn("Güvenlik duvarı ve konteyner koruması yeniden kurulur.", plan["etkiler"])
        self.assertNotIn("Caddy yapılandırması yeniden yüklenir.", plan["etkiler"])
        self.assertIn("Doğrudan açılan port güvenlik duvarının kurallarından geçmez", " ".join(w["metin"] for w in plan["uyarilar"]))
        self.assertIn("Uygulandıktan sonra 60 saniye", plan["uyarilar"][-1]["metin"])
        plan = self.plan(WEB, address("defter"))
        self.assertEqual(plan["etkiler"], ["Caddy yapılandırması yeniden yüklenir.", "Yerel adlar (dnsmasq) yeniden başlar."],
                         "a rename restarts nothing")
        self.assertIn("notlar.ayc adı artık yanıt vermez", plan["uyarilar"][0]["metin"])
        plan = self.plan(WEB, address(internet="notlar.example.net"))
        self.assertIn("İnternet adı için HTTPS sertifikası alınır (en çok 1 dakika).", plan["etkiler"])
        plan = self.plan(RAW, address("defter"))
        self.assertIn("web servisi (ve ona bağlı servisler) yeniden başlar; birkaç saniye yanıt vermez.", plan["etkiler"])
        # A stopped application's units are written, not started.
        record = apps.Records(self.env).load("notlar")
        apps.Records(self.env).write("notlar", places=dict(record["places"], stopped=True))
        plan = self.plan(RAW, raw("tailscale", 7002))
        self.assertIn("Uygulama durdurulmuş: web servisinin birimi yeniden yazılır, başlatılmaz.", plan["etkiler"])

    def test_an_opening_cannot_be_applied_from_the_internet_but_a_closing_can(self):
        self.assertFalse(self.plan(RAW, raw("tailscale"), kanal="internet")["uygulanabilir"])
        self.assertTrue(self.plan(RAW, raw(), before=raw("tailscale"), kanal="internet")["uygulanabilir"])


class ApplyTests(AccessFixture):
    def pending_files(self):
        return set(self.m.pending()["files"])

    def test_a_closing_change_commits_at_once(self):
        self.set_row(WEB, address(port=9000, internet="notlar.example.net"))
        self.s.publish()
        self.assertIn("https://notlar.example.net:443", self.site("uygulama-notlar-wan.caddy"))
        result = self.m.apply(self.request(WEB, address(port=9000)))
        self.assertEqual(result, {"pending": None, "committed": True})
        self.assertEqual(self.containers.calls, [("row_change", "notlar", WEB, address(port=9000))])
        self.assertEqual(self.rows()[WEB], address(port=9000))
        self.assertIsNone(self.site("uygulama-notlar-wan.caddy"), "the internet site goes")
        self.assertIn("http://notlar.ayc, http://{$TAILSCALE_IPV4}:9000 {", self.site("uygulama-notlar.caddy"))
        self.assertIn([self.env["SBIN_DIR"] + "/master-firewall"], self.calls)
        self.assertFalse(self.m.pending_path.exists())
        self.assertIn("_transaction", self.m.config())

    def test_an_opening_waits_and_commits_on_confirmation(self):
        result = self.m.apply(self.request(WEB, address(port=9000)))
        pending = result["pending"]
        self.assertEqual((pending["phase"], pending["erisim"]), ("awaiting", RID[WEB]))
        master_api.check(master_api.ref("AyarSonucu"), result)
        snapshot = self.pending_files()
        folder = apps.Records(self.env).dir("notlar")
        self.assertTrue({str(folder / "erisim.json"), str(folder / "yerler.json"),
                         str(self.root / "sites/uygulama-notlar.caddy"), str(self.root / "sites/uygulama-notlar-wan.caddy"),
                         str(self.root / "sites/paylasim-wan.caddy"), str(self.root / "dns" / apps.DNS_FILE)} <= snapshot)
        self.assertTrue(all(name.startswith(str(self.root)) for name in snapshot))
        self.assertIn({"family": 4, "proto": "tcp", "port": 9000, "name": "notlar · Tailscale portu"},
                      settings.tailnet_ports(self.m.e))
        self.confirm(result)
        self.assertFalse(self.m.pending_path.exists())
        self.assertEqual(self.rows()[WEB], address(port=9000))

    def test_the_deadline_and_the_pending_file_of_an_access_change(self):
        with patch.object(settings.time, "monotonic", return_value=1000.0):
            self.m.apply(self.request(RAW, raw("tailscale")))
            pending = self.m.pending()
        self.assertEqual(pending["until"], 1060.0, "awaiting: the 60 s window")
        self.assertEqual(pending["erisim"], {"yeniden_baslatilan": ["konsol-notlar_web.service"]})
        self.assertEqual(pending["changes"]["erisim"]["sonra"], raw("tailscale"))
        self.m.rollback(manual=True)
        seen = {}
        original = settings.save_json

        def save(path, value):
            if Path(path) == self.m.pending_path and value.get("phase") == "applying":
                seen.setdefault("until", value["until"])
            return original(path, value)
        with patch.object(settings.time, "monotonic", return_value=1000.0), patch.object(settings, "save_json", side_effect=save):
            self.m.apply(self.request(RAW, raw("tailscale")))
        self.assertEqual(seen["until"], 1000.0 + settings.ERISIM_SECONDS)
        self.assertGreater(settings.ERISIM_SECONDS, 300 + 60, "the ready wait and the certificate fit")
        self.assertGreater(settings.ERISIM_WORKER_SECONDS, 2 * settings.ERISIM_SECONDS - 1, "an apply at its deadline and its rollback")

    def test_an_unconfirmed_opening_is_rolled_back(self):
        old_units = {n: (Path(self.env["KONTEYNER_BIRIM_DIR"]) / n).read_bytes() for n in UNITS}
        self.m.apply(self.request(RAW, raw("tailscale")))
        self.assertEqual(self.rows()[RAW], raw("tailscale"))
        pending = self.m.pending()
        pending["until"] = 0
        settings.save_json(self.m.pending_path, pending)
        self.m.guard()
        self.assertFalse(self.m.pending_path.exists())
        self.assertEqual(self.rows()[RAW], raw(), "the row is back")
        self.assertEqual({n: (Path(self.env["KONTEYNER_BIRIM_DIR"]) / n).read_bytes() for n in UNITS}, old_units)
        self.assertEqual(self.containers.calls[-1], ("row_restore", "notlar", ["konsol-notlar_web.service"]))

    def test_an_unconfirmed_rename_gives_dnsmasq_the_old_name_again(self):
        self.s.publish()
        names = self.root / "dns" / apps.DNS_FILE
        self.assertIn("interface-name=notlar.ayc,", names.read_text())
        self.m.apply(self.request(WEB, address("defter")))
        self.assertIn("interface-name=defter.ayc,", names.read_text())
        pending = self.m.pending()
        pending["until"] = 0
        settings.save_json(self.m.pending_path, pending)
        self.calls.clear()
        self.m.guard()
        self.assertIn("interface-name=notlar.ayc,", names.read_text())
        self.assertNotIn("defter", names.read_text())
        self.assertIn(["systemctl", "restart", "dnsmasq"], self.calls, "dnsmasq forgets the new name")
        self.assertIn(["systemctl", "reload", "caddy"], self.calls)
        self.assertIn("http://notlar.ayc {", self.site("uygulama-notlar.caddy"))

    def test_a_failed_row_change_restarts_every_service_when_it_wrote(self):
        self.containers.fail = "after"
        with self.assertRaisesRegex(settings.SettingsError, "300 saniyede başlamadı"):
            self.m.apply(self.request(RAW, raw("tailscale")))
        self.assertFalse(self.m.pending_path.exists())
        self.assertEqual(self.rows()[RAW], raw())
        self.assertEqual(self.containers.calls[-1], ("row_restore", "notlar", None), "not known: every service")

    def test_a_row_change_that_wrote_nothing_restarts_nothing(self):
        self.containers.fail = "before"
        with self.assertRaisesRegex(settings.SettingsError, "çakışıyor"):
            self.m.apply(self.request(RAW, raw("tailscale")))
        self.assertEqual([c[0] for c in self.containers.calls], ["row_change"])
        self.assertFalse(self.m.pending_path.exists())

    def test_a_failed_certificate_wait_takes_the_internet_name_back(self):
        with patch.object(tls, "wait_certificate", side_effect=settings.SettingsError("HTTPS sertifikası doğrulanamadı.")):
            with self.assertRaisesRegex(settings.SettingsError, "sertifikası doğrulanamadı"):
                self.m.apply(self.request(WEB, address(internet="notlar.example.net")))
        self.assertEqual(self.rows()[WEB], address())
        self.assertIsNone(self.site("uygulama-notlar-wan.caddy"))
        self.assertEqual(self.containers.calls[-1], ("row_restore", "notlar", []), "only erisim.json changed")
        self.assertEqual(pubs.https_apps_active(self.env), [])

    def test_an_internet_name_without_a_wan_address_fails_fast(self):
        tls.wait_certificate.reset_mock()
        with patch.object(pubs, "wan_ok", return_value=False), \
                self.assertRaisesRegex(settings.SettingsError, "İnternet adı açılamadı"):
            self.m.apply(self.request(WEB, address(internet="notlar.example.net")))
        tls.wait_certificate.assert_not_called()
        self.assertEqual(self.rows()[WEB], address())

    def test_a_failed_rollback_keeps_the_pending_change_for_the_timer(self):
        self.m.apply(self.request(RAW, raw("tailscale")))
        self.containers.fail = "restore"
        with self.assertRaises(settings.SettingsError):
            self.m.rollback(manual=True)
        pending = self.m.pending()
        self.assertEqual((pending["phase"], pending["attempts"]), ("rollback", 1))
        self.assertIn("yeniden başlamadı", pending["error"])
        self.containers.fail = None
        self.m.rollback(manual=True)
        self.assertFalse(self.m.pending_path.exists())
        self.assertEqual(self.rows()[RAW], raw())

    def test_the_revision_covers_every_access_record(self):
        revision = self.m.revision()
        path = apps.Records(self.env).dir("sayac") / apps.ROWS_FILE
        os.utime(path, ns=(1, 1))
        self.assertNotEqual(self.m.revision(), revision)
        with self.assertRaises(settings.SettingsStale):
            self.m.validate({"revision": revision, "erisim": {"uygulama": "notlar", "anahtar": RAW, "satir": raw("tailscale")}})


class ProjectionTests(AccessFixture):
    def test_each_application_gets_its_sites_and_names(self):
        self.set_row(WEB, address(port=9000, internet="notlar.example.net"))
        self.set_row(RAW, raw("tailscale"))
        (self.root / "sites/uygulama-eski.caddy").write_text("# stale\n")
        (self.root / "sites/uygulama-eski-wan.caddy").write_text("# stale\n")
        extras = pubs.extra_sites(self.env)
        self.assertEqual(extras["uygulama-notlar.caddy"],
                         "# Uygulama notlar (rebuild phase 4): Tailscale; upstream on this server's loopback.\n"
                         "# uygulama:notlar:web:8080/tcp\n"
                         "http://notlar.ayc, http://{$TAILSCALE_IPV4}:9000 {\n\treverse_proxy 127.0.0.1:62100\n}\n")
        public = extras["uygulama-notlar-wan.caddy"]
        self.assertIn("https://notlar.example.net:443 {\n\tbind 8.8.8.8\n", public)
        self.assertIn("disable_http_challenge", public)
        self.assertIn("\treverse_proxy 127.0.0.1:62100 {\n\t\theader_up X-Forwarded-For {http.request.remote.host}\n", public)
        self.assertNotIn("konsol", public.replace("# ", ""), "the application's own login is the guard")
        self.assertIn("http://sayac.ayc {\n\treverse_proxy 127.0.0.1:62101\n}", extras["uygulama-sayac.caddy"])
        self.assertEqual(extras["uygulama-sayac-wan.caddy"], "")
        self.assertEqual((extras["uygulama-eski.caddy"], extras["uygulama-eski-wan.caddy"]), ("", ""))
        self.assertNotIn("7000", extras["uygulama-notlar.caddy"], "a raw port is the guard's, never Caddy's")
        self.assertEqual(pubs.dns_text(self.env).splitlines()[1:],
                         ["interface-name=notlar.ayc,tailscale0/4", "interface-name=sayac.ayc,tailscale0/4"])
        # The publisher writes them, checks dnsmasq and restarts it because the names changed.
        self.calls.clear()
        self.s.publish()
        self.assertEqual(self.site("uygulama-notlar.caddy"), extras["uygulama-notlar.caddy"])
        self.assertFalse((self.root / "sites/uygulama-eski.caddy").exists())
        self.assertEqual((self.root / "dns" / apps.DNS_FILE).read_text(), pubs.dns_text(self.env))
        self.assertIn(["systemctl", "restart", "dnsmasq"], self.calls)
        self.assertIn(["dnsmasq", "--test", "--conf-dir=" + self.env["DNSMASQ_CONF_DIR"]], self.calls)
        self.calls.clear()
        self.s.publish()
        self.assertEqual(self.calls, [], "nothing changed: no reload")
        # An application with no address left keeps no file and no name.
        self.set_row("app:9000/tcp", raw(port=9000), app="sayac")
        self.set_row(WEB, raw(port=8080))
        self.s.publish()
        self.assertIsNone(self.site("uygulama-notlar.caddy"))
        self.assertIsNone(self.site("uygulama-sayac.caddy"))
        self.assertFalse((self.root / "dns" / apps.DNS_FILE).exists())

    def test_a_failed_name_restart_puts_every_file_back(self):
        self.s.publish()
        before = self.site("uygulama-notlar.caddy"), (self.root / "dns" / apps.DNS_FILE).read_text()
        self.set_row(WEB, address("defter"))
        self.fail_once = "restart dnsmasq"
        with self.assertRaisesRegex(shares.ShareError, r"yerel adlar \(dnsmasq\) yeniden başlatılamadı"):
            self.s.publish()
        self.assertEqual((self.site("uygulama-notlar.caddy"), (self.root / "dns" / apps.DNS_FILE).read_text()), before)

    def test_application_internet_names_open_443_and_close_plaintext_webdav(self):
        self.assertFalse(pubs.https_apps_enabled(self.env))
        self.set_row(WEB, address(internet="notlar.example.net"))
        self.assertTrue(pubs.https_apps_enabled(self.env))
        self.assertEqual(pubs.https_apps_active(self.env), ["notlar"])
        with patch.object(pubs, "wan_ok", return_value=False):
            self.assertEqual(pubs.https_apps_active(self.env), [])
        # WebDAV in plaintext mode: its internet connection stays closed while an HTTPS name is on.
        cfg = self.m.config()
        cfg.pop("web")
        settings.save_json(self.m.config_path, cfg)
        info = self.s.wan_info()
        self.assertFalse(info["available"])
        self.assertIn("bir uygulamanın internet adı açıkken", info["reason"])
        row = {r["service"]: r for r in pubs.status(self.env)}["paylasim"]
        self.assertIn("bir uygulamanın internet adı açıkken", row["message"])

    def test_status_rows_name_each_address_and_its_certificate(self):
        self.set_row(WEB, address(internet="notlar.example.net"))
        with patch.object(tls, "certificate", return_value=1_900_000_000):
            rows = {r["service"]: r for r in pubs.status(self.env)}
        row = rows[RID[WEB]]
        self.assertEqual((row["status"], row["expires"], row["domain"], row["local"], row["uygulama"]),
                         ("ready", 1_900_000_000, "notlar.example.net", "notlar.ayc", "notlar"))
        self.assertEqual(rows["uygulama:sayac:app:9000/tcp"]["status"], "disabled")
        self.assertNotIn(RID[RAW], rows, "a raw port has no Caddy publication")

    def test_an_unreadable_record_stops_the_projection_and_keeps_its_files(self):
        self.s.publish()
        before = sorted(p.name for p in (self.root / "sites").iterdir())
        (apps.Records(self.env).dir("sayac") / apps.ROWS_FILE).write_text("{}")
        os.chmod(apps.Records(self.env).dir("sayac") / apps.ROWS_FILE, 0o600)
        with self.assertRaises(settings.SettingsError):
            pubs.extra_sites(self.env)
        with self.assertRaisesRegex(shares.ShareError, "Caddy yayın kaydı uygulanamadı: Uygulamanın erişim kaydı geçersiz"):
            self.s.publish()
        self.assertEqual(sorted(p.name for p in (self.root / "sites").iterdir()), before)
        with self.assertRaises(settings.SettingsError):
            settings.tailnet_ports(self.m.e)
        self.assertEqual([r["service"] for r in pubs.status(self.env)], ["panel", "paylasim"])

    def test_the_local_domain_rename_covers_the_applications_files(self):
        self.set_row(WEB, address(port=9000))
        self.s.publish()
        with patch.object(self.m, "domain_reload"), patch.object(self.m, "pending", return_value={"files_active": False}):
            self.m.domain_apply(dict(self.m.config(), domain="ev"))
        self.assertIn("http://notlar.ev, http://{$TAILSCALE_IPV4}:9000 {", self.site("uygulama-notlar.caddy"))
        self.assertIn("interface-name=notlar.ev,tailscale0/4", (self.root / "dns" / apps.DNS_FILE).read_text())
        self.assertIn("http://notlar.ev, http://{$TAILSCALE_IPV4}:9000 {", pubs.extra_sites(self.m.e)["uygulama-notlar.caddy"])


class FirewallAndNamesTests(AccessFixture):
    def test_tailnet_ports_gain_each_tailscale_port_only(self):
        self.set_row(WEB, address(port=9000))
        self.set_row(RAW, raw("tailscale", 7000))
        ports = settings.tailnet_ports(self.m.e)
        self.assertIn({"family": 4, "proto": "tcp", "port": 9000, "name": "notlar · Tailscale portu"}, ports)
        self.assertFalse([p for p in ports if p["port"] == 7000], "a raw port is FORWARD traffic, the guard's")

    def test_operator_rules_on_an_application_port_are_refused(self):
        self.set_row(WEB, address(port=9000))
        self.set_row(RAW, raw("tailscale", 7000))
        self.set_row(PEER, raw("internet", 6881))

        def rule(scope, proto, port, family=4):
            return {"id": "r%d" % port, "name": "Kural", "family": family, "scope": scope, "proto": proto, "port": port,
                    "source": "", "allow": True}
        for item in (rule("tail", "tcp", 7000), rule("tail", "tcp", 9000), rule("wan", "udp", 6881), rule("tail", "tcp", 7000, 6)):
            with self.subTest(rule=item), self.assertRaises(settings.SettingsError) as err:
                self.m.validate({"revision": self.m.revision(), "firewall": [item]})
            self.assertEqual(str(err.exception), pubs.RULE_HELD)
        self.m.validate({"revision": self.m.revision(), "firewall": [rule("wan", "tcp", 7000), rule("tail", "udp", 6881)]})

    def test_the_firewall_view_shows_application_ports_fixed_with_their_row(self):
        self.set_row(WEB, address(port=9000))
        self.set_row(RAW, raw("tailscale", 7000))
        self.set_row(PEER, raw("internet", 6881))
        instance = panel.Panel(types.SimpleNamespace(state=str(self.state)))
        with patch.object(instance, "ports", return_value=[]):
            rows = instance.settings_ports(self.env, [], listeners=[])
        fixed = sorted((r["scope"], r["proto"], r["port"], r["row"]) for r in rows if r.get("fixed"))
        self.assertEqual(fixed, [("tail", "tcp", 7000, RID[RAW]), ("tail", "tcp", 9000, RID[WEB]), ("wan", "udp", 6881, RID[PEER])])
        self.assertEqual(len([r for r in rows if r["port"] == 9000 and r["scope"] == "tail"]), 1, "K5 once, as its row")
        view = {"firewall": {"ok": True, "check": "", "networks": [], "ports": rows, "listeners": [], "rules": {}},
                "manage": {"revision": "r", "config": {"firewall": []}}}
        with patch.object(instance, "settings", return_value=view):
            answer = instance.guvenlik_duvari()
        master_api.check(master_api.ref("GuvenlikDuvari"), answer)
        row = next(r for r in answer["portlar"] if r["port"] == 6881)
        self.assertEqual((row["sabit"], row["satir"], row["kapsam"], row["ad"]),
                         (True, RID[PEER], "wan", "notlar · web 6881/udp · doğrudan port"))

    def test_managed_names_are_read_only_in_local_names(self):
        Path(self.env["DNSMASQ_CONF_FILE"]).write_text("local=/ayc/\ninterface-name=panel.ayc,tailscale0/4\n")
        self.s.publish()
        dns = copy.deepcopy(settings.DEFAULT["dns"])
        # Rebuild phase 6: no managed name is switched in Yerel adlar; the DNS object has no "disabled" key.
        with self.assertRaisesRegex(settings.SettingsError, "^DNS biçimi geçersiz.$"):
            self.m.validate({"revision": self.m.revision(), "dns": dict(dns, disabled=["notlar.ayc"])})
        with self.assertRaisesRegex(settings.SettingsError, "zaten tanımlı"):
            self.m.validate({"revision": self.m.revision(), "dns": dict(dns, records=[
                {"name": "sayac.ayc", "target": "tailscale", "enabled": True}])})
        (self.root / "dns" / "modul-paylasim.conf").write_text("interface-name=paylas.ayc,tailscale0/4\n")
        # The DNS tab's projection leaves the managed names' files alone (the applications' and WebDAV's).
        paths = [self.root / "dns" / apps.DNS_FILE, self.root / "dns" / "modul-paylasim.conf"]
        before = [path.read_text() for path in paths]
        self.m.project_dns(self.m.config())
        self.assertEqual([path.read_text() for path in paths], before)
        instance = panel.Panel(types.SimpleNamespace(state=str(self.state)))
        answer = instance.adlar()
        master_api.check(master_api.ref("Adlar"), answer)
        names = {n["ad"]: n for n in answer["adlar"]}
        self.assertEqual((names["notlar.ayc"]["satir"], names["notlar.ayc"]["kaynak"]), (RID[WEB], "uygulama"))
        self.assertEqual(names["panel.ayc"]["satir"], "panel")
        self.assertEqual((names["paylas.ayc"]["satir"], names["paylas.ayc"]["kaynak"]), (pubs.BUILTIN_ID, "paylasim"))
        self.assertEqual(sum(n["ad"] == "paylas.ayc" for n in answer["adlar"]), 1, "listed once, from its own file")
        self.assertEqual({k for n in answer["adlar"] for k in n}, {"ad", "aile", "hedef", "kaynak", "satir"}, "no on/off state")

    def test_a_wireguard_network_may_not_take_an_application_port(self):
        self.set_row(RAW, raw("internet", 51820))
        env = dict(self.env, WG_NETWORKS_MAX="9", WG_CONF_DIR=str(self.root / "wg"), WG_ADDR_BASE4="10.8")
        with self.assertRaises(master_wireguard.WireGuardError) as err:
            master_wireguard.new_network(env, {"port": 51820, "dns": "1.1.1.1"}, [])
        self.assertIn(RID[RAW], str(err.exception))
        self.set_row(RAW, raw("kapali", 51820))
        self.assertEqual(master_wireguard.new_network(env, {"port": 51820, "dns": "1.1.1.1"}, [])[0], "wg0")


class AuditAndShapeTests(AccessFixture):
    def test_the_audit_detail_names_the_row_and_what_it_becomes(self):
        item = {"uygulama": "notlar", "anahtar": RAW, "satir": raw("tailscale", 7001)}
        self.assertEqual(settings.audit_detail(item), "erisim %s ham tailscale 7001" % RID[RAW])
        self.assertEqual(settings.audit_detail({"uygulama": "notlar", "anahtar": WEB, "satir": address(port=9000)}),
                         "erisim %s adres notlar tailscale-portu 9000 internet kapali" % RID[WEB])
        self.assertEqual(settings.audit_detail(dict(item, satir={"tur": "ham", "kapsam": "x; rm", "port": 1})), "erisim")
        self.assertEqual(settings.audit_detail(dict(item, uygulama="a b")), "erisim")
        self.assertEqual(settings.audit_detail(RID[RAW]), "erisim " + RID[RAW])
        self.assertEqual(settings.audit_detail("uygulama:x y:z"), "ayarlar")

    def test_the_route_takes_only_the_real_request_shapes(self):
        shape = master_api.ref("AyarIstegi")
        for good in ({"revision": "r", "firewall": []}, {"revision": "r", "dns": settings.DEFAULT["dns"]},
                     {"revision": "r", "firewall": [], "dns": settings.DEFAULT["dns"]}, {"revision": "r", "domain": "ev"},
                     {"revision": "r", "web": {"service": "panel", "tail": True, "enabled": True, "domain": "k.example.net",
                                               "confirm": "onayla"}},
                     {"revision": "r", "erisim": {"uygulama": "notlar", "anahtar": RAW, "satir": raw("internet"),
                                                  "internet_onayi": True}},
                     {"revision": "r", "wireguard": {"eylem": "baslat"}}):
            with self.subTest(good=good):
                master_api.check(shape, good)
        for bad in ({"revision": "r", "https": {"domain": "dav.example.net"}},
                    {"revision": "r", "web": {"service": "elle-notlar", "tail": True, "enabled": False, "domain": ""}},
                    {"revision": "r", "web": {"service": "panel", "tail": True, "enabled": False, "domain": "", "sil": True}},
                    {"revision": "r", "erisim": {"uygulama": "notlar", "anahtar": RAW, "satir": raw()}, "dns": settings.DEFAULT["dns"]},
                    {"revision": "r", "erisim": {"uygulama": "notlar", "anahtar": RAW, "satir": {"tur": "ham", "kapsam": "acik", "port": 1}}},
                    {"revision": "r", "domain": "ev", "firewall": []}, {"firewall": []}):
            with self.subTest(bad=bad), self.assertRaises(master_api.SchemaError):
                master_api.check(shape, bad)

    def test_the_backend_gives_an_access_change_the_longer_worker_limit(self):
        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        instance = panel.Panel(types.SimpleNamespace(state=str(self.state)))
        Handler.panel = instance
        _server, sock = test_resources.start_unix(self, Handler)
        headers = {"X-Konsol": "1", "Content-Type": "application/json", "Host": "panel.ayc"}
        body = self.request(RAW, raw("tailscale"))
        with patch.object(instance, "settings_run", return_value=(200, {"pending": None, "committed": True})) as worker, \
                patch.object(instance, "pending", return_value={"bekleyen": None}):
            code, _, _ = test_resources.unix_get(sock, "/api/konsol/ayarlar/uygula", headers, "POST", json.dumps(body))
            self.assertEqual(code, 200)
            # The worker gets the channel Caddy named (here the host itself), never the body's.
            worker.assert_called_once_with("apply", dict(body, kanal="yerel"), seconds=settings.ERISIM_WORKER_SECONDS)
        with patch.object(instance, "settings_run", return_value=(200, {"ok": True})) as worker, \
                patch.object(instance, "pending", return_value={"bekleyen": {"id": "abc", "erisim": RID[RAW]}}):
            test_resources.unix_get(sock, "/api/konsol/ayarlar/geri-al", headers, "POST", json.dumps({"id": "abc"}))
            test_resources.unix_get(sock, "/api/konsol/ayarlar/onayla", headers, "POST", json.dumps({"id": "abc"}))
        self.assertEqual([c.kwargs["seconds"] for c in worker.call_args_list],
                         [settings.ERISIM_WORKER_SECONDS, settings.WORKER_SECONDS], "a confirmation restarts nothing")
        with patch.object(panel.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, '{"ok": true}', "")) as run:
            instance.run_worker(["true"], {}, "x", seconds=settings.ERISIM_WORKER_SECONDS)
        self.assertIn("--property=RuntimeMaxSec=%d" % settings.ERISIM_WORKER_SECONDS, run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs["timeout"], settings.ERISIM_WORKER_SECONDS + 5)

    def test_removed_routes_answer_nothing(self):
        for method, path in (("GET", "/api/konsol/yayinlar"), ("POST", "/api/konsol/yayinlar/plan")):
            self.assertIsNone(master_api.find(method, path))
        self.assertNotIn("YayinSatiri", master_api.SCHEMAS)
        self.assertNotIn("elle", master_api.SCHEMAS["Hizmet"]["properties"]["tur"]["enum"])
        self.assertEqual(master_api.SCHEMAS["Uyari"]["properties"]["duzelt"]["anyOf"][0]["properties"]["bolum"]["enum"],
                         ["adresler", "uygulama"], "DD-288: no Tailscale tab to lead to")


if __name__ == "__main__":
    unittest.main()
