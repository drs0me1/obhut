#!/usr/bin/env python3
"""Erişim read model (DD-259): who can reach which service on this server, and from where.

A projection of what Konsol's root backend already reads. It changes nothing and probes nothing of
its own:
- the Caddy publication table (DD-191, DD-195, DD-252): Tailscale names and HTTPS names;
- folder share policies (DD-192);
- container port publications and their scope (DD-217: the container guard admits exactly these);
- WireGuard's networks (DD-271). They lead only to the internet (DD-177), so a WireGuard device
  reaches no service on this server;
- the port catalogue and the operator's own firewall rules (DD-172, DD-173).
A source that cannot be read adds a line to "hatalar"; the other rows stay.

Each service row has four cells (yerel, tailscale, wireguard, internet). A cell's "durum" is
acik (reachable), kismen (only some ports), kapali (closed), yok (does not apply) or hata (switched
on but not working; "not" says why).

DD-265: a warning names the row it is about by the row's id ("konteyner:x", "elle:x", "panel"; ""
when it is about no row) and where it is fixed: "duzelt" = {bolum, hedef}, bolum one of yayinlar (a
publication; hedef is the row id), uygulama (an application's page; hedef is the application's name,
DD-271 phase 3), tailscale. A container of no application has no page: its warning names no place.
"""
import datetime

CERT_WARN_DAYS = 14
VPN_NOTE = "WireGuard cihazları yalnız internete çıkar; bu sunucudaki hizmetlere ulaşamaz."


def cell(durum="yok", adresler=(), note="", uyari=""):
    return {"durum": durum, "adresler": list(adresler), "not": note, "uyari": uyari}


def day(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%d.%m.%Y")


def number(value, default=0):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    return value if 0 < value < 65536 else default


def upstream_port(value):
    host, _, port = str(value or "").rpartition(":")
    return number(port) if host == "127.0.0.1" else 0


def open_cell(target, address, partial=False, note=""):
    """Adds a reachable address to a cell; a closed or not-applicable cell opens."""
    if address and address not in target["adresler"]:
        target["adresler"].append(address)
    if target["durum"] in ("yok", "kapali"):
        target["durum"] = "kismen" if partial else "acik"
        target["not"] = note


def close_cell(target, note=""):
    if target["durum"] == "yok":
        target["durum"], target["not"] = "kapali", note


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
    return {"id": sid, "ad": ad, "tur": tur, "aciklama": aciklama, "uygulama": uygulama, "calisiyor": calisiyor,
            "yerel": cell(), "tailscale": cell(), "wireguard": dict(wireguard, adresler=list(wireguard["adresler"])),
            "internet": cell(), "yayinlar": [], "ayrinti": []}


def closed(row):
    """A service row's cells that nothing opened are closed, not "does not apply"."""
    for scope in ("yerel", "tailscale", "internet"):
        close_cell(row[scope])
    return row


def detail(row, baslik, deger):
    item = {"baslik": baslik, "deger": deger}
    if item not in row["ayrinti"]:
        row["ayrinti"].append(item)


def publish(row, pub, env, upstream=""):
    """One Caddy publication (its Tailscale name and its HTTPS name) on a service row."""
    row["yayinlar"].append(pub["service"])
    ts = env.get("TAILSCALE_IPV4", "")
    if pub.get("tail"):
        open_cell(row["tailscale"], pub.get("local", ""))
        detail(row, "DNS", "%s → %s" % (pub.get("local", ""), ts) if ts else pub.get("local", ""))
    else:
        close_cell(row["tailscale"], "Tailscale adı kapalı.")
    if not pub.get("enabled"):
        close_cell(row["internet"])
        return
    domain = pub.get("domain") or ""
    if pub.get("status") == "ready":
        open_cell(row["internet"], domain)
        if upstream:
            detail(row, "Caddy", "%s → %s" % (domain, upstream))
        if isinstance(pub.get("expires"), (int, float)) and not isinstance(pub.get("expires"), bool):
            detail(row, "Sertifika", "%s tarihine kadar" % day(pub["expires"]))
        return
    target = row["internet"]
    if domain and domain not in target["adresler"]:
        target["adresler"].append(domain)
    target["durum"] = "hata"
    target["not"] = pub.get("message") or "İnternet yayını doğrulanamadı."


def warning(seviye, hizmet, metin, bolum, hedef=""):
    return {"seviye": seviye, "hizmet": hizmet, "metin": metin, "duzelt": {"bolum": bolum, "hedef": hedef} if bolum else None}


def add_container(row, item, env, warnings):
    """A container's publications on a service row."""
    app = row["uygulama"]
    fix = ("uygulama", app) if app else (None, "")
    for group in port_groups(item.get("ports")):
        text = port_text(group, env)
        detail(row, "Konteyner portu", text)
        if group["scope"] == "local":
            open_cell(row["yerel"], text)
        elif group["scope"] == "tailscale":
            open_cell(row["tailscale"], text)
        elif group["scope"] == "public":
            open_cell(row["internet"], text)
            warnings.append(warning("warn", row["id"], "%s: %s doğrudan internete açık; şifreleme ve giriş uygulamanın kendisinde."
                                    % (row["ad"], text), *fix))
        else:
            warnings.append(warning("warn", row["id"], "%s: %s adresindeki yayın tanınmıyor; Gelişmiş → Podman'dan denetleyin."
                                    % (row["ad"], text), *fix))


def share_row(env, pub, shares, wireguard, warnings):
    row = service("paylasim", "Paylaşımlar", "paylasim", "WebDAV", wireguard, calisiyor=True if shares else None)
    if pub:
        row["yayinlar"].append(pub["service"])
    if not shares:
        row["tailscale"] = cell("hata", (), "Paylaşım kaydı okunamadı.")
        row["internet"] = cell("hata", (), "Paylaşım kaydı okunamadı.")
        return row
    items = [i for i in shares.get("items") or [] if isinstance(i, dict)]
    row["aciklama"] = "WebDAV · %d klasör" % len(items)
    active = {scope: [i for i in items if ((i.get("connections") or {}).get(scope) or {}).get("active")]
              for scope in ("tailscale", "wan")}
    for item in items:
        conns = item.get("connections") or {}
        state = ["%s %s" % (name, "açık" if (conns.get(scope) or {}).get("active") else "kapalı")
                 for scope, name in (("tailscale", "Tailscale"), ("wan", "İnternet"))]
        detail(row, "Klasör · %s" % item.get("name", ""), " · ".join(state))
    if active["tailscale"]:
        origin = shares.get("host", "")
        row["tailscale"] = cell("acik", [a for a in ("paylas." + env.get("LOCAL_DOMAIN", ""), origin) if a],
                                "%d klasör" % len(active["tailscale"]))
    else:
        reason = ("Erişim → Adresler bölümünde Tailscale erişimi kapalı." if not shares.get("tail_enabled") else
                  "Tailscale'den paylaşılan klasör yok.")
        row["tailscale"] = cell("kapali", (), reason)
    wan = shares.get("wan") or {}
    if active["wan"]:
        origin = str((active["wan"][0]["connections"]["wan"].get("url") or "")).split("/s/")[0]
        if wan.get("mode") == "https":
            row["internet"] = cell("acik", [origin], "%d klasör" % len(active["wan"]))
        else:
            row["internet"] = cell("acik", [origin], "%d klasör" % len(active["wan"]), "Şifresiz HTTP")
            warnings.append(warning("warn", "paylasim", "İnternetten gelen WebDAV bağlantıları şifresiz; kullanıcı adı ve parola ağda "
                                    "okunabilir. Bir HTTPS adı tanımlayınca bağlantı şifrelenir.", "yayinlar", "paylasim"))
    else:
        row["internet"] = cell("kapali", (), "" if wan.get("available") else str(wan.get("reason") or ""))
    return row


def tailscale_summary(env, status):
    """`tailscale status --json --peers=false` as the Erişim page shows it. DD-265 adds the device's
    name, the client version, its addresses and whether it is offered as an exit node."""
    out = {"ipv4": env.get("TAILSCALE_IPV4", ""), "ipv6": env.get("TAILSCALE_IPV6", ""),
           "durum": "bilinmiyor", "anahtar_bitis": None, "ad": "", "surum": "", "adresler": [], "cikis_dugumu": None}
    if isinstance(status, dict) and isinstance(status.get("Self"), dict):
        me = status["Self"]
        out["durum"] = "bagli" if status.get("BackendState") == "Running" and me.get("Online") is True else "bagli-degil"
        out["ad"] = str(me.get("DNSName") or "").rstrip(".")
        out["surum"] = str(status.get("Version") or "").split("-")[0]
        out["adresler"] = [str(a) for a in me.get("TailscaleIPs") or [] if isinstance(a, str)]
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


def build(env, settings, shares, containers, tailscale, networks, wg_stopped, now, errors=()):
    """env: state.env; settings: the backend's settings view; shares: master_shares public() or None;
    containers: Inventory.reach() or None; tailscale: `tailscale status --json` or None; networks:
    WireGuard's networks (none while it is stopped); wg_stopped: WireGuard is stopped as a whole."""
    errors = list(errors)
    settings = settings or {}
    manage = settings.get("manage") or {}
    if manage.get("error"):
        errors.append(str(manage["error"]))
    pubs = {r["service"]: r for r in manage.get("publications") or [] if isinstance(r, dict) and r.get("service")}
    rules = [r for r in ((manage.get("config") or {}).get("firewall") or [])
             if isinstance(r, dict) and r.get("scope") in ("wan", "tail") and isinstance(r.get("port"), int)]
    networks = [n for n in networks or [] if isinstance(n, dict) and n.get("iface")]
    wireguard = cell("kapali", (), VPN_NOTE) if networks else cell()
    domain, wan4 = env.get("LOCAL_DOMAIN", ""), env.get("WAN_IPV4", "")
    warnings, rows = [], []

    panel = service("panel", "Konsol", "konsol", "Yönetim paneli", wireguard, calisiyor=True)
    panel["tailscale"] = cell("acik", ["panel." + domain], "Giriş istemez; cihazı Tailscale doğrular.")
    pub = pubs.get("panel") or {"service": "panel", "tail": True, "enabled": False, "local": "panel." + domain}
    publish(panel, pub, env)
    if panel["internet"]["durum"] == "acik":
        panel["internet"]["not"] = "Konsol hesabıyla giriş ister."
    rows.append(panel)

    items = []
    if containers is not None:
        items = [i for i in containers.get("containers") or [] if isinstance(i, dict) and i.get("name")]
        runtime = containers.get("runtime") or {}
        if not runtime.get("ok", True):
            errors.append(str(runtime.get("error") or "Podman kullanılamıyor."))

    manual = {sid: pub for sid, pub in pubs.items() if pub.get("manual")}
    for item in items:
        app = item.get("uygulama") if item.get("source") == "uygulama" else None
        row = service("konteyner:" + item["name"], item["name"], "konteyner",
                      "Uygulama · %s" % app if app else "Konteyner · Konsol dışında yönetiliyor",
                      wireguard, app or None, item.get("state") == "running")
        add_container(row, item, env, warnings)
        local = {g["host_port"] for g in port_groups(item.get("ports")) if g["scope"] == "local" and g["host_ip"] == "127.0.0.1"}
        for sid, pub in sorted(manual.items()):
            if upstream_port(pub.get("upstream")) in local:
                publish(row, pub, env, pub.get("upstream", ""))
                del manual[sid]
        rows.append(closed(row))
    for sid, pub in sorted(manual.items()):
        row = service("elle:" + sid.partition("-")[2], pub.get("name") or sid, "elle", "Elle adres", wireguard,
                      calisiyor=pub.get("answers") if isinstance(pub.get("answers"), bool) else None)
        if pub.get("answers") is False:
            row["yerel"] = cell("hata", [pub.get("upstream", "")], "Hedef yanıt vermiyor; uygulamanın çalıştığını ve portunu kontrol edin.")
        else:
            open_cell(row["yerel"], pub.get("upstream", ""))
        publish(row, pub, env, pub.get("upstream", ""))
        rows.append(row)

    rows.append(share_row(env, pubs.get("paylasim"), shares, wireguard, warnings))

    ssh = number(env.get("SSH_PUBLIC_PORT"))
    if ssh:
        row = service("sistem:ssh", "SSH", "sistem", "Uzak kabuk", wireguard)
        row["tailscale"] = cell("acik", ["%d/tcp" % ssh])
        row["internet"] = cell("acik", ["%s:%d/tcp" % (wan4, ssh) if wan4 else "%d/tcp" % ssh])
        rows.append(row)
    dns = number(env.get("DNS_PORT"), 53)
    row = service("sistem:dns", "Yerel adlar", "sistem", "dnsmasq · .%s" % domain if domain else "dnsmasq", wireguard)
    row["tailscale"] = cell("acik", ["%d/udp+tcp" % dns])
    row["internet"] = cell("kapali")
    rows.append(row)
    for net in networks:
        port = number(net.get("port"))
        row = service("vpn:" + net["iface"], "WireGuard %s" % net["iface"], "vpn",
                      net.get("label") or "VPN", cell(), calisiyor=bool(net.get("active")))
        if net.get("active") and port:
            row["tailscale"] = cell("acik", ["%d/udp" % port])
            row["internet"] = cell("acik", ["%s:%d/udp" % (wan4, port) if wan4 else "%d/udp" % port])
        else:
            row["tailscale"] = cell("kapali", (), "Ağ kapalı.")
            row["internet"] = cell("kapali", (), "Ağ kapalı.")
        rows.append(row)
    for rule in rules:
        row = service("kural:" + str(rule.get("id", "")), str(rule.get("name") or "Kural"), "kural",
                      "Güvenlik duvarı kuralı · IPv%s" % rule.get("family"), cell())
        text = "%d/%s" % (rule["port"], rule.get("proto", "")) + (" · yalnız %s" % rule["source"] if rule.get("source") else "")
        row["internet" if rule["scope"] == "wan" else "tailscale"] = cell(
            "acik" if rule.get("allow") else "kapali", [text], "İzin kuralı" if rule.get("allow") else "Engelleme kuralı")
        rows.append(row)

    owner = {}  # a publication's service id → the row it is shown on
    for row in rows:
        for service_id in row["yayinlar"]:
            owner.setdefault(service_id, row["id"])
        for scope in ("yerel", "tailscale", "internet"):
            if row[scope]["durum"] == "hata":
                warnings.append(warning("warn", row["id"], "%s: %s" % (row["ad"], row[scope]["not"]), "yayinlar", row["id"]))

    summary = tailscale_summary(env, tailscale)
    if summary["durum"] == "bagli-degil":
        warnings.insert(0, warning("bad", "", "Tailscale bağlı değil; Konsol'a ve tailnet adlarına öbür cihazlardan ulaşılamaz.",
                                   "tailscale"))
    certificates = []
    for pub in pubs.values():
        if not (pub.get("enabled") and pub.get("domain")):
            continue
        expires = pub.get("expires") if isinstance(pub.get("expires"), (int, float)) and not isinstance(pub.get("expires"), bool) else None
        ready = pub.get("status") == "ready"
        certificates.append({"ad": pub["domain"], "hizmet": owner.get(pub["service"], ""), "durum": "gecerli" if ready else "hazir-degil",
                             "bitis": int(expires) if expires is not None else None})
        if ready and expires is not None and expires - now <= CERT_WARN_DAYS * 86400:
            left = int((expires - now) // 86400)
            row_id = owner.get(pub["service"], "")
            warnings.append(warning("bad" if expires <= now else "warn", row_id,
                                    "%s sertifikasının süresi doldu." % pub["domain"] if expires <= now else
                                    "%s sertifikası %d gün sonra doluyor; Caddy kendiliğinden yeniler, yenilemezse "
                                    "internetten erişim kesilir." % (pub["domain"], left), "yayinlar", row_id))
    certificates.sort(key=lambda c: (c["bitis"] is None, c["bitis"] or 0, c["ad"]))
    return {
        "read_at": int(now),
        "alan": domain,
        "ozet": {
            "tailscale": summary,
            "internet": {"ipv4": wan4, "ipv6": env.get("WAN_IPV6", ""), "acik": internet_ports(settings, rules)},
            "wireguard": {"kurulu": bool(networks), "durduruldu": bool(wg_stopped), "not": VPN_NOTE if networks else "",
                          "aglar": [{"arayuz": n["iface"], "ad": str(n.get("label") or ""),
                                     "etkin": bool(n.get("active")), "port": number(n.get("port"))} for n in networks]},
            "sertifikalar": certificates,
        },
        "hizmetler": rows,
        "uyarilar": warnings,
        "hatalar": errors,
    }
