"""qBittorrent package: Konsol API module (DD-202).

Loaded by the root backend while the package is registered; serves /api/uygulama/torrent/*.
Reads are done here (the profile is a root file under /var); every change runs the package's
worker ayar.py through ctx.worker() as a separate transient unit, JSON on stdin, so nothing is
written from inside the backend's sandbox and no password reaches argv, environment or journal.
"""
import importlib.util
import os

APP_NAME = "qBittorrent"


def create(ctx):
    return Api(ctx)


class Api:
    APP_NAME = APP_NAME

    def __init__(self, ctx):
        self.ctx = ctx
        here = os.path.dirname(os.path.abspath(__file__))
        self.worker_path = os.path.join(here, "ayar.py")
        # The worker runs standalone and needs the base's library next to the engine (SBIN_DIR).
        self.lib_dir = os.path.dirname(self.ctx.tool("master_settings.py"))
        spec = importlib.util.spec_from_file_location("magaza_torrent_ayar", self.worker_path)
        self.ayar = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ayar)

    def handle(self, req):
        if req.method == "GET" and req.path == "/durum":
            return 200, self.durum()
        if req.method == "POST" and req.path in ("/hesap", "/dizin"):
            return self.change(req, req.path[1:])
        raise self.ctx.error(405 if req.method not in ("GET", "POST") else 404, "bulunamadı")

    def env(self):
        """The base's state plus the package's own torrent.env (DD-203)."""
        env = self.ctx.env()
        env.update(self.ctx.read_env(os.path.join(os.path.dirname(self.worker_path), "torrent.env")))
        return env

    def durum(self):
        env = self.env()
        try:
            unit = self.ayar.unit_name(env)
        except Exception:
            unit = ""
        rc, _, _ = self.ctx.run(["systemctl", "is-active", "--quiet", unit], timeout=10) if unit else (1, "", "")
        return dict(self.ayar.durum(env), installed=True, running=rc == 0, unit=unit)

    def change(self, req, action):
        data = req.data if isinstance(req.data, dict) else {}
        # Shape and limits are checked here too, so a bad request never starts the worker.
        if action == "hesap":
            if not data or not set(data) <= {"username", "password"}:
                raise self.ctx.error(400, "Hesap alanı geçersiz.")
            if "username" in data and not (isinstance(data["username"], str) and self.ayar.USERNAME_RE.fullmatch(data["username"])):
                raise self.ctx.error(400, "Kullanıcı adı geçersiz (1–64 harf/rakam/._@-).")
            if "password" in data and not (isinstance(data["password"], str) and 8 <= len(data["password"]) <= 256
                                           and all(ord(x) >= 32 for x in data["password"])):
                raise self.ctx.error(400, "Parola 8–256 karakter olmalı.")
            detail = " ve ".join(k for k, v in (("kullanıcı adı", "username" in data), ("parola", "password" in data)) if v)
        else:
            if set(data) != {"save"} or not isinstance(data["save"], str) or len(data["save"]) > 1024:
                raise self.ctx.error(400, "Dizin alanı geçersiz.")
            detail = data["save"]
        code, result = self.ctx.worker(["/usr/bin/python3", self.worker_path, "--lib", self.lib_dir, "--state", self.ctx.state_path(), action], data)
        req.audit(action, detail, code == 200)
        if code != 200:
            raise self.ctx.error(code, result.get("error", "qBittorrent ayarı uygulanamadı") if isinstance(result, dict) else "qBittorrent ayarı uygulanamadı")
        return 200, result
