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
        self.assertNotIn('altyapi', answer, "Podman's inventory is Gelişmiş's; the list carries none")
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
        self.assertEqual(web['portlar'], [{'port': 8080, 'protokol': 'tcp', 'id': 'uygulama:notlar:web:8080/tcp',
                                           'erisim': {'tur': 'adres', 'ad': 'notlar', 'tailscale_portu': None, 'internet': ''},
                                           'kullanim': 'caddy', 'tailscale_adi': 'notlar', 'yerel_port': 62100}])
        self.assertEqual(detail['servisler'][1]['portlar'], [], 'the database publishes no port')
        self.assertEqual([m['tur'] for m in web['baglamalar']], ['app', 'srv'])
        self.assertEqual(web['baglamalar'][1], {'hedef': '/media', 'tur': 'srv', 'yol': '/srv/media', 'salt_okunur': True,
                                                'boyut': None})
        self.assertEqual((web['gizliler'], web['saglik'], web['yeniden_baslama']), (['notlar-db-password'], 'healthy', 1))
        self.assertEqual(detail['gizliler'], [{'ad': 'notlar-db-password', 'servisler': ['web', 'db']}])
        self.assertEqual(detail['yanitlar']['answers']['var:DB_PASSWORD'], {'set': True})
        self.assertEqual(detail['metin'], app_fixtures.TEXT)
        self.assertEqual(detail['birimler'], ['konsol-notlar.network', 'konsol-notlar_db.container', 'konsol-notlar_web.container'])
        self.assertEqual((detail['ag'], detail['pod'], detail['koken']['tur']), ('ksl-notlar', None, 'dosya'))
        with self.assertRaises(manager.ContainerError) as err:
            self.s.view().application('yok')
        self.assertEqual(err.exception.status, 404)

    def test_the_detail_gives_application_folders_their_measured_size_and_the_last_update_check(self):
        self.running_app()
        folder = Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar' / 'uploads'
        folder.mkdir(parents=True)
        (folder / 'dosya.bin').write_bytes(b'x' * 20000)
        detail = self.s.view().application('notlar')
        web, db = detail['servisler']
        self.assertGreaterEqual(web['baglamalar'][0]['boyut'], 20000, "the folder's share of Depolama's measurement")
        self.assertIsNone(web['baglamalar'][1]['boyut'], 'a server folder has no size here')
        self.assertIsNone(db['baglamalar'][0]['boyut'], 'a folder not on disk yet')
        self.assertIsNone(detail['guncelleme_denetlendi'], 'never checked')
        # The same cached measurement Depolama reads: a second read walks nothing.
        (folder / 'ikinci.bin').write_bytes(b'x' * 50000)
        self.assertEqual(self.s.view().application('notlar')['servisler'][0]['baglamalar'][0]['boyut'], web['baglamalar'][0]['boyut'])
        with self.s.lock:
            self.s.update_items, self.s.update_at = {'notlar': {'web': {'state': 'guncel'}}}, 1791845000.5
        self.assertEqual(self.s.view().application('notlar')['guncelleme_denetlendi'], 1791845000)
        with self.s.lock:
            self.s.update_items = {'baska': {'web': {'state': 'guncel'}}}
        self.assertIsNone(self.s.view().application('notlar')['guncelleme_denetlendi'], 'a check that did not ask about it')

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
        # How a port that stays is reached changes in Erişim: an answer that is not its row is refused by question.
        given['answers']['port:web:8080/tcp'] = {'use': 'raw'}
        self.assertEqual(self.s.view().definition_plan('notlar', text, given)['hatalar'],
                         {'port:web:8080/tcp': "Bu portun kullanımı Erişim'den değişir."})
        # A new value for the secret renews it; a port that went drops its row and pool port, a new one gets
        # both (its name checked); Podman 4.9 cannot wait for health.
        given['answers'].pop('port:web:8080/tcp')
        given['answers']['var:DB_PASSWORD'] = {'value': 'yeni-' + app_fixtures.SECRET}
        given['answers']['port:web:9090/tcp'] = {'use': 'caddy', 'tailscale_name': 'notlar-yeni'}
        moved = app_fixtures.TEXT.replace('      - "8080"\n', '      - "9090"\n')
        original = self.p.run_tool
        self.p.run_tool = lambda argv, timeout=30, binary=False: (0, '4.9.3', '') if argv[:2] == ['podman', 'version'] else original(argv, timeout)
        fark = self.s.view().definition_plan('notlar', moved, given)['fark']
        self.assertEqual(fark['gizliler']['yenilenen'], ['notlar-db-password'])
        # The pool port the gone port released is free again.
        self.assertEqual(fark['portlar'], [{'anahtar': 'web:9090/tcp', 'degisim': 'eklenir', 'yerel_port': 62100},
                                           {'anahtar': 'web:8080/tcp', 'degisim': 'kaldirilir', 'yerel_port': 62100}])
        self.assertIn('Podman 5 gerekir; bu sunucuda 4.9', fark['uyarilar'][-1]['metin'])
        given['answers']['port:web:9090/tcp'] = {'use': 'caddy', 'tailscale_name': 'panel-x'}
        app_fixtures.record(self.env, text=app_fixtures.SIMPLE, given=json.loads(json.dumps(app_fixtures.SIMPLE_ANSWERS).replace(
            '"tailscale_name": "sayac"', '"tailscale_name": "panel-x"')), app='sayac', ports={'app:9000/tcp': 62105})
        self.assertEqual(self.s.view().definition_plan('notlar', moved, given)['hatalar'],
                         {'port:web:9090/tcp': 'panel-x.ev adı zaten kullanılıyor.'})
        given['answers'].pop('port:web:9090/tcp')
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
            self.assertFalse(hasattr(self.s, 'submit'), 'the Podman resource actions are gone')

    def test_the_cleanup_job_takes_only_checked_items_and_names_no_application(self):
        with patch.object(self.s, '_launch') as launch:
            job = self.s.submit_cleanup({'imajlar': ['c' * 64, 'c' * 64], 'aglar': ['eski-ag'], 'birimler': ['yetim'],
                                         'klasorler': ['eskiuygulama']})
            self.assertEqual((job['action'], job['name']), ('temizlik', 'Podman'))
            self.assertEqual(launch.call_args.args[1:], ('temizlik', {'imajlar': ['c' * 64], 'aglar': ['eski-ag'],
                                                                      'birimler': ['yetim'], 'klasorler': ['eskiuygulama'],
                                                                      'name': 'Podman'}))
            self.assertIsNone(self.s.busy('podman'), 'an application named like the job is not busy')
            with self.assertRaises(manager.ContainerError) as err:
                self.s.submit_cleanup({'birimler': ['ikinci']})
            self.assertEqual(err.exception.status, 409, 'one cleanup at a time')
            self.s.jobs.clear()
            for bad in ({}, {'imajlar': []}, {'imajlar': ['sha256:' + 'c' * 64]}, {'imajlar': ['nginx:latest']},
                        {'aglar': ['podman']}, {'aglar': ['-f']}, {'birimler': ['a/b']}, {'klasorler': ['Bad_Name']},
                        {'klasorler': ['../etc']}, {'konteynerler': ['eski']}, {'imajlar': 'c' * 64},
                        {'birimler': ['v%d' % n for n in range(201)]}):
                with self.subTest(bad=str(bad)[:60]), self.assertRaises(manager.ContainerError) as err:
                    self.s.submit_cleanup(bad)
                self.assertEqual(err.exception.status, 400)
            self.assertEqual(launch.call_count, 1)

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
        for action, accepted in (('uygulama-kur', True), ('temizlik', False)):
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


class CleanupViewTests(unittest.TestCase):
    """K8: Gelişmiş's cleanup read model offers only what is proven unused, and lists the containers no application
    owns; a source that cannot be read leaves what depends on it empty."""
    A, B, Z, R = ('%064x' % n for n in (0xa, 0xb, 0xf, 0xe))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = app_fixtures.env(self.root)
        app_fixtures.write_state(self.root, self.env)
        self.record = app_fixtures.record(self.env)
        veri = Path(self.env['UYGULAMA_VERI_DIR'])
        (veri / 'notlar' / 'uploads').mkdir(parents=True)
        (veri / 'eskiuygulama' / 'veri').mkdir(parents=True)
        (veri / 'eskiuygulama' / 'veri' / 'dosya').write_bytes(b'x' * 10000)
        (veri / 'baglanmis').mkdir()
        (veri / 'Bad_Name').mkdir()
        (veri / 'baglanti').symlink_to(veri / 'eskiuygulama')
        self.ps = [
            {'Id': 'a' * 64, 'Names': ['notlar_web'], 'Image': 'registry.example/notlar/web:1.4', 'ImageID': self.A,
             'State': 'running', 'Networks': ['ksl-notlar']},
            {'Id': 'b' * 64, 'Names': ['eski'], 'Image': 'registry.example/eski:1', 'ImageID': self.B, 'State': 'exited',
             'Networks': ['ozel']},
            {'Id': 'c' * 64, 'Names': ['bagli'], 'Image': 'registry.example/eski:1', 'ImageID': self.B, 'State': 'exited',
             'Networks': []}]
        labels = {'io.master-stack.managed': 'uygulama', 'io.master-stack.uygulama': 'notlar',
                  'PODMAN_SYSTEMD_UNIT': 'konsol-notlar_web.service'}
        self.inspected = {
            'a' * 64: {'Name': 'notlar_web', 'Image': self.A, 'Config': {'Labels': labels},
                       'NetworkSettings': {'Networks': {'ksl-notlar': {}}},
                       'Mounts': [{'Type': 'bind', 'Source': str(veri / 'notlar' / 'uploads')}]},
            'b' * 64: {'Name': 'eski', 'Image': self.B, 'Config': {'Labels': {}}, 'State': {},
                       'Mounts': [{'Type': 'volume', 'Name': 'eski-veri', 'Source': '/var/lib/containers/storage/volumes/eski-veri/_data'}]},
            'c' * 64: {'Name': 'bagli', 'Image': self.B, 'Config': {'Labels': {'PODMAN_SYSTEMD_UNIT': 'baska.service'}}, 'State': {},
                       'Mounts': [{'Type': 'bind', 'Source': str(veri / 'baglanmis' / 'alt')}]}}
        pinned = self.record['places']['images']
        self.images = [
            {'Id': self.A, 'Names': ['registry.example/notlar/web:1.4'], 'RepoDigests': [pinned['web']], 'Size': 10},
            {'Id': self.B, 'Names': ['registry.example/eski:1'], 'Size': 20},
            {'Id': '%064x' % 0xd, 'Names': ['registry.example/notlar/db:16'], 'RepoDigests': [pinned['db']], 'Size': 30},
            {'Id': self.Z, 'Names': ['registry.example/artik:2', 'registry.example/artik:latest'], 'Size': 40, 'Created': 1700000000},
            # Podman lists an image once for each of its tags.
            {'Id': self.Z, 'Names': ['registry.example/artik:2', 'registry.example/artik:latest'], 'Size': 40, 'Created': 1700000000},
            {'Id': self.R, 'Names': ['registry.example/salt:1'], 'Size': 50, 'ReadOnly': True},
            {'Id': '%064x' % 0x9, 'Names': ['registry.example/sayilan:1'], 'Size': 60, 'Containers': 1}]
        self.networks = [{'name': 'podman', 'driver': 'bridge'}, {'name': 'ksl-notlar', 'driver': 'bridge'},
                         {'name': 'ozel', 'driver': 'bridge'}, {'name': 'bos-ag', 'driver': 'bridge', 'network_interface': 'podman3'}]
        self.volumes = [{'Name': 'eski-veri', 'Driver': 'local'}, {'Name': 'yetim', 'Driver': 'local', 'CreatedAt': '2026-10-01T10:00:00Z'}]
        self.fail = set()
        self.calls = []
        self.p = types.SimpleNamespace(args=types.SimpleNamespace(state=str(self.root / 'state.env')), run_tool=self.podman_fake, env=lambda: {})
        self.s = manager.Service(self.p)

    def podman_fake(self, argv, timeout=30, binary=False):
        self.calls.append(list(argv))
        if tuple(argv[:3]) in self.fail or tuple(argv[:2]) in self.fail:
            return 125, '', 'fixture unavailable'
        if argv[:2] == ['podman', 'version']:
            return 0, '5.4.2', ''
        if argv[:3] == ['podman', 'ps', '-a']:
            return 0, json.dumps(self.ps), ''
        if argv[:2] == ['podman', 'inspect']:
            return (0, json.dumps([self.inspected[argv[-1]]]), '') if argv[-1] in self.inspected else (125, '', 'no such container')
        if argv[:2] == ['podman', 'images']:
            return 0, json.dumps(self.images), ''
        if argv[:3] == ['podman', 'network', 'ls']:
            return 0, json.dumps(self.networks), ''
        if argv[:3] == ['podman', 'volume', 'ls']:
            return 0, json.dumps(self.volumes), ''
        raise AssertionError(argv)

    def test_only_what_nothing_uses_is_offered(self):
        answer = self.s.view().cleanup()
        self.assertEqual(answer['hatalar'], [])
        self.assertEqual(answer['imajlar'], [{'id': self.Z, 'etiketler': ['registry.example/artik:2', 'registry.example/artik:latest'],
                                              'boyut': 40, 'olusturuldu': 1700000000}],
                         'not a pinned or named image, not one a stopped container came from, not a read-only or counted one')
        self.assertEqual(answer['aglar'], [{'ad': 'bos-ag', 'surucu': 'bridge', 'arayuz': 'podman3'}],
                         "never Podman's default, an application's or a stopped container's network")
        self.assertEqual([v['ad'] for v in answer['birimler']], ['yetim'])
        [folder] = answer['klasorler']
        self.assertEqual((folder['ad'], folder['yol'], folder['neden']), ('eskiuygulama', str(Path(self.env['UYGULAMA_VERI_DIR']) / 'eskiuygulama'), ''))
        self.assertGreaterEqual(folder['boyut'], 10000)
        self.assertEqual(answer['konteynerler'], [{'ad': 'bagli', 'imaj': 'registry.example/eski:1', 'durum': 'exited', 'yonetici': 'baska'},
                                                  {'ad': 'eski', 'imaj': 'registry.example/eski:1', 'durum': 'exited', 'yonetici': 'podman'}])
        import master_api
        master_api.check(master_api.ref('Temizlik'), answer)
        self.assertFalse([c for c in self.calls if c[:2] in (['podman', 'rm'], ['podman', 'image'], ['podman', 'volume'])
                          and c[2:3] not in (['ls'],)], 'read-only')

    def test_what_cannot_be_read_is_never_offered(self):
        del self.inspected['b' * 64]
        answer = self.s.view().cleanup()
        self.assertEqual((answer['birimler'], answer['klasorler']), ([], []), 'a container that cannot be read may use them')
        self.assertEqual([i['id'] for i in answer['imajlar']], [self.Z])
        self.assertTrue(answer['hatalar'][0].startswith('Konteyner okunamadı: eski'))
        self.fail.add(('podman', 'ps', '-a'))
        answer = self.s.view().cleanup()
        self.assertEqual([answer[k] for k in ('imajlar', 'aglar', 'birimler', 'klasorler', 'konteynerler')], [[]] * 5)
        self.fail = {('podman', 'images')}
        self.inspected['b' * 64] = {'Name': 'eski', 'Image': self.B, 'Config': {'Labels': {}}, 'Mounts': []}
        answer = self.s.view().cleanup()
        self.assertEqual(answer['imajlar'], [])
        self.assertIn('İmajlar okunamadı: fixture unavailable', answer['hatalar'])
        self.assertEqual([v['ad'] for v in answer['birimler']], ['eski-veri', 'yetim'], 'no container mounts eski-veri now')
        # An application record that cannot be read: nothing can be proven unused.
        (Path(self.env['UYGULAMA_STATE_DIR']) / 'notlar' / 'tanim.json').write_text('{')
        answer = self.s.view().cleanup()
        self.assertEqual([answer[k] for k in ('imajlar', 'aglar', 'birimler', 'klasorler')], [[]] * 4)
        self.assertEqual(len(answer['hatalar']), 1)


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
    def test_the_cleanup_routes_keep_the_gates_and_the_resource_actions_are_gone(self):
        from test_resources import panel, start_unix, unix_get
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        (root / 'state').write_text(f'SERVER_ROOT={root}\nLOCAL_DOMAIN=test\nKONTEYNER_STATE_DIR={root}/containers\n')
        p = panel.Panel(types.SimpleNamespace(state=str(root / 'state')))
        audits = []

        class Handler(panel.Handler):
            def log_message(self, *_):
                pass

            def audit(self, user, action, detail, ok):
                audits.append((action, detail, ok))
        Handler.panel = p
        _server, sock = start_unix(self, Handler)
        body = json.dumps({'birimler': ['yetim'], 'klasorler': ['eskiuygulama']}).encode()
        headers = {'X-Konsol': '1', 'Content-Type': 'application/json'}
        path = '/api/konsol/gelismis/temizlik'
        with patch.object(manager.Service, '_launch') as launch:
            self.assertEqual(unix_get(sock, path, {'Content-Type': 'application/json'}, 'POST', body)[0], 403)
            self.assertEqual(unix_get(sock, path, dict(headers, Host='evil.test'), 'POST', body)[0], 403)
            code, _, raw = unix_get(sock, path, headers, 'POST', body)
            self.assertEqual(code, 202, raw)
            job = json.loads(raw)
            self.assertEqual(set(job), {'is'})
            self.assertEqual(launch.call_args.args[1:], ('temizlik', {'birimler': ['yetim'], 'klasorler': ['eskiuygulama'],
                                                                      'name': 'Podman'}))
            self.assertEqual(audits, [('temizlik', 'birim yetim; klasör eskiuygulama', True)])
            code, _, raw = unix_get(sock, '/api/konsol/konteynerler/islem?id=' + job['is'], headers)
            self.assertEqual((code, json.loads(raw)['state'], json.loads(raw)['name']), (200, 'running', 'Podman'))
            for bad in ({'birimler': 'yetim'}, {'konteynerler': ['x']}, {}, {'aglar': ['podman']}):
                self.assertEqual(unix_get(sock, path, headers, 'POST', json.dumps(bad).encode())[0], 400, bad)
            # The six Podman resource actions and their route are gone; only the table answers.
            for action in ('image-pull', 'image-remove', 'volume-create', 'volume-remove', 'network-create', 'network-remove'):
                body = json.dumps({'action': action, 'name': 'web'}).encode()
                self.assertEqual(unix_get(sock, '/api/konsol/konteynerler/islem', headers, 'POST', body)[0], 404, action)
            self.assertEqual(launch.call_count, 1)


if __name__ == '__main__':
    unittest.main()
