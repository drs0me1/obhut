#!/usr/bin/env python3
"""A Compose file read into Obhut's application model (rebuild DD-271, phase 2). Standard library only.

read(docs) takes the documents master_yaml.load_all returned for a Compose file and returns the model
that both readers share (master_kube reads Kubernetes YAML into the same shape), with its refusals and
notes. Strings stay as written: Compose interpolation (${VAR}, ${VAR:-d}, ${VAR-d}, ${VAR:?m}, ${VAR?m},
$VAR and the literal $$) is listed in "variables" and applied only by the inspector, once the operator
has answered (substitute). Anything this reader does not know is a refusal naming its key and line,
never skipped (rebuild.md §2.4, §4.2); x- keys are ignored with a note (A3).

The parts both readers use live here: the findings, the capability set, the rule for host paths, names
and folders. Nothing here writes, runs or fetches anything.
"""
import posixpath
import re
import shlex

# Podman's default capability set; a file may add only these (rebuild.md §4.2, A4).
DEFAULT_CAPS = ("CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "NET_BIND_SERVICE", "SETFCAP", "SETGID",
                "SETPCAP", "SETUID", "SYS_CHROOT")
# Host paths never mounted, with everything under them; the sockets of container engines anywhere.
SYSTEM_PATHS = ("/", "/etc", "/proc", "/sys", "/dev", "/boot", "/root", "/usr", "/bin", "/sbin", "/lib", "/lib32",
                "/lib64", "/libx32", "/run", "/var/run", "/var/lib/containers", "/var/lib/docker",
                "/var/lib/master-stack", "/etc/master-stack")
ENGINE_SOCKETS = ("docker.sock", "podman.sock", "containerd.sock")
RESTARTS = ("no", "always", "on-failure", "unless-stopped")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,62}\Z")
ENV_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]{0,254}\Z")
VAR_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
DURATION_RE = re.compile(r"(?:(?:[0-9]+(?:\.[0-9]+)?(?:ns|us|µs|ms|s|m|h))+|0)\Z")
HOSTNAME_RE = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\Z")
# Sizes as Docker reads them (go-units RAMInBytes): every unit binary, b/k/m/g/t/p with an optional i and b.
SIZE_RE = re.compile(r"([0-9]{1,15}(?:\.[0-9]{1,6})?)([kmgtp]?)(?:i?b)?\Z", re.I)
CPUS_RE = re.compile(r"[0-9]{1,6}(?:\.[0-9]{1,6})?\Z")
ULIMITS = ("as", "core", "cpu", "data", "fsize", "locks", "memlock", "msgqueue", "nice", "nofile", "nproc", "rss",
           "rtprio", "rttime", "sigpending", "stack")
NO_NEW_PRIVILEGES = ("no-new-privileges", "no-new-privileges:true", "no-new-privileges=true")
USER_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,31})?\Z")
SIGNAL_RE = re.compile(r"(?:(?:SIG)?[A-Z][A-Z0-9]{1,11}(?:[+-][0-9]{1,2})?|[0-9]{1,2})\Z")
# Podman's own labels steer Podman itself (io.containers.autoupdate would update an image unasked, DD-214).
PODMAN_LABELS = ("io.containers.", "io.podman.", "PODMAN_")
SHELL_CHARS = frozenset("|&;<>()`\n")
_TR = str.maketrans("çğıöşüÇĞİÖŞÜâîûÂÎÛ", "cgiosucgiosuaiuaiu")

TOP_REFUSED = {
    "secrets": "Compose secret dosyaları desteklenmez; gizli değerleri ${DEĞİŞKEN} ile yazın, denetçi sorar.",
    "configs": "Compose config dosyaları desteklenmez.",
    "include": "Başka bir Compose dosyasını içeren dosya desteklenmez; her şey tek dosyada olmalı.",
}
SERVICE_REFUSED = {
    "build": "Sunucuda imaj derlenmez; hazır bir imaj (image) gerekir.",
    "extends": "Başka bir dosyaya ya da servise dayanan servis desteklenmez.",
    "env_file": "Sunucuda okunacak ayrı bir dosya yok; değişkenleri dosyaya yazın ya da ${…} ile sorulsun.",
    "secrets": "Compose secret dosyaları desteklenmez; gizli değerleri ${DEĞİŞKEN} ile yazın, denetçi sorar.",
    "configs": "Compose config dosyaları desteklenmez.",
    "profiles": "Profiller desteklenmez; dosyada yalnız kurulacak servisler olmalı.",
    "privileged": "Ayrıcalıklı konteyner sunucunun tamamına erişir; Obhut bunu hiçbir uygulamaya vermez.",
    "network_mode": "Konteyner sunucunun ya da başka bir konteynerin ağını paylaşamaz; her uygulama kendi köprü ağında çalışır.",
    "pid": "Konteyner sunucunun ya da başka bir konteynerin süreç alanını paylaşamaz.",
    "ipc": "Konteyner sunucunun ya da başka bir konteynerin paylaşılan belleğini kullanamaz.",
    "devices": "Sunucunun aygıtları konteynere verilmez.",
    "sysctls": "Çekirdek ayarları konteynerden değiştirilmez.",
    "volumes_from": "Başka bir konteynerin bağlamaları alınmaz; klasörleri volumes ile yazın.",
    "dns": "Konteynerin ad sunucusunu Obhut verir; dns desteklenmez.",
    "dns_search": "Konteynerin ad arama alanlarını Obhut verir; dns_search desteklenmez.",
    "extra_hosts": "Konteynerin hosts dosyasına satır eklenmez; servislere adlarıyla ulaşılır.",
    "group_add": "Konteynere ek grup verilmez; klasör izinleri Dosyalar hesabıyla çalışır.",
    "links": "Eski bağlantı biçimi (links) desteklenmez; servislere adlarıyla ulaşılır.",
    "external_links": "Uygulamanın dışındaki konteynerlere bağlanılmaz.",
    "domainname": "Konteynerin alan adını Obhut verir; domainname desteklenmez.",
    "mac_address": "Konteynerin donanım adresini Obhut verir; mac_address desteklenmez.",
}
SERVICE_IGNORED = {
    "container_name": "Konteynerin adını Obhut verir; yok sayılır.",
    "expose": "Yalnız uygulamanın kendi ağında görünür, dışarıya açılmaz; yok sayılır.",
    "tty": "Konteyner bir uçbirime bağlanmaz; tty yok sayılır.",
    "stdin_open": "Konteyner standart girdiden okumaz; stdin_open yok sayılır.",
    "logging": "Günlükler systemd günlüğüne yazılır; logging yok sayılır.",
    "platform": "İmaj sunucunun kendi mimarisiyle çekilir; platform yok sayılır.",
    "pull_policy": "İmajı Obhut çeker ve özetine sabitler; pull_policy yok sayılır.",
}
UNKNOWN = "Desteklenmeyen anahtar: %s. Denetçi bilmediği bir satırı atlamaz."
TEXT = "%s bir metin olmalı."


class TemplateError(ValueError):
    """An interpolation the reader does not accept, or a required variable without a value."""


class Findings:
    """Refusals block the installation; notes tell what was ignored. Both carry the line (1-based)."""

    def __init__(self):
        self.refusals = []
        self.notes = []

    def refuse(self, line, key, text):
        self.refusals.append({"line": int(line or 1), "key": key, "text": text})

    def note(self, line, key, text):
        self.notes.append({"line": int(line or 1), "key": key, "text": text})


def key_line(node, key, default=1):
    lines = getattr(node, "key_lines", None) or {}
    return lines.get(key) or getattr(node, "line", 0) or default


def item_line(seq, index, default=1):
    lines = getattr(seq, "item_lines", None) or []
    return lines[index] if index < len(lines) else (getattr(seq, "line", 0) or default)


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def scalar_text(value):
    """A YAML scalar as Compose turns it into text (numbers and booleans as written), or None."""
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return None


def app_name(raw):
    """A suggested application name: lower-case [a-z0-9-], starting with a letter, at most 30 characters."""
    if not isinstance(raw, str):
        return ""
    text = re.sub(r"[^a-z0-9]+", "-", raw.translate(_TR).lower())
    text = re.sub(r"^[^a-z]+", "", text)
    return text[:30].rstrip("-")


def lower_dashed(name):
    return re.sub(r"[^a-z0-9]+", "-", str(name).translate(_TR).lower()).strip("-")


def safe_folder(name):
    """A folder name under the application's data folder: no hidden name, no separator."""
    text = re.sub(r"[^a-z0-9._-]+", "-", str(name).translate(_TR).lower()).lstrip("._-")
    return text[:63].rstrip("._-") or "veri"


def new_service(name, line, restart):
    """A service of the model with every field at its default (both readers start from it)."""
    return {"name": name, "line": line, "image": "", "image_line": line, "command": None, "entrypoint": None,
            "workdir": None, "user": None, "environment": [], "ports": [], "mounts": [], "health": None,
            "restart": restart, "depends_on": [], "caps_add": [], "caps_drop": [], "no_new_privileges": False,
            "read_only": False, "init": False, "hostname": None, "shm_size": None,
            "limits": {"cpus": None, "memory": None, "pids": None, "ulimits": {}}, "labels": {}, "stop_signal": None,
            "stop_grace": None}


def size_bytes(value):
    """Bytes for a Compose size (an integer, or 256m, 1.5g, 64MiB), else None."""
    if is_int(value):
        return value if value > 0 else None
    match = SIZE_RE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return None
    number = float(match.group(1)) * 1024 ** "bkmgtp".index((match.group(2) or "b").lower())
    return int(number) if number >= 1 else None


def cpu_count(value):
    """A CPU limit as a number above zero (0.5, "1.5"), else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    if isinstance(value, str) and not CPUS_RE.fullmatch(value):
        return None
    number = float(value)
    if not 0 < number <= 4096:
        return None
    return int(number) if number == int(number) else round(number, 3)


def capability(value):
    """CAP_NET_ADMIN, net_admin and NET_ADMIN all name NET_ADMIN; anything else is None."""
    if not isinstance(value, str):
        return None
    name = value.strip().upper()
    if name.startswith("CAP_"):
        name = name[4:]
    return name if re.fullmatch(r"[A-Z][A-Z0-9_]*", name) else None


def clean_path(path):
    return posixpath.normpath(re.sub(r"/+", "/", path))


def host_path_refusal(path):
    """Why a host path may not be mounted into a container (Turkish), or None."""
    clean = clean_path(path)
    if posixpath.basename(clean) in ENGINE_SOCKETS:
        return "bir konteyner motorunun soketi; sunucunun tamamını yönetir"
    for system in sorted(SYSTEM_PATHS, key=len, reverse=True):
        if clean == system:
            return "sunucunun kök dizini" if system == "/" else "sistem dizini %s" % system
        if system != "/" and clean.startswith(system + "/"):
            return "sistem dizini %s altında" % system
    return None


def container_path(value):
    """A container path, normalised; None when it is not absolute or climbs with '..'."""
    if not isinstance(value, str) or not value.startswith("/") or "\x00" in value:
        return None
    if ".." in value.split("/"):
        return None
    clean = clean_path(value)
    return clean if clean != "/" else None


# -- Compose interpolation (the inspector applies it after the answers)
def template_parts(text):
    """The text split into literal strings and variable references ({"name", "op", "arg"})."""
    parts, buf = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c != "$":
            buf.append(c)
            i += 1
            continue
        nxt = text[i + 1:i + 2]
        if nxt == "$":
            buf.append("$")
            i += 2
            continue
        match = VAR_NAME_RE.match(text, i + 1)
        if match:
            ref = {"name": match.group(), "op": "", "arg": None}
            i = match.end()
        elif nxt == "{":
            end = text.find("}", i + 2)
            if end < 0:
                raise TemplateError("Kapanmayan ${ var; düz $ için $$ yazın.")
            body = text[i + 2:end]
            match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?:(:-|-|:\?|\?)(.*))?", body, re.S)
            if not match:
                raise TemplateError("Desteklenmeyen değişken biçimi: ${%s}" % body[:40])
            arg = match.group(3)
            if arg is not None and ("$" in arg or "{" in arg):
                raise TemplateError("İç içe değişken desteklenmez: ${%s}" % body[:40])
            ref = {"name": match.group(1), "op": match.group(2) or "", "arg": arg}
            i = end + 1
        else:
            raise TemplateError("Geçersiz $ kullanımı; düz $ için $$ yazın.")
        if buf:
            parts.append("".join(buf))
            buf = []
        parts.append(ref)
    if buf:
        parts.append("".join(buf))
    return parts


def references(text):
    return [part for part in template_parts(text) if isinstance(part, dict)]


def substitute(text, values):
    """Compose's interpolation with the operator's values; values maps every variable to its text."""
    out = []
    for part in template_parts(text):
        if isinstance(part, str):
            out.append(part)
            continue
        value = values.get(part["name"])
        op, arg = part["op"], part["arg"]
        if op == ":-":
            out.append(value if value else arg)
        elif op == "-":
            out.append(arg if value is None else value)
        elif op in (":?", "?"):
            if value is None or value == "":
                raise TemplateError("${%s} zorunlu%s" % (part["name"], ": " + arg if arg else ""))
            out.append(value)
        else:
            out.append(value or "")
    return "".join(out)


def defaults_only(text):
    """The text with each variable at its default (or empty): what a host path would most likely be."""
    out = []
    for part in template_parts(text):
        out.append(part if isinstance(part, str) else (part["arg"] or "") if part["op"] in (":-", "-") else "")
    return "".join(out)


def split_outside_braces(text, sep=":"):
    parts, buf, depth = [], [], 0
    for c in text:
        if c == "{":
            depth += 1
        elif c == "}" and depth:
            depth -= 1
        if c == sep and not depth:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(c)
    parts.append("".join(buf))
    return parts


def needs_shell(text):
    """True when a command string uses what only a shell understands (pipes, lists, redirection)."""
    quote = None
    i = 0
    while i < len(text):
        c = text[i]
        if quote == "'":
            if c == "'":
                quote = None
        elif c == "\\":
            i += 1
        elif quote == '"':
            if c == '"':
                quote = None
            elif c == "`":
                return True
        elif c in ("'", '"'):
            quote = c
        elif c in SHELL_CHARS:
            return True
        i += 1
    return False


class _Reader:
    def __init__(self):
        self.f = Findings()
        self.variables = {}
        self.volumes = {}

    # -- variables in the strings the model keeps
    def scan(self, text, line, service, field):
        try:
            refs = references(text)
        except TemplateError as err:
            self.f.refuse(line, field, str(err))
            return False
        for ref in refs:
            entry = self.variables.get(ref["name"])
            if entry is None:
                entry = self.variables[ref["name"]] = {"name": ref["name"], "default": None, "required": False,
                                                       "line": line, "uses": []}
            if entry["default"] is None and ref["op"] in (":-", "-"):
                entry["default"] = ref["arg"]
            entry["required"] = entry["required"] or ref["op"] in (":?", "?")
            entry["uses"].append({"service": service, "field": field, "line": line})
        return True

    def fixed(self, text, line, key):
        """A string where no variable may stand (a container port or path, a duration)."""
        if "$" in text:
            self.f.refuse(line, key, "Burada değişken kullanılamaz: %s" % text[:80])
            return False
        return True

    # -- the file
    def read(self, docs):
        doc = docs[0]
        for extra in docs[1:]:
            self.f.refuse(getattr(extra, "line", 1), "---", "Compose dosyası tek belge olmalı; ikinci belge okunmaz.")
        if not isinstance(doc, dict):
            self.f.refuse(getattr(doc, "line", 1), "services", "Compose dosyası bir eşleme olmalı.")
            return self.result("", [], 1)
        name_text, name_line = None, None
        for key, value in doc.items():
            line = key_line(doc, key)
            if key in ("services", "volumes"):
                continue
            if key.startswith("x-"):
                self.f.note(line, key, "Uzantı alanı; yok sayılır.")
            elif key == "networks":
                self.f.note(line, key, "Obhut her uygulamaya kendi ağını açar; tanımlı ağlar yok sayılır.")
            elif key == "version":
                self.f.note(line, key, "Eski sürüm alanı; yok sayılır.")
            elif key == "name":
                if isinstance(value, str) and "$" not in value:
                    name_text, name_line = value, line
                else:
                    self.f.note(line, key, "Proje adı okunamadı; ad ilk servisten önerilir.")
            elif key in TOP_REFUSED:
                self.f.refuse(line, key, TOP_REFUSED[key])
            else:
                self.f.refuse(line, key, UNKNOWN % key)
        self.read_volumes(doc.get("volumes"), key_line(doc, "volumes"))
        services = []
        block = doc.get("services")
        sline = key_line(doc, "services")
        if not isinstance(block, dict) or not block:
            self.f.refuse(sline, "services", "services bir eşleme olmalı ve en az bir servis içermeli.")
        else:
            for name, spec in block.items():
                service = self.service(name, spec, key_line(block, name))
                if service is not None:
                    services.append(service)
            self.check_dependencies(services)
        # The project's name when it gives one, else the first service's.
        name = app_name(name_text)
        if not name and services:
            name, name_line = app_name(services[0]["name"]), services[0]["line"]
        return self.result(name, services, name_line or sline)

    def result(self, name, services, name_line):
        for svc in services:
            svc.pop("_targets", None)
        return {"format": "compose", "name": name, "pod": False, "services": services,
                "variables": list(self.variables.values()), "refusals": self.f.refusals, "notes": self.f.notes,
                "name_line": name_line}

    def read_volumes(self, block, line):
        if block is None:
            return
        if not isinstance(block, dict):
            self.f.refuse(line, "volumes", "volumes bir eşleme olmalı.")
            return
        for name, spec in block.items():
            vline = key_line(block, name)
            if not NAME_RE.fullmatch(name):
                self.f.refuse(vline, "volumes", "Geçersiz birim adı: %s" % name[:64])
                continue
            self.volumes[name] = vline
            if spec is None:
                continue
            if not isinstance(spec, dict):
                self.f.refuse(vline, name, "Birim tanımı bir eşleme olmalı.")
                continue
            for key, value in spec.items():
                kline = key_line(spec, key, vline)
                if key.startswith("x-"):
                    self.f.note(kline, key, "Uzantı alanı; yok sayılır.")
                elif key == "driver" and value == "local":
                    self.f.note(kline, key, "Birim uygulamanın klasöründe bir alt klasör olur; sürücü yok sayılır.")
                elif key == "external" and value is False:
                    self.f.note(kline, key, "external: false; yok sayılır.")
                elif key in ("name", "labels"):
                    self.f.note(kline, key, "Birimin klasörü anahtarın adını alır; %s yok sayılır." % key)
                elif key == "external":
                    self.f.refuse(kline, key, "Uygulamanın dışındaki bir birim kullanılamaz.")
                elif key in ("driver", "driver_opts"):
                    self.f.refuse(kline, key, "Birim sürücüsü ve seçenekleri desteklenmez; birim uygulamanın klasörüdür.")
                else:
                    self.f.refuse(kline, key, UNKNOWN % key)

    # -- one service
    def service(self, name, spec, line):
        if not NAME_RE.fullmatch(name):
            self.f.refuse(line, "services", "Geçersiz servis adı: %s (harf, rakam, '.', '_', '-')" % name[:64])
            return None
        if not isinstance(spec, dict):
            self.f.refuse(line, name, "Servis tanımı boş ya da bir eşleme değil.")
            return None
        svc = new_service(name, line, "no")
        for key, value in spec.items():
            kline = key_line(spec, key, line)
            handler = getattr(self, "s_" + key, None) if re.fullmatch(r"[a-z_]+", key) else None
            if key.startswith("x-"):
                self.f.note(kline, key, "Uzantı alanı; yok sayılır.")
            elif key == "privileged" and value is False:
                self.f.note(kline, key, "privileged: false; konteyner zaten ayrıcalıksız.")
            elif key in SERVICE_REFUSED:
                self.f.refuse(kline, key, SERVICE_REFUSED[key])
            elif key in SERVICE_IGNORED:
                self.f.note(kline, key, SERVICE_IGNORED[key])
            elif handler is not None:
                handler(svc, value, kline)
            else:
                self.f.refuse(kline, key, UNKNOWN % key)
        self.finish(svc, spec)
        return svc

    def finish(self, svc, spec):
        """What only the whole service shows: deploy's restart policy against restart, a capability both
        added and dropped."""
        deploy = svc.pop("_deploy_restart", None)
        if deploy is not None:
            restart, line = deploy
            if "restart" in spec and svc["restart"] != restart:
                self.f.refuse(line, "restart_policy", "restart ile deploy.restart_policy farklı; yalnız birini yazın.")
            svc["restart"] = restart
        both = [c for c in svc["caps_add"] if c in svc["caps_drop"]]
        if both:
            self.f.refuse(key_line(spec, "cap_drop", svc["line"]), "cap_drop",
                          "Aynı yetenek hem ekleniyor hem düşürülüyor: %s" % ", ".join(both))
        svc.pop("_limit_lines", None)

    def s_image(self, svc, value, line):
        svc["image_line"] = line
        if not isinstance(value, str) or not value.strip() or re.search(r"\s", value):
            self.f.refuse(line, "image", "image bir imaj adı olmalı (boşluksuz metin).")
            return
        if self.scan(value, line, svc["name"], "image"):
            svc["image"] = value

    def s_command(self, svc, value, line):
        svc["command"] = self.words(value, line, svc["name"], "command")

    def s_entrypoint(self, svc, value, line):
        svc["entrypoint"] = self.words(value, line, svc["name"], "entrypoint")

    def words(self, value, line, service, key):
        if value is None:
            return None
        if isinstance(value, str):
            if not self.scan(value, line, service, key):
                return None
            if needs_shell(value):
                self.f.note(line, key, "Kabuk özelliği kullanıyor; /bin/sh -c ile çalıştırılır.")
                return ["/bin/sh", "-c", value]
            try:
                return shlex.split(value)
            except ValueError:
                self.f.refuse(line, key, "Tırnaklar kapanmıyor.")
                return None
        if isinstance(value, list):
            out = []
            for i, item in enumerate(value):
                iline = item_line(value, i, line)
                text = scalar_text(item) if not isinstance(item, bool) else None
                if text is None:
                    self.f.refuse(iline, key, TEXT % key)
                    continue
                if self.scan(text, iline, service, key):
                    out.append(text)
            return out
        self.f.refuse(line, key, "%s bir metin ya da liste olmalı." % key)
        return None

    def s_working_dir(self, svc, value, line):
        if not isinstance(value, str) or not value:
            self.f.refuse(line, "working_dir", TEXT % "working_dir")
        elif "$" not in value and not value.startswith("/"):
            self.f.refuse(line, "working_dir", "working_dir mutlak bir yol olmalı.")
        elif self.scan(value, line, svc["name"], "working_dir"):
            svc["workdir"] = value

    def s_user(self, svc, value, line):
        text = scalar_text(value) if not isinstance(value, (bool, float)) else None
        if not text or ("$" not in text and not USER_RE.fullmatch(text)) or re.search(r"\s", text):
            self.f.refuse(line, "user", "user bir kullanıcı olmalı (ör. 1000 ya da 1000:1000).")
        elif self.scan(text, line, svc["name"], "user"):
            svc["user"] = text

    def s_restart(self, svc, value, line):
        if isinstance(value, str) and re.fullmatch(r"on-failure:[0-9]+", value):
            self.f.note(line, "restart", "Yeniden deneme sayısı yok sayılır; on-failure kullanılır.")
            value = "on-failure"
        if value not in RESTARTS:
            self.f.refuse(line, "restart", "restart şunlardan biri olmalı: %s." % ", ".join(RESTARTS))
            return
        svc["restart"] = value

    def s_stop_signal(self, svc, value, line):
        if not isinstance(value, str) or not SIGNAL_RE.fullmatch(value):
            self.f.refuse(line, "stop_signal", "stop_signal bir sinyal adı olmalı (ör. SIGTERM).")
            return
        svc["stop_signal"] = value

    def s_stop_grace_period(self, svc, value, line):
        svc["stop_grace"] = self.duration(value, line, "stop_grace_period")

    def duration(self, value, line, key):
        if is_int(value) and value >= 0:
            return "%ds" % value
        if isinstance(value, str) and not self.fixed(value, line, key):
            return None
        if not isinstance(value, str) or not DURATION_RE.fullmatch(value):
            self.f.refuse(line, key, "%s bir süre olmalı (ör. 30s, 1m30s)." % key)
            return None
        return value

    def s_environment(self, svc, value, line):
        seen = set()

        def add(name, text, eline, bare):
            if not ENV_NAME_RE.fullmatch(name) or (bare and not VAR_NAME_RE.fullmatch(name)):
                self.f.refuse(eline, "environment", "Geçersiz ortam değişkeni adı: %s" % name[:64])
                return
            if name in seen:
                self.f.refuse(eline, "environment", "%s iki kez yazılmış." % name)
                return
            seen.add(name)
            if self.scan(text, eline, svc["name"], "environment"):
                svc["environment"].append({"name": name, "value": text, "line": eline, "secret_ref": False,
                                           "secret_key": None})

        if value is None:
            return
        if isinstance(value, list):
            for i, item in enumerate(value):
                eline = item_line(value, i, line)
                if not isinstance(item, str):
                    self.f.refuse(eline, "environment", "Ortam değişkeni AD=değer biçiminde bir metin olmalı.")
                    continue
                name, eq, text = item.partition("=")
                add(name, text if eq else "${%s}" % name, eline, not eq)
        elif isinstance(value, dict):
            for name, item in value.items():
                eline = key_line(value, name, line)
                text = "${%s}" % name if item is None else scalar_text(item)
                if text is None:
                    self.f.refuse(eline, "environment", "%s için değer bir metin olmalı." % name[:64])
                    continue
                add(name, text, eline, item is None)
        else:
            self.f.refuse(line, "environment", "environment bir liste ya da eşleme olmalı.")

    def s_labels(self, svc, value, line):
        pairs = []
        if isinstance(value, list):
            for i, item in enumerate(value):
                lline = item_line(value, i, line)
                if not isinstance(item, str):
                    self.f.refuse(lline, "labels", "Etiket AD=değer biçiminde bir metin olmalı.")
                    continue
                key, _, text = item.partition("=")
                pairs.append((key, text, lline))
        elif isinstance(value, dict):
            for key, item in value.items():
                text = "" if item is None else scalar_text(item)
                if text is None:
                    self.f.refuse(key_line(value, key, line), "labels", "Etiket değeri bir metin olmalı.")
                    continue
                pairs.append((key, text, key_line(value, key, line)))
        elif value is not None:
            self.f.refuse(line, "labels", "labels bir liste ya da eşleme olmalı.")
        for key, text, lline in pairs:
            if not key or re.search(r"[\s=]", key) or key in svc["labels"]:
                self.f.refuse(lline, "labels", "Geçersiz ya da iki kez yazılmış etiket adı: %s" % key[:64])
            elif key.startswith(PODMAN_LABELS):
                self.f.refuse(lline, "labels", "Podman'ın kendi etiketi (%s) dosyadan verilmez." % key[:64])
            elif self.scan(text, lline, svc["name"], "labels"):
                svc["labels"][key] = text

    def s_cap_add(self, svc, value, line):
        if not isinstance(value, list):
            self.f.refuse(line, "cap_add", "cap_add bir liste olmalı.")
            return
        for i, item in enumerate(value):
            cline = item_line(value, i, line)
            name = capability(item)
            if name is None:
                self.f.refuse(cline, "cap_add", "Geçersiz yetenek adı.")
            elif name not in DEFAULT_CAPS:
                self.f.refuse(cline, "cap_add", "Varsayılan kümenin dışında bir yetenek: %s. Ağ, çekirdek ya da başka "
                                                "süreçler üzerinde yetki verir; hiçbir uygulamaya verilmez." % name)
            elif name not in svc["caps_add"]:
                svc["caps_add"].append(name)

    def s_cap_drop(self, svc, value, line):
        if not isinstance(value, list):
            self.f.refuse(line, "cap_drop", "cap_drop bir liste olmalı.")
            return
        for i, item in enumerate(value):
            cline = item_line(value, i, line)
            name = capability(item)
            if name is None or (name != "ALL" and name not in DEFAULT_CAPS):
                self.f.refuse(cline, "cap_drop", "cap_drop yalnız Podman'ın varsayılan kümesinden adlar ya da ALL alır.")
            elif name == "ALL" or "ALL" in svc["caps_drop"]:
                svc["caps_drop"] = ["ALL"]
            elif name not in svc["caps_drop"]:
                svc["caps_drop"].append(name)

    def s_security_opt(self, svc, value, line):
        if not isinstance(value, list):
            self.f.refuse(line, "security_opt", "security_opt bir liste olmalı.")
            return
        for i, item in enumerate(value):
            oline = item_line(value, i, line)
            if isinstance(item, str) and item.strip() in NO_NEW_PRIVILEGES:
                svc["no_new_privileges"] = True
                self.f.note(oline, "security_opt", "Yeni yetki kazanma kapalı (no-new-privileges).")
            else:
                self.f.refuse(oline, "security_opt", "Yalnız no-new-privileges:true okunur; seccomp, apparmor ve label "
                                                     "ayarlarını Obhut seçer.")

    def flag(self, svc, field, value, line):
        if isinstance(value, bool):
            svc[field] = value
        else:
            self.f.refuse(line, field, "%s true ya da false olmalı." % field)

    def s_init(self, svc, value, line):
        self.flag(svc, "init", value, line)

    def s_read_only(self, svc, value, line):
        self.flag(svc, "read_only", value, line)

    def s_hostname(self, svc, value, line):
        if isinstance(value, str) and HOSTNAME_RE.fullmatch(value):
            svc["hostname"] = value
        else:
            self.f.refuse(line, "hostname", "hostname bir DNS etiketi olmalı (harf, rakam ve '-', en çok 63).")

    def s_shm_size(self, svc, value, line):
        size = size_bytes(value)
        if size is None:
            self.f.refuse(line, "shm_size", "shm_size bir boyut olmalı (ör. 64m, 1g ya da bayt).")
        else:
            svc["shm_size"] = size

    def limit(self, svc, field, value, line, key):
        """One limit, which two keys (mem_limit and deploy's memory) may give only alike."""
        lines = svc.setdefault("_limit_lines", {})
        if svc["limits"][field] is not None and svc["limits"][field] != value:
            self.f.refuse(line, key, "Bu sınır satır %d'de başka bir değerle yazılmış." % lines[field])
            return
        svc["limits"][field] = value
        lines.setdefault(field, line)

    def s_mem_limit(self, svc, value, line):
        size = size_bytes(value)
        if size is None:
            self.f.refuse(line, "mem_limit", "mem_limit bir boyut olmalı (ör. 512m, 1g ya da bayt).")
        else:
            self.limit(svc, "memory", size, line, "mem_limit")

    def s_cpus(self, svc, value, line):
        cpus = cpu_count(value)
        if cpus is None:
            self.f.refuse(line, "cpus", "cpus sıfırdan büyük bir sayı olmalı (ör. 0.5).")
        else:
            self.limit(svc, "cpus", cpus, line, "cpus")

    def s_pids_limit(self, svc, value, line):
        if is_int(value) and value in (0, -1):
            self.f.note(line, "pids_limit", "pids_limit sınırsız; yok sayılır.")
        elif is_int(value) and value > 0:
            self.limit(svc, "pids", value, line, "pids_limit")
        else:
            self.f.refuse(line, "pids_limit", "pids_limit bir sayı olmalı.")

    def s_ulimits(self, svc, value, line):
        if not isinstance(value, dict):
            self.f.refuse(line, "ulimits", "ulimits bir eşleme olmalı.")
            return
        for name, item in value.items():
            uline = key_line(value, name, line)
            if name not in ULIMITS:
                self.f.refuse(uline, "ulimits", "Bilinmeyen sınır: %s" % name[:40])
                continue
            if is_int(item):
                soft = hard = item
            elif isinstance(item, dict) and set(item) == {"soft", "hard"} and is_int(item["soft"]) and is_int(item["hard"]):
                soft, hard = item["soft"], item["hard"]
            else:
                self.f.refuse(uline, "ulimits", "%s bir sayı ya da soft ve hard sayıları olmalı." % name)
                continue
            if soft < -1 or hard < -1 or (hard != -1 and (soft == -1 or soft > hard)):
                self.f.refuse(uline, "ulimits", "%s için soft, hard'dan büyük olamaz (-1 sınırsız)." % name)
                continue
            svc["limits"]["ulimits"][name] = {"soft": soft, "hard": hard}

    def s_deploy(self, svc, value, line):
        if not isinstance(value, dict):
            self.f.refuse(line, "deploy", "deploy bir eşleme olmalı.")
            return
        for key, item in value.items():
            kline = key_line(value, key, line)
            if key == "replicas":
                if item != 1 or isinstance(item, bool):
                    self.f.refuse(kline, key, "Servis tek kopya (replicas: 1) olmalı; bir uygulama bir kez çalışır.")
            elif key == "resources":
                self.deploy_resources(svc, item, kline)
            elif key == "restart_policy":
                self.restart_policy(svc, item, kline)
            elif key in ("mode", "endpoint_mode", "placement", "update_config", "rollback_config", "labels") \
                    or key.startswith("x-"):
                self.f.note(kline, key, "deploy.%s yok sayılır." % key)
            else:
                self.f.refuse(kline, key, UNKNOWN % ("deploy." + key))

    def deploy_resources(self, svc, value, line):
        if not isinstance(value, dict):
            self.f.refuse(line, "resources", "resources bir eşleme olmalı.")
            return
        for key, item in value.items():
            kline = key_line(value, key, line)
            if key == "reservations" or key.startswith("x-"):
                self.f.note(kline, key, "deploy.resources.%s yok sayılır." % key)
            elif key != "limits":
                self.f.refuse(kline, key, UNKNOWN % ("deploy.resources." + key))
            elif not isinstance(item, dict):
                self.f.refuse(kline, key, "limits bir eşleme olmalı.")
            else:
                for name, limit in item.items():
                    lline = key_line(item, name, kline)
                    if name == "cpus" and cpu_count(limit) is not None:
                        self.limit(svc, "cpus", cpu_count(limit), lline, name)
                    elif name == "memory" and size_bytes(limit) is not None:
                        self.limit(svc, "memory", size_bytes(limit), lline, name)
                    elif name == "pids" and is_int(limit) and limit > 0:
                        self.limit(svc, "pids", limit, lline, name)
                    elif name in ("cpus", "memory", "pids"):
                        self.f.refuse(lline, name, "deploy.resources.limits.%s okunamadı." % name)
                    else:
                        self.f.refuse(lline, name, UNKNOWN % ("deploy.resources.limits." + name))

    def restart_policy(self, svc, value, line):
        if not isinstance(value, dict):
            self.f.refuse(line, "restart_policy", "restart_policy bir eşleme olmalı.")
            return
        condition = value.get("condition", "any")
        restart = {"none": "no", "on-failure": "on-failure", "any": "always"}.get(condition) if isinstance(condition, str) else None
        if restart is None:
            self.f.refuse(key_line(value, "condition", line), "condition", "condition none, on-failure ya da any olmalı.")
            return
        for key in value:
            if key != "condition":
                self.f.note(key_line(value, key, line), key, "deploy.restart_policy.%s yok sayılır." % key)
        svc["_deploy_restart"] = (restart, line)

    def s_networks(self, svc, value, line):
        if isinstance(value, dict) and any(isinstance(v, dict) and "aliases" in v for v in value.values()):
            self.f.refuse(line, "networks", "Ağ takma adları desteklenmez; servislere adlarıyla ulaşılır.")
            return
        self.f.note(line, "networks", "Servis uygulamanın tek ağına bağlanır; tanımlı ağlar yok sayılır.")

    def s_depends_on(self, svc, value, line):
        items = []
        if isinstance(value, list):
            for i, item in enumerate(value):
                items.append((item, None, item_line(value, i, line)))
        elif isinstance(value, dict):
            for name, spec in value.items():
                items.append((name, spec, key_line(value, name, line)))
        else:
            self.f.refuse(line, "depends_on", "depends_on bir liste ya da eşleme olmalı.")
            return
        seen = set()
        for name, spec, dline in items:
            if not isinstance(name, str) or not name:
                self.f.refuse(dline, "depends_on", "Bağımlılık bir servis adı olmalı.")
                continue
            condition = "started"
            if isinstance(spec, dict):
                for key, item in spec.items():
                    kline = key_line(spec, key, dline)
                    if key == "condition":
                        if item == "service_started":
                            condition = "started"
                        elif item == "service_healthy":
                            condition = "healthy"
                        elif item == "service_completed_successfully":
                            self.f.refuse(kline, "condition", "Bir kez çalışıp biten servisi bekleme desteklenmez.")
                        else:
                            self.f.refuse(kline, "condition", "Bilinmeyen bekleme koşulu.")
                    elif key in ("restart", "required") or key.startswith("x-"):
                        self.f.note(kline, key, "%s yok sayılır." % key)
                    else:
                        self.f.refuse(kline, key, UNKNOWN % key)
            elif spec is not None:
                self.f.refuse(dline, "depends_on", "Bağımlılık tanımı bir eşleme olmalı.")
            if name in seen:
                self.f.refuse(dline, "depends_on", "%s iki kez yazılmış." % name[:64])
                continue
            seen.add(name)
            svc["depends_on"].append({"service": name, "condition": condition, "line": dline})

    def check_dependencies(self, services):
        names = {s["name"] for s in services}
        for svc in services:
            for dep in svc["depends_on"]:
                if dep["service"] == svc["name"]:
                    self.f.refuse(dep["line"], "depends_on", "Servis kendine bağımlı olamaz.")
                elif dep["service"] not in names:
                    self.f.refuse(dep["line"], "depends_on", "Tanımlı olmayan servis: %s" % dep["service"][:64])
        # A start order exists unless the dependencies form a cycle (Kahn's algorithm, no recursion).
        waits = {s["name"]: {d["service"] for d in s["depends_on"] if d["service"] in names and d["service"] != s["name"]}
                 for s in services}
        dependents = {}
        for name, deps in waits.items():
            for dep in deps:
                dependents.setdefault(dep, []).append(name)
        ready = [name for name, deps in waits.items() if not deps]
        done = set()
        while ready:
            name = ready.pop()
            done.add(name)
            for other in dependents.get(name, ()):
                waits[other].discard(name)
                if not waits[other] and other not in done:
                    ready.append(other)
        looping = [s for s in services if s["name"] not in done]
        if looping:
            self.f.refuse(looping[0]["line"], "depends_on",
                          "Servisler birbirini bekliyor (döngü); başlatma sırası çıkarılamaz.")
        for svc in services:
            for dep in svc["depends_on"]:
                dep.pop("line", None)

    def s_healthcheck(self, svc, value, line):
        if not isinstance(value, dict):
            self.f.refuse(line, "healthcheck", "healthcheck bir eşleme olmalı.")
            return
        health = {"test": [], "interval": None, "timeout": None, "retries": None, "start_period": None}
        disabled = False
        for key, item in value.items():
            kline = key_line(value, key, line)
            if key == "test":
                test = self.health_test(item, kline, svc["name"])
                if test is None:
                    continue
                if test[0] == "NONE":
                    disabled = True
                else:
                    health["test"] = test
            elif key in ("interval", "timeout", "start_period"):
                health[key] = self.duration(item, kline, key)
            elif key == "retries":
                if is_int(item) and item >= 0:
                    health["retries"] = item
                else:
                    self.f.refuse(kline, key, "retries bir sayı olmalı.")
            elif key == "disable":
                if not isinstance(item, bool):
                    self.f.refuse(kline, key, "disable true ya da false olmalı.")
                disabled = disabled or item is True
            elif key == "start_interval" or key.startswith("x-"):
                self.f.note(kline, key, "%s yok sayılır." % key)
            else:
                self.f.refuse(kline, key, UNKNOWN % key)
        if disabled:
            self.f.note(line, "healthcheck", "Sağlık denetimi kapalı.")
            return
        if not health["test"]:
            self.f.note(line, "healthcheck", "Denetim komutu yok; imajın kendi sağlık denetimi kullanılır.")
        svc["health"] = health

    def health_test(self, value, line, service):
        if isinstance(value, str):
            return ["CMD-SHELL", value] if self.scan(value, line, service, "healthcheck") else None
        if not isinstance(value, list) or not value:
            self.f.refuse(line, "test", "test bir metin ya da boş olmayan bir liste olmalı.")
            return None
        if value[0] not in ("CMD", "CMD-SHELL", "NONE") or (value[0] != "NONE" and len(value) < 2):
            self.f.refuse(line, "test", "test listesi CMD ya da CMD-SHELL ve bir komutla ya da NONE ile başlamalı.")
            return None
        out = []
        for i, item in enumerate(value):
            text = scalar_text(item) if not isinstance(item, bool) else None
            iline = item_line(value, i, line)
            if text is None:
                self.f.refuse(iline, "test", TEXT % "test")
                return None
            if not self.scan(text, iline, service, "healthcheck"):
                return None
            out.append(text)
        return out

    # -- ports
    def s_ports(self, svc, value, line):
        if not isinstance(value, list):
            self.f.refuse(line, "ports", "ports bir liste olmalı.")
            return
        for i, item in enumerate(value):
            pline = item_line(value, i, line)
            if is_int(item):
                self.port_short(svc, str(item), pline)
            elif isinstance(item, str):
                self.port_short(svc, item, pline)
            elif isinstance(item, dict):
                self.port_long(svc, item, pline)
            else:
                self.f.refuse(pline, "ports", "Port bir metin, sayı ya da eşleme olmalı.")

    def port_number(self, text, line):
        if re.fullmatch(r"[0-9]+-[0-9]+", text):
            self.f.refuse(line, "ports", "Port aralığı desteklenmez; her portu ayrı yazın.")
            return None
        if not re.fullmatch(r"[0-9]{1,5}", text) or not 0 < int(text) < 65536:
            self.f.refuse(line, "ports", "Geçersiz port: %s" % text[:40])
            return None
        return int(text)

    def add_port(self, svc, port, protocol, host_port, line, ignored):
        svc["ports"].append({"port": port, "protocol": protocol, "host_port": host_port, "line": line})
        if ignored:
            self.f.note(line, "ports", "Dosyadaki sunucu tarafı (%s) kullanılmaz; port Erişim'den açılır." % ignored)

    def port_short(self, svc, text, line):
        main, protocol = text, "tcp"
        if "/" in text:
            main, _, protocol = text.rpartition("/")
            protocol = protocol.lower()
        if protocol not in ("tcp", "udp"):
            self.f.refuse(line, "ports", "Yalnız tcp ve udp portları desteklenir.")
            return
        ip = None
        if main.startswith("["):
            end = main.find("]")
            if end < 0 or main[end + 1:end + 2] != ":":
                self.f.refuse(line, "ports", "Port satırı okunamadı: %s" % text[:60])
                return
            ip, parts = main[1:end], split_outside_braces(main[end + 2:])
            if len(parts) != 2:
                self.f.refuse(line, "ports", "Port satırı okunamadı: %s" % text[:60])
                return
        else:
            parts = split_outside_braces(main)
            if len(parts) == 3:
                ip, parts = parts[0], parts[1:]
            elif len(parts) not in (1, 2):
                self.f.refuse(line, "ports", "Port satırı okunamadı: %s" % text[:60])
                return
        container = parts[-1]
        if not self.fixed(container, line, "ports"):
            return
        port = self.port_number(container, line)
        if port is None:
            return
        host_port, host = None, parts[0] if len(parts) == 2 else ""
        if host and "$" not in host and re.fullmatch(r"[0-9]+-[0-9]+", host):
            self.f.refuse(line, "ports", "Port aralığı desteklenmez; her portu ayrı yazın.")
            return
        if host and "$" not in host and re.fullmatch(r"[0-9]{1,5}", host) and 0 < int(host) < 65536:
            host_port = int(host)
        ignored = ":".join(x for x in (ip, host) if x)
        self.add_port(svc, port, protocol, host_port, line, ignored)

    def port_long(self, svc, spec, line):
        target, protocol, host_port, ignored = None, "tcp", None, []
        for key, item in spec.items():
            kline = key_line(spec, key, line)
            if key == "target":
                text = scalar_text(item) if is_int(item) or isinstance(item, str) else None
                if text is None or not self.fixed(text, kline, "target"):
                    if text is None:
                        self.f.refuse(kline, key, "target bir port olmalı.")
                    return
                target = self.port_number(text, kline)
                if target is None:
                    return
            elif key == "protocol":
                if item not in ("tcp", "udp"):
                    self.f.refuse(kline, key, "Yalnız tcp ve udp portları desteklenir.")
                    return
                protocol = item
            elif key == "published":
                text = scalar_text(item) if is_int(item) or isinstance(item, str) else ""
                if text and re.fullmatch(r"[0-9]{1,5}", text) and 0 < int(text) < 65536:
                    host_port = int(text)
                ignored.append(text or "?")
            elif key == "host_ip":
                ignored.insert(0, scalar_text(item) or "?")
            elif key in ("mode", "name", "app_protocol") or key.startswith("x-"):
                self.f.note(kline, key, "%s yok sayılır." % key)
            else:
                self.f.refuse(kline, key, UNKNOWN % key)
                return
        if target is None:
            self.f.refuse(line, "ports", "Port tanımında target yok.")
            return
        self.add_port(svc, target, protocol, host_port, line, ":".join(ignored))

    # -- mounts
    def s_volumes(self, svc, value, line):
        if not isinstance(value, list):
            self.f.refuse(line, "volumes", "volumes bir liste olmalı.")
            return
        for i, item in enumerate(value):
            mline = item_line(value, i, line)
            if isinstance(item, str):
                self.volume_short(svc, item, mline)
            elif isinstance(item, dict):
                self.volume_long(svc, item, mline)
            else:
                self.f.refuse(mline, "volumes", "Bağlama bir metin ya da eşleme olmalı.")

    def target(self, svc, value, line):
        if not isinstance(value, str) or not self.fixed(value, line, "volumes"):
            if not isinstance(value, str):
                self.f.refuse(line, "volumes", "Konteynerdeki yol bir metin olmalı.")
            return None
        clean = container_path(value)
        if clean is None:
            self.f.refuse(line, "volumes", "Konteynerdeki yol mutlak olmalı, '..' içermemeli ve / olmamalı: %s" % value[:80])
            return None
        if clean in svc.setdefault("_targets", set()):
            self.f.refuse(line, "volumes", "Aynı konteyner yoluna iki bağlama: %s" % clean[:80])
            return None
        return clean

    def source_kind(self, source, line, volume_type=None):
        """(kind, source) for a mount source as written, or None when it is refused."""
        probe = source
        if "$" in source:
            try:
                probe = defaults_only(source)
            except TemplateError as err:
                self.f.refuse(line, "volumes", str(err))
                return None
            self.f.note(line, "volumes", "Kaynak bir değişkene bağlı; nereye bağlanacağını soru belirler.")
            if not probe:
                return ("absolute", source)
        if probe.startswith("/"):
            reason = host_path_refusal(probe)
            if reason:
                self.f.refuse(line, "volumes", "Bağlanamaz: %s (%s)." % (probe[:80], reason))
                return None
            return ("absolute", source)
        if probe.startswith("~"):
            self.f.refuse(line, "volumes", "Ev dizini (~) bağlanamaz.")
            return None
        if probe.startswith(".") or volume_type == "bind":
            rel = posixpath.normpath(probe)
            if rel == ".." or rel.startswith("../"):
                self.f.refuse(line, "volumes", "Göreli yol dosyanın klasöründen dışarı çıkıyor: %s" % probe[:80])
                return None
            return ("relative", source)
        if not NAME_RE.fullmatch(probe):
            self.f.refuse(line, "volumes", "Geçersiz birim adı: %s" % probe[:64])
            return None
        if probe not in self.volumes:
            self.f.refuse(line, "volumes", "Tanımlanmamış birim: %s (dosyanın volumes bölümünde yok)." % probe[:64])
            return None
        return ("named", source)

    def add_mount(self, svc, kind, source, target, read_only, line):
        svc.setdefault("_targets", set()).add(target)
        svc["mounts"].append({"kind": kind, "source": source, "target": target, "read_only": read_only, "line": line})

    def volume_short(self, svc, text, line):
        parts = split_outside_braces(text)
        if len(parts) == 1:
            target = self.target(svc, parts[0], line)
            if target is not None:
                self.f.note(line, "volumes", "Adsız birim; uygulamanın klasöründe bir alt klasör olur.")
                self.add_mount(svc, "named", "", target, False, line)
            return
        if len(parts) > 3 or not parts[0]:
            self.f.refuse(line, "volumes", "Bağlama satırı okunamadı: %s" % text[:80])
            return
        read_only = False
        if len(parts) == 3:
            for option in parts[2].split(","):
                if option in ("ro", "rw"):
                    read_only = option == "ro"
                elif option in ("z", "Z", "cached", "delegated", "consistent", "nocopy", "private", "rprivate"):
                    self.f.note(line, "volumes", "Bağlama seçeneği %s yok sayılır." % option)
                else:
                    self.f.refuse(line, "volumes", "Desteklenmeyen bağlama seçeneği: %s" % option[:40])
                    return
        kind = self.source_kind(parts[0], line)
        target = self.target(svc, parts[1], line)
        if kind is not None and target is not None:
            self.add_mount(svc, kind[0], kind[1], target, read_only, line)

    def volume_long(self, svc, spec, line):
        kind_name = spec.get("type")
        if kind_name not in ("bind", "volume", "tmpfs"):
            self.f.refuse(key_line(spec, "type", line), "type", "Bağlama türü bind, volume ya da tmpfs olmalı.")
            return
        source, target, read_only = None, None, False
        for key, item in spec.items():
            kline = key_line(spec, key, line)
            if key == "type":
                continue
            if key == "source":
                if not isinstance(item, str) or not item:
                    self.f.refuse(kline, key, TEXT % "source")
                    return
                source = item
            elif key == "target":
                target = self.target(svc, item, kline)
                if target is None:
                    return
            elif key == "read_only":
                if not isinstance(item, bool):
                    self.f.refuse(kline, key, "read_only true ya da false olmalı.")
                    return
                read_only = item
            elif key in ("bind", "volume", "tmpfs") and key == kind_name and isinstance(item, dict):
                if not self.mount_options(key, item, kline):
                    return
            elif key == "consistency" or key.startswith("x-"):
                self.f.note(kline, key, "%s yok sayılır." % key)
            else:
                self.f.refuse(kline, key, UNKNOWN % key)
                return
        if target is None:
            self.f.refuse(line, "volumes", "Bağlamada target yok.")
            return
        if kind_name == "tmpfs":
            if source is not None:
                self.f.refuse(line, "volumes", "tmpfs bağlamasının kaynağı olmaz.")
                return
            self.add_mount(svc, "tmpfs", "", target, False, line)
            return
        if source is None:
            if kind_name == "bind":
                self.f.refuse(line, "volumes", "bind bağlamasında source yok.")
                return
            self.f.note(line, "volumes", "Adsız birim; uygulamanın klasöründe bir alt klasör olur.")
            self.add_mount(svc, "named", "", target, read_only, line)
            return
        kind = self.source_kind(source, line, kind_name)
        if kind is None:
            return
        if kind_name == "volume" and kind[0] != "named":
            self.f.refuse(line, "volumes", "volume türünde kaynak bir birim adı olmalı.")
            return
        if kind_name == "bind" and kind[0] == "named":
            self.f.refuse(line, "volumes", "bind türünde kaynak bir yol olmalı.")
            return
        self.add_mount(svc, kind[0], kind[1], target, read_only, line)

    def mount_options(self, kind, spec, line):
        for key, item in spec.items():
            kline = key_line(spec, key, line)
            if kind == "bind" and key == "propagation" and item not in ("private", "rprivate"):
                self.f.refuse(kline, key, "Bağlama yayılımı (%s) desteklenmez." % scalar_text(item))
                return False
            if kind == "volume" and key == "subpath":
                self.f.refuse(kline, key, "Birimin alt yolu desteklenmez.")
                return False
            known = {"bind": ("propagation", "create_host_path", "selinux"), "volume": ("nocopy",),
                     "tmpfs": ("size", "mode")}[kind]
            if key in known or key.startswith("x-"):
                self.f.note(kline, key, "%s yok sayılır." % key)
            else:
                self.f.refuse(kline, key, UNKNOWN % key)
                return False
        return True

    def s_tmpfs(self, svc, value, line):
        items = [(value, line)] if isinstance(value, str) else \
            [(item, item_line(value, i, line)) for i, item in enumerate(value)] if isinstance(value, list) else None
        if items is None:
            self.f.refuse(line, "tmpfs", "tmpfs bir yol ya da yol listesi olmalı.")
            return
        for item, tline in items:
            if not isinstance(item, str):
                self.f.refuse(tline, "tmpfs", TEXT % "tmpfs")
                continue
            path, sep, _options = item.partition(":")
            if sep:
                self.f.note(tline, "tmpfs", "tmpfs seçenekleri yok sayılır.")
            target = self.target(svc, path, tline)
            if target is not None:
                self.add_mount(svc, "tmpfs", "", target, False, tline)


def read(docs):
    """The model of a Compose file from master_yaml.load_all's documents (empty documents left out)."""
    return _Reader().read([d for d in docs if d is not None] or [None])

