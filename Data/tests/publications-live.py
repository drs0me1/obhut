"""Opt-in nrm/publication acceptance. Restores effective network choices.

Runs real Settings writes; transfers/services can interrupt. Never changes credentials or enables a
new public hostname; the operator's names are read from the host, never written here.
"""
import argparse
import hashlib
import http.client
import json
import secrets
import shlex
import subprocess
import time

import konsol_session

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


# DD-194: Konsol through Caddy needs a session; a short root-issued one, closed at the end.
COOKIE = konsol_session.open_session(ssh)


def request(path, data=None, host=None, port=None):
    conn = http.client.HTTPConnection(meta["TAILSCALE_IPV4"], port or int(meta["CADDY_HTTP_PORT"]), timeout=145)
    try:
        conn.request("POST" if data is not None else "GET", path,
                     json.dumps(data) if data is not None else None,
                     {"Host": host or "panel." + meta["LOCAL_DOMAIN"], "X-Konsol": "1", "Content-Type": "application/json",
                      **({} if host else {"Cookie": COOKIE})})
        response = conn.getresponse()
        return response.status, response.read()
    finally:
        conn.close()


def read(path):
    code, body = request(path)
    assert code == 200, (path, code)
    return json.loads(body)


def status():
    """The settings revision, the publication rows and the pending change in the shape this test checks,
    read from Erişim's routes (GET yayinlar, GET bekleyen; DD-265)."""
    view = read("/api/konsol/yayinlar")
    rows = [{"service": c["servis"], "tail": c["tailscale"], "enabled": c["internet"], "domain": c["alan_adi"],
             "status": c["durum"], "installed": True, "account": "Konsol hesabı" not in c["internet_engel"]}
            for c in view["adaylar"] if c.get("servis")]
    return {"revision": view["revizyon"], "publications": rows, "pending": read("/api/konsol/bekleyen")["bekleyen"]}


def save(row, **updates):
    item = {k: row[k] for k in ("service", "tail", "enabled", "domain")}
    item.update(updates)
    for attempt in range(10):
        code, body = request("/api/konsol/ayarlar/uygula", {"revision": status()["revision"], "web": item})
        # The share/settings guard timers hold the operation locks briefly; retry only that answer.
        if code == 400 and "sürüyor" in body.decode(errors="replace") and attempt < 9:
            time.sleep(3)
            continue
        break
    assert code == 200, (code, body.decode()[:300])
    assert json.loads(body) == {"committed": True, "pending": None}


before = status()
rows = {r["service"]: r for r in before["publications"]}
# DD-195: Panel may be public, but its tailnet address never closes; this test never changes it.
assert rows["panel"]["tail"] and rows["panel"]["status"] in ("disabled", "ready", "error")
panel_before = {k: rows["panel"][k] for k in ("tail", "enabled", "domain")}
assert rows["paylasim"]["enabled"] and rows["paylasim"]["status"] == "ready", "Requires existing verified DAV HTTPS"
# Names come from the host. example.net is reserved and never resolves below its apex.
digest = remote("print(json.dumps(hashlib.sha256(pathlib.Path(e['SHARE_STATE_FILE']).read_bytes()).hexdigest()))")
try:
    # Each refusal names its real cause (DD-195: the typed word and the account come before DNS).
    missing = "panel-" + secrets.token_hex(5) + ".example.net"
    for item, expected in ((dict(service="panel", tail=False, enabled=False, domain=""), "Tailscale erişimi kapatılamaz"),
                           (dict(service="panel", tail=True, enabled=True, domain=missing), "onayla yazın"),
                           (dict(service="panel", tail=True, enabled=True, domain=missing, confirm="onayla"),
                            "DNS" if rows["panel"]["account"] else "Konsol hesabını"),
                           (dict(service="panel", tail=True, enabled=True, domain=rows["paylasim"]["domain"], confirm="onayla"),
                            "aynı HTTPS alan adını"),
                           (dict(service="paylasim", tail=True, enabled=True, domain="missing-" + secrets.token_hex(5) + ".example.net"), "DNS")):
        code, body = request("/api/konsol/ayarlar/uygula", {"revision": status()["revision"], "web": item})
        assert code == 400 and expected in json.loads(body)["error"], (code, body.decode()[:200])
        assert status()["pending"] is None
    print("PASS: Panel tailnet-off/word/account-or-DNS, duplicate domain and DAV missing DNS rejected with their real causes", flush=True)
    # Every address of WebDAV's template must answer 403 when Tailscale is off (DD-193).
    targets = [(meta["TAILSCALE_IPV4"], int(meta["SHARE_PORT"])), ("paylas." + meta["LOCAL_DOMAIN"], None)]
    save(rows["paylasim"], tail=False)
    assert all(request("/", host=h, port=p)[0] == 403 for h, p in targets)
    assert status()["publications"][0]["tail"] is True
    conn = http.client.HTTPSConnection(rows["paylasim"]["domain"], int(meta["SHARE_HTTPS_PORT"]), timeout=15)
    try:
        conn.request("GET", "/s/" + "a"*24 + "/")
        response = conn.getresponse(); response.read()
        assert response.status == 401, response.status
    finally:
        conn.close()
    save(rows["paylasim"])
    assert all(request("/", host=h, port=p)[0] == 401 for h, p in targets)
    print("PASS: paylasim private off/403, on/restore; Panel preserved", flush=True)
    save(rows["paylasim"], enabled=False)
    current = next(r for r in status()["publications"] if r["service"] == "paylasim")
    assert not current["enabled"] and current["domain"] == rows["paylasim"]["domain"]
    assert request("/", host=meta["TAILSCALE_IPV4"], port=int(meta["SHARE_PORT"]))[0] == 401
    saved = remote("print(json.dumps((pathlib.Path(e['CADDY_MODULES_DIR'])/'paylasim-wan.caddy').exists()))")
    assert saved is False, saved
    print("PASS: public DAV off remembers domain, removes only its WAN site and preserves private DAV", flush=True)
finally:
    # Restore every row even if one fails, so the operator's choices never stay changed.
    failures = []
    try:
        save(rows["paylasim"])
    except AssertionError as err:
        failures.append(("paylasim", str(err)[:200]))
    assert not failures, failures
    assert status()["pending"] is None
    after = {r["service"]: r for r in status()["publications"]}["panel"]
    assert {k: after[k] for k in ("tail", "enabled", "domain")} == panel_before, "Panel row changed"
    assert remote("print(json.dumps(hashlib.sha256(pathlib.Path(e['SHARE_STATE_FILE']).read_bytes()).hexdigest()))") == digest
    konsol_session.close_session(ssh, COOKIE)
    print("CLEANUP: original effective network choices restored; folder accounts unchanged", flush=True)
