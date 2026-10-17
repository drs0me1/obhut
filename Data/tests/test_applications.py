"""master_applications (rebuild DD-271, phases 3 and 4): the record and its access rows (the row store, seeding,
an edit's port rules, name checks and the rows of every application), the loopback pool, the guard's input, the
read model's pieces and the drafts (K2) with their YAML emitter and the address fetch. Pure functions and
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
        self.assertNotIn("port:web:8080/tcp", record["answers"]["answers"], "the row holds how a port is reached")
        self.assertEqual(record["rows"], {"web:8080/tcp": {"tur": "adres", "ad": "notlar", "tailscale_portu": None, "internet": ""}})
        self.assertEqual(record["definition"]["services"][0]["ports"], [{"port": 8080, "protocol": "tcp"}])
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
        self.assertNotIn("port:web:8080/tcp", apps.stored_answers(inspection, given)["answers"])
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


ADDRESS = {"tur": "adres", "ad": "notlar", "tailscale_portu": None, "internet": ""}
# A web service with an address, a raw TCP port and a UDP port (raw, closed).
PORTS = """name: notlar
services:
  web:
    image: registry.example/notlar/web:1.4
    ports:
      - "8080"
      - "2222"
      - "5353/udp"
"""
PORT_ANSWERS = {"name": "notlar", "answers": {"port:web:8080/tcp": {"use": "caddy", "tailscale_name": "notlar"},
                                              "port:web:2222/tcp": {"use": "raw"}, "port:web:5353/udp": {"use": "raw"},
                                              "start:web": {"mode": "root"}}}


class RowTests(Case):
    def setUp(self):
        super().setUp()
        self.env.update(DNSMASQ_CONF_FILE=str(self.root / "dnsmasq/local-services.conf"), DNSMASQ_CONF_DIR=str(self.root / "dnsmasq"),
                        SETTINGS_FILE=str(self.root / "ayarlar.json"))
        (self.root / "dnsmasq").mkdir()

    def test_install_seeds_one_row_per_port_and_the_definition_keeps_only_numbers(self):
        made = app_fixtures.record(self.env, text=PORTS, given=PORT_ANSWERS)
        self.assertEqual(made["rows"], {"web:8080/tcp": ADDRESS, "web:2222/tcp": {"tur": "ham", "kapsam": "kapali", "port": 2222},
                                        "web:5353/udp": {"tur": "ham", "kapsam": "kapali", "port": 5353}})
        self.assertEqual(made["places"]["ports"], {"web:8080/tcp": 62100}, "only an address has a pool port")
        records = apps.Records(self.env)
        record = records.load("notlar")
        self.assertEqual(record["rows"], made["rows"])
        self.assertEqual(record["definition"]["services"][0]["ports"],
                         [{"port": 8080, "protocol": "tcp"}, {"port": 2222, "protocol": "tcp"}, {"port": 5353, "protocol": "udp"}])
        self.assertEqual(sorted(record["answers"]["answers"]), ["start:web"])
        path = records.dir("notlar") / "erisim.json"
        self.assertEqual((oct(path.stat().st_mode & 0o777), json.loads(path.read_text())), ("0o600", {"satirlar": made["rows"]}))
        # The checked definition (with its answers) is never stored as it is.
        with self.assertRaises(cfg.ContainerConfigError):
            records.write("notlar", definition=made["checked"])
        with self.assertRaises(cfg.ContainerConfigError):
            records.write("notlar", answers={"name": "notlar", "answers": {"port:web:8080/tcp": {"use": "raw"}}})
        self.assertEqual(apps.row_id("notlar", "web:8080/tcp"), "uygulama:notlar:web:8080/tcp")

    def test_anything_unexpected_in_the_rows_fails_closed(self):
        app_fixtures.record(self.env, text=PORTS, given=PORT_ANSWERS)
        records = apps.Records(self.env)
        path = records.dir("notlar") / "erisim.json"
        good = json.loads(path.read_text())
        ham = {"tur": "ham", "kapsam": "kapali", "port": 2222}

        def rows(**changes):
            value = json.loads(json.dumps(good))
            value["satirlar"].update(changes)
            return value
        cases = {
            "garbage": "{", "not an object": [], "another key": dict(good, fazla=1), "no rows": {},
            "a row too many": rows(**{"web:9/tcp": ham}), "a row missing": {"satirlar": {k: v for k, v in good["satirlar"].items()
                                                                                       if k != "web:2222/tcp"}},
            "an extra field": rows(**{"web:8080/tcp": dict(ADDRESS, not_=1)}),
            "an address on UDP": rows(**{"web:5353/udp": dict(ADDRESS, ad="dns")}),
            "a raw port for the pool port": rows(**{"web:8080/tcp": dict(ham, port=8080)}),
            "an address without a pool port": rows(**{"web:2222/tcp": dict(ADDRESS, ad="ssh")}),
            "an unknown kind": rows(**{"web:2222/tcp": {"tur": "elle", "port": 2222}}),
            "an unknown scope": rows(**{"web:2222/tcp": dict(ham, kapsam="lan")}),
            "a key that is not a port": {"satirlar": dict(good["satirlar"], **{"web:0/tcp": ham})},
        }
        for value in ("Notlar", "-notlar", "notlar-", "a" * 64, "", 7, "panel", "paylas"):
            cases["name %r" % (value,)] = rows(**{"web:8080/tcp": dict(ADDRESS, ad=value)})
        for value in (0, 65536, True, "8080", 1.5):
            cases["Tailscale port %r" % (value,)] = rows(**{"web:8080/tcp": dict(ADDRESS, tailscale_portu=value)})
            cases["raw port %r" % (value,)] = rows(**{"web:2222/tcp": dict(ham, port=value)})
        for value in ("Notlar.example.org", "notlar.example.org.", "localhost", "notlar", "https://notlar.example.org", None):
            cases["internet name %r" % (value,)] = rows(**{"web:8080/tcp": dict(ADDRESS, internet=value)})
        cases["one open raw port twice"] = rows(**{"web:2222/tcp": dict(ham, kapsam="tailscale", port=9000),
                                                   "web:8080/tcp": dict(ADDRESS, tailscale_portu=9000)})
        for name, value in cases.items():
            with self.subTest(case=name):
                path.write_text(value if isinstance(value, str) else json.dumps(value))
                path.chmod(0o600)
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    records.load("notlar")
                self.assertEqual(err.exception.status, 503)
        path.write_text(json.dumps(good))
        for name, change in (("mode", lambda: path.chmod(0o644)), ("missing", path.unlink),
                             ("link", lambda: (path.unlink(), path.symlink_to(self.root / "elsewhere.json")))):
            with self.subTest(case=name):
                (self.root / "elsewhere.json").write_text(json.dumps(good))
                change()
                with self.assertRaises(cfg.ContainerConfigError):
                    records.rows("notlar")
                if path.is_symlink() or path.exists():
                    path.unlink()
                path.write_text(json.dumps(good))
                path.chmod(0o600)
        # Two closed raw rows may share a number: neither publishes.
        path.write_text(json.dumps(rows(**{"web:5353/udp": dict(ham, port=2222)})))
        self.assertEqual(records.load("notlar")["rows"]["web:5353/udp"]["port"], 2222)

    def test_an_edit_keeps_the_row_of_a_port_that_stays(self):
        made = app_fixtures.record(self.env, text=PORTS, given=PORT_ANSWERS)
        record = apps.Records(self.env).load("notlar")
        record["rows"]["web:8080/tcp"] = dict(ADDRESS, ad="yeni-ad", tailscale_portu=8443)  # as Erişim changed it
        text = PORTS.replace('      - "2222"\n', '      - "9090"\n')
        inspection = master_inspector.inspect(text)
        # The ports that stay need no answer; a new one does.
        answers, errors = apps.port_answers(record, inspection, {"name": "notlar", "answers": {
            "start:web": {"mode": "root"}, "port:web:9090/tcp": {"use": "caddy", "tailscale_name": "notlar-9090"}}})
        self.assertEqual(errors, {})
        self.assertEqual(answers["answers"]["port:web:8080/tcp"], {"use": "caddy", "tailscale_name": "yeni-ad"})
        self.assertEqual(answers["answers"]["port:web:5353/udp"], {"use": "raw"})
        self.assertNotIn("port:web:2222/tcp", answers["answers"], "a port that went has no question")
        definition, _values, check_errors = master_inspector.check(inspection, answers)
        self.assertEqual(check_errors, {})
        rows = apps.next_rows(definition, record["rows"])
        self.assertEqual(rows, {"web:8080/tcp": record["rows"]["web:8080/tcp"], "web:5353/udp": made["rows"]["web:5353/udp"],
                                "web:9090/tcp": dict(ADDRESS, ad="notlar-9090")})
        # An answer given for a port that stays must be what its row is.
        for qid, given in (("port:web:8080/tcp", {"use": "raw"}), ("port:web:8080/tcp", {"use": "caddy", "tailscale_name": "notlar"}),
                           ("port:web:5353/udp", {"use": "caddy", "tailscale_name": "dns"})):
            with self.subTest(qid=qid, given=given):
                _answers, errors = apps.port_answers(record, inspection, {"name": "notlar", "answers": {qid: given}})
                self.assertEqual(errors, {qid: "Bu portun kullanımı Erişim'den değişir."})
        _answers, errors = apps.port_answers(record, inspection, {"name": "notlar", "answers": {
            "port:web:8080/tcp": {"use": "caddy", "tailscale_name": "yeni-ad"}}})
        self.assertEqual(errors, {})
        self.assertEqual(apps.port_answers(record, inspection, "bozuk"), ("bozuk", {}), "the inspector says why")
        # yenile: the stored answers with the port answers from the rows; only a new port is a new question.
        filled = apps.filled_answers(record)
        self.assertEqual(filled["answers"]["port:web:8080/tcp"], {"use": "caddy", "tailscale_name": "yeni-ad"})
        self.assertEqual(apps.new_questions(master_inspector.inspect(PORTS), filled), [])
        self.assertEqual(apps.new_questions(inspection, filled), ["port:web:9090/tcp"])

    def test_a_new_tailscale_name_must_be_free_everywhere(self):
        app_fixtures.record(self.env, text=PORTS, given=PORT_ANSWERS)
        definition = app_fixtures.checked(app_fixtures.SIMPLE, app_fixtures.SIMPLE_ANSWERS)[1]
        question = "port:app:9000/tcp"
        named = lambda name: apps.name_errors(self.env, "sayac", json.loads(json.dumps(definition).replace('"sayac"', '"%s"' % name)))  # noqa: E731
        self.assertEqual(named("sayac"), {})
        self.assertEqual(named("notlar"), {question: "notlar.ev adı zaten kullanılıyor."}, "another application's row")
        Path(self.env["DNSMASQ_CONF_FILE"]).write_text("interface-name=panel.ev,tailscale0/4\ninterface-name=temel.ev,tailscale0/4\n")
        (self.root / "dnsmasq/modul-paylasim.conf").write_text("interface-name=ek.ev,tailscale0/4\n")
        (self.root / "dnsmasq" / apps.DNS_FILE).write_text("interface-name=eski.ev,tailscale0/4\n")
        Path(self.env["SETTINGS_FILE"]).write_text(json.dumps({"dns": {"records": [{"name": "kayit.ev", "target": "tailscale",
                                                                                   "enabled": True}]}}))
        for name in ("temel", "ek", "kayit"):
            with self.subTest(name=name):
                self.assertEqual(named(name), {question: "%s.ev adı zaten kullanılıyor." % name})
        self.assertEqual(named("eski"), {}, "the applications' own DNS file is their projection; the rows decide")
        taken = apps.taken_names(self.env)
        self.assertLessEqual({"panel.ev", "paylas.ev", "notlar.ev", "temel.ev", "ek.ev", "kayit.ev"}, taken)
        # A row renamed in Erişim holds its new name; an edit of the same application keeps its own names.
        records = apps.Records(self.env)
        rows = records.load("notlar")["rows"]
        records.write("notlar", rows=dict(rows, **{"web:8080/tcp": dict(ADDRESS, ad="yeni")}))
        self.assertEqual(named("notlar"), {})
        self.assertEqual(named("yeni"), {question: "yeni.ev adı zaten kullanılıyor."})
        self.assertNotIn("yeni.ev", apps.taken_names(self.env, skip_app="notlar"))
        self.assertNotIn("yeni.ev", apps.taken_names(self.env, skip_rows={"uygulama:notlar:web:8080/tcp"}))
        # The ports that stay are not checked again; without a local domain nothing is decided.
        self.assertEqual(apps.name_errors(self.env, "sayac", json.loads(json.dumps(definition).replace('"sayac"', '"yeni"')),
                                          rows={"app:9000/tcp": ADDRESS}), {})
        with self.assertRaises(cfg.ContainerConfigError) as err:
            apps.name_errors(dict(self.env, LOCAL_DOMAIN=""), "sayac", definition)
        self.assertEqual(err.exception.status, 503)
        Path(self.env["SETTINGS_FILE"]).write_text("{")
        with self.assertRaises(cfg.ContainerConfigError):
            named("sayac")

    def test_every_row_of_every_application_with_its_pool_port(self):
        app_fixtures.record(self.env, text=PORTS, given=PORT_ANSWERS)
        app_fixtures.record(self.env, text=app_fixtures.SIMPLE, given=app_fixtures.SIMPLE_ANSWERS, app="sayac",
                            ports={"app:9000/tcp": 62105})
        (Path(self.env["UYGULAMA_STATE_DIR"]) / "yeni").mkdir(mode=0o700)  # an install that has written nothing yet
        rows = apps.access_rows(self.env)
        self.assertEqual([r["id"] for r in rows], ["uygulama:notlar:web:2222/tcp", "uygulama:notlar:web:5353/udp",
                                                  "uygulama:notlar:web:8080/tcp", "uygulama:sayac:app:9000/tcp"])
        self.assertEqual(rows[2], {"id": "uygulama:notlar:web:8080/tcp", "uygulama": "notlar", "anahtar": "web:8080/tcp",
                                   "servis": "web", "port": 8080, "protokol": "tcp", "yerel_port": 62100, "satir": ADDRESS})
        self.assertEqual((rows[1]["yerel_port"], rows[1]["protokol"], rows[1]["satir"]["kapsam"]), (None, "udp", "kapali"))
        # A clash between two applications' rows stops every reader (the projection keeps what it applied).
        records = apps.Records(self.env)
        own = records.load("sayac")["rows"]
        for clash in ({"tur": "adres", "ad": "notlar", "tailscale_portu": None, "internet": ""},
                      {"tur": "adres", "ad": "sayac", "tailscale_portu": 2222, "internet": ""}):
            with self.subTest(clash=clash):
                notlar = records.load("notlar")["rows"]
                records.write("notlar", rows=dict(notlar, **{"web:2222/tcp": {"tur": "ham", "kapsam": "tailscale", "port": 2222}}))
                records.write("sayac", rows=dict(own, **{"app:9000/tcp": clash}))
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    apps.access_rows(self.env)
                self.assertEqual(err.exception.status, 503)
                self.assertIn("iki satırda kullanılıyor", str(err.exception))
        records.write("sayac", rows=own)
        self.assertEqual(len(apps.access_rows(self.env)), 4)
        self.assertIsNone(apps.row_conflict([("a", "x:1/tcp", {"tur": "ham", "kapsam": "internet", "port": 80}),
                                             ("b", "y:1/udp", {"tur": "ham", "kapsam": "internet", "port": 80}),
                                             ("c", "z:1/tcp", {"tur": "ham", "kapsam": "tailscale", "port": 80})]),
                          "another protocol or another address is another listener")
        self.assertIn("İnternet adı n.example.org", apps.row_conflict(
            [("a", "x:1/tcp", dict(ADDRESS, ad="a", internet="n.example.org")),
             ("b", "y:1/tcp", dict(ADDRESS, ad="b", internet="n.example.org"))]))

    def test_open_raw_rows_are_published_on_the_addresses_state_env_names(self):
        rows = {"web:8080/tcp": ADDRESS, "web:2222/tcp": {"tur": "ham", "kapsam": "tailscale", "port": 12222},
                "web:5353/udp": {"tur": "ham", "kapsam": "internet", "port": 5353}, "web:9/tcp": {"tur": "ham", "kapsam": "kapali", "port": 9}}
        self.assertEqual(apps.raw_hosts(self.env, rows), {"web:2222/tcp": {"host_ip": "100.64.0.2", "host_port": 12222},
                                                          "web:5353/udp": {"host_ip": "203.0.113.10", "host_port": 5353}})
        for key, value in (("TAILSCALE_IPV4", ""), ("WAN_IPV4", "yok"), ("WAN_IPV4", "127.0.0.1"), ("TAILSCALE_IPV4", "0.0.0.0")):
            with self.subTest(key=key, value=value), self.assertRaises(cfg.ContainerConfigError) as err:
                apps.raw_hosts(dict(self.env, **{key: value}), rows)
            self.assertEqual(err.exception.status, 503)
        self.assertEqual(apps.raw_hosts(dict(self.env, WAN_IPV4=""), {"web:9/tcp": rows["web:9/tcp"]}), {}, "closed needs none")


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
        # 62100 is held by a listener, 62101 by notlar, 62102 is a base port.
        env = dict(self.env, SOME_PORT="62102")
        keys = apps.address_keys(apps.next_rows(definition))
        ports = apps.allocate(env, "sayac", keys, {}, bind=bind)
        self.assertEqual(ports, {"app:9000/tcp": 62103})
        self.assertEqual(apps.allocate(env, "sayac", keys, {"app:9000/tcp": 62109, "eski:1/tcp": 62108}, bind=bind),
                         {"app:9000/tcp": 62109}, "kept across edits; a key that went is dropped")
        with self.assertRaises(cfg.ContainerConfigError) as err:
            apps.allocate(env, "sayac", keys, {"app:9000/tcp": 62101}, bind=bind)
        self.assertEqual(err.exception.status, 409, "another application's port is never taken over")
        with self.assertRaises(cfg.ContainerConfigError) as err:
            apps.allocate(dict(env, UYGULAMA_PORT_SON="62101"), "sayac", keys, {}, bind=bind)
        self.assertIn("boş port kalmadı", str(err.exception))
        raw = json.loads(json.dumps(definition))
        raw["services"][0]["ports"][0]["use"] = "raw"
        self.assertEqual(apps.allocate(env, "sayac", apps.address_keys(apps.next_rows(raw)), {"app:9000/tcp": 62109},
                                       bind=bind), {}, "a raw row has no pool port (A2)")

    def test_the_guard_reads_each_bridge_and_its_loopback_publications(self):
        app_fixtures.record(self.env)
        self.assertEqual(apps.guard_input(self.env), [{"app": "notlar", "interface": apps.interface(self.env, "notlar"),
                                                       "publications": [{"service": "web", "port": 8080, "protocol": "tcp",
                                                                         "scope": "local", "host_ip": "127.0.0.1",
                                                                         "host_port": 62100}]}])


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


class SizeTests(Case):
    """Folder sizes for Depolama and the cleanup: a bounded walk (allocated blocks, no link followed, a hard link
    once) with a time limit and a cache."""

    class Clock:
        def __init__(self):
            self.now = 100.0

        def __call__(self):
            return self.now

    def tree(self):
        top = self.root / "veri" / "notlar"
        (top / "uploads" / "alt").mkdir(parents=True)
        (top / "db-data").mkdir()
        (top / "uploads" / "a").write_bytes(b"a" * 50000)
        (top / "uploads" / "alt" / "b").write_bytes(b"b" * 20000)
        (top / "db-data" / "c").write_bytes(b"c" * 8000)
        import os
        os.link(top / "uploads" / "a", top / "db-data" / "a-link")
        (top / "db-data" / "dis").symlink_to(self.root)  # never followed
        return top

    def test_a_tree_is_measured_by_its_blocks_with_each_entrys_share(self):
        top = self.tree()
        value, reason = apps.tree_size(top, deadline=float("inf"))
        self.assertEqual(reason, "")
        self.assertEqual(set(value["alt"]), {"uploads", "db-data"})
        shares = value["alt"]["uploads"] + value["alt"]["db-data"]
        self.assertGreaterEqual(shares, 78000)
        self.assertLess(shares, 120000, "a hard-linked file counts once (where it is met first), a link is not followed")
        self.assertEqual(value["boyut"], sum(value["alt"].values()) + top.lstat().st_blocks * 512)
        for path, why in ((self.root / "yok", "Klasör yok."), (top / "uploads" / "a", "Klasör değil.")):
            self.assertEqual(apps.tree_size(path, float("inf")), (None, why))

    def test_a_walk_that_runs_out_of_time_says_so_and_is_kept_briefly(self):
        top = self.tree()
        clock = self.Clock()
        ticks = iter(range(1000))
        late = lambda: clock.now + next(ticks)  # every reading is a second later
        self.assertEqual(apps.tree_size(top, deadline=late() + 1.5, clock=late)[0], None)
        sizes = apps.Sizes(clock=clock, wall=lambda: 1_800_000_000)
        with unittest.mock.patch.object(apps, "tree_size", side_effect=lambda p, d, c: (None, "Ölçüm süreye sığmadı; klasörde çok fazla öge var.")) as walk:
            first = sizes.measure([top], seconds=1)[str(top)]
            self.assertEqual((first["boyut"], first["olculdu"]), (None, 1_800_000_000))
            sizes.measure([top], seconds=1)
            self.assertEqual(walk.call_count, 1, "a failed walk is kept SIZE_FAIL_TTL")
            clock.now += apps.SIZE_FAIL_TTL
            sizes.measure([top], seconds=1)
            self.assertEqual(walk.call_count, 2)
        # Once the time is spent the other folders are not walked at all.
        def slow(path, deadline, c):
            clock.now += 10
            return {"boyut": 1, "alt": {}}, ""
        with unittest.mock.patch.object(apps, "tree_size", side_effect=slow) as walk:
            out = apps.Sizes(clock=clock).measure([top / "uploads", top / "db-data"], seconds=5)
        self.assertEqual(walk.call_count, 1)
        self.assertEqual(out[str(top / "db-data")]["neden"], "Ölçüm süreye sığmadı; sonra yeniden denenecek.")

    def test_a_measurement_is_cached_and_fresh_measures_again(self):
        top = self.tree()
        clock = self.Clock()
        sizes = apps.Sizes(clock=clock)
        first = sizes.measure([top])[str(top)]
        (top / "uploads" / "yeni").write_bytes(b"y" * 40000)
        self.assertEqual(sizes.measure([top])[str(top)], first, "kept SIZE_TTL")
        self.assertGreater(sizes.measure([top], fresh=True)[str(top)]["boyut"], first["boyut"])
        clock.now += apps.SIZE_TTL
        self.assertEqual(sizes.measure([self.root / "yok"])[str(self.root / "yok")]["neden"], "Klasör yok.")
        self.assertNotIn(str(self.root / "yok"), sizes.cache, "a missing folder is not kept")
        self.assertNotIn(str(top), sizes.cache, "an old measurement is dropped")


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
