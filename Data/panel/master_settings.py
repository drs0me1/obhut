#!/usr/bin/env python3
"""Konsol settings transactions (DD-156), Python stdlib only.

The HTTP process only reads here. Mutations run in an independent systemd unit,
with JSON on stdin, and share the installer's lock. A permanent systemd
timer recovers incomplete transactions, including after a reboot. No shell input.

DD-275: WireGuard's access-changing actions are the "wireguard" section. The worker runs master-wg
in its caller mode: the install.lock descriptor it holds (OBHUT_KILIT_FD) and the pending change's id
(OBHUT_AYAR_ISLEMI). WireGuard's private keys and device profiles never enter the pending file.

Rebuild phase 4: the settings transaction is the single writer of access. Its sections, each alone in a
request except firewall + dns: firewall, dns, domain, web (Konsol's and WebDAV's fixed rows), erisim (one
access row of one application, checked in master_publications.section) and wireguard. Decision 1: a change
that opens or widens access waits for the 60 s confirmation from Tailscale; one that only closes commits at
once. An erisim change runs its container side in this process (master_container_worker.Manager.row_change,
under the contract its docstring holds), then the firewall and the projection (master_shares publish).
"""
import argparse
import base64
import contextlib
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import subprocess
import sys
import time
import urllib.parse

LIMIT = 65536
# DD-181: the rollback timer runs only while a change is pending (apply starts it, an idle
# guard stops it under the locks); at boot it runs once to catch a pending change.
GUARD_TIMER = "master-settings-guard.timer"
# DD-182: a failing automatic rollback is retried after 15, 30, 60 and 120 s; after the
# fifth failure it is "stuck" and waits for the operator (retry or discard in Konsol).
ROLLBACK_ATTEMPTS = 5
ROLLBACK_BACKOFF = 15
CONFIRM_WORD = "onayla"
# DD-275: the worker's exit status for a page that showed another revision; the backend answers 409.
STALE_EXIT = 75
BASE_ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C.UTF-8"}
OFF = "# konsol-off: "
DEFAULT = {"firewall": [], "dns": {"disabled": [], "records": [], "forward": False, "servers": []}}
# The applying deadline: a change must be applied (or rolled back by the guard) within this many seconds. An
# erisim change may restart a container and wait up to 300 s for it to be ready (master_container_worker
# READY_SECONDS), then publish and wait for a certificate: it gets ERISIM_SECONDS, and the backend runs its
# worker (apply, and the rollback of a pending erisim change) with ERISIM_WORKER_SECONDS (RuntimeMaxSec), enough
# for an apply that fails at the deadline and its rollback. Every other change keeps the shorter limits.
APPLY_SECONDS = 180
ERISIM_SECONDS = 900
WORKER_SECONDS = 150
ERISIM_WORKER_SECONDS = 1800
SECTIONS = ("firewall", "dns", "domain", "web", "erisim", "wireguard")
DOMAIN_RE = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"


class SettingsError(Exception):
    pass


class SettingsBusy(SettingsError):
    pass


class SettingsStale(SettingsError):
    """The request carries another revision than the files have now (409)."""


def require(ok, message):
    if not ok:
        raise SettingsError(message)


def env_read(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            result[key] = value.strip('"')
    return result


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return copy.deepcopy(default)
    except (ValueError, OSError, RecursionError) as err:
        raise SettingsError("Ayar kaydı okunamadı; üzerine yazılmadı.") from err


@contextlib.contextmanager
def parent_fd(path, create=False):
    # Servis kullanıcısının sahip olduğu profil dizinleri değişebilir; tüm yolu
    # O_NOFOLLOW ile açıp yazma boyunca dizin tanıtıcısını sabit tutuyoruz.
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "Ayar dosyasının yolu geçersiz.")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
            new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = new
        yield fd, path.name
    finally:
        os.close(fd)


def read_regular(path, limit=1024 * 1024):
    with parent_fd(path) as (directory, name):
        with os.fdopen(os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory), "rb") as fh:
            info = os.fstat(fh.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, "Ayar dosyası geçersiz veya çok büyük.")
            data = fh.read(limit + 1)
            require(len(data) <= limit, "Ayar dosyası çok büyük.")
            return data, info


def atomic(path, content, mode=0o600, owner=None):
    path = Path(path)
    require(not path.is_symlink(), "Sembolik bağlantı hedefi reddedildi.")
    data = content.encode() if isinstance(content, str) else content
    try:
        if read_regular(path, max(16 * 1024 * 1024, len(data)))[0] == data:
            return
    except FileNotFoundError:
        pass
    with parent_fd(path, create=True) as (directory, name):
        tmp = ".konsol-" + secrets.token_hex(16)
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=directory)
            with os.fdopen(fd, "wb") as fh:
                os.fchmod(fh.fileno(), mode)
                if owner is not None:
                    os.fchown(fh.fileno(), *owner)
                fh.write(data)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, name, src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(tmp, dir_fd=directory)
            except FileNotFoundError:
                pass


def save_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


def saved_domain(path):
    value = read_json(path, {}).get("domain", "")
    require(isinstance(value, str) and (not value or re.fullmatch(DOMAIN_RE, value)), "Kayıtlı yerel alan adı geçersiz.")
    return value


def run(argv, *, input=None, check=True, timeout=30, env=None):
    try:
        p = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout, env=dict(BASE_ENV, **(env or {})))
    except (OSError, subprocess.TimeoutExpired) as err:
        raise SettingsError("Komut tamamlanamadı: " + Path(argv[0]).name) from err
    # Never copy command output into errors: a service may print credentials.
    require(not check or p.returncode == 0, "Doğrulama/uygulama başarısız: " + Path(argv[0]).name)
    return p


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def tailnet_ports(env):
    """DD-172: host ingress allowlist; not a list of arbitrary open sockets.

    Keep Tailscale's own PeerAPI endpoints, discovered from Self, never peers.
    A daemon not yet ready must not prevent the WAN firewall from landing.
    The existing firewall watchdog notices changed endpoints via --check.
    """
    rows = []
    for key, proto, name in (("SSH_PUBLIC_PORT", "tcp", "SSH"),
                             ("CADDY_HTTP_PORT", "tcp", "Caddy"),
                             ("DNS_PORT", "tcp", "dnsmasq"),
                             ("DNS_PORT", "udp", "dnsmasq"),
                             ("SHARE_PORT", "tcp", "Paylaşım WebDAV")):
        port = int(env.get(key, 0))
        if 1 <= port <= 65535:
            # Caddy templates bind only TAILSCALE_IPV4, including folder WebDAV.
            families = (4,) if key in ("CADDY_HTTP_PORT", "SHARE_PORT") else (4, 6)
            rows.extend(dict(family=f, proto=proto, port=port, name=name) for f in families)
    try:
        status = json.loads(run(["tailscale", "status", "--json", "--peers=false"], timeout=3).stdout)
        own = status.get("Self") or {}
        addresses = {ipaddress.ip_address(x) for x in own.get("TailscaleIPs", [])}
        for value in own.get("PeerAPIURL", []) or []:
            url = urllib.parse.urlsplit(value)
            ip = ipaddress.ip_address(url.hostname)
            if (url.scheme == "http" and ip in addresses and url.port and
                    not url.username and not url.password and url.path in ("", "/") and
                    not url.query and not url.fragment):
                row = dict(family=ip.version, proto="tcp", port=url.port, name="Tailscale PeerAPI")
                if not any(all(r[k] == row[k] for k in ("family", "proto", "port")) for r in rows):
                    rows.append(row)
    except (SettingsError, ValueError, TypeError, AttributeError, RecursionError):
        # PeerAPI normally also has a userspace netstack path; never grant an
        # ephemeral port range or abort host protection on a failed status read.
        pass
    # DD-172 amended (rebuild phase 4, K5): an address row's Tailscale port, where Caddy listens on the
    # Tailscale IPv4. An application record that cannot be read stops the caller (the firewall keeps its rules).
    import master_publications
    for item in master_publications.app_rows(env):
        row = item["satir"]
        if row["tur"] == "adres" and row["tailscale_portu"] is not None:
            port = dict(family=4, proto="tcp", port=row["tailscale_portu"], name="%s · Tailscale portu" % item["uygulama"])
            if not any(all(r[k] == port[k] for k in ("family", "proto", "port")) for r in rows):
                rows.append(port)
    return rows


SCOPE_TEXT = {"wan": "İnternet", "tail": "Tailscale"}


def rule_text(r):
    """A firewall rule as the plan shows it: "TCP 8080 · İnternet · IPv4 · izin"."""
    text = "%s %d · %s · IPv%d" % (r["proto"].upper(), r["port"], SCOPE_TEXT.get(r["scope"], r["scope"]), r["family"])
    if r["source"]:
        text += " · yalnız " + r["source"]
    return text + (" · izin" if r["allow"] else " · engel")


def plan_item(alan, islem, nesne, once=None, sonra=None):
    return {"alan": alan, "islem": islem, "nesne": nesne, "once": once, "sonra": sonra}


def dns_record_text(r):
    return ("Tailscale adresi" if r["target"] == "tailscale" else r["target"]) + ("" if r["enabled"] else " · kapalı")


def forward_text(d):
    return "Üst DNS: " + ", ".join(d["servers"]) if d["forward"] else "Yalnız yerel adlar"


def audit_detail(item):
    """The audit line's detail for a settings action (DD-275): a WireGuard action by its name and network
    (item: the request's "wireguard" object or the pending change's), an access row by its id and what it becomes
    (the request's "erisim" object, or the pending change's row id), "ayarlar" for the other sections. Only checked
    words reach the journal."""
    import master_wireguard
    if isinstance(item, str):
        return "erisim " + item if erisim_id(item) else "ayarlar"
    if isinstance(item, dict) and {"uygulama", "anahtar", "satir"} <= set(item):
        return erisim_detail(item)
    if not isinstance(item, dict) or item.get("eylem") not in master_wireguard.ACTIONS:
        return "ayarlar"
    words = ["wireguard", item["eylem"]]
    if isinstance(item.get("iface"), str) and master_wireguard.IFACE_RE.fullmatch(item["iface"]):
        words.append(item["iface"])
    ag = item.get("ag")
    if isinstance(ag, dict) and type(ag.get("port")) is int and 0 < ag["port"] < 65536:
        words.append("UDP %d" % ag["port"])
    return " ".join(words)


def erisim_id(value):
    """True for an application access row's id (uygulama:<app>:<service>:<port>/<proto>)."""
    import master_applications as apps
    app, sep, key = value.removeprefix(apps.ROW_PREFIX).partition(":") if value.startswith(apps.ROW_PREFIX) else ("", "", "")
    match = apps.PORT_KEY_RE.fullmatch(key) if sep else None
    return bool(match and apps.APP_NAME_RE.fullmatch(app) and apps.SERVICE_RE.fullmatch(match.group(1)))


def erisim_detail(item):
    """"erisim <row id> <what the row becomes>" for a request whose application, key and row are well formed."""
    import master_applications as apps
    app, key, row = item.get("uygulama"), item.get("anahtar"), item.get("satir")
    if not (isinstance(app, str) and isinstance(key, str) and apps.APP_NAME_RE.fullmatch(app)
            and apps.row_problem(key, row) is None):
        return "erisim"
    rid = apps.row_id(app, key)
    if row["tur"] == "ham":
        return "erisim %s ham %s %d" % (rid, row["kapsam"], row["port"])
    return "erisim %s adres %s tailscale-portu %s internet %s" % (
        rid, row["ad"], row["tailscale_portu"] if row["tailscale_portu"] is not None else "kapali", row["internet"] or "kapali")


def dns_interface(value):
    """The managed interface-name grammar, shared with the read-only DNS view."""
    match = re.fullmatch(r"([^,\s]+),([^,/\s]+)(?:/([46]))?", value)
    if match is None:
        return None
    name, iface, family = match.groups()
    return {"name": name, "iface": iface, "family": int(family) if family else None}


class Manager:
    def __init__(self, state):
        self.state = str(state)
        self.e = env_read(state)
        self.config_path = Path(self.e["SETTINGS_FILE"])
        self.pending_path = Path(self.e["SETTINGS_PENDING_FILE"])
        self.dns_file = Path(self.e["SETTINGS_DNS_FILE"])
        # DD-275: install.lock while locked() holds it; master-wg's caller mode inherits it.
        self.install_lock = None

    def config(self):
        return read_json(self.config_path, DEFAULT)

    def pending(self):
        return read_json(self.pending_path, None)

    def current(self):
        p = self.pending()
        if p and p["boot"] == boot_id() and time.monotonic() < p["until"] and p["phase"] != "rollback":
            return p["candidate"]
        return self.config()

    def revision(self):
        h = hashlib.sha256(json.dumps(self.config(), sort_keys=True).encode())
        # Detect installer changes too, and WireGuard's networks and stopped marker (DD-275).
        for path in [Path(self.state), self.dns_file, *self.dns_paths(), *self.domain_paths(), *self.wireguard_paths(),
                     *self.row_paths()]:
            try:
                s = path.stat()
                h.update((str(path) + str(s.st_mtime_ns) + str(s.st_size)).encode())
            except FileNotFoundError:
                pass
        return h.hexdigest()

    @contextlib.contextmanager
    def locked(self):
        with contextlib.ExitStack() as stack:
            held = {}
            for name in ("install.lock", "settings.lock", "state.lock"):
                path = Path(self.e["RUNTIME_DIR"]) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                f = stack.enter_context(open(path, "a"))
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as err:
                    raise SettingsBusy("Kurulum ya da ayar işlemi sürüyor; biraz sonra yeniden deneyin.") from err
                held[name] = f
            self.install_lock = held["install.lock"]
            try:
                yield
            finally:
                self.install_lock = None

    def row_paths(self):
        """Rebuild phase 4: every application's erisim.json (the access rows; a fingerprint only, read by stat)."""
        root = self.e.get("UYGULAMA_STATE_DIR")
        if not root:
            return []
        try:
            return sorted(Path(entry.path) / "erisim.json" for entry in os.scandir(root)
                          if not entry.name.startswith(".") and entry.is_dir(follow_symlinks=False))
        except OSError:
            return []

    def wireguard_paths(self):
        """DD-275: WireGuard's non-secret files that master-wg changes for a planned action."""
        return [Path(self.e[k]) for k in ("WG_NETWORKS_FILE", "WG_STOPPED_FILE") if self.e.get(k)]

    def dns_paths(self):
        directory = Path(self.e["DNSMASQ_CONF_DIR"])
        return [Path(self.e["DNSMASQ_CONF_FILE"]), *sorted(directory.glob("modul-*.conf"))]

    def dns_names(self):
        names = []
        for path in self.dns_paths():
            if not path.exists():
                continue
            source = path.stem.removeprefix("modul-") if path.name.startswith("modul-") else "base"
            for line in path.read_text().splitlines():
                line = line.removeprefix(OFF)
                if line.startswith("interface-name="):
                    record = dns_interface(line.partition("=")[2])
                    if record:
                        target = "tailscale" if record["family"] != 6 else self.e.get("TAILSCALE_IPV6", "")
                        names.append({**record, "target": target, "source": source})
        return names

    def validate(self, data):
        require(isinstance(data, dict) and set(data) <= {"revision", *SECTIONS}, "Bilinmeyen ayar alanı.")
        if data.get("revision") != self.revision():
            raise SettingsStale("Ayarlar değişmiş. Yenileyip yeniden inceleyin.")
        c = self.config()
        if "wireguard" in data:
            # DD-275: checked against the files and units in prepare (wireguard_section).
            require(set(data) == {"revision", "wireguard"}, "WireGuard değişikliğini diğer ayarlardan ayrı kaydedin.")
        if "erisim" in data:
            # Rebuild phase 4: checked against every row, the host's ports and DNS in prepare (erisim_section).
            require(set(data) == {"revision", "erisim"}, "Erişim satırını diğer ayarlardan ayrı kaydedin.")
            require(not Path(self.e["SHARE_STATE_FILE"] + ".pending").exists(), "Önceki paylaşım işlemi kurtarılıyor.")
        if "web" in data:
            import master_publications
            require(set(data) == {"revision", "web"}, "Caddy yayınını diğer ayarlardan ayrı kaydedin.")
            require(not Path(self.e["SHARE_STATE_FILE"] + ".pending").exists(), "Önceki paylaşım işlemi kurtarılıyor.")
            c = master_publications.validate(self.e, c, data["web"])
        if "domain" in data:
            require(set(data) == {"revision", "domain"}, "Alan adını diğer ayarlardan ayrı güncelleyin.")
            domain = data["domain"]
            require(isinstance(domain, str) and re.fullmatch(DOMAIN_RE, domain),
                    "Yerel ad 1–63 küçük harf/rakam veya tire olmalı; nokta, boşluk ve adres öneki kullanmayın.")
            old = self.e["LOCAL_DOMAIN"]
            require(domain != old, "Yeni alan adı mevcut adla aynı.")
            c["domain"] = domain
            def rename(name):
                return name[:-len(old)] + domain if name.endswith("." + old) else name
            c["dns"]["disabled"] = [rename(n) for n in c["dns"]["disabled"]]
            for record in c["dns"]["records"]:
                record["name"] = rename(record["name"])
        if "firewall" in data:
            rules = data["firewall"]
            require(isinstance(rules, list) and len(rules) <= 100, "En çok 100 kullanıcı kuralı olabilir.")
            seen, selectors = set(), set()
            held = self.app_rule_ports()
            for r in rules:
                require(isinstance(r, dict) and set(r) == {"id", "name", "family", "scope", "proto", "port", "source", "allow"}, "Kural biçimi geçersiz.")
                require(isinstance(r["id"], str) and re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", r["id"]), "Kural kimliği geçersiz.")
                require(r["id"] not in seen, "Tekrar eden kural kimliği.")
                seen.add(r["id"])
                require(isinstance(r["name"], str) and 1 <= len(r["name"]) <= 64 and r["name"].isprintable(), "Kural adı geçersiz.")
                require(type(r["family"]) is int and r["family"] in (4, 6), "IPv4 veya IPv6 seçin.")
                require(r["scope"] in ("wan", "tail"), "Port kuralları yalnız İnternet ve Tailscale için düzenlenebilir.")
                require(r["proto"] in ("tcp", "udp") and type(r["port"]) is int and 1 <= r["port"] <= 65535, "Port/protokol geçersiz.")
                require(type(r["allow"]) is bool and isinstance(r["source"], str), "Kural eylemi/kaynağı geçersiz.")
                if r["source"]:
                    try:
                        src = ipaddress.ip_network(r["source"], strict=False)
                    except ValueError as err:
                        raise SettingsError("Kaynak IP/CIDR geçersiz.") from err
                    require(src.version == r["family"], "Kaynak adresinin IP ailesi uyuşmuyor.")
                    r["source"] = str(src)
                selector = (r["family"], r["scope"], r["proto"], r["port"], r["source"])
                require(selector not in selectors, "Aynı port/kaynak için iki kural olamaz.")
                # Rebuild phase 4: a raw port or a Tailscale port is its access row's; a rule there would mislead.
                import master_publications
                require((r["scope"], r["proto"], r["port"]) not in held, master_publications.RULE_HELD)
                selectors.add(selector)
            c["firewall"] = rules
        if "dns" in data:
            d = data["dns"]
            require(isinstance(d, dict) and set(d) == {"disabled", "records", "forward", "servers"}, "DNS biçimi geçersiz.")
            require(type(d["forward"]) is bool and isinstance(d["disabled"], list) and isinstance(d["records"], list)
                    and isinstance(d["servers"], list), "DNS alanları geçersiz.")
            require(len(d["records"]) <= 100 and len(d["disabled"]) <= 200 and len(d["servers"]) <= 4, "Çok fazla DNS kaydı.")
            reserved = {n["name"] for n in self.dns_names()}
            managed_names = set(reserved)
            # Rebuild phase 4: an application's Tailscale name is switched in its access row, never here.
            locked = self.app_names()
            reserved |= set(locked)
            for r in d["records"]:
                require(isinstance(r, dict) and set(r) == {"name", "target", "enabled"}, "DNS kaydı biçimi geçersiz.")
                name = r["name"]
                require(isinstance(name, str) and len(name) <= 253 and name.endswith("." + self.e["LOCAL_DOMAIN"])
                        and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in name.split(".")),
                        "Kayıt yerel alan içinde, geçerli küçük harfli bir ad olmalı.")
                require(name not in reserved, "Bu DNS adı zaten tanımlı.")
                reserved.add(name)
                require(type(r["enabled"]) is bool and isinstance(r["target"], str), "DNS hedefi geçersiz.")
                if r["target"] != "tailscale":
                    try:
                        addr = ipaddress.ip_address(r["target"])
                    except ValueError as err:
                        raise SettingsError("DNS hedefi IPv4/IPv6 olmalı.") from err
                    require(not (addr.is_unspecified or addr.is_multicast), "DNS hedefi geçersiz.")
                    r["target"] = str(addr)
            require(all(isinstance(n, str) and n in managed_names for n in d["disabled"]), "Bilinmeyen DNS adı kapatılamaz.")
            for name in d["disabled"]:
                require(name not in locked, "%s bir uygulamanın erişim satırına ait; Erişim → Adresler'den değişir." % name)
            for server in d["servers"]:
                try:
                    addr = ipaddress.ip_address(server)
                except (ValueError, TypeError) as err:
                    raise SettingsError("Üst DNS, public IPv4/IPv6 adresi olmalı.") from err
                require(addr.is_global and not addr.is_multicast and str(addr) not in
                        {self.e.get(k, "") for k in ("WAN_IPV4", "WAN_IPV6", "TAILSCALE_IPV4", "TAILSCALE_IPV6")},
                        "Yerel/kendisine dönen DNS sunucusu kullanılamaz.")
            require(not d["forward"] or bool(d["servers"]), "Yönlendirme için DNS sunucusu seçin.")
            c["dns"] = d
        return c

    def app_rows(self):
        import master_publications
        return master_publications.app_rows(self.e)

    def app_rule_ports(self):
        """{(scope, protocol, port): row id} the operator's firewall rules may not name (master_publications)."""
        import master_publications
        return master_publications.rule_ports(self.app_rows())

    def app_names(self):
        """{full Tailscale name: row id} of the applications' address rows."""
        return {"%s.%s" % (r["satir"]["ad"], self.e["LOCAL_DOMAIN"]): r["id"]
                for r in self.app_rows() if r["satir"]["tur"] == "adres"}

    def safe_dir(self, value, writable=False):
        require(isinstance(value, str) and len(value) <= 1024 and bool(re.fullmatch(r"/[A-Za-z0-9_./ -]+", value)),
                "Dizin yolu geçersiz (harf/rakam, boşluk, . _ - / kullanılabilir).")
        path = Path(value)
        root = Path(self.e["SERVER_ROOT"])
        require(path.is_absolute() and ".." not in path.parts and path.is_dir() and str(path.resolve()) == str(path), "Dizin mevcut ve gerçek bir klasör olmalı; sembolik bağlantı kullanılamaz.")
        allowed = [Path(self.e["DOWNLOADS_PATH"]), root / self.e["MEDIA_SUBDIR"]]
        require(any(path == a or a in path.parents for a in allowed), "Yalnız indirmeler veya kütüphane altı seçilebilir.")
        require(not any(part.startswith(".") for part in path.relative_to(root).parts), "Gizli/paylaşım/çöp dizinleri kullanılamaz.")
        if writable:
            # Probe as the service user, never chown a user-selected tree as root.
            probe = "import os,sys,tempfile; f,p=tempfile.mkstemp(prefix='.konsol-test-',dir=sys.argv[1]); os.close(f); os.unlink(p)"
            run(["setpriv", "--reuid=" + self.e["DOWNLOADS_UID"], "--regid=" + self.e["DOWNLOADS_GID"],
                 "--clear-groups", "python3", "-c", probe, str(path)])
            s = os.statvfs(path)
            require(s.f_bavail * s.f_frsize > 0, "Seçilen diskte boş alan yok.")
        return path

    def folders(self, path=None):
        if path:
            root = self.safe_dir(path)
            dirs = [p for p in root.iterdir() if not p.is_symlink() and p.is_dir() and not p.name.startswith(".")]
        else:
            dirs = [Path(self.e["DOWNLOADS_PATH"]), Path(self.e["SERVER_ROOT"]) / self.e["MEDIA_SUBDIR"]]
        result = []
        for p in sorted(dirs)[:200]:
            try:
                self.safe_dir(str(p))
                s = os.statvfs(p)
                result.append({"path": str(p), "free": s.f_bavail * s.f_frsize})
            except (SettingsError, OSError):
                continue
        return result

    def filter_dns(self, text, config=None):
        disabled = (config or self.current())["dns"]["disabled"]
        lines = []
        for raw in text.splitlines():
            line = raw.removeprefix(OFF)
            name = line.partition("=")[2].partition(",")[0]
            lines.append(OFF + line if line.startswith("interface-name=") and name in disabled else line)
        return "\n".join(lines) + "\n"

    def project_dns(self, config=None):
        import master_applications as apps
        d = (config or self.current())["dns"]
        for path in self.dns_paths():
            # The applications' names are not switchable here; their file is the projection's (master_shares publish).
            if not path.exists() or path.name == apps.DNS_FILE:
                continue
            atomic(path, self.filter_dns(path.read_text(), config), 0o644)
        lines = ["# Konsol (DD-156); kalıcı kaynak SETTINGS_FILE."]
        for r in d["records"]:
            if r["enabled"]:
                lines.append("interface-name=" + r["name"] + "," + self.e["TAILSCALE_IF"] + "/4" if r["target"] == "tailscale"
                             else "host-record=" + r["name"] + "," + r["target"])
        if d["forward"]:
            lines += ["server=" + ip for ip in d["servers"]]
        # Base local=/DOMAIN/ + no-resolv remain authoritative, even for disabled names.
        atomic(self.dns_file, "\n".join(lines) + "\n", 0o644)

    def rules(self, family, wan=None):
        out = []
        for r in self.current()["firewall"]:
            if r["family"] != family or r["scope"] not in ("wan", "tail"):
                continue
            iface = (wan or self.e["WAN_INTERFACE"]) if r["scope"] == "wan" else self.e["TAILSCALE_IF"]
            require(bool(re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", iface)), "Arayüz adı geçersiz.")
            args = ["-i", iface, "-p", r["proto"], "--dport", str(r["port"])]
            if r["source"]:
                args += ["-s", r["source"]]
            # The core continues protecting loopback, established flows and IPv6 ICMP.
            args += ["-m", "comment", "--comment", "konsol:" + r["id"], "-j", "ACCEPT" if r["allow"] else "DROP"]
            out.append(args)
        return out

    def pending_view(self):
        """The pending change as pages show it (None without one); reads only the pending file."""
        p = self.pending()
        if not p:
            return None
        pending = {"id": p["id"], "phase": p["phase"], "seconds": max(0, int(p["until"] - time.monotonic())) if p["boot"] == boot_id() else 0}
        if p.get("attempts"):
            pending.update(attempts=p["attempts"], error=p.get("error", ""))
            if p["phase"] == "rollback" and p.get("retry_boot") == boot_id():
                pending["retry_in"] = max(0, int(p.get("retry_at", 0) - time.monotonic()))
        if p["changes"].get("domain"):
            pending["domain"] = {"old": p["old_domain"], "new": p["candidate"]["domain"]}
        if p["changes"].get("web"):
            pending["web"] = True
        if p["changes"].get("erisim"):
            pending["erisim"] = p["changes"]["erisim"]["id"]
        wg = p["changes"].get("wireguard")
        if wg:
            pending["wireguard"] = {"eylem": wg["eylem"], "iface": wg["iface"]}
        return pending

    def status(self):
        import master_https
        import master_publications
        pending = self.pending_view()
        return {"revision": self.revision(), "config": self.current(), "pending": pending,
                "https": master_https.status(self.e), "publications": master_publications.status(self.e)}

    def snapshot(self, path):
        require(not path.is_symlink(), "Sembolik ayar dosyası reddedildi.")
        if not path.exists():
            return None
        data, info = read_regular(path)
        return {"data": base64.b64encode(data).decode(), "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}

    def restore(self, files):
        for name, record in files.items():
            path = Path(name)
            if record is None:
                path.unlink(missing_ok=True)
            else:
                atomic(path, base64.b64decode(record["data"]), record["mode"], (record["uid"], record["gid"]))

    def firewall_apply(self):
        run([self.e["SBIN_DIR"] + "/master-firewall"], timeout=40, env={"STATE_FILE": self.state})
        run([self.e["SBIN_DIR"] + "/master-firewall", "--check"], timeout=40, env={"STATE_FILE": self.state})

    def dns_test(self):
        helper = Path("/usr/share/dnsmasq/systemd-helper")
        run([str(helper), "checkconfig"] if helper.exists() else ["dnsmasq", "--test", "--conf-dir=" + self.e["DNSMASQ_CONF_DIR"]])

    def domain_paths(self):
        # Only installer-owned renderings; never touch credentials or download data.
        paths = [Path(self.e["UNIT_DIR"]) / "master-files-panel.service",
                 Path(self.e["UNIT_DIR"]) / "master-sistem-dosya.service"]
        if self.e.get("SHARE_CADDY_SOURCE"):
            paths.append(Path(self.e["SHARE_CADDY_SOURCE"]))
        if self.e.get("CADDYFILE"):
            paths.append(Path(self.e["CADDYFILE"]))
        if self.e.get("CADDY_MODULES_DIR"):
            paths.extend(Path(self.e["CADDY_MODULES_DIR"]).glob("*.caddy"))
        return sorted({p for p in paths if p.exists()})

    def set_domain_state(self, domain):
        # refresh-tailnet shares state.lock. Restore ONLY the suffix, never old IPs.
        text, info = read_regular(self.state)
        text, count = re.subn(r"(?m)^LOCAL_DOMAIN=.*$", "LOCAL_DOMAIN=" + domain, text.decode())
        require(count == 1, "state.env alan adı kaydı geçersiz.")
        atomic(self.state, text, stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
        self.e = env_read(self.state)

    def caddy_test(self):
        run(["caddy", "validate", "--config", self.e["CADDYFILE"], "--adapter", "caddyfile"],
            env={"TAILSCALE_IPV4": self.e["TAILSCALE_IPV4"]})

    def domain_reload(self, files_active):
        self.dns_test()
        self.caddy_test()
        run(["systemctl", "daemon-reload"])
        if files_active:
            run(["systemctl", "restart", "master-files-panel.service"], timeout=20)
            run(["systemctl", "is-active", "--quiet", "master-files-panel.service"])
        # DD-235: the system view checks the Host name it was started with.
        if Path(self.e["UNIT_DIR"], "master-sistem-dosya.service").exists():
            run(["systemctl", "restart", "master-sistem-dosya.service"], timeout=20)
        run(["systemctl", "restart", "dnsmasq"], timeout=20)
        # Caddy's graceful reload keeps the in-flight apply response alive.
        run(["systemctl", "reload", "caddy.service"], timeout=20)

    def domain_apply(self, candidate):
        old, new = re.escape(self.e["LOCAL_DOMAIN"]), candidate["domain"]
        for path in [*self.dns_paths(), *self.domain_paths()]:
            if not path.exists():
                continue
            raw, info = read_regular(path)
            text = raw.decode()
            # Structured tokens only: no blanket replacement in paths/comments.
            patterns = [r"(?m)^((?:# konsol-off: )?interface-name=[^,\n]+\.)" + old + r"(?=,)",
                        r"(?m)^(local=/)" + old + r"(?=/$)",
                        r"(?m)^(http://[a-z0-9.-]+\.)" + old + r"(?=[:\s,{]|$)",
                        # DD-195: the shared Konsol routes name the backends' Host.
                        r"(?m)^(\t+header_up Host panel\.)" + old + r"$",
                        r"(--domain=)" + old + r"(?=\s|$)"]
            for pattern in patterns:
                text = re.sub(pattern, lambda m: m[1] + new, text)
            atomic(path, text, stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
        self.set_domain_state(new)
        self.project_dns(candidate)
        self.domain_reload(self.pending()["files_active"])

    def prepare(self, data):
        """Every check apply makes before it changes anything (DD-265): the candidate and which
        sections change. plan() runs the same, so a plan and an apply cannot disagree."""
        require(not self.pending(), "Önce bekleyen işlemi onaylayın veya geri alın.")
        candidate = self.validate(data)
        change = {k: k in data for k in ("firewall", "dns", "domain")}
        change["web"] = False
        if "web" in data:
            # Decision 1 for a fixed row: whether it opens or widens access (master_publications.web_opening).
            import master_publications
            service = data["web"]["service"]
            before = master_publications.config(self.e, self.config())[service]
            after = master_publications.config(self.e, candidate)[service]
            change["web"] = {"service": service, "acilir": master_publications.web_opening(before, after)}
        # DD-275: the checked WireGuard change (master_wireguard.section), False without the section.
        change["wireguard"] = self.wireguard_section(data["wireguard"]) if "wireguard" in data else False
        # Rebuild phase 4: the checked access row change (master_publications.section), False without the section.
        change["erisim"] = self.erisim_section(data["erisim"], candidate) if "erisim" in data else False
        require(any(change.values()), "Değişiklik yok.")
        if change["dns"]:
            require("panel." + self.e["LOCAL_DOMAIN"] not in candidate["dns"]["disabled"],
                    "Panel erişimini korumak için Konsol'un kendi DNS adı kapatılamaz.")
        if change["domain"]:
            require(Path(self.e["CADDYFILE"]).is_file(), "Caddy yapılandırması bulunamadı.")
        return candidate, change

    @staticmethod
    def confirm_seconds(change):
        """0 when the change commits at once, else the window the operator has to confirm it (decision 1/4,
        DD-275): 300 s for the local domain; 60 s for the firewall, a WireGuard action that opens, an access row
        (erisim) or a fixed row (web) that opens or widens access. DNS alone and any change that only closes or
        narrows access commit at once."""
        if change.get("wireguard"):
            import master_wireguard
            return 60 if change["wireguard"]["eylem"] in master_wireguard.OPENING else 0
        if change.get("erisim"):
            import master_publications
            return 60 if master_publications.opening(change["erisim"]) else 0
        if change.get("web"):
            return 60 if change["web"]["acilir"] else 0
        if change["dns"] and not any(change[k] for k in ("firewall", "domain")):
            return 0
        return 300 if change["domain"] else 60

    def client_blocked(self, candidate, client):
        """The message when the candidate's Tailscale rules shut this client out of Konsol or DNS."""
        for proto, port in (("tcp", self.e["CADDY_HTTP_PORT"]), ("udp", self.e["DNS_PORT"]), ("tcp", self.e["DNS_PORT"])):
            for r in candidate["firewall"]:
                if (r["scope"] == "tail" and r["family"] == client.version and r["proto"] == proto and r["port"] == int(port)
                        and (not r["source"] or client in ipaddress.ip_network(r["source"]))):
                    if not r["allow"]:
                        return "Bu kural yeni Konsol/DNS bağlantınızı engelliyor; geri alın veya sürenin dolmasını bekleyin."
                    break
        return ""

    def plan(self, data, client="", kanal=""):
        """DD-265: what applying `data` would change, before anything changes. The same checks as
        apply (prepare), on a copy; no lock, file, timer or service is touched. A validation error is
        the same SettingsError apply would raise. client/kanal: the operator's address and channel,
        to say when a change could not be confirmed from there."""
        saved = self.config()
        candidate, change = self.prepare(copy.deepcopy(data))
        items = self.plan_items(saved, candidate, change, data)
        require(bool(items), "Değişiklik yok.")
        seconds = self.confirm_seconds(change)
        effects, warnings, ok = [], [], True
        if change["firewall"]:
            effects.append("Güvenlik duvarı kuralları yeniden kurulur.")
        if change["dns"] or change["domain"]:
            effects.append("dnsmasq yeniden başlar; yerel adlar birkaç saniye yanıt vermeyebilir.")
        if change["domain"]:
            effects.append("Caddy ve dosya servisleri yeni adla yeniden başlar.")
            warnings.append({"seviye": "warn", "metin": "Değişikliği 5 dakika içinde yeni adresten onaylayın: http://panel.%s. "
                             "Tailscale yönetim panelindeki split DNS kaydını da yeni ada çevirin." % candidate["domain"]})
        if change["web"]:
            import master_publications
            effects.append("Caddy yapılandırması yeniden yüklenir.")
            before = master_publications.config(self.e, saved)[change["web"]["service"]]
            after = master_publications.config(self.e, candidate)[change["web"]["service"]]
            if after["enabled"] and (not before["enabled"] or before["domain"] != after["domain"]):
                effects.append("İnternet adı için HTTPS sertifikası alınır (en çok 1 dakika).")
        if change["erisim"]:
            import master_publications
            notes, notices, applicable = master_publications.plan_notes(self.e, change["erisim"])
            effects += notes
            warnings += notices
            ok = ok and applicable
        if change["wireguard"]:
            import master_wireguard
            wg_effects, wg_warnings = master_wireguard.plan_notes(change["wireguard"])
            effects += wg_effects
            warnings += wg_warnings
            if change["wireguard"]["eylem"] in master_wireguard.TYPED and not change["wireguard"]["onay"]:
                ok = False
                warnings.append({"seviye": "bad", "metin": master_wireguard.TYPED_TEXT})
        if seconds:
            warnings.append({"seviye": "info", "metin": "Uygulandıktan sonra %d saniye içinde onaylamazsanız kendiliğinden geri alınır."
                             % seconds})
            if kanal == "internet":
                ok = False
                warnings.append({"seviye": "bad", "metin": "Bu değişiklik süreli onay ister ve onay yalnız Tailscale'den verilir; "
                                 "internet adresinden uygulanamaz."})
        try:
            address = ipaddress.ip_address(client) if client else None
        except ValueError:
            address = None
        if address is not None and change["firewall"]:
            blocked = self.client_blocked(candidate, address)
            if blocked:
                ok = False
                warnings.append({"seviye": "bad", "metin": "Bu kurallar şu anki Konsol bağlantınızı keser; onay verilemez ve "
                                 "değişiklik geri alınır."})
        return {"revizyon": self.revision(), "onay_sn": seconds, "degisiklikler": items, "etkiler": effects,
                "uyarilar": warnings, "uygulanabilir": ok}

    def plan_items(self, saved, candidate, change, data):
        items = []
        if change["firewall"]:
            before = {r["id"]: r for r in saved.get("firewall", [])}
            after = {r["id"]: r for r in candidate["firewall"]}
            for rid, r in after.items():
                old = before.get(rid)
                if old is None:
                    items.append(plan_item("guvenlik-duvari", "ekle", r["name"], None, rule_text(r)))
                elif old != r:
                    once, sonra = rule_text(old), rule_text(r)
                    if once == sonra:
                        once, sonra = "Ad: " + old["name"], "Ad: " + r["name"]
                    items.append(plan_item("guvenlik-duvari", "degistir", r["name"], once, sonra))
            for rid, r in before.items():
                if rid not in after:
                    items.append(plan_item("guvenlik-duvari", "kaldir", r["name"], rule_text(r), None))
        if change["domain"]:
            items.append(plan_item("alan-adi", "degistir", "Yerel alan adı", self.e["LOCAL_DOMAIN"], candidate["domain"]))
        elif change["dns"]:
            b, a = saved.get("dns") or DEFAULT["dns"], candidate["dns"]
            for name in sorted(set(a["disabled"]) - set(b["disabled"])):
                items.append(plan_item("dns", "kapat", name, "açık", "kapalı"))
            for name in sorted(set(b["disabled"]) - set(a["disabled"])):
                items.append(plan_item("dns", "ac", name, "kapalı", "açık"))
            before = {r["name"]: r for r in b["records"]}
            after = {r["name"]: r for r in a["records"]}
            for name, r in after.items():
                if name not in before:
                    items.append(plan_item("dns", "ekle", name, None, dns_record_text(r)))
                elif before[name] != r:
                    items.append(plan_item("dns", "degistir", name, dns_record_text(before[name]), dns_record_text(r)))
            for name, r in before.items():
                if name not in after:
                    items.append(plan_item("dns", "kaldir", name, dns_record_text(r), None))
            if (b["forward"], b["servers"]) != (a["forward"], a["servers"]):
                items.append(plan_item("dns", "degistir", "Dış adlar", forward_text(b), forward_text(a)))
        if change["web"]:
            items += self.publication_items(saved, candidate, data)
        if change["erisim"]:
            import master_publications
            items += master_publications.plan_items(self.e, change["erisim"])
        if change["wireguard"]:
            import master_wireguard
            items += master_wireguard.plan_items(change["wireguard"])
        return items

    def wireguard_section(self, item):
        """DD-275: the WireGuard section checked against the networks file, the stopped marker and the units."""
        import master_wireguard
        try:
            return master_wireguard.section(self.e, item, self.wireguard_unit)
        except master_wireguard.WireGuardError as err:
            raise SettingsError(str(err)) from err

    def wireguard_unit(self, iface):
        """(enabled, active) of a network's wg-quick unit; reads only."""
        unit = "wg-quick@%s.service" % iface
        return (run(["systemctl", "is-enabled", "--quiet", unit], check=False).returncode == 0,
                run(["systemctl", "is-active", "--quiet", unit], check=False).returncode == 0)

    def publication_items(self, saved, candidate, data):
        """A fixed row (Konsol, WebDAV) before and after: its Tailscale name and its internet (HTTPS) name, as
        access rows (alan "erisim")."""
        import master_publications
        service = data["web"]["service"]
        before = master_publications.config(self.e, saved)[service]
        after = master_publications.config(self.e, candidate)[service]
        name, local = ("Konsol", "panel") if service == master_publications.PANEL_ID else ("WebDAV", "paylas")
        tailnet = "%s.%s" % (local, self.e["LOCAL_DOMAIN"])
        out = []
        if before["tail"] != after["tail"]:
            out.append(plan_item("erisim", "ac" if after["tail"] else "kapat", "%s · Tailscale adı" % name,
                                 tailnet + (" açık" if before["tail"] else " kapalı"), tailnet + (" açık" if after["tail"] else " kapalı")))
        if (before["enabled"], before["domain"]) != (after["enabled"], after["domain"]):
            out.append(plan_item("erisim", "ac" if after["enabled"] and not before["enabled"] else
                                 "kapat" if before["enabled"] and not after["enabled"] else "degistir",
                                 "%s · internet adı" % name, before["domain"] if before["enabled"] else "kapalı",
                                 after["domain"] if after["enabled"] else "kapalı"))
        return out

    def erisim_section(self, item, saved):
        """Rebuild phase 4: the erisim section checked against every row, the host's ports and DNS
        (master_publications.section; saved: SETTINGS_FILE, whose firewall rules a port may not collide with)."""
        import master_publications
        return master_publications.section(self.e, saved, item)

    def apply(self, data):
        candidate, change = self.prepare(data)
        if change["wireguard"]:
            import master_wireguard
            require(change["wireguard"]["eylem"] not in master_wireguard.TYPED or change["wireguard"]["onay"],
                    master_wireguard.TYPED_TEXT)
        if change["erisim"]:
            import master_publications
            # A2: a raw port opens to the internet only with the consent the plan asked for.
            require(not change["erisim"]["internet_acilir"] or change["erisim"]["internet_onayi"],
                    master_publications.CONSENT_MISSING)
        seconds = self.confirm_seconds(change)
        run(["systemctl", "start", GUARD_TIMER])
        run(["systemctl", "is-active", "--quiet", GUARD_TIMER])
        paths = [*self.dns_paths(), self.dns_file] if change["dns"] else []
        files_active = False
        if change["web"]:
            import master_publications
            # Snapshot private projections too: a first-time row has no saved
            # web key for the publisher to reconstruct after a failed apply.
            paths.append(Path(self.e["CADDY_MODULES_DIR"]) / (master_publications.BUILTIN_ID + ".caddy"))
        if change["erisim"]:
            paths += self.erisim_paths(change["erisim"]["uygulama"])
        if change["domain"]:
            paths += [*self.dns_paths(), self.dns_file, *self.domain_paths()]
            files_active = run(["systemctl", "is-active", "--quiet", "master-files-panel.service"], check=False).returncode == 0
        # Pending is durable BEFORE the first mutation, and the timer already runs.
        p = {"id": secrets.token_hex(16), "boot": boot_id(),
             "until": time.monotonic() + (ERISIM_SECONDS if change["erisim"] else APPLY_SECONDS),
             "phase": "applying", "candidate": candidate, "changes": change,
             "files": {str(path): self.snapshot(path) for path in paths},
             "old_domain": self.e["LOCAL_DOMAIN"], "files_active": files_active}
        if change["erisim"]:
            # The units row_change restarted; None until it returns (a rollback then restarts every service).
            p["erisim"] = {"yeniden_baslatilan": None}
        if change["wireguard"]:
            # DD-275: the networks file and the stopped marker only; keys and profiles are never copied.
            p["wireguard"] = {"files": {str(path): self.snapshot(path) for path in self.wireguard_paths()}}
        save_json(self.pending_path, p)
        try:
            if change["wireguard"]:
                self.wireguard_apply(p)
            if change["web"]:
                row = data["web"]
                self.https_apply(candidate["web"][row["service"]]["domain"] if row.get("enabled") else None,
                                 row["service"])
            if change["erisim"]:
                self.erisim_apply(p)
            if change["domain"]:
                self.domain_apply(candidate)
            if change["dns"]:
                self.project_dns(candidate)
                self.dns_test()
                run(["systemctl", "restart", "dnsmasq"], timeout=20)
            if change["firewall"]:
                self.firewall_apply()
            p = self.pending()
            require(p["until"] > time.monotonic(), "Uygulama zaman aşımına uğradı.")
            if not seconds:
                self.commit(p)
                return {"pending": None, "committed": True}
            p.update(phase="awaiting", until=time.monotonic() + seconds)
            save_json(self.pending_path, p)
        except Exception:
            self.rollback()
            raise
        return {"pending": self.pending_view()}

    def wireguard_tool(self, pending_id, *argv):
        """master-wg in its caller mode (DD-275): it inherits the install.lock descriptor this worker
        holds and the pending change's id. (returncode, stdout, its last HATA line without the prefix);
        these verbs print no key."""
        lock = self.install_lock
        require(lock is not None and not lock.closed, "Kurulum kilidi tutulmuyor; WireGuard değişikliği uygulanmadı.")
        fd = lock.fileno()
        env = dict(BASE_ENV, STATE_FILE=self.state, OBHUT_KILIT_FD=str(fd), OBHUT_AYAR_ISLEMI=pending_id)
        try:
            p = subprocess.run([self.e["SBIN_DIR"] + "/master-wg", *argv], capture_output=True, text=True, timeout=90,
                               env=env, pass_fds=(fd,), stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as err:
            raise SettingsError("Komut tamamlanamadı: master-wg") from err
        errors = [line[6:] for line in p.stderr.splitlines() if line.startswith("HATA: ")]
        return p.returncode, p.stdout, errors[-1] if errors else ""

    def wireguard_run(self, p, *argv):
        rc, out, message = self.wireguard_tool(p["id"], *argv)
        require(rc == 0, message or "WireGuard geri alınamadı.")
        return out

    def wireguard_apply(self, p):
        """DD-275: the planned WireGuard action through master-wg. A closing action that fails names the
        state it left; it is not reopened."""
        import master_wireguard
        wg = p["changes"]["wireguard"]
        action, iface = wg["eylem"], wg["iface"]
        if action in ("baslat", "durdur"):
            argv = [action]
        elif action == "ag-ekle":
            argv = ["net-add", str(wg["ag"]["port"]), wg["ag"]["dns"], wg["ag"]["label"]]
        elif action == "ag-kaldir":
            argv = ["net-remove", iface, "--onay"]
        elif action == "yeniden-uret":
            argv = ["--if", iface, "reset", "--onay"]
        else:
            argv = ["--if", iface, "net", "ac" if action == "ag-ac" else "kapat"]
        rc, _out, message = self.wireguard_tool(p["id"], *argv)
        if rc != 0:
            text = message or master_wireguard.FAILED[action]
            raise SettingsError(text if action in master_wireguard.OPENING else "%s %s" % (text, self.wireguard_left()))

    def wireguard_left(self):
        """What a failed closing action left: WireGuard stopped or not, and each network's unit."""
        import master_wireguard
        try:
            if master_wireguard.stopped(self.e):
                return "Şu anki durum: WireGuard durdurulmuş."
            names = master_wireguard.registered(self.e)
            if not names:
                return "Şu anki durum: WireGuard ağı yok."
            return "Şu anki durum: %s." % ", ".join("%s %s" % (n, "açık" if self.wireguard_unit(n)[1] else "kapalı") for n in names)
        except (SettingsError, OSError, ValueError):
            return "Şu anki durum okunamadı; Erişim → WireGuard'ı yenileyin."

    def wireguard_rollback(self, p):
        """DD-275: an opening that was not confirmed (or failed) is undone: baslat by putting the marker
        back, taking the networks down and applying the firewall; ag-ac by closing the network; ag-ekle by
        removing every network the change created. A closing action is never reopened: only the firewall
        is applied again from the files as they are."""
        import master_wireguard
        wg = p["changes"]["wireguard"]
        files = (p.get("wireguard") or {}).get("files") or {}
        action = wg["eylem"]
        if action == "baslat":
            # The marker first: from then on the firewall drops WireGuard's ports, forwarding and NAT.
            self.restore(files)
            for iface in master_wireguard.registered(self.e):
                unit = "wg-quick@%s.service" % iface
                run(["systemctl", "disable", "--now", "--quiet", unit], check=False, timeout=30)
                require(not self.wireguard_unit(iface)[1], "%s kapatılamadı." % iface)
            self.firewall_apply()
        elif action == "ag-ac":
            self.wireguard_run(p, "--if", wg["iface"], "net", "kapat")
        elif action == "ag-ekle":
            saved = files.get(self.e.get("WG_NETWORKS_FILE", ""))
            before = {n["iface"] for n in master_wireguard.parse(base64.b64decode(saved["data"]).decode())} if saved else set()
            for iface in master_wireguard.registered(self.e):
                if iface not in before:
                    self.wireguard_run(p, "net-remove", iface, "--onay")
            self.restore(files)
            self.firewall_apply()
        else:
            self.firewall_apply()

    def publish(self):
        """master_shares.Manager.publish (the access projection) under its contract: this worker holds install.lock,
        the share lock is taken here around the call (its other holders hold install.lock too, so it is free)."""
        import master_shares
        with open(Path(self.e["RUNTIME_DIR"]) / "paylasim.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as err:
                raise SettingsBusy("Paylaşım işlemi sürüyor; biraz sonra yeniden deneyin.") from err
            shares = master_shares.Manager(self.state)
            try:
                shares.publish()
            except master_shares.ShareError as err:
                raise SettingsError(str(err)) from err
            return shares

    def https_apply(self, name=None, service="paylasim"):
        import master_https
        import master_shares
        shares = self.publish()
        if not name:
            return
        # Without the listener the certificate wait can only time out after a
        # minute with a DNS/CAA hint; report the actual cause instead (DD-193).
        import master_publications
        try:
            if service == master_publications.PANEL_ID:
                require(master_publications.panel_active(self.e),
                        "Panel internet yayını açılamadı; Konsol hesabını ve sunucunun WAN IPv4 adresini kontrol edin.")
            elif not shares.wan_active():
                raise SettingsError(shares.wan_info()["reason"] or
                                    "WAN HTTPS dinleyicisi açılamadı; paylaşım servisini ve WAN adresini kontrol edin.")
        except master_shares.ShareError as err:
            raise SettingsError(str(err)) from err
        master_https.wait_certificate(self.e, name)

    # -- rebuild phase 4: an access row of an application (the "erisim" section)
    def container_manager(self):
        """The container worker's Manager in this process (row_files, row_change, row_restore)."""
        import master_container_worker
        return master_container_worker.Manager(self.state)

    def container_call(self, method, *args):
        import master_applications as apps
        try:
            return getattr(self.container_manager(), method)(*args)
        except apps.AppError as err:
            raise SettingsError(str(err)) from err

    def erisim_paths(self, app):
        """Every file an erisim change may change: the application's erisim.json, yerler.json and unit files
        (row_files), its two Caddy files, WebDAV's internet site (an internet name may close plaintext WebDAV) and
        the applications' DNS file."""
        import master_publications
        modules = Path(self.e["CADDY_MODULES_DIR"])
        return ([Path(name) for name in self.container_call("row_files", app)]
                + [modules / name for name in master_publications.app_files(app)]
                + [modules / "paylasim-wan.caddy", Path(master_publications.dns_path(self.e))])

    def erisim_apply(self, p):
        """The row through the container side (units, restart, ready check: row_change), then the firewall (K5 ports,
        the guard), the projection (Caddy sites, names, 443) and the certificate of a new internet name."""
        import master_https
        import master_publications
        change = p["changes"]["erisim"]
        result = self.container_call("row_change", change["uygulama"], change["anahtar"], change["sonra"])
        p["erisim"] = {"yeniden_baslatilan": list(result["yeniden_baslatilan"])}
        save_json(self.pending_path, p)
        self.firewall_apply()
        self.publish()
        name = master_publications.certificate_name(change)
        if name:
            item = next((r for r in master_publications.app_rows(self.e) if r["id"] == change["id"]), None)
            require(item is not None and master_publications.app_active(self.e, item),
                    "İnternet adı açılamadı; sunucunun WAN IPv4 adresini kontrol edin.")
            master_https.wait_certificate(self.e, name)

    def erisim_rollback(self, p):
        """Puts the snapshot back; when the row change wrote anything, the container side follows (row_restore:
        the guard, systemd and the services it restarted, every service when that is not known), then the firewall
        and the projection, and the snapshot once more (the projection's files exactly as before)."""
        change = p["changes"]["erisim"]
        restarted = (p.get("erisim") or {}).get("yeniden_baslatilan")
        files = p["files"]
        written = any(self.snapshot(Path(name)) != record for name, record in files.items())
        self.restore(files)
        if written or restarted:
            self.container_call("row_restore", change["uygulama"], restarted)
        self.firewall_apply()
        self.publish()
        self.restore(files)

    def confirm(self, data):
        p = self.pending()
        require(p and p["id"] == data.get("id") and p["phase"] == "awaiting" and p["boot"] == boot_id()
                and p["until"] > time.monotonic(), "Onay süresi dolmuş veya işlem artık geçerli değil.")
        # A fresh API request is necessary, but an established browser TCP connection
        # can survive a new-connection deny. Do not mistake that for connectivity.
        try:
            client = ipaddress.ip_address(data.get("client", ""))
        except ValueError as err:
            raise SettingsError("Yönetim istemcisinin adresi doğrulanamadı.") from err
        # DD-195: 100.64.0.0/10 is also carrier NAT space, so the Caddy site matters too:
        # a confirmation through the public Konsol address is refused.
        require((client in ipaddress.ip_network("100.64.0.0/10") or client in ipaddress.ip_network("fd7a:115c:a1e0::/48"))
                and data.get("kanal") == "tailscale", "Onay Tailscale üzerinden Konsol'dan gelmeli.")
        if p["changes"].get("domain"):
            require(data.get("host") == "panel." + p["candidate"]["domain"], "Alan adı değişikliğini yeni Konsol adresinden onaylayın.")
            self.dns_test()
            self.caddy_test()
        blocked = self.client_blocked(p["candidate"], client)
        require(not blocked, blocked)
        require("panel." + self.e["LOCAL_DOMAIN"] not in p["candidate"]["dns"]["disabled"],
                "Konsol'un kendi DNS adı kapalıyken değişiklik kalıcılaştırılamaz.")
        # Recheck validators before committing.
        if p["changes"]["dns"]:
            self.dns_test()
        require(p["until"] > time.monotonic(), "Onay süresi doldu.")
        self.commit(p)
        return {"ok": True}

    def commit(self, p):
        committed = dict(p["candidate"], _transaction=p["id"])
        save_json(self.config_path, committed)
        # A crash after the commit is recognized by guard, rather than rolling back a committed change.
        p["phase"] = "committed"
        save_json(self.pending_path, p)
        self.pending_path.unlink()

    def rollback(self, manual=False):
        p = self.pending()
        if not p:
            return {"ok": True}
        if p["phase"] == "committed" or self.config().get("_transaction") == p["id"]:
            self.pending_path.unlink()
            return {"ok": True}
        if p["phase"] == "stuck" and not manual:
            return {"ok": True}  # DD-182: waits for the operator
        p["phase"] = "rollback"
        p["attempts"] = p.get("attempts", 0) + 1
        save_json(self.pending_path, p)
        try:
            self.rollback_steps(p)
        except (SettingsError, OSError, ValueError, KeyError, TypeError) as err:
            p["error"] = str(err) if isinstance(err, SettingsError) else "Geri alma adımı tamamlanamadı."
            if p["attempts"] >= ROLLBACK_ATTEMPTS:
                p["phase"] = "stuck"
            else:
                p.update(retry_at=time.monotonic() + ROLLBACK_BACKOFF * 2 ** (p["attempts"] - 1), retry_boot=boot_id())
            save_json(self.pending_path, p)
            raise
        self.pending_path.unlink()
        return {"ok": True}

    def rollback_steps(self, p):
        if p["changes"].get("wireguard"):
            self.wireguard_rollback(p)
        if p["changes"].get("erisim"):
            self.erisim_rollback(p)
            return
        if p["changes"].get("web"):
            self.restore(p["files"])
            self.https_apply()
        self.restore(p["files"])
        if p["changes"].get("domain"):
            self.set_domain_state(p["old_domain"])
            self.domain_reload(p["files_active"])
        if p["changes"]["dns"]:
            self.project_dns(self.config())
            self.dns_test()
            run(["systemctl", "restart", "dnsmasq"], timeout=20)
        if p["changes"]["firewall"]:
            self.firewall_apply()

    def discard(self, data):
        """DD-182: stop a stuck rollback. Files stay as they are now; the installer re-applies
        the saved (confirmed) settings. Only for "stuck", only with the typed word."""
        p = self.pending()
        require(p and p["id"] == data.get("id") and p["phase"] == "stuck", "Bırakılacak takılmış bir işlem yok.")
        require(str(data.get("confirm", "")).strip().lower() == CONFIRM_WORD, "Bırakmak için onayla yazın.")
        self.pending_path.unlink()
        return {"ok": True}

    def guard(self):
        p = self.pending()
        if not p or p["phase"] == "stuck":
            return {"ok": True}
        if p["phase"] == "rollback" and p.get("retry_boot") == boot_id() and p.get("retry_at", 0) > time.monotonic():
            return {"ok": True}  # DD-182: backoff between automatic attempts
        if p["phase"] in ("rollback", "committed") or p["boot"] != boot_id() or p["until"] <= time.monotonic():
            return self.rollback()
        return {"ok": True}


def guard_idle(p):
    """Nothing for the timer to do: no pending change, or a stuck rollback (DD-182)."""
    return not p or p["phase"] == "stuck"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default=os.environ.get("STATE_FILE", "/etc/master-stack/state.env"))
    parser.add_argument("action", choices=("apply", "confirm", "rollback", "discard", "guard", "rules", "tailnet-ports", "project-dns", "filter-dns", "dns-enabled", "dns-forward", "status", "saved-domain"))
    parser.add_argument("value", nargs="?")
    parser.add_argument("wan", nargs="?")
    args = parser.parse_args()
    try:
        if args.action == "saved-domain":
            print(saved_domain(args.value))
            return
        m = Manager(args.state)
        if args.action == "tailnet-ports":
            for row in tailnet_ports(m.e):
                print(row["family"], row["proto"], row["port"])
            return
        if args.action == "guard" and guard_idle(m.pending()):
            # Re-check under the locks: an apply holds them from starting the timer
            # until its pending file exists, so a timer stopped here is never needed.
            with m.locked():
                if guard_idle(m.pending()):
                    run(["systemctl", "stop", "--no-block", GUARD_TIMER], check=False)
                    return
        if args.action == "rules":
            for rule in m.rules(int(args.value), args.wan):
                print(shlex.join(rule))
            return
        if args.action == "project-dns":
            m.project_dns()
            return
        if args.action == "filter-dns":
            path = Path(args.value)
            atomic(path, m.filter_dns(path.read_text()), 0o644)
            return
        if args.action == "dns-enabled":
            sys.exit(0 if args.value not in m.current()["dns"]["disabled"] else 1)
        if args.action == "dns-forward":
            sys.exit(0 if m.current()["dns"]["forward"] else 1)
        if args.action == "status":
            print(json.dumps(m.status(), ensure_ascii=False))
            return
        with m.locked():
            if args.action in ("apply", "confirm", "rollback", "discard"):
                raw = sys.stdin.read(LIMIT + 1)
                require(len(raw) <= LIMIT, "İstek çok büyük.")
                data = json.loads(raw)
                require(isinstance(data, dict), "İstek gövdesi JSON nesnesi olmalı.")
                if args.action == "rollback":
                    require(not m.pending() or m.pending()["id"] == data.get("id"), "Geri alınacak işlem artık geçerli değil.")
                    result = m.rollback(manual=True)
                else:
                    result = getattr(m, args.action)(data)
            else:
                result = getattr(m, args.action)()
        print(json.dumps(result, ensure_ascii=False))
    except (SettingsError, ValueError, KeyError, TypeError, OSError, RecursionError) as err:
        if args.action == "guard" and isinstance(err, SettingsBusy):
            return
        message = str(err) if isinstance(err, SettingsError) else "Ayar işlemi tamamlanamadı; sunucu yapılandırmasını denetleyin."
        print(json.dumps({"error": message}, ensure_ascii=False))
        if args.action == "guard":
            print(message, file=sys.stderr)
        sys.exit(STALE_EXIT if isinstance(err, SettingsStale) else 1)


if __name__ == "__main__":
    # Imported helpers must share this worker's exception classes. Loading a
    # second copy as master_settings made validation errors escape as tracebacks.
    sys.modules["master_settings"] = sys.modules[__name__]
    main()
