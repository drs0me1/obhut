"""Network settings HTTP gates/validation; no real WireGuard or systemd changes."""
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

import test_resources as resources

panel = resources.panel


class NetworkSettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state = Path(self.tmp.name) / "state.env"
        state.write_text("LOCAL_DOMAIN=test\n")
        self.p = panel.Panel(types.SimpleNamespace(state=str(state), allow_host=[]))
        class Handler(panel.Handler):
            def log_message(self, *_args):
                pass
        Handler.panel = self.p
        self.server = panel.Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.data = dict(scope="ui", dns="9.9.9.9, 2620:fe::fe", revision="a" * 64)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)

    def request(self, data=None, headers=None, path="/api/wg/nets/wg0/ayarlar"):
        headers = headers if headers is not None else {"X-Konsol":"1"}
        headers = {"Content-Type":"application/json", **headers}
        req = urllib.request.Request(self.base+path, data=json.dumps(self.data if data is None else data).encode(), headers=headers)
        try:
            response = urllib.request.urlopen(req, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def test_valid_request_delegates_once_without_reset_and_invalidates_settings_cache(self):
        self.p.settings_cache = (1, {"old":True})
        with patch.object(self.p,"wg_on",return_value=True), patch.object(self.p,"run",return_value=(0,"","")) as run:
            code, data = self.request()
            self.assertEqual(code,200,data)
            run.assert_called_once_with("net-settings","ui",self.data["dns"],self.data["revision"],net="wg0")
            self.assertEqual(data["dns"],self.data["dns"])
        self.assertEqual(self.p.settings_cache,(0,None))

    def test_gates_and_module_absence_never_invoke_helper(self):
        with patch.object(self.p,"run",side_effect=AssertionError("must not mutate")):
            for headers in ({}, {"X-Konsol":"1","Host":"evil.test"},
                            {"X-Konsol":"1","Sec-Fetch-Site":"cross-site"}):
                self.assertEqual(self.request(headers=headers)[0],403)
            with patch.object(self.p,"wg_on",return_value=False):
                self.assertEqual(self.request()[0],409)

    def test_bad_inputs_never_reach_helper(self):
        with patch.object(self.p,"wg_on",return_value=True), patch.object(self.p,"run",side_effect=AssertionError("invalid mutation")):
            for override in [{"scope":"all"},{"dns":None},{"dns":"dns.example"},{"dns":"999.1.1.1"},
                             {"dns":"1.1.1.1\n9.9.9.9"},{"dns":"1.1.1.1,,"},{"dns":":::"},
                             {"dns":"fe80::1%eth0"},{"dns":", ".join(["1.1.1.1"]*9)},
                             {"revision":None},{"revision":"bad"}]:
                with self.subTest(override=override):
                    self.assertEqual(self.request({**self.data,**override})[0],400)
            self.assertEqual(self.request(path="/api/wg/nets/notwg/ayarlar")[0],400)

    def test_conflict_or_apply_failure_is_not_reported_as_saved(self):
        with patch.object(self.p,"wg_on",return_value=True), patch.object(self.p,"run",return_value=(1,"","Ağ ayarları değişmiş")):
            code,data=self.request()
            self.assertEqual(code,409)
            self.assertIn("Ağ ayarları değişmiş",data["error"])

    def test_revision_matches_exact_registry_line_not_runtime_activity(self):
        line="wg0\t61001\tui\t10.8.0.1\t10.8.0.0/24\tfd00::1\tfd00::/112\t1.1.1.1\tTürkçe ağ"
        with patch.object(self.p,"wg_on",return_value=True), patch.object(self.p,"run") as run:
            for runtime in ("\t1\t2","\t0\t3"):
                run.return_value=(0,line+runtime+"\n","")
                self.assertEqual(self.p.net_rows()[0]["revision"],hashlib.sha256(line.encode()).hexdigest())


if __name__ == "__main__":
    unittest.main()
