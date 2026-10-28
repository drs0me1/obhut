"""The container guard's owned nft policy (DD-223, DD-224, DD-229) and its input, the application records with
their access rows (rebuild DD-271, phases 3 and 4): the per-address ingress permit of a raw publication (DD-217),
none for an address the host does not have, and fail closed for anything else; no host mutations."""
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


def app_row(app, *pools, raw=()):
    """A guard_input row: pool ports on 127.0.0.1, raw publications as (scope, address, protocol, host port, port)."""
    return {"app": app, "interface": "ksl" + "%010x" % (abs(hash(app)) % 16 ** 10),
            "publications": [{"service": "web", "port": 8080 + n, "protocol": "tcp", "scope": "local", "host_ip": "127.0.0.1",
                              "host_port": pool} for n, pool in enumerate(pools)]
            + [{"service": "web", "port": port, "protocol": protocol, "scope": scope, "host_ip": address, "host_port": host}
               for scope, address, protocol, host, port in raw]}


TAIL, WAN = "100.64.0.2", "203.0.113.10"


def addresses(tail=(TAIL,), wan=(WAN,), routes=None):
    """`ip -j` as the guard reads it: tailscale0's and eth0's IPv4 addresses and the default route."""
    def answer(argv):
        if argv[:5] == ["ip", "-j", "address", "show", "dev"]:
            found = {"tailscale0": tail, "eth0": wan}.get(argv[5])
            if found is None:
                return 1, "", "Device does not exist"
            return 0, json.dumps([{"addr_info": [{"family": "inet", "scope": "global", "local": a} for a in found]}]), ""
        if argv[:5] == ["ip", "-j", "route", "show", "default"]:
            return 0, json.dumps([{"dev": "eth0", "metric": 0}] if routes is None else routes), ""
        return None
    return answer


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(app_fixtures.env(self.root), VPN_BLOCK_DEST4=network.env_read(DATA / "config/defaults.env")["VPN_BLOCK_DEST4"])
        (self.root / "run").mkdir()
        self.calls = []
        self.applied = None
        self.ip = addresses()

    def runner(self, argv, timeout=20):
        """nft as the guard sees it: what the last apply loaded is what a list shows; ip from self.ip."""
        self.calls.append(list(argv))
        if argv[0] == "ip" and self.ip and self.ip(list(argv)) is not None:
            return self.ip(list(argv))
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
                                 "publications": [{"service": "web", "port": 8080, "protocol": "tcp", "scope": "local",
                                                   "host_ip": "127.0.0.1", "host_port": record["places"]["ports"]["web:8080/tcp"]}]}])
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

    def test_any_other_publication_fails_closed(self):
        row = app_row("notlar", 62100)
        bad = [{"host_ip": address} for address in ("0.0.0.0", "100.64.0.2", "192.0.2.1", "", "::1")]
        bad += [{"protocol": "udp"}, {"protocol": "sctp"}, {"scope": "public"}, {"scope": None}, {"host_port": 0},
                {"port": 70000}, {"host_port": "62100"}, {"extra": 1}]
        bad += [{"scope": scope, "host_ip": address} for scope in ("tailscale", "internet")
                for address in ("127.0.0.1", "0.0.0.0", "224.0.0.1", "169.254.169.254", "fd7a:115c:a1e0::1", " " + TAIL, 7)]
        for change in bad:
            pub = dict(row["publications"][0], **change)
            with self.subTest(change=change), patch.object(apps, "guard_input", return_value=[dict(row, publications=[pub])]), \
                    self.assertRaises(network.NetworkError) as err:
                network.applications(self.env)
            self.assertEqual(err.exception.status, 503)
        missing = {k: v for k, v in row["publications"][0].items() if k != "scope"}
        with patch.object(apps, "guard_input", return_value=[dict(row, publications=[missing])]), \
                self.assertRaises(network.NetworkError):
            network.applications(self.env)
        with patch.object(apps, "guard_input", return_value=[dict(app_row("notlar"), interface="eth0")]), \
                self.assertRaises(network.NetworkError):
            network.applications(self.env)

    def permits(self, policy):
        return [r for r in self.egress_rules(policy) if any(e.get("match", {}).get("right") == "dnat" for e in r)]

    def test_a_raw_publication_is_let_in_only_as_its_own_dnat(self):
        # DD-217's rule: out to the bridge, in from the scope's interface, IPv4, the protocol, a DNAT of exactly the
        # original address and host port, to the container port.
        row = app_row("notlar", 62100, raw=[("tailscale", TAIL, "udp", 16881, 6881), ("internet", WAN, "tcp", 18443, 8443)])
        policy = network.policy(self.env, [row], run=self.runner)
        m = lambda key, right, op="==": {"match": {"op": op, "left": {"meta": {"key": key}}, "right": right}}
        ct = lambda key, right, op="==", **kw: {"match": {"op": op, "left": {"ct": dict(key=key, **kw)}, "right": right}}
        port = lambda proto, value: {"match": {"op": "==", "left": {"payload": {"protocol": proto, "field": "dport"}}, "right": value}}
        expected = [[m("oifname", row["interface"]), m("iifname", ingress), m("nfproto", "ipv4"), m("l4proto", proto),
                     ct("direction", "original"), ct("status", "dnat", "in"), ct("daddr", address, family="ip", dir="original"),
                     ct("proto-dst", host, dir="original"), port(proto, container), {"return": None}]
                    for ingress, address, proto, host, container in (("tailscale0", TAIL, "udp", 16881, 6881),
                                                                     ("eth0", WAN, "tcp", 18443, 8443))]
        self.assertEqual(self.permits(policy), expected)
        rules = self.egress_rules(policy)
        self.assertEqual(rules[-3:], expected + [[{"drop": None}]], "after the bridge's own return, before the final drop")
        self.assertNotIn("62100", json.dumps(policy), "the pool port needs no permit")
        # The guard reads the host's addresses itself, never from state.env.
        self.assertIn(["ip", "-j", "address", "show", "dev", "tailscale0"], self.calls)
        self.assertIn(["ip", "-j", "route", "show", "default"], self.calls)
        with patch.object(apps, "guard_input", return_value=[row]):
            network.apply(self.env, run=self.runner)
            self.assertTrue(network.check(self.env, run=self.runner))
        # Without a raw publication no address is read.
        self.calls.clear()
        network.policy(self.env, [app_row("notlar", 62100)], run=self.runner)
        self.assertFalse([c for c in self.calls if c[0] == "ip"])

    def test_an_address_the_host_does_not_have_gets_no_permit(self):
        row = app_row("notlar", raw=[("tailscale", TAIL, "tcp", 18080, 8080), ("internet", WAN, "udp", 18081, 8081)])
        cases = {"an older Tailscale address": (addresses(tail=("100.64.0.9",)), ["eth0"]),
                 "Tailscale not ready": (addresses(tail=()), ["eth0"]),
                 "two Tailscale addresses": (addresses(tail=(TAIL, "100.64.0.3")), ["eth0"]),
                 "no tailscale0": (addresses(tail=None), ["eth0"]),
                 "an older WAN address": (addresses(wan=("198.51.100.4",)), ["tailscale0"]),
                 "two default routes": (addresses(routes=[{"dev": "eth0", "metric": 0}, {"dev": "eth1", "metric": 0}]),
                                        ["tailscale0"]),
                 "the default route on a VPN": (addresses(routes=[{"dev": "wg0"}]), ["tailscale0"])}
        for what, (ip, ingress) in cases.items():
            with self.subTest(what=what):
                self.ip = ip
                permits = self.permits(network.policy(self.env, [row], run=self.runner))
                self.assertEqual([r[1]["match"]["right"] for r in permits], ingress)
        # A changed address changes the expected policy: the check fails and the next apply follows it.
        self.ip = addresses()
        with patch.object(apps, "guard_input", return_value=[row]):
            network.apply(self.env, run=self.runner)
            self.ip = addresses(tail=("100.64.0.9",))
            with self.assertRaises(network.NetworkError):
                network.check(self.env, run=self.runner)

    def test_the_guard_reads_the_open_raw_rows_on_the_addresses_state_env_names(self):
        rows = {"web:8080/tcp": {"tur": "adres", "ad": "notlar", "tailscale_portu": None, "internet": ""},
                "db:5432/tcp": {"tur": "ham", "kapsam": "kapali", "port": 5432}}
        app_fixtures.record(self.env, rows=rows)
        self.assertEqual([p["scope"] for p in network.applications(self.env)[0]["publications"]], ["local"], "closed: nothing")
        records = apps.Records(self.env)
        for scope, address in (("tailscale", self.env["TAILSCALE_IPV4"]), ("internet", self.env["WAN_IPV4"])):
            with self.subTest(scope=scope):
                records.write("notlar", rows=dict(rows, **{"db:5432/tcp": {"tur": "ham", "kapsam": scope, "port": 15432}}))
                [_local, raw] = network.applications(self.env)[0]["publications"]
                self.assertEqual(raw, {"service": "db", "port": 5432, "protocol": "tcp", "scope": scope, "host_ip": address,
                                       "host_port": 15432})
        # An open raw row whose address state.env does not hold stops the guard (fail closed).
        with self.assertRaises(network.NetworkError) as err:
            network.applications(dict(self.env, WAN_IPV4=""))
        self.assertEqual(err.exception.status, 503)
        # A pool port without its address row, or rows without the file, fail closed too.
        (records.dir("notlar") / "erisim.json").unlink()
        with self.assertRaises(network.NetworkError):
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
