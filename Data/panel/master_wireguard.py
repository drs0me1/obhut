#!/usr/bin/env python3
"""WireGuard in Konsol (DD-133, DD-136, DD-137, DD-143, DD-229): a built-in of the base (DD-271).

The root backend answers /api/konsol/wireguard/* through this module; the routes and their shapes are
in master_api's table. Nothing here opens a port or touches the host directly: every change goes
through the base's tool master-wg (same validation, same lock, same live apply), run with the
backend's environment. WireGuard's keys (WG_*) come from state.env like every other base key.

WireGuard is installed with the base and off (K6): with no network it is not set up, and the first
network created in Konsol turns it on. "Stopped" is WG_STOPPED_FILE (master-wg durdur / baslat,
DD-229): the networks are down and the firewall drops their ports, forwarding and NAT.

The backend gives the class four callables: env() → state.env as a dict; run(argv, binary, timeout)
→ (rc, out, message); ports(env) → the port catalogue rows; changed() → drop the backend's settings
view after a change. Errors are WireGuardError(status, message). Python standard library only.
"""
import hashlib
import ipaddress
import os
import re
import threading
import time

IFACE_RE = re.compile(r"^wg[0-9]$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
# DD-137: "Bağlı" = son ACTIVE_WINDOW saniyede cihazdan veri geldi (istemci 21 sn'de bir
# canlı tutma paketi yollar). Sayaçlar SAMPLE_SECONDS'ta bir, sayfa açık olmasa da okunur.
ACTIVE_WINDOW = float(os.environ.get("PANEL_ACTIVE_WINDOW", "45"))
SAMPLE_SECONDS = float(os.environ.get("PANEL_SAMPLE_SECONDS", "10"))
HANDSHAKE_FRESH = 180
CONFIRM_WORD = "onayla"
KEYS = ("SBIN_DIR", "WG_NETWORKS_FILE", "WG_STOPPED_FILE", "WG_NETWORKS_MAX", "WG_CLIENT_DNS_DEFAULT",
        "WG_CLIENT_KEEPALIVE_DEFAULT", "WG_MTU", "WG_PORT_DEFAULT")


class WireGuardError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def num_or(value, default):
    return int(value) if value is not None and str(value).strip().isdigit() else default


def dns_provider(dns):
    tokens = [t.strip() for t in dns.split(",") if t.strip()]
    known = (
        # Aile sürümü Cloudflare'in önekiyle de eşleşir; önce o denenir.
        ("Cloudflare Aile", ("1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003")),
        ("Cloudflare", ("1.1.1.", "1.0.0.", "2606:4700:4700::")),
        ("AdGuard", ("94.140.14.", "94.140.15.", "2a10:50c0::ad")),
        ("Google", ("8.8.8.", "8.8.4.", "2001:4860:4860::")),
        ("Quad9", ("9.9.9.", "149.112.112.", "2620:fe::")),
        ("NextDNS", ("45.90.28.", "45.90.30.", "2a07:a8c0:", "2a07:a8c1:")),
    )
    for name, prefixes in known:
        if tokens and all(t.startswith(prefixes) for t in tokens):
            return name
    return "Özel"


def keys(env):
    """WireGuard's base keys; a missing one means the installer did not finish."""
    missing = [k for k in KEYS if not env.get(k)]
    if missing:
        raise WireGuardError(503, "WireGuard ayarı eksik (%s); kurulumu yeniden çalıştırın." % ", ".join(missing))
    return env


def registered(env):
    """Interfaces in the networks file (WG_NETWORKS_FILE), in file order; [] when it does not exist.
    A line that is not a network's raises ValueError: health and repair report it, they never guess."""
    path = env["WG_NETWORKS_FILE"]
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read(65536)
    except FileNotFoundError:
        return []
    names = []
    for line in text.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 9 or not IFACE_RE.fullmatch(fields[0]) or fields[2] != "inet" or fields[0] in names:
            raise ValueError("WireGuard ağ kaydı")
        names.append(fields[0])
    return names


def stopped(env):
    """DD-229: WireGuard as a whole is stopped (master-wg durdur)."""
    return os.path.lexists(env["WG_STOPPED_FILE"])


class WireGuard:
    def __init__(self, env, run, ports, changed, log=print):
        self.env = env
        self.run_tool = run
        self.ports = ports
        self.changed = changed
        self.log = log
        self.activity = {}
        self.activity_lock = threading.Lock()
        self.halt = threading.Event()

    # -- the sampler (DD-137): the backend starts it once; it watches the peers' counters while
    #    there is a network to watch and WireGuard is not stopped.
    def start(self):
        threading.Thread(target=self.sample_forever, name="wireguard-sampler", daemon=True).start()

    def sample_forever(self):
        while not self.halt.is_set():
            try:
                env = keys(self.env())
                if not stopped(env) and os.path.exists(env["WG_NETWORKS_FILE"]):
                    self.state()
            except Exception as err:  # örnekleme durursa sayfa yine el sıkışmaya düşer
                self.log("panel: wireguard: sayaç okunamadı (%s)" % err)
            self.halt.wait(SAMPLE_SECONDS)

    # -- master-wg
    def run(self, *argv, binary=False, net=None):
        env = keys(self.env())
        cmd = [os.path.join(env["SBIN_DIR"], "master-wg")] + (["--if", net] if net else []) + list(argv)
        return self.run_tool(cmd, binary=binary, timeout=120)

    def works(self):
        return self.run("version")[0] == 0

    def net_rows(self):
        """master-wg nets satırları (peer listesi olmadan); state ve networks() aynı kaynağı okur."""
        rc, out, message = self.run("nets")
        if rc != 0:
            raise WireGuardError(502, message or "ağ listesi okunamadı")
        rows = []
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) != 11 or not IFACE_RE.match(f[0]):
                continue
            rows.append({
                "iface": f[0], "port": num_or(f[1], 0),
                "server4": f[3], "subnet4": f[4], "server6": f[5], "subnet6": f[6],
                "dns": f[7], "label": f[8], "active": f[9] == "1", "count": num_or(f[10], 0),
                "revision": hashlib.sha256("\t".join(f[:9]).encode("utf-8")).hexdigest(),
            })
        return rows

    def networks(self):
        """The networks for Erişim, the firewall view, the port catalogue and listener scopes (no keys).
        A stopped WireGuard has none: its ports, forwarding and NAT are gone (DD-229)."""
        try:
            env = keys(self.env())
            if stopped(env) or not registered(env):
                return []
            rows = self.net_rows()
        except (WireGuardError, OSError, ValueError) as err:
            self.log("panel: wireguard: ağ listesi okunamadı (%s)" % err)
            return []
        return [{k: n[k] for k in ("iface", "port", "label", "active", "server4", "server6")} for n in rows]

    def peers(self, net, seen=None):
        rc, out, message = self.run("info", net=net)
        if rc != 0:
            raise WireGuardError(502, message or "%s peer listesi okunamadı" % net)
        peers = []
        now = time.time()
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) != 11:
                continue
            peer = {
                "name": f[0], "ipv4": f[1], "ipv6": f[2], "handshake": num_or(f[3], 0),
                "rx": num_or(f[4], 0), "tx": num_or(f[5], 0), "profile": f[6] == "var",
                "dns": f[7], "provider": dns_provider(f[7]) if f[7] else "",
                "keepalive": num_or(f[8], 0), "mtu": num_or(f[9], 0), "enabled": f[10] != "0",
            }
            peer["online"], peer["active_at"] = self.observe(net, peer, now, seen)
            peer["online"] = peer["online"] and peer["enabled"]
            peers.append(peer)
        return peers

    def observe(self, net, peer, now, seen):
        """DD-137: cihazdan gelen bayt (rx) son ACTIVE_WINDOW saniyede arttıysa bağlı.

        WireGuard'da "bağlantı" yoktur; el sıkışma yalnız 2 dakikada bir yenilenir, bu
        yüzden kapanan cihaz yalnız ona bakılınca 3 dakika bağlı görünürdü. Yeterince
        izlenmemiş (servis yeni başlamış) bir peer için taze el sıkışmaya bakılır.
        """
        key = (net, peer["name"], peer["ipv4"])
        if seen is not None:
            seen.add(key)
        fresh = peer["handshake"] > 0 and now - peer["handshake"] < HANDSHAKE_FRESH
        with self.activity_lock:
            rec = self.activity.get(key)
            if rec is None or peer["rx"] < rec[0]:
                rec = [peer["rx"], None, now]
                self.activity[key] = rec
            elif peer["rx"] > rec[0]:
                rec[0], rec[1] = peer["rx"], now
            if rec[1] is not None:
                online = now - rec[1] <= ACTIVE_WINDOW
            elif now - rec[2] >= ACTIVE_WINDOW:
                online = False
            else:
                online = fresh
            return online and fresh, (int(rec[1]) if rec[1] is not None else None)

    def state(self):
        """GET /api/konsol/wireguard/state: every network with its peers, the defaults for a new one,
        whether WireGuard is stopped and whether master-wg works at all (kurulu)."""
        env = keys(self.env())
        try:
            networks = self.net_rows()
        except WireGuardError:
            if self.works():
                raise
            networks, installed = [], False
        else:
            installed = True
        seen = set()
        for net in networks:
            net["peers"] = self.peers(net["iface"], seen)
        with self.activity_lock:
            for key in [k for k in self.activity if k not in seen]:
                del self.activity[key]
        # Yeni ağa önerilmeyecek portlar, master-wg net-add'in reddettikleri: temelin port kataloğu (DNS ve
        # HTTP master-wg'deki varsayılanlarıyla) ve kayıtlı ağların portları.
        reserved = {p["port"] for p in self.ports(env) if p.get("port")}
        reserved |= {num_or(env.get("DNS_PORT"), 53), num_or(env.get("CADDY_HTTP_PORT"), 80)}
        reserved |= {n["port"] for n in networks if n["port"]}
        return {
            "kurulu": installed,
            "durduruldu": stopped(env),
            "endpoint": env.get("WAN_IPV4", ""),
            "max": num_or(env["WG_NETWORKS_MAX"], 0) + 1,
            "reserved": sorted(reserved),
            "defaults": {
                "dns": env["WG_CLIENT_DNS_DEFAULT"],
                "keepalive": num_or(env["WG_CLIENT_KEEPALIVE_DEFAULT"], 0),
                "mtu": num_or(env["WG_MTU"], 0),
                # DD-143: ilk ağa önerilen UDP portu; sonrakiler 61020'den sıralanır.
                "port": num_or(env["WG_PORT_DEFAULT"], 0),
            },
            "now": int(time.time()),
            "active_window": int(ACTIVE_WINDOW),
            "networks": networks,
        }

    # -- WireGuard as a whole (DD-229)
    def halt_all(self, audit):
        rc, _, message = self.run("durdur")
        self.changed()
        audit("durdur", "WireGuard", rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "WireGuard durdurulamadı")
        return {"durduruldu": stopped(keys(self.env()))}

    def resume(self, audit):
        rc, _, message = self.run("baslat")
        self.changed()
        audit("baslat", "WireGuard", rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "WireGuard başlatılamadı")
        return {"durduruldu": stopped(keys(self.env()))}

    # -- networks
    @staticmethod
    def confirmed(data):
        if str(data.get("confirm", "")).strip().lower() != CONFIRM_WORD:
            raise WireGuardError(400, "onay için %s yazın" % CONFIRM_WORD)

    def add_network(self, data, audit):
        port, dns, label = data["port"], data["dns"].strip(), data.get("label", "").strip()
        if not 0 < port < 65536 or not dns:
            raise WireGuardError(400, "Port ve DNS gerekli.")
        rc, out, message = self.run("net-add", str(port), dns, label)
        parts = out.strip().split("\t")
        self.changed()  # the firewall and port views list the new network at once
        audit("ag-ekle", parts[0] if rc == 0 else str(port), rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "ağ eklenemedi")
        return {"iface": parts[0], "port": num_or(parts[-1], 0)}

    def remove_network(self, net, data, audit):
        self.confirmed(data)
        rc, out, message = self.run("net-remove", net, "--onay")
        audit("ag-kaldir", net, rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "ağ kaldırılamadı")
        self.changed()
        return {"iface": net, "peers": num_or(out.strip().split("\t")[-1], 0)}

    def switch_network(self, net, data, audit):
        want = "ac" if data["on"] else "kapat"
        rc, out, message = self.run("net", want, net=net)
        # Günlük satırı Konsol'da şablonla okunur: ayrıntı doğrudan cümleye girer.
        audit("ag-durum", "%s %s" % (net, "açıldı" if want == "ac" else "kapatıldı"), rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "ağ durumu değiştirilemedi")
        self.changed()
        return {"iface": net, "active": out.strip().split("\t")[-1] == "1"}

    def reset_network(self, net, data, audit):
        self.confirmed(data)
        rc, out, message = self.run("reset", "--onay", net=net)
        audit("yeniden-uret", net, rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "%s yeniden üretilemedi" % net)
        parts = out.strip().split("\t")
        return {"peers": num_or(parts[0], 0), "profiles": num_or(parts[-1], 0)}

    def network_settings(self, net, data, audit):
        """Default DNS and, when "label" is sent (DD-265), the network's name; the revision guards both."""
        dns, revision, label = data["dns"], data["revision"], data.get("label")
        if "label" in data and (len(label.encode("utf-8")) > 64 or label != label.strip()
                                or any(ord(c) < 32 or ord(c) == 127 for c in label)):
            raise WireGuardError(400, "Ağ adı en çok 64 bayt olabilir; baş/son boşluk ve denetim karakteri içeremez")
        if not dns.strip() or len(dns) > 512 or any(ord(c) < 32 for c in dns) or not re.fullmatch(r"[a-f0-9]{64}", revision):
            raise WireGuardError(400, "Geçerli DNS ve ağ revizyonu gerekli.")
        try:
            addresses = [s.strip() for s in dns.split(",")]
            if not 1 <= len(addresses) <= 8 or any("%" in s for s in addresses):
                raise ValueError("DNS")
            for address in addresses:
                ipaddress.ip_address(address)
        except ValueError:
            raise WireGuardError(400, "DNS için en fazla 8 geçerli IPv4/IPv6 adresi yazın")
        args = ("net-settings", dns, revision) + ((label,) if "label" in data else ())
        rc, _, message = self.run(*args, net=net)
        self.changed()
        audit("ag-ayarlar", net, rc == 0)
        if rc != 0:
            raise WireGuardError(409, message or "Ağ ayarları kaydedilemedi")
        return {"iface": net, "dns": ", ".join(addresses), **({"label": label} if "label" in data else {})}

    # -- devices
    def add_peer(self, net, data, audit):
        name, dns, keepalive, mtu = data["name"], data["dns"].strip(), data["keepalive"], data["mtu"]
        if not NAME_RE.match(name):
            raise WireGuardError(400, "geçersiz peer adı (harf, rakam, . _ -; en çok 32)")
        if not dns or keepalive < 0 or mtu <= 0:
            raise WireGuardError(400, "DNS, keepalive ve MTU gerekli")
        rc, out, message = self.run("add", name, dns, str(keepalive), str(mtu), net=net)
        audit("ekle", "%s/%s" % (net, name), rc == 0)
        if rc != 0:
            raise WireGuardError(400, message or "peer eklenemedi")
        return {"name": name, "ipv4": out.strip().split("\t")[-1]}

    def remove_peer(self, net, name, audit):
        rc, _, message = self.run("remove", name, net=net)
        audit("cikar", "%s/%s" % (net, name), rc == 0)
        return self.done(rc, message)

    def switch_peer(self, net, name, data, audit):
        want = "ac" if data["on"] else "kapat"
        rc, _, message = self.run("peer", name, want, net=net)
        audit("peer-durum", "%s/%s %s" % (net, name, "açıldı" if want == "ac" else "kapatıldı"), rc == 0)
        return self.done(rc, message)

    def peer_keepalive(self, net, name, data, audit):
        keepalive = data["keepalive"]
        if keepalive < 0:
            raise WireGuardError(400, "keepalive saniye olarak gerekli (0 = kapalı)")
        rc, _, message = self.run("keepalive", name, str(keepalive), net=net)
        audit("keepalive", "%s/%s %s" % (net, name, keepalive), rc == 0)
        return self.done(rc, message)

    def peer_dns(self, net, name, data, audit):
        dns = data["dns"].strip()
        if not dns:
            raise WireGuardError(400, "DNS gerekli")
        rc, _, message = self.run("dns", name, dns, net=net)
        audit("dns", "%s/%s" % (net, name), rc == 0)
        return self.done(rc, message)

    @staticmethod
    def done(rc, message):
        if rc != 0:
            raise WireGuardError(400, message or "işlem yapılamadı")
        return {"ok": True}

    # -- a device's secrets: only on an explicit request, never cached, never logged
    def profile(self, net, name, audit):
        rc, out, message = self.run("profile", name, net=net)
        if rc != 0:
            raise WireGuardError(404, message or "profil yok")
        audit("profil", "%s/%s" % (net, name), True)
        return out.encode("utf-8"), "text/plain; charset=utf-8", {"Content-Disposition": 'attachment; filename="%s.conf"' % name}

    def qr(self, net, name, audit):
        rc, out, message = self.run("png", name, binary=True, net=net)
        audit("qr", "%s/%s" % (net, name), rc == 0)
        if rc != 0 or not out.startswith(b"\x89PNG"):
            raise WireGuardError(404, message or "QR üretilemedi")
        return out, "image/png", {"Content-Disposition": 'attachment; filename="%s.png"' % name}
