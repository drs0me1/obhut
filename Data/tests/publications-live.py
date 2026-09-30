"""Opt-in nrm/publication acceptance. Restores effective network choices.

Runs real Settings writes and module reapply; transfers/services can interrupt.
Never changes app credentials or enables a new public hostname.
"""
import argparse
import hashlib
import http.client
import json
import secrets
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True)
args = parser.parse_args()
ssh = ["ssh", "-o", "ClearAllForwardings=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", args.host]
boot = "import json,sys,pathlib,hashlib; sys.path.insert(0,'/usr/local/sbin'); import master_settings as settings; e=settings.env_read('/etc/master-stack/state.env'); "


def remote(code):
    proc = subprocess.run(ssh + ["python3 -c " + shlex.quote(boot + code)], capture_output=True, text=True, timeout=90)
    if proc.returncode:
        raise RuntimeError("Remote test step failed; private output withheld")
    return json.loads(proc.stdout)


meta = remote("print(json.dumps({k:e[k] for k in ('TAILSCALE_IPV4','LOCAL_DOMAIN','CADDY_HTTP_PORT','SHARE_PORT','SHARE_HTTPS_PORT')}))")


def request(path, data=None, host=None, port=None):
    conn = http.client.HTTPConnection(meta["TAILSCALE_IPV4"], port or int(meta["CADDY_HTTP_PORT"]), timeout=145)
    try:
        conn.request("POST" if data is not None else "GET", path,
                     json.dumps(data) if data is not None else None,
                     {"Host": host or "panel." + meta["LOCAL_DOMAIN"], "X-Konsol": "1", "Content-Type": "application/json"})
        response = conn.getresponse()
        return response.status, response.read()
    finally:
        conn.close()


def status():
    code, body = request("/api/konsol/ayarlar/durum")
    assert code == 200, code
    return json.loads(body)


def save(row, **updates):
    item = {k: row[k] for k in ("service", "tail", "enabled", "domain")}
    item.update(updates)
    code, body = request("/api/konsol/ayarlar/uygula", {"revision": status()["revision"], "web": item})
    assert code == 200, (code, body.decode()[:300])
    assert json.loads(body) == {"committed": True, "pending": None}


before = status()
rows = {r["service"]: r for r in before["publications"]}
assert rows["panel"]["tail"] and not rows["panel"]["enabled"] and rows["panel"]["status"] == "locked"
assert rows["paylasim"]["enabled"] and rows["paylasim"]["status"] == "ready", "Requires existing verified DAV HTTPS"
assert rows["torrent"]["installed"] and not rows["torrent"]["enabled"], "Test expects private qBittorrent"
digest = remote("print(json.dumps(hashlib.sha256(pathlib.Path(e['SHARE_STATE_FILE']).read_bytes()).hexdigest()))")
try:
    for item in (dict(service="panel", tail=True, enabled=True, domain="panel.example.net"),
                 dict(service="torrent", tail=True, enabled=True, domain=rows["paylasim"]["domain"]),
                 dict(service="paylasim", tail=True, enabled=True, domain="missing-" + secrets.token_hex(5) + ".example.net")):
        code, body = request("/api/konsol/ayarlar/uygula", {"revision": status()["revision"], "web": item})
        assert code == 400 and "error" in json.loads(body), code
        assert status()["pending"] is None
    print("PASS: Panel WAN, duplicate domain and missing DNS rejected by real API", flush=True)
    result = remote("import master_publications as pubs; pubs.torrent_security(e,'torrent.example.net',probe=True); print(json.dumps(True))")
    assert result is True
    print("PASS: native qBittorrent permanent-auth checks and anonymous API refusal", flush=True)
    for service, hostname, port in (("torrent", "torrent." + meta["LOCAL_DOMAIN"], None),
                                    ("paylasim", meta["TAILSCALE_IPV4"], int(meta["SHARE_PORT"]))):
        save(rows[service], tail=False)
        assert request("/", host=hostname, port=port)[0] == 403
        # Real lifecycle consumes the choice, not the original always-on template.
        command = "master-modul uygula torrent" if service == "torrent" else "master-modul yerlesik"
        proc = subprocess.run(ssh + [command], capture_output=True, timeout=90)
        assert proc.returncode == 0, "Module reapply failed (private output withheld)"
        assert request("/", host=hostname, port=port)[0] == 403
        assert status()["publications"][0]["tail"] is True
        if service == "paylasim":
            conn = http.client.HTTPSConnection(rows[service]["domain"], int(meta["SHARE_HTTPS_PORT"]), timeout=15)
            try:
                conn.request("GET", "/s/" + "a"*24 + "/")
                response = conn.getresponse(); response.read()
                assert response.status == 401, response.status
            finally:
                conn.close()
        save(rows[service])
        assert request("/", host=hostname, port=port)[0] == (200 if service == "torrent" else 401)
        print("PASS: %s private off/403, real module reapply, on/restore; Panel preserved" % service, flush=True)
    save(rows["paylasim"], enabled=False)
    current = next(r for r in status()["publications"] if r["service"] == "paylasim")
    assert not current["enabled"] and current["domain"] == rows["paylasim"]["domain"]
    assert request("/", host=meta["TAILSCALE_IPV4"], port=int(meta["SHARE_PORT"]))[0] == 401
    saved = remote("import master_publications as pubs; print(json.dumps(pubs.extra_sites(e).get('torrent-wan.caddy')=='' and not (pathlib.Path(e['CADDY_MODULES_DIR'])/'paylasim-wan.caddy').exists()))")
    assert saved
    print("PASS: public off remembers domain, removes WAN site and preserves private DAV", flush=True)
finally:
    for service in ("torrent", "paylasim"):
        save(rows[service])
    assert status()["pending"] is None
    assert remote("print(json.dumps(hashlib.sha256(pathlib.Path(e['SHARE_STATE_FILE']).read_bytes()).hexdigest()))") == digest
    print("CLEANUP: original effective network choices restored; folder accounts unchanged", flush=True)
