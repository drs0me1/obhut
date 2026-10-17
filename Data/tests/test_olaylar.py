"""DD-259: Konsol's live events. The producer (one reader for every open stream, changed topics only,
slow topics in their own thread, a per-channel stream limit); the activity drawer's operations and the
pending change; and the stream through the real handler on a temporary Unix socket: headers, frames,
heartbeat, the end of a stream, the limit and an internet session that ends while it is open."""
import json
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest.mock import patch

import test_resources
from test_overview import Fixture

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_api  # noqa: E402
import master_olaylar  # noqa: E402
import master_settings  # noqa: E402

panel = test_resources.panel
Events, Topic, TooMany = master_olaylar.Events, master_olaylar.Topic, master_olaylar.TooMany


class ProducerTests(unittest.TestCase):
    def test_a_topic_is_published_again_only_when_it_changed(self):
        clock, value = [0.0], {"a": 1}
        events = Events([Topic("a", 2, lambda: {"v": value["a"]}),
                         Topic("b", 5, lambda: {"read_at": clock[0], "x": 1}, key=master_olaylar.without("read_at"))],
                        clock=lambda: clock[0])
        events.step()
        seen, items = events.wait(0, 0)
        self.assertEqual([(name, json.loads(text)) for name, _, text in items], [("a", {"v": 1}), ("b", {"read_at": 0.0, "x": 1})])
        for now, change in ((1.0, None), (2.0, None), (4.0, 2), (5.0, None)):
            clock[0] = now
            if change:
                value["a"] = change
            events.step()
            seen, items = events.wait(seen, 0)
            self.assertEqual([name for name, _, _ in items], ["a"] if change else [], now)
        self.assertEqual([name for name, _, _ in events.wait(0, 0)[1]], ["b", "a"],
                         "a new stream gets every topic's latest value, in the order they were published")

    def test_a_failing_topic_is_logged_once_and_the_others_go_on(self):
        lines, clock = [], [0.0]

        def broken():
            raise RuntimeError("boom")
        events = Events([Topic("kotu", 1, broken), Topic("iyi", 1, lambda: {"ok": clock[0]})],
                        clock=lambda: clock[0], log=lines.append)
        for now in (0.0, 1.0, 2.0):
            clock[0] = now
            events.step()
        self.assertEqual(lines, ["canlı olay okunamadı: kotu (RuntimeError)"])
        self.assertEqual([name for name, _, _ in events.wait(0, 0)[1]], ["iyi"])

    def test_a_slow_topic_does_not_hold_up_the_others(self):
        gate, started = threading.Event(), threading.Event()

        def slow():
            started.set()
            gate.wait(5)
            return {"saglik": "ok"}
        events = Events([Topic("saglik", 60, slow, slow=True), Topic("kaynaklar", 1, lambda: {"cpu": 1})], clock=lambda: 0.0)
        events.step()
        self.assertTrue(started.wait(5))
        seen, items = events.wait(0, 0)
        self.assertEqual([name for name, _, _ in items], ["kaynaklar"])
        events.due.clear()
        events.step()  # still reading: not started twice
        gate.set()
        seen, items = events.wait(seen, 5)
        self.assertEqual([name for name, _, _ in items], ["saglik"])

    def test_each_channel_has_its_stream_limit_and_the_producer_stops_when_idle(self):
        reads = []
        events = Events([Topic("a", 1, lambda: reads.append(1) or {"n": 1})], limit=2, tick=0.01)
        events.subscribe("tailscale")
        events.subscribe("tailscale")
        with self.assertRaises(TooMany):
            events.subscribe("tailscale")
        events.subscribe("internet")
        self.assertEqual(events.wait(0, 5)[1][0][0], "a")
        for channel in ("tailscale", "tailscale", "internet"):
            events.unsubscribe(channel)
        events.thread.join(5)
        self.assertFalse(events.thread.is_alive())
        self.assertEqual((events.running, events.latest, events.clients), (False, {}, {}))
        events.subscribe("tailscale")  # a later stream starts it again
        self.assertTrue(events.running)
        events.unsubscribe("tailscale")
        events.thread.join(5)


class JobsTests(Fixture):
    def setUp(self):
        super().setUp()
        self.update_state, self.update_log = self.root / "guncelleme.durum", self.root / "guncelleme.log"
        self.repair_state = self.root / "onarim.json"
        with self.state.open("a") as fh:
            fh.write("GUNCELLEME_UNIT=master-guncelle.service\nGUNCELLEME_DURUM_FILE=%s\nGUNCELLEME_LOG_FILE=%s\n"
                     "ONARIM_UNIT=master-onar.service\nONARIM_DURUM_FILE=%s\n" % (self.update_state, self.update_log, self.repair_state))
        self.active = set()
        patch.object(self.p, "unit_active", side_effect=lambda unit: unit in self.active).start()
        self.addCleanup(patch.stopall)

    def jobs(self, now=None):
        with patch.object(panel.time, "time", return_value=now or time.time()):
            result = self.p.jobs()
        master_api.check(master_api.ref("Islemler"), result)
        return result["items"]

    def test_application_and_resource_jobs_from_the_dispatch_records(self):
        now = int(time.time())
        self.p.containers.jobs.update({
            "a" * 32: {"id": "a" * 32, "action": "temizlik", "name": "Podman", "state": "running",
                       "step": "Kaldırılıyor: ornek-veri", "updated_at": now - 5},
            "b" * 32: {"id": "b" * 32, "action": "uygulama-yeniden-baslat", "name": "notlar", "state": "done", "updated_at": now - 10},
            "c" * 32: {"id": "c" * 32, "action": "uygulama-kaldir", "name": "eski", "state": "failed", "error": "Kaldırma başarısız.",
                       "updated_at": now - 20},
            "d" * 32: {"id": "d" * 32, "action": "uygulama-baslat", "name": "dun", "state": "done", "updated_at": now - 3600}})
        items = self.jobs(now=now)
        self.assertEqual([(i["tur"], i["ad"], i["durum"], i["adim"], i["bitis"]) for i in items], [
            ("uygulama", "eski · Kaldırma", "hata", "Kaldırma başarısız.", now - 20),
            ("uygulama", "notlar · Yeniden başlatma", "tamam", "", now - 10),
            ("konteyner", "Podman · Temizlik", "calisiyor", "Kaldırılıyor: ornek-veri", None)])
        self.assertEqual([i["durum"] for i in self.jobs(now=now + panel.JOB_KEEP_SECONDS)], ["calisiyor"],
                         "a finished operation is dropped in time; a running one stays")

    def test_the_update_and_the_repair(self):
        now = int(time.time())
        self.update_state.write_text("durum=calisiyor\nhedef=v2-300\n")
        self.update_log.write_text("==> Aşama 3/7 — Caddy kuruluyor\n")
        self.repair_state.write_text(json.dumps({"durum": "calisiyor", "kip": "onar", "kaynak": "konsol", "baslangic": now - 4,
                                                 "bitis": None, "adimlar": [{"id": "duvar", "ad": "Güvenlik duvarı", "durum": "ok", "detay": ""}]}))
        self.active = {"master-guncelle.service", "master-onar.service"}
        items = self.jobs(now=now)
        self.assertEqual(items, [
            {"tur": "guncelleme", "id": "guncelleme", "ad": "Güncelleme · v2-300", "durum": "calisiyor",
             "adim": "Aşama 3/7 — Caddy kuruluyor", "bitis": None},
            {"tur": "onarim", "id": "onarim", "ad": "Denetle ve onar", "durum": "calisiyor", "adim": "Güvenlik duvarı", "bitis": None}])
        self.update_state.write_text("durum=hata\nhedef=v2-300\nmesaj=İndirme başarısız\nbitis=%d\n" % (now - 30))
        self.repair_state.write_text(json.dumps({"durum": "tamam", "kip": "denetle", "kaynak": "konsol", "baslangic": now - 90,
                                                 "bitis": now - 60, "adimlar": []}))
        self.active = set()
        self.assertEqual([(i["durum"], i["adim"], i["bitis"]) for i in self.jobs(now=now)],
                         [("hata", "İndirme başarısız", now - 30), ("tamam", "", now - 60)])
        self.assertEqual(self.jobs(now=now + panel.JOB_KEEP_SECONDS + 60), [])


class PendingTests(Fixture):
    def test_the_pending_change(self):
        self.assertEqual(self.p.pending(), {"bekleyen": None})
        pending = self.root / "pending.json"
        with self.state.open("a") as fh:
            fh.write("SETTINGS_FILE=%s\nSETTINGS_PENDING_FILE=%s\nSETTINGS_DNS_FILE=%s\n"
                     % (self.root / "settings.json", pending, self.root / "dns.conf"))
        self.assertEqual(self.p.pending(), {"bekleyen": None})
        pending.write_text(json.dumps({"id": "x1", "phase": "awaiting", "until": time.monotonic() + 42, "boot": "b",
                                       "changes": {"web": True}}))
        with patch.object(master_settings, "boot_id", return_value="b"):
            result = self.p.pending()
        master_api.check(master_api.ref("Bekleyen"), result)
        self.assertEqual((result["bekleyen"]["id"], result["bekleyen"]["phase"], result["bekleyen"]["web"]), ("x1", "awaiting", True))
        self.assertIn(result["bekleyen"]["seconds"], (40, 41, 42))


def read_stream(sock_path, headers, timeout=6):
    """The raw HTTP answer of one stream, read until the backend closes the connection."""
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    client.connect(sock_path)
    lines = ["GET /api/konsol/olaylar HTTP/1.1", "Host: panel.test"] + ["%s: %s" % kv for kv in headers.items()]
    client.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    chunks = []
    try:
        while True:
            data = client.recv(65536)
            if not data:
                break
            chunks.append(data)
    finally:
        client.close()
    head, _, body = b"".join(chunks).decode("utf-8").partition("\r\n\r\n")
    return head.split("\r\n"), body


def frames(body):
    out = []
    for block in body.split("\n\n"):
        if block.startswith("event: "):
            lines = dict(line.split(": ", 1) for line in block.splitlines())
            out.append((lines["event"], json.loads(lines["data"])))
    return out


class StreamTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)
        for name, value in (("STREAM_SECONDS", 1.2), ("STREAM_HEARTBEAT_SECONDS", 0.3), ("STREAM_CHECK_SECONDS", 0.2)):
            patch.object(panel, name, value).start()
        self.addCleanup(patch.stopall)
        self.value = {"cpu": [1.5], "sampled_at": 1}
        self.p.events = Events([Topic("kaynaklar", 0.05, lambda: dict(self.value)),
                                Topic("bekleyen", 0.05, lambda: {"bekleyen": None})], limit=2, tick=0.02)

    def test_the_stream_sends_topics_heartbeats_and_ends(self):
        head, body = read_stream(self.sock, {"X-Konsol": "1"})
        self.assertEqual(head[0], "HTTP/1.1 200 OK")
        fields = dict(line.split(": ", 1) for line in head[1:])
        self.assertEqual(fields["Content-Type"], "text/event-stream; charset=utf-8")
        self.assertEqual((fields["Cache-Control"], fields["Connection"], fields["X-Frame-Options"]), ("no-store", "close", "DENY"))
        self.assertEqual(fields["Content-Security-Policy"], panel.CSP)
        self.assertNotIn("Content-Length", fields)
        self.assertTrue(body.startswith("retry: 3000\n\n"))
        self.assertIn(": canli\n\n", body)
        got = frames(body)
        self.assertEqual(got[0], ("kaynaklar", {"cpu": [1.5], "sampled_at": 1}))
        self.assertEqual(got[1], ("bekleyen", {"bekleyen": None}))
        self.assertEqual(got[-1], ("kapat", {"neden": "sure"}))
        self.assertEqual(len(got), 3, "unchanged topics are not sent again")
        master_api.check(master_api.ref("Kapat"), got[-1][1])
        self.assertEqual(self.p.events.clients, {}, "the stream gave its slot back")

    def test_a_change_reaches_an_open_stream(self):
        timer = threading.Timer(0.4, lambda: self.value.update(sampled_at=2))
        timer.start()
        self.addCleanup(timer.cancel)
        _, body = read_stream(self.sock, {"X-Konsol": "1"})
        self.assertEqual([d.get("sampled_at") for n, d in frames(body) if n == "kaynaklar"], [1, 2])

    def test_the_channel_limit_and_the_gates(self):
        self.p.events.subscribe("yerel")
        self.p.events.subscribe("yerel")
        self.addCleanup(lambda: [self.p.events.unsubscribe("yerel") for _ in range(2)])
        status, headers, body = test_resources.unix_get(self.sock, "/api/konsol/olaylar", {"X-Konsol": "1"})
        self.assertEqual(status, 503)
        self.assertIn("canlı akış", json.loads(body)["error"])
        self.assertEqual(test_resources.unix_get(self.sock, "/api/konsol/olaylar", {})[0], 403, "X-Konsol stays required")

    def test_an_internet_stream_ends_with_its_session(self):
        sessions = {"user": "operator"}

        class Store:
            @staticmethod
            def user_for(token):
                return sessions["user"] if token == "t0k3n" else None
        patch.object(self.p, "public_open", return_value=True).start()
        patch.object(self.p, "auth", return_value=Store()).start()
        timer = threading.Timer(0.35, lambda: sessions.update(user=None))
        timer.start()
        self.addCleanup(timer.cancel)
        start = time.monotonic()
        head, body = read_stream(self.sock, {"X-Konsol": "1", "X-Forwarded-For": "198.51.100.7", "X-Konsol-Kanal": "internet",
                                             "Cookie": "%s=t0k3n" % panel.master_auth.COOKIE})
        self.assertEqual(head[0], "HTTP/1.1 200 OK")
        self.assertEqual(frames(body)[-1], ("kapat", {"neden": "oturum"}))
        self.assertLess(time.monotonic() - start, 1.0, "it ended before the stream's time was up")


if __name__ == "__main__":
    unittest.main()
