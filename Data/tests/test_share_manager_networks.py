"""Network opt-in, registry schema and root publication rollback, without host changes."""
import contextlib
import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "panel"))
import master_shares as s
loader=importlib.machinery.SourceFileLoader("share_panel",str(Path(__file__).resolve().parents[1]/"panel/master-panel"))
if Path(loader.path).exists():
    spec=importlib.util.spec_from_loader(loader.name,loader)
    panel=importlib.util.module_from_spec(spec); loader.exec_module(panel)
else:
    loader=importlib.machinery.SourceFileLoader("share_panel","/usr/local/sbin/master-panel")
    spec=importlib.util.spec_from_loader(loader.name,loader)
    panel=importlib.util.module_from_spec(spec); loader.exec_module(panel)



class NetworkManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="share-networks-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        for name in ("srv/alpha", "run", "sites"):
            (self.root / name).mkdir(parents=True)
        self.env = dict(SHARE_STATE_FILE=str(self.root/"registry"),
                        RUNTIME_DIR=str(self.root/"run"), SERVER_ROOT=str(self.root/"srv"),
                        FILES_PANEL_TRASH=".cop",
                        SETTINGS_PENDING_FILE=str(self.root/"settings-pending"),
                        SHARE_PORT="61010", TAILSCALE_IPV4="100.64.0.2", WAN_IPV4="8.8.8.8",
                        SHARE_WAN_BACKEND="127.0.0.2", CADDY_MODULES_DIR=str(self.root/"sites"),
                        CADDYFILE=str(self.root/"Caddyfile"), SBIN_DIR=str(self.root))
        self.state = self.root/"state.env"
        self.state.write_text("".join(k+"="+v+"\n" for k,v in self.env.items()))
        # The fixture WAN address is not on this machine; DD-182's live check is tested separately.
        self.addCleanup(patch.stopall)
        self.assigned_patch = patch.object(s, "assigned", return_value=True)
        self.assigned = self.assigned_patch.start()
        self.m = s.Manager(self.state)
        with self.offline():
            self.m.change("save", dict(path="alpha",username="reader",password="Test12345"))
        self.item = self.m.read()["items"][0]

    def offline(self):
        """The WebDAV restart and the Caddy projection, which every saved change runs, without host
        commands; the tests below that exercise them call publish/guard/prepare themselves."""
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(self.m, "restart"))
        stack.enter_context(patch.object(self.m, "publish"))
        return stack

    def save(self, **fields):
        with self.offline():
            return self.m.change("save", dict(id=self.item["id"], **fields))

    def test_optin_required_and_selections_strict(self):
        before = Path(self.m.path).read_bytes()
        for connections in ({}, None, "wan", [], {"other": {"enabled": True}},
                            {"wan": {}}, {"wan": {"enabled": 1}}, {"wan": {"enabled": "true"}}):
            with self.subTest(connections=connections), self.assertRaises(s.ShareError):
                self.save(connections=connections)
        for ack in (None, False, 1, "true"):
            with self.assertRaises(s.ShareError):
                self.save(connections={"wan": {"enabled": True}},ack_wan_http=ack)
        self.assertEqual(before,Path(self.m.path).read_bytes())

    def test_network_edit_preserves_identity_credentials_and_absolute_expiry(self):
        self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)
        row = self.m.public()["items"][0]
        after = self.m.read()["items"][0]
        for key in ("id","salt","hash","identity"):
            self.assertEqual(self.item[key],after[key])
        for scope in ("tailscale", "wan"):
            for key in ("expires", "permission"):
                self.assertEqual(self.item["connections"][scope][key], after["connections"][scope][key])
        self.assertEqual(set(row["urls"]),{"tailscale","wan"})
        self.assertTrue(row["urls"]["wan"].startswith("http://8.8.8.8:61010/s/"))
        row = self.save(connections={"tailscale": {"enabled": False}})["items"][0]
        self.assertFalse(row["connections"]["tailscale"]["active"])
        self.assertTrue(row["connections"]["wan"]["active"])
        self.assertEqual(set(row["urls"]),{"wan"})
        self.assertEqual(row["url"],row["urls"]["wan"])
        self.save(connections={"tailscale": {"enabled": True}, "wan": {"enabled": False}})
        with self.assertRaises(s.ShareError): self.save(connections={"wan": {"enabled": True}})

    def test_schema4_is_stable_and_older_schemas_are_rejected(self):
        before=Path(self.m.path).read_bytes()
        self.m.prepare()
        self.assertEqual(before,Path(self.m.path).read_bytes())
        data = self.m.read()
        self.assertEqual(data["schema"], 4)
        for schema in (2, 3):
            old = copy.deepcopy(data); old["schema"] = schema
            s.atomic(self.m.path,old)
            raw = Path(self.m.path).read_bytes()
            with self.assertRaisesRegex(s.ShareError, "Paylaşım kaydı desteklenmiyor"): self.m.read()
            with self.assertRaisesRegex(s.ShareError, "Paylaşım kaydı desteklenmiyor"): self.m.prepare()
            self.assertEqual(Path(self.m.path).read_bytes(), raw)
        # A key this version does not write, at the top or in an item, fails closed too (DD-271).
        for place, key in (("top", "enabled"), ("item", "tail_enabled"), ("item", "permission")):
            odd = copy.deepcopy(data)
            (odd if place == "top" else odd["items"][0])[key] = True
            s.atomic(self.m.path, odd)
            with self.assertRaisesRegex(s.ShareError, "Paylaşım kaydı desteklenmiyor"): self.m.read()
        data["items"][0].pop("connections")
        s.atomic(self.m.path,data)
        with self.assertRaises(s.ShareError): self.m.read()

    def test_private_nat_and_ipv6_only_addresses_are_not_offered(self):
        for ip in ("", "192.168.1.2", "100.64.0.3", "127.0.0.1", "224.0.0.1", "::1", "192.0.2.1"):
            self.m.env["WAN_IPV4"] = ip
            self.assertFalse(self.m.wan_info()["available"])
            with self.assertRaises(s.ShareError): self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)

    def test_last_active_share_closes_publication(self):
        self.save(connections={"tailscale": {"enabled": False}, "wan": {"enabled": True}},ack_wan_http=True)
        self.assertTrue(self.m.wan_active())
        with patch.object(s.subprocess,"run",return_value=subprocess.CompletedProcess([],0)) as run:
            self.m.publish()
            target=self.root/"sites/paylasim-wan.caddy"
            text=target.read_text()
            self.assertIn("bind 8.8.8.8",text)
            self.assertIn("http://:61010 {",text)  # catch all Host values on only this explicit bind
            self.assertIn("127.0.0.2:61010",text)
            self.assertIn("X-Share-Client-IP {http.request.remote.host}",text)
            self.assertNotIn("panel.",text)
            self.assertNotIn("0.0.0.0",text)
            self.assertIn("respond 404",text)
            calls=run.call_count
            self.m.publish()
            self.assertEqual(run.call_count,calls)
            data=self.m.read(); data["items"][0]["connections"]["wan"]["expires"]=time.time()-1; s.atomic(self.m.path,data)
            self.assertFalse(self.m.wan_active())
            self.m.guard()
            self.assertFalse(target.exists())
            self.assertGreater(run.call_count,calls)

    def test_rollback_restores_registry_and_publication_on_caddy_failure(self):
        old=Path(self.m.path).read_bytes()
        with patch.object(self.m,"restart"), patch.object(s.subprocess,"run",side_effect=[subprocess.CalledProcessError(1,"caddy"),subprocess.CompletedProcess([],0),subprocess.CompletedProcess([],0),subprocess.CompletedProcess([],0)]):
            with self.assertRaises(s.ShareError):
                self.m.change("save", dict(id=self.item["id"], connections={"wan": {"enabled": True}}, ack_wan_http=True))
        self.assertEqual(Path(self.m.path).read_bytes(),old)
        self.assertFalse(os.path.exists(self.m.pending))
        self.assertFalse((self.root/"sites/paylasim-wan.caddy").exists())

    def test_vanished_wan_address_closes_publication_with_a_reason(self):
        self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)
        with patch.object(s.subprocess,"run",return_value=subprocess.CompletedProcess([],0)):
            self.m.publish()
            target=self.root/"sites/paylasim-wan.caddy"
            self.assertTrue(target.exists())
            self.assigned.return_value=False
            info=self.m.wan_info()
            self.assertFalse(info["available"])
            self.assertIn("8.8.8.8 artık bu sunucuda değil",info["reason"])
            self.assertFalse(self.m.wan_active())
            self.m.guard()
            self.assertFalse(target.exists())

    def test_address_probe_only_reports_missing_for_eaddrnotavail(self):
        self.assigned_patch.stop()
        for code,present in ((s.errno.EADDRNOTAVAIL,False),(s.errno.EADDRINUSE,True),(s.errno.EMFILE,True)):
            with self.subTest(code=code), patch.object(s.socket.socket,"bind",side_effect=OSError(code,"fixture")):
                self.assertEqual(s.assigned("198.51.100.7"),present)
        self.assertTrue(s.assigned("127.0.0.1"))
        self.assertFalse(s.assigned("192.0.2.77"))

    def test_reload_failure_starts_a_stopped_caddy_but_rolls_back_a_running_one(self):
        self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)
        target=self.root/"sites/paylasim-wan.caddy"
        marker=self.root/"run/share-network-applied.json"
        calls=[]
        def run(argv,**kw):
            calls.append(argv)
            if argv[:2]==["systemctl","reload"]:
                raise subprocess.CalledProcessError(1,argv)
            if argv[:2]==["systemctl","is-active"]:
                return subprocess.CompletedProcess(argv,self.caddy)
            return subprocess.CompletedProcess(argv,0)
        self.caddy=3  # stopped, e.g. it could not bind an address the provider took away
        with patch.object(s.subprocess,"run",side_effect=run):
            self.m.publish()
        self.assertTrue(target.exists())
        self.assertFalse(marker.exists())
        self.assertIn(["systemctl","reset-failed","caddy"],calls)
        self.assertIn(["systemctl","start","--no-block","caddy"],calls)
        target.unlink(); calls.clear()
        self.caddy=0  # running: a failed reload is a real error and the old projection returns
        with patch.object(s.subprocess,"run",side_effect=run), self.assertRaises(s.ShareError):
            self.m.publish()
        self.assertFalse(target.exists())
        self.assertNotIn(["systemctl","start","--no-block","caddy"],calls)

    def test_interrupted_operation_is_recovered_with_credentials_first(self):
        old=self.m.read()
        self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)
        s.atomic(self.m.pending,old)
        with patch.object(self.m,"restart") as restart, patch.object(self.m,"publish") as publish:
            self.m.guard()
            restart.assert_called_once(); publish.assert_called_once()
        self.assertEqual(self.m.read(),old)
        self.assertFalse(os.path.exists(self.m.pending))

    def test_pause_and_missing_root_do_not_leave_active_wan(self):
        self.save(connections={"tailscale": {"enabled": False}, "wan": {"enabled": True}},ack_wan_http=True)
        data=self.m.read(); data["items"][0]["connections"]["wan"]["enabled"]=False; s.atomic(self.m.path,data)
        self.assertFalse(self.m.wan_active())
        data["items"][0]["connections"]["wan"]["enabled"]=True; s.atomic(self.m.path,data)
        (self.root/"srv/alpha").rename(self.root/"srv/old")
        (self.root/"srv/alpha").mkdir()
        self.assertFalse(self.m.wan_active())

    def test_installer_recovery_reloads_credentials_before_clearing_pending(self):
        old=self.m.read()
        self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)
        s.atomic(self.m.pending,old)
        with patch.object(self.m,"restart",side_effect=s.ShareError("injected")):
            with self.assertRaises(s.ShareError): self.m.prepare()
        self.assertTrue(os.path.exists(self.m.pending))
        with patch.object(self.m,"restart") as restart:
            self.m.prepare()
            restart.assert_called_once()
        self.assertFalse(os.path.exists(self.m.pending))
        self.assertEqual(self.m.read(),old)

    def test_panel_caddy_projection_names_wan_and_preserves_proxy_routes(self):
        self.save(connections={"wan": {"enabled": True}},ack_wan_http=True)
        with patch.object(s.subprocess,"run",return_value=subprocess.CompletedProcess([],0)):
            self.m.publish()
        Path(self.env["CADDYFILE"]).write_text("{\n servers 8.8.8.8:61010 {\n timeouts {\n read_header 10s\n }\n }\n}\n")
        p=object.__new__(panel.Panel)
        entries=p.web_view(self.env)["entries"]
        self.assertEqual(len(entries),1)
        self.assertEqual(entries[0]["address"],"8.8.8.8:61010")
        self.assertEqual(entries[0]["access"],"wan")
        self.assertIn(dict(path="/s/*",kind="proxy",to="127.0.0.2:61010"),entries[0]["routes"])


if __name__ == "__main__": unittest.main()
