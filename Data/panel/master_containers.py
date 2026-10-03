#!/usr/bin/env python3
"""Read-only Podman mapper (DD-208), reused by the DD-211 container manager.

Podman is part of the base (the App Store's container runtime). The root backend calls this module
for GET /api/konsol/konteynerler/{liste,ayrinti,gunluk}; everything comes from `podman` itself
(ps, inspect, images, system df, logs) run inside the backend's sandbox, which is enough for
reading. Nothing here starts, stops or removes a container: that belongs to the application that
owns it. Environment variables are never returned (they may hold passwords), and log lines mask
values that follow words like password or token before they leave the server.
"""
import json
import re
import time

NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
TAILS = (100, 200, 500, 1000)
# "A temporary password is provided for this session: X", "token=..." , "API key: ..." → the value is masked.
SECRET_RE = re.compile(r"((?i:password|passwd|parola|secret|token|api[_ -]?key|private[_ -]?key)[^\n:=]{0,60}[:=]\s*)(\S+)")
MASK = "••••"
LABEL_KEYS = {"version": "org.opencontainers.image.version", "source": "org.opencontainers.image.source", "title": "org.opencontainers.image.title"}


def mask(line):
    return SECRET_RE.sub(lambda m: m.group(1) + MASK, line)


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


def ports_of(bindings):
    """{'8080/tcp': [{'HostIp': '', 'HostPort': '61016'}]} → rows; an empty list for host networking."""
    rows = []
    for key, binds in sorted((bindings or {}).items()):
        port, _, proto = str(key).partition("/")
        for b in binds or []:
            host_port = str((b or {}).get("HostPort", "")).strip()
            if port.isdigit() and host_port.isdigit():
                rows.append({"host_ip": (b or {}).get("HostIp") or "0.0.0.0", "host_port": int(host_port),
                             "container_port": int(port), "protocol": proto or "tcp"})
    return rows


def ps_ports(items):
    """podman ps gives Ports as a list of {host_ip, host_port, container_port, protocol, range}."""
    rows = []
    for p in items or []:
        if isinstance(p, dict) and str(p.get("host_port", "")).isdigit() and str(p.get("container_port", "")).isdigit():
            rows.append({"host_ip": p.get("host_ip") or "0.0.0.0", "host_port": int(p["host_port"]),
                         "container_port": int(p["container_port"]), "protocol": p.get("protocol") or "tcp"})
    return rows


class ContainerError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def name_of(value):
    if not isinstance(value, str) or not NAME_RE.fullmatch(value):
        raise ContainerError(400, "Konteyner adı geçersiz.")
    return value


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

    def liste(self):
        runtime = self.runtime()
        answer = {"read_at": int(time.time()), "runtime": runtime, "containers": [], "images": [], "storage": {"images": 0, "containers": 0, "size": None}}
        if not runtime["ok"]:
            return answer
        ok, rows, message = self.podman("ps", "-a", "--format", "json")
        if not ok:
            answer["runtime"] = {"version": runtime["version"], "ok": False, "error": "Konteynerler okunamadı: %s" % message}
            return answer
        for c in rows or []:
            if not isinstance(c, dict):
                continue
            names = c.get("Names") or []
            name = names[0] if isinstance(names, list) and names else str(c.get("Id", ""))[:12]
            labels = c.get("Labels") or {}
            networks = c.get("Networks") or []
            answer["containers"].append({
                "id": str(c.get("Id", ""))[:12], "name": name, "image": c.get("Image", ""), "state": c.get("State") or "unknown",
                "status": c.get("Status", ""), "created": epoch(c.get("Created")), "started": epoch(c.get("StartedAt")),
                "exit_code": c.get("ExitCode", 0) if isinstance(c.get("ExitCode"), int) else 0,
                "restarts": c.get("Restarts", 0) if isinstance(c.get("Restarts"), int) else 0,
                "unit": labels.get("PODMAN_SYSTEMD_UNIT", "") if isinstance(labels, dict) else "",
                "network": ", ".join(networks) if networks else "host" if (c.get("Namespaces") or {}).get("Net", "") == "host" or not networks else "",
                "ports": ps_ports(c.get("Ports")), "mounts": len(c.get("Mounts") or []),
            })
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
            answer["storage"]["size"] = total
        return answer

    def ayrinti(self, name):
        ok, data, message = self.podman("inspect", "--type", "container", name)
        if not ok:
            raise ContainerError(404 if "no such" in message.lower() or "not found" in message.lower() else 502, "Konteyner bulunamadı" if "no such" in message.lower() else "Konteyner okunamadı: %s" % message)
        try:
            c = json.loads(data)[0]
        except (ValueError, IndexError, TypeError):
            raise ContainerError(502, "podman inspect çıktısı okunamadı")
        state, host, config, net = c.get("State") or {}, c.get("HostConfig") or {}, c.get("Config") or {}, c.get("NetworkSettings") or {}
        labels = config.get("Labels") or {}
        health = state.get("Health") or {}
        mounts = []
        for m in c.get("Mounts") or []:
            if isinstance(m, dict):
                mounts.append({"type": m.get("Type", ""), "source": m.get("Source", ""), "destination": m.get("Destination", ""),
                               "rw": bool(m.get("RW", True)), "name": m.get("Name") or ""})
        mounts.sort(key=lambda m: m["destination"])
        return {
            "name": (c.get("Name") or name).lstrip("/"), "id": str(c.get("Id", ""))[:12], "image": c.get("ImageName", ""),
            "image_digest": str(c.get("ImageDigest", "")).replace("sha256:", "")[:12], "state": state.get("Status") or "unknown",
            "status": "", "created": epoch(c.get("Created")), "started": epoch(state.get("StartedAt")), "finished": epoch(state.get("FinishedAt")),
            "exit_code": state.get("ExitCode", 0) if isinstance(state.get("ExitCode"), int) else 0,
            "restarts": c.get("RestartCount", 0) if isinstance(c.get("RestartCount"), int) else 0,
            "unit": labels.get("PODMAN_SYSTEMD_UNIT", "") if isinstance(labels, dict) else "",
            "network": host.get("NetworkMode", "") or "", "health": (health.get("Status") or "") if isinstance(health, dict) else "",
            "ports": ports_of(net.get("Ports") or host.get("PortBindings")), "mounts": mounts,
            "labels": {k: str(labels.get(v, "")) if isinstance(labels, dict) else "" for k, v in LABEL_KEYS.items()},
            "command": " ".join(str(x) for x in (config.get("Cmd") or [])),
        }

    def gunluk(self, name, tail):
        tail = int(tail) if str(tail).isdigit() and int(tail) in TAILS else 200
        ok, text, message = self.podman("logs", "--timestamps", "--tail", str(tail), name, timeout=30)
        if not ok:
            raise ContainerError(404 if "no such" in message.lower() else 502, "Konteyner bulunamadı" if "no such" in message.lower() else "Günlük okunamadı: %s" % message)
        lines = [mask(l) for l in (text or "").splitlines() if l.strip()]
        return {"name": name, "lines": lines[-tail:], "truncated": len(lines) >= tail, "masked": True}
