"""Network opt-in, migration and root publication rollback, without host changes."""
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
loader=importlib.machinery.SourceFileLoader("share_panel",str(Path(__file__).resolve().parents[1]/"panel/master-wg-panel"))
if Path(loader.path).exists():
    spec=importlib.util.spec_from_loader(loader.name,loader)
    panel=importlib.util.module_from_spec(spec); loader.exec_module(panel)
else:
    loader=importlib.machinery.SourceFileLoader("share_panel","/usr/local/sbin/master-wg-panel")
    spec=importlib.util.spec_from_loader(loader.name,loader)
    panel=importlib.util.module_from_spec(spec); loader.exec_module(panel)


class NetworkManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="share-networks-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("srv/alpha", "run", "sites", "profile"):
            (self.root / name).mkdir(parents=True)
        self.env = dict(SHARE_STATE_FILE=str(self.root/"registry"), MODULES_FILE=str(self.root/"modules"),
                        RUNTIME_DIR=str(self.root/"run"), SERVER_ROOT=str(self.root/"srv"),
                        DOWNLOADS_PATH=str(self.root/"srv/downloads"), TORRENT_PROFILE_DIR=str(self.root/"profile"),
                        TORRENT_TEMP_DIR="incomplete", FILES_PANEL_TRASH=".cop", SHARE_DIR=".pay",
                        SETTINGS_PENDING_FILE=str(self.root/"settings-pending"),
                        SHARE_PORT="61010", TAILSCALE_IPV4="100.64.0.2", WAN_IPV4="8.8.8.8",
                        SHARE_WAN_BACKEND="127.0.0.2", CADDY_MODULES_DIR=str(self.root/"sites"),
                        CADDYFILE=str(self.root/"Caddyfile"), SBIN_DIR=str(self.root))
        self.state = self.root/"state.env"
        self.state.write_text("".join(k+"="+v+"\n" for k,v in self.env.items()))
        (self.root/"modules").write_text("paylasim\tdurduruldu\n")
        self.m = s.Manager(self.state)
        self.m.change("save", dict(path="alpha",username="reader",password="Test12345",permission="ro",days=7))
        self.item = self.m.read()["items"][0]

    def save(self, **fields):
        return self.m.change("save", dict(id=self.item["id"], **fields))

    def running(self):
        (self.root/"modules").write_text("paylasim\tcalisiyor\n")

    def test_optin_required_and_selections_strict(self):
        before = Path(self.m.path).read_bytes()
        for nets in ([], None, "wan", ["other"], ["tailscale","tailscale"], ["wan",{}]):
            with self.subTest(nets=nets), self.assertRaises(s.ShareError):
                self.save(networks=nets)
        for ack in (None, False, 1, "true"):
            with self.assertRaises(s.ShareError):
                self.save(networks=["wan"],ack_wan_http=ack)
        self.assertEqual(before,Path(self.m.path).read_bytes())

    def test_network_edit_preserves_identity_credentials_and_absolute_expiry(self):
        row = self.save(networks=["tailscale","wan"],ack_wan_http=True)["items"][0]
        after = self.m.read()["items"][0]
        for key in ("id","salt","hash","identity","expires","paused","permission"):
            self.assertEqual(self.item[key],after[key])
        self.assertEqual(set(row["urls"]),{"tailscale","wan"})
        self.assertTrue(row["urls"]["wan"].startswith("http://8.8.8.8:61010/s/"))
        row = self.save(networks=["wan"])["items"][0]
        self.assertEqual(set(row["urls"]),{"wan"})
        self.assertEqual(row["url"],row["urls"]["wan"])
        self.save(networks=["tailscale"])
        with self.assertRaises(s.ShareError): self.save(networks=["wan"])

    def test_schema2_migration_never_infers_public_access(self):
        old = self.m.read()
        old["schema"] = 2
        old["items"][0]["networks"] = ["wan"]
        s.atomic(self.m.path,old)
        self.m.prepare()
        data = self.m.read()
        self.assertEqual(data["schema"],3)
        self.assertEqual(data["items"][0]["networks"],["tailscale"])
        self.assertEqual(data["items"][0]["hash"],self.item["hash"])
        before=Path(self.m.path).read_bytes()
        self.m.prepare()
        self.assertEqual(before,Path(self.m.path).read_bytes())
        data["items"][0].pop("networks")
        s.atomic(self.m.path,data)
        with self.assertRaises(s.ShareError): self.m.read()

    def test_private_nat_and_ipv6_only_addresses_are_not_offered(self):
        for ip in ("", "192.168.1.2", "100.64.0.3", "127.0.0.1", "224.0.0.1", "::1", "192.0.2.1"):
            self.m.env["WAN_IPV4"] = ip
            self.assertFalse(self.m.wan_info()["available"])
            with self.assertRaises(s.ShareError): self.save(networks=["wan"],ack_wan_http=True)

    def test_last_active_share_closes_publication(self):
        self.save(networks=["wan"],ack_wan_http=True)
        self.running()
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
            data=self.m.read(); data["items"][0]["expires"]=time.time()-1; s.atomic(self.m.path,data)
            self.assertFalse(self.m.wan_active())
            self.m.guard()
            self.assertFalse(target.exists())
            self.assertGreater(run.call_count,calls)

    def test_rollback_restores_registry_and_publication_on_caddy_failure(self):
        self.running()
        old=Path(self.m.path).read_bytes()
        with patch.object(self.m,"restart"), patch.object(s.subprocess,"run",side_effect=[subprocess.CalledProcessError(1,"caddy"),subprocess.CompletedProcess([],0),subprocess.CompletedProcess([],0),subprocess.CompletedProcess([],0)]):
            with self.assertRaises(s.ShareError): self.save(networks=["wan"],ack_wan_http=True)
        self.assertEqual(Path(self.m.path).read_bytes(),old)
        self.assertFalse(os.path.exists(self.m.pending))
        self.assertFalse((self.root/"sites/paylasim-wan.caddy").exists())

    def test_interrupted_operation_is_recovered_with_credentials_first(self):
        old=self.m.read()
        self.save(networks=["wan"],ack_wan_http=True)
        self.running()
        s.atomic(self.m.pending,old)
        with patch.object(self.m,"restart") as restart, patch.object(self.m,"publish") as publish:
            self.m.guard()
            restart.assert_called_once(); publish.assert_called_once()
        self.assertEqual(self.m.read(),old)
        self.assertFalse(os.path.exists(self.m.pending))

    def test_pause_and_missing_root_do_not_leave_active_wan(self):
        self.save(networks=["wan"],ack_wan_http=True)
        self.running()
        data=self.m.read(); data["items"][0]["paused"]=True; s.atomic(self.m.path,data)
        self.assertFalse(self.m.wan_active())
        data["items"][0]["paused"]=False; s.atomic(self.m.path,data)
        (self.root/"srv/alpha").rename(self.root/"srv/old")
        (self.root/"srv/alpha").mkdir()
        self.assertFalse(self.m.wan_active())

    def test_installer_recovery_reloads_credentials_before_clearing_pending(self):
        old=self.m.read()
        self.save(networks=["wan"],ack_wan_http=True)
        self.running()
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
        self.save(networks=["wan"],ack_wan_http=True)
        self.running()
        with patch.object(s.subprocess,"run",return_value=subprocess.CompletedProcess([],0)):
            self.m.publish()
        Path(self.env["CADDYFILE"]).write_text("{\n servers 8.8.8.8:61010 {\n timeouts {\n read_header 10s\n }\n }\n}\n")
        p=object.__new__(panel.Panel)
        entries=p.web_view(self.env,[])["entries"]
        self.assertEqual(len(entries),1)
        self.assertEqual(entries[0]["address"],"8.8.8.8:61010")
        self.assertEqual(entries[0]["access"],"wan")
        self.assertIn(dict(path="/s/*",kind="proxy",to="127.0.0.2:61010"),entries[0]["routes"])


if __name__ == "__main__": unittest.main()
