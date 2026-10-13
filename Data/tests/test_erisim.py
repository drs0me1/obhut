"""DD-259: the Erişim read model (who reaches which service, from where) and its route.

master_erisim.build() is fed the shapes the backend's own sources return (documentation addresses
only); every result is checked against master_api's Erisim schema. The route test runs the real
handler on a temporary Unix socket."""
import copy
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
ENV = {"LOCAL_DOMAIN": "ev", "TAILSCALE_IPV4": "100.64.0.2", "TAILSCALE_IPV6": "fd7a:115c:a1e0::2",
       "WAN_IPV4": "203.0.113.10", "WAN_IPV6": "2001:db8::10", "SSH_PUBLIC_PORT": "22", "DNS_PORT": "53"}


def publication(service, name, local, **extra):
    row = {"tail": True, "enabled": False, "domain": "", "service": service, "name": name, "local": local + ".ev",
           "installed": True, "running": True, "expires": None, "status": "disabled", "message": "İnternet yayını kapalı."}
    row.update(extra)
    return row


def port(name, number, proto, scope, families=(4, 6)):
    return [{"name": name, "family": f, "proto": proto, "port": number, "scope": scope, "baseline": True} for f in families]


SETTINGS = {
    "firewall": {"ports": port("SSH", 22, "tcp", "wan") + port("Tailscale", 41641, "udp", "wan")
                 + port("WireGuard wg0 · home", 61001, "udp", "wan", (4,)) + port("qBittorrent eş portu", 63851, "udp", "wan", (4,))
                 + port("qBittorrent eş portu", 63851, "tcp", "wan", (4,)) + port("Caddy HTTPS · Gezgin · WAN", 443, "tcp", "wan", (4,))
                 + port("SSH", 22, "tcp", "tail") + port("dnsmasq — yerel adlar", 53, "udp", "tail")
                 + port("qBittorrent arayüzü", 62947, "tcp", "lo")},
    "manage": {
        "config": {"firewall": []},
        "publications": [
            publication("panel", "Panel", "panel", account=False, message="İnternet yayını kapalı. Tailscale adresi her zaman açık kalır."),
            publication("torrent", "qBittorrent", "torrent"),
            publication("elle-gezgin", "Gezgin", "gezgin", manual=True, upstream="127.0.0.1:8093", answers=True,
                        enabled=True, domain="gezgin.example.org", status="ready", expires=NOW + 90 * 86400,
                        message="Sertifika doğrulandı."),
            publication("paylasim", "WebDAV", "paylas", enabled=True, status="http", mode="http", wan_active=False),
        ],
    },
}
SHARES = {
    "enabled": True, "running": True, "host": "http://100.64.0.2:61010", "tail_enabled": True,
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
    {"name": "gezgin", "source": "konsol", "module_id": None, "state": "running", "live": True, "ports": [
        {"host_ip": "100.64.0.2", "host_port": 8091, "container_port": 8080, "protocol": "tcp", "scope": "tailscale"},
        {"host_ip": "100.64.0.2", "host_port": 8092, "container_port": 8092, "protocol": "tcp", "scope": "tailscale"},
        {"host_ip": "127.0.0.1", "host_port": 8093, "container_port": 8080, "protocol": "tcp", "scope": "local"}]},
    {"name": "qbittorrent", "source": "appstore", "module_id": "torrent", "state": "running", "live": True, "ports": [
        {"host_ip": "127.0.0.1", "host_port": 62947, "container_port": 62947, "protocol": "tcp", "scope": "local"},
        {"host_ip": "203.0.113.10", "host_port": 63851, "container_port": 63851, "protocol": "tcp", "scope": "public"},
        {"host_ip": "203.0.113.10", "host_port": 63851, "container_port": 63851, "protocol": "udp", "scope": "public"}]},
]}
TAILSCALE = {"BackendState": "Running", "Self": {"Online": True, "KeyExpiry": "2026-07-01T00:00:00Z"}}
NETWORKS = [{"app": "WireGuard", "iface": "wg0", "port": 61001, "label": "home", "active": True,
             "server4": "10.8.0.1", "subnet4": "10.8.0.0/24", "server6": "", "subnet6": ""}]
PACKAGES = {"torrent": {"name": "qBittorrent", "local": "torrent", "upstream": "127.0.0.1:62947", "check": "", "order": 20}}
NAMES = {"torrent": "qBittorrent", "wireguard": "WireGuard"}


class ReadModelTests(unittest.TestCase):
    def build(self, settings=None, shares=SHARES, containers=CONTAINERS, tailscale=TAILSCALE, networks=NETWORKS,
              env=None, errors=()):
        result = master_erisim.build(dict(ENV, **(env or {})), copy.deepcopy(settings or SETTINGS), copy.deepcopy(shares),
                                     copy.deepcopy(containers), copy.deepcopy(tailscale), copy.deepcopy(networks),
                                     copy.deepcopy(PACKAGES), NAMES, NOW, errors)
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
                         ["panel", "paket:torrent", "konteyner:gezgin", "paylasim", "sistem:ssh", "sistem:dns", "vpn:wg0"])
        panel_row = self.row(result, "panel")
        self.assertEqual(self.states(panel_row), ("yok", "acik", "kapali", "kapali"))
        self.assertEqual(panel_row["tailscale"]["adresler"], ["panel.ev"])
        torrent = self.row(result, "paket:torrent")
        self.assertEqual(self.states(torrent), ("acik", "acik", "kapali", "kismen"))
        self.assertEqual(torrent["yerel"]["adresler"], ["127.0.0.1:62947/tcp"], "the package upstream is not listed twice")
        self.assertEqual(torrent["internet"], {"durum": "kismen", "adresler": ["203.0.113.10:63851/tcp+udp"],
                                               "not": "Yalnız qBittorrent eş portu", "uyari": ""})
        self.assertEqual((torrent["uygulama"], torrent["calisiyor"], torrent["yayinlar"]), ("torrent", True, ["torrent"]))
        ssh = self.row(result, "sistem:ssh")
        self.assertEqual(self.states(ssh), ("yok", "acik", "kapali", "acik"))
        self.assertEqual(ssh["internet"]["adresler"], ["203.0.113.10:22/tcp"])
        self.assertEqual(self.states(self.row(result, "sistem:dns")), ("yok", "acik", "kapali", "kapali"))
        self.assertEqual(result["uyarilar"], [], "a package's declared peer port is not a warning")
        self.assertEqual(result["hatalar"], [])
        self.assertEqual(result["ozet"]["tailscale"], {"ipv4": "100.64.0.2", "ipv6": "fd7a:115c:a1e0::2", "durum": "bagli",
                                                      "anahtar_bitis": 1782864000})
        self.assertEqual([(p["ad"], p["port"], p["proto"], p["aileler"]) for p in result["ozet"]["internet"]["acik"]],
                         [("SSH", 22, "tcp", [4, 6]), ("Caddy HTTPS · Gezgin · WAN", 443, "tcp", [4]),
                          ("Tailscale", 41641, "udp", [4, 6]), ("WireGuard wg0 · home", 61001, "udp", [4]),
                          ("qBittorrent eş portu", 63851, "tcp+udp", [4])])
        self.assertEqual(result["ozet"]["sertifikalar"], [{"ad": "gezgin.example.org", "hizmet": "elle-gezgin",
                                                           "durum": "gecerli", "bitis": NOW + 90 * 86400}])
        self.assertEqual((result["read_at"], result["alan"]), (NOW, "ev"))

    def test_a_manual_address_joins_the_container_it_leads_to(self):
        gezgin = self.row(self.build(), "konteyner:gezgin")
        self.assertEqual(self.states(gezgin), ("acik", "acik", "kapali", "acik"))
        self.assertEqual(gezgin["yerel"]["adresler"], ["127.0.0.1:8093 → 8080/tcp"])
        self.assertEqual(gezgin["tailscale"]["adresler"], ["100.64.0.2:8091 → 8080/tcp", "100.64.0.2:8092/tcp", "gezgin.ev"])
        self.assertEqual(gezgin["internet"]["adresler"], ["gezgin.example.org"])
        self.assertEqual((gezgin["yayinlar"], gezgin["uygulama"], gezgin["aciklama"]), (["elle-gezgin"], "gezgin", "Konteyner"))
        details = [(d["baslik"], d["deger"]) for d in gezgin["ayrinti"]]
        self.assertIn(("Caddy", "gezgin.example.org → 127.0.0.1:8093"), details)
        self.assertIn(("DNS", "gezgin.ev → 100.64.0.2"), details)
        self.assertIn(("Sertifika", "01.04.2026 tarihine kadar"), details)

    def test_a_manual_address_without_its_container_is_a_row_and_a_dead_target_warns(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["publications"][2].update(upstream="127.0.0.1:9000", answers=False)
        result = self.build(settings)
        row = self.row(result, "elle:gezgin")
        self.assertEqual(self.states(row), ("hata", "acik", "kapali", "acik"))
        self.assertEqual((row["tur"], row["calisiyor"], row["yerel"]["adresler"]), ("elle", False, ["127.0.0.1:9000"]))
        self.assertEqual(self.row(result, "konteyner:gezgin")["yayinlar"], [])
        self.assertEqual([w["hizmet"] for w in result["uyarilar"]], ["elle:gezgin"])
        self.assertIn("yanıt vermiyor", result["uyarilar"][0]["metin"])

    def test_webdav_over_plaintext_http_is_a_warning(self):
        shares = copy.deepcopy(SHARES)
        shares["items"][0]["connections"]["wan"].update(enabled=True, active=True)
        result = self.build(shares=shares)
        row = self.row(result, "paylasim")
        self.assertEqual(row["internet"], {"durum": "acik", "adresler": ["http://203.0.113.10:61010"], "not": "1 klasör",
                                           "uyari": "Şifresiz HTTP"})
        self.assertEqual(row["tailscale"], {"durum": "acik", "adresler": ["paylas.ev", "http://100.64.0.2:61010"],
                                            "not": "1 klasör", "uyari": ""})
        self.assertEqual(row["aciklama"], "WebDAV · 2 klasör")
        self.assertEqual([w["hizmet"] for w in result["uyarilar"]], ["paylasim"])
        self.assertIn("şifresiz", result["uyarilar"][0]["metin"])
        shares["wan"].update(mode="https", domain="dav.example.org", port=443)
        shares["items"][0]["connections"]["wan"]["url"] = "https://dav.example.org/s/a1/"
        result = self.build(shares=shares)
        self.assertEqual(self.row(result, "paylasim")["internet"]["adresler"], ["https://dav.example.org"])
        self.assertEqual(result["uyarilar"], [])

    def test_closed_shares_say_why(self):
        shares = copy.deepcopy(SHARES)
        shares["items"][0]["connections"]["tailscale"]["active"] = False
        shares["wan"] = {"available": False, "mode": "off", "reason": "İnternet paylaşımı kapalı."}
        row = self.row(self.build(shares=shares), "paylasim")
        self.assertEqual((row["tailscale"]["durum"], row["tailscale"]["not"]), ("kapali", "Tailscale'den paylaşılan klasör yok."))
        self.assertEqual((row["internet"]["durum"], row["internet"]["not"]), ("kapali", "İnternet paylaşımı kapalı."))
        shares["running"] = False
        self.assertEqual(self.row(self.build(shares=shares), "paylasim")["tailscale"]["not"], "WebDAV hizmeti çalışmıyor.")
        shares["running"], shares["tail_enabled"] = True, False
        self.assertIn("Tailscale erişimi kapalı", self.row(self.build(shares=shares), "paylasim")["tailscale"]["not"])

    def test_wireguard_devices_reach_no_service(self):
        result = self.build()
        for row in result["hizmetler"]:
            expected = "yok" if row["tur"] == "vpn" else "kapali"
            self.assertEqual(row["wireguard"]["durum"], expected, row["id"])
        vpn = self.row(result, "vpn:wg0")
        self.assertEqual((vpn["ad"], vpn["aciklama"], vpn["internet"]["adresler"], vpn["tailscale"]["adresler"]),
                         ("WireGuard wg0", "home", ["203.0.113.10:61001/udp"], ["61001/udp"]))
        self.assertEqual(result["ozet"]["wireguard"], {"kurulu": True, "not": master_erisim.VPN_NOTE, "aglar": [
            {"uygulama": "WireGuard", "arayuz": "wg0", "ad": "home", "etkin": True, "port": 61001}]})
        off = copy.deepcopy(NETWORKS)
        off[0]["active"] = False
        self.assertEqual(self.states(self.row(self.build(networks=off), "vpn:wg0")), ("yok", "kapali", "yok", "kapali"))
        without = self.build(networks=[])
        self.assertTrue(all(r["wireguard"]["durum"] == "yok" for r in without["hizmetler"]))
        self.assertEqual(without["ozet"]["wireguard"], {"kurulu": False, "not": "", "aglar": []})

    def test_direct_and_unknown_container_publications_warn(self):
        containers = copy.deepcopy(CONTAINERS)
        containers["containers"][0]["ports"] += [
            {"host_ip": "0.0.0.0", "host_port": 8443, "container_port": 443, "protocol": "tcp", "scope": "public"},
            {"host_ip": "192.168.1.5", "host_port": 9000, "container_port": 9000, "protocol": "tcp", "scope": "other"}]
        result = self.build(containers=containers)
        row = self.row(result, "konteyner:gezgin")
        self.assertEqual(row["internet"]["adresler"], ["203.0.113.10:8443 → 443/tcp", "gezgin.example.org"])
        texts = sorted(w["metin"] for w in result["uyarilar"])
        self.assertEqual(len(texts), 2)
        self.assertIn("192.168.1.5:9000/tcp adresindeki yayın tanınmıyor", texts[0])
        self.assertIn("203.0.113.10:8443 → 443/tcp doğrudan internete açık", texts[1])

    def test_a_container_without_publications_is_closed_not_unknown(self):
        containers = {"runtime": CONTAINERS["runtime"], "containers": [
            {"name": "gece", "source": "external", "module_id": None, "state": "exited", "live": True, "ports": []}]}
        row = self.row(self.build(containers=containers), "konteyner:gece")
        self.assertEqual(self.states(row), ("kapali", "kapali", "kapali", "kapali"))
        self.assertEqual((row["calisiyor"], row["aciklama"]), (False, "Konteyner · Konsol dışında yönetiliyor"))

    def test_publication_errors_become_warnings(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["publications"][0].update(enabled=True, domain="konsol.example.org", status="error",
                                                      message="Konsol hesabı yok; internet yayını kapalı.")
        settings["manage"]["publications"][1].update(enabled=True, domain="torrent.example.org", status="error", running=False,
                                                      message="qBittorrent durdurulmuş; başlatıldığında internet yayını yeniden açılır.")
        result = self.build(settings)
        konsol = self.row(result, "panel")["internet"]
        self.assertEqual((konsol["durum"], konsol["adresler"]), ("hata", ["konsol.example.org"]))
        torrent = self.row(result, "paket:torrent")
        self.assertEqual((torrent["internet"]["durum"], torrent["calisiyor"]), ("hata", False))
        self.assertEqual(torrent["internet"]["adresler"], ["torrent.example.org", "203.0.113.10:63851/tcp+udp"])
        self.assertEqual([w["hizmet"] for w in result["uyarilar"]], ["panel", "paket:torrent"])
        self.assertEqual(result["ozet"]["sertifikalar"][0]["durum"], "gecerli")
        self.assertEqual({c["ad"]: c["durum"] for c in result["ozet"]["sertifikalar"]},
                         {"gezgin.example.org": "gecerli", "konsol.example.org": "hazir-degil", "torrent.example.org": "hazir-degil"})
        settings["manage"]["publications"][0].update(status="ready", message="Sertifika doğrulandı.")
        self.assertEqual(self.row(self.build(settings), "panel")["internet"]["not"], "Konsol hesabıyla giriş ister.")

    def test_tailscale_state_and_certificate_expiry(self):
        result = self.build(tailscale={"BackendState": "Stopped", "Self": {"Online": False}})
        self.assertEqual(result["ozet"]["tailscale"]["durum"], "bagli-degil")
        self.assertEqual((result["uyarilar"][0]["seviye"], result["uyarilar"][0]["hizmet"]), ("bad", "tailscale"))
        self.assertEqual(self.build(tailscale=None)["ozet"]["tailscale"]["durum"], "bilinmiyor")
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["publications"][2]["expires"] = NOW + 5 * 86400 + 60
        warning = self.build(settings)["uyarilar"]
        self.assertEqual([(w["seviye"], w["hizmet"]) for w in warning], [("warn", "elle-gezgin")])
        self.assertIn("5 gün sonra doluyor", warning[0]["metin"])
        settings["manage"]["publications"][2]["expires"] = NOW - 60
        self.assertEqual([w["seviye"] for w in self.build(settings)["uyarilar"]], ["bad"])

    def test_operator_rules_are_rows_and_open_ports(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"]["config"]["firewall"] = [
            {"id": "r1", "name": "Oyun", "family": 4, "scope": "wan", "proto": "udp", "port": 27015, "source": "", "allow": True},
            {"id": "r2", "name": "Yazıcı", "family": 4, "scope": "tail", "proto": "tcp", "port": 631, "source": "100.64.0.9", "allow": False}]
        result = self.build(settings)
        game, printer = self.row(result, "kural:r1"), self.row(result, "kural:r2")
        self.assertEqual((game["internet"]["durum"], game["internet"]["adresler"], game["internet"]["not"]),
                         ("acik", ["27015/udp"], "İzin kuralı"))
        self.assertEqual((printer["tailscale"]["durum"], printer["tailscale"]["adresler"]), ("kapali", ["631/tcp · yalnız 100.64.0.9"]))
        self.assertEqual(result["ozet"]["internet"]["acik"][-1], {"ad": "Oyun", "port": 27015, "proto": "udp", "aileler": [4], "kaynak": "kural"})

    def test_unreadable_sources_leave_error_lines(self):
        settings = copy.deepcopy(SETTINGS)
        settings["manage"] = {"error": "Ayar yönetimi okunamadı; kurulumu yenileyin."}
        result = self.build(settings, shares=None, containers={"runtime": {"ok": False, "version": "", "error": "Podman kullanılamıyor: x"}, "containers": []},
                            errors=["Paylaşım kaydı okunamadı."])
        self.assertEqual(result["hatalar"], ["Paylaşım kaydı okunamadı.", "Ayar yönetimi okunamadı; kurulumu yenileyin.", "Podman kullanılamıyor: x"])
        self.assertEqual(self.states(self.row(result, "paylasim"))[1], "hata")
        self.assertEqual(self.states(self.row(result, "panel")), ("yok", "acik", "kapali", "kapali"))
        self.assertEqual([r["id"] for r in result["hizmetler"]][:2], ["panel", "paylasim"])

    def test_the_schema_refuses_a_wrong_shape(self):
        result = self.build()
        for mutate in (lambda r: r.pop("uyarilar"), lambda r: r.update(fazla=1),
                       lambda r: r["hizmetler"][0]["yerel"].update(durum="belki"),
                       lambda r: r["hizmetler"][0].update(calisiyor="evet"), lambda r: r.update(read_at=True)):
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
             patch.object(self.p, "package_networks", return_value=copy.deepcopy(NETWORKS)), \
             patch.object(self.p, "health_cmd", return_value=ts) as health_cmd:
            status, headers, body = test_resources.unix_get(self.sock, "/api/konsol/erisim", {"X-Konsol": "1"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        answer = json.loads(body)
        master_api.check(master_api.ref("Erisim"), answer)
        health_cmd.assert_called_once_with(["tailscale", "status", "--json", "--peers=false"])
        self.assertEqual(answer["ozet"]["tailscale"]["durum"], "bagli")
        self.assertEqual(answer["hatalar"], ["Paylaşım kaydı okunamadı."], "the temporary state has no share registry")
        self.assertEqual(answer["alan"], "test")

    def test_the_gates_stay_in_front(self):
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/erisim", {})[0], 403)
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/erisim", {"X-Konsol": "1", "Host": "evil.test"})[0], 403)


if __name__ == "__main__":
    unittest.main()
