#!/usr/bin/env python3
"""Applications (rebuild DD-271, phase 3): an application installed from its own Compose or Kubernetes
file. This module holds what the root backend and the root worker share: the record, the loopback pool,
the container guard's input, the read model, an install's summary, what the records use and the cleanup's items
(Gelişmiş, K8), folder sizes and the drafts. The worker (master_container_worker) runs the lifecycle; the backend
only reads (master-panel.service keeps its sandbox).

Record, UYGULAMA_STATE_DIR/<app>/ (0700 root; every file 0600, written atomically, read without following
a link, its owner, mode and size checked):

  kaynak.yaml    the file exactly as the operator gave it
  kaynak.json    {"tur": dosya|adres|imaj, "adres"?, "imaj"?, "alindi": epoch, "sha256": hex}
  yanitlar.json  the answers as given, without the port answers; every secret answer is {"set": true}
  tanim.json     the checked definition (master_inspector.check), each port only {"port", "protocol"}
  yerler.json    {"revision", "stopped", "ports": {"<service>:<port>/<proto>": pool port},
                  "secrets": {logical name: Podman secret}, "images": {service: "repo@sha256:…"}}
  erisim.json    the access rows (rebuild phase 4), one per port of the definition (see below)
  env/<service>.env   the non-secret environment the generator's plan holds

The record is the single source: the units are generated again from it whenever the worker writes them.
Nothing runs unasked (no reconcile). Data lives in UYGULAMA_VERI_DIR/<app>/<folder>/ (A5).

Access rows (erisim.json, the home of how a port is reached; Erişim changes them through the settings
transaction, the worker seeds and drops them with the definition):

  {"satirlar": {"<service>:<port>/<proto>":
      {"tur": "adres", "ad": label, "tailscale_portu": null | port, "internet": "" | host name}   (TCP only)
    | {"tur": "ham", "kapsam": "kapali" | "tailscale" | "internet", "port": host port}}}

An address row's pool port is yerler.json's ports entry of the same key (exactly the address rows have one); a
raw row is published on the address state.env names now (TAILSCALE_IPV4, WAN_IPV4) and its host port, only
while it is not kapali. Its row id everywhere is uygulama:<app>:<key> (row_id). Install seeds the rows from the
answers (an address with the answered name, no Tailscale port, no internet name; a raw port closed on its own
number); an edit keeps the row of a port that stays, seeds a new port's and drops a gone port's (and its pool
port); removal takes them with the record. Anything unexpected in the file stops its reader (fail closed).

Drafts (K2) turn an https address or an image into a Compose text for the inspector; nothing is
written. Python standard library only.
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
import threading
import time
import urllib.parse

import master_container_config as cfg
import master_containers
import master_generator as generator
import master_https as tls
import master_inspector as inspector
import master_settings as settings

# The generator owns every name (its names table); these are the inspector's and the readers' own rules.
APP_NAME_RE = generator.APP_NAME_RE
SERVICE_RE = generator.SERVICE_RE
# One rule for every Tailscale name (applications, Konsol, Paylaşımlar): the inspector's.
TAILSCALE_NAME_RE = inspector.TAILSCALE_NAME_RE
RESERVED_NAMES = inspector.RESERVED_NAMES
# "<service>:<port>/<proto>": the service part is checked with SERVICE_RE.
PORT_KEY_RE = re.compile(r"([^:]+):([1-9][0-9]{0,4})/(tcp|udp)\Z")
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
URL_LIMIT = 2048
TEXT_LIMIT = 262144  # master_yaml.LIMIT_BYTES (a test keeps the two equal)
SOURCES = ("dosya", "adres", "imaj")
ROWS_FILE = "erisim.json"
FILES = ("kaynak.yaml", "kaynak.json", "yanitlar.json", "tanim.json", "yerler.json", ROWS_FILE)
ROW_KINDS = ("adres", "ham")
SCOPES = ("kapali", "tailscale", "internet")
# state.env's key for the address an open raw row of each scope is published on.
SCOPE_ADDRESS = {"tailscale": "TAILSCALE_IPV4", "internet": "WAN_IPV4"}
ROW_PREFIX = "uygulama:"
# The applications' own DNS file (DNSMASQ_CONF_DIR): one interface-name line per address row, written by the
# publication projection. Name checks read the rows instead of it.
DNS_FILE = "modul-uygulama.conf"
ROW_CHANGED = "Bu portun kullanımı Erişim'den değişir."
MANAGED = generator.MANAGED_VALUE
APP_LABEL = generator.APP_LABEL
TAILS = (100, 200, 500, 1000)
# The address draft (K2): at most this many redirects, in this many seconds, of this size.
FETCH_SECONDS = 10.0
FETCH_REDIRECTS = 3
UPDATE_ORDER = ("yeni", "denetlenemedi", "bilinmiyor", "guncel", "sabit")
# Folder sizes (Dosyalar → Depolama, Podman's cleanup): one read spends at most SIZE_SECONDS walking the folders it
# has not measured; a measurement is kept SIZE_TTL seconds, a walk that ran out of time or could not read SIZE_FAIL_TTL.
SIZE_SECONDS = 5.0
SIZE_TTL = 300
SIZE_FAIL_TTL = 60
# Podman's cleanup (K8): at most this many items in one job; Podman's default network is never offered.
CLEANUP_LIMIT = 200
CLEANUP_KINDS = {"imajlar": "imaj", "aglar": "ag", "birimler": "birim", "klasorler": "klasor"}
DEFAULT_NETWORK = "podman"
IMAGE_ID_RE = re.compile(r"[0-9a-f]{64}\Z")

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


def context(env, app, places, version, rows):
    """The generator's context: what the engine allocated (an address row's pool port), the open raw rows on
    the address state.env names now, and the state.env keys it reads."""
    return {"app": app, "images": dict(places["images"]), "ports": dict(places["ports"]), "secrets": dict(places["secrets"]),
            "raw": raw_hosts(env, rows), "stopped": places["stopped"], "podman": tuple(version),
            "env": {k: env.get(k, "") for k in generator.ENV_KEYS}}


def render(env, app, definition, places, version, rows, module=None):
    """The generator's plan for a definition, its places and its access rows; its units, start order and
    folders must be the application's own."""
    module = module or generator
    try:
        plan = module.render(definition, context(env, app, places, version, rows))
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


def _port_number(value):
    return type(value) is int and 0 < value < 65536


def check_definition(value, app):
    """tanim.json: the checked definition, each port only its number and protocol (stored_definition)."""
    require(isinstance(value, dict) and value.get("name") == app and value.get("format") in ("compose", "kubernetes")
            and isinstance(value.get("services"), list) and value["services"] and isinstance(value.get("secrets"), list),
            "Uygulama tanımı kaydı geçersiz.", 503)
    seen, keys = set(), set()
    for svc in value["services"]:
        require(isinstance(svc, dict) and isinstance(svc.get("name"), str) and SERVICE_RE.fullmatch(svc["name"]) is not None
                and svc["name"] not in seen and isinstance(svc.get("image"), str) and isinstance(svc.get("ports"), list),
                "Uygulama tanımı kaydı geçersiz.", 503)
        seen.add(svc["name"])
        for port in svc["ports"]:
            require(isinstance(port, dict) and set(port) == {"port", "protocol"} and _port_number(port["port"])
                    and port["protocol"] in ("tcp", "udp") and port_key(svc["name"], port) not in keys,
                    "Uygulama tanımının port kaydı geçersiz.", 503)
            keys.add(port_key(svc["name"], port))
    return value


def check_answers(value):
    """yanitlar.json: the answers without a port answer (the rows hold those)."""
    require(isinstance(value, dict) and set(value) == {"name", "answers"} and isinstance(value["answers"], dict)
            and not any(str(qid).startswith("port:") for qid in value["answers"]),
            "Uygulamanın yanıt kaydı geçersiz.", 503)
    return value


# -- access rows (erisim.json; the module's docstring has the shape)
def port_key(service, port):
    """"<service>:<port>/<proto>" of one port of a definition: its row's key and its question's id after "port:"."""
    return "%s:%d/%s" % (service, port["port"], port["protocol"])


def port_keys(definition):
    """The keys of every port of a definition, in its order."""
    return [port_key(svc["name"], p) for svc in definition["services"] for p in svc.get("ports", [])]


def row_id(app, key):
    """A row's id everywhere (Erişim, the firewall view, plans, the audit): uygulama:<app>:<key>."""
    return ROW_PREFIX + app_name(app) + ":" + key


def stored_definition(definition):
    """The definition as tanim.json holds it: each port only its number and protocol (its row is how it is reached)."""
    out = copy.deepcopy(definition)
    for svc in out["services"]:
        svc["ports"] = [{"port": p["port"], "protocol": p["protocol"]} for p in svc.get("ports", [])]
    return out


def row_problem(key, row):
    """Why a row cannot be stored, in Turkish, or None."""
    match = PORT_KEY_RE.fullmatch(key) if isinstance(key, str) else None
    if match is None or SERVICE_RE.fullmatch(match.group(1)) is None or int(match.group(2)) > 65535:
        return "Erişim satırının anahtarı geçersiz."
    if not isinstance(row, dict) or row.get("tur") not in ROW_KINDS:
        return "Erişim satırı bir adres ya da doğrudan port olmalı."
    if row["tur"] == "ham":
        if set(row) != {"tur", "kapsam", "port"} or row["kapsam"] not in SCOPES:
            return "Doğrudan port satırı kapsamını (kapalı, Tailscale ya da internet) ve portunu taşır."
        if not _port_number(row["port"]):
            return "Doğrudan portun numarası 1–65535 arasında olmalı."
        return None
    if set(row) != {"tur", "ad", "tailscale_portu", "internet"}:
        return "Adres satırı Tailscale adını, Tailscale portunu ve internet adını taşır."
    if match.group(3) != "tcp":
        return "UDP portu yalnız doğrudan port olabilir."
    if not isinstance(row["ad"], str) or TAILSCALE_NAME_RE.fullmatch(row["ad"]) is None:
        return "Tailscale adı küçük harf, rakam ve '-' içermeli, '-' ile başlayıp bitmemeli (en çok 63)."
    if row["ad"] in RESERVED_NAMES:
        return "%s adı Obhut'undur." % row["ad"]
    if row["tailscale_portu"] is not None and not _port_number(row["tailscale_portu"]):
        return "Tailscale portu 1–65535 arasında olmalı ya da kapalı (null) olmalı."
    if not isinstance(row["internet"], str):
        return "İnternet adı bir metin olmalı."
    if row["internet"]:
        try:
            if tls.domain(row["internet"]) != row["internet"]:
                return "İnternet adı küçük harfle ve sonunda nokta olmadan yazılır."
        except settings.SettingsError as err:
            return str(err)
    return None


def check_row(key, row, status=503):
    """One access row; status 503 for a stored row (the record), 400 for a request's."""
    problem = row_problem(key, row)
    if problem:
        raise AppError(status, ("Uygulamanın erişim kaydı geçersiz (%s): %s" % (key, problem)) if status == 503 else problem)
    return row


def row_claims(key, row):
    """What a row holds alone: its Tailscale name, its internet name, its Tailscale port (Caddy on the Tailscale
    IPv4, TCP) and an open raw port (its scope's address and protocol); [(claim, Turkish text)]."""
    protocol = key.rpartition("/")[2]
    if row["tur"] == "ham":
        if row["kapsam"] == "kapali":
            return []
        scope = "Tailscale" if row["kapsam"] == "tailscale" else "İnternet"
        return [((row["kapsam"], protocol, row["port"]), "%s %s portu %d" % (scope, protocol.upper(), row["port"]))]
    claims = [(("ad", row["ad"]), "Tailscale adı %s" % row["ad"])]
    if row["internet"]:
        claims.append((("internet-adi", row["internet"]), "İnternet adı %s" % row["internet"]))
    if row["tailscale_portu"] is not None:
        claims.append((("tailscale", "tcp", row["tailscale_portu"]), "Tailscale TCP portu %d" % row["tailscale_portu"]))
    return claims


def row_conflict(items):
    """The first clash among rows [(row id, key, row)] of one or of every application, or None: a Tailscale name, an
    internet name, a Tailscale port or an open raw port held twice on the same address and protocol."""
    seen = {}
    for ident, key, row in items:
        for claim, text in row_claims(key, row):
            other = seen.setdefault(claim, ident)
            if other != ident:
                return "%s iki satırda kullanılıyor: %s ve %s." % (text, other, ident)
    return None


def check_rows(value, places=None, definition=None):
    """erisim.json: {"satirlar": {key: row}} → {key: row}. With places, exactly the address rows have a pool port;
    with the definition, every port has exactly one row."""
    require(isinstance(value, dict) and set(value) == {"satirlar"} and isinstance(value["satirlar"], dict)
            and len(value["satirlar"]) <= inspector.MAX_PORTS, "Uygulamanın erişim kaydı geçersiz.", 503)
    rows = value["satirlar"]
    for key, row in rows.items():
        check_row(key, row)
    clash = row_conflict([(key, key, row) for key, row in sorted(rows.items())])
    require(clash is None, "Uygulamanın erişim kaydı geçersiz: %s" % clash, 503)
    if places is not None:
        require(set(address_keys(rows)) == set(places["ports"]),
                "Uygulamanın erişim kaydı yerel portlarıyla uyuşmuyor.", 503)
    if definition is not None:
        require(sorted(rows) == sorted(port_keys(definition)), "Uygulamanın erişim kaydı tanımın portlarıyla uyuşmuyor.", 503)
    return rows


def address_keys(rows):
    """The keys of the address rows: the ports that have a 127.0.0.1 pool port."""
    return sorted(k for k, r in rows.items() if r["tur"] == "adres")


def seed_row(port):
    """A new port's row from its answer (a port of master_inspector.check's definition): an address with the
    answered Tailscale name, no Tailscale port and no internet name; a raw port closed on its own number (A2)."""
    if port.get("use") == "caddy":
        return {"tur": "adres", "ad": port["tailscale_name"], "tailscale_portu": None, "internet": ""}
    return {"tur": "ham", "kapsam": "kapali", "port": port["port"]}


def next_rows(definition, rows=None):
    """The rows of a checked definition (install: rows None; an edit: the current rows): a port that stays keeps
    its row, a new port gets one from its answer, a port that went has none."""
    rows = rows or {}
    out = {}
    for svc in definition["services"]:
        for port in svc.get("ports", []):
            key = port_key(svc["name"], port)
            out[key] = copy.deepcopy(rows[key]) if key in rows else seed_row(port)
    return out


def port_answer(row):
    """The answer of a port question that a row stands for."""
    if row["tur"] == "adres":
        return {"use": "caddy", "tailscale_name": row["ad"]}
    return {"use": "raw"}


def filled_answers(record):
    """The stored answers with every port answer filled from its row (yenile)."""
    answers = dict(record["answers"]["answers"])
    for key, row in record["rows"].items():
        answers["port:" + key] = port_answer(row)
    return {"name": record["answers"]["name"], "answers": dict(sorted(answers.items()))}


def port_answers(record, inspection, answers):
    """An edit's answers with the questions of the ports that stay answered from their rows: (answers, errors). An
    answer given for such a port must be the one its row stands for (how a port is reached changes in Erişim);
    a new port's question needs its own answer."""
    if not isinstance(answers, dict) or not isinstance(answers.get("answers"), dict):
        return answers, {}
    given, errors = dict(answers["answers"]), {}
    for q in inspection.get("questions", []):
        key = q["id"][len("port:"):] if q.get("kind") == "port" else None
        if key not in record["rows"]:
            continue
        expected = port_answer(record["rows"][key])
        if q["id"] not in given:
            given[q["id"]] = expected
        elif given[q["id"]] != expected:
            errors[q["id"]] = ROW_CHANGED
    return dict(answers, answers=given), errors


def local_domain(env):
    value = env.get("LOCAL_DOMAIN", "")
    require(isinstance(value, str) and re.fullmatch(settings.DOMAIN_RE, value) is not None,
            "Yerel alan adı tanımlı değil; kurulumu yeniden çalıştırın.", 503)
    return value


def taken_names(env, skip_app=None, skip_rows=(), records=None):
    """Every name of the local domain an application's Tailscale name may not take (full names): Konsol's and
    Paylaşımlar's (panel., paylas.), every interface-name of the base's DNS file and of the modul-*.conf files other
    than the applications' own (DNS_FILE, their projection), the operator's DNS records and the Tailscale name of
    every application row. skip_app leaves one application's rows out (its edit: a name it keeps is its own),
    skip_rows single row ids (a rename)."""
    domain = local_domain(env)
    names = {name + "." + domain for name in RESERVED_NAMES}
    paths = [Path(env["DNSMASQ_CONF_FILE"])] if env.get("DNSMASQ_CONF_FILE") else []
    if env.get("DNSMASQ_CONF_DIR"):
        paths += [p for p in sorted(Path(env["DNSMASQ_CONF_DIR"]).glob("modul-*.conf")) if p.name != DNS_FILE]
    for path in paths:
        try:
            text = settings.read_regular(path, 1 << 20)[0].decode("utf-8")
        except FileNotFoundError:
            continue
        except (OSError, UnicodeDecodeError, settings.SettingsError) as err:
            raise AppError(503, "Yerel DNS adları okunamadı; Tailscale adı denetlenemedi.") from err
        for line in text.splitlines():
            if line.startswith("interface-name="):
                names.add(line.partition("=")[2].partition(",")[0])
    if env.get("SETTINGS_FILE"):
        try:
            saved = settings.read_json(env["SETTINGS_FILE"], {})
        except settings.SettingsError as err:
            raise AppError(503, "Ayar kaydı okunamadı; Tailscale adı denetlenemedi.") from err
        dns = saved.get("dns") if isinstance(saved, dict) else None
        for item in (dns.get("records") if isinstance(dns, dict) else None) or []:
            if isinstance(item, dict) and isinstance(item.get("name"), str):
                names.add(item["name"])
    for item in access_rows(env, records):
        if item["uygulama"] != skip_app and item["id"] not in skip_rows and item["satir"]["tur"] == "adres":
            names.add(item["satir"]["ad"] + "." + domain)
    return names


def name_errors(env, app, definition, rows=None, records=None):
    """State checks of a checked definition's new address ports (install: rows None; an edit: the current rows,
    whose ports are not new): each Tailscale name must be free (taken_names). {question id: Turkish text}."""
    rows = rows or {}
    fresh = [(svc["name"], p) for svc in definition["services"] for p in svc.get("ports", [])
             if p.get("use") == "caddy" and port_key(svc["name"], p) not in rows]
    if not fresh:
        return {}
    domain = local_domain(env)
    taken = taken_names(env, skip_app=app, records=records)
    errors = {}
    for service, port in fresh:
        name = "%s.%s" % (port["tailscale_name"], domain)
        if name in taken:
            errors["port:" + port_key(service, port)] = "%s adı zaten kullanılıyor." % name
    return errors


def scope_address(env, scope):
    """The IPv4 address state.env names now for a raw row's scope (TAILSCALE_IPV4, WAN_IPV4)."""
    try:
        ip = ipaddress.IPv4Address(env.get(SCOPE_ADDRESS[scope], ""))
    except ValueError:
        ip = None
    require(ip is not None and not (ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local),
            "Sunucunun %s IPv4 adresi kayıtlı değil; bu kapsamdaki doğrudan port yayımlanamaz."
            % ("Tailscale" if scope == "tailscale" else "internet"), 503)
    return str(ip)


def raw_hosts(env, rows):
    """The generator's context["raw"]: {key: {"host_ip", "host_port"}} of the open raw rows, on the address state.env
    names now for each one's scope; a missing address stops the caller (fail closed)."""
    return {key: {"host_ip": scope_address(env, row["kapsam"]), "host_port": row["port"]}
            for key, row in sorted(rows.items()) if row["tur"] == "ham" and row["kapsam"] != "kapali"}


def access_rows(env, records=None):
    """Every access row of every application, in application and key order: what the publication projection,
    the settings validation and the read models read.

        [{"id": "uygulama:<app>:<service>:<port>/<proto>", "uygulama": app, "anahtar": "<service>:<port>/<proto>",
          "servis": service, "port": container port, "protokol": "tcp" | "udp",
          "yerel_port": the address row's 127.0.0.1 pool port | None for a raw row,
          "satir": the row as erisim.json holds it ({"tur": "adres", "ad", "tailscale_portu", "internet"} or
                   {"tur": "ham", "kapsam", "port"})}]

    An application folder without yerler.json is an install that has not written its record yet and is left out.
    Any other record that cannot be read whole and any clash between two rows (row_conflict: a Tailscale name, an
    internet name, a Tailscale port or an open raw port held twice) raise AppError(503): a projection then keeps
    what it applied last."""
    records = records or Records(env)
    out = []
    for app in records.names():
        if not os.path.lexists(records.dir(app) / "yerler.json"):
            continue
        record = records.load(app)
        for key, row in sorted(record["rows"].items()):
            service, number, protocol = PORT_KEY_RE.fullmatch(key).groups()
            out.append({"id": row_id(app, key), "uygulama": app, "anahtar": key, "servis": service, "port": int(number),
                        "protokol": protocol, "yerel_port": record["places"]["ports"].get(key), "satir": copy.deepcopy(row)})
    clash = row_conflict([(item["id"], item["anahtar"], item["satir"]) for item in out])
    require(clash is None, "Erişim satırları çakışıyor: %s" % (clash or ""), 503)
    return out


def known_domain(env):
    """The local domain, or None when state.env has none that is valid (a read model then shows no address)."""
    try:
        return local_domain(env)
    except AppError:
        return None


def address_url(domain, row):
    """An address row's Tailscale URL, http://<name>.<domain>; None for a raw row or without a domain."""
    if not domain or row.get("tur") != "adres":
        return None
    return "http://%s.%s" % (row["ad"], domain)


def first_address(record, domain):
    """The URL of an application's first address row, in its file's order (services, then their ports), or None."""
    for svc in record["definition"]["services"]:
        for port in svc.get("ports", []):
            url = address_url(domain, record["rows"].get(port_key(svc["name"], port)) or {})
            if url:
                return url
    return None


def record_images(record):
    """The images an application's record names: its pinned digests and the references its file gives."""
    return set(record["places"]["images"].values()) | {reference(s["image"])[1] for s in record["definition"]["services"]}


def resource_uses(records):
    """What the application records use, whether their applications run or not (Podman's cleanup and the
    inventory): {"image": {reference: {apps}}, "network": {name: {apps}}, "container": {name: app}}. An image is
    named by its pinned digest and by the reference its file gives; the containers are every service's and a pod's
    infra container. A folder without yerler.json is an install that has not written its record yet and is left out
    (the cleanup job holds the install lock and checks again); any other record that cannot be read raises."""
    uses = {"image": {}, "network": {}, "container": {}}
    for app in records.names():
        if not os.path.lexists(records.dir(app) / "yerler.json"):
            continue
        record = records.load(app)
        objects = names(app, record["definition"])
        for image in record_images(record):
            uses["image"].setdefault(image, set()).add(app)
        uses["network"].setdefault(objects["network"], set()).add(app)
        for container in objects["containers"].values():
            uses["container"][container] = app
        if objects["pod"]:
            uses["container"][_names(generator.pod_infra_name, app)] = app
    return uses


def cleanup_items(request):
    """The items of a cleanup request (POST /api/konsol/gelismis/temizlik): [(kind, target)] in a fixed order, each
    target checked for its kind (an image by its ID, a network or volume by its name, a data folder by its
    application's name), duplicates dropped; at least one and at most CLEANUP_LIMIT."""
    require(isinstance(request, dict) and set(request) <= set(CLEANUP_KINDS), "Temizlik isteği geçersiz.")
    items = []
    for field, kind in CLEANUP_KINDS.items():
        values = request.get(field, [])
        require(isinstance(values, list), "Temizlik isteği geçersiz.")
        for value in values:
            if kind == "imaj":
                require(isinstance(value, str) and IMAGE_ID_RE.fullmatch(value) is not None, "İmaj kimliği geçersiz.")
            elif kind == "klasor":
                app_name(value)
            else:
                require(isinstance(value, str) and master_containers.NAME_RE.fullmatch(value) is not None,
                        "%s adı geçersiz." % ("Ağ" if kind == "ag" else "Birim"))
                require(kind != "ag" or value != DEFAULT_NETWORK, "Podman'ın varsayılan ağı kaldırılmaz.")
            if (kind, value) not in items:
                items.append((kind, value))
    require(bool(items), "Kaldırılacak bir şey seçin.")
    require(len(items) <= CLEANUP_LIMIT, "Bir temizlikte en çok %d öge kaldırılır." % CLEANUP_LIMIT)
    return items


# -- folder sizes (a bounded walk; Dosyalar → Depolama and Podman's cleanup)
def tree_size(path, deadline, clock=time.monotonic):
    """The disk use of a folder tree in bytes (allocated blocks, as du counts them), walked without following a
    link and without leaving the folder's file system, a hard-linked file counted once: ({"boyut": bytes, "alt":
    {entry: bytes}}, "") with the share of each entry directly in it, or (None, Turkish reason) when the folder is
    missing or not a folder, cannot be read, or the walk is still going at `deadline` (clock's time)."""
    late = "Ölçüm süreye sığmadı; klasörde çok fazla öge var."
    try:
        top = os.lstat(path)
    except FileNotFoundError:
        return None, "Klasör yok."
    except OSError:
        return None, "Klasör okunamadı."
    if not stat.S_ISDIR(top.st_mode):
        return None, "Klasör değil."
    total, children, seen, count = top.st_blocks * 512, {}, set(), 0
    stack = [(str(path), None)]
    while stack:
        if clock() > deadline:
            return None, late
        folder, child = stack.pop()
        try:
            with os.scandir(folder) as entries:
                for entry in entries:
                    count += 1
                    if count % 512 == 0 and clock() > deadline:
                        return None, late
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    if not stat.S_ISDIR(info.st_mode) and info.st_nlink > 1:
                        if (info.st_dev, info.st_ino) in seen:
                            continue
                        seen.add((info.st_dev, info.st_ino))
                    name = entry.name if child is None else child
                    total += info.st_blocks * 512
                    children[name] = children.get(name, 0) + info.st_blocks * 512
                    if stat.S_ISDIR(info.st_mode) and info.st_dev == top.st_dev:
                        stack.append((entry.path, name))
        except FileNotFoundError:
            continue  # removed while it was walked
        except OSError:
            return None, "Klasör okunamadı."
    return {"boyut": total, "alt": children}, ""


class Sizes:
    """Folder sizes (tree_size), cached: a measurement is kept SIZE_TTL seconds, a walk that ran out of time or could
    not read SIZE_FAIL_TTL (a missing folder is not kept). One walk at a time; a call spends at most `seconds` on the
    folders it has to walk, the rest of them answer that time ran out."""

    def __init__(self, clock=time.monotonic, wall=time.time):
        self.lock = threading.Lock()
        self.cache = {}
        self.clock, self.wall = clock, wall

    def measure(self, paths, seconds=SIZE_SECONDS, fresh=False):
        """{path: {"boyut": bytes | None, "alt": {entry: bytes}, "neden": "" | reason, "olculdu": epoch | None}}."""
        out = {}
        with self.lock:
            start = self.clock()
            deadline = start + seconds
            for path in (str(p) for p in paths):
                if path in out:
                    continue
                hit = self.cache.get(path)
                if hit and not fresh and start - hit[0] < (SIZE_TTL if hit[1]["boyut"] is not None else SIZE_FAIL_TTL):
                    out[path] = hit[1]
                    continue
                if self.clock() > deadline:
                    out[path] = {"boyut": None, "alt": {}, "neden": "Ölçüm süreye sığmadı; sonra yeniden denenecek.",
                                 "olculdu": None}
                    continue
                value, reason = tree_size(path, deadline, self.clock)
                out[path] = {"boyut": value["boyut"] if value else None, "alt": value["alt"] if value else {},
                             "neden": reason, "olculdu": int(self.wall())}
                if value is not None or reason != "Klasör yok.":
                    self.cache[path] = (self.clock(), out[path])
                else:
                    self.cache.pop(path, None)
            now = self.clock()
            for path in [p for p, (at, _v) in self.cache.items() if now - at >= SIZE_TTL]:
                del self.cache[path]
        return out


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

    def rows(self, app, places=None):
        """The application's access rows {key: row}, checked against its pool ports."""
        return check_rows(self.need(app, ROWS_FILE), self.places(app) if places is None else places)

    def text(self, app):
        value = read_text(self.dir(app) / "kaynak.yaml")
        require(value is not None, "Uygulama kaydı eksik: %s/kaynak.yaml" % app, 503)
        return value

    def load(self, app):
        """The whole record: name, text, source, answers, definition, places, rows."""
        app = app_name(app)
        definition = check_definition(self.need(app, "tanim.json"), app)
        places = self.places(app)
        return {"name": app, "text": self.text(app), "source": check_source(self.need(app, "kaynak.json")),
                "answers": check_answers(self.need(app, "yanitlar.json")), "definition": definition, "places": places,
                "rows": check_rows(self.need(app, ROWS_FILE), places, definition)}

    def write(self, app, text=None, source=None, answers=None, definition=None, places=None, rows=None):
        """Writes the given parts (rows: {key: row}); erisim.json and then yerler.json first, so the guard sees a new
        application's bridge at once and never a pool port without its row."""
        cfg.private_dir(self.root)
        cfg.private_dir(self.dir(app))
        if rows is not None:
            check_rows({"satirlar": rows}, places)
        if places is not None:
            check_places(places, app)
        if answers is not None:
            check_answers(answers)
        if definition is not None:
            check_definition(definition, app)
        for name, value in ((ROWS_FILE, None if rows is None else {"satirlar": rows}), ("yerler.json", places),
                            ("kaynak.json", source), ("yanitlar.json", answers), ("tanim.json", definition)):
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
    """The answers as given without the port answers (the rows hold how a port is reached), every secret answer
    (a value or a keep) replaced by {"set": true}."""
    hidden = secret_questions(inspection)
    return {"name": answers.get("name"),
            "answers": {qid: ({"set": True} if qid in hidden else copy.deepcopy(value))
                        for qid, value in sorted((answers.get("answers") or {}).items()) if not qid.startswith("port:")}}


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
    """The kaynak of an install request: {"tur": dosya} or one of adres, imaj with its value."""
    require(isinstance(value, dict) and value.get("tur") in SOURCES, "Uygulamanın kaynağı geçersiz.")
    tur = value["tur"]
    require(set(value) == ({"tur"} if tur == "dosya" else {"tur", tur}), "Uygulamanın kaynağı geçersiz.")
    if tur == "adres":
        check_url(value["adres"])
    elif tur == "imaj":
        image_ref(value["imaj"])
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
        first, last = int(env.get("UYGULAMA_PORT_ILK", "")), int(env.get("UYGULAMA_PORT_SON", ""))
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
    """The first port of UYGULAMA_PORT_ILK–UYGULAMA_PORT_SON that nothing uses and nothing listens on."""
    first, last = pool_range(env)
    for port in range(first, last + 1):
        if port not in used and (bind or bindable)(port):
            return port
    raise AppError(409, "Yerel port aralığında boş port kalmadı.")


def base_ports(env):
    """The base's own ports: every *_PORT key of state.env."""
    return {int(v) for key, v in env.items() if key.endswith("_PORT") and str(v).isdigit() and 0 < int(v) < 65536}


def allocate(env, app, keys, previous, records=None, bind=None):
    """Pool ports for the address rows' keys (address_keys): kept for the same key across edits and row changes,
    new ones free of every other application's allocation, the base's ports and live listeners."""
    records = records or Records(env)
    used = base_ports(env)
    for other in records.names():
        if other != app:
            used |= set(records.places(other)["ports"].values())
    wanted = list(keys)
    result = {key: port for key, port in (previous or {}).items() if key in wanted}
    require(not used & set(result.values()), "Uygulamanın ayrılmış portu başka bir yerde kullanılıyor.", 409)
    used |= set(result.values())
    for key in wanted:
        if key not in result:
            result[key] = free_port(env, used, bind)
            used.add(result[key])
    return dict(sorted(result.items()))


def guard_input(env):
    """The container guard's input (master_container_network): each application's bridge and its publications.

        [{"app", "interface", "publications": [{"service", "port", "protocol", "scope": "local" | "tailscale" |
          "internet", "host_ip", "host_port"}]}]

    local: an address row's pool port on 127.0.0.1 (the host reaches it through OUTPUT DNAT, no permit);
    tailscale and internet: an open raw row on the address state.env names now for its scope, the address the
    generator writes into its unit (--adres-yenile rewrites a unit that still carries an older one)."""
    records = Records(env)
    out = []
    for app in records.names():
        # A folder without yerler.json is an install that has not written it yet: leaving it out makes the
        # policy stricter, never wider. Every other unreadable part stops the guard (fail closed).
        if not os.path.lexists(records.dir(app) / "yerler.json"):
            continue
        places = records.places(app)
        rows = records.rows(app, places)
        publications = []
        for key, port in sorted(places["ports"].items()):
            service, number, protocol = PORT_KEY_RE.fullmatch(key).groups()
            publications.append({"service": service, "port": int(number), "protocol": protocol, "scope": "local",
                                 "host_ip": generator.LOOPBACK, "host_port": port})
        for key, host in raw_hosts(env, rows).items():
            service, number, protocol = PORT_KEY_RE.fullmatch(key).groups()
            publications.append({"service": service, "port": int(number), "protocol": protocol,
                                 "scope": rows[key]["kapsam"], "host_ip": host["host_ip"], "host_port": host["host_port"]})
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


def app_update(definition, updates):
    """An application's update state: its services' (service_update) summed as UPDATE_ORDER ranks them. The list,
    the detail and Sistem → Güncellemeler read it from the same cached check (DD-214)."""
    return update_summary([service_update(svc, (updates or {}).get(svc["name"])) for svc in definition["services"]])


def summary(record, objects, live, busy, updates, domain=None):
    """An application of the list: live state per service, resources summed, its bridge's rate and what passed
    through it so far (live["ag"], the backend's sampler), its first address (domain: the local domain), update
    state, actions."""
    definition, places = record["definition"], record["places"]
    services, states, cpu, memory = [], [], [], []
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
            "guncelleme": app_update(definition, updates), "eylemler": actions, "revizyon": places["revision"],
            "is": busy or None, "koken": record["source"]["tur"], "durduruldu": places["stopped"],
            "uyari": len(definition.get("warnings") or []),
            "ag": copy.deepcopy((live.get("ag") or {}).get(record["name"])), "adres": first_address(record, domain)}


def mount_rows(env, app, svc, size=None):
    """A service's mounts as Konsol shows them. size: the application's data folder as Sizes.measure gives it (or
    None): an application folder's boyut is its share of that measurement, null when it was not measured."""
    rows = []
    for m in svc.get("mounts", []):
        boyut = None
        if m.get("to") == "app":
            path = str(data_dir(env, app) / m["folder"])
            if size and size.get("boyut") is not None:
                boyut = (size.get("alt") or {}).get(m["folder"])
        elif m.get("to") == "srv":
            path = m["path"]
        else:
            path = None
        rows.append({"hedef": m["target"], "tur": m["to"], "yol": path, "salt_okunur": bool(m.get("read_only")),
                     "boyut": boyut})
    return rows


def who(user):
    """A process user as people read it: "abc (uid 1000)", "uid 911", "root"."""
    if user["uid"] == 0:
        return "root"
    return "%s (uid %d)" % (user["ad"], user["uid"]) if user.get("ad") else "uid %d" % user["uid"]


def warning_now(env, users):
    """A /srv warning (a root start, or a direct start as another user) with what the service's processes run as
    now: (sentence, resolved). Resolved: every process that is not root runs as the Files account, so what it
    writes under /srv opens in Dosyalar. (None, False) while the service does not run or its processes cannot be
    read."""
    if not users:
        return None, False
    files = env.get("DOWNLOADS_UID", "")
    files_uid = int(files) if files.isdigit() else None
    own = [u for u in users if u["uid"] != 0]
    roots = sum(u["surec"] for u in users if u["uid"] == 0)
    if not own:
        return ("Şu an bütün süreçleri root olarak çalışıyor: /srv'ye yazdıkları root'a ait olur ve Dosyalar hesabı "
                "açamaz."), False
    names = ", ".join(who(u) for u in own)
    rest = " Başlatıcının %d süreci root olarak kalıyor." % roots if roots else ""
    if files_uid is not None and all(u["uid"] == files_uid for u in own):
        return ("Şu an uygulama %s olarak çalışıyor: Dosyalar hesabıyla aynı kullanıcı, /srv'ye yazdıkları Dosyalar'dan "
                "açılır.%s" % (names, rest)), True
    return ("Şu an uygulama %s olarak çalışıyor; Dosyalar hesabı%s bu dosyaları açamayabilir.%s"
            % (names, " (uid %d)" % files_uid if files_uid is not None else "", rest)), False


def detail(env, record, objects, live, busy, updates, inspected, size=None, checked=None, users=None):
    """GET /api/konsol/uygulamalar/{app}: the application with every service, its ports with their access rows,
    folders (an application folder with its size from size, the data folder's measurement), secrets by name only,
    warnings (a /srv warning with what its service's processes run as now), source, file, answers (no secret value,
    no port answer), units and when its image update was last checked (checked). users: {container: what its
    processes run as (master_containers.process_users)} for the running ones."""
    users = users or {}
    item = summary(record, objects, live, busy, updates, known_domain(env))
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
            key = port_key(name, p)
            access = record["rows"][key]
            # kullanim and tailscale_adi are what the row is (an address and its name, or a raw port).
            ports.append({"port": p["port"], "protokol": p["protocol"], "id": row_id(record["name"], key),
                          "erisim": copy.deepcopy(access), "kullanim": "caddy" if access["tur"] == "adres" else "raw",
                          "tailscale_adi": access.get("ad"), "yerel_port": places["ports"].get(key)})
        services.append({
            "ad": name, "durum": row["durum"], "baslangic": svc["start"], "kullanici": svc.get("user"),
            "imaj": svc["image"], "ozet": places["images"].get(name), "kanal": channel(svc["image"]),
            "guncelleme": row["guncelleme"], "konteyner": container, "birim": objects["units"][name],
            "calisma": started, "saglik": str(health.get("Status") or "") if isinstance(health, dict) else "",
            "yeniden_baslama": info.get("RestartCount") if type(info.get("RestartCount")) is int else 0,
            "portlar": ports, "baglamalar": mount_rows(env, record["name"], svc, size),
            "gizliler": sorted({e["secret"] for e in svc.get("environment", []) if "secret" in e}),
            "surecler": copy.deepcopy(users.get(container)),
        })
    source = record["source"]
    warnings = []
    for w in definition.get("warnings") or []:
        service = w.get("service", "")
        now, resolved = warning_now(env, users.get(objects["containers"].get(service))) if service in objects["containers"] else (None, False)
        warnings.append({"servis": service, "metin": w.get("text", ""), "simdi": now, "cozuldu": resolved})
    return {
        "uygulama": item, "servisler": services,
        "gizliler": [{"ad": s["name"], "servisler": list(s.get("services") or [])} for s in definition["secrets"]],
        "uyarilar": warnings,
        "koken": {"tur": source["tur"], "adres": source.get("adres"), "imaj": source.get("imaj"),
                  "alindi": source["alindi"], "sha256": source["sha256"]},
        "metin": record["text"], "yanitlar": record["answers"], "birimler": list(objects["files"]),
        "veri": str(data_dir(env, record["name"])), "ag": objects["network"], "pod": objects["pod"],
        "guncelleme_denetlendi": checked,
    }


# -- an install's plan (POST …/kur with plan): what it creates, nothing written
def install_summary(env, app, definition, rows, objects, plan):
    """KurOzeti: what installing a checked definition creates: each service with its start mode, user, image, folders
    and secret names; the access rows it seeds (an address with its URL); the data folders it makes; its secrets by
    name; the definition's warnings; the images it pulls; its unit files, network and pod. plan: the install's
    preliminary render (its folders). No secret value."""
    domain = known_domain(env)
    services, access = [], []
    for svc in definition["services"]:
        services.append({"ad": svc["name"], "baslangic": svc["start"], "kullanici": svc.get("user"), "imaj": svc["image"],
                         "baglamalar": mount_rows(env, app, svc),
                         "gizliler": sorted({e["secret"] for e in svc.get("environment", []) if "secret" in e})})
        for port in svc.get("ports", []):
            key = port_key(svc["name"], port)
            access.append({"id": row_id(app, key), "anahtar": key, "servis": svc["name"], "port": port["port"],
                           "protokol": port["protocol"], "satir": copy.deepcopy(rows[key]),
                           "adres": address_url(domain, rows[key])})
    warnings = [{"servis": w.get("service", ""), "metin": w.get("text", "")} for w in definition.get("warnings") or []]
    return {"ad": app, "veri": str(data_dir(env, app)), "ag": objects["network"], "pod": objects["pod"],
            "birimler": list(objects["files"]), "servisler": services, "erisim": access, "klasorler": list(plan["folders"]),
            "gizliler": [{"ad": s["name"], "servisler": list(s.get("services") or [])} for s in definition["secrets"]],
            "uyarilar": warnings, "imajlar": sorted({reference(s["image"])[1] for s in definition["services"]})}


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


def difference(record, definition, old_plan, new_plan, ports, rows, version=None):
    """TanimFarki: per unit (added, removed, changed), the services whose environment file changes, port (each
    row: kept, new or gone, with its pool port), folder (a dropped one stays on disk), secret (new, renewed, kept,
    dropped), start mode and the new definition's warnings."""
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
    port_rows = [{"anahtar": key, "degisim": "kalir" if key in record["rows"] else "eklenir", "yerel_port": ports.get(key)}
                 for key in sorted(rows)]
    port_rows += [{"anahtar": key, "degisim": "kaldirilir", "yerel_port": places["ports"].get(key)}
                  for key in sorted(record["rows"]) if key not in rows]
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
            # Only the services whose start mode changes, or which are new: an unchanged one is not a change.
            "baslangic": [{"servis": s["name"], "once": before.get(s["name"]), "sonra": s["start"]} for s in definition["services"]
                          if before.get(s["name"]) != s["start"]],
            "uyarilar": warnings, "yeniden_baslar": bool(units or environment) and not places["stopped"]}


def edit_plan(env, record, inspection, definition, rows, ports, version, module=None):
    """The differences an edit makes (TanimFarki), from two renders; no pull, no secret, nothing written. rows and
    ports: the edit's rows (next_rows) and their pool ports (allocate)."""
    app, places = record["name"], record["places"]
    old_plan = render(env, app, record["definition"], places, version, record["rows"], module)
    secrets = placeholder_secrets(app, definition, {s["name"]: places["secrets"][s["name"]] for s in definition["secrets"]
                                                   if s.get("keep")})
    candidate = {"revision": places["revision"], "stopped": places["stopped"], "ports": ports, "secrets": secrets,
                 "images": placeholders(definition, kept_images(record["definition"], places, definition))}
    new_plan = render(env, app, definition, candidate, version, rows, module)
    return difference(record, definition, old_plan, new_plan, ports, rows, version)


def new_questions(inspection, stored):
    """The ids of an inspection's questions that the stored answers (with the port answers filled from the rows,
    filled_answers) do not answer yet."""
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
