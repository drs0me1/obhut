"""DD-259: the Erişim read model (who reaches which service, from where) and its route.

master_erisim.build() is fed the shapes the backend's own sources return (documentation addresses
only); every result is checked against master_api's Erisim schema. The route test runs the real
handler on a temporary Unix socket."""
import copy
import datetime
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

import test_resources
from test_overview import Fixture

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_api  # noqa: E402
import master_erisim  # noqa: E402

panel = test_resources.panel
NOW = 1767225600  # 2026-01-01
CLOSED = {"durum": "kapali", "adresler": [], "not": "", "uyari": ""}
ENV = {"LOCAL_DOMAIN": "ev", "TAILSCALE_IPV4": "100.64.0.2", "TAILSCALE_IPV6": "fd7a:115c:a1e0::2",
       "WAN_IPV4": "203.0.113.10", "WAN_IPV6": "2001:db8::10", "SSH_PUBLIC_PORT": "22", "DNS_PORT": "53"}


def publication(service, name, local, **extra):
    row = {"tail": True, "enabled": False, "domain": "", "service": service, "name": name, "local": local + ".ev",
           "installed": True, "running": True, "expires": None, "status": "disabled", "message": "İnternet yayını kapalı."}
    row.update(extra)
    return row


def port(name, number, proto, scope, families=(4, 6)):
    return [{"name": name, "family": f, "proto": proto, "port": number, "scope": scope, "baseline": True} for f in families]


ROW_WEB = "uygulama:notlar:web:8080/tcp"
ROW_PEER = "uygulama:notlar:web:6881/udp"
ROW_DB = "uygulama:notlar:db:5432/tcp"
# master_applications.access_rows of one application: an address with a Tailscale port and an internet name, a raw
# UDP port open on Tailscale and a closed raw port (rebuild phase 4).
ROWS = [
    {"id": ROW_WEB, "uygulama": "notlar", "anahtar": "web:8080/tcp", "servis": "web", "port": 8080, "protokol": "tcp",
     "yerel_port": 62100, "satir": {"tur": "adres", "ad": "notlar", "tailscale_portu": 8080, "internet": "notlar.example.org"}},
    {"id": ROW_PEER, "uygulama": "notlar", "anahtar": "web:6881/udp", "servis": "web", "port": 6881, "protokol": "udp",
     "yerel_port": None, "satir": {"tur": "ham", "kapsam": "tailscale", "port": 6881}},
    {"id": ROW_DB, "uygulama": "notlar", "anahtar": "db:5432/tcp", "servis": "db", "port": 5432, "protokol": "tcp",
     "yerel_port": None, "satir": {"tur": "ham", "kapsam": "kapali", "port": 5432}},
]
SETTINGS = {
    "firewall": {"ports": port("SSH", 22, "tcp", "wan") + port("Tailscale", 41641, "udp", "wan")
                 + port("WireGuard wg0 · home", 61001, "udp", "wan", (4,))
                 + port("Caddy HTTPS · notlar · WAN", 443, "tcp", "wan", (4,))
                 + port("SSH", 22, "tcp", "tail") + port("dnsmasq — yerel adlar", 53, "udp", "tail")
                 + port("Konsol · dosya arka ucu", 62980, "tcp", "lo")},
    "manage": {
        "revision": "f" * 64,
        "config": {"firewall": []},
        "publications": [
            publication("panel", "Panel", "panel", account=False, message="İnternet yayını kapalı. Tailscale adresi her zaman açık kalır."),
            publication(ROW_WEB, "notlar · web", "notlar", uygulama="notlar", enabled=True, domain="notlar.example.org",
                        status="ready", expires=NOW + 90 * 86400, message="Sertifika doğrulandı."),
            publication("paylasim", "WebDAV", "paylas", enabled=True, status="http"),
        ],
    },
}
SHARES = {
    "host": "http://100.64.0.2:61010", "tail_enabled": True,
    "wan": {"available": True, "mode": "http", "address": "203.0.113.10", "port": 61010, "domain": "", "reason": ""},
    "items": [
        {"id": "a1", "name": "Filmler", "connections": {
            "tailscale": {"enabled": True, "active": True, "url": "http://100.64.0.2:61010/s/a1/"},
            "wan": {"enabled": False, "active": False, "url": "http://203.0.113.10:61010/s/a1/"}}},
        {"id": "b2", "name": "Belgeler", "connections": {
            "tailscale": {"enabled": False, "active": False, "url": "http://100.64.0.2:61010/s/b2/"},
            "wan": {"enabled": False, "active": False, "url": "http://203.0.113.10:61010/s/b2/"}}},
    ],
}
CONTAINERS = {"runtime": {"ok": True, "version": "5.4.2", "error": ""}, "containers": [
    # An application's containers are shown through its access rows; any other container keeps its own row.
    {"name": "notlar_web", "source": "uygulama", "uygulama": "notlar", "state": "running", "live": True, "ports": [
        {"host_ip": "127.0.0.1", "host_port": 62100, "container_port": 8080, "protocol": "tcp", "scope": "local"},
        {"host_ip": "100.64.0.2", "host_port": 6881, "container_port": 6881, "protocol": "udp", "scope": "tailscale"}]},
    {"name": "notlar_db", "source": "uygulama", "uygulama": "notlar", "state": "exited", "live": True, "ports": []},
    {"name": "medya", "source": "external", "uygulama": None, "state": "running", "live": True, "ports": [
        {"host_ip": "127.0.0.1", "host_port": 8094, "container_port": 80, "protocol": "tcp", "scope": "local"}]},
]}
TAILSCALE = {"BackendState": "Running", "Version": "1.90.1-t0f0b1c2d3",
             "Self": {"Online": True, "KeyExpiry": "2026-07-01T00:00:00Z", "DNSName": "sunucu.tail0000.ts.net.",
                      "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"],
                      "AllowedIPs": ["100.64.0.2/32", "fd7a:115c:a1e0::2/128", "0.0.0.0/0", "::/0"]}}
# Panel.wireguard.networks() rows (DD-271).
NETWORKS = [{"iface": "wg0", "port": 61001, "label": "home", "active": True, "server4": "10.8.0.1", "server6": ""}]


class ReadModelTests(unittest.TestCase):
    def build(self, settings=None, shares=SHARES, containers=CONTAINERS, tailscale=TAILSCALE, networks=NETWORKS,
              env=None, errors=(), wg_stopped=False, rows=ROWS):
        result = master_erisim.build(dict(ENV, **(env or {})), copy.deepcopy(settings or SETTINGS), copy.deepcopy(shares),
                                     copy.deepcopy(containers), copy.deepcopy(tailscale), copy.deepcopy(networks),
                                     wg_stopped, NOW, errors, copy.deepcopy(rows))
        master_api.check(master_api.ref("Erisim"), result)
        return result

    @staticmethod
    def row(result, sid):
        return next(r for r in result["hizmetler"] if r["id"] == sid)

    @staticmethod
    def states(row):
        return tuple(row[k]["durum"] for k in ("yerel", "tailscale", "wireguard", "internet"))

    def test_a_typical_server_reads_as_one_matrix(self):
        result = self.build()
        self.assertEqual([r["id"] for r in result["hizmetler"]],
                         ["panel", ROW_WEB, ROW_PEER, ROW_DB, "konteyner:medya", "paylasim", "sistem:ssh", "sistem:dns", "vpn:wg0"],
                         "one row per application port; an application's containers have no row of their own")
        panel_row = self.row(result, "panel")
        self.assertEqual(self.states(panel_row), ("yok", "acik", "kapali", "kapali"))
        self.assertEqual(panel_row["tailscale"]["adresler"], ["panel.ev"])
        self.assertEqual((panel_row["web"], panel_row["satir"]), ({"tail": True, "enabled": False, "domain": ""}, None))
        medya = self.row(result, "konteyner:medya")
        self.assertEqual(self.states(medya), ("acik", "kapali", "kapali", "kapali"))
        self.assertEqual(medya["yerel"]["adresler"], ["127.0.0.1:8094 → 80/tcp"])
        self.assertEqual((medya["uygulama"], medya["calisiyor"], medya["satir"], medya["aciklama"]),
                         (None, True, None, "Konteyner · Konsol dışında yönetiliyor"), "an external container has no page")
        ssh = self.row(result, "sistem:ssh")
        self.assertEqual(self.states(ssh), ("yok", "acik", "kapali", "acik"))
        self.assertEqual(ssh["internet"]["adresler"], ["203.0.113.10:22/tcp"])
        self.assertEqual(self.states(self.row(result, "sistem:dns")), ("yok", "acik", "kapali", "kapali"))
        self.assertEqual(result["uyarilar"], [], "loopback and Tailscale publications are not warnings")
        self.assertEqual(result["hatalar"], [])
        self.assertEqual(result["ozet"]["tailscale"], {"ipv4": "100.64.0.2", "ipv6": "fd7a:115c:a1e0::2", "durum": "bagli",
                                                      "anahtar_bitis": 1782864000, "ad": "sunucu.tail0000.ts.net",
                                                      "surum": "1.90.1", "cikis_dugumu": True})
        self.assertEqual([(p["ad"], p["port"], p["proto"], p["aileler"]) for p in result["ozet"]["internet"]["acik"]],
                         [("SSH", 22, "tcp", [4, 6]), ("Caddy HTTPS · notlar · WAN", 443, "tcp", [4]),
                          ("Tailscale", 41641, "udp", [4, 6]), ("WireGuard wg0 · home", 61001, "udp", [4])])
        # A certificate names the row its name belongs to.
        self.assertEqual(result["ozet"]["sertifikalar"], [{"ad": "notlar.example.org", "hizmet": ROW_WEB,
                                                           "durum": "gecerli", "bitis": NOW + 90 * 86400}])
        self.assertEqual((result["read_at"], result["alan"], result["revizyon"]), (NOW, "ev", "f" * 64))

    def test_an_address_row_has_its_pool_port_names_and_internet_name(self):
        web = self.row(self.build(), ROW_WEB)
        self.assertEqual(self.states(web), ("acik", "acik", "kapali", "acik"))
        self.assertEqual(web["yerel"]["adresler"], ["127.0.0.1:62100"])
        self.assertEqual(web["tailscale"]["adresler"], ["notlar.ev", "100.64.0.2:8080"])
        self.assertEqual(web["internet"]["adresler"], ["notlar.example.org"])
        self.assertEqual((web["tur"], web["uygulama"], web["servis"], web["anahtar"], web["calisiyor"], web["web"]),
                         ("uygulama", "notlar", "web", "web:8080/tcp", True, None))
        self.assertEqual(web["satir"], ROWS[0]["satir"])
        self.assertEqual((web["ad"], web["aciklama"]), ("notlar · web", "8080/tcp · Adres"))
        self.assertNotIn("ayrinti", web, "a row carries its cells only: the addresses are in them")

    def test_raw_ports_open_only_their_scope(self):
        result = self.build()
        peer, db = self.row(result, ROW_PEER), self.row(result, ROW_DB)
        self.assertEqual(self.states(peer), ("yok", "acik", "kapali", "kapali"), "a raw port is never on loopback")
        self.assertEqual(peer["tailscale"]["adresler"], ["100.64.0.2:6881/udp"])
        self.assertEqual((peer["aciklama"], peer["satir"]), ("6881/udp · Doğrudan port", ROWS[1]["satir"]))
        self.assertEqual(self.states(db), ("yok", "kapali", "kapali", "kapali"))
        self.assertIs(db["calisiyor"], False, "the db service's container is not running")
        rows = copy.deepcopy(ROWS)
        rows[1]["satir"]["kapsam"] = "internet"
        result = self.build(rows=rows)
        peer = self.row(result, ROW_PEER)
        self.assertEqual(self.states(peer), ("yok", "kapali", "kapali", "acik"))
        self.assertEqual((peer["internet"]["adresler"], peer["internet"]["uyari"]),
                         (["203.0.113.10:6881/udp"], "Şifreleme ve giriş uygulamanın kendisinde."))
        self.assertEqual([(w["seviye"], w["hizmet"], w["duzelt"]) for w in result["uyarilar"]],
                         [("warn", ROW_PEER, {"bolum": "adresler", "hedef": ROW_PEER})])
        self.assertIn("6881/udp doğrudan internete açık", result["uyarilar"][0]["metin"])

    def test_without_podman_or_records(self):
        result = self.build(containers=None)
        self.assertIsNone(self.row(result, ROW_WEB)["calisiyor"], "no live state without the container view")
        result = self.build(rows=None, errors=["Erişim satırları çakışıyor: x"])
        self.assertFalse([r for r in result["hizmetler"] if r["tur"] == "uygulama"])
        self.assertEqual(result["hatalar"], ["Erişim satırları çakışıyor: x"])

    def test_webdav_over_plaintext_http_is_a_warning(self):
        shares = copy.deepcopy(SHARES)
        shares["items"][0]["connections"]["wan"].update(enabled=True, active=True)
        result = self.build(shares=shares)
        row = self.row(result, "paylasim")
        self.assertEqual(row["internet"], {"durum": "acik", "adresler": ["http://203.0.113.10:61010"], "not": "",
                                           "uyari": "Şifresiz HTTP"})
        self.assertEqual(row["tailscale"], {"durum": "acik", "adresler": ["paylas.ev", "http://100.64.0.2:61010"],
                                            "not": "", "uyari": ""})
        self.assertEqual((row["aciklama"], row["web"]), ("WebDAV · 2 klasör", {"tail": True, "enabled": True, "domain": ""}))
        self.assertEqual([w["hizmet"] for w in result["uyarilar"]], ["paylasim"])
        self.assertIn("şifresiz", result["uyarilar"][0]["metin"])
        self.assertEqual(result["uyarilar"][0]["duzelt"], {"bolum": "adresler", "hedef": "paylasim"})
        shares["wan"].update(mode="https", domain="dav.example.org", port=443)
        shares["items"][0]["connections"]["wan"]["url"] = "https://dav.example.org/s/a1/"
        result = self.build(shares=shares)
        self.assertEqual(self.row(result, "paylasim")["internet"]["adresler"], ["https://dav.example.org"])
        self.assertEqual(result["uyarilar"], [])

    def test_closed_shares_are_closed_cells(self):
        shares = copy.deepcopy(SHARES)
        shares["items"][0]["connections"]["tailscale"]["active"] = False
        shares["wan"] = {"available": False, "mode": "off", "reason": "İnternet paylaşımı kapalı."}
        row = self.row(self.build(shares=shares), "paylasim")
        self.assertEqual((row["tailscale"], row["internet"]), (CLOSED, CLOSED), "a closed cell carries no explanation")
        self.assertTrue(row["calisiyor"], "the share service is part of the base")

    def test_wireguard_devices_reach_no_service(self):
        result = self.build()
        for row in result["hizmetler"]:
            expected = "yok" if row["tur"] == "vpn" else "kapali"
            self.assertEqual(row["wireguard"]["durum"], expected, row["id"])
        vpn = self.row(result, "vpn:wg0")
        self.assertEqual((vpn["ad"], vpn["aciklama"], vpn["internet"]["adresler"], vpn["tailscale"]["adresler"]),
                         ("WireGuard wg0", "home", ["203.0.113.10:61001/udp"], ["61001/udp"]))
        self.assertEqual(result["ozet"]["wireguard"], {"kurulu": True, "durduruldu": False, "aglar": [
            {"arayuz": "wg0", "ad": "home", "etkin": True, "port": 61001}]})
        off = copy.deepcopy(NETWORKS)
        off[0]["active"] = False
        self.assertEqual(self.states(self.row(self.build(networks=off), "vpn:wg0")), ("yok", "kapali", "yok", "kapali"))
        without = self.build(networks=[])
        self.assertTrue(all(r["wireguard"]["durum"] == "yok" for r in without["hizmetler"]))
        self.assertEqual(without["ozet"]["wireguard"], {"kurulu": False, "durduruldu": False, "aglar": []})
        # DD-229: a stopped WireGuard lists no network; the summary says it is stopped.
        stopped = self.build(networks=[], wg_stopped=True)
        self.assertFalse([r for r in stopped["hizmetler"] if r["tur"] == "vpn"])
        self.assertEqual(stopped["ozet"]["wireguard"], {"kurulu": False, "durduruldu": True, "aglar": []})

    def test_an_external_containers_publications_warn_without_a_place(self):
        containers = copy.deepcopy(CONTAINERS)
        containers["containers"][2]["ports"] += [
            {"host_ip": "0.0.0.0", "host_port": 8443, "container_port": 443, "protocol": "tcp", "scope": "public"},
            {"host_ip": "192.168.1.5", "host_port": 9000, "container_port": 9000, "protocol": "tcp", "scope": "other"}]
        result = self.build(containers=containers)
        row = self.row(result, "konteyner:medya")
        self.assertEqual(row["internet"]["adresler"], ["203.0.113.10:8443 → 443/tcp"])
        texts = sorted(w["metin"] for w in result["uyarilar"])
        self.assertEqual(len(texts), 2)
        self.assertIn("192.168.1.5:9000/tcp adresindeki yayın tanınmıyor", texts[0])
        self.assertIn("203.0.113.10:8443 → 443/tcp doğrudan internete açık", texts[1])
        self.assertEqual({(w["hizmet"], w["duzelt"]) for w in result["uyarilar"]}, {("konteyner:medya", None)},
                         "a container of no application has no page to fix it on")

    def test_a_container_without_publications_is_closed_not_unknown(self):
        containers = {"runtime": CONTAINERS["runtime"], "containers": [
            {"name": "gece", "source": "external", "state": "exited", "live": True, "ports": []}]}
        row = self.row(self.build(containers=containers), "konteyner:gece")
        self.assertEqual(self.states(row), ("kapali", "kapali", "kapali", "kapali"))
        self.assertEqual((row["calisiyor"], row["aciklama"]), (False, "Konteyner · Konsol dışında yönetiliyor"))

    def test_publication_errors_become_warnings(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["publications"][0].update(enabled=True, domain="konsol.example.org", status="error",
                                                      message="Konsol hesabı yok; internet yayını kapalı.")
        settings["manage"]["publications"][1].update(status="error", expires=None,
                                                      message="Sertifika alınamadı; adın bu sunucuyu gösterdiğini denetleyin.")
        result = self.build(settings)
        konsol = self.row(result, "panel")["internet"]
        self.assertEqual((konsol["durum"], konsol["adresler"]), ("hata", ["konsol.example.org"]))
        web = self.row(result, ROW_WEB)
        self.assertEqual((web["internet"]["durum"], web["internet"]["adresler"]), ("hata", ["notlar.example.org"]))
        self.assertIn("Sertifika alınamadı", web["internet"]["not"])
        self.assertEqual([(w["hizmet"], w["duzelt"]) for w in result["uyarilar"]],
                         [("panel", {"bolum": "adresler", "hedef": "panel"}), (ROW_WEB, {"bolum": "adresler", "hedef": ROW_WEB})])
        self.assertEqual({c["ad"]: c["durum"] for c in result["ozet"]["sertifikalar"]},
                         {"notlar.example.org": "hazir-degil", "konsol.example.org": "hazir-degil"})
        settings["manage"]["publications"][0].update(status="ready", message="Sertifika doğrulandı.")
        self.assertEqual(self.row(self.build(settings), "panel")["internet"],
                         {"durum": "acik", "adresler": ["konsol.example.org"], "not": "", "uyari": ""}, "an open cell: its address only")

    def test_tailscale_state_and_certificate_expiry(self):
        result = self.build(tailscale={"BackendState": "Stopped", "Self": {"Online": False}})
        self.assertEqual(result["ozet"]["tailscale"]["durum"], "bagli-degil")
        self.assertEqual((result["uyarilar"][0]["seviye"], result["uyarilar"][0]["hizmet"], result["uyarilar"][0]["duzelt"]),
                         ("bad", "", None), "DD-288: no row and no place; Erişim → Genel shows Tailscale's summary")
        self.assertIsNone(self.build(tailscale={"BackendState": "Running", "Self": {"Online": True}})["ozet"]["tailscale"]["cikis_dugumu"])
        self.assertEqual(self.build(tailscale=None)["ozet"]["tailscale"]["durum"], "bilinmiyor")
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["publications"][1]["expires"] = NOW + 5 * 86400 + 60
        warning = self.build(settings)["uyarilar"]
        self.assertEqual([(w["seviye"], w["hizmet"], w["duzelt"]) for w in warning],
                         [("warn", ROW_WEB, {"bolum": "adresler", "hedef": ROW_WEB})])
        self.assertIn("5 gün sonra doluyor", warning[0]["metin"])
        settings["manage"]["publications"][1]["expires"] = NOW - 60
        self.assertEqual([w["seviye"] for w in self.build(settings)["uyarilar"]], ["bad"])

    def test_tailscale_key_expiry_is_a_warning(self):
        """DD-288: the device key's end within 14 days is a warning of its own (it was only on the Tailscale tab)."""
        def key(seconds, state="Running", online=True):
            expiry = datetime.datetime.fromtimestamp(NOW + seconds, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            return self.build(tailscale={"BackendState": state, "Self": {"Online": online, "KeyExpiry": expiry}})["uyarilar"]
        self.assertEqual(key(15 * 86400), [], "more than 14 days left")
        soon = key(5 * 86400 + 60)
        self.assertEqual([(w["seviye"], w["hizmet"], w["duzelt"]) for w in soon], [("warn", "", None)])
        self.assertIn("5 gün sonra doluyor", soon[0]["metin"])
        self.assertIn("bir gün içinde doluyor", key(3600)[0]["metin"])
        gone = key(-60, "Stopped", False)
        self.assertEqual([(w["seviye"], w["metin"].split(";")[0]) for w in gone],
                         [("bad", "Tailscale bağlı değil"), ("bad", "Tailscale cihaz anahtarının süresi doldu")],
                         "not connected first, then the key")
        self.assertEqual(self.build(tailscale={"BackendState": "Running", "Self": {"Online": True}})["uyarilar"], [], "no key end: no warning")

    def test_operator_rules_are_rows_and_open_ports(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["config"]["firewall"] = [
            {"id": "r1", "name": "Oyun", "family": 4, "scope": "wan", "proto": "udp", "port": 27015, "source": "", "allow": True},
            {"id": "r2", "name": "Yazıcı", "family": 4, "scope": "tail", "proto": "tcp", "port": 631, "source": "100.64.0.9", "allow": False}]
        result = self.build(settings)
        game, printer = self.row(result, "kural:r1"), self.row(result, "kural:r2")
        self.assertEqual((game["internet"]["durum"], game["internet"]["adresler"], game["aciklama"]),
                         ("acik", ["27015/udp"], "İzin kuralı · IPv4"))
        self.assertEqual(printer["aciklama"], "Engelleme kuralı · IPv4")
        self.assertEqual((printer["tailscale"]["durum"], printer["tailscale"]["adresler"]), ("kapali", ["631/tcp · yalnız 100.64.0.9"]))
        self.assertEqual(result["ozet"]["internet"]["acik"][-1], {"ad": "Oyun", "port": 27015, "proto": "udp", "aileler": [4], "kaynak": "kural"})

    def test_unreadable_sources_leave_error_lines(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"] = {"error": "Ayar yönetimi okunamadı; kurulumu yenileyin."}
        result = self.build(settings, shares=None, containers={"runtime": {"ok": False, "version": "", "error": "Podman kullanılamıyor: x"}, "containers": []},
                            errors=["Paylaşım kaydı okunamadı."], rows=[])
        self.assertEqual(result["hatalar"], ["Paylaşım kaydı okunamadı.", "Ayar yönetimi okunamadı; kurulumu yenileyin.", "Podman kullanılamıyor: x"])
        self.assertEqual(self.states(self.row(result, "paylasim"))[1], "hata")
        self.assertEqual(self.states(self.row(result, "panel")), ("yok", "acik", "kapali", "kapali"))
        self.assertEqual([r["id"] for r in result["hizmetler"]][:2], ["panel", "paylasim"])
        self.assertEqual(result["revizyon"], "")

    def test_the_schema_refuses_a_wrong_shape(self):
        result = self.build()
        for mutate in (lambda r: r.pop("uyarilar"), lambda r: r.update(fazla=1),
                       lambda r: r["hizmetler"][0]["yerel"].update(durum="belki"),
                       lambda r: r["hizmetler"][0].update(calisiyor="evet"), lambda r: r.update(read_at=True),
                       lambda r: r["hizmetler"][1].update(tur="elle"),
                       lambda r: r["hizmetler"][1]["satir"].update(kapsam="kapali")):
            broken = copy.deepcopy(result)
            mutate(broken)
            with self.assertRaises(master_api.SchemaError):
                master_api.check(master_api.ref("Erisim"), broken)


class ErisimRouteTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)

    def test_the_route_answers_with_the_read_model(self):
        ts = (0, json.dumps(TAILSCALE))
        with patch.object(self.p, "settings", return_value=copy.deepcopy(SETTINGS)), \
             patch.object(self.p.wireguard, "networks", return_value=copy.deepcopy(NETWORKS)), \
             patch.object(self.p, "health_cmd", return_value=ts) as health_cmd:
            status, headers, body = test_resources.unix_get(self.sock, "/api/konsol/erisim", {"X-Konsol": "1"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        answer = json.loads(body)
        master_api.check(master_api.ref("Erisim"), answer)
        health_cmd.assert_called_once_with(["tailscale", "status", "--json", "--peers=false"])
        self.assertEqual(answer["ozet"]["tailscale"]["durum"], "bagli")
        self.assertEqual(answer["ozet"]["wireguard"]["aglar"], [{"arayuz": "wg0", "ad": "home", "etkin": True, "port": 61001}],
                         "DD-271: the networks are WireGuard's own")
        self.assertIn("vpn:wg0", [r["id"] for r in answer["hizmetler"]])
        self.assertEqual(answer["hatalar"], ["Paylaşım kaydı okunamadı."], "the temporary state has no share registry")
        self.assertEqual(answer["alan"], "test")

    def test_the_gates_stay_in_front(self):
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/erisim", {})[0], 403)
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/erisim", {"X-Konsol": "1", "Host": "evil.test"})[0], 403)


if __name__ == "__main__":
    unittest.main()
