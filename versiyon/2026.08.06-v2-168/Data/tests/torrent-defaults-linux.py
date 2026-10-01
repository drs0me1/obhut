#!/usr/bin/env python3
"""DD-178: compare the seed with native defaults in an isolated network namespace.

Run as root: unshare --net --fork python3 Data/tests/torrent-defaults-linux.py
Uses only disposable profiles; no installed service, account or firewall changes.
"""
import http.cookiejar
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

DATA = Path(__file__).resolve().parents[1]
USER_KEYS = ("upnp", "lsd", "dht", "pex", "temp_path_enabled", "dl_limit", "up_limit")


class Client:
    def __init__(self, root, port, seed):
        self.root, self.port = root, port
        self.base = "http://127.0.0.1:%d" % port
        self.proc = None
        self.log = None
        self.conf = root / "profile/qBittorrent/qBittorrent.conf"
        self.conf.parent.mkdir(parents=True)
        (root / "downloads").mkdir()
        self.conf.write_text(seed)
        for path in [root, *root.rglob("*")]:
            os.chown(path, 1000, 1000)
        self.conf.chmod(0o600)

    def request(self, endpoint, fields=None):
        payload = None if fields is None else urllib.parse.urlencode(fields).encode()
        request = urllib.request.Request(self.base + "/api/v2/" + endpoint, payload,
                                         {"Origin": self.base, "Referer": self.base + "/"})
        with self.http.open(request, timeout=3) as response:
            return response.read().decode()

    def preferences(self):
        return json.loads(self.request("app/preferences"))

    def start(self):
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        profile = str(self.root / "profile")
        env = dict(os.environ, HOME=profile, XDG_CONFIG_HOME=profile,
                   XDG_DATA_HOME=profile, XDG_CACHE_HOME=profile + "/cache", LC_ALL="C.UTF-8")
        # The private log may contain a fixture password; never print it on failure.
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(
            ["setpriv", "--reuid=1000", "--regid=1000", "--clear-groups", "qbittorrent-nox"],
            env=env, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 20
        password = None
        while time.monotonic() < deadline:
            assert self.proc.poll() is None, "Fixture qBittorrent exited"
            self.log.seek(0)
            match = re.search(r"temporary password is provided for this session:\s*(\S+)",
                              self.log.read().decode(errors="replace"))
            if match:
                password = match[1]
                try:
                    self.request("app/version")
                except urllib.error.HTTPError as error:
                    assert error.code == 403, "Anonymous API must require login"
                    break
                except (OSError, urllib.error.URLError):
                    pass
                else:
                    raise AssertionError("Anonymous API unexpectedly accessible")
            time.sleep(.1)
        else:
            raise AssertionError("Private fixture did not become ready")
        assert password and self.request("auth/login", {"username": "admin", "password": password}) == "Ok."
        status = Path("/proc/%d/status" % self.proc.pid).read_text()
        assert re.search(r"^Uid:\s+1000\s+1000\s+1000\s+1000$", status, re.M)
        prefs = self.preferences()
        assert prefs["web_ui_address"] == "127.0.0.1" and prefs["web_ui_port"] == self.port
        assert not prefs["bypass_local_auth"], "Local login protection was lost"

    def stop(self):
        try:
            if self.proc is not None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)
                    raise AssertionError("Fixture did not stop cleanly")
        finally:
            self.proc = None
            if self.log is not None:
                self.log.close()
                self.log = None


def main():
    assert os.geteuid() == 0, "Root required for the disposable uid-1000 fixture"
    assert os.readlink("/proc/self/ns/net") != os.readlink("/proc/1/ns/net"), "Refusing host network namespace"
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True, timeout=10)
    template = (DATA / "modules/torrent/qBittorrent.conf").read_text()
    with tempfile.TemporaryDirectory(prefix="konsol-torrent-defaults-") as tmp:
        root = Path(tmp)
        root.chmod(0o755)
        baseline = "[LegalNotice]\nAccepted=true\n[Preferences]\nWebUI\\Address=127.0.0.1\nWebUI\\LocalHostAuth=true\nWebUI\\Port=18555\n"
        seed = template.replace("__DOWNLOADS_PATH__", str(root / "seed/downloads")).replace("__TORRENT_UI_PORT__", "18556")
        assert "__" not in seed, "Unrendered seed placeholder"
        vanilla = Client(root / "vanilla", 18555, baseline)
        panel = Client(root / "seed", 18556, seed)
        try:
            vanilla.start()
            defaults = vanilla.preferences()
            vanilla.stop()
            panel.start()
            current = panel.preferences()
            for key in USER_KEYS:
                assert key in current and current[key] == defaults[key], "Forced preference: " + key
            assert current["save_path"].rstrip("/") == str(root / "seed/downloads")
            assert current["temp_path_enabled"] is False, "Seed must not force separate temporary storage"
            print("PASS: native defaults preserved; nonroot start, loopback login and downloads integration")
            chosen = {"upnp": not current["upnp"], "lsd": not current["lsd"],
                      "temp_path_enabled": True, "temp_path": str(root / "seed/downloads/incomplete")}
            panel.request("app/setPreferences", {"json": json.dumps(chosen)})
            panel.stop()
            panel.start()
            saved = panel.preferences()
            for key, value in chosen.items():
                assert saved[key] == value if isinstance(value, bool) else saved[key].rstrip("/") == value
            print("PASS: user-selected UPnP/discovery/temporary storage survive native restart")
        finally:
            panel.stop()
            vanilla.stop()


if __name__ == "__main__":
    main()
