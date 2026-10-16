#!/usr/bin/env python3
"""Uygulamalar read model (DD-261): every application in one list.

Until the application engine (DD-271, phase 3) the applications are Konsol's containers: each with its
state, how it is reached (from the Erişim read model, DD-259), resource use, image update state, where
to open it and the actions it accepts. It joins what the backend already reads (the container
inventory, the Erişim view); it changes nothing. A source that cannot be read adds a line to "hatalar".
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
    """The names among a cell's addresses ("notlar.ev"), not the raw ports ("100.64.0.2:8091/tcp")."""
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


def container_state(row):
    state = (row or {}).get("state", "")
    if state == "running":
        return "calisiyor"
    if state in ("exited", "stopped", "created", "configured"):
        return "durduruldu"
    return "bilinmiyor"


def addresses(row):
    tail = names(cell(row, "tailscale")["adresler"])
    net = names(cell(row, "internet")["adresler"])
    return {"tailscale": "http://" + tail[0] if tail else None, "internet": "https://" + net[0] if net else None}


def build(containers, erisim, now, errors=()):
    """containers: Inventory.liste() or None; erisim: the Erişim read model or None."""
    errors = list(errors)
    rows = {r["id"]: r for r in (erisim or {}).get("hizmetler") or [] if isinstance(r, dict) and r.get("id")}
    found = [c for c in (containers or {}).get("containers") or [] if isinstance(c, dict) and c.get("name")]
    items = []
    for box in found:
        row = rows.get("konteyner:" + box["name"])
        image = str(box.get("image") or "").split("@")[0]
        state = "islemde" if box.get("busy") else container_state(box)
        own = box.get("source") == "konsol"
        actions = [CONTAINER_ACTIONS[a] for a in box.get("actions") or [] if a in CONTAINER_ACTIONS]
        if "guncelle" in actions and update_state(box) != "yeni":
            actions.remove("guncelle")
        items.append({"id": "konteyner:" + box["name"], "ad": box["name"], "tur": "konteyner",
                      "aciklama": ("Konteyner · %s" % image) if own else "Konsol dışında yönetilen konteyner · %s" % image,
                      "konteyner": box["name"], "durum": state, "tailscale": cell(row, "tailscale"),
                      "internet": cell(row, "internet"), "kaynak": resources(box), "guncelleme": update_state(box),
                      "adres": addresses(row), "eylemler": actions if state != "islemde" else [],
                      "revizyon": box.get("revision")})

    runtime = (containers or {}).get("runtime") or {}
    if containers is not None and not runtime.get("ok", True):
        errors.append(str(runtime.get("error") or "Podman kullanılamıyor."))
    images = [i for i in (containers or {}).get("images") or [] if isinstance(i, dict)]
    return {
        "read_at": int(now),
        "items": items,
        "altyapi": {"podman": str(runtime.get("version") or ""), "calisiyor": bool(runtime.get("ok")),
                    "imaj": len({i.get("id") or i.get("name") for i in images}),
                    "kullanilmayan_imaj": len({i.get("id") or i.get("name") for i in images if not i.get("used_by")}),
                    "birim": len((containers or {}).get("volumes") or []), "ag": len((containers or {}).get("networks") or [])},
        "hatalar": errors,
    }
