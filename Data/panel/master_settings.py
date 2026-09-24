#!/usr/bin/env python3
"""Konsol settings transactions (DD-156), Python stdlib only.

The HTTP process only reads here. Mutations run in an independent systemd unit,
with JSON on stdin, and share the install/module locks. A permanent systemd
timer recovers incomplete transactions, including after a reboot. No shell input.
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
import pwd
import re
import secrets
import shlex
import stat
import subprocess
import sys
import time

LIMIT = 65536
OFF = "# konsol-off: "
DEFAULT = {"firewall": [], "dns": {"disabled": [], "records": [], "forward": False, "servers": []}}
DOMAIN_RE = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"


class SettingsError(Exception):
    pass


class SettingsBusy(SettingsError):
    pass


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
    except (ValueError, OSError) as err:
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
        p = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout,
                           env=dict({"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C.UTF-8"}, **(env or {})))
    except (OSError, subprocess.TimeoutExpired) as err:
        raise SettingsError("Komut tamamlanamadı: " + Path(argv[0]).name) from err
    # Never copy command output into errors: qBittorrent may print credentials.
    require(not check or p.returncode == 0, "Doğrulama/uygulama başarısız: " + Path(argv[0]).name)
    return p


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def ini_values(text):
    section, out = "", {}
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif "=" in line and not line.startswith(("#", ";")):
            k, _, v = line.partition("=")
            out[(section, k)] = v.strip('"').replace("\\\\", "\\")
    return out


def ini_patch(text, updates):
    """Change only selected keys, preserving unrelated qBittorrent settings."""
    remaining, section, out = dict(updates), "", []
    def finish():
        for (sec, key), value in list(remaining.items()):
            if sec == section:
                out.append(key + "=" + value)
                del remaining[(sec, key)]
    seen = set()
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            finish()
            section = line[1:-1]
        key = (section, line.partition("=")[0])
        if "=" in line and key in updates:
            if key not in seen:
                out.append(key[1] + "=" + updates[key])
                seen.add(key)
                remaining.pop(key, None)
        else:
            out.append(line)
    finish()
    for sec in dict.fromkeys(k[0] for k in remaining):
        out.extend(["", "[" + sec + "]"])
        out.extend(k + "=" + v for (s, k), v in remaining.items() if s == sec)
    return "\n".join(out) + "\n"


def password_hash(password):
    # qBittorrent Utils::Password::PBKDF2 (4.6/5.x): SHA512, 100000, salt16/key64.
    salt = secrets.token_bytes(16)
    key = hashlib.pbkdf2_hmac("sha512", password.encode("utf-8"), salt, 100000, 64)
    return "@ByteArray(%s:%s)" % (base64.b64encode(salt).decode(), base64.b64encode(key).decode())


class Manager:
    def __init__(self, state):
        self.state = str(state)
        self.e = env_read(state)
        self.config_path = Path(self.e["SETTINGS_FILE"])
        self.pending_path = Path(self.e["SETTINGS_PENDING_FILE"])
        self.dns_file = Path(self.e["SETTINGS_DNS_FILE"])
        self.qconf = Path(self.e["TORRENT_PROFILE_DIR"]) / "qBittorrent/qBittorrent.conf"
        self.qdrop = Path(self.e["UNIT_DIR"]) / "qbittorrent-nox@.service.d/90-konsol.conf"

    def config(self):
        config = read_json(self.config_path, DEFAULT)
        # An upgrade retires the built-in health name. Do not keep an invisible
        # disabled entry that would make later DNS drafts fail validation.
        retired = "health." + self.e["LOCAL_DOMAIN"]
        if retired in config["dns"]["disabled"] and not any(n["name"] == retired for n in self.dns_names()):
            config["dns"]["disabled"].remove(retired)
        return config

    def pending(self):
        return read_json(self.pending_path, None)

    def current(self):
        p = self.pending()
        if p and p["boot"] == boot_id() and time.monotonic() < p["until"] and p["phase"] != "rollback":
            return p["candidate"]
        return self.config()

    def revision(self):
        h = hashlib.sha256(json.dumps(self.config(), sort_keys=True).encode())
        # Detect changes from qBittorrent itself, installer and module lifecycle too.
        for path in [Path(self.state), self.qconf, self.qdrop, Path(self.e["WG_NETWORKS_FILE"]),
                     Path(self.e["MODULES_FILE"]), self.dns_file, *self.dns_paths(), *self.domain_paths()]:
            try:
                s = path.stat()
                h.update((str(path) + str(s.st_mtime_ns) + str(s.st_size)).encode())
            except FileNotFoundError:
                pass
        return h.hexdigest()

    @contextlib.contextmanager
    def locked(self):
        with contextlib.ExitStack() as stack:
            for name in ("install.lock", "modul.lock", "settings.lock", "state.lock"):
                path = Path(self.e["RUNTIME_DIR"]) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                f = stack.enter_context(open(path, "a"))
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as err:
                    raise SettingsBusy("Kurulum/modül/ayar işlemi sürüyor; biraz sonra yeniden deneyin.") from err
            yield

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
                    name, _, iface = line.partition("=")[2].partition(",")
                    names.append({"name": name, "target": "tailscale", "source": source, "iface": iface})
        return names

    def validate(self, data):
        require(isinstance(data, dict) and set(data) <= {"revision", "firewall", "dns", "torrent", "domain"}, "Bilinmeyen ayar alanı.")
        require(data.get("revision") == self.revision(), "Ayarlar değişmiş. Yenileyip yeniden inceleyin.")
        c = self.config()
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
            for r in rules:
                require(isinstance(r, dict) and set(r) == {"id", "name", "family", "scope", "proto", "port", "source", "allow"}, "Kural biçimi geçersiz.")
                require(isinstance(r["id"], str) and re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", r["id"]), "Kural kimliği geçersiz.")
                require(r["id"] not in seen, "Tekrar eden kural kimliği.")
                seen.add(r["id"])
                require(isinstance(r["name"], str) and 1 <= len(r["name"]) <= 64 and r["name"].isprintable(), "Kural adı geçersiz.")
                require(type(r["family"]) is int and r["family"] in (4, 6), "IPv4 veya IPv6 seçin.")
                require(r["scope"] in ("wan", "tail") or bool(re.fullmatch(r"wg[0-9]", str(r["scope"]))), "Kapsam geçersiz.")
                if r["scope"].startswith("wg"):
                    nets = Path(self.e["WG_NETWORKS_FILE"])
                    require(nets.exists() and any(x.startswith(r["scope"] + "\t") for x in nets.read_text().splitlines()), "WireGuard ağı artık yok.")
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
                selectors.add(selector)
            c["firewall"] = rules
        if "dns" in data:
            d = data["dns"]
            require(isinstance(d, dict) and set(d) == {"disabled", "records", "forward", "servers"}, "DNS biçimi geçersiz.")
            require(type(d["forward"]) is bool and isinstance(d["disabled"], list) and isinstance(d["records"], list)
                    and isinstance(d["servers"], list), "DNS alanları geçersiz.")
            require(len(d["records"]) <= 100 and len(d["disabled"]) <= 200 and len(d["servers"]) <= 4, "Çok fazla DNS kaydı.")
            known = {n["name"] for n in self.dns_names()}
            reserved = set(known)
            for path in Path(self.e["MODULES_DIR"]).glob("*/dnsmasq.conf"):
                for line in path.read_text().splitlines():
                    if line.startswith("interface-name="):
                        reserved.add(line.partition("=")[2].partition(",")[0])
            managed_names = set(reserved)
            for r in d["records"]:
                require(isinstance(r, dict) and set(r) == {"name", "target", "enabled"}, "DNS kaydı biçimi geçersiz.")
                name = r["name"]
                require(isinstance(name, str) and len(name) <= 253 and name.endswith("." + self.e["LOCAL_DOMAIN"])
                        and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in name.split(".")),
                        "Kayıt yerel alan içinde, geçerli küçük harfli bir ad olmalı.")
                require(name not in reserved, "Bu DNS adı zaten tanımlı ya da bir modüle ayrılmış.")
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
        if "torrent" in data:
            q = data["torrent"]
            require(isinstance(q, dict) and set(q) <= {"username", "password", "save"} and bool(q), "qBittorrent alanı geçersiz.")
            modules = Path(self.e["MODULES_FILE"]).read_text()
            require(any(x.startswith("torrent\t") for x in modules.splitlines()) and self.qconf.is_file(), "qBittorrent kurulu değil.")
            if "username" in q:
                require(isinstance(q["username"], str) and re.fullmatch(r"[A-Za-z0-9._@-]{1,64}", q["username"]), "Kullanıcı adı geçersiz (1–64 harf/rakam/._@-).")
            if "password" in q:
                require(isinstance(q["password"], str) and 12 <= len(q["password"]) <= 256
                        and all(ord(x) >= 32 for x in q["password"]), "Parola 12–256 karakter olmalı.")
            if "save" in q:
                self.safe_dir(q["save"], writable=True)
        return c

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
        d = (config or self.current())["dns"]
        for path in self.dns_paths():
            if not path.exists():
                continue
            atomic(path, self.filter_dns(path.read_text(), config), 0o644)
        lines = ["# Konsol (DD-156); kalıcı kaynak SETTINGS_FILE."]
        for r in d["records"]:
            if r["enabled"]:
                lines.append("interface-name=" + r["name"] + "," + self.e["TAILSCALE_IF"] if r["target"] == "tailscale"
                             else "host-record=" + r["name"] + "," + r["target"])
        if d["forward"]:
            lines += ["server=" + ip for ip in d["servers"]]
        # Base local=/DOMAIN/ + no-resolv remain authoritative, even for disabled names.
        atomic(self.dns_file, "\n".join(lines) + "\n", 0o644)

    def rules(self, family, wan=None):
        out = []
        for r in self.current()["firewall"]:
            if r["family"] != family:
                continue
            iface = (wan or self.e["WAN_INTERFACE"]) if r["scope"] == "wan" else self.e["TAILSCALE_IF"] if r["scope"] == "tail" else r["scope"]
            require(bool(re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", iface)), "Arayüz adı geçersiz.")
            args = ["-i", iface, "-p", r["proto"], "--dport", str(r["port"])]
            if r["source"]:
                args += ["-s", r["source"]]
            # The core continues protecting loopback, established flows and IPv6 ICMP.
            args += ["-m", "comment", "--comment", "konsol:" + r["id"], "-j", "ACCEPT" if r["allow"] else "DROP"]
            out.append(args)
        return out

    def status(self):
        p = self.pending()
        pending = None
        if p:
            pending = {"id": p["id"], "phase": p["phase"], "seconds": max(0, int(p["until"] - time.monotonic())) if p["boot"] == boot_id() else 0}
            if p["changes"].get("domain"):
                pending["domain"] = {"old": p["old_domain"], "new": p["candidate"]["domain"]}
        q = ini_values(read_regular(self.qconf)[0].decode()) if self.qconf.exists() else {}
        return {"revision": self.revision(), "config": self.current(), "pending": pending,
                "names": self.dns_names(), "username": q.get(("Preferences", "WebUI\\Username"), "admin"),
                "save": q.get(("BitTorrent", "Session\\DefaultSavePath"), q.get(("Preferences", "Downloads\\SavePath"), "")),
                "folders": self.folders()}

    def q_unit(self):
        user = pwd.getpwuid(int(self.e["DOWNLOADS_UID"])).pw_name
        require(bool(re.fullmatch(r"[a-z_][a-z0-9_-]*", user)), "Servis kullanıcısı geçersiz.")
        return "qbittorrent-nox@" + user + ".service"

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
        modules = Path(self.e["MODULES_DIR"])
        paths = [*modules.glob("*/dnsmasq.conf"), *modules.glob("*/*.caddy"),
                 modules / "dosya/master-files-panel.service",
                 Path(self.e["UNIT_DIR"]) / "master-files-panel.service"]
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
                        r"(--domain=)" + old + r"(?=\s|$)"]
            for pattern in patterns:
                text = re.sub(pattern, lambda m: m[1] + new, text)
            atomic(path, text, stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
        self.set_domain_state(new)
        self.project_dns(candidate)
        self.domain_reload(self.pending()["files_active"])

    def torrent_apply(self, q):
        unit = self.q_unit()
        # Snapshot only after clean shutdown, which flushes qBittorrent's in-memory settings.
        active = run(["systemctl", "is-active", "--quiet", unit], check=False).returncode == 0
        p = self.pending()
        p["q_active"] = active
        save_json(self.pending_path, p)
        run(["systemctl", "stop", unit], timeout=25)
        p["files"][str(self.qconf)] = self.snapshot(self.qconf)
        save_json(self.pending_path, p)
        text = read_regular(self.qconf)[0].decode()
        updates = {}
        if "username" in q:
            updates[("Preferences", "WebUI\\Username")] = q["username"]
        if "password" in q:
            updates[("Preferences", "WebUI\\Password_PBKDF2")] = password_hash(q["password"])
        if "save" in q:
            path = str(self.safe_dir(q["save"], writable=True)).rstrip("/") + "/"
            updates[("BitTorrent", "Session\\DefaultSavePath")] = '"' + path + '"'
            updates[("Preferences", "Downloads\\SavePath")] = '"' + path + '"'
            # Add one narrow write path. Default downloads + temp path remain available.
            atomic(self.qdrop, '[Service]\nReadWritePaths="' + path.rstrip("/") + '"\n', 0o644)
            run(["systemctl", "daemon-reload"])
        atomic(self.qconf, ini_patch(text, updates), 0o640, (int(self.e["DOWNLOADS_UID"]), int(self.e["DOWNLOADS_GID"])))
        if active:
            run(["systemctl", "start", unit], timeout=25)
            run(["systemctl", "is-active", "--quiet", unit])

    def apply(self, data):
        require(not self.pending(), "Önce bekleyen işlemi onaylayın veya geri alın.")
        candidate = self.validate(data)
        change = {k: k in data for k in ("firewall", "dns", "torrent", "domain")}
        require(any(change.values()), "Değişiklik yok.")
        run(["systemctl", "is-active", "--quiet", "master-settings-guard.timer"])
        paths = ([*self.dns_paths(), self.dns_file] if change["dns"] else []) + ([self.qdrop] if change["torrent"] else [])
        files_active = False
        if change["domain"]:
            require(Path(self.e["CADDYFILE"]).is_file(), "Caddy yapılandırması bulunamadı.")
            paths += [*self.dns_paths(), self.dns_file, *self.domain_paths()]
            files_active = run(["systemctl", "is-active", "--quiet", "master-files-panel.service"], check=False).returncode == 0
        # Pending is durable BEFORE the first mutation, and the timer already runs.
        p = {"id": secrets.token_hex(16), "boot": boot_id(), "until": time.monotonic() + 180,
             "phase": "applying", "candidate": candidate, "changes": change,
             "files": {str(path): self.snapshot(path) for path in paths}, "q_active": False,
             "old_domain": self.e["LOCAL_DOMAIN"], "files_active": files_active}
        save_json(self.pending_path, p)
        try:
            if change["domain"]:
                self.domain_apply(candidate)
            if change["torrent"]:
                self.torrent_apply(data["torrent"])
            if change["dns"]:
                self.project_dns(candidate)
                self.dns_test()
                run(["systemctl", "restart", "dnsmasq"], timeout=20)
            if change["firewall"]:
                self.firewall_apply()
            p = self.pending()
            require(p["until"] > time.monotonic(), "Uygulama zaman aşımına uğradı.")
            p.update(phase="awaiting", until=time.monotonic() + (300 if change["domain"] else 60))
            save_json(self.pending_path, p)
        except Exception:
            self.rollback()
            raise
        return {"pending": self.status()["pending"]}

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
        require(client in ipaddress.ip_network("100.64.0.0/10") or client in ipaddress.ip_network("fd7a:115c:a1e0::/48"),
                "Onay Tailscale üzerinden Konsol'dan gelmeli.")
        if p["changes"].get("domain"):
            require(data.get("host") == "panel." + p["candidate"]["domain"], "Alan adı değişikliğini yeni Konsol adresinden onaylayın.")
            self.dns_test()
            self.caddy_test()
        for proto, port in (("tcp", self.e["CADDY_HTTP_PORT"]), ("udp", self.e["DNS_PORT"]), ("tcp", self.e["DNS_PORT"])):
            for r in p["candidate"]["firewall"]:
                if (r["scope"] == "tail" and r["family"] == client.version and r["proto"] == proto and r["port"] == int(port)
                        and (not r["source"] or client in ipaddress.ip_network(r["source"]))):
                    require(r["allow"], "Bu kural yeni Konsol/DNS bağlantınızı engelliyor; geri alın veya sürenin dolmasını bekleyin.")
                    break
        require("panel." + self.e["LOCAL_DOMAIN"] not in p["candidate"]["dns"]["disabled"],
                "Konsol'un kendi DNS adı kapalıyken değişiklik kalıcılaştırılamaz.")
        # Recheck validators before committing.
        if p["changes"]["dns"]:
            self.dns_test()
        require(p["until"] > time.monotonic(), "Onay süresi doldu.")
        committed = dict(p["candidate"], _transaction=p["id"])
        save_json(self.config_path, committed)
        # A crash after the commit is recognized by guard, rather than rolling back a committed change.
        p["phase"] = "committed"
        save_json(self.pending_path, p)
        self.pending_path.unlink()
        return {"ok": True}

    def rollback(self):
        p = self.pending()
        if not p:
            return {"ok": True}
        if p["phase"] == "committed" or self.config().get("_transaction") == p["id"]:
            self.pending_path.unlink()
            return {"ok": True}
        p["phase"] = "rollback"
        save_json(self.pending_path, p)
        if p["changes"]["torrent"]:
            run(["systemctl", "stop", self.q_unit()], timeout=25)
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
        if p["changes"]["torrent"]:
            run(["systemctl", "daemon-reload"])
            if p["q_active"]:
                run(["systemctl", "start", self.q_unit()], timeout=25)
        self.pending_path.unlink()
        return {"ok": True}

    def guard(self):
        p = self.pending()
        if p and (p["phase"] in ("rollback", "committed") or p["boot"] != boot_id() or p["until"] <= time.monotonic()):
            return self.rollback()
        return {"ok": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default=os.environ.get("STATE_FILE", "/etc/master-stack/state.env"))
    parser.add_argument("action", choices=("apply", "confirm", "rollback", "guard", "rules", "project-dns", "filter-dns", "dns-enabled", "dns-forward", "pending", "status", "saved-domain"))
    parser.add_argument("value", nargs="?")
    parser.add_argument("wan", nargs="?")
    args = parser.parse_args()
    try:
        if args.action == "saved-domain":
            print(saved_domain(args.value))
            return
        m = Manager(args.state)
        if args.action == "guard" and not m.pending():
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
        if args.action == "pending":
            sys.exit(0 if m.pending() else 1)
        if args.action == "status":
            print(json.dumps(m.status(), ensure_ascii=False))
            return
        with m.locked():
            if args.action in ("apply", "confirm", "rollback"):
                raw = sys.stdin.read(LIMIT + 1)
                require(len(raw) <= LIMIT, "İstek çok büyük.")
                data = json.loads(raw)
                if args.action == "rollback":
                    require(not m.pending() or m.pending()["id"] == data.get("id"), "Geri alınacak işlem artık geçerli değil.")
                    result = m.rollback()
                else:
                    result = getattr(m, args.action)(data)
            else:
                result = getattr(m, args.action)()
        print(json.dumps(result, ensure_ascii=False))
    except (SettingsError, ValueError, KeyError, TypeError, OSError) as err:
        if args.action == "guard" and isinstance(err, SettingsBusy):
            return
        message = str(err) if isinstance(err, SettingsError) else "Ayar işlemi tamamlanamadı; sunucu yapılandırmasını denetleyin."
        print(json.dumps({"error": message}, ensure_ascii=False))
        if args.action == "guard":
            print(message, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
