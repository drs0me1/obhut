"""The root worker (rebuild DD-271, phase 3): an application's lifecycle and Gelişmiş's Podman resources.
Podman, systemctl, Quadlet and the guard are fakes; every rollback path is driven to its end and checked
for what it left behind. No secret value may reach an argument, a file other than Podman's standard
input, an operation record, a log line or a reply."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'panel'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_fixtures  # noqa: E402
import master_applications as apps  # noqa: E402
import master_container_config as cfg  # noqa: E402
import master_container_worker as worker  # noqa: E402
import master_generator  # noqa: E402
import master_inspector  # noqa: E402

SECRET = app_fixtures.SECRET
POD = """apiVersion: v1
kind: Pod
metadata:
  name: ikili
spec:
  containers:
  - name: web
    image: registry.example/ikili/web:1
    ports:
    - containerPort: 8080
  - name: cache
    image: registry.example/ikili/cache:2
"""
TAKEOVER = """name: devir
services:
  app:
    image: registry.example/devir:3
    volumes:
      - veri:/data
volumes:
  veri:
"""


def auto_answers(text, name, **given):
    """Answers for every question: root start, the application's folder, raw ports, a plain value."""
    out = {}
    for q in master_inspector.inspect(text)['questions']:
        kind = q['kind']
        if kind == 'start':
            out[q['id']] = {'mode': 'root'}
        elif kind == 'mount':
            out[q['id']] = {'to': 'app'}
        elif kind == 'port':
            out[q['id']] = {'use': 'raw'}
        elif kind in ('var', 'secret'):
            out[q['id']] = {'value': SECRET}
    out.update(given)
    return {'name': name, 'answers': {k: v for k, v in out.items() if k != 'name'}}


class FakeHost:
    """Podman, systemctl and Quadlet as the worker sees them. Starting a container unit creates its container
    from the unit file (labels, user, capabilities); stopping removes it (Quadlet's --rm)."""

    def __init__(self, env):
        self.env = env
        self.calls, self.inputs = [], []
        self.containers, self.networks, self.pods = {}, set(), set()
        self.secrets = {}
        self.units = {}
        self.digest = {}
        self.fail = []
        self.unhealthy = set()
        self.restarts = {}
        self.vanish = set()
        self.version = '5.4.2'
        self.volumes = {}
        self.reloads = 0

    def fails(self, *parts):
        self.fail.append(' '.join(parts))

    def unit_text(self, unit):
        name = unit[:-len('.service')]
        for suffix in ('.container', '.pod', '.network'):
            base = name[:-len('-pod')] if suffix == '.pod' and name.endswith('-pod') else \
                name[:-len('-network')] if suffix == '.network' and name.endswith('-network') else name
            path = Path(self.env['KONTEYNER_BIRIM_DIR']) / (base + suffix)
            if path.exists() and (suffix != '.container' or base == name):
                return suffix, path.read_text()
        return None, None

    def __call__(self, argv, timeout=60, input=None, **kwargs):
        argv = list(argv)
        self.calls.append(argv)
        if input is not None:
            self.inputs.append(input)
        line = ' '.join(argv)
        for i, part in enumerate(self.fail):
            if part in line:
                del self.fail[i]
                return subprocess.CompletedProcess(argv, 1, '', 'sensitive failure password=never-print')
        out, code = '', 0
        if argv[:2] == ['podman', 'version']:
            out = self.version + '\n'
        elif argv[:3] == ['podman', 'container', 'exists']:
            code = 0 if argv[-1] in self.containers else 1
            if code == 0 and argv[-1] in self.vanish:
                self.vanish.discard(argv[-1])
                self.containers.pop(argv[-1])
                self.units['konsol-%s.service' % argv[-1]] = 'failed'
        elif argv[:3] == ['podman', 'network', 'exists']:
            code = 0 if argv[-1] in self.networks else 1
        elif argv[:3] == ['podman', 'pod', 'exists']:
            code = 0 if argv[-1] in self.pods else 1
        elif argv[:3] == ['podman', 'inspect', '--type']:
            if argv[-1] in self.containers:
                out = json.dumps([self.containers[argv[-1]]])
            else:
                code = 125
        elif argv[:2] == ['podman', 'pull']:
            pass
        elif argv[:3] == ['podman', 'image', 'inspect']:
            repository, _ref = master_generator.image_reference(argv[-1])
            digest = self.digest.get(repository, 'sha256:' + 'd' * 64)
            out = json.dumps([{'Id': 'sha256:' + 'e' * 64, 'RepoDigests': [repository + '@' + digest],
                               'Config': {'ExposedPorts': {'8080/tcp': {}, '53/udp': {}}, 'Volumes': {'/data': {}}}}])
        elif argv[:3] == ['podman', 'secret', 'create']:
            self.secrets[argv[-2]] = input
        elif argv[:3] == ['podman', 'secret', 'rm']:
            self.secrets.pop(argv[-1], None)
        elif argv[:3] == ['podman', 'secret', 'inspect']:
            code = 0 if argv[-1] in self.secrets else 125
        elif argv[:2] == ['podman', 'rm']:
            self.containers.pop(argv[-1], None)
        elif argv[:3] == ['podman', 'pod', 'rm']:
            self.pods.discard(argv[-1])
        elif argv[:3] == ['podman', 'network', 'rm']:
            self.networks.discard(argv[-1])
        elif argv[:2] == ['podman', 'stop']:
            self.containers[argv[-1]]['State'].update(Running=False, Status='exited')
        elif argv[:2] == ['podman', 'start']:
            self.containers[argv[-1]]['State'].update(Running=True, Status='running')
        elif argv[:3] == ['podman', 'volume', 'create']:
            pass
        elif argv[:3] == ['podman', 'volume', 'inspect']:
            out = json.dumps([self.volumes[argv[-1]]])
        elif argv[0] == 'cp':
            source, target = argv[-2].rstrip('.'), argv[-1]
            shutil.copytree(source, target, dirs_exist_ok=True)
        elif argv[:2] == ['systemctl', 'daemon-reload']:
            self.reloads += 1
        elif argv[:2] == ['systemctl', 'show'] and 'NRestarts' in argv:
            out = '%d\n' % self.restarts.get(argv[-1], 0)
        elif argv[:2] == ['systemctl', 'show']:
            out = self.units.get(argv[-1], 'inactive') + '\n'
        elif argv[:2] == ['systemctl', 'start']:
            self.start(argv[-1])
        elif argv[:2] == ['systemctl', 'stop']:
            self.units[argv[-1]] = 'inactive'
            name = argv[-1][len('konsol-'):-len('.service')]
            self.containers.pop(name, None)
            if argv[-1].endswith('-pod.service'):
                self.pods.discard(name[:-len('-pod')])
        elif argv[0] == '/fixture/quadlet':
            folder = Path(kwargs['env']['QUADLET_UNIT_DIRS'])
            names = [p.stem + '.service' for p in folder.glob('*.container')]
            names += [p.stem + '-pod.service' for p in folder.glob('*.pod')]
            names += [p.stem + '-network.service' for p in folder.glob('*.network')]
            out = ''.join('---%s---\n[Service]\nExecStart=/usr/bin/podman\n' % n for n in sorted(names))
        else:
            raise AssertionError('unexpected command: %r' % argv)
        return subprocess.CompletedProcess(argv, code, out, '')

    def start(self, unit):
        kind, text = self.unit_text(unit)
        if kind is None:
            raise AssertionError('no unit file for ' + unit)
        self.units[unit] = 'active'
        if kind == '.pod':
            self.pods.add(re.search(r'^PodName=(.*)$', text, re.M).group(1))
            return
        if kind == '.network':
            self.networks.add(re.search(r'^NetworkName=(.*)$', text, re.M).group(1))
            return
        network = re.search(r'^Network=konsol-(.*)\.network$', text, re.M)
        if network:
            self.networks.add('ksl-' + network.group(1))
        name = re.search(r'^ContainerName=(.*)$', text, re.M).group(1)
        labels = dict(l.split('=', 1) for l in re.findall(r'^Label=(.*)$', text, re.M))
        labels['PODMAN_SYSTEMD_UNIT'] = unit
        user = re.search(r'^User=(.*)$', text, re.M)
        caps = None if 'DropCapability=all' in text else ['CAP_CHOWN', 'CAP_KILL']
        health = 'unhealthy' if name in self.unhealthy else 'healthy'
        self.containers[name] = {'Id': 'f' * 64, 'Name': name, 'State': {'Running': True, 'Status': 'running',
                                                                         'Health': {'Status': health}},
                                 'EffectiveCaps': caps, 'BoundingCaps': caps,
                                 'Config': {'Labels': labels, 'User': user.group(1) if user else ''}}

    def started(self):
        return [c[-1] for c in self.calls if c[:2] == ['systemctl', 'start']]

    def stopped(self):
        return [c[-1] for c in self.calls if c[:2] == ['systemctl', 'stop']]


class FakeNetwork:
    """The guard: it reads every record as the real one does, and remembers which applications it saw."""

    def __init__(self):
        self.applied = []
        self.fail = 0

    def apply(self, env, run):
        if self.fail:
            self.fail -= 1
            raise cfg.ContainerConfigError(503, 'Konteyner yönlendirme koruması uygulanamadı.')
        self.applied.append([row['app'] for row in apps.guard_input(env)])


class WorkerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='uygulama-worker-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = app_fixtures.env(self.root)
        for key in ('KONTEYNER_BIRIM_DIR', 'RUNTIME_DIR'):
            Path(self.env[key]).mkdir(parents=True)
        self.state = app_fixtures.write_state(self.root, self.env)
        self.host = FakeHost(self.env)
        self.guard = FakeNetwork()
        self.now = [1000.0]
        self.manager = worker.Manager(str(self.state), run=self.host, network=self.guard, quadlet='/fixture/quadlet',
                                      clock=lambda: self.now[0], sleep=self.tick)
        self.checked = []
        # /srv itself is the host's; the DD-226 walk is checked in its own test.
        patcher = patch.object(worker.binds, 'walk', side_effect=lambda source: self.checked.append(source) or os.open(self.root, os.O_RDONLY))
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(apps, 'bindable', return_value=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(apps, 'manual_ports', return_value=set())
        patcher.start()
        self.addCleanup(patcher.stop)

    def tick(self, seconds):
        self.now[0] += seconds

    def execute(self, action, request):
        return self.manager.execute(action, request, uuid.uuid4().hex)

    def install(self, text=None, given=None, name='notlar', source=None):
        text = app_fixtures.TEXT if text is None else text
        given = app_fixtures.answers() if given is None else given
        return self.execute('uygulama-kur', {'name': name, 'metin': text, 'yanitlar': given, 'kaynak': source or {'tur': 'dosya'}})

    def record(self, app='notlar'):
        return apps.Records(self.env).load(app)

    def unit_files(self):
        return sorted(p.name for p in Path(self.env['KONTEYNER_BIRIM_DIR']).iterdir())

    def assert_no_secret(self, *values):
        """No secret value in an argument, a file Obhut wrote, an operation record or a reply."""
        for value in values or (SECRET,):
            self.assertFalse([c for c in self.host.calls if any(value in a for a in c)], 'a secret in argv')
            for path in self.root.rglob('*'):
                if path.is_file():
                    self.assertNotIn(value.encode(), path.read_bytes(), 'a secret in ' + str(path))

    def assert_nothing_left(self, app='notlar'):
        self.assertFalse(os.path.lexists(Path(self.env['UYGULAMA_STATE_DIR']) / app), 'the record was removed')
        self.assertEqual([n for n in self.unit_files() if n.startswith('konsol-' + app)], [], 'no unit file stays')
        self.assertEqual({k for k in self.host.secrets if k.startswith('obhut_%s_' % app)}, set(), 'no secret stays')
        self.assertEqual([c for c in self.host.containers if c.startswith(app + '_')], [])
        self.assertNotIn('ksl-' + app, self.host.networks)
        self.assertNotIn(app, self.guard.applied[-1], 'the guard was applied again without it')

    def operation(self):
        folder = Path(self.env['KONTEYNER_STATE_DIR']) / 'operations'
        return json.loads(sorted(folder.iterdir(), key=lambda p: p.stat().st_mtime_ns)[-1].read_text())


class InstallTests(WorkerCase):
    def test_install_records_pins_creates_secrets_and_starts_in_order(self):
        result = self.install()
        record = self.record()
        self.assertEqual(result, {'ok': True, 'ad': 'notlar', 'revizyon': record['places']['revision']})
        places = record['places']
        self.assertEqual(places['ports'], {'web:8080/tcp': 62100})
        self.assertEqual(places['images'], {'web': 'registry.example/notlar/web@sha256:' + 'd' * 64,
                                            'db': 'registry.example/notlar/db@sha256:' + 'd' * 64})
        [podman] = places['secrets'].values()
        self.assertRegex(podman, r'^obhut_notlar_[0-9a-f]{8}$')
        self.assertEqual(self.host.secrets, {podman: SECRET}, 'the value went to Podman on standard input only')
        create = next(c for c in self.host.calls if c[:3] == ['podman', 'secret', 'create'])
        self.assertEqual(create[-1], '-')
        self.assertIn('io.master-stack.uygulama=notlar', create)
        self.assertEqual(record['answers']['answers']['var:DB_PASSWORD'], {'set': True})
        self.assertEqual((record['source']['tur'], record['text']), ('dosya', app_fixtures.TEXT))
        folder = Path(self.env['UYGULAMA_STATE_DIR']) / 'notlar'
        self.assertEqual(oct(folder.stat().st_mode & 0o777), '0o700')
        self.assertEqual({p.name: oct(p.stat().st_mode & 0o777) for p in folder.iterdir() if p.is_file()},
                         {n: '0o600' for n in apps.FILES})
        self.assertEqual((folder / 'env/web.env').read_text(), 'LOG_LEVEL=info\n')
        data = Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar'
        self.assertEqual(sorted(p.name for p in data.iterdir()), ['db-data', 'uploads'])
        self.assertEqual(oct((data / 'uploads').stat().st_mode & 0o777), '0o700')
        self.assertEqual(self.unit_files(), ['konsol-notlar.network', 'konsol-notlar_db.container', 'konsol-notlar_web.container'])
        self.assertEqual(self.host.started(), ['konsol-notlar_db.service', 'konsol-notlar_web.service'], 'dependencies first')
        self.assertEqual(self.guard.applied[0], ['notlar'], 'the guard knew the bridge before anything started')
        self.assertEqual(self.checked, ['/srv/media'], 'the /srv folder was walked at install time')
        self.assertEqual([c[-1] for c in self.host.calls if c[:2] == ['podman', 'pull']],
                         ['registry.example/notlar/web:1.4', 'registry.example/notlar/db:16'])
        self.assertEqual(self.operation()['state'], 'done')
        self.assertNotIn('metin', json.dumps(self.operation()))
        self.assert_no_secret()

    def test_one_pull_per_distinct_image(self):
        text = app_fixtures.SIMPLE.replace('volumes:\n  veri:\n', '').replace('    volumes:\n      - veri:/data\n', '')
        text = text.replace('services:\n', 'services:\n  ikinci:\n    image: registry.example/sayac:2\n')
        given = auto_answers(text, 'sayac')
        self.install(text, given, 'sayac')
        self.assertEqual([c[-1] for c in self.host.calls if c[:2] == ['podman', 'pull']], ['registry.example/sayac:2'])

    def test_the_name_must_be_free_everywhere(self):
        cases = {'record': lambda: app_fixtures.record(self.env),
                 'unit': lambda: (Path(self.env['KONTEYNER_BIRIM_DIR']) / 'konsol-notlar_eski.container').write_text('x'),
                 'container': lambda: self.host.containers.update(notlar_web={'Name': 'notlar_web'}),
                 'network': lambda: self.host.networks.add('ksl-notlar'),
                 'pod': lambda: self.host.pods.add('notlar')}
        for what, make in cases.items():
            with self.subTest(what=what):
                self.setUp()
                make()
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    self.install()
                self.assertEqual(err.exception.status, 409)
                self.assertFalse([c for c in self.host.calls if c[:2] in (['podman', 'pull'], ['systemctl', 'start'])
                                  or c[:3] == ['podman', 'secret', 'create']])

    def test_refusals_come_before_any_write(self):
        def no_write():
            self.assertFalse(os.path.lexists(Path(self.env['UYGULAMA_STATE_DIR']) / 'notlar'))
            self.assertEqual(self.unit_files(), [])
            self.assertFalse([c for c in self.host.calls if c[:2] == ['podman', 'pull']])
        given = app_fixtures.answers()
        given['answers']['var:DB_PASSWORD'] = {'value': ''}
        for request, status in (({'metin': app_fixtures.TEXT, 'yanitlar': given}, 400),
                                ({'metin': 'services: [', 'yanitlar': app_fixtures.answers()}, 409),
                                ({'metin': 'x' * (256 * 1024 + 1), 'yanitlar': app_fixtures.answers()}, 400),
                                ({'metin': app_fixtures.TEXT, 'yanitlar': app_fixtures.answers(), 'name': 'baska'}, 400)):
            with self.subTest(request=str(request)[:60]):
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    self.execute('uygulama-kur', dict({'name': 'notlar', 'kaynak': {'tur': 'dosya'}}, **request))
                self.assertEqual(err.exception.status, status)
                no_write()
        # The /srv folder is walked without following a link; a missing or linked one stops the install.
        with patch.object(worker.binds, 'walk', side_effect=worker.binds.BindError('Bağlanan klasör eksik: /srv/media')):
            with self.assertRaises(cfg.ContainerConfigError) as err:
                self.install()
        self.assertEqual(err.exception.status, 409)
        no_write()

    def test_podman_4_9_runs_neither_a_health_wait_nor_a_pod(self):
        self.host.version = '4.9.3'
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install()
        self.assertIn('Podman 5 gerekir; bu sunucuda 4.9', str(err.exception))
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install(POD, auto_answers(POD, 'ikili'), 'ikili')
        self.assertIn('Podman 5 gerekir; bu sunucuda 4.9', str(err.exception))
        self.assertEqual(self.unit_files(), [])
        self.assertFalse(os.listdir(self.env['UYGULAMA_STATE_DIR']) if os.path.exists(self.env['UYGULAMA_STATE_DIR']) else [])
        # A single-service file runs on 4.9.
        self.install(app_fixtures.SIMPLE, app_fixtures.SIMPLE_ANSWERS, 'sayac')
        self.assertTrue(self.record('sayac'))

    def test_a_pod_starts_first_and_its_members_belong_to_the_application(self):
        self.install(POD, auto_answers(POD, 'ikili'), 'ikili')
        self.assertEqual(self.host.started()[0], 'konsol-ikili-pod.service')
        self.assertIn('konsol-ikili.pod', self.unit_files())
        self.assertIn('ikili', self.host.pods)

    def test_a_failure_at_every_step_takes_back_what_the_job_did(self):
        steps = [('pull', ('podman pull --quiet registry.example/notlar/db:16',)),
                 ('secret', ('podman secret create',)),
                 ('dryrun', ('/fixture/quadlet --dryrun',)),
                 ('reload', ('systemctl daemon-reload',)),
                 ('first start', ('systemctl start konsol-notlar_db.service',)),
                 ('second start', ('systemctl start konsol-notlar_web.service',))]
        for label, parts in steps + [('unhealthy', ()), ('restarted', ()), ('gone', ()), ('wrong user', ()), ('guard', ())]:
            with self.subTest(step=label):
                self.setUp()
                existing = Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar' / 'uploads'
                if label == 'unhealthy':
                    self.host.unhealthy.add('notlar_web')
                elif label == 'restarted':
                    # It stopped at once and systemd restarts it: the job says so instead of waiting.
                    self.host.restarts['konsol-notlar_web.service'] = 1
                elif label == 'gone':
                    # It exits between `exists` and `inspect` (Quadlet's --rm); then its unit has failed.
                    self.host.vanish.add('notlar_web')
                elif label == 'wrong user':
                    original = self.host.start
                    self.host.start = lambda unit: (original(unit), self.host.containers.get('notlar_web', {}).get('Config', {}).update(User='0'))
                elif label == 'guard':
                    self.guard.fail = 1
                else:
                    self.host.fails(*parts)
                if label == 'second start':
                    # Data kept from an earlier removal stays; only what this job made goes.
                    existing.mkdir(parents=True)
                    (existing / 'eski').write_text('kept')
                with self.assertRaises(cfg.ContainerConfigError) as err:
                    self.install()
                self.assertIn('Yapılan her şey geri alındı', str(err.exception))
                if label in ('restarted', 'gone'):
                    self.assertIn('journalctl -u konsol-notlar_web.service', str(err.exception))
                if label != 'guard':
                    self.assert_nothing_left()
                self.assertFalse(os.path.lexists(Path(self.env['UYGULAMA_STATE_DIR']) / 'notlar'))
                self.assertEqual(self.host.containers, {})
                if label == 'second start':
                    self.assertEqual((existing / 'eski').read_text(), 'kept')
                    self.assertFalse((Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar' / 'db-data').exists())
                else:
                    self.assertFalse((Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar').exists())
                record = self.operation()
                self.assertEqual(record['state'], 'failed')
                self.assertTrue(record['failed_step'])
                self.assertNotIn('never-print', json.dumps(record), 'a tool error is never echoed')
                self.assert_no_secret()

    def test_a_failed_rollback_says_so(self):
        self.host.fails('systemctl start konsol-notlar_web.service')
        self.host.fails('podman secret rm')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install()
        self.assertIn('Geri alma da tamamlanamadı', str(err.exception))


class TakeoverTests(WorkerCase):
    def old(self, running=True):
        point = self.root / 'volumes/veri/_data'
        point.mkdir(parents=True)
        (point / 'kayit.txt').write_text('eski veri')
        self.host.volumes['veri'] = {'Name': 'veri', 'Driver': 'local', 'Options': {}, 'Mountpoint': str(point)}
        self.host.containers['eski'] = {'Id': 'a' * 64, 'Name': 'eski', 'State': {'Running': running, 'Status': 'running'},
                                        'Config': {'Labels': {}}, 'Mounts': [{'Type': 'volume', 'Name': 'veri', 'Destination': '/data'}]}

    def request(self):
        return {'name': 'devir', 'metin': TAKEOVER, 'yanitlar': auto_answers(TAKEOVER, 'devir'),
                'kaynak': {'tur': 'konteyner', 'konteyner': 'eski'}}

    def test_the_old_container_stops_its_volume_is_copied_and_it_goes_only_when_the_application_is_ready(self):
        self.old()
        self.execute('uygulama-kur', self.request())
        copied = Path(self.env['UYGULAMA_VERI_DIR']) / 'devir/veri/kayit.txt'
        self.assertEqual(copied.read_text(), 'eski veri')
        order = [' '.join(c[:2]) + ' ' + c[-1] for c in self.host.calls if c[:2] in (['podman', 'stop'], ['systemctl', 'start'], ['podman', 'rm'])]
        self.assertEqual(order, ['podman stop eski', 'systemctl start konsol-devir_app.service', 'podman rm eski'])
        rm = next(c for c in self.host.calls if c[:2] == ['podman', 'rm'])
        self.assertNotIn('--volumes', rm, 'the old named volume stays')
        self.assertEqual(self.record('devir')['source'], dict(self.record('devir')['source'], tur='konteyner', konteyner='eski'))

    def test_a_failed_takeover_starts_the_old_container_again(self):
        self.old()
        self.host.fails('systemctl start konsol-devir_app.service')
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-kur', self.request())
        self.assertTrue(self.host.containers['eski']['State']['Running'])
        self.assertFalse((Path(self.env['UYGULAMA_VERI_DIR']) / 'devir').exists())
        self.assert_nothing_left('devir')

    def test_a_volume_is_copied_only_into_a_new_folder(self):
        self.old()
        (Path(self.env['UYGULAMA_VERI_DIR']) / 'devir/veri').mkdir(parents=True)
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-kur', self.request())
        self.assertIn('zaten var', str(err.exception))
        self.assertTrue(self.host.containers['eski']['State']['Running'], 'refused before the old container stopped')

    def test_only_a_standalone_container_is_taken_over(self):
        self.old()
        self.host.containers['eski']['Config']['Labels'] = {'PODMAN_SYSTEMD_UNIT': 'baskasi.service'}
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-kur', self.request())
        self.assertEqual(err.exception.status, 409)
        self.assertEqual(self.host.containers['eski']['State']['Running'], True, 'nothing was stopped')


class LifecycleTests(WorkerCase):
    def setUp(self):
        super().setUp()
        self.install()
        self.host.calls.clear()

    def revision(self):
        return self.record()['places']['revision']

    def unit(self, service):
        return (Path(self.env['KONTEYNER_BIRIM_DIR']) / ('konsol-notlar_%s.container' % service)).read_text()

    def test_stop_and_start_keep_the_order_and_the_boot_choice(self):
        self.execute('uygulama-durdur', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(self.host.stopped(), ['konsol-notlar_web.service', 'konsol-notlar_db.service'], 'reverse order')
        self.assertTrue(self.record()['places']['stopped'])
        self.assertNotIn('[Install]', self.unit('web'))
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-yeniden-baslat', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(err.exception.status, 409, 'restart is for a running application')
        self.host.calls.clear()
        self.execute('uygulama-baslat', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(self.host.started(), ['konsol-notlar_db.service', 'konsol-notlar_web.service'])
        self.assertFalse(self.record()['places']['stopped'])
        self.assertIn('WantedBy=multi-user.target', self.unit('web'))
        self.assert_no_secret()

    def test_restart_stops_in_reverse_and_starts_in_order(self):
        self.execute('uygulama-yeniden-baslat', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(self.host.stopped(), ['konsol-notlar_web.service', 'konsol-notlar_db.service'])
        self.assertEqual(self.host.started(), ['konsol-notlar_db.service', 'konsol-notlar_web.service'])

    def test_a_stale_revision_changes_nothing(self):
        for action in ('uygulama-baslat', 'uygulama-durdur', 'uygulama-yeniden-baslat', 'uygulama-guncelle', 'uygulama-kaldir'):
            with self.subTest(action=action), self.assertRaises(cfg.ContainerConfigError) as err:
                self.execute(action, {'name': 'notlar', 'revizyon': 'b' * 32, 'veri': 'sakla'})
            self.assertEqual(err.exception.status, 409)
        self.assertFalse([c for c in self.host.calls if c[:2] in (['systemctl', 'stop'], ['systemctl', 'start'])])
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-baslat', {'name': 'yok', 'revizyon': 'b' * 32})
        self.assertEqual(err.exception.status, 404)

    def test_a_failed_stop_restores_the_record_and_the_running_units(self):
        before = apps.Records(self.env).snapshot('notlar')
        self.host.fails('systemctl daemon-reload')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-durdur', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertIn('Önceki durum geri yüklendi', str(err.exception))
        self.assertEqual(apps.Records(self.env).snapshot('notlar'), before)
        self.assertIn('WantedBy=multi-user.target', self.unit('web'))
        self.assertEqual(self.host.started(), ['konsol-notlar_db.service', 'konsol-notlar_web.service'])

    def test_a_failed_start_stops_what_started_and_keeps_it_stopped(self):
        self.execute('uygulama-durdur', {'name': 'notlar', 'revizyon': self.revision()})
        before = apps.Records(self.env).snapshot('notlar')
        self.host.calls.clear()
        self.host.fails('systemctl start konsol-notlar_web.service')
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-baslat', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(apps.Records(self.env).snapshot('notlar'), before)
        self.assertNotIn('[Install]', self.unit('web'))
        self.assertIn('konsol-notlar_db.service', self.host.stopped())
        self.assertEqual(self.host.units.get('konsol-notlar_db.service'), 'inactive')

    def test_update_pulls_again_and_changes_only_when_a_digest_moved(self):
        result = self.execute('uygulama-guncelle', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(result['changed'], False)
        self.assertFalse([c for c in self.host.calls if c[:2] in (['systemctl', 'stop'], ['systemctl', 'start'])])
        self.host.digest['registry.example/notlar/web'] = 'sha256:' + '7' * 64
        result = self.execute('uygulama-guncelle', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(result['changed'], True)
        self.assertIn('Image=registry.example/notlar/web@sha256:' + '7' * 64, self.unit('web'))
        self.assertEqual(self.host.started()[-2:], ['konsol-notlar_db.service', 'konsol-notlar_web.service'])

    def test_a_failed_update_puts_back_the_old_digests_and_starts_them(self):
        old = self.unit('web')
        self.host.digest['registry.example/notlar/web'] = 'sha256:' + '7' * 64
        self.host.unhealthy.add('notlar_web')
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-guncelle', {'name': 'notlar', 'revizyon': self.revision()})
        self.assertEqual(self.unit('web'), old)
        self.assertEqual(self.record()['places']['images']['web'], 'registry.example/notlar/web@sha256:' + 'd' * 64)
        self.assertEqual(self.host.units.get('konsol-notlar_web.service'), 'active', 'the old units run again')

    def test_an_edit_keeps_a_secret_renews_another_and_writes_the_new_environment(self):
        [old_secret] = self.record()['places']['secrets'].values()
        given = app_fixtures.answers()
        given['answers']['var:DB_PASSWORD'] = {'keep': True}
        text = app_fixtures.TEXT.replace('LOG_LEVEL: info', 'LOG_LEVEL: debug')
        self.execute('uygulama-tanim', {'name': 'notlar', 'metin': text, 'yanitlar': given, 'revizyon': self.revision()})
        record = self.record()
        self.assertEqual(list(record['places']['secrets'].values()), [old_secret], 'the kept value is the same secret')
        self.assertFalse([c for c in self.host.calls if c[:3] == ['podman', 'secret', 'create']])
        self.assertEqual((Path(self.env['UYGULAMA_STATE_DIR']) / 'notlar/env/web.env').read_text(), 'LOG_LEVEL=debug\n')
        self.assertEqual(record['text'], text)
        self.assertEqual(record['places']['ports'], {'web:8080/tcp': 62100}, 'the allocation is kept for the same key')
        # A new value: a new secret; the old one goes only after the new units run.
        self.host.calls.clear()
        given['answers']['var:DB_PASSWORD'] = {'value': 'yeni-' + SECRET}
        self.execute('uygulama-tanim', {'name': 'notlar', 'metin': text, 'yanitlar': given, 'revizyon': self.revision()})
        [new_secret] = self.record()['places']['secrets'].values()
        self.assertNotEqual(new_secret, old_secret)
        self.assertEqual(self.host.secrets, {new_secret: 'yeni-' + SECRET})
        calls = [' '.join(c) for c in self.host.calls]
        last_start = max(i for i, c in enumerate(calls) if c.startswith('systemctl start'))
        removal = next(i for i, c in enumerate(calls) if c == 'podman secret rm ' + old_secret)
        self.assertGreater(removal, last_start)
        self.assert_no_secret(SECRET, 'yeni-' + SECRET)

    def test_a_failed_edit_takes_its_new_secret_back_and_runs_the_old_application(self):
        before = apps.Records(self.env).snapshot('notlar')
        units = self.unit_files(), self.unit('web')
        secrets = dict(self.host.secrets)
        given = app_fixtures.answers()
        given['answers']['var:DB_PASSWORD'] = {'value': 'yeni-' + SECRET}
        self.host.fails('systemctl start konsol-notlar_web.service')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-tanim', {'name': 'notlar', 'metin': app_fixtures.TEXT, 'yanitlar': given, 'revizyon': self.revision()})
        self.assertIn('Önceki durum geri yüklendi', str(err.exception))
        self.assertEqual(apps.Records(self.env).snapshot('notlar'), before)
        self.assertEqual((self.unit_files(), self.unit('web')), units)
        self.assertEqual(self.host.secrets, secrets, 'the new secret is gone, the old one kept')
        self.assertEqual(self.host.units.get('konsol-notlar_web.service'), 'active')

    def test_an_edit_drops_a_service_and_keeps_its_folder(self):
        text = app_fixtures.SIMPLE.replace('sayac', 'notlar')
        given = auto_answers(text, 'notlar')
        self.execute('uygulama-tanim', {'name': 'notlar', 'metin': text, 'yanitlar': given, 'revizyon': self.revision()})
        self.assertEqual(self.unit_files(), ['konsol-notlar.network', 'konsol-notlar_app.container'])
        self.assertTrue((Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar/db-data').is_dir(), 'a dropped folder stays on disk')
        self.assertEqual(self.host.secrets, {}, 'a dropped secret goes after the new units run')
        self.assertNotIn('notlar_db', self.host.containers)

    def test_an_edit_cannot_rename_the_application(self):
        given = app_fixtures.answers()
        given['name'] = 'baska'
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-tanim', {'name': 'notlar', 'metin': app_fixtures.TEXT.replace('name: notlar', 'name: baska'),
                                            'yanitlar': given, 'revizyon': self.revision()})
        self.assertEqual(err.exception.status, 409)

    def test_removal_keeps_the_data_by_default_and_deletes_it_only_with_the_name(self):
        data = Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar'
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.revision(), 'veri': 'sil', 'onay': 'yanlis'})
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.revision(), 'veri': 'sakla'})
        self.assert_nothing_left()
        self.assertTrue((data / 'uploads').is_dir(), 'K9: the data stays')
        self.assertFalse([c for c in self.host.calls if c[:3] == ['podman', 'image', 'rm']], 'images stay for Gelişmiş')
        self.install()
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.revision(), 'veri': 'sil', 'onay': 'notlar'})
        self.assertFalse(data.exists())

    def test_an_interrupted_removal_can_be_run_again(self):
        self.host.fails('podman secret rm')
        revision = self.revision()
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': revision, 'veri': 'sakla'})
        self.assertTrue(self.record(), 'the record stays until the end, so the removal can be repeated')
        self.assertEqual(self.unit_files(), [])
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': revision, 'veri': 'sakla'})
        self.assert_nothing_left()


class DraftAndResourceTests(WorkerCase):
    def test_an_image_draft_is_a_compose_file_the_inspector_reads(self):
        result = self.execute('uygulama-taslak', {'name': 'registry.example/sayac:2', 'imaj': 'registry.example/sayac:2'})
        self.assertEqual(result['kaynak'], {'tur': 'imaj', 'imaj': 'registry.example/sayac:2'})
        inspection = master_inspector.inspect(result['metin'])
        self.assertEqual(inspection['refusals'], [])
        self.assertEqual([(p['port'], p['protocol']) for p in inspection['services'][0]['ports']], [(53, 'udp'), (8080, 'tcp')])
        self.assertEqual(self.unit_files(), [])
        self.assertFalse(os.path.exists(self.env['UYGULAMA_STATE_DIR']))
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-taslak', {'name': 'x', 'imaj': 'Kötü İmaj'})

    def test_an_image_or_network_an_application_uses_is_not_removed(self):
        self.install()
        pinned = self.record()['places']['images']['web']
        original = self.host.__call__

        def run(argv, timeout=60, input=None, **kwargs):
            if list(argv[:3]) == ['podman', 'image', 'inspect'] and argv[-1] == pinned:
                return subprocess.CompletedProcess(argv, 0, json.dumps([{'Id': 'sha256:' + 'e' * 64, 'RepoDigests': [pinned]}]), '')
            if list(argv[:3]) == ['podman', 'ps', '-a']:
                return subprocess.CompletedProcess(argv, 0, '[]', '')
            if list(argv[:3]) == ['podman', 'network', 'inspect']:
                return subprocess.CompletedProcess(argv, 0, json.dumps([{'driver': 'bridge', 'labels': {
                    'io.master-stack.managed': 'uygulama', 'io.master-stack.uygulama': 'notlar'}}]), '')
            return original(argv, timeout=timeout, input=input, **kwargs)
        self.manager.run = run
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('image-remove', {'image': pinned})
        self.assertIn('uygulamanın kaydında', str(err.exception))
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('network-remove', {'name': 'ksl-notlar'})
        self.assertIn('uygulamayla birlikte', str(err.exception))
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('network-create', {'name': 'ksl-baska'})

    def test_an_operation_id_runs_once_and_its_record_never_holds_the_request(self):
        ident = uuid.uuid4().hex
        request = {'name': 'notlar', 'metin': app_fixtures.TEXT, 'yanitlar': app_fixtures.answers(), 'kaynak': {'tur': 'dosya'}}
        self.manager.execute('uygulama-kur', request, ident)
        with self.assertRaises(cfg.ContainerConfigError) as err:
            worker.Manager(str(self.state), run=self.host, network=self.guard).execute('uygulama-kur', request, ident)
        self.assertEqual(err.exception.status, 409)
        record = json.loads((Path(self.env['KONTEYNER_STATE_DIR']) / 'operations' / (ident + '.json')).read_text())
        self.assertEqual(set(record) - {'result', 'finished_at'}, {'id', 'action', 'name', 'state', 'step', 'created_at', 'updated_at'})
        self.assertEqual((record['name'], record['action']), ('notlar', 'uygulama-kur'))

    def test_a_job_waits_briefly_for_a_held_install_lock(self):
        import fcntl
        import threading
        lock = Path(self.env['RUNTIME_DIR']) / 'install.lock'
        with open(lock, 'a') as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            timer = threading.Timer(0.5, lambda: fcntl.flock(held.fileno(), fcntl.LOCK_UN))
            timer.start()
            try:
                self.execute('volume-create', {'name': 'yedek'})
            finally:
                timer.cancel()
        self.assertIn(['podman', 'volume', 'create', '--label', 'io.master-stack.managed=konsol', 'yedek'], self.host.calls)
        with open(lock, 'a') as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            with patch.object(worker, 'LOCK_WAIT', 0.2), self.assertRaises(cfg.ContainerConfigError) as err:
                self.execute('volume-create', {'name': 'ikinci'})
        self.assertEqual(err.exception.status, 409)

    def test_a_pending_settings_change_blocks_every_job(self):
        pending = self.root / 'ayarlar-bekleyen.json'
        pending.write_text('{}')
        self.env['SETTINGS_PENDING_FILE'] = str(pending)
        self.state = app_fixtures.write_state(self.root, self.env)
        manager = worker.Manager(str(self.state), run=self.host, network=self.guard, quadlet='/fixture/quadlet')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            manager.execute('uygulama-kur', {'name': 'notlar', 'metin': app_fixtures.TEXT, 'yanitlar': app_fixtures.answers(),
                                             'kaynak': {'tur': 'dosya'}}, uuid.uuid4().hex)
        self.assertIn('Onay bekleyen', str(err.exception))


class SrvWalkTests(unittest.TestCase):
    def test_install_time_check_refuses_a_linked_or_hidden_folder(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        (root / 'srv/media').mkdir(parents=True)
        (root / 'elsewhere').mkdir()
        (root / 'srv/link').symlink_to(root / 'elsewhere', target_is_directory=True)
        env = dict(app_fixtures.env(root), SERVER_ROOT=str(root / 'srv'))
        state = app_fixtures.write_state(root, env)
        manager = worker.Manager(str(state), run=FakeHost(env))
        self.assertEqual(manager.srv_folder(str(root / 'srv/media')), str(root / 'srv/media'))
        for path in ('srv/link', 'srv/.cop', 'srv/yok', 'elsewhere', 'srv'):
            with self.subTest(path=path), self.assertRaises(cfg.ContainerConfigError) as err:
                manager.srv_folder(str(root / path))
            self.assertEqual(err.exception.status, 409)


if __name__ == '__main__':
    unittest.main()
