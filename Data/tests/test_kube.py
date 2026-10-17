"""DD-271 (phase 2): the Kubernetes reader (master_kube). What `podman kube generate` writes (Podman 5.4, and
the fuller securityContext older versions wrote) reads without a refusal, its harmless keys as notes; a
Deployment with one replica and its claims; and a refusal with its line for everything rebuild.md 4.2
does not list."""
from pathlib import Path
import sys
import textwrap
import unittest

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_kube  # noqa: E402
import master_yaml  # noqa: E402

FIXTURES = DATA / "tests" / "fixtures" / "uygulama"


def read(text):
    return master_kube.read(master_yaml.load_all(textwrap.dedent(text)))


def pod(containers, spec=""):
    """A Pod whose spec holds the given container list (YAML under containers:) and other spec keys."""
    return read("apiVersion: v1\nkind: Pod\nmetadata:\n  name: deneme\nspec:\n%s  containers:\n%s"
                % (textwrap.indent(textwrap.dedent(spec), "  "), textwrap.indent(textwrap.dedent(containers), "  ")))


def one(body, spec=""):
    """A Pod with one container named app; body is the container's own keys."""
    return pod("- name: app\n  image: docker.io/library/nginx:1.27\n" + textwrap.indent(textwrap.dedent(body), "  "), spec)


def refused(model):
    return [(r["line"], r["key"]) for r in model["refusals"]]


class FixtureTests(unittest.TestCase):
    def test_podman_kube_generate_output_reads_cleanly(self):
        model = read((FIXTURES / "notlar-pod.yaml").read_text())
        self.assertEqual(model["refusals"], [])
        self.assertEqual((model["format"], model["name"], model["pod"], model["variables"]), ("kubernetes", "notlar", True, []))
        web, redis = model["services"]
        self.assertEqual((web["name"], web["image"], web["entrypoint"], web["command"]),
                         ("notlar-web", "docker.io/library/nginx:1.27-alpine", None, ["nginx", "-g", "daemon off;"]))
        self.assertEqual(web["ports"], [{"port": 8080, "protocol": "tcp", "host_port": 8080, "line": 26}])
        self.assertEqual(web["environment"], [{"name": "NGINX_PORT", "value": "8080", "line": 21, "secret_ref": False,
                                               "secret_key": None}])
        self.assertEqual([(m["kind"], m["source"], m["target"], m["read_only"]) for m in web["mounts"]],
                         [("absolute", "/srv/notlar/html", "/usr/share/nginx/html", True),
                          ("named", "notlar_cache", "/var/cache/nginx", False)])
        self.assertEqual((web["user"], web["caps_add"], web["restart"]), (None, [], "always"))
        self.assertEqual((redis["user"], redis["command"]), ("999:999", ["redis-server", "--save", "60", "1"]))
        noted = {n["key"] for n in model["notes"]}
        for key in ("annotations", "creationTimestamp", "labels", "drop", "stdin", "tty", "type", "hostPort"):
            self.assertIn(key, noted)

    def test_a_deployment_with_one_replica_and_its_claim(self):
        model = read((FIXTURES / "sayac-deployment.yaml").read_text())
        self.assertEqual(model["refusals"], [])
        self.assertEqual(model["name"], "sayac", "the pod template's name, without Podman's -pod")
        (svc,) = model["services"]
        self.assertEqual(svc["environment"], [
            {"name": "COUNTER_TOKEN", "value": "", "line": 24, "secret_ref": True, "secret_key": "sayac/token"},
            {"name": "COUNTER_MODE", "value": "public", "line": 29, "secret_ref": False, "secret_key": None}])
        self.assertEqual([(p["port"], p["protocol"]) for p in svc["ports"]], [(9000, "tcp"), (9001, "udp")])
        self.assertEqual(svc["health"], {"test": ["CMD-SHELL", "curl -f http://localhost:9000/healthz || exit 1"],
                                         "interval": "30s", "timeout": "5s", "retries": 3, "start_period": "10s"})
        self.assertEqual([(m["kind"], m["source"], m["target"]) for m in svc["mounts"]],
                         [("named", "sayac-data", "/data"), ("tmpfs", "", "/tmp")])
        self.assertEqual(svc["workdir"], "/data")
        noted = {n["key"] for n in model["notes"]}
        for key in ("status", "selector", "imagePullPolicy", "accessModes", "PersistentVolumeClaim", "httpGet"):
            self.assertIn(key, noted)

    def test_the_fuller_security_context_of_older_podman_versions(self):
        model = one("""\
            securityContext:
              allowPrivilegeEscalation: true
              capabilities:
                drop: [CAP_MKNOD, CAP_NET_RAW, CAP_AUDIT_WRITE]
                add: [CAP_NET_BIND_SERVICE]
              privileged: false
              readOnlyRootFilesystem: false
              runAsNonRoot: false
              seLinuxOptions: {}
              procMount: Default
              seccompProfile: {type: RuntimeDefault}
            workingDir: /
            resources: {}
            terminationMessagePath: /dev/termination-log
            terminationMessagePolicy: File
            """, spec="hostname: deneme\nenableServiceLinks: false\nautomountServiceAccountToken: false\n"
                      "hostNetwork: false\ndnsPolicy: ClusterFirst\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual(model["services"][0]["caps_add"], ["NET_BIND_SERVICE"])
        self.assertEqual(model["services"][0]["workdir"], "/")


class HardeningAndLimitTests(unittest.TestCase):
    def test_resource_limits(self):
        model = one("resources:\n  limits: {cpu: 500m, memory: 256Mi, ephemeral-storage: 1Gi}\n  requests: {cpu: 100m}\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual(model["services"][0]["limits"], {"cpus": 0.5, "memory": 256 * 2 ** 20, "pids": None, "ulimits": {}})
        self.assertEqual(sorted(n["key"] for n in model["notes"]), ["ephemeral-storage", "requests"])
        for quantity, value in (("2", 2), ("1.5", 1.5), (1, 1), ("1500m", 1.5)):
            with self.subTest(cpu=quantity):
                self.assertEqual(one("resources: {limits: {cpu: %r}}\n" % quantity)["services"][0]["limits"]["cpus"], value)
        for quantity, value in (("1G", 10 ** 9), ("129e6", 129 * 10 ** 6), ("1Gi", 2 ** 30), (1048576, 2 ** 20), ("512k", 512000)):
            with self.subTest(memory=quantity):
                self.assertEqual(one("resources: {limits: {memory: %r}}\n" % quantity)["services"][0]["limits"]["memory"], value)
        for text in ("resources: {limits: {cpu: lots}}\n", "resources: {limits: {memory: 1Q}}\n", "resources: {limits: {cpu: 0}}\n",
                     "resources: {limits: {nvidia.com/gpu: 1}}\n", "resources: {limits: {hugepages-2Mi: 1Gi}}\n",
                     "resources: {claims: []}\n", "resources: []\n"):
            with self.subTest(text=text):
                self.assertEqual(len(one(text)["refusals"]), 1)

    def test_read_only_root_no_new_privileges_and_drops(self):
        model = one("securityContext:\n  readOnlyRootFilesystem: true\n  allowPrivilegeEscalation: false\n"
                    "  capabilities:\n    drop: [ALL]\n    add: [NET_BIND_SERVICE]\n")
        self.assertEqual(model["refusals"], [])
        svc = model["services"][0]
        self.assertEqual((svc["read_only"], svc["no_new_privileges"], svc["caps_drop"], svc["caps_add"]),
                         (True, True, ["ALL"], ["NET_BIND_SERVICE"]))
        svc = one("securityContext: {capabilities: {drop: [CAP_KILL, CAP_MKNOD, SETUID]}}\n")["services"][0]
        self.assertEqual(svc["caps_drop"], ["KILL", "SETUID"], "names Podman never gives are only noted")
        svc = one("securityContext: {readOnlyRootFilesystem: false, allowPrivilegeEscalation: true}\n")["services"][0]
        self.assertEqual((svc["read_only"], svc["no_new_privileges"]), (False, False))
        for text in ("securityContext: {readOnlyRootFilesystem: 'yes'}\n", "securityContext: {capabilities: {add: [KILL], drop: [KILL]}}\n",
                     "securityContext: {capabilities: {drop: KILL}}\n"):
            with self.subTest(text=text):
                self.assertEqual(len(one(text)["refusals"]), 1)
        self.assertEqual(refused(one("", spec="securityContext: {readOnlyRootFilesystem: true}\n")), [(6, "readOnlyRootFilesystem")])

    def test_references_in_command_and_args(self):
        model = one("command: [run, '$(MODE)']\nargs: ['--port=$(PORT)', '$$(PORT)', '$(UNKNOWN)']\n"
                    "env: [{name: PORT, value: '8080'}, {name: MODE, value: fast}]\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual(sorted(n["key"] for n in model["notes"]), ["args", "command"])
        model = one("args: ['--password=$(DB_PASSWORD)']\n"
                    "env: [{name: DB_PASSWORD, valueFrom: {secretKeyRef: {name: db, key: password}}}]\n")
        self.assertEqual([r["text"] for r in model["refusals"]], ["Gizli değer komut satırında kullanılamaz: $(DB_PASSWORD)."])
        self.assertEqual(master_kube.references("a$(X)b$$(Y)$(Z"), ["X"])
        # Env values: an earlier entry is filled in (noted); a secret never stands inside another value.
        model = one("env:\n- {name: HOST, value: db}\n- {name: URL, value: 'http://$(HOST):$(PORT)/$(URL)'}\n"
                    "- {name: PORT, value: '5432'}\n")
        self.assertEqual(model["refusals"], [])
        self.assertEqual([(n["line"], n["text"]) for n in model["notes"]],
                         [(11, "$(HOST) bu konteynerin önceki bir ortam değişkeninden doldurulur.")])
        for order in ("- {name: PW, valueFrom: {secretKeyRef: {name: db, key: pw}}}\n- {name: DSN, value: 'u:$(PW)@db'}\n",
                      "- {name: DSN, value: 'u:$(PW)@db'}\n- {name: PW, valueFrom: {secretKeyRef: {name: db, key: pw}}}\n"):
            with self.subTest(order=order):
                model = one("env:\n" + order)
                self.assertEqual([r["text"] for r in model["refusals"]],
                                 ["Gizli değer başka bir değişkenin içinde kullanılamaz: $(PW)."])
                self.assertEqual(model["refusals"][0]["key"], "env")
        self.assertEqual(one("env:\n- {name: A, value: '$$(B) and $$'}\n- {name: B, value: x}\n")["notes"], [])
        self.assertEqual(master_kube.expand("$(X)/$$(X)/$(Y)/$$/$/a$(", {"X": "1"}), "1/$(X)/$(Y)/$/$/a$(")
        bad_refs = ("env: [{name: A, valueFrom: {secretKeyRef: {name: 'bad name', key: k}}}]\n",
                    "env: [{name: A, valueFrom: {secretKeyRef: {name: s, key: 'a b'}}}]\n")
        for text in bad_refs:
            with self.subTest(text=text):
                self.assertEqual([k for _l, k in refused(one(text))], ["valueFrom"])


class RefusalTests(unittest.TestCase):
    def test_host_namespaces_and_privileged_mode(self):
        for key in ("hostNetwork", "hostPID", "hostIPC"):
            with self.subTest(key=key):
                self.assertEqual(refused(one("", spec="%s: true\n" % key)), [(6, key)])
        self.assertEqual(refused(one("securityContext:\n  privileged: true\n")), [(10, "privileged")])
        model = read("""\
            apiVersion: v1
            kind: Pod
            metadata:
              name: p
              annotations:
                io.podman.annotations.privileged/app: "TRUE"
            spec:
              containers:
              - name: app
                image: x
            """)
        self.assertEqual(refused(model), [(6, "io.podman.annotations.privileged/app")])

    def test_capabilities_beyond_the_default_set(self):
        model = one("securityContext:\n  capabilities:\n    add: [NET_ADMIN, CAP_SYS_ADMIN, KILL]\n")
        self.assertEqual(refused(model), [(11, "add"), (11, "add")])
        self.assertEqual(model["services"][0]["caps_add"], ["KILL"])
        self.assertEqual(refused(one("securityContext:\n  capabilities:\n    keep: [KILL]\n")), [(11, "keep")])

    def test_other_kinds_and_objects(self):
        for kind in ("ConfigMap", "Secret", "Service", "StatefulSet", "DaemonSet", "Job", "List"):
            with self.subTest(kind=kind):
                model = read("apiVersion: v1\nkind: %s\nmetadata:\n  name: x\n" % kind)
                self.assertEqual(refused(model)[0], (2, "kind"))
        model = read("apiVersion: apps/v1\nkind: Pod\nmetadata: {name: x}\nspec: {containers: [{name: a, image: b}]}\n")
        self.assertEqual(refused(model), [(1, "apiVersion")])
        two = "apiVersion: v1\nkind: Pod\nmetadata: {name: a}\nspec: {containers: [{name: a, image: b}]}\n"
        self.assertEqual(refused(read(two + "---\n" + two)), [(7, "kind")])
        self.assertEqual(refused(read("apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata: {name: c}\n")), [(1, "kind")])
        self.assertEqual(refused(read("- a\n- b\n")), [(1, "kind")])

    def test_deployments_run_once(self):
        base = (FIXTURES / "sayac-deployment.yaml").read_text()
        for replicas in ("2", "0", "true"):
            with self.subTest(replicas=replicas):
                model = read(base.replace("replicas: 1", "replicas: %s" % replicas))
                self.assertEqual(refused(model), [(11, "replicas")])
        self.assertEqual(read(base.replace("  replicas: 1\n", ""))["refusals"], [], "one replica is the default")
        self.assertEqual(refused(read(base.replace("  selector:", "  paused: true\n  selector:"))), [(12, "paused")])

    def test_unsupported_pod_and_container_keys(self):
        cases = {
            ("", "initContainers: []\n"): "initContainers",
            ("", "dnsConfig: {nameservers: [192.0.2.53]}\n"): "dnsConfig",
            ("", "hostAliases: []\n"): "hostAliases",
            ("", "shareProcessNamespace: true\n"): "shareProcessNamespace",
            ("", "securityContext: {sysctls: []}\n"): "sysctls",
            ("", "restartPolicy: Sometimes\n"): "restartPolicy",
            ("envFrom: []\n", ""): "envFrom",
            ("lifecycle: {}\n", ""): "lifecycle",
            ("volumeDevices: []\n", ""): "volumeDevices",
            ("readinessGates: []\n", ""): "readinessGates",
            ("securityContext: {seccompProfile: {type: Unconfined}}\n", ""): "seccompProfile",
            ("securityContext: {procMount: Unmasked}\n", ""): "procMount",
            ("securityContext: {windowsOptions: {}}\n", ""): "windowsOptions",
            ("ports: [{containerPort: 80, protocol: SCTP}]\n", ""): "protocol",
            ("ports: [{containerPort: 0}]\n", ""): "containerPort",
            ("env: [{name: A, valueFrom: {configMapKeyRef: {name: c, key: k}}}]\n", ""): "valueFrom",
            ("env: [{name: A, valueFrom: {fieldRef: {fieldPath: metadata.name}}}]\n", ""): "valueFrom",
            ("env: [{name: A, value: x}, {name: A, value: y}]\n", ""): "env",
            ("livenessProbe: {tcpSocket: {port: 80}}\n", ""): "livenessProbe",
            ("livenessProbe: {grpc: {port: 80}}\n", ""): "livenessProbe",
            ("livenessProbe: {httpGet: {port: web}}\n", ""): "port",
            ("livenessProbe: {exec: {command: [true]}}\n", ""): "exec",
            ("command: run\n", ""): "command",
            ("workingDir: data\n", ""): "workingDir",
        }
        for (body, spec), key in cases.items():
            with self.subTest(key=key, body=body, spec=spec):
                model = one(body, spec)
                self.assertIn(key, [k for _l, k in refused(model)], model["refusals"])

    def test_volumes(self):
        containers = """\
            - name: app
              image: x
              volumeMounts:
              - {name: v, mountPath: /data}
            """
        for volume in ("{name: v, hostPath: {path: /etc}}", "{name: v, hostPath: {path: /var/run/docker.sock, type: Socket}}",
                       "{name: v, hostPath: {path: /dev/sda, type: BlockDevice}}", "{name: v, hostPath: {path: relative}}",
                       "{name: v, hostPath: {path: /srv/x, type: CharDevice}}", "{name: v, configMap: {name: c}}",
                       "{name: v, secret: {secretName: s}}", "{name: v, nfs: {server: 192.0.2.1, path: /}}",
                       "{name: v, emptyDir: {medium: HugePages}}", "{name: v}", "{name: v, persistentVolumeClaim: {}}",
                       "{name: v, hostPath: {path: /srv/x, other: 1}}"):
            with self.subTest(volume=volume):
                model = pod(containers, spec="volumes:\n- %s\n" % volume)
                self.assertTrue(model["refusals"], volume)
                self.assertEqual(model["services"][0]["mounts"], [])
        model = pod(containers, spec="volumes:\n- {name: v, hostPath: {path: /srv/x, type: DirectoryOrCreate}}\n- {name: unused, emptyDir: {}}\n")
        self.assertEqual(model["refusals"], [])
        self.assertIn("unused", " ".join(n["text"] for n in model["notes"]))
        for mount in ("{name: missing, mountPath: /data}", "{name: v, mountPath: data}", "{name: v, mountPath: /data, subPath: a}",
                      "{name: v, mountPath: /data, mountPropagation: Bidirectional}", "{name: v, mountPath: /a/../b}"):
            with self.subTest(mount=mount):
                model = pod("- name: app\n  image: x\n  volumeMounts:\n  - %s\n" % mount,
                            spec="volumes:\n- {name: v, emptyDir: {}}\n")
                self.assertTrue(model["refusals"], mount)

    def test_a_mapping_where_text_belongs_is_a_refusal(self):
        self.assertEqual(refused(read("apiVersion: v1\nkind: {a: 1}\n")), [(2, "kind")])
        self.assertEqual(refused(one("", spec="restartPolicy: {a: 1}\n")), [(6, "restartPolicy")])
        model = pod("- name: app\n  image: x\n  volumeMounts:\n  - {name: {a: 1}, mountPath: /d}\n")
        self.assertEqual([k for _l, k in refused(model)], ["name"])

    def test_names(self):
        self.assertEqual(refused(read("apiVersion: v1\nkind: Pod\nmetadata: {}\nspec: {containers: [{name: a, image: b}]}\n")),
                         [(3, "name")])
        model = pod("- {name: a, image: x}\n- {name: a, image: y}\n")
        self.assertEqual([k for _l, k in refused(model)], ["name"])
        self.assertEqual(refused(pod("- {image: x}\n")), [(7, "name")])
        self.assertEqual(refused(read("apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec: {}\n")), [(4, "containers")])


if __name__ == "__main__":
    unittest.main()
