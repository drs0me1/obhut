"""Overview network card (DD-206): the WAN rate sampler and /api/konsol/ag. Since DD-271 the card
shows the WAN rates only; no application reports traffic. Temporary directories only; no host changes."""
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
        self.p = panel.Panel(types.SimpleNamespace(state=str(self.state), allow_host=[]))


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
        self.assertEqual(set(answer), {"read_at", "sampled_at", "rx", "tx"}, "the WAN rates only")
        panel.master_api.check(panel.master_api.ref("Ag"), answer)


if __name__ == "__main__":
    unittest.main()
