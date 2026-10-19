"""Independent inventory edge reproductions; no server or real Podman calls. The inventory offers no action:
an application is managed on its own page (DD-271, phase 3), Podman's resources by their jobs."""
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_container_manager as manager


class IntegrationEdges(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="container-edges-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {"KONTEYNER_STATE_DIR": str(self.root / "state"), "RUNTIME_DIR": str(self.root / "run"),
                    "KONTEYNER_LOCK": str(self.root / "run/containers.lock"), "TAILSCALE_IPV4": "100.64.0.2"}
        self.state = self.root / "state.env"
        self.state.write_text("".join(k + "=" + v + "\n" for k, v in self.env.items()))
        self.raw, self.networks, self.calls = {}, [], []
        panel = types.SimpleNamespace(args=types.SimpleNamespace(state=str(self.state)), run_tool=self.fake_run, env=lambda: {})
        self.service = manager.Service(panel)

    def fake_run(self, argv, timeout=30, **kwargs):
        self.calls.append(list(argv))
        if argv[:2] == ["podman", "version"]:
            return 0, "5.4.2", ""
        if argv[:2] == ["podman", "ps"]:
            rows = [{"Id": r["Id"], "Names": [name], "Image": r["ImageName"], "State": r["State"]["Status"],
                     "Labels": r["Config"].get("Labels", {}), "Status": "Up 2 minutes (unhealthy)"}
                    for name, r in self.raw.items()]
            return 0, json.dumps(rows), ""
        if argv[:2] == ["podman", "inspect"]:
            return (0, json.dumps([self.raw[argv[-1]]]), "") if argv[-1] in self.raw else (1, "", "no such container")
        if argv[:3] == ["podman", "container", "exists"]:
            return (0 if argv[-1] in self.raw else 1), "", ""
        if argv[:2] == ["podman", "stop"]:
            self.raw[argv[-1]]["State"].update(Running=False, Status="exited")
            return 0, "", ""
        if argv[:3] == ["podman", "network", "ls"]:
            return 0, json.dumps(self.networks), ""
        if argv[:2] in (["podman", "images"], ["podman", "system"], ["podman", "stats"], ["podman", "volume"]):
            return 0, "[]", ""
        raise AssertionError(argv)

    def container(self, name="outside", status="running", labels=None):
        self.raw[name] = {"Id": "c" * 64, "Name": name, "ImageName": "docker.io/library/nginx:alpine",
                          "State": {"Status": status, "Running": status in ("running", "paused"),
                                    "Paused": status == "paused", "Health": {"Status": "unhealthy"}},
                          "HostConfig": {"NetworkMode": "bridge"}, "NetworkSettings": {}, "Mounts": [],
                          "Config": {"Labels": labels or {}, "Env": ["TOKEN=native-secret-value"], "Cmd": ["serve"]}}

    def test_a_paused_container_offers_nothing(self):
        self.container(status="paused")
        row = self.service.view().liste()["containers"][0]
        self.assertEqual(row["state"], "paused")
        self.assertNotIn("actions", row, "no lifecycle action lives on a container row")

    def test_application_labels_with_a_foreign_unit_are_not_an_application(self):
        labels = {"io.master-stack.managed": "uygulama", "io.master-stack.uygulama": "notlar"}
        self.container("notlar_web", labels=dict(labels, PODMAN_SYSTEMD_UNIT="konsol-notlar_web.service"))
        self.container("notlar_db", labels=dict(labels, PODMAN_SYSTEMD_UNIT="foreign-owner.service"))
        rows = {r["name"]: r for r in self.service.view().liste()["containers"]}
        self.assertEqual((rows["notlar_web"]["source"], rows["notlar_web"]["uygulama"]), ("uygulama", "notlar"))
        self.assertEqual((rows["notlar_db"]["source"], rows["notlar_db"]["uygulama"]), ("external", None),
                         "labels alone never make a container an application's")

    def test_list_health_uses_already_collected_native_inspection(self):
        self.container()
        row = self.service.view().liste()["containers"][0]
        self.assertEqual(row["health"], "unhealthy", "The summary must not report zero unhealthy containers when native inspect says unhealthy")

    def test_real_network_subnet_objects_normalized_for_console_string_rows(self):
        self.networks = [{"name": "konsol", "driver": "bridge", "id": "d" * 64,
                          "subnets": [{"subnet": "10.89.0.0/24", "gateway": "10.89.0.1"}],
                          "labels": {"io.master-stack.managed": "konsol"}}]
        row = self.service.view().liste()["networks"][0]
        self.assertEqual(row["subnets"], ["10.89.0.0/24"], "Console joins these rows as strings; objects display as [object Object]")

    def test_runtime_environment_values_are_not_returned_from_inspect(self):
        self.container()
        listing = self.service.view().liste()
        self.assertTrue(any(c[:2] == ["podman", "inspect"] for c in self.calls), "the list inspects the container")
        self.assertNotIn("native-secret-value", json.dumps(listing))


if __name__ == "__main__":
    unittest.main()
