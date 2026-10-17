"""DD-271 (phase 3): the generator (master_generator). Golden units for every acceptance fixture the inspector
accepts, with the answers fixed here, and focused tests: the names, the two start modes, folders and anchors,
aliases, the pod, the start order and Notify=healthy, what needs Podman 5, no secret value in the plan, the env
file and the quoting Quadlet and systemd undo (each checked against a model of the real parser), a stopped
application, and the values the generator cannot express.

    python3.13 -I tests/test_generator.py --yaz      rewrites tests/fixtures/uygulama/beklenen/
"""
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import textwrap
import unittest
from unittest.mock import patch

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_container_binds  # noqa: E402
import master_generator  # noqa: E402
import master_inspector  # noqa: E402

GeneratorError = master_generator.GeneratorError
FIXTURES = DATA / "tests" / "fixtures" / "uygulama"
GOLDEN = FIXTURES / "beklenen"
# The state.env keys the generator reads, as config/defaults.env sets them (a test holds them equal).
ENV = {"KONTEYNER_BIRIM_DIR": "/etc/containers/systemd", "KONTEYNER_BRIDGE_PREFIX": "ksl",
       "UYGULAMA_STATE_DIR": "/etc/master-stack/containers/uygulamalar", "UYGULAMA_VERI_DIR": "/var/lib/master-stack/uygulamalar",
       "SERVER_ROOT": "/srv", "KONTEYNER_BAGLAMA_DIR": "/run/master-stack/konteyner-baglama", "SBIN_DIR": "/usr/local/sbin",
       "STATE_FILE": "/etc/master-stack/state.env", "DOWNLOADS_UID": "1000", "DOWNLOADS_GID": "1000"}
CADDY = "caddy"


def caddy(name):
    return {"use": CADDY, "tailscale_name": name}


RAW = {"use": "raw"}
APP = {"to": "app"}


def srv(path, read_only=False):
    return {"to": "srv", "path": path, "read_only": read_only}


DIRECT, ROOT = {"mode": "direct"}, {"mode": "root"}
SECRET_VALUES = ("Gizli-Deger-7f3a9", "Sayac-Jetonu-41c2")
# Every fixture the inspector accepts, with its answers: both start modes, addresses and raw ports, application
# and /srv folders, secrets, a Kubernetes Pod with two containers and a single-container Deployment.
ANSWERS = {
    "ornek-compose.yaml": {"name": "ornek", "answers": {
        "port:ornek:8080/tcp": caddy("ornek"), "port:ornek:8092/tcp": RAW,
        "mount:ornek:/database": APP, "mount:ornek:/config": APP, "mount:ornek:/srv": srv("/srv/ornek"),
        "start:ornek": DIRECT}},
    "notlar-compose.yaml": {"name": "notlar", "answers": {
        "var:NOTLAR_VERSION": {"value": "1.5"}, "var:BASE_URL": {"value": ""},
        "var:DB_PASSWORD": {"value": SECRET_VALUES[0]}, "var:LOG_LEVEL": {"value": ""},
        "port:web:3000/tcp": caddy("notlar"), "mount:web:/app/uploads": APP,
        "mount:web:/media/notlar": srv("/srv/media/notlar", True), "start:web": DIRECT,
        "mount:db:/var/lib/postgresql/data": APP, "start:db": ROOT}},
    "kasa-compose.yaml": {"name": "kasa", "answers": {
        "port:kasa:80/tcp": caddy("kasa"), "mount:kasa:/data": APP, "start:kasa": DIRECT,
        "mount:yedek:/data": APP, "start:yedek": ROOT}},
    "qbittorrent-compose.yaml": {"name": "aktarim", "answers": {
        "port:qbittorrent:8080/tcp": caddy("aktarim"), "port:qbittorrent:6881/tcp": RAW, "port:qbittorrent:6881/udp": RAW,
        "mount:qbittorrent:/config": APP, "mount:qbittorrent:/downloads": srv("/srv/downloads"), "start:qbittorrent": ROOT}},
    "notlar-pod.yaml": {"name": "notlar", "answers": {
        "port:notlar-web:8080/tcp": caddy("notlar"),
        "mount:notlar-web:/usr/share/nginx/html": srv("/srv/notlar/html", True), "mount:notlar-web:/var/cache/nginx": APP,
        "start:notlar-web": ROOT, "mount:notlar-redis:/data": APP, "start:notlar-redis": DIRECT}},
    "sayac-deployment.yaml": {"name": "sayac", "answers": {
        "port:sayac:9000/tcp": caddy("sayac"), "port:sayac:9001/udp": RAW, "mount:sayac:/data": APP,
        "secret:sayac/token": {"value": SECRET_VALUES[1]}, "start:sayac": ROOT}},
}
# Quadlet's supported keys (pkg/systemd/quadlet/quadlet.go): [Container] and [Network] of v4.9.3, [Pod] of v5.0.0.
QUADLET_49_CONTAINER = frozenset(
    "AddCapability AddDevice Annotation AutoUpdate ContainerName ContainersConfModule DNS DNSOption DNSSearch DropCapability "
    "Environment EnvironmentFile EnvironmentHost Exec ExposeHostPort GIDMap GlobalArgs Group HealthCmd HealthInterval "
    "HealthOnFailure HealthRetries HealthStartPeriod HealthStartupCmd HealthStartupInterval HealthStartupRetries "
    "HealthStartupSuccess HealthStartupTimeout HealthTimeout HostName IP IP6 Image Label LogDriver Mask Mount Network "
    "NoNewPrivileges Notify PidsLimit PodmanArgs PublishPort Pull ReadOnly ReadOnlyTmpfs RemapGid RemapUid RemapUidSize "
    "RemapUsers Rootfs RunInit SeccompProfile Secret SecurityLabelDisable SecurityLabelFileType SecurityLabelLevel "
    "SecurityLabelNested SecurityLabelType ShmSize SubGIDMap SubUIDMap Sysctl Timezone Tmpfs UIDMap Ulimit Unmask User "
    "UserNS VolatileTmp Volume WorkingDir".split())
QUADLET_49_NETWORK = frozenset("ContainersConfModule DNS DisableDNS Driver Gateway GlobalArgs IPAMDriver IPRange IPv6 "
                               "Internal Label NetworkName Options PodmanArgs Subnet".split())
QUADLET_50_POD = frozenset("ContainersConfModule GlobalArgs Network PodName PodmanArgs PublishPort Volume".split())
# The PodmanArgs flags in use, each one a podman-run (or pod/network create) option of v4.9.3.
PODMAN_49_FLAGS = ("--entrypoint=", "--network-alias=", "--stop-signal=", "--stop-timeout=", "--cpus=", "--memory=",
                   "--ulimit=", "--umask=", "--interface-name=", "--infra-name=", "--label=")


# -- the inputs
def definition_of(fixture, answers=None, existing=frozenset()):
    inspection = master_inspector.inspect((FIXTURES / fixture).read_text())
    definition, secrets, errors = master_inspector.check(inspection, answers or ANSWERS[fixture], existing)
    assert not errors, (fixture, errors)
    return definition, secrets


def compose(text, answers):
    inspection = master_inspector.inspect(textwrap.dedent(text))
    assert not inspection["refusals"], inspection["refusals"]
    definition, _secrets, errors = master_inspector.check(inspection, answers)
    assert not errors, errors
    return definition


def context(definition, **changes):
    """What the engine would have allocated: digests, pool ports in order, a Podman name for each secret."""
    app = definition["name"]
    images = {s["name"]: "%s@sha256:%s" % (master_generator.image_reference(s["image"])[0],
                                           hashlib.sha256(s["name"].encode()).hexdigest()) for s in definition["services"]}
    ports, pool = {}, 62100
    for svc in definition["services"]:
        for port in svc["ports"]:
            if port["use"] == CADDY:
                ports["%s:%d/%s" % (svc["name"], port["port"], port["protocol"])] = pool
                pool += 1
    secrets = {s["name"]: master_generator.secret_name(app, hashlib.sha256(s["name"].encode()).hexdigest()[:8])
               for s in definition["secrets"]}
    value = {"app": app, "images": images, "ports": ports, "secrets": secrets, "stopped": False, "podman": (5, 4),
             "env": dict(ENV)}
    value.update(changes)
    return value


def render(definition, **changes):
    return master_generator.render(definition, context(definition, **changes))


def golden(plan):
    files = dict(plan["units"])
    files["plan.json"] = json.dumps({k: v for k, v in plan.items() if k != "units"}, indent=2, ensure_ascii=False) + "\n"
    return files


def write_golden():
    for fixture in sorted(ANSWERS):
        folder = GOLDEN / Path(fixture).stem
        folder.mkdir(parents=True, exist_ok=True)
        files = golden(render(definition_of(fixture)[0]))
        for stale in folder.iterdir():
            if stale.name not in files:
                stale.unlink()
        for name, text in files.items():
            (folder / name).write_text(text)
        print("%s: %s" % (folder.relative_to(DATA), ", ".join(sorted(files))))


# -- models of the parsers the units meet
def sections(text):
    """[(section, key, value)] of a unit file, as systemd and Quadlet read its lines."""
    out, section = [], None
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line.strip("[]")
            continue
        key, _, value = line.partition("=")
        out.append((section, key, value))
    return out


def values(text, section, key):
    return [v for s, k, v in sections(text) if s == section and k == key]


def split_words(text):
    """Quadlet's splitString(SplitRelax|SplitUnquote|SplitCUnescape) for the words word() and arg() write, then
    systemd's ExecStart, which turns $$ into $ and %% into %: the argument podman receives."""
    escapes = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\", '"': '"', "'": "'",
               "s": " "}
    words, i = [], 0
    while i < len(text):
        if text[i] == " ":
            i += 1
            continue
        out = []
        if text[i] == '"':
            i += 1
            while text[i] != '"':
                if text[i] == "\\":
                    if text[i + 1] == "x":
                        out.append(chr(int(text[i + 2:i + 4], 16)))
                        i += 4
                        continue
                    out.append(escapes[text[i + 1]])
                    i += 2
                    continue
                out.append(text[i])
                i += 1
            i += 1
        else:
            while i < len(text) and text[i] != " ":
                assert text[i] not in "\\\"'", text
                out.append(text[i])
                i += 1
        words.append(systemd("".join(out)))
    return words


def systemd(value):
    """What systemd makes of a word in ExecStart: %% and $$ are one character each."""
    return re.sub(r"%%|\$\$", lambda m: m.group()[0], value)


def podman_env_file(text):
    """Podman's env-file reader (pkg/env ParseFile, v4.9.3 to 5.6): bufio lines (a final CR dropped), leading blanks
    trimmed, '#' lines skipped, the name up to the first '=' and the rest as written."""
    env = {}
    for line in text.split("\n"):
        line = line[:-1] if line.endswith("\r") else line
        line = line.lstrip(" \t")
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        env[key.lstrip(" \t")] = value
    return env


def podman_health(value):
    """MakeHealthCheckFromCli's reading of --health-cmd (identical in v4.9.3 and v5.4.2): the Test it stores."""
    try:
        words, is_array = json.loads(value), True
        assert isinstance(words, list)
    except (ValueError, AssertionError):
        words, is_array = value.split(" ", 1), False
    if words[0].upper() in ("CMD", "NONE"):
        words = value.split()
    elif words[0].upper() != "CMD-SHELL":
        words = ["CMD"] + words if is_array and len(words) > 1 else ["CMD-SHELL", " ".join(words)]
    return ["NONE"] if words[0].upper() == "NONE" else words


class GoldenTests(unittest.TestCase):
    def test_every_accepted_fixture_has_answers_here(self):
        for path in sorted(FIXTURES.glob("*.yaml")):
            accepted = not master_inspector.inspect(path.read_text())["refusals"]
            self.assertEqual(path.name in ANSWERS, accepted, path.name)

    def test_the_golden_units(self):
        for fixture in sorted(ANSWERS):
            with self.subTest(fixture=fixture):
                folder = GOLDEN / Path(fixture).stem
                files = golden(render(definition_of(fixture)[0]))
                found = sorted(p.name for p in folder.iterdir()) if folder.is_dir() else []
                hint = "run `python3.13 -I tests/test_generator.py --yaz` and review the difference"
                self.assertEqual(found, sorted(files), hint)
                for name, text in files.items():
                    self.assertEqual((folder / name).read_text(), text, "%s/%s: %s" % (folder.name, name, hint))

    def test_golden_plans_hold_no_secret_value_and_only_known_keys(self):
        for fixture in sorted(ANSWERS):
            with self.subTest(fixture=fixture):
                definition, secrets = definition_of(fixture)
                plan = render(definition)
                text = json.dumps(plan, ensure_ascii=False)
                for value in list(secrets.values()) + list(SECRET_VALUES):
                    self.assertNotIn(value, text)
                self.assertEqual(set(plan), {"units", "environment", "folders", "binds", "start", "stop", "containers",
                                             "network", "pod", "publications", "needs_podman5"})
                self.assertEqual(list(plan["units"]), sorted(plan["units"]))
                for name, unit in plan["units"].items():
                    group = {"container": "Container", "network": "Network", "pod": "Pod"}[name.rsplit(".", 1)[1]]
                    keys = {k for s, k, _v in sections(unit) if s == group}
                    allowed = {"Container": QUADLET_49_CONTAINER, "Network": QUADLET_49_NETWORK, "Pod": QUADLET_50_POD}[group]
                    # Pod= (and the .pod itself) is Podman 5's, and only a plan that says so has it.
                    self.assertLessEqual(keys - {"Pod"} if plan["pod"] else keys, allowed, name)
                    if group != "Network" and plan["pod"]:
                        self.assertTrue(plan["needs_podman5"])
                    for flag in values(unit, group, "PodmanArgs"):
                        self.assertTrue(split_words(flag)[0].startswith(PODMAN_49_FLAGS), flag)
                    if group == "Container":
                        self.assertLessEqual(set(values(unit, "Container", "Notify")), {"healthy"})
                        self.assertNotIn("Ulimit", keys, "Quadlet 4.9 keeps only the last Ulimit= line")

    def test_the_same_input_gives_the_same_plan_and_is_not_changed(self):
        definition = definition_of("notlar-compose.yaml")[0]
        before = copy.deepcopy(definition)
        ctx = context(definition)
        self.assertEqual(master_generator.render(definition, ctx), master_generator.render(definition, copy.deepcopy(ctx)))
        self.assertEqual(definition, before)


class NameTests(unittest.TestCase):
    def test_the_names_of_one_application(self):
        g = master_generator
        self.assertEqual((g.container_name("notlar", "web"), g.container_file("notlar", "web"), g.container_unit("notlar", "web")),
                         ("notlar_web", "konsol-notlar_web.container", "konsol-notlar_web.service"))
        self.assertEqual((g.network_file("notlar"), g.network_name("notlar"), g.network_unit("notlar")),
                         ("konsol-notlar.network", "ksl-notlar", "konsol-notlar-network.service"))
        self.assertEqual((g.pod_file("notlar"), g.pod_name("notlar"), g.pod_unit("notlar"), g.pod_infra_name("notlar")),
                         ("konsol-notlar.pod", "notlar", "konsol-notlar-pod.service", "notlar__infra"))
        self.assertEqual(g.labels("notlar"), {"io.master-stack.managed": "uygulama", "io.master-stack.uygulama": "notlar"})
        self.assertEqual(g.interface_name(ENV, "notlar"), "ksl" + hashlib.sha256(b"ksl-notlar").hexdigest()[:10])
        longest = "a" * 30
        self.assertLessEqual(len(g.interface_name(dict(ENV, KONTEYNER_BRIDGE_PREFIX="abcde"), longest)), 15, "IFNAMSIZ")
        for prefix in ("", "abcdef", "K", None):
            with self.subTest(prefix=prefix), self.assertRaises(GeneratorError):
                g.interface_name(dict(ENV, KONTEYNER_BRIDGE_PREFIX=prefix), "notlar")
        self.assertEqual(g.env_file(ENV, "notlar", "web"), "/etc/master-stack/containers/uygulamalar/notlar/env/web.env")
        self.assertEqual(g.app_folder(ENV, "notlar"), "/var/lib/master-stack/uygulamalar/notlar")
        for bad in ("Notlar", "a_b", "", None, "konsol" * 6):
            with self.subTest(bad=bad), self.assertRaises(GeneratorError):
                g.container_name(bad, "web")
        with self.assertRaises(GeneratorError):
            g.container_name("notlar", "-web")

    def test_no_two_applications_share_a_name(self):
        g = master_generator
        # '_' separates the application from the service, and application names have none.
        pairs = (("a", "b-c"), ("a-b", "c"), ("a", "b_c"), ("a", "b.c"), ("a-b-c", "d"))
        self.assertEqual(len({g.container_name(a, s) for a, s in pairs}), len(pairs))
        self.assertEqual(len({g.container_file(a, s) for a, s in pairs} | {g.network_file(a) for a, _s in pairs}),
                         len(pairs) + 3)
        # An infra container never takes a service's or a pod's name.
        self.assertNotIn(g.pod_infra_name("a"), {g.container_name("a", "infra"), g.pod_name("a-infra")})
        units = {g.network_unit("x-pod"), g.pod_unit("x"), g.network_unit("x"), g.pod_unit("x-network")}
        self.assertEqual(len(units), 4)

    def test_names_without_rendering_match_the_plan(self):
        for fixture in sorted(ANSWERS):
            definition = definition_of(fixture)[0]
            plan, objects = render(definition), master_generator.names(definition["name"], definition)
            with self.subTest(fixture=fixture):
                self.assertEqual(objects["files"], list(plan["units"]))
                self.assertEqual(objects["containers"], plan["containers"])
                self.assertEqual(sorted(objects["units"].values()), sorted(u for u in plan["start"] if not u.endswith("-pod.service")))
                self.assertEqual((objects["network"], objects["network_unit"]), (plan["network"]["name"], plan["network"]["unit"]))
                self.assertEqual((objects["pod"], objects["pod_unit"]),
                                 (plan["pod"]["name"], plan["pod"]["unit"]) if plan["pod"] else (None, None))
        with self.assertRaises(GeneratorError):
            master_generator.names("notlar", {"services": [{"name": "-x"}]})

    def test_secret_names(self):
        g = master_generator
        name = g.secret_name("notlar", "0a1b2c3d")
        self.assertEqual((name, g.secret_app(name)), ("obhut_notlar_0a1b2c3d", "notlar"))
        for bad in ("obhut_notlar_0A1B2C3D", "notlar-db-password", "obhut_a_b_01234567", None):
            self.assertIsNone(g.secret_app(bad))
        for token in ("0a1b2c3", "0a1b2c3dd", "zzzzzzzz", 5):
            with self.subTest(token=token), self.assertRaises(GeneratorError):
                g.secret_name("notlar", token)

    def test_image_references_as_docker_reads_them(self):
        cases = {
            "nginx": ("docker.io/library/nginx", "docker.io/library/nginx:latest"),
            "postgres:16-alpine": ("docker.io/library/postgres", "docker.io/library/postgres:16-alpine"),
            "example/app:2": ("docker.io/example/app", "docker.io/example/app:2"),
            "index.docker.io/library/redis:7": ("docker.io/library/redis", "docker.io/library/redis:7"),
            "registry.example/ornek/sunucu:2": ("registry.example/ornek/sunucu", "registry.example/ornek/sunucu:2"),
            "localhost/yerel": ("localhost/yerel", "localhost/yerel:latest"),
            "registry.example:5000/a/b": ("registry.example:5000/a/b", "registry.example:5000/a/b:latest"),
            "ghcr.io/example/x@sha256:" + "a" * 64: ("ghcr.io/example/x", "ghcr.io/example/x@sha256:" + "a" * 64),
            "ghcr.io/example/x:1@sha256:" + "b" * 64: ("ghcr.io/example/x", "ghcr.io/example/x:1@sha256:" + "b" * 64),
        }
        for image, expected in cases.items():
            self.assertEqual(master_generator.image_reference(image), expected, image)
        for bad in ("", "Nginx", "docker.io/Library/nginx", "nginx:", "nginx@sha256:abc", "a b", "registry.example/a//b",
                    "nginx@md5:" + "a" * 32, None, "x/" * 200 + "y"):
            with self.subTest(bad=bad), self.assertRaises(GeneratorError):
                master_generator.image_reference(bad)

    def test_the_rules_shared_with_the_inspector_and_the_defaults(self):
        self.assertIs(master_generator.APP_NAME_RE, master_inspector.APP_NAME_RE)
        defaults = dict(re.findall(r'^([A-Z_]+)="?([^"\n]*)"?$', (DATA / "config/defaults.env").read_text(), re.M))
        for key, value in ENV.items():
            if key in defaults:
                self.assertEqual(defaults[key], value, key)


class StartModeTests(unittest.TestCase):
    def unit(self, plan, app, service):
        return plan["units"][master_generator.container_file(app, service)]

    def test_direct_and_root_lines(self):
        plan = render(definition_of("notlar-compose.yaml")[0])
        web, db = self.unit(plan, "notlar", "web"), self.unit(plan, "notlar", "db")
        self.assertEqual((values(web, "Container", "User"), values(web, "Container", "DropCapability"),
                          values(web, "Container", "NoNewPrivileges"), values(web, "Container", "AddCapability")),
                         (["1000:1000"], ["all"], ["true"], []))
        self.assertEqual((values(db, "Container", "User"), values(db, "Container", "DropCapability"),
                          values(db, "Container", "NoNewPrivileges")), ([], ["NET_BIND_SERVICE SETFCAP SYS_CHROOT"], []))
        definition = compose("""\
            services:
              a:
                image: x
                cap_add: [CHOWN]
                cap_drop: [ALL]
                security_opt: [no-new-privileges]
                ports: ["80"]
              b:
                image: y
                user: "33:33"
                cap_add: [KILL]
            """, {"name": "uyg", "answers": {"port:a:80/tcp": RAW, "start:a": ROOT, "start:b": DIRECT}})
        plan = render(definition)
        a, b = self.unit(plan, "uyg", "a"), self.unit(plan, "uyg", "b")
        self.assertEqual((values(a, "Container", "DropCapability"), values(a, "Container", "AddCapability"),
                          values(a, "Container", "NoNewPrivileges")), (["all"], ["CHOWN"], ["true"]))
        # A direct start never adds a capability, whatever the file asks: the worker proves empty sets.
        self.assertEqual((values(b, "Container", "User"), values(b, "Container", "DropCapability"),
                          values(b, "Container", "AddCapability")), (["33:33"], ["all"], []))

    def test_the_files_account_keeps_group_writable_files_on_srv_only(self):
        ornek = self.unit(render(definition_of("ornek-compose.yaml")[0]), "ornek", "ornek")
        self.assertIn("--umask=0002", values(ornek, "Container", "PodmanArgs"), "Files account, writable /srv")
        notlar = self.unit(render(definition_of("notlar-compose.yaml")[0]), "notlar", "web")
        self.assertNotIn("--umask=0002", values(notlar, "Container", "PodmanArgs"), "its /srv folder is read-only")
        redis = self.unit(render(definition_of("notlar-pod.yaml")[0]), "notlar", "notlar-redis")
        self.assertNotIn("--umask=0002", values(redis, "Container", "PodmanArgs"), "999:999 has no /srv folder")


class MountTests(unittest.TestCase):
    def test_u_only_on_the_application_folders_of_direct_services(self):
        for fixture in sorted(ANSWERS):
            definition = definition_of(fixture)[0]
            plan = render(definition)
            for svc in definition["services"]:
                unit = plan["units"][master_generator.container_file(definition["name"], svc["name"])]
                for volume in values(unit, "Container", "Volume"):
                    source, _target, options = volume.split(":")
                    app_folder = source.startswith(ENV["UYGULAMA_VERI_DIR"] + "/")
                    with self.subTest(fixture=fixture, volume=volume):
                        self.assertTrue(app_folder or source.startswith(ENV["KONTEYNER_BAGLAMA_DIR"] + "/"))
                        self.assertEqual("U" in options.split(","), app_folder and svc["start"] == "direct")

    def test_anchors_only_for_srv(self):
        definition = definition_of("notlar-compose.yaml")[0]
        plan = render(definition)
        web = plan["units"]["konsol-notlar_web.container"]
        db = plan["units"]["konsol-notlar_db.container"]
        anchor = master_container_binds.anchor_path(ENV, "notlar_web", 0, "/srv/media/notlar")
        self.assertIn("%s:/media/notlar:ro" % anchor, values(web, "Container", "Volume"))
        self.assertEqual(values(web, "Unit", "RequiresMountsFor"), ['"/srv/media/notlar"'])
        pre = values(web, "Service", "ExecStartPre")
        self.assertEqual(split_words(pre[1].partition(" ")[2])[-3:], ["bagla", "notlar_web", "/srv/media/notlar"])
        self.assertEqual(split_words(values(web, "Service", "ExecStopPost")[0])[-2:], ["birak", "notlar_web"])
        self.assertEqual((plan["binds"], plan["folders"]),
                         ({"web": ["/srv/media/notlar"], "db": []},
                          ["/var/lib/master-stack/uygulamalar/notlar/db-data", "/var/lib/master-stack/uygulamalar/notlar/uploads"]))
        self.assertFalse([v for v in values(db, "Service", "ExecStartPre") if "bagla" in v])
        self.assertEqual((values(db, "Service", "ExecStopPost"), values(db, "Unit", "RequiresMountsFor")), ([], []))
        self.assertEqual(values(db, "Container", "Tmpfs"), ["/run/postgresql"])

    def test_two_folders_from_one_srv_path_and_a_shared_volume(self):
        definition = compose("""\
            services:
              a:
                image: x
                volumes: [/srv/ortak:/one, /srv/ortak:/two, veri:/data]
              b:
                image: y
                volumes: ["veri:/data:ro"]
            volumes: {veri: {}}
            """, {"name": "uyg", "answers": {"mount:a:/one": srv("/srv/ortak"), "mount:a:/two": srv("/srv/ortak", True),
                                             "mount:a:/data": APP, "mount:b:/data": APP, "start:a": ROOT, "start:b": ROOT}})
        plan = render(definition)
        a = plan["units"]["konsol-uyg_a.container"]
        anchors = [master_container_binds.anchor_path(ENV, "uyg_a", n, "/srv/ortak") for n in (0, 1)]
        self.assertNotEqual(*anchors)
        self.assertEqual(values(a, "Container", "Volume")[:2], ["%s:/one:rw" % anchors[0], "%s:/two:ro" % anchors[1]])
        self.assertEqual(values(a, "Unit", "RequiresMountsFor"), ['"/srv/ortak"'])
        self.assertEqual((plan["binds"]["a"], plan["folders"]), (["/srv/ortak", "/srv/ortak"],
                                                                  ["/var/lib/master-stack/uygulamalar/uyg/veri"]))

    def test_paths_the_bind_anchor_cannot_pin_or_a_volume_cannot_carry(self):
        base = definition_of("ornek-compose.yaml")[0]
        for path in ("/srv", "/srv/.gizli/x", "/srv/Müzik", "/srv/a/../b", "/srv//a", "/srvx/a", "/srv/a\nb"):
            definition = copy.deepcopy(base)
            definition["services"][0]["mounts"][2]["path"] = path
            with self.subTest(path=path), self.assertRaises(GeneratorError):
                render(definition)
        for target in ("/a:b", "relative", "/", "/a/../b", "/a\nb", "/trailing ", '/"q"'):
            definition = copy.deepcopy(base)
            definition["services"][0]["mounts"][0]["target"] = target
            with self.subTest(target=target), self.assertRaises(GeneratorError):
                render(definition)
        # The anchor key is the container name; master_container_binds' own refusal stops the plan.
        with patch.object(master_generator, "anchor_path", side_effect=ValueError("ad")), \
                self.assertRaisesRegex(GeneratorError, "ornek_ornek"):
            render(base)
        definition = copy.deepcopy(base)
        definition["services"][0]["mounts"] = definition["services"][0]["mounts"][:2]
        with patch.object(master_generator, "anchor_path", side_effect=ValueError("ad")):
            self.assertTrue(render(definition)["units"], "no /srv, no anchor")
        # A target with spaces, '$' and '%' reaches Podman as written.
        definition = copy.deepcopy(base)
        definition["services"][0]["mounts"][0]["target"] = "/veri $HOME %h"
        volume = values(render(definition)["units"]["konsol-ornek_ornek.container"], "Container", "Volume")[0]
        self.assertEqual(systemd(volume).split(":")[1], "/veri $HOME %h")


class NetworkTests(unittest.TestCase):
    def test_compose_services_share_one_network_by_their_names(self):
        plan = render(definition_of("kasa-compose.yaml")[0])
        self.assertEqual(plan["network"], {"name": "ksl-kasa", "interface": master_generator.interface_name(ENV, "kasa"),
                                           "unit": "konsol-kasa-network.service"})
        network = plan["units"]["konsol-kasa.network"]
        self.assertEqual((values(network, "Network", "NetworkName"), values(network, "Network", "Driver"),
                          values(network, "Network", "PodmanArgs")),
                         (["ksl-kasa"], ["bridge"], ["--interface-name=" + plan["network"]["interface"]]))
        self.assertEqual(values(network, "Network", "Label"), ["io.master-stack.managed=uygulama", "io.master-stack.uygulama=kasa"])
        for service in ("kasa", "yedek"):
            unit = plan["units"]["konsol-kasa_%s.container" % service]
            self.assertEqual(values(unit, "Container", "Network"), ["konsol-kasa.network"])
            self.assertIn("--network-alias=" + service, values(unit, "Container", "PodmanArgs"))
            self.assertEqual(values(unit, "Container", "Pod"), [])
        self.assertIsNone(plan["pod"])

    def test_a_pod_holds_the_network_and_the_publications(self):
        plan = render(definition_of("notlar-pod.yaml")[0])
        self.assertEqual(plan["pod"], {"name": "notlar", "unit": "konsol-notlar-pod.service"})
        pod = plan["units"]["konsol-notlar.pod"]
        self.assertEqual((values(pod, "Pod", "PodName"), values(pod, "Pod", "Network"), values(pod, "Pod", "PublishPort")),
                         (["notlar"], ["konsol-notlar.network"], ["127.0.0.1:62100:8080/tcp"]))
        self.assertEqual(values(pod, "Pod", "PodmanArgs"), ["--infra-name=notlar__infra", "--label=io.master-stack.managed=uygulama",
                                                            "--label=io.master-stack.uygulama=notlar"])
        self.assertEqual(len(values(pod, "Service", "ExecStartPre")), 1, "the guard check before Quadlet's pod create")
        for service in ("notlar-web", "notlar-redis"):
            unit = plan["units"]["konsol-notlar_%s.container" % service]
            self.assertEqual(values(unit, "Container", "Pod"), ["konsol-notlar.pod"])
            for key in ("Network", "PublishPort", "HostName"):
                self.assertEqual(values(unit, "Container", key), [], key)
            self.assertFalse([a for a in values(unit, "Container", "PodmanArgs") if a.startswith("--network-alias")])
        self.assertEqual(plan["start"], ["konsol-notlar-pod.service", "konsol-notlar_notlar-web.service",
                                         "konsol-notlar_notlar-redis.service"])
        self.assertEqual(plan["stop"], list(reversed(plan["start"])))
        self.assertEqual(plan["needs_podman5"], ["Kubernetes dosyası birden çok konteynerli bir Pod (Quadlet .pod)"])

    def test_one_kubernetes_container_is_generated_like_a_compose_service(self):
        plan = render(definition_of("sayac-deployment.yaml")[0])
        self.assertEqual((plan["pod"], plan["needs_podman5"], sorted(plan["units"])),
                         (None, [], ["konsol-sayac.network", "konsol-sayac_sayac.container"]))
        unit = plan["units"]["konsol-sayac_sayac.container"]
        self.assertEqual((values(unit, "Container", "Network"), values(unit, "Container", "PublishPort")),
                         (["konsol-sayac.network"], ["127.0.0.1:62100:9000/tcp"]))
        self.assertIn("--network-alias=sayac", values(unit, "Container", "PodmanArgs"))

    def test_only_addresses_are_published_and_only_on_loopback(self):
        definition = definition_of("qbittorrent-compose.yaml")[0]
        plan = render(definition)
        self.assertEqual(plan["publications"], [{"service": "qbittorrent", "port": 8080, "protocol": "tcp", "host_ip": "127.0.0.1",
                                                 "host_port": 62100}])
        unit = plan["units"]["konsol-aktarim_qbittorrent.container"]
        self.assertEqual(values(unit, "Container", "PublishPort"), ["127.0.0.1:62100:8080/tcp"], "raw ports stay closed")
        with self.assertRaisesRegex(GeneratorError, "qbittorrent:8080/tcp"):
            render(definition, ports={})
        two = definition_of("ornek-compose.yaml")[0]
        two["services"][0]["ports"][1]["use"] = CADDY
        with self.assertRaises(GeneratorError):
            render(two, ports={"ornek:8080/tcp": 62100, "ornek:8092/tcp": 62100})
        # A pool port left over from an earlier edit is the engine's business; nothing publishes it.
        extra = render(definition, ports={"qbittorrent:8080/tcp": 62100, "qbittorrent:6881/tcp": 62101})
        self.assertEqual(len(extra["publications"]), 1)


class OrderTests(unittest.TestCase):
    def test_dependencies_start_first_and_stop_last(self):
        definition = compose("""\
            services:
              web:
                image: x
                depends_on: [api]
              cache:
                image: y
              api:
                image: z
                depends_on:
                  cache: {condition: service_started}
                  db: {condition: service_healthy}
              db:
                image: w
                healthcheck: {test: [CMD, pg_isready, -q]}
            """, {"name": "uyg", "answers": {"start:%s" % s: ROOT for s in ("web", "cache", "api", "db")}})
        plan = render(definition)
        self.assertEqual(plan["start"], ["konsol-uyg_cache.service", "konsol-uyg_db.service", "konsol-uyg_api.service",
                                         "konsol-uyg_web.service"])
        self.assertEqual(plan["stop"], list(reversed(plan["start"])))
        api, db = plan["units"]["konsol-uyg_api.container"], plan["units"]["konsol-uyg_db.container"]
        self.assertEqual(values(api, "Unit", "Requires"), ["konsol-uyg_cache.service", "konsol-uyg_db.service"])
        self.assertEqual(values(api, "Unit", "After")[1:], ["konsol-uyg_cache.service", "konsol-uyg_db.service"])
        self.assertEqual((values(db, "Container", "Notify"), values(db, "Service", "TimeoutStartSec")), (["healthy"], ["300"]))
        for name in ("api", "cache", "web"):
            unit = plan["units"]["konsol-uyg_%s.container" % name]
            self.assertEqual((values(unit, "Container", "Notify"), values(unit, "Service", "TimeoutStartSec")), ([], ["180"]))
        self.assertEqual(plan["needs_podman5"], ["api, db servisinin sağlıklı olmasını bekliyor (Notify=healthy)"])

    def test_what_needs_podman_5(self):
        for fixture, needs in (("ornek-compose.yaml", False), ("kasa-compose.yaml", False), ("qbittorrent-compose.yaml", False),
                               ("sayac-deployment.yaml", False), ("notlar-compose.yaml", True), ("notlar-pod.yaml", True)):
            plan = render(definition_of(fixture)[0])
            with self.subTest(fixture=fixture):
                self.assertEqual(bool(plan["needs_podman5"]), needs)
                self.assertIsNone(master_generator.podman5_refusal(plan, (5, 0)))
                refusal = master_generator.podman5_refusal(plan, (4, 9))
                if needs:
                    self.assertTrue(refusal.endswith("Podman 5 gerekir; bu sunucuda 4.9."), refusal)
                    self.assertIn(plan["needs_podman5"][0], refusal)
                else:
                    self.assertIsNone(refusal)
        # The units do not depend on the version: the worker refuses, the generator only says why.
        definition = definition_of("notlar-pod.yaml")[0]
        self.assertEqual(render(definition, podman=(4, 9)), render(definition, podman=(5, 4)))
        for version in ((4, 4), (3, 9), "5.4", (5,), None):
            with self.subTest(version=version), self.assertRaises(GeneratorError):
                render(definition, podman=version)

    def test_waiting_for_a_health_check_that_is_off(self):
        definition = compose("""\
            services:
              web:
                image: x
                depends_on: {db: {condition: service_healthy}}
              db:
                image: y
                healthcheck: {disable: true}
            """, {"name": "uyg", "answers": {"start:web": ROOT, "start:db": ROOT}})
        with self.assertRaisesRegex(GeneratorError, "kapalı"):
            render(definition)


class SecretTests(unittest.TestCase):
    def test_units_name_podman_secrets_and_the_plan_holds_no_value(self):
        definition, secrets = definition_of("notlar-compose.yaml")
        ctx = context(definition)
        plan = master_generator.render(definition, ctx)
        web = plan["units"]["konsol-notlar_web.container"]
        self.assertEqual(values(web, "Container", "Secret"),
                         ["%s,type=env,target=DATABASE_URL" % ctx["secrets"]["notlar-database-url"],
                          "%s,type=env,target=DB_PASSWORD" % ctx["secrets"]["notlar-db-password"]])
        self.assertEqual(podman_env_file(plan["environment"]["web"]), {"LOG_LEVEL": "", "PRICE_NOTE": "$5 per month"})
        dump = json.dumps(plan, ensure_ascii=False)
        for value in secrets.values():
            self.assertNotIn(value, dump)
        self.assertNotIn("notlar-db-password", dump, "logical names stay in the record")
        for broken in ({}, {"notlar-database-url": "obhut_baska_0a1b2c3d", "notlar-db-password": "x"}):
            with self.subTest(secrets=broken), self.assertRaises(GeneratorError):
                render(definition, secrets=broken)

    def test_a_kept_secret_renders_like_a_new_one(self):
        answers = copy.deepcopy(ANSWERS["sayac-deployment.yaml"])
        answers["answers"]["secret:sayac/token"] = {"keep": True}
        definition, secrets = definition_of("sayac-deployment.yaml", answers, frozenset({"sayac-counter-token"}))
        self.assertEqual((secrets, definition["secrets"]), ({}, [{"name": "sayac-counter-token", "services": ["sayac"], "keep": True}]))
        self.assertEqual(golden(render(definition)), golden(render(definition_of("sayac-deployment.yaml")[0])))


class EnvFileTests(unittest.TestCase):
    def definition(self, value):
        definition = definition_of("kasa-compose.yaml")[0]
        definition["services"][0]["environment"] = [{"name": "A", "value": value}, {"name": "B.c-d", "value": "x"}]
        return definition

    def test_values_reach_podman_as_written(self):
        for value in ("", "a=b=c", "# not a comment", ' "quoted" ', "'single'", "$HOME ${X} $$", "back\\slash\\", "  lead",
                      "trail  ", "ünlü ğ ş", "%h %%", "tab\there", "x" * 60000):
            with self.subTest(value=value[:40]):
                text = render(self.definition(value))["environment"]["kasa"]
                self.assertEqual(podman_env_file(text), {"A": value, "B.c-d": "x"})

    def test_a_value_that_breaks_the_line_is_refused(self):
        for value in ("a\nb", "a\r", "a\rb", "a\x00b", "x" * 65534):
            with self.subTest(value=value[:12]), self.assertRaises(GeneratorError):
                render(self.definition(value))
        definition = self.definition("x")
        definition["services"][0]["environment"][0]["name"] = "#A"
        with self.assertRaises(GeneratorError):
            render(definition)


class QuotingTests(unittest.TestCase):
    def unit(self, **fields):
        definition = definition_of("kasa-compose.yaml")[0]
        definition["services"][0].update(fields)
        return render(definition)["units"]["konsol-kasa_kasa.container"]

    def test_commands_reach_podman_as_written(self):
        command = ["sh", "-c", "echo \"$HOME\" 100% \\n;\nexec x", "a b", "tab\tx", "ünlü", "--x='y'", "\x01", "a;b", "$$", "%%"]
        unit = self.unit(command=command)
        self.assertEqual(split_words(values(unit, "Container", "Exec")[0]), command)
        entrypoint = ["/bin/run", "$MODE", "100%"]
        args = values(self.unit(entrypoint=entrypoint), "Container", "PodmanArgs")
        self.assertEqual(json.loads(split_words(args[0]).pop()[len("--entrypoint="):]), entrypoint)
        args = values(self.unit(entrypoint=[]), "Container", "PodmanArgs")
        self.assertEqual(split_words(args[0]), ["--entrypoint=[]"], "an empty entrypoint clears the image's")

    def test_labels_reach_podman_as_written(self):
        unit = self.unit(labels={"org.example.note": "a b $X %h \"q\"", "plain": "v"})
        self.assertEqual([split_words(v)[0] for v in values(unit, "Container", "Label")[2:]],
                         ['org.example.note=a b $X %h "q"', "plain=v"])
        for key in ("io.master-stack.managed", "io.containers.autoupdate", "PODMAN_SYSTEMD_UNIT", "a b", "a=b"):
            with self.subTest(key=key), self.assertRaises(GeneratorError):
                self.unit(labels={key: "x"})

    def test_what_a_unit_cannot_carry(self):
        for command in (["a", ""], ["find", ".", "-exec", "rm", "{}", ";"], ["a\x00"]):
            with self.subTest(command=command), self.assertRaises(GeneratorError):
                self.unit(command=command)
        for workdir in ("/a\nb", '/a"', "/a\\", "/a ", "relative"):
            with self.subTest(workdir=workdir), self.assertRaises(GeneratorError):
                self.unit(workdir=workdir)
        self.assertEqual(systemd(values(self.unit(workdir="/w $X %h"), "Container", "WorkingDir")[0]), "/w $X %h")

    def test_health_checks_as_podman_reads_them(self):
        def health(test, **timing):
            fields = {"interval": None, "timeout": None, "retries": None, "start_period": None}
            fields.update(timing)
            return self.unit(health=dict(fields, test=test))
        cases = [(["CMD", "wget", "-qO-", "http://localhost/ a"], ["CMD", "wget", "-qO-", "http://localhost/ a"]),
                 (["CMD-SHELL", "pg_isready -U $USER || exit 1"], ["CMD-SHELL", "pg_isready -U $USER || exit 1"]),
                 (["CMD-SHELL", '["CMD", "x"]'], ["CMD-SHELL", '["CMD", "x"]']),
                 (["CMD-SHELL", "CMD looks like a keyword\nsecond line"], ["CMD-SHELL", "CMD looks like a keyword\nsecond line"]),
                 (["NONE"], ["NONE"])]
        for test, expected in cases:
            with self.subTest(test=test):
                value = values(health(test), "Container", "HealthCmd")[0]
                self.assertEqual(podman_health(systemd(value)), expected)
        self.assertEqual(values(health([]), "Container", "HealthCmd"), [], "the image's own check")
        unit = health(["CMD", "a", "b"], interval="0", timeout="1m30s", retries=0, start_period="5s")
        self.assertEqual([(k, v) for s, k, v in sections(unit) if k.startswith("Health")],
                         [("HealthCmd", '["a", "b"]'), ("HealthTimeout", "1m30s"), ("HealthStartPeriod", "5s")],
                         "zero is the default, as in Docker")
        with self.assertRaisesRegex(GeneratorError, "tek parçalı"):
            health(["CMD", "/healthcheck"])
        for first in ("cmd", "None", "CMD-SHELL"):
            with self.subTest(first=first), self.assertRaisesRegex(GeneratorError, "kendi sözcüğü"):
                health(["CMD", first, "x"])
        for bad in (dict(timeout="500ms"), dict(interval="often")):
            with self.subTest(bad=bad), self.assertRaises(GeneratorError):
                health(["CMD", "a", "b"], **bad)

    def test_limits_and_stop_settings(self):
        unit = self.unit(stop_signal="SIGINT", stop_grace="1m30.5s", restart="no")
        self.assertEqual([a for a in values(unit, "Container", "PodmanArgs") if a.startswith("--stop")],
                         ["--stop-signal=SIGINT", "--stop-timeout=91"])
        self.assertEqual((values(unit, "Service", "TimeoutStopSec"), values(unit, "Service", "Restart")), (["106"], ["no"]))
        kasa = render(definition_of("kasa-compose.yaml")[0])["units"]["konsol-kasa_kasa.container"]
        self.assertEqual(values(kasa, "Container", "PodmanArgs")[-4:],
                         ["--cpus=0.5", "--memory=268435456", "--ulimit=nofile=20000:40000", "--ulimit=nproc=512:512"])
        self.assertEqual((values(kasa, "Container", "PidsLimit"), values(kasa, "Container", "ShmSize")), (["200"], ["67108864"]))
        for fields in ({"stop_grace": "2h"}, {"stop_signal": "SIG TERM"}, {"restart": "sometimes"},
                       {"limits": {"cpus": 0, "memory": None, "pids": None, "ulimits": {}}},
                       {"limits": {"cpus": None, "memory": 1024, "pids": None, "ulimits": {}}},
                       {"limits": {"cpus": None, "memory": None, "pids": None, "ulimits": {"nofile": {"soft": 1}}}},
                       {"limits": {"cpus": None, "memory": None, "pids": None, "ulimits": {"bogus": {"soft": 1, "hard": 1}}}}):
            with self.subTest(fields=fields), self.assertRaises(GeneratorError):
                self.unit(**fields)


class StoppedTests(unittest.TestCase):
    def test_a_stopped_application_has_no_install_section(self):
        for fixture in ("notlar-compose.yaml", "notlar-pod.yaml"):
            definition = definition_of(fixture)[0]
            running, stopped = render(definition), render(definition, stopped=True)
            for name in running["units"]:
                with self.subTest(fixture=fixture, unit=name):
                    self.assertEqual(values(stopped["units"][name], "Install", "WantedBy"), [])
                    self.assertEqual(values(running["units"][name], "Install", "WantedBy"),
                                     [] if name.endswith(".network") else ["multi-user.target"])
            self.assertEqual({k: v for k, v in running.items() if k != "units"}, {k: v for k, v in stopped.items() if k != "units"})


class RefusedInputTests(unittest.TestCase):
    def test_a_context_that_does_not_fit_the_definition(self):
        definition = definition_of("notlar-compose.yaml")[0]
        ctx = context(definition)
        changes = [{"app": "baska"}, {"stopped": "no"}, {"images": {}},
                   {"images": dict(ctx["images"], web="ghcr.io/example/baska@sha256:" + "a" * 64)},
                   {"images": dict(ctx["images"], web="ghcr.io/example/notlar:1.5")}, {"ports": None}]
        for key in ("SERVER_ROOT", "STATE_FILE", "DOWNLOADS_UID", "KONTEYNER_BRIDGE_PREFIX"):
            changes.append({"env": {k: v for k, v in ENV.items() if k != key}})
        changes += [{"env": dict(ENV, DOWNLOADS_UID="0")}, {"env": dict(ENV, SBIN_DIR="/usr/local/../sbin")},
                    {"env": dict(ENV, UYGULAMA_STATE_DIR="relative")}, {"env": dict(ENV, KONTEYNER_BRIDGE_PREFIX="kslong")}]
        for change in changes:
            with self.subTest(change=str(change)[:80]), self.assertRaises(GeneratorError):
                master_generator.render(definition, dict(ctx, **change))

    def test_a_malformed_definition_fails_closed(self):
        definition = definition_of("notlar-compose.yaml")[0]
        for change in (lambda d: d.update(format="swarm"), lambda d: d.update(services=[]),
                       lambda d: d["services"].append(copy.deepcopy(d["services"][0])),
                       lambda d: d["services"][0].update(start="privileged"),
                       lambda d: d["services"][0].update(depends_on=[{"service": "yok", "condition": "started"}]),
                       lambda d: d["services"][0]["mounts"][0].update(to="host"),
                       lambda d: d["services"][0]["mounts"][0].update(folder="../x"),
                       lambda d: d["services"][0]["ports"][0].update(protocol="sctp"),
                       lambda d: d["services"][0].update(caps_add=["NET_ADMIN"]),
                       lambda d: d["services"][1].update(caps_drop=["SYS_ADMIN"]),
                       lambda d: d["services"][0].update(environment=[{"name": "A"}]),
                       lambda d: d["services"][0].pop("mounts") and d["services"][0].update(mounts=5)):
            broken = copy.deepcopy(definition)
            change(broken)
            with self.subTest(change=change), self.assertRaises(GeneratorError):
                master_generator.render(broken, context(definition))
        with self.assertRaises(GeneratorError):
            master_generator.render(None, {})


if __name__ == "__main__":
    if "--yaz" in sys.argv[1:]:
        write_golden()
    else:
        unittest.main()
