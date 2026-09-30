#!/usr/bin/env python3
"""Real packet tests in nested disposable namespaces, never the host firewall.

Run as root: unshare --net --fork python3 Data/tests/firewall-linux.py
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import socket
import subprocess
import tempfile
import threading
import time

DATA = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("settings", DATA / "panel/master_settings.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def cmd(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def main():
    assert os.geteuid() == 0
    assert os.readlink("/proc/self/ns/net") != os.readlink("/proc/1/ns/net"), "Separate network namespace required"
    peers, sockets, echoes = [], [], []
    cmd("ip", "link", "set", "lo", "up")
    try:
        addresses = [("eth0", "192.0.2", "2001:db8:1"), ("tailscale0", "100.64.0", "fd00:2"), ("wg0", "10.8.0", "fd00:3")]
        for index, (iface, v4, v6) in enumerate(addresses):
            proc = subprocess.Popen(["unshare", "--net", "sleep", "600"])
            peers.append(proc)
            until = time.monotonic() + 5
            while os.readlink(f"/proc/{proc.pid}/ns/net") == os.readlink("/proc/self/ns/net"):
                assert time.monotonic() < until
                time.sleep(.01)
            peer = "peer" + str(index)
            cmd("ip", "link", "add", iface, "type", "veth", "peer", "name", peer)
            cmd("ip", "link", "set", peer, "netns", str(proc.pid))
            for prefix, device, suffix in (([], iface, 1), (["nsenter", "-t", str(proc.pid), "-n"], peer, 2)):
                cmd(*prefix, "ip", "link", "set", "lo", "up")
                cmd(*prefix, "ip", "addr", "add", f"{v4}.{suffix}/24", "dev", device)
                cmd(*prefix, "ip", "-6", "addr", "add", f"{v6}::{suffix}/64", "dev", device, "nodad")
                cmd(*prefix, "ip", "link", "set", device, "up")
        # veth stands in for point-to-point WireGuard (which has no NDP).
        # Pin only fixture neighbors: allowing WG INPUT ICMPv6 would weaken the policy.
        peer_mac=json.loads(cmd("nsenter","-t",str(peers[2].pid),"-n","ip","-j","link","show","peer2"))[0]["address"]
        host_mac=json.loads(cmd("ip","-j","link","show","wg0"))[0]["address"]
        cmd("ip","-6","neigh","replace","fd00:3::2","lladdr",peer_mac,"nud","permanent","dev","wg0")
        cmd("nsenter","-t",str(peers[2].pid),"-n","ip","-6","neigh","replace","fd00:3::1","lladdr",host_mac,"nud","permanent","dev","peer2")
        cmd("ip", "route", "add", "default", "via", "192.0.2.2", "dev", "eth0")
        # An upstream blanket tailnet ACCEPT must not bypass our baseline.
        for binary in ("iptables", "ip6tables"):
            cmd(binary, "-N", "ts-input")
            cmd(binary, "-A", "ts-input", "-i", "tailscale0", "-j", "ACCEPT")
            cmd(binary, "-A", "ts-input", "-p", "udp", "--dport", "41641", "-j", "ACCEPT")
            cmd(binary, "-A", "INPUT", "-j", "ts-input")
            for table, parent in (("filter", "FORWARD"), ("nat", "POSTROUTING")):
                cmd(binary, "-t", table, "-N", "third-party")
                cmd(binary, "-t", table, "-A", "third-party", "-j", "RETURN")
                cmd(binary, "-t", table, "-A", parent, "-j", "third-party")
        ts_before = [cmd(b, "-S", "ts-input") for b in ("iptables", "ip6tables")]
        def outsiders():
            return [cmd(b, "-t", t, "-S", "third-party") for b in ("iptables", "ip6tables") for t in ("filter", "nat")]
        outsiders_before = outsiders()
        with tempfile.TemporaryDirectory(prefix="firewall-test-") as temp:
            root = Path(temp)
            e = m.env_read(DATA / "config/defaults.env")
            for key in ("SETTINGS_FILE", "SETTINGS_PENDING_FILE", "SETTINGS_DNS_FILE", "DNSMASQ_CONF_FILE",
                        "DNSMASQ_CONF_DIR", "MODULES_FILE", "MODULES_DIR", "WG_NETWORKS_FILE", "RUNTIME_DIR",
                        "UNIT_DIR", "TORRENT_PROFILE_DIR", "SBIN_DIR", "SHARE_STATE_FILE"):
                e[key] = str(root / key.lower())
            e.update(LOCAL_DOMAIN="test", WAN_INTERFACE="eth0", TAILSCALE_IPV4="100.64.0.1")
            for key in ("SBIN_DIR", "RUNTIME_DIR", "DNSMASQ_CONF_DIR"):
                Path(e[key]).mkdir()
            modules = Path(e["MODULES_FILE"])
            networks = Path(e["WG_NETWORKS_FILE"])
            module_record = "wireguard\tcalisiyor\ntorrent\tcalisiyor\n"
            network_record = f"wg0\t{e['WG_PORT_DEFAULT']}\tinet\t10.8.0.1\t10.8.0.0/24\tfd00:3::1\tfd00:3::/112\t1.1.1.1\tTest\n"
            state = root / "state.env"
            e["STATE_FILE"] = str(state)
            state.write_text("".join(k + "=" + shlex.quote(v) + "\n" for k, v in e.items()))
            shutil.copy(DATA / "panel/master_settings.py", Path(e["SBIN_DIR"]) / "master_settings.py")
            # DD-179: firewall.sh asks master_shares.py whether a WAN share is active.
            shutil.copy(DATA / "panel/master_shares.py", Path(e["SBIN_DIR"]) / "master_shares.py")
            worker = ["bash", str(DATA / "scripts/firewall.sh")]
            env = dict(os.environ, STATE_FILE=str(state))
            def apply():
                cmd(*worker, env=env)
                cmd(*worker, "--check", env=env)
            def snapshot():
                return [cmd(b, "-t", t, "-S") for b in ("iptables", "ip6tables") for t in ("filter", "nat")]
            def no_wg():
                for listing in snapshot():
                    assert e["CHAIN_FORWARD"] not in listing and e["CHAIN_NAT"] not in listing, listing
                    assert "wg0" not in listing and "--dport " + e["WG_PORT_DEFAULT"] not in listing, listing
            def repeat():
                before = snapshot()
                apply()
                assert before == snapshot(), "Repeated application changed the rules"
            # A genuinely empty firewall configuration; no module/network files.
            apply()
            no_wg()
            repeat()
            # Merely retaining a network file must never reactivate a module.
            networks.write_text(network_record)
            for record in (None, "", "dosya\tcalisiyor\npaylasim\tcalisiyor\n", "wireguard\tdurduruldu\n"):
                if record is not None:
                    modules.write_text(record)
                apply()
                no_wg()
                repeat()
            modules.write_text(module_record)
            apply()
            def serve(sock, proto):
                while True:
                    try:
                        if proto == "tcp":
                            conn, _ = sock.accept()
                            conn.sendall(b"ok")
                            conn.close()
                        else:
                            data, addr = sock.recvfrom(128)
                            sock.sendto(data, addr)
                    except OSError:
                        return
            allowed_tcp = {int(e[k]) for k in ("SSH_PUBLIC_PORT", "CADDY_HTTP_PORT", "SHARE_PORT", "DNS_PORT")}
            denied_tcp = {2019, 20902, 59000, 61002, 61003, 61007, 61008, int(e["FILES_PANEL_PORT"]), int(e["TORRENT_UI_PORT"])}
            udp_ports = {int(e[k]) for k in ("DNS_PORT", "TAILSCALE_UDP_PORT", "WG_PORT_DEFAULT")} | {20902, 59000}
            for family in (socket.AF_INET, socket.AF_INET6):
                for proto, ports in (("tcp", allowed_tcp | denied_tcp), ("udp", udp_ports)):
                    for port in ports:
                        sock = socket.socket(family, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
                        sockets.append(sock)
                        if family == socket.AF_INET6:
                            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                        sock.bind(("0.0.0.0" if family == socket.AF_INET else "::", port))
                        if proto == "tcp":
                            sock.listen()
                        threading.Thread(target=serve, args=(sock, proto), daemon=True).start()
            probe = """import socket,sys
s=socket.socket(socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM if sys.argv[3]=='tcp' else socket.SOCK_DGRAM)
s.settimeout(.25)
if len(sys.argv)>5: s.bind(("::" if ":" in sys.argv[1] else "0.0.0.0",int(sys.argv[5])))
try:
 s.connect((sys.argv[1],int(sys.argv[2])))
 if sys.argv[3]=='udp': s.send(b'ok')
 result=s.recv(2)==b'ok'
except OSError: result=False
assert result==(sys.argv[4]=='1'),sys.argv[1:]
"""
            def check(index, family, proto, port, allowed):
                addr = addresses[index][1] + ".1" if family == 4 else addresses[index][2] + "::1"
                cmd("nsenter", "-t", str(peers[index].pid), "-n", "python3", "-c", probe,
                    addr, str(port), proto, "1" if allowed else "0")
            for family in (4, 6):
                tail_tcp = allowed_tcp if family == 4 else {int(e["SSH_PUBLIC_PORT"]), int(e["DNS_PORT"])}
                for port in allowed_tcp | denied_tcp:
                    check(1, family, "tcp", port, port in tail_tcp)
                    check(0, family, "tcp", port, port == int(e["SSH_PUBLIC_PORT"]))
                for port in udp_ports:
                    check(1, family, "udp", port, port in {int(e["DNS_PORT"]), int(e["WG_PORT_DEFAULT"])})
                    check(0, family, "udp", port, port == int(e["TAILSCALE_UDP_PORT"]) or
                          (family == 4 and port == int(e["WG_PORT_DEFAULT"])))
                for port in allowed_tcp | denied_tcp:
                    check(2, family, "tcp", port, False)
                for port in udp_ports:
                    check(2, family, "udp", port, False)
                address = addresses[2][1]+".1" if family == 4 else addresses[2][2]+"::1"
                ping = subprocess.run(["nsenter","-t",str(peers[2].pid),"-n","ping","-"+str(family),"-c","1","-W","1",address], capture_output=True)
                assert ping.returncode != 0, "WG host ping unexpectedly allowed"
            print("PASS real IPv4/IPv6 tailnet allowlist, unknown/peer/backend deny, WAN and WG preservation", flush=True)
            # Real routed traffic: the WAN peer has no route back to the WG
            # subnet, so an echo reply also proves NAT (both address families).
            cmd("sysctl", "-qw", "net.ipv4.ip_forward=1", "net.ipv6.conf.all.forwarding=1")
            cmd("nsenter", "-t", str(peers[2].pid), "-n", "ip", "route", "add", "default", "via", "10.8.0.1")
            cmd("nsenter", "-t", str(peers[2].pid), "-n", "ip", "-6", "route", "add", "default", "via", "fd00:3::1")
            echo = """import socket,threading,time
def serve(s):
 while True:
  data,addr=s.recvfrom(128); s.sendto(data,addr)
for family,addr in ((socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::')):
 s=socket.socket(family,socket.SOCK_DGRAM)
 if family==socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
 s.bind((addr,59001)); threading.Thread(target=serve,args=(s,),daemon=True).start()
print('ready',flush=True)
time.sleep(600)
"""
            for index in (0, 1):
                process = subprocess.Popen(["nsenter", "-t", str(peers[index].pid), "-n", "python3", "-c", echo],
                                           stdout=subprocess.PIPE, text=True)
                echoes.append(process)
                assert process.stdout.readline().strip() == "ready"
                for family in (4, 6):
                    addr = addresses[index][1] + ".2" if family == 4 else addresses[index][2] + "::2"
                    cmd("python3", "-c", probe, addr, "59001", "udp", "1")
                    cmd("nsenter", "-t", str(peers[2].pid), "-n", "python3", "-c", probe,
                        addr, "59001", "udp", "1" if index == 0 else "0")
            # Private/CGNAT/link-local destinations routed through the WAN are still denied.
            for addr in ("10.23.1.2", "172.20.0.2", "192.168.40.2", "100.90.0.2", "169.254.20.2", "fd00:5::2"):
                version = "-6" if ":" in addr else "-4"
                prefix = "/128" if version == "-6" else "/32"
                gateway = "2001:db8:1::2" if version == "-6" else "192.0.2.2"
                cmd("nsenter","-t",str(peers[0].pid),"-n","ip",version,"addr","add",addr+prefix,"dev","lo")
                cmd("ip",version,"route","add",addr+prefix,"via",gateway)
                # Bind the echo to this exact alias, so replies use the same source.
                fixture = echo.replace("((socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::'))",
                                       f"((socket.AF_INET6 if ':' in '{addr}' else socket.AF_INET,'{addr}'),)").replace("59001","59002")
                process=subprocess.Popen(["nsenter","-t",str(peers[0].pid),"-n","python3","-c",fixture],
                                         stdout=subprocess.PIPE,text=True)
                echoes.append(process)
                assert process.stdout.readline().strip()=="ready"
                cmd("python3","-c",probe,addr,"59002","udp","1")
                cmd("nsenter","-t",str(peers[2].pid),"-n","python3","-c",probe,addr,"59002","udp","0")
            # A previous allowed UDP flow must not bypass the new WG host guard.
            for binary, addr in (("iptables","10.8.0.1"),("ip6tables","fd00:3::1")):
                cmd(binary,"-I",e["CHAIN_SETTINGS"],"1","-i","wg0","-p","udp","--dport","59000","-j","ACCEPT")
                call = ["nsenter","-t",str(peers[2].pid),"-n","python3","-c",probe,addr,"59000","udp"]
                cmd(*call,"1","59005")
                apply()
                cmd(*call,"0","59005")
            # Old disk rules cannot punch a hole in the mandatory WG policy.
            old_rule = dict(id="retired",name="Legacy",family=4,scope="wg0",proto="tcp",port=61006,source="",allow=True)
            m.save_json(e["SETTINGS_FILE"],dict(m.DEFAULT,firewall=[old_rule]))
            apply()
            check(2,4,"tcp",61006,False)
            print("PASS WG host isolation including established flows; IPv4/IPv6 WAN forwarding/NAT; private WAN and tailnet deny", flush=True)
            # Explicit operator allows/denies stay above the baseline, in order.
            rule = dict(id="fixture", name="Test", family=4, scope="tail", proto="tcp", port=59000, source="", allow=True)
            m.save_json(e["SETTINGS_FILE"], dict(m.DEFAULT, firewall=[rule]))
            apply()
            check(1, 4, "tcp", 59000, True)
            rule.update(port=int(e["CADDY_HTTP_PORT"]), allow=False)
            m.save_json(e["SETTINGS_FILE"], dict(m.DEFAULT, firewall=[rule]))
            apply()
            check(1, 4, "tcp", rule["port"], False)
            m.save_json(e["SETTINGS_FILE"], m.DEFAULT)
            apply()
            repeat()
            for binary in ("iptables", "ip6tables"):
                cmd(binary, "-I", e["CHAIN_SETTINGS"], "3", "-i", "tailscale0", "-j", "RETURN")
                result = subprocess.run([*worker, "--check"], env=env, capture_output=True)
                assert result.returncode != 0, "Extra tailnet bypass was not detected"
                apply()
                # Real stale INPUT/FORWARD/NAT rules, not just UI rows.
                for table, chain, rule in (
                    ("filter", e["CHAIN_INPUT"], ["-i", "wg0", "-p", "tcp", "--dport", "61003", "-j", "ACCEPT"]),
                    ("filter", e["CHAIN_FORWARD"], ["-j", "RETURN"]),
                    ("nat", e["CHAIN_NAT"], ["-o", "eth0", "-j", "MASQUERADE"]),
                ):
                    cmd(binary, "-t", table, "-A", chain, *rule)
                    result = subprocess.run([*worker, "--check"], env=env, capture_output=True)
                    assert result.returncode != 0, f"Stale {binary}/{chain} rule was not detected"
                    apply()
                    assert subprocess.run([binary, "-t", table, "-C", chain, *rule], capture_output=True).returncode != 0
            # No terminal-only RETURN remains in any of our chains.
            for listing in snapshot():
                assert not any(line.startswith("-A MASTER-") and line.split()[2:] == ["-j", "RETURN"]
                               for line in listing.splitlines())
            # Uninstall while retaining networks -> no WG chains/ports, including
            # on the next install/reload. The module record is the sole authority.
            modules.unlink()
            apply()
            no_wg()
            repeat()
            for family in (4, 6):
                check(0, family, "udp", int(e["WG_PORT_DEFAULT"]), False)
                check(1, family, "udp", int(e["WG_PORT_DEFAULT"]), False)
            assert networks.read_text() == network_record
            modules.write_text(module_record)
            apply()
            repeat()
            check(0, 4, "udp", int(e["WG_PORT_DEFAULT"]), True)
            check(1, 4, "udp", int(e["WG_PORT_DEFAULT"]), True)
            assert ts_before == [cmd(b, "-S", "ts-input") for b in ("iptables", "ip6tables")]
            assert outsiders_before == outsiders()
            for binary in ("iptables", "ip6tables"):
                for table, parent in (("filter", "FORWARD"), ("nat", "POSTROUTING")):
                    cmd(binary, "-t", table, "-C", parent, "-j", "third-party")
            print("PASS clean/repeat installs, missing/stopped module, retained profiles, stale INPUT/FORWARD/NAT repair, untouched third-party chains", flush=True)
    finally:
        for process in echoes:
            process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
        for sock in sockets:
            sock.close()
        for proc in peers:
            proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    main()
