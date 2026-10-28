#!/usr/bin/env python3
"""Kubernetes YAML read into Obhut's application model (rebuild DD-271, phase 2). Standard library only.

read(docs) takes the documents master_yaml.load_all returned and returns the same model master_compose
returns for Compose (pod: true, the containers share localhost). Kinds read: one Pod or one Deployment
with a single replica, and PersistentVolumeClaims (each becomes a folder of the application). What
`podman kube generate` writes reads cleanly: its annotations, labels, creationTimestamp, empty status,
resources, the capability drops and the like are notes. Anything else this reader does not know is a
refusal naming its key and line (rebuild.md §2.4, §4.2). Nothing here writes, runs or fetches anything.
"""
import re
import shlex

import master_compose as base

KINDS = {"Pod": "v1", "Deployment": "apps/v1", "PersistentVolumeClaim": "v1"}
# Kubernetes wants DNS names; Podman also writes '_' and capitals from its own names (mariadb_data-pvc).
OBJECT_NAME_RE = re.compile(r"[A-Za-z0-9]([A-Za-z0-9_.-]{0,251}[A-Za-z0-9])?\Z")
UNKNOWN = base.UNKNOWN
IGNORED = "%s yok sayılır."
# Harmless keys, ignored with a note.
META_NOTES = ("labels", "annotations", "creationTimestamp", "namespace", "uid", "resourceVersion", "generation")
POD_NOTES = ("hostname", "subdomain", "hostUsers", "dnsPolicy", "schedulerName", "nodeName", "nodeSelector",
             "tolerations", "affinity", "priority", "priorityClassName", "preemptionPolicy", "serviceAccountName",
             "serviceAccount", "enableServiceLinks", "automountServiceAccountToken", "topologySpreadConstraints",
             "imagePullSecrets", "setHostnameAsFQDN")
CONTAINER_NOTES = ("imagePullPolicy", "tty", "stdin", "stdinOnce", "terminationMessagePath", "terminationMessagePolicy",
                   "startupProbe")
SECRET_KEY_RE = re.compile(r"[-._A-Za-z0-9]{1,253}\Z")
CPU_RE = re.compile(r"([0-9]{1,6}(?:\.[0-9]{1,6})?)(m?)\Z")
# Kubernetes quantities: binary suffixes Ki…Ei, decimal k…E, or an exponent.
MEMORY_RE = re.compile(r"([0-9]{1,15}(?:\.[0-9]{1,6})?)(?:e([0-9]{1,2}))?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?\Z")
MEMORY_UNITS = {"Ki": 2 ** 10, "Mi": 2 ** 20, "Gi": 2 ** 30, "Ti": 2 ** 40, "Pi": 2 ** 50, "Ei": 2 ** 60,
                "k": 10 ** 3, "M": 10 ** 6, "G": 10 ** 9, "T": 10 ** 12, "P": 10 ** 15, "E": 10 ** 18}
REFERENCE_RE = re.compile(r"\$(\$|\(([^)]*)\))")


def references(text):
    """The $(NAME) references in a command or args string; $$ escapes ($$(NAME) is literal)."""
    return [m.group(2) for m in REFERENCE_RE.finditer(text) if m.group(1) != "$"]


def expand(text, values):
    """Kubernetes' expansion of env values, command and args: $(NAME) from values, $$ is one $, an unknown
    name stays as written."""
    def one(match):
        if match.group(1) == "$":
            return "$"
        name = match.group(2)
        return values[name] if name in values else match.group(0)
    return REFERENCE_RE.sub(one, text)


def cpu_quantity(value):
    if base.is_int(value):
        return base.cpu_count(value)
    match = CPU_RE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return None
    return base.cpu_count(float(match.group(1)) / (1000 if match.group(2) else 1))


def memory_quantity(value):
    if base.is_int(value):
        return value if value > 0 else None
    match = MEMORY_RE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        return None
    number = float(match.group(1)) * 10 ** int(match.group(2) or 0) * MEMORY_UNITS.get(match.group(3), 1)
    return int(number) if 1 <= number < 2 ** 63 else None
POD_REFUSED = {
    "hostNetwork": "Konteyner sunucunun ağını paylaşamaz; her uygulama kendi köprü ağında çalışır.",
    "hostPID": "Konteyner sunucunun süreçlerini göremez.",
    "hostIPC": "Konteyner sunucunun paylaşılan belleğini kullanamaz.",
    "initContainers": "Başlangıç konteynerleri (initContainers) bu sürümde desteklenmez.",
}
CONTAINER_REFUSED = {
    "envFrom": "ConfigMap ve Secret nesneleri desteklenmez; değişkenleri env ile yazın.",
    "volumeDevices": "Sunucunun aygıtları konteynere verilmez.",
    "lifecycle": "Başlangıç ve durdurma kancaları (lifecycle) desteklenmez.",
}


class _Reader(base._Reader):
    def read(self, docs):
        workload, claims = None, {}
        for doc in docs:
            line = getattr(doc, "line", 1) or 1
            if not isinstance(doc, dict):
                self.f.refuse(line, "kind", "Her belge bir Kubernetes nesnesi (eşleme) olmalı.")
                continue
            kind, api = doc.get("kind"), doc.get("apiVersion")
            kline = base.key_line(doc, "kind", line)
            if not isinstance(kind, str) or kind not in KINDS:
                text = "Desteklenmeyen tür: %s. Pod, tek kopyalı Deployment ve PersistentVolumeClaim okunur." % (
                    kind if isinstance(kind, str) else "yok")
                if kind in ("ConfigMap", "Secret"):
                    text = "%s nesneleri desteklenmez; değerleri env ile yazın, gizli olanları denetçi sorar." % kind
                self.f.refuse(kline, "kind", text)
                continue
            if api != KINDS[kind]:
                self.f.refuse(base.key_line(doc, "apiVersion", line), "apiVersion",
                              "%s için apiVersion %s olmalı." % (kind, KINDS[kind]))
                continue
            if kind == "PersistentVolumeClaim":
                name = self.claim(doc, line)
                if name:
                    claims[name] = line
                continue
            if workload is not None:
                self.f.refuse(kline, "kind", "Dosyada tek bir Pod ya da Deployment olmalı.")
                continue
            workload = (kind, doc, line)
        services, name, name_line = [], "", 1
        if workload is None:
            if not self.f.refusals:
                self.f.refuse(1, "kind", "Dosyada bir Pod ya da Deployment yok.")
        else:
            services, name, name_line = self.workload(*workload)
        used = {m["source"] for s in services for m in s["mounts"] if m["kind"] == "named"}
        for claim, line in claims.items():
            if claim not in used:
                self.f.note(line, "PersistentVolumeClaim", "%s hiçbir konteynerde kullanılmıyor." % claim)
        return {"format": "kubernetes", "name": name, "pod": True, "services": services, "variables": [],
                "refusals": self.f.refusals, "notes": self.f.notes, "name_line": name_line}

    # -- objects
    def keys(self, node, line, handled, notes=(), refused=None):
        """Notes and refusals for every key of node that handled does not take."""
        for key in node:
            kline = base.key_line(node, key, line)
            if key in handled:
                continue
            if key in notes:
                self.f.note(kline, key, IGNORED % key)
            elif refused and key in refused:
                self.f.refuse(kline, key, refused[key])
            else:
                self.f.refuse(kline, key, UNKNOWN % key)

    def metadata(self, doc, line, required=True):
        meta = doc.get("metadata")
        mline = base.key_line(doc, "metadata", line)
        if meta is None and not required:
            return "", mline
        if not isinstance(meta, dict):
            self.f.refuse(mline, "metadata", "metadata bir eşleme olmalı.")
            return "", mline
        self.keys(meta, mline, ("name",), META_NOTES)
        annotations = meta.get("annotations")
        if isinstance(annotations, dict):
            # Podman writes the privileged flag as an annotation too; it is not taken, so it stops here.
            for key, value in annotations.items():
                if key.startswith("io.podman.annotations.privileged") and str(value).lower() == "true":
                    self.f.refuse(base.key_line(annotations, key, mline), key,
                                  base.SERVICE_REFUSED["privileged"])
        name = meta.get("name")
        nline = base.key_line(meta, "name", mline)
        if name is None and not required:
            return "", nline
        if not isinstance(name, str) or not OBJECT_NAME_RE.fullmatch(name):
            self.f.refuse(nline, "name", "metadata.name harf, rakam, '-', '_' ve '.' içeren bir ad olmalı.")
            return "", nline
        return name, nline

    def top_keys(self, doc, line, spec_required=True):
        self.keys(doc, line, ("apiVersion", "kind", "metadata", "spec"), ("status",))
        spec = doc.get("spec")
        if not isinstance(spec, dict):
            if spec_required or spec is not None:
                self.f.refuse(base.key_line(doc, "spec", line), "spec", "spec bir eşleme olmalı.")
            return None
        return spec

    def claim(self, doc, line):
        name, _nline = self.metadata(doc, line)
        spec = self.top_keys(doc, line, spec_required=False)
        if spec is not None:
            sline = base.key_line(doc, "spec", line)
            mode = spec.get("volumeMode")
            if mode not in (None, "Filesystem"):
                self.f.refuse(base.key_line(spec, "volumeMode", sline), "volumeMode", "Yalnız dosya sistemi birimleri okunur.")
            self.keys(spec, sline, ("volumeMode",), ("accessModes", "resources", "storageClassName", "volumeName",
                                                     "selector", "dataSource"))
        if name:
            self.f.note(line, "PersistentVolumeClaim", "%s uygulamanın klasöründe bir alt klasör olur." % name)
        return name

    def workload(self, kind, doc, line):
        name, name_line = self.metadata(doc, line)
        spec = self.top_keys(doc, line)
        if spec is None:
            return [], base.app_name(name), name_line
        sline = base.key_line(doc, "spec", line)
        if kind == "Deployment":
            replicas = spec.get("replicas", 1)
            if replicas != 1 or isinstance(replicas, bool):
                self.f.refuse(base.key_line(spec, "replicas", sline), "replicas",
                              "Deployment tek kopya (replicas: 1) olmalı; bir uygulama bir kez çalışır.")
            self.keys(spec, sline, ("replicas", "template"), ("selector", "strategy", "revisionHistoryLimit",
                                                               "progressDeadlineSeconds", "minReadySeconds"))
            template = spec.get("template")
            tline = base.key_line(spec, "template", sline)
            if not isinstance(template, dict):
                self.f.refuse(tline, "template", "Deployment'ın template bölümü yok.")
                return [], base.app_name(name), name_line
            self.keys(template, tline, ("metadata", "spec"))
            pod_name, pod_line = self.metadata(template, tline, required=False)
            if pod_name:
                name, name_line = pod_name, pod_line
            elif name.endswith("-deployment"):
                name = name[:-len("-deployment")]
            spec = template.get("spec")
            sline = base.key_line(template, "spec", tline)
            if not isinstance(spec, dict):
                self.f.refuse(sline, "spec", "template.spec bir eşleme olmalı.")
                return [], base.app_name(name), name_line
        suggestion = name[:-len("-pod")] if name.endswith("-pod") and len(name) > 4 else name
        return self.pod(spec, sline), base.app_name(suggestion), name_line

    # -- the pod
    def pod(self, spec, line):
        handled = ("containers", "volumes", "restartPolicy", "securityContext", "terminationGracePeriodSeconds")
        for key in ("hostNetwork", "hostPID", "hostIPC"):
            if spec.get(key) is False:
                self.f.note(base.key_line(spec, key, line), key, "%s: false; yok sayılır." % key)
        self.keys(spec, line, handled + tuple(k for k in ("hostNetwork", "hostPID", "hostIPC") if spec.get(k) is False),
                  POD_NOTES, POD_REFUSED)
        policy = spec.get("restartPolicy", "Always")
        restart = {"Always": "always", "OnFailure": "on-failure", "Never": "no"}.get(policy) if isinstance(policy, str) else None
        if restart is None:
            self.f.refuse(base.key_line(spec, "restartPolicy", line), "restartPolicy",
                          "restartPolicy Always, OnFailure ya da Never olmalı.")
            restart = "always"
        grace = None
        if "terminationGracePeriodSeconds" in spec:
            value = spec["terminationGracePeriodSeconds"]
            if base.is_int(value) and value >= 0:
                grace = "%ds" % value
            else:
                self.f.refuse(base.key_line(spec, "terminationGracePeriodSeconds", line), "terminationGracePeriodSeconds",
                              "terminationGracePeriodSeconds bir sayı olmalı.")
        pod_user = self.security(spec.get("securityContext"), base.key_line(spec, "securityContext", line), pod=True)
        volumes = self.volumes_of(spec.get("volumes"), base.key_line(spec, "volumes", line))
        containers = spec.get("containers")
        cline = base.key_line(spec, "containers", line)
        if not isinstance(containers, list) or not containers:
            self.f.refuse(cline, "containers", "containers en az bir konteyner içeren bir liste olmalı.")
            return []
        services, names, used = [], set(), set()
        for i, item in enumerate(containers):
            iline = base.item_line(containers, i, cline)
            svc = self.container(item, iline, volumes, used, pod_user)
            if svc is None:
                continue
            if svc["name"] in names:
                self.f.refuse(iline, "name", "Aynı konteyner adı iki kez: %s" % svc["name"])
                continue
            names.add(svc["name"])
            svc["restart"], svc["stop_grace"] = restart, grace
            services.append(svc)
        for vname, volume in volumes.items():
            if vname not in used:
                self.f.note(volume["line"], "volumes", "%s birimi hiçbir konteynerde bağlanmıyor; yok sayılır." % vname)
        return services

    def security(self, ctx, line, pod=False):
        """The user (runAsUser[:runAsGroup]) a securityContext sets; capabilities only for containers."""
        if ctx is None:
            return {}
        if not isinstance(ctx, dict):
            self.f.refuse(line, "securityContext", "securityContext bir eşleme olmalı.")
            return {}
        out = {}
        for key in ("runAsUser", "runAsGroup"):
            if key in ctx:
                value = ctx[key]
                if base.is_int(value) and value >= 0:
                    out[key] = value
                else:
                    self.f.refuse(base.key_line(ctx, key, line), key, "%s bir sayı olmalı." % key)
        handled = ["runAsUser", "runAsGroup"]
        for key, value in ctx.items():
            kline = base.key_line(ctx, key, line)
            if key == "privileged" and not pod:
                handled.append(key)
                if value is False:
                    self.f.note(kline, key, "privileged: false; konteyner zaten ayrıcalıksız.")
                else:
                    self.f.refuse(kline, key, base.SERVICE_REFUSED["privileged"])
            elif key in ("seccompProfile", "appArmorProfile"):
                handled.append(key)
                if isinstance(value, dict) and value.get("type") == "RuntimeDefault" and len(value) == 1:
                    self.f.note(kline, key, IGNORED % key)
                else:
                    self.f.refuse(kline, key, "Güvenlik profili kapatılamaz ya da değiştirilemez; Obhut varsayılanı kullanır.")
            elif key == "procMount" and not pod:
                handled.append(key)
                if value == "Default":
                    self.f.note(kline, key, IGNORED % key)
                else:
                    self.f.refuse(kline, key, "procMount yalnız Default olabilir.")
            elif key == "capabilities" and not pod:
                handled.append(key)
                out["caps"], out["drops"] = self.capabilities(value, kline)
            elif key in ("readOnlyRootFilesystem", "allowPrivilegeEscalation") and not pod:
                handled.append(key)
                if not isinstance(value, bool):
                    self.f.refuse(kline, key, "%s true ya da false olmalı." % key)
                elif key == "readOnlyRootFilesystem" and value:
                    out["read_only"] = True
                elif key == "allowPrivilegeEscalation" and not value:
                    out["no_new_privileges"] = True
                    self.f.note(kline, key, "Yeni yetki kazanma kapalı (no-new-privileges).")
                else:
                    self.f.note(kline, key, IGNORED % key)
        self.keys(ctx, line, tuple(handled), ("runAsNonRoot", "seLinuxOptions"))
        return out

    def capabilities(self, value, line):
        caps, drops = [], []
        if not isinstance(value, dict):
            self.f.refuse(line, "capabilities", "capabilities bir eşleme olmalı.")
            return caps, drops
        for key, items in value.items():
            kline = base.key_line(value, key, line)
            if key == "drop":
                if not isinstance(items, list):
                    self.f.refuse(kline, key, "drop bir liste olmalı.")
                    continue
                # Only ever more restrictive: ALL and Podman's defaults are dropped; the rest Podman never gives.
                outside = []
                for i, item in enumerate(items):
                    name = base.capability(item)
                    if name is None:
                        self.f.refuse(base.item_line(items, i, kline), "drop", "Geçersiz yetenek adı.")
                    elif name == "ALL" or "ALL" in drops:
                        drops[:] = ["ALL"]
                    elif name in base.DEFAULT_CAPS:
                        if name not in drops:
                            drops.append(name)
                    else:
                        outside.append(name)
                if outside:
                    self.f.note(kline, key, "Podman'ın varsayılanında zaten olmayan yetenekler: %s." % ", ".join(outside))
            elif key == "add":
                if not isinstance(items, list):
                    self.f.refuse(kline, key, "add bir liste olmalı.")
                    continue
                for i, item in enumerate(items):
                    aline = base.item_line(items, i, kline)
                    name = base.capability(item)
                    if name is None:
                        self.f.refuse(aline, "add", "Geçersiz yetenek adı.")
                    elif name not in base.DEFAULT_CAPS:
                        self.f.refuse(aline, "add", "Varsayılan kümenin dışında bir yetenek: %s. Ağ, çekirdek ya da başka "
                                                    "süreçler üzerinde yetki verir; hiçbir uygulamaya verilmez." % name)
                    elif name not in caps:
                        caps.append(name)
            else:
                self.f.refuse(kline, key, UNKNOWN % key)
        both = [c for c in caps if c in drops]
        if both:
            self.f.refuse(line, "capabilities", "Aynı yetenek hem ekleniyor hem düşürülüyor: %s" % ", ".join(both))
        return caps, drops

    def resources(self, svc, value, line):
        if not isinstance(value, dict):
            self.f.refuse(line, "resources", "resources bir eşleme olmalı.")
            return
        for key, item in value.items():
            kline = base.key_line(value, key, line)
            if key == "requests":
                self.f.note(kline, key, IGNORED % key)
            elif key != "limits":
                self.f.refuse(kline, key, UNKNOWN % ("resources." + key))
            elif not isinstance(item, dict):
                self.f.refuse(kline, key, "limits bir eşleme olmalı.")
            else:
                for name, limit in item.items():
                    lline = base.key_line(item, name, kline)
                    if name == "cpu" and cpu_quantity(limit) is not None:
                        svc["limits"]["cpus"] = cpu_quantity(limit)
                    elif name == "memory" and memory_quantity(limit) is not None:
                        svc["limits"]["memory"] = memory_quantity(limit)
                    elif name == "ephemeral-storage":
                        self.f.note(lline, name, IGNORED % name)
                    elif name in ("cpu", "memory"):
                        self.f.refuse(lline, name, "resources.limits.%s okunamadı." % name)
                    else:
                        self.f.refuse(lline, name, "Desteklenmeyen kaynak sınırı: %s" % name[:60])

    def volumes_of(self, value, line):
        volumes = {}
        if value is None:
            return volumes
        if not isinstance(value, list):
            self.f.refuse(line, "volumes", "volumes bir liste olmalı.")
            return volumes
        for i, item in enumerate(value):
            vline = base.item_line(value, i, line)
            if not isinstance(item, dict) or not isinstance(item.get("name"), str) or not item["name"]:
                self.f.refuse(vline, "volumes", "Her birimin bir adı (name) olmalı.")
                continue
            name = item["name"]
            if name in volumes:
                self.f.refuse(vline, "volumes", "Aynı birim adı iki kez: %s" % name[:64])
                continue
            kinds = [k for k in item if k != "name"]
            if len(kinds) != 1 or kinds[0] not in ("hostPath", "persistentVolumeClaim", "emptyDir"):
                self.f.refuse(vline, "volumes", "Desteklenmeyen birim: %s. hostPath, persistentVolumeClaim ve emptyDir "
                                                "okunur." % (", ".join(kinds)[:60] or "türü yok"))
                continue
            kind = kinds[0]
            spec = item[kind]
            kline = base.key_line(item, kind, vline)
            entry = self.volume(kind, spec if spec is not None else {}, kline)
            if entry is not None:
                entry["line"] = vline
                volumes[name] = entry
        return volumes

    def clean(self, node, line, handled, notes=()):
        """keys(), and whether it found nothing to refuse."""
        before = len(self.f.refusals)
        self.keys(node, line, handled, notes)
        return len(self.f.refusals) == before

    def volume(self, kind, spec, line):
        if not isinstance(spec, dict):
            self.f.refuse(line, kind, "%s bir eşleme olmalı." % kind)
            return None
        if kind == "emptyDir":
            if spec.get("medium") not in (None, "", "Memory"):
                self.f.refuse(base.key_line(spec, "medium", line), "medium", "emptyDir yalnız bellekte (tmpfs) olur.")
                return None
            if not self.clean(spec, line, ("medium",), ("sizeLimit",)):
                return None
            return {"kind": "tmpfs", "source": "", "read_only": False}
        if kind == "persistentVolumeClaim":
            claim = spec.get("claimName")
            if not isinstance(claim, str) or not OBJECT_NAME_RE.fullmatch(claim):
                self.f.refuse(base.key_line(spec, "claimName", line), "claimName", "claimName bir ad olmalı.")
                return None
            read_only = spec.get("readOnly", False)
            if not isinstance(read_only, bool):
                self.f.refuse(base.key_line(spec, "readOnly", line), "readOnly", "readOnly true ya da false olmalı.")
                return None
            if not self.clean(spec, line, ("claimName", "readOnly")):
                return None
            return {"kind": "named", "source": claim, "read_only": read_only}
        path = spec.get("path")
        pline = base.key_line(spec, "path", line)
        if not isinstance(path, str) or not path.startswith("/"):
            self.f.refuse(pline, "path", "hostPath.path mutlak bir yol olmalı.")
            return None
        reason = base.host_path_refusal(path)
        if reason:
            self.f.refuse(pline, "path", "Bağlanamaz: %s (%s)." % (path[:80], reason))
            return None
        kind_of = spec.get("type", "")
        if kind_of not in ("", "Directory", "DirectoryOrCreate", "File", "FileOrCreate"):
            self.f.refuse(base.key_line(spec, "type", line), "type",
                          "Yalnız klasör ve dosya bağlanır; soket ve aygıtlar bağlanmaz.")
            return None
        if not self.clean(spec, line, ("path",), ("type",)):
            return None
        return {"kind": "absolute", "source": path, "read_only": False}

    # -- one container
    def container(self, item, line, volumes, used, pod_user):
        if not isinstance(item, dict):
            self.f.refuse(line, "containers", "Konteyner tanımı bir eşleme olmalı.")
            return None
        name = item.get("name")
        if not isinstance(name, str) or not base.NAME_RE.fullmatch(name):
            self.f.refuse(base.key_line(item, "name", line), "name", "Konteynerin geçerli bir adı (name) olmalı.")
            return None
        svc = base.new_service(name, line, "always")
        handled = ("name", "image", "command", "args", "env", "ports", "volumeMounts", "securityContext",
                   "livenessProbe", "readinessProbe", "workingDir", "resources")
        self.keys(item, line, handled, CONTAINER_NOTES, CONTAINER_REFUSED)
        image = item.get("image")
        if image is not None:
            svc["image_line"] = base.key_line(item, "image", line)
            if isinstance(image, str) and image.strip() and not re.search(r"\s", image):
                svc["image"] = image
            else:
                self.f.refuse(svc["image_line"], "image", "image bir imaj adı olmalı (boşluksuz metin).")
        svc["entrypoint"] = self.strings(item, "command", line)
        svc["command"] = self.strings(item, "args", line)
        if "workingDir" in item:
            wline = base.key_line(item, "workingDir", line)
            value = item["workingDir"]
            if isinstance(value, str) and value.startswith("/"):
                svc["workdir"] = value
            else:
                self.f.refuse(wline, "workingDir", "workingDir mutlak bir yol olmalı.")
        ctx = self.security(item.get("securityContext"), base.key_line(item, "securityContext", line))
        uid = ctx.get("runAsUser", pod_user.get("runAsUser"))
        gid = ctx.get("runAsGroup", pod_user.get("runAsGroup"))
        if uid is not None:
            svc["user"] = "%d:%d" % (uid, gid) if gid is not None else str(uid)
        elif gid is not None:
            self.f.note(base.key_line(item, "securityContext", line), "runAsGroup",
                        "runAsUser olmadan runAsGroup yok sayılır.")
        svc["caps_add"], svc["caps_drop"] = ctx.get("caps", []), ctx.get("drops", [])
        svc["read_only"] = ctx.get("read_only", False)
        svc["no_new_privileges"] = ctx.get("no_new_privileges", False)
        if "resources" in item:
            self.resources(svc, item["resources"], base.key_line(item, "resources", line))
        self.env(svc, item.get("env"), base.key_line(item, "env", line))
        self.env_references(svc)
        self.command_references(svc, item, line)
        names = self.ports(svc, item.get("ports"), base.key_line(item, "ports", line))
        self.mounts(svc, item.get("volumeMounts"), base.key_line(item, "volumeMounts", line), volumes, used)
        probe_key = "livenessProbe" if "livenessProbe" in item else "readinessProbe" if "readinessProbe" in item else None
        if probe_key:
            if probe_key == "livenessProbe" and "readinessProbe" in item:
                self.f.note(base.key_line(item, "readinessProbe", line), "readinessProbe",
                            "Sağlık denetimi livenessProbe'dan alınır; readinessProbe yok sayılır.")
            svc["health"] = self.probe(item[probe_key], base.key_line(item, probe_key, line), probe_key, names)
        return svc

    def env_references(self, svc):
        """$(NAME) in an env value: Kubernetes fills it from an entry earlier in the list (at check time); a
        later or unknown name stays as written. A secret may never stand inside another value."""
        secret = {e["name"] for e in svc["environment"] if e["secret_ref"]}
        earlier = set()
        for entry in svc["environment"]:
            if entry["secret_ref"]:
                continue
            names = set(references(entry["value"]))
            if names & secret:
                self.f.refuse(entry["line"], "env", "Gizli değer başka bir değişkenin içinde kullanılamaz: $(%s)."
                              % ", ".join(sorted(names & secret)))
            elif names & earlier:
                self.f.note(entry["line"], "env", "$(%s) bu konteynerin önceki bir ortam değişkeninden doldurulur."
                            % ", ".join(sorted(names & earlier)))
            earlier.add(entry["name"])

    def command_references(self, svc, item, line):
        """$(NAME) in command and args: a secret may not stand there; a known name is filled in at check time."""
        secret = {e["name"] for e in svc["environment"] if e["secret_ref"]}
        plain = {e["name"] for e in svc["environment"] if not e["secret_ref"]}
        for key, words in (("command", svc["entrypoint"]), ("args", svc["command"])):
            names = {name for word in words or () for name in references(word)}
            kline = base.key_line(item, key, line)
            if names & secret:
                self.f.refuse(kline, key, "Gizli değer komut satırında kullanılamaz: $(%s)." % ", ".join(sorted(names & secret)))
            elif names & plain:
                self.f.note(kline, key, "$(%s) konteynerin ortam değişkeninden doldurulur." % ", ".join(sorted(names & plain)))

    def strings(self, item, key, line):
        if key not in item:
            return None
        value = item[key]
        kline = base.key_line(item, key, line)
        if not isinstance(value, list):
            self.f.refuse(kline, key, "%s bir liste olmalı." % key)
            return None
        out = []
        for i, part in enumerate(value):
            text = base.scalar_text(part) if not isinstance(part, bool) else None
            if text is None:
                self.f.refuse(base.item_line(value, i, kline), key, base.TEXT % key)
                return None
            out.append(text)
        return out

    def env(self, svc, value, line):
        if value is None:
            return
        if not isinstance(value, list):
            self.f.refuse(line, "env", "env bir liste olmalı.")
            return
        seen = set()
        for i, item in enumerate(value):
            eline = base.item_line(value, i, line)
            if not isinstance(item, dict) or not isinstance(item.get("name"), str) \
                    or not base.ENV_NAME_RE.fullmatch(item["name"]):
                self.f.refuse(eline, "env", "Her ortam değişkeninin geçerli bir adı (name) olmalı.")
                continue
            name = item["name"]
            if name in seen:
                self.f.refuse(eline, "env", "%s iki kez yazılmış." % name)
                continue
            seen.add(name)
            if "valueFrom" in item:
                ref = item["valueFrom"]
                rline = base.key_line(item, "valueFrom", eline)
                secret = ref.get("secretKeyRef") if isinstance(ref, dict) and len(ref) == 1 else None
                if not isinstance(secret, dict) or not isinstance(secret.get("name"), str) \
                        or not isinstance(secret.get("key"), str) or set(secret) - {"name", "key", "optional"} \
                        or not OBJECT_NAME_RE.fullmatch(secret["name"]) or not SECRET_KEY_RE.fullmatch(secret["key"]):
                    self.f.refuse(rline, "valueFrom", "Yalnız secretKeyRef (name ve key) okunur; ConfigMap ve alan "
                                                      "başvuruları desteklenmez.")
                    continue
                self.keys(item, eline, ("name", "valueFrom"))
                svc["environment"].append({"name": name, "value": "", "line": eline, "secret_ref": True,
                                           "secret_key": "%s/%s" % (secret["name"], secret["key"])})
                continue
            text = "" if item.get("value") is None else base.scalar_text(item["value"])
            if text is None:
                self.f.refuse(base.key_line(item, "value", eline), "value", "value bir metin olmalı.")
                continue
            self.keys(item, eline, ("name", "value"))
            svc["environment"].append({"name": name, "value": text, "line": eline, "secret_ref": False, "secret_key": None})

    def ports(self, svc, value, line):
        names = {}
        if value is None:
            return names
        if not isinstance(value, list):
            self.f.refuse(line, "ports", "ports bir liste olmalı.")
            return names
        for i, item in enumerate(value):
            pline = base.item_line(value, i, line)
            if not isinstance(item, dict):
                self.f.refuse(pline, "ports", "Port tanımı bir eşleme olmalı.")
                continue
            port = item.get("containerPort")
            if not base.is_int(port) or not 0 < port < 65536:
                self.f.refuse(base.key_line(item, "containerPort", pline), "containerPort", "containerPort bir port olmalı.")
                continue
            protocol = item.get("protocol", "TCP")
            if protocol not in ("TCP", "UDP"):
                self.f.refuse(base.key_line(item, "protocol", pline), "protocol", "Yalnız TCP ve UDP portları desteklenir.")
                continue
            host = item.get("hostPort")
            host_port = host if base.is_int(host) and 0 < host < 65536 else None
            ignored = ":".join(base.scalar_text(x) or "?" for x in (item.get("hostIP"), host) if x is not None)
            self.keys(item, pline, ("containerPort", "protocol", "hostPort", "hostIP", "name"))
            if isinstance(item.get("name"), str):
                names[item["name"]] = port
            svc["ports"].append({"port": port, "protocol": protocol.lower(), "host_port": host_port, "line": pline})
            if ignored:
                self.f.note(pline, "hostPort", "Dosyadaki sunucu tarafı (%s) kullanılmaz; port Erişim'den açılır." % ignored)
        return names

    def mounts(self, svc, value, line, volumes, used):
        if value is None:
            return
        if not isinstance(value, list):
            self.f.refuse(line, "volumeMounts", "volumeMounts bir liste olmalı.")
            return
        targets = set()
        for i, item in enumerate(value):
            mline = base.item_line(value, i, line)
            if not isinstance(item, dict):
                self.f.refuse(mline, "volumeMounts", "Bağlama tanımı bir eşleme olmalı.")
                continue
            name = item.get("name")
            if not isinstance(name, str) or name not in volumes:
                self.f.refuse(base.key_line(item, "name", mline), "name",
                              "Tanımlanmamış ya da okunamayan birim: %s" % (name if isinstance(name, str) else "")[:64])
                continue
            target = base.container_path(item.get("mountPath"))
            if target is None or target in targets:
                self.f.refuse(base.key_line(item, "mountPath", mline), "mountPath",
                              "mountPath mutlak, '..' içermeyen ve konteynerde bir kez kullanılan bir yol olmalı.")
                continue
            read_only = item.get("readOnly", False)
            if not isinstance(read_only, bool):
                self.f.refuse(base.key_line(item, "readOnly", mline), "readOnly", "readOnly true ya da false olmalı.")
                continue
            if item.get("mountPropagation") not in (None, "None"):
                self.f.refuse(base.key_line(item, "mountPropagation", mline), "mountPropagation",
                              "Bağlama yayılımı desteklenmez.")
                continue
            refused = {"subPath": "Birimin alt yolu desteklenmez.", "subPathExpr": "Birimin alt yolu desteklenmez.",
                       "recursiveReadOnly": "recursiveReadOnly desteklenmez."}
            before = len(self.f.refusals)
            self.keys(item, mline, ("name", "mountPath", "readOnly", "mountPropagation"), (), refused)
            if len(self.f.refusals) != before:
                continue
            volume = volumes[name]
            used.add(name)
            targets.add(target)
            svc["mounts"].append({"kind": volume["kind"], "source": volume["source"], "target": target,
                                  "read_only": read_only or volume["read_only"], "line": mline})

    def probe(self, value, line, key, port_names):
        if not isinstance(value, dict):
            self.f.refuse(line, key, "%s bir eşleme olmalı." % key)
            return None
        health = {"test": [], "interval": None, "timeout": None, "retries": None, "start_period": None}
        actions = [k for k in ("exec", "httpGet", "tcpSocket", "grpc") if k in value]
        if len(actions) != 1 or actions[0] not in ("exec", "httpGet"):
            self.f.refuse(line, key, "Sağlık denetimi tek bir exec ya da httpGet olmalı.")
            return None
        action = value[actions[0]]
        aline = base.key_line(value, actions[0], line)
        if actions[0] == "exec":
            command = action.get("command") if isinstance(action, dict) and set(action) == {"command"} else None
            if not isinstance(command, list) or not command or not all(isinstance(c, str) for c in command):
                self.f.refuse(aline, "exec", "exec.command bir metin listesi olmalı.")
                return None
            health["test"] = ["CMD"] + list(command)
        else:
            test = self.http_get(action, aline, port_names)
            if test is None:
                return None
            health["test"] = test
        timing = {"initialDelaySeconds": "start_period", "periodSeconds": "interval", "timeoutSeconds": "timeout"}
        for name, field in timing.items():
            if name in value:
                seconds = value[name]
                if base.is_int(seconds) and seconds >= 0:
                    health[field] = "%ds" % seconds
                else:
                    self.f.refuse(base.key_line(value, name, line), name, "%s bir sayı olmalı." % name)
        if "failureThreshold" in value:
            if base.is_int(value["failureThreshold"]) and value["failureThreshold"] > 0:
                health["retries"] = value["failureThreshold"]
            else:
                self.f.refuse(base.key_line(value, "failureThreshold", line), "failureThreshold",
                              "failureThreshold bir sayı olmalı.")
        self.keys(value, line, tuple(actions) + tuple(timing) + ("failureThreshold",),
                  ("successThreshold", "terminationGracePeriodSeconds"))
        return health

    def http_get(self, spec, line, port_names):
        """Podman's own reading of an httpGet probe: curl against the port inside the container."""
        if not isinstance(spec, dict):
            self.f.refuse(line, "httpGet", "httpGet bir eşleme olmalı.")
            return None
        port = spec.get("port")
        if isinstance(port, str) and port in port_names:
            port = port_names[port]
        if not base.is_int(port) or not 0 < port < 65536:
            self.f.refuse(base.key_line(spec, "port", line), "port", "httpGet.port bir port ya da bir port adı olmalı.")
            return None
        path = spec.get("path", "/")
        host = spec.get("host", "localhost")
        scheme = spec.get("scheme", "HTTP")
        if not isinstance(path, str) or not path.startswith("/") or not isinstance(host, str) \
                or not re.fullmatch(r"[A-Za-z0-9.:-]+", host) or scheme not in ("HTTP", "HTTPS"):
            self.f.refuse(line, "httpGet", "httpGet'in path, host ya da scheme alanı okunamadı.")
            return None
        self.keys(spec, line, ("port", "path", "host", "scheme"), ("httpHeaders",))
        self.f.note(line, "httpGet", "Sağlık denetimi konteynerin içinde curl ile yapılır; imajda curl olmalı.")
        url = "%s://%s:%d%s" % (scheme.lower(), host, port, path)
        return ["CMD-SHELL", "curl -f%s %s || exit 1" % ("k" if scheme == "HTTPS" else "", shlex.quote(url))]


def read(docs):
    """The model of a Kubernetes file from master_yaml.load_all's documents (empty documents left out)."""
    return _Reader().read([d for d in docs if d is not None])
