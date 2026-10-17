#!/usr/bin/env python3
"""Applications (rebuild DD-271, phase 3): an application installed from its own Compose or Kubernetes
file. This module holds what the root backend and the root worker share: the record, the loopback pool,
the container guard's input, the read model and the drafts. The worker (master_container_worker) runs the
lifecycle; the backend only reads (master-panel.service keeps its sandbox).

Record, UYGULAMA_STATE_DIR/<app>/ (0700 root; every file 0600, written atomically, read without following
a link, its owner, mode and size checked):

  kaynak.yaml    the file exactly as the operator gave it
  kaynak.json    {"tur": dosya|adres|imaj|konteyner, "adres"?, "imaj"?, "konteyner"?, "alindi": epoch, "sha256": hex}
  yanitlar.json  the answers as given; every secret answer is {"set": true}
  tanim.json     the checked definition (master_inspector.check)
  yerler.json    {"revision", "stopped", "ports": {"<service>:<port>/<proto>": pool port},
                  "secrets": {logical name: Podman secret}, "images": {service: "repo@sha256:…"}}
  env/<service>.env   the non-secret environment the generator's plan holds

The record is the single source: the units are generated again from it whenever the worker writes them.
Nothing runs unasked (no reconcile). Data lives in UYGULAMA_VERI_DIR/<app>/<folder>/ (A5).

Drafts (K2) turn an https address, an image or a standalone container into a Compose text for the
inspector; nothing is written. Python standard library only.
"""
import copy
import datetime
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import time
import urllib.parse

import master_container_config as cfg
import master_containers
import master_generator as generator
import master_settings as settings

# The generator owns every name (its names table); these are the inspector's and the readers' own rules.
APP_NAME_RE = generator.APP_NAME_RE
SERVICE_RE = generator.SERVICE_RE
# "<service>:<port>/<proto>": the service part is checked with SERVICE_RE.
PORT_KEY_RE = re.compile(r"([^:]+):([1-9][0-9]{0,4})/(tcp|udp)\Z")
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
URL_LIMIT = 2048
TEXT_LIMIT = 262144  # master_yaml.LIMIT_BYTES (a test keeps the two equal)
SOURCES = ("dosya", "adres", "imaj", "konteyner")
FILES = ("kaynak.yaml", "kaynak.json", "yanitlar.json", "tanim.json", "yerler.json")
MANAGED = generator.MANAGED_VALUE
APP_LABEL = generator.APP_LABEL
TAILS = (100, 200, 500, 1000)
# The address draft (K2): at most this many redirects, in this many seconds, of this size.
FETCH_SECONDS = 10.0
FETCH_REDIRECTS = 3
UPDATE_ORDER = ("yeni", "denetlenemedi", "bilinmiyor", "guncel", "sabit")

require = cfg.require
AppError = cfg.ContainerConfigError


# -- names and paths
def app_name(value):
    require(isinstance(value, str) and APP_NAME_RE.fullmatch(value) is not None, "Uygulama adı geçersiz.")
    return value


def _root(env, key, what):
    value = env.get(key, "")
    require(isinstance(value, str) and value.startswith("/") and ".." not in Path(value).parts,
            "%s yolu eksik; kurulumu yeniden çalıştırın." % what, 503)
    return Path(value)


def state_root(env):
    return _root(env, "UYGULAMA_STATE_DIR", "Uygulama kayıt")


def data_root(env):
    return _root(env, "UYGULAMA_VERI_DIR", "Uygulama veri")


def _names(call, *args):
    try:
        return call(*args)
    except generator.GeneratorError as err:
        raise AppError(503, str(err)) from err


def data_dir(env, app):
    """UYGULAMA_VERI_DIR/<app> (A5)."""
    return Path(_names(generator.app_folder, env, app_name(app)))


def names(app, definition):
    """The names of an application's objects (the generator's table): containers and service units per
    service, unit files, network and pod."""
    return _names(generator.names, app, definition)


def interface(env, app):
    return _names(generator.interface_name, env, app)


def context(env, app, places, version):
    """The generator's context: what the engine allocated and the state.env keys it reads."""
    return {"app": app, "images": dict(places["images"]), "ports": dict(places["ports"]), "secrets": dict(places["secrets"]),
            "stopped": places["stopped"], "podman": tuple(version), "env": {k: env.get(k, "") for k in generator.ENV_KEYS}}


def render(env, app, definition, places, version, module=None):
    """The generator's plan for a definition and its places; its units, start order and folders must be the
    application's own."""
    module = module or generator
    try:
        plan = module.render(definition, context(env, app, places, version))
    except module.GeneratorError as err:
        raise AppError(409, str(err)) from err
    objects = names(app, definition)
    services = set(objects["units"].values()) | {objects["network_unit"]} | ({objects["pod_unit"]} if objects["pod"] else set())
    require(sorted(plan["units"]) == objects["files"] and set(plan["start"]) <= services and set(plan["stop"]) <= services,
            "Üretilen birimler uygulamanın adlarıyla uyuşmuyor.", 502)
    root = data_dir(env, app)
    for folder in plan["folders"]:
        path = Path(folder)
        require(path.is_absolute() and ".." not in path.parts and (path == root or root in path.parents),
                "Üretilen klasör uygulamanın klasörü dışında: %s" % folder, 502)
    return plan


# -- private files
def _private(info):
    return info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) & 0o077 == 0


def read_text(path, limit=TEXT_LIMIT):
    """A private text file (UTF-8), or None when it does not exist."""
    try:
        raw, info = settings.read_regular(path, limit)
    except FileNotFoundError:
        return None
    except (OSError, settings.SettingsError) as err:
        raise AppError(503, "Uygulama kaydı güvenli biçimde okunamadı.") from err
    require(_private(info), "Uygulama kaydı özel değil; işlem yapılmadı.", 503)
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as err:
        raise AppError(503, "Uygulama kaydı okunamadı.") from err


def remove_tree(path):
    """Removes a folder this job made, without following a link inside it (rmtree's fd-based walk)."""
    import shutil
    path = Path(path)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode), "Silinecek klasör güvenli değil: %s" % path, 503)
    require(shutil.rmtree.avoids_symlink_attacks, "Bu sistemde klasör güvenli biçimde silinemiyor.", 503)
    shutil.rmtree(path)


def make_dir(path, own=True):
    """A 0700 root folder (and its missing parents) without following a link; True when this call made it.
    own=False: an application's sub-folder. Once it exists its owner and mode are the container's (Podman's U
    option, or the image's own start-up chowns it), so an existing one only has to be a real directory; its
    parent, the application's data folder, stays 0700 root and nothing inside a container can replace it."""
    path = Path(path)
    existed = os.path.lexists(path)
    if existed and not own:
        require(stat.S_ISDIR(os.lstat(path).st_mode), "Uygulama klasörü güvenli değil: %s" % path, 503)
        return False
    cfg.private_dir(path)
    info = os.lstat(path)
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid(), "Uygulama klasörü güvenli değil: %s" % path, 503)
    return not existed


# -- record validation
def check_source(value):
    require(isinstance(value, dict) and value.get("tur") in SOURCES, "Uygulama kaynağı kaydı geçersiz.", 503)
    allowed = {"tur", "alindi", "sha256"} | ({value["tur"]} if value["tur"] != "dosya" else set())
    require(set(value) == allowed and type(value["alindi"]) is int and isinstance(value["sha256"], str)
            and SHA_RE.fullmatch(value["sha256"]) is not None, "Uygulama kaynağı kaydı geçersiz.", 503)
    if value["tur"] != "dosya":
        require(isinstance(value[value["tur"]], str) and 0 < len(value[value["tur"]]) <= URL_LIMIT,
                "Uygulama kaynağı kaydı geçersiz.", 503)
    return value


def check_places(value, app):
    require(isinstance(value, dict) and set(value) == {"revision", "stopped", "ports", "secrets", "images"},
            "Uygulamanın yerleri kaydı geçersiz.", 503)
    require(isinstance(value["revision"], str) and cfg.REV_RE.fullmatch(value["revision"]) is not None
            and type(value["stopped"]) is bool and all(isinstance(value[k], dict) for k in ("ports", "secrets", "images")),
            "Uygulamanın yerleri kaydı geçersiz.", 503)
    for key, port in value["ports"].items():
        match = PORT_KEY_RE.fullmatch(key)
        require(match is not None and SERVICE_RE.fullmatch(match.group(1)) is not None and int(match.group(2)) < 65536
                and type(port) is int and 0 < port < 65536, "Uygulamanın port kaydı geçersiz.", 503)
    require(len(set(value["ports"].values())) == len(value["ports"]), "Uygulamanın port kaydı geçersiz.", 503)
    for logical, podman in value["secrets"].items():
        require(isinstance(logical, str) and 0 < len(logical) <= 255 and generator.secret_app(podman) == app,
                "Uygulamanın gizli değer kaydı geçersiz.", 503)
    for service, image in value["images"].items():
        require(SERVICE_RE.fullmatch(service) is not None and is_pinned(image), "Uygulamanın imaj kaydı geçersiz.", 503)
    return value


def check_definition(value, app):
    require(isinstance(value, dict) and value.get("name") == app and value.get("format") in ("compose", "kubernetes")
            and isinstance(value.get("services"), list) and value["services"] and isinstance(value.get("secrets"), list),
            "Uygulama tanımı kaydı geçersiz.", 503)
    seen = set()
    for svc in value["services"]:
        require(isinstance(svc, dict) and isinstance(svc.get("name"), str) and SERVICE_RE.fullmatch(svc["name"]) is not None
                and svc["name"] not in seen and isinstance(svc.get("image"), str), "Uygulama tanımı kaydı geçersiz.", 503)
        seen.add(svc["name"])
    return value


def check_answers(value):
    require(isinstance(value, dict) and set(value) == {"name", "answers"} and isinstance(value["answers"], dict),
            "Uygulamanın yanıt kaydı geçersiz.", 503)
    return value


class Records:
    """UYGULAMA_STATE_DIR: one folder per application."""

    def __init__(self, env):
        self.env = env
        self.root = state_root(env)

    def dir(self, app):
        return self.root / app_name(app)

    def names(self):
        """The applications with a record, sorted; anything else in the folder stops the caller (fail closed)."""
        try:
            info = os.lstat(self.root)
        except FileNotFoundError:
            return []
        require(stat.S_ISDIR(info.st_mode) and _private(info), "Uygulama kayıt klasörü güvenli değil.", 503)
        out = []
        for entry in sorted(os.listdir(self.root)):
            require(APP_NAME_RE.fullmatch(entry) is not None, "Uygulama kayıt klasöründe beklenmeyen öge: %s" % entry, 503)
            info = os.lstat(self.root / entry)
            require(stat.S_ISDIR(info.st_mode) and _private(info), "Uygulama kaydı güvenli değil: %s" % entry, 503)
            out.append(entry)
        return out

    def exists(self, app):
        return os.path.lexists(self.dir(app))

    def json_file(self, app, name):
        return cfg.read_private(self.dir(app) / name)

    def need(self, app, name):
        value = self.json_file(app, name)
        require(value is not None, "Uygulama kaydı eksik: %s/%s" % (app, name), 503)
        return value

    def places(self, app):
        return check_places(self.need(app, "yerler.json"), app)

    def text(self, app):
        value = read_text(self.dir(app) / "kaynak.yaml")
        require(value is not None, "Uygulama kaydı eksik: %s/kaynak.yaml" % app, 503)
        return value

    def load(self, app):
        """The whole record: name, text, source, answers, definition, places."""
        app = app_name(app)
        return {"name": app, "text": self.text(app), "source": check_source(self.need(app, "kaynak.json")),
                "answers": check_answers(self.need(app, "yanitlar.json")),
                "definition": check_definition(self.need(app, "tanim.json"), app), "places": self.places(app)}

    def write(self, app, text=None, source=None, answers=None, definition=None, places=None):
        """Writes the given parts; yerler.json first, so the guard sees a new application's bridge at once."""
        cfg.private_dir(self.root)
        cfg.private_dir(self.dir(app))
        if places is not None:
            check_places(places, app)
        for name, value in (("yerler.json", places), ("kaynak.json", source), ("yanitlar.json", answers),
                            ("tanim.json", definition)):
            if value is not None:
                settings.atomic(self.dir(app) / name, json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n", 0o600)
        if text is not None:
            settings.atomic(self.dir(app) / "kaynak.yaml", text, 0o600)

    def env_path(self, app, service):
        """The generator's env_file: UYGULAMA_STATE_DIR/<app>/env/<service>.env."""
        path = Path(_names(generator.env_file, self.env, app_name(app), service))
        require(path.parent == self.dir(app) / "env", "Ortam dosyasının yolu beklenmedik.", 502)
        return path

    def env_files(self, app):
        folder = self.dir(app) / "env"
        try:
            entries = os.listdir(folder)
        except FileNotFoundError:
            return []
        require(not os.path.islink(folder), "Uygulamanın ortam klasörü güvenli değil.", 503)
        return sorted(e for e in entries if e.endswith(".env") and SERVICE_RE.fullmatch(e[:-4]))

    def write_env(self, app, environment):
        """env/<service>.env for every service of the plan; the files of services that went are removed."""
        cfg.private_dir(self.dir(app) / "env")
        for service, text in environment.items():
            require(isinstance(text, str) and "\x00" not in text, "Ortam dosyası geçersiz.", 502)
            settings.atomic(self.env_path(app, service), text, 0o600)
        for name in self.env_files(app):
            if name[:-4] not in environment:
                cfg.unlink(self.dir(app) / "env" / name)

    def snapshot(self, app):
        """Every file of the record as bytes (None: absent), to put back when a change fails."""
        snap = {}
        for name in FILES:
            try:
                snap[name] = settings.read_regular(self.dir(app) / name, 4 * 1024 * 1024)[0]
            except FileNotFoundError:
                snap[name] = None
        for name in self.env_files(app):
            snap["env/" + name] = settings.read_regular(self.dir(app) / "env" / name, 4 * 1024 * 1024)[0]
        return snap

    def restore(self, app, snap):
        cfg.private_dir(self.root)
        cfg.private_dir(self.dir(app))
        for name in FILES:
            if snap.get(name) is None:
                cfg.unlink(self.dir(app) / name)
            else:
                settings.atomic(self.dir(app) / name, snap[name], 0o600)
        keep = {k[4:] for k in snap if k.startswith("env/")}
        if keep:
            cfg.private_dir(self.dir(app) / "env")
        for name in self.env_files(app):
            if name not in keep:
                cfg.unlink(self.dir(app) / "env" / name)
        for name in keep:
            settings.atomic(self.dir(app) / "env" / name, snap["env/" + name], 0o600)

    def remove(self, app):
        """The record folder: only its own regular files and env folder; anything else stops the removal."""
        folder = self.dir(app)
        if not os.path.lexists(folder):
            return
        for name in self.env_files(app):
            cfg.unlink(folder / "env" / name)
        if os.path.lexists(folder / "env"):
            require(not os.listdir(folder / "env"), "Uygulamanın ortam klasöründe beklenmeyen öge var.", 503)
            os.rmdir(folder / "env")
        for name in os.listdir(folder):
            require(name in FILES or name.startswith(".konsol-"), "Uygulama kaydında beklenmeyen öge: %s" % name, 503)
            cfg.unlink(folder / name)
        os.rmdir(folder)


# -- answers and sources
def secret_questions(inspection):
    return {q["id"] for q in inspection.get("questions", [])
            if q.get("kind") == "secret" or (q.get("kind") == "var" and q.get("secret"))}


def stored_answers(inspection, answers):
    """The answers as given, every secret answer (a value or a keep) replaced by {"set": true}."""
    hidden = secret_questions(inspection)
    return {"name": answers.get("name"),
            "answers": {qid: ({"set": True} if qid in hidden else copy.deepcopy(value))
                        for qid, value in sorted((answers.get("answers") or {}).items())}}


def check_url(value):
    require(isinstance(value, str) and 0 < len(value) <= URL_LIMIT and not re.search(r"[\x00-\x20\x7f]", value),
            "Adres geçersiz.")
    try:
        parts = urllib.parse.urlsplit(value)
        port = parts.port
    except ValueError as err:
        raise AppError(400, "Adres geçersiz.") from err
    require(parts.scheme == "https", "Yalnız https:// ile başlayan bir adres alınır.")
    require(bool(parts.hostname) and parts.username is None and parts.password is None,
            "Adreste bir sunucu adı olmalı; kullanıcı adı ve parola yazılamaz.")
    return parts, port or 443


def request_source(value):
    """The kaynak of an install request: {"tur": dosya} or one of adres, imaj, konteyner with its value."""
    require(isinstance(value, dict) and value.get("tur") in SOURCES, "Uygulamanın kaynağı geçersiz.")
    tur = value["tur"]
    require(set(value) == ({"tur"} if tur == "dosya" else {"tur", tur}), "Uygulamanın kaynağı geçersiz.")
    if tur == "adres":
        check_url(value["adres"])
    elif tur == "imaj":
        image_ref(value["imaj"])
    elif tur == "konteyner":
        require(isinstance(value["konteyner"], str) and cfg.NAME_RE.fullmatch(value["konteyner"]) is not None,
                "Konteyner adı geçersiz.")
    return dict(value)


def source_record(source, text, now):
    record = {"tur": source["tur"], "alindi": int(now), "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest()}
    if source["tur"] != "dosya":
        record[source["tur"]] = source[source["tur"]]
    return check_source(record)


def checked_text(text):
    require(isinstance(text, str), "Dosya bir metin olmalı.")
    try:
        size = len(text.encode("utf-8"))
    except UnicodeEncodeError as err:
        raise AppError(400, "Dosya geçerli bir UTF-8 metni değil.") from err
    require(size <= TEXT_LIMIT, "Dosya çok büyük (en çok %d KiB)." % (TEXT_LIMIT // 1024))
    return text


# -- images (the generator's image_reference: Docker's rules, as a Compose file means them)
def reference(value):
    """master_generator.image_reference: (repository, reference); a short name is Docker Hub's, a single name
    its library, no tag is :latest. The pull, the pin and the unit's check all read an image this way."""
    try:
        return generator.image_reference(value)
    except generator.GeneratorError as err:
        raise AppError(400, str(err)) from err


def image_ref(value):
    reference(value)
    return value


def channel(value):
    """The tag an image follows (DD-214), "" when the file pins a digest (nothing to follow)."""
    ref = reference(value)[1]
    return "" if "@" in ref else ref


def is_pinned(value):
    if not isinstance(value, str) or "@" not in value:
        return False
    try:
        repository, ref = generator.image_reference(value)
    except generator.GeneratorError:
        return False
    return ref == value and SHA_RE.fullmatch(value.rpartition("@sha256:")[2]) is not None and value.startswith(repository + "@")


def pinned(info, value):
    """The repo@sha256 digest of a pulled image for its reference, from `podman image inspect`."""
    repository, ref = reference(value)
    digest = ref.partition("@")[2]
    try:
        found = [d for d in info.get("RepoDigests") or [] if isinstance(d, str) and d.startswith(repository + "@sha256:")]
    except AttributeError as err:
        raise AppError(502, "İmaj özeti okunamadı.") from err
    if digest:
        found = [d for d in found if d == repository + "@" + digest]
    require(bool(found) and is_pinned(found[0]), "İmaj sabit bir özete çözümlenemedi: %s" % value, 502)
    return found[0]


def podman_version(text):
    match = re.match(r"\s*([0-9]{1,3})\.([0-9]{1,3})", text or "")
    require(match is not None, "Podman sürümü okunamadı.", 502)
    return int(match.group(1)), int(match.group(2))


# -- the loopback pool
def pool_range(env):
    try:
        first, last = int(env.get("YAYIN_PORT_ILK", "")), int(env.get("YAYIN_PORT_SON", ""))
    except ValueError as err:
        raise AppError(503, "Yerel port aralığı tanımlı değil; kurulumu yeniden çalıştırın.") from err
    require(0 < first <= last < 65536, "Yerel port aralığı geçersiz; kurulumu yeniden çalıştırın.", 503)
    return first, last


def bindable(port):
    """Nothing holds the loopback port now (the test socket is closed at once)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def free_port(env, used, bind=None):
    """The first port of YAYIN_PORT_ILK–YAYIN_PORT_SON that nothing uses and nothing listens on."""
    first, last = pool_range(env)
    for port in range(first, last + 1):
        if port not in used and (bind or bindable)(port):
            return port
    raise AppError(409, "Yerel port aralığında boş port kalmadı.")


def base_ports(env):
    """The base's own ports: every *_PORT key of state.env."""
    return {int(v) for key, v in env.items() if key.endswith("_PORT") and str(v).isdigit() and 0 < int(v) < 65536}


def manual_ports(env):
    """Loopback ports of Yayınla's manual rows (DD-252), until phase 4 replaces them."""
    if not env.get("SETTINGS_FILE"):
        return set()
    import master_publications
    try:
        rows = master_publications.manual(env)
    except (settings.SettingsError, OSError, ValueError, KeyError) as err:
        raise AppError(503, "Yayın kaydı okunamadı; port ayrılmadı.") from err
    return {int(r["upstream"].rpartition(":")[2]) for r in rows.values()}


def wanted_ports(definition):
    """"<service>:<port>/<proto>" of every port answered with an address (a Caddy row, A1)."""
    return [("%s:%d/%s" % (svc["name"], p["port"], p["protocol"])) for svc in definition["services"]
            for p in svc.get("ports", []) if p.get("use") == "caddy"]


def allocate(env, app, definition, previous, records=None, manual=None, bind=None):
    """Pool ports for the definition's address ports: kept for the same key across edits, new ones free of
    every other application's allocation, Yayınla's rows, the base's ports and live listeners."""
    records = records or Records(env)
    used = base_ports(env) | (manual_ports(env) if manual is None else set(manual))
    for other in records.names():
        if other != app:
            used |= set(records.places(other)["ports"].values())
    wanted = wanted_ports(definition)
    result = {key: port for key, port in (previous or {}).items() if key in wanted}
    require(not used & set(result.values()), "Uygulamanın ayrılmış portu başka bir yerde kullanılıyor.", 409)
    used |= set(result.values())
    for key in wanted:
        if key not in result:
            result[key] = free_port(env, used, bind)
            used.add(result[key])
    return dict(sorted(result.items()))


def guard_input(env):
    """The container guard's input (master_container_network): each application's bridge and its
    publications. Phase 3 publishes on 127.0.0.1 only; the Caddy rows come in phase 4."""
    records = Records(env)
    out = []
    for app in records.names():
        # A folder without yerler.json is an install that has not written it yet: leaving it out makes the
        # policy stricter, never wider. Every other unreadable part stops the guard (fail closed).
        if not os.path.lexists(records.dir(app) / "yerler.json"):
            continue
        places = records.places(app)
        publications = []
        for key, port in sorted(places["ports"].items()):
            service, number, protocol = PORT_KEY_RE.fullmatch(key).groups()
            publications.append({"service": service, "port": int(number), "protocol": protocol,
                                 "host_ip": "127.0.0.1", "host_port": port})
        out.append({"app": app, "interface": interface(env, app), "publications": publications})
    return out


# -- the read model
def service_state(unit, running, busy):
    """One service: its unit's ActiveState and whether its container runs (a job on the application wins)."""
    if busy:
        return "islemde"
    if unit in ("activating", "deactivating", "reloading"):
        return "islemde"
    if unit == "failed":
        return "hata"
    if unit == "active":
        return "calisiyor" if running else "hata"
    return "durduruldu"


def app_state(states):
    if "islemde" in states:
        return "islemde"
    if "hata" in states:
        return "hata"
    if all(s == "calisiyor" for s in states):
        return "calisiyor"
    if all(s == "durduruldu" for s in states):
        return "durduruldu"
    return "kismen"


def update_summary(values):
    for state in UPDATE_ORDER:
        if state in values:
            return state
    return "sabit"


def service_update(definition_service, item):
    if not channel(definition_service["image"]):
        return "sabit"
    state = (item or {}).get("state")
    return {"guncel": "guncel", "var": "yeni", "denetlenemedi": "denetlenemedi", "sabit": "sabit"}.get(state, "bilinmiyor")


def summary(record, objects, live, busy, updates):
    """An application of the list: live state per service, resources summed, update state, actions."""
    definition, places = record["definition"], record["places"]
    services, states, cpu, memory, update_states = [], [], [], [], []
    for svc in definition["services"]:
        name = svc["name"]
        container = objects["containers"][name]
        row = live.get("containers", {}).get(container) or {}
        state = service_state(live.get("units", {}).get(objects["units"][name], ""), row.get("state") == "running", bool(busy))
        use = live.get("usage", {}).get(container) or (None, None)
        if use[0] is not None:
            cpu.append(use[0])
        if use[1] is not None:
            memory.append(use[1])
        update = service_update(svc, (updates or {}).get(name))
        update_states.append(update)
        states.append(state)
        services.append({"ad": name, "durum": state, "imaj": svc["image"], "guncelleme": update})
    state = app_state(states)
    actions = []
    if not busy:
        if state != "calisiyor":
            actions.append("baslat")
        if not places["stopped"] or any(s in ("calisiyor", "hata") for s in states):
            actions.append("durdur")
        if state == "calisiyor":
            actions.append("yeniden-baslat")
        if any(channel(s["image"]) for s in definition["services"]):
            actions.append("guncelle")
    return {"ad": record["name"], "durum": state, "bicim": definition["format"], "servisler": services,
            "kaynak": {"cpu": round(sum(cpu), 2) if cpu else None, "bellek": sum(memory) if memory else None},
            "guncelleme": update_summary(update_states), "eylemler": actions, "revizyon": places["revision"],
            "is": busy or None, "koken": record["source"]["tur"], "durduruldu": places["stopped"],
            "uyari": len(definition.get("warnings") or [])}


def mount_rows(env, app, svc):
    rows = []
    for m in svc.get("mounts", []):
        if m.get("to") == "app":
            path = str(data_dir(env, app) / m["folder"])
        elif m.get("to") == "srv":
            path = m["path"]
        else:
            path = None
        rows.append({"hedef": m["target"], "tur": m["to"], "yol": path, "salt_okunur": bool(m.get("read_only"))})
    return rows


def detail(env, record, objects, live, busy, updates, inspected):
    """GET /api/konsol/uygulamalar/{app}: the application with every service, its ports, folders, secrets by
    name only, warnings, source, file, answers (no secret value) and units."""
    item = summary(record, objects, live, busy, updates)
    definition, places = record["definition"], record["places"]
    services = []
    for svc, row in zip(definition["services"], item["servisler"]):
        name = svc["name"]
        container = objects["containers"][name]
        info = inspected.get(container) or {}
        state = info.get("State") or {}
        health = state.get("Health") or {}
        started = master_containers.epoch(state.get("StartedAt")) if state.get("Running") else None
        ports = []
        for p in svc.get("ports", []):
            key = "%s:%d/%s" % (name, p["port"], p["protocol"])
            ports.append({"port": p["port"], "protokol": p["protocol"], "kullanim": p["use"],
                          "tailscale_adi": p.get("tailscale_name"), "yerel_port": places["ports"].get(key)})
        services.append({
            "ad": name, "durum": row["durum"], "baslangic": svc["start"], "kullanici": svc.get("user"),
            "imaj": svc["image"], "ozet": places["images"].get(name), "kanal": channel(svc["image"]),
            "guncelleme": row["guncelleme"], "konteyner": container, "birim": objects["units"][name],
            "calisma": started, "saglik": str(health.get("Status") or "") if isinstance(health, dict) else "",
            "yeniden_baslama": info.get("RestartCount") if type(info.get("RestartCount")) is int else 0,
            "portlar": ports, "baglamalar": mount_rows(env, record["name"], svc),
            "gizliler": sorted({e["secret"] for e in svc.get("environment", []) if "secret" in e}),
        })
    source = record["source"]
    return {
        "uygulama": item, "servisler": services,
        "gizliler": [{"ad": s["name"], "servisler": list(s.get("services") or [])} for s in definition["secrets"]],
        "uyarilar": [{"servis": w.get("service", ""), "metin": w.get("text", "")} for w in definition.get("warnings") or []],
        "koken": {"tur": source["tur"], "adres": source.get("adres"), "imaj": source.get("imaj"),
                  "konteyner": source.get("konteyner"), "alindi": source["alindi"], "sha256": source["sha256"]},
        "metin": record["text"], "yanitlar": record["answers"], "birimler": list(objects["files"]),
        "veri": str(data_dir(env, record["name"])), "ag": objects["network"], "pod": objects["pod"],
    }


# -- an edit's plan (Tanım, K3): what changes, nothing written
def placeholders(definition, keep=None):
    """Pinned-looking references for a render without a pull: a service whose image did not change keeps its
    digest, any other gets a zero digest (its unit then reads as changed, which it is)."""
    keep = keep or {}
    return {s["name"]: keep.get(s["name"]) or reference(s["image"])[0] + "@sha256:" + "0" * 64
            for s in definition["services"]}


def placeholder_secrets(app, definition, kept=None):
    """Podman secret names for a render before any secret exists: a kept value keeps its own name."""
    kept = kept or {}
    return {item["name"]: kept.get(item["name"]) or generator.secret_name(app, "%08x" % n)
            for n, item in enumerate(definition["secrets"])}


def kept_images(old_definition, places, definition):
    """{service: pinned digest} for the services whose image text is the same as before."""
    before = {s["name"]: s["image"] for s in old_definition["services"]}
    return {s["name"]: places["images"][s["name"]] for s in definition["services"]
            if before.get(s["name"]) == s["image"] and s["name"] in places["images"]}


def difference(record, definition, old_plan, new_plan, ports, version=None):
    """TanimFarki: per unit (added, removed, changed), the services whose environment file changes, port,
    folder (a dropped one stays on disk), secret (new, renewed, kept, dropped), start mode and the new
    definition's warnings."""
    old_definition, places = record["definition"], record["places"]
    units = []
    for name in sorted(set(old_plan["units"]) | set(new_plan["units"])):
        if name not in old_plan["units"]:
            units.append({"ad": name, "degisim": "eklenir"})
        elif name not in new_plan["units"]:
            units.append({"ad": name, "degisim": "kaldirilir"})
        elif old_plan["units"][name] != new_plan["units"][name]:
            units.append({"ad": name, "degisim": "degisir"})
    environment = sorted(svc for svc in set(old_plan["environment"]) | set(new_plan["environment"])
                         if old_plan["environment"].get(svc) != new_plan["environment"].get(svc))
    port_rows = [{"anahtar": key, "degisim": "kalir" if key in places["ports"] else "eklenir", "yerel_port": port}
                 for key, port in sorted(ports.items())]
    port_rows += [{"anahtar": key, "degisim": "kaldirilir", "yerel_port": port}
                  for key, port in sorted(places["ports"].items()) if key not in ports]
    old_folders, new_folders = set(old_plan["folders"]), set(new_plan["folders"])
    secrets = {"yeni": [], "yenilenen": [], "korunan": [], "kaldirilan": []}
    names = set()
    for item in definition["secrets"]:
        names.add(item["name"])
        if item.get("keep"):
            secrets["korunan"].append(item["name"])
        elif item["name"] in places["secrets"]:
            secrets["yenilenen"].append(item["name"])
        else:
            secrets["yeni"].append(item["name"])
    secrets["kaldirilan"] = sorted(set(places["secrets"]) - names)
    before = {s["name"]: s["start"] for s in old_definition["services"]}
    warnings = [{"servis": w.get("service", ""), "metin": w.get("text", "")} for w in definition.get("warnings") or []]
    refusal = generator.podman5_refusal(new_plan, version) if version is not None else None
    if refusal:
        warnings.append({"servis": "", "metin": refusal})
    return {"birimler": units, "ortam": environment, "portlar": port_rows,
            "klasorler": {"eklenen": sorted(new_folders - old_folders), "birakilan": sorted(old_folders - new_folders)},
            "gizliler": {k: sorted(v) for k, v in secrets.items()},
            "baslangic": [{"servis": s["name"], "once": before.get(s["name"]), "sonra": s["start"]} for s in definition["services"]],
            "uyarilar": warnings, "yeniden_baslar": bool(units or environment) and not places["stopped"]}


def edit_plan(env, record, inspection, definition, ports, version, module=None):
    """The differences an edit makes (TanimFarki), from two renders; no pull, no secret, nothing written."""
    app, places = record["name"], record["places"]
    old_plan = render(env, app, record["definition"], places, version, module)
    secrets = placeholder_secrets(app, definition, {s["name"]: places["secrets"][s["name"]] for s in definition["secrets"]
                                                   if s.get("keep")})
    candidate = {"revision": places["revision"], "stopped": places["stopped"], "ports": ports, "secrets": secrets,
                 "images": placeholders(definition, kept_images(record["definition"], places, definition))}
    new_plan = render(env, app, definition, candidate, version, module)
    return difference(record, definition, old_plan, new_plan, ports, version)


def new_questions(inspection, stored):
    """The ids of an inspection's questions that the stored answers do not answer yet."""
    known = set((stored or {}).get("answers") or {})
    return [q["id"] for q in inspection.get("questions", []) if q.get("kind") != "name" and q["id"] not in known]


# -- drafts (K2): a Compose text written by Obhut, nothing else
KEY_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]*\Z")
PLAIN_WORDS = frozenset(("true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"))


def _quote(text, interpolate=True):
    """A YAML double-quoted scalar; "$" doubled where Compose would read a variable."""
    out = []
    for c in text:
        o = ord(c)
        if c in '"\\':
            out.append("\\" + c)
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif o < 0x20 or 0x7f <= o <= 0x9f or c in "  ﻿" or 0xd800 <= o <= 0xdfff:
            out.append("\\u%04x" % o if o <= 0xffff else "\\U%08x" % o)
        elif c == "$" and interpolate:
            out.append("$$")
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


def _key(key):
    key = str(key)
    if KEY_RE.fullmatch(key) and key.lower() not in PLAIN_WORDS:
        return key
    return _quote(key, interpolate=False)


def _scalar(value):
    if value is None:
        return "null"
    if value is True or value is False:
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return _quote(str(value))


def emit(value, indent=0):
    """YAML block lines for dicts, lists and scalars; empty collections in flow form."""
    pad = "  " * indent
    lines = []
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, (dict, list)) and item:
                lines.append("%s%s:" % (pad, _key(key)))
                lines.extend(emit(item, indent + 1))
            elif isinstance(item, dict):
                lines.append("%s%s: {}" % (pad, _key(key)))
            elif isinstance(item, list):
                lines.append("%s%s: []" % (pad, _key(key)))
            else:
                lines.append("%s%s: %s" % (pad, _key(key), _scalar(item)))
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, dict) and item:
                inner = emit(item, indent + 1)
                lines.append("%s- %s" % (pad, inner[0].lstrip()))
                lines.extend(inner[1:])
            elif isinstance(item, list) and item:
                lines.append("%s-" % pad)
                lines.extend(emit(item, indent + 1))
            else:
                lines.append("%s- %s" % (pad, "{}" if isinstance(item, dict) else "[]" if isinstance(item, list) else _scalar(item)))
    return lines


def compose_text(header, document):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return "# Obhut taslağı: %s (%s).\n# Gözden geçirin; denetçi her satırı yeniden denetler.\n%s\n" % (
        header.replace("\n", " "), stamp, "\n".join(emit(document)))


def service_name(text, fallback="uygulama"):
    name = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(text or "")).strip("-._")[:63].rstrip("-._")
    return name if SERVICE_RE.fullmatch(name or "") else fallback


def project_name(text):
    import master_compose
    return master_compose.app_name(text)


def _ports(keys):
    out = []
    for key in sorted(keys, key=lambda k: (int(k.partition("/")[0]) if k.partition("/")[0].isdigit() else 0, k)):
        number, _, protocol = str(key).partition("/")
        if number.isdigit():
            out.append(number if protocol in ("", "tcp") else "%s/%s" % (number, protocol))
    return out


def image_draft(image, info):
    """POST …/kaynak {"tur": "imaj"}: one service named after the repository, the image as given, its
    exposed ports and its volumes as named volumes; nothing else."""
    reference_of = reference
    config = (info or {}).get("Config") or {}
    service = service_name(reference_of(image)[0].rsplit("/", 1)[-1])
    volumes, named = [], {}
    for path in sorted(config.get("Volumes") or {}):
        if not isinstance(path, str) or not path.startswith("/"):
            continue
        base = service_name("%s-%s" % (service, path.rstrip("/").rsplit("/", 1)[-1] or "veri"), service + "-veri").lower()
        candidate, n = base, 2
        while candidate in named:
            candidate, n = "%s-%d" % (base, n), n + 1
        named[candidate] = {}
        volumes.append({"type": "volume", "source": candidate, "target": path})
    body = {"image": image}
    ports = _ports(config.get("ExposedPorts") or {})
    if ports:
        body["ports"] = ports
    if volumes:
        body["volumes"] = volumes
    document = {"name": project_name(service) or "uygulama", "services": {service: body}}
    if named:
        document["volumes"] = named
    return compose_text("%s imajından (podman image inspect)" % image, document)


PODMAN_ENV = ("container", "HOSTNAME")


def _env_map(entries):
    out = {}
    for entry in entries or []:
        key, sep, value = str(entry).partition("=")
        if sep:
            out[key] = value
    return out


def _words(value):
    if value is None:
        return None
    if isinstance(value, list):
        return [str(v) for v in value]
    return str(value)


def container_draft(info, image_info):
    """POST …/kaynak {"tur": "konteyner"}: a Compose draft from `podman inspect` of a standalone container.
    Settings that differ from the image's, the environment without the image's own entries (every
    secret-looking name left empty, never a value), ports, mounts, restart, capabilities, and every
    setting the inspector refuses written as it is, so that the inspector shows why."""
    import master_inspector
    config, host = info.get("Config") or {}, info.get("HostConfig") or {}
    base = (image_info or {}).get("Config") or {}
    name = str(info.get("Name", "")).lstrip("/")
    service = service_name(name)
    body = {"image": str(info.get("ImageName") or config.get("Image") or "")}
    for key, field in (("command", "Cmd"), ("entrypoint", "Entrypoint")):
        mine, theirs = _words(config.get(field)), _words(base.get(field))
        if mine not in (None, "", []) and mine != theirs:
            body[key] = mine
    for key, field in (("working_dir", "WorkingDir"), ("user", "User")):
        mine = str(config.get(field) or "")
        if mine and mine != str(base.get(field) or "") and not (key == "working_dir" and mine == "/"):
            body[key] = mine
    image_env = _env_map(base.get("Env"))
    environment = {}
    for key, value in _env_map(config.get("Env")).items():
        if key in PODMAN_ENV or image_env.get(key) == value:
            continue
        environment[key] = "" if master_inspector.secret_name(key) else value
    if environment:
        body["environment"] = dict(sorted(environment.items()))
    ports = set((host.get("PortBindings") or {}).keys()) | set((config.get("ExposedPorts") or {}).keys())
    if ports:
        body["ports"] = _ports(ports)
    volumes, named = [], {}
    for m in sorted(info.get("Mounts") or [], key=lambda m: str(m.get("Destination", ""))):
        if not isinstance(m, dict) or not isinstance(m.get("Destination"), str):
            continue
        row = {"target": m["Destination"]}
        if m.get("Type") == "volume" and m.get("Name"):
            row = {"type": "volume", "source": m["Name"], **row}
            named[m["Name"]] = {}
        elif m.get("Type") == "bind":
            row = {"type": "bind", "source": str(m.get("Source") or ""), **row}
        else:
            continue
        if m.get("RW") is False:
            row["read_only"] = True
        volumes.append(row)
    if volumes:
        body["volumes"] = volumes
    tmpfs = sorted(str(k) for k in (host.get("Tmpfs") or {}))
    if tmpfs:
        body["tmpfs"] = tmpfs
    policy = host.get("RestartPolicy") or {}
    restart = str(policy.get("Name") or "")
    if restart and restart != "no":
        retries = policy.get("MaximumRetryCount")
        body["restart"] = "%s:%d" % (restart, retries) if restart == "on-failure" and type(retries) is int and retries > 0 else restart
    import master_compose
    added = [str(c) for c in host.get("CapAdd") or []]
    if added:
        body["cap_add"] = added
    # Podman lists the capabilities its default set already lacks (MKNOD, NET_RAW, …) as dropped; only a drop
    # from the default set says something.
    dropped = [str(c) for c in host.get("CapDrop") or [] if master_compose.capability(c) in master_compose.DEFAULT_CAPS]
    if dropped:
        body["cap_drop"] = dropped
    if host.get("ReadonlyRootfs") is True:
        body["read_only"] = True
    if host.get("Init") is True:
        body["init"] = True
    # Refused settings, as the container has them.
    if host.get("Privileged") is True:
        body["privileged"] = True
    devices = ["%s:%s%s" % (d.get("PathOnHost", ""), d.get("PathInContainer", ""),
                            ":" + d["CgroupPermissions"] if d.get("CgroupPermissions") else "")
               for d in host.get("Devices") or [] if isinstance(d, dict)]
    if devices:
        body["devices"] = devices
    mode = str(host.get("NetworkMode") or "")
    if mode == "host" or mode.startswith(("container:", "ns:")):
        body["network_mode"] = mode
    for key, field in (("pid", "PidMode"), ("ipc", "IpcMode")):
        if str(host.get(field) or "") == "host":
            body[key] = "host"
    for key, field in (("security_opt", "SecurityOpt"), ("dns", "Dns"), ("extra_hosts", "ExtraHosts"),
                       ("group_add", "GroupAdd")):
        values = [str(v) for v in host.get(field) or []]
        if values:
            body[key] = values
    if host.get("Sysctls"):
        body["sysctls"] = {str(k): str(v) for k, v in sorted(host["Sysctls"].items())}
    document = {"name": project_name(name) or "uygulama", "services": {service: body}}
    if named:
        document["volumes"] = named
    return compose_text("%s konteynerinden (podman inspect)" % name, document)


# -- the address draft
def blocked_networks(env):
    """VPN_BLOCK_DEST4/6 of defaults.env (private, CGNAT, link-local, multicast, NAT64, …); missing fails closed."""
    blocks = []
    for key in ("VPN_BLOCK_DEST4", "VPN_BLOCK_DEST6"):
        items = str(env.get(key, "")).split()
        require(bool(items), "Engelli adres listesi yok; kurulumu yeniden çalıştırın.", 503)
        for item in items:
            try:
                blocks.append(ipaddress.ip_network(item, strict=True))
            except ValueError as err:
                raise AppError(503, "Engelli adres listesi geçersiz; kurulumu yeniden çalıştırın.") from err
    return blocks


def public(address, blocks):
    """Only a global unicast address: never loopback, private, link-local, CGNAT, the tailnet, multicast,
    reserved, unspecified, nor an IPv4 address hidden in IPv6."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if ip.version == 6:
        if ip.ipv4_mapped or ip.sixtofour or ip.teredo:
            return False
    if not ip.is_global or ip.is_multicast or ip.is_reserved or ip.is_unspecified or ip.is_loopback or \
            ip.is_link_local or ip.is_private:
        return False
    return not any(ip.version == net.version and ip in net for net in blocks)


class _Pinned(http.client.HTTPSConnection):
    """HTTPS to an already checked address: SNI, certificate and Host from the URL, no second lookup."""

    def __init__(self, host, address, port, timeout, context):
        super().__init__(host, port, timeout=timeout, context=context)
        self.address = address

    def connect(self):
        sock = socket.create_connection((self.address, self.port), self.timeout)
        try:
            self.sock = self._context.wrap_socket(sock, server_hostname=self.host)
        except BaseException:
            sock.close()
            raise


def resolve(host, port):
    return [info[4][0] for info in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)]


def fetch(url, env, lookup=None, connection=None, clock=time.monotonic):
    """POST …/kaynak {"tur": "adres"}: the text at an https address (K2). Every address the name resolves to
    must be public; the connection goes to a checked one; at most 3 redirects, each checked the same way;
    256 KiB, 10 s, UTF-8 text only. Returns the text."""
    blocks = blocked_networks(env)
    deadline = clock() + FETCH_SECONDS
    lookup = lookup or resolve
    connection = connection or (lambda host, address, port, timeout: _Pinned(host, address, port, timeout,
                                                                                 ssl.create_default_context()))
    current = url
    for _hop in range(FETCH_REDIRECTS + 1):
        parts, port = check_url(current)
        host = parts.hostname
        try:
            addresses = lookup(host, port)
        except (OSError, UnicodeError) as err:
            raise AppError(502, "Adres çözümlenemedi: %s" % host) from err
        require(bool(addresses), "Adres çözümlenemedi: %s" % host, 502)
        for address in addresses:
            require(public(address, blocks), "%s yerel, özel ya da ayrılmış bir adrese (%s) çözümleniyor; yalnız "
                    "internetteki bir adres alınır." % (host, address))
        left = deadline - clock()
        require(left > 0, "Adres zamanında yanıt vermedi.", 502)
        path = (parts.path or "/") + ("?" + parts.query if parts.query else "")
        conn = connection(host, addresses[0], port, left)
        try:
            try:
                conn.request("GET", path, headers={"User-Agent": "Obhut", "Accept": "*/*", "Accept-Encoding": "identity",
                                                   "Connection": "close"})
                response = conn.getresponse()
            except (OSError, http.client.HTTPException, ssl.SSLError) as err:
                raise AppError(502, "Adrese bağlanılamadı ya da sertifikası doğrulanamadı: %s" % host) from err
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader("Location") or ""
                require(bool(location), "Adres yönlendirdi ama yeni adres vermedi.", 502)
                current = urllib.parse.urljoin(current, location)
                continue
            require(response.status == 200, "Adres %d yanıtı verdi." % response.status, 502)
            require((response.getheader("Content-Encoding") or "identity").lower() == "identity",
                    "Adres sıkıştırılmış bir yanıt verdi; düz metin gerekir.", 502)
            chunks, size = [], 0
            while True:
                left = deadline - clock()
                require(left > 0, "Adres zamanında yanıt vermedi.", 502)
                if getattr(conn, "sock", None) is not None:
                    conn.sock.settimeout(left)
                try:
                    chunk = response.read1(65536)
                except (OSError, http.client.HTTPException) as err:
                    raise AppError(502, "Adresten okunamadı.") from err
                if not chunk:
                    break
                size += len(chunk)
                require(size <= TEXT_LIMIT, "Dosya çok büyük (en çok %d KiB)." % (TEXT_LIMIT // 1024))
                chunks.append(chunk)
            try:
                text = b"".join(chunks).decode("utf-8")
            except UnicodeDecodeError as err:
                raise AppError(400, "Adresteki dosya UTF-8 bir metin değil.") from err
            require("\x00" not in text, "Adresteki dosya bir metin değil.")
            return text
        finally:
            conn.close()
    raise AppError(502, "Adres en çok %d kez yönlendirebilir." % FETCH_REDIRECTS)
