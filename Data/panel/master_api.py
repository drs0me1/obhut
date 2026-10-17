#!/usr/bin/env python3
"""Konsol's API description (DD-259): Konsol's routes and the shape of each reply.

The root backend dispatches these routes from this table. Tests check real replies against the
shapes, and generate from them the OpenAPI description (docs/konsol-api.json) and the interface's
TypeScript types (tools/konsol-ui/src/api/sema.ts); a committed copy that differs fails the tests.

    python3 panel/master_api.py openapi > docs/konsol-api.json
    python3 panel/master_api.py ts > tools/konsol-ui/src/api/sema.ts

Outside the table the backend answers only the session check Caddy asks (/oturum-denetle) and the
sign-in page's POST /api/konsol/oturum/giris. A path segment written {name} is a parameter whose
shape is in PATH_PARAMS (the WireGuard routes name a network and a device that way).
Python standard library only.
"""
import json
import re
import sys
import urllib.parse

STR = {"type": "string"}
INT = {"type": "integer"}
NUM = {"type": "number"}
BOOL = {"type": "boolean"}


def obj(props, optional=()):
    return {"type": "object", "properties": props, "required": [k for k in props if k not in optional],
            "additionalProperties": False}


def open_obj(props):
    """An object whose listed fields are all optional and which may carry others: the shell reads what
    it knows and checks it at run time."""
    return {"type": "object", "properties": props, "required": [], "additionalProperties": True}


def arr(item):
    return {"type": "array", "items": item}


def map_of(item):
    """An object whose keys are free (a question id, a label) and whose values all have one shape."""
    return {"type": "object", "properties": {}, "required": [], "additionalProperties": item}


def one_of(*schemas):
    return {"anyOf": list(schemas)}


def null(schema):
    return {"anyOf": [schema, {"type": "null"}]}


def enum(*values):
    return {"type": "string", "enum": list(values)}


def ref(name):
    return {"$ref": "#/components/schemas/" + name}


SCHEMAS = {
    "Hata": obj({"error": STR, "giris": BOOL}, optional=("giris",)),
    "Kaynaklar": obj({
        "host": STR, "version": STR, "surum": STR, "domain": STR, "os": STR, "kernel": STR, "uptime": INT, "cores": INT,
        "read_at": INT, "sampled_at": null(INT), "cpu": null(NUM),
        "mem": obj({"total": INT, "used": INT}),
        "net": obj({"wan": STR, "wan6": STR, "iface": STR, "tailscale": STR, "tailscale6": STR}),
        "root": STR, "disk": null(obj({"total": INT, "free": INT})),
    }),
    "SaglikDurumu": enum("ok", "warn", "bad"),
    "Saglik": obj({"status": ref("SaglikDurumu"),
                   "checks": arr(obj({"id": STR, "name": STR, "status": ref("SaglikDurumu"), "detail": STR})),
                   "read_at": INT}),
    "Islem": obj({"tur": enum("konteyner", "guncelleme", "onarim"), "id": STR, "ad": STR,
                  "durum": enum("calisiyor", "tamam", "hata"), "adim": STR, "bitis": null(INT)}),
    "Islemler": obj({"items": arr(ref("Islem"))}),
    "BekleyenDegisiklik": obj({"id": STR, "phase": enum("applying", "awaiting", "committed", "rollback", "stuck"),
                               "seconds": INT, "attempts": INT, "error": STR, "retry_in": INT,
                               "domain": obj({"old": STR, "new": STR}), "web": BOOL},
                              optional=("attempts", "error", "retry_in", "domain", "web")),
    "Bekleyen": obj({"bekleyen": null(ref("BekleyenDegisiklik"))}),
    "Kapat": obj({"neden": enum("sure", "oturum")}),
    "ErisimDurumu": enum("acik", "kismen", "kapali", "yok", "hata"),
    "ErisimHucresi": obj({"durum": ref("ErisimDurumu"), "adresler": arr(STR), "not": STR, "uyari": STR}),
    "Hizmet": obj({
        "id": STR, "ad": STR, "tur": enum("konsol", "konteyner", "elle", "paylasim", "sistem", "vpn", "kural"),
        "aciklama": STR, "uygulama": null(STR), "calisiyor": null(BOOL),
        "yerel": ref("ErisimHucresi"), "tailscale": ref("ErisimHucresi"), "wireguard": ref("ErisimHucresi"),
        "internet": ref("ErisimHucresi"), "yayinlar": arr(STR), "ayrinti": arr(obj({"baslik": STR, "deger": STR})),
    }),
    # DD-265: the row a warning is about (its id; "" when none) and where it is fixed.
    "Uyari": obj({"seviye": enum("warn", "bad"), "hizmet": STR, "metin": STR,
                  "duzelt": null(obj({"bolum": enum("yayinlar", "uygulama", "tailscale"), "hedef": STR}))}),
    "UygulamaHucresi": obj({"durum": ref("ErisimDurumu"), "adresler": arr(STR), "uyari": STR, "not": STR}),
    # DD-271 (phase 1): Konsol's containers only, until the application engine replaces them (phase 3).
    "Uygulama": obj({
        "id": STR, "ad": STR, "tur": enum("konteyner"), "aciklama": STR, "konteyner": STR,
        "durum": enum("calisiyor", "durduruldu", "islemde", "hata", "bilinmiyor"),
        "tailscale": ref("UygulamaHucresi"), "internet": ref("UygulamaHucresi"),
        "kaynak": obj({"cpu": null(NUM), "bellek": null(INT)}),
        "guncelleme": enum("guncel", "yeni", "denetlenemedi", "bilinmiyor", "sabit"),
        "adres": obj({"tailscale": null(STR), "internet": null(STR)}),
        "eylemler": arr(enum("baslat", "durdur", "yeniden-baslat", "kaldir", "guncelle")), "revizyon": null(STR),
    }),
    "UygulamaAyrinti": obj({
        "uygulama": ref("Uygulama"),
        "konteyner": null(obj({
            "imaj": STR, "ag": STR, "kullanici": STR, "baslangic": null(INT), "saglik": STR, "yeniden_baslama": INT,
            "portlar": arr(obj({"host_ip": STR, "host_port": INT, "container_port": INT, "protocol": STR, "scope": STR})),
            "baglamalar": arr(obj({"tur": STR, "kaynak": STR, "hedef": STR, "yazilabilir": BOOL, "ad": STR})),
        })),
        "erisim": null(ref("Hizmet")),
    }),
    "UygulamaGunlugu": obj({"satirlar": arr(STR), "kesik": BOOL}),
    "UygulamaIslemi": obj({"id": STR, "eylem": enum("baslat", "durdur", "yeniden-baslat", "guncelle", "kaldir"),
                           "revizyon": STR}, optional=("revizyon",)),
    "UygulamaIslemiBasladi": obj({"id": STR, "eylem": STR, "is": null(STR)}),
    "Ag": obj({"read_at": INT, "sampled_at": null(INT), "rx": null(INT), "tx": null(INT)}),
    "OnarimAdimi": obj({"id": STR, "ad": STR, "durum": enum("ok", "onarildi", "sorun", "hata", "atlandi", "calisiyor"),
                        "detay": STR}),
    "Onarim": obj({"calisiyor": BOOL, "kurulu": BOOL, "baslatilabilir": BOOL,
                   "rapor": null(obj({"durum": enum("calisiyor", "tamam", "hata"), "kip": enum("onar", "denetle"), "kaynak": STR,
                                      "baslangic": INT, "bitis": null(INT), "adimlar": arr(ref("OnarimAdimi")), "yarida": BOOL},
                                     optional=("yarida",)))}),
    "OnarimIstegi": obj({"kip": enum("onar", "denetle")}, optional=("kip",)),
    "OnarimBasladi": obj({"kip": STR}),
    "Uygulamalar": obj({
        "read_at": INT, "items": arr(ref("Uygulama")),
        "altyapi": obj({"podman": STR, "calisiyor": BOOL, "imaj": INT, "kullanilmayan_imaj": INT, "birim": INT, "ag": INT}),
        "hatalar": arr(STR),
    }),
    "GuncellemeIsi": obj({"durum": enum("yok", "calisiyor", "tamam", "hata"), "hedef": STR, "mesaj": STR,
                          "bitis": null(INT), "asama": STR}),
    "Guncelleme": obj({"kurulu": STR, "kurulu_surum": STR, "son": null(STR), "son_surum": null(STR), "commit": null(STR),
                       "yeni": BOOL, "denetlendi": null(INT),
                       "hata": STR, "is": ref("GuncellemeIsi"), "baslatilabilir": BOOL}),
    "Erisim": obj({
        "read_at": INT, "alan": STR,
        "ozet": obj({
            "tailscale": obj({"ipv4": STR, "ipv6": STR, "durum": enum("bagli", "bagli-degil", "bilinmiyor"),
                              "anahtar_bitis": null(INT), "ad": STR, "surum": STR, "adresler": arr(STR),
                              "cikis_dugumu": null(BOOL)}),
            "internet": obj({"ipv4": STR, "ipv6": STR,
                             "acik": arr(obj({"ad": STR, "port": INT, "proto": STR, "aileler": arr(INT),
                                              "kaynak": enum("temel", "kural")}))}),
            # kurulu: WireGuard has a network; durduruldu: it is stopped as a whole (its networks are then not listed).
            "wireguard": obj({"kurulu": BOOL, "durduruldu": BOOL, "not": STR,
                              "aglar": arr(obj({"arayuz": STR, "ad": STR, "etkin": BOOL, "port": INT}))}),
            "sertifikalar": arr(obj({"ad": STR, "hizmet": STR, "durum": enum("gecerli", "hazir-degil"), "bitis": null(INT)})),
        }),
        "hizmetler": arr(ref("Hizmet")), "uyarilar": arr(ref("Uyari")), "hatalar": arr(STR),
    }),
    # DD-265: the settings transaction's dry run, and its writes declared in the table.
    "KuralTaslagi": obj({"id": STR, "name": STR, "family": INT, "scope": enum("wan", "tail"), "proto": enum("tcp", "udp"),
                         "port": INT, "source": STR, "allow": BOOL}),
    "DnsKaydi": obj({"name": STR, "target": STR, "enabled": BOOL}),
    "DnsTaslagi": obj({"disabled": arr(STR), "records": arr(ref("DnsKaydi")), "forward": BOOL, "servers": arr(STR)}),
    "YayinSatiri": open_obj({"service": STR, "tail": BOOL, "enabled": BOOL, "domain": STR, "confirm": STR, "sil": BOOL,
                             "elle": obj({"name": STR, "local": STR, "upstream": STR})}),
    "AyarIstegi": open_obj({"revision": STR, "firewall": arr(ref("KuralTaslagi")), "dns": ref("DnsTaslagi"),
                            "domain": STR, "web": ref("YayinSatiri")}),
    "PlanDegisikligi": obj({"alan": enum("guvenlik-duvari", "dns", "alan-adi", "yayin"),
                            "islem": enum("ekle", "kaldir", "degistir", "ac", "kapat"), "nesne": STR,
                            "once": null(STR), "sonra": null(STR)}),
    "PlanUyarisi": obj({"seviye": enum("info", "warn", "bad"), "metin": STR}),
    "AyarPlani": obj({"revizyon": STR, "onay_sn": INT, "degisiklikler": arr(ref("PlanDegisikligi")), "etkiler": arr(STR),
                      "uyarilar": arr(ref("PlanUyarisi")), "uygulanabilir": BOOL}),
    "AyarSonucu": obj({"pending": null(ref("BekleyenDegisiklik")), "committed": BOOL}, optional=("committed",)),
    "IslemKimligi": open_obj({"id": STR, "confirm": STR}),
    "Tamam": open_obj({"ok": BOOL}),
    "GuvenlikDuvari": obj({
        "revizyon": STR, "denetim": obj({"ok": BOOL, "metin": STR}), "kurallar": arr(ref("KuralTaslagi")),
        "portlar": arr(obj({"ad": STR, "aile": INT, "proto": STR, "port": INT, "kapsam": enum("wan", "tail", "lo"), "sabit": BOOL})),
        "dinleyiciler": null(arr(obj({"proto": STR, "aile": INT, "port": INT, "adres": STR, "kapsam": STR}))),
        "teknik": arr(obj({"aile": INT, "tablo": STR, "zincir": STR, "sira": STR, "paket": INT, "bayt": INT,
                           "kural": STR, "sahip": STR})),
        "aglar": arr(obj({"arayuz": STR, "ad": STR, "etkin": BOOL})), "hatalar": arr(STR),
    }),
    "Adlar": obj({
        "revizyon": STR, "alan": STR,
        "adlar": arr(obj({"ad": STR, "aile": null(INT), "hedef": STR, "kaynak": STR, "kapali": BOOL, "kilitli": BOOL})),
        "kayitlar": arr(ref("DnsKaydi")), "yonlendirme": BOOL, "sunucular": arr(STR), "hatalar": arr(STR),
    }),
    # DD-265: the Yayınla flow.
    "YayinAdayi": obj({
        "id": STR, "tur": enum("konsol", "konteyner", "elle", "paylasim"), "ad": STR, "servis": null(STR),
        "yerel_ad": null(STR), "tailscale": BOOL, "internet": BOOL, "alan_adi": STR, "durum": STR, "mesaj": STR,
        "bitis": null(INT), "hedef": null(STR), "giris": STR, "onay_kelimesi": BOOL, "internet_engel": STR,
        "kullanilabilir": BOOL, "neden": STR,
        "konteyner": null(obj({"ad": STR, "kaynak": enum("konsol", "dis"), "calisiyor": BOOL,
                               "yerel_portlar": arr(obj({"host_port": INT, "container_port": INT})),
                               "diger_portlar": arr(obj({"kapsam": STR, "host_port": INT, "container_port": INT})),
                               "port_eklenebilir": BOOL, "onerilen_port": null(INT)})),
    }),
    "Yayinlar": obj({"revizyon": STR, "alan": STR, "wan_ipv4": STR, "adaylar": arr(ref("YayinAdayi")), "hatalar": arr(STR)}),
    "YayinIstegi": obj({"hedef": STR, "revizyon": STR, "tailscale": BOOL, "internet": BOOL, "alan_adi": STR,
                        "ad": STR, "yerel": STR, "konteyner_portu": INT, "onay": STR},
                       optional=("ad", "yerel", "konteyner_portu", "onay")),
    "YayinAdimi": obj({"tur": enum("konteyner", "ayar"), "baslik": STR, "aciklama": STR, "istek": open_obj({})}),
    "YayinPlani": obj({"hedef": ref("YayinAdayi"), "adimlar": arr(ref("YayinAdimi")), "plan": null(ref("AyarPlani")),
                       "engel": STR, "dns": null(obj({"ad": STR, "tur": STR, "deger": STR})),
                       "uyarilar": arr(ref("PlanUyarisi"))}),
    # Container requests (DD-211): a revision may be null, an image action names the image.
    "KonteynerIstegi": open_obj({"action": STR, "name": STR, "image": STR, "revision": null(STR), "config": open_obj({})}),
    "KonteynerIsi": open_obj({"id": STR, "action": STR, "name": STR, "state": STR, "step": STR}),
    # DD-266 (phase 4a): the Podman reads, moved into the table unchanged (docs/design/container-manager-api.md).
    # Rows stay open objects: the list and the detail share them and add fields of their own.
    "KonteynerPortu": open_obj({"host_ip": STR, "host_port": INT, "container_port": INT, "protocol": STR, "scope": STR}),
    "KonteynerGuncellemesi": open_obj({"state": STR, "channel": STR, "error": STR, "checked_at": INT}),
    "KonteynerSatiri": open_obj({
        "id": STR, "name": STR, "image": STR, "state": STR, "status": STR, "unit": STR, "network": STR,
        "ports": arr(ref("KonteynerPortu")), "created": null(INT), "started": null(INT), "exit_code": INT, "restarts": INT,
        "health": STR, "live": BOOL, "source": enum("konsol", "external"), "management_id": STR,
        "revision": null(STR), "actions": arr(STR), "restricted_reason": STR,
        "cpu_percent": null(NUM), "memory_bytes": null(INT), "busy": null(STR),
        "listening": null(arr(obj({"address": STR, "port": INT, "protocol": STR, "scope": STR}))),
        "update": null(ref("KonteynerGuncellemesi")),
    }),
    "KonteynerListesi": open_obj({
        "read_at": INT, "runtime": obj({"version": STR, "ok": BOOL, "error": STR}),
        "containers": arr(ref("KonteynerSatiri")),
        "images": arr(open_obj({"id": STR, "name": STR, "size": null(INT), "created": null(INT), "used_by": arr(STR),
                                "managed": BOOL})),
        "volumes": arr(open_obj({"name": STR, "driver": STR, "size": null(INT), "used_by": arr(STR), "managed": BOOL})),
        "networks": arr(open_obj({"name": STR, "id": STR, "driver": STR, "subnets": arr(STR), "used_by": arr(STR),
                                  "managed": BOOL, "internal": BOOL})),
        "storage": open_obj({"images": INT, "containers": INT, "size": null(INT)}),
        "resource_errors": open_obj({}),
    }),
    # The detail is a row with its mounts, config, editable fields and effective start (the editor's input).
    "KonteynerAyrintisi": open_obj({
        "name": STR, "state": STR, "image": STR, "revision": null(STR), "actions": arr(STR),
        "mounts": arr(open_obj({"type": STR, "source": STR, "destination": STR, "rw": BOOL, "name": STR})),
        "config": open_obj({}), "editable": arr(STR), "protected_mounts": arr(STR), "effective_autostart": BOOL,
        "user": STR, "command": STR,
    }),
    "KonteynerGuncellemeleri": obj({"checked_at": INT, "items": open_obj({}), "cached": BOOL}),
    # DD-266: Sistem.
    "Oturum": obj({"durum": enum("kurulum", "acik", "giris"), "kullanici": STR, "oturum_gun": INT,
                   "kanal": enum("yerel", "tailscale", "internet")}, optional=("kullanici", "oturum_gun")),
    "HesapKur": obj({"kullanici": STR, "parola": STR}),
    "ParolaDegistir": obj({"eski": STR, "yeni": STR}, optional=("eski",)),
    "HesapSonucu": obj({"durum": enum("kuruldu", "degisti", "cikis")}),
    "Bos": obj({}),
    "YenidenBaslatma": obj({"sure": INT}),
    "GuncellemeIstegi": obj({"surum": STR, "commit": STR}),
    "GuncellemeBasladi": obj({"surum": STR}),
    "KayitSatiri": obj({"at": INT, "source": STR, "user": STR, "client": STR, "action": STR, "detail": STR, "ok": BOOL}),
    "Kayitlar": obj({"items": arr(ref("KayitSatiri"))}),
    "Klasorler": obj({"items": arr(obj({"path": STR, "free": INT}))}),
    # DD-267 (phase 4b): Dosyalar → Paylaşımlar (DD-158/179/190/192), the share manager's own view and requests.
    "PaylasimBaglantisi": obj({"enabled": BOOL, "permission": enum("ro", "rw"), "expires": null(NUM), "expired": BOOL,
                               "available": BOOL, "active": BOOL, "reason": STR, "url": STR}),
    "Paylasim": obj({"id": STR, "path": STR, "name": STR, "username": STR, "created": null(NUM), "changed": null(NUM),
                     "type": STR, "available": BOOL,
                     "connections": obj({"tailscale": ref("PaylasimBaglantisi"), "wan": ref("PaylasimBaglantisi")},
                                        optional=("tailscale", "wan")),
                     "urls": open_obj({"tailscale": STR, "wan": STR}), "url": STR}),
    "Paylasimlar": obj({"host": STR, "items": arr(ref("Paylasim")), "max": INT,
                        "wan": open_obj({"available": BOOL, "address": STR, "reason": STR, "mode": STR, "domain": STR, "port": INT}),
                        "tail_enabled": BOOL, "limits": open_obj({})}),
    # The manager checks a save itself (allowed fields, connections, acknowledgements); the table keeps it open.
    "PaylasimKaydi": open_obj({"id": STR, "path": STR, "username": STR, "password": STR, "connections": open_obj({}),
                               "ack_wan_http": BOOL}),
    "PaylasimKimligi": obj({"id": STR}),
    # DD-267: who uses which server folder (Dosyalar → Depolama), joined with the files backend's folders.
    "Depolama": obj({"read_at": INT, "kok": STR,
                     "kullananlar": arr(obj({"yol": STR, "id": STR, "ad": STR, "tur": enum("konteyner", "paylasim"),
                                             "hedef": STR, "yazilabilir": BOOL})),
                     "hatalar": arr(STR)}),
    # DD-266: Gelişmiş, the effective configuration as the server holds it (read-only).
    "YapilandirmaDosyasi": obj({"file": STR, "text": STR}),
    "Gelismis": obj({
        "read_at": INT,
        "caddy": obj({"entries": arr(obj({"address": STR, "source": STR,
                                          "routes": arr(obj({"path": STR, "kind": enum("proxy", "files", "respond", "redirect"),
                                                             "to": STR})),
                                          "access": enum("tailscale", "wan"), "scheme": STR})),
                      "raw": arr(ref("YapilandirmaDosyasi"))}),
        "dnsmasq": obj({"listen": arr(STR), "domains": arr(STR), "dhcp": BOOL,
                        "names": arr(open_obj({"name": STR, "iface": STR, "family": null(INT), "address": STR, "source": STR})),
                        "raw": arr(ref("YapilandirmaDosyasi"))}),
    }),
    # DD-271: WireGuard, a built-in (DD-133, DD-136, DD-137, DD-143, DD-229). Every change goes through master-wg.
    "WireGuardCihazi": obj({
        "name": STR, "ipv4": STR, "ipv6": STR, "handshake": INT, "rx": INT, "tx": INT, "profile": BOOL, "dns": STR,
        "provider": STR, "keepalive": INT, "mtu": INT, "enabled": BOOL, "online": BOOL, "active_at": null(INT),
    }),
    # revision guards the network's settings (a stale one is refused with 409).
    "WireGuardAgi": obj({
        "iface": STR, "port": INT, "server4": STR, "subnet4": STR, "server6": STR, "subnet6": STR, "dns": STR, "label": STR,
        "active": BOOL, "count": INT, "revision": STR, "peers": arr(ref("WireGuardCihazi")),
    }),
    # kurulu: master-wg works; durduruldu: WireGuard is stopped as a whole; max: how many networks there may be;
    # reserved: UDP ports a new network may not take.
    "WireGuard": obj({
        "kurulu": BOOL, "durduruldu": BOOL, "endpoint": STR, "max": INT, "reserved": arr(INT),
        "defaults": obj({"dns": STR, "keepalive": INT, "mtu": INT, "port": INT}),
        "now": INT, "active_window": INT, "networks": arr(ref("WireGuardAgi")),
    }),
    "WireGuardCalismasi": obj({"durduruldu": BOOL}),
    "WireGuardAgIstegi": obj({"port": INT, "dns": STR, "label": STR}, optional=("label",)),
    "WireGuardAgEklendi": obj({"iface": STR, "port": INT}),
    "WireGuardAgKaldirildi": obj({"iface": STR, "peers": INT}),
    "WireGuardAgDurumu": obj({"iface": STR, "active": BOOL}),
    "WireGuardYenidenUretildi": obj({"peers": INT, "profiles": INT}),
    "WireGuardAgAyari": obj({"dns": STR, "revision": STR, "label": STR}, optional=("label",)),
    "WireGuardAgAyarSonucu": obj({"iface": STR, "dns": STR, "label": STR}, optional=("label",)),
    "WireGuardCihazIstegi": obj({"name": STR, "dns": STR, "keepalive": INT, "mtu": INT}),
    "WireGuardCihazEklendi": obj({"name": STR, "ipv4": STR}),
    "WireGuardDns": obj({"dns": STR}),
    "WireGuardKeepalive": obj({"keepalive": INT}),
    "Onay": obj({"confirm": STR}),
    "Acik": obj({"on": BOOL}),
    # DD-271 (phase 2): the inspector's dry run (master_inspector). The model both readers return, the
    # questions, the answers and the checked definition phase 3 installs from; no secret value in a reply.
    "Bulgu": obj({"line": INT, "key": STR, "text": STR}),
    "Isaret": obj({"line": INT, "kind": enum("refuse", "question", "note"), "text": STR}),
    # secret_key: the Kubernetes secretKeyRef as "<secret>/<key>" (null in Compose).
    "ModelOrtami": obj({"name": STR, "value": STR, "line": INT, "secret_ref": BOOL, "secret_key": null(STR)}),
    "ModelPortu": obj({"port": INT, "protocol": enum("tcp", "udp"), "host_port": null(INT), "line": INT}),
    "ModelBaglamasi": obj({"kind": enum("named", "relative", "absolute", "tmpfs"), "source": STR, "target": STR,
                           "read_only": BOOL, "line": INT}),
    "SaglikDenetimi": obj({"test": arr(STR), "interval": null(STR), "timeout": null(STR), "retries": null(INT),
                           "start_period": null(STR)}),
    "Bagimlilik": obj({"service": STR, "condition": enum("started", "healthy")}),
    # memory in bytes; ulimits by name (soft and hard, -1 unlimited).
    "Sinirlar": obj({"cpus": null(NUM), "memory": null(INT), "pids": null(INT),
                     "ulimits": map_of(obj({"soft": INT, "hard": INT}))}),
    "YenidenBaslatmaKurali": enum("no", "always", "on-failure", "unless-stopped"),
    "ModelServisi": obj({
        "name": STR, "line": INT, "image": STR, "image_line": INT, "command": null(arr(STR)),
        "entrypoint": null(arr(STR)), "workdir": null(STR), "user": null(STR), "environment": arr(ref("ModelOrtami")),
        "ports": arr(ref("ModelPortu")), "mounts": arr(ref("ModelBaglamasi")), "health": null(ref("SaglikDenetimi")),
        "restart": ref("YenidenBaslatmaKurali"), "depends_on": arr(ref("Bagimlilik")), "caps_add": arr(STR),
        "caps_drop": arr(STR), "no_new_privileges": BOOL, "read_only": BOOL, "init": BOOL, "hostname": null(STR),
        "shm_size": null(INT), "limits": ref("Sinirlar"),
        "labels": map_of(STR), "stop_signal": null(STR), "stop_grace": null(STR),
    }),
    "ModelDegiskeni": obj({"name": STR, "default": null(STR), "required": BOOL, "line": INT,
                           "uses": arr(obj({"service": null(STR), "field": STR, "line": INT}))}),
    "SoruAd": obj({"id": STR, "kind": enum("name"), "line": INT, "title": STR, "why": STR, "suggest": STR}),
    "SoruPort": obj({"id": STR, "kind": enum("port"), "line": INT, "title": STR, "why": STR, "service": STR,
                     "port": INT, "protocol": enum("tcp", "udp"), "guess": enum("web", "raw"),
                     "choices": arr(enum("caddy", "raw")), "suggest": null(STR), "host_port": null(INT)}),
    "SoruDegisken": obj({"id": STR, "kind": enum("var"), "line": INT, "title": STR, "why": STR, "name": STR,
                         "secret": BOOL, "generate": BOOL, "default": null(STR), "required": BOOL,
                         "services": arr(STR)}),
    # Compose: one question per service and entry; Kubernetes: one per secret and key, with every use.
    "SoruGizli": obj({"id": STR, "kind": enum("secret"), "line": INT, "title": STR, "why": STR, "service": STR,
                      "env": STR, "generate": BOOL, "services": arr(STR),
                      "uses": arr(obj({"service": STR, "env": STR}))}),
    "SoruKlasor": obj({"id": STR, "kind": enum("mount"), "line": INT, "title": STR, "why": STR, "service": STR,
                       "target": STR, "source": STR, "source_kind": enum("named", "relative", "absolute"),
                       "read_only": BOOL, "suggest": enum("app", "srv"), "folder": STR, "srv_path": null(STR)}),
    "SoruBaslangic": obj({"id": STR, "kind": enum("start"), "line": INT, "title": STR, "why": STR, "service": STR,
                          "suggest": enum("direct", "root"), "user": null(STR), "direct_user": STR,
                          "caps_add": arr(STR), "open_caps": arr(STR)}),
    "Soru": one_of(ref("SoruAd"), ref("SoruPort"), ref("SoruDegisken"), ref("SoruGizli"), ref("SoruKlasor"),
                   ref("SoruBaslangic")),
    "Inceleme": obj({
        "format": null(enum("compose", "kubernetes")), "name": STR, "pod": BOOL,
        "services": arr(ref("ModelServisi")), "variables": arr(ref("ModelDegiskeni")),
        "refusals": arr(ref("Bulgu")), "notes": arr(ref("Bulgu")), "questions": arr(ref("Soru")),
        "marks": arr(ref("Isaret")),
    }),
    "YanitAdres": obj({"use": enum("caddy"), "tailscale_name": STR}),
    "YanitHamPort": obj({"use": enum("raw")}),
    "YanitDeger": obj({"value": STR}),
    "YanitUygulamaKlasoru": obj({"to": enum("app")}),
    "YanitSrvKlasoru": obj({"to": enum("srv"), "path": STR, "read_only": BOOL}),
    "YanitBaslangic": obj({"mode": enum("direct", "root")}),
    "Yanit": one_of(ref("YanitAdres"), ref("YanitHamPort"), ref("YanitDeger"), ref("YanitUygulamaKlasoru"),
                    ref("YanitSrvKlasoru"), ref("YanitBaslangic")),
    "Yanitlar": obj({"name": STR, "answers": map_of(ref("Yanit"))}),
    "TanimOrtami": one_of(obj({"name": STR, "value": STR}), obj({"name": STR, "secret": STR})),
    "TanimPortu": obj({"port": INT, "protocol": enum("tcp", "udp"), "use": enum("caddy", "raw"),
                       "tailscale_name": null(STR)}),
    "TanimBaglamasi": one_of(obj({"target": STR, "to": enum("app"), "folder": STR, "read_only": BOOL}),
                             obj({"target": STR, "to": enum("srv"), "path": STR, "read_only": BOOL}),
                             obj({"target": STR, "to": enum("tmpfs")})),
    "TanimServisi": obj({
        "name": STR, "image": STR, "command": null(arr(STR)), "entrypoint": null(arr(STR)), "workdir": null(STR),
        "health": null(ref("SaglikDenetimi")), "restart": ref("YenidenBaslatmaKurali"), "depends_on": arr(ref("Bagimlilik")),
        "labels": map_of(STR), "stop_signal": null(STR), "stop_grace": null(STR),
        "start": enum("direct", "root"), "user": null(STR), "caps_drop": one_of(arr(STR), enum("all")),
        "caps_add": arr(STR), "no_new_privileges": BOOL, "read_only": BOOL, "init": BOOL, "hostname": null(STR),
        "shm_size": null(INT), "limits": ref("Sinirlar"), "environment": arr(ref("TanimOrtami")),
        "ports": arr(ref("TanimPortu")), "mounts": arr(ref("TanimBaglamasi")),
    }),
    "Tanim": obj({"name": STR, "format": enum("compose", "kubernetes"), "pod": BOOL, "services": arr(ref("TanimServisi")),
                  "secrets": arr(obj({"name": STR, "services": arr(STR)}))}),
    "DenetimIstegi": obj({"metin": STR, "yanitlar": ref("Yanitlar")}, optional=("yanitlar",)),
    "Denetim": obj({"inceleme": ref("Inceleme"), "tanim": ref("Tanim"), "hatalar": map_of(STR)},
                   optional=("tanim", "hatalar")),
}

# Path parameters ({name} segments); a segment is percent-decoded before its shape is checked.
PATH_PARAMS = {
    "iface": {"type": "string", "pattern": "^wg[0-9]$"},
    "name": {"type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"},
}
JSON = "application/json"


class Route:
    """content: the reply's media type; anything but JSON (a log, a device profile, a QR code) is sent as
    it is, its schema a string. params: the path's {name} segments, in order. body_limit: the largest
    request body in bytes when it is not the backend's usual one (a whole file in a request)."""

    def __init__(self, method, path, name, summary, reply=None, events=None, request=None, query=None, status=200,
                 content=JSON, body_limit=None):
        self.method, self.path, self.name, self.summary = method, path, name, summary
        self.reply, self.events, self.request, self.query, self.status = reply, events, request, query or {}, status
        self.content, self.body_limit = content, body_limit
        self.segments = path.split("/")
        self.params = [seg[1:-1] for seg in self.segments if seg.startswith("{") and seg.endswith("}")]


ROUTES = (
    Route("GET", "/api/konsol/erisim", "erisim", "Erişim: her hizmete nereden ulaşılır (okuma modeli)", ref("Erisim")),
    Route("GET", "/api/konsol/olaylar", "olaylar",
          "Canlı olaylar (Server-Sent Events): değişen konu yeniden gönderilir, 15 sn'de bir yaşam satırı, "
          "yaklaşık 10 dakikada bir akış biter ve sayfa yeniden bağlanır",
          events={"kaynaklar": ref("Kaynaklar"), "saglik": ref("Saglik"), "islemler": ref("Islemler"),
                  "bekleyen": ref("Bekleyen"), "kapat": ref("Kapat")}),
    Route("GET", "/api/konsol/kaynaklar", "kaynaklar", "Sunucunun kaynakları", ref("Kaynaklar")),
    Route("GET", "/api/konsol/saglik", "saglik", "Sağlık kartı (30 sn önbellekli)", ref("Saglik")),
    Route("GET", "/api/konsol/etkinlik", "etkinlik", "Süren ve yeni biten işlemler (olay akışı yokken)", ref("Islemler")),
    Route("GET", "/api/konsol/bekleyen", "bekleyen", "Onay ya da geri alma bekleyen ayar değişikliği", ref("Bekleyen")),
    Route("GET", "/api/konsol/uygulamalar", "uygulamalar", "Uygulamalar: Konsol'un konteynerleri (DD-261)", ref("Uygulamalar")),
    Route("GET", "/api/konsol/uygulamalar/ayrinti", "uygulama_ayrinti", "Bir uygulamanın konteyneri, bağlı klasörleri ve erişimi",
          ref("UygulamaAyrinti"), query={"id": STR}),
    Route("GET", "/api/konsol/uygulamalar/gunluk", "uygulama_gunlugu", "Bir uygulamanın günlüğü (son satırlar)",
          ref("UygulamaGunlugu"), query={"id": STR, "satir": INT}),
    Route("POST", "/api/konsol/uygulamalar/islem", "uygulama_islemi",
          "Bir uygulamayı başlat, durdur, yeniden başlat, güncelle ya da kaldır; ilerleme olay akışında (islemler)",
          ref("UygulamaIslemiBasladi"), request=ref("UygulamaIslemi"), status=202),
    # DD-271 (phase 2): the inspector's dry run. A file of up to 256 KiB arrives JSON-escaped beside the answers.
    Route("POST", "/api/konsol/uygulamalar/denetle", "uygulama_denetle",
          "Bir Compose ya da Kubernetes dosyasını denetler; yanıtlar verilirse tanımı çıkarır. Hiçbir şey yazılmaz, "
          "çalıştırılmaz, indirilmez; gizli değerler yanıtta yer almaz", ref("Denetim"), request=ref("DenetimIstegi"),
          body_limit=1048576),
    Route("GET", "/api/konsol/ag", "ag", "WAN'ın son hızı (DD-206)", ref("Ag")),
    Route("GET", "/api/konsol/onarim", "onarim", "Son denetim ve onarım raporu (DD-239)", ref("Onarim")),
    Route("POST", "/api/konsol/onarim", "onarim_baslat", "Denetimi ya da onarımı başlatır; yalnız Tailscale'den",
          ref("OnarimBasladi"), request=ref("OnarimIstegi"), status=202),
    Route("GET", "/api/konsol/guncelleme", "guncelleme",
          "Kurulu ve GitHub'daki son sürüm (DD-233); ?yenile yeniden sorar", ref("Guncelleme")),
    # DD-265: the settings transaction (DD-156) with its dry run.
    Route("POST", "/api/konsol/ayarlar/plan", "ayarlar_plan",
          "Bir ayar değişikliğinin planı: ne değişir, ne yeniden başlar, süreli onay ister mi; hiçbir şey değişmez",
          ref("AyarPlani"), request=ref("AyarIstegi")),
    Route("POST", "/api/konsol/ayarlar/uygula", "ayarlar_uygula",
          "Ayar değişikliğini uygular; güvenlik duvarı 60 sn, alan adı 300 sn içinde onay bekler", ref("AyarSonucu"),
          request=ref("AyarIstegi")),
    Route("POST", "/api/konsol/ayarlar/onayla", "ayarlar_onayla", "Bekleyen değişikliği kalıcılaştırır; yalnız Tailscale'den",
          ref("Tamam"), request=ref("IslemKimligi")),
    Route("POST", "/api/konsol/ayarlar/geri-al", "ayarlar_geri_al", "Bekleyen değişikliği geri alır", ref("Tamam"),
          request=ref("IslemKimligi")),
    Route("POST", "/api/konsol/ayarlar/birak", "ayarlar_birak",
          "Geri alınamayan değişikliği bırakır (onayla yazılarak)", ref("Tamam"), request=ref("IslemKimligi")),
    Route("GET", "/api/konsol/guvenlik-duvari", "guvenlik_duvari",
          "Güvenlik duvarı: kurallar, port kataloğu, dinleyiciler ve teknik kurallar; ?yenile önbelleği atlar",
          ref("GuvenlikDuvari"), query={"yenile": STR}),
    Route("GET", "/api/konsol/adlar", "adlar", "Yerel DNS adları, kayıtlar ve dış ad yönlendirmesi", ref("Adlar")),
    Route("GET", "/api/konsol/yayinlar", "yayinlar", "Yayınla: neyin, nasıl yayımlanabileceği (DD-265)", ref("Yayinlar")),
    Route("POST", "/api/konsol/yayinlar/plan", "yayin_plani",
          "Bir yayının adımları ve planı; hiçbir şey değişmez", ref("YayinPlani"), request=ref("YayinIstegi")),
    Route("POST", "/api/konsol/konteynerler/islem", "konteyner_islemi",
          "Konteyner işlemi (DD-211); iş arka planda sürer, ilerleme olay akışında", ref("KonteynerIsi"),
          request=ref("KonteynerIstegi"), status=202),
    # DD-266 (phase 4a): the Podman reads, the Sistem routes and Gelişmiş.
    Route("GET", "/api/konsol/konteynerler/liste", "konteyner_listesi",
          "Konteynerler, imajlar, birimler ve ağlar (DD-211)", ref("KonteynerListesi")),
    Route("GET", "/api/konsol/konteynerler/ayrinti", "konteyner_ayrintisi",
          "Bir konteynerin ayrıntısı ve düzenlenebilir tanımı", ref("KonteynerAyrintisi"), query={"ad": STR}),
    Route("GET", "/api/konsol/konteynerler/guncellemeler", "konteyner_guncellemeleri",
          "İmaj güncelleme durumu (DD-214); ?yenile en çok dakikada bir yeniden sorar", ref("KonteynerGuncellemeleri"),
          query={"yenile": STR}),
    Route("GET", "/api/konsol/konteynerler/islem", "konteyner_isi", "Bir konteyner işinin durumu", ref("KonteynerIsi"),
          query={"id": STR}),
    Route("GET", "/api/konsol/ayarlar/klasorler", "klasorler", "Klasör seçici: bir klasörün alt klasörleri ve boş yer",
          ref("Klasorler"), query={"path": STR}),
    Route("GET", "/api/konsol/oturum", "oturum", "Konsol hesabı ve bu oturum (DD-194, DD-205)", ref("Oturum")),
    Route("POST", "/api/konsol/oturum/kur", "oturum_kur", "Konsol hesabını oluşturur; yalnız Tailscale'den",
          ref("HesapSonucu"), request=ref("HesapKur")),
    Route("POST", "/api/konsol/oturum/cikis", "oturum_cikis", "Bu tarayıcının oturumunu kapatır", ref("HesapSonucu"),
          request=ref("Bos")),
    Route("POST", "/api/konsol/hesap/parola", "hesap_parola",
          "Konsol parolasını değiştirir; internetten eski parola istenir, Tailscale'den diğer oturumlar kapanır",
          ref("HesapSonucu"), request=ref("ParolaDegistir")),
    Route("POST", "/api/konsol/guncelleme", "guncelleme_baslat",
          "Güncellemeyi başlatır (DD-233); yalnız Tailscale'den", ref("GuncellemeBasladi"), request=ref("GuncellemeIstegi"),
          status=202),
    Route("POST", "/api/konsol/yeniden-baslat", "yeniden_baslat", "Sunucuyu yeniden başlatır (DD-246); yalnız Tailscale'den",
          ref("YenidenBaslatma"), request=ref("Bos"), status=202),
    Route("GET", "/api/konsol/onarim/gunluk", "onarim_gunlugu", "Denetim ve onarım günlüğü (72s ya da 7g, düz metin)",
          STR, query={"sure": STR}, content="text/plain"),
    Route("GET", "/api/konsol/islemler", "islemler", "Konsol günlüğü: son yedi günün işlemleri, yeniden eskiye",
          ref("Kayitlar")),
    # DD-267 (phase 4b): Dosyalar's shares and storage.
    Route("GET", "/api/konsol/paylasim", "paylasimlar", "Klasör paylaşımları ve bağlantıları (WebDAV, DD-192)",
          ref("Paylasimlar")),
    Route("POST", "/api/konsol/paylasim/kaydet", "paylasim_kaydet",
          "Bir klasör paylaşımını oluşturur ya da değiştirir; WebDAV yeniden başlar", ref("Paylasimlar"),
          request=ref("PaylasimKaydi")),
    Route("POST", "/api/konsol/paylasim/kaldir", "paylasim_kaldir", "Bir klasör paylaşımını kaldırır", ref("Paylasimlar"),
          request=ref("PaylasimKimligi")),
    Route("GET", "/api/konsol/depolama", "depolama", "Sunucu klasörlerini kullanan uygulamalar ve paylaşımlar",
          ref("Depolama")),
    Route("GET", "/api/konsol/gelismis", "gelismis",
          "Gelişmiş: etkin Caddy ve dnsmasq yapılandırması (salt okunur); ?yenile önbelleği atlar", ref("Gelismis"),
          query={"yenile": STR}),
    # DD-271: WireGuard (Erişim → WireGuard); every change through master-wg, the audit line wireguard-<verb>.
    Route("GET", "/api/konsol/wireguard/state", "wireguard",
          "WireGuard: ağlar ve cihazları, yeni ağın varsayılanları, durdurulmuş mu", ref("WireGuard")),
    Route("POST", "/api/konsol/wireguard/durdur", "wireguard_durdur",
          "WireGuard'ı bütünüyle durdurur: ağlar kapanır, portları ve yönlendirmesi kalkar (DD-229)",
          ref("WireGuardCalismasi"), request=ref("Bos")),
    Route("POST", "/api/konsol/wireguard/baslat", "wireguard_baslat",
          "WireGuard'ı başlatır: durdurmadan önce açık olan ağlar geri gelir", ref("WireGuardCalismasi"), request=ref("Bos")),
    Route("POST", "/api/konsol/wireguard/nets", "wireguard_ag_ekle", "Yeni WireGuard ağı (wg0…wg9); ilk ağ WireGuard'ı açar",
          ref("WireGuardAgEklendi"), request=ref("WireGuardAgIstegi"), status=201),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/remove", "wireguard_ag_kaldir",
          "Ağı, anahtarını ve bütün cihazlarını siler (onayla yazılarak)", ref("WireGuardAgKaldirildi"), request=ref("Onay")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/reset", "wireguard_ag_yeniden_uret",
          "Ağın sunucu anahtarını yeniden üretir; bütün cihazlar silinir (onayla yazılarak)", ref("WireGuardYenidenUretildi"),
          request=ref("Onay")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/peers", "wireguard_cihaz_ekle", "Ağa yeni cihaz ekler",
          ref("WireGuardCihazEklendi"), request=ref("WireGuardCihazIstegi"), status=201),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/durum", "wireguard_ag_durum", "Ağı açar ya da kapatır",
          ref("WireGuardAgDurumu"), request=ref("Acik")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/ayarlar", "wireguard_ag_ayarlar",
          "Ağın varsayılan DNS'i ve adı; revizyon eskiyse 409", ref("WireGuardAgAyarSonucu"), request=ref("WireGuardAgAyari")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/peers/{name}/remove", "wireguard_cihaz_kaldir", "Cihazı siler",
          ref("Tamam"), request=ref("Bos")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/peers/{name}/dns", "wireguard_cihaz_dns",
          "Cihaz profilindeki DNS; anahtarlar aynı kalır", ref("Tamam"), request=ref("WireGuardDns")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/peers/{name}/keepalive", "wireguard_cihaz_keepalive",
          "Cihaz profilindeki canlı tutma süresi (0 = kapalı)", ref("Tamam"), request=ref("WireGuardKeepalive")),
    Route("POST", "/api/konsol/wireguard/nets/{iface}/peers/{name}/durum", "wireguard_cihaz_durum",
          "Cihazı ağdan düşürür ya da geri koyar", ref("Tamam"), request=ref("Acik")),
    Route("GET", "/api/konsol/wireguard/nets/{iface}/peers/{name}/profile", "wireguard_profil",
          "Cihaz profili (indirme; gizli anahtarı taşır, yalnız açıkça istenince)", STR, content="text/plain"),
    Route("GET", "/api/konsol/wireguard/nets/{iface}/peers/{name}/qr.png", "wireguard_qr",
          "Cihaz profilinin QR kodu (PNG indirme; gizli anahtarı taşır, yalnız açıkça istenince)", STR, content="image/png"),
)


def match(method, path):
    """(route, path parameters) for a request path, or (None, None). A parameter that does not have its
    shape matches nothing."""
    segments = path.split("/")
    for route in ROUTES:
        if route.method != method or len(route.segments) != len(segments):
            continue
        params = {}
        for want, got in zip(route.segments, segments):
            if want.startswith("{") and want.endswith("}"):
                value = urllib.parse.unquote(got)
                try:
                    check(PATH_PARAMS[want[1:-1]], value)
                except SchemaError:
                    break
                params[want[1:-1]] = value
            elif want != got:
                break
        else:
            return route, params
    return None, None


def find(method, path):
    return match(method, path)[0]


# -- validation (request bodies, path parameters and tests)
class SchemaError(ValueError):
    pass


def check(schema, value, path="$"):
    """Raises SchemaError when value does not have the shape; a subset of JSON Schema 2020-12."""
    if "$ref" in schema:
        return check(SCHEMAS[schema["$ref"].rsplit("/", 1)[1]], value, path)
    if "anyOf" in schema:
        errors = []
        for option in schema["anyOf"]:
            try:
                return check(option, value, path)
            except SchemaError as err:
                errors.append(str(err))
        raise SchemaError("; ".join(errors))
    kind = schema["type"]
    ok = {"null": value is None, "string": isinstance(value, str), "boolean": isinstance(value, bool),
          "integer": isinstance(value, int) and not isinstance(value, bool),
          "number": isinstance(value, (int, float)) and not isinstance(value, bool),
          "array": isinstance(value, list), "object": isinstance(value, dict)}[kind]
    if not ok:
        raise SchemaError("%s: %s bekleniyordu, %s geldi" % (path, kind, type(value).__name__))
    if "enum" in schema and value not in schema["enum"]:
        raise SchemaError("%s: %r izinli değerlerden değil" % (path, value))
    if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
        raise SchemaError("%s: biçimi geçersiz" % path)
    if kind == "array":
        for i, item in enumerate(value):
            check(schema["items"], item, "%s[%d]" % (path, i))
    if kind == "object":
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties")
        for key in schema.get("required", []):
            if key not in value:
                raise SchemaError("%s: %s eksik" % (path, key))
        for key, item in value.items():
            if key in props:
                check(props[key], item, "%s.%s" % (path, key))
            elif extra is False:
                raise SchemaError("%s: bilinmeyen alan %s" % (path, key))
            elif isinstance(extra, dict):
                check(extra, item, "%s.%s" % (path, key))


# -- generated descriptions
def openapi():
    paths = {}
    for route in ROUTES:
        if route.events:
            content = {"text/event-stream": {"schema": STR}}
        elif route.content == JSON:
            content = {JSON: {"schema": route.reply}}
        else:
            content = {route.content: {"schema": STR if route.content.startswith("text/") else {}}}
        responses = {str(route.status): {"description": "Başarılı", "content": content},
                     "403": {"description": "Host, köken ya da X-Konsol denetimi",
                             "content": {"application/json": {"schema": ref("Hata")}}}}
        if route.events:
            responses["503"] = {"description": "Bu kanaldaki akış sınırı dolu; sayfa yenilemeye geçer",
                                "content": {"application/json": {"schema": ref("Hata")}}}
        op = {"operationId": route.name, "summary": route.summary,
              "parameters": [{"name": "X-Konsol", "in": "header", "required": True, "schema": enum("1")}]
              + [{"name": key, "in": "path", "required": True, "schema": PATH_PARAMS[key]} for key in route.params]
              + [{"name": key, "in": "query", "required": key == "id", "schema": schema} for key, schema in route.query.items()],
              "responses": responses}
        if route.request:
            op["requestBody"] = {"required": True, "content": {"application/json": {"schema": route.request}}}
            responses["400"] = {"description": "İstek biçimi geçersiz", "content": {"application/json": {"schema": ref("Hata")}}}
        if route.events:
            op["x-olaylar"] = dict(route.events)
        paths.setdefault(route.path, {})[route.method.lower()] = op
    return {"openapi": "3.1.0",
            "info": {"title": "Konsol API", "version": "1",
                     "description": "Konsol'un root arka ucu; yalnız Caddy'nin oturum kapısının arkasından (DD-180, DD-194)."},
            "paths": paths, "components": {"schemas": SCHEMAS}}


def ts_type(schema, indent=""):
    if "$ref" in schema:
        return schema["$ref"].rsplit("/", 1)[1]
    if "anyOf" in schema:
        return " | ".join(ts_type(option, indent) for option in schema["anyOf"])
    kind = schema["type"]
    if "enum" in schema:
        return " | ".join(json.dumps(v, ensure_ascii=False) for v in schema["enum"])
    if kind == "array":
        inner = ts_type(schema["items"], indent)
        return "(%s)[]" % inner if " | " in inner else inner + "[]"
    if kind == "object":
        return ts_object(schema, indent)
    return {"string": "string", "integer": "number", "number": "number", "boolean": "boolean", "null": "null"}[kind]


def ts_object(schema, indent):
    inner = indent + "  "
    lines = ["{"]
    required = set(schema.get("required", []))
    for key, prop in schema["properties"].items():
        lines.append("%s%s%s: %s;" % (inner, key, "" if key in required else "?", ts_type(prop, inner)))
    extra = schema.get("additionalProperties")
    if extra is True:
        lines.append("%s[key: string]: unknown;" % inner)
    elif isinstance(extra, dict):
        lines.append("%s[key: string]: %s;" % (inner, ts_type(extra, inner)))
    lines.append(indent + "}")
    return "\n".join(lines)


def typescript():
    out = ["// Generated by Data/panel/master_api.py (DD-259); do not edit.",
           "// python3 panel/master_api.py ts > tools/konsol-ui/src/api/sema.ts", ""]
    for name, schema in SCHEMAS.items():
        if schema.get("type") == "object" and "enum" not in schema:
            out.append("export interface %s %s" % (name, ts_object(schema, "")))
        else:
            out.append("export type %s = %s;" % (name, ts_type(schema)))
        out.append("")
    events = [r for r in ROUTES if r.events]
    for route in events:
        out.append("export interface Olaylar {")
        for event, schema in route.events.items():
            out.append("  %s: %s;" % (event, ts_type(schema)))
        out.append("}")
        out.append("")
    out.append("export const YOLLAR = {")
    for route in ROUTES:
        out.append("  %s: %s," % (route.name, json.dumps(route.path)))
    out.append("} as const;")
    return "\n".join(out) + "\n"


def main():
    if sys.argv[1:] == ["openapi"]:
        sys.stdout.write(json.dumps(openapi(), ensure_ascii=False, indent=2) + "\n")
    elif sys.argv[1:] == ["ts"]:
        sys.stdout.write(typescript())
    else:
        sys.stderr.write("kullanım: master_api.py openapi|ts\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
