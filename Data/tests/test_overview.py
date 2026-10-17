"""Overview network card (DD-206): the WAN rate sampler, each application's bridge rate (the operator's decision of
2026-10-17: its own bridge's sysfs counters, read the same way) and /api/konsol/ag. Temporary directories (a fake
/sys/class/net among them) only; no host changes."""
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "panel"))
import test_resources

panel = test_resources.panel


class Fixture(unittest.TestCase):
    """A Panel on a temporary state: account folder and WAN interface."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="konsol-overview-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        (self.root / "konsol").mkdir(mode=0o700)
        self.state = self.root / "state.env"
        self.state.write_text("SERVER_ROOT=%s\nLOCAL_DOMAIN=test\nV2_VERSION=test\nKONSOL_AUTH_DIR=%s\nWAN_INTERFACE=eth0\n"
                              % (self.root, self.root / "konsol"))
        self.p = panel.Panel(types.SimpleNamespace(state=str(self.state)))


class Clock:
    def __init__(self):
        self.mono, self.wall = 1000.0, 2_000_000_000.0

    def step(self, seconds):
        self.mono += seconds
        self.wall += seconds


class NetworkSamplerTests(Fixture):
    def sample(self, clock, rx, tx, env=None):
        with patch.object(panel.Panel, "net_counters", staticmethod(lambda iface: [rx, tx])), \
                patch.object(panel.time, "monotonic", lambda: clock.mono), patch.object(panel.time, "time", lambda: clock.wall):
            return self.p.net_sample(env or {"WAN_INTERFACE": "eth0"})

    def test_rates_come_from_counter_deltas_with_a_minimum_step(self):
        clock = Clock()
        self.sample(clock, 1000, 500)
        self.assertIsNone(self.p.net_last, "the first reading is only a baseline")
        clock.step(2)
        self.sample(clock, 1000 + 4 * 1024 * 1024, 500 + 2048)
        self.assertEqual(self.p.net_last, {"t": int(clock.wall), "rx": 2 * 1024 * 1024, "tx": 1024})
        clock.step(0.5)
        self.sample(clock, 10 ** 9, 10 ** 9)
        self.assertEqual(self.p.net_last["rx"], 2 * 1024 * 1024, "readings closer than NET_STEP_SECONDS measure nothing")
        clock.step(2)
        self.sample(clock, 0, 0)
        self.assertEqual(self.p.net_last["rx"], 0, "a counter reset is not a negative rate")
        before = self.p.net_last
        clock.step(10 * panel.SAMPLE_SECONDS)
        self.sample(clock, 100, 100)
        self.assertEqual(self.p.net_last, before, "a stale baseline gives no rate")

    def test_interface_names_are_checked_and_a_new_interface_drops_the_rate(self):
        clock = Clock()
        for bad in ("", "../x", ".", "..", "a" * 16, "eth 0", "eth/0"):
            with self.subTest(iface=bad):
                self.sample(clock, 1, 1, {"WAN_INTERFACE": bad})
                self.assertIsNone(self.p.net_prev)
        self.sample(clock, 0, 0)
        clock.step(2)
        self.sample(clock, 2048, 2048)
        self.assertIsNotNone(self.p.net_last)
        clock.step(2)
        self.sample(clock, 0, 0, {"WAN_INTERFACE": "ens3"})
        self.assertIsNone(self.p.net_last)

    def test_unreadable_counters_leave_the_rate_alone(self):
        def broken(_iface):
            raise OSError("no such device")
        with patch.object(panel.Panel, "net_counters", staticmethod(broken)):
            self.p.net_sample({"WAN_INTERFACE": "eth0"})
        self.assertIsNone(self.p.net_prev)


class ApplicationNetworkTests(Fixture):
    """Each application's rate from its own bridge (the interface master_generator.interface_name gives) in a fake
    /sys/class/net, with the host's view of the bridge: tx is what the application receives, rx what it sends."""

    def setUp(self):
        super().setUp()
        import app_fixtures
        import master_applications as apps
        self.apps = apps
        self.values = app_fixtures.env(self.root)
        with self.state.open("a") as fh:
            fh.write("".join("%s=%s\n" % kv for kv in self.values.items() if kv[0] not in ("STATE_FILE", "LOCAL_DOMAIN")))
        self.env = panel.read_env(str(self.state))
        app_fixtures.record(self.values)
        app_fixtures.record(self.values, text=app_fixtures.SIMPLE, given=app_fixtures.SIMPLE_ANSWERS, app="sayac",
                            ports={"app:9000/tcp": 62105})
        self.sys = self.root / "sys-class-net"
        patch.object(panel, "SYS_NET", str(self.sys)).start()
        self.addCleanup(patch.stopall)
        self.clock = Clock()
        patch.object(panel.time, "monotonic", lambda: self.clock.mono).start()
        patch.object(panel.time, "time", lambda: self.clock.wall).start()

    def counters(self, app, rx, tx):
        folder = self.sys / self.apps.interface(self.env, app) / "statistics"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "rx_bytes").write_text("%d\n" % rx)
        (folder / "tx_bytes").write_text("%d\n" % tx)

    def test_an_applications_rate_comes_from_its_own_bridge_with_the_hosts_view_of_it(self):
        self.counters("notlar", 1000, 5000)
        self.counters("sayac", 7, 7)
        self.p.app_net_sample(self.env)
        self.assertEqual(self.p.app_rates(), {}, "the first reading is only a baseline")
        self.clock.step(2)
        self.counters("notlar", 1000 + 2048, 5000 + 8192)
        self.p.app_net_sample(self.env)
        self.assertEqual(self.p.app_rates(), {"notlar": {"indirme": 4096, "yukleme": 1024}, "sayac": {"indirme": 0, "yukleme": 0}},
                         "what the host sends into the bridge is what the application downloads")
        self.clock.step(0.5)
        self.counters("notlar", 10 ** 9, 10 ** 9)
        self.p.app_net_sample(self.env)
        self.assertEqual(self.p.app_rates()["notlar"], {"indirme": 4096, "yukleme": 1024}, "a reading too close measures nothing")
        answer = self.p.network()
        self.assertEqual(answer["uygulamalar"], [{"ad": "notlar", "indirme": 4096, "yukleme": 1024}],
                         "only an application with traffic")
        panel.master_api.check(panel.master_api.ref("Ag"), answer)

    def test_a_counter_that_went_back_starts_over_and_a_missing_bridge_has_no_rate(self):
        self.counters("notlar", 10 ** 6, 10 ** 6)
        self.p.app_net_sample(self.env)
        self.clock.step(2)
        self.counters("notlar", 10 ** 6 + 200, 10 ** 6 + 400)
        self.p.app_net_sample(self.env)
        self.assertEqual(self.p.app_rates()["notlar"], {"indirme": 200, "yukleme": 100})
        # The bridge was made again: its counters start from zero; no rate until the next reading.
        self.clock.step(2)
        self.counters("notlar", 50, 60)
        self.p.app_net_sample(self.env)
        self.assertNotIn("notlar", self.p.app_rates())
        self.clock.step(2)
        self.counters("notlar", 50 + 4, 60 + 8)
        self.p.app_net_sample(self.env)
        self.assertEqual(self.p.app_rates()["notlar"], {"indirme": 4, "yukleme": 2})
        # A stopped application has no bridge: no rate and no baseline.
        import shutil
        shutil.rmtree(self.sys / self.apps.interface(self.env, "notlar"))
        self.p.app_net_sample(self.env)
        self.assertNotIn("notlar", self.p.app_rates())
        self.assertNotIn("notlar", self.p.app_net_prev)
        # A stale baseline (a stalled sampler) gives no rate; a rate older than the window is not shown.
        self.counters("sayac", 0, 0)
        self.p.app_net_sample(self.env)
        self.clock.step(10 * panel.SAMPLE_SECONDS)
        self.counters("sayac", 100, 100)
        self.p.app_net_sample(self.env)
        self.assertNotIn("sayac", self.p.app_rates())
        self.p.app_net_last["sayac"] = {"t": int(self.clock.wall) - panel.NET_WINDOW_SECONDS - 1, "indirme": 1, "yukleme": 1}
        self.assertEqual(self.p.app_rates(), {})
        # An application without a record is forgotten.
        self.clock.step(2)
        self.p.app_net_sample(self.env)
        self.apps.Records(self.values).remove("sayac")
        self.p.app_net_sample(self.env)
        self.assertNotIn("sayac", self.p.app_net_prev)

    def test_the_card_lists_the_five_busiest_with_traffic(self):
        now = int(self.clock.wall)
        rates = {"a": (5, 5), "b": (100, 0), "c": (0, 50), "d": (0, 0), "e": (30, 30), "f": (1, 0), "g": (60, 0), "h": (2, 1)}
        self.p.app_net_last = {app: {"t": now, "indirme": down, "yukleme": up} for app, (down, up) in rates.items()}
        with patch.object(self.p, "app_net_sample"):
            answer = self.p.network()
        self.assertEqual([(r["ad"], r["indirme"], r["yukleme"]) for r in answer["uygulamalar"]],
                         [("b", 100, 0), ("e", 30, 30), ("g", 60, 0), ("c", 0, 50), ("a", 5, 5)])

    def test_the_sampler_runs_no_command_and_survives_a_broken_record(self):
        self.counters("notlar", 1, 1)
        with patch.object(panel.subprocess, "run", side_effect=AssertionError("no command")):
            self.p.app_net_sample(self.env)
        (Path(self.values["UYGULAMA_STATE_DIR"]) / "Bozuk").mkdir(mode=0o700)
        self.p.app_net_sample(self.env)  # an unexpected entry stops the records' reader; the sampler keeps what it had
        self.assertIn("notlar", self.p.app_net_prev)


class NetworkEndpointTests(Fixture):
    def test_a_rate_older_than_the_window_is_not_shown(self):
        now = 2_000_000_000
        with patch.object(panel.time, "time", lambda: now), patch.object(panel.Panel, "net_counters", staticmethod(lambda iface: [0, 0])):
            self.p.net_last = {"t": now - 10, "rx": 2, "tx": 3}
            answer = self.p.network()
            self.assertEqual((answer["rx"], answer["tx"], answer["sampled_at"], answer["read_at"]), (2, 3, now - 10, now))
            self.p.net_last = {"t": now - panel.NET_WINDOW_SECONDS - 1, "rx": 1, "tx": 1}
            answer = self.p.network()
        self.assertEqual((answer["rx"], answer["tx"], answer["sampled_at"]), (None, None, None))
        self.assertEqual(set(answer), {"read_at", "sampled_at", "rx", "tx", "uygulamalar"})
        self.assertEqual(answer["uygulamalar"], [], "no application has a record here")
        panel.master_api.check(panel.master_api.ref("Ag"), answer)


if __name__ == "__main__":
    unittest.main()
