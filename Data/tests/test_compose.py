"""DD-271 (phase 2): the Compose reader (master_compose). The model it builds from the acceptance fixtures,
every supported form of the keys rebuild.md 4.2 lists, the interpolation rules, and a refusal with its
line for everything else: nothing is skipped silently."""
from pathlib import Path
import sys
import textwrap
import unittest

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_compose  # noqa: E402
import master_yaml  # noqa: E402

FIXTURES = DATA / "tests" / "fixtures" / "uygulama"


def read(text):
    return master_compose.read(master_yaml.load_all(textwrap.dedent(text)))


def service(text, name="app"):
    """A one-service file: text is the service's body, indented under it."""
    body = textwrap.indent(textwrap.dedent(text), "    ")
    return read("services:\n  %s:\n    image: docker.io/library/nginx:1.27\n%s" % (name, body))


def refused(model):
    return [(r["line"], r["key"]) for r in model["refusals"]]


class FixtureTests(unittest.TestCase):
    def test_a_published_file_with_named_volumes(self):
        model = read((FIXTURES / "ornek-compose.yaml").read_text())
        self.assertEqual(model["refusals"], [])
        self.assertEqual((model["format"], model["name"], model["pod"]), ("compose", "ornek", False))
        (svc,) = model["services"]
        self.assertEqual((svc["name"], svc["line"], svc["image"], svc["image_line"]), ("ornek", 10, "registry.example/ornek/sunucu:2", 11))
        self.assertEqual(svc["restart"], "unless-stopped")
        self.assertEqual(svc["ports"], [{"port": 8080, "protocol": "tcp", "host_port": 8080, "line": 15},
                                        {"port": 8092, "protocol": "tcp", "host_port": 8092, "line": 18}])
        self.assertEqual(svc["environment"], [{"name": "ORNEK_EK_PORT", "value": "8092", "line": 20, "secret_ref": False,
                                               "secret_key": None}])
        self.assertEqual(svc["mounts"], [
            {"kind": "named", "source": "ornek-db", "target": "/database", "read_only": False, "line": 22},
            {"kind": "named", "source": "ornek-config", "target": "/config", "read_only": False, "line": 23},
            {"kind": "absolute", "source": "/path/to/your/files", "target": "/srv", "read_only": False, "line": 24}])
        self.assertEqual((svc["user"], svc["health"], svc["command"], svc["caps_add"]), (None, None, None, []))
        self.assertIn((12, "container_name"), [(n["line"], n["key"]) for n in model["notes"]])
        self.assertEqual(model["variables"], [])

    def test_the_linuxserver_qbittorrent_file(self):
        model = read((FIXTURES / "qbittorrent-compose.yaml").read_text())
        self.assertEqual(model["refusals"], [])
        (svc,) = model["services"]
        self.assertEqual(model["name"], "qbittorrent")
        # Unquoted 8080:8080 is text under YAML 1.2, not a base-60 number.
        self.assertEqual([(p["port"], p["protocol"], p["host_port"]) for p in svc["ports"]],
                         [(8080, "tcp", 8080), (6881, "tcp", 6881), (6881, "udp", 6881)])
        self.assertEqual([(e["name"], e["value"]) for e in svc["environment"]],
                         [("PUID", "1000"), ("PGID", "1000"), ("TZ", "Etc/UTC"), ("WEBUI_PORT", "8080"), ("TORRENTING_PORT", "6881")])
        self.assertEqual([(m["kind"], m["source"], m["target"]) for m in svc["mounts"]],
                         [("absolute", "/path/to/qbittorrent/appdata", "/config"), ("absolute", "/path/to/downloads", "/downloads")])

    def test_a_web_application_with_its_database(self):
        model = read((FIXTURES / "notlar-compose.yaml").read_text())
        self.assertEqual(model["refusals"], [])
        self.assertEqual(model["name"], "notlar")
        web, db = model["services"]
        self.assertEqual(web["image"], "ghcr.io/example/notlar:${NOTLAR_VERSION:-1.4}", "strings stay as written")
        self.assertEqual(web["user"], "1000:1000")
        self.assertEqual(web["command"], ["serve", "--listen", "0.0.0.0:3000", "--base", "${BASE_URL:-http://notlar.example}"])
        self.assertEqual(web["depends_on"], [{"service": "db", "condition": "healthy"}])
        self.assertEqual(web["health"], {"test": ["CMD", "wget", "-qO-", "http://localhost:3000/health"], "interval": "30s",
                                         "timeout": "5s", "retries": 3, "start_period": "20s"})
        self.assertEqual(web["labels"], {"org.example.role": "web"})
        self.assertEqual([(m["kind"], m["source"], m["target"], m["read_only"]) for m in web["mounts"]],
                         [("relative", "./uploads", "/app/uploads", False), ("absolute", "/srv/media/notlar", "/media/notlar", True)])
        self.assertEqual(db["health"]["test"], ["CMD-SHELL", "pg_isready -U notlar"])
        self.assertEqual(db["stop_grace"], "1m30s")
        self.assertEqual([(m["kind"], m["target"]) for m in db["mounts"]],
                         [("named", "/var/lib/postgresql/data"), ("tmpfs", "/run/postgresql")])
        variables = {v["name"]: v for v in model["variables"]}
        self.assertEqual(list(variables), ["NOTLAR_VERSION", "BASE_URL", "DB_PASSWORD", "LOG_LEVEL"])
        self.assertEqual((variables["DB_PASSWORD"]["required"], variables["DB_PASSWORD"]["default"]), (True, None))
        self.assertEqual(variables["LOG_LEVEL"]["default"], "info")
        self.assertEqual([(u["service"], u["field"]) for u in variables["DB_PASSWORD"]["uses"]],
                         [("web", "environment"), ("web", "environment"), ("db", "environment")])
        self.assertEqual([(u["service"], u["field"]) for u in variables["NOTLAR_VERSION"]["uses"]], [("web", "image")])
        self.assertIn("x-backup", [n["key"] for n in model["notes"]])
        self.assertIn("x-note", [n["key"] for n in model["notes"]])

    def test_the_unsafe_file_stops_at_every_line(self):
        model = read((FIXTURES / "unsafe-compose.yaml").read_text())
        self.assertEqual(refused(model), [(5, "privileged"), (6, "network_mode"), (7, "pid"), (10, "cap_add"), (12, "volumes"),
                                          (13, "volumes"), (14, "volumes"), (17, "runtime")])
        texts = " ".join(r["text"] for r in model["refusals"])
        for word in ("NET_ADMIN", "soketi", "kök dizini", "/etc/master-stack", "runtime"):
            self.assertIn(word, texts)
        self.assertEqual(model["services"][0]["caps_add"], ["CHOWN"])


class HardeningAndLimitTests(unittest.TestCase):
    """The coordinator's phase 2 decision: common harmless keys are read, not refused."""

    def test_the_hardened_fixture_reads_without_a_refusal(self):
        model = read((FIXTURES / "kasa-compose.yaml").read_text())
        self.assertEqual(model["refusals"], [])
        kasa, yedek = model["services"]
        self.assertEqual((kasa["hostname"], kasa["init"], kasa["read_only"], kasa["shm_size"], kasa["caps_drop"],
                          kasa["no_new_privileges"], kasa["restart"]),
                         ("kasa", True, True, 64 * 2 ** 20, ["ALL"], True, "on-failure"))
        self.assertEqual(kasa["limits"], {"cpus": 0.5, "memory": 256 * 2 ** 20, "pids": 200,
                                          "ulimits": {"nofile": {"soft": 20000, "hard": 40000}, "nproc": {"soft": 512, "hard": 512}}})
        self.assertEqual((yedek["init"], yedek["caps_drop"], yedek["no_new_privileges"], yedek["restart"]),
                         (False, ["SETFCAP", "KILL"], True, "unless-stopped"))
        self.assertEqual(yedek["limits"], {"cpus": 0.25, "memory": 128 * 2 ** 20, "pids": None, "ulimits": {}})
        noted = [n["key"] for n in model["notes"]]
        for key in ("security_opt", "reservations", "max_attempts", "logging", "tty", "stdin_open", "platform", "pull_policy"):
            self.assertIn(key, noted)

    def test_values_of_the_new_keys(self):
        good = {
            "hostname: Web-1\n": ("hostname", "Web-1"),
            "shm_size: 1073741824\n": ("shm_size", 2 ** 30),
            "shm_size: 1.5g\n": ("shm_size", int(1.5 * 2 ** 30)),
            "shm_size: 64MiB\n": ("shm_size", 64 * 2 ** 20),
            "cap_drop: [all]\n": ("caps_drop", ["ALL"]),
            "cap_drop: [CAP_KILL, kill, ALL, CHOWN]\n": ("caps_drop", ["ALL"]),
            "security_opt: ['no-new-privileges=true']\n": ("no_new_privileges", True),
        }
        for text, (field, value) in good.items():
            with self.subTest(text=text):
                model = service(text)
                self.assertEqual(model["refusals"], [])
                self.assertEqual(model["services"][0][field], value)
        limits = {
            "mem_limit: 512\n": {"memory": 512}, "mem_limit: 2g\n": {"memory": 2 * 2 ** 30}, "cpus: '1.5'\n": {"cpus": 1.5},
            "cpus: 2\n": {"cpus": 2}, "pids_limit: 100\n": {"pids": 100},
            "deploy:\n  resources:\n    limits: {cpus: '0.5', memory: 1G, pids: 50}\n": {"cpus": 0.5, "memory": 2 ** 30, "pids": 50},
            "mem_limit: 1g\ndeploy:\n  resources:\n    limits: {memory: 1024M}\n": {"memory": 2 ** 30},
            "ulimits:\n  memlock: {soft: -1, hard: -1}\n  core: 0\n": {"ulimits": {"memlock": {"soft": -1, "hard": -1},
                                                                                  "core": {"soft": 0, "hard": 0}}},
        }
        for text, value in limits.items():
            with self.subTest(text=text):
                model = service(text)
                self.assertEqual(model["refusals"], [])
                expected = dict({"cpus": None, "memory": None, "pids": None, "ulimits": {}}, **value)
                self.assertEqual(model["services"][0]["limits"], expected)
        self.assertEqual(service("pids_limit: -1\n")["services"][0]["limits"]["pids"], None)
        self.assertEqual(service("deploy:\n  restart_policy: {condition: none}\n")["services"][0]["restart"], "no")
        self.assertEqual(service("deploy:\n  restart_policy: {}\n")["services"][0]["restart"], "always")
        self.assertEqual(service("restart: always\ndeploy:\n  restart_policy: {condition: any}\n")["refusals"], [])
        model = service("deploy:\n  mode: replicated\n  replicas: 1\n  placement: {}\n  update_config: {}\n  labels: {a: b}\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual([n["key"] for n in model["notes"]], ["mode", "placement", "update_config", "labels"])

    def test_refused_values_of_the_new_keys(self):
        bad = ["hostname: -web\n", "hostname: a.b\n", "hostname: %s\n" % ("h" * 64), "hostname: 5\n", "init: yes\n",
               "read_only: 1\n", "shm_size: lots\n", "shm_size: 0\n", "shm_size: '%s'\n" % ("9" * 20), "cap_drop: [NET_RAW]\n",
               "cap_drop: [NET_ADMIN]\n", "cap_drop: KILL\n", "cap_add: [KILL]\ncap_drop: [KILL]\n",
               "security_opt: ['seccomp:unconfined']\n", "security_opt: ['apparmor:unconfined']\n",
               "security_opt: ['label:disable']\n", "security_opt: ['no-new-privileges:false']\n", "security_opt: x\n",
               "ulimits: {nofile: {soft: 10, hard: 5}}\n", "ulimits: {nofile: {soft: 10}}\n", "ulimits: {bogus: 1}\n",
               "ulimits: {nofile: -2}\n", "ulimits: {nofile: {soft: -1, hard: 5}}\n", "ulimits: [nofile]\n",
               "pids_limit: many\n", "mem_limit: lots\n", "mem_limit: 0\n", "cpus: 0\n", "cpus: -1\n", "cpus: abc\n",
               "cpus: true\n", "mem_limit: 1g\ndeploy:\n  resources:\n    limits: {memory: 2g}\n",
               "cpus: 1\ndeploy:\n  resources:\n    limits: {cpus: '2'}\n", "deploy:\n  replicas: 2\n", "deploy:\n  replicas: 0\n",
               "deploy:\n  replicas: true\n", "deploy:\n  scale: 1\n", "deploy: []\n",
               "deploy:\n  resources:\n    limits: {gpus: 1}\n", "deploy:\n  resources:\n    devices: []\n",
               "deploy:\n  resources:\n    limits: {memory: much}\n", "deploy:\n  restart_policy: {condition: sometimes}\n",
               "restart: no\ndeploy:\n  restart_policy: {condition: on-failure}\n"]
        for text in bad:
            with self.subTest(text=text):
                self.assertEqual(len(service(text)["refusals"]), 1, service(text)["refusals"])

    def test_a_mapping_where_text_belongs_is_a_refusal(self):
        self.assertEqual(len(service("deploy:\n  restart_policy: {condition: {a: 1}}\n")["refusals"]), 1)

    def test_the_still_refused_keys_name_why(self):
        for key in ("dns", "dns_search", "extra_hosts", "group_add", "links", "external_links", "domainname", "mac_address",
                    "devices", "privileged", "network_mode", "pid", "ipc", "volumes_from", "env_file", "build", "extends",
                    "profiles", "secrets", "configs", "sysctls"):
            with self.subTest(key=key):
                self.assertIn(key, master_compose.SERVICE_REFUSED)
        self.assertNotIn("security_opt", master_compose.SERVICE_REFUSED)

    def test_sizes_and_cpus(self):
        self.assertEqual([master_compose.size_bytes(v) for v in ("100", "100b", "1k", "1KB", "1kib", "2.5m", 7, 0, "1x", True)],
                         [100, 100, 1024, 1024, 1024, int(2.5 * 2 ** 20), 7, None, None, None])
        self.assertEqual([master_compose.cpu_count(v) for v in (0.5, "0.50", 3, "3.0", 0, "-1", 1e9)], [0.5, 0.5, 3, 3, None, None, None])


class TopLevelTests(unittest.TestCase):
    def test_top_level_keys(self):
        model = read("""\
            version: "3.9"
            name: Örnek Uygulama
            x-common: {a: 1}
            networks:
              front: {}
            services:
              web:
                image: nginx
            """)
        self.assertEqual(model["refusals"], [])
        self.assertEqual(model["name"], "ornek-uygulama")
        self.assertEqual(sorted(n["key"] for n in model["notes"]), ["networks", "version", "x-common"])
        model = read("""\
            services:
              web: {image: nginx}
            secrets:
              s: {file: ./s.txt}
            configs:
              c: {file: ./c}
            include:
              - other.yaml
            profiles: [x]
            """)
        self.assertEqual(refused(model), [(3, "secrets"), (5, "configs"), (7, "include"), (9, "profiles")])

    def test_services_must_be_a_non_empty_mapping_in_a_single_document(self):
        self.assertEqual(refused(read("services:\n")), [(1, "services")])
        self.assertEqual(refused(read("services: []\n")), [(1, "services")])
        self.assertEqual(refused(read("services:\n  web:\n")), [(2, "web")])
        self.assertEqual(refused(read("services:\n  'bad name':\n    image: x\n")), [(2, "services")])
        self.assertEqual(refused(read("services:\n  web: {image: x}\n---\nservices:\n  db: {image: y}\n")), [(4, "---")])

    def test_the_name_falls_back_to_the_first_service(self):
        self.assertEqual(read("name: ${PROJECT}\nservices:\n  Web_1:\n    image: x\n")["name"], "web-1")
        self.assertEqual(read("name: '123'\nservices:\n  db:\n    image: x\n")["name"], "db")
        self.assertEqual(read("services:\n  '1':\n    image: x\n")["name"], "")
        self.assertEqual(master_compose.app_name("Çok Güzel İşler Şirketi ve uzun bir ad daha"), "cok-guzel-isler-sirketi-ve-uzu")

    def test_named_volumes_must_be_declared_and_plain(self):
        model = read("""\
            services:
              web:
                image: x
                volumes: [data:/data, other:/other]
            volumes:
              data:
                driver: local
                name: custom
                labels: {a: b}
                x-meta: 1
              ext:
                external: true
              opts:
                driver_opts: {type: none, o: bind, device: /etc}
              rem:
                driver: rexray
            """)
        self.assertEqual(refused(model), [(12, "external"), (14, "driver_opts"), (16, "driver"), (4, "volumes")])
        self.assertIn("Tanımlanmamış birim: other", model["refusals"][-1]["text"])
        self.assertEqual(model["services"][0]["mounts"][0]["source"], "data")


class ServiceKeyTests(unittest.TestCase):
    def test_every_refused_service_key(self):
        for key in master_compose.SERVICE_REFUSED:
            with self.subTest(key=key):
                model = service("%s: value\n" % key)
                self.assertEqual(refused(model), [(4, key)])
                self.assertEqual(model["refusals"][0]["text"], master_compose.SERVICE_REFUSED[key])

    def test_unknown_keys_are_refused_and_x_keys_noted(self):
        for key in ("mem_reservation", "memswap_limit", "cpu_shares", "oom_kill_disable", "userns_mode", "cgroup_parent",
                    "runtime", "storage_opt", "isolation", "cpuset"):
            with self.subTest(key=key):
                model = service("%s: value\n" % key)
                self.assertEqual(refused(model), [(4, key)])
                self.assertIn("Desteklenmeyen anahtar: %s" % key, model["refusals"][0]["text"])
        model = service("x-anything: {nested: 1}\ncontainer_name: x\nexpose: ['80']\nnetworks: [front]\nprivileged: false\n"
                        "tty: true\nstdin_open: true\nlogging: {driver: none}\nplatform: linux/arm64\npull_policy: missing\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual([n["key"] for n in model["notes"]], ["x-anything", "container_name", "expose", "networks", "privileged",
                                                             "tty", "stdin_open", "logging", "platform", "pull_policy"])

    def test_network_aliases_are_refused(self):
        self.assertEqual(refused(service("networks:\n  default:\n    aliases: [database]\n")), [(4, "networks")])

    def test_image_user_workdir_restart_and_stop(self):
        svc = service("user: 1000\nworking_dir: /app\nrestart: on-failure:3\nstop_signal: SIGINT\nstop_grace_period: 20\n")
        self.assertEqual(svc["refusals"], [])
        s = svc["services"][0]
        self.assertEqual((s["user"], s["workdir"], s["restart"], s["stop_signal"], s["stop_grace"]),
                         ("1000", "/app", "on-failure", "SIGINT", "20s"))
        for text, key in (("restart: sometimes\n", "restart"), ("restart: false\n", "restart"), ("working_dir: app\n", "working_dir"),
                          ("user: true\n", "user"), ("user: 'a b'\n", "user"), ("stop_signal: 'kill -9'\n", "stop_signal"),
                          ("stop_grace_period: soon\n", "stop_grace_period"), ("stop_grace_period: ${GRACE}\n", "stop_grace_period")):
            with self.subTest(text=text):
                self.assertEqual([k for _l, k in refused(service(text))], [key])
        self.assertEqual(refused(read("services:\n  a:\n    image: 'two words'\n")), [(3, "image")])
        self.assertEqual(read("services:\n  a:\n    user: '1'\n")["services"][0]["image"], "", "the inspector refuses it")

    def test_command_and_entrypoint(self):
        s = service("""\
            entrypoint: /docker-entrypoint.sh
            command: run --name "my app" --flag='a b' ${ARGS}
            """)["services"][0]
        self.assertEqual(s["entrypoint"], ["/docker-entrypoint.sh"])
        self.assertEqual(s["command"], ["run", "--name", "my app", "--flag=a b", "${ARGS}"])
        for text in ("npm start && node x", "a | b", "a; b", "a > out", "echo `date`", 'sh -c "x" ; y', "a & b"):
            with self.subTest(text=text):
                s = service("command: %r\n" % text)["services"][0]
                self.assertEqual(s["command"], ["/bin/sh", "-c", text])
        self.assertEqual(service("command: 'sh -c \"a && b\"'\n")["services"][0]["command"], ["sh", "-c", "a && b"])
        self.assertEqual(service("command: [sleep, 3600, 1.5]\n")["services"][0]["command"], ["sleep", "3600", "1.5"])
        self.assertEqual(service("entrypoint: []\n")["services"][0]["entrypoint"], [])
        self.assertEqual(service("command: |\n  echo one\n  echo two\n")["services"][0]["command"][:2], ["/bin/sh", "-c"])
        self.assertEqual(refused(service("command: 'echo \"open'\n")), [(4, "command")])
        self.assertEqual(refused(service("command: [a, [b]]\n")), [(4, "command")])
        self.assertEqual(refused(service("command: {a: b}\n")), [(4, "command")])
        self.assertEqual(refused(service("command: [a, true]\n")), [(4, "command")])

    def test_environment_list_and_map(self):
        s = service("""\
            environment:
              - A=1
              - B=x=y
              - FROM_HOST
              - EMPTY=
            """)["services"][0]
        self.assertEqual([(e["name"], e["value"], e["line"]) for e in s["environment"]],
                         [("A", "1", 5), ("B", "x=y", 6), ("FROM_HOST", "${FROM_HOST}", 7), ("EMPTY", "", 8)])
        model = service("""\
            environment:
              NUM: 5
              FLAG: true
              FLOAT: 1.5
              UNSET:
              QUOTED: "007"
              Dotted.Name-1: x
            """)
        self.assertEqual(model["refusals"], [])
        self.assertEqual([(e["name"], e["value"]) for e in model["services"][0]["environment"]],
                         [("NUM", "5"), ("FLAG", "true"), ("FLOAT", "1.5"), ("UNSET", "${UNSET}"), ("QUOTED", "007"),
                          ("Dotted.Name-1", "x")])
        self.assertEqual([v["name"] for v in model["variables"]], ["UNSET"])
        for text in ("environment:\n  - A=1\n  - A=2\n", "environment:\n  - 5\n", "environment:\n  '1A': x\n",
                     "environment:\n  - bad.name\n", "environment: text\n", "environment:\n  A: [1]\n"):
            with self.subTest(text=text):
                self.assertEqual([k for _l, k in refused(service(text))], ["environment"])

    def test_labels(self):
        s = service("labels:\n  - a=1\n  - b\n")["services"][0]
        self.assertEqual(s["labels"], {"a": "1", "b": ""})
        s = service("labels:\n  com.example.x: 2\n  empty:\n")["services"][0]
        self.assertEqual(s["labels"], {"com.example.x": "2", "empty": ""})
        for label in ("io.containers.autoupdate", "io.podman.annotations.x", "PODMAN_SYSTEMD_UNIT",
                      "io.master-stack.managed", "io.master-stack.uygulama"):
            with self.subTest(label=label):
                model = service("labels:\n  %s: registry\n" % label)
                self.assertEqual(refused(model), [(5, "labels")])
                self.assertEqual(model["services"][0]["labels"], {})
        # Obhut's own labels say who owns a container; the refusal names them as Obhut's.
        self.assertIn("Obhut", service("labels:\n  - io.master-stack.managed=uygulama\n")["refusals"][0]["text"])
        self.assertEqual(refused(service("labels:\n  - a=1\n  - a=2\n")), [(6, "labels")])

    def test_capabilities_from_the_default_set_only(self):
        s = service("cap_add: [chown, CAP_NET_BIND_SERVICE, SETUID, SETUID]\n")
        self.assertEqual(s["refusals"], [])
        self.assertEqual(s["services"][0]["caps_add"], ["CHOWN", "NET_BIND_SERVICE", "SETUID"])
        for cap in ("NET_ADMIN", "SYS_ADMIN", "ALL", "NET_RAW", "SYS_PTRACE", "MKNOD"):
            with self.subTest(cap=cap):
                self.assertEqual(refused(service("cap_add: [%s]\n" % cap)), [(4, "cap_add")])
        self.assertEqual(refused(service("cap_add: NET_ADMIN\n")), [(4, "cap_add")])
        self.assertEqual(refused(service("cap_add: ['1x']\n")), [(4, "cap_add")])

    def test_dependencies(self):
        model = read("""\
            services:
              web:
                image: x
                depends_on: [db, cache]
              db:
                image: y
                depends_on:
                  cache:
                    condition: service_healthy
                    restart: true
              cache:
                image: z
            """)
        self.assertEqual(model["refusals"], [])
        web, db, _cache = model["services"]
        self.assertEqual(web["depends_on"], [{"service": "db", "condition": "started"}, {"service": "cache", "condition": "started"}])
        self.assertEqual(db["depends_on"], [{"service": "cache", "condition": "healthy"}])
        bad = {
            "depends_on: [nope]\n": "Tanımlı olmayan servis",
            "depends_on: [app]\n": "kendine",
            "depends_on:\n  b:\n    condition: service_completed_successfully\n": "biten",
            "depends_on:\n  b:\n    condition: whenever\n": "Bilinmeyen",
            "depends_on: [b, b]\n": "iki kez",
            "depends_on: b\n": "liste",
        }
        for text, word in bad.items():
            with self.subTest(text=text):
                body = textwrap.indent(text, "    ")
                model = read("services:\n  app:\n    image: x\n%s  b:\n    image: y\n" % body)
                self.assertTrue(model["refusals"], text)
                self.assertIn(word, model["refusals"][0]["text"])
        cycle = read("services:\n  a:\n    image: x\n    depends_on: [b]\n  b:\n    image: y\n    depends_on: [a]\n")
        self.assertIn("döngü", cycle["refusals"][0]["text"])
        # A long chain is no problem (no recursion).
        chain = "services:\n" + "".join("  s%d:\n    image: x\n    depends_on: [s%d]\n" % (i, i + 1) for i in range(2000)) \
            + "  s2000:\n    image: x\n"
        self.assertEqual(read(chain)["refusals"], [])

    def test_health_checks(self):
        cases = {
            "healthcheck:\n  test: curl -f http://localhost/\n": ["CMD-SHELL", "curl -f http://localhost/"],
            "healthcheck:\n  test: [CMD-SHELL, 'true']\n  retries: 0\n": ["CMD-SHELL", "true"],
            "healthcheck:\n  interval: 1m\n": [],
        }
        for text, test in cases.items():
            with self.subTest(text=text):
                model = service(text)
                self.assertEqual(model["refusals"], [])
                self.assertEqual(model["services"][0]["health"]["test"], test)
        for text in ("healthcheck:\n  test: [NONE]\n", "healthcheck:\n  disable: true\n  test: [CMD, x]\n"):
            with self.subTest(text=text):
                model = service(text)
                # NONE turns the image's own check off too (None would keep it).
                self.assertEqual(model["services"][0]["health"], {"test": ["NONE"], "interval": None, "timeout": None,
                                                                  "retries": None, "start_period": None})
                self.assertIn("kapalı", model["notes"][-1]["text"])
        for text in ("healthcheck:\n  test: [curl, x]\n", "healthcheck:\n  test: [CMD]\n", "healthcheck:\n  test: []\n",
                     "healthcheck:\n  test: [CMD, x]\n  interval: often\n", "healthcheck:\n  test: [CMD, x]\n  retries: many\n",
                     "healthcheck:\n  test: [CMD, x]\n  disable: yes\n", "healthcheck:\n  test: [CMD, x]\n  probe: 1\n",
                     "healthcheck: curl\n"):
            with self.subTest(text=text):
                self.assertTrue(service(text)["refusals"])
        self.assertEqual(service("healthcheck:\n  test: [CMD, x]\n  start_interval: 5s\n")["notes"][-1]["key"], "start_interval")


class PortTests(unittest.TestCase):
    def ports(self, items):
        model = service("ports:\n" + "".join("  - %s\n" % item for item in items))
        return model, [(p["port"], p["protocol"], p["host_port"]) for p in model["services"][0]["ports"]]

    def test_short_syntax(self):
        model, ports = self.ports(["80", "8080:80", "127.0.0.1:8081:81", "127.0.0.1::82", "'[::1]:8083:83'", "53:53/udp",
                                   "54/TCP", "${WEB_PORT:-8090}:90", "1000"])
        self.assertEqual(model["refusals"], [])
        self.assertEqual(ports, [(80, "tcp", None), (80, "tcp", 8080), (81, "tcp", 8081), (82, "tcp", None),
                                 (83, "tcp", 8083), (53, "udp", 53), (54, "tcp", None), (90, "tcp", None), (1000, "tcp", None)])
        self.assertEqual(model["variables"], [], "a variable on the host side is never used")
        self.assertIn("127.0.0.1:8081", " ".join(n["text"] for n in model["notes"]))

    def test_long_syntax(self):
        model = service("""\
            ports:
              - target: 80
                published: "8080"
                host_ip: 127.0.0.1
                protocol: udp
                mode: host
                name: web
                x-k: 1
              - target: "81"
            """)
        self.assertEqual(model["refusals"], [])
        self.assertEqual([(p["port"], p["protocol"], p["host_port"]) for p in model["services"][0]["ports"]],
                         [(80, "udp", 8080), (81, "tcp", None)])
        for text in ("ports:\n  - published: 80\n", "ports:\n  - target: 80\n    protocol: sctp\n",
                     "ports:\n  - target: 80\n    extra: 1\n", "ports:\n  - target: ${P}\n", "ports:\n  - target: [1]\n"):
            with self.subTest(text=text):
                self.assertTrue(service(text)["refusals"])

    def test_refused_ports(self):
        for item in ("8000-8010:8000-8010", "8000-8010", "9000-9001:80", "80/sctp", "0", "65536", "a:b:c:d", "8080:${PORT}",
                     "'[::1]8080'", "true", "{target: [x]}", "abc"):
            with self.subTest(item=item):
                model, ports = self.ports([item])
                self.assertEqual(len(model["refusals"]), 1, item)
                self.assertEqual(ports, [])
        self.assertIn("aralığı", self.ports(["8000-8010"])[0]["refusals"][0]["text"])


class MountTests(unittest.TestCase):
    def mounts(self, items, top="volumes:\n  data:\n"):
        body = "volumes:\n" + "".join("  - %s\n" % item for item in items)
        model = read("services:\n  app:\n    image: x\n%s%s" % (textwrap.indent(body, "    "), top))
        return model, [(m["kind"], m["source"], m["target"], m["read_only"]) for m in model["services"][0]["mounts"]]

    def test_short_syntax(self):
        model, mounts = self.mounts(["data:/data", "./conf:/conf:ro", "/srv/media:/media:ro,z", "/opt/app/:/opt/app/:rw",
                                     "/anon", "${DATA_DIR:-./d}:/d", "${CONF}:/c"])
        self.assertEqual(model["refusals"], [])
        self.assertEqual(mounts, [("named", "data", "/data", False), ("relative", "./conf", "/conf", True),
                                  ("absolute", "/srv/media", "/media", True), ("absolute", "/opt/app/", "/opt/app", False),
                                  ("named", "", "/anon", False), ("relative", "${DATA_DIR:-./d}", "/d", False),
                                  ("absolute", "${CONF}", "/c", False)])
        self.assertEqual(model["variables"], [], "a host source is never used, so its variables are not asked")

    def test_long_syntax(self):
        model = read("""\
            services:
              app:
                image: x
                volumes:
                  - type: volume
                    source: data
                    target: /data
                    volume: {nocopy: true}
                  - type: bind
                    source: conf
                    target: /conf
                    read_only: true
                    bind: {create_host_path: true, selinux: z, propagation: rprivate}
                  - type: tmpfs
                    target: /tmp
                    tmpfs: {size: 1000}
                  - type: volume
                    target: /anon
            volumes:
              data:
            """)
        self.assertEqual(model["refusals"], [])
        self.assertEqual([(m["kind"], m["source"], m["target"], m["read_only"]) for m in model["services"][0]["mounts"]],
                         [("named", "data", "/data", False), ("relative", "conf", "/conf", True), ("tmpfs", "", "/tmp", False),
                          ("named", "", "/anon", False)])

    def test_tmpfs_key(self):
        model = service("tmpfs:\n  - /run\n  - /tmp:size=64m\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual([(m["kind"], m["target"]) for m in model["services"][0]["mounts"]], [("tmpfs", "/run"), ("tmpfs", "/tmp")])
        self.assertEqual(service("tmpfs: /run\n")["services"][0]["mounts"][0]["target"], "/run")
        self.assertTrue(service("tmpfs: {a: 1}\n")["refusals"])
        self.assertTrue(service("tmpfs: [run]\n")["refusals"])

    def test_system_paths_and_engine_sockets_are_refused(self):
        sources = ["/", "/etc", "/etc/ssl/certs", "/proc", "/sys/fs", "/dev/sda", "/boot", "/root/.ssh", "/usr/lib", "/bin",
                   "/sbin", "/lib/modules", "/lib64", "/run/user", "/var/run", "/var/lib/containers/storage",
                   "/var/lib/master-stack/uygulamalar/x", "/etc/master-stack", "/home/u/.docker/run/docker.sock",
                   "/run/podman/podman.sock", "/srv/containerd.sock", "//etc", "/srv/../etc", "/etc/", "${X:-/etc}"]
        for source in sources:
            with self.subTest(source=source):
                model, mounts = self.mounts(["%s:/x" % source])
                self.assertEqual([k for _l, k in refused(model)], ["volumes"])
                self.assertEqual(mounts, [])
        self.assertIn("/var/lib/master-stack", self.mounts(["/var/lib/master-stack:/x"])[0]["refusals"][0]["text"])
        for source in ("/srv", "/srv/media", "/home/u/media", "/opt/x", "/mnt/disk", "/var/lib/other", "/etcetera", "/tmp/x"):
            with self.subTest(source=source):
                self.assertEqual(self.mounts(["%s:/x" % source])[0]["refusals"], [])

    def test_refused_mounts(self):
        items = ["~/data:/x", "../up:/x", "./a/../../b:/x", "undeclared:/x", "data:relative", "data:/", "data:/a/../b",
                 "data:/x:rshared", "data:/x:ro:extra", ":/x", "data:${T}", "'{type: npipe, source: x, target: /x}'"]
        for item in items:
            with self.subTest(item=item):
                model, mounts = self.mounts([item])
                self.assertEqual(len(model["refusals"]), 1, model["refusals"])
                self.assertEqual(mounts, [])
        model, _mounts = self.mounts(["data:/x", "./y:/x"])
        self.assertIn("iki bağlama", model["refusals"][0]["text"])
        long_cases = [
            "{type: bind, target: /x}", "{type: tmpfs, source: a, target: /x}", "{type: volume, source: ./p, target: /x}",
            "{type: bind, source: data2, target: /x, bind: {propagation: rshared}}", "{type: volume, source: data, target: /x, volume: {subpath: a}}",
            "{type: volume, source: data, target: /x, read_only: 1}", "{type: volume, source: data, target: /x, other: 1}",
            "{type: bind, source: /etc, target: /x}", "{type: volume, source: data}",
        ]
        for item in long_cases:
            with self.subTest(item=item):
                self.assertEqual(len(self.mounts([item])[0]["refusals"]), 1, item)


class InterpolationTests(unittest.TestCase):
    def test_template_parts(self):
        parts = master_compose.template_parts("a$$b${X}c$Y_1-${Z:-d e}${W-}${R:?need it}${Q?}$$")
        self.assertEqual(parts, ["a$b", {"name": "X", "op": "", "arg": None}, "c", {"name": "Y_1", "op": "", "arg": None}, "-",
                                 {"name": "Z", "op": ":-", "arg": "d e"}, {"name": "W", "op": "-", "arg": ""},
                                 {"name": "R", "op": ":?", "arg": "need it"}, {"name": "Q", "op": "?", "arg": ""}, "$"])
        for bad in ("$5", "a $", "${X:+y}", "${X+y}", "${X", "${}", "${1X}", "${X:-${Y}}", "${X:-$$}", "${X:-{y}", "${X.y}"):
            with self.subTest(bad=bad), self.assertRaises(master_compose.TemplateError):
                master_compose.template_parts(bad)

    def test_substitute_follows_compose(self):
        sub = master_compose.substitute
        self.assertEqual(sub("${A}/$A/${A:-d}/${A-d}", {"A": "v"}), "v/v/v/v")
        self.assertEqual(sub("${A}|${A:-d}|${A-d}", {"A": ""}), "|d|")
        self.assertEqual(sub("${A}|${A:-d}|${A-d}", {}), "|d|d")
        self.assertEqual(sub("$$HOME and $${X}", {}), "$HOME and ${X}")
        self.assertEqual(sub("${A:?m}${B?}", {"A": "1", "B": "2"}), "12")
        for values in ({}, {"A": ""}):
            with self.subTest(values=values), self.assertRaises(master_compose.TemplateError):
                sub("${A:?gerekli}", values)

    def test_invalid_interpolation_is_a_refusal_with_its_line(self):
        model = service("environment:\n  - A=$5\nimage_extra_note: 1\n")
        self.assertEqual(refused(model)[0], (5, "environment"))
        model = service("command: echo ${X:+y}\n")
        self.assertEqual(refused(model), [(4, "command")])
        self.assertIn("Desteklenmeyen değişken", model["refusals"][0]["text"])

    def test_variables_are_listed_once_with_their_uses(self):
        model = read("""\
            services:
              a:
                image: x:${TAG:-1}
                environment: ["T=${TAG}", "U=${USER_NAME:?}"]
                labels: {l: "${TAG-2}"}
              b:
                image: y:${TAG:-3}
                working_dir: ${WD}
                user: ${PUID}:${PGID}
            """)
        self.assertEqual(model["refusals"], [])
        tag, user_name = model["variables"][0], model["variables"][1]
        self.assertEqual((tag["name"], tag["default"], tag["required"], tag["line"]), ("TAG", "1", False, 3))
        self.assertEqual([(u["service"], u["field"], u["line"]) for u in tag["uses"]],
                         [("a", "image", 3), ("a", "environment", 4), ("a", "labels", 5), ("b", "image", 7)])
        self.assertTrue(user_name["required"])
        self.assertEqual([v["name"] for v in model["variables"]], ["TAG", "USER_NAME", "WD", "PUID", "PGID"])


class HelperTests(unittest.TestCase):
    def test_names_and_folders(self):
        self.assertEqual(master_compose.lower_dashed("DB_PASSWORD"), "db-password")
        self.assertEqual(master_compose.safe_folder("..hidden"), "hidden")
        self.assertEqual(master_compose.safe_folder("Ornek DB"), "ornek-db")
        self.assertEqual(master_compose.safe_folder("///"), "veri")
        self.assertEqual(master_compose.capability("cap_kill"), "KILL")
        self.assertIsNone(master_compose.capability(5))
        self.assertTrue(master_compose.needs_shell("a | b"))
        self.assertFalse(master_compose.needs_shell("a '|' \"b;\" \\;"))


if __name__ == "__main__":
    unittest.main()
