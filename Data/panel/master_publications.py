#!/usr/bin/env python3
"""Fixed Caddy publication catalogue. No arbitrary upstreams, panel WAN or tunnels.

Settings owns transactions; the existing share publisher applies the small
projection under its locks. qBittorrent preferences are inspected, never rewritten.
"""
import argparse
import fnmatch
import http.client
import ipaddress
from pathlib import Path
import sys

import master_https as tls
from master_settings import SettingsError, atomic, ini_values, read_regular, require

IDS = ("torrent", "paylasim")


def config(env, value=None):
    value = tls.settings(env) if value is None else value
    web = value.get("web", {})
    require(isinstance(web, dict) and set(web) <= set(IDS), "Caddy yayın kaydı geçersiz.")
    dav = tls.config(env, value)
    rows = {"torrent": {"tail": True, "enabled": False, "domain": ""},
            "paylasim": {"tail": True, "enabled": dav["mode"] != "off", "domain": dav["domain"]}}
    for key, item in web.items():
        require(isinstance(item, dict) and set(item) == {"tail", "enabled", "domain"}
                and type(item["tail"]) is bool and type(item["enabled"]) is bool,
                "Caddy ağ seçimi geçersiz.")
        name = tls.domain(item["domain"])
        require(not item["enabled"] or bool(name), "İnternet yayını için HTTPS alan adı gerekli.")
        rows[key] = dict(item, domain=name)
    names = [r["domain"] for r in rows.values() if r["enabled"] and r["domain"]]
    require(len(names) == len(set(names)), "İki uygulama aynı HTTPS alan adını kullanamaz.")
    require(not rows["torrent"]["enabled"] or dav["mode"] != "http",
            "Önce WebDAV için HTTPS kaydedin veya eski HTTP WAN erişimini kapatın.")
    return rows


def module_states(env):
    try:
        text = read_regular(env["MODULES_FILE"], 65536)[0].decode()
    except FileNotFoundError:
        return {}
    return {parts[0]: parts[1] for line in text.splitlines()
            if len(parts := line.split("\t")) == 2}


def torrent_security(env, name, probe=False):
    """Fail closed if the native app permits bypass or has no permanent password."""
    path = Path(env["TORRENT_PROFILE_DIR"]) / "qBittorrent/qBittorrent.conf"
    q = ini_values(read_regular(path)[0].decode())
    def flag(key, default):
        return q.get(("Preferences", "WebUI\\" + key), default).lower()
    require(flag("LocalHostAuth", "true") == "true" and
            flag("AuthSubnetWhitelistEnabled", "false") == "false",
            "qBittorrent internet erişimi için giriş atlama seçenekleri kapalı olmalı.")
    require(bool(q.get(("Preferences", "WebUI\\Password_PBKDF2"))),
            "Önce qBittorrent için kalıcı kullanıcı parolası belirleyin.")
    require(flag("CSRFProtection", "true") == "true" and flag("HostHeaderValidation", "true") == "true",
            "qBittorrent CSRF ve Host koruması açık olmalı.")
    try:
        require(1 <= int(flag("MaxAuthenticationFailCount", "5")) <= 20 and
                int(flag("BanDuration", "3600")) >= 60, "qBittorrent parola denemesi sınırı etkin olmalı.")
    except ValueError as err:
        raise SettingsError("qBittorrent parola denemesi sınırı okunamadı.") from err
    domains = flag("ServerDomains", "*").replace(";", ",").split(",")
    require(any(fnmatch.fnmatchcase(name, part.strip()) for part in domains),
            "qBittorrent izinli sunucu adlarına bu alan adını ekleyin.")
    if probe:
        conn = http.client.HTTPConnection("127.0.0.1", int(env["TORRENT_UI_PORT"]), timeout=3)
        try:
            conn.request("GET", "/api/v2/app/version", headers={"Host": name, "X-Forwarded-Host": name})
            response = conn.getresponse()
            body = response.read(4096)
            require(response.status == 403 and b"banned" not in body.lower(),
                    "qBittorrent giriş kapısı doğrulanamadı; internet yayını açılmadı.")
        finally:
            conn.close()


def torrent_active(env, rows=None):
    rows = config(env) if rows is None else rows
    row = rows["torrent"]
    if not row["enabled"] or module_states(env).get("torrent") != "calisiyor":
        return False
    try:
        from master_shares import assigned
        ip = ipaddress.IPv4Address(env["WAN_IPV4"])
        if not ip.is_global or ip.is_multicast or not assigned(str(ip)):
            return False
        torrent_security(env, row["domain"])
        return True
    except (SettingsError, OSError, ValueError, KeyError):
        return False


def validate(env, saved, request):
    require(isinstance(request, dict) and set(request) == {"service", "tail", "enabled", "domain"},
            "Caddy yayın alanları geçersiz.")
    service = request["service"]
    require(service != "panel", "Panel yalnız Tailscale üzerinden kullanılabilir; bu yayın düzenlenemez.")
    require(isinstance(service, str) and service in IDS, "Bilinmeyen Caddy yayını.")
    require(type(request["tail"]) is bool and type(request["enabled"]) is bool,
            "Ağ seçimleri açık veya kapalı olmalı.")
    item = {k: request[k] for k in ("tail", "enabled", "domain")}
    item["domain"] = tls.domain(item["domain"])
    saved.setdefault("web", {})[service] = item
    # The old WebDAV-only endpoint remains a compatible writer; one row owns
    # the effective setting after migration, including its remembered off name.
    if service == "paylasim":
        saved.pop("https", None)
    rows = config(env, saved)
    require(service in module_states(env), "Önce uygulamayı kurun.")
    if item["enabled"]:
        require(module_states(env).get(service) == "calisiyor", "Önce uygulamayı başlatın.")
        if service == "torrent":
            try:
                torrent_security(env, rows[service]["domain"], probe=True)
            except (OSError, http.client.HTTPException) as err:
                raise SettingsError("qBittorrent giriş kapısı yanıt vermiyor.") from err
        tls.check_dns(env, item["domain"])
    return saved


def site_addresses(source):
    """Address line of a module's single site block (DD-193: the template is the source)."""
    for line in source.splitlines():
        if line.startswith(("http://", "https://")) and line.rstrip().endswith("{"):
            return line.rstrip()[:-1].strip()
    raise SettingsError("Uygulamanın Caddy site adresi okunamadı.")


def private_site(env, service, source):
    if config(env)[service]["tail"]:
        return source
    # A disabled route refuses requests on exactly the template's addresses,
    # including WebDAV by Tailscale IP:port for clients without DNS.
    return ("# Caddy Tailscale publication disabled; application remains running.\n%s {\n\trespond 403\n}\n"
            % site_addresses(source))


def extra_sites(env):
    rows, states = config(env), module_states(env)
    result = {}
    for service in IDS:
        # Unconfigured installations retain the original module projection.
        if service not in tls.settings(env).get("web", {}):
            continue
        if service not in states:
            result[service + ".caddy"] = ""
            continue
        source = Path(env["MODULES_DIR"]) / service / (service + ".caddy")
        result[service + ".caddy"] = private_site(env, service, read_regular(source)[0].decode())
    text = ""
    if torrent_active(env, rows):
        authority = rows["torrent"]["domain"] + (":" + env["SHARE_HTTPS_PORT"] if int(env["SHARE_HTTPS_PORT"]) != 443 else "")
        # Native Host validation compares an explicit port with its loopback
        # listener. CSRF instead needs the external authority (including port).
        text = ("# Managed public qBittorrent only; native authentication remains mandatory.\n"
                "https://%s:%s {\n\tbind %s\n%s"
                "\treverse_proxy 127.0.0.1:%s {\n"
                "\t\theader_up Host %s\n"
                "\t\theader_up X-Forwarded-Host %s\n"
                "\t\theader_up X-Forwarded-For {http.request.remote.host}\n"
                "\t}\n}\n" % (rows["torrent"]["domain"], env["SHARE_HTTPS_PORT"], env["WAN_IPV4"],
                                    tls.tls_block(), env["TORRENT_UI_PORT"], rows["torrent"]["domain"], authority))
    result["torrent-wan.caddy"] = text
    return result


def status(env):
    rows, states = config(env), module_states(env)
    out = [{"service": "panel", "name": "Panel", "local": "panel." + env["LOCAL_DOMAIN"],
            "tail": True, "enabled": False, "domain": "", "installed": True,
            "status": "locked", "message": "Yönetici girişi geliştirilene kadar yalnız Tailscale."}]
    for service, name, local in (("torrent", "qBittorrent", "torrent"), ("paylasim", "WebDAV", "paylas")):
        row = dict(rows[service], service=service, name=name, local=local + "." + env["LOCAL_DOMAIN"],
                   installed=service in states, running=states.get(service) == "calisiyor", expires=None,
                   status="disabled", message="İnternet yayını kapalı.")
        if service == "paylasim":
            info = tls.status(env)
            row.update({k: info[k] for k in ("status", "message", "expires", "mode")})
        elif row["enabled"]:
            row.update(status="error", message="qBittorrent yayını veya sertifikası doğrulanamadı.")
            if not row["running"]:
                # Name the actual cause; a stopped app is not a certificate problem.
                row["message"] = ("qBittorrent kurulu değil; internet yayını kapalı." if not row["installed"] else
                                  "qBittorrent durdurulmuş; başlatıldığında internet yayını yeniden açılır.")
            elif torrent_active(env, rows):
                try:
                    row.update(expires=tls.certificate(env, row["domain"]), status="ready", message="Sertifika doğrulandı.")
                except (OSError, ValueError, KeyError, SettingsError):
                    pass
            else:
                try:
                    torrent_security(env, row["domain"])
                except SettingsError as err:
                    row["message"] = str(err)
                except (OSError, ValueError, KeyError):
                    pass
        out.append(row)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="/etc/master-stack/state.env")
    parser.add_argument("action", choices=("filter-caddy", "tail-enabled"))
    parser.add_argument("service", choices=IDS)
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    from master_settings import env_read
    try:
        env = env_read(args.state)
        if args.action == "tail-enabled":
            sys.exit(0 if config(env)[args.service]["tail"] else 1)
        require(bool(args.path), "Caddy geçici dosyası gerekli.")
        atomic(args.path, private_site(env, args.service, read_regular(args.path)[0].decode()), 0o644)
    except (SettingsError, OSError, ValueError, KeyError) as err:
        print(str(err) if isinstance(err, SettingsError) else "Caddy yayın ayarı okunamadı.", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
