#!/usr/bin/env python3
"""DD-177: retire WG host access on installer upgrades; no keys/profiles read.

Called only by install.sh while holding install.lock. Module/settings mutations
are excluded too. Fresh/repeated installations are no-ops; failed retirement is
fatal and retryable, never a reason to restore the retired permission.
"""
import contextlib
import fcntl
import ipaddress
from pathlib import Path
import re
import sys

from master_settings import SettingsError, atomic, env_read, read_json, require, run, save_json


def retire(env):
    registry = Path(env["WG_NETWORKS_FILE"])
    require(not registry.is_symlink(), "WireGuard ağ kaydı bağlantı olamaz.")
    old = registry.read_text() if registry.exists() else ""
    rows, seen, ports = [], set(), set()
    for line in old.splitlines():
        f = line.split("\t")
        require(len(f) == 9 and re.fullmatch(r"wg[0-9]", f[0]), "WireGuard ağ kaydı geçersiz.")
        require(f[1].isdigit() and 1 <= int(f[1]) <= 65535 and f[2] in ("ui", "inet"),
                "WireGuard port/politika kaydı geçersiz.")
        require(f[0] not in seen and int(f[1]) not in ports, "WireGuard ağ kaydı tekrarlanıyor.")
        require(ipaddress.ip_address(f[3]) in ipaddress.ip_network(f[4]) and
                ipaddress.ip_address(f[5]) in ipaddress.ip_network(f[6]), "WireGuard adres kaydı geçersiz.")
        seen.add(f[0])
        ports.add(int(f[1]))
        f[2] = "inet"  # Retain column positions and every other byte/field.
        rows.append("\t".join(f))
    new = "\n".join(rows) + ("\n" if rows else "")
    settings = Path(env["SETTINGS_FILE"])
    require(not settings.is_symlink(), "Ayar kaydı bağlantı olamaz.")
    config = read_json(settings, None)
    kept = None if config is None else [
        r for r in config["firewall"] if not re.fullmatch(r"wg[0-9]", str(r.get("scope", "")))]
    # Validate everything before stopping/removing any old runtime artifact.
    require(not Path(env["SETTINGS_PENDING_FILE"]).exists(), "Önce bekleyen ayar işlemini tamamlayın.")
    unit_dir, wg_dir = Path(env["UNIT_DIR"]), Path(env["WG_CONF_DIR"])
    template = unit_dir / "caddy-wg@.service"
    files = [template, Path(env["CADDYFILE"]).with_name("Caddyfile.wg")]
    for i in range(int(env["WG_NETWORKS_MAX"]) + 1):
        files.append(wg_dir / f"caddy-wg-wg{i}.env")
    require(all(not p.is_symlink() for p in files), "Eski WireGuard servis dosyası bağlantı olamaz.")
    changed = any(p.exists() for p in files)
    # Exact project instances only: orphaned/stopped instances are retired too.
    for i in range(int(env["WG_NETWORKS_MAX"]) + 1):
        unit = f"caddy-wg@wg{i}.service"
        loaded = run(["systemctl", "show", "-p", "LoadState", "--value", unit], check=False)
        if loaded.stdout.strip() not in ("", "not-found"):
            run(["systemctl", "disable", "--now", unit])
            require(run(["systemctl", "is-active", "--quiet", unit], check=False).returncode != 0,
                    "Eski WireGuard web servisi durdurulamadı.")
            changed = True
    for path in files:
        path.unlink(missing_ok=True)
    if changed:
        run(["systemctl", "daemon-reload"])
    if old != new:
        atomic(registry, new)
    if config is not None and kept != config["firewall"]:
        config["firewall"] = kept
        save_json(settings, config)
    print("WireGuard: yalnız internet politikası hazır; anahtarlar ve profiller korundu.")


def main(state):
    env = env_read(state)
    with contextlib.ExitStack() as stack:
        for name in ("modul.lock", "settings.lock"):
            fd = stack.enter_context(open(Path(env["RUNTIME_DIR"]) / name, "a"))
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as err:
                raise SettingsError("Başka bir ayar/modül işlemi sürüyor; kurulumu tekrar deneyin.") from err
        retire(env)


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except (SettingsError, OSError, ValueError, KeyError) as error:
        print("HATA: WireGuard geçişi tamamlanamadı: " + str(error), file=sys.stderr)
        sys.exit(1)
