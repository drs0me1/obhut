#!/usr/bin/env python3
"""The generator (rebuild DD-271, phase 3): an application's checked definition → its Quadlet units and
everything the worker needs to place them. Pure: standard library, no I/O, no subprocess, no clock and no
randomness; the same definition and context always give the same plan.

    render(definition, context) -> plan          raises GeneratorError(text) on anything it cannot express

    context = {"app": str, "images": {service: "repo@sha256:…"}, "ports": {"<service>:<port>/<proto>": pool_port},
               "raw": {"<service>:<port>/<proto>": {"host_ip": IPv4, "host_port": port}},
               "secrets": {logical: podman_name}, "stopped": bool, "podman": (major, minor),
               "env": {KONTEYNER_BRIDGE_PREFIX, UYGULAMA_STATE_DIR, UYGULAMA_VERI_DIR, SERVER_ROOT,
                       KONTEYNER_BAGLAMA_DIR, SBIN_DIR, STATE_FILE, DOWNLOADS_UID, DOWNLOADS_GID, …}}
    plan = {"units": {file_name: text}, "environment": {service: text}, "folders": [path],
            "binds": {service: [srv_path]}, "start": [unit], "stop": [unit], "containers": {service: name},
            "network": {"name", "interface", "unit"}, "pod": None | {"name", "unit"},
            "publications": [{"service", "port", "protocol", "host_ip", "host_port"}], "needs_podman5": [reason]}

The definition is master_inspector.check's or the record's (the generator reads each port's number and
protocol only); the context is what the engine allocated (pinned digests, loopback pool ports, Podman secret
names) and its access rows (rebuild phase 4). No secret value ever reaches the generator: units name Podman
secrets, and environment holds only the plain variables. A port with a pool port (an address row, TCP only) is
published on 127.0.0.1 and that port; a port in context["raw"] (an open raw row) on its address (the Tailscale
or WAN IPv4) and host port, with its protocol; any other port publishes nothing. A Kubernetes Pod publishes on
its .pod. A key of either map that is not a port of the definition, or one in both, is refused.

Names (one home; the engine imports them, nothing else spells them). Application names have no '_'
(APP_NAME_RE), so '_' separates the application from the service and no two applications meet:

    container_name(app, service)            <app>_<service>
    container_file / container_unit         konsol-<app>_<service>.container / .service
    network_file / network_name             konsol-<app>.network / ksl-<app>
    network_unit                            konsol-<app>-network.service
    interface_name(env, app)                KONTEYNER_BRIDGE_PREFIX + 10 hex of sha256(ksl-<app>)
    pod_file / pod_name / pod_unit          konsol-<app>.pod / <app> / konsol-<app>-pod.service
    pod_infra_name(app)                     <app>__infra (no service can give it: services begin with
                                            a letter or digit; Quadlet's own <pod>-infra could be another
                                            application's pod name)
    labels(app)                             io.master-stack.managed=uygulama, io.master-stack.uygulama=<app>
    secret_name(app, token), secret_app()   obhut_<app>_<8 hex> (SECRET_NAME_RE)
    env_file(env, app, service)             UYGULAMA_STATE_DIR/<app>/env/<service>.env
    app_folder(env, app)                    UYGULAMA_VERI_DIR/<app>
    image_reference(image)                  (repository, reference) of a file's image as Docker reads it:
                                            short names are Docker Hub's, a missing tag is latest
    uses_pod(definition)                    a Kubernetes file with more than one container
    names(app, definition)                  all of the above for one application, without rendering it
    podman5_refusal(plan, version)          the Turkish refusal on Podman < 5, or None

Podman versions: Debian 13 and Ubuntu 26.04 ship Podman 5, Ubuntu 24.04 ships 4.9. Every [Container] and
[Network] key used here is in Quadlet 4.9.3's supported set (podman-systemd.unit(5) of v4.9.3); options
Quadlet learned later go through PodmanArgs with validated or encoded values: --entrypoint (JSON),
--network-alias, --stop-signal, --stop-timeout, --cpus, --memory, --ulimit (4.9 keeps only the last
Ulimit= line), --umask, the network's --interface-name and the pod's --infra-name and --label. Only a
Kubernetes Pod with several containers (Pod=, .pod) and a Compose service_healthy dependency
(Notify=healthy) need Podman 5; the plan lists them in needs_podman5 and the worker refuses them on 4.9.

Quoting: Quadlet copies every [Container] value into ExecStart, where systemd still expands '$' and '%'.
Keys Quadlet splits like a command line (Exec, PodmanArgs, Label, Secret, EnvironmentFile) get word():
quote() of master_container_config with '$' doubled and control characters as C escapes, which Quadlet
and then systemd both undo. Keys Quadlet passes on as written (WorkingDir, HostName, HealthCmd, Volume,
Tmpfs, …) get raw(): '$' and '%' doubled, and anything Quadlet would change (a control character, a '"'
that Podman 5 trims from the ends, a trailing space or backslash) is refused. Two things no unit can
carry are refused too: an empty argument and a lone ';' (Quadlet writes both bare into ExecStart).
"""
import hashlib
import ipaddress
import json
import math
import posixpath
import re

import master_compose
from master_container_binds import anchor_path
from master_container_config import MANAGED_LABEL, quote
from master_inspector import APP_NAME_RE

MANAGED_VALUE = "uygulama"
APP_LABEL = "io.master-stack.uygulama"
LOOPBACK = "127.0.0.1"
SECRET_NAME_RE = re.compile(r"obhut_([a-z][a-z0-9-]{0,29})_([0-9a-f]{8})\Z")
TOKEN_RE = re.compile(r"[0-9a-f]{8}\Z")
SERVICE_RE = master_compose.NAME_RE
# DD-226's start-time rule for a bind source: a non-hidden folder below SERVER_ROOT in this alphabet.
SRV_SOURCE_RE = re.compile(r"/[A-Za-z0-9_./ -]+\Z")
FOLDER_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,62}\Z")
PATH_RE = re.compile(r"/[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)*\Z")
PREFIX_RE = re.compile(r"[a-z]{1,5}\Z")
ID_RE = re.compile(r"[1-9][0-9]{0,9}\Z")
ENV_NAME_RE = master_compose.ENV_NAME_RE
# Docker's reference grammar (distribution/reference): a domain, path components, a tag, a digest.
DOMAIN_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*"
                       r"(?::[0-9]{1,5})?\Z")
COMPONENT_RE = re.compile(r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*\Z")
TAG_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z")
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
ENV_KEYS = ("KONTEYNER_BRIDGE_PREFIX", "UYGULAMA_STATE_DIR", "UYGULAMA_VERI_DIR", "SERVER_ROOT", "KONTEYNER_BAGLAMA_DIR",
            "SBIN_DIR", "STATE_FILE", "DOWNLOADS_UID", "DOWNLOADS_GID")
MAX_SERVICES = 16
RESTART = {"no": "no", "always": "always", "unless-stopped": "always", "on-failure": "on-failure"}
START_TIMEOUT = 180
# Notify=healthy holds the unit in "activating" until the container's own check passes.
HEALTHY_TIMEOUT = 300
# Without a grace period Podman stops a container after its own 10 s; the unit keeps DD-223's 75 s.
STOP_TIMEOUT = 75
STOP_MARGIN = 15
MAX_GRACE = 3600
# Podman refuses a memory limit below 6 MiB.
MIN_MEMORY = 6 * 1024 * 1024
# Podman reads an env file with bufio.Scanner: a line and its newline must fit its 64 KiB buffer.
ENV_LINE_MAX = 65535
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
C_ESCAPES = {"\a": "\\a", "\b": "\\b", "\t": "\\t", "\n": "\\n", "\v": "\\v", "\f": "\\f", "\r": "\\r"}
DURATION_UNITS = {"ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}
HEADER = "# Konsol tarafından oluşturuldu; kalıcı kaynak: %s uygulamasının kaydı."


class GeneratorError(Exception):
    """What the generator cannot express, in Turkish for the operator."""


def require(ok, text):
    if not ok:
        raise GeneratorError(text)


# -- names
def check_app(app):
    require(isinstance(app, str) and APP_NAME_RE.fullmatch(app), "Uygulama adı geçersiz.")
    return app


def check_service(service):
    require(isinstance(service, str) and SERVICE_RE.fullmatch(service), "Servis adı geçersiz.")
    return service


def container_name(app, service):
    return "%s_%s" % (check_app(app), check_service(service))


def container_file(app, service):
    return "konsol-%s.container" % container_name(app, service)


def container_unit(app, service):
    return "konsol-%s.service" % container_name(app, service)


def network_file(app):
    return "konsol-%s.network" % check_app(app)


def network_name(app):
    return "ksl-%s" % check_app(app)


def network_unit(app):
    return "konsol-%s-network.service" % check_app(app)


def interface_name(env, app):
    """The bridge's interface: KONTEYNER_BRIDGE_PREFIX and 10 hex of sha256(ksl-<app>), at most 15 characters."""
    prefix = env.get("KONTEYNER_BRIDGE_PREFIX") if isinstance(env, dict) else None
    require(isinstance(prefix, str) and PREFIX_RE.fullmatch(prefix),
            "Köprü arayüzü öneki geçersiz; kurulumu yeniden çalıştırın.")
    return prefix + hashlib.sha256(network_name(app).encode()).hexdigest()[:10]


def pod_file(app):
    return "konsol-%s.pod" % check_app(app)


def pod_name(app):
    return check_app(app)


def pod_unit(app):
    return "konsol-%s-pod.service" % check_app(app)


def pod_infra_name(app):
    return "%s__infra" % check_app(app)


def labels(app):
    return {MANAGED_LABEL: MANAGED_VALUE, APP_LABEL: check_app(app)}


def secret_name(app, token):
    """A Podman secret's name; token is 8 random hex digits the engine draws."""
    require(isinstance(token, str) and TOKEN_RE.fullmatch(token), "Gizli değer adı için geçersiz bir rastgele parça.")
    return "obhut_%s_%s" % (check_app(app), token)


def secret_app(name):
    """The application a Podman secret name belongs to, or None when it is not one of Obhut's."""
    match = SECRET_NAME_RE.fullmatch(name) if isinstance(name, str) else None
    return match.group(1) if match else None


def env_file(env, app, service):
    return "%s/%s/env/%s.env" % (_path(env, "UYGULAMA_STATE_DIR"), check_app(app), check_service(service))


def app_folder(env, app):
    return "%s/%s" % (_path(env, "UYGULAMA_VERI_DIR"), check_app(app))


def uses_pod(definition):
    return definition.get("format") == "kubernetes" and len(definition.get("services") or ()) > 1


def names(app, definition):
    """The names of an application's objects, without rendering it: {"containers": {service: name},
    "units": {service: unit}, "files": [unit file, sorted], "network": ksl-<app>, "network_unit",
    "pod": <app> | None, "pod_unit": unit | None}. The plan's units are exactly "files"."""
    require(isinstance(definition, dict) and isinstance(definition.get("services"), list), "Uygulamanın tanımı okunamadı.")
    services = [check_service(s.get("name") if isinstance(s, dict) else None) for s in definition["services"]]
    pod = uses_pod(definition)
    files = [network_file(app)] + ([pod_file(app)] if pod else []) + [container_file(app, s) for s in services]
    return {"containers": {s: container_name(app, s) for s in services},
            "units": {s: container_unit(app, s) for s in services}, "files": sorted(files),
            "network": network_name(app), "network_unit": network_unit(app),
            "pod": pod_name(app) if pod else None, "pod_unit": pod_unit(app) if pod else None}


def image_reference(image):
    """(repository, reference) of an image as a Compose or Kubernetes file means it (Docker's rules): a first
    component without '.', ':' or capitals is a Docker Hub path, a single name is library/, no tag is latest."""
    require(isinstance(image, str) and 0 < len(image) <= 512 and not re.search(r"\s", image),
            "İmaj adı okunamadı: %s" % str(image)[:120])
    name, _, digest = image.partition("@")
    tag = None
    if name.rfind(":") > name.rfind("/"):
        name, _, tag = name.rpartition(":")
        require(TAG_RE.fullmatch(tag), "İmajın etiketi okunamadı: %s" % image[:120])
    require(not digest or DIGEST_RE.fullmatch(digest), "İmajın özeti okunamadı (yalnız sha256): %s" % image[:120])
    first, sep, rest = name.partition("/")
    if sep and ("." in first or ":" in first or first == "localhost" or first != first.lower()):
        domain, path = first, rest
    else:
        domain, path = "docker.io", name
    if domain == "index.docker.io":
        domain = "docker.io"
    if domain == "docker.io" and "/" not in path:
        path = "library/" + path
    require(DOMAIN_RE.fullmatch(domain) and path and all(COMPONENT_RE.fullmatch(p) for p in path.split("/")),
            "İmaj adı okunamadı (küçük harf, rakam ve . _ - ile yollar): %s" % image[:120])
    repository = "%s/%s" % (domain, path)
    require(len(repository) <= 255, "İmaj adı çok uzun: %s" % image[:120])
    if tag is None and not digest:
        tag = "latest"
    return repository, repository + (":" + tag if tag else "") + ("@" + digest if digest else "")


def podman5_refusal(plan, version):
    """The refusal the worker gives on a Podman older than 5 for what only Podman 5 runs, or None."""
    major, minor = _version(version)
    if not plan.get("needs_podman5") or major >= 5:
        return None
    return "%s: Podman 5 gerekir; bu sunucuda %d.%d." % ("; ".join(plan["needs_podman5"]), major, minor)


# -- quoting
def word(value):
    """One word of a key Quadlet splits like a command line (Exec, PodmanArgs, Label, Secret, EnvironmentFile)."""
    require(isinstance(value, str), "Birim satırına metin olmayan bir değer yazılamaz.")
    require("\x00" not in value, "Birim satırına NUL karakteri yazılamaz.")
    return CONTROL_RE.sub(lambda m: C_ESCAPES.get(m.group(), "\\x%02x" % ord(m.group())), quote(value, command=True))


def arg(value):
    """word(), left bare when nothing in it needs quoting (flags, names, numbers)."""
    require(isinstance(value, str) and value != "", "Boş bir argüman birim satırına yazılamaz.")
    return value if re.fullmatch(r"[A-Za-z0-9_./:=@+,-]+", value) else word(value)


def raw(value, what):
    """A value Quadlet passes on as written: '$' and '%' doubled for ExecStart, everything it would change refused."""
    require(isinstance(value, str) and value != "", "%s boş olamaz." % what)
    require(not CONTROL_RE.search(value) and value == value.strip() and not value.startswith('"')
            and not value.endswith(('"', "\\")),
            "%s birim satırına olduğu gibi yazılamıyor (denetim karakteri, baştaki ya da sondaki boşluk, '\"' ya da "
            "sondaki '\\'): %s" % (what, value[:120]))
    return value.replace("%", "%%").replace("$", "$$")


# -- checks of the context and the definition
def _version(value):
    require(isinstance(value, (tuple, list)) and len(value) == 2 and all(type(v) is int and v >= 0 for v in value),
            "Podman sürümü okunamadı.")
    return tuple(value)


def _path(env, key):
    value = env.get(key) if isinstance(env, dict) else None
    require(isinstance(value, str) and PATH_RE.fullmatch(value) and ".." not in value.split("/"),
            "%s eksik ya da geçersiz; kurulumu yeniden çalıştırın." % key)
    return value


def _env(env):
    require(isinstance(env, dict), "Kurulum ayarları okunamadı.")
    for key in ENV_KEYS:
        require(key in env, "%s eksik; kurulumu yeniden çalıştırın." % key)
    for key in ("UYGULAMA_STATE_DIR", "UYGULAMA_VERI_DIR", "SERVER_ROOT", "KONTEYNER_BAGLAMA_DIR", "SBIN_DIR", "STATE_FILE"):
        _path(env, key)
    require(all(isinstance(env[k], str) and ID_RE.fullmatch(env[k]) for k in ("DOWNLOADS_UID", "DOWNLOADS_GID")),
            "Dosyalar hesabı kimliği geçersiz; kurulumu yeniden çalıştırın.")
    interface_name(env, "a")
    return env


def duration_of(duration, what):
    """A Compose or Kubernetes duration (1m30s, 10s, 0) in seconds."""
    require(isinstance(duration, str) and master_compose.DURATION_RE.fullmatch(duration), "%s bir süre değil." % what)
    return sum(float(n) * DURATION_UNITS[u] for n, u in re.findall(r"([0-9]+(?:\.[0-9]+)?)(ns|us|µs|ms|s|m|h)", duration))


def seconds(duration, what):
    """duration_of() in whole seconds, rounded up."""
    return math.ceil(duration_of(duration, what))


def _number(value):
    return ("%.3f" % value).rstrip("0").rstrip(".") if isinstance(value, float) else str(value)


def _int(value, low, what):
    require(type(value) is int and value >= low, "%s geçersiz." % what)
    return value


class _Render:
    def __init__(self, definition, context):
        require(isinstance(definition, dict) and isinstance(context, dict), "Uygulamanın tanımı okunamadı.")
        self.d = definition
        self.app = check_app(definition.get("name"))
        require(context.get("app") == self.app, "Tanım başka bir uygulamanın.")
        require(definition.get("format") in ("compose", "kubernetes"), "Tanımın biçimi bilinmiyor.")
        services = definition.get("services")
        require(isinstance(services, list) and 0 < len(services) <= MAX_SERVICES, "Tanımda servis yok ya da çok fazla.")
        names = [check_service(s.get("name") if isinstance(s, dict) else None) for s in services]
        require(len(set(names)) == len(names), "Tanımda aynı servis adı iki kez.")
        self.services = services
        self.names = names
        self.env = _env(context.get("env"))
        require(_version(context.get("podman")) >= (4, 9), "Podman 4.9 ya da daha yenisi gerekir.")
        require(type(context.get("stopped")) is bool, "Uygulamanın durumu okunamadı.")
        self.stopped = context["stopped"]
        for key in ("images", "ports", "raw", "secrets"):
            require(isinstance(context.get(key), dict), "Uygulamanın kaydı eksik: %s." % key)
        self.images = context["images"]
        self.ports = context["ports"]
        self.raw = context["raw"]
        self.secrets = context["secrets"]
        self.pod = uses_pod(definition)
        self.by_name = dict(zip(names, services))
        self.healthy = set()
        self.reasons = []
        if self.pod:
            self.reasons.append("Kubernetes dosyası birden çok konteynerli bir Pod (Quadlet .pod)")
        for svc in services:
            for dep in svc.get("depends_on") or ():
                require(isinstance(dep, dict) and dep.get("service") in self.by_name and dep["service"] != svc["name"],
                        "%s: bağımlı olduğu servis tanımda yok." % svc["name"])
                require(dep.get("condition") in ("started", "healthy"), "%s: bekleme koşulu bilinmiyor." % svc["name"])
                if dep["condition"] == "healthy":
                    target = self.by_name[dep["service"]]
                    require((target.get("health") or {}).get("test") != ["NONE"],
                            "%s, %s servisinin sağlıklı olmasını bekliyor ama onun sağlık denetimi kapalı."
                            % (svc["name"], dep["service"]))
                    self.healthy.add(dep["service"])
                    self.reasons.append("%s, %s servisinin sağlıklı olmasını bekliyor (Notify=healthy)"
                                        % (svc["name"], dep["service"]))
        self.order = self.start_order()

    # -- the plan
    def plan(self):
        app, env = self.app, self.env
        units, environment, binds, containers, publications, folders = {}, {}, {}, {}, [], []
        for svc in self.services:
            name = svc["name"]
            containers[name] = container_name(app, name)
            environment[name] = self.env_text(svc)
            binds[name] = [self.srv_source(svc, m) for m in svc.get("mounts") or () if self.mount_kind(svc, m) == "srv"]
            for mount in svc.get("mounts") or ():
                if self.mount_kind(svc, mount) == "app":
                    path = self.app_path(svc, mount)
                    if path not in folders:
                        folders.append(path)
            publications.extend(self.publications(svc))
        keys = {"%s:%d/%s" % (r["service"], r["port"], r["protocol"]) for r in publications}
        for key in sorted((set(self.ports) | set(self.raw)) - keys):
            require(False, "Kayıttaki %s portu tanımda yok." % str(key)[:120])
        listeners = [(row["host_ip"], row["host_port"], row["protocol"]) for row in publications]
        require(len(set(listeners)) == len(listeners), "Aynı adres ve port iki porta ayrılmış.")
        units[network_file(app)] = self.network_unit_text()
        if self.pod:
            units[pod_file(app)] = self.pod_unit_text(publications)
        for svc in self.services:
            units[container_file(app, svc["name"])] = self.container_text(svc, publications)
        start = ([pod_unit(app)] if self.pod else []) + [container_unit(app, n) for n in self.order]
        return {
            "units": dict(sorted(units.items())),
            "environment": environment,
            "folders": sorted(folders),
            "binds": binds,
            "start": start,
            "stop": list(reversed(start)),
            "containers": containers,
            "network": {"name": network_name(app), "interface": interface_name(env, app), "unit": network_unit(app)},
            "pod": {"name": pod_name(app), "unit": pod_unit(app)} if self.pod else None,
            "publications": publications,
            "needs_podman5": list(self.reasons),
        }

    def start_order(self):
        """Dependencies first; among the ready ones the file's order (Kahn's algorithm, stable)."""
        waits = {n: {d["service"] for d in self.by_name[n].get("depends_on") or ()} for n in self.names}
        order = []
        while len(order) < len(self.names):
            ready = [n for n in self.names if n not in order and waits[n] <= set(order)]
            require(ready, "Servisler birbirini bekliyor (döngü); başlatma sırası çıkarılamaz.")
            order.append(ready[0])
        return order

    # -- pieces
    def mount_kind(self, svc, mount):
        require(isinstance(mount, dict) and mount.get("to") in ("app", "srv", "tmpfs"), "%s: bağlama okunamadı." % svc["name"])
        return mount["to"]

    def target(self, svc, mount):
        target = mount.get("target")
        require(isinstance(target, str) and target.startswith("/") and target != "/" and ":" not in target
                and ".." not in target.split("/"), "%s: konteynerdeki yol bağlanamıyor (':' içeremez): %s"
                % (svc["name"], str(target)[:120]))
        return raw(target, "%s: konteynerdeki yol" % svc["name"])

    def srv_source(self, svc, mount):
        path, root = mount.get("path"), self.env["SERVER_ROOT"]
        ok = isinstance(path, str) and SRV_SOURCE_RE.fullmatch(path) and posixpath.normpath(path) == path
        parts = path[len(root):].split("/")[1:] if ok and path.startswith(root + "/") else []
        require(parts and all(p and not p.startswith(".") for p in parts),
                "%s: %s bağlanamaz; %s altında gizli olmayan bir klasör olmalı (harf, rakam, boşluk, . _ -)."
                % (svc["name"], str(path)[:120], root))
        return path

    def anchor(self, container, index, source):
        """DD-226's anchor; master_container_binds checks the container name the anchors live under."""
        try:
            return str(anchor_path(self.env, container, index, source))
        except Exception as err:  # noqa: BLE001 - its own refusal, in the generator's words
            raise GeneratorError("%s: /srv bağlamasının bağlama noktası adı oluşturulamadı." % container) from err

    def app_path(self, svc, mount):
        folder = mount.get("folder")
        require(isinstance(folder, str) and FOLDER_RE.fullmatch(folder), "%s: veri klasörünün adı geçersiz." % svc["name"])
        return "%s/%s" % (app_folder(self.env, self.app), folder)

    def publications(self, svc):
        """An address row's pool port on 127.0.0.1 (TCP); an open raw row on its address and host port."""
        rows = []
        for port in svc.get("ports") or ():
            require(isinstance(port, dict) and type(port.get("port")) is int and 0 < port["port"] < 65536
                    and port.get("protocol") in ("tcp", "udp"), "%s: port okunamadı." % svc["name"])
            key = "%s:%d/%s" % (svc["name"], port["port"], port["protocol"])
            require(not (key in self.ports and key in self.raw), "%s hem adres hem ham port olamaz." % key)
            if key in self.ports:
                require(port["protocol"] == "tcp", "%s: UDP portu yalnız ham port olabilir." % svc["name"])
                pool = self.ports[key]
                require(type(pool) is int and 0 < pool < 65536, "%s için yerel port ayrılmamış." % key)
                rows.append({"service": svc["name"], "port": port["port"], "protocol": "tcp", "host_ip": LOOPBACK,
                             "host_port": pool})
            elif key in self.raw:
                host = self.raw[key]
                require(isinstance(host, dict) and set(host) == {"host_ip", "host_port"} and type(host["host_port"]) is int
                        and 0 < host["host_port"] < 65536, "%s ham portunun adresi okunamadı." % key)
                try:
                    address = ipaddress.IPv4Address(host["host_ip"])
                except (ValueError, TypeError) as err:
                    raise GeneratorError("%s ham portu yalnız bir IPv4 adresinde yayımlanır." % key) from err
                require(str(address) == host["host_ip"] and not (address.is_loopback or address.is_unspecified
                                                                 or address.is_multicast or address.is_link_local),
                        "%s ham portu yalnız sunucunun Tailscale ya da internet IPv4 adresinde yayımlanır." % key)
                rows.append({"service": svc["name"], "port": port["port"], "protocol": port["protocol"],
                             "host_ip": host["host_ip"], "host_port": host["host_port"]})
        return rows

    def env_text(self, svc):
        lines = []
        for entry in svc.get("environment") or ():
            require(isinstance(entry, dict) and isinstance(entry.get("name"), str) and ENV_NAME_RE.fullmatch(entry["name"]),
                    "%s: ortam değişkeni adı geçersiz." % svc["name"])
            if "secret" in entry:
                continue
            value = entry.get("value")
            require(isinstance(value, str) and not re.search(r"[\n\r\x00]", value),
                    "%s: %s değeri satır sonu ya da NUL içeriyor; ortam dosyasına yazılamaz." % (svc["name"], entry["name"]))
            line = "%s=%s" % (entry["name"], value)
            require(len(line.encode("utf-8")) < ENV_LINE_MAX,
                    "%s: %s değeri çok uzun (en çok %d bayt)." % (svc["name"], entry["name"], ENV_LINE_MAX - 1))
            lines.append(line + "\n")
        return "".join(lines)

    def health(self, svc):
        health = svc.get("health")
        if health is None:
            return []
        require(isinstance(health, dict) and isinstance(health.get("test"), list)
                and all(isinstance(t, str) for t in health["test"]), "%s: sağlık denetimi okunamadı." % svc["name"])
        test = health["test"]
        if not test:
            # No command: the image's own check runs, and Podman takes timings only with a command.
            return []
        if test == ["NONE"]:
            return ["HealthCmd=none"]
        if test[0] == "CMD":
            # Podman prepends CMD to a JSON array of two or more words; one that starts with CMD itself it
            # splits at its spaces, and a single word it runs through /bin/sh.
            require(len(test) >= 3, "%s: tek parçalı bir CMD sağlık denetimi Podman'a olduğu gibi verilemez; komutu "
                                    "argümanlarıyla ya da CMD-SHELL ile yazın." % svc["name"])
            # Podman reads a first word of CMD, NONE or CMD-SHELL (in any case) as its own keyword.
            require(test[1].upper() not in ("CMD", "NONE", "CMD-SHELL"),
                    "%s: sağlık denetiminin komutu %s adını taşıyamaz; Podman onu kendi sözcüğü sayar." % (svc["name"], test[1]))
            command = test[1:]
        else:
            require(test[0] == "CMD-SHELL" and len(test) >= 2, "%s: sağlık denetimi CMD ya da CMD-SHELL olmalı." % svc["name"])
            command = test
        lines = ["HealthCmd=" + raw(json.dumps(command), "%s: sağlık denetimi" % svc["name"])]
        for key, field in (("HealthInterval", "interval"), ("HealthTimeout", "timeout"), ("HealthStartPeriod", "start_period")):
            value = health.get(field)
            if value is None:
                continue
            # Zero means the default, as in Docker (Podman would read an interval of 0 as "never").
            total = duration_of(value, "%s: %s" % (svc["name"], field))
            if total == 0:
                continue
            require(field != "timeout" or total >= 1, "%s: sağlık denetiminin zaman aşımı en az 1 saniye olmalı." % svc["name"])
            lines.append("%s=%s" % (key, value))
        retries = health.get("retries")
        if retries is not None and _int(retries, 0, "%s: deneme sayısı" % svc["name"]) > 0:
            lines.append("HealthRetries=%d" % retries)
        return lines

    def start_lines(self, svc, srv_writable):
        """A4: direct (its user, no capabilities, no new privileges) or root (Podman's set less the drops)."""
        name = svc["name"]
        caps_add = svc.get("caps_add") or []
        require(all(c in master_compose.DEFAULT_CAPS for c in caps_add), "%s: varsayılan kümenin dışında yetenek." % name)
        if svc.get("start") == "direct":
            user = svc.get("user") or "%s:%s" % (self.env["DOWNLOADS_UID"], self.env["DOWNLOADS_GID"])
            require(isinstance(user, str) and master_compose.USER_RE.fullmatch(user), "%s: kullanıcı geçersiz." % name)
            files_account = user == "%s:%s" % (self.env["DOWNLOADS_UID"], self.env["DOWNLOADS_GID"])
            # DD-227: the Files account keeps /srv's group-writable files.
            umask = ["--umask=0002"] if files_account and srv_writable else []
            return ["User=" + user, "DropCapability=all", "NoNewPrivileges=true"], umask
        require(svc.get("start") == "root", "%s: başlangıç biçimi bilinmiyor." % name)
        lines, drops = [], svc.get("caps_drop")
        if drops == "all":
            lines.append("DropCapability=all")
        else:
            require(isinstance(drops, list) and all(c in master_compose.DEFAULT_CAPS for c in drops),
                    "%s: düşürülen yetenekler okunamadı." % name)
            if drops:
                lines.append("DropCapability=" + " ".join(drops))
        if caps_add:
            lines.append("AddCapability=" + " ".join(caps_add))
        if svc.get("no_new_privileges") is True:
            lines.append("NoNewPrivileges=true")
        return lines, []

    def limits(self, svc):
        name = svc["name"]
        limits = svc.get("limits") or {}
        require(isinstance(limits, dict), "%s: sınırlar okunamadı." % name)
        lines, args = [], []
        if limits.get("pids") is not None:
            lines.append("PidsLimit=%d" % _int(limits["pids"], 1, "%s: süreç sınırı" % name))
        cpus = limits.get("cpus")
        if cpus is not None:
            require(type(cpus) in (int, float) and 0 < cpus <= 4096, "%s: CPU sınırı geçersiz." % name)
            args.append("--cpus=" + _number(cpus))
        memory = limits.get("memory")
        if memory is not None:
            require(_int(memory, 1, "%s: bellek sınırı" % name) >= MIN_MEMORY, "%s: bellek sınırı en az 6 MiB olmalı." % name)
            args.append("--memory=%d" % memory)
        ulimits = limits.get("ulimits") or {}
        require(isinstance(ulimits, dict), "%s: işlem kaynak sınırları okunamadı." % name)
        for key in sorted(ulimits):
            item = ulimits[key]
            require(key in master_compose.ULIMITS and isinstance(item, dict)
                    and all(type(item.get(k)) is int and item[k] >= -1 for k in ("soft", "hard")),
                    "%s: işlem kaynak sınırı okunamadı: %s" % (name, str(key)[:40]))
            args.append("--ulimit=%s=%d:%d" % (key, item["soft"], item["hard"]))
        return lines, args

    def stop(self, svc):
        """--stop-signal and --stop-timeout, and the unit's TimeoutStopSec."""
        name, args = svc["name"], []
        signal = svc.get("stop_signal")
        if signal is not None:
            require(isinstance(signal, str) and master_compose.SIGNAL_RE.fullmatch(signal), "%s: durdurma sinyali geçersiz." % name)
            args.append("--stop-signal=" + signal)
        grace = svc.get("stop_grace")
        if grace is None:
            return args, STOP_TIMEOUT
        total = seconds(grace, "%s: durdurma süresi" % name)
        require(total <= MAX_GRACE, "%s: durdurma süresi en çok %d saniye olabilir." % (name, MAX_GRACE))
        args.append("--stop-timeout=%d" % total)
        return args, total + STOP_MARGIN

    def command(self, svc):
        name = svc["name"]
        lines, args = [], []
        entrypoint, command, workdir = svc.get("entrypoint"), svc.get("command"), svc.get("workdir")
        if entrypoint is not None:
            require(isinstance(entrypoint, list) and all(isinstance(t, str) and "\x00" not in t for t in entrypoint),
                    "%s: giriş noktası okunamadı." % name)
            args.append("--entrypoint=" + json.dumps(entrypoint))
        if command:
            require(isinstance(command, list) and all(isinstance(t, str) for t in command), "%s: komut okunamadı." % name)
            for token in command:
                require(token != "", "%s: komutta boş bir argüman var; Quadlet onu yazamaz." % name)
                require(token != ";", "%s: komutta tek başına ';' var; systemd onu komut ayırıcısı sayar." % name)
            lines.append("Exec=" + " ".join(arg(t) for t in command))
        if workdir is not None:
            require(isinstance(workdir, str) and workdir.startswith("/"), "%s: çalışma klasörü mutlak bir yol olmalı." % name)
            lines.append("WorkingDir=" + raw(workdir, "%s: çalışma klasörü" % name))
        return lines, args

    def file_labels(self, svc):
        out = []
        file_labels = svc.get("labels") or {}
        require(isinstance(file_labels, dict), "%s: etiketler okunamadı." % svc["name"])
        for key in sorted(file_labels):
            value = file_labels[key]
            require(isinstance(key, str) and key and not re.search(r"[\s=\x00-\x1f\x7f]", key)
                    and not key.startswith(master_compose.PODMAN_LABELS + master_compose.OBHUT_LABELS)
                    and isinstance(value, str), "%s: etiket verilemez: %s" % (svc["name"], str(key)[:64]))
            out.append("Label=" + arg("%s=%s" % (key, value)))
        return out

    def unit_head(self, what, extra=()):
        return [HEADER % self.app, "[Unit]", "Description=Konsol uygulaması %s: %s" % (self.app, what),
                "After=network-online.target master-firewall.service",
                # DD-223: no Requires=, so a firewall restart does not restart the application.
                "Wants=network-online.target master-firewall.service"] + list(extra)

    def guard_check(self):
        # DD-223: only the locked writers apply the guard; the unit checks it and retries.
        helper = "%s/master_container_network.py" % self.env["SBIN_DIR"]
        return ("ExecStartPre=/usr/bin/python3 " + quote(helper, command=True) + " --state " +
                quote(self.env["STATE_FILE"], command=True) + " --check")

    def install(self):
        return [] if self.stopped else ["", "[Install]", "WantedBy=multi-user.target"]

    def container_text(self, svc, publications):
        app, env, name = self.app, self.env, svc["name"]
        container = container_name(app, name)
        image = self.images.get(name)
        match = re.fullmatch(r"(.+)@(sha256:[0-9a-f]{64})", image) if isinstance(image, str) else None
        require(match is not None, "%s: imaj özetine sabitlenmemiş." % name)
        repository, _reference = image_reference(svc.get("image"))
        require(image_reference(image)[0] == repository == match.group(1),
                "%s: sabitlenen imaj (%s) tanımdakinin deposu değil (%s)." % (name, image[:120], repository))
        mounts = svc.get("mounts") or []
        sources = [self.srv_source(svc, m) for m in mounts if self.mount_kind(svc, m) == "srv"]
        srv_writable = any(m["to"] == "srv" and m.get("read_only") is not True for m in mounts)
        head = []
        for dep in svc.get("depends_on") or ():
            head += ["Requires=" + container_unit(app, dep["service"]), "After=" + container_unit(app, dep["service"])]
        # DD-226: the Volume source is a pinned anchor, so the real folder stays a mount dependency here.
        for source in dict.fromkeys(sources):
            head.append("RequiresMountsFor=" + quote(source))
        lines = self.unit_head(name, head)
        lines += ["", "[Container]", "ContainerName=" + container, "Image=" + raw(image, "%s: imaj" % name), "Pull=never"]
        lines.append(("Pod=" + pod_file(app)) if self.pod else ("Network=" + network_file(app)))
        lines += ["Label=%s=%s" % item for item in labels(app).items()]
        lines += self.file_labels(svc)
        lines.append("LogDriver=journald")
        start, umask = self.start_lines(svc, srv_writable)
        lines += start
        for flag, key in (("read_only", "ReadOnly=true"), ("init", "RunInit=true")):
            value = svc.get(flag, False)
            require(type(value) is bool, "%s: %s okunamadı." % (name, flag))
            if value:
                lines.append(key)
        hostname = svc.get("hostname")
        if hostname is not None:
            require(isinstance(hostname, str) and master_compose.HOSTNAME_RE.fullmatch(hostname), "%s: makine adı geçersiz." % name)
            lines.append("HostName=" + hostname)
        if svc.get("shm_size") is not None:
            lines.append("ShmSize=%d" % _int(svc["shm_size"], 1, "%s: paylaşılan bellek" % name))
        limit_lines, limit_args = self.limits(svc)
        lines += limit_lines
        lines.append("EnvironmentFile=" + word(env_file(env, app, name)))
        for entry in svc.get("environment") or ():
            if "secret" not in entry:
                continue
            podman = self.secrets.get(entry["secret"])
            require(secret_app(podman) == app, "%s: %s için Podman secret'ı ayrılmamış." % (name, entry["name"]))
            lines.append("Secret=%s,type=env,target=%s" % (podman, entry["name"]))
        if not self.pod:
            lines += [publish_line(r) for r in publications if r["service"] == name]
        index = 0
        for mount in mounts:
            kind = self.mount_kind(svc, mount)
            if kind == "tmpfs":
                lines.append("Tmpfs=" + self.target(svc, mount))
                continue
            read_only = mount.get("read_only")
            require(type(read_only) is bool, "%s: bağlamanın yazma izni okunamadı." % name)
            mode = "ro" if read_only else "rw"
            if kind == "srv":
                # DD-226: Podman would resolve the path again at every start; it mounts the anchor that
                # ExecStartPre pinned through a descriptor instead. /srv never gets U.
                source = self.anchor(container, index, sources[index])
                index += 1
            else:
                source = self.app_path(svc, mount)
                # The data folder follows a direct container's user; a root start's image sees to its own.
                if svc.get("start") == "direct":
                    mode += ",U"
            lines.append("Volume=%s:%s:%s" % (raw(source, "%s: kaynak" % name), self.target(svc, mount), mode))
        lines += self.health(svc)
        if name in self.healthy:
            lines.append("Notify=healthy")
        command_lines, command_args = self.command(svc)
        lines += command_lines
        stop_args, stop_timeout = self.stop(svc)
        args = command_args + ([] if self.pod else ["--network-alias=" + name]) + stop_args + limit_args + umask
        lines += ["PodmanArgs=" + arg(a) for a in args]
        restart = RESTART.get(svc.get("restart"))
        require(restart is not None, "%s: yeniden başlatma kuralı bilinmiyor." % name)
        lines += ["", "[Service]", "Restart=" + restart, "RestartSec=10s",
                  "TimeoutStartSec=%d" % (HEALTHY_TIMEOUT if name in self.healthy else START_TIMEOUT),
                  "TimeoutStopSec=%d" % stop_timeout, "UMask=0077", self.guard_check()]
        if sources:
            pin = "/usr/bin/python3 " + quote("%s/master_container_binds.py" % env["SBIN_DIR"], command=True) + \
                " --state " + quote(env["STATE_FILE"], command=True)
            lines.append("ExecStartPre=" + pin + " bagla " + " ".join(quote(v, command=True) for v in [container] + sources))
            lines.append("ExecStopPost=-" + pin + " birak " + quote(container, command=True))
        lines += self.install()
        return "\n".join(lines) + "\n"

    def network_unit_text(self):
        app = self.app
        lines = [HEADER % app, "[Unit]", "Description=Konsol uygulaması %s: ağ" % app, "",
                 "[Network]", "NetworkName=" + network_name(app), "Driver=bridge"]
        lines += ["Label=%s=%s" % item for item in labels(app).items()]
        # Quadlet 4.9 has no InterfaceName= key; the guard knows the bridge by this name.
        lines.append("PodmanArgs=--interface-name=" + interface_name(self.env, app))
        return "\n".join(lines) + "\n"

    def pod_unit_text(self, publications):
        app = self.app
        lines = self.unit_head("Pod")
        lines += ["", "[Pod]", "PodName=" + pod_name(app), "Network=" + network_file(app)]
        # The pod holds the network namespace: every container's publication is the pod's.
        lines += [publish_line(r) for r in publications]
        # Quadlet's [Pod] has no Label= key; its own infra name (<pod>-infra) could be another application's pod.
        lines.append("PodmanArgs=--infra-name=" + pod_infra_name(app))
        lines += ["PodmanArgs=--label=%s=%s" % item for item in labels(app).items()]
        lines += ["", "[Service]", "RestartSec=10s", self.guard_check()]
        lines += self.install()
        return "\n".join(lines) + "\n"


def publish_line(row):
    """A publication as Quadlet's PublishPort: <host_ip>:<host_port>:<port>/<protocol> (IPv4 only, DD-217)."""
    return "PublishPort=%s:%d:%d/%s" % (row["host_ip"], row["host_port"], row["port"], row["protocol"])


def render(definition, context):
    """The plan for one application (see the module's docstring); GeneratorError(text) when it cannot be built."""
    try:
        return _Render(definition, context).plan()
    except GeneratorError:
        raise
    except Exception as err:  # noqa: BLE001 - a malformed definition or context fails closed with a reason
        raise GeneratorError("Uygulamanın birimleri oluşturulamadı: tanım ya da kayıt okunamadı.") from err
