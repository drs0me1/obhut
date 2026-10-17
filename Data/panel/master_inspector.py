#!/usr/bin/env python3
"""The inspector (denetçi, rebuild DD-271, phase 2): a Compose or Kubernetes file → refusals, guesses and
questions; the operator's answers → a checked application definition. Standard library only.

    inspect(text) -> inspection
    check(inspection, answers) -> (definition, secrets, errors)

inspect never raises for bad input: a reading error is a refusal with its line. The inspection carries
the reader's model (services, variables) so that check needs nothing else; it is computed by the server
from the file in the same request, never taken from the browser. check is pure: questions only the
server's state can answer (a name taken, a folder that exists) belong to phase 3. The definition holds
no secret value; secrets come back separately as {name: value} and are never echoed to the browser.
Guesses are shown beside each question and never applied to ports (A1). Nothing here writes, runs or
fetches anything.
"""
import posixpath
import re

import master_compose
import master_kube
import master_yaml

LIMIT_BYTES = master_yaml.LIMIT_BYTES
MAX_SERVICES = 16
MAX_PORTS = 64
MAX_VALUE = 4096
# A refused file lists at most this many refusals and notes; one line says how many more there are.
MAX_FINDINGS = 500
# More questions than this is not an application an operator can answer; the file is refused.
MAX_QUESTIONS = 256
# SERVER_ROOT and the Files account (DOWNLOADS_UID:DOWNLOADS_GID) of config/defaults.env, both fixed
# (DD-144); a test keeps these equal to the file.
SRV = "/srv"
DIRECT_USER = "1000:1000"
SRV_TARGETS = ("/srv", "/media", "/downloads")
RAW_PORTS = frozenset((21, 22, 23, 25, 53, 110, 143, 465, 587, 993, 995, 1883, 3306, 5432, 6379, 6881, 8883, 27017,
                       51413))
SECRET_RE = re.compile(r"PASS|PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|PWD", re.I)
# A random value fits a password or a secret the application itself checks; a token, an API key or a
# private key comes from elsewhere, so the interface offers "Rastgele üret" only for the first kind.
GENERATE_RE = re.compile(r"PASS|SECRET|PWD", re.I)
NO_GENERATE_RE = re.compile(r"TOKEN|API_?KEY|PRIVATE_?KEY", re.I)
APP_NAME_RE = re.compile(r"[a-z][a-z0-9-]{0,29}\Z")
TAILSCALE_NAME_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\Z")
RESERVED_NAMES = ("panel", "paylas")
ROOT_DROPS = ("SETFCAP", "SYS_CHROOT")


def _failed(line, key, text):
    return {"format": None, "name": "", "pod": False, "services": [], "variables": [],
            "refusals": [{"line": line, "key": key, "text": text}], "notes": [], "questions": [],
            "marks": [{"line": line, "kind": "refuse", "text": text}]}


def inspect(text):
    """The inspection of a file's text; never raises."""
    try:
        return _inspect(text)
    except Exception:  # noqa: BLE001 - fail closed: a reader bug refuses the file instead of letting it through
        return _failed(1, "ic-hata", "Denetçi bu dosyayı okurken bir iç hataya düştü; dosya kabul edilmedi.")


def detect(docs):
    """compose, kubernetes or None, from the documents' top-level keys."""
    if any(isinstance(d, dict) and "services" in d for d in docs):
        return "compose"
    if any(isinstance(d, dict) and ("apiVersion" in d or "kind" in d) for d in docs):
        return "kubernetes"
    return None


def _inspect(text):
    if not isinstance(text, str):
        return _failed(1, "metin", "Dosya bir metin olmalı.")
    try:
        docs = master_yaml.load_all(text)
    except master_yaml.YamlError as err:
        return _failed(err.line, "yaml", "Dosya okunamadı (satır %d): %s" % (err.line, err))
    docs = [d for d in docs if d is not None]
    if not docs:
        return _failed(1, "dosya", "Dosya boş; içinde bir Compose ya da Kubernetes tanımı yok.")
    kind = detect(docs)
    if kind is None:
        return _failed(getattr(docs[0], "line", 1) or 1, "dosya",
                       "Biçim tanınmadı: Compose dosyasında services, Kubernetes dosyasında apiVersion ve kind olur.")
    model = (master_compose if kind == "compose" else master_kube).read(docs)
    return _Inspector(model).run()


def secret_name(name):
    return bool(SECRET_RE.search(name))


def can_generate(name):
    return bool(GENERATE_RE.search(name)) and not NO_GENERATE_RE.search(name)


def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def root_drops(svc):
    """The capabilities the root start drops from Podman's defaults (A4)."""
    drops = [c for c in ROOT_DROPS if c not in svc["caps_add"]]
    if "NET_BIND_SERVICE" not in svc["caps_add"] and not any(p["port"] < 1024 for p in svc["ports"]):
        drops.insert(0, "NET_BIND_SERVICE")
    return [c for c in master_compose.DEFAULT_CAPS if c in drops]


def root_caps(svc):
    """(caps_drop, open capabilities) of the root start: A4's drops plus the file's own (only ever more)."""
    if "ALL" in svc["caps_drop"]:
        return "all", [c for c in master_compose.DEFAULT_CAPS if c in svc["caps_add"]]
    drops = set(root_drops(svc)) | set(svc["caps_drop"])
    return ([c for c in master_compose.DEFAULT_CAPS if c in drops],
            [c for c in master_compose.DEFAULT_CAPS if c not in drops])


def env_refs(entry):
    try:
        return master_compose.references(entry["value"])
    except master_compose.TemplateError:
        return []


class _Inspector:
    def __init__(self, model):
        self.m = model
        self.compose = model["format"] == "compose"
        self.refusals = list(model["refusals"])
        self.notes = list(model["notes"])
        self.questions = []
        self.folders = {}
        self.folder_names = set()
        self.kube_secrets = {}

    def refuse(self, line, key, text):
        self.refusals.append({"line": int(line or 1), "key": key, "text": text})

    def note(self, line, key, text):
        self.notes.append({"line": int(line or 1), "key": key, "text": text})

    def ask(self, qid, kind, line, title, why, **fields):
        self.questions.append(dict({"id": qid, "kind": kind, "line": int(line or 1), "title": title, "why": why}, **fields))

    def secret_vars(self):
        return {v["name"] for v in self.m["variables"] if secret_name(v["name"])}

    def run(self):
        m = self.m
        services = m["services"]
        if len(services) > MAX_SERVICES:
            self.refuse(services[MAX_SERVICES]["line"], "services",
                        "En çok %d servis olabilir; dosyada %d var." % (MAX_SERVICES, len(services)))
            # The file is refused; questions and the listed model stop at the limit.
            services = m["services"] = services[:MAX_SERVICES]
        ports = [p for s in services for p in s["ports"]]
        if len(ports) > MAX_PORTS:
            self.refuse(ports[MAX_PORTS]["line"], "ports", "En çok %d port olabilir; dosyada %d var." % (MAX_PORTS, len(ports)))
            left = MAX_PORTS
            for svc in services:
                svc["ports"] = svc["ports"][:left]
                left -= len(svc["ports"])
        self.udp = {p["port"] for s in services for p in s["ports"] if p["protocol"] == "udp"}
        if not m["name"]:
            self.refuse(m["name_line"], "name", "Uygulamanın adı dosyadan çıkarılamadı; ad bir harfle başlamalı.")
        self.ask("name", "name", m["name_line"], "Uygulamanın adı",
                 "Birimlerin, ağın ve verilerin klasörünün adı olur: küçük harf, rakam ve '-', en çok 30 karakter.",
                 suggest=m["name"])
        secret_vars = self.secret_vars()
        for var in m["variables"]:
            for use in var["uses"]:
                if var["name"] in secret_vars and use["field"] != "environment":
                    self.refuse(use["line"], use["field"], "Gizli görünen ${%s} yalnız bir ortam değişkeninin değerinde "
                                                           "kullanılabilir; %s içinde açık yazılırdı." % (var["name"], use["field"]))
            self.var_question(var, var["name"] in secret_vars)
        seen_pod = set()
        web_names = []
        image_refused = {r["line"] for r in m["refusals"] if r["key"] == "image"}
        for svc in services:
            if not svc["image"] and svc["image_line"] not in image_refused:
                self.refuse(svc["line"], "image", "%s: imaj yok; hazır bir imaj (image) gerekir." % svc["name"])
            seen = seen_pod if m["pod"] else set()
            for port in svc["ports"]:
                key = (port["port"], port["protocol"])
                if key in seen:
                    where = "Pod'un konteynerleri aynı ağı paylaşır; " if m["pod"] else ""
                    self.refuse(port["line"], "ports", "%s%d/%s iki kez yazılmış." % (where, port["port"], port["protocol"].upper()))
                seen.add(key)
            self.port_questions(svc, web_names)
            self.mount_questions(svc)
            self.secret_questions(svc, secret_vars)
            self.start_question(svc)
        if len(self.questions) > MAX_QUESTIONS:
            self.refuse(self.questions[MAX_QUESTIONS]["line"], "dosya", "Dosya %d soru doğuruyor; en çok %d olabilir."
                        % (len(self.questions), MAX_QUESTIONS))
            self.questions = self.questions[:MAX_QUESTIONS]
        return self.result()

    @staticmethod
    def bounded(items, what):
        if len(items) <= MAX_FINDINGS:
            return items
        rest = len(items) - MAX_FINDINGS
        return items[:MAX_FINDINGS] + [{"line": items[MAX_FINDINGS]["line"], "key": "dosya",
                                        "text": "%d %s daha var; gösterilmiyor." % (rest, what)}]

    def result(self):
        m = self.m
        self.refusals = self.bounded(self.refusals, "durduran satır")
        self.notes = self.bounded(self.notes, "not")
        marks = [{"line": r["line"], "kind": "refuse", "text": r["text"]} for r in self.refusals]
        marks += [{"line": q["line"], "kind": "question", "text": q["title"]} for q in self.questions]
        marks += [{"line": n["line"], "kind": "note", "text": n["text"]} for n in self.notes]
        order = {"refuse": 0, "question": 1, "note": 2}
        marks.sort(key=lambda x: (x["line"], order[x["kind"]]))
        return {"format": m["format"], "name": m["name"], "pod": m["pod"], "services": m["services"],
                "variables": m["variables"], "refusals": self.refusals, "notes": self.notes,
                "questions": self.questions, "marks": marks}

    # -- questions
    def var_question(self, var, secret):
        users = []
        for use in var["uses"]:
            if use["service"] and use["service"] not in users:
                users.append(use["service"])
        if secret:
            why = "Gizli bir değer gibi görünüyor; Podman secret olarak verilir, diske ve tarayıcıya açık yazılmaz."
        else:
            why = "Dosya bu değeri dışarıdan (.env) bekliyor"
            why += "; varsayılanı: %s." % var["default"] if var["default"] else "."
        if var["required"]:
            why += " Boş bırakılamaz."
        self.ask("var:" + var["name"], "var", var["line"], "Değişken: ${%s}" % var["name"], why,
                 name=var["name"], secret=secret, generate=secret and can_generate(var["name"]),
                 default=var["default"], required=var["required"], services=users)

    def port_questions(self, svc, web_names):
        udp = self.udp if self.m["pod"] else {p["port"] for p in svc["ports"] if p["protocol"] == "udp"}
        for port in svc["ports"]:
            qid = "port:%s:%d/%s" % (svc["name"], port["port"], port["protocol"])
            title = "%s: %d/%s" % (svc["name"], port["port"], port["protocol"].upper())
            if port["protocol"] == "udp":
                self.ask(qid, "port", port["line"], title,
                         "UDP ham port olarak eklenir ve kapalı gelir; kapsamı (Tailscale ya da internet) Erişim'den seçilir.",
                         service=svc["name"], port=port["port"], protocol="udp", guess="raw", choices=["raw"],
                         suggest=None, host_port=port["host_port"])
                continue
            raw = port["port"] in RAW_PORTS or port["port"] in udp
            if raw:
                why = ("Web dışı bir port gibi görünüyor (bilinen bir servis portu ya da aynı port UDP'de de açılıyor): "
                       "ham port önerilir. Ham portlar kapalı gelir; Erişim'den açılır.")
            else:
                why = ("Web arayüzü olabilir: bir adres (Caddy satırı, Tailscale adı) ya da ham port olarak eklenir. "
                       "Seçim sizin; dosyadaki sunucu portu kullanılmaz.")
            self.ask(qid, "port", port["line"], title, why, service=svc["name"], port=port["port"], protocol="tcp",
                     guess="raw" if raw else "web", choices=["caddy", "raw"],
                     suggest=None if raw else self.tailscale_suggest(svc, port, web_names), host_port=port["host_port"])

    def tailscale_suggest(self, svc, port, web_names):
        app = self.m["name"]
        if not app:
            return None
        candidates = [app] if not web_names else []
        if len(self.m["services"]) > 1:
            candidates.append(master_compose.lower_dashed("%s-%s" % (app, svc["name"])))
        candidates.append("%s-%d" % (app, port["port"]))
        for name in candidates:
            if TAILSCALE_NAME_RE.fullmatch(name) and name not in web_names and name not in RESERVED_NAMES:
                web_names.append(name)
                return name
        return None

    def mount_questions(self, svc):
        for mount in svc["mounts"]:
            if mount["kind"] == "tmpfs":
                continue
            qid = "mount:%s:%s" % (svc["name"], mount["target"])
            folder = self.folder_of(svc, mount)
            srv_path = self.srv_guess(mount)
            source = mount["source"] or "adsız birim"
            self.ask(qid, "mount", mount["line"], "%s: %s" % (svc["name"], mount["target"]),
                     "Dosyada %s. Uygulamanın klasörüne ya da %s altından bir klasöre bağlanır; başka bir sunucu yolu "
                     "kullanılmaz." % (source, SRV),
                     service=svc["name"], target=mount["target"], source=mount["source"], source_kind=mount["kind"],
                     read_only=mount["read_only"], suggest="srv" if srv_path else "app", folder=folder, srv_path=srv_path)

    def folder_of(self, svc, mount):
        """The application folder's sub-folder for a mount; one source, one folder (Compose shares named volumes)."""
        folders = self.folders
        source, kind = mount["source"], mount["kind"]
        if kind == "named" and source:
            identity, base = ("named", source), source
        elif not source or "$" in source:
            identity, base = ("own", svc["name"], mount["target"]), posixpath.basename(mount["target"])
        else:
            clean = posixpath.normpath(source)
            identity, base = (kind, clean), posixpath.basename(clean)
        if identity in folders:
            return folders[identity]
        name = master_compose.safe_folder(base)
        candidate, n = name, 2
        while candidate in self.folder_names:
            candidate = "%s-%d" % (name, n)
            n += 1
        folders[identity] = candidate
        self.folder_names.add(candidate)
        return candidate

    def srv_guess(self, mount):
        source = mount["source"]
        if mount["kind"] == "absolute" and source and "$" not in source:
            clean = master_compose.clean_path(source)
            if under(clean, SRV):
                return clean
        for target in SRV_TARGETS:
            if under(mount["target"], target):
                return mount["target"] if target == SRV else SRV + mount["target"]
        return None

    def secret_questions(self, svc, secret_vars):
        for entry in svc["environment"]:
            refs = env_refs(entry)
            use = {"service": svc["name"], "env": entry["name"]}
            if entry["secret_ref"]:
                # One question per referenced secret and key, however many containers use it.
                qid = "secret:" + entry["secret_key"]
                question = self.kube_secrets.get(qid)
                if question is not None:
                    question["uses"].append(use)
                    if svc["name"] not in question["services"]:
                        question["services"].append(svc["name"])
                    continue
                key = entry["secret_key"].partition("/")[2]
                self.ask(qid, "secret", entry["line"], "Gizli değer: %s" % entry["secret_key"],
                         "Kubernetes secret'ından (%s) okunuyor; değerini siz verirsiniz, Podman secret olur ve onu "
                         "kullanan her konteynere verilir." % entry["secret_key"],
                         service=svc["name"], env=entry["name"], generate=can_generate("%s %s" % (entry["name"], key)),
                         services=[svc["name"]], uses=[use])
                self.kube_secrets[qid] = self.questions[-1]
                continue
            if refs:
                continue
            elif entry["value"] == "":
                why = "Dosyada boş; değerini siz verirsiniz, Podman secret olur."
            elif secret_name(entry["name"]):
                why = "Adı gizli bir değer gibi; dosyadaki değer kullanılmaz, değerini siz verirsiniz, Podman secret olur."
            else:
                continue
            self.ask("secret:%s:%s" % (svc["name"], entry["name"]), "secret", entry["line"],
                     "%s: %s (gizli değer)" % (svc["name"], entry["name"]), why, service=svc["name"], env=entry["name"],
                     generate=can_generate(entry["name"]), services=[svc["name"]], uses=[use])

    def start_question(self, svc):
        user, caps = svc["user"], svc["caps_add"]
        _drops, open_caps = root_caps(svc)
        if caps:
            why = "Dosya ek yetki istiyor (%s): root başlangıcı önerilir." % ", ".join(caps)
        elif user:
            why = ("Dosya kullanıcıyı belirtiyor (%s): doğrudan bu kullanıcıyla başlayabilir; bütün yetkiler kapalı, "
                   "yeni yetki kazanılamaz." % user)
        else:
            why = ("Dosya kullanıcı belirtmiyor: imaj büyük olasılıkla root başlayıp kendi kullanıcısına geçiyor "
                   "(ör. linuxserver, gosu). Doğrudan başlatılırsa %s ile başlar ve açılmayabilir." % DIRECT_USER)
        self.ask("start:" + svc["name"], "start", svc["line"], "%s: nasıl başlasın?" % svc["name"], why,
                 service=svc["name"], suggest="direct" if user and not caps else "root", user=user,
                 direct_user=user or DIRECT_USER, caps_add=list(caps), open_caps=open_caps)


# -- answers
def _text(value):
    """None when value is an acceptable answer text, else the Turkish reason."""
    if not isinstance(value, str):
        return "Bir metin olmalı."
    if "\x00" in value:
        return "Boş karakter (NUL) içeremez."
    if len(value) > MAX_VALUE:
        return "En çok %d karakter olabilir." % MAX_VALUE
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return "Geçerli bir metin değil."
    return None


def _srv_path(path):
    reason = _text(path)
    if reason:
        return reason
    if not path.startswith("/") or re.search(r"[\x00-\x1f\x7f]", path):
        return "Mutlak bir yol olmalı."
    parts = path.split("/")[1:]
    if path != SRV and (not under(path, SRV) or any(p in ("", ".", "..") or p.startswith(".") for p in parts)):
        return "%s ya da altında, gizli klasör ve '..' içermeyen bir yol olmalı." % SRV
    return None


def check(inspection, answers):
    """(definition, secrets, errors): the definition and the secret values when every answer is valid,
    else (None, {}, {question id: Turkish text}). Never raises."""
    try:
        return _Check(inspection, answers).run()
    except Exception:  # noqa: BLE001 - fail closed
        return None, {}, {"dosya": "Yanıtlar denetlenirken bir iç hata oldu; tanım çıkarılmadı."}


class _Check:
    def __init__(self, inspection, answers):
        self.i = inspection
        self.a = answers
        self.errors = {}

    def error(self, qid, text):
        self.errors.setdefault(qid, text)

    def run(self):
        i = self.i
        if not isinstance(i, dict) or i.get("format") not in ("compose", "kubernetes"):
            return None, {}, {"dosya": "Dosya okunamadı; önce denetimdeki sorunlar giderilmeli."}
        if i.get("refusals"):
            return None, {}, {"dosya": "Dosyada kurulumu durduran satırlar var; önce onlar giderilmeli."}
        a = self.a
        if not isinstance(a, dict) or set(a) - {"name", "answers"} or not isinstance(a.get("answers", {}), dict):
            return None, {}, {"dosya": "Yanıtlar okunamadı."}
        given = a.get("answers", {})
        name = a.get("name")
        reason = _text(name) if name is not None else "Uygulamanın adı gerekli."
        if reason is None and not APP_NAME_RE.fullmatch(name):
            reason = "Küçük harfle başlamalı; küçük harf, rakam ve '-' içermeli, en çok 30 karakter."
        if reason is None and name.startswith(("konsol", "master")):
            reason = "konsol ve master ile başlayan adlar Obhut'undur."
        if reason:
            self.error("name", reason)
        questions = {q["id"]: q for q in i["questions"] if q["kind"] != "name"}
        for qid in given:
            if qid not in questions:
                self.error(qid, "Böyle bir soru yok.")
        chosen = {}
        for qid, q in questions.items():
            if qid not in given:
                self.error(qid, "Yanıt gerekli.")
                continue
            value = getattr(self, "a_" + q["kind"])(q, given[qid])
            if value is not None:
                chosen[qid] = value
        names = {}
        for qid, value in chosen.items():
            if questions[qid]["kind"] == "port" and value.get("tailscale_name"):
                other = names.setdefault(value["tailscale_name"], qid)
                if other != qid:
                    self.error(qid, "Bu Tailscale adı bu uygulamada başka bir portta da kullanılıyor.")
        if self.errors:
            return None, {}, self.errors
        return _Definition(i, name, chosen, questions).build(self)

    @staticmethod
    def shape(answer, keys):
        return isinstance(answer, dict) and set(answer) == set(keys)

    def a_port(self, q, answer):
        if self.shape(answer, ("use",)) and answer["use"] == "raw":
            return {"use": "raw", "tailscale_name": None}
        if q["protocol"] == "udp":
            self.error(q["id"], "UDP portu yalnız ham port olabilir.")
            return None
        if not self.shape(answer, ("use", "tailscale_name")) or answer["use"] != "caddy":
            self.error(q["id"], "Bir adres (Caddy satırı ve Tailscale adı) ya da ham port seçin.")
            return None
        ts = answer["tailscale_name"]
        if not isinstance(ts, str) or not TAILSCALE_NAME_RE.fullmatch(ts):
            self.error(q["id"], "Tailscale adı küçük harf, rakam ve '-' içermeli, '-' ile başlayıp bitmemeli (en çok 63).")
            return None
        if ts in RESERVED_NAMES:
            self.error(q["id"], "%s adı Obhut'undur." % ts)
            return None
        return {"use": "caddy", "tailscale_name": ts}

    def value(self, q, answer):
        if not self.shape(answer, ("value",)):
            self.error(q["id"], "Bir değer girin.")
            return None
        reason = _text(answer["value"])
        if reason:
            self.error(q["id"], reason)
            return None
        return answer["value"]

    def a_var(self, q, answer):
        value = self.value(q, answer)
        if value is None:
            return None
        if value == "" and (q["secret"] or q["required"]):
            self.error(q["id"], "Gizli değer boş olamaz; bir değer girin ya da Rastgele üret'i kullanın." if q["generate"]
                       else "Bu değer boş olamaz.")
            return None
        return {"value": value}

    def a_secret(self, q, answer):
        value = self.value(q, answer)
        if value is None:
            return None
        if value == "":
            self.error(q["id"], "Gizli değer boş olamaz; bir değer girin%s." % (" ya da Rastgele üret'i kullanın"
                                                                               if q["generate"] else ""))
            return None
        return {"value": value}

    def a_mount(self, q, answer):
        if self.shape(answer, ("to",)) and answer["to"] == "app":
            return {"to": "app"}
        if not self.shape(answer, ("to", "path", "read_only")) or answer["to"] != "srv":
            self.error(q["id"], "Uygulamanın klasörünü ya da %s altından bir klasörü seçin." % SRV)
            return None
        if not isinstance(answer["read_only"], bool):
            self.error(q["id"], "Yalnız okuma seçimi true ya da false olmalı.")
            return None
        reason = _srv_path(answer["path"])
        if reason:
            self.error(q["id"], reason)
            return None
        return {"to": "srv", "path": answer["path"], "read_only": answer["read_only"]}

    def a_start(self, q, answer):
        if not self.shape(answer, ("mode",)) or answer["mode"] not in ("direct", "root"):
            self.error(q["id"], "Doğrudan ya da root başlangıcını seçin.")
            return None
        return {"mode": answer["mode"]}


class _Definition:
    def __init__(self, inspection, name, chosen, questions):
        self.i = inspection
        self.app = name
        self.chosen = chosen
        self.questions = questions
        self.compose = inspection["format"] == "compose"
        self.values = {qid[4:]: v["value"] for qid, v in chosen.items() if qid.startswith("var:")}
        self.secret_vars = {q["name"] for q in questions.values() if q["kind"] == "var" and q["secret"]}
        self.secret_names = {}
        self.secret_of = {}
        self.secret_values = {}
        self.secret_users = {}

    def sub(self, text):
        return master_compose.substitute(text, self.values) if self.compose and text is not None else text

    def allocate(self, identity, preferred, fallback):
        """A Podman secret name for one value; the same value keeps one name, two values never share one."""
        if identity in self.secret_of:
            return self.secret_of[identity]
        candidates = [master_compose.lower_dashed(c) for c in (preferred, fallback)]
        n = 2
        while True:
            for candidate in candidates:
                if self.secret_names.setdefault(candidate, identity) == identity:
                    self.secret_of[identity] = candidate
                    return candidate
            candidates = ["%s-%d" % (master_compose.lower_dashed(fallback), n)]
            n += 1

    def secret(self, identity, preferred, fallback, value, service):
        name = self.allocate(identity, preferred, fallback)
        self.secret_values[name] = value
        users = self.secret_users.setdefault(name, [])
        if service not in users:
            users.append(service)
        return name

    def build(self, check):
        services = []
        for svc in self.i["services"]:
            try:
                services.append(self.service(svc))
            except master_compose.TemplateError as err:
                check.error("dosya", "%s: %s" % (svc["name"], err))
        for svc, out in zip(self.i["services"], services):
            self.after(check, svc, out)
        if check.errors:
            return None, {}, check.errors
        definition = {"name": self.app, "format": self.i["format"], "pod": self.i["pod"], "services": services,
                      "secrets": [{"name": n, "services": u} for n, u in self.secret_users.items()]}
        return definition, dict(self.secret_values), {}

    def after(self, check, svc, out):
        """Checks that only the substituted strings can fail: an image or a user left empty by a variable."""
        def blame(field, text):
            uses = [v for v in self.i["variables"] for u in v["uses"] if u["service"] == svc["name"] and u["field"] == field]
            check.error("var:" + uses[0]["name"] if uses else "dosya", text)
        if not out["image"] or re.search(r"\s", out["image"]):
            blame("image", "%s: değişkenlerle imaj adı boş ya da boşluklu kalıyor." % svc["name"])
        if out["start"] == "direct" and not master_compose.USER_RE.fullmatch(out["user"] or ""):
            blame("user", "%s: değişkenlerle kullanıcı boş kalıyor." % svc["name"])
        if out["workdir"] is not None and not out["workdir"].startswith("/"):
            blame("working_dir", "%s: çalışma klasörü mutlak bir yol olmalı." % svc["name"])

    def service(self, svc):
        name = svc["name"]
        start = self.chosen["start:" + name]["mode"]
        if start == "direct":
            user = self.sub(svc["user"]) if svc["user"] else DIRECT_USER
            caps_drop, nnp = "all", True
        else:
            user, nnp = None, svc["no_new_privileges"]
            caps_drop, _open = root_caps(svc)
        health = None
        if svc["health"] is not None:
            health = dict(svc["health"], test=[self.sub(t) for t in svc["health"]["test"]])
        if self.compose:
            words = self.sub
        else:
            # Kubernetes fills $(NAME) in an env value from the entries before it, and in command and args
            # from the container's whole plain environment, already filled in.
            plain = {}
            for entry in svc["environment"]:
                if not entry["secret_ref"]:
                    plain[entry["name"]] = master_kube.expand(entry["value"], plain)
            self.expanded = plain
            words = lambda text: master_kube.expand(text, plain)  # noqa: E731
        return {
            "name": name, "image": self.sub(svc["image"]),
            "command": None if svc["command"] is None else [words(t) for t in svc["command"]],
            "entrypoint": None if svc["entrypoint"] is None else [words(t) for t in svc["entrypoint"]],
            "workdir": self.sub(svc["workdir"]), "health": health, "restart": svc["restart"],
            "depends_on": [dict(d) for d in svc["depends_on"]],
            "labels": {k: self.sub(v) for k, v in svc["labels"].items()},
            "stop_signal": svc["stop_signal"], "stop_grace": svc["stop_grace"],
            "start": start, "user": user, "caps_drop": caps_drop, "caps_add": list(svc["caps_add"]),
            "no_new_privileges": nnp, "read_only": svc["read_only"], "init": svc["init"], "hostname": svc["hostname"],
            "shm_size": svc["shm_size"],
            "limits": dict(svc["limits"], ulimits={k: dict(v) for k, v in svc["limits"]["ulimits"].items()}),
            "environment": [self.env(name, e) for e in svc["environment"]],
            "ports": [self.port(name, p) for p in svc["ports"]],
            "mounts": [self.mount(name, m) for m in svc["mounts"]],
        }

    def env(self, service, entry):
        name = entry["name"]
        if entry["secret_ref"]:
            ref = entry["secret_key"]
            return {"name": name, "secret": self.secret(("kube", ref), "%s-%s" % (self.app, name),
                                                        "%s-%s" % (self.app, ref.replace("/", "-")),
                                                        self.chosen["secret:" + ref]["value"], service)}
        qid = "secret:%s:%s" % (service, name)
        if qid in self.chosen:
            return {"name": name, "secret": self.secret(("question", qid), "%s-%s" % (self.app, name),
                                                        "%s-%s-%s" % (self.app, service, name),
                                                        self.chosen[qid]["value"], service)}
        refs = env_refs(entry) if self.compose else []
        secret_refs = [r for r in refs if r["name"] in self.secret_vars]
        if not secret_refs:
            return {"name": name, "value": self.sub(entry["value"]) if self.compose else self.expanded[name]}
        value = self.sub(entry["value"])
        parts = master_compose.template_parts(entry["value"])
        if len(parts) == 1 and len(secret_refs) == 1:
            var = secret_refs[0]["name"]
            secret = self.secret(("var", var), "%s-%s" % (self.app, var), "%s-var-%s" % (self.app, var), value, service)
        else:
            secret = self.secret(("env", service, name), "%s-%s" % (self.app, name), "%s-%s-%s" % (self.app, service, name),
                                 value, service)
        return {"name": name, "secret": secret}

    def port(self, service, port):
        answer = self.chosen["port:%s:%d/%s" % (service, port["port"], port["protocol"])]
        return {"port": port["port"], "protocol": port["protocol"], "use": answer["use"],
                "tailscale_name": answer["tailscale_name"]}

    def mount(self, service, mount):
        if mount["kind"] == "tmpfs":
            return {"target": mount["target"], "to": "tmpfs"}
        qid = "mount:%s:%s" % (service, mount["target"])
        answer = self.chosen[qid]
        if answer["to"] == "app":
            return {"target": mount["target"], "to": "app", "folder": self.questions[qid]["folder"],
                    "read_only": mount["read_only"]}
        return {"target": mount["target"], "to": "srv", "path": answer["path"], "read_only": answer["read_only"]}
