#!/usr/bin/env python3
"""The access projection (DD-191, DD-195; rebuild phase 4): the fixed Caddy rows and the applications' rows.

Settings owns transactions; the share publisher (master_shares.Manager.publish) applies the projection under
its locks. Two fixed rows live in SETTINGS_FILE's "web": WebDAV ("paylasim") and Konsol ("panel"). The
applications' access rows live in their records (master_applications, erisim.json) and are read through one
function, master_applications.access_rows. Their files:

  CADDY_MODULES_DIR/uygulama-<app>.caddy      every address row's Tailscale name (http://<ad>.<domain>) and its
                                              Tailscale port (K5, http://{$TAILSCALE_IPV4}:<port>), both to the
                                              row's 127.0.0.1 pool port
  CADDY_MODULES_DIR/uygulama-<app>-wan.caddy  every internet name: bind WAN_IPV4, TLS-ALPN, X-Forwarded-For; the
                                              application's own login is the guard (the layout of DD-252's sites)
  DNSMASQ_CONF_DIR/modul-uygulama.conf        one interface-name line per address row (master_applications.DNS_FILE)

Stale uygulama-* files are removed. A raw port is the container guard's (master_container_network), never
Caddy's. An application record that cannot be read stops the projection: the publisher keeps what it applied
last. The settings transaction's "erisim" section (one row of one application) is checked and worded here
(section, plan_items, plan_notes, opening), as master_wireguard does for its section.
"""
import argparse
import ipaddress
import os
import sys

import master_https as tls
import master_settings as settings
from master_settings import SettingsError, atomic, read_regular, require

BUILTIN_ID = "paylasim"
PANEL_ID = "panel"
# The applications' Caddy files: uygulama-<app>.caddy and uygulama-<app>-wan.caddy.
APP_FILE_PREFIX = "uygulama-"
WAN_SUFFIX = "-wan"
SCOPE_TEXT = {"kapali": "kapalı", "tailscale": "Tailscale", "internet": "İnternet"}
# A2: what opening a raw port to the internet means; the request carries internet_onayi: true.
CONSENT_TEXT = ("Ham port internete doğrudan açılır: arada Caddy, HTTPS ve Konsol girişi olmaz; şifreleme ve giriş "
                "uygulamanın kendisindedir.")
CONSENT_MISSING = "Ham portu internete açmak için bu uyarıyı onaylayın (internet onayı)."
RULE_HELD = "Bu port bir uygulamanın erişim satırına ait; Erişim → Adresler'den değişir."
WILDCARDS = ("0.0.0.0", "*", "::", "[::]")


def ids():
    return (BUILTIN_ID, PANEL_ID)


def config(env, value=None):
    """The fixed rows {paylasim, panel: {tail, enabled, domain}}; any other key of "web" fails closed."""
    value = tls.settings(env) if value is None else value
    web = value.get("web", {})
    require(isinstance(web, dict), "Caddy yayın kaydı geçersiz.")
    dav = tls.config(env, value)
    rows = {BUILTIN_ID: {"tail": True, "enabled": dav["mode"] != "off", "domain": dav["domain"]},
            PANEL_ID: {"tail": True, "enabled": False, "domain": ""}}
    for key, item in web.items():
        require(key in rows, "Caddy yayın kaydında bilinmeyen satır: %s." % key)
        require(isinstance(item, dict) and set(item) == {"tail", "enabled", "domain"}
                and type(item["tail"]) is bool and type(item["enabled"]) is bool,
                "Caddy ağ seçimi geçersiz.")
        name = tls.domain(item["domain"])
        require(not item["enabled"] or bool(name), "İnternet yayını için HTTPS alan adı gerekli.")
        # The tailnet address is the management path that always remains.
        require(key != PANEL_ID or item["tail"], "Panel'in Tailscale erişimi kapatılamaz.")
        rows[key] = dict(item, domain=name)
    names = [r["domain"] for r in rows.values() if r["enabled"] and r["domain"]]
    require(len(names) == len(set(names)), "İki satır aynı HTTPS alan adını kullanamaz.")
    return rows


def app_rows(env):
    """Every application's access rows (master_applications.access_rows); [] on a base without an application store.
    A record that cannot be read, or two rows that clash, raise SettingsError (fail closed)."""
    if not env.get("UYGULAMA_STATE_DIR"):
        return []
    import master_applications as apps
    try:
        return apps.access_rows(env)
    except apps.AppError as err:
        raise SettingsError(str(err)) from err


def internet_names(rows):
    """{internet name: row id} of the address rows."""
    return {r["satir"]["internet"]: r["id"] for r in rows if r["satir"]["tur"] == "adres" and r["satir"]["internet"]}


def https_apps_enabled(env, rows=None):
    """A saved Konsol internet row or an application internet name: Caddy's one WAN port is then TCP 443. An
    application record that cannot be read raises (the caller fails closed)."""
    rows = config(env) if rows is None else rows
    return rows[PANEL_ID]["enabled"] or bool(internet_names(app_rows(env)))


def plain_http_active(env):
    """Folders shared over the internet with plaintext HTTP right now (no HTTPS name saved)."""
    from master_shares import Manager, ShareError
    if tls.config(env)["mode"] != "http":
        return False
    try:
        return Manager.from_env(env).wan_active()
    except (ShareError, OSError, ValueError, KeyError):
        return False


PLAIN_HTTP_BUSY = ("WebDAV internet paylaşımı şu an şifresiz HTTP ile açık. Önce WebDAV için HTTPS alan adı "
                    "kaydedin ya da o klasörlerin internet bağlantısını kapatın.")


def wan_ready(env):
    from master_shares import assigned
    ip = ipaddress.IPv4Address(env["WAN_IPV4"])
    return ip.is_global and not ip.is_multicast and assigned(str(ip))


def wan_ok(env):
    try:
        return wan_ready(env)
    except (OSError, ValueError, KeyError):
        return False


def konsol_account(env):
    """True only when the operator's Konsol account exists (DD-194)."""
    import master_auth
    try:
        return master_auth.Store(env["KONSOL_AUTH_DIR"]).account() is not None
    except (master_auth.AuthError, OSError, KeyError):
        return False


def panel_active(env, rows=None):
    """Public Konsol only with a saved name, an assigned WAN IPv4 and an existing account."""
    try:
        rows = config(env) if rows is None else rows
        return rows[PANEL_ID]["enabled"] and wan_ready(env) and konsol_account(env)
    except (SettingsError, OSError, ValueError, KeyError):
        return False


def app_active(env, item):
    """An application row's internet site exists: an address row with an internet name and an assigned WAN IPv4.
    The application behind it keeps its own login; nothing is probed."""
    return item["satir"]["tur"] == "adres" and bool(item["satir"]["internet"]) and wan_ok(env)


def https_apps_active(env, rows=None):
    """Names of the HTTPS publications active right now (Konsol, then the applications with an internet name);
    [] when none or when the fixed rows cannot be read. An application record that cannot be read raises."""
    try:
        rows = config(env) if rows is None else rows
    except (SettingsError, OSError, ValueError, KeyError):
        return []
    names = ["Konsol"] if panel_active(env, rows) else []
    for item in app_rows(env):
        if app_active(env, item) and item["uygulama"] not in names:
            names.append(item["uygulama"])
    return names


def validate(env, saved, request):
    """A fixed row's request (web): {service, tail, enabled, domain, confirm?}."""
    fields = {"service", "tail", "enabled", "domain"}
    require(isinstance(request, dict) and fields <= set(request) <= fields | {"confirm"},
            "Caddy yayın alanları geçersiz.")
    service = request["service"]
    require(isinstance(service, str) and service in ids(), "Bilinmeyen Caddy yayını.")
    require("confirm" not in request or service == PANEL_ID, "Caddy yayın alanları geçersiz.")
    before = config(env, saved)[service]
    require(type(request["tail"]) is bool and type(request["enabled"]) is bool,
            "Ağ seçimleri açık veya kapalı olmalı.")
    item = {k: request[k] for k in ("tail", "enabled", "domain")}
    item["domain"] = tls.domain(item["domain"])
    saved.setdefault("web", {})[service] = item
    config(env, saved)  # one HTTPS name per enabled row, a name for an enabled row
    if item["enabled"]:
        taken = internet_names(app_rows(env))
        require(item["domain"] not in taken, "%s internet adı bir uygulamanın erişim satırında (%s) kullanılıyor."
                % (item["domain"], taken.get(item["domain"], "")))
    if service == PANEL_ID:
        if item["enabled"]:
            # Publishing the console is the operator's typed decision, checked here too.
            if not before["enabled"] or before["domain"] != item["domain"]:
                require(request.get("confirm") == "onayla", "Panel'i internete açmak için onayla yazın.")
            # The account is created only over Tailscale (DD-205).
            require(konsol_account(env), "Önce Tailscale adresinden Sistem → Hesap bölümünde internet hesabını oluşturun.")
            require(not plain_http_active(env), PLAIN_HTTP_BUSY)
            tls.check_dns(env, item["domain"])
        return saved
    if item["enabled"]:
        tls.check_dns(env, item["domain"])
    return saved


def web_opening(before, after):
    """Decision 1 for a fixed row: True when it opens or widens access (the Tailscale name switched on, the
    internet name switched on or renamed)."""
    return ((after["tail"] and not before["tail"]) or (after["enabled"] and not before["enabled"])
            or (after["enabled"] and before["enabled"] and after["domain"] != before["domain"]))


# -- rendering
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


def panel_site(env, rows):
    # The snippet keeps backend Host checks and writes the channel the backend
    # trusts; no other route, upstream or module is reachable through this name.
    return ("# Managed public Konsol (DD-195): same sign-in and routes as the tailnet site.\n"
            "https://%s:%s {\n\tbind %s\n%s"
            "\theader Strict-Transport-Security \"max-age=31536000\"\n"
            "\timport konsol internet\n}\n"
            % (rows[PANEL_ID]["domain"], env["SHARE_HTTPS_PORT"], env["WAN_IPV4"], tls.tls_block()))


def app_files(app):
    """An application's two Caddy files: (tailnet, internet)."""
    return APP_FILE_PREFIX + app + ".caddy", APP_FILE_PREFIX + app + WAN_SUFFIX + ".caddy"


def app_private_site(env, app, items):
    """uygulama-<app>.caddy: each address row's Tailscale name and Tailscale port (default_bind is the Tailscale
    IPv4); "" without an address row."""
    blocks = []
    for item in items:
        row = item["satir"]
        if row["tur"] != "adres":
            continue
        addresses = ["http://%s.%s" % (row["ad"], env["LOCAL_DOMAIN"])]
        if row["tailscale_portu"] is not None:
            addresses.append("http://{$TAILSCALE_IPV4}:%d" % row["tailscale_portu"])
        blocks.append("# %s\n%s {\n\treverse_proxy 127.0.0.1:%d\n}\n" % (item["id"], ", ".join(addresses), item["yerel_port"]))
    if not blocks:
        return ""
    return "# Uygulama %s (rebuild phase 4): Tailscale; upstream on this server's loopback.\n%s" % (app, "".join(blocks))


def app_public_site(env, app, items):
    """uygulama-<app>-wan.caddy: each internet name, TLS-ALPN, its loopback upstream; "" without one or without an
    assigned WAN IPv4. The application's own login is the guard; the client address is Caddy's."""
    blocks = ["https://%s:%s {\n\tbind %s\n%s"
              "\treverse_proxy 127.0.0.1:%d {\n"
              "\t\theader_up X-Forwarded-For {http.request.remote.host}\n"
              "\t}\n}\n" % (item["satir"]["internet"], env["SHARE_HTTPS_PORT"], env["WAN_IPV4"], tls.tls_block(), item["yerel_port"])
              for item in items if app_active(env, item)]
    if not blocks:
        return ""
    return "# Uygulama %s (rebuild phase 4): internet; the application's own login remains the guard.\n%s" % (app, "".join(blocks))


def extra_sites(env):
    """{file: text} for CADDY_MODULES_DIR ("" removes the file)."""
    rows = config(env)
    saved = tls.settings(env).get("web", {})
    result = {}
    # WebDAV's tailnet site comes from the installer's rendering (SHARE_CADDY_SOURCE); until a row
    # is saved the installer's own placement stays as it is.
    if BUILTIN_ID in saved:
        source = read_regular(env["SHARE_CADDY_SOURCE"])[0].decode()
        result[BUILTIN_ID + ".caddy"] = private_site(env, BUILTIN_ID, source)
    result["panel-wan.caddy"] = panel_site(env, rows) if panel_active(env, rows) else ""
    by_app = {}
    for item in app_rows(env):
        by_app.setdefault(item["uygulama"], []).append(item)
    for app, items in sorted(by_app.items()):
        private, public = app_files(app)
        result[private] = app_private_site(env, app, items)
        result[public] = app_public_site(env, app, items)
    # The files of a removed application (or of one with no address left) go, never kept by accident.
    try:
        for name in os.listdir(env["CADDY_MODULES_DIR"]):
            if name.startswith(APP_FILE_PREFIX) and name.endswith(".caddy"):
                result.setdefault(name, "")
    except (OSError, KeyError):
        pass
    return result


def dns_text(env):
    """modul-uygulama.conf: one interface-name line per address row; "" when there is none (the file is removed).
    These names are not switchable in Yerel adlar: their row is their home."""
    lines = ["interface-name=%s.%s,%s/4" % (item["satir"]["ad"], env["LOCAL_DOMAIN"], env["TAILSCALE_IF"])
             for item in app_rows(env) if item["satir"]["tur"] == "adres"]
    if not lines:
        return ""
    return "# Uygulamaların Tailscale adları; kaynak Erişim → Adresler (erişim satırları).\n" + "\n".join(lines) + "\n"


def dns_path(env):
    import master_applications as apps
    return os.path.join(env["DNSMASQ_CONF_DIR"], apps.DNS_FILE)


# -- status
def status(env):
    rows = config(env)
    out = [panel_status(env, rows)]
    try:
        out += [app_status(env, item) for item in app_rows(env) if item["satir"]["tur"] == "adres"]
    except SettingsError:
        pass  # Erişim reads the rows itself and names the record that cannot be read
    row = dict(rows[BUILTIN_ID], service=BUILTIN_ID, name="WebDAV", local="paylas." + env["LOCAL_DOMAIN"],
               installed=True, running=True, expires=None, status="disabled", message="İnternet yayını kapalı.")
    info = tls.status(env)
    row.update({k: info[k] for k in ("status", "message", "expires")})
    if info["mode"] == "http":
        try:
            busy = https_apps_enabled(env, rows)
        except SettingsError:
            busy = True
        if busy:
            row["message"] = ("HTTPS alan adı tanımlanmadı. Konsol'un ya da bir uygulamanın internet adı açıkken "
                              "WebDAV internet erişimi için HTTPS alan adı gerekir.")
    out.append(row)
    return out


def app_status(env, item):
    """An address row's publication: its Tailscale name and its internet name's certificate."""
    row = item["satir"]
    out = {"service": item["id"], "tail": True, "enabled": bool(row["internet"]), "domain": row["internet"],
           "name": "%s · %s" % (item["uygulama"], item["servis"]), "local": "%s.%s" % (row["ad"], env["LOCAL_DOMAIN"]),
           "uygulama": item["uygulama"], "installed": True, "running": True, "expires": None,
           "status": "disabled", "message": "İnternet adı kapalı."}
    if not row["internet"]:
        return out
    out.update(status="error", message="%s yayını veya sertifikası doğrulanamadı." % row["internet"])
    if app_active(env, item):
        try:
            out.update(expires=tls.certificate(env, row["internet"]), status="ready", message="Sertifika doğrulandı.")
        except (OSError, ValueError, KeyError, SettingsError):
            pass
    else:
        out["message"] = "Sunucunun internet IPv4 adresi kullanılamıyor; internet adı kapalı."
    return out


def panel_status(env, rows):
    row = dict(rows[PANEL_ID], service=PANEL_ID, name="Panel", local="panel." + env["LOCAL_DOMAIN"],
               installed=True, running=True, expires=None, account=konsol_account(env),
               status="disabled", message="İnternet yayını kapalı. Tailscale adresi her zaman açık kalır.")
    if not row["enabled"]:
        return row
    row.update(status="error", message="Panel yayını veya sertifikası doğrulanamadı.")
    if not row["account"]:
        row["message"] = "Konsol hesabı yok; internet yayını kapalı. Hesabı Tailscale adresinden Sistem → Hesap bölümünde oluşturun."
    elif panel_active(env, rows):
        try:
            row.update(expires=tls.certificate(env, row["domain"]), status="ready", message="Sertifika doğrulandı.")
        except (OSError, ValueError, KeyError, SettingsError):
            pass
    else:
        row["message"] = "Sunucunun internet IPv4 adresi kullanılamıyor; internet yayını kapalı."
    return row


# -- the settings transaction's "erisim" section (one access row of one application)
def held_ports(rows):
    """{(scope, protocol, port): row id} of what the rows hold on the host: an open raw port on its scope's
    address ("tailscale" or "internet") and an address row's Tailscale port (K5, TCP)."""
    out = {}
    for item in rows:
        row = item["satir"]
        if row["tur"] == "ham" and row["kapsam"] != "kapali":
            out[(row["kapsam"], item["protokol"], row["port"])] = item["id"]
        elif row["tur"] == "adres" and row["tailscale_portu"] is not None:
            out[("tailscale", "tcp", row["tailscale_portu"])] = item["id"]
    return out


def rule_ports(rows):
    """{(firewall scope "tail" | "wan", protocol, port): row id}: the ports an operator rule may not name."""
    return {("tail" if scope == "tailscale" else "wan", proto, port): rid for (scope, proto, port), rid in held_ports(rows).items()}


def claims(key, row):
    """The host ports one row holds: {(scope, protocol, port)}."""
    item = {"satir": row, "protokol": key.rpartition("/")[2], "id": ""}
    return set(held_ports([item]))


def listeners():
    """Every listening socket as (protocol, address, port), from ss (fail closed: an unreadable list refuses)."""
    p = settings.run(["ss", "-H", "-lntu"], check=False, timeout=10)
    require(p.returncode == 0, "Dinleyen portlar okunamadı; port denetlenemedi.")
    out = []
    for line in p.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5 or fields[0] not in ("tcp", "udp"):
            continue
        address, _, port = fields[4].rpartition(":")
        if port.isdigit():
            out.append((fields[0], address.partition("%")[0].strip("[]") or "*", int(port)))
    return out


def port_problem(env, saved, scope, proto, port, listening):
    """Why a raw or Tailscale port may not be taken on the host, in Turkish, or None: a *_PORT of state.env, a
    WireGuard network's port, the pool range, an operator firewall rule on the same scope, protocol and port, or a
    live listener on that address (for an internet port also every WAN port the firewall opens: the base's keys,
    WireGuard and the operator's allow rules). Clashes between rows are row_conflict's."""
    import master_applications as apps
    import master_wireguard
    text = "%s %s %d" % (SCOPE_TEXT[scope], proto.upper(), port)
    if port in apps.base_ports(env):
        return "%s Obhut'un kendi portu; başka bir port seçin." % text
    try:
        first, last = apps.pool_range(env)
    except apps.AppError as err:
        return str(err)
    if first <= port <= last:
        return "%s uygulamaların yerel port aralığında (%d–%d); başka bir port seçin." % (text, first, last)
    if env.get("WG_NETWORKS_FILE"):
        try:
            nets = master_wireguard.records(env)
        except (OSError, ValueError):
            return "WireGuard ağ kaydı okunamadı; port denetlenemedi."
        hit = next((n["iface"] for n in nets if n["port"] == port), None)
        if hit:
            return "%s bir WireGuard ağının (%s) portu; başka bir port seçin." % (text, hit)
    wanted = "tail" if scope == "tailscale" else "wan"
    for rule in saved.get("firewall") or []:
        if isinstance(rule, dict) and rule.get("scope") == wanted and rule.get("proto") == proto and rule.get("port") == port:
            return "%s için bir güvenlik duvarı kuralı var (%s); önce Erişim → Güvenlik duvarı'ndan kaldırın." % (
                text, rule.get("name", ""))
    try:
        address = apps.scope_address(env, scope)
    except apps.AppError as err:
        return str(err)
    for lproto, laddress, lport in listening():
        if lproto == proto and lport == port and laddress in (address,) + WILDCARDS:
            return "%s: bu adreste dinleyen bir servis var; başka bir port seçin." % text
    return None


def section(env, saved, item, listening=None):
    """The settings transaction's "erisim" section checked against every row, state.env, WireGuard, the operator's
    firewall rules, the live listeners and DNS. item: {"uygulama", "anahtar", "satir", "internet_onayi"?}; saved:
    SETTINGS_FILE. Returns the change the plan words and apply runs:

        {"id", "uygulama", "anahtar", "servis", "port", "protokol", "yerel_port", "once": the stored row,
         "sonra": the new row, "durduruldu": the application is stopped, "internet_onayi": the consent was given,
         "internet_acilir": a raw port opens to the internet (A2)}

    Raises SettingsError with the reason (a validation error is the same in plan and apply)."""
    import master_applications as apps
    fields = {"uygulama", "anahtar", "satir"}
    require(isinstance(item, dict) and fields <= set(item) <= fields | {"internet_onayi"}, "Erişim isteğinin alanları geçersiz.")
    consent = item.get("internet_onayi", False)
    require(type(consent) is bool, "İnternet onayı açık ya da kapalı olmalı.")
    app, key, row = item["uygulama"], item["anahtar"], item["satir"]
    require(isinstance(app, str) and apps.APP_NAME_RE.fullmatch(app) is not None, "Uygulama adı geçersiz.")
    rows = app_rows(env)
    current = next((r for r in rows if r["uygulama"] == app and r["anahtar"] == key), None)
    if current is None:
        try:
            known = apps.Records(env).exists(app)
        except apps.AppError as err:
            raise SettingsError(str(err)) from err
        raise SettingsError("Uygulamanın böyle bir portu yok." if known else "Uygulama bulunamadı.")
    problem = apps.row_problem(key, row)
    require(problem is None, problem or "")
    old, rid = current["satir"], current["id"]
    require(row != old, "Değişiklik yok.")
    if row["tur"] == "adres" and (old["tur"] != "adres" or old["ad"] != row["ad"]):
        try:
            taken = apps.taken_names(env, skip_rows=(rid,))
        except apps.AppError as err:
            raise SettingsError(str(err)) from err
        name = "%s.%s" % (row["ad"], env["LOCAL_DOMAIN"])
        require(name not in taken, "%s adı zaten kullanılıyor." % name)
    clash = apps.row_conflict([(r["id"], r["anahtar"], r["satir"]) for r in rows if r["id"] != rid] + [(rid, key, row)])
    require(clash is None, clash or "")
    name = row["internet"] if row["tur"] == "adres" else ""
    if name and name != (old["internet"] if old["tur"] == "adres" else ""):
        fixed = config(env, saved)
        require(not any(r["enabled"] and r["domain"] == name for r in fixed.values()),
                "%s internet adı Konsol'da ya da WebDAV'da kullanılıyor." % name)
        require(not plain_http_active(env), PLAIN_HTTP_BUSY)
        tls.check_dns(env, name)
    listening = listening or listeners
    for scope, proto, port in sorted(claims(key, row) - claims(key, old)):
        problem = port_problem(env, saved, scope, proto, port, listening)
        require(problem is None, problem or "")
    opens = row["tur"] == "ham" and row["kapsam"] == "internet" and not (
        old["tur"] == "ham" and old["kapsam"] == "internet" and old["port"] == row["port"])
    try:
        stopped = apps.Records(env).places(app)["stopped"]
    except apps.AppError as err:
        raise SettingsError(str(err)) from err
    return {"id": rid, "uygulama": app, "anahtar": key, "servis": current["servis"], "port": current["port"],
            "protokol": current["protokol"], "yerel_port": current["yerel_port"], "once": old, "sonra": row,
            "durduruldu": stopped, "internet_onayi": consent, "internet_acilir": opens}


def opening(change):
    """Decision 1: True when the change opens or widens access (a Tailscale name, a rename, a Tailscale port, an
    internet name, a raw port opened or moved to another port or to the internet, "Adres aç"); False when it only
    closes or narrows (a Tailscale port or an internet name removed, a raw port closed, internet → Tailscale on the
    same port, "Adresi kaldır" to a closed raw port)."""
    old, new = change["once"], change["sonra"]
    if new["tur"] == "adres":
        if old["tur"] != "adres" or old["ad"] != new["ad"]:
            return True
        if new["tailscale_portu"] is not None and new["tailscale_portu"] != old["tailscale_portu"]:
            return True
        return bool(new["internet"]) and new["internet"] != old["internet"]
    if new["kapsam"] == "kapali":
        return False
    if old["tur"] != "ham" or old["kapsam"] == "kapali" or old["port"] != new["port"]:
        return True
    return new["kapsam"] == "internet" and old["kapsam"] != "internet"


def publications(key, row):
    """What a row puts into its service's unit: an address its pool publication, an open raw row its raw one."""
    if row["tur"] == "adres":
        return ("adres",)
    return ("ham", row["kapsam"], row["port"]) if row["kapsam"] != "kapali" else ()


def restarts(change):
    """The row change rewrites the service's unit and restarts it (an address added or removed, a raw port opened,
    closed or moved)."""
    return publications(change["anahtar"], change["once"]) != publications(change["anahtar"], change["sonra"])


def label(change):
    return "%s · %s %d/%s" % (change["uygulama"], change["servis"], change["port"], change["protokol"])


def row_text(env, change, row):
    proto = change["protokol"].upper()
    if row["tur"] == "ham":
        if row["kapsam"] == "kapali":
            return "Ham port · kapalı"
        return "Ham port · %s %s %d" % (SCOPE_TEXT[row["kapsam"]], proto, row["port"])
    parts = ["%s.%s" % (row["ad"], env["LOCAL_DOMAIN"])]
    if row["tailscale_portu"] is not None:
        parts.append("Tailscale portu %d" % row["tailscale_portu"])
    parts.append("internet: %s" % (row["internet"] or "kapalı"))
    return "Adres · " + " · ".join(parts)


def plan_items(env, change):
    """What the change does, as the settings plan lists it (alan "erisim")."""
    old, new, name = change["once"], change["sonra"], label(change)
    domain = env["LOCAL_DOMAIN"]

    def item(islem, nesne, once, sonra):
        return {"alan": "erisim", "islem": islem, "nesne": nesne, "once": once, "sonra": sonra}
    if old["tur"] != new["tur"]:
        if new["tur"] == "adres":
            return [item("ekle", name + " · adres", row_text(env, change, old), row_text(env, change, new))]
        return [item("kaldir", name + " · adres", row_text(env, change, old), row_text(env, change, new))]
    out = []
    if new["tur"] == "adres":
        if old["ad"] != new["ad"]:
            out.append(item("degistir", name + " · Tailscale adı", "%s.%s" % (old["ad"], domain), "%s.%s" % (new["ad"], domain)))
        if old["tailscale_portu"] != new["tailscale_portu"]:
            islem = "ac" if old["tailscale_portu"] is None else "kapat" if new["tailscale_portu"] is None else "degistir"
            out.append(item(islem, name + " · Tailscale portu",
                            "kapalı" if old["tailscale_portu"] is None else "TCP %d" % old["tailscale_portu"],
                            "kapalı" if new["tailscale_portu"] is None else "TCP %d" % new["tailscale_portu"]))
        if old["internet"] != new["internet"]:
            islem = "ac" if not old["internet"] else "kapat" if not new["internet"] else "degistir"
            out.append(item(islem, name + " · internet adı", old["internet"] or "kapalı", new["internet"] or "kapalı"))
        return out
    closed = (old["kapsam"] == "kapali", new["kapsam"] == "kapali")
    islem = {(True, False): "ac", (False, True): "kapat"}.get(closed, "degistir")
    once, sonra = row_text(env, change, old), row_text(env, change, new)
    if closed == (True, True):
        # A closed raw port's number is the one it opens on later.
        once, sonra = "%s · port %d" % (once, old["port"]), "%s · port %d" % (sonra, new["port"])
    return [item(islem, name + " · ham port", once, sonra)]


def plan_notes(env, change):
    """The plan's effects (what restarts, reloads, opens or closes) and warnings, and whether the change can be
    applied as asked (False: the internet consent is missing)."""
    old, new = change["once"], change["sonra"]
    effects, warnings, ok = [], [], True
    if restarts(change):
        if change["durduruldu"]:
            effects.append("Uygulama durdurulmuş: %s servisinin birimi yeniden yazılır, başlatılmaz." % change["servis"])
        else:
            effects.append("%s servisi (ve ona bağlı servisler) yeniden başlar; birkaç saniye yanıt vermez."
                           % change["servis"])
    if "adres" in (old["tur"], new["tur"]):
        effects.append("Caddy yapılandırması yeniden yüklenir.")
    names = ({old["ad"]} if old["tur"] == "adres" else set()) ^ ({new["ad"]} if new["tur"] == "adres" else set())
    if names:
        effects.append("Yerel adlar (dnsmasq) yeniden başlar.")
    if new["tur"] == "adres" and new["internet"] and new["internet"] != (old.get("internet") if old["tur"] == "adres" else ""):
        effects.append("İnternet adı için HTTPS sertifikası alınır (en çok 1 dakika).")
    if claims(change["anahtar"], old) != claims(change["anahtar"], new) or restarts(change):
        effects.append("Güvenlik duvarı ve konteyner koruması yeniden kurulur.")
    if old["tur"] == "adres" and (new["tur"] != "adres" or new["ad"] != old["ad"]):
        warnings.append({"seviye": "warn", "metin": "%s.%s adı artık yanıt vermez; yer imlerini ve uygulamanın kendi adres "
                         "ayarını güncelleyin." % (old["ad"], env["LOCAL_DOMAIN"])})
    if new["tur"] == "ham" and new["kapsam"] != "kapali" and claims(change["anahtar"], new) - claims(change["anahtar"], old):
        warnings.append({"seviye": "warn", "metin": "Ham port güvenlik duvarının kurallarından geçmez; ona kimin "
                         "ulaşacağını yalnız bu satır belirler."})
    if change["internet_acilir"]:
        warnings.append({"seviye": "warn", "metin": CONSENT_TEXT})
        if not change["internet_onayi"]:
            ok = False
            warnings.append({"seviye": "bad", "metin": CONSENT_MISSING})
    return effects, warnings, ok


def certificate_name(change):
    """The internet name the change adds or renames to (its certificate is waited for), or ""."""
    old, new = change["once"], change["sonra"]
    if new["tur"] != "adres" or not new["internet"]:
        return ""
    return new["internet"] if old["tur"] != "adres" or old["internet"] != new["internet"] else ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="/etc/master-stack/state.env")
    parser.add_argument("action", choices=("filter-caddy", "tail-enabled"))
    parser.add_argument("service")
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    from master_settings import env_read
    try:
        env = env_read(args.state)
        require(args.service == BUILTIN_ID, "Bilinmeyen Caddy yayını.")
        if args.action == "tail-enabled":
            sys.exit(0 if config(env)[args.service]["tail"] else 1)
        require(bool(args.path), "Caddy geçici dosyası gerekli.")
        atomic(args.path, private_site(env, args.service, read_regular(args.path)[0].decode()), 0o644)
    except (SettingsError, OSError, ValueError, KeyError) as err:
        print(str(err) if isinstance(err, SettingsError) else "Caddy yayın ayarı okunamadı.", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
