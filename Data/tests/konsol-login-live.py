#!/usr/bin/env python3
"""Opt-in DD-194 sign-in acceptance from a tailnet client against an authorized test host.

Requires a host WITHOUT a Konsol account (a fresh install); otherwise it exits 3 and
touches nothing. It issues its own one-time code over SSH (root CLI), creates a temporary
account through the real Caddy path, checks page/API protection, sign-in/out, password
change and the attempt limit, then resets: no account remains and the operator gets a
new code with `sudo master-konsol sifirla`. Codes, passwords and tokens stay in memory.

Run on the operator Mac: python3 Data/tests/konsol-login-live.py --host nrm
"""
import argparse
import http.client
import json
import re
import secrets
import shlex
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True)
args = parser.parse_args()
ssh = ["ssh", "-o", "ClearAllForwardings=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", args.host]
CLI = "sudo -n /usr/local/sbin/master-konsol "


def run(command):
    result = subprocess.run(ssh + [command], capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError("Remote step failed (output withheld)")
    return result.stdout


if run(CLI + "durum").startswith("Konsol hesabı:"):
    print("SKIP: this host already has a Konsol account; the test never touches it.", file=sys.stderr)
    sys.exit(3)
meta = json.loads(run("sudo -n python3 -c " + shlex.quote(
    "import sys,json; sys.path.insert(0,'/usr/local/sbin'); from master_shares import env_read; "
    "e=env_read('/etc/master-stack/state.env'); "
    "print(json.dumps({'tail':e['TAILSCALE_IPV4'],'domain':e['LOCAL_DOMAIN'],'port':int(e['CADDY_HTTP_PORT'])}))")))


def call(method, path, body=None, cookie=None, api=True):
    conn = http.client.HTTPConnection(meta["tail"], meta["port"], timeout=30)
    headers = {"Host": "panel." + meta["domain"]}
    if api:
        headers["X-Konsol"] = "1"
    if cookie:
        headers["Cookie"] = cookie
    if body is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(body)
    try:
        conn.request(method, path, body, headers)
        response = conn.getresponse()
        return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
    finally:
        conn.close()


def new_code():
    found = re.search(r"\b([A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4})\b", run(CLI + "sifirla"))
    if not found:
        raise RuntimeError("No one-time code in the reset output (output withheld)")
    return found.group(1)


user = "test-" + secrets.token_hex(4)
password, changed = secrets.token_urlsafe(18), secrets.token_urlsafe(18)
try:
    code = new_code()
    assert call("GET", "/giris.html", api=False)[0] == 200
    assert call("GET", "/konsol.css", api=False)[0] == 200
    for page in ("/", "/konsol.js", "/index.html"):
        status, headers, _ = call("GET", page, api=False)
        assert (status, headers.get("location")) == (302, "/giris.html"), (page, status)
    for api in ("/api/konsol/kaynaklar", "/api/state", "/api/uygulama/wireguard/state"):
        status, _, body = call("GET", api)
        assert status == 401 and json.loads(body)["giris"] is True, (api, status)
    assert json.loads(call("GET", "/api/konsol/oturum")[2]) == {"durum": "kurulum", "kod": True}
    print("PASS: sign-in page/files open; every Konsol page, file and API needs a session", flush=True)

    assert call("POST", "/api/konsol/oturum/kur", {"kod": "AAAA-BBBB-CCCC", "kullanici": user, "parola": password})[0] == 401
    status, headers, _ = call("POST", "/api/konsol/oturum/kur", {"kod": code.lower(), "kullanici": user, "parola": password})
    assert status == 200, status
    attributes = [part.strip() for part in headers["set-cookie"].split(";")]
    assert attributes[1:] == ["Path=/", "HttpOnly", "SameSite=Strict", "Max-Age=604800"], attributes[1:]
    first = attributes[0]
    status, _, body = call("GET", "/", cookie=first, api=False)
    assert status == 200 and b'id="panel-sidebar"' in body
    for api in ("/api/konsol/kaynaklar", "/api/state"):
        assert call("GET", api, cookie=first)[0] == 200, api
    assert json.loads(call("GET", "/api/konsol/oturum", cookie=first)[2])["kullanici"] == user
    assert call("POST", "/api/konsol/oturum/kur", {"kod": code, "kullanici": user, "parola": password})[0] == 409
    print("PASS: one-time code creates the account once; the session opens pages, files and API", flush=True)

    status, headers, _ = call("POST", "/api/konsol/oturum/giris", {"kullanici": user, "parola": password})
    assert status == 200
    second = headers["set-cookie"].split(";", 1)[0]
    assert call("POST", "/api/konsol/hesap/parola", {"eski": "wrong-" + password, "yeni": changed}, cookie=first)[0] == 401
    assert call("POST", "/api/konsol/hesap/parola", {"eski": password, "yeni": changed}, cookie=first)[0] == 200
    assert call("GET", "/api/konsol/kaynaklar", cookie=second)[0] == 401
    assert call("GET", "/api/konsol/kaynaklar", cookie=first)[0] == 200
    assert call("POST", "/api/konsol/oturum/giris", {"kullanici": user, "parola": password})[0] == 401
    status, headers, _ = call("POST", "/api/konsol/oturum/giris", {"kullanici": user, "parola": changed})
    assert status == 200
    third = headers["set-cookie"].split(";", 1)[0]
    status, headers, _ = call("POST", "/api/konsol/oturum/cikis", {}, cookie=third)
    assert status == 200 and "Max-Age=0" in headers["set-cookie"]
    assert call("GET", "/", cookie=third, api=False)[0] == 302
    print("PASS: sign-in, password change closes other sessions, old password refused, sign-out", flush=True)

    # Three failures so far (wrong code, wrong current password, old password).
    for _ in range(2):
        assert call("POST", "/api/konsol/oturum/giris", {"kullanici": user, "parola": "wrong-" + changed})[0] == 401
    status, headers, body = call("POST", "/api/konsol/oturum/giris", {"kullanici": user, "parola": changed})
    assert status == 429 and int(headers["retry-after"]) > 0, status
    print("PASS: five failures from one address block sign-in with Retry-After", flush=True)
finally:
    new_code()  # removes the test account and sessions; this code is never shown
    # The attempt limit lives in the backend's memory; a restart frees this address.
    run("sudo -n systemctl restart master-panel.service")
    assert "Konsol hesabı yok" in run(CLI + "durum")
    print("CLEANUP: test account and sessions removed; show a fresh code with: sudo master-konsol sifirla", flush=True)
