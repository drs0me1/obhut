"""master_applications (rebuild DD-271, phase 3): the record, the loopback pool, the guard's input, the read
model's pieces and the drafts (K2) with their YAML emitter and the address fetch. Pure functions and
temporary folders only; the address fetch runs against a fake resolver and connection."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_fixtures  # noqa: E402
import master_applications as apps  # noqa: E402
import master_container_config as cfg  # noqa: E402
import master_inspector  # noqa: E402
import master_yaml  # noqa: E402


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="uygulama-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = app_fixtures.env(self.root)


class RecordTests(Case):
    def test_the_rules_are_the_inspectors_and_the_readers(self):
        self.assertIs(apps.APP_NAME_RE, master_inspector.APP_NAME_RE)
        self.assertEqual(apps.TEXT_LIMIT, master_yaml.LIMIT_BYTES)
        for bad in ("Notlar", "a_b", "1x", "", "x" * 31, None):
            with self.subTest(bad=bad), self.assertRaises(cfg.ContainerConfigError):
                apps.app_name(bad)

    def test_a_record_is_written_privately_and_read_back_whole(self):
        made = app_fixtures.record(self.env)
        records = apps.Records(self.env)
        self.assertEqual(records.names(), ["notlar"])
        record = records.load("notlar")
        self.assertEqual((record["text"], record["definition"], record["places"]), (made["text"], made["definition"], made["places"]))
        self.assertEqual(record["source"], {"tur": "dosya", "alindi": 1_800_000_000,
                                            "sha256": __import__("hashlib").sha256(made["text"].encode()).hexdigest()})
        self.assertEqual(record["answers"]["answers"]["var:DB_PASSWORD"], {"set": True})
        self.assertNotIn(app_fixtures.SECRET, json.dumps(record))
        folder = records.dir("notlar")
        self.assertEqual(oct(folder.stat().st_mode & 0o777), "0o700")
        self.assertTrue(all(oct(p.stat().st_mode & 0o777) == "0o600" for p in folder.iterdir() if p.is_file()))
        # The environment file is the generator's path.
        records.write_env("notlar", {"web": "A=1\n", "db": ""})
        self.assertEqual(records.env_files("notlar"), ["db.env", "web.env"])
        self.assertEqual(str(records.env_path("notlar", "web")), app_fixtures.apps.generator.env_file(self.env, "notlar", "web"))
        records.write_env("notlar", {"web": "A=2\n"})
        self.assertEqual(records.env_files("notlar"), ["web.env"], "a service that went loses its file")
        # A snapshot puts every file back as it was, an added env file goes.
        before = records.snapshot("notlar")
        records.write("notlar", text="degisti\n")
        records.write_env("notlar", {"web": "A=3\n", "yeni": "B=1\n"})
        records.restore("notlar", before)
        self.assertEqual(records.snapshot("notlar"), before)
        records.remove("notlar")
        self.assertEqual(records.names(), [])

    def test_anything_not_private_or_not_valid_fails_closed(self):
        app_fixtures.record(self.env)
        records = apps.Records(self.env)
        places = records.dir("notlar") / "yerler.json"
        good = places.read_text()
        for name, change in (("mode", lambda: places.chmod(0o644)),
                             ("link", lambda: (places.unlink(), places.symlink_to(self.root / "elsewhere.json"))),
                             ("garbage", lambda: places.write_text("{")),
                             ("revision", lambda: places.write_text(good.replace('"revision": "' + "a" * 32, '"revision": "x'))),
                             ("secret of another", lambda: places.write_text(good.replace("obhut_notlar_", "obhut_baska_"))),
                             ("unpinned image", lambda: places.write_text(good.replace("@sha256:", ":latest#"))),
                             ("pool twice", lambda: places.write_text(json.dumps(dict(json.loads(good), ports={"web:8080/tcp": 62100, "db:1/tcp": 62100}))))):
            with self.subTest(change=name):
                (self.root / "elsewhere.json").write_text(good)
                change()
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    records.places("notlar")
                self.assertEqual(err.exception.status, 503)
                if places.is_symlink():
                    places.unlink()
                places.write_text(good)
                places.chmod(0o600)
        (self.root / "containers/uygulamalar/Bozuk").mkdir()
        with self.assertRaises(cfg.ContainerConfigError):
            records.names()

    def test_stored_answers_never_hold_a_secret_value_or_a_keep(self):
        inspection = master_inspector.inspect(app_fixtures.TEXT)
        given = app_fixtures.answers()
        self.assertEqual(apps.stored_answers(inspection, given)["answers"]["var:DB_PASSWORD"], {"set": True})
        given["answers"]["var:DB_PASSWORD"] = {"keep": True}
        self.assertEqual(apps.stored_answers(inspection, given)["answers"]["var:DB_PASSWORD"], {"set": True})
        self.assertEqual(apps.stored_answers(inspection, given)["answers"]["start:web"], {"mode": "direct"})
        self.assertEqual(apps.new_questions(inspection, {"answers": {"start:web": {}}})[:2], ["var:DB_PASSWORD", "port:web:8080/tcp"])

    def test_a_request_names_its_source_exactly(self):
        for good in ({"tur": "dosya"}, {"tur": "adres", "adres": "https://example.org/compose.yaml"},
                     {"tur": "imaj", "imaj": "nginx:alpine"}, {"tur": "konteyner", "konteyner": "eski"}):
            self.assertEqual(apps.request_source(good), good)
        for bad in ({"tur": "dosya", "adres": "x"}, {"tur": "adres", "adres": "http://example.org/x"},
                    {"tur": "adres", "adres": "https://user:pass@example.org/x"}, {"tur": "imaj", "imaj": "Bad Image"},
                    {"tur": "konteyner", "konteyner": "../x"}, {"tur": "kod"}, []):
            with self.subTest(bad=bad), self.assertRaises(cfg.ContainerConfigError):
                apps.request_source(bad)

    def test_images_are_read_as_docker_reads_them(self):
        self.assertEqual(apps.reference("nginx"), ("docker.io/library/nginx", "docker.io/library/nginx:latest"))
        self.assertEqual(apps.channel("registry.example/x:2"), "registry.example/x:2")
        self.assertEqual(apps.channel("registry.example/x@sha256:" + "a" * 64), "", "a digest follows no tag")
        info = {"RepoDigests": ["docker.io/library/nginx@sha256:" + "b" * 64, "other/x@sha256:" + "c" * 64]}
        self.assertEqual(apps.pinned(info, "nginx:alpine"), "docker.io/library/nginx@sha256:" + "b" * 64)
        with self.assertRaises(cfg.ContainerConfigError):
            apps.pinned({"RepoDigests": ["other/x@sha256:" + "c" * 64]}, "nginx:alpine")
        self.assertEqual(apps.podman_version("4.9.3\n"), (4, 9))


class FolderTests(Case):
    def test_an_existing_sub_folder_keeps_the_owner_its_container_gave_it(self):
        sub = self.root / "veri" / "uyg" / "db"
        self.assertTrue(apps.make_dir(sub.parent))
        self.assertTrue(apps.make_dir(sub, own=False))
        sub.chmod(0o755)  # as an image's start-up leaves it; the owner check is not made either
        with unittest.mock.patch.object(cfg, "private_dir", side_effect=AssertionError("no chmod or chown")):
            self.assertFalse(apps.make_dir(sub, own=False))
        self.assertEqual(sub.stat().st_mode & 0o777, 0o755)
        link = sub.parent / "baglanti"
        link.symlink_to(self.root)
        with self.assertRaises(cfg.ContainerConfigError):
            apps.make_dir(link, own=False)


class PoolTests(Case):
    def test_ports_are_kept_for_the_same_key_and_new_ones_are_free_of_everything(self):
        app_fixtures.record(self.env, ports={"web:8080/tcp": 62101})
        definition = app_fixtures.checked(app_fixtures.SIMPLE, app_fixtures.SIMPLE_ANSWERS)[1]
        held = {62100}
        bind = lambda port: port not in held
        # 62100 is held by a listener, 62101 by notlar, 62102 by a Yayınla row, 62103 is a base port.
        env = dict(self.env, SOME_PORT="62103")
        ports = apps.allocate(env, "sayac", definition, {}, manual={62102}, bind=bind)
        self.assertEqual(ports, {"app:9000/tcp": 62104})
        self.assertEqual(apps.allocate(env, "sayac", definition, {"app:9000/tcp": 62109, "eski:1/tcp": 62108}, manual=set(), bind=bind),
                         {"app:9000/tcp": 62109}, "kept across edits; a key that went is dropped")
        with self.assertRaises(cfg.ContainerConfigError) as err:
            apps.allocate(env, "sayac", definition, {"app:9000/tcp": 62101}, manual=set(), bind=bind)
        self.assertEqual(err.exception.status, 409, "another application's port is never taken over")
        with self.assertRaises(cfg.ContainerConfigError) as err:
            apps.allocate(dict(env, YAYIN_PORT_SON="62101"), "sayac", definition, {}, manual=set(), bind=bind)
        self.assertIn("boş port kalmadı", str(err.exception))
        raw = json.loads(json.dumps(definition))
        raw["services"][0]["ports"][0]["use"] = "raw"
        self.assertEqual(apps.allocate(env, "sayac", raw, {"app:9000/tcp": 62109}, manual=set(), bind=bind), {},
                         "a raw port publishes nothing (A2)")

    def test_the_guard_reads_each_bridge_and_its_loopback_publications(self):
        app_fixtures.record(self.env)
        self.assertEqual(apps.guard_input(self.env), [{"app": "notlar", "interface": apps.interface(self.env, "notlar"),
                                                       "publications": [{"service": "web", "port": 8080, "protocol": "tcp",
                                                                         "host_ip": "127.0.0.1", "host_port": 62100}]}])


class ReadModelTests(Case):
    def test_states_and_actions(self):
        made = app_fixtures.record(self.env)
        record = apps.Records(self.env).load("notlar")
        objects = apps.names("notlar", record["definition"])
        live = {"containers": {"notlar_web": {"state": "running"}, "notlar_db": {"state": "running"}},
                "units": {"konsol-notlar_web.service": "active", "konsol-notlar_db.service": "active"},
                "usage": {"notlar_web": (1.5, 100), "notlar_db": (None, 50)}}
        item = apps.summary(record, objects, live, None, {"web": {"state": "var"}, "db": {"state": "guncel"}})
        self.assertEqual((item["durum"], item["kaynak"], item["guncelleme"]), ("calisiyor", {"cpu": 1.5, "bellek": 150}, "yeni"))
        self.assertEqual([s["guncelleme"] for s in item["servisler"]], ["yeni", "guncel"])
        self.assertEqual(item["revizyon"], made["places"]["revision"])
        for unit_state, expected in (("activating", "islemde"), ("failed", "hata"), ("inactive", "kismen")):
            live["units"]["konsol-notlar_db.service"] = unit_state
            self.assertEqual(apps.summary(record, objects, live, None, None)["durum"], expected)
        self.assertEqual(apps.app_state(["durduruldu", "durduruldu"]), "durduruldu")
        self.assertEqual(apps.service_state("active", False, None), "hata", "an active unit without its container")


class EmitterTests(unittest.TestCase):
    def test_every_value_survives_the_reader_and_compose_reads_no_variable_in_it(self):
        values = ["plain", "", "with space", "quote \" and \\ back", "tab\tnew\nline", "$HOME and ${X} and $$",
                  "true", "null", "123", "-1", "#hash", "- dash", ": colon", "ç ğ ı ö ş ü", "\x01\x7f ", "emoji 🐳"]
        # A newline cannot be an environment value (one line of an env file); a command word may hold one.
        # An empty one is a secret the operator gives (the inspector asks for it).
        plain = [v for v in values if "\n" not in v and v]
        document = {"name": "deneme", "services": {"web": {"image": "registry.example/web:1",
                                                           "environment": {"K%d" % n: v for n, v in enumerate(plain)},
                                                           "command": values}}}
        text = apps.compose_text("bir test", document)
        loaded = master_yaml.load(text)
        self.assertEqual(loaded["services"]["web"]["command"], [v.replace("$", "$$") for v in values])
        inspection = master_inspector.inspect(text)
        self.assertEqual(inspection["refusals"], [])
        definition, _secrets, errors = master_inspector.check(inspection, {"name": "deneme", "answers": {"start:web": {"mode": "root"}}})
        self.assertEqual(errors, {})
        [svc] = definition["services"]
        self.assertEqual({e["name"]: e["value"] for e in svc["environment"]}, {"K%d" % n: v for n, v in enumerate(plain)},
                         "Compose reads every value back as written")
        self.assertEqual(svc["command"], values)
        self.assertEqual(inspection["variables"], [])
        self.assertTrue(text.startswith("# Obhut taslağı: bir test ("))
        for key in ("true", "on", "a b", "1x"):
            self.assertEqual(master_yaml.load(apps.compose_text("k", {key: 1}))[key], 1)


class DraftTests(unittest.TestCase):
    IMAGE = {"Config": {"ExposedPorts": {"80/tcp": {}, "443/tcp": {}, "53/udp": {}}, "Volumes": {"/data": {}, "/var/cache/x": {}},
                        "Env": ["PATH=/usr/bin"], "Cmd": ["serve"], "WorkingDir": "/app", "User": ""}}

    def test_an_image_draft_has_one_service_its_ports_and_volumes_and_nothing_else(self):
        text = apps.image_draft("registry.example/team/web-app:1.2", self.IMAGE)
        inspection = master_inspector.inspect(text)
        self.assertEqual(inspection["refusals"], [])
        [svc] = inspection["services"]
        self.assertEqual((inspection["name"], svc["name"], svc["image"]), ("web-app", "web-app", "registry.example/team/web-app:1.2"))
        self.assertEqual([(p["port"], p["protocol"]) for p in svc["ports"]], [(53, "udp"), (80, "tcp"), (443, "tcp")])
        self.assertEqual([(m["kind"], m["source"], m["target"]) for m in svc["mounts"]],
                         [("named", "web-app-data", "/data"), ("named", "web-app-x", "/var/cache/x")])
        self.assertEqual(svc["command"], None, "the image's own command stays")

    def container(self, **host):
        return {"Name": "eski-uygulama", "ImageName": "registry.example/team/web-app:1.2",
                "Config": {"Env": ["PATH=/usr/bin", "container=podman", "HOSTNAME=abc", "DB_PASSWORD=cok-gizli", "MODE=prod",
                                   "API_TOKEN=tok-123"],
                           "Cmd": ["serve", "--fast"], "WorkingDir": "/app", "User": "1000", "ExposedPorts": {"8080/tcp": {}}},
                "HostConfig": dict({"PortBindings": {"8080/tcp": [{"HostPort": "18080"}]}, "RestartPolicy": {"Name": "always"},
                                    "CapDrop": ["CAP_MKNOD", "CAP_NET_RAW", "CAP_AUDIT_WRITE", "CAP_SETFCAP"]}, **host),
                "Mounts": [{"Type": "volume", "Name": "veri", "Destination": "/data", "RW": True},
                           {"Type": "bind", "Source": "/srv/media", "Destination": "/media", "RW": False}]}

    def test_a_container_draft_carries_what_differs_and_never_a_secret_value(self):
        text = apps.container_draft(self.container(), self.IMAGE)
        self.assertNotIn("cok-gizli", text)
        self.assertNotIn("tok-123", text)
        inspection = master_inspector.inspect(text)
        self.assertEqual(inspection["refusals"], [])
        [svc] = inspection["services"]
        env = {e["name"]: e["value"] for e in svc["environment"]}
        self.assertEqual(env, {"API_TOKEN": "", "DB_PASSWORD": "", "MODE": "prod"}, "no image or Podman entry; secrets empty")
        self.assertEqual((svc["command"], svc["user"], svc["restart"]), (["serve", "--fast"], "1000", "always"))
        self.assertEqual(svc["workdir"], None, "the image's own working folder is not repeated")
        self.assertEqual([(m["kind"], m["source"], m["target"], m["read_only"]) for m in svc["mounts"]],
                         [("named", "veri", "/data", False), ("absolute", "/srv/media", "/media", True)])
        self.assertEqual([p["port"] for p in svc["ports"]], [8080])
        self.assertEqual(svc["caps_drop"], ["SETFCAP"], "only a drop from Podman's default set is written")
        self.assertIn("secret:eski-uygulama:DB_PASSWORD", [q["id"] for q in inspection["questions"]])

    def test_refused_settings_are_written_as_they_are_so_the_inspector_says_why(self):
        host = {"Privileged": True, "NetworkMode": "host", "PidMode": "host", "Devices": [{"PathOnHost": "/dev/fuse",
                "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"}], "Sysctls": {"net.ipv4.ip_forward": "1"}}
        inspection = master_inspector.inspect(apps.container_draft(self.container(**host), self.IMAGE))
        keys = {r["key"] for r in inspection["refusals"]}
        self.assertLessEqual({"privileged", "network_mode", "pid", "devices", "sysctls"}, keys)


class Response:
    def __init__(self, status=200, body=b"", headers=None):
        self.status, self.body, self.headers = status, body, headers or {}

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def read1(self, n):
        chunk, self.body = self.body[:n], self.body[n:]
        return chunk


class FakeConnection:
    def __init__(self, site, host, address, port, timeout):
        self.site, self.host, self.address = site, host, address
        self.sock = None

    def request(self, method, path, headers=None):
        self.site.requests.append((self.host, self.address, path, headers))

    def getresponse(self):
        value = self.site.pages[(self.host, self.site.requests[-1][2])]
        if isinstance(value, Exception):
            raise value
        return Response(*value)

    def close(self):
        pass


class Site:
    """DNS and HTTPS as the fetch sees them."""

    def __init__(self, dns, pages):
        self.dns, self.pages, self.requests, self.lookups = dns, pages, [], []

    def lookup(self, host, port):
        self.lookups.append(host)
        return self.dns[host]

    def connection(self, host, address, port, timeout):
        return FakeConnection(self, host, address, port, timeout)


class FetchTests(Case):
    def fetch(self, site, url="https://dosya.example.org/compose.yaml", clock=None):
        kwargs = {"clock": clock} if clock else {}
        return apps.fetch(url, self.env, lookup=site.lookup, connection=site.connection, **kwargs)

    def test_a_public_address_gives_its_text_and_the_connection_goes_to_the_checked_address(self):
        site = Site({"dosya.example.org": ["93.184.215.14", "2606:2800:21f:cb07:6820:80da:af6b:8b2c"]},
                    {("dosya.example.org", "/compose.yaml?v=1"): (200, "services: {}\n".encode())})
        self.assertEqual(self.fetch(site, "https://dosya.example.org/compose.yaml?v=1#x"), "services: {}\n")
        host, address, path, headers = site.requests[0]
        self.assertEqual((host, address, path, headers["Accept-Encoding"]), ("dosya.example.org", "93.184.215.14", "/compose.yaml?v=1", "identity"))
        self.assertEqual(site.lookups, ["dosya.example.org"], "one lookup, no second resolution at connect time")

    def test_every_local_private_or_special_address_is_refused(self):
        for address in ("127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "169.254.169.254", "100.64.0.7", "0.0.0.0",
                        "224.0.0.1", "240.0.0.1", "::1", "fe80::1", "fd7a:115c:a1e0::1", "fc00::1", "::ffff:127.0.0.1",
                        "64:ff9b::7f00:1", "2002:7f00:1::", "2001:0:4136:e378:8000:63bf:3fff:fdd2", "ff02::1", "::"):
            with self.subTest(address=address):
                site = Site({"dosya.example.org": ["93.184.215.14", address]}, {})
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    self.fetch(site)
                self.assertEqual(err.exception.status, 400)
                self.assertEqual(site.requests, [], "nothing is asked of a refused address")
        self.assertTrue(apps.public("93.184.215.14", apps.blocked_networks(self.env)))
        with self.assertRaises(cfg.ContainerConfigError):
            apps.blocked_networks(dict(self.env, VPN_BLOCK_DEST6=""))

    def test_scheme_and_credentials_are_refused_before_any_lookup(self):
        site = Site({}, {})
        for url in ("http://dosya.example.org/x", "file:///etc/passwd", "https://user:pw@dosya.example.org/x", "https:///x",
                    "https://dosya.example.org:99999/x", "https://dosya.example.org/\x00", "x" * 3000):
            with self.subTest(url=url[:40]), self.assertRaises(cfg.ContainerConfigError):
                self.fetch(site, url)
        self.assertEqual(site.lookups, [])

    def test_redirects_are_followed_three_times_each_checked(self):
        dns = {"a.example.org": ["93.184.215.14"], "b.example.org": ["93.184.215.15"], "ic.example.org": ["10.0.0.5"]}
        pages = {("a.example.org", "/1"): (302, b"", {"Location": "https://b.example.org/2"}),
                 ("b.example.org", "/2"): (301, b"", {"Location": "/3"}),
                 ("b.example.org", "/3"): (307, b"", {"Location": "https://a.example.org/4"}),
                 ("a.example.org", "/4"): (200, b"ok\n")}
        self.assertEqual(self.fetch(Site(dns, pages), "https://a.example.org/1"), "ok\n")
        pages[("a.example.org", "/4")] = (308, b"", {"Location": "https://a.example.org/5"})
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.fetch(Site(dns, pages), "https://a.example.org/1")
        self.assertIn("en çok 3", str(err.exception))
        for location in ("https://ic.example.org/x", "http://b.example.org/x"):
            pages[("a.example.org", "/4")] = (302, b"", {"Location": location})
            with self.subTest(location=location), self.assertRaises(cfg.ContainerConfigError):
                self.fetch(Site(dns, pages), "https://a.example.org/1")

    def test_size_text_status_compression_and_time_are_bounded(self):
        dns = {"dosya.example.org": ["93.184.215.14"]}
        cases = {"big": (200, b"#" * (apps.TEXT_LIMIT + 1)), "binary": (200, b"\xff\xfe"), "nul": (200, b"a\x00b"),
                 "status": (404, b"yok"), "gzip": (200, b"x", {"Content-Encoding": "gzip"}),
                 "error": OSError("reset")}
        for name, page in cases.items():
            with self.subTest(case=name), self.assertRaises(cfg.ContainerConfigError):
                self.fetch(Site(dns, {("dosya.example.org", "/compose.yaml"): page}))
        self.assertEqual(len(self.fetch(Site(dns, {("dosya.example.org", "/compose.yaml"): (200, b"#" * apps.TEXT_LIMIT)}))),
                         apps.TEXT_LIMIT)
        clock = iter([0, 0, 11, 11, 11]).__next__
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.fetch(Site(dns, {("dosya.example.org", "/compose.yaml"): (200, b"x")}), clock=clock)
        self.assertIn("zamanında", str(err.exception))


if __name__ == "__main__":
    unittest.main()
