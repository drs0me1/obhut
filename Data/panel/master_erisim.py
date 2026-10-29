#!/usr/bin/env python3
"""Erişim read model (DD-259): who can reach which service on this server, and from where.

A projection of what Konsol's root backend already reads. It changes nothing and probes nothing of
its own:
- the fixed rows of Konsol and WebDAV (DD-191, DD-195): Tailscale names and HTTPS names;
- the applications' access rows (rebuild phase 4, master_applications.access_rows): one row per
  application port with its address (Tailscale name, Tailscale port, internet name) or raw port;
- folder share policies (DD-192);
- containers that no application owns, with their port publications;
- WireGuard's networks (DD-271). They lead only to the internet (DD-177), so a WireGuard device
  reaches no service on this server;
- the port catalogue and the operator's own firewall rules (DD-172, DD-173).
A source that cannot be read adds a line to "hatalar"; the other rows stay.

Each service row has four cells (yerel, tailscale, wireguard, internet). A cell's "durum" is
acik (reachable), kismen (only some ports), kapali (closed), yok (does not apply) or hata (switched
on but not working; "not" says why, and is empty otherwise). "adresler" are the addresses and ports;
"uyari" is a short risk of an open cell (a raw port on the internet, unencrypted WebDAV).

DD-265: a warning names the row it is about by the row's id ("panel", "paylasim",
"uygulama:<app>:<service>:<port>/<proto>", "konteyner:x"; "" when it is about no row) and where it is
fixed: "duzelt" = {bolum, hedef}, bolum one of adresler (Erişim → Adresler; hedef is the row id),
uygulama (an application's page; hedef is the application's name). A warning about Tailscale itself
(not connected, the device key about to expire) and one about a container of no application name no
place: Erişim → Genel shows the Tailscale summary, and a container of no application has no page.
"""
import copy
import datetime

import master_generator

CERT_WARN_DAYS = 14
TAILSCALE_KEY_WARN_DAYS = 14


def cell(durum="yok", adresler=(), note="", uyari=""):
    return {"durum": durum, "adresler": list(adresler), "not": note, "uyari": uyari}


def number(value, default=0):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    return value if 0 < value < 65536 else default


def open_cell(target, address, partial=False):
    """Adds a reachable address to a cell; a closed or not-applicable cell opens."""
    if address and address not in target["adresler"]:
        target["adresler"].append(address)
    if target["durum"] in ("yok", "kapali"):
        target["durum"] = "kismen" if partial else "acik"


def close_cell(target):
    if target["durum"] == "yok":
        target["durum"] = "kapali"


def port_groups(ports):
    """Container publications grouped by scope, host address and ports; protocols joined (tcp+udp)."""
    groups = {}
    for p in ports or []:
        if not isinstance(p, dict) or not isinstance(p.get("host_port"), int) or not isinstance(p.get("container_port"), int):
            continue
        key = (str(p.get("scope") or "other"), str(p.get("host_ip") or "0.0.0.0"), p["host_port"], p["container_port"])
        groups.setdefault(key, set()).add(str(p.get("protocol") or "tcp"))
    return [{"scope": scope, "host_ip": ip, "host_port": host, "container_port": inner, "proto": "+".join(sorted(protos))}
            for (scope, ip, host, inner), protos in sorted(groups.items())]


def port_text(group, env):
    ip = group["host_ip"]
    if group["scope"] == "public" and ip in ("0.0.0.0", "::", ""):
        ip = env.get("WAN_IPV4") or ip
    host = "[%s]" % ip if ":" in ip else ip
    if group["host_port"] == group["container_port"]:
        return "%s:%d/%s" % (host, group["host_port"], group["proto"])
    return "%s:%d → %d/%s" % (host, group["host_port"], group["container_port"], group["proto"])


def service(sid, ad, tur, aciklama, wireguard, uygulama=None, calisiyor=None):
    return {"id": sid, "ad": ad, "tur": tur, "aciklama": aciklama, "uygulama": uygulama, "servis": None, "anahtar": None,
            "calisiyor": calisiyor, "yerel": cell(), "tailscale": cell(),
            "wireguard": dict(wireguard, adresler=list(wireguard["adresler"])), "internet": cell(), "satir": None,
            "web": None}


def closed(row):
    """A service row's cells that nothing opened are closed, not "does not apply"."""
    for scope in ("yerel", "tailscale", "internet"):
        close_cell(row[scope])
    return row


def publish(row, pub):
    """A fixed row's publication (its Tailscale name and its HTTPS name) on its service row."""
    row["web"] = {"tail": bool(pub.get("tail")), "enabled": bool(pub.get("enabled")), "domain": str(pub.get("domain") or "")}
    if pub.get("tail"):
        open_cell(row["tailscale"], pub.get("local", ""))
    else:
        close_cell(row["tailscale"])
    if not pub.get("enabled"):
        close_cell(row["internet"])
        return
    domain = pub.get("domain") or ""
    if pub.get("status") == "ready":
        open_cell(row["internet"], domain)
        return
    target = row["internet"]
    if domain and domain not in target["adresler"]:
        target["adresler"].append(domain)
    target["durum"] = "hata"
    target["not"] = pub.get("message") or "İnternet yayını doğrulanamadı."


def warning(seviye, hizmet, metin, bolum, hedef=""):
    return {"seviye": seviye, "hizmet": hizmet, "metin": metin, "duzelt": {"bolum": bolum, "hedef": hedef} if bolum else None}


def internet_name(row, pub, name):
    """An address row's internet name on its cell: open with a verified certificate, else hata with the reason."""
    target = row["internet"]
    if pub.get("status") == "ready":
        open_cell(target, name)
        return
    if name not in target["adresler"]:
        target["adresler"].append(name)
    target["durum"] = "hata"
    target["not"] = pub.get("message") or "İnternet adı doğrulanamadı."


def app_row(env, item, pubs, running, wireguard, warnings):
    """One application port's access row (rebuild phase 4): yerel is an address's 127.0.0.1 pool port; tailscale its
    Tailscale name and Tailscale port, or a raw port open on Tailscale; internet its internet name, or a raw port open
    on the WAN IPv4; WireGuard devices reach none of it."""
    access = item["satir"]
    proto = item["protokol"]
    row = service(item["id"], "%s · %s" % (item["uygulama"], item["servis"]), "uygulama",
                  "%d/%s · %s" % (item["port"], proto, "Adres" if access["tur"] == "adres" else "Doğrudan port"),
                  wireguard, item["uygulama"], running)
    row.update(servis=item["servis"], anahtar=item["anahtar"], satir=copy.deepcopy(access))
    ts, wan = env.get("TAILSCALE_IPV4", ""), env.get("WAN_IPV4", "")
    if access["tur"] == "adres":
        open_cell(row["yerel"], "127.0.0.1:%d" % item["yerel_port"] if item.get("yerel_port") else "")
        name = "%s.%s" % (access["ad"], env.get("LOCAL_DOMAIN", ""))
        open_cell(row["tailscale"], name)
        if access["tailscale_portu"] is not None:
            open_cell(row["tailscale"], "%s:%d" % (ts, access["tailscale_portu"]) if ts else "%d/tcp" % access["tailscale_portu"])
        if access["internet"]:
            internet_name(row, pubs.get(item["id"]) or {}, access["internet"])
        return closed(row)
    text = "%d/%s" % (access["port"], proto)
    if access["kapsam"] == "tailscale":
        open_cell(row["tailscale"], "%s:%s" % (ts, text) if ts else text)
    elif access["kapsam"] == "internet":
        open_cell(row["internet"], "%s:%s" % (wan, text) if wan else text)
        row["internet"]["uyari"] = "Şifreleme ve giriş uygulamanın kendisinde."
        warnings.append(warning("warn", row["id"], "%s: %s doğrudan internete açık; şifreleme ve giriş uygulamanın kendisinde."
                                % (row["ad"], text), "adresler", row["id"]))
    for scope in ("tailscale", "internet"):
        close_cell(row[scope])
    return row


def add_container(row, item, env, warnings):
    """The publications of a container that no application owns on its service row (no place to fix them). DD-294: the
    container guard drops what comes in from the internet to such a container, so a public publication is the internet
    cell's closed address; published on every address it is reached from Tailscale."""
    fix = (None, "")
    for group in port_groups(item.get("ports")):
        text = port_text(group, env)
        if group["scope"] == "local":
            open_cell(row["yerel"], text)
        elif group["scope"] == "tailscale":
            open_cell(row["tailscale"], text)
        elif group["scope"] == "public":
            if text not in row["internet"]["adresler"]:
                row["internet"]["adresler"].append(text)
            close_cell(row["internet"])
            if group["host_ip"] in ("0.0.0.0", "::", "") and env.get("TAILSCALE_IPV4"):
                open_cell(row["tailscale"], port_text(dict(group, scope="tailscale", host_ip=env["TAILSCALE_IPV4"]), env))
        else:
            warnings.append(warning("warn", row["id"], "%s: %s adresindeki yayın tanınmıyor; Podman'dan denetleyin."
                                    % (row["ad"], text), *fix))


def share_row(env, pub, shares, wireguard, warnings):
    row = service("paylasim", "Paylaşımlar", "paylasim", "WebDAV", wireguard, calisiyor=True if shares else None)
    if pub:
        row["web"] = {"tail": bool(pub.get("tail")), "enabled": bool(pub.get("enabled")), "domain": str(pub.get("domain") or "")}
    if not shares:
        row["tailscale"] = cell("hata", (), "Paylaşım kaydı okunamadı.")
        row["internet"] = cell("hata", (), "Paylaşım kaydı okunamadı.")
        return row
    items = [i for i in shares.get("items") or [] if isinstance(i, dict)]
    row["aciklama"] = "WebDAV · %d klasör" % len(items)
    active = {scope: [i for i in items if ((i.get("connections") or {}).get(scope) or {}).get("active")]
              for scope in ("tailscale", "wan")}
    if active["tailscale"]:
        origin = shares.get("host", "")
        row["tailscale"] = cell("acik", [a for a in ("paylas." + env.get("LOCAL_DOMAIN", ""), origin) if a])
    else:
        row["tailscale"] = cell("kapali")
    wan = shares.get("wan") or {}
    if active["wan"]:
        origin = str((active["wan"][0]["connections"]["wan"].get("url") or "")).split("/s/")[0]
        if wan.get("mode") == "https":
            row["internet"] = cell("acik", [origin])
        else:
            row["internet"] = cell("acik", [origin], uyari="Şifresiz HTTP")
            warnings.append(warning("warn", "paylasim", "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda "
                                    "okunabilir. Bir HTTPS adı tanımlayınca bağlantı şifrelenir.", "adresler", "paylasim"))
    else:
        row["internet"] = cell("kapali")
    return row


def tailscale_summary(env, status):
    """`tailscale status --json --peers=false` as Konsol shows it: the state, the addresses and the key's end on
    Erişim → Genel; the device's name, the client version and whether it is offered as an exit node on
    Sistem → Sunucu (DD-265, DD-288)."""
    out = {"ipv4": env.get("TAILSCALE_IPV4", ""), "ipv6": env.get("TAILSCALE_IPV6", ""),
           "durum": "bilinmiyor", "anahtar_bitis": None, "ad": "", "surum": "", "cikis_dugumu": None}
    if isinstance(status, dict) and isinstance(status.get("Self"), dict):
        me = status["Self"]
        out["durum"] = "bagli" if status.get("BackendState") == "Running" and me.get("Online") is True else "bagli-degil"
        out["ad"] = str(me.get("DNSName") or "").rstrip(".")
        out["surum"] = str(status.get("Version") or "").split("-")[0]
        routes = me.get("AllowedIPs") if isinstance(me.get("AllowedIPs"), list) else []
        if isinstance(me.get("ExitNodeOption"), bool):
            out["cikis_dugumu"] = me["ExitNodeOption"]
        elif routes:
            out["cikis_dugumu"] = "0.0.0.0/0" in routes or "::/0" in routes
        expiry = me.get("KeyExpiry")
        if isinstance(expiry, str):
            try:
                out["anahtar_bitis"] = int(datetime.datetime.fromisoformat(expiry.replace("Z", "+00:00")).timestamp())
            except (ValueError, OverflowError):
                pass
    return out


def internet_ports(settings, rules):
    """The WAN rows of the port catalogue (DD-173) and the operator's own allow rules."""
    groups = {}
    for r in ((settings.get("firewall") or {}).get("ports") or []):
        if isinstance(r, dict) and r.get("scope") == "wan" and isinstance(r.get("port"), int):
            key = (str(r.get("name", "")), r["port"])
            entry = groups.setdefault(key, (set(), set()))
            entry[0].add(str(r.get("proto", "")))
            entry[1].add(r.get("family"))
    out = [{"ad": name, "port": port, "proto": "+".join(sorted(protos)), "aileler": sorted(f for f in families if f in (4, 6)),
            "kaynak": "temel"} for (name, port), (protos, families) in sorted(groups.items(), key=lambda kv: (kv[0][1], kv[0][0]))]
    for r in rules:
        if r.get("scope") == "wan" and r.get("allow"):
            out.append({"ad": str(r.get("name") or "Kural"), "port": r["port"], "proto": str(r.get("proto", "")),
                        "aileler": [r["family"]] if r.get("family") in (4, 6) else [], "kaynak": "kural"})
    return out


def build(env, settings, shares, containers, tailscale, networks, wg_stopped, now, errors=(), rows=None):
    """env: state.env; settings: the backend's settings view; shares: master_shares public() or None;
    containers: Inventory.reach() or None; tailscale: `tailscale status --json` or None; networks:
    WireGuard's networks (none while it is stopped); wg_stopped: WireGuard is stopped as a whole; rows: every
    application's access rows (master_applications.access_rows), None when they could not be read."""
    errors = list(errors)
    settings = settings or {}
    manage = settings.get("manage") or {}
    if manage.get("error"):
        errors.append(str(manage["error"]))
    pubs = {r["service"]: r for r in manage.get("publications") or [] if isinstance(r, dict) and r.get("service")}
    rules = [r for r in ((manage.get("config") or {}).get("firewall") or [])
             if isinstance(r, dict) and r.get("scope") in ("wan", "tail") and isinstance(r.get("port"), int)]
    networks = [n for n in networks or [] if isinstance(n, dict) and n.get("iface")]
    wireguard = cell("kapali") if networks else cell()
    domain, wan4 = env.get("LOCAL_DOMAIN", ""), env.get("WAN_IPV4", "")
    warnings, out = [], []

    panel = service("panel", "Konsol", "konsol", "Yönetim paneli", wireguard, calisiyor=True)
    panel["tailscale"] = cell("acik", ["panel." + domain])
    pub = pubs.get("panel") or {"service": "panel", "tail": True, "enabled": False, "local": "panel." + domain}
    publish(panel, pub)
    out.append(panel)

    items = []
    if containers is not None:
        items = [i for i in containers.get("containers") or [] if isinstance(i, dict) and i.get("name")]
        runtime = containers.get("runtime") or {}
        if not runtime.get("ok", True):
            errors.append(str(runtime.get("error") or "Podman kullanılamıyor."))
    state = {i["name"]: i.get("state") == "running" for i in items}
    for item in rows or []:
        try:
            container = master_generator.container_name(item["uygulama"], item["servis"])
        except master_generator.GeneratorError:
            container = ""
        running = state.get(container) if containers is not None else None
        out.append(app_row(env, item, pubs, running, wireguard, warnings))
    # A container that no application owns keeps its own row (an application's ports are its access rows).
    for item in items:
        if item.get("source") == "uygulama":
            continue
        row = service("konteyner:" + item["name"], item["name"], "konteyner", "Konteyner · Obhut dışında kuruldu",
                      wireguard, None, item.get("state") == "running")
        add_container(row, item, env, warnings)
        out.append(closed(row))

    out.append(share_row(env, pubs.get("paylasim"), shares, wireguard, warnings))

    ssh = number(env.get("SSH_PUBLIC_PORT"))
    if ssh:
        row = service("sistem:ssh", "SSH", "sistem", "Uzak kabuk", wireguard)
        row["tailscale"] = cell("acik", ["%d/tcp" % ssh])
        row["internet"] = cell("acik", ["%s:%d/tcp" % (wan4, ssh) if wan4 else "%d/tcp" % ssh])
        out.append(row)
    dns = number(env.get("DNS_PORT"), 53)
    row = service("sistem:dns", "Yerel adlar", "sistem", "dnsmasq · .%s" % domain if domain else "dnsmasq", wireguard)
    row["tailscale"] = cell("acik", ["%d/udp+tcp" % dns])
    row["internet"] = cell("kapali")
    out.append(row)
    for net in networks:
        port = number(net.get("port"))
        row = service("vpn:" + net["iface"], "WireGuard %s" % net["iface"], "vpn",
                      net.get("label") or "VPN", cell(), calisiyor=bool(net.get("active")))
        if net.get("active") and port:
            row["tailscale"] = cell("acik", ["%d/udp" % port])
            row["internet"] = cell("acik", ["%s:%d/udp" % (wan4, port) if wan4 else "%d/udp" % port])
        else:
            row["tailscale"] = cell("kapali")
            row["internet"] = cell("kapali")
        out.append(row)
    for rule in rules:
        row = service("kural:" + str(rule.get("id", "")), str(rule.get("name") or "Kural"), "kural",
                      "%s · IPv%s" % ("İzin kuralı" if rule.get("allow") else "Engelleme kuralı", rule.get("family")), cell())
        text = "%d/%s" % (rule["port"], rule.get("proto", "")) + (" · yalnız %s" % rule["source"] if rule.get("source") else "")
        row["internet" if rule["scope"] == "wan" else "tailscale"] = cell("acik" if rule.get("allow") else "kapali", [text])
        out.append(row)

    addresses = {r["id"] for r in out if r["tur"] in ("konsol", "paylasim", "uygulama")}
    for row in out:
        for scope in ("yerel", "tailscale", "internet"):
            if row[scope]["durum"] == "hata":
                place = ("adresler", row["id"]) if row["id"] in addresses else (None, "")
                warnings.append(warning("warn", row["id"], "%s: %s" % (row["ad"], row[scope]["not"]), *place))

    summary = tailscale_summary(env, tailscale)
    # Tailscale itself first: not connected, then the device key's end (DD-288: the warning the Tailscale tab gave).
    first = []
    if summary["durum"] == "bagli-degil":
        first.append(warning("bad", "", "Tailscale bağlı değil; Konsol'a ve tailnet adlarına öbür cihazlardan ulaşılamaz.", None))
    key_end = summary["anahtar_bitis"]
    if key_end is not None and key_end - now <= TAILSCALE_KEY_WARN_DAYS * 86400:
        days = int((key_end - now) // 86400)
        when = "%d gün sonra" % days if days else "bir gün içinde"
        first.append(warning("bad" if key_end <= now else "warn", "",
                             "Tailscale cihaz anahtarının süresi doldu; sunucu tailnet'ten düştü." if key_end <= now else
                             "Tailscale cihaz anahtarının süresi %s doluyor; dolunca sunucu tailnet'ten düşer. "
                             "Tailscale yönetim panelinden anahtarı yenileyin ya da süresini kapatın." % when,
                             None))
    warnings[:0] = first
    certificates = []
    for pub in pubs.values():
        if not (pub.get("enabled") and pub.get("domain")):
            continue
        expires = pub.get("expires") if isinstance(pub.get("expires"), (int, float)) and not isinstance(pub.get("expires"), bool) else None
        ready = pub.get("status") == "ready"
        owner = pub["service"] if pub["service"] in addresses else ""
        certificates.append({"ad": pub["domain"], "hizmet": owner, "durum": "gecerli" if ready else "hazir-degil",
                             "bitis": int(expires) if expires is not None else None})
        if ready and expires is not None and expires - now <= CERT_WARN_DAYS * 86400:
            left = int((expires - now) // 86400)
            warnings.append(warning("bad" if expires <= now else "warn", owner,
                                    "%s sertifikasının süresi doldu." % pub["domain"] if expires <= now else
                                    "%s sertifikası %d gün sonra doluyor; Caddy kendiliğinden yeniler, yenilemezse "
                                    "internetten erişim kesilir." % (pub["domain"], left), "adresler", owner))
    certificates.sort(key=lambda c: (c["bitis"] is None, c["bitis"] or 0, c["ad"]))
    return {
        "read_at": int(now),
        "alan": domain,
        "revizyon": str(manage.get("revision") or ""),
        "ozet": {
            "tailscale": summary,
            "internet": {"ipv4": wan4, "ipv6": env.get("WAN_IPV6", ""), "acik": internet_ports(settings, rules)},
            "wireguard": {"kurulu": bool(networks), "durduruldu": bool(wg_stopped),
                          "aglar": [{"arayuz": n["iface"], "ad": str(n.get("label") or ""),
                                     "etkin": bool(n.get("active")), "port": number(n.get("port"))} for n in networks]},
            "sertifikalar": certificates,
        },
        "hizmetler": out,
        "uyarilar": warnings,
        "hatalar": errors,
    }
