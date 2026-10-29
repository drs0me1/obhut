#!/usr/bin/env python3
"""The project's independent forwarding guard for Konsol's container bridges, and (DD-294) for every published port.

Netavark owns DNAT/SNAT. We own only one nft inet table with a forward and an input
chain at priority -10; an ACCEPT in Netavark/Tailscale's filter chains cannot bypass
its DROP. The input chain closes the host itself to containers (DD-229). No foreign
table is flushed. The locked writers (master-firewall and the container worker) install it;
container units only check it before they start, including at boot, and retry until it is in
place (DD-223).

Its input is the application records (master_applications.guard_input): each application's bridge
and its publications. An address row's pool port is published on 127.0.0.1, which the host reaches
through OUTPUT DNAT and needs no forward rule. An open raw row (rebuild phase 4) is published on the
Tailscale or the WAN IPv4 address: it gets one ingress permit per publication (out to the application's
bridge, in from tailscale0 or the WAN interface, IPv4, its protocol, a DNAT of exactly that original
address and host port to the container port; DD-217's rule). The permit is written only while the
address is the host's now (read from the interfaces, not from state.env): one the host no longer has
gets none, so nothing reaches it (DD-217's lesson: refusing such a mismatch stopped the firewall), and
the address refresh (master_container_worker --adres-yenile) moves the unit. Any other publication
(another scope, an address that is not an IPv4 address, a pool port off loopback) fails the whole guard
closed. IPv6 ingress to managed bridges is denied.

DD-294: Konsol manages every container now, also one it did not install, and such a container may publish a
port on any address; Netavark's DNAT then takes the connection past the host's input rules. A connection that
came in on the WAN interface and was DNAT'd to anything but Konsol's own bridges is dropped (from Tailscale it
passes); a missing or invalid WAN interface fails the guard closed like any other missing value.

  apply(env, run=runner); check(env, run=runner)
runner(argv, timeout=20) returns CompletedProcess or (rc, stdout, stderr).

References: docs.podman.io/en/v5.4.2/markdown/podman-run.1.html (--publish);
www.netfilter.org/projects/nftables/manpage.html (hook priorities and ct tuples);
manpages.debian.org/trixie/libnftables1/libnftables-json.5.en.html.
"""
import argparse
import ipaddress
import json
import os
import re
import stat
import subprocess
import tempfile


class NetworkError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def _run(argv, timeout=20):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def _result(run, argv, timeout=20):
    try:
        result = (run or _run)(argv, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as err:
        raise NetworkError("Ağ komutu çalıştırılamadı: " + argv[0], 503) from err
    if isinstance(result, tuple):
        return result
    return result.returncode, result.stdout or "", result.stderr or ""


def _json(run, argv):
    rc, out, _ = _result(run, argv)
    if rc:
        raise NetworkError("Ağ durumu okunamadı: " + argv[0], 503)
    try:
        return json.loads(out)
    except (ValueError, TypeError) as err:
        raise NetworkError("Ağ durumu geçersiz: " + argv[0], 503) from err


def _iface(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}", value):
        raise NetworkError("Ağ arayüzü adı geçersiz.")
    return value


def _config(env):
    table = env.get("KONTEYNER_NFT_TABLE", "")
    prefix = env.get("KONTEYNER_BRIDGE_PREFIX", "")
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,31}", table) or not re.fullmatch(r"[a-z][a-z0-9]{1,4}", prefix):
        raise NetworkError("Konteyner ağ koruması yapılandırılmamış.", 503)
    return table, prefix


def _addresses(env, iface, run):
    rows = _json(run, ["ip", "-j", "address", "show", "dev", _iface(iface)])
    if not isinstance(rows, list):
        raise NetworkError("Arayüz adresleri okunamadı.", 503)
    addresses = []
    for row in rows:
        for address in row.get("addr_info", []):
            if address.get("family") != "inet" or address.get("scope") != "global":
                continue
            if any(flag in address.get("flags", []) for flag in ("tentative", "dadfailed")):
                continue
            try:
                parsed = ipaddress.IPv4Address(address["local"])
            except (KeyError, ValueError) as err:
                raise NetworkError("Arayüzde geçersiz IPv4 adresi.", 503) from err
            if parsed.is_unspecified or parsed.is_loopback or parsed.is_multicast or parsed.is_link_local:
                raise NetworkError("Arayüzde kullanılamayan IPv4 adresi.", 503)
            addresses.append(str(parsed))
    return sorted(set(addresses))


def tailscale_address(env, run=None):
    addresses = _addresses(env, env.get("TAILSCALE_IF", ""), run)
    if len(addresses) != 1 or ipaddress.ip_address(addresses[0]) not in ipaddress.ip_network("100.64.0.0/10"):
        raise NetworkError("Tailscale IPv4 adresi hazır değil; port açılmadı.", 409)
    return addresses[0]


def wan_addresses(env, run=None):
    rows = _json(run, ["ip", "-j", "route", "show", "default"])
    if not isinstance(rows, list):
        raise NetworkError("İnternet arayüzü bulunamadı.", 503)
    rows = sorted((r for r in rows if isinstance(r, dict) and r.get("dev")), key=lambda r: r.get("metric", 0))
    if not rows or (len(rows) > 1 and rows[0].get("metric", 0) == rows[1].get("metric", 0) and rows[0]["dev"] != rows[1]["dev"]):
        raise NetworkError("İnternet arayüzü belirsiz; port açılmadı.", 409)
    iface = _iface(rows[0]["dev"])
    _, prefix = _config(env)
    if iface == env.get("TAILSCALE_IF") or iface.startswith((prefix, "wg")):
        raise NetworkError("İnternet portu VPN veya konteyner arayüzüne açılamaz.", 409)
    addresses = _addresses(env, iface, run)
    if not addresses:
        raise NetworkError("İnternet IPv4 adresi hazır değil; port açılmadı.", 409)
    return iface, addresses


def current_addresses(env, run=None):
    """{scope: (ingress interface, [the host's IPv4 addresses of it now])}: the Tailscale address and the WAN
    addresses as the interfaces have them. Not ready, ambiguous or unreadable is no address (no permit)."""
    found = {}
    try:
        found["tailscale"] = (_iface(env.get("TAILSCALE_IF", "")), [tailscale_address(env, run)])
    except NetworkError:
        found["tailscale"] = (None, [])
    try:
        found["internet"] = wan_addresses(env, run)
    except NetworkError:
        found["internet"] = (None, [])
    return found


def _read(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            info = os.fstat(fh.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 1048576:
                raise NetworkError("Konteyner ağ kaydı geçersiz.", 503)
            return fh.read(1048577)
    except (OSError, UnicodeError) as err:
        raise NetworkError("Konteyner ağ kaydı okunamadı.", 503) from err


def env_read(path):
    out = {}
    for line in _read(path).splitlines():
        key, sep, value = line.partition("=")
        if sep and re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            out[key] = value.strip().strip('"')
    return out


SCOPES = ("local", "tailscale", "internet")


def _publication(pub):
    """A publication the guard understands: a pool port on 127.0.0.1 (TCP) or a raw port on an IPv4 address."""
    def port(value):
        return type(value) is int and 0 < value < 65536
    if not (isinstance(pub, dict) and set(pub) == {"service", "port", "protocol", "scope", "host_ip", "host_port"}
            and pub["scope"] in SCOPES and pub["protocol"] in ("tcp", "udp") and port(pub["port"]) and port(pub["host_port"])):
        return False
    if pub["scope"] == "local":
        return pub["host_ip"] == "127.0.0.1" and pub["protocol"] == "tcp"
    try:
        address = ipaddress.IPv4Address(pub["host_ip"])
    except (ValueError, TypeError):
        return False
    return str(address) == pub["host_ip"] and not (address.is_loopback or address.is_unspecified or address.is_multicast
                                                   or address.is_link_local)


def applications(env):
    """Each application's bridge and publications, from its record (fail closed on anything unreadable)."""
    import master_applications
    try:
        rows = master_applications.guard_input(env)
    except Exception as err:  # noqa: BLE001 - fail closed: a record the guard cannot read keeps the old rules
        raise NetworkError("Uygulama kayıtları okunamadı; ağ kuralları korunuyor.", 503) from err
    _, prefix = _config(env)
    for row in rows:
        if not re.fullmatch(re.escape(prefix) + r"[0-9a-f]{10}", str(row.get("interface", ""))):
            raise NetworkError("Uygulama köprüsünün adı geçersiz.", 503)
        for pub in row.get("publications", []):
            if not _publication(pub):
                raise NetworkError("Uygulama yayını yalnız 127.0.0.1 ya da sunucunun Tailscale veya internet IPv4 "
                                   "adresi üzerinde olabilir; ağ kuralları korunuyor.", 503)
    return rows


def _match(left, right, op="=="):
    return {"match": {"op": op, "left": left, "right": right}}


def egress_blocks(env):
    """DD-224: destinations a container may not open a connection to: the VPN block list (IPv4,
    defaults.env's single owner). Missing or invalid fails closed: no guard is written."""
    blocks = []
    for item in env.get("VPN_BLOCK_DEST4", "").split():
        try:
            blocks.append(ipaddress.IPv4Network(item, strict=True))
        except ValueError as err:
            raise NetworkError("Konteyner çıkış engeli listesi geçersiz; kurulumu yeniden çalıştırın.", 503) from err
    if not blocks:
        raise NetworkError("Konteyner çıkış engeli listesi yok; kurulumu yeniden çalıştırın.", 503)
    return blocks


def policy(env, apps, run=None):
    """Return nft's JSON table/chain/rule objects, suitable for exact health comparison. The host's
    Tailscale and WAN addresses are read (run) only when a raw publication needs them."""
    table, prefix = _config(env)
    owner = {"family": "inet", "table": table}
    objects = [{"table": {"family": "inet", "name": table}},
               {"chain": dict(owner, name="forward", type="filter", hook="forward", prio=-10, policy="accept")},
               {"chain": dict(owner, name="input", type="filter", hook="input", prio=-10, policy="accept")}]
    inputs = []
    def rule(*expr):
        objects.append({"rule": dict(owner, chain="forward", expr=list(expr))})
    meta = lambda key: {"meta": {"key": key}}
    ct = lambda key, **kw: {"ct": dict(key=key, **kw)}
    # DD-229: a container opens nothing on the host itself (any host address: bridge gateway, WAN,
    # Tailscale, WireGuard, loopback through route_localnet). Only replies to connections the host
    # opened and DNS to its own bridge gateway (aardvark-dns) are let in. This is the project's own
    # input guard; it holds even if the host INPUT chain is missing or another chain accepts first.
    def input_rule(*expr):
        inputs.append({"rule": dict(owner, chain="input", expr=list(expr))})
    input_rule(_match(meta("iifname"), prefix + "*", "!="), {"return": None})
    for state in ("established", "related"):
        input_rule(_match(ct("direction"), "reply"), _match(ct("state"), state, "in"), {"return": None})
    for protocol in ("udp", "tcp"):
        input_rule(_match(meta("nfproto"), "ipv4"), _match(meta("l4proto"), protocol),
                   _match({"payload": {"protocol": protocol, "field": "dport"}}, 53),
                   _match({"fib": {"result": "type", "flags": ["daddr", "iif"]}}, "local"), {"return": None})
    input_rule({"drop": None})
    # DD-294: a port published by a container Obhut did not install is not reachable from the internet: a connection
    # in on the WAN interface, DNAT'd to anything but Konsol's bridges, is dropped before any other rule. Konsol's own
    # raw rows reach their bridges through the permits below; the exit node and WireGuard are never DNAT'd.
    rule(_match(meta("iifname"), _iface(env.get("WAN_INTERFACE", ""))), _match(meta("oifname"), prefix + "*", "!="),
         _match(ct("direction"), "original"), _match(ct("status"), "dnat", "in"), {"drop": None})
    # DD-181/DD-224: traffic that neither leaves nor enters a bridge (exit node, WireGuard) passes after one rule.
    rule(_match(meta("iifname"), prefix + "*", "!="), _match(meta("oifname"), prefix + "*", "!="), {"return": None})
    # Only replies to container-originated traffic bypass publication checks. Original-direction
    # established connections still lose access immediately when their publication is revoked.
    # They come before the egress drops: replies to a Tailscale or WAN publication leave the bridge.
    for state in ("established", "related"):
        rule(_match(ct("direction"), "reply"), _match(ct("state"), state, "in"), {"return": None})
    # DD-224: a container may open connections to the internet, but not to the tailnet (it would leave
    # as this exit node), private, CGNAT or link-local ranges, nor over IPv6 (the bridges are IPv4-only).
    egress = lambda: [_match(meta("iifname"), prefix + "*"), _match(meta("oifname"), prefix + "*", "!=")]
    rule(*egress(), _match(meta("nfproto"), "ipv6"), {"drop": None})
    rule(_match(meta("iifname"), prefix + "*"), _match(meta("oifname"), _iface(env["TAILSCALE_IF"])), {"drop": None})
    for block in egress_blocks(env):
        address = str(block.network_address)
        rule(*egress(), _match({"payload": {"protocol": "ip", "field": "daddr"}},
                               address if block.prefixlen == 32 else {"prefix": {"addr": address, "len": block.prefixlen}}),
             {"drop": None})
    rule(_match(meta("oifname"), prefix + "*", "!="), {"return": None})
    # Bridge-local peers (an application's services) are governed by Netavark's network isolation; no
    # blanket interbridge permit. Publications on 127.0.0.1 reach the bridge from the host's OUTPUT path.
    for bridge in sorted({row["interface"] for row in apps}):
        rule(_match(meta("iifname"), bridge), _match(meta("oifname"), bridge), {"return": None})

    # DD-217: a raw publication is let in only as the DNAT Podman made for it: out to its own bridge, in from
    # the scope's interface, to exactly the original address and host port, to the container port.
    def publish(bridge, ingress, address, pub):
        rule(_match(meta("oifname"), bridge), _match(meta("iifname"), ingress),
             _match(meta("nfproto"), "ipv4"), _match(meta("l4proto"), pub["protocol"]),
             _match(ct("direction"), "original"), _match(ct("status"), "dnat", "in"),
             _match(ct("daddr", family="ip", dir="original"), address),
             _match(ct("proto-dst", dir="original"), pub["host_port"]),
             _match({"payload": {"protocol": pub["protocol"], "field": "dport"}}, pub["port"]),
             {"return": None})
    current = None
    for row in sorted(apps, key=lambda r: r["app"]):
        for pub in row.get("publications", []):
            if pub["scope"] == "local":
                continue
            if current is None:
                current = current_addresses(env, run)
            ingress, addresses = current[pub["scope"]]
            # An address the host does not have now cannot be reached: no permit (stricter, never wider).
            if ingress and pub["host_ip"] in addresses:
                publish(row["interface"], ingress, pub["host_ip"], pub)
    rule({"drop": None})
    # nft lists chains before rules, and rules chain by chain; the health check compares in that order.
    return objects + inputs


def same_policy(expected, actual):
    def canonical_expr(expr):
        # nft list elides protocol selectors implied by a typed address/payload,
        # and the ct-address family. Normalize only these provable redundancies;
        # the address, port, direction and verdict must still match exactly.
        protocols = set()
        families = set()
        for e in expr:
            match = e.get("match", {})
            left = match.get("left", {})
            if match.get("op") != "==":
                continue
            payload = left.get("payload", {})
            if payload.get("protocol") in ("tcp", "udp"):
                protocols.add(payload["protocol"])
            ct = left.get("ct", {})
            if ct.get("key") == "daddr":
                try:
                    address = ipaddress.ip_address(match.get("right"))
                except ValueError:
                    continue
                family = "ip" if address.version == 4 else "ip6"
                if ct.get("family", family) == family:
                    families.add("ipv4" if address.version == 4 else "ipv6")
                    ct.pop("family", None)
        return [e for e in expr if not (
            e.get("match", {}).get("op") == "==" and (
                e["match"].get("left") == {"meta": {"key": "nfproto"}} and e["match"].get("right") in families
                or e["match"].get("left") == {"meta": {"key": "l4proto"}} and e["match"].get("right") in protocols))]
    def clean(value):
        if isinstance(value, list):
            return [clean(x) for x in value]
        if isinstance(value, dict):
            result = {k: clean(v) for k, v in value.items() if k not in ("handle", "index", "position")}
            if "expr" in result:
                result["expr"] = canonical_expr(result["expr"])
            return result
        return value
    if not isinstance(actual, dict) or not isinstance(actual.get("nftables"), list):
        return False
    rows = [x for x in actual["nftables"] if "metainfo" not in x]
    return clean(expected) == clean(rows)


def check(env, run=None):
    table, _ = _config(env)
    expected = policy(env, applications(env), run=run)
    rc, out, err = _result(run, ["nft", "-j", "list", "table", "inet", table])
    if rc and re.search(r"No such file|does not exist", err, re.I):
        raise NetworkError("Konteyner yönlendirme koruması eksik veya güncel değil.", 503)
    if rc:
        raise NetworkError("Ağ durumu okunamadı: nft", 503)
    try:
        actual = json.loads(out)
    except (ValueError, TypeError) as error:
        raise NetworkError("Ağ durumu geçersiz: nft", 503) from error
    if not same_policy(expected, actual):
        raise NetworkError("Konteyner yönlendirme koruması eksik veya güncel değil.", 503)
    return True


def apply(env, run=None):
    table, _ = _config(env)
    objects = policy(env, applications(env), run=run)
    rc, _, err = _result(run, ["nft", "-j", "list", "table", "inet", table])
    if rc and not re.search(r"No such file|does not exist", err, re.I):
        raise NetworkError("Konteyner güvenlik duvarı okunamadı.", 503)
    commands = [] if rc else [{"delete": {"table": {"family": "inet", "name": table}}}]
    commands.extend({"add": item} for item in objects)
    # Delete + rebuild is ONE netlink transaction; a failed parse/commit retains the previous table.
    with tempfile.NamedTemporaryFile(mode="w", prefix="container-net-", suffix=".json", dir=env["RUNTIME_DIR"], encoding="utf-8") as fh:
        json.dump({"nftables": commands}, fh)
        fh.flush()
        for argv in (["nft", "-j", "-c", "-f", fh.name], ["nft", "-j", "-f", fh.name]):
            rc, _, _ = _result(run, argv)
            if rc:
                raise NetworkError("Konteyner yönlendirme koruması uygulanamadı; önceki kurallar korunuyor.", 503)
    check(env, run=run)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("operation", choices=("apply", "check"), nargs="?", default="apply")
    parser.add_argument("--check", action="store_true", dest="check_only")
    args = parser.parse_args()
    try:
        env = env_read(args.state)
        (check if args.check_only or args.operation == "check" else apply)(env)
    except (NetworkError, KeyError) as err:
        parser.exit(1, "HATA: %s\n" % err)


if __name__ == "__main__":
    main()
