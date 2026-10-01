#!/usr/bin/env python3
"""Fixed Caddy publication catalogue. No arbitrary upstreams or tunnels.

Settings owns transactions; the existing share publisher applies the small
projection under its locks. qBittorrent preferences are inspected, never rewritten.
DD-195: Konsol may also be published over HTTPS; its tailnet address always stays,
and the public site imports the same signed-in routes as the tailnet site.
"""
import argparse
import fnmatch
import http.client
import ipaddress
from pathlib import Path
import sys

import master_https as tls
from master_settings import SettingsError, atomic, ini_values, read_regular, require

# Module rows own a private site file; the panel row only adds the optional public one.
MODULE_IDS = ("torrent", "paylasim")
IDS = MODULE_IDS + ("panel",)


def config(env, value=None):
    value = tls.settings(env) if value is None else value
    web = value.get("web", {})
    require(isinstance(web, dict) and set(web) <= set(IDS), "Caddy yayın kaydı geçersiz.")
    dav = tls.config(env, value)
    rows = {"torrent": {"tail": True, "enabled": False, "domain": ""},
            "paylasim": {"tail": True, "enabled": dav["mode"] != "off", "domain": dav["domain"]},
            "panel": {"tail": True, "enabled": False, "domain": ""}}
    for key, item in web.items():
        require(isinstance(item, dict) and set(item) == {"tail", "enabled", "domain"}
                and type(item["tail"]) is bool and type(item["enabled"]) is bool,
                "Caddy ağ seçimi geçersiz.")
        name = tls.domain(item["domain"])
        require(not item["enabled"] or bool(name), "İnternet yayını için HTTPS alan adı gerekli.")
        # The tailnet address is the management path that always remains.
        require(key != "panel" or item["tail"], "Panel'in Tailscale erişimi kapatılamaz.")
        rows[key] = dict(item, domain=name)
    names = [r["domain"] for r in rows.values() if r["enabled"] and r["domain"]]
    require(len(names) == len(set(names)), "İki uygulama aynı HTTPS alan adını kullanamaz.")
    return rows


def https_apps_enabled(env, rows=None):
    """A saved qBittorrent or Panel internet row: Caddy's one WAN port is then TCP 443 (v2-169)."""
    rows = config(env) if rows is None else rows
    return rows["torrent"]["enabled"] or rows["panel"]["enabled"]


def legacy_http_active(env):
    """Folders shared over the internet with plaintext HTTP right now (no HTTPS name saved)."""
    from master_shares import Manager, ShareError
    if tls.config(env)["mode"] != "http":
        return False
    try:
        return Manager.from_env(env).wan_active()
    except (ShareError, OSError, ValueError, KeyError):
        return False


LEGACY_HTTP_BUSY = ("WebDAV internet paylaşımı şu an eski HTTP ile açık. Önce WebDAV için HTTPS alan adı "
                    "kaydedin ya da o klasörlerin internet bağlantısını kapatın.")


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


def konsol_account(env):
    """True only when the operator's Konsol account exists (DD-194)."""
    import master_auth
    try:
        return master_auth.Store(env["KONSOL_AUTH_DIR"]).account() is not None
    except (master_auth.AuthError, OSError, KeyError):
        return False


def wan_ready(env):
    from master_shares import assigned
    ip = ipaddress.IPv4Address(env["WAN_IPV4"])
    return ip.is_global and not ip.is_multicast and assigned(str(ip))


def panel_active(env, rows=None):
    """Public Konsol only with a saved name, an assigned WAN IPv4 and an existing account."""
    try:
        rows = config(env) if rows is None else rows
        return rows["panel"]["enabled"] and wan_ready(env) and konsol_account(env)
    except (SettingsError, OSError, ValueError, KeyError):
        return False


def validate(env, saved, request):
    fields = {"service", "tail", "enabled", "domain"}
    require(isinstance(request, dict) and fields <= set(request) <= fields | {"confirm"},
            "Caddy yayın alanları geçersiz.")
    service = request["service"]
    require(isinstance(service, str) and service in IDS, "Bilinmeyen Caddy yayını.")
    require("confirm" not in request or service == "panel", "Caddy yayın alanları geçersiz.")
    before = config(env, saved)[service]
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
    if service == "panel":
        if item["enabled"]:
            # Publishing the console is the operator's typed decision, checked here too.
            if not before["enabled"] or before["domain"] != item["domain"]:
                require(request.get("confirm") == "onayla", "Panel'i internete açmak için onayla yazın.")
            # The first account is created only over Tailscale with the one-time code.
            require(konsol_account(env), "Önce Konsol hesabını Tailscale üzerinden oluşturun.")
            require(not legacy_http_active(env), LEGACY_HTTP_BUSY)
            tls.check_dns(env, item["domain"])
        return saved
    require(service in module_states(env), "Önce uygulamayı kurun.")
    if item["enabled"]:
        require(module_states(env).get(service) == "calisiyor", "Önce uygulamayı başlatın.")
        if service == "torrent":
            # Not WebDAV's mode: only folders actually shared over plaintext HTTP block the port.
            require(not legacy_http_active(env), LEGACY_HTTP_BUSY)
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
    for service in MODULE_IDS:
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
    result["panel-wan.caddy"] = panel_site(env, rows) if panel_active(env, rows) else ""
    return result


def panel_site(env, rows):
    # The snippet keeps backend Host checks and writes the channel the backend
    # trusts; no other route, upstream or module is reachable through this name.
    return ("# Managed public Konsol (DD-195): same sign-in and routes as the tailnet site.\n"
            "https://%s:%s {\n\tbind %s\n%s"
            "\theader Strict-Transport-Security \"max-age=31536000\"\n"
            "\timport konsol internet\n}\n"
            % (rows["panel"]["domain"], env["SHARE_HTTPS_PORT"], env["WAN_IPV4"], tls.tls_block()))


def status(env):
    rows, states = config(env), module_states(env)
    out = [panel_status(env, rows)]
    for service, name, local in (("torrent", "qBittorrent", "torrent"), ("paylasim", "WebDAV", "paylas")):
        row = dict(rows[service], service=service, name=name, local=local + "." + env["LOCAL_DOMAIN"],
                   installed=service in states, running=states.get(service) == "calisiyor", expires=None,
                   status="disabled", message="İnternet yayını kapalı.")
        if service == "paylasim":
            info = tls.status(env)
            row.update({k: info[k] for k in ("status", "message", "expires", "mode")})
            row["wan_active"] = legacy_http_active(env) if info["mode"] == "http" else None
            if info["mode"] == "http" and https_apps_enabled(env, rows):
                row["message"] = ("HTTPS alan adı tanımlanmadı. qBittorrent veya Panel internet yayını açıkken "
                                  "WebDAV internet erişimi için HTTPS alan adı gerekir.")
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


def panel_status(env, rows):
    row = dict(rows["panel"], service="panel", name="Panel", local="panel." + env["LOCAL_DOMAIN"],
               installed=True, running=True, expires=None, account=konsol_account(env),
               status="disabled", message="İnternet yayını kapalı. Tailscale adresi her zaman açık kalır.")
    if not row["enabled"]:
        return row
    row.update(status="error", message="Panel yayını veya sertifikası doğrulanamadı.")
    if not row["account"]:
        row["message"] = "Konsol hesabı yok; internet yayını kapalı. İlk hesap yalnız Tailscale üzerinden oluşturulur."
    elif panel_active(env, rows):
        try:
            row.update(expires=tls.certificate(env, row["domain"]), status="ready", message="Sertifika doğrulandı.")
        except (OSError, ValueError, KeyError, SettingsError):
            pass
    else:
        row["message"] = "Sunucunun internet IPv4 adresi kullanılamıyor; internet yayını kapalı."
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="/etc/master-stack/state.env")
    parser.add_argument("action", choices=("filter-caddy", "tail-enabled"))
    parser.add_argument("service", choices=MODULE_IDS)
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
