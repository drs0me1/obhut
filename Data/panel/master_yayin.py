#!/usr/bin/env python3
"""Yayınla (DD-265): what can be published, and the plan of one publication.

A publication is one row of the Caddy publication table (DD-191/195/252): a Tailscale name
(<ad>.<alan>) and an optional internet (HTTPS) name. candidates() lists every row and every container
that could have one: a container is published from a port it already listens on at 127.0.0.1 (an
application's address port, DD-271 phase 3). plan() turns the four decisions of the Yayınla flow (what,
who, which name, plan) into the request the page then sends to the settings transaction
(master_settings.plan/apply). This module changes nothing: the settings plan is the same dry run apply
validates with (DD-265), and its failure is the plan's "engel". Phase 4 replaces the flow with the
access rows.
"""
import copy
import re

from master_settings import SettingsError, require

PUB_LOCAL_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
NAME_RE = re.compile(r"^[^\x00-\x1f]{1,40}$")
MANUAL_PREFIX = "elle-"
GUARD_KONSOL = "İnternetten Konsol hesabıyla giriş istenir."
GUARD_SHARES = "Klasör hesapları korur; her klasörün internet erişimi Paylaşımlar'dan açılır."
GUARD_APP = "Yalnız uygulamanın kendi girişi korur; Konsol bu adreste giriş denetlemez."


def default_local(name):
    """A container's name as a Tailscale name: lower case, letters, digits and hyphens."""
    text = re.sub(r"[^a-z0-9-]+", "-", str(name).lower()).strip("-")
    if not text or not text[0].isalpha():
        text = "k-" + text
    return text[:31].rstrip("-") or "konteyner"


def number(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 < value < 65536 else 0


def upstream_port(value):
    host, _, port = str(value or "").rpartition(":")
    return int(port) if host == "127.0.0.1" and port.isdigit() and 0 < int(port) < 65536 else 0


def item(cid, tur, ad, row=None, **extra):
    row = row or {}
    base = {"id": cid, "tur": tur, "ad": ad, "servis": row.get("service"), "yerel_ad": row.get("local") or None,
            "tailscale": bool(row.get("tail", True)) if row else False, "internet": bool(row.get("enabled")),
            "alan_adi": str(row.get("domain") or ""), "durum": str(row.get("status") or "disabled"),
            "mesaj": str(row.get("message") or ""), "bitis": row.get("expires") if isinstance(row.get("expires"), int) else None,
            "hedef": row.get("upstream") or None, "giris": GUARD_APP, "onay_kelimesi": False,
            "internet_engel": "", "kullanilabilir": True, "neden": "", "konteyner": None}
    base.update(extra)
    return base


def candidates(env, rows, containers, wan_ready=True):
    """rows: master_publications.status(); containers: Inventory.reach() or None; wan_ready: the server
    has an assigned public IPv4."""
    by_service = {r["service"]: r for r in rows if isinstance(r, dict) and r.get("service")}
    no_wan = "" if wan_ready else "Sunucunun internet IPv4 adresi kullanılamıyor; internet adı açılamaz."
    out = []
    panel = by_service.get("panel")
    if panel:
        out.append(item("panel", "konsol", "Konsol", panel, giris=GUARD_KONSOL, onay_kelimesi=True, internet_engel=no_wan or (
            "" if panel.get("account") else "Önce Konsol hesabı oluşturun (Tailscale adresinden, Sistem → Hesap).")))
    items = [c for c in ((containers or {}).get("containers") or []) if isinstance(c, dict) and c.get("name")]
    manual = {sid: r for sid, r in by_service.items() if r.get("manual")}
    for c in items:
        local, others = [], []
        for p in c.get("ports") or []:
            if not isinstance(p, dict) or str(p.get("protocol") or "tcp") != "tcp":
                continue
            host, inner = number(p.get("host_port")), number(p.get("container_port"))
            if not host or not inner:
                continue
            if p.get("scope") == "local" and str(p.get("host_ip") or "") == "127.0.0.1":
                local.append({"host_port": host, "container_port": inner})
            else:
                others.append({"kapsam": str(p.get("scope") or ""), "host_port": host, "container_port": inner})
        app = c.get("uygulama") if c.get("source") == "uygulama" else None
        info = {"ad": c["name"], "kaynak": "uygulama" if app else "dis", "uygulama": app or None,
                "calisiyor": c.get("state") == "running", "yerel_portlar": local, "diger_portlar": others}
        joined = next((sid for sid, r in sorted(manual.items()) if upstream_port(r.get("upstream")) in
                       {x["host_port"] for x in local}), None)
        if joined:
            row = manual.pop(joined)
            out.append(item("konteyner:" + c["name"], "konteyner", c["name"], row, konteyner=info, internet_engel=no_wan))
        else:
            reason = "" if local else "Bu konteynerin yalnız bu sunucuda (127.0.0.1) dinleyen bir portu yok; yayımlanamaz."
            out.append(item("konteyner:" + c["name"], "konteyner", c["name"], None, konteyner=info,
                            yerel_ad=None, kullanilabilir=not reason, neden=reason, internet_engel=no_wan))
    for sid, row in sorted(manual.items()):
        out.append(item("elle:" + sid[len(MANUAL_PREFIX):], "elle", row.get("name") or sid, row, internet_engel=no_wan))
    dav = by_service.get("paylasim")
    if dav:
        out.append(item("paylasim", "paylasim", "WebDAV paylaşımları", dav, giris=GUARD_SHARES, internet_engel=no_wan))
    return out


def plan(env, request, cands, settings_plan):
    """The step of one publication. settings_plan(data) is Manager.plan bound to the operator's address and
    channel."""
    c = next((x for x in cands if x["id"] == request["hedef"]), None)
    require(c is not None, "Yayımlanacak uygulama bulunamadı; sayfayı yenileyin.")
    require(c["kullanilabilir"], c["neden"] or "Bu uygulama şu an yayımlanamaz.")
    tail, internet = request["tailscale"], request["internet"]
    domain = request.get("alan_adi", "").strip().lower()
    steps, warnings = [], []
    if c["servis"]:
        web = {"service": c["servis"], "tail": tail, "enabled": internet, "domain": domain}
        if c["tur"] == "konsol" and request.get("onay"):
            web["confirm"] = request["onay"]
    else:
        box = c["konteyner"]
        local = (request.get("yerel") or default_local(c["ad"])).strip().lower()
        require(bool(PUB_LOCAL_RE.fullmatch(local)), "Tailscale adı küçük harfle başlamalı; yalnız küçük harf, rakam ve tire (en çok 31).")
        name = (request.get("ad") or c["ad"]).strip()
        require(bool(NAME_RE.fullmatch(name)), "Ad 1–40 karakter olmalı.")
        port = box["yerel_portlar"][0]["host_port"]
        web = {"service": MANUAL_PREFIX + local, "tail": tail, "enabled": internet, "domain": domain,
               "elle": {"name": name, "local": local, "upstream": "127.0.0.1:%d" % port}}
    data = {"revision": request["revizyon"], "web": web}
    try:
        settings, engel = settings_plan(copy.deepcopy(data)), ""
    except SettingsError as err:
        settings, engel = None, str(err)
    yerel = "%s.%s" % (web["elle"]["local"] if "elle" in web else (c["yerel_ad"] or "").split(".")[0], env.get("LOCAL_DOMAIN", ""))
    steps.append({"tur": "ayar", "baslik": "Ad ve erişim",
                  "aciklama": "Tailscale adı %s %s; internet adı %s." % (
                      yerel, "açık" if tail else "kapalı", domain if internet and domain else "kapalı"),
                  "istek": data})
    if internet and c["giris"] == GUARD_APP:
        warnings.append({"seviye": "warn", "metin": GUARD_APP})
    if c["konteyner"] and not c["konteyner"]["calisiyor"] and (tail or internet):
        warnings.append({"seviye": "warn", "metin": "Konteyner şu an çalışmıyor; ad açılır ama başlatılana kadar yanıt vermez."})
    if internet and c["internet_engel"] and not engel:
        engel = c["internet_engel"]
    dns = {"ad": domain, "tur": "A", "deger": env.get("WAN_IPV4", "")} if internet and domain else None
    return {"hedef": c, "adimlar": steps, "plan": settings, "engel": engel, "dns": dns, "uyarilar": warnings}
