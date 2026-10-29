#!/usr/bin/env python3
"""Read-only Podman mapper (DD-208), reused by the DD-211 container manager.

Podman is part of the base (Konsol's container runtime). The root backend calls this module
for GET /api/konsol/konteynerler/liste; everything comes from `podman` itself
(ps, inspect, images, system df) run inside the backend's sandbox, which is enough for
reading, and, for a container on the host network, from /proc (the sockets it listens on, DD-215).
Nothing here starts, stops or removes a container: every action is a job of the root worker (an
application's through its own record, any other container's under DD-294's rules, which `control` names).
Environment variables and the command line are never returned (they may hold passwords). An application's
log is its units' journal (master_container_manager, DD-251); any other container's comes from where its log
driver writes it (`log_source`).
"""
import ipaddress
import json
import os
import re
import stat
import sys
import time

NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
# DD-294: what Konsol may do to a container that is not an application's, and the systemd unit names it acts on.
CONTAINER_ACTIONS = ("baslat", "durdur", "yeniden-baslat", "kaldir")
UNIT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@:-]{0,250}\.service\Z")
# Units Konsol never stops, restarts or disables for a container, whatever a container's label names: the
# installer's own and the system's.
PROTECTED_UNITS = frozenset(("tailscaled.service", "caddy.service", "dnsmasq.service", "ssh.service", "sshd.service", "cron.service",
                             "networking.service", "systemd-networkd.service", "systemd-resolved.service", "dbus.service"))
PROTECTED_UNIT_PREFIXES = ("master-", "systemd-", "wg-quick@", "podman", "user@", "getty@", "serial-getty@")
PROJECT_LABELS = ("com.docker.compose.project", "io.podman.compose.project")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
LOG_LINE_CHARS = 2000
# `podman system df`'s kinds as Konsol's Podman section names them (DD-289).
DF_TYPES = {"Images": "images", "Containers": "containers", "Local Volumes": "volumes"}


def epoch(value):
    """podman gives epoch seconds in ps and RFC 3339 text in inspect; the zero time means none."""
    if isinstance(value, (int, float)):
        return int(value) if value > 0 else None
    if isinstance(value, str) and value and not value.startswith("0001-"):
        from datetime import datetime
        text = re.sub(r"(\.\d{1,6})\d*", r"\1", value).replace("Z", "+00:00")
        try:
            return int(datetime.fromisoformat(text).timestamp())
        except ValueError:
            return None
    return None


def ps_ports(items):
    """podman ps gives Ports as a list of {host_ip, host_port, container_port, protocol, range}."""
    rows = []
    for p in items or []:
        if isinstance(p, dict) and str(p.get("host_port", "")).isdigit() and str(p.get("container_port", "")).isdigit():
            rows.append({"host_ip": p.get("host_ip") or "0.0.0.0", "host_port": int(p["host_port"]),
                         "container_port": int(p["container_port"]), "protocol": p.get("protocol") or "tcp"})
    return rows


DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")


def image_repo(ref):
    """Repository of an image reference: without its @digest and without a :tag after the last '/'."""
    repo = str(ref or "").split("@", 1)[0]
    head, sep, last = repo.rpartition("/")
    if sep and ":" in last:
        repo = head + "/" + last.split(":", 1)[0]
    return repo


def update_status(run, image, channel, arch, timeout=30):
    """DD-214: is there a newer build on the image's channel? Reads manifests only, downloads no layer.

    `image` is the installed, digest-pinned reference; `channel` the tag it follows (empty or a
    digest: pinned, nothing to follow). A multi-arch index is compared by this host's platform
    manifest digest, a single manifest by its config digest (the local image id).
    run(argv, timeout) -> (returncode, stdout, last stderr line). Never raises.
    """
    result = {"state": "sabit", "channel": channel or "", "candidate": "", "error": ""}
    if not channel or "@" in channel:
        return result
    rc, out, _ = run(["podman", "image", "inspect", image], 20)
    try:
        info = json.loads(out)[0] if rc == 0 else None
    except (ValueError, IndexError, TypeError):
        info = None
    if not isinstance(info, dict):
        return dict(result, state="denetlenemedi", error="Kurulu imaj okunamadı.")
    local = {str(d).split("@", 1)[1] for d in info.get("RepoDigests") or [] if "@" in str(d)}
    if isinstance(info.get("Digest"), str):
        local.add(info["Digest"])
    rc, out, message = run(["podman", "manifest", "inspect", channel], timeout)
    try:
        remote = json.loads(out) if rc == 0 else None
    except ValueError:
        remote = None
    if not isinstance(remote, dict):
        return dict(result, state="denetlenemedi", error="Kayıt defterine ulaşılamadı" + (": " + message if message else "."))
    if isinstance(remote.get("manifests"), list):
        entries = [m for m in remote["manifests"] if isinstance(m, dict) and isinstance(m.get("platform"), dict)
                   and m["platform"].get("architecture") == arch and m["platform"].get("os", "linux") == "linux"
                   and DIGEST_RE.fullmatch(str(m.get("digest", "")))]
        if not entries:
            return dict(result, state="denetlenemedi", error="Kanalda bu sunucunun mimarisi (%s) için imaj yok." % arch)
        digest = entries[0]["digest"]
        return dict(result, state="guncel" if digest in local else "var", candidate=image_repo(channel) + "@" + digest)
    config = str((remote.get("config") or {}).get("digest", ""))
    if DIGEST_RE.fullmatch(config):
        current = "sha256:" + str(info.get("Id", "")).replace("sha256:", "")
        return dict(result, state="guncel" if config == current else "var")
    return dict(result, state="denetlenemedi", error="Kanalın imaj tanımı okunamadı.")


# DD-215: a container on the host network has no port mappings, so Konsol shows the sockets its own
# processes listen on: TCP in LISTEN and unconnected bound UDP, read from /proc like ss does.
TCP_LISTEN, UDP_UNBOUND = "0A", "07"
TAILNET_NETS = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
SOCKET_SCOPES = ("all", "wan", "tailscale", "other", "local")


def proc_address(text):
    """/proc/net/{tcp,udp}{,6} "0100007F:EE6E" → (address, port); each 32-bit word is in host order."""
    host, _, port = text.partition(":")
    raw = bytes.fromhex(host)
    if len(raw) not in (4, 16):
        raise ValueError("address length")
    if sys.byteorder == "little":
        raw = b"".join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
    ip = ipaddress.ip_address(raw)
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip, int(port, 16)


def socket_scope(ip, wan=(), tailscale=()):
    """The kind of address a socket is bound to, not whether it is reachable (the firewall decides)."""
    if ip.is_unspecified:
        return "all"
    if ip.is_loopback:
        return "local"
    if ip.is_link_local:
        return "link"
    if str(ip) in tailscale:
        return "tailscale"
    if str(ip) in wan:
        return "wan"
    if any(ip.version == net.version and ip in net for net in TAILNET_NETS):
        return "tailscale"
    return "other"


def container_pids(pid, proc="/proc", cgroups="/sys/fs/cgroup", limit=512):
    """The container's init process and every process of its own cgroup (v2) subtree."""
    pids = {pid}
    try:
        with open("%s/%d/cgroup" % (proc, pid)) as f:
            path = next((line.strip()[3:] for line in f if line.startswith("0::")), "")
    except OSError:
        return pids
    if not path.startswith("/") or path == "/":
        return pids
    for root, _, _ in os.walk(os.path.join(cgroups, path.lstrip("/"))):
        try:
            with open(os.path.join(root, "cgroup.procs")) as f:
                pids.update(int(x) for x in f.read().split() if x.isdigit())
        except OSError:
            continue
        if len(pids) >= limit:
            break
    return pids


PASSWD_LIMIT = 256 * 1024
USER_NAME_RE = re.compile(r"[a-z_][a-z0-9_.-]{0,31}\$?\Z")


def passwd_names(pid, proc="/proc"):
    """{uid: name} from a running container's own /etc/passwd, reached through /proc/<pid>/root without
    following a link inside the container (one could point at a host file); {} when it cannot be read."""
    names, root = {}, None
    try:
        root = os.open("%s/%d/root" % (proc, pid), os.O_RDONLY | os.O_DIRECTORY)
        etc = os.open("etc", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root)
        try:
            fd = os.open("passwd", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=etc)
        finally:
            os.close(etc)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return {}
            text = os.read(fd, PASSWD_LIMIT).decode("utf-8", "replace")
        finally:
            os.close(fd)
    except OSError:
        return {}
    finally:
        if root is not None:
            os.close(root)
    for line in text.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[2].isdigit() and USER_NAME_RE.match(parts[0]):
            names.setdefault(int(parts[2]), parts[0])
    return names


def process_users(pid, proc="/proc", cgroups="/sys/fs/cgroup"):
    """Who a running container's processes run as (its init and its cgroup's): [{uid, ad, surec, komutlar}], one
    entry per effective user, the others before root, each with the container's own name for it (null when its
    /etc/passwd has none) and up to three command names. None when no process can be read: unknown, never an
    empty list. The host and the container share user IDs (rootful Podman without a user namespace)."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    names, users = passwd_names(pid, proc), {}
    for p in sorted(container_pids(pid, proc, cgroups)):
        try:
            with open("%s/%d/status" % (proc, p)) as f:
                uid = next(int(line.split()[2]) for line in f if line.startswith("Uid:"))
            with open("%s/%d/comm" % (proc, p)) as f:
                command = "".join(ch for ch in f.read(64).strip() if ch.isprintable())[:32]
        except (OSError, ValueError, IndexError, StopIteration):
            continue
        user = users.setdefault(uid, {"uid": uid, "ad": names.get(uid), "surec": 0, "komutlar": []})
        user["surec"] += 1
        if command and command not in user["komutlar"] and len(user["komutlar"]) < 3:
            user["komutlar"].append(command)
    return sorted(users.values(), key=lambda u: (u["uid"] == 0, u["uid"])) or None


def listening(pid, wan=(), tailscale=(), proc="/proc", cgroups="/sys/fs/cgroup"):
    """Sockets a running host-network container listens on: [{address, port, protocol, scope}].

    Only sockets owned by the container's processes count (their fds matched against the socket
    table of the container's network namespace). IPv6 link-local binds are left out. None when the
    processes or the socket table cannot be read: unknown, never an empty "no ports".
    """
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    inodes, seen_fds = set(), False
    for p in container_pids(pid, proc, cgroups):
        fd_dir = "%s/%d/fd" % (proc, p)
        try:
            names = os.listdir(fd_dir)
        except OSError:
            continue
        seen_fds = True
        for n in names:
            try:
                target = os.readlink(os.path.join(fd_dir, n))
            except OSError:
                continue
            if target.startswith("socket:[") and target.endswith("]"):
                inodes.add(target[8:-1])
    if not seen_fds:
        return None
    rows, seen, tables = [], set(), 0
    for protocol, files in (("tcp", ("tcp", "tcp6")), ("udp", ("udp", "udp6"))):
        for name in files:
            try:
                with open("%s/%d/net/%s" % (proc, pid, name)) as f:
                    lines = f.read().splitlines()[1:]
            except OSError:
                continue
            tables += 1
            for line in lines:
                parts = line.split()
                if len(parts) < 10 or parts[9] not in inodes:
                    continue
                if parts[3] != (TCP_LISTEN if protocol == "tcp" else UDP_UNBOUND) or not parts[2].endswith(":0000"):
                    continue
                try:
                    ip, port = proc_address(parts[1])
                except ValueError:
                    continue
                scope = socket_scope(ip, wan, tailscale)
                if port == 0 or scope == "link" or (protocol, str(ip), port) in seen:
                    continue
                seen.add((protocol, str(ip), port))
                rows.append({"address": str(ip), "port": port, "protocol": protocol, "scope": scope})
    if not tables:
        return None
    rows.sort(key=lambda r: (r["port"], r["protocol"], SOCKET_SCOPES.index(r["scope"]), r["address"]))
    return rows


def protected_unit(unit):
    return unit in PROTECTED_UNITS or unit.startswith(PROTECTED_UNIT_PREFIXES)


def conmon_cgroup(raw, proc="/proc"):
    """The cgroup path of a container's conmon (its unit's own cgroup when a unit runs it), or ""."""
    pid = (raw.get("State") or {}).get("ConmonPid")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return ""
    try:
        with open("%s/%d/cgroup" % (proc, pid), encoding="utf-8") as fh:
            for line in fh.read(8192).splitlines():
                if line.startswith("0::"):
                    return line[3:].strip()
    except OSError:
        return ""
    return ""


def unit_runs(raw, unit, props, folder, proc="/proc"):
    """Whether `unit` really runs this container (DD-294): a label is the container's own word, so it counts only when
    systemd agrees: the unit was generated from a Quadlet file in KONTEYNER_BIRIM_DIR, or the unit's cgroup holds the
    container's conmon or the container itself. The installer's and the system's units never count. props: the
    unit's systemd ControlGroup and SourcePath."""
    if not UNIT_RE.fullmatch(unit) or protected_unit(unit):
        return False
    if quadlet_path(props.get("SourcePath", ""), folder):
        return True
    group = (props.get("ControlGroup") or "").rstrip("/")
    if not group:
        return False
    for path in (conmon_cgroup(raw, proc), str((raw.get("State") or {}).get("CgroupPath", ""))):
        if path and (path == group or path.startswith(group + "/")):
            return True
    return False


def unit_of(raw):
    """The systemd unit a container says runs it: Podman's PODMAN_SYSTEMD_UNIT label (Quadlet, `podman generate
    systemd`), else the service in its cgroup path; "" when nothing but Podman runs it. A claim only: unit_runs
    checks it with systemd."""
    labels = (raw.get("Config") or {}).get("Labels") or {}
    unit = labels.get("PODMAN_SYSTEMD_UNIT")
    if isinstance(unit, str) and UNIT_RE.fullmatch(unit):
        return unit
    cgroup = str((raw.get("State") or {}).get("CgroupPath", ""))
    for part in cgroup.split("/"):
        if part.endswith(".service") and not part.startswith("user@") and UNIT_RE.fullmatch(part):
            return part
    return ""


def control(raw, pod="", app_exists=lambda app: False, unit_props=None):
    """Who runs a container and so how Konsol acts on it (DD-294, the operator's decision of 2026-10-29: every
    container is Konsol's to manage): {tur, ad, eylemler, dosya}. An application's (its labels and a record, or its
    pod's infra container) is managed on the application's page; a systemd unit's through that unit, so systemd does
    not undo it (unit_props(unit) → {ControlGroup, SourcePath, folder}: the claim checked with systemd, unit_runs;
    without it only a protected unit is refused); a Compose project's, a pod's and a plain one through Podman.
    dosya: the unit's Quadlet file, when there is one."""
    import master_container_config as config
    import master_generator as table
    labels = (raw.get("Config") or {}).get("Labels") or {}
    app = labels.get(table.APP_LABEL)
    if config.ownership(raw) == table.MANAGED_VALUE and isinstance(app, str) and app_exists(app):
        return {"tur": "uygulama", "ad": app, "eylemler": [], "dosya": ""}
    name = str(raw.get("Name", "")).lstrip("/")
    if name.endswith("__infra"):
        owner = name[:-len("__infra")]
        try:
            if name == table.pod_infra_name(owner) and app_exists(owner):
                return {"tur": "uygulama", "ad": owner, "eylemler": [], "dosya": ""}
        except table.GeneratorError:
            pass
    every = list(CONTAINER_ACTIONS)
    unit = unit_of(raw)
    if unit:
        props = unit_props(unit) if unit_props else {}
        trusted = unit_runs(raw, unit, props, props.get("folder", "")) if unit_props else not protected_unit(unit)
        if trusted:
            return {"tur": "birim", "ad": unit, "eylemler": every, "dosya": quadlet_path(props.get("SourcePath", ""), props.get("folder", ""))}
    project = next((labels[k] for k in PROJECT_LABELS if isinstance(labels.get(k), str) and labels[k]), "")
    if project:
        return {"tur": "compose", "ad": project, "eylemler": every, "dosya": ""}
    if pod:
        return {"tur": "pod", "ad": pod, "eylemler": every, "dosya": ""}
    return {"tur": "podman", "ad": "", "eylemler": every, "dosya": ""}


def quadlet_path(source, folder):
    """A unit's SourcePath when it is a Quadlet file directly in `folder` (KONTEYNER_BIRIM_DIR), else ""."""
    folder = (folder or "").rstrip("/")
    if folder and isinstance(source, str) and source.startswith(folder + "/") and "/" not in source[len(folder) + 1:] \
            and source.endswith((".container", ".kube", ".pod")) and NAME_RE.fullmatch(source[len(folder) + 1:]):
        return source
    return ""


def log_source(raw):
    """Where a container's output is (DD-294): ("journald", full ID), ("birim", unit) for a unit's passthrough,
    ("dosya", path) for a k8s-file or json-file log, or ("yok", "")."""
    host = raw.get("HostConfig") or {}
    kind = str((host.get("LogConfig") or {}).get("Type") or "")
    ident = raw.get("Id")
    if kind == "journald" and isinstance(ident, str) and re.fullmatch(r"[0-9a-f]{64}", ident):
        return "journald", ident
    if kind == "passthrough" and unit_of(raw):
        return "birim", unit_of(raw)
    path = (host.get("LogConfig") or {}).get("Path") or raw.get("LogPath")
    if kind in ("k8s-file", "json-file") and isinstance(path, str) and path.startswith("/") and ".." not in path.split("/"):
        return "dosya", path
    return "yok", ""


def clean_line(text):
    """A log line as a page shows it: no terminal colours or control characters, at most LOG_LINE_CHARS."""
    text = ANSI_RE.sub("", text)
    text = "".join(ch for ch in text if ch == "\t" or ord(ch) >= 32)
    return text[:LOG_LINE_CHARS]


def file_tail(path, lines, limit=4 * 1024 * 1024):
    """The last `lines` lines of a k8s-file or json-file log (its own format undone to the time and the text)."""
    import json as _json
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - limit))
        data = fh.read(limit).decode("utf-8", "replace")
    out = []
    for line in data.splitlines()[-lines:]:
        if line.startswith("{"):
            try:
                item = _json.loads(line)
                out.append("%s %s" % (str(item.get("time", ""))[:19], str(item.get("log", "")).rstrip("\n")))
                continue
            except ValueError:
                pass
        # k8s-file: "<time> <stream> <F|P> <text>"
        parts = line.split(" ", 3)
        out.append("%s %s" % (parts[0][:19], parts[3]) if len(parts) == 4 and parts[1] in ("stdout", "stderr") else line)
    return out


class ContainerError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class Containers:
    """run(argv, timeout) → (returncode, stdout text, last stderr line); the backend's run_tool."""

    def __init__(self, run):
        self.run = run

    # -- podman
    def podman(self, *args, timeout=20):
        """Runs podman read-only; returns (ok, parsed JSON or text, error text)."""
        rc, out, message = self.run(["podman", *args], timeout)
        if rc != 0:
            return False, None, message or "podman komutu başarısız"
        if "--format" in args and "json" in args:
            try:
                return True, json.loads(out or "null"), ""
            except ValueError:
                return False, None, "podman çıktısı okunamadı"
        return True, out, ""

    def runtime(self):
        ok, version, message = self.podman("version", "--format", "{{.Client.Version}}")
        version = (version or "").strip() if ok else ""
        if ok and not re.fullmatch(r"[0-9][0-9A-Za-z.+~-]{0,30}", version):
            ok, message = False, "podman sürümü okunamadı"
        return {"version": version if ok else "", "ok": ok, "error": "" if ok else "Podman kullanılamıyor: %s" % message}

    def ps(self):
        """`podman ps -a` as rows: (ok, rows, error text)."""
        ok, rows, message = self.podman("ps", "-a", "--format", "json")
        if not ok:
            return False, [], message
        import master_generator as table  # the labels' one home
        result = []
        for c in rows or []:
            if not isinstance(c, dict):
                continue
            names = c.get("Names") or []
            name = names[0] if isinstance(names, list) and names else str(c.get("Id", ""))[:12]
            labels = c.get("Labels") or {}
            if not isinstance(labels, dict):
                labels = {}
            networks = c.get("Networks") or []
            image_id = str(c.get("ImageID") or "")
            result.append({
                "id": str(c.get("Id", ""))[:12], "name": name, "image": c.get("Image", ""),
                # The full ID of the image it was made from (whether an image is unused, Podman's cleanup).
                "image_id": image_id[7:] if image_id.startswith("sha256:") else image_id, "state": c.get("State") or "unknown",
                "status": c.get("Status", ""), "created": epoch(c.get("Created")), "started": epoch(c.get("StartedAt")),
                "exit_code": c.get("ExitCode", 0) if isinstance(c.get("ExitCode"), int) else 0,
                "restarts": c.get("Restarts", 0) if isinstance(c.get("Restarts"), int) else 0,
                "unit": labels.get("PODMAN_SYSTEMD_UNIT", ""),
                # The application a container belongs to, by its labels (a display hint; the worker proves ownership).
                "uygulama": str(labels.get(table.APP_LABEL) or "") if labels.get(table.MANAGED_LABEL) == table.MANAGED_VALUE else "",
                "network": ", ".join(networks) if networks else "host" if (c.get("Namespaces") or {}).get("Net", "") == "host" or not networks else "",
                "pod": str(c.get("PodName") or ""),
                "ports": ps_ports(c.get("Ports")), "mounts": len(c.get("Mounts") or []),
            })
        return True, result, ""

    def liste(self):
        runtime = self.runtime()
        answer = {"read_at": int(time.time()), "runtime": runtime, "containers": [], "images": [],
                  "storage": {"images": 0, "containers": 0, "size": None, "types": []}}
        if not runtime["ok"]:
            return answer
        ok, rows, message = self.ps()
        if not ok:
            answer["runtime"] = {"version": runtime["version"], "ok": False, "error": "Konteynerler okunamadı: %s" % message}
            return answer
        answer["containers"] = rows
        answer["storage"]["containers"] = len(answer["containers"])
        ok, images, _ = self.podman("images", "--format", "json")
        if ok:
            for i in images or []:
                if isinstance(i, dict):
                    for n in (i.get("Names") or ["<adsız>"]):
                        answer["images"].append({"name": n, "size": i.get("Size") if isinstance(i.get("Size"), int) else None, "created": epoch(i.get("Created"))})
            answer["storage"]["images"] = len(answer["images"])
        ok, df, _ = self.podman("system", "df", "--format", "json")
        if ok and isinstance(df, list):
            total = 0
            for row in df:
                size = row.get("RawSize") if isinstance(row, dict) else None
                if isinstance(size, int):
                    total += size
                    # DD-289: each kind's size, how many there are, how many are in use and what is unused (Podman).
                    kind = DF_TYPES.get(row.get("Type"))
                    if kind:
                        count = lambda key: row[key] if isinstance(row.get(key), int) and not isinstance(row[key], bool) else 0
                        free = row.get("RawReclaimable")
                        answer["storage"]["types"].append({"type": kind, "count": count("Total"), "active": count("Active"), "size": size,
                                                           "reclaimable": free if isinstance(free, int) and not isinstance(free, bool) else None})
            answer["storage"]["size"] = total
        return answer
