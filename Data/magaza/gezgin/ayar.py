#!/usr/bin/env python3
"""Gezgin package: install-form worker and Podman adapter (DD-262).

    ayar.py --state STATE kur-hazirla --tohum SEED   {"username", "password"}  the base, before the engine
    ayar.py --state STATE kur-uygula --tohum SEED    the engine, before the container's first start
    ayar.py --state STATE kur-geri --tohum SEED      the engine, when that install fails
    ayar.py --state STATE konteyner-ayar             the Podman page (Gezgin has no field to edit there)
    ayar.py --state STATE konteyner-guncelle         {"revision"}: DD-214, move to the channel's digest

container_config(env) is the adapter's read side; the base loads it as a module. JSON on stdin and stdout,
exit 1 with {"error"} on refusal.

DD-210: the first administrator. Python's standard library has no bcrypt and Gezgin's own `hash` command
takes the password as an argument, so the base's Caddy hashes it from standard input (`caddy
hash-password`): the password reaches no argv, environment or journal. Only the hash goes into the private
seed; kur-uygula writes it with the user name into ilk.env, which Podman reads when the container starts;
Gezgin creates the account while its database is empty, and the hook then empties the file. A database
kept from an earlier install keeps its users: the form's account is not created then.
"""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import time


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
PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
USERNAME_RE = re.compile(r"[A-Za-z0-9._@-]{1,64}")
# bcrypt as Caddy and Go's x/crypto write it; bcrypt reads at most 72 bytes of a password.
HASH_RE = re.compile(r"\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}")
PASSWORD_MIN, PASSWORD_MAX_BYTES = 12, 72
SEED_RE = re.compile(r"modul-[a-z]{2,16}\.kur")
CONTAINER_RE = re.compile(r"[a-z][a-z0-9-]{1,30}")
STOP_TIMEOUT = 40   # the quadlet's StopTimeout (20 s) plus the container teardown


class ContainerEditError(settings.SettingsError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def package_env(env):
    """The package's own settings (gezgin.env next to this file, DD-203) on top of the base's state."""
    merged = dict(env)
    merged.update(settings.env_read(os.path.join(PACKAGE_DIR, "gezgin.env")))
    merged.update(settings.package_overrides(env, "gezgin"))
    return merged


def container_name(env):
    name = env.get("GEZGIN_CONTAINER", "")
    settings.require(bool(CONTAINER_RE.fullmatch(name)), "Konteyner adı geçersiz.")
    return name


def unit_name(env):
    return container_name(env) + ".service"


def data_dir(env):
    path = env.get("GEZGIN_DATA_DIR", "")
    settings.require(path.startswith("/var/lib/") and len(path) > len("/var/lib/") and ".." not in path.split("/"),
                     "Gezgin'in veri klasörü geçersiz.")
    return Path(path)


def ilk_path(env):
    return data_dir(env) / "ilk.env"


def wait_ui(env, seconds=40):
    """The unit is active before Gezgin listens; a change counts only once /health answers on loopback."""
    port = int(env.get("GEZGIN_UI_PORT", "0") or 0)
    deadline = time.monotonic() + seconds
    while True:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            try:
                conn.request("GET", "/health")
                if conn.getresponse().status == 200:
                    return
            finally:
                conn.close()
        except OSError:
            pass
        if time.monotonic() >= deadline:
            raise settings.SettingsError("Gezgin yeniden başlatmadan sonra yanıt vermedi.")
        time.sleep(1)


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


def image_files(env):
    """DD-214: the files that name the pinned image: the rendered Quadlet, the rendered manifest and, while
    the app is placed, the active Quadlet (a drop-in cannot replace Image=)."""
    name = container_name(env) + ".container"
    placed = Path(env["KONTEYNER_BIRIM_DIR"]) / name
    return Path(PACKAGE_DIR) / name, Path(PACKAGE_DIR) / "paket.env", placed


def patch_image(text, old, new, manifest=False):
    pattern = r'^(PAKET_IMAJ=)"?' + re.escape(old) + r'"?$' if manifest else r"^(Image=)" + re.escape(old) + r"$"
    result, count = re.subn(pattern, lambda m: m[1] + ('"%s"' % new if manifest else new), text, flags=re.M)
    settings.require(count == 1, "İmaj satırı doğrulanamadı; kurulumu yeniden çalıştırın.")
    return result


def container_config(env):
    """Declared App Store adapter: effective settings and an opaque stale-edit revision. Gezgin's own
    settings live in Gezgin; nothing here is editable from the Podman page."""
    env = package_env(env)
    config = {"listener_port": int(env["GEZGIN_UI_PORT"])}
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
    quadlet, _, placed = image_files(env)
    paths = [quadlet, placed]
    override = settings.package_override_path(env, "gezgin")
    if override is not None:
        paths.append(override)
    for path in paths:
        digest.update(str(path).encode() + b"\0")
        try:
            digest.update(settings.read_regular(path)[0])
        except FileNotFoundError:
            digest.update(b"missing")
    state = ""
    if env.get("MODULES_FILE"):
        try:
            state = next((line for line in settings.read_regular(env["MODULES_FILE"])[0].decode().splitlines()
                          if line.split("\t", 1)[0] == "gezgin"), "")
        except FileNotFoundError:
            pass
    digest.update(state.encode())
    root, data = env["SERVER_ROOT"], data_dir(env)
    return {"config": config, "revision": digest.hexdigest(), "editable": [],
            "protected_mounts": [
                {"source": root, "target": "/srv", "destination": "/srv", "reason": "Gezgin'in kökü: kullanıcı alanı."},
                {"source": str(data / "database"), "target": "/database", "destination": "/database",
                 "reason": "Kullanıcılar, ayarlar ve bağlantı paylaşımları."},
                {"source": str(data / "config"), "target": "/config", "destination": "/config", "reason": "Gezgin'in ayar dosyası."}],
            "effective_autostart": state == "gezgin\tcalisiyor"}


def _runner(argv, timeout):
    """master_containers' runner contract over the shared command helper: (rc, stdout, last stderr line)."""
    try:
        p = settings.run(argv, check=False, timeout=timeout)
    except settings.SettingsError:
        return 1, "", argv[0] + " çalıştırılamadı"
    lines = [line for line in p.stderr.splitlines() if line.strip()]
    return p.returncode, p.stdout, lines[-1] if lines else ""


def konteyner_guncelle(env, data, state):
    """DD-214: move the pinned image to what the update channel points to now, on explicit request.

    Pulls the exact new digest before touching the running service; restarts only a running app and
    verifies /health and the container's image; any failure restores every file and the previous
    service state. The previous image is removed only after success.
    """
    import master_containers
    settings.require(isinstance(data, dict) and set(data) == {"revision"} and isinstance(data["revision"], str),
                     "Güncelleme alanları geçersiz.")
    current = container_config(env)
    if data["revision"] != current["revision"]:
        raise ContainerEditError("Ayarlar değişti; sayfayı yenileyip yeniden deneyin.", 409)
    channel = env.get("GEZGIN_IMAGE_KANAL", "")
    settings.require(bool(channel) and "@" not in channel, "Bu uygulama için güncelleme kanalı tanımlı değil.")
    quadlet, manifest, placed = image_files(env)
    lines = re.findall(r"^Image=(\S+)$", (snapshot(quadlet) or {"data": b""})["data"].decode(), re.M)
    settings.require(len(lines) == 1, "Gezgin paketi bulunamadı; kurulumu yeniden çalıştırın.")
    old = lines[0]
    rc, arch, _ = _runner(["podman", "info", "--format", "{{.Host.Arch}}"], 20)
    settings.require(rc == 0 and bool(arch.strip()), "Podman yanıt vermedi.")
    status = master_containers.update_status(_runner, old, channel, arch.strip())
    if status["state"] == "guncel":
        return dict(current, ok=True, changed=False, image=old)
    if status["state"] != "var" or not status["candidate"]:
        raise ContainerEditError(status["error"] or "Güncelleme denetlenemedi.", 502)
    new = status["candidate"]
    override = settings.package_override_path(env, "gezgin")
    settings.require(override is not None, "Kalıcı paket ayar dizini yok; kurulumu yeniden çalıştırın.")
    chosen = dict(settings.package_overrides(env, "gezgin"), GEZGIN_IMAGE=new)
    targets = [override, quadlet, manifest] + ([placed] if placed.exists() else [])
    before = {target: snapshot(target) for target in targets}
    settings.require(before[quadlet] is not None and before[manifest] is not None, "Gezgin paketi bulunamadı; kurulumu yeniden çalıştırın.")
    texts = {override: "".join(k + "=" + v + "\n" for k, v in sorted(chosen.items())),
             quadlet: patch_image(before[quadlet]["data"].decode(), old, new),
             manifest: patch_image(before[manifest]["data"].decode(), old, new, manifest=True)}
    if placed in before:
        texts[placed] = patch_image(before[placed]["data"].decode(), old, new)
    # Every file was validated above; only now the exact digest is downloaded, before any service change.
    settings.run(["podman", "pull", "-q", new], timeout=600)
    unit = unit_name(env)
    active = settings.run(["systemctl", "is-active", "--quiet", unit], check=False).returncode == 0
    restarted = False
    try:
        for target in targets:
            settings.atomic(target, texts[target], 0o600 if target == override else before[target]["mode"] if before[target] else 0o644)
        settings.run(["systemctl", "daemon-reload"])
        if active:
            restarted = True
            settings.run(["systemctl", "restart", unit], timeout=STOP_TIMEOUT + 60)
            settings.run(["systemctl", "is-active", "--quiet", unit])
            wait_ui(env)
            image = settings.run(["podman", "inspect", "--format", "{{.ImageName}}", container_name(env)], timeout=20).stdout.strip()
            settings.require(image == new, "Konteyner yeni imajla açılmadı.")
    except Exception as error:
        rollback_failed = False
        for target in targets:
            try:
                restore(target, before[target])
            except (OSError, settings.SettingsError):
                rollback_failed = True
        try:
            settings.run(["systemctl", "daemon-reload"])
            if restarted:
                settings.run(["systemctl", "restart", unit], timeout=STOP_TIMEOUT + 60)
                settings.run(["systemctl", "is-active", "--quiet", unit])
                wait_ui(env)
        except settings.SettingsError:
            rollback_failed = True
        if rollback_failed:
            raise ContainerEditError("Güncelleme başarısız ve önceki imaj tam geri yüklenemedi; servis durumunu denetleyin.", 503) from error
        raise ContainerEditError("Güncelleme başarısız; önceki imaja dönüldü.", 502) from error
    # The old image goes only now and only if nothing else uses it (no force).
    rc, ident, _ = _runner(["podman", "image", "inspect", "--format", "{{.Id}}", old], 20)
    rc_new, ident_new, _ = _runner(["podman", "image", "inspect", "--format", "{{.Id}}", new], 20)
    if rc == 0 and re.fullmatch(r"[0-9a-f]{64}", ident.strip()) and ident.strip() != ident_new.strip():
        _runner(["podman", "rmi", ident.strip()], 60)
    _, version, _ = _runner(["podman", "image", "inspect", "--format", '{{index .Labels "org.opencontainers.image.version"}}', new], 20)
    return dict(container_config(dict(env, GEZGIN_IMAGE=new)), ok=True, changed=True, image=new, previous=old,
                version=version.strip()[:80])


def check_username(value):
    settings.require(isinstance(value, str) and USERNAME_RE.fullmatch(value) is not None,
                     "Kullanıcı adı 1-64 karakter olmalı; harf, rakam ve . _ @ - kullanılabilir.")
    return value


def check_password(value):
    settings.require(isinstance(value, str) and len(value) >= PASSWORD_MIN, "Parola en az %d karakter olmalı." % PASSWORD_MIN)
    settings.require(len(value.encode("utf-8")) <= PASSWORD_MAX_BYTES, "Parola en çok %d bayt olabilir." % PASSWORD_MAX_BYTES)
    settings.require(not any(ord(ch) < 32 or ord(ch) == 127 for ch in value), "Parolada satır sonu ya da denetim karakteri olamaz.")
    return value


def password_hash(password):
    """bcrypt from the base's Caddy; the password goes on standard input as one line, never in argv."""
    p = settings.run(["caddy", "hash-password"], input=password + "\n", timeout=60)
    value = p.stdout.strip()
    settings.require(HASH_RE.fullmatch(value) is not None, "Parola özeti üretilemedi.")
    return value


def seed_path(env, value):
    """The seed sits directly in the base's runtime folder under the engine's name for it."""
    path = Path(value)
    settings.require(SEED_RE.fullmatch(path.name) is not None and str(path.parent) == str(Path(env.get("RUNTIME_DIR", "/nonexistent"))),
                     "Kurulum bilgisi dosyası geçersiz.")
    return path


def kur_hazirla(env, data, state, seed):
    """DD-210: validate the install form and keep only the hash, before the engine starts."""
    path = seed_path(env, seed)
    settings.require(isinstance(data, dict) and set(data) == {"username", "password"}, "Kurulum bilgileri eksik ya da geçersiz.")
    username = check_username(data["username"])
    check_password(data["password"])
    settings.atomic(path, json.dumps({"username": username, "hash": password_hash(data["password"])}) + "\n", 0o600)
    return {"ok": True, "username": username}


def read_seed(path):
    raw, info = settings.read_regular(path, LIMIT)
    settings.require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) & 0o077 == 0, "Kurulum bilgisi dosyası korunmuyor.")
    doc = json.loads(raw.decode("utf-8"))
    settings.require(isinstance(doc, dict) and set(doc) == {"username", "hash"}, "Kurulum bilgisi dosyası geçersiz.")
    check_username(doc["username"])
    settings.require(isinstance(doc["hash"], str) and HASH_RE.fullmatch(doc["hash"]) is not None, "Kurulum bilgisi dosyası geçersiz.")
    return doc


def kur_uygula(env, seed):
    """DD-210: hand the account to the container's first start through ilk.env (Podman reads it itself, so
    the hash's "$" stays literal). The file as it was goes next to the seed for kur-geri."""
    path = seed_path(env, seed)
    doc = read_seed(path)
    target = ilk_path(env)
    settings.require(target.parent.is_dir() and not target.parent.is_symlink(), "Gezgin'in veri klasörü hazır değil.")
    before = snapshot(target)
    keep = None if before is None else dict(before, data=base64.b64encode(before["data"]).decode())
    settings.atomic(str(path) + ".onceki", json.dumps({"ilk": keep}) + "\n", 0o600)
    text = ("# Gezgin: ilk açılışın yönetici hesabı (DD-262); veritabanı oluşunca boşaltılır.\n"
            "GEZGIN_USERNAME=%s\nGEZGIN_PASSWORD=%s\n" % (doc["username"], doc["hash"]))
    settings.atomic(target, text, 0o600)
    return {"ok": True}


def kur_geri(env, seed):
    """DD-210: a failed install returns ilk.env to what it was before kur-uygula."""
    path = Path(str(seed_path(env, seed)) + ".onceki")
    try:
        raw, info = settings.read_regular(path, LIMIT)
    except FileNotFoundError:
        return {"ok": True}
    settings.require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) & 0o077 == 0, "Kurulum yedeği korunmuyor.")
    snap = json.loads(raw.decode("utf-8")).get("ilk")
    restore(ilk_path(env), None if snap is None else dict(snap, data=base64.b64decode(snap["data"])))
    return {"ok": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default=os.environ.get("STATE_FILE", "/etc/master-stack/state.env"))
    parser.add_argument("--lib", default=None, help=argparse.SUPPRESS)  # consumed above, before the import
    parser.add_argument("--tohum", default=None, help="DD-210: the engine's seed file for the install form")
    parser.add_argument("action", choices=("konteyner-ayar", "konteyner-guncelle", "kur-hazirla", "kur-uygula", "kur-geri"))
    args = parser.parse_args()
    if args.action.startswith("kur-") and not args.tohum:
        parser.error("--tohum gerekli")
    try:
        env = package_env(settings.env_read(args.state))
        # The engine runs these inside its own install, holding the locks already.
        if args.action in ("kur-uygula", "kur-geri"):
            result = (kur_uygula if args.action == "kur-uygula" else kur_geri)(env, args.tohum)
            print(json.dumps(result, ensure_ascii=False))
            return
        raw = sys.stdin.read(LIMIT + 1)
        settings.require(len(raw) <= LIMIT, "İstek çok büyük.")
        data = json.loads(raw)
        manager = settings.Manager(args.state)
        with manager.locked():
            if args.action in ("konteyner-ayar", "konteyner-guncelle") and manager.pending():
                raise ContainerEditError("Konsol'da onay bekleyen ayar var; önce onaylayın veya geri alın.", 409)
            if args.action == "kur-hazirla":
                result = kur_hazirla(env, data, args.state, args.tohum)
            elif args.action == "konteyner-guncelle":
                result = konteyner_guncelle(env, data, args.state)
            else:
                raise ContainerEditError("Gezgin'in Podman sayfasında düzenlenecek ayarı yok; ayarları Gezgin'in içindedir.", 400)
        print(json.dumps(result, ensure_ascii=False))
    except (settings.SettingsError, ValueError, KeyError, TypeError, OSError, RecursionError) as err:
        message = str(err) if isinstance(err, settings.SettingsError) else "Gezgin işlemi uygulanamadı."
        result = {"error": message}
        if args.action in ("konteyner-ayar", "konteyner-guncelle"):
            result["status"] = getattr(err, "status", 409 if isinstance(err, settings.SettingsBusy) else
                                       400 if isinstance(err, (settings.SettingsError, ValueError, TypeError)) else 503)
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
