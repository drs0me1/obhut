#!/usr/bin/env python3
"""DD-156: real Linux binaries in a disposable network namespace and profile.

Run as root: unshare --net --fork python3 Data/tests/settings-linux.py
Never uses the installed stack's configuration or controls its services.
"""
import copy
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_settings as settings
real_run = settings.run


def cmd(*args):
    return real_run(list(args)).stdout.strip()


def wait_for(test):
    until = time.monotonic() + 12
    while time.monotonic() < until:
        try:
            if test():
                return
        except (OSError, ValueError):
            pass
        time.sleep(.1)
    raise AssertionError("Test servisi zamanında hazır olmadı")


def main():
    assert os.geteuid() == 0, "root gerekli"
    assert os.readlink('/proc/self/ns/net') != os.readlink('/proc/1/ns/net'), "Ayrı ağ ad alanı gerekli!"
    cmd("ip", "link", "set", "lo", "up")
    for name, address in (("eth0", "192.0.2.1/24"), ("tailscale0", "100.64.0.2/32")):
        cmd("ip", "link", "add", name, "type", "dummy")
        cmd("ip", "addr", "add", address, "dev", name)
        cmd("ip", "link", "set", name, "up")
    cmd("ip", "route", "add", "default", "dev", "eth0")
    cmd("ip", "addr", "add", "9.9.9.9/32", "dev", "lo")
    for binary in ("iptables", "ip6tables"):
        cmd(binary, "-N", "ts-input")
        cmd(binary, "-A", "ts-input", "-i", "tailscale0", "-j", "ACCEPT")
        cmd(binary, "-A", "INPUT", "-j", "ts-input")
    with tempfile.TemporaryDirectory(prefix="konsol-linux-") as temp:
        root = Path(temp)
        root.chmod(0o755)
        e = settings.env_read(DATA / "config/defaults.env")
        paths = {"SETTINGS_FILE": "etc/settings.json", "SETTINGS_PENDING_FILE": "etc/pending.json",
                 "SETTINGS_DNS_FILE": "dns/konsol.conf", "DNSMASQ_CONF_FILE": "dns/base.conf", "DNSMASQ_CONF_DIR": "dns",
                 "UNIT_DIR": "units", "KONTEYNER_BIRIM_DIR": "quadlet", "RUNTIME_DIR": "run", "SERVER_ROOT": "srv",
                 "DOWNLOADS_PATH": "srv/downloads", "SBIN_DIR": "bin", "SHARE_STATE_FILE": "etc/webdav.json",
                 "WG_NETWORKS_FILE": "etc/networks", "WG_STOPPED_FILE": "etc/.durduruldu"}
        e.update({k: str(root / v) for k, v in paths.items()})
        e.update(LOCAL_DOMAIN="ayc", WAN_INTERFACE="eth0", WAN_IPV4="192.0.2.1", TAILSCALE_IPV4="100.64.0.2",
                 DOWNLOADS_UID="1000", DOWNLOADS_GID="1000")
        for name in ("etc", "bin", "dns", "units", "quadlet", "run", "srv/downloads", "srv/media"):
            (root / name).mkdir(parents=True, exist_ok=True)
        for p in [root / "srv", *(root / "srv").rglob("*")]:
            os.chown(p, 1000, 1000)
        state = root / "state.env"
        e["STATE_FILE"] = str(state)
        state.write_text("".join(k + '="' + v + '"\n' for k, v in e.items()))
        (root / "etc/networks").write_text("")
        shutil.copy(DATA / "scripts/firewall.sh", root / "bin/master-firewall")
        (root / "bin/master-firewall").chmod(0o755)
        shutil.copy(DATA / "panel/master_settings.py", root / "bin/master_settings.py")
        # DD-179: firewall.sh asks master_shares.py whether a WAN share is active.
        shutil.copy(DATA / "panel/master_shares.py", root / "bin/master_shares.py")
        shutil.copy(DATA / "panel/master_https.py", root / "bin/master_https.py")
        shutil.copy(DATA / "panel/master_publications.py", root / "bin/master_publications.py")
        def render(source):
            text = (DATA / source).read_text()
            for key, value in e.items():
                text = text.replace("__" + key + "__", value)
            return text
        Path(e["DNSMASQ_CONF_FILE"]).write_text(render("templates/dnsmasq.conf"))
        # The built-in WebDAV's local name, as the installer places it.
        (root / "dns/modul-paylasim.conf").write_text(render("templates/paylasim-dnsmasq.conf"))
        m = settings.Manager(state)
        processes = {}
        def stop(name):
            p = processes.pop(name, None)
            if p and p.poll() is None:
                p.terminate()
                p.wait(timeout=20)
        def start(name):
            stop(name)
            args = ["dnsmasq", "--keep-in-foreground", "--conf-file=/dev/null", "--conf-dir=" + e["DNSMASQ_CONF_DIR"], "--port=15353"]
            processes[name] = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            wait_for(lambda: "100.64.0.2" in dig("panel.ayc"))
        def dig(name):
            return cmd("dig", "@127.0.0.1", "-p", "15353", "+noedns", "+time=1", "+tries=1", name, "A")
        def adapter(argv, **kwargs):
            if argv[0] != "systemctl":
                if argv[0] == e["SBIN_DIR"] + "/master-firewall":
                    result = real_run(argv, **dict(kwargs, check=False))
                    assert result.returncode == 0, result.stderr
                    return result
                return real_run(argv, **kwargs)
            action = argv[1]
            if argv[-1] == "master-settings-guard.timer":
                return subprocess.CompletedProcess(argv, 0, "", "")  # DD-181: apply starts the timer
            name = "dns"
            if action == "stop":
                stop(name)
            elif action in ("start", "restart"):
                start(name)
            elif action == "is-active" and argv[-1] != "master-settings-guard.timer":
                code = 0 if name in processes and processes[name].poll() is None else 3
                settings.require(not kwargs.get("check", True) or code == 0, "Test servisi durmuş")
                return subprocess.CompletedProcess(argv, code, "", "")
            return subprocess.CompletedProcess(argv, 0, "", "")
        def dns_test():
            cmd("dnsmasq", "--test", "--conf-file=/dev/null", "--conf-dir=" + e["DNSMASQ_CONF_DIR"])
        def apply(**data):
            with m.locked():
                return m.apply(dict(revision=m.revision(), **data))
        def confirm():
            with m.locked():
                m.confirm({"id": m.pending()["id"], "client": "100.64.0.9", "kanal": "tailscale"})
        forwarded = []
        upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        upstream.bind(("9.9.9.9", 53))
        upstream.settimeout(.5)
        finished = threading.Event()
        def answer():
            while not finished.is_set():
                try:
                    packet, addr = upstream.recvfrom(4096)
                except socket.timeout:
                    continue
                forwarded.append(packet)
                # Test üst sunucusu: soruyu koru, bir A yanıtı ekle.
                end = 12
                while packet[end]:
                    end += packet[end] + 1
                end += 5
                response = packet[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0) + packet[12:end] + b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton("192.0.2.99")
                upstream.sendto(response, addr)
        thread = threading.Thread(target=answer, daemon=True)
        thread.start()
        try:
            with patch.object(settings, "run", side_effect=adapter), patch.object(m, "dns_test", side_effect=dns_test):
                m.firewall_apply()
                ts_before = cmd("iptables", "-S", "ts-input")
                rules = [dict(id="specific", name="Test", family=4, scope="wan", proto="tcp", port=12345, source="192.0.2.3/32", allow=True),
                         dict(id="general", name="Test", family=4, scope="wan", proto="tcp", port=12345, source="", allow=False),
                         dict(id="ipv6", name="Test6", family=6, scope="tail", proto="udp", port=12346, source="", allow=False)]
                apply(firewall=rules)
                for family, binary in ((4, "iptables"), (6, "ip6tables")):
                    for row in m.rules(family):
                        cmd(binary, "-C", e["CHAIN_SETTINGS"], *row)
                    assert cmd(binary, "-S", "INPUT").splitlines()[1] == "-A INPUT -j " + e["CHAIN_SETTINGS"]
                assert ts_before == cmd("iptables", "-S", "ts-input")
                confirm()
                m.firewall_apply()
                cmd("iptables", "-D", e["CHAIN_SETTINGS"], *m.rules(4)[0])
                cmd("iptables", "-I", e["CHAIN_SETTINGS"], "4", *m.rules(4)[0])
                broken = real_run([e["SBIN_DIR"] + "/master-firewall", "--check"], env={"STATE_FILE": str(state)}, check=False)
                assert broken.returncode != 0, "Kural sırası bozulması fark edilmedi"
                m.firewall_apply()
                apply(firewall=[])
                m.rollback()
                assert m.current()["firewall"] == rules
                print("PASS real IPv4/IPv6 firewall, ordering, persistence, rollback, Tailscale ownership", flush=True)
                start("dns")
                assert "REFUSED" in dig("public.example")
                d = copy.deepcopy(settings.DEFAULT["dns"])
                d.update(disabled=["paylas.ayc"], records=[dict(name="nas.ayc", target="192.0.2.10", enabled=True)], forward=True, servers=["9.9.9.9"])
                result = apply(dns=d)
                assert result == {"pending": None, "committed": True}
                assert m.config()["dns"] == d
                assert "192.0.2.10" in dig("nas.ayc")
                assert "100.64.0.2" not in dig("paylas.ayc")
                answer_text = dig("public.example")
                assert "192.0.2.99" in answer_text, answer_text
                before = len(forwarded)
                dig("missing.ayc")
                assert len(forwarded) == before, "Yerel DNS sorgusu üst sunucuya sızdı"
                m.guard()
                assert m.config()["dns"] == d
                apply(dns=copy.deepcopy(settings.DEFAULT["dns"]))
                assert "100.64.0.2" in dig("paylas.ayc")
                assert "REFUSED" in dig("public.example")
                with patch.object(m, "dns_test", side_effect=[settings.SettingsError("injected"), None]):
                    try:
                        apply(dns=d)
                    except settings.SettingsError:
                        pass
                    else:
                        raise AssertionError("Invalid DNS was accepted")
                assert m.pending() is None
                assert "100.64.0.2" in dig("paylas.ayc")
                print("PASS real dnsmasq local names, forwarding, private-zone isolation, immediate commit, failed-apply rollback", flush=True)
        finally:
            for name in list(processes):
                stop(name)
            finished.set()
            thread.join(timeout=2)
            upstream.close()


if __name__ == "__main__":
    main()
