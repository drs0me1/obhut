#!/usr/bin/env python3
"""obhut (DD-268): the server's state and its recovery over SSH, as root.

It speaks to Konsol's root backend over its own Unix socket (the same routes the interface uses,
DD-259; the socket's caller is "yerel", DD-180) and to the existing root tools: master-onar for checks
and repairs (it works while the backend is down), master-konsol for the Konsol account. When the
backend does not answer, `durum` reads the units from systemd and says how to repair.

    sudo obhut durum [--json]
    sudo obhut denetle | onar
    sudo obhut guncelle [--evet]
    sudo obhut hesap durum | sifirla
    sudo obhut uygulama liste [--json] | baslat|durdur|yeniden-baslat <id>
    sudo obhut yayin liste [--json] | kapat <id>|--hepsi
    sudo obhut geri-al

Python standard library only; operator text is Turkish.
"""
import argparse
import http.client
import json
import os
import shlex
import socket
import subprocess
import sys

STATE = "/etc/master-stack/state.env"
SBIN = os.path.dirname(os.path.realpath(__file__))
UNITS = ("tailscaled", "caddy", "dnsmasq", "master-panel", "master-files-panel", "master-paylasim")


class ObhutError(Exception):
    """A refusal or a failure the operator reads; the exit status is 1."""


def read_env(path):
    env = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and key and not key.startswith("#"):
                    try:
                        parts = shlex.split(value)
                    except ValueError:
                        continue
                    env[key] = parts[0] if parts else ""
    except OSError as err:
        raise ObhutError("Kurulum kaydı okunamadı (%s): %s" % (path, err.strerror or err)) from err
    return env


class Socket(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


class Konsol:
    """Konsol's root backend over its socket: JSON in and out, the backend's own message on a refusal."""

    def __init__(self, env, timeout=30):
        self.path = env.get("PANEL_SOCKET") or "/run/master-panel/api.sock"
        self.host = "panel.%s" % env.get("LOCAL_DOMAIN", "")
        self.timeout = timeout

    def call(self, method, route, data=None):
        conn = Socket(self.path, self.timeout)
        headers = {"Host": self.host, "X-Konsol": "1", "Connection": "close"}
        body = None
        if data is not None:
            body = json.dumps(data).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            conn.request(method, route, body=body, headers=headers)
            res = conn.getresponse()
            raw = res.read()
        except (OSError, http.client.HTTPException) as err:
            raise ObhutError("Konsol'un arka ucuna ulaşılamadı (%s): %s" % (self.path, err)) from err
        finally:
            conn.close()
        try:
            answer = json.loads(raw.decode("utf-8")) if raw else None
        except (ValueError, UnicodeDecodeError):
            answer = None
        if res.status >= 400:
            message = answer.get("error") if isinstance(answer, dict) else ""
            raise ObhutError(message or "Konsol isteği reddetti (HTTP %d)." % res.status)
        return answer

    def get(self, route):
        return self.call("GET", route)

    def post(self, route, data):
        return self.call("POST", route, data)


def run_tool(name, *args):
    """A root tool beside this one (master-onar, master-konsol); its output goes straight to the terminal."""
    path = os.path.join(SBIN, name)
    if not os.access(path, os.X_OK):
        raise ObhutError("%s bulunamadı; kurulumu yeniden çalıştırın." % path)
    return subprocess.call([path, *args])


def unit_states():
    states = {}
    for unit in UNITS:
        try:
            out = subprocess.run(["systemctl", "is-active", unit + ".service"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        states[unit] = out.strip() or "bilinmiyor"
    return states


def show(data, as_json, lines):
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        for line in lines:
            print(line)


# -- commands
def cmd_durum(konsol, args):
    try:
        res = konsol.get("/api/konsol/kaynaklar")
        health = konsol.get("/api/konsol/saglik")
        apps = konsol.get("/api/konsol/uygulamalar")
        pending = konsol.get("/api/konsol/bekleyen")
        update = konsol.get("/api/konsol/guncelleme")
    except ObhutError as err:
        states = unit_states()
        lines = ["Konsol yanıt vermiyor: %s" % err, "Servisler:"]
        lines += ["  %-20s %s" % (u, s) for u, s in states.items()]
        lines.append("Onarmak için: sudo obhut onar")
        show({"konsol": False, "hata": str(err), "servisler": states}, args.json, lines)
        return 1
    data = {"kaynaklar": res, "saglik": health, "uygulamalar": apps, "bekleyen": pending, "guncelleme": update}
    net = res.get("net") or {}
    lines = ["Obhut %s (yapı %s) · %s" % (res.get("surum") or "?", res.get("version") or "?", res.get("host") or "?"),
             "Konsol: http://panel.%s (Tailscale)" % (res.get("domain") or "?"),
             "Adresler: Tailscale %s · internet %s" % (net.get("tailscale") or "yok", net.get("wan") or "yok")]
    if update.get("yeni"):
        lines.append("Yeni sürüm var: %s (sudo obhut guncelle)" % (update.get("son_surum") or update.get("son")))
    word = {"ok": "sorunsuz", "warn": "dikkat", "bad": "sorun var"}
    lines.append("Sağlık: %s" % word.get(health.get("status"), health.get("status")))
    for check in health.get("checks") or []:
        if check.get("status") != "ok":
            lines.append("  ! %s: %s" % (check.get("name"), check.get("detail")))
    lines.append("Uygulamalar:")
    for item in apps.get("items") or []:
        lines.append("  %-28s %s" % (item.get("id"), item.get("durum")))
    if pending.get("bekleyen"):
        lines.append("Onay bekleyen bir ayar değişikliği var (geri almak için: sudo obhut geri-al).")
    show(data, args.json, lines)
    return 0 if health.get("status") != "bad" else 1


def cmd_denetle(konsol, args):
    return run_tool("master-onar", "--denetle")


def cmd_onar(konsol, args):
    return run_tool("master-onar")


def cmd_hesap(konsol, args):
    return run_tool("master-konsol", args.eylem)


def cmd_guncelle(konsol, args):
    update = konsol.get("/api/konsol/guncelleme?yenile=1")
    job = update.get("is") or {}
    if job.get("durum") == "calisiyor":
        print("Güncelleme zaten sürüyor: %s" % (job.get("asama") or ""))
        return 0
    if not update.get("son") or not update.get("commit"):
        raise ObhutError(update.get("hata") or "En son sürüm okunamadı; ağ bağlantısını denetleyin.")
    if not update.get("yeni"):
        # The backend compares the builds (DD-233); a test build newer than GitHub's is not an update.
        print("Güncel: %s (yapı %s); en yeni yayın %s." % (update.get("kurulu_surum") or "?", update.get("kurulu"), update.get("son")))
        return 0
    print("Kurulu %s, en yeni %s (commit %s)." % (update.get("kurulu"), update.get("son"), update["commit"][:7]))
    print("Kod GitHub'dan indirilir, sistem paketleri de güncellenir; Konsol ve servisler yeniden başlar.")
    if not args.evet:
        if not sys.stdin.isatty():
            raise ObhutError("Onay için --evet ekleyin.")
        if input("Güncellensin mi? [e/H] ").strip().lower() not in ("e", "evet"):
            print("Vazgeçildi.")
            return 0
    started = konsol.post("/api/konsol/guncelleme", {"surum": update["son"], "commit": update["commit"]})
    print("Güncelleme başladı (%s); günlük: journalctl -u master-guncelle -f" % started.get("surum"))
    return 0


def cmd_uygulama(konsol, args):
    apps = konsol.get("/api/konsol/uygulamalar")
    items = apps.get("items") or []
    if args.eylem == "liste":
        lines = ["%-28s %-12s %s" % (i.get("id"), i.get("durum"), i.get("ad")) for i in items]
        show(apps, args.json, lines or ["Kurulu uygulama yok."])
        return 0
    item = next((i for i in items if i.get("id") == args.id or i.get("modul") == args.id or i.get("konteyner") == args.id), None)
    if item is None:
        raise ObhutError("Uygulama bulunamadı: %s (sudo obhut uygulama liste)" % args.id)
    if args.eylem not in (item.get("eylemler") or []):
        verb = {"baslat": "başlatılamaz", "durdur": "durdurulamaz", "yeniden-baslat": "yeniden başlatılamaz"}[args.eylem]
        raise ObhutError("%s şu an %s (durum: %s)." % (item.get("ad"), verb, item.get("durum")))
    body = {"id": item["id"], "eylem": args.eylem}
    if item.get("revizyon"):
        body["revizyon"] = item["revizyon"]
    konsol.post("/api/konsol/uygulamalar/islem", body)
    print("%s: %s isteği gönderildi; durumu: sudo obhut uygulama liste" % (item.get("ad"), args.eylem))
    return 0


def cmd_yayin(konsol, args):
    view = konsol.get("/api/konsol/yayinlar")
    rows = [r for r in view.get("adaylar") or [] if r.get("servis")]
    if args.eylem == "liste":
        lines = []
        for r in rows:
            internet = r.get("alan_adi") if r.get("internet") and r.get("alan_adi") else ("açık" if r.get("internet") else "kapalı")
            lines.append("%-24s Tailscale %-6s internet %s" % (r.get("id"), "açık" if r.get("tailscale") else "kapalı", internet))
        show(view, args.json, lines or ["Yayın yok."])
        return 0
    targets = [r for r in rows if r.get("internet")] if args.hepsi else [r for r in rows if r.get("id") == args.id or r.get("servis") == args.id]
    if not args.hepsi and not targets:
        raise ObhutError("Yayın bulunamadı: %s (sudo obhut yayin liste)" % args.id)
    targets = [r for r in targets if r.get("internet")]
    if not targets:
        print("İnternete açık yayın yok; değişen bir şey olmadı.")
        return 0
    revision = view.get("revizyon")
    for index, r in enumerate(targets):
        # Each write changes the revision; the next one reads it again.
        if index:
            revision = konsol.get("/api/konsol/yayinlar").get("revizyon")
        # The internet name closes; the Tailscale name stays as it is (Konsol's own always stays on).
        web = {"service": r["servis"], "tail": bool(r.get("tailscale")), "enabled": False, "domain": r.get("alan_adi") or ""}
        konsol.post("/api/konsol/ayarlar/uygula", {"revision": revision, "web": web})
        print("%s: internet adı kapatıldı." % r.get("ad"))
    return 0


def cmd_geri_al(konsol, args):
    pending = (konsol.get("/api/konsol/bekleyen") or {}).get("bekleyen")
    if not pending:
        print("Onay bekleyen bir ayar değişikliği yok.")
        return 0
    konsol.post("/api/konsol/ayarlar/geri-al", {"id": pending["id"]})
    print("Bekleyen değişiklik geri alınıyor; önceki ayarlar yükleniyor.")
    return 0


def parser():
    p = argparse.ArgumentParser(prog="obhut", description="Sunucunun durumu ve kurtarma (root).")
    p.add_argument("--state", default=STATE, help=argparse.SUPPRESS)
    sub = p.add_subparsers(dest="komut", required=True, metavar="komut")
    s = sub.add_parser("durum", help="sürüm, sağlık, uygulamalar ve bekleyen değişiklik")
    s.add_argument("--json", action="store_true")
    s.set_defaults(run=cmd_durum)
    sub.add_parser("denetle", help="denetim (master-onar --denetle)").set_defaults(run=cmd_denetle)
    sub.add_parser("onar", help="onarım (master-onar)").set_defaults(run=cmd_onar)
    s = sub.add_parser("guncelle", help="yeni sürüm varsa güncellemeyi başlatır")
    s.add_argument("--evet", action="store_true", help="sormadan başlat")
    s.set_defaults(run=cmd_guncelle)
    s = sub.add_parser("hesap", help="Konsol hesabı (master-konsol)")
    s.add_argument("eylem", choices=("durum", "sifirla"))
    s.set_defaults(run=cmd_hesap)
    s = sub.add_parser("uygulama", help="uygulamalar: liste, başlat, durdur, yeniden başlat")
    s.add_argument("eylem", choices=("liste", "baslat", "durdur", "yeniden-baslat"))
    s.add_argument("id", nargs="?", default="")
    s.add_argument("--json", action="store_true")
    s.set_defaults(run=cmd_uygulama)
    s = sub.add_parser("yayin", help="yayınlar: liste; bir internet adını ya da hepsini kapat")
    s.add_argument("eylem", choices=("liste", "kapat"))
    s.add_argument("id", nargs="?", default="")
    s.add_argument("--hepsi", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(run=cmd_yayin)
    sub.add_parser("geri-al", help="onay bekleyen ayar değişikliğini geri alır").set_defaults(run=cmd_geri_al)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    if getattr(args, "eylem", None) in ("baslat", "durdur", "yeniden-baslat") and not args.id:
        print("obhut: uygulamanın kimliğini yazın (sudo obhut uygulama liste).", file=sys.stderr)
        return 2
    if args.komut == "yayin" and args.eylem == "kapat" and not (args.id or args.hepsi):
        print("obhut: yayının kimliğini ya da --hepsi yazın (sudo obhut yayin liste).", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("obhut: root olarak çalıştırın: sudo obhut %s" % " ".join(argv if argv is not None else sys.argv[1:]), file=sys.stderr)
        return 2
    try:
        konsol = Konsol(read_env(args.state))
        return args.run(konsol, args)
    except ObhutError as err:
        print("obhut: %s" % err, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
