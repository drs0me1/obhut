#!/usr/bin/env python3
"""Podman's API over its Unix socket (DD-294), Python stdlib only.

The socket (PODMAN_SOCKET, podman.socket) is root's alone; only Konsol's root backend talks to it and no site
forwards it. Reads still run the `podman` command where they did (master_containers); the API serves what the
command cannot: Podman's event stream, followed while a Konsol page is open, so the pages change when Podman
does. Socket activation starts `podman system service` on the first connection and Podman stops it when idle.

`Watch` follows `/events` in its own thread between start() and stop() and counts what it saw; a dropped stream
is opened again with a growing pause, and while it is down the watch says so (the page then reads on a timer).
"""
import http.client
import json
import socket
import threading
import time

# Event types that change what the Podman section or an application shows.
EVENT_TYPES = ("container", "pod", "image", "volume", "network")
# Actions that change nothing a page shows (a health check that kept its result is seen per container below).
QUIET_ACTIONS = frozenset(("exec", "exec_died", "attach", "health_status"))
REPLY_LIMIT = 8 * 1024 * 1024
LINE_LIMIT = 64 * 1024
HEADER_LIMIT = 16 * 1024
# A dropped stream is opened again after these pauses (seconds), the last one repeating.
BACKOFF = (1, 2, 5, 10, 30)


class PodmanApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class _Connection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("d", timeout=timeout)
        self.unix_path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(self.unix_path)
        except OSError:
            sock.close()
            raise
        self.sock = sock


def _query(params):
    from urllib.parse import urlencode
    return "?" + urlencode(params) if params else ""


class Client:
    def __init__(self, path, prefix, timeout=20.0):
        if not isinstance(path, str) or not path.startswith("/") or not isinstance(prefix, str) or not prefix.startswith("/v"):
            raise PodmanApiError(503, "Podman API ayarı eksik; kurulumu yeniden çalıştırın.")
        self.path, self.prefix, self.timeout = path, prefix.rstrip("/"), timeout

    def get(self, path, params=None):
        """GET prefix+path as JSON; an error reply raises with Podman's own message."""
        conn = _Connection(self.path, self.timeout)
        try:
            conn.request("GET", self.prefix + path + _query(params), headers={"Accept": "application/json"})
            reply = conn.getresponse()
            body = reply.read(REPLY_LIMIT + 1)
        except (OSError, http.client.HTTPException) as err:
            raise PodmanApiError(503, "Podman API'sine ulaşılamıyor.") from err
        finally:
            conn.close()
        if len(body) > REPLY_LIMIT:
            raise PodmanApiError(502, "Podman API'sinin yanıtı çok büyük.")
        try:
            value = json.loads(body or b"null")
        except ValueError as err:
            raise PodmanApiError(502, "Podman API'sinin yanıtı okunamadı.") from err
        if reply.status >= 400:
            message = value.get("message") if isinstance(value, dict) else None
            raise PodmanApiError(reply.status, "Podman: %s" % (message if isinstance(message, str) and message else reply.status))
        return value

    def events(self, stop, seen, opened=lambda: None, poll=1.0):
        """Follows the event stream until stop() is true or the stream ends: opened() once Podman accepted it, then
        seen(event) for each event (a dict).
        Read on a raw socket with a short timeout so stop() is honoured while Podman stays quiet; the chunked body
        is decoded here, so a timeout between two reads loses nothing."""
        filters = json.dumps({"type": list(EVENT_TYPES)}, separators=(",", ":"))
        target = self.prefix + "/events" + _query({"stream": "true", "filters": filters})
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(self.path)
            sock.sendall(("GET %s HTTP/1.1\r\nHost: d\r\nAccept: application/json\r\nConnection: close\r\n\r\n" % target).encode("ascii"))
            raw = b""
            while b"\r\n\r\n" not in raw:
                part = sock.recv(4096)
                if not part or len(raw) > HEADER_LIMIT:
                    raise PodmanApiError(502, "Podman olay akışı açılamadı.")
                raw += part
            head, raw = raw.split(b"\r\n\r\n", 1)
            lines = head.decode("latin-1").split("\r\n")
            parts = lines[0].split(" ", 2)
            if len(parts) < 2 or not parts[1].isdigit() or int(parts[1]) != 200:
                raise PodmanApiError(502, "Podman olay akışı açılamadı.")
            chunked = any(l.lower().replace(" ", "") == "transfer-encoding:chunked" for l in lines[1:])
            opened()
            sock.settimeout(poll)
            decoder = _Chunks(chunked)
            text = b""
            for data in _receive(sock, raw, stop):
                text += decoder.feed(data)
                if len(text) > LINE_LIMIT and b"\n" not in text:
                    raise PodmanApiError(502, "Podman olay akışında çok uzun bir satır var.")
                while b"\n" in text:
                    line, text = text.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(event, dict):
                        seen(event)
                if decoder.done:
                    return
        except OSError as err:
            if stop():
                return
            raise PodmanApiError(503, "Podman olay akışı kesildi.") from err
        finally:
            sock.close()


def _receive(sock, first, stop):
    """The body's bytes as they arrive (the part read with the headers first); ends at EOF or when stop() is true."""
    if first:
        yield first
    while not stop():
        try:
            data = sock.recv(65536)
        except socket.timeout:
            continue
        if not data:
            return
        yield data


class _Chunks:
    """HTTP/1.1 chunked transfer decoding, fed piece by piece."""

    def __init__(self, chunked):
        self.chunked, self.buffer, self.left, self.done = chunked, b"", 0, False

    def feed(self, data):
        if not self.chunked:
            return data
        self.buffer += data
        out = b""
        while not self.done:
            if self.left:
                take = self.buffer[:self.left]
                out += take
                self.buffer = self.buffer[len(take):]
                self.left -= len(take)
                if self.left:
                    break
                continue
            if self.buffer.startswith(b"\r\n"):
                self.buffer = self.buffer[2:]
            if b"\r\n" not in self.buffer:
                if len(self.buffer) > 64:
                    raise PodmanApiError(502, "Podman olay akışı bozuk.")
                break
            size, self.buffer = self.buffer.split(b"\r\n", 1)
            try:
                self.left = int(size.split(b";")[0].strip() or b"0", 16)
            except ValueError as err:
                raise PodmanApiError(502, "Podman olay akışı bozuk.") from err
            if self.left == 0:
                self.done = True
        return out


class Watch:
    """Podman's events between start() and stop(): `revision` grows with each event, `live` says whether the stream
    is open now. changed() is called after each event (the live-events producer's nudge)."""

    def __init__(self, client, changed=lambda: None, log=None, sleep=time.sleep):
        self.client, self.changed, self.sleep = client, changed, sleep
        self.log = log or (lambda message: print("panel: %s" % message, flush=True))
        self.lock = threading.Lock()
        self.revision = 0
        self.live = False
        # Each start has its own stop: a stop and a start in quick succession (the last tab closed, a new one opened)
        # end the old thread and begin a new one, never leave none running.
        self.stopping = None
        self.thread = None
        self.health = {}

    def state(self):
        with self.lock:
            return self.revision, self.live

    def start(self):
        with self.lock:
            if self.stopping is not None and not self.stopping.is_set() and self.thread is not None and self.thread.is_alive():
                return
            self.stopping = threading.Event()
            self.thread = threading.Thread(target=self.run, args=(self.stopping,), name="konsol-podman-olaylari", daemon=True)
            self.thread.start()

    def stop(self):
        with self.lock:
            if self.stopping is not None:
                self.stopping.set()
            self.live = False

    def seen(self, event):
        """An event: counted unless it changes nothing a page shows (an exec, an attach, a health check whose
        result is the container's last one)."""
        action = str(event.get("Action") or event.get("status") or "")
        if action in QUIET_ACTIONS:
            if action != "health_status":
                return
            actor = event.get("Actor") if isinstance(event.get("Actor"), dict) else {}
            ident = str(actor.get("ID") or event.get("ID") or event.get("id") or "")
            result = str(event.get("HealthStatus") or (actor.get("Attributes") or {}).get("health_status") or "")
            with self.lock:
                if not ident or self.health.get(ident) == result:
                    return
                self.health[ident] = result
        with self.lock:
            self.revision += 1
        self.changed()

    def opened(self):
        with self.lock:
            self.live = True
            self.health = {}
            # Whatever happened while the stream was closed is read again once.
            self.revision += 1
        self.changed()

    def run(self, stopping):
        failures = 0
        warned = False
        while not stopping.is_set():
            try:
                client = self.client() if callable(self.client) else self.client
                opened = []

                def accepted():
                    opened.append(True)
                    self.opened()
                client.events(stopping.is_set, self.seen, accepted)
                if opened:
                    failures, warned = 0, False
            except PodmanApiError as err:
                if not warned:
                    self.log("Podman olayları izlenemiyor: %s" % err)
                    warned = True
            except Exception as err:  # the watch must never take the backend down
                if not warned:
                    self.log("Podman olayları izlenemiyor (%s)" % err.__class__.__name__)
                    warned = True
            with self.lock:
                if self.stopping is stopping:
                    self.live = False
            if stopping.is_set():
                return
            pause = BACKOFF[min(failures, len(BACKOFF) - 1)]
            failures += 1
            if stopping.wait(pause):
                return
