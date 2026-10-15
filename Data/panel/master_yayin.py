#!/usr/bin/env python3
"""Yayınla (DD-265): what can be published, and the plan of one publication.

A publication is one row of the Caddy publication table (DD-191/195/199/252): a Tailscale name
(<ad>.<alan>) and an optional internet (HTTPS) name. candidates() lists every row and every Konsol
container that could have one; plan() turns the four decisions of the Yayınla flow (what, who, which
name, plan) into the requests the page then sends to the existing write routes:

- a Konsol container that listens on no loopback port first gets one, through the container save
  job (DD-211), with a free port from YAYIN_PORT_ILK–YAYIN_PORT_SON;
- then the publication row, through the settings transaction (master_settings.plan/apply).

The two cannot be one transaction (separate locks, rollbacks and revisions), so they run in order;
when the second fails, the loopback port stays and is harmless. This module changes nothing: the
settings plan is the same dry run apply validates with (DD-265), and its failure is the plan's
"engel".
"""
import copy
import re
import socket

from master_settings import SettingsError, require

PUB_LOCAL_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
NAME_RE = re.compile(r"^[^\x00-\x1f]{1,40}$")
MANUAL_PREFIX = "elle-"
GUARD_KONSOL = "İnternetten Konsol hesabıyla giriş istenir."
GUARD_SHARES = "Klasör hesapları korur; her klasörün internet erişimi Paylaşımlar'dan açılır."
GUARD_APP = "Yalnız uygulamanın kendi girişi korur; Konsol bu adreste giriş denetlemez."


def guard_checked(name):
    return "%s'in kendi girişi korur; Konsol açmadan önce girişin açık olduğunu denetler." % name


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


def candidates(env, rows, packages, containers, wan_ready=True):
    """rows: master_publications.status(); packages: master_publications.packages(); containers:
    Inventory.reach() or None; wan_ready: the server has an assigned public IPv4."""
    by_service = {r["service"]: r for r in rows if isinstance(r, dict) and r.get("service")}
    no_wan = "" if wan_ready else "Sunucunun internet IPv4 adresi kullanılamıyor; internet adı açılamaz."
    out = []
    panel = by_service.get("panel")
    if panel:
        out.append(item("panel", "konsol", "Konsol", panel, giris=GUARD_KONSOL, onay_kelimesi=True, internet_engel=no_wan or (
            "" if panel.get("account") else "Önce Konsol hesabı oluşturun (Tailscale adresinden, Sistem → Hesap).")))
    for mid, info in packages.items():
        row = by_service.get(mid)
        if not row or not row.get("installed"):
            continue
        reason = "" if row.get("running") else "%s durdurulmuş; önce başlatın." % info["name"]
        out.append(item("paket:" + mid, "paket", info["name"], dict(row, upstream=info.get("upstream")),
                        giris=guard_checked(info["name"]) if info.get("check") else GUARD_APP,
                        internet_engel=no_wan or reason))
    items = [c for c in ((containers or {}).get("containers") or []) if isinstance(c, dict) and c.get("name")]
    manual = {sid: r for sid, r in by_service.items() if r.get("manual")}
    for c in items:
        if c.get("module_id"):
            continue
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
        own = c.get("source") == "konsol"
        info = {"ad": c["name"], "kaynak": "konsol" if own else "dis", "calisiyor": c.get("state") == "running",
                "yerel_portlar": local, "diger_portlar": others, "port_eklenebilir": own,
                "onerilen_port": (others[0]["container_port"] if others else local[0]["container_port"] if local else None)}
        joined = next((sid for sid, r in sorted(manual.items()) if upstream_port(r.get("upstream")) in
                       {x["host_port"] for x in local}), None)
        if joined:
            row = manual.pop(joined)
            out.append(item("konteyner:" + c["name"], "konteyner", c["name"], row, konteyner=info, internet_engel=no_wan))
        else:
            reason = "" if local or own else ("Konsol dışında yönetilen bu konteynerin yalnız bu sunucuda dinleyen portu yok; "
                                              "önce Podman sayfasından sahiplenin.")
            out.append(item("konteyner:" + c["name"], "konteyner", c["name"], None, konteyner=info,
                            yerel_ad=None, kullanilabilir=not reason, neden=reason, internet_engel=no_wan))
    for sid, row in sorted(manual.items()):
        out.append(item("elle:" + sid[len(MANUAL_PREFIX):], "elle", row.get("name") or sid, row, internet_engel=no_wan))
    dav = by_service.get("paylasim")
    if dav:
        out.append(item("paylasim", "paylasim", "WebDAV paylaşımları", dav, giris=GUARD_SHARES, internet_engel=no_wan))
    return out


def free_port(env, used, bind=None):
    """The first loopback port in YAYIN_PORT_ILK–YAYIN_PORT_SON that no definition, publication or
    listener uses. bind(port) -> bool tests that nothing holds it now (a bound socket is closed at once)."""
    def bindable(port):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return True
            except OSError:
                return False
    bind = bind or bindable
    try:
        first, last = int(env.get("YAYIN_PORT_ILK", "")), int(env.get("YAYIN_PORT_SON", ""))
    except ValueError:
        raise SettingsError("Yerel port aralığı tanımlı değil; kurulumu yeniden çalıştırın.")
    require(0 < first <= last < 65536, "Yerel port aralığı geçersiz; kurulumu yeniden çalıştırın.")
    for port in range(first, last + 1):
        if port not in used and bind(port):
            return port
    raise SettingsError("Yerel port aralığında boş port kalmadı.")


def plan(env, request, cands, settings_plan, container_detail, pick_port):
    """The steps of one publication. settings_plan(data) is Manager.plan bound to the operator's
    address and channel; container_detail(name) the container's detail row (config, revision);
    pick_port() a free loopback port."""
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
        if box["yerel_portlar"]:
            port = box["yerel_portlar"][0]["host_port"]
        else:
            inner = request.get("konteyner_portu") or box["onerilen_port"]
            require(bool(number(inner)), "Uygulamanın konteyner içinde dinlediği portu yazın (ör. 8080).")
            row = container_detail(box["ad"])
            config = copy.deepcopy(row.get("config") or {})
            require(bool(config) and "save" in (row.get("actions") or []), "Bu konteynerin ayarları buradan değiştirilemez; Podman sayfasından bakın.")
            require(config.get("network") != "none", "Ağsız bir konteyner port yayımlayamaz; önce Podman sayfasından bir ağ seçin.")
            port = pick_port()
            config["ports"] = list(config.get("ports") or []) + [
                {"scope": "local", "host_port": port, "container_port": inner, "protocol": "tcp", "public_ack": False}]
            steps.append({"tur": "konteyner", "baslik": "Konteynere yalnız bu sunucuda dinleyen port",
                          "aciklama": "127.0.0.1:%d → konteynerde %d/tcp. Konteyner yeniden oluşturulur; kısa bir kesinti olur." % (port, inner),
                          "istek": {"action": "save", "name": box["ad"], "revision": row.get("revision") or "", "config": config}})
            warnings.append({"seviye": "info", "metin": "İki adım sırayla uygulanır. İkincisi başarısız olursa eklenen port yalnız bu "
                             "sunucuda dinler ve zararsız olarak kalır."})
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
