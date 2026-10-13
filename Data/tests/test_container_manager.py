"""Container manager public read/write contract; no host/container mutations."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

PANEL = Path(__file__).resolve().parents[1] / 'panel'
sys.path.insert(0, str(PANEL))
import master_container_config as config
try:
    import master_container_manager as manager
except ImportError:
    manager = None


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(manager, 'The public container manager is not implemented')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {'KONTEYNER_STATE_DIR': str(self.root / 'containers'), 'MODULES_FILE': str(self.root / 'modules'),
                    'MODULES_DIR': str(self.root / 'packages'), 'RUNTIME_DIR': str(self.root / 'run'),
                    'KONTEYNER_NETWORK': 'konsol', 'TAILSCALE_IPV4': '100.64.0.2'}
        (self.root / 'modules').write_text('')
        (self.root / 'state').write_text(''.join(k+'='+v+'\n' for k,v in self.env.items()))
        self.rows = []
        self.fail_commands = set()
        self.calls = []
        self.p = types.SimpleNamespace(args=types.SimpleNamespace(state=str(self.root / 'state'), master_modul='/fixture/master-modul'),
                                       run_tool=self.fake_run, env=lambda:{}, module_busy=lambda _:False)
        self.s = manager.Service(self.p)

    def fake_run(self, argv, timeout=30, binary=False):
        self.calls.append(argv)
        key = tuple(argv[:2])
        if key in self.fail_commands:
            return 1, '', 'fixture unavailable'
        if argv[:2] == ['podman','version']:
            return 0,'5.4.2',''
        if argv[:2] == ['podman','ps']:
            return 0,json.dumps(self.rows),''
        if argv[:2] == ['podman','inspect']:
            return 1,'','no such container'
        if argv[:2] == ['podman','volume']:
            return 0,'[]',''
        if argv[:2] == ['podman','network']:
            return 0,'[]',''
        if argv[:2] in (['podman','images'], ['podman','system'], ['podman','stats']):
            return 0,'[]',''
        if argv[0] == 'journalctl':
            return 0,'token=secret\nclean log\n',''
        raise AssertionError(argv)

    def save(self):
        value = {'schema':1,'name':'web','revision':'a'*32,'image':'docker.io/library/nginx@sha256:'+'b'*64,
                 'image_ref':'docker.io/library/nginx:alpine','network':'konsol','ports':[],
                 'mounts':[{'type':'volume','source':'web-data','destination':'/data','read_only':False}],
                 'environment':[{'name':'API_TOKEN','value':'secret-token','secret':True}],
                 'command':[],'autostart':True,'manual_stop':True,'restart':'on-failure','cpus':'','memory':''}
        config.Store(self.env).save(value)
        return value

    def test_stopped_definition_remains_visible_and_secret_never_leaves_read_view(self):
        self.save()
        answer = self.s.view().liste()
        self.assertEqual([c['name'] for c in answer['containers']], ['web'])
        row = answer['containers'][0]
        self.assertEqual((row['source'],row['state'],row['live']), ('konsol','stopped',False))
        self.assertEqual(row['management_id'], 'konsol:web')
        self.assertIn('start',row['actions'])
        detail = self.s.view().ayrinti('web')
        self.assertFalse(detail['effective_autostart'])
        self.assertEqual(detail['config']['environment'],[{'name':'API_TOKEN','secret':True,'present':True}])
        self.assertNotIn('secret-token',json.dumps(detail))

    def test_unknown_systemd_owner_does_not_receive_destructive_controls(self):
        self.rows = [{'Id':'abc','Names':['external'],'Image':'image','State':'running','Labels':{'PODMAN_SYSTEMD_UNIT':'foreign.service'}}]
        row = self.s.view().liste()['containers'][0]
        self.assertEqual(row['source'],'external')
        self.assertEqual(row['actions'],[])
        self.assertTrue(row['restricted_reason'])

    def test_resource_read_failure_is_explicit_and_saved_definition_survives(self):
        self.save()
        self.fail_commands.add(('podman','volume'))
        answer = self.s.view().liste()
        self.assertTrue(answer['resource_errors']['volumes'])
        self.assertEqual(answer['containers'][0]['name'],'web')

    def test_reach_lists_owners_states_and_port_scopes_with_one_podman_call(self):
        # DD-259: Erişim's view; a stopped definition shows the ports it would publish.
        value = self.save()
        value.update(name='gezgin', ports=[{'scope':'local','host_port':8093,'container_port':8080,'protocol':'tcp','public_ack':False},
                                           {'scope':'public','host_port':8443,'container_port':443,'protocol':'tcp','public_ack':True}])
        config.Store(self.env).save(value)
        self.rows = [{'Id':'abc','Names':['other'],'Image':'image','State':'running',
                      'Ports':[{'host_ip':'100.64.0.2','host_port':9000,'container_port':80,'protocol':'tcp'}]}]
        app={'name':'qbittorrent','image':'docker.io/x/y@sha256:'+'e'*64,'unit':'qbittorrent.service',
             'module_id':'torrent','module_state':'durduruldu','adapter':'','channel':''}
        with patch.object(manager,'app_specs',return_value={'qbittorrent':app}):
            answer = self.s.view().reach()
        self.assertEqual(answer['runtime']['ok'], True)
        self.assertEqual([(c['name'],c['source'],c['module_id'],c['state'],c['live']) for c in answer['containers']],
                         [('gezgin','konsol',None,'stopped',False),('other','external',None,'running',True),
                          ('qbittorrent','appstore','torrent','stopped',False),('web','konsol',None,'stopped',False)])
        self.assertEqual([(p['host_ip'],p['host_port'],p['scope']) for p in answer['containers'][0]['ports']],
                         [('127.0.0.1',8093,'local'),('0.0.0.0',8443,'public')])
        self.assertEqual(answer['containers'][1]['ports'][0]['scope'], 'tailscale')
        self.assertEqual([c[:2] for c in self.calls], [['podman','version'],['podman','ps']], 'no stats, images or inspect')
        self.fail_commands.add(('podman','ps'))
        answer = self.s.view().reach()
        self.assertFalse(answer['runtime']['ok'])
        self.assertEqual([c['name'] for c in answer['containers']], ['gezgin','web'], 'saved definitions stay listed')

    def test_managed_container_log_is_its_unit_journal_unfiltered(self):
        # DD-251: a Konsol container's log is its unit's journal (every start and re-creation), live or not,
        # and nothing in it is masked.
        self.save()
        for live in (False, True):
            with self.subTest(live=live), patch.object(self.s.view().__class__, 'inspect', return_value={'Name': 'web'} if live else None):
                self.calls.clear()
                log = self.s.view().gunluk('web',200)
                self.assertEqual(log['lines'],['token=secret','clean log'])
                self.assertNotIn('masked', log)
                self.assertIn(['journalctl','-u','konsol-web.service','-n','200','--no-pager','-o','short-iso'],self.calls)
                self.assertFalse(any(c[:2] == ['podman','logs'] for c in self.calls), 'podman logs would show only the current run')

    def test_unknown_action_and_stale_save_never_launch_worker(self):
        self.save()
        with patch.object(self.s, '_launch') as launch:
            for data in ({'action':'exec','name':'web'}, {'action':'save','name':'web','revision':'b'*32,'config':{}}):
                with self.assertRaises(manager.ContainerError):
                    self.s.submit(data)
            launch.assert_not_called()

    def test_async_acceptance_is_not_reported_as_success_and_duplicate_is_busy(self):
        self.save()
        with patch.object(self.s,'_launch') as launch:
            result = self.s.submit({'action':'start','name':'web','revision':'a'*32})
            self.assertEqual(result['state'],'running')
            self.assertEqual(self.s.operation(result['id'])['state'],'running')
            with self.assertRaises(manager.ContainerError) as e:
                self.s.submit({'action':'start','name':'web','revision':'a'*32})
            self.assertEqual(e.exception.status,409)
            launch.assert_called_once()

    def test_job_lookup_rejects_paths_and_returns_durable_completed_result(self):
        directory=Path(self.env['KONTEYNER_STATE_DIR'])/'operations';directory.mkdir(parents=True)
        value={'id':'c'*32,'action':'start','name':'web','state':'done','step':'Tamamlandı','updated_at':1}
        path=directory/('c'*32+'.json');path.write_text(json.dumps(value));path.chmod(0o600)
        self.assertEqual(self.s.operation('c'*32),value)
        with self.assertRaises(manager.ContainerError):self.s.operation('../state')

    def test_real_image_json_links_stopped_definition_by_digest(self):
        definition=self.save()
        original=self.fake_run
        def run(argv,**kw):
            if argv[:2]==['podman','images']:
                return 0,json.dumps([{'id':'c'*64,'names':['docker.io/library/nginx:alpine'],
                    'digest':'sha256:'+'b'*64,'created':'2026-10-03T09:00:00Z','size':12345}]),''
            return original(argv,**kw)
        self.p.run_tool=run
        row=self.s.view().liste()['images'][0]
        self.assertEqual((row['id'],row['name'],row['size']),('c'*64,'docker.io/library/nginx:alpine',12345))
        self.assertEqual(row['used_by'],[definition['name']])

    def test_absent_package_runtime_detail_has_mount_array(self):
        app={'name':'example','image':'docker.io/library/nginx:alpine','unit':'example.service',
             'module_id':'example','module_state':'durduruldu','adapter':'adapter.py'}
        with patch.object(manager,'app_specs',return_value={'example':app}), \
             patch.object(manager,'app_config',return_value={'revision':'d'*64,'config':{'listener_port':8080},
                          'editable':['listener_port'],'protected_mounts':[]}):
            row=self.s.view().ayrinti('example')
        self.assertEqual(row['mounts'],[])
        self.assertEqual(row['state'],'stopped')

    def test_image_delete_normalizes_real_podman_id_for_worker(self):
        with patch.object(self.s,'_launch') as launch:
            self.s.submit({'action':'image-remove','image':'c'*64})
        self.assertEqual(launch.call_args.args[2]['image'],'sha256:'+'c'*64)


class ResourceTests(unittest.TestCase):
    """DD-263: CPU and memory come from the running container's own cgroup v2 files. `podman stats`
    enters each container's network namespace, which the backend's RestrictNamespaces forbids."""
    ID = 'ab'*32
    SCOPE = '/machine.slice/libpod-'+'ab'*32+'.scope'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        (self.root/'modules').write_text('')
        (self.root/'state').write_text('MODULES_FILE=%s\n' % (self.root/'modules'))
        self.cgroups = self.root/'cgroup'
        self.state = {'Status':'running','Pid':4242,'StartedAt':'2026-10-13T10:21:32.392702319+02:00','CgroupPath':self.SCOPE}
        self.calls, self.clock = [], [1000.0]
        p = types.SimpleNamespace(args=types.SimpleNamespace(state=str(self.root/'state'), master_modul='/fixture/master-modul'),
                                  run_tool=self.fake_run, env=lambda:{}, module_busy=lambda _:False)
        self.s = manager.Service(p)
        for target, attr, value in ((manager,'CGROUP_ROOT',str(self.cgroups)), (manager.time,'monotonic',lambda:self.clock[0])):
            patcher = patch.object(target, attr, value); patcher.start(); self.addCleanup(patcher.stop)
        # The numbers of a probe container on nrm (2026-10-13): 64 MiB of it is file cache.
        self.group(self.SCOPE, current=69345280, inactive=67125248, usec=1000000)

    def group(self, path, current, inactive, usec):
        d = self.cgroups/path.lstrip('/'); d.mkdir(parents=True, exist_ok=True)
        (d/'memory.current').write_text('%d\n' % current)
        (d/'memory.stat').write_text('anon 49152\nfile %d\nshmem 0\ninactive_anon 0\nactive_anon 49152\ninactive_file %d\nactive_file 0\n' % (inactive, inactive))
        (d/'cpu.stat').write_text('usage_usec %d\nuser_usec %d\nsystem_usec 0\nnr_periods 0\n' % (usec, usec))
        return d

    def fake_run(self, argv, timeout=30, binary=False):
        self.calls.append(argv)
        if argv[:2] == ['podman','version']: return 0,'5.4.2',''
        if argv[:2] == ['podman','ps']: return 0,json.dumps([{'Id':self.ID,'Names':['web'],'Image':'image','State':'running','Labels':{}}]),''
        if argv[:2] == ['podman','inspect']: return 0,json.dumps([{'Id':self.ID,'Name':'web','State':self.state,'Config':{'Labels':{}}}]),''
        if argv[:2] == ['podman','stats']:  # what the sandboxed backend gets (nrm, 2026-10-13)
            return 125,'','Error: error switching to ns /run/netns/netns-0: operation not permitted'
        if argv[:2] in (['podman','images'],['podman','system'],['podman','volume'],['podman','network']): return 0,'[]',''
        raise AssertionError(argv)

    def listing(self):
        answer = self.s.view().liste()
        return answer['containers'][0], answer['resource_errors']

    def test_usage_is_read_from_the_cgroup_and_podman_stats_is_never_run(self):
        row, errors = self.listing()
        self.assertEqual(row['memory_bytes'], 69345280-67125248, 'memory.current less the inactive file cache')
        self.assertIsNone(row['cpu_percent'], 'one reading gives no CPU rate')
        self.assertNotIn('stats', errors)
        self.group(self.SCOPE, current=69345280, inactive=67125248, usec=1000000+2500000)
        self.clock[0] += 10
        row, errors = self.listing()
        self.assertEqual(row['cpu_percent'], 25.0, '2.5 s of CPU in 10 s: a quarter of one core')
        detail = self.s.view().ayrinti('web')
        self.assertEqual((detail['cpu_percent'], detail['memory_bytes']), (25.0, 69345280-67125248))
        self.assertFalse([c for c in self.calls if c[:2] == ['podman','stats']], 'podman stats needs a namespace switch')

    def test_quadlet_payload_cgroup_is_read(self):
        # Quadlet runs podman with --cgroups=split: the payload is a child of the unit's cgroup.
        self.state['CgroupPath'] = '/system.slice/web.service/libpod-payload-'+self.ID
        self.group(self.state['CgroupPath'], current=5000000, inactive=1000000, usec=10)
        self.assertEqual(self.listing()[0]['memory_bytes'], 4000000)

    def test_cpu_rate_needs_a_minimum_interval_and_a_restart_starts_over(self):
        self.listing()
        for step, usec, expected in ((10, 2000000, 10.0), (0.5, 2500000, 10.0), (9.5, 4000000, 20.0)):
            self.clock[0] += step
            self.group(self.SCOPE, current=1, inactive=0, usec=usec)
            self.assertEqual(self.listing()[0]['cpu_percent'], expected)
        self.clock[0] += 10
        self.state['StartedAt'] = '2026-10-13T11:00:00+02:00'
        self.group(self.SCOPE, current=1, inactive=0, usec=9000000)
        self.assertIsNone(self.listing()[0]['cpu_percent'], 'a new run of the container has no earlier reading')
        self.clock[0] += 10
        self.group(self.SCOPE, current=1, inactive=0, usec=100)
        self.assertIsNone(self.listing()[0]['cpu_percent'], 'a counter that went back is a new start')
        self.clock[0] += 10
        self.group(self.SCOPE, current=1, inactive=0, usec=100100)
        self.assertEqual(self.listing()[0]['cpu_percent'], 1.0)

    def test_unsafe_or_foreign_cgroup_paths_are_never_read(self):
        # Every path below reaches readable files in a naive join; none of them is the container's own cgroup.
        scope = 'libpod-'+self.ID+'.scope'
        self.group('/../trap/'+scope, current=999, inactive=0, usec=999)  # outside the cgroup root
        os.symlink(self.root, self.cgroups/'evil.slice')
        other = '/machine.slice/libpod-'+'cd'*32+'.scope'
        for wider in ('/', '/machine.slice', other):
            self.group(wider, current=777, inactive=0, usec=777)
        for path in ('/../trap/'+scope, '/machine.slice/../../trap/'+scope, 'machine.slice'+self.SCOPE, '/', '', None, 42,
                     '/machine.slice//'+scope, '/machine.slice/./'+scope, '/machine.slice', other,
                     '/evil.slice/trap/'+scope, '/evil.slice/cgroup'+self.SCOPE,
                     self.SCOPE+'\n', self.SCOPE+'/x y', '/'+'a'*2000+'/'+scope):
            with self.subTest(path=path):
                self.state['CgroupPath'] = path
                row, errors = self.listing()
                self.assertEqual((row['cpu_percent'], row['memory_bytes']), (None, None))
                self.assertEqual(errors['stats'], 'Kaynak kullanımı okunamadı: web.')

    def test_unreadable_files_leave_only_their_own_number_unknown(self):
        d = self.cgroups/self.SCOPE.lstrip('/')
        (d/'cpu.stat').write_text('usage_usec 1\n' + 'x'*8192)
        row, errors = self.listing()
        self.assertEqual((row['cpu_percent'], row['memory_bytes']), (None, 69345280-67125248))
        self.assertEqual(errors['stats'], 'Kaynak kullanımı okunamadı: web.', 'unreadable is not the same as no reading yet')
        (d/'memory.current').unlink(); (d/'memory.current').mkdir()
        self.assertIsNone(self.listing()[0]['memory_bytes'], 'a directory is not a regular file')

    def test_cpu_readings_are_bounded(self):
        for n in range(300):
            self.s.cpu_percent(('%064x' % n, 'start'), n, float(n))
        self.assertLessEqual(len(self.s.cpu_samples), 256)
        self.assertIn(('%064x' % 299, 'start'), self.s.cpu_samples, 'the newest readings stay')



class RouteTests(unittest.TestCase):
    def test_real_handler_requires_gates_and_returns_operation_identity(self):
        from test_resources import panel, start_unix, unix_get
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        root=Path(tmp.name).resolve();(root/'modules').write_text('')
        (root/'state').write_text(f'SERVER_ROOT={root}\nLOCAL_DOMAIN=test\nMODULES_FILE={root}/modules\nKONTEYNER_STATE_DIR={root}/containers\n')
        p=panel.Panel(types.SimpleNamespace(state=str(root/'state'),allow_host=[],master_modul='/fixture/master-modul'))
        class Handler(panel.Handler):
            def log_message(self,*_):pass
        Handler.panel=p
        _server,sock=start_unix(self,Handler)
        body=json.dumps({'action':'create','config':{'name':'web','image':'docker.io/library/nginx:alpine'}}).encode()
        headers={'X-Konsol':'1','Content-Type':'application/json'}
        with patch.object(manager.Service,'_launch'):
            self.assertEqual(unix_get(sock,'/api/konsol/konteynerler/islem',{'Content-Type':'application/json'},'POST',body)[0],403)
            self.assertEqual(unix_get(sock,'/api/konsol/konteynerler/islem',dict(headers,Host='evil.test'),'POST',body)[0],403)
            code,_,raw=unix_get(sock,'/api/konsol/konteynerler/islem',headers,'POST',body)
            self.assertEqual(code,202,raw)
            job=json.loads(raw)
            code,_,raw=unix_get(sock,'/api/konsol/konteynerler/islem?id='+job['id'],headers)
            self.assertEqual((code,json.loads(raw)['state']),(200,'running'))

class PublicationIntegrationTests(unittest.TestCase):
    def test_declared_port_key_updates_both_catalogue_and_private_proxy(self):
        import master_publications as pubs
        manifest={'PAKET_YAYIN':'1','PAKET_YAYIN_AD':'Example','PAKET_YAYIN_YEREL':'example',
                  'PAKET_YAYIN_UPSTREAM':'127.0.0.1:61006','PAKET_YAYIN_PORT_ANAHTARI':'EXAMPLE_PORT'}
        with patch.object(pubs,'read_manifests',return_value={'example':manifest}), \
             patch.object(pubs,'package_env',return_value={'EXAMPLE_PORT':'61016'},create=True), \
             patch.object(pubs,'config',return_value={'example':{'tail':True}}):
            self.assertEqual(pubs.packages({})['example']['upstream'],'127.0.0.1:61016')
            source='http://example.test {\n reverse_proxy 127.0.0.1:61006 {\n }\n}\n'
            self.assertIn('reverse_proxy 127.0.0.1:61016',pubs.private_site({},'example',source))
            self.assertNotIn(':61006',pubs.private_site({},'example',source))

if __name__ == '__main__':unittest.main()
