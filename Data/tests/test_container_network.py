"""The container guard's owned nft policy (DD-223, DD-224, DD-229) and its input, the application records
(rebuild DD-271, phase 3); no host mutations."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_fixtures  # noqa: E402
import master_applications as apps  # noqa: E402

SPEC = importlib.util.spec_from_file_location("container_network", Path(__file__).resolve().parents[1] / "panel/master_container_network.py")
network = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(network)
DATA = Path(__file__).resolve().parents[1]


def app_row(app, *pools):
    return {"app": app, "interface": "ksl" + "%010x" % (abs(hash(app)) % 16 ** 10),
            "publications": [{"service": "web", "port": 8080 + n, "protocol": "tcp", "host_ip": "127.0.0.1", "host_port": pool}
                             for n, pool in enumerate(pools)]}


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(app_fixtures.env(self.root), VPN_BLOCK_DEST4=network.env_read(DATA / "config/defaults.env")["VPN_BLOCK_DEST4"])
        (self.root / "run").mkdir()
        self.calls = []
        self.applied = None

    def runner(self, argv, timeout=20):
        """nft as the guard sees it: what the last apply loaded is what a list shows."""
        self.calls.append(list(argv))
        if argv[:3] == ["nft", "-j", "list"]:
            if self.applied is None:
                return 1, "", "Error: No such file or directory"
            return 0, json.dumps({"nftables": [{"metainfo": {"version": "test"}}] + self.applied}), ""
        if argv[:3] == ["nft", "-j", "-c"]:
            return 0, "", ""
        if argv[:2] == ["nft", "-j"] and argv[2] == "-f":
            with open(argv[3], encoding="utf-8") as fh:
                self.applied = [next(iter(c.values())) for c in json.load(fh)["nftables"] if "add" in c]
            return 0, "", ""
        self.fail("Unexpected command: " + repr(argv))

    def egress_rules(self, objects):
        return [o["rule"]["expr"] for o in objects if "rule" in o and o["rule"]["chain"] == "forward"]

    def input_rules(self, objects):
        return [o["rule"]["expr"] for o in objects if "rule" in o and o["rule"]["chain"] == "input"]

    def test_each_application_bridge_returns_its_own_traffic_and_a_loopback_publication_needs_no_permit(self):
        rows = [app_row("notlar", 62100, 62101), app_row("sayac", 62102)]
        policy = network.policy(self.env, rows)
        chain = next(x["chain"] for x in policy if "chain" in x)
        self.assertEqual((chain["family"], chain["hook"], chain["prio"], chain["policy"]), ("inet", "forward", -10, "accept"))
        m = lambda key, right, op="==": {"match": {"op": op, "left": {"meta": {"key": key}}, "right": right}}
        rules = self.egress_rules(policy)
        bridges = sorted(r["interface"] for r in rows)
        self.assertEqual(rules[-3:], [[m("iifname", b), m("oifname", b), {"return": None}] for b in bridges] + [[{"drop": None}]])
        text = json.dumps(policy)
        for value in ("62100", "62101", "62102", '"dnat"', '"ip6"', '"accept": null'):
            self.assertNotIn(value, text, "the host reaches 127.0.0.1 through OUTPUT DNAT; nothing else is opened")

    def test_the_guard_reads_the_application_records(self):
        record = app_fixtures.record(self.env)
        rows = network.applications(self.env)
        self.assertEqual(rows, [{"app": "notlar", "interface": apps.interface(self.env, "notlar"),
                                 "publications": [{"service": "web", "port": 8080, "protocol": "tcp", "host_ip": "127.0.0.1",
                                                   "host_port": record["places"]["ports"]["web:8080/tcp"]}]}])
        self.assertRegex(rows[0]["interface"], r"^ksl[0-9a-f]{10}$")
        network.apply(self.env, run=self.runner)
        self.assertTrue(network.check(self.env, run=self.runner))
        self.assertIn(rows[0]["interface"], json.dumps(self.applied))
        # Removing the record leaves the applied rules stale: the check says so; a new apply drops the bridge.
        apps.Records(self.env).remove("notlar")
        with self.assertRaises(network.NetworkError) as err:
            network.check(self.env, run=self.runner)
        self.assertEqual(err.exception.status, 503)
        network.apply(self.env, run=self.runner)
        self.assertNotIn(rows[0]["interface"], json.dumps(self.applied))

    def test_an_install_without_its_places_yet_is_left_out_and_anything_unreadable_fails_closed(self):
        app_fixtures.record(self.env)
        partial = Path(self.env["UYGULAMA_STATE_DIR"]) / "yeni"
        partial.mkdir(mode=0o700)
        self.assertEqual([r["app"] for r in network.applications(self.env)], ["notlar"], "stricter, never wider")
        places = partial / "yerler.json"
        for bad in ("{", json.dumps({"revision": "x"}), json.dumps({"revision": "a" * 32, "stopped": False, "images": {},
                                                                   "secrets": {}, "ports": {"web:8080/tcp": "62100"}})):
            with self.subTest(bad=bad):
                places.write_text(bad)
                places.chmod(0o600)
                with self.assertRaises(network.NetworkError) as err:
                    network.applications(self.env)
                self.assertEqual(err.exception.status, 503)
        places.unlink()
        (Path(self.env["UYGULAMA_STATE_DIR"]) / "Bozuk_ad").mkdir(mode=0o700)
        with self.assertRaises(network.NetworkError):
            network.applications(self.env)
        os.rmdir(Path(self.env["UYGULAMA_STATE_DIR"]) / "Bozuk_ad")
        with self.assertRaises(network.NetworkError):
            network.applications(dict(self.env, UYGULAMA_STATE_DIR=""))

    def test_a_publication_on_any_other_address_fails_closed_until_phase_4(self):
        row = app_row("notlar", 62100)
        for address in ("0.0.0.0", "100.64.0.2", "192.0.2.1", ""):
            row["publications"][0]["host_ip"] = address
            with self.subTest(address=address), patch.object(apps, "guard_input", return_value=[copy.deepcopy(row)]), \
                    self.assertRaises(network.NetworkError):
                network.applications(self.env)
        with patch.object(apps, "guard_input", return_value=[dict(app_row("notlar"), interface="eth0")]), \
                self.assertRaises(network.NetworkError):
            network.applications(self.env)

    def test_policy_identity_fails_closed(self):
        with self.assertRaises(network.NetworkError):
            network.policy(dict(self.env, KONTEYNER_BRIDGE_PREFIX="*"), [])

    def test_containers_open_nothing_on_the_host_but_gateway_dns(self):
        # DD-229: the input chain at -10 ends in a drop for anything a bridge opens to the host itself;
        # only replies to host-opened connections and DNS to the address of the incoming bridge pass.
        policy = network.policy(self.env, [app_row("notlar", 62100)])
        chains = [o["chain"] for o in policy if "chain" in o]
        self.assertEqual([(c["name"], c["hook"], c["prio"], c["policy"]) for c in chains],
                         [("forward", "forward", -10, "accept"), ("input", "input", -10, "accept")])
        # nft lists chains first, then the rules chain by chain: the input rules come last.
        kinds = ["table" if "table" in o else "chain" if "chain" in o else o["rule"]["chain"] for o in policy]
        self.assertEqual(kinds, sorted(kinds, key=["table", "chain", "forward", "input"].index))
        m = lambda key, right, op="==": {"match": {"op": op, "left": {"meta": {"key": key}}, "right": right}}
        ct = lambda key, right, op="==": {"match": {"op": op, "left": {"ct": {"key": key}}, "right": right}}
        fib = {"match": {"op": "==", "left": {"fib": {"result": "type", "flags": ["daddr", "iif"]}}, "right": "local"}}
        dport = lambda proto: {"match": {"op": "==", "left": {"payload": {"protocol": proto, "field": "dport"}}, "right": 53}}
        self.assertEqual(self.input_rules(policy), [
            [m("iifname", "ksl*", "!="), {"return": None}],
            [ct("direction", "reply"), ct("state", "established", "in"), {"return": None}],
            [ct("direction", "reply"), ct("state", "related", "in"), {"return": None}],
            [m("nfproto", "ipv4"), m("l4proto", "udp"), dport("udp"), fib, {"return": None}],
            [m("nfproto", "ipv4"), m("l4proto", "tcp"), dport("tcp"), fib, {"return": None}],
            [{"drop": None}]])
        self.assertNotIn("62100", json.dumps(self.input_rules(policy)))

    def test_container_egress_rules_come_after_the_hot_path_and_replies(self):
        # DD-224: exit-node/WireGuard traffic leaves after one rule; replies pass before any egress drop;
        # then IPv6, tailscale0 and every block-list prefix, in list order.
        rules = self.egress_rules(network.policy(self.env, []))
        m = lambda key, right, op="==": {"match": {"op": op, "left": {"meta": {"key": key}}, "right": right}}
        self.assertEqual(rules[0], [m("iifname", "ksl*", "!="), m("oifname", "ksl*", "!="), {"return": None}])
        self.assertEqual([r[-1] for r in rules[1:3]], [{"return": None}] * 2)
        self.assertTrue(all(r[0]["match"]["left"] == {"ct": {"key": "direction"}} for r in rules[1:3]))
        egress = [m("iifname", "ksl*"), m("oifname", "ksl*", "!=")]
        self.assertEqual(rules[3], egress + [m("nfproto", "ipv6"), {"drop": None}])
        self.assertEqual(rules[4], [m("iifname", "ksl*"), m("oifname", "tailscale0"), {"drop": None}])
        blocks = self.env["VPN_BLOCK_DEST4"].split()
        dests = []
        for r in rules[5:5 + len(blocks)]:
            self.assertEqual(r[:2], egress)
            self.assertEqual(r[2]["match"]["left"], {"payload": {"protocol": "ip", "field": "daddr"}})
            self.assertEqual(r[-1], {"drop": None})
            right = r[2]["match"]["right"]
            dests.append(right if isinstance(right, str) else "%s/%d" % (right["prefix"]["addr"], right["prefix"]["len"]))
        self.assertEqual(dests, blocks)
        self.assertEqual(rules[5 + len(blocks)], [m("oifname", "ksl*", "!="), {"return": None}])
        # One rule per prefix, no literal list in the code: the block list has one owner (defaults.env).
        source = (DATA / "panel/master_container_network.py").read_text(encoding="utf-8")
        for literal in ("169.254", "172.16", "192.168"):
            self.assertNotIn(literal, source)
        single = self.egress_rules(network.policy(dict(self.env, VPN_BLOCK_DEST4="203.0.113.9/32 10.0.0.0/8"), []))
        self.assertEqual([r[2]["match"]["right"] for r in single[5:7]],
                         ["203.0.113.9", {"prefix": {"addr": "10.0.0.0", "len": 8}}])

    def test_container_egress_block_list_fails_closed(self):
        for value in (None, "", "fd00::/8", "10.0.0.1/8", "10.0.0.0/33", "not-a-network"):
            env = dict(self.env)
            if value is None:
                env.pop("VPN_BLOCK_DEST4")
            else:
                env["VPN_BLOCK_DEST4"] = value
            with self.subTest(value=value), self.assertRaises(network.NetworkError) as err:
                network.policy(env, [])
            self.assertEqual(err.exception.status, 503)

    def test_health_detects_a_missing_or_reordered_egress_rule(self):
        expected = network.policy(self.env, [])
        rules = [i for i, o in enumerate(expected) if "rule" in o]
        missing = [o for i, o in enumerate(expected) if i != rules[6]]
        self.assertFalse(network.same_policy(expected, {"nftables": copy.deepcopy(missing)}))
        swapped = copy.deepcopy(expected)
        swapped[rules[5]], swapped[rules[6]] = swapped[rules[6]], swapped[rules[5]]
        self.assertFalse(network.same_policy(expected, {"nftables": swapped}))
        self.assertTrue(network.same_policy(expected, {"nftables": copy.deepcopy(expected)}))

    def test_check_names_a_missing_guard_table(self):
        # DD-223: a container unit's start precondition says why the container waits.
        with self.assertRaises(network.NetworkError) as err:
            network.check(self.env, run=self.runner)
        self.assertEqual(str(err.exception), "Konteyner yönlendirme koruması eksik veya güncel değil.")

        def broken(argv, timeout=20):
            return 1, "", "Error: Operation not permitted"
        with self.assertRaises(network.NetworkError) as err:
            network.check(self.env, run=broken)
        self.assertEqual(str(err.exception), "Ağ durumu okunamadı: nft")

    def test_health_comparison_checks_rules_not_only_existence(self):
        expected = network.policy(self.env, [app_row("notlar")])
        actual = {"nftables": [{"metainfo": {"version": "test"}}] + copy.deepcopy(expected)}
        for row in actual["nftables"][1:]:
            next(iter(row.values()))["handle"] = 3
        self.assertTrue(network.same_policy(expected, actual))
        actual["nftables"][-1]["rule"]["expr"][-1] = {"accept": None}
        self.assertFalse(network.same_policy(expected, actual))

    def test_health_accepts_nft_inferred_protocols_but_not_a_changed_port(self):
        expected = network.policy(self.env, [])
        canonical = copy.deepcopy(expected)
        for obj in canonical:
            if "rule" in obj:
                obj["rule"]["expr"] = [e for e in obj["rule"]["expr"]
                                       if e.get("match", {}).get("left", {}).get("meta", {}).get("key") != "l4proto"]
        self.assertTrue(network.same_policy(expected, {"nftables": canonical}), "nft elides l4proto implied by the port match")
        changed = copy.deepcopy(canonical)
        for obj in changed:
            for e in obj.get("rule", {}).get("expr", []):
                if e.get("match", {}).get("left", {}).get("payload", {}).get("field") == "dport":
                    e["match"]["right"] = 5353
        self.assertFalse(network.same_policy(expected, {"nftables": changed}))


if __name__ == "__main__":
    unittest.main()
