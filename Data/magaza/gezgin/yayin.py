"""Gezgin internet publication checks (DD-191, DD-199, DD-262).

master_publications loads this file from the package folder when the operator turns the Gezgin row
on (probe) and whenever it renders or lists the row. Gezgin has nothing that bypasses its sign-in:
username and password is its only method (a database naming another one refuses to start), there is
no self sign-up, and failed logins from outside private ranges spend a per-address budget. So there
is no setting to read while the row is on; turning it on proves that the running app answers and
refuses an anonymous API call.
"""
import http.client
from pathlib import Path

from master_settings import env_read, package_overrides, require

PACKAGE_DIR = Path(__file__).resolve().parent


def package_env(env):
    """The package's own settings (gezgin.env, DD-203) on top of the base's state."""
    merged = dict(env)
    merged.update(env_read(PACKAGE_DIR / "gezgin.env"))
    merged.update(package_overrides(env, "gezgin"))
    return merged


def status(port, path, name):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request("GET", path, headers={"Host": name, "X-Forwarded-Host": name})
        response = conn.getresponse()
        response.read(4096)
        return response.status
    finally:
        conn.close()


def security(env, name, probe=False):
    """Fail closed unless Gezgin answers and requires its sign-in for the API."""
    if not probe:
        return
    port = int(package_env(env)["GEZGIN_UI_PORT"])
    require(status(port, "/health", name) == 200, "Gezgin yanıt vermiyor; internet yayını açılmadı.")
    require(status(port, "/api/resources/", name) == 401,
            "Gezgin'in giriş kapısı doğrulanamadı; internet yayını açılmadı.")
