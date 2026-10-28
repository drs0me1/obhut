"""DD-271 (phase 2): the inspector (master_inspector). Questions and guesses for the acceptance fixtures, the
inspector's own refusals, that bad input never raises, and check(): every answer is checked, the
definition is built with Compose's interpolation and carries no secret value."""
import copy
import json
from pathlib import Path
import random
import re
import sys
import textwrap
import unittest

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_compose  # noqa: E402
import master_inspector  # noqa: E402

FIXTURES = DATA / "tests" / "fixtures" / "uygulama"
inspect, check = master_inspector.inspect, master_inspector.check


def fixture(name):
    return inspect((FIXTURES / name).read_text())


def questions(inspection):
    return {q["id"]: q for q in inspection["questions"]}


def compose(text):
    return inspect(textwrap.dedent(text))


def refusal_keys(inspection):
    return [(r["line"], r["key"]) for r in inspection["refusals"]]


ORNEK = {"name": "ornek", "answers": {
    "port:ornek:8080/tcp": {"use": "caddy", "tailscale_name": "ornek"},
    "port:ornek:8092/tcp": {"use": "raw"},
    "mount:ornek:/database": {"to": "app"}, "mount:ornek:/config": {"to": "app"},
    "mount:ornek:/srv": {"to": "srv", "path": "/srv/ornek", "read_only": False},
    "start:ornek": {"mode": "direct"}}}
NOTLAR = {"name": "notlar", "answers": {
    "var:NOTLAR_VERSION": {"value": "1.5"}, "var:BASE_URL": {"value": ""}, "var:DB_PASSWORD": {"value": "s3cret-Value"},
    "var:LOG_LEVEL": {"value": ""},
    "port:web:3000/tcp": {"use": "caddy", "tailscale_name": "notlar"},
    "mount:web:/app/uploads": {"to": "app"},
    "mount:web:/media/notlar": {"to": "srv", "path": "/srv/media/notlar", "read_only": True},
    "start:web": {"mode": "direct"}, "mount:db:/var/lib/postgresql/data": {"to": "app"}, "start:db": {"mode": "root"}}}


class DefaultsTests(unittest.TestCase):
    def test_the_fixed_values_match_config_defaults(self):
        env = dict(re.findall(r'^([A-Z_]+)="?([^"\n]*)"?$', (DATA / "config/defaults.env").read_text(), re.M))
        self.assertEqual(master_inspector.SRV, env["SERVER_ROOT"])
        self.assertEqual(master_inspector.DIRECT_USER, "%s:%s" % (env["DOWNLOADS_UID"], env["DOWNLOADS_GID"]))


class FixtureTests(unittest.TestCase):
    def test_named_volumes_and_a_placeholder_path(self):
        i = fixture("ornek-compose.yaml")
        self.assertEqual((i["format"], i["name"], i["refusals"]), ("compose", "ornek", []))
        q = questions(i)
        self.assertEqual(list(q), ["name", "port:ornek:8080/tcp", "port:ornek:8092/tcp", "mount:ornek:/database",
                                   "mount:ornek:/config", "mount:ornek:/srv", "start:ornek"])
        self.assertEqual(q["name"]["suggest"], "ornek")
        self.assertEqual((q["port:ornek:8080/tcp"]["guess"], q["port:ornek:8080/tcp"]["suggest"]), ("web", "ornek"))
        self.assertEqual(q["port:ornek:8092/tcp"]["suggest"], "ornek-8092")
        self.assertEqual((q["mount:ornek:/srv"]["suggest"], q["mount:ornek:/srv"]["srv_path"]), ("srv", None))
        self.assertEqual((q["mount:ornek:/database"]["suggest"], q["mount:ornek:/database"]["folder"]), ("app", "ornek-db"))
        start = q["start:ornek"]
        self.assertEqual((start["suggest"], start["direct_user"]), ("root", "1000:1000"))
        self.assertEqual(start["open_caps"], ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "SETGID", "SETPCAP", "SETUID"])
        for question in i["questions"]:
            self.assertTrue(question["title"] and question["why"] and question["line"] >= 1, question)

    def test_qbittorrent(self):
        q = questions(fixture("qbittorrent-compose.yaml"))
        self.assertEqual((q["port:qbittorrent:8080/tcp"]["guess"], q["port:qbittorrent:8080/tcp"]["choices"]), ("web", ["caddy", "raw"]))
        # 6881 is a known peer port and is also published as UDP: raw, and UDP may only be raw (A2).
        self.assertEqual((q["port:qbittorrent:6881/tcp"]["guess"], q["port:qbittorrent:6881/tcp"]["suggest"]), ("raw", None))
        self.assertEqual((q["port:qbittorrent:6881/udp"]["guess"], q["port:qbittorrent:6881/udp"]["choices"]), ("raw", ["raw"]))
        self.assertEqual((q["mount:qbittorrent:/config"]["suggest"], q["mount:qbittorrent:/config"]["folder"]), ("app", "appdata"))
        self.assertEqual((q["mount:qbittorrent:/downloads"]["suggest"], q["mount:qbittorrent:/downloads"]["srv_path"]),
                         ("srv", "/srv/downloads"))
        self.assertEqual(q["start:qbittorrent"]["suggest"], "root", "linuxserver images start as root and switch (s6)")
        self.assertNotIn("secret:qbittorrent:PUID", q)

    def test_the_web_application_and_its_database(self):
        i = fixture("notlar-compose.yaml")
        self.assertEqual(i["refusals"], [])
        q = questions(i)
        password = q["var:DB_PASSWORD"]
        self.assertEqual((password["secret"], password["generate"], password["required"], password["services"]),
                         (True, True, True, ["web", "db"]))
        self.assertEqual((q["var:LOG_LEVEL"]["secret"], q["var:LOG_LEVEL"]["default"]), (False, "info"))
        self.assertEqual(q["var:NOTLAR_VERSION"]["services"], ["web"])
        self.assertEqual(q["start:web"]["suggest"], "direct", "the file sets user and adds nothing")
        self.assertEqual(q["start:db"]["suggest"], "root")
        self.assertEqual(q["mount:web:/media/notlar"]["srv_path"], "/srv/media/notlar")
        self.assertEqual(q["mount:db:/var/lib/postgresql/data"]["folder"], "db-data")
        self.assertNotIn("mount:db:/run/postgresql", q, "tmpfs needs no question")
        self.assertFalse([x for x in q if x.startswith("secret:")])

    def test_kubernetes_pod_and_deployment(self):
        i = fixture("notlar-pod.yaml")
        self.assertEqual((i["format"], i["pod"], i["refusals"]), ("kubernetes", True, []))
        q = questions(i)
        self.assertEqual(q["start:notlar-redis"]["suggest"], "direct")
        self.assertEqual(q["start:notlar-redis"]["direct_user"], "999:999")
        self.assertEqual(q["mount:notlar-web:/usr/share/nginx/html"]["srv_path"], "/srv/notlar/html")
        d = fixture("sayac-deployment.yaml")
        q = questions(d)
        token = q["secret:sayac/token"]
        self.assertEqual((token["generate"], token["env"], token["services"], token["uses"]),
                         (False, "COUNTER_TOKEN", ["sayac"], [{"service": "sayac", "env": "COUNTER_TOKEN"}]))
        self.assertEqual(q["port:sayac:9001/udp"]["choices"], ["raw"])
        self.assertEqual(q["mount:sayac:/data"]["folder"], "sayac-data")

    def test_the_unsafe_file_has_refusals_and_marks(self):
        i = fixture("unsafe-compose.yaml")
        self.assertEqual(len(i["refusals"]), 8)
        lines = [m["line"] for m in i["marks"]]
        self.assertEqual(lines, sorted(lines))
        self.assertEqual({m["kind"] for m in i["marks"]}, {"refuse", "question", "note"})
        self.assertEqual([m for m in i["marks"] if m["line"] == 5], [{"line": 5, "kind": "refuse",
                                                                    "text": master_compose.SERVICE_REFUSED["privileged"]}])
        definition, secrets, errors = check(i, {"name": "yonetim", "answers": {}})
        self.assertEqual((definition, secrets, list(errors)), (None, {}, ["dosya"]))


class InspectorRefusalTests(unittest.TestCase):
    def test_a_secret_variable_only_in_an_environment_value(self):
        i = compose("""\
            services:
              app:
                image: x:${API_TOKEN}
                command: [run, "--password=${DB_PASSWORD}"]
                labels: {k: "${SECRET_KEY}"}
                environment: ["OK=${DB_PASSWORD}"]
            """)
        self.assertEqual(refusal_keys(i), [(3, "image"), (4, "command"), (5, "labels")])
        self.assertIn("${DB_PASSWORD}", i["refusals"][1]["text"])

    def test_service_counts_images_ports_and_names(self):
        many = "services:\n" + "".join("  s%d:\n    image: x\n" % n for n in range(17))
        self.assertIn("En çok 16 servis", inspect(many)["refusals"][0]["text"])
        ports = "services:\n  a:\n    image: x\n    ports:\n" + "".join("      - %d\n" % (1000 + n) for n in range(65))
        self.assertIn("En çok 64 port", inspect(ports)["refusals"][0]["text"])
        self.assertEqual(refusal_keys(compose("services:\n  a:\n    user: '1'\n")), [(2, "image")])
        self.assertEqual(refusal_keys(compose("services:\n  '1':\n    image: x\n")), [(2, "name")])
        self.assertEqual(refusal_keys(compose("services:\n  a:\n    image: x\n    ports: ['80', '8080:80', 80/udp]\n")),
                         [(4, "ports")])
        many = "services:\n  a:\n    image: x\n    environment:\n" + "".join("      - A%d=${V%d}\n" % (n, n) for n in range(300))
        i = inspect(many)
        self.assertIn("en çok 256", i["refusals"][0]["text"])
        self.assertEqual(len(i["questions"]), 256)
        # A refused file lists a bounded inspection: the first services, the first ports, 500 findings.
        huge = "services:\n" + "".join("  s%d: {image: x, ports: ['%d:80']}\n" % (n, 1000 + n) for n in range(5000))
        i = inspect(huge)
        self.assertEqual((len(i["services"]), len(i["notes"])), (16, 501))
        self.assertLess(len(json.dumps(i)), len(huge))
        noisy = "services:\n  a:\n    image: x\n    ports:\n" + "".join("      - '%d:%d'\n" % (n, n) for n in range(1, 2000))
        i = inspect(noisy)
        self.assertEqual((len(i["notes"]), i["notes"][-1]["key"]), (501, "dosya"))
        self.assertEqual(sum(len(s["ports"]) for s in i["services"]), 64)
        pod = textwrap.dedent("""\
            apiVersion: v1
            kind: Pod
            metadata: {name: p}
            spec:
              containers:
              - {name: a, image: x, ports: [{containerPort: 80}]}
              - {name: b, image: y, ports: [{containerPort: 80, hostPort: 8080}, {containerPort: 80, protocol: UDP}]}
            """)
        i = inspect(pod)
        self.assertEqual(refusal_keys(i), [(7, "ports")])
        self.assertIn("Pod", i["refusals"][0]["text"])

    def test_bad_input_never_raises(self):
        cases = [None, 5, b"services: {}", "", "\n\n# yalnız yorum\n", "---\n---\n", "services: [", "a: b\na: c\n",
                 "anchor: &a 1\n", "x: 1\n", "- 1\n", "\x00", "services:\n\t- a\n", "a" * (master_inspector.LIMIT_BYTES + 1),
                 "apiVersion: v1\n", "services: 5\n", "kind: Pod\nmetadata: 7\nspec: [1]\n"]
        for text in cases:
            with self.subTest(text=repr(text)[:40]):
                i = inspect(text)
                self.assertTrue(i["refusals"], text)
                self.assertNotEqual(i["refusals"][0]["key"], "ic-hata")
                json.dumps(i)
        i = inspect("apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec: {containers: [{name: a, image: x}]}\n---\nfoo: bar\n")
        self.assertEqual((i["format"], [(r["line"], r["key"]) for r in i["refusals"]]), ("kubernetes", [(6, "kind")]))
        i = inspect("services:\n  a:\n    image: x\n  a:\n    image: y\n")
        self.assertEqual((i["refusals"][0]["line"], i["format"]), (4, None))
        self.assertIn("satır 4", i["refusals"][0]["text"])

    def test_mutated_fixtures_never_reach_an_internal_error(self):
        """Every reader path stays inside its refusals: a small fuzz over the acceptance fixtures."""
        rng = random.Random(271)
        texts = [p.read_text() for p in sorted(FIXTURES.glob("*.yaml"))]
        pieces = ["", " ", "-", ":", "'", '"', "[", "]", "{", "}", "${", "$", "true", "null", "0", "/etc", "\n", "  ", "#",
                  "x-", "~", "../", "|", ">"]
        for n in range(1500):
            lines = rng.choice(texts).split("\n")
            for _ in range(rng.randint(1, 4)):
                at = rng.randrange(len(lines))
                line = lines[at]
                cut = rng.randint(0, len(line))
                choice = rng.random()
                if choice < 0.4:
                    lines[at] = line[:cut] + rng.choice(pieces) + line[cut:]
                elif choice < 0.6:
                    lines[at] = line[:cut]
                elif choice < 0.8:
                    lines.insert(at, rng.choice(lines))
                else:
                    del lines[at]
                    if not lines:
                        lines = [""]
            text = "\n".join(lines)
            i = inspect(text)
            self.assertNotIn("ic-hata", [r["key"] for r in i["refusals"]], text)
            json.dumps(i)
            if not i["refusals"]:
                check(i, {"name": "x", "answers": {}})


class CheckTests(unittest.TestCase):
    def test_named_volumes_definition(self):
        definition, secrets, errors = check(fixture("ornek-compose.yaml"), ORNEK)
        self.assertEqual((errors, secrets), ({}, {}))
        (svc,) = definition["services"]
        self.assertEqual((definition["name"], definition["format"], definition["pod"], definition["secrets"]),
                         ("ornek", "compose", False, []))
        self.assertEqual((svc["start"], svc["user"], svc["caps_drop"], svc["no_new_privileges"]), ("direct", "1000:1000", "all", True))
        self.assertEqual(svc["ports"], [{"port": 8080, "protocol": "tcp", "use": "caddy", "tailscale_name": "ornek"},
                                        {"port": 8092, "protocol": "tcp", "use": "raw", "tailscale_name": None}])
        self.assertEqual(svc["mounts"], [{"target": "/database", "to": "app", "folder": "ornek-db", "read_only": False},
                                         {"target": "/config", "to": "app", "folder": "ornek-config", "read_only": False},
                                         {"target": "/srv", "to": "srv", "path": "/srv/ornek", "read_only": False}])

    def test_interpolation_secrets_and_start_modes(self):
        definition, secrets, errors = check(fixture("notlar-compose.yaml"), NOTLAR)
        self.assertEqual(errors, {})
        web, db = definition["services"]
        self.assertEqual(web["image"], "ghcr.io/example/notlar:1.5")
        self.assertEqual(web["command"], ["serve", "--listen", "0.0.0.0:3000", "--base", "http://notlar.example"],
                         "${VAR:-default} with an empty answer takes the default")
        env = {e["name"]: e for e in web["environment"]}
        self.assertEqual(env["LOG_LEVEL"], {"name": "LOG_LEVEL", "value": ""}, "${VAR-default} keeps an empty answer")
        self.assertEqual(env["PRICE_NOTE"], {"name": "PRICE_NOTE", "value": "$5 per month"})
        self.assertEqual(env["DB_PASSWORD"], {"name": "DB_PASSWORD", "secret": "notlar-db-password"})
        self.assertEqual(env["DATABASE_URL"], {"name": "DATABASE_URL", "secret": "notlar-database-url"})
        self.assertEqual({e["name"]: e for e in db["environment"]}["POSTGRES_PASSWORD"],
                         {"name": "POSTGRES_PASSWORD", "secret": "notlar-db-password"})
        self.assertEqual(secrets, {"notlar-db-password": "s3cret-Value",
                                   "notlar-database-url": "postgres://notlar:s3cret-Value@db:5432/notlar"})
        self.assertEqual(definition["secrets"], [{"name": "notlar-database-url", "services": ["web"], "keep": False},
                                                 {"name": "notlar-db-password", "services": ["web", "db"], "keep": False}])
        self.assertNotIn("s3cret-Value", json.dumps(definition))
        self.assertEqual((web["start"], web["user"], web["caps_drop"], web["no_new_privileges"]), ("direct", "1000:1000", "all", True))
        self.assertEqual((db["start"], db["user"], db["caps_drop"], db["no_new_privileges"]),
                         ("root", None, ["NET_BIND_SERVICE", "SETFCAP", "SYS_CHROOT"], False))
        self.assertEqual(web["depends_on"], [{"service": "db", "condition": "healthy"}])
        self.assertEqual(db["mounts"], [{"target": "/var/lib/postgresql/data", "to": "app", "folder": "db-data", "read_only": False},
                                        {"target": "/run/postgresql", "to": "tmpfs"}])
        self.assertEqual(web["mounts"][1], {"target": "/media/notlar", "to": "srv", "path": "/srv/media/notlar", "read_only": True})

    def test_kubernetes_definition(self):
        i = fixture("sayac-deployment.yaml")
        answers = {"name": "sayac", "answers": {
            "port:sayac:9000/tcp": {"use": "caddy", "tailscale_name": "sayac"}, "port:sayac:9001/udp": {"use": "raw"},
            "mount:sayac:/data": {"to": "app"}, "secret:sayac/token": {"value": "tok-1"}, "start:sayac": {"mode": "root"}}}
        definition, secrets, errors = check(i, answers)
        self.assertEqual(errors, {})
        (svc,) = definition["services"]
        self.assertEqual(svc["environment"], [{"name": "COUNTER_TOKEN", "secret": "sayac-counter-token"},
                                              {"name": "COUNTER_MODE", "value": "public"}])
        self.assertEqual(secrets, {"sayac-counter-token": "tok-1"})
        self.assertEqual(svc["mounts"], [{"target": "/data", "to": "app", "folder": "sayac-data", "read_only": False},
                                         {"target": "/tmp", "to": "tmpfs"}])
        self.assertEqual((definition["pod"], svc["restart"]), (True, "always"))
        # Kubernetes has no Compose interpolation; $$ is Kubernetes' own escape for one $.
        i = inspect("apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec:\n  containers:\n  - name: a\n    image: x\n"
                    "    args: ['$$HOME', '${A}']\n    securityContext: {runAsUser: 0}\n")
        definition, _s, errors = check(i, {"name": "p", "answers": {"start:a": {"mode": "direct"}}})
        self.assertEqual((errors, definition["services"][0]["command"], definition["services"][0]["user"]),
                         ({}, ["$HOME", "${A}"], "0"))

    def test_compose_secret_questions_and_name_collisions(self):
        i = compose("""\
            services:
              a:
                image: x
                environment:
                  MYSQL_PASSWORD: example
                  OPTIONAL: ""
                  TZ: Europe/Berlin
              b:
                image: y
                environment:
                  MYSQL_PASSWORD: other
                  PASS_URL: "u:${PASS}@h"
            """)
        q = questions(i)
        self.assertEqual([x for x in q if x.startswith(("secret:", "var:"))],
                         ["var:PASS", "secret:a:MYSQL_PASSWORD", "secret:a:OPTIONAL", "secret:b:MYSQL_PASSWORD"])
        self.assertEqual((q["secret:a:MYSQL_PASSWORD"]["generate"], q["secret:a:OPTIONAL"]["generate"]), (True, False))
        answers = {"name": "uyg", "answers": {
            "var:PASS": {"value": "p1"}, "secret:a:MYSQL_PASSWORD": {"value": "m1"}, "secret:a:OPTIONAL": {"value": "o"},
            "secret:b:MYSQL_PASSWORD": {"value": "m2"}, "start:a": {"mode": "root"}, "start:b": {"mode": "root"}}}
        definition, secrets, errors = check(i, answers)
        self.assertEqual(errors, {})
        self.assertEqual(secrets, {"uyg-mysql-password": "m1", "uyg-optional": "o", "uyg-b-mysql-password": "m2",
                                   "uyg-pass-url": "u:p1@h"})
        self.assertEqual({e["name"]: e for e in definition["services"][0]["environment"]}["TZ"], {"name": "TZ", "value": "Europe/Berlin"})
        self.assertNotIn("example", json.dumps(definition), "the file's own value of a secret is not used")

    def test_every_question_needs_a_valid_answer(self):
        i = fixture("notlar-compose.yaml")

        def errors_for(change):
            answers = copy.deepcopy(NOTLAR)
            change(answers)
            definition, secrets, errors = check(i, answers)
            self.assertIsNone(definition)
            self.assertEqual(secrets, {})
            return errors

        def answer(qid, value):
            return lambda a: a["answers"].__setitem__(qid, value)
        cases = [
            (lambda a: a["answers"].pop("start:db"), "start:db"),
            (answer("extra", {"value": "x"}), "extra"),
            (answer("name", {"value": "x"}), "name"),
            (lambda a: a.__setitem__("name", "Notlar"), "name"),
            (lambda a: a.__setitem__("name", "1notlar"), "name"),
            (lambda a: a.__setitem__("name", "konsol-x"), "name"),
            (lambda a: a.__setitem__("name", "master"), "name"),
            (lambda a: a.__setitem__("name", "a" * 31), "name"),
            (lambda a: a.pop("name"), "name"),
            (answer("port:web:3000/tcp", {"use": "caddy", "tailscale_name": "Panel"}), "port:web:3000/tcp"),
            (answer("port:web:3000/tcp", {"use": "caddy", "tailscale_name": "panel"}), "port:web:3000/tcp"),
            (answer("port:web:3000/tcp", {"use": "caddy", "tailscale_name": "paylas"}), "port:web:3000/tcp"),
            (answer("port:web:3000/tcp", {"use": "caddy", "tailscale_name": "-x"}), "port:web:3000/tcp"),
            (answer("port:web:3000/tcp", {"use": "caddy"}), "port:web:3000/tcp"),
            (answer("port:web:3000/tcp", {"use": "raw", "scope": "internet"}), "port:web:3000/tcp"),
            (answer("port:web:3000/tcp", "raw"), "port:web:3000/tcp"),
            (answer("var:DB_PASSWORD", {"value": ""}), "var:DB_PASSWORD"),
            (answer("var:DB_PASSWORD", {"value": "x" * 4097}), "var:DB_PASSWORD"),
            (answer("var:DB_PASSWORD", {"value": "a\x00b"}), "var:DB_PASSWORD"),
            (answer("var:DB_PASSWORD", {"value": "\ud800"}), "var:DB_PASSWORD"),
            (answer("var:DB_PASSWORD", {"value": 5}), "var:DB_PASSWORD"),
            (answer("var:LOG_LEVEL", {}), "var:LOG_LEVEL"),
            (answer("mount:web:/app/uploads", {"to": "srv", "path": "/srv/x"}), "mount:web:/app/uploads"),
            (answer("mount:web:/app/uploads", {"to": "elsewhere"}), "mount:web:/app/uploads"),
            (answer("mount:web:/app/uploads", {"to": "app", "read_only": True}), "mount:web:/app/uploads"),
            (answer("mount:web:/app/uploads", {"to": "srv", "path": "/srv/x", "read_only": "no"}), "mount:web:/app/uploads"),
            (answer("start:web", {"mode": "privileged"}), "start:web"),
        ]
        for path in ("srv/x", "/srvx", "/etc", "/srv/../etc", "/srv/./x", "/srv//x", "/srv/x/", "/srv/.cop", "/srv/a/.git/b",
                     "/srv/a\nb", "/", ""):
            cases.append((answer("mount:web:/app/uploads", {"to": "srv", "path": path, "read_only": False}), "mount:web:/app/uploads"))
        for change, qid in cases:
            with self.subTest(qid=qid):
                errors = errors_for(change)
                self.assertIn(qid, errors)
                self.assertTrue(errors[qid])
        # Two addresses of one application may not share a Tailscale name.
        i = fixture("ornek-compose.yaml")
        answers = copy.deepcopy(ORNEK)
        answers["answers"]["port:ornek:8092/tcp"] = {"use": "caddy", "tailscale_name": "ornek"}
        self.assertIn("port:ornek:8092/tcp", check(i, answers)[2])
        answers["answers"]["port:ornek:8092/tcp"] = {"use": "caddy", "tailscale_name": "ornek-dav"}
        self.assertEqual(check(i, answers)[2], {})
        # UDP may only be raw (A2).
        i = fixture("qbittorrent-compose.yaml")
        q = questions(i)
        bad = {"name": "qbittorrent", "answers": {qid: {"use": "raw"} for qid in q if qid.startswith("port:")}}
        bad["answers"].update({"mount:qbittorrent:/config": {"to": "app"}, "start:qbittorrent": {"mode": "root"},
                               "mount:qbittorrent:/downloads": {"to": "srv", "path": "/srv/downloads", "read_only": False}})
        self.assertEqual(check(i, bad)[2], {})
        bad["answers"]["port:qbittorrent:6881/udp"] = {"use": "caddy", "tailscale_name": "peer"}
        self.assertIn("port:qbittorrent:6881/udp", check(i, bad)[2])
        # Secret values never come back in an error text.
        answers = copy.deepcopy(NOTLAR)
        answers["answers"]["var:DB_PASSWORD"] = {"value": "x" * 4097}
        self.assertNotIn("xxxx", json.dumps(check(fixture("notlar-compose.yaml"), answers)[2]))

    def test_the_hardened_fixture_carries_its_limits_into_the_definition(self):
        i = fixture("kasa-compose.yaml")
        self.assertEqual(i["refusals"], [])
        q = questions(i)
        self.assertEqual((q["start:kasa"]["suggest"], q["start:kasa"]["open_caps"]), ("direct", []))
        self.assertEqual(q["start:yedek"]["open_caps"], ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "SETGID", "SETPCAP", "SETUID"],
                         "the file's own drops stay dropped in the root start")
        answers = {"name": "kasa", "answers": {"port:kasa:80/tcp": {"use": "caddy", "tailscale_name": "kasa"},
                                               "mount:kasa:/data": {"to": "app"}, "start:kasa": {"mode": "root"},
                                               "mount:yedek:/data": {"to": "app"}, "start:yedek": {"mode": "root"}}}
        definition, _s, errors = check(i, answers)
        self.assertEqual(errors, {})
        kasa, yedek = definition["services"]
        self.assertEqual((kasa["caps_drop"], kasa["no_new_privileges"], kasa["read_only"], kasa["init"], kasa["hostname"],
                          kasa["shm_size"], kasa["restart"]), ("all", True, True, True, "kasa", 64 * 2 ** 20, "on-failure"))
        self.assertEqual(kasa["limits"]["ulimits"]["nofile"], {"soft": 20000, "hard": 40000})
        self.assertEqual((yedek["caps_drop"], yedek["no_new_privileges"], yedek["limits"]["memory"]),
                         (["KILL", "NET_BIND_SERVICE", "SETFCAP", "SYS_CHROOT"], True, 128 * 2 ** 20))
        self.assertEqual(yedek["mounts"], [{"target": "/data", "to": "app", "folder": "kasa-data", "read_only": True}])
        answers["answers"]["start:yedek"] = {"mode": "direct"}
        yedek = check(i, answers)[0]["services"][1]
        self.assertEqual((yedek["caps_drop"], yedek["no_new_privileges"], yedek["user"]), ("all", True, "1000:1000"))

    def test_one_question_per_kubernetes_secret(self):
        i = inspect(textwrap.dedent("""\
            apiVersion: v1
            kind: Pod
            metadata: {name: ortak}
            spec:
              containers:
              - name: web
                image: x
                env:
                - {name: DB_PASSWORD, valueFrom: {secretKeyRef: {name: db, key: password}}}
                - {name: API_TOKEN, valueFrom: {secretKeyRef: {name: api, key: token}}}
              - name: worker
                image: y
                env:
                - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: db, key: password}}}
                - {name: API_TOKEN, valueFrom: {secretKeyRef: {name: other, key: token}}}
            """))
        q = [x for x in i["questions"] if x["kind"] == "secret"]
        self.assertEqual([x["id"] for x in q], ["secret:db/password", "secret:api/token", "secret:other/token"])
        self.assertEqual((q[0]["services"], q[0]["uses"], q[0]["generate"], q[0]["line"]),
                         (["web", "worker"], [{"service": "web", "env": "DB_PASSWORD"}, {"service": "worker", "env": "PGPASSWORD"}],
                          True, 9))
        answers = {"name": "ortak", "answers": {"secret:db/password": {"value": "pw"}, "secret:api/token": {"value": "t1"},
                                                "secret:other/token": {"value": "t2"}, "start:web": {"mode": "root"},
                                                "start:worker": {"mode": "root"}}}
        definition, secrets, errors = check(i, answers)
        self.assertEqual(errors, {})
        self.assertEqual(secrets, {"ortak-db-password": "pw", "ortak-api-token": "t1", "ortak-other-token": "t2"})
        self.assertEqual(definition["secrets"], [{"name": "ortak-db-password", "services": ["web", "worker"], "keep": False},
                                                 {"name": "ortak-api-token", "services": ["web"], "keep": False},
                                                 {"name": "ortak-other-token", "services": ["worker"], "keep": False}])
        self.assertEqual(definition["services"][1]["environment"], [{"name": "PGPASSWORD", "secret": "ortak-db-password"},
                                                                    {"name": "API_TOKEN", "secret": "ortak-other-token"}])
        self.assertNotIn("pw", json.dumps(definition["services"]))

    def test_kubernetes_references_are_filled_in_from_the_container(self):
        i = inspect(textwrap.dedent("""\
            apiVersion: v1
            kind: Pod
            metadata: {name: p}
            spec:
              containers:
              - name: a
                image: x
                command: [serve, "$(MODE)"]
                args: ["--port=$(PORT)", "$$(PORT)", "$(UNKNOWN)", "cost: $$5"]
                env:
                - {name: PORT, value: "8080"}
                - {name: MODE, value: fast}
            """))
        self.assertEqual(i["refusals"], [])
        definition, _s, errors = check(i, {"name": "p", "answers": {"start:a": {"mode": "root"}}})
        self.assertEqual(errors, {})
        svc = definition["services"][0]
        self.assertEqual((svc["entrypoint"], svc["command"]),
                         (["serve", "fast"], ["--port=8080", "$(PORT)", "$(UNKNOWN)", "cost: $5"]))

    def test_kubernetes_env_values_are_filled_in_from_earlier_entries(self):
        i = inspect(textwrap.dedent("""\
            apiVersion: v1
            kind: Pod
            metadata: {name: p}
            spec:
              containers:
              - name: a
                image: x
                args: ["--url=$(URL)", "$(LATE)"]
                env:
                - {name: HOST, value: db}
                - {name: PORT, value: "$(LATE)"}
                - {name: URL, value: "http://$(HOST):$(PORT)/$$(HOST)/$(URL)"}
                - {name: LATE, value: "5432"}
                - {name: TOKEN, valueFrom: {secretKeyRef: {name: s, key: t}}}
            """))
        self.assertEqual(i["refusals"], [])
        definition, secrets, errors = check(i, {"name": "p", "answers": {"start:a": {"mode": "root"},
                                                                          "secret:s/t": {"value": "tok"}}})
        self.assertEqual(errors, {})
        svc = definition["services"][0]
        self.assertEqual(svc["environment"], [{"name": "HOST", "value": "db"}, {"name": "PORT", "value": "$(LATE)"},
                                              {"name": "URL", "value": "http://db:$(LATE)/$(HOST)/$(URL)"},
                                              {"name": "LATE", "value": "5432"}, {"name": "TOKEN", "secret": "p-token"}])
        # command and args see the values as Kubernetes filled them in (one pass, no second expansion).
        self.assertEqual(svc["command"], ["--url=http://db:$(LATE)/$(HOST)/$(URL)", "5432"])
        self.assertEqual(secrets, {"p-token": "tok"})

    def test_malformed_inspections_and_answers_never_raise(self):
        i = fixture("ornek-compose.yaml")
        for answers in (None, [], "x", {"name": "ornek", "answers": []}, {"name": "ornek", "answers": {}, "other": 1},
                        {"name": 5, "answers": {}}):
            with self.subTest(answers=answers):
                definition, secrets, errors = check(i, answers)
                self.assertIsNone(definition)
                self.assertTrue(errors)
        for inspection in (None, {}, {"format": "compose"}, {"format": "x", "questions": []}):
            with self.subTest(inspection=inspection):
                self.assertTrue(check(inspection, ORNEK)[2])

    def test_variables_shape_the_definition(self):
        i = compose("""\
            services:
              app:
                image: ${IMAGE:?}
                user: ${PUID}:${PGID}
                working_dir: ${WD:-/app}
                entrypoint: ["/bin/run", "${MODE-safe}"]
                labels: {version: "${TAG:-1}"}
                healthcheck:
                  test: [CMD, check, "${URL}"]
            """)
        q = questions(i)
        self.assertTrue(q["var:IMAGE"]["required"])
        self.assertEqual(q["start:app"]["suggest"], "direct")
        base = {"name": "uyg", "answers": {"var:IMAGE": {"value": "docker.io/x/y:1"}, "var:PUID": {"value": "1001"},
                                           "var:PGID": {"value": "1002"}, "var:WD": {"value": ""}, "var:MODE": {"value": "fast"},
                                           "var:TAG": {"value": "2"}, "var:URL": {"value": "http://localhost/"},
                                           "start:app": {"mode": "direct"}}}
        definition, _s, errors = check(i, base)
        self.assertEqual(errors, {})
        svc = definition["services"][0]
        self.assertEqual((svc["image"], svc["user"], svc["workdir"], svc["entrypoint"], svc["labels"], svc["health"]["test"]),
                         ("docker.io/x/y:1", "1001:1002", "/app", ["/bin/run", "fast"], {"version": "2"},
                          ["CMD", "check", "http://localhost/"]))
        answers = copy.deepcopy(base)
        answers["answers"]["var:IMAGE"] = {"value": ""}
        self.assertIn("var:IMAGE", check(i, answers)[2])
        answers = copy.deepcopy(base)
        answers["answers"]["var:IMAGE"] = {"value": "a b"}
        self.assertIn("var:IMAGE", check(i, answers)[2])
        answers = copy.deepcopy(base)
        answers["answers"]["var:PUID"] = {"value": ""}
        answers["answers"]["var:PGID"] = {"value": ""}
        self.assertEqual(check(i, answers)[2], {"var:PUID": "app: değişkenlerle kullanıcı boş kalıyor."}, "':' alone is no user")
        answers = copy.deepcopy(base)
        answers["answers"]["var:WD"] = {"value": "relative"}
        self.assertIn("var:WD", check(i, answers)[2])

    def test_start_modes_and_capabilities(self):
        i = compose("""\
            services:
              web:
                image: x
                user: "33"
                cap_add: [CHOWN]
                ports: ["80"]
              worker:
                image: y
                cap_add: [NET_BIND_SERVICE, SYS_CHROOT]
            """)
        q = questions(i)
        self.assertEqual(q["start:web"]["suggest"], "root", "added capabilities need the root start")
        self.assertEqual(q["start:web"]["open_caps"], ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "NET_BIND_SERVICE",
                                                      "SETGID", "SETPCAP", "SETUID"], "a port below 1024 keeps NET_BIND_SERVICE")
        self.assertIn("SYS_CHROOT", q["start:worker"]["open_caps"])
        answers = {"name": "uyg", "answers": {"port:web:80/tcp": {"use": "raw"}, "start:web": {"mode": "direct"},
                                              "start:worker": {"mode": "root"}}}
        definition, _s, errors = check(i, answers)
        self.assertEqual(errors, {})
        web, worker = definition["services"]
        self.assertEqual((web["user"], web["caps_drop"], web["caps_add"], web["no_new_privileges"]), ("33", "all", ["CHOWN"], True))
        self.assertEqual((worker["caps_drop"], worker["caps_add"]), (["SETFCAP"], ["NET_BIND_SERVICE", "SYS_CHROOT"]))


class EditAndWarningTests(unittest.TestCase):
    """Phase 3: {"keep": true} for a secret the application already has, the root start's /srv warning and
    the line breaks an env file cannot carry."""

    def test_a_secret_question_may_keep_the_applications_value(self):
        i = compose("""\
            services:
              a:
                image: x
                environment:
                  MYSQL_PASSWORD: example
                  OPTIONAL: ""
            """)
        answers = {"name": "uyg", "answers": {"secret:a:MYSQL_PASSWORD": {"keep": True}, "secret:a:OPTIONAL": {"value": "o"},
                                              "start:a": {"mode": "root"}}}
        definition, secrets, errors = check(i, answers, frozenset({"uyg-mysql-password"}))
        self.assertEqual(errors, {})
        self.assertEqual(secrets, {"uyg-optional": "o"}, "a kept value is not returned")
        self.assertEqual(definition["secrets"], [{"name": "uyg-mysql-password", "services": ["a"], "keep": True},
                                                 {"name": "uyg-optional", "services": ["a"], "keep": False}])
        self.assertEqual(definition["services"][0]["environment"][0], {"name": "MYSQL_PASSWORD", "secret": "uyg-mysql-password"})
        for existing in (frozenset(), frozenset({"uyg-optional"}), frozenset({"baska-mysql-password"})):
            with self.subTest(existing=existing):
                definition, secrets, errors = check(i, answers, existing)
                self.assertEqual((definition, secrets), (None, {}))
                self.assertEqual(errors, {"secret:a:MYSQL_PASSWORD": master_inspector.KEEP_MISSING})
        for keep in ({"keep": False}, {"keep": "true"}, {"keep": True, "value": "x"}):
            answers["answers"]["secret:a:MYSQL_PASSWORD"] = keep
            with self.subTest(keep=keep):
                self.assertIn("secret:a:MYSQL_PASSWORD", check(i, answers, frozenset({"uyg-mysql-password"}))[2])
        self.assertEqual(check(i, answers, "uyg-mysql-password")[2], {"dosya": "Saklanan gizli değerlerin listesi okunamadı."})
        self.assertIn("dosya", check(i, answers, [5])[2])

    def test_a_secret_variable_keeps_its_value_unless_it_is_composed(self):
        i = fixture("notlar-compose.yaml")
        answers = copy.deepcopy(NOTLAR)
        answers["answers"]["var:DB_PASSWORD"] = {"keep": True}
        existing = frozenset({"notlar-db-password", "notlar-database-url"})
        # DATABASE_URL holds the password inside other text: it cannot be built from a kept value.
        self.assertEqual(check(i, answers, existing)[2], {"var:DB_PASSWORD": master_inspector.KEEP_COMPOSED})
        i = compose("""\
            services:
              web:
                image: x
                environment: {DB_PASSWORD: "${DB_PASSWORD}"}
              db:
                image: y
                environment: ["POSTGRES_PASSWORD=${DB_PASSWORD:?required}"]
            """)
        answers = {"name": "uyg", "answers": {"var:DB_PASSWORD": {"keep": True}, "start:web": {"mode": "root"},
                                              "start:db": {"mode": "root"}}}
        definition, secrets, errors = check(i, answers, frozenset({"uyg-db-password"}))
        self.assertEqual((errors, secrets), ({}, {}))
        self.assertEqual(definition["secrets"], [{"name": "uyg-db-password", "services": ["web", "db"], "keep": True}])
        self.assertEqual(check(i, answers)[2], {"var:DB_PASSWORD": master_inspector.KEEP_MISSING})
        # Only a secret is kept; a plain variable needs its value.
        i = compose("services:\n  a:\n    image: x\n    environment: ['TZ=${TZ}']\n")
        errors = check(i, {"name": "uyg", "answers": {"var:TZ": {"keep": True}, "start:a": {"mode": "root"}}},
                       frozenset({"uyg-tz"}))[2]
        self.assertEqual(errors, {"var:TZ": "Bir değer girin."})

    def test_a_kubernetes_secret_may_keep_its_value(self):
        i = fixture("sayac-deployment.yaml")
        answers = {"name": "sayac", "answers": {
            "port:sayac:9000/tcp": {"use": "caddy", "tailscale_name": "sayac"}, "port:sayac:9001/udp": {"use": "raw"},
            "mount:sayac:/data": {"to": "app"}, "secret:sayac/token": {"keep": True}, "start:sayac": {"mode": "root"}}}
        definition, secrets, errors = check(i, answers, frozenset({"sayac-counter-token"}))
        self.assertEqual((errors, secrets, definition["secrets"][0]["keep"]), ({}, {}, True))
        self.assertEqual(check(i, answers)[2], {"secret:sayac/token": master_inspector.KEEP_MISSING})

    def test_a_root_start_with_a_writable_srv_folder_is_warned_about(self):
        i = fixture("qbittorrent-compose.yaml")
        answers = {"name": "aktarim", "answers": {
            "port:qbittorrent:8080/tcp": {"use": "caddy", "tailscale_name": "aktarim"},
            "port:qbittorrent:6881/tcp": {"use": "raw"}, "port:qbittorrent:6881/udp": {"use": "raw"},
            "mount:qbittorrent:/config": {"to": "app"}, "start:qbittorrent": {"mode": "root"},
            "mount:qbittorrent:/downloads": {"to": "srv", "path": "/srv/downloads", "read_only": False}}}
        definition = check(i, answers)[0]
        self.assertEqual(definition["warnings"], [{"service": "qbittorrent", "text":
                                                   "Bu konteyner root olarak başlıyor; kendi kullanıcısına geçmezse /srv'ye "
                                                   "Dosyalar hesabının açamayacağı dosyalar yazabilir."}])
        for change in ({"start:qbittorrent": {"mode": "direct"}},
                       {"mount:qbittorrent:/downloads": {"to": "srv", "path": "/srv/downloads", "read_only": True}},
                       {"mount:qbittorrent:/downloads": {"to": "app"}}):
            changed = copy.deepcopy(answers)
            changed["answers"].update(change)
            with self.subTest(change=change):
                self.assertEqual(check(i, changed)[0]["warnings"], [])
        self.assertEqual(check(fixture("ornek-compose.yaml"), ORNEK)[0]["warnings"], [])

    def test_a_direct_start_as_another_user_with_a_writable_srv_folder_is_warned_about(self):
        i = compose("""\
            services:
              web:
                image: registry.example/web:1
                user: "999:999"
                volumes: ["/srv/web:/data"]
            """)
        answers = {"name": "web", "answers": {"start:web": {"mode": "direct"},
                                              "mount:web:/data": {"to": "srv", "path": "/srv/web", "read_only": False}}}
        self.assertEqual(check(i, answers)[0]["warnings"], [{"service": "web", "text":
                                                             "Bu konteyner 999:999 kullanıcısıyla başlıyor; /srv'ye "
                                                             "Dosyalar hesabının açamayacağı dosyalar yazabilir."}])
        answers["answers"]["mount:web:/data"]["read_only"] = True
        self.assertEqual(check(i, answers)[0]["warnings"], [])

    def test_a_secret_written_in_the_file_is_noted_on_its_line(self):
        # The file is kept as given (K3); its literal secret is not used but stays readable there: say so.
        i = compose("""\
            services:
              web:
                image: registry.example/web:1
                environment:
                  ADMIN_PASSWORD: hunter2
                  LEVEL: info
            """)
        notes = [n for n in i["notes"] if n["key"] == "gizli-deger"]
        self.assertEqual([(n["line"], n["text"]) for n in notes],
                         [(5, "web: ADMIN_PASSWORD dosyada açık yazılmış. Bu değer kullanılmaz ama dosyayla birlikte "
                              "saklanır ve Tanım'da görünür; dosyadan silmeniz önerilir.")])
        self.assertNotIn("hunter2", repr(i["notes"]) + repr(i["questions"]))
        self.assertIn({"line": 5, "kind": "note", "text": notes[0]["text"]}, i["marks"])

    def test_srv_paths_follow_the_bind_anchor_rule(self):
        # DD-226's anchors pin a non-hidden sub-folder of /srv in plain characters; the answer is refused early.
        i = compose("""\
            services:
              web:
                image: registry.example/web:1
                volumes: ["/srv:/srv", "veri:/veri"]
            volumes: {veri: {}}
            """)
        q = {x["id"]: x for x in i["questions"]}
        self.assertEqual((q["mount:web:/srv"]["suggest"], q["mount:web:/srv"]["srv_path"]), ("srv", None))
        for path in ("/srv", "/srv/Müzik", "/srv/.gizli", "/srv/a/../b", "/srv/a/"):
            answers = {"name": "web", "answers": {"start:web": {"mode": "root"}, "mount:web:/veri": {"to": "app"},
                                                  "mount:web:/srv": {"to": "srv", "path": path, "read_only": True}}}
            with self.subTest(path=path):
                self.assertIn("mount:web:/srv", check(i, answers)[2])
        answers["answers"]["mount:web:/srv"]["path"] = "/srv/Muzik ve Film"
        self.assertEqual(check(i, answers)[2], {})

    def test_an_env_file_line_cannot_break(self):
        # The file's own text is refused at inspect, with its line.
        i = compose("""\
            services:
              a:
                image: x
                environment:
                  MOTD: |
                    hello
                    world
                  NOTE: "a\\rb ${X}"
                  API_TOKEN: |
                    a secret
                    may hold lines
            """)
        self.assertEqual([(r["line"], r["key"]) for r in i["refusals"]], [(5, "environment"), (8, "environment")])
        pod = inspect("apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec:\n  containers:\n  - name: a\n    image: x\n"
                      "    env:\n    - {name: MOTD, value: \"a\\nb\"}\n")
        self.assertEqual([(r["line"], r["key"]) for r in pod["refusals"]], [(9, "environment")])
        # An answer or a default is refused for the variable it came from; a secret may hold a line break.
        i = compose("""\
            services:
              a:
                image: x
                environment: ["GREETING=${GREETING}", "DEFAULTED=${OTHER:-a\\nb}", "DB_PASSWORD=${DB_PASSWORD}"]
            """)
        self.assertEqual(i["refusals"], [])
        base = {"name": "uyg", "answers": {"var:GREETING": {"value": "hi"}, "var:OTHER": {"value": "set"},
                                           "var:DB_PASSWORD": {"value": "-----BEGIN-----\nkey\n-----END-----"},
                                           "start:a": {"mode": "root"}}}
        definition, secrets, errors = check(i, base)
        self.assertEqual((errors, secrets), ({}, {"uyg-db-password": "-----BEGIN-----\nkey\n-----END-----"}))
        for qid, value in (("var:GREETING", "a\nb"), ("var:GREETING", "a\rb"), ("var:OTHER", "")):
            answers = copy.deepcopy(base)
            answers["answers"][qid] = {"value": value}
            with self.subTest(qid=qid, value=value):
                definition, _s, errors = check(i, answers)
                self.assertIsNone(definition)
                self.assertEqual(list(errors), [qid])
                self.assertIn("satır sonu", errors[qid])
        # A working folder from a variable may not carry a control character either.
        i = compose("services:\n  a:\n    image: x\n    working_dir: ${WD}\n")
        errors = check(i, {"name": "uyg", "answers": {"var:WD": {"value": "/a\nb"}, "start:a": {"mode": "root"}}})[2]
        self.assertEqual(list(errors), ["var:WD"])

    def test_a_user_the_image_switches_to_itself_suggests_the_root_start_and_says_why(self):
        i = compose("""\
            services:
              web:
                image: x
                environment:
                  - PUID=1000
                  - PGID=1000
              api:
                image: y
                environment: {PUID: "${KULLANICI:-1000}"}
              db:
                image: z
                user: "999"
                environment: [PUID=1000]
            """)
        q = questions(i)
        self.assertEqual(q["start:web"]["suggest"], "root")
        self.assertIn("Dosyada PUID=1000 ve PGID=1000 var: imaj root olarak başlar", q["start:web"]["why"])
        self.assertIn("Dosyada PUID var:", q["start:api"]["why"], "a variable's value is not quoted")
        self.assertEqual(q["start:db"]["suggest"], "direct", "the file's own user wins")

    def test_the_start_question_names_no_image_family(self):
        why = questions(fixture("ornek-compose.yaml"))["start:ornek"]["why"]
        self.assertNotRegex(why.lower(), "linuxserver|gosu|ör\\.")
        self.assertIn("kendi kullanıcısına geçiyor", why)


if __name__ == "__main__":
    unittest.main()
