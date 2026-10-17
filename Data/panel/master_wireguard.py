#!/usr/bin/env python3
"""WireGuard in Konsol (DD-133, DD-136, DD-137, DD-143, DD-229): a built-in of the base (DD-271).

The root backend answers /api/konsol/wireguard/* through this module; the routes and their shapes are
in master_api's table. Nothing here opens a port or touches the host directly: every change goes
through the base's tool master-wg (same validation, same lock, same live apply), run with the
backend's environment. WireGuard's keys (WG_*) come from state.env like every other base key.

DD-275: the actions that change who reaches what (start or stop WireGuard, add, remove, open or close a
network, regenerate its key) are the settings transaction's "wireguard" section (master_settings): this
module checks the request (section) and words its plan (plan_items, plan_notes); the settings worker runs
master-wg in its caller mode. Devices, their DNS and keepalive, a network's DNS and name stay immediate
routes here.

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
# The networks file's columns (DD-136, DD-177): interface, UDP port, the fixed scope "inet", server and
# subnet IPv4, server and subnet IPv6, the default DNS and the name.
FIELDS = ("iface", "port", "scope", "server4", "subnet4", "server6", "subnet6", "dns", "label")

# DD-275: the settings transaction's WireGuard section. Decision 4: turning WireGuard on, adding a network
# and opening one wait for the timed confirmation and are rolled back without it; stopping, closing,
# removing and regenerating commit at once. Removing and regenerating cannot be undone: the typed word.
ACTIONS = ("baslat", "durdur", "ag-ekle", "ag-kaldir", "ag-ac", "ag-kapat", "yeniden-uret")
OPENING = ("baslat", "ag-ekle", "ag-ac")
TYPED = ("ag-kaldir", "yeniden-uret")
NETWORK_ACTIONS = ("ag-kaldir", "ag-ac", "ag-kapat", "yeniden-uret")
SECTION_KEYS = ("SBIN_DIR", "WG_NETWORKS_FILE", "WG_STOPPED_FILE", "WG_NETWORKS_MAX", "WG_CONF_DIR", "WG_ADDR_BASE4")
TYPED_TEXT = "Bu işlem geri alınamaz; uygulamak için %s yazın." % CONFIRM_WORD
STOPPED_TEXT = "WireGuard durduruldu; önce Konsol → Erişim → WireGuard'dan başlatın"
# master-wg's message when it gives none.
FAILED = {"baslat": "WireGuard başlatılamadı.", "durdur": "WireGuard durdurulamadı.", "ag-ekle": "Ağ eklenemedi.",
          "ag-kaldir": "Ağ kaldırılamadı.", "ag-ac": "Ağ açılamadı.", "ag-kapat": "Ağ kapatılamadı.",
          "yeniden-uret": "Ağ yeniden üretilemedi."}


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


def keys(env, names=KEYS):
    """WireGuard's base keys; a missing one means the installer did not finish."""
    missing = [k for k in names if not env.get(k)]
    if missing:
        raise WireGuardError(503, "WireGuard ayarı eksik (%s); kurulumu yeniden çalıştırın." % ", ".join(missing))
    return env


def parse(text):
    """The networks file's lines as FIELDS dicts (port an integer), in file order. A line that is not a
    network's raises ValueError: health, repair and the settings plan report it, they never guess."""
    rows = []
    for line in text.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if (len(fields) != 9 or not IFACE_RE.fullmatch(fields[0]) or not re.fullmatch(r"[0-9]{1,5}", fields[1])
                or fields[2] != "inet" or fields[0] in {r["iface"] for r in rows}):
            raise ValueError("WireGuard ağ kaydı")
        rows.append(dict(zip(FIELDS, fields), port=int(fields[1])))
    return rows


def records(env):
    """The networks in the networks file (WG_NETWORKS_FILE); [] when it does not exist."""
    try:
        with open(env["WG_NETWORKS_FILE"], encoding="utf-8") as fh:
            return parse(fh.read(65536))
    except FileNotFoundError:
        return []


def registered(env):
    """Interfaces in the networks file, in file order; [] when it does not exist."""
    return [r["iface"] for r in records(env)]


def stopped(env):
    """DD-229: WireGuard as a whole is stopped (master-wg durdur)."""
    return os.path.lexists(env["WG_STOPPED_FILE"])


def stopped_list(env):
    """The networks master-wg durdur wrote down as open (baslat opens these); [] without the marker."""
    try:
        with open(env["WG_STOPPED_FILE"], encoding="utf-8") as fh:
            return [line for line in fh.read(4096).splitlines() if IFACE_RE.fullmatch(line)]
    except FileNotFoundError:
        return []


def dns_addresses(dns):
    """A network's default DNS: 1–8 IPv4/IPv6 addresses separated by commas, as "a, b"."""
    if not isinstance(dns, str) or not dns.strip() or len(dns) > 512 or any(ord(c) < 32 for c in dns):
        raise WireGuardError(400, "Geçerli DNS gerekli.")
    try:
        addresses = [s.strip() for s in dns.split(",")]
        if not 1 <= len(addresses) <= 8 or any("%" in s for s in addresses):
            raise ValueError("DNS")
        for address in addresses:
            ipaddress.ip_address(address)
    except ValueError:
        raise WireGuardError(400, "DNS için en fazla 8 geçerli IPv4/IPv6 adresi yazın")
    return ", ".join(addresses)


def check_label(label):
    """A network's name: at most 64 bytes, no control character, no leading or trailing space."""
    if (not isinstance(label, str) or len(label.encode("utf-8")) > 64 or label != label.strip()
            or any(ord(c) < 32 or ord(c) == 127 for c in label)):
        raise WireGuardError(400, "Ağ adı en çok 64 bayt olabilir; baş/son boşluk ve denetim karakteri içeremez")
    return label


def section(env, item, unit):
    """DD-275: the settings transaction's "wireguard" section checked with master-wg's rules against the
    files and units now. item: {"eylem", "iface"?, "ag"?: {"port", "dns", "label"?}, "onay"?}; unit(iface)
    → (enabled, active) of its wg-quick unit. Returns the change the plan words and apply runs (no key,
    never the typed word itself): eylem, iface (for ag-ekle the interface master-wg will take), ag,
    onay (the typed word was given), durduruldu, aglar (the networks before), acilacak (baslat) and
    birim (a network's unit before). Raises WireGuardError(400, …)."""
    keys(env, SECTION_KEYS)
    if not isinstance(item, dict) or not isinstance(item.get("eylem"), str) or item["eylem"] not in ACTIONS:
        raise WireGuardError(400, "WireGuard eylemi geçersiz.")
    action = item["eylem"]
    need = {"eylem"} | ({"iface"} if action in NETWORK_ACTIONS else set()) | ({"ag"} if action == "ag-ekle" else set())
    if not need <= set(item) <= need | ({"onay"} if action in TYPED else set()):
        raise WireGuardError(400, "WireGuard isteğinin alanları bu eylemle uyuşmuyor.")
    if not isinstance(item.get("onay", ""), str):
        raise WireGuardError(400, "Onay sözcüğü metin olmalı.")
    try:
        nets = records(env)
        listed = stopped_list(env)
    except (OSError, ValueError):
        raise WireGuardError(400, "WireGuard ağ kaydı okunamadı; kurulumu yeniden çalıştırın.")
    is_stopped = stopped(env)
    names = [n["iface"] for n in nets]
    change = {"eylem": action, "iface": None, "ag": None, "durduruldu": is_stopped,
              "onay": str(item.get("onay", "")).strip().lower() == CONFIRM_WORD,
              "aglar": [{k: n[k] for k in ("iface", "port", "label", "subnet4")} for n in nets]}
    if action == "baslat":
        if not is_stopped:
            raise WireGuardError(400, "WireGuard zaten çalışıyor.")
        change["acilacak"] = [name for name in listed if name in names]
    elif action == "durdur":
        if is_stopped:
            raise WireGuardError(400, "WireGuard zaten durdurulmuş.")
    elif action == "ag-ekle":
        if is_stopped:
            raise WireGuardError(400, STOPPED_TEXT)
        change["iface"], change["ag"] = new_network(env, item["ag"], nets)
    else:
        iface = item["iface"]
        if not isinstance(iface, str) or not IFACE_RE.fullmatch(iface):
            raise WireGuardError(400, "Geçersiz arayüz (wg0-wg9).")
        if iface not in names:
            raise WireGuardError(400, "'%s' diye bir WireGuard ağı yok" % iface)
        enabled, active = unit(iface)
        change["iface"], change["birim"] = iface, {"etkin": enabled, "calisiyor": active}
        if action in ("ag-ac", "ag-kapat") and is_stopped:
            raise WireGuardError(400, STOPPED_TEXT)
        if action == "ag-ac" and active:
            raise WireGuardError(400, "%s zaten açık." % iface)
        if action == "ag-kapat" and not (enabled or active):
            raise WireGuardError(400, "%s zaten kapalı." % iface)
    return change


def new_network(env, ag, nets):
    """ag-ekle's fields with master-wg net-add's rules: (the interface it will take, {port, dns, label, subnet4})."""
    if not isinstance(ag, dict) or not {"port", "dns"} <= set(ag) <= {"port", "dns", "label"}:
        raise WireGuardError(400, "Port ve DNS gerekli.")
    port = ag["port"]
    if type(port) is not int or not 1024 <= port <= 65535:
        raise WireGuardError(400, "UDP portu 1024-65535 arasında olmalı")
    dns = dns_addresses(ag["dns"])
    if not isinstance(ag.get("label", ""), str):
        raise WireGuardError(400, "Ağ adı metin olmalı.")
    label = check_label(ag.get("label", "").strip())
    # The base's ports (whatever their protocol) and the registered networks' ports, as master-wg reserves them.
    taken = [("ssh", env.get("SSH_PUBLIC_PORT")), ("tailscale", env.get("TAILSCALE_UDP_PORT")),
             ("dns", env.get("DNS_PORT") or "53"), ("http", env.get("CADDY_HTTP_PORT") or "80"),
             ("Dosyalar", env.get("FILES_PANEL_PORT")), ("Paylaşım", env.get("SHARE_PORT"))]
    for name, value in taken + [(n["iface"], str(n["port"])) for n in nets]:
        if value and str(value).strip() == str(port):
            raise WireGuardError(400, "UDP %d kullanılıyor (%s); başka bir port seçin" % (port, name))
    # Rebuild phase 4: an application's open raw port (TCP or UDP, on Tailscale or the WAN) holds its number.
    owner = app_ports(env).get(port)
    if owner:
        raise WireGuardError(400, "UDP %d bir uygulamanın erişim satırında kullanılıyor (%s); başka bir port seçin" % (port, owner))
    limit = num_or(env["WG_NETWORKS_MAX"], 9) + 1
    names = {n["iface"] for n in nets}
    free = [i for i in range(min(limit, 10)) if "wg%d" % i not in names
            and not os.path.exists(os.path.join(env["WG_CONF_DIR"], "wg%d.conf" % i))]
    if not free:
        raise WireGuardError(400, "en çok %d ağ oluşturulabilir" % limit)
    return "wg%d" % free[0], {"port": port, "dns": dns, "label": label,
                              "subnet4": "%s.%d.0/24" % (env["WG_ADDR_BASE4"], free[0])}


def app_ports(env):
    """{port: row id} of the applications' open raw ports (either protocol, either scope): a WireGuard network may
    not take one of their numbers. A record that cannot be read refuses (fail closed)."""
    if not env.get("UYGULAMA_STATE_DIR"):
        return {}
    import master_publications
    import master_settings
    try:
        rows = master_publications.app_rows(env)
    except master_settings.SettingsError as err:
        raise WireGuardError(400, str(err)) from err
    return {r["satir"]["port"]: r["id"] for r in rows if r["satir"]["tur"] == "ham" and r["satir"]["kapsam"] != "kapali"}


def network_name(change, iface):
    label = next((n["label"] for n in change["aglar"] if n["iface"] == iface), "")
    return "WireGuard ağı %s%s" % (iface, " · " + label if label else "")


def network_port(change, iface):
    return next((n["port"] for n in change["aglar"] if n["iface"] == iface), 0)


def plan_items(change):
    """DD-275: what the change does, as the settings plan lists it (alan "wireguard")."""
    action, iface = change["eylem"], change["iface"]

    def item(islem, nesne, once, sonra):
        return {"alan": "wireguard", "islem": islem, "nesne": nesne, "once": once, "sonra": sonra}
    if action == "baslat":
        return [item("ac", "WireGuard", "durduruldu", "çalışıyor")]
    if action == "durdur":
        return [item("kapat", "WireGuard", "çalışıyor", "durduruldu")]
    if action == "ag-ekle":
        ag = change["ag"]
        added = item("ekle", "WireGuard ağı %s%s" % (iface, " · " + ag["label"] if ag["label"] else ""), None,
                     "UDP %d · %s · DNS %s" % (ag["port"], ag["subnet4"], ag["dns"]))
        return ([item("ac", "WireGuard", "kapalı", "açık")] if not change["aglar"] else []) + [added]
    up = "açık" if change["birim"]["calisiyor"] else "kapalı"
    if action == "ag-ac":
        return [item("ac", network_name(change, iface), "kapalı", "açık")]
    if action == "ag-kapat":
        return [item("kapat", network_name(change, iface), "açık" if change["birim"]["calisiyor"] else "açık (çalışmıyor)",
                     "kapalı")]
    if action == "ag-kaldir":
        out = [item("kaldir", network_name(change, iface), "UDP %d · %s" % (network_port(change, iface), up), None)]
        if len(change["aglar"]) == 1 and not change["durduruldu"]:
            out.append(item("kapat", "WireGuard", "açık", "kapalı"))
        return out
    return [item("degistir", network_name(change, iface) + " · sunucu anahtarı", "mevcut anahtar", "yeni anahtar"),
            item("kaldir", network_name(change, iface) + " · cihazlar", "bütün cihazlar ve profilleri", None)]


def plan_notes(change):
    """DD-275: the plan's effects (what restarts, opens, closes or is replaced) and warnings."""
    action, iface = change["eylem"], change["iface"]
    effects, warnings = [], []
    closing = {"seviye": "warn", "metin": "Onay beklemeden hemen kalıcı olur; bağlı cihazların bağlantısı kopar."}
    if action == "baslat":
        ports = ", ".join(str(n["port"]) for n in change["aglar"])
        effects.append("Güvenlik duvarı yeniden kurulur: WireGuard'ın UDP portları internete açılır%s; yönlendirme ve NAT gelir."
                       % (" (%s)" % ports if ports else ""))
        effects.append("Durdurmadan önce açık olan ağlar açılır: %s." % ", ".join(change["acilacak"]) if change["acilacak"]
                       else "Açılacak ağ yok; ağlar Konsol'dan tek tek açılır.")
    elif action == "durdur":
        ports = ", ".join(str(n["port"]) for n in change["aglar"])
        effects.append("Bütün ağlar kapanır; bağlı cihazların bağlantısı kopar.")
        effects.append("Güvenlik duvarı yeniden kurulur: WireGuard'ın UDP portları kapanır%s; yönlendirme ve NAT kalkar."
                       % (" (%s)" % ports if ports else ""))
        warnings.append(closing)
    elif action == "ag-ekle":
        effects.append("Ağın sunucu anahtarı üretilir ve %s arayüzü açılır." % iface)
        effects.append("Güvenlik duvarı yeniden kurulur: UDP %d internete açılır%s." % (
            change["ag"]["port"], "; yönlendirme ve NAT gelir" if not change["aglar"] else ""))
    elif action == "ag-ac":
        effects.append("%s arayüzü açılır; cihazları yeniden bağlanabilir." % iface)
        effects.append("UDP %d güvenlik duvarında zaten açık; güvenlik duvarı değişmez." % network_port(change, iface))
    elif action == "ag-kapat":
        effects.append("%s arayüzü kapanır; bağlı cihazların bağlantısı kopar." % iface)
        effects.append("UDP %d güvenlik duvarında açık kalır; dinleyen olmaz." % network_port(change, iface))
        warnings.append(closing)
    elif action == "ag-kaldir":
        effects.append("%s kapanır; ağın anahtarı, bütün cihazları ve profilleri silinir." % iface)
        effects.append("Güvenlik duvarı yeniden kurulur%s." % (
            ": UDP %d kapanır" % network_port(change, iface) if not change["durduruldu"] else ""))
        warnings += [closing, {"seviye": "warn", "metin": "Geri alınamaz: ağın anahtarı ve cihaz profilleri silinir."}]
    else:
        effects.append("%s ağının sunucu anahtarı yeniden üretilir; bütün cihazları ve profilleri silinir." % iface)
        effects.append("Cihazlar yeni profille yeniden eklenmeli.")
        warnings += [closing, {"seviye": "warn", "metin": "Geri alınamaz: eski sunucu anahtarı ve bütün cihaz profilleri silinir."}]
    return effects, warnings


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
        try:
            reserved |= set(app_ports(env))
        except WireGuardError:
            pass  # the section refuses with the reason when a network is added
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

    # -- networks: a network's default DNS and name stay immediate (DD-265)
    def network_settings(self, net, data, audit):
        """Default DNS and, when "label" is sent (DD-265), the network's name; the revision guards both."""
        dns, revision, label = data["dns"], data["revision"], data.get("label")
        if "label" in data:
            check_label(label)
        if not dns.strip() or len(dns) > 512 or any(ord(c) < 32 for c in dns) or not re.fullmatch(r"[a-f0-9]{64}", revision):
            raise WireGuardError(400, "Geçerli DNS ve ağ revizyonu gerekli.")
        addresses = dns_addresses(dns)
        args = ("net-settings", dns, revision) + ((label,) if "label" in data else ())
        rc, _, message = self.run(*args, net=net)
        self.changed()
        audit("ag-ayarlar", net, rc == 0)
        if rc != 0:
            raise WireGuardError(409, message or "Ağ ayarları kaydedilemedi")
        return {"iface": net, "dns": addresses, **({"label": label} if "label" in data else {})}

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
