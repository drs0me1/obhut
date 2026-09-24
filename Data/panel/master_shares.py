#!/usr/bin/env python3
"""Klasör paylaşımlarının root yöneticisi. Parolalar yalnız stdin; diskte scrypt özeti.

WebDAV işlemleri indirme hesabında, master_webdav.py içinde yürür. Yönetici sabit
eylemler dışında komut çalıştırmaz; JSON kayıt 0600 ve servis LoadCredential kullanır.
"""
import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import stat
import struct
import subprocess
import sys
import tempfile
import time

UNIT = "master-paylasim.service"
ID_RE = re.compile(r"[0-9a-f]{24}\Z")
USER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,31}\Z")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


class ShareError(Exception):
    pass


def env_read(path):
    with open(path, encoding="utf-8") as stream:
        return {k: v.strip('"') for line in stream if not line.startswith("#") and "=" in line
                for k, v in [line.rstrip("\n").split("=", 1)]}


def parts(raw, empty=False):
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > 4096:
        raise ShareError("Geçersiz klasör yolu.")
    out = raw.strip("/").split("/") if raw.strip("/") else []
    if (not out and not empty) or len(out) > 64 or any(
            not p or p.startswith(".") or "\\" in p or len(p.encode("utf-8")) > 255
            or any(ord(c) < 32 or ord(c) == 127 for c in p) for p in out):
        raise ShareError("Kök, gizli/iç klasörler ve geçersiz yollar paylaşılamaz.")
    return out


def open_dir(root, path):
    fd = os.open(root, DIR_FLAGS) if isinstance(root, str) else os.dup(root)
    try:
        for name in path:
            nxt = os.open(name, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def identity(fd):
    """Birth time prevents inode reuse from exposing a replacement directory."""
    st = os.fstat(fd)
    if sys.platform == "linux":
        buf = ctypes.create_string_buffer(256)
        libc = ctypes.CDLL(None, use_errno=True)
        # statx(fd, "", AT_EMPTY_PATH|AT_SYMLINK_NOFOLLOW, STATX_BTIME, buf)
        if libc.statx(fd, b"", 0x1000 | 0x100, 0x800, ctypes.byref(buf)) != 0:
            raise ShareError("Dosya sistemi klasör kimliğini doğrulayamıyor (statx).")
        mask = struct.unpack_from("=I", buf.raw, 0)[0]
        sec, ns = struct.unpack_from("=qI", buf.raw, 80)
        if not mask & 0x800:
            raise ShareError("Bu dosya sistemi güvenli paylaşım için oluşturulma zamanını sağlamıyor.")
        birth = [sec, ns]
    else:
        birth = [getattr(st, "st_birthtime", 0)]
    return [st.st_dev, st.st_ino, birth]


def password_hash(password, salt=None):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt),
                            n=16384, r=8, p=1, dklen=32).hex()
    return salt, digest


def password_ok(item, password):
    return hmac.compare_digest(password_hash(password, item["salt"])[1], item["hash"])


def load(path):
    fd = os.open(path, FILE_FLAGS)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ShareError("Paylaşım kaydı düz dosya olmalı.")
        raw = stream.read(262145)
    if len(raw) > 262144:
        raise ShareError("Paylaşım kaydı çok büyük.")
    data = json.loads(raw)
    if data.get("schema") != 2 or not isinstance(data.get("items"), list):
        raise ShareError("Paylaşım kaydı desteklenmiyor.")
    return data


def atomic(path, data):
    directory = os.path.dirname(path)
    fd, temp = tempfile.mkstemp(prefix=".webdav-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        dfd = os.open(directory, DIR_FLAGS)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class Manager:
    def __init__(self, state):
        self.env = env_read(state)
        self.path = self.env["SHARE_STATE_FILE"]

    def initial(self):
        e = self.env
        return {"schema": 2, "root": e["SERVER_ROOT"], "items": [], "temp_name": e["TORRENT_TEMP_DIR"],
                "blocked": [e["FILES_PANEL_TRASH"], e["SHARE_DIR"],
                            os.path.relpath(e["DOWNLOADS_PATH"], e["SERVER_ROOT"]) + "/" + e["TORRENT_TEMP_DIR"]]}

    def read(self):
        try:
            return load(self.path)
        except FileNotFoundError:
            return self.initial()

    def module_state(self):
        try:
            with open(self.env["MODULES_FILE"], encoding="utf-8") as stream:
                return next((line.rstrip().split("\t")[1] for line in stream
                             if line.startswith("paylasim\t")), "")
        except FileNotFoundError:
            return ""

    def public(self):
        data = self.read()
        result = []
        base = "http://%s:%s" % (self.env["TAILSCALE_IPV4"], self.env["SHARE_PORT"])
        for item in data["items"]:
            row = {k: item[k] for k in ("id", "path", "name", "username", "permission", "paused",
                                       "created", "changed", "expires")}
            row.update(type="dir", url=base + "/s/" + item["id"] + "/", available=False)
            try:
                fd = open_dir(data["root"], parts(item["path"]))
                try:
                    row["available"] = identity(fd) == item["identity"]
                finally:
                    os.close(fd)
            except (OSError, ShareError):
                pass
            row["expired"] = bool(item["expires"] and time.time() >= item["expires"])
            result.append(row)
        state = self.module_state()
        return {"enabled": bool(state), "running": state == "calisiyor", "host": base,
                "items": result, "max": 32}

    def validate_path(self, data, path, exclude=""):
        pp = parts(path)
        path = "/".join(pp)
        blocked = list(data["blocked"])
        # Respect a user-selected qBittorrent incomplete folder as well as the default.
        conf = os.path.join(self.env["TORRENT_PROFILE_DIR"], "qBittorrent", "qBittorrent.conf")
        try:
            with open(conf, encoding="utf-8") as stream:
                for line in stream:
                    if line.startswith(("Session\\TempPath=", "Downloads\\TempPath=")):
                        temp = os.path.normpath(line.rstrip().split("=", 1)[1])
                        if temp.startswith(data["root"] + "/"):
                            blocked.append(os.path.relpath(temp, data["root"]))
        except FileNotFoundError:
            pass
        others = blocked + [i["path"] for i in data["items"] if i["id"] != exclude]
        if any(path == p or path.startswith(p + "/") or p.startswith(path + "/") for p in others):
            raise ShareError("Bu klasör iç/geçici alanla veya başka bir paylaşımla çakışıyor. Bir alt klasör seçin.")
        fd = open_dir(data["root"], pp)
        try:
            return path, identity(fd)
        finally:
            os.close(fd)

    def change(self, action, request):
        with contextlib.ExitStack() as stack:
            # Same ordering as settings; no module lifecycle/installer race.
            for name in ("install.lock", "modul.lock", "paylasim.lock"):
                stream = stack.enter_context(open(os.path.join(self.env["RUNTIME_DIR"], name), "a"))
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise ShareError("Başka bir kurulum/ayar işlemi sürüyor; yeniden deneyin.")
            if os.path.exists(self.env["SETTINGS_PENDING_FILE"]):
                raise ShareError("Önce bekleyen ayar değişikliğini onaylayın veya geri alın.")
            if not self.module_state():
                raise ShareError("Yerleşik WebDAV kurulumu tamamlanmamış; kurulumu yeniden çalıştırın.")
            old = self.read()
            data = json.loads(json.dumps(old))
            items = data["items"]
            sid = request.get("id", "")
            item = next((i for i in items if i["id"] == sid), None)
            if sid and (not isinstance(sid, str) or not ID_RE.fullmatch(sid) or item is None):
                raise ShareError("Paylaşım bulunamadı.")
            if action == "save":
                if item is None and len(items) >= 32:
                    raise ShareError("En çok 32 bağımsız paylaşım oluşturulabilir.")
                user = request.get("username", "")
                if not isinstance(user, str) or not USER_RE.fullmatch(user):
                    raise ShareError("Kullanıcı adı 3–32 harf/rakam veya . _ - içermeli.")
                if any(i["username"].lower() == user.lower() and i["id"] != sid for i in items):
                    raise ShareError("Bu kullanıcı adı başka bir paylaşımda kullanılıyor.")
                permission = request.get("permission", "ro")
                if permission not in ("ro", "rw"):
                    raise ShareError("Geçersiz erişim izni.")
                if permission == "rw" and request.get("ack_write") is not True:
                    raise ShareError("Yazma izninin silmeyi de kapsadığını onaylayın.")
                password = request.get("password", "")
                if not isinstance(password, str) or len(password) > 256 or ":" in password or any(ord(c) < 32 for c in password):
                    raise ShareError("Parola geçersiz (en çok 256 karakter; kontrol karakteri ve : yok).")
                if (password or item is None) and len(password) < 12:
                    raise ShareError("Yeni parola en az 12 karakter olmalı.")
                days = request.get("days")
                if days is not None and (type(days) is not int or days not in (0, 1, 7, 30)):
                    raise ShareError("Süre 1, 7, 30 gün veya süresiz olabilir.")
                path, ident = self.validate_path(data, request.get("path"), sid)
                now = int(time.time())
                if item is None:
                    item = {"id": secrets.token_hex(12), "created": now, "paused": False, "expires": None}
                    items.append(item)
                item.update(path=path, identity=ident, name=path.rsplit("/", 1)[-1], username=user,
                            permission=permission, changed=now)
                if password:
                    item["salt"], item["hash"] = password_hash(password)
                if days is not None:
                    item["expires"] = now + days * 86400 if days else None
            elif action == "pause" and item is not None and type(request.get("paused")) is bool:
                item["paused"] = request["paused"]
                item["changed"] = int(time.time())
            elif action == "remove" and item is not None:
                items.remove(item)
            else:
                raise ShareError("Geçersiz paylaşım işlemi.")
            atomic(self.path, data)
            if self.module_state() == "calisiyor":
                try:
                    self.restart()
                except (subprocess.SubprocessError, OSError, ShareError):
                    atomic(self.path, old)
                    try:
                        self.restart()
                    except (subprocess.SubprocessError, OSError, ShareError):
                        raise ShareError("Önceki kayıt geri yüklendi ancak WebDAV başlamadı. Sunucuda master-paylasim günlüğünü kontrol edin.")
                    raise ShareError("Paylaşım yeniden başlatılamadı; önceki kayıt geri yüklendi.")
            return self.public()

    def restart(self):
        # Explicit user changes must not exhaust the automatic crash restart limit.
        subprocess.run(["systemctl", "reset-failed", UNIT], check=True, timeout=10, capture_output=True)
        subprocess.run(["systemctl", "restart", UNIT], check=True, timeout=30, capture_output=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            conn = http.client.HTTPConnection("127.0.0.1", int(self.env["SHARE_PORT"]), timeout=1)
            try:
                conn.request("GET", "/")
                response = conn.getresponse()
                response.read()
                if response.status == 401:
                    return
            except (OSError, http.client.HTTPException):
                pass
            finally:
                conn.close()
            time.sleep(.1)
        raise ShareError("WebDAV yeniden başlatıldı ancak giriş kapısı yanıt vermiyor.")

    def prepare(self):
        if not os.path.exists(self.path):
            atomic(self.path, self.initial())
        else:
            self.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default=os.environ.get("STATE_FILE", "/etc/master-stack/state.env"))
    parser.add_argument("action", choices=("prepare", "status", "save", "pause", "remove"))
    args = parser.parse_args()
    try:
        manager = Manager(args.state)
        if args.action == "prepare":
            manager.prepare()
            return
        result = manager.public() if args.action == "status" else manager.change(args.action, json.loads(sys.stdin.read(65537)))
        print(json.dumps(result, ensure_ascii=False))
    except (ShareError, OSError, ValueError, KeyError) as err:
        print(json.dumps({"error": str(err) if isinstance(err, ShareError) else "Paylaşım kaydı işlenemedi; kurulumu kontrol edin."}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
