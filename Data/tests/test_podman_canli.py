"""DD-294: Podman, live and fully managed. Podman's API client over a Unix socket (a fake libpod server: JSON
replies, Podman's error message, the chunked event stream split anywhere), the event watch and the live-events
producer that runs it only while a stream is open, who runs a container and what Konsol may do to it, a
container's page (a whitelist: never its environment or command line), its log from where its driver writes it,
and the root worker's container job: through Podman, through a systemd unit, a Quadlet file removed so the
container does not come back, an application's container refused. Temporary folders and fakes only."""
import http.server
import json
import os
from pathlib import Path
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_fixtures  # noqa: E402
import master_container_config as cfg  # noqa: E402
import master_container_manager as manager  # noqa: E402
import master_container_worker as worker  # noqa: E402
import master_containers as mc  # noqa: E402
import master_generator as table  # noqa: E402
import master_olaylar  # noqa: E402
import master_podman_api as api  # noqa: E402

PREFIX = "/v4.0.0/libpod"
ID = "a" * 64


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def fake_podman(test, events=(), pieces=7, hold=None):
    """A libpod API on a temporary Unix socket: /info, an error, and /events streaming `events` chunked, each chunk
    cut into `pieces` writes; the stream then waits for `hold` (an Event) or ends."""
    seen = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def address_string(self):
            return "unix"

        def reply(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            seen.append(self.path)
            if self.path == PREFIX + "/info":
                return self.reply(200, {"version": {"Version": "5.4.2"}})
            if self.path.startswith(PREFIX + "/containers/yok/json"):
                return self.reply(404, {"cause": "no such container", "message": "no container with name or ID \"yok\" found", "response": 404})
            if self.path.startswith(PREFIX + "/events"):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                self.wfile.flush()
                for event in events:
                    data = (json.dumps(event) + "\n").encode()
                    chunk = b"%x\r\n" % len(data) + data + b"\r\n"
                    step = max(1, len(chunk) // pieces)
                    for i in range(0, len(chunk), step):
                        self.wfile.write(chunk[i:i + step])
                        self.wfile.flush()
                        time.sleep(0.01)
                if hold is not None:
                    hold.wait(10)
                try:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                except OSError:
                    pass  # the client stopped first
                return
            return self.reply(404, {"message": "not found"})

    folder = tempfile.mkdtemp(prefix="podman-api-")
    path = os.path.join(folder, "podman.sock")
    server = Server(path, Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def close():
        if hold is not None:
            hold.set()
        server.shutdown()
        server.server_close()
        os.unlink(path)
        os.rmdir(folder)
    test.addCleanup(close)
    return api.Client(path, PREFIX, timeout=5), seen


class ClientTests(unittest.TestCase):
    def test_json_and_podmans_own_error(self):
        client, seen = fake_podman(self)
        self.assertEqual(client.get("/info")["version"]["Version"], "5.4.2")
        with self.assertRaises(api.PodmanApiError) as err:
            client.get("/containers/yok/json")
        self.assertEqual((err.exception.status, str(err.exception)), (404, 'Podman: no container with name or ID "yok" found'))
        self.assertEqual(seen, [PREFIX + "/info", PREFIX + "/containers/yok/json"])

    def test_a_missing_socket_says_so(self):
        with self.assertRaises(api.PodmanApiError) as err:
            api.Client("/nonexistent/podman.sock", PREFIX).get("/info")
        self.assertEqual(err.exception.status, 503)
        with self.assertRaises(api.PodmanApiError):
            api.Client("relative.sock", PREFIX)

    def test_the_event_stream_survives_any_split_and_is_filtered(self):
        events = [{"Type": "container", "Action": "start", "Actor": {"Attributes": {"name": "web"}}},
                  {"Type": "image", "Action": "pull"}, {"Type": "container", "Action": "died"}]
        client, seen = fake_podman(self, events, pieces=13)
        got, opened = [], []
        client.events(lambda: False, got.append, lambda: opened.append(True), poll=0.2)
        self.assertEqual((got, opened), (events, [True]), "every event whole, opened once, the stream's end ends it")
        query = seen[0].split("?", 1)[1]
        self.assertIn("stream=true", query)
        self.assertIn("container", query)
        self.assertIn("network", query)

    def test_stop_is_honoured_while_podman_is_quiet(self):
        hold = threading.Event()
        client, _seen = fake_podman(self, [{"Type": "container", "Action": "start"}], hold=hold)
        got, stop = [], threading.Event()
        threading.Timer(0.5, stop.set).start()
        started = time.monotonic()
        client.events(stop.is_set, got.append, poll=0.1)
        self.assertLess(time.monotonic() - started, 3, "a quiet stream does not hold the watch")
        self.assertEqual(len(got), 1)

    def test_chunk_decoder(self):
        d = api._Chunks(True)
        out = b"".join(d.feed(bytes([b])) for b in b"5\r\nhello\r\n3;x=1\r\n ab\r\n0\r\n\r\n")
        self.assertEqual((out, d.done), (b"hello ab", True))
        with self.assertRaises(api.PodmanApiError):
            api._Chunks(True).feed(b"zz\r\n")


class WatchTests(unittest.TestCase):
    def test_revision_follows_events_and_the_stream_reopens(self):
        events = [{"Type": "container", "Action": "start"}, {"Type": "container", "Action": "stop"}]
        client, _seen = fake_podman(self, events)
        changed = []
        watch = api.Watch(client, changed=lambda: changed.append(True), log=lambda m: None)
        with patch.object(api, "BACKOFF", (0.05,)):
            watch.start()
            deadline = time.monotonic() + 5
            while watch.state()[0] < 6 and time.monotonic() < deadline:
                time.sleep(0.02)
            watch.stop()
        self.assertGreaterEqual(watch.state()[0], 6, "each open counts once and each event once; the ended stream reopened")
        self.assertFalse(watch.state()[1])
        self.assertTrue(changed)

    def test_a_stop_and_a_start_at_once_leave_one_watch_running(self):
        hold = threading.Event()
        client, _seen = fake_podman(self, [{"Type": "container", "Action": "start"}], hold=hold)
        watch = api.Watch(client, log=lambda m: None)
        watch.start()
        deadline = time.monotonic() + 3
        while not watch.state()[1] and time.monotonic() < deadline:
            time.sleep(0.02)
        first = watch.thread
        watch.stop()
        watch.start()  # the last tab closed and a new one opened before the old thread noticed
        self.assertIsNot(watch.thread, first)
        deadline = time.monotonic() + 3
        while not watch.state()[1] and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(watch.state()[1], "the new watch is live")
        first.join(3)
        self.assertFalse(first.is_alive(), "the old one ended")
        self.assertTrue(watch.thread.is_alive())
        watch.stop()

    def test_quiet_events_change_nothing(self):
        changed = []
        watch = api.Watch(None, changed=lambda: changed.append(1))
        for event in ({"Type": "container", "Action": "exec"}, {"Type": "container", "Action": "exec_died"}, {"Type": "container", "Action": "attach"}):
            watch.seen(event)
        health = lambda result: {"Type": "container", "Action": "health_status", "HealthStatus": result, "Actor": {"ID": ID}}
        watch.seen(health("healthy"))
        watch.seen(health("healthy"))
        watch.seen(health("unhealthy"))
        watch.seen({"Type": "container", "Action": "die"})
        self.assertEqual((watch.state()[0], len(changed)), (3, 3), "a health result counts once per change; an exec never")

    def test_a_watch_that_cannot_connect_is_not_live_and_logs_once(self):
        logged = []
        watch = api.Watch(api.Client("/nonexistent/podman.sock", PREFIX), log=logged.append)
        with patch.object(api, "BACKOFF", (0.02,)):
            watch.start()
            time.sleep(0.3)
            watch.stop()
        self.assertEqual(watch.state(), (0, False))
        self.assertEqual(len(logged), 1)


class ProducerWatcherTests(unittest.TestCase):
    def test_watchers_run_with_the_producer_and_a_nudge_reads_the_topic(self):
        calls = []

        class Watcher:
            def start(self):
                calls.append("start")

            def stop(self):
                calls.append("stop")
        reads = []
        events = master_olaylar.Events([master_olaylar.Topic("podman", 3600, lambda: reads.append(1) or {"surum": str(len(reads))})],
                                       tick=0.05, watchers=[Watcher()])
        events.subscribe("tailscale")
        events.subscribe("tailscale")
        time.sleep(0.2)
        self.assertEqual(calls, ["start"], "once for the producer, not per stream")
        first = len(reads)
        events.nudge("podman")
        deadline = time.monotonic() + 2
        while len(reads) == first and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(len(reads), first + 1, "the nudged topic is read on the next tick, not after its hour")
        events.unsubscribe("tailscale")
        events.unsubscribe("tailscale")
        deadline = time.monotonic() + 2
        while calls[-1] != "stop" and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(calls, ["start", "stop"], "the last stream gone: the watch stops")


def raw(name="web", labels=None, cgroup="/machine.slice/libpod-%s.scope" % ID, log="journald", pod="", **extra):
    value = {"Id": ID, "Name": name, "Image": "sha256:" + "b" * 64, "ImageName": "registry.example/web:1", "Pod": pod,
             "Config": {"Labels": labels or {}, "Env": ["PASSWORD=never-shown"], "Cmd": ["--token=never-shown"], "Image": "registry.example/web:1"},
             "CreateCommand": ["podman", "run", "-e", "PASSWORD=never-shown"], "Args": ["--token=never-shown"],
             "State": {"Status": "running", "Running": True, "CgroupPath": cgroup, "StartedAt": "2026-10-29T10:00:00Z", "ExitCode": 0, "Error": ""},
             "HostConfig": {"LogConfig": {"Type": log, "Path": "/var/lib/containers/storage/overlay-containers/%s/userdata/ctr.log" % ID},
                            "RestartPolicy": {"Name": "always"}, "NetworkMode": "bridge"},
             "Mounts": [{"Type": "bind", "Source": "/srv/media", "Destination": "/media", "RW": False},
                        {"Type": "volume", "Name": "veri", "Source": "/var/lib/containers/storage/volumes/veri/_data", "Destination": "/data", "RW": True}],
             "NetworkSettings": {"Networks": {"podman": {"IPAddress": "10.88.0.5"}}}, "RestartCount": 2, "Created": "2026-10-29T09:00:00Z"}
    value.update(extra)
    return value


EVERY = ["baslat", "durdur", "yeniden-baslat", "kaldir"]


class ControlTests(unittest.TestCase):
    def test_who_runs_it_and_what_konsol_may_do(self):
        app = {cfg.MANAGED_LABEL: table.MANAGED_VALUE, table.APP_LABEL: "notlar", "PODMAN_SYSTEMD_UNIT": table.container_unit("notlar", "web")}
        own = raw(table.container_name("notlar", "web"), app)
        self.assertEqual(mc.control(own, app_exists=lambda a: a == "notlar"), {"tur": "uygulama", "ad": "notlar", "eylemler": [], "dosya": ""})
        infra = raw(table.pod_infra_name("ikili"), {"PODMAN_SYSTEMD_UNIT": "konsol-ikili-pod.service"})
        self.assertEqual(mc.control(infra, app_exists=lambda a: a == "ikili")["tur"], "uygulama", "a pod's infra container is its application's")
        self.assertEqual(mc.control(own, app_exists=lambda a: False)["tur"], "birim", "no record: the leftover unit is managed through it")
        self.assertEqual(mc.control(raw(labels={"PODMAN_SYSTEMD_UNIT": "kamera.service"})), {"tur": "birim", "ad": "kamera.service", "eylemler": EVERY, "dosya": ""})
        self.assertEqual(mc.control(raw(cgroup="/system.slice/eski.service/libpod-payload-%s" % ID))["ad"], "eski.service")
        self.assertEqual(mc.control(raw(labels={"com.docker.compose.project": "yigin"})), {"tur": "compose", "ad": "yigin", "eylemler": EVERY, "dosya": ""})
        self.assertEqual(mc.control(raw(labels={"io.podman.compose.project": "yigin2"}))["ad"], "yigin2")
        self.assertEqual(mc.control(raw(), pod="ikili"), {"tur": "pod", "ad": "ikili", "eylemler": EVERY, "dosya": ""})
        self.assertEqual(mc.control(raw()), {"tur": "podman", "ad": "", "eylemler": EVERY, "dosya": ""})
        self.assertEqual(mc.unit_of(raw(labels={"PODMAN_SYSTEMD_UNIT": "bad unit; rm -rf"}), ), "", "only a plain unit name")

    def test_a_unit_label_counts_only_when_systemd_agrees(self):
        folder = "/etc/containers/systemd"
        with tempfile.TemporaryDirectory() as proc:
            os.makedirs(os.path.join(proc, "4242"))
            Path(proc, "4242", "cgroup").write_text("0::/system.slice/kamera.service\n")
            claims = raw(labels={"PODMAN_SYSTEMD_UNIT": "kamera.service"}, State={"Status": "running", "Running": True, "ConmonPid": 4242,
                                                                           "CgroupPath": "/machine.slice/libpod-%s.scope" % ID})
            self.assertTrue(mc.unit_runs(claims, "kamera.service", {"ControlGroup": "/system.slice/kamera.service"}, folder, proc),
                            "the unit's cgroup holds the container's conmon (podman generate systemd)")
            self.assertFalse(mc.unit_runs(claims, "kamera.service", {"ControlGroup": "/system.slice/baska.service"}, folder, proc))
            self.assertFalse(mc.unit_runs(claims, "kamera.service", {}, folder, proc), "a stopped unit with no Quadlet file proves nothing")
        self.assertTrue(mc.unit_runs(raw(), "kamera.service", {"SourcePath": folder + "/kamera.container"}, folder), "generated from a Quadlet file")
        self.assertTrue(mc.unit_runs(raw(cgroup="/system.slice/kamera.service/libpod-payload-%s" % ID), "kamera.service",
                                     {"ControlGroup": "/system.slice/kamera.service"}, folder), "Quadlet's split cgroup")
        for unit in ("tailscaled.service", "ssh.service", "caddy.service", "master-panel.service", "wg-quick@wg0.service", "systemd-logind.service"):
            self.assertFalse(mc.unit_runs(raw(cgroup="/system.slice/%s/x" % unit), unit, {"ControlGroup": "/system.slice/" + unit,
                                                                                          "SourcePath": folder + "/x.container"}, folder), unit)
            spoof = raw(labels={"PODMAN_SYSTEMD_UNIT": unit})
            self.assertEqual(mc.control(spoof)["tur"], "podman", "a label naming %s is ignored" % unit)
        lie = raw(labels={"PODMAN_SYSTEMD_UNIT": "kamera.service"})
        unchecked = mc.control(lie, unit_props=lambda u: {"ControlGroup": "", "SourcePath": "", "folder": folder})
        self.assertEqual(unchecked["tur"], "podman", "systemd does not agree: the container is Podman's alone")
        quadlet = mc.control(lie, unit_props=lambda u: {"SourcePath": folder + "/kamera.container", "folder": folder})
        self.assertEqual((quadlet["tur"], quadlet["dosya"]), ("birim", folder + "/kamera.container"))

    def test_log_source_quadlet_file_and_lines(self):
        self.assertEqual(mc.log_source(raw()), ("journald", ID))
        self.assertEqual(mc.log_source(raw(log="passthrough", labels={"PODMAN_SYSTEMD_UNIT": "kamera.service"})), ("birim", "kamera.service"))
        self.assertEqual(mc.log_source(raw(log="k8s-file"))[0], "dosya")
        self.assertEqual(mc.log_source(raw(log="none")), ("yok", ""))
        self.assertEqual(mc.quadlet_path("/etc/containers/systemd/kamera.container", "/etc/containers/systemd"), "/etc/containers/systemd/kamera.container")
        for bad in ("/etc/containers/systemd/alt/kamera.container", "/etc/systemd/system/kamera.service", "/etc/containers/systemd/../x.container", ""):
            self.assertEqual(mc.quadlet_path(bad, "/etc/containers/systemd"), "", bad)
        self.assertEqual(mc.clean_line("\x1b[31mhata\x1b[0m\x07 sonu"), "hata sonu")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "ctr.log"
            path.write_text("2026-10-29T10:00:00.123456789+01:00 stdout F hazır\n2026-10-29T10:00:01.0+01:00 stderr F uyarı\n")
            self.assertEqual(mc.file_tail(str(path), 5), ["2026-10-29T10:00:00 hazır", "2026-10-29T10:00:01 uyarı"])


class DetailTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.values = app_fixtures.env(tmp.name)
        state = app_fixtures.write_state(tmp.name, self.values)
        self.calls = []
        self.containers = {"kamera": raw("kamera", {"PODMAN_SYSTEMD_UNIT": "kamera.service"}), "web": raw("web")}
        self.unit_file = os.path.join(self.values["KONTEYNER_BIRIM_DIR"], "kamera.container")

        def run(argv, timeout=120, binary=False):
            self.calls.append(list(argv))
            if argv[:2] == ["podman", "version"]:
                return 0, "5.4.2\n", ""
            if argv[:2] == ["podman", "ps"]:
                return 0, json.dumps([{"Id": c["Id"], "Names": [n], "Image": "registry.example/web:1", "State": "running", "Labels": c["Config"]["Labels"],
                                       "Ports": [{"host_ip": "", "host_port": 8080, "container_port": 80, "protocol": "tcp", "range": 1}]}
                                      for n, c in self.containers.items()]), ""
            if argv[:3] == ["podman", "inspect", "--type"]:
                c = self.containers.get(argv[-1])
                return (0, json.dumps([c]), "") if c else (125, "", "no such container")
            if argv[:2] == ["systemctl", "show"]:
                return 0, "ControlGroup=/system.slice/kamera.service\nSourcePath=%s\n" % self.unit_file, ""
            if argv[:1] == ["journalctl"]:
                return 0, "-- Journal begins --\n2026-10-29T10:00:00+0100 sunucu web[1]: \x1b[32mhazır\x1b[0m\n", ""
            return 1, "", "unexpected"
        panel = types.SimpleNamespace(args=types.SimpleNamespace(state=str(state)), run_tool=run)
        self.service = manager.Service(panel)

    def test_a_containers_page_never_carries_its_environment_or_command(self):
        detail = self.service.view().detail("kamera")
        text = json.dumps(detail)
        self.assertNotIn("never-shown", text)
        self.assertEqual(detail["yonetim"], {"tur": "birim", "ad": "kamera.service", "eylemler": EVERY, "dosya": self.unit_file})
        self.assertEqual(detail["baglamalar"][0], {"tur": "bind", "kaynak": "/srv/media", "hedef": "/media", "ad": "", "salt_okunur": True})
        self.assertEqual((detail["aglar"], detail["politika"], detail["yeniden_baslama"], detail["gunluk_kaynagi"]),
                         ([{"ad": "podman", "ipv4": "10.88.0.5", "ipv6": ""}], "always", 2, "journald"))
        self.assertEqual(detail["portlar"][0]["scope"], "public")
        import master_api
        master_api.check(master_api.ref("KonteynerAyrintisi"), detail)
        with self.assertRaises(mc.ContainerError) as err:
            self.service.view().detail("yok")
        self.assertEqual(err.exception.status, 404)
        with self.assertRaises(mc.ContainerError):
            self.service.view().detail("../x")

    def test_the_list_says_who_runs_each_and_the_log_comes_from_journald(self):
        rows = {r["name"]: r for r in self.service.view().liste()["containers"]}
        self.assertEqual(rows["web"]["yonetim"], {"tur": "podman", "ad": "", "eylemler": EVERY, "dosya": ""})
        self.assertEqual(rows["kamera"]["yonetim"]["tur"], "birim")
        log = self.service.view().logs("web", "100")
        self.assertEqual(log, {"satirlar": ["2026-10-29T10:00:00+0100 sunucu web[1]: hazır"], "kesik": False, "kaynak": "journald"})
        self.assertIn(["journalctl", "CONTAINER_ID_FULL=" + ID, "-n", "100", "--no-pager", "-o", "short-iso"], self.calls)

    def test_an_action_is_checked_before_it_becomes_a_job(self):
        launched = []
        with patch.object(self.service, "launch", side_effect=lambda *a: launched.append(a) or {"id": "1" * 32}):
            for bad, status in (({"ad": "../x", "eylem": "durdur"}, 400), ({"ad": "web", "eylem": "sil"}, 400),
                                ({"ad": "web", "eylem": "kaldir"}, 400), ({"ad": "web", "eylem": "kaldir", "onay": "baska"}, 400),
                                ({"ad": "web", "eylem": "durdur", "birimler": "evet"}, 400)):
                with self.assertRaises(mc.ContainerError) as err:
                    self.service.submit_container(bad)
                self.assertEqual(err.exception.status, status, bad)
            self.service.submit_container({"ad": "web", "eylem": "kaldir", "onay": " WEB ", "birimler": True})
        self.assertEqual(launched, [("konteyner", "web", {"name": "web", "eylem": "kaldir", "birim_dosyasi": True, "birimler": True})])


class TopicTests(unittest.TestCase):
    def test_the_live_mark_follows_the_watch_or_the_clock(self):
        import test_resources
        panel = test_resources.panel
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder) / "state.env"
            state.write_text("SERVER_ROOT=%s\nLOCAL_DOMAIN=test\nV2_VERSION=test\nPODMAN_SOCKET=/run/podman/podman.sock\nPODMAN_API=%s\n" % (folder, PREFIX))
            p = panel.Panel(types.SimpleNamespace(state=str(state)))
            self.assertEqual((p.podman_client().path, p.podman_client().prefix), ("/run/podman/podman.sock", PREFIX))
            p.podman_watch.revision, p.podman_watch.live = 7, True
            self.assertEqual(p.podman_changes(), {"surum": "7", "canli": True})
            p.podman_watch.live = False
            with patch.object(panel.time, "time", return_value=1005):
                self.assertEqual(p.podman_changes(), {"surum": "t100", "canli": False}, "while the stream is down, every 10 s")
            self.assertIn(p.podman_watch, p.events.watchers)


class Host:
    """systemctl and Podman as the worker sees them for one container's job."""

    def __init__(self, containers, source="", group=""):
        self.containers, self.source, self.group, self.calls = containers, source, group, []

    def __call__(self, argv, timeout=60, input=None, **kwargs):
        argv = list(argv)
        self.calls.append(argv)
        out, code = "", 0
        if argv[:3] == ["podman", "container", "exists"]:
            code = 0 if argv[-1] in self.containers else 1
        elif argv[:3] == ["podman", "inspect", "--type"]:
            out = json.dumps([self.containers[argv[-1]]])
        elif argv[:2] == ["podman", "rm"]:
            self.containers.pop(argv[-1], None)
        elif argv[:2] == ["podman", "stop"]:
            self.containers[argv[-1]]["State"]["Running"] = False
        elif argv[:2] in (["podman", "start"], ["podman", "restart"]):
            self.containers[argv[-1]]["State"]["Running"] = True
        elif argv[:2] == ["systemctl", "show"]:
            out = "ControlGroup=%s\nSourcePath=%s\n" % (self.group, self.source)
        return subprocess.CompletedProcess(argv, code, out, "")


class WorkerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.values = app_fixtures.env(tmp.name)
        self.state = app_fixtures.write_state(tmp.name, self.values)
        os.makedirs(self.values["KONTEYNER_BIRIM_DIR"])

    def job(self, host, request):
        return worker.Manager(str(self.state), run=host).execute("konteyner", request, uuid.uuid4().hex)

    def test_a_plain_container_goes_through_podman(self):
        host = Host({"web": raw("web")})
        self.job(host, {"name": "web", "eylem": "durdur"})
        self.assertIn(["podman", "stop", "--time", "10", "web"], host.calls)
        self.job(host, {"name": "web", "eylem": "baslat"})
        self.assertIn(["podman", "start", "web"], host.calls)
        result = self.job(host, {"name": "web", "eylem": "kaldir", "birimler": True})
        self.assertIn(["podman", "rm", "--force", "--time", "10", "--volumes", "web"], host.calls)
        self.assertEqual((result["eylem"], "web" in host.containers), ("kaldir", False))
        self.assertFalse([c for c in host.calls if c[:1] == ["systemctl"]])

    def test_a_units_container_goes_through_its_unit_and_its_quadlet_file_goes_too(self):
        path = Path(self.values["KONTEYNER_BIRIM_DIR"]) / "kamera.container"
        path.write_text("[Container]\nImage=registry.example/kamera:1\n")
        host = Host({"kamera": raw("kamera", {"PODMAN_SYSTEMD_UNIT": "kamera.service"})}, source=str(path))
        self.job(host, {"name": "kamera", "eylem": "yeniden-baslat"})
        self.assertIn(["systemctl", "restart", "kamera.service"], host.calls)
        self.assertFalse([c for c in host.calls if c[:2] == ["podman", "restart"]], "systemd would undo a direct restart")
        result = self.job(host, {"name": "kamera", "eylem": "kaldir", "birim_dosyasi": True})
        self.assertIn(["systemctl", "stop", "kamera.service"], host.calls)
        self.assertIn(["systemctl", "daemon-reload"], host.calls)
        self.assertIn(["systemctl", "reset-failed", "kamera.service"], host.calls, "no failed unit left behind for Sağlık")
        self.assertFalse(path.exists(), "it does not come back at the next boot")
        self.assertIn("geri gelmez", result["notlar"][0])

    def test_a_kept_quadlet_file_is_said_and_a_unit_file_is_disabled(self):
        path = Path(self.values["KONTEYNER_BIRIM_DIR"]) / "kamera.container"
        path.write_text("[Container]\n")
        host = Host({"kamera": raw("kamera", {"PODMAN_SYSTEMD_UNIT": "kamera.service"})}, source=str(path))
        result = self.job(host, {"name": "kamera", "eylem": "kaldir", "birim_dosyasi": False})
        self.assertTrue(path.exists())
        self.assertIn("yeniden kurulur", result["notlar"][0])
        host = Host({"eski": raw("eski", {"PODMAN_SYSTEMD_UNIT": "eski.service"}, cgroup="/system.slice/eski.service/libpod-payload-" + ID)},
                    source="/etc/systemd/system/eski.service", group="/system.slice/eski.service")
        self.job(host, {"name": "eski", "eylem": "kaldir"})
        self.assertIn(["systemctl", "disable", "eski.service"], host.calls)

    def test_a_label_systemd_does_not_back_is_ignored(self):
        # A container whose image says PODMAN_SYSTEMD_UNIT=tailscaled.service, or a unit that does not run it:
        # Konsol acts on the container alone and never on the unit.
        for unit, group in (("tailscaled.service", "/system.slice/tailscaled.service"), ("kamera.service", "/system.slice/kamera.service")):
            host = Host({"web": raw("web", {"PODMAN_SYSTEMD_UNIT": unit})}, group=group)
            self.job(host, {"name": "web", "eylem": "kaldir"})
            self.assertFalse([c for c in host.calls if c[:2] in (["systemctl", "stop"], ["systemctl", "disable"])], unit)
            self.assertIn(["podman", "rm", "--force", "--time", "10", "web"], host.calls)

    def test_an_applications_container_is_its_pages(self):
        app_fixtures.record(self.values)
        labels = {cfg.MANAGED_LABEL: table.MANAGED_VALUE, table.APP_LABEL: "notlar",
                  "PODMAN_SYSTEMD_UNIT": table.container_unit("notlar", "web")}
        name = table.container_name("notlar", "web")
        host = Host({name: raw(name, labels)})
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.job(host, {"name": name, "eylem": "durdur"})
        self.assertEqual(err.exception.status, 409)
        self.assertIn("uygulamanın sayfasından", str(err.exception))
        self.assertFalse([c for c in host.calls if c[:2] in (["podman", "stop"], ["systemctl", "stop"])])

    def test_a_start_that_does_not_run_fails(self):
        host = Host({"web": raw("web")})
        real = host.__call__

        def stays_down(argv, **kw):
            p = real(argv, **kw)
            host.containers.get("web", {}).get("State", {})["Running"] = False
            return p
        with self.assertRaises(cfg.ContainerConfigError) as err:
            worker.Manager(str(self.state), run=stays_down).execute("konteyner", {"name": "web", "eylem": "baslat"}, uuid.uuid4().hex)
        self.assertIn("çalışmıyor", str(err.exception))


if __name__ == "__main__":
    unittest.main()
