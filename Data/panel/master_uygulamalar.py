#!/usr/bin/env python3
"""Uygulamalar read model (DD-261): every application in one list.

App Store packages, Konsol's own containers and the built-ins (Files, WebDAV) appear side by side
with their state, a running operation, how they are reached (from the Erişim read model, DD-259),
resource use, image update state, where to open them and the actions they accept. It joins what
the backend already reads (the package list, the container inventory, the Erişim view); it changes
nothing. A source that cannot be read adds a line to "hatalar".

Pages of the current interface are named by their route ("#/torrent") until the new interface has
its own.
"""
import re

CONTAINER_ACTIONS = {"start": "baslat", "stop": "durdur", "restart": "yeniden-baslat", "remove": "kaldir",
                     "image-update": "guncelle"}
UPDATE_STATES = {"guncel": "guncel", "var": "yeni", "denetlenemedi": "denetlenemedi", "sabit": "sabit"}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+$")


def cell(row, scope):
    c = (row or {}).get(scope) or {}
    return {"durum": c.get("durum", "yok"), "adresler": list(c.get("adresler") or []), "uyari": c.get("uyari", ""),
            "not": c.get("not", "")}


def names(addresses):
    """The names among a cell's addresses ("gezgin.ev"), not the raw ports ("100.64.0.2:8091/tcp")."""
    return [a for a in addresses if NAME_RE.match(a)]


def update_state(row):
    """DD-214's cached check. "bilinmiyor": the image can move (it has a channel) but has not been checked
    yet; "sabit": it cannot move."""
    state = ((row or {}).get("update") or {}).get("state")
    if state:
        return UPDATE_STATES.get(state, "sabit")
    return "bilinmiyor" if "image-update" in ((row or {}).get("actions") or []) else "sabit"


def resources(row):
    if not row:
        return {"cpu": None, "bellek": None}
    cpu = row.get("cpu_percent")
    mem = row.get("memory_bytes")
    return {"cpu": float(cpu) if isinstance(cpu, (int, float)) and not isinstance(cpu, bool) else None,
            "bellek": int(mem) if isinstance(mem, int) and not isinstance(mem, bool) else None}


def texts(meta):
    """A package's own stop and removal words from its konsol.json (DD-200), as App Store shows them:
    what removal takes away, the data switch's label, what stays and what goes with it."""
    remove = meta.get("kaldir") if isinstance(meta.get("kaldir"), dict) else {}

    def text(value):
        return value if isinstance(value, str) else ""
    pairs = [[p[0], p[1]] for p in remove.get("neler") or []
             if isinstance(p, list) and len(p) == 2 and all(isinstance(x, str) for x in p)]
    return {"durdur": text(meta.get("durdur_notu")), "kaldir": pairs, "veri_etiket": text(remove.get("veri_etiket")),
            "veri_kalir": text(remove.get("veri_kalir")), "veri_silinir": text(remove.get("veri_silinir"))}


def container_state(row):
    state = (row or {}).get("state", "")
    if state == "running":
        return "calisiyor"
    if state in ("exited", "stopped", "created", "configured"):
        return "durduruldu"
    return "bilinmiyor"


def item(sid, ad, tur, aciklama, **extra):
    base = {"id": sid, "ad": ad, "tur": tur, "aciklama": aciklama, "modul": None, "konteyner": None, "simge": None,
            "durum": "bilinmiyor", "islem": None, "tailscale": cell(None, "tailscale"), "internet": cell(None, "internet"),
            "kaynak": {"cpu": None, "bellek": None}, "guncelleme": "sabit", "adres": {"tailscale": None, "internet": None},
            "sayfa": None, "eylemler": [], "revizyon": None, "metinler": None}
    base.update(extra)
    return base


def addresses(row):
    tail = names(cell(row, "tailscale")["adresler"])
    net = names(cell(row, "internet")["adresler"])
    return {"tailscale": "http://" + tail[0] if tail else None, "internet": "https://" + net[0] if net else None}


def build(modules, containers, erisim, now, errors=()):
    """modules: Panel.modules() items or None; containers: Inventory.liste() or None; erisim: the Erişim
    read model or None."""
    errors = list(errors)
    rows = {r["id"]: r for r in (erisim or {}).get("hizmetler") or [] if isinstance(r, dict) and r.get("id")}
    found = [c for c in (containers or {}).get("containers") or [] if isinstance(c, dict) and c.get("name")]
    by_module = {c["module_id"]: c for c in found if c.get("module_id")}
    items, catalogue = [], []

    for m in modules or []:
        meta = m.get("konsol") if isinstance(m.get("konsol"), dict) else {}
        name = str(meta.get("ad") or m["id"])
        if not m.get("installed"):
            catalogue.append({"id": m["id"], "ad": name, "aciklama": str(meta.get("alt") or ""), "simge": meta.get("simge")})
            continue
        row = rows.get("paket:" + m["id"])
        box = by_module.get(m["id"])
        if m.get("busy"):
            state = "islemde"
        elif m.get("state") == "durduruldu":
            state = "durduruldu"
        elif m.get("live") == "exited":
            state = "hata"
        else:
            state = "calisiyor"
        progress = m.get("progress") if m.get("busy") else None
        actions = ["durdur", "yeniden-baslat"] if state == "calisiyor" and m.get("durdurulabilir") else []
        if state == "durduruldu":
            actions = ["baslat"]
        if box and update_state(box) == "yeni" and "image-update" in (box.get("actions") or []):
            actions.append("guncelle")
        actions.append("kaldir")
        page = (meta.get("sayfa") or {}).get("rota") if isinstance(meta.get("sayfa"), dict) else None
        urls = m.get("urls") if isinstance(m.get("urls"), dict) else {}
        adres = addresses(row)
        adres = {"tailscale": urls.get("tailscale") or adres["tailscale"], "internet": urls.get("internet") or adres["internet"]}
        items.append(item("paket:" + m["id"], name, "paket", str(meta.get("alt") or ""), modul=m["id"],
                          konteyner=box["name"] if box else None, simge=meta.get("simge"), durum=state,
                          islem={"eylem": str(progress.get("action", "")), "adim": str(progress.get("step", "")),
                                 "metin": str(progress.get("text", ""))} if isinstance(progress, dict) else None,
                          tailscale=cell(row, "tailscale"), internet=cell(row, "internet"), kaynak=resources(box),
                          guncelleme=update_state(box) if box else "sabit", adres=adres,
                          sayfa="#/" + page if isinstance(page, str) and re.fullmatch(r"[a-z]{2,16}", page) else None,
                          eylemler=actions if state != "islemde" else [], revizyon=(box or {}).get("revision"),
                          metinler=texts(meta)))

    for box in found:
        if box.get("module_id") or box.get("source") == "appstore":
            continue
        row = rows.get("konteyner:" + box["name"])
        image = str(box.get("image") or "").split("@")[0]
        state = "islemde" if box.get("busy") else container_state(box)
        own = box.get("source") == "konsol"
        actions = [CONTAINER_ACTIONS[a] for a in box.get("actions") or [] if a in CONTAINER_ACTIONS]
        if "guncelle" in actions and update_state(box) != "yeni":
            actions.remove("guncelle")
        items.append(item("konteyner:" + box["name"], box["name"], "konteyner",
                          ("Konteyner · %s" % image) if own else "Konsol dışında yönetilen konteyner · %s" % image,
                          konteyner=box["name"], durum=state, tailscale=cell(row, "tailscale"), internet=cell(row, "internet"),
                          kaynak=resources(box), guncelleme=update_state(box), adres=addresses(row),
                          sayfa="#/konteynerler/" + box["name"], eylemler=actions if state != "islemde" else [],
                          revizyon=box.get("revision")))

    share = rows.get("paylasim")
    items.append(item("yerlesik:dosya", "Dosyalar", "yerlesik", "Dosya yöneticisi · yerleşik", durum="calisiyor",
                      sayfa="#/dosyalar"))
    items.append(item("yerlesik:paylasim", "Paylaşımlar", "yerlesik",
                      "WebDAV · yerleşik" + (" · %s" % share["aciklama"].split("·", 1)[1].strip() if share and "·" in share.get("aciklama", "") else ""),
                      durum="calisiyor" if (share or {}).get("calisiyor") else "durduruldu" if share else "bilinmiyor",
                      tailscale=cell(share, "tailscale"), internet=cell(share, "internet"), sayfa="#/dosyalar/paylasim"))

    runtime = (containers or {}).get("runtime") or {}
    if containers is not None and not runtime.get("ok", True):
        errors.append(str(runtime.get("error") or "Podman kullanılamıyor."))
    images = [i for i in (containers or {}).get("images") or [] if isinstance(i, dict)]
    return {
        "read_at": int(now),
        "items": items,
        "katalog": catalogue,
        "altyapi": {"podman": str(runtime.get("version") or ""), "calisiyor": bool(runtime.get("ok")),
                    "imaj": len({i.get("id") or i.get("name") for i in images}),
                    "kullanilmayan_imaj": len({i.get("id") or i.get("name") for i in images if not i.get("used_by")}),
                    "birim": len((containers or {}).get("volumes") or []), "ag": len((containers or {}).get("networks") or [])},
        "hatalar": errors,
    }
