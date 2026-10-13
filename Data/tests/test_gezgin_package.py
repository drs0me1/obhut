"""Gezgin package (DD-262): the install-form worker and Podman adapter ayar.py, the publication check
yayin.py and the package files. No real Gezgin, Caddy, Podman or systemd: commands are faked, the data
folder and the rendered package folder are scratch files."""
import contextlib
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
PACKAGE = REPO / "magaza" / "gezgin"
sys.path.insert(0, str(REPO / "panel"))
import master_settings as settings  # noqa: E402


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


ayar = load("gezgin_ayar_test", PACKAGE / "ayar.py")
yayin = load("gezgin_yayin_test", PACKAGE / "yayin.py")
# The shape Caddy's `hash-password` prints: bcrypt, cost 14, 22 salt and 31 hash characters.
HASH = "$2a$14$R9h/cIPz0gi.URNNX3kh2OPST9/PgBkqquzi.Ss7KIUgO2t0jWMUW"
IMAGE = "ghcr.io/drs0me1/gezgin"
OLD = IMAGE + "@sha256:" + "b5" * 32
NEW = IMAGE + "@sha256:" + "11" * 32
CHANNEL = IMAGE + ":1.0"
EMPTY_ILK = "# Gezgin: ilk açılışın yönetici hesabı yalnız veritabanı yokken burada durur (DD-262).\n"


def render(text, values):
    return re.sub(r"__([A-Z][A-Z0-9_]*)__", lambda m: values.get(m[1], m[0]), text)


class Scratch(unittest.TestCase):
    """A rendered package folder, a data folder, a Quadlet folder and a recording command runner."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gezgin-pkg-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        for rel in ("run", "quadlet", "etc", "dns", "srv", "data"):
            (self.root / rel).mkdir()
        (self.root / "overrides").mkdir(mode=0o700)
        self.env = {
            "SETTINGS_FILE": str(self.root / "etc/settings.json"), "SETTINGS_PENDING_FILE": str(self.root / "etc/pending.json"),
            "SETTINGS_DNS_FILE": str(self.root / "dns/konsol.conf"), "DNSMASQ_CONF_FILE": str(self.root / "dns/base.conf"),
            "DNSMASQ_CONF_DIR": str(self.root / "dns"), "MODULES_FILE": str(self.root / "modules"),
            "MODULES_DIR": str(self.root / "mods"), "RUNTIME_DIR": str(self.root / "run"),
            "KONTEYNER_BIRIM_DIR": str(self.root / "quadlet"), "PACKAGE_OVERRIDES_DIR": str(self.root / "overrides"),
            "SERVER_ROOT": str(self.root / "srv"), "LOCAL_DOMAIN": "test",
            "GEZGIN_UI_PORT": "62983", "GEZGIN_DATA_DIR": "/var/lib/gezgin", "GEZGIN_CONTAINER": "gezgin",
            "GEZGIN_NETWORK": "gezgin", "GEZGIN_IMAGE": OLD, "GEZGIN_IMAGE_KANAL": CHANNEL,
        }
        (self.root / "modules").write_text("gezgin\tcalisiyor\n")
        self.state = self.root / "state.env"
        self.state.write_text("".join(k + "=" + v + "\n" for k, v in self.env.items()))
        # DD-203: the rendered package folder with its own settings file; the worker reads it next to itself.
        self.pkg = self.root / "mods" / "gezgin"
        self.pkg.mkdir(parents=True)
        values = dict(self.env, DOWNLOADS_UID="1000", DOWNLOADS_GID="1000", FILES_PANEL_TRASH=".cop", FILES_ARCHIVE_DIR=".arsiv",
                      TIMEZONE="UTC", SBIN_DIR="/usr/local/sbin", STATE_FILE=str(self.state))
        for name in ("ayar.py", "yayin.py", "paket.env", "gezgin.container"):
            (self.pkg / name).write_text(render((PACKAGE / name).read_text(), values))
        (self.pkg / "gezgin.env").write_text(render((PACKAGE / "gezgin.env").read_text(), values).replace(
            (PACKAGE / "gezgin.env").read_text().split("GEZGIN_IMAGE=", 1)[1].split("\n", 1)[0], OLD))
        self.quadlet = self.pkg / "gezgin.container"
        self.placed = self.root / "quadlet" / "gezgin.container"
        self.placed.write_bytes(self.quadlet.read_bytes())
        self.data = self.root / "data"
        self.ilk = self.data / "ilk.env"
        self.ilk.write_text(EMPTY_ILK)
        self.ilk.chmod(0o600)
        self.seed = self.root / "run" / "modul-gezgin.kur"
        self.calls, self.fail_cmd, self.active, self.hash_out, self.inputs = [], None, True, HASH + "\n", []
        self.addCleanup(patch.stopall)
        patch.object(settings, "run", side_effect=self.fake_run).start()
        patch.object(ayar, "PACKAGE_DIR", str(self.pkg)).start()
        # The real check refuses anything outside /var/lib; here the data folder is a scratch folder.
        patch.object(ayar, "data_dir", lambda env: self.data).start()
        self.ui_waits = []
        patch.object(ayar, "wait_ui", side_effect=lambda env, seconds=40: self.ui_waits.append(env["GEZGIN_UI_PORT"])).start()

    def fake_run(self, argv, **kwargs):
        argv = list(argv)
        self.calls.append(argv)
        if self.fail_cmd and self.fail_cmd in " ".join(argv):
            self.fail_cmd = None
            if not kwargs.get("check", True):
                return subprocess.CompletedProcess(argv, 5, "", "")
            raise settings.SettingsError("injected failure")
        out, code = "", 0
        if argv == ["caddy", "hash-password"]:
            self.inputs.append(kwargs.get("input"))
            out = self.hash_out
        elif argv[:3] == ["systemctl", "is-active", "--quiet"]:
            code = 0 if self.active else 3
            settings.require(not kwargs.get("check", True) or code == 0, "Test servisi durmuş")
        return subprocess.CompletedProcess(argv, code, out, "")

    def systemctl(self):
        return [c[1] for c in self.calls if c[0] == "systemctl"]

    def main(self, argv, stdin=""):
        out = io.StringIO()
        with patch("sys.argv", ["ayar.py", "--lib", str(REPO / "panel"), "--state", str(self.state), *argv]), \
                patch("sys.stdin", io.StringIO(stdin)), contextlib.redirect_stdout(out):
            try:
                ayar.main()
            except SystemExit as stop:
                return stop.code, json.loads(out.getvalue())
        return 0, json.loads(out.getvalue())


class InstallWorkerTests(Scratch):
    """DD-210: the App Store install form. kur-hazirla validates the first administrator and stores only
    the bcrypt hash in a private seed; kur-uygula hands it to the first start; kur-geri restores."""
    def setUp(self):
        super().setUp()
        self.form = {"username": "operator", "password": "first-install-phrase"}

    def test_kur_hazirla_validates_before_hashing_and_keeps_only_the_hash(self):
        bad = [None, "text", {}, {"username": "operator"}, dict(self.form, password=""), dict(self.form, password="eleven-char"),
               dict(self.form, password="x" * 73), dict(self.form, password="ş" * 37), dict(self.form, password="tab\there-phrase"),
               dict(self.form, password="line\nbreak-phrase"), dict(self.form, username="bad user"), dict(self.form, username=""),
               dict(self.form, username="a" * 65), dict(self.form, password=12345678901234), dict(self.form, extra=1)]
        for data in bad:
            with self.subTest(data=data), self.assertRaises(settings.SettingsError):
                ayar.kur_hazirla(self.env, data, str(self.state), str(self.seed))
        self.assertEqual(self.calls, [], "a refused form runs nothing, not even the hash")
        self.assertFalse(self.seed.exists(), "a refused form leaves no seed")
        with self.assertRaises(settings.SettingsError):
            ayar.kur_hazirla(self.env, self.form, str(self.state), str(self.root / "elsewhere.kur"))
        self.assertFalse((self.root / "elsewhere.kur").exists(), "the seed lives only in the runtime folder")
        self.calls.clear()
        # 72 bytes is bcrypt's whole input: the longest password still counts every byte.
        self.assertEqual(ayar.kur_hazirla(self.env, dict(self.form, password="ş" * 36), str(self.state), str(self.seed))["ok"], True)
        result = ayar.kur_hazirla(self.env, self.form, str(self.state), str(self.seed))
        self.assertEqual(result, {"ok": True, "username": "operator"})
        self.assertEqual(self.seed.stat().st_mode & 0o777, 0o600)
        raw = self.seed.read_text()
        self.assertNotIn("first-install-phrase", raw)
        self.assertEqual(json.loads(raw), {"username": "operator", "hash": HASH})
        # The password reaches Caddy only on standard input, as one line; never an argument.
        self.assertEqual(self.calls, [["caddy", "hash-password"]] * 2)
        self.assertEqual(self.inputs[-1], "first-install-phrase\n")
        self.assertEqual(self.systemctl(), [], "preparing an install touches no service")
        self.assertEqual(self.ilk.read_text(), EMPTY_ILK, "ilk.env is not touched yet")

    def test_a_hash_that_is_not_bcrypt_is_refused(self):
        for out in ("", "plain\n", HASH[:-1] + "\n", "$2a$14$" + "!" * 53 + "\n"):
            self.hash_out = out
            with self.subTest(out=out), self.assertRaises(settings.SettingsError):
                ayar.kur_hazirla(self.env, self.form, str(self.state), str(self.seed))
        self.assertFalse(self.seed.exists())

    def test_kur_uygula_hands_the_account_to_the_first_start_and_kur_geri_restores(self):
        ayar.kur_hazirla(self.env, self.form, str(self.state), str(self.seed))
        self.calls.clear()
        self.assertEqual(ayar.kur_uygula(self.env, str(self.seed)), {"ok": True})
        text = self.ilk.read_text()
        # Podman reads the file itself: the hash's "$" stays literal, no quoting or escaping.
        self.assertIn("\nGEZGIN_USERNAME=operator\nGEZGIN_PASSWORD=%s\n" % HASH, text)
        self.assertNotIn("first-install-phrase", text)
        self.assertEqual(self.ilk.stat().st_mode & 0o777, 0o600)
        backup = Path(str(self.seed) + ".onceki")
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.calls, [], "no service command: the container has not started yet")
        self.assertEqual(ayar.kur_geri(self.env, str(self.seed)), {"ok": True})
        self.assertEqual(self.ilk.read_text(), EMPTY_ILK, "a failed install returns the file it found")
        # With no file before, a failed install leaves none.
        self.ilk.unlink()
        ayar.kur_uygula(self.env, str(self.seed))
        self.assertTrue(self.ilk.exists())
        ayar.kur_geri(self.env, str(self.seed))
        self.assertFalse(self.ilk.exists())

    def test_kur_uygula_refuses_a_seed_that_is_not_private_or_not_its_shape(self):
        ayar.kur_hazirla(self.env, self.form, str(self.state), str(self.seed))
        self.seed.chmod(0o644)
        with self.assertRaises(settings.SettingsError):
            ayar.kur_uygula(self.env, str(self.seed))
        self.seed.chmod(0o600)
        link = self.root / "run" / "modul-link.kur"
        link.symlink_to(self.seed)
        with self.assertRaises((settings.SettingsError, OSError)):
            ayar.kur_uygula(self.env, str(link))
        data = json.loads(self.seed.read_text())
        for broken in (dict(data, username="bad user"), dict(data, hash="plain"), dict(data, hash=HASH + "\nGEZGIN_X=1"),
                       dict(data, extra=1), {"username": "operator"}):
            with self.subTest(broken=broken), self.assertRaises(settings.SettingsError):
                self.seed.write_text(json.dumps(broken))
                ayar.kur_uygula(self.env, str(self.seed))
        self.assertEqual(self.ilk.read_text(), EMPTY_ILK)
        self.seed.unlink()
        with self.assertRaises((settings.SettingsError, OSError)):
            ayar.kur_uygula(self.env, str(self.seed))
        ayar.kur_geri(self.env, str(self.seed))  # nothing applied: nothing to restore
        self.assertEqual(self.ilk.read_text(), EMPTY_ILK)

    def test_cli_reads_stdin_never_prints_the_password_and_has_no_podman_edit(self):
        code, body = self.main(["kur-hazirla", "--tohum", str(self.seed)], json.dumps(self.form))
        self.assertEqual((code, body), (0, {"ok": True, "username": "operator"}))
        self.assertEqual(self.main(["kur-uygula", "--tohum", str(self.seed)]), (0, {"ok": True}))
        self.assertEqual(self.main(["kur-geri", "--tohum", str(self.seed)]), (0, {"ok": True}))
        code, body = self.main(["kur-hazirla", "--tohum", str(self.seed)], json.dumps(dict(self.form, password="short")))
        self.assertEqual((code, body), (1, {"error": "Parola en az 12 karakter olmalı."}))
        code, body = self.main(["konteyner-ayar"], json.dumps({"revision": "0" * 64, "config": {}}))
        self.assertEqual((code, body["status"]), (1, 400))
        self.assertIn("Gezgin'in içindedir", body["error"])
        with patch("sys.argv", ["ayar.py", "--state", str(self.state), "kur-uygula"]), patch("sys.stderr", io.StringIO()), \
                self.assertRaises(SystemExit) as stop:
            ayar.main()  # the seed path is required
        self.assertEqual(stop.exception.code, 2)

    def test_the_data_folder_must_be_under_var_lib(self):
        check = load("gezgin_ayar_check", PACKAGE / "ayar.py").data_dir
        self.assertEqual(check({"GEZGIN_DATA_DIR": "/var/lib/gezgin"}), Path("/var/lib/gezgin"))
        for bad in ("", "/var/lib/", "/srv/gezgin", "/var/lib/../etc", "var/lib/gezgin", "/var/library/x"):
            with self.subTest(bad=bad), self.assertRaises(settings.SettingsError):
                check({"GEZGIN_DATA_DIR": bad})


class AdapterTests(Scratch):
    """The Podman page's adapter: no editable field; the revision follows every file a change could touch."""
    def test_config_has_nothing_to_edit_and_names_the_protected_mounts(self):
        view = ayar.container_config(self.env)
        self.assertEqual((view["config"], view["editable"], view["effective_autostart"]), ({"listener_port": 62983}, [], True))
        self.assertEqual([m["target"] for m in view["protected_mounts"]], ["/srv", "/database", "/config"])
        self.assertEqual(view["protected_mounts"][0]["source"], self.env["SERVER_ROOT"])
        (self.root / "modules").write_text("gezgin\tdurduruldu\n")
        stopped = ayar.container_config(self.env)
        self.assertFalse(stopped["effective_autostart"])
        self.assertNotEqual(stopped["revision"], view["revision"], "the registry line is part of the revision")
        self.placed.write_text(self.placed.read_text() + "# changed\n")
        self.assertNotEqual(ayar.container_config(self.env)["revision"], stopped["revision"])
        self.assertEqual(self.calls, [], "reading runs no command")


class ImageUpdateTests(Scratch):
    """DD-214: the package moves its pinned image on explicit request; rollback restores every file."""
    def setUp(self):
        super().setUp()
        self.override = self.root / "overrides" / "gezgin.env"
        self.remote_digest = "sha256:" + "11" * 32
        self.local_digest = "sha256:" + "22" * 32
        self.manifest = self.pkg / "paket.env"
        self.assertIn('PAKET_IMAJ="%s"\n' % OLD, self.manifest.read_text())
        self.assertIn("Image=%s\n" % OLD, self.quadlet.read_text())
        self.files = [self.quadlet, self.manifest, self.placed]

    def fake_run(self, argv, **kwargs):
        argv = list(argv)
        if argv[:1] != ["podman"]:
            return super().fake_run(argv, **kwargs)
        self.calls.append(argv)
        if self.fail_cmd and self.fail_cmd in " ".join(argv):
            self.fail_cmd = None
            raise settings.SettingsError("injected failure")
        out = ""
        if argv[:2] == ["podman", "info"]:
            out = "amd64\n"
        elif argv[:3] == ["podman", "image", "inspect"] and "--format" not in argv:
            out = json.dumps([{"Id": "a" * 64, "Digest": "sha256:" + "b5" * 32, "RepoDigests": [IMAGE + "@" + self.local_digest, OLD]}])
        elif argv[:3] == ["podman", "manifest", "inspect"]:
            out = json.dumps({"manifests": [{"digest": self.remote_digest, "platform": {"architecture": "amd64", "os": "linux"}}]})
        elif argv[:2] == ["podman", "inspect"]:
            out = NEW + "\n"
        elif argv[:3] == ["podman", "image", "inspect"]:
            fmt = argv[argv.index("--format") + 1]
            out = ("1.0.1\n" if "version" in fmt else ("a" * 64 if argv[-1] == OLD else "c" * 64) + "\n")
        return subprocess.CompletedProcess(argv, 0, out, "")

    def run_update(self, revision=None):
        env = ayar.package_env(self.env)
        return ayar.konteyner_guncelle(env, {"revision": revision or ayar.container_config(self.env)["revision"]}, str(self.state))

    def test_an_up_to_date_channel_changes_nothing(self):
        self.local_digest = self.remote_digest
        before = [p.read_bytes() for p in self.files]
        result = self.run_update()
        self.assertEqual((result["ok"], result["changed"], result["image"]), (True, False, OLD))
        self.assertEqual([p.read_bytes() for p in self.files], before)
        self.assertFalse(self.override.exists())
        self.assertFalse([c for c in self.calls if c[:2] == ["podman", "pull"]])
        self.assertEqual(self.systemctl(), [])

    def test_update_pins_the_new_digest_everywhere_restarts_verifies_and_drops_the_old_image(self):
        result = self.run_update()
        self.assertEqual((result["changed"], result["image"], result["previous"], result["version"]), (True, NEW, OLD, "1.0.1"))
        self.assertEqual(self.override.read_text(), "GEZGIN_IMAGE=%s\n" % NEW)
        self.assertEqual(self.override.stat().st_mode & 0o777, 0o600)
        for path in (self.quadlet, self.placed):
            self.assertIn("Image=%s\n" % NEW, path.read_text())
            self.assertNotIn(OLD, path.read_text())
        self.assertIn('PAKET_IMAJ="%s"\n' % NEW, self.manifest.read_text())
        self.assertEqual([c for c in self.calls if c[:2] == ["podman", "pull"]], [["podman", "pull", "-q", NEW]])
        self.assertEqual(self.systemctl(), ["is-active", "daemon-reload", "restart", "is-active"])
        self.assertEqual(self.ui_waits, ["62983"])
        self.assertIn(["podman", "rmi", "a" * 64], self.calls, "the previous image is removed only after success")
        first_service = min(i for i, c in enumerate(self.calls) if c[:1] == ["systemctl"])
        self.assertLess(self.calls.index(["podman", "pull", "-q", NEW]), first_service)
        # The chosen image survives a regenerated package folder (DD-214, DD-203).
        self.assertEqual(settings.package_env(self.env, "gezgin")["GEZGIN_IMAGE"], NEW)

    def test_a_failed_restart_restores_every_file_and_the_previous_service(self):
        before = [p.read_bytes() for p in self.files]
        self.fail_cmd = "restart gezgin.service"
        with self.assertRaises(settings.SettingsError) as err:
            self.run_update()
        self.assertEqual(err.exception.status, 502)
        self.assertEqual([p.read_bytes() for p in self.files], before)
        self.assertFalse(self.override.exists())
        self.assertEqual(self.systemctl(), ["is-active", "daemon-reload", "restart", "daemon-reload", "restart", "is-active"])
        self.assertNotIn(["podman", "rmi", "a" * 64], self.calls)

    def test_stale_revision_and_missing_channel_change_nothing(self):
        before = [p.read_bytes() for p in self.files]
        with self.assertRaises(settings.SettingsError) as err:
            self.run_update("0" * 64)
        self.assertEqual(err.exception.status, 409)
        revision = ayar.container_config(self.env)["revision"]
        for channel in ("", NEW):
            with self.subTest(channel=channel), self.assertRaises(settings.SettingsError):
                ayar.konteyner_guncelle(dict(ayar.package_env(self.env), GEZGIN_IMAGE_KANAL=channel), {"revision": revision}, str(self.state))
        self.assertEqual([p.read_bytes() for p in self.files], before)
        self.assertEqual(self.calls, [])


class Gezgin(http.server.BaseHTTPRequestHandler):
    """Answers like Gezgin: the configured status per path; records the Host header."""
    answers, hosts = {}, []

    def do_GET(self):
        type(self).hosts.append(self.headers.get("Host"))
        self.send_response(type(self).answers.get(self.path, 404))
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


class PublicationTests(unittest.TestCase):
    """DD-199: turning the public row on proves the running app answers and requires its sign-in."""
    def setUp(self):
        Gezgin.answers, Gezgin.hosts = {"/health": 200, "/api/resources/": 401}, []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gezgin)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(patch.stopall)
        patch.object(yayin, "package_env", lambda env: {"GEZGIN_UI_PORT": str(self.server.server_address[1])}).start()

    def test_the_probe_passes_only_with_health_and_a_closed_api(self):
        yayin.security({}, "dosya.example.org", probe=True)
        self.assertEqual(Gezgin.hosts, ["dosya.example.org"] * 2)
        for answers, message in (({"/health": 503, "/api/resources/": 401}, "yanıt vermiyor"),
                                 ({"/health": 200, "/api/resources/": 200}, "giriş kapısı"),
                                 ({"/health": 200, "/api/resources/": 403}, "giriş kapısı")):
            Gezgin.answers = answers
            with self.subTest(answers=answers), self.assertRaisesRegex(settings.SettingsError, message):
                yayin.security({}, "dosya.example.org", probe=True)

    def test_listing_and_rendering_probe_nothing(self):
        Gezgin.answers = {}
        with patch.object(yayin.http.client, "HTTPConnection", side_effect=AssertionError("no network")):
            self.assertIsNone(yayin.security({}, "dosya.example.org"))
        self.assertEqual(Gezgin.hosts, [])

    def test_a_closed_port_raises_for_the_caller_to_report(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with patch.object(yayin, "package_env", lambda env: {"GEZGIN_UI_PORT": str(port)}), self.assertRaises(OSError):
            yayin.security({}, "dosya.example.org", probe=True)


class PackageFileTests(unittest.TestCase):
    """The package's files against the base's rules: every placeholder resolves, the Quadlet keeps Gezgin on
    loopback with the Files account and no capability, the form matches the worker's limits."""
    def setUp(self):
        self.manifest = settings.env_read(PACKAGE / "paket.env")
        self.own = settings.env_read(PACKAGE / "gezgin.env")
        self.quadlet = (PACKAGE / "gezgin.container").read_text()

    def test_every_placeholder_comes_from_the_package_or_the_base(self):
        base = settings.env_read(REPO / "config" / "defaults.env")
        for path in sorted(PACKAGE.iterdir()):
            for key in sorted(set(re.findall(r"__([A-Z][A-Z0-9_]*)__", path.read_text()))):
                with self.subTest(file=path.name, key=key):
                    # LOCAL_DOMAIN is the installer's only question (state, not defaults).
                    self.assertTrue(key in self.own or key in base or key == "LOCAL_DOMAIN", key)

    def test_the_image_is_pinned_and_the_port_is_unique(self):
        self.assertRegex(self.own["GEZGIN_IMAGE"], r"^ghcr\.io/drs0me1/gezgin@sha256:[0-9a-f]{64}$")
        self.assertEqual(self.own["GEZGIN_IMAGE_KANAL"], "ghcr.io/drs0me1/gezgin:1.0")
        port = int(self.own["GEZGIN_UI_PORT"])
        self.assertFalse(32768 <= port <= 60999, "outside Linux's outgoing port range")
        others = [(REPO / "config" / "defaults.env").read_text()] + [p.read_text() for p in (REPO / "magaza").glob("*/*.env")
                                                                   if p.parent.name != "gezgin"]
        self.assertFalse([t for t in others if re.search(r"=%d\b" % port, t)], "no other service uses the port")

    def test_the_quadlet_keeps_gezgin_on_loopback_with_the_files_account(self):
        lines = self.quadlet.splitlines()
        self.assertEqual([l for l in lines if l.startswith("PublishPort=")], ["PublishPort=127.0.0.1:__GEZGIN_UI_PORT__:8080/tcp"])
        for line in ("Image=__GEZGIN_IMAGE__", "Pull=never", "Network=__GEZGIN_NETWORK__", "User=__DOWNLOADS_UID__",
                     "Group=__DOWNLOADS_GID__", "DropCapability=all", "NoNewPrivileges=true", "EnvironmentFile=__GEZGIN_DATA_DIR__/ilk.env"):
            self.assertIn(line, lines)
        self.assertEqual([l for l in lines if l.startswith("Volume=")], [
            "Volume=__GEZGIN_DATA_DIR__/database:/database", "Volume=__GEZGIN_DATA_DIR__/config:/config",
            "Volume=__SERVER_ROOT__:/srv",
            "Volume=__GEZGIN_DATA_DIR__/bos:/srv/__FILES_PANEL_TRASH__:ro", "Volume=__GEZGIN_DATA_DIR__/bos:/srv/__FILES_ARCHIVE_DIR__:ro"])
        self.assertFalse([l for l in lines if re.match(r"(AutoUpdate|AddCapability|Requires|PodmanArgs=.*--privileged)", l)])
        self.assertEqual(self.manifest["PAKET_YAYIN_UPSTREAM"], "127.0.0.1:__GEZGIN_UI_PORT__")
        self.assertEqual(self.manifest["PAKET_KONTEYNER_AG"], "__GEZGIN_NETWORK__")

    def test_the_form_matches_the_worker_and_there_is_no_konsol_page(self):
        doc = json.loads((PACKAGE / "konsol.json").read_text())
        fields = {f["ad"]: f for f in doc["form"]["alanlar"]}
        self.assertEqual(sorted(fields), ["password", "username"])
        self.assertEqual((fields["password"]["en_az"], fields["password"]["en_cok"]), (ayar.PASSWORD_MIN, ayar.PASSWORD_MAX_BYTES))
        self.assertEqual(fields["username"]["desen"], ayar.USERNAME_RE.pattern.replace("-]", "\\-]"))
        self.assertNotIn("sayfa", doc)
        self.assertFalse({"PAKET_SAYFA", "PAKET_API"} & set(self.manifest))
        self.assertEqual(self.manifest["PAKET_KUR_AYAR"], "ayar.py")

    def test_a_same_named_container_of_another_manager_stops_the_package(self):
        """Quadlet replaces a container of the same name: one made in Konsol before the package (its
        definition or a running one) must be removed first, never taken over."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bin").mkdir()
            (root / "state" / "definitions").mkdir(parents=True)
            podman = root / "bin" / "podman"
            podman.write_text('#!/bin/sh\ncase "$1 $2" in\n  "container exists") exit "$KAP_VAR" ;;\n'
                              '  "container inspect") printf "%s\\n" "$KAP_BIRIM" ;;\nesac\n')
            podman.chmod(0o755)
            script = ('fail_step() { echo "DUR: $*"; exit 3; }; source "$1"; GEZGIN_CONTAINER=gezgin; '
                      'KONTEYNER_STATE_DIR="$2"; gezgin_eski_yok && echo GEÇ')

            def guard(exists, unit=""):
                env = {"PATH": "%s:%s" % (root / "bin", os.environ["PATH"]), "KAP_VAR": "0" if exists else "1", "KAP_BIRIM": unit}
                return subprocess.run(["bash", "-c", script, "_", str(PACKAGE / "kanca"), str(root / "state")],
                                      env=env, capture_output=True, text=True).stdout.strip()
            self.assertEqual(guard(False), "GEÇ")
            self.assertEqual(guard(True, "gezgin.service"), "GEÇ", "the package's own container")
            self.assertIn("başka bir konteyner var (konsol-gezgin.service)", guard(True, "konsol-gezgin.service"))
            self.assertIn("elle kurulmuş", guard(True))
            (root / "state" / "definitions" / "gezgin.json").write_text("{}")
            self.assertIn("konteyner tanımı var", guard(False))

    def test_the_hook_writes_the_account_before_the_first_start_and_empties_it_after(self):
        text = (PACKAGE / "kanca").read_text()
        body = text[text.index("paket_kur() {"):]
        body = body[:body.index("\n}\n")]
        order = [body.index(s) for s in ("gezgin_tohum uygula", 'systemctl start "$(gezgin_unit_name)"', "gezgin_verify --ilk",
                                          "gezgin_ilk_bosalt", "paket_adlar_ac")]
        self.assertEqual(order, sorted(order))
        masked = subprocess.run(["bash", "-c", 'source "$1"; paket_gunluk_suz', "_", str(PACKAGE / "kanca")],
                                input="User 'admin' initialized with randomly generated password: Zx9-secret (to be changed)\n",
                                capture_output=True, text=True, check=True, env={"PATH": os.environ["PATH"]}).stdout
        self.assertNotIn("Zx9-secret", masked)
        self.assertIn("randomly generated password: ••••", masked)


if __name__ == "__main__":
    unittest.main()
