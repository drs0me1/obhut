#!/usr/bin/env python3
"""Konsol's API description (DD-259): the routes of the new interface and the shape of each reply.

The root backend dispatches these routes from this table. Tests check real replies against the
shapes, and generate from them the OpenAPI description (docs/konsol-api.json) and the interface's
TypeScript types (tools/konsol-ui/src/api/sema.ts); a committed copy that differs fails the tests.

    python3 panel/master_api.py openapi > docs/konsol-api.json
    python3 panel/master_api.py ts > tools/konsol-ui/src/api/sema.ts

Routes that predate the table keep their place in the backend until their page moves to the new
interface (docs/redesign.md). Python standard library only.
"""
import json
import sys

STR = {"type": "string"}
INT = {"type": "integer"}
NUM = {"type": "number"}
BOOL = {"type": "boolean"}


def obj(props, optional=()):
    return {"type": "object", "properties": props, "required": [k for k in props if k not in optional],
            "additionalProperties": False}


def open_obj(props):
    """An object whose listed fields are all optional and which may carry others (a package's own
    konsol.json): the shell reads what it knows and checks it at run time."""
    return {"type": "object", "properties": props, "required": [], "additionalProperties": True}


def arr(item):
    return {"type": "array", "items": item}


def null(schema):
    return {"anyOf": [schema, {"type": "null"}]}


def enum(*values):
    return {"type": "string", "enum": list(values)}


def ref(name):
    return {"$ref": "#/components/schemas/" + name}


SCHEMAS = {
    "Hata": obj({"error": STR, "giris": BOOL}, optional=("giris",)),
    "Kaynaklar": obj({
        "host": STR, "version": STR, "domain": STR, "os": STR, "kernel": STR, "uptime": INT, "cores": INT,
        "interval": INT, "read_at": INT, "sampled_at": null(INT), "cpu": arr(NUM),
        "mem": obj({"total": INT, "used": INT, "graph": arr(NUM)}),
        "net": obj({"wan": STR, "wan6": STR, "iface": STR, "tailscale": STR, "tailscale6": STR}),
        "root": STR, "disk": null(obj({"total": INT, "free": INT})),
    }),
    "SaglikDurumu": enum("ok", "warn", "bad"),
    "Saglik": obj({"status": ref("SaglikDurumu"),
                   "checks": arr(obj({"id": STR, "name": STR, "status": ref("SaglikDurumu"), "detail": STR})),
                   "read_at": INT}),
    "Islem": obj({"tur": enum("modul", "konteyner", "guncelleme", "onarim"), "id": STR, "ad": STR,
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
        "id": STR, "ad": STR, "tur": enum("konsol", "paket", "konteyner", "elle", "paylasim", "sistem", "vpn", "kural"),
        "aciklama": STR, "uygulama": null(STR), "calisiyor": null(BOOL),
        "yerel": ref("ErisimHucresi"), "tailscale": ref("ErisimHucresi"), "wireguard": ref("ErisimHucresi"),
        "internet": ref("ErisimHucresi"), "yayinlar": arr(STR), "ayrinti": arr(obj({"baslik": STR, "deger": STR})),
    }),
    "Uyari": obj({"seviye": enum("warn", "bad"), "hizmet": STR, "metin": STR}),
    "KonsolBildirimi": open_obj({"ad": STR, "alt": STR, "simge": STR,
                                 "sayfa": open_obj({"rota": STR, "baslik": STR, "ustbilgi": STR})}),
    "Modul": obj({"id": STR, "runtime": STR, "installed": BOOL, "state": enum("calisiyor", "durduruldu", ""), "live": STR,
                  "busy": BOOL, "progress": null(obj({"action": STR, "step": STR, "total": INT, "text": STR})),
                  "durdurulabilir": BOOL, "konsol": ref("KonsolBildirimi"), "sayfa": arr(STR),
                  "urls": obj({"tailscale": null(STR), "internet": null(STR)})},
                 optional=("konsol", "sayfa", "urls")),
    "Moduller": obj({"items": arr(ref("Modul"))}),
    "GuncellemeIsi": obj({"durum": enum("yok", "calisiyor", "tamam", "hata"), "hedef": STR, "mesaj": STR,
                          "bitis": null(INT), "asama": STR}),
    "Guncelleme": obj({"kurulu": STR, "son": null(STR), "commit": null(STR), "yeni": BOOL, "denetlendi": null(INT),
                       "hata": STR, "is": ref("GuncellemeIsi"), "baslatilabilir": BOOL}),
    "Erisim": obj({
        "read_at": INT, "alan": STR,
        "ozet": obj({
            "tailscale": obj({"ipv4": STR, "ipv6": STR, "durum": enum("bagli", "bagli-degil", "bilinmiyor"),
                              "anahtar_bitis": null(INT)}),
            "internet": obj({"ipv4": STR, "ipv6": STR,
                             "acik": arr(obj({"ad": STR, "port": INT, "proto": STR, "aileler": arr(INT),
                                              "kaynak": enum("temel", "kural")}))}),
            "wireguard": obj({"kurulu": BOOL, "not": STR,
                              "aglar": arr(obj({"uygulama": STR, "arayuz": STR, "ad": STR, "etkin": BOOL, "port": INT}))}),
            "sertifikalar": arr(obj({"ad": STR, "hizmet": STR, "durum": enum("gecerli", "hazir-degil"), "bitis": null(INT)})),
        }),
        "hizmetler": arr(ref("Hizmet")), "uyarilar": arr(ref("Uyari")), "hatalar": arr(STR),
    }),
}


class Route:
    def __init__(self, method, path, name, summary, reply=None, events=None):
        self.method, self.path, self.name, self.summary = method, path, name, summary
        self.reply, self.events = reply, events


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
    Route("GET", "/api/konsol/moduller", "moduller", "App Store paketleri ve yerleşikler (DD-148, DD-200)", ref("Moduller")),
    Route("GET", "/api/konsol/guncelleme", "guncelleme",
          "Kurulu ve GitHub'daki son sürüm (DD-233); ?yenile yeniden sorar", ref("Guncelleme")),
)


def find(method, path):
    for route in ROUTES:
        if route.method == method and route.path == path:
            return route
    return None


# -- validation (tests)
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
    if kind == "array":
        for i, item in enumerate(value):
            check(schema["items"], item, "%s[%d]" % (path, i))
    if kind == "object":
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                raise SchemaError("%s: %s eksik" % (path, key))
        for key, item in value.items():
            if key in props:
                check(props[key], item, "%s.%s" % (path, key))
            elif schema.get("additionalProperties") is False:
                raise SchemaError("%s: bilinmeyen alan %s" % (path, key))


# -- generated descriptions
def openapi():
    paths = {}
    for route in ROUTES:
        if route.events:
            content = {"text/event-stream": {"schema": STR}}
        else:
            content = {"application/json": {"schema": route.reply}}
        responses = {"200": {"description": "Başarılı", "content": content},
                     "403": {"description": "Host, köken ya da X-Konsol denetimi",
                             "content": {"application/json": {"schema": ref("Hata")}}}}
        if route.events:
            responses["503"] = {"description": "Bu kanaldaki akış sınırı dolu; sayfa yenilemeye geçer",
                                "content": {"application/json": {"schema": ref("Hata")}}}
        op = {"operationId": route.name, "summary": route.summary,
              "parameters": [{"name": "X-Konsol", "in": "header", "required": True, "schema": enum("1")}],
              "responses": responses}
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
    if schema.get("additionalProperties") is True:
        lines.append("%s[key: string]: unknown;" % inner)
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
