"""DD-268: obhut, the root CLI for the server's state and its recovery over SSH. Commands are checked
against a fake backend (the exact requests they send and what they print); the socket client is checked
against the real backend on a Unix socket, as root's own caller ("yerel")."""
import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import test_resources
from test_overview import Fixture

DATA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DATA / "panel"))
import master_obhut as obhut  # noqa: E402


class FakeKonsol:
    """Answers GETs from `reads` (a route → reply or an ObhutError) and records POSTs."""

    def __init__(self, reads, replies=None):
        self.reads, self.replies, self.posts = reads, replies or {}, []

    def get(self, route):
        value = self.reads[route]
        if isinstance(value, Exception):
            raise value
        return value

    def post(self, route, data):
        self.posts.append((route, data))
        return self.replies.get(route, {"ok": True})


def run(argv, konsol, root=True):
    out, err = io.StringIO(), io.StringIO()
    with patch.object(obhut, "Konsol", return_value=konsol), patch.object(obhut, "read_env", return_value={}), \
         patch.object(obhut.os, "geteuid", return_value=0 if root else 1000), \
         contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = obhut.main(argv)
    return code, out.getvalue(), err.getvalue()


APPS = {"items": [
    {"id": "paket:gezgin", "ad": "Gezgin", "modul": "gezgin", "konteyner": "gezgin", "durum": "calisiyor",
     "eylemler": ["durdur", "yeniden-baslat", "kaldir"], "revizyon": "r1"},
    {"id": "konteyner:notlar", "ad": "notlar", "modul": None, "konteyner": "notlar", "durum": "durduruldu",
     "eylemler": ["baslat", "kaldir"], "revizyon": None}]}
PUBS = {"revizyon": "v1", "adaylar": [
    {"id": "panel", "ad": "Konsol", "servis": "panel", "tailscale": True, "internet": True, "alan_adi": "konsol.example.org"},
    {"id": "paket:gezgin", "ad": "Gezgin", "servis": "gezgin", "tailscale": True, "internet": False, "alan_adi": ""},
    {"id": "konteyner:kutu", "ad": "kutu", "servis": None, "tailscale": False, "internet": False, "alan_adi": ""}]}


class CommandTests(unittest.TestCase):
    def test_status_reads_the_backend_and_falls_back_to_systemd(self):
        konsol = FakeKonsol({
            "/api/konsol/kaynaklar": {"surum": "1.2.0", "version": "v2-252", "host": "sunucu", "domain": "ev",
                                      "net": {"tailscale": "100.64.0.2", "wan": "203.0.113.10"}},
            "/api/konsol/saglik": {"status": "warn", "checks": [{"name": "Disk", "status": "warn", "detail": "%91 dolu"},
                                                                 {"name": "Servisler", "status": "ok", "detail": ""}]},
            "/api/konsol/uygulamalar": APPS, "/api/konsol/bekleyen": {"bekleyen": {"id": "abc"}},
            "/api/konsol/guncelleme": {"kurulu": "v2-252", "son": "v2-253", "son_surum": "1.3.0", "yeni": True}})
        code, out, _ = run(["durum"], konsol)
        self.assertEqual(code, 0)
        for text in ("Obhut 1.2.0 (yapı v2-252) · sunucu", "Konsol: http://panel.ev (Tailscale)",
                     "Adresler: Tailscale 100.64.0.2 · internet 203.0.113.10", "Yeni sürüm var: 1.3.0 (sudo obhut guncelle)",
                     "Sağlık: dikkat", "  ! Disk: %91 dolu", "paket:gezgin", "sudo obhut geri-al"):
            self.assertIn(text, out)
        self.assertNotIn("Servisler:", out)
        code, out, _ = run(["durum", "--json"], konsol)
        self.assertEqual(json.loads(out)["uygulamalar"], APPS)
        # The backend does not answer: the units from systemd and the way to repair.
        down = FakeKonsol({"/api/konsol/kaynaklar": obhut.ObhutError("Konsol'un arka ucuna ulaşılamadı")})
        with patch.object(obhut, "unit_states", return_value={"caddy": "active", "master-panel": "failed"}):
            code, out, _ = run(["durum"], down)
        self.assertEqual(code, 1)
        self.assertIn("Konsol yanıt vermiyor", out)
        self.assertIn("master-panel", out)
        self.assertIn("sudo obhut onar", out)

    def test_checks_repairs_and_the_account_run_the_root_tools(self):
        with patch.object(obhut, "run_tool", return_value=0) as tool:
            self.assertEqual(run(["denetle"], FakeKonsol({}))[0], 0)
            self.assertEqual(run(["onar"], FakeKonsol({}))[0], 0)
            self.assertEqual(run(["hesap", "sifirla"], FakeKonsol({}))[0], 0)
        self.assertEqual([c.args for c in tool.call_args_list], [("master-onar", "--denetle"), ("master-onar",), ("master-konsol", "sifirla")])

    def test_applications_start_and_stop_with_their_revision(self):
        konsol = FakeKonsol({"/api/konsol/uygulamalar": APPS})
        code, out, _ = run(["uygulama", "liste"], konsol)
        self.assertIn("konteyner:notlar", out)
        self.assertEqual(run(["uygulama", "durdur", "gezgin"], konsol)[0], 0)
        self.assertEqual(run(["uygulama", "baslat", "konteyner:notlar"], konsol)[0], 0)
        self.assertEqual(konsol.posts, [("/api/konsol/uygulamalar/islem", {"id": "paket:gezgin", "eylem": "durdur", "revizyon": "r1"}),
                                        ("/api/konsol/uygulamalar/islem", {"id": "konteyner:notlar", "eylem": "baslat"})])
        code, _, err = run(["uygulama", "baslat", "gezgin"], konsol)
        self.assertEqual(code, 1)
        self.assertIn("Gezgin şu an başlatılamaz (durum: calisiyor).", err)
        self.assertEqual(run(["uygulama", "durdur", "yok"], konsol)[0], 1)
        self.assertEqual(run(["uygulama", "durdur"], konsol)[0], 2)
        self.assertEqual(len(konsol.posts), 2)

    def test_internet_names_close_and_the_tailnet_name_stays(self):
        konsol = FakeKonsol({"/api/konsol/yayinlar": PUBS})
        code, out, _ = run(["yayin", "liste"], konsol)
        self.assertIn("panel", out)
        self.assertIn("konsol.example.org", out)
        self.assertNotIn("konteyner:kutu", out, "a container that is not published is no publication")
        self.assertEqual(run(["yayin", "kapat", "panel"], konsol)[0], 0)
        self.assertEqual(konsol.posts, [("/api/konsol/ayarlar/uygula", {"revision": "v1", "web": {
            "service": "panel", "tail": True, "enabled": False, "domain": "konsol.example.org"}})])
        # Only the open ones; a tailnet-only publication is left alone.
        konsol.posts.clear()
        self.assertEqual(run(["yayin", "kapat", "--hepsi"], konsol)[0], 0)
        self.assertEqual([p[1]["web"]["service"] for p in konsol.posts], ["panel"])
        konsol.posts.clear()
        code, out, _ = run(["yayin", "kapat", "gezgin"], konsol)
        self.assertEqual((code, konsol.posts), (0, []))
        self.assertIn("İnternete açık yayın yok", out)
        self.assertEqual(run(["yayin", "kapat"], konsol)[0], 2)

    def test_a_pending_change_is_rolled_back(self):
        konsol = FakeKonsol({"/api/konsol/bekleyen": {"bekleyen": {"id": "abc"}}})
        self.assertEqual(run(["geri-al"], konsol)[0], 0)
        self.assertEqual(konsol.posts, [("/api/konsol/ayarlar/geri-al", {"id": "abc"})])
        nothing = FakeKonsol({"/api/konsol/bekleyen": {"bekleyen": None}})
        code, out, _ = run(["geri-al"], nothing)
        self.assertEqual((code, nothing.posts), (0, []))
        self.assertIn("Onay bekleyen bir ayar değişikliği yok.", out)

    def test_an_update_starts_only_when_newer_and_confirmed(self):
        current = FakeKonsol({"/api/konsol/guncelleme?yenile=1": {"kurulu": "v2-253", "son": "v2-252", "commit": "a" * 40,
                                                                   "kurulu_surum": "1.2.0", "yeni": False, "is": {"durum": "yok"}}})
        code, out, _ = run(["guncelle"], current)
        self.assertEqual((code, current.posts), (0, []))
        self.assertIn("Güncel: 1.2.0", out, "a build newer than GitHub's is not an update")
        newer = FakeKonsol({"/api/konsol/guncelleme?yenile=1": {"kurulu": "v2-252", "son": "v2-253", "commit": "b" * 40, "yeni": True, "is": {"durum": "yok"}}},
                           {"/api/konsol/guncelleme": {"surum": "v2-253"}})
        with patch.object(obhut.sys.stdin, "isatty", return_value=False):
            code, _, err = run(["guncelle"], newer)
        self.assertEqual((code, newer.posts), (1, []))
        self.assertIn("--evet", err)
        self.assertEqual(run(["guncelle", "--evet"], newer)[0], 0)
        self.assertEqual(newer.posts, [("/api/konsol/guncelleme", {"surum": "v2-253", "commit": "b" * 40})])

    def test_only_root_runs_it(self):
        konsol = FakeKonsol({})
        code, _, err = run(["durum"], konsol, root=False)
        self.assertEqual(code, 2)
        self.assertIn("sudo obhut durum", err)


class SocketTests(Fixture):
    def setUp(self):
        super().setUp()

        class Handler(test_resources.panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        _server, self.sock = test_resources.start_unix(self, Handler)

    def test_the_client_speaks_to_the_real_backend_as_its_local_caller(self):
        konsol = obhut.Konsol({"PANEL_SOCKET": self.sock, "LOCAL_DOMAIN": "test"})
        self.assertEqual(konsol.get("/api/konsol/kaynaklar")["domain"], "test")
        with self.assertRaises(obhut.ObhutError) as caught:
            konsol.post("/api/konsol/oturum/cikis", {"x": 1})
        self.assertIn("İstek biçimi geçersiz", str(caught.exception))
        # Another Host is refused by the backend's gate, and a missing socket is a plain error.
        with self.assertRaises(obhut.ObhutError):
            obhut.Konsol({"PANEL_SOCKET": self.sock, "LOCAL_DOMAIN": "baska"}).get("/api/konsol/kaynaklar")
        with self.assertRaises(obhut.ObhutError) as caught:
            obhut.Konsol({"PANEL_SOCKET": self.sock + ".yok", "LOCAL_DOMAIN": "test"}).get("/api/konsol/kaynaklar")
        self.assertIn("ulaşılamadı", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
