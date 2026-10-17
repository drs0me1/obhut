"""The container manager (rebuild DD-271, phase 3): the inventory, the applications' read model from their
records with live state, the edit plan, and the broker that hands every job to the worker on standard
input. No host or container is touched: Podman, systemctl and journalctl are fakes."""
import io
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
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_fixtures  # noqa: E402
import master_applications as apps  # noqa: E402
import master_container_manager as manager  # noqa: E402

LABELS = {'io.master-stack.managed': 'uygulama', 'io.master-stack.uygulama': 'notlar'}


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(app_fixtures.env(self.root), TAILSCALE_IPV4='100.64.0.2')
        app_fixtures.write_state(self.root, self.env)
        self.rows, self.inspected, self.units = [], {}, {}
        self.fail_commands = set()
        self.calls = []
        self.p = types.SimpleNamespace(args=types.SimpleNamespace(state=str(self.root / 'state.env')),
                                       run_tool=self.fake_run, env=lambda: {})
        self.s = manager.Service(self.p)
        patcher = patch.object(manager, 'CGROUP_ROOT', str(self.root / 'cgroup'))
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_run(self, argv, timeout=30, binary=False):
        self.calls.append(list(argv))
        key = tuple(argv[:2])
        if key in self.fail_commands:
            return 1, '', 'fixture unavailable'
        if argv[:2] == ['podman', 'version']:
            return 0, '5.4.2', ''
        if argv[:2] == ['podman', 'ps']:
            return 0, json.dumps(self.rows), ''
        if argv[:2] == ['podman', 'inspect']:
            return (0, json.dumps([self.inspected[argv[-1]]]), '') if argv[-1] in self.inspected else (1, '', 'no such container')
        if argv[:2] in (['podman', 'volume'], ['podman', 'network'], ['podman', 'images'], ['podman', 'system'], ['podman', 'image']):
            return 0, '[]', ''
        if argv[:2] == ['systemctl', 'show']:
            names = [a for a in argv[2:] if not a.startswith('--')]
            return 0, '\n\n'.join('Id=%s\nActiveState=%s' % (n, self.units.get(n, 'inactive')) for n in names) + '\n', ''
        if argv[0] == 'journalctl':
            return 0, 'token=secret\nclean log\n', ''
        raise AssertionError(argv)

    def container(self, name, state='running', labels=None, unit=None, image='registry.example/x@sha256:' + 'c' * 64):
        labels = dict(labels or {})
        if unit:
            labels['PODMAN_SYSTEMD_UNIT'] = unit
        ident = '%064x' % (len(self.rows) + 1)
        cgroup = '/system.slice/libpod-payload-' + ident
        folder = self.root / 'cgroup' / cgroup.lstrip('/')
        folder.mkdir(parents=True)
        (folder / 'memory.current').write_text('3000\n')
        (folder / 'memory.stat').write_text('inactive_file 1000\n')
        (folder / 'cpu.stat').write_text('usage_usec 10\n')
        self.rows.append({'Id': ident, 'Names': [name], 'Image': image, 'State': state, 'Labels': labels})
        self.inspected[name] = {'Id': ident, 'Name': name, 'Image': image, 'ImageName': image,
                                'State': {'Status': state, 'Running': state == 'running', 'StartedAt': '2026-10-17T08:00:00Z',
                                          'Health': {'Status': 'healthy'}, 'CgroupPath': cgroup},
                                'RestartCount': 1, 'Config': {'Labels': labels, 'Env': ['DB_PASSWORD=' + app_fixtures.SECRET]},
                                'HostConfig': {'NetworkMode': 'bridge'}, 'Mounts': []}

    def running_app(self):
        record = app_fixtures.record(self.env)
        for svc in ('web', 'db'):
            self.container('notlar_' + svc, labels=LABELS, unit='konsol-notlar_%s.service' % svc,
                           image=record['places']['images'][svc])
            self.units['konsol-notlar_%s.service' % svc] = 'active'
        return record

    def test_an_application_comes_from_its_record_with_the_live_state_of_each_service(self):
        record = self.running_app()
        answer = self.s.view().applications()
        self.assertEqual(answer['hatalar'], [])
        [item] = answer['items']
        self.assertEqual((item['ad'], item['durum'], item['bicim'], item['koken'], item['revizyon'], item['is']),
                         ('notlar', 'calisiyor', 'compose', 'dosya', record['places']['revision'], None))
        self.assertEqual([(s['ad'], s['durum'], s['guncelleme']) for s in item['servisler']],
                         [('web', 'calisiyor', 'bilinmiyor'), ('db', 'calisiyor', 'bilinmiyor')])
        self.assertEqual(item['eylemler'], ['durdur', 'yeniden-baslat', 'guncelle'])
        self.assertEqual(item['kaynak'], {'cpu': None, 'bellek': 4000}, 'memory summed over the services; one reading gives no CPU')
        self.assertEqual(answer['altyapi']['podman'], '5.4.2')
        # One service down: kismen; a failed unit: hata; a stopped record: durduruldu.
        self.units['konsol-notlar_db.service'] = 'inactive'
        self.inspected['notlar_db']['State']['Running'] = False
        self.rows[1]['State'] = 'exited'
        self.assertEqual(self.s.view().applications()['items'][0]['durum'], 'kismen')
        self.units['konsol-notlar_db.service'] = 'failed'
        self.assertEqual(self.s.view().applications()['items'][0]['durum'], 'hata')
        apps.Records(self.env).write('notlar', places=dict(record['places'], stopped=True))
        self.units = {}
        self.rows = []
        item = self.s.view().applications()['items'][0]
        self.assertEqual((item['durum'], item['durduruldu'], item['eylemler']), ('durduruldu', True, ['baslat', 'guncelle']))

    def test_a_running_job_shows_on_the_application_and_takes_its_actions(self):
        self.running_app()
        self.s.jobs['b' * 32] = {'id': 'b' * 32, 'action': 'uygulama-guncelle', 'name': 'notlar', 'state': 'running'}
        item = self.s.view().applications()['items'][0]
        self.assertEqual((item['durum'], item['is'], item['eylemler']), ('islemde', 'b' * 32, []))

    def test_standalone_containers_are_offered_as_sources_and_nothing_else(self):
        self.running_app()
        self.container('eski', image='registry.example/eski:1')
        self.container('baskasi', unit='foreign-owner.service')
        self.assertEqual(self.s.view().applications()['kaynaklar'], [{'ad': 'eski', 'imaj': 'registry.example/eski:1', 'durum': 'running'}])

    def test_the_detail_names_every_part_and_no_secret_value(self):
        record = self.running_app()
        detail = self.s.view().application('notlar')
        raw = json.dumps(detail)
        self.assertNotIn(app_fixtures.SECRET, raw)
        web = detail['servisler'][0]
        self.assertEqual((web['ad'], web['baslangic'], web['kullanici'], web['konteyner'], web['birim'], web['ozet'], web['kanal']),
                         ('web', 'direct', '1000:1000', 'notlar_web', 'konsol-notlar_web.service', record['places']['images']['web'],
                          'registry.example/notlar/web:1.4'))
        self.assertEqual(web['portlar'], [{'port': 8080, 'protokol': 'tcp', 'kullanim': 'caddy', 'tailscale_adi': 'notlar',
                                           'yerel_port': 62100}])
        self.assertEqual([m['tur'] for m in web['baglamalar']], ['app', 'srv'])
        self.assertEqual(web['baglamalar'][1], {'hedef': '/media', 'tur': 'srv', 'yol': '/srv/media', 'salt_okunur': True})
        self.assertEqual((web['gizliler'], web['saglik'], web['yeniden_baslama']), (['notlar-db-password'], 'healthy', 1))
        self.assertEqual(detail['gizliler'], [{'ad': 'notlar-db-password', 'servisler': ['web', 'db']}])
        self.assertEqual(detail['yanitlar']['answers']['var:DB_PASSWORD'], {'set': True})
        self.assertEqual(detail['metin'], app_fixtures.TEXT)
        self.assertEqual(detail['birimler'], ['konsol-notlar.network', 'konsol-notlar_db.container', 'konsol-notlar_web.container'])
        self.assertEqual((detail['ag'], detail['pod'], detail['koken']['tur']), ('ksl-notlar', None, 'dosya'))
        with self.assertRaises(manager.ContainerError) as err:
            self.s.view().application('yok')
        self.assertEqual(err.exception.status, 404)

    def test_a_service_log_is_its_unit_journal_unfiltered(self):
        # DD-251: an application's log is its unit's journal (every start and re-creation), nothing masked.
        self.running_app()
        log = self.s.view().journal('notlar', 'web', 500)
        self.assertEqual(log, {'satirlar': ['token=secret', 'clean log'], 'kesik': False})
        self.assertIn(['journalctl', '-u', 'konsol-notlar_web.service', '-n', '500', '--no-pager', '-o', 'short-iso'], self.calls)
        self.s.view().journal('notlar', 'db', 7)
        self.assertEqual(self.calls[-1][4], '200', 'an unknown line count falls back to 200')
        self.assertFalse(any(c[:2] == ['podman', 'logs'] for c in self.calls))
        for app, service in (('notlar', 'yok'), ('yok', 'web')):
            with self.subTest(app=app, service=service), self.assertRaises(manager.ContainerError) as err:
                self.s.view().journal(app, service, 200)
            self.assertEqual(err.exception.status, 404)

    def test_an_unreadable_record_is_an_error_line_and_the_others_stay(self):
        self.running_app()
        broken = Path(self.env['UYGULAMA_STATE_DIR']) / 'bozuk'
        broken.mkdir(mode=0o700)
        (broken / 'yerler.json').write_text('{')
        (broken / 'yerler.json').chmod(0o600)
        answer = self.s.view().applications()
        self.assertEqual([i['ad'] for i in answer['items']], ['notlar'])
        self.assertEqual(len(answer['hatalar']), 1)
        self.assertTrue(answer['hatalar'][0].startswith('bozuk: '))

    def test_reach_and_the_inventory_name_an_applications_container(self):
        self.running_app()
        self.container('baskasi', image='registry.example/baska:1')
        answer = self.s.view().reach()
        self.assertEqual([(c['name'], c['source'], c['uygulama']) for c in answer['containers']],
                         [('baskasi', 'external', None), ('notlar_db', 'uygulama', 'notlar'), ('notlar_web', 'uygulama', 'notlar')])
        self.assertEqual([c[:2] for c in self.calls], [['podman', 'version'], ['podman', 'ps']], 'no stats, images or inspect')
        rows = {r['name']: r for r in self.s.view().liste()['containers']}
        self.assertEqual((rows['notlar_web']['source'], rows['notlar_web']['uygulama']), ('uygulama', 'notlar'))
        self.assertNotIn('actions', rows['notlar_web'])
        self.assertNotIn(app_fixtures.SECRET, json.dumps(rows))

    def test_an_image_a_stopped_application_pins_is_in_use(self):
        record = app_fixtures.record(self.env, stopped=True)
        pinned = record['places']['images']['web']
        original = self.fake_run

        def run(argv, **kw):
            if argv[:2] == ['podman', 'images']:
                return 0, json.dumps([{'id': 'c' * 64, 'names': ['registry.example/notlar/web:1.4'], 'RepoDigests': [pinned],
                                       'created': '2026-10-03T09:00:00Z', 'size': 12345}]), ''
            return original(argv, **kw)
        self.p.run_tool = run
        row = self.s.view().liste()['images'][0]
        self.assertEqual((row['name'], row['used_by'], row['managed']), ('registry.example/notlar/web:1.4', ['notlar'], True))
        self.assertEqual(self.s.view().applications()['altyapi']['kullanilmayan_imaj'], 0)

    def test_the_edit_plan_lists_what_changes_and_writes_nothing(self):
        self.running_app()
        given = app_fixtures.answers()
        given['answers']['var:DB_PASSWORD'] = {'keep': True}
        given['answers']['start:db'] = {'mode': 'direct'}
        text = app_fixtures.TEXT.replace('LOG_LEVEL: info', 'LOG_LEVEL: debug')
        before = apps.Records(self.env).snapshot('notlar')
        plan = self.s.view().definition_plan('notlar', text, given)
        self.assertEqual(apps.Records(self.env).snapshot('notlar'), before, 'nothing written')
        fark = plan['fark']
        self.assertEqual(fark['ortam'], ['web'])
        self.assertEqual([u['ad'] for u in fark['birimler']], ['konsol-notlar_db.container'], 'the start mode changes its unit')
        self.assertEqual(fark['gizliler'], {'yeni': [], 'yenilenen': [], 'korunan': ['notlar-db-password'], 'kaldirilan': []})
        self.assertEqual(fark['baslangic'][1], {'servis': 'db', 'once': 'root', 'sonra': 'direct'})
        self.assertEqual(fark['portlar'], [{'anahtar': 'web:8080/tcp', 'degisim': 'kalir', 'yerel_port': 62100}])
        self.assertTrue(fark['yeniden_baslar'])
        # A new value for the secret renews it; a raw port drops its pool port; Podman 4.9 cannot wait for health.
        given['answers']['var:DB_PASSWORD'] = {'value': 'yeni-' + app_fixtures.SECRET}
        given['answers']['port:web:8080/tcp'] = {'use': 'raw'}
        original = self.p.run_tool
        self.p.run_tool = lambda argv, timeout=30, binary=False: (0, '4.9.3', '') if argv[:2] == ['podman', 'version'] else original(argv, timeout)
        fark = self.s.view().definition_plan('notlar', app_fixtures.TEXT, given)['fark']
        self.assertEqual(fark['gizliler']['yenilenen'], ['notlar-db-password'])
        self.assertEqual(fark['portlar'], [{'anahtar': 'web:8080/tcp', 'degisim': 'kaldirilir', 'yerel_port': 62100}])
        self.assertIn('Podman 5 gerekir; bu sunucuda 4.9', fark['uyarilar'][-1]['metin'])
        # Answers that do not check come back by question; a keep without an earlier value is refused.
        given['answers']['var:DB_PASSWORD'] = {'value': ''}
        self.assertIn('var:DB_PASSWORD', self.s.view().definition_plan('notlar', app_fixtures.TEXT, given)['hatalar'])
        given['name'] = 'baska'
        given['answers']['var:DB_PASSWORD'] = {'value': 'x'}
        self.assertIn('name', self.s.view().definition_plan('notlar', app_fixtures.TEXT, given)['hatalar'])
        self.assertNotIn(app_fixtures.SECRET, json.dumps(plan))

    def test_the_broker_hands_application_jobs_over_and_keeps_no_request(self):
        with patch.object(self.s, '_launch') as launch:
            job = self.s.submit_app('uygulama-kur', 'notlar', {'metin': 'x', 'yanitlar': {'answers': {'var:X': {'value': app_fixtures.SECRET}}}})
            self.assertEqual((job['state'], job['action'], job['name']), ('running', 'uygulama-kur', 'notlar'))
            self.assertNotIn(app_fixtures.SECRET, json.dumps(self.s.jobs), 'the in-memory job never holds the request')
            self.assertEqual(launch.call_args.args[2]['name'], 'notlar')
            with self.assertRaises(manager.ContainerError) as err:
                self.s.submit_app('uygulama-baslat', 'notlar', {'revizyon': 'a' * 32})
            self.assertEqual(err.exception.status, 409, 'one job per application at a time')
            for action, name in (('uygulama-exec', 'notlar'), ('uygulama-kur', 'Notlar'), ('uygulama-kur', 'a_b'),
                                 ('uygulama-taslak', 'bad image name')):
                with self.subTest(action=action, name=name), self.assertRaises(manager.ContainerError):
                    self.s.submit_app(action, name, {})
            with self.assertRaises(manager.ContainerError):
                self.s.submit({'action': 'create', 'name': 'web'})
            self.s.submit({'action': 'image-remove', 'image': 'c' * 64})
            self.assertEqual(launch.call_args.args[2]['image'], 'sha256:' + 'c' * 64)

    def test_an_application_job_runs_longer_and_its_file_fits_on_standard_input(self):
        self.s.jobs['d' * 32] = {'id': 'd' * 32, 'action': 'uygulama-kur', 'name': 'notlar', 'state': 'running'}
        with patch.object(manager.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0, stdout='{"ok": true}')) as run, \
                patch.object(self.s, 'operation', return_value={'id': 'd' * 32, 'state': 'done'}):
            self.s._execute('d' * 32, 'uygulama-kur', {'name': 'notlar', 'metin': 'x', 'yanitlar': {}})
        argv = run.call_args.args[0]
        self.assertIn('--property=RuntimeMaxSec=1800', argv)
        self.assertEqual(json.loads(run.call_args.kwargs['input'])['metin'], 'x', 'the request travels on standard input')
        self.assertFalse([a for a in argv if 'metin' in a])
        # The CLI the transient unit runs reads up to 2 MiB for an application job, 64 KiB for any other.
        big = json.dumps({'name': 'notlar', 'metin': '#' * (256 * 1024), 'yanitlar': {}})
        self.assertGreater(len(big), manager.STDIN_LIMIT)
        for action, accepted in (('uygulama-kur', True), ('volume-create', False)):
            with self.subTest(action=action), patch.object(sys, 'argv', ['m', '--state', str(self.root / 'state.env'),
                                                                         '--operation', 'e' * 32, action]), \
                    patch.object(sys, 'stdin', io.StringIO(big)), patch('master_container_worker.Manager') as worker, \
                    patch('sys.stdout', new_callable=io.StringIO) as out:
                worker.return_value.execute.return_value = {'ok': True}
                try:
                    manager.main()
                except SystemExit:
                    pass
                self.assertEqual(worker.return_value.execute.called, accepted)
                if not accepted:
                    self.assertIn('İstek çok büyük', out.getvalue())

    def test_job_lookup_rejects_paths_and_returns_durable_completed_result(self):
        directory = Path(self.env['KONTEYNER_STATE_DIR']) / 'operations'
        directory.mkdir(parents=True)
        value = {'id': 'c' * 32, 'action': 'uygulama-baslat', 'name': 'notlar', 'state': 'done', 'step': 'Tamamlandı', 'updated_at': 1}
        path = directory / ('c' * 32 + '.json')
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        self.assertEqual(self.s.operation('c' * 32), value)
        with self.assertRaises(manager.ContainerError):
            self.s.operation('../state')

    def test_a_reserved_empty_record_reads_as_the_job_starting(self):
        # The worker creates the record empty to reserve the id, then writes its first step.
        directory = Path(self.env['KONTEYNER_STATE_DIR']) / 'operations'
        directory.mkdir(parents=True)
        path = directory / ('d' * 32 + '.json')
        path.write_text('')
        path.chmod(0o600)
        self.s.jobs['d' * 32] = {'id': 'd' * 32, 'action': 'uygulama-durdur', 'name': 'notlar', 'state': 'running',
                                 'step': 'Başlatılıyor', 'updated_at': 1}
        self.assertEqual(self.s.operation('d' * 32)['state'], 'running')
        path.write_text('{"broken"')
        with self.assertRaises(manager.ContainerError):
            self.s.operation('d' * 32)


class ResourceTests(unittest.TestCase):
    """DD-263: CPU and memory come from the running container's own cgroup v2 files. `podman stats`
    enters each container's network namespace, which the backend's RestrictNamespaces forbids."""
    ID = 'ab'*32
    SCOPE = '/machine.slice/libpod-'+'ab'*32+'.scope'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        (self.root/'state').write_text('LOCAL_DOMAIN=test\n')
        self.cgroups = self.root/'cgroup'
        self.state = {'Status':'running','Pid':4242,'StartedAt':'2026-10-13T10:21:32.392702319+02:00','CgroupPath':self.SCOPE}
        self.calls, self.clock = [], [1000.0]
        p = types.SimpleNamespace(args=types.SimpleNamespace(state=str(self.root/'state')), run_tool=self.fake_run, env=lambda:{})
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
    def test_the_resource_route_requires_the_gates_and_returns_the_job(self):
        from test_resources import panel, start_unix, unix_get
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        (root / 'state').write_text(f'SERVER_ROOT={root}\nLOCAL_DOMAIN=test\nKONTEYNER_STATE_DIR={root}/containers\n')
        p = panel.Panel(types.SimpleNamespace(state=str(root / 'state'), allow_host=[], state_env=False))

        class Handler(panel.Handler):
            def log_message(self, *_):
                pass
        Handler.panel = p
        _server, sock = start_unix(self, Handler)
        body = json.dumps({'action': 'volume-create', 'name': 'yedek'}).encode()
        headers = {'X-Konsol': '1', 'Content-Type': 'application/json'}
        with patch.object(manager.Service, '_launch'):
            self.assertEqual(unix_get(sock, '/api/konsol/konteynerler/islem', {'Content-Type': 'application/json'}, 'POST', body)[0], 403)
            self.assertEqual(unix_get(sock, '/api/konsol/konteynerler/islem', dict(headers, Host='evil.test'), 'POST', body)[0], 403)
            code, _, raw = unix_get(sock, '/api/konsol/konteynerler/islem', headers, 'POST', body)
            self.assertEqual(code, 202, raw)
            job = json.loads(raw)
            code, _, raw = unix_get(sock, '/api/konsol/konteynerler/islem?id=' + job['id'], headers)
            self.assertEqual((code, json.loads(raw)['state']), (200, 'running'))
            # The single-container actions are gone from the table's request shape.
            for action in ('create', 'save', 'start', 'adopt', 'image-update'):
                body = json.dumps({'action': action, 'name': 'web'}).encode()
                self.assertEqual(unix_get(sock, '/api/konsol/konteynerler/islem', headers, 'POST', body)[0], 400, action)


if __name__ == '__main__':
    unittest.main()
