#!/usr/bin/env python3
"""qBittorrent package: settings worker (DD-202).

The Konsol root backend never edits the profile itself: its API module (api.py) runs this
file through ctx.worker() as a separate transient unit (outside the backend's sandbox, like
the base settings worker), JSON on stdin, JSON on stdout, exit 1 with {"error"} on refusal.

    ayar.py --state STATE hesap    {"username"?: str, "password"?: str}
    ayar.py --state STATE dizin    {"save": "/abs/dir"}

Every change is direct (DD-165): validate, stop the service if it runs, snapshot the files,
write, start again, verify; a failure restores the snapshot and starts the service again.
No pending/confirmation window: a wrong account or folder cannot lock the operator out.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import stat
import sys


def _lib_dir():
    """The base's Python library (master_settings.py) sits next to master-modul (SBIN_DIR): the
    backend passes it as --lib; a hand run finds master-modul on PATH."""
    argv = sys.argv
    if "--lib" in argv[:-1]:
        return argv[argv.index("--lib") + 1]
    return os.path.dirname(shutil.which("master-modul") or "/usr/local/sbin/master-modul")


if "master_settings" not in sys.modules:  # standalone worker run; inside the backend it is loaded already
    sys.path.insert(0, _lib_dir())
import master_settings as settings  # noqa: E402

LIMIT = 65536
USERNAME_RE = re.compile(r"[A-Za-z0-9._@-]{1,64}")
PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))


def package_env(env):
    """The package's own settings (torrent.env next to this file, DD-203) on top of the base's state."""
    merged = dict(env)
    merged.update(settings.env_read(os.path.join(PACKAGE_DIR, "torrent.env")))
    return merged
CONF = "qBittorrent/qBittorrent.conf"
DROP_IN = "qbittorrent-nox@.service.d/90-konsol.conf"


def ini_values(text):
    section, out = "", {}
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif "=" in line and not line.startswith(("#", ";")):
            k, _, v = line.partition("=")
            out[(section, k)] = v.strip('"').replace("\\\\", "\\")
    return out


def ini_patch(text, updates):
    """Change only selected keys, preserving unrelated qBittorrent settings."""
    remaining, section, out = dict(updates), "", []

    def finish():
        for (sec, key), value in list(remaining.items()):
            if sec == section:
                out.append(key + "=" + value)
                del remaining[(sec, key)]
    seen = set()
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            finish()
            section = line[1:-1]
        key = (section, line.partition("=")[0])
        if "=" in line and key in updates:
            if key not in seen:
                out.append(key[1] + "=" + updates[key])
                seen.add(key)
                remaining.pop(key, None)
        else:
            out.append(line)
    finish()
    for sec in dict.fromkeys(k[0] for k in remaining):
        out.extend(["", "[" + sec + "]"])
        out.extend(k + "=" + v for (s, k), v in remaining.items() if s == sec)
    return "\n".join(out) + "\n"


def password_hash(password):
    # qBittorrent Utils::Password::PBKDF2 (4.6/5.x): SHA512, 100000, salt16/key64.
    salt = secrets.token_bytes(16)
    key = hashlib.pbkdf2_hmac("sha512", password.encode("utf-8"), salt, 100000, 64)
    return "@ByteArray(%s:%s)" % (base64.b64encode(salt).decode(), base64.b64encode(key).decode())


def conf_path(env):
    return Path(env["TORRENT_PROFILE_DIR"]) / CONF


def drop_in_path(env):
    return Path(env["UNIT_DIR"]) / DROP_IN


def unit_name(env):
    user = pwd.getpwuid(int(env["DOWNLOADS_UID"])).pw_name
    settings.require(bool(re.fullmatch(r"[a-z_][a-z0-9_-]*", user)), "Servis kullanıcısı geçersiz.")
    return "qbittorrent-nox@" + user + ".service"


def read_conf(path, limit=LIMIT):
    """The profile, read like the base reads any root file: regular, no-follow, bounded; None when unsafe."""
    try:
        raw, _ = settings.read_regular(path, limit)
        return raw.decode("utf-8", "replace")
    except (OSError, settings.SettingsError):
        return None


def durum(env):
    """Read-only view for the page: paths, interface, account name; never the password hash."""
    profile = env.get("TORRENT_PROFILE_DIR", "")
    text = read_conf(conf_path(env)) if profile else None
    if text is None:
        return {"error": "qBittorrent'in ayar dosyası okunamadı", "profile": profile}
    q = ini_values(text)
    downloads = env.get("DOWNLOADS_PATH", "")

    def inside(path):
        if not path or not downloads:
            return False
        real, root = os.path.realpath(path), os.path.realpath(downloads)
        return real == root or real.startswith(root.rstrip("/") + "/")
    save = q.get(("BitTorrent", "Session\\DefaultSavePath")) or q.get(("Preferences", "Downloads\\SavePath"), "")
    temp = q.get(("BitTorrent", "Session\\TempPath")) or q.get(("Preferences", "Downloads\\TempPath"), "")
    port = q.get(("BitTorrent", "Session\\Port"), "")
    return {"profile": profile, "downloads": downloads, "save": save, "save_inside": inside(save),
            "temp": temp, "temp_on": q.get(("BitTorrent", "Session\\TempPathEnabled"), "").lower() == "true",
            "temp_inside": inside(temp),
            "ui": "%s:%s" % (q.get(("Preferences", "WebUI\\Address"), ""), q.get(("Preferences", "WebUI\\Port"), "")),
            "peer_port": int(port) if port.isdigit() else 0,
            "username": q.get(("Preferences", "WebUI\\Username"), "admin")}


def snapshot(path):
    settings.require(not path.is_symlink(), "Sembolik ayar dosyası reddedildi.")
    if not path.exists():
        return None
    data, info = settings.read_regular(path)
    return {"data": data, "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}


def restore(path, snap):
    if snap is None:
        if path.exists() and not path.is_symlink():
            path.unlink()
        return
    settings.atomic(path, snap["data"], snap["mode"], (snap["uid"], snap["gid"]))


def change(env, updates, drop_in=None):
    """Stop/snapshot/write/start; a failure restores the files and starts the service again."""
    unit = unit_name(env)
    conf = conf_path(env)
    settings.require(conf.is_file() and not conf.is_symlink(), "qBittorrent kurulu değil.")
    active = settings.run(["systemctl", "is-active", "--quiet", unit], check=False).returncode == 0
    saved = {conf: None, drop_in_path(env): None}
    try:
        # Stop first: qBittorrent writes its settings back on shutdown.
        settings.run(["systemctl", "stop", unit], timeout=25)
        saved[conf] = snapshot(conf)
        if drop_in is not None:
            saved[drop_in_path(env)] = snapshot(drop_in_path(env))
            settings.atomic(drop_in_path(env), drop_in, 0o644)
            settings.run(["systemctl", "daemon-reload"])
        text = settings.read_regular(conf)[0].decode()
        settings.atomic(conf, ini_patch(text, updates), 0o640, (int(env["DOWNLOADS_UID"]), int(env["DOWNLOADS_GID"])))
        if active:
            settings.run(["systemctl", "start", unit], timeout=25)
            settings.run(["systemctl", "is-active", "--quiet", unit])
    except Exception:
        for path, snap in saved.items():
            if snap is not None or path.exists():
                restore(path, snap)
        if drop_in is not None:
            settings.run(["systemctl", "daemon-reload"], check=False)
        if active:
            settings.run(["systemctl", "start", unit], timeout=25, check=False)
        raise


def hesap(env, data):
    settings.require(isinstance(data, dict) and set(data) <= {"username", "password"} and bool(data), "Hesap alanı geçersiz.")
    updates = {}
    if "username" in data:
        settings.require(isinstance(data["username"], str) and USERNAME_RE.fullmatch(data["username"]),
                         "Kullanıcı adı geçersiz (1–64 harf/rakam/._@-).")
        updates[("Preferences", "WebUI\\Username")] = data["username"]
    if "password" in data:
        settings.require(isinstance(data["password"], str) and 8 <= len(data["password"]) <= 256
                         and all(ord(x) >= 32 for x in data["password"]), "Parola 8–256 karakter olmalı.")
        updates[("Preferences", "WebUI\\Password_PBKDF2")] = password_hash(data["password"])
    change(env, updates)
    return {"ok": True, "username": durum(env).get("username", "")}


def dizin(env, data, state):
    settings.require(isinstance(data, dict) and set(data) == {"save"}, "Dizin alanı geçersiz.")
    # The base owns the user-area policy (downloads/library only, no hidden/share/trash dirs,
    # writable by the service user); the package only asks it.
    path = str(settings.Manager(state).safe_dir(data["save"], writable=True)).rstrip("/") + "/"
    updates = {("BitTorrent", "Session\\DefaultSavePath"): '"' + path + '"',
               ("Preferences", "Downloads\\SavePath"): '"' + path + '"'}
    # One narrow extra write path for the sandboxed service; downloads + temp stay available.
    change(env, updates, '[Service]\nReadWritePaths="' + path.rstrip("/") + '"\n')
    return {"ok": True, "save": path}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default=os.environ.get("STATE_FILE", "/etc/master-stack/state.env"))
    parser.add_argument("--lib", default=None, help=argparse.SUPPRESS)  # consumed above, before the import
    parser.add_argument("action", choices=("hesap", "dizin", "durum"))
    args = parser.parse_args()
    try:
        env = package_env(settings.env_read(args.state))
        if args.action == "durum":
            print(json.dumps(durum(env), ensure_ascii=False))
            return
        raw = sys.stdin.read(LIMIT + 1)
        settings.require(len(raw) <= LIMIT, "İstek çok büyük.")
        data = json.loads(raw)
        with settings.Manager(args.state).locked():
            result = hesap(env, data) if args.action == "hesap" else dizin(env, data, args.state)
        print(json.dumps(result, ensure_ascii=False))
    except (settings.SettingsError, ValueError, KeyError, TypeError, OSError, RecursionError) as err:
        message = str(err) if isinstance(err, settings.SettingsError) else "qBittorrent ayarı uygulanamadı; önceki ayar geri yüklendi."
        print(json.dumps({"error": message}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
