#!/usr/bin/env python3
"""Actual forwarding/NAT acceptance in disposable nested network namespaces.

Run as root: unshare --net --fork python3 Data/tests/containers-network-linux.py
Requires iproute2, nftables and Python; never changes the host network namespace.
This exercises our actual nft guard with Netavark-shaped DNAT/SNAT and permissive
foreign filter chains, including what a container may open itself (DD-224): the
internet yes; tailnet, WireGuard, private, link-local and IPv6 destinations no.
DD-229: the container opens nothing on the host itself, only DNS on its bridge gateway.
DD-271 (phases 3 and 4): the guard's input is an application record with its access rows. The
address row is published on 127.0.0.1; an open raw row on the Tailscale or the WAN address passes
only as its own DNAT, from its own interface (TCP and UDP); a closed raw row, another interface,
another address or port, a direct packet to the bridge and an address the host no longer has find
no permit; a publication the guard does not understand keeps the previous table.
Real Podman/Quadlet lifecycle is a separate live check.
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
spec = importlib.util.spec_from_file_location("container_network", DATA / "panel/master_container_network.py")
net = importlib.util.module_from_spec(spec)
spec.loader.exec_module(net)


def cmd(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=15, **kw).stdout.strip()


SERVER = r'''
import socket, threading, time
def client(c):
    with c:
        while True:
            data=c.recv(1024)
            if not data: return
            c.sendall(data)
def serve(kind, port):
    s=socket.socket(socket.AF_INET6,kind)
    s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0)
    s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('::',port))
    if kind == socket.SOCK_STREAM:
        s.listen()
        while True:
            c,_=s.accept();threading.Thread(target=client,args=(c,),daemon=True).start()
    else:
        while True:
            d,a=s.recvfrom(1024);s.sendto(d,a)
for k in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
    for p in (8080, 8081, 8082):
        threading.Thread(target=serve,args=(k,p),daemon=True).start()
time.sleep(300)
'''
# DD-229: listeners on the host itself (any address), plus a stand-in for aardvark-dns on port 53.
HOST_SERVER = r'''
import socket, sys, threading, time
port = int(sys.argv[1])
def client(c):
    with c:
        while True:
            data = c.recv(1024)
            if not data: return
            c.sendall(data)
def serve(kind):
    s = socket.socket(socket.AF_INET, kind)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    if kind == socket.SOCK_STREAM:
        s.listen()
        while True:
            c, _ = s.accept(); threading.Thread(target=client, args=(c,), daemon=True).start()
    else:
        while True:
            d, a = s.recvfrom(1024); s.sendto(d, a)
for k in (socket.SOCK_STREAM, socket.SOCK_DGRAM): threading.Thread(target=serve, args=(k,), daemon=True).start()
time.sleep(300)
'''
PROBE = r'''
import socket,sys
ip,port,proto=sys.argv[1:]
s=socket.socket(socket.AF_INET6 if ':' in ip else socket.AF_INET,socket.SOCK_DGRAM if proto=='udp' else socket.SOCK_STREAM)
s.settimeout(.45)
try:
    s.connect((ip,int(port)));s.send(b'container-policy-probe');ok=s.recv(128)==b'container-policy-probe'
except OSError: ok=False
finally: s.close()
sys.exit(0 if ok else 1)
'''


def main():
    if os.geteuid() != 0 or os.readlink("/proc/self/ns/net") == os.readlink("/proc/1/ns/net"):
        raise SystemExit("Run as root in a separate network namespace (unshare --net --fork).")
    children = []
    cmd("ip", "link", "set", "lo", "up")
    # The simulated NAT needs Netavark's loopback-routing prerequisite too. This
    # changes only the fixture namespace, never the host's sysctl configuration.
    cmd("sysctl", "-q", "-w", "net.ipv4.ip_forward=1", "net.ipv6.conf.all.forwarding=1",
        "net.ipv4.conf.all.route_localnet=1")
    def peer(iface, v4, v6, bridge=None):
        process = subprocess.Popen(["unshare", "--net", "sleep", "300"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(process)
        until = time.monotonic() + 5
        while os.readlink(f"/proc/{process.pid}/ns/net") == os.readlink("/proc/self/ns/net"):
            if time.monotonic() > until:
                raise AssertionError("child network namespace did not start")
            time.sleep(.01)
        remote = "p" + str(len(children))
        cmd("ip", "link", "add", iface, "type", "veth", "peer", "name", remote)
        cmd("ip", "link", "set", remote, "netns", str(process.pid))
        if bridge:
            cmd("ip", "link", "set", iface, "master", bridge)
        cmd("ip", "link", "set", iface, "up")
        hostdev = bridge or iface
        cmd("ip", "addr", "add", v4 + ".1/24", "dev", hostdev)
        cmd("ip", "-6", "addr", "add", v6 + "::1/64", "dev", hostdev, "nodad")
        prefix = ["nsenter", "-t", str(process.pid), "-n"]
        cmd(*prefix, "ip", "link", "set", "lo", "up")
        cmd(*prefix, "ip", "addr", "add", v4 + ".2/24", "dev", remote)
        cmd(*prefix, "ip", "-6", "addr", "add", v6 + "::2/64", "dev", remote, "nodad")
        cmd(*prefix, "ip", "link", "set", remote, "up")
        cmd(*prefix, "ip", "route", "add", "default", "via", v4 + ".1")
        cmd(*prefix, "ip", "-6", "route", "add", "default", "via", v6 + "::1")
        return prefix
    probes = 0
    def probe(prefix, address, port, protocol, allowed):
        nonlocal probes
        got = subprocess.run([*prefix, "python3", "-c", PROBE, address, str(port), protocol], capture_output=True, text=True, timeout=3)
        if (got.returncode == 0) != allowed:
            raise AssertionError(f"{prefix or 'host'} -> {address}:{port}/{protocol}: wanted {'allow' if allowed else 'deny'}, rc={got.returncode}, {got.stderr}")
        probes += 1
    try:
        with tempfile.TemporaryDirectory(prefix="container-network-") as root:
            env = dict(KONTEYNER_STATE_DIR=root, RUNTIME_DIR=root, UYGULAMA_STATE_DIR=root + "/uygulamalar",
                       KONTEYNER_BRIDGE_PREFIX="ksl", KONTEYNER_NFT_TABLE="master_containers", TAILSCALE_IF="tailscale0", WAN_INTERFACE="eth0",
                       TAILSCALE_IPV4="100.64.0.1", WAN_IPV4="192.0.2.1",
                       VPN_BLOCK_DEST4=net.env_read(DATA / "config/defaults.env")["VPN_BLOCK_DEST4"])
            import master_applications
            bridge = master_applications.interface(env, "probe")
            wan = peer("eth0", "192.0.2", "2001:db8:1")
            tail = peer("tailscale0", "100.64.0", "fd7a:115c:a1e0:1")
            wg = peer("wg0", "10.8.0", "fd00:3")
            other = peer("eth1", "198.51.100", "2001:db8:4")
            lan = peer("eth2", "192.168.77", "2001:db8:77")
            meta = peer("eth3", "169.254.169", "2001:db8:169")
            cmd("ip", "link", "add", bridge, "type", "bridge")
            cmd("ip", "link", "set", bridge, "up")
            ctr = peer("ceth", "10.250.0", "fd00:250", bridge)
            cmd("ip", "route", "add", "default", "via", "192.0.2.2", "dev", "eth0")
            server = subprocess.Popen([*ctr, "python3", "-c", SERVER], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            children.append(server)
            deadline = time.monotonic() + 5
            for port in (8080, 8081, 8082):
                while True:
                    try:
                        with socket.create_connection(("10.250.0.2", port), timeout=.1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise AssertionError("fixture echo server not ready: %d" % port)
                        time.sleep(.05)
            # The application record the guard reads: an address on the loopback pool (8080/tcp), raw rows open to
            # Tailscale (8081, TCP and UDP, host port 18081) and to the internet (8082, host port 18082), and a
            # closed raw row (8080/udp) that a foreign NAT rule points at anyway.
            directory = Path(env["UYGULAMA_STATE_DIR"]) / "probe"
            directory.mkdir(parents=True, mode=0o700)
            Path(env["UYGULAMA_STATE_DIR"]).chmod(0o700)
            path, rows_path = directory / "yerler.json", directory / "erisim.json"
            path.write_text(json.dumps({"revision": "a" * 32, "stopped": False, "ports": {"web:8080/tcp": 18080},
                                        "secrets": {}, "images": {}}))
            path.chmod(0o600)
            rows = {"web:8080/tcp": {"tur": "adres", "ad": "probe", "tailscale_portu": None, "internet": ""},
                    "web:8080/udp": {"tur": "ham", "kapsam": "kapali", "port": 18084}}
            for protocol in ("tcp", "udp"):
                rows["web:8081/%s" % protocol] = {"tur": "ham", "kapsam": "tailscale", "port": 18081}
                rows["web:8082/%s" % protocol] = {"tur": "ham", "kapsam": "internet", "port": 18082}

            def write_rows(value):
                rows_path.write_text(json.dumps({"satirlar": value}))
                rows_path.chmod(0o600)
            write_rows(rows)
            # Prefix guards must win over both earlier and later foreign ACCEPT chains.
            nat = ["table inet fixture {",
                   "chain early { type filter hook forward priority -20; policy accept; accept; }",
                   "chain late { type filter hook forward priority 0; policy accept; accept; }",
                   "chain pre { type nat hook prerouting priority -100; policy accept;"]
            for protocol in ("tcp", "udp"):
                # Podman's DNAT for each publication; plus foreign rules the guard never permits: a closed row's
                # port, the same address with another host port, transit traffic and IPv6.
                for address, port, target in (("127.0.0.1", 18080, 8080), ("100.64.0.1", 18081, 8081), ("192.0.2.1", 18082, 8082),
                                              ("100.64.0.1", 18084, 8080), ("100.64.0.1", 18085, 8081),
                                              ("192.0.2.1", 18081, 8081), ("203.0.113.88", 18082, 8082)):
                    nat.append(f"ip daddr {address} {protocol} dport {port} dnat ip to 10.250.0.2:{target};")
                nat.append(f"ip6 daddr 2001:db8:1::1 {protocol} dport 18082 dnat ip6 to [fd00:250::2]:8082;")
            nat += ["}", "chain out { type nat hook output priority -100; policy accept;"]
            for protocol in ("tcp", "udp"):
                nat.append(f"ip daddr 127.0.0.1 {protocol} dport 18080 dnat ip to 10.250.0.2:8080;")
            nat += ["}", "chain post { type nat hook postrouting priority 100; policy accept; ip saddr 127.0.0.0/8 ip daddr 10.250.0.2 masquerade; }", "}"]
            cmd("nft", "-f", "-", input="\n".join(nat))
            outsiders = cmd("nft", "-j", "list", "table", "inet", "fixture")
            net.apply(env)
            assert net.check(env)
            # DD-224: echo servers next to the host; the container may reach only the internet ones.
            for prefix in (wan, tail, wg, other, lan, meta):
                children.append(subprocess.Popen([*prefix, "python3", "-c", SERVER], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE))
            for address in ("192.0.2.2", "100.64.0.2", "10.8.0.2", "198.51.100.2", "192.168.77.2", "169.254.169.2"):
                deadline = time.monotonic() + 5
                while True:
                    try:
                        with socket.create_connection((address, 8080), timeout=.1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise AssertionError("peer echo server not ready: " + address)
                        time.sleep(.05)
            for protocol in ("tcp", "udp"):
                probe(ctr, "192.0.2.2", 8080, protocol, True)
                probe(ctr, "198.51.100.2", 8080, protocol, True)
                for address in ("100.64.0.2", "10.8.0.2", "192.168.77.2", "169.254.169.2", "2001:db8:1::2", "2001:db8:4::2"):
                    probe(ctr, address, 8080, protocol, False)
            # DD-229: the host's own services are closed to the container on every host address;
            # only DNS on the container's bridge gateway answers. (No host INPUT chain exists in this
            # fixture: the guard alone decides.)
            for port in (9090, 53):
                children.append(subprocess.Popen(["python3", "-c", HOST_SERVER, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE))
            for port in (9090, 53):
                deadline = time.monotonic() + 5
                while True:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise AssertionError("host echo server not ready: %d" % port)
                        time.sleep(.05)
            for protocol in ("tcp", "udp"):
                probe(ctr, "10.250.0.1", 53, protocol, True)
                for address in ("10.250.0.1", "192.0.2.1", "100.64.0.1", "10.8.0.1", "198.51.100.1"):
                    probe(ctr, address, 9090, protocol, False)
                for address in ("192.0.2.1", "100.64.0.1", "10.8.0.1"):
                    probe(ctr, address, 53, protocol, False)
                # Other networks still reach the host's services: the input guard names only container bridges.
                probe(tail, "100.64.0.1", 9090, protocol, True)
            for protocol in ("tcp", "udp"):
                # The loopback publication answers on the host (OUTPUT DNAT, no permit); a raw row answers only as
                # its own DNAT from its own interface.
                probe([], "127.0.0.1", 18080, protocol, True)
                probe(tail, "100.64.0.1", 18081, protocol, True)
                probe(wan, "192.0.2.1", 18082, protocol, True)
                for prefix in (wan, wg, other):
                    probe(prefix, "100.64.0.1", 18081, protocol, False)
                for prefix in (tail, wg, other):
                    probe(prefix, "192.0.2.1", 18082, protocol, False)
                for prefix in (wan, tail, wg, other):
                    for port in (8080, 8081, 8082):
                        probe(prefix, "10.250.0.2", port, protocol, False)
                        probe(prefix, "fd00:250::2", port, protocol, False)
                    probe(prefix, "127.0.0.1", 18080, protocol, False)
                # A closed row's port, another host port to the same container port, the WAN address on the
                # Tailscale row's port: no permit, whatever a foreign NAT rule says.
                probe(tail, "100.64.0.1", 18084, protocol, False)
                probe(tail, "100.64.0.1", 18085, protocol, False)
                probe(wan, "192.0.2.1", 18081, protocol, False)
                probe(wan, "2001:db8:1::1", 18082, protocol, False)
                # Exit-node/transit packets with the same port never count as a publication.
                probe(tail, "203.0.113.88", 18082, protocol, False)
                probe(wg, "203.0.113.88", 18082, protocol, False)
            # Closing the rows closes the doors at the next apply.
            write_rows({k: (dict(v, kapsam="kapali") if v["tur"] == "ham" else v) for k, v in rows.items()})
            net.apply(env)
            assert net.check(env)
            for protocol in ("tcp", "udp"):
                probe(tail, "100.64.0.1", 18081, protocol, False)
                probe(wan, "192.0.2.1", 18082, protocol, False)
            # An address the host no longer has gets no permit; the rest of the guard stays (DD-217's lesson).
            write_rows(rows)
            stale = dict(env, TAILSCALE_IPV4="100.64.0.9")
            net.apply(stale)
            assert net.check(stale)
            for protocol in ("tcp", "udp"):
                probe(tail, "100.64.0.1", 18081, protocol, False)
                probe(wan, "192.0.2.1", 18082, protocol, True)
            net.apply(env)
            # A publication the guard does not understand stops the apply; the previous table stays.
            before = cmd("nft", "-j", "list", "table", "inet", env["KONTEYNER_NFT_TABLE"])
            try:
                net.apply(dict(env, WAN_IPV4="0.0.0.0"))
            except net.NetworkError:
                pass
            else:
                raise AssertionError("the guard took a publication on 0.0.0.0")
            assert before == cmd("nft", "-j", "list", "table", "inet", env["KONTEYNER_NFT_TABLE"]), "the table changed"
            probe(tail, "100.64.0.1", 18081, "tcp", True)
            # Removing the record removes the bridge's own rules at the next apply.
            path.unlink()
            rows_path.unlink()
            directory.rmdir()
            net.apply(env)
            assert bridge not in cmd("nft", "-j", "list", "table", "inet", env["KONTEYNER_NFT_TABLE"])
            assert outsiders == cmd("nft", "-j", "list", "table", "inet", "fixture"), "foreign table changed"
            # Tampering that keeps the table present must fail health verification.
            cmd("nft", "add", "rule", "inet", env["KONTEYNER_NFT_TABLE"], "forward", "accept")
            try:
                net.check(env)
            except net.NetworkError:
                pass
            else:
                raise AssertionError("health accepted changed owned rules")
            net.apply(env)
            assert net.check(env)
            cmd("nft", "insert", "rule", "inet", env["KONTEYNER_NFT_TABLE"], "input", "accept")
            try:
                net.check(env)
            except net.NetworkError:
                pass
            else:
                raise AssertionError("health accepted a changed input chain")
            print(f"PASS: {probes} TCP/UDP IPv4/IPv6 packet probes (the loopback publication, raw Tailscale and WAN publications, container egress and the closed host side), closed and stale rows, a refused publication, record removal, foreign chains preserved, rule-integrity check")
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()


if __name__ == "__main__":
    main()
