"""The root worker (rebuild DD-271, phases 3 and 4): an application's lifecycle with its access rows, the
settings worker's row change and its restore, the address refresh (--adres-yenile) and Gelişmiş's Podman
cleanup (K8). Podman, systemctl, Quadlet, the guard and the publication projection are fakes; every rollback path
is driven to its end and checked for what it left behind. No secret value may reach an argument, a file other
than Podman's standard input, an operation record, a log line or a reply."""
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
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
        self.journal = {}
        self.vanish = set()
        self.version = '5.4.2'
        self.volumes = {}
        self.reloads = 0
        self.reset = []
        # The cleanup's view: images by ID, the containers Podman's filters find ("ancestor=<id>", "network=<name>",
        # "volume=<name>") and the images another one depends on (their last tag cannot take them).
        self.images = {}
        self.users = {}
        self.children = set()

    def container(self, key):
        """A container by its name or its ID."""
        if key in self.containers:
            return self.containers[key]
        return next((c for c in self.containers.values() if c.get('Id') == key), None)

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
            code = 0 if self.container(argv[-1]) is not None else 1
            if code == 0 and argv[-1] in self.vanish:
                self.vanish.discard(argv[-1])
                self.containers.pop(argv[-1])
                self.units['konsol-%s.service' % argv[-1]] = 'failed'
        elif argv[:3] == ['podman', 'network', 'exists']:
            code = 0 if argv[-1] in self.networks else 1
        elif argv[:3] == ['podman', 'pod', 'exists']:
            code = 0 if argv[-1] in self.pods else 1
        elif argv[:3] == ['podman', 'inspect', '--type']:
            if self.container(argv[-1]) is not None:
                out = json.dumps([self.container(argv[-1])])
            else:
                code = 125
        elif argv[:3] == ['podman', 'image', 'exists']:
            code = 0 if argv[-1] in self.images else 1
        elif argv[:3] == ['podman', 'image', 'inspect'] and argv[-1] in self.images:
            out = json.dumps([self.images[argv[-1]]])
        elif argv[:3] == ['podman', 'image', 'rm']:
            for target in argv[3:]:
                if target in self.images and target not in self.children:
                    del self.images[target]
                for ident, info in list(self.images.items()):
                    if target in info['RepoTags']:
                        info['RepoTags'].remove(target)
                        if not info['RepoTags'] and ident not in self.children:
                            del self.images[ident]
        elif argv[:3] == ['podman', 'ps', '-a'] and '--filter' in argv:
            out = json.dumps(self.users.get(argv[argv.index('--filter') + 1], []))
        elif argv[:3] == ['podman', 'ps', '-a']:
            out = json.dumps([{'Id': c['Id'], 'Names': [name]} for name, c in sorted(self.containers.items())])
        elif argv[:3] == ['podman', 'volume', 'exists']:
            code = 0 if argv[-1] in self.volumes else 1
        elif argv[:3] == ['podman', 'volume', 'rm']:
            self.volumes.pop(argv[-1], None)
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
        elif argv[0] == 'journalctl' and argv[1].startswith('CONTAINER_NAME='):
            out = self.journal.get(argv[1].split('=', 1)[1], '')
        elif argv[:2] == ['systemctl', 'daemon-reload']:
            self.reloads += 1
        elif argv[:2] == ['systemctl', 'reset-failed']:
            self.reset.extend(argv[3:])
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
        self.containers[name] = {'Id': hashlib.sha256(name.encode()).hexdigest(), 'Name': name, 'State': {'Running': True, 'Status': 'running',
                                                                         'Health': {'Status': health}},
                                 'EffectiveCaps': caps, 'BoundingCaps': caps,
                                 'Config': {'Labels': labels, 'User': user.group(1) if user else ''}}

    def started(self):
        return [c[-1] for c in self.calls if c[:2] == ['systemctl', 'start']]

    def stopped(self):
        return [c[-1] for c in self.calls if c[:2] == ['systemctl', 'stop']]


class FakeNetwork:
    """The guard: it reads every record as the real one does, and remembers which applications it saw (and,
    with a host, notes its turn among the host's calls)."""

    def __init__(self, host=None):
        self.applied = []
        self.inputs = []
        self.fail = 0
        self.host = host

    def apply(self, env, run):
        if self.fail:
            self.fail -= 1
            raise cfg.ContainerConfigError(503, 'Konteyner yönlendirme koruması uygulanamadı.')
        rows = apps.guard_input(env)
        self.applied.append([row['app'] for row in rows])
        self.inputs.append(rows)
        if self.host is not None:
            self.host.calls.append(['guard', 'apply'])


class FakePublisher:
    """The publication projection: the rows it saw each time, or a failure."""

    def __init__(self, env, host):
        self.env, self.host = env, host
        self.seen = []
        self.fail = 0

    def __call__(self):
        self.host.calls.append(['publish'])
        if self.fail:
            self.fail -= 1
            raise cfg.ContainerConfigError(502, 'WAN dinleyicisi/güvenlik duvarı uygulanamadı (Caddy yapılandırması geçersiz).')
        self.seen.append([r['id'] for r in apps.access_rows(self.env)])


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
        self.guard = FakeNetwork(self.host)
        self.publisher = FakePublisher(self.env, self.host)
        self.now = [1000.0]
        self.manager = self.make_manager()
        self.checked = []
        # /srv itself is the host's; the DD-226 walk is checked in its own test.
        patcher = patch.object(worker.binds, 'walk', side_effect=lambda source: self.checked.append(source) or os.open(self.root, os.O_RDONLY))
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(apps, 'bindable', return_value=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def make_manager(self):
        return worker.Manager(str(self.state), run=self.host, network=self.guard, quadlet='/fixture/quadlet',
                              clock=lambda: self.now[0], sleep=self.tick, publisher=self.publisher)

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
                if label in ('first start', 'second start', 'unhealthy', 'restarted', 'gone', 'wrong user'):
                    self.assertIn('konsol-notlar_web.service', self.host.reset, 'a failed unit is not left listed')
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

    def test_the_job_log_holds_each_step_and_fact_in_order(self):
        self.install()
        log = self.operation()['gunluk']
        self.assertEqual(log[0], {'t': log[0]['t'], 'tur': 'adim', 'ileti': 'Doğrulanıyor'})
        self.assertEqual(log[-1]['tur'], 'tamam')
        texts = [line['ileti'] for line in log]
        for before, after in [('Kayıt yazılıyor', 'İmaj indiriliyor: registry.example/notlar/web:1.4'),
                              ('İmaj indiriliyor: registry.example/notlar/web:1.4', 'İmaj sabitlendi: registry.example/notlar/web@sha256:' + 'd' * 64),
                              ('Başlatılıyor: konsol-notlar_web.service', 'Hazır olması bekleniyor'),
                              ('Hazır olması bekleniyor', 'web çalışıyor.'), ('db çalışıyor.', 'Adresler yayımlanıyor')]:
            self.assertLess(texts.index(before), texts.index(after), (before, after))
        self.assertEqual({line['tur'] for line in log}, {'adim', 'bilgi', 'tamam'})
        self.assertFalse([c for c in self.host.calls if c[0] == 'journalctl'], 'a running install reads no journal')

    def test_a_failed_install_keeps_its_containers_output_masked_and_names_the_start_question(self):
        self.host.restarts['konsol-notlar_web.service'] = 1
        self.host.journal['notlar_web'] = ''.join('satır %d\n' % i for i in range(30)) + \
            '\x1b[31mfatal:\x1b[0m parola %s kabul edilmedi\x07\n\n' % SECRET
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install()
        self.assertIn('web başladıktan hemen sonra durdu', str(err.exception))
        self.assertIn(worker.DIRECT_HINT.strip(), str(err.exception))
        record = self.operation()
        self.assertEqual(record['soru'], 'start:web')
        kinds = [(line['tur'], line['ileti']) for line in record['gunluk']]
        output = [text for kind, text in kinds if kind == 'cikti']
        self.assertEqual(len(output), worker.OUTPUT_LINES)
        self.assertEqual(output[-1], 'fatal: parola •••• kabul edilmedi')
        self.assertEqual(output[0], 'satır 11')
        cause = kinds.index(('hata', 'web başladıktan hemen sonra durdu (günlüğü: journalctl -u konsol-notlar_web.service).'
                             + worker.DIRECT_HINT))
        self.assertLess(kinds.index(('cikti', output[-1])), cause)
        self.assertLess(cause, kinds.index(('adim', 'Geri alınıyor')))
        self.assertEqual(kinds[-1], ('bilgi', 'Yapılan her şey geri alındı.'))
        self.assertEqual([k for k, _ in kinds].count('hata'), 1, 'the cause is said once')
        journal = [c for c in self.host.calls if c[0] == 'journalctl']
        self.assertEqual(journal, [['journalctl', 'CONTAINER_NAME=notlar_web', '--since', '@%d' % record['created_at'],
                                    '-n', str(worker.OUTPUT_LINES), '-o', 'cat', '--no-pager']])
        self.assert_nothing_left()
        self.assert_no_secret()

    def test_a_root_start_names_no_question_and_an_unreadable_journal_hides_nothing(self):
        self.host.restarts['konsol-notlar_db.service'] = 1
        self.host.fails('journalctl CONTAINER_NAME=notlar_db')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install()
        self.assertIn('db başladıktan hemen sonra durdu', str(err.exception))
        self.assertNotIn(worker.DIRECT_HINT.strip(), str(err.exception))
        record = self.operation()
        self.assertNotIn('soru', record)
        self.assertIn({'t': record['gunluk'][0]['t'], 'tur': 'bilgi', 'ileti': 'notlar_db konteyneri bir şey yazmadı.'},
                      [dict(line, t=record['gunluk'][0]['t']) for line in record['gunluk']])
        self.assertNotIn('never-print', json.dumps(record))

    def test_a_multi_line_secret_and_one_with_a_tab_are_masked_before_a_line_is_cleaned(self):
        self.manager.begin('uygulama-kur', {'name': 'notlar'}, uuid.uuid4().hex)
        key = '-----BEGIN KEY-----\nQUJDREVGR0hJSktMTU5PUA==\nUVJTVFVWV1hZWjAxMjM0NQ==\n-----END KEY-----'
        tabbed = 'parola\tsekmeli-77'
        self.host.journal['notlar_web'] = 'anahtar: %s\nyeniden: %s\nbaşka: %s\n' % (key, key.splitlines()[2], tabbed)
        self.manager.container_output('notlar_web', {'anahtar': key, 'parola': tabbed})
        lines = [line['ileti'] for line in self.operation()['gunluk'] if line['tur'] == 'cikti']
        self.assertEqual(lines, ['anahtar: ••••', 'yeniden: ••••', 'başka: ••••'])

    def test_records_older_than_thirty_days_go_when_a_job_begins(self):
        folder = Path(self.env['KONTEYNER_STATE_DIR']) / 'operations'
        folder.mkdir(parents=True)
        old, recent = folder / ('a' * 32 + '.json'), folder / ('b' * 32 + '.json')
        for path in (old, recent):
            path.write_text('{}')
        stale = time.time() - (worker.RECORD_DAYS + 1) * 86400
        os.utime(old, (stale, stale))
        self.install()
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())

    def test_the_log_keeps_its_newest_lines(self):
        self.manager.begin('uygulama-baslat', {'name': 'notlar'}, uuid.uuid4().hex)
        for i in range(worker.LOG_LINES + 5):
            self.manager.note('satır %d ' % i + 'x' * worker.LINE_CHARS)
        log = self.operation()['gunluk']
        self.assertEqual(len(log), worker.LOG_LINES)
        self.assertTrue(log[-1]['ileti'].startswith('satır %d ' % (worker.LOG_LINES + 4)))
        self.assertEqual({len(line['ileti']) for line in log}, {worker.LINE_CHARS})

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
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-baslat', {'name': 'notlar', 'revizyon': self.revision()})
        # Any job but an install says why once, as its log's last line; only an install reads a journal.
        log = self.operation()['gunluk']
        self.assertEqual(log[-1]['tur'], 'hata')
        self.assertEqual(log[-1]['ileti'], str(err.exception))
        self.assertEqual([line['tur'] for line in log].count('hata'), 1)
        self.assertFalse([c for c in self.host.calls if c[0] == 'journalctl'])
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
        self.assertEqual(self.host.reset, ['konsol-notlar_db.service', 'konsol-notlar_web.service'],
                         'the dropped services (web and db; the new file has app) are forgotten')

    def test_an_edit_cannot_rename_the_application(self):
        given = app_fixtures.answers()
        given['name'] = 'baska'
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-tanim', {'name': 'notlar', 'metin': app_fixtures.TEXT.replace('name: notlar', 'name: baska'),
                                            'yanitlar': given, 'revizyon': self.revision()})
        self.assertEqual(err.exception.status, 409)

    def test_removal_takes_the_unused_images_and_with_the_name_the_data_and_the_job_records(self):
        data = Path(self.env['UYGULAMA_VERI_DIR']) / 'notlar'
        operations = Path(self.env['KONTEYNER_STATE_DIR']) / 'operations'
        places = self.record()['places']['images']
        web, db = '%064x' % 0xaa, '%064x' % 0xbb
        # web's image is only notlar's; db's is also another container's, so it stays.
        for ident, ref, tag in ((web, places['web'], 'registry.example/notlar/web:1.4'), (db, places['db'], 'registry.example/notlar/db:16')):
            info = {'Id': 'sha256:' + ident, 'RepoTags': [tag], 'RepoDigests': [ref]}
            self.host.images.update({ident: info, ref: info})
        self.host.users['ancestor=' + db] = [{'Id': 'c' * 64}]
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.revision(), 'veri': 'sil', 'onay': 'yanlis'})
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.revision(), 'veri': 'sakla'})
        self.assert_nothing_left()
        self.assertTrue((data / 'uploads').is_dir(), 'kept when asked')
        self.assertEqual(set(self.host.reset), {'konsol-notlar_web.service', 'konsol-notlar_db.service', 'konsol-notlar-network.service'},
                         'systemd forgets the failed state of every unit that went')
        self.assertIn(['podman', 'image', 'rm', 'registry.example/notlar/web:1.4'], self.host.calls)
        self.assertNotIn(web, self.host.images, 'the unused image went')
        self.assertIn(db, self.host.images, 'an image a container uses stays')
        log = [(line['tur'], line['ileti']) for line in self.operation()['gunluk']]
        self.assertIn(('bilgi', 'İmaj kaldırıldı: %s' % places['web']), log)
        self.assertIn(('bilgi', 'İmaj kaldı (%s): İmaj bir konteynerde kullanılıyor.' % places['db']), log)
        self.assertEqual(self.operation()['state'], 'done')
        # Again, now deleting: the data and notlar's earlier job records go; another application's and this job's stay.
        self.install()
        other = operations / ('f' * 32 + '.json')
        other.write_text(json.dumps({'id': 'f' * 32, 'name': 'pano', 'action': 'uygulama-kur'}))
        before = {p.name for p in operations.iterdir() if json.loads(p.read_text()).get('name') == 'notlar'}
        self.assertGreaterEqual(len(before), 3, 'two installs and a removal so far')
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.revision(), 'veri': 'sil', 'onay': 'notlar'})
        self.assertFalse(data.exists())
        left = [json.loads(p.read_text()) for p in operations.iterdir()]
        self.assertEqual([j['action'] for j in left if j.get('name') == 'notlar'], ['uygulama-kaldir'], 'only this removal stays')
        self.assertTrue(other.exists())

    def test_an_interrupted_removal_can_be_run_again(self):
        self.host.fails('podman secret rm')
        revision = self.revision()
        with self.assertRaises(cfg.ContainerConfigError):
            self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': revision, 'veri': 'sakla'})
        self.assertTrue(self.record(), 'the record stays until the end, so the removal can be repeated')
        self.assertEqual(self.unit_files(), [])
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': revision, 'veri': 'sakla'})
        self.assert_nothing_left()


class DraftAndJobTests(WorkerCase):
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

    def test_an_operation_id_runs_once_and_its_record_never_holds_the_request(self):
        ident = uuid.uuid4().hex
        request = {'name': 'notlar', 'metin': app_fixtures.TEXT, 'yanitlar': app_fixtures.answers(), 'kaynak': {'tur': 'dosya'}}
        self.manager.execute('uygulama-kur', request, ident)
        with self.assertRaises(cfg.ContainerConfigError) as err:
            worker.Manager(str(self.state), run=self.host, network=self.guard).execute('uygulama-kur', request, ident)
        self.assertEqual(err.exception.status, 409)
        record = json.loads((Path(self.env['KONTEYNER_STATE_DIR']) / 'operations' / (ident + '.json')).read_text())
        self.assertEqual(set(record) - {'result', 'finished_at'}, {'id', 'action', 'name', 'state', 'step', 'created_at', 'updated_at', 'gunluk'})
        self.assertEqual({tuple(sorted(line)) for line in record['gunluk']}, {('ileti', 't', 'tur')})
        self.assertEqual((record['name'], record['action']), ('notlar', 'uygulama-kur'))

    def test_a_job_waits_briefly_for_a_held_install_lock(self):
        import fcntl
        import threading
        lock = Path(self.env['RUNTIME_DIR']) / 'install.lock'
        with open(lock, 'a') as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            timer = threading.Timer(0.5, lambda: fcntl.flock(held.fileno(), fcntl.LOCK_UN))
            timer.start()
            self.host.volumes.update(yedek={}, ikinci={})
            try:
                self.execute('temizlik', {'birimler': ['yedek']})
            finally:
                timer.cancel()
        self.assertIn(['podman', 'volume', 'rm', 'yedek'], self.host.calls)
        with open(lock, 'a') as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            with patch.object(worker, 'LOCK_WAIT', 0.2), self.assertRaises(cfg.ContainerConfigError) as err:
                self.execute('temizlik', {'birimler': ['ikinci']})
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


class CleanupTests(WorkerCase):
    """K8: Gelişmiş's cleanup. Every item is checked again right before it goes; what is in use or gone stays and is
    named, the rest goes; nothing is removed with --force."""
    P, U, N, C = ('%064x' % n for n in (0x1, 0x2, 0x3, 0x4))

    def setUp(self):
        super().setUp()
        self.install()
        pinned = self.record()['places']['images']['web']
        self.host.images.update({
            self.P: {'Id': self.P, 'RepoTags': ['registry.example/notlar/web:9'], 'RepoDigests': [pinned]},
            self.U: {'Id': self.U, 'RepoTags': ['registry.example/artik:2', 'registry.example/artik:latest'], 'RepoDigests': []},
            self.N: {'Id': self.N, 'RepoTags': [], 'RepoDigests': ['registry.example/eski@sha256:' + '5' * 64]},
            self.C: {'Id': self.C, 'RepoTags': ['registry.example/kullanilan:1'], 'RepoDigests': []}})
        self.host.users.update({'ancestor=' + self.C: [{'Id': 'c' * 64}], 'network=ozel': [{'Id': 'c' * 64}],
                                'volume=eski-veri': [{'Id': 'c' * 64}]})
        self.host.networks.update({'bos-ag', 'ozel'})
        self.host.volumes.update({'yetim': {}, 'eski-veri': {}})
        self.veri = Path(self.env['UYGULAMA_VERI_DIR'])
        (self.veri / 'eskiuygulama' / 'veri').mkdir(parents=True)
        (self.veri / 'eskiuygulama' / 'veri' / 'dosya').write_text('x')
        (self.veri / 'baglanmis' / 'alt').mkdir(parents=True)
        self.host.containers['bagli'] = {'Id': 'b' * 64, 'Name': 'bagli', 'State': {'Running': False},
                                         'Mounts': [{'Type': 'bind', 'Source': str(self.veri / 'baglanmis' / 'alt')}]}
        self.host.calls.clear()

    def test_each_item_is_checked_again_and_only_what_nothing_uses_goes(self):
        request = {'imajlar': [self.U, self.N, self.P, self.C], 'aglar': ['bos-ag', 'ozel', 'ksl-notlar'],
                   'birimler': ['yetim', 'eski-veri'], 'klasorler': ['eskiuygulama', 'baglanmis', 'notlar']}
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('temizlik', dict(request, name='Podman'))
        text = str(err.exception)
        self.assertEqual(err.exception.status, 409)
        self.assertTrue(text.startswith('7 öge kaldırılmadı (5 kaldırıldı): '), text)
        for reason in ('İmaj bir uygulamanın kaydında kullanılıyor.', 'İmaj bir konteynerde kullanılıyor.',
                       'ozel: Ağ bir konteynerde kullanılıyor.', 'ksl-notlar: Ağ bir uygulamanın',
                       'eski-veri: Birim bir konteynerde kullanılıyor.', 'baglanmis: Klasör bir konteynerde bağlı.',
                       'notlar: Bu klasörün uygulaması var'):
            self.assertIn(reason, text)
        self.assertEqual(sorted(self.host.images), sorted([self.P, self.C]))
        self.assertIn(['podman', 'image', 'rm', 'registry.example/artik:2', 'registry.example/artik:latest'], self.host.calls,
                      'a tagged image goes by its tags')
        self.assertIn(['podman', 'image', 'rm', self.N], self.host.calls, 'an untagged one by its ID')
        self.assertEqual((self.host.networks >= {'ozel', 'ksl-notlar'}, 'bos-ag' in self.host.networks), (True, False))
        self.assertEqual(sorted(self.host.volumes), ['eski-veri'])
        self.assertEqual(sorted(p.name for p in self.veri.iterdir()), ['baglanmis', 'notlar'])
        self.assertFalse([c for c in self.host.calls if '--force' in c or '-f' in c], 'never forced')
        record = self.operation()
        self.assertEqual((record['state'], record['action'], record['name']), ('failed', 'temizlik', 'Podman'))
        self.assertNotIn('imajlar', json.dumps(record), 'the record never holds the request')
        self.assertEqual(self.record()['name'], 'notlar', 'the application is untouched')

    def test_a_cleanup_of_unused_items_succeeds_and_a_gone_or_held_item_is_named(self):
        result = self.execute('temizlik', {'birimler': ['yetim'], 'aglar': ['bos-ag']})
        self.assertEqual(result, {'ok': True, 'kaldirilan': [{'tur': 'ag', 'ad': 'bos-ag'}, {'tur': 'birim', 'ad': 'yetim'}]})
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('temizlik', {'birimler': ['yetim']})
        self.assertIn('yetim: Birim artık yok.', str(err.exception))
        self.host.children.add(self.U)
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('temizlik', {'imajlar': [self.U]})
        self.assertIn('başka bir imaj ona dayanıyor', str(err.exception))
        for bad in ({'aglar': ['podman']}, {'imajlar': ['registry.example/artik:2']}, {}, {'birimler': ['yetim'], 'x': []}):
            with self.subTest(bad=bad), self.assertRaises(cfg.ContainerConfigError) as err:
                self.execute('temizlik', bad)
            self.assertEqual(err.exception.status, 400)

    def test_a_folder_an_application_takes_meanwhile_stays(self):
        app_fixtures.record(self.env, text=app_fixtures.SIMPLE, given=app_fixtures.SIMPLE_ANSWERS, app='sayac',
                            ports={'app:9000/tcp': 62105})
        (self.veri / 'sayac').mkdir()
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('temizlik', {'klasorler': ['sayac', 'eskiuygulama']})
        self.assertIn('sayac: Bu klasörün uygulaması var', str(err.exception))
        self.assertEqual(sorted(p.name for p in self.veri.iterdir()), ['baglanmis', 'notlar', 'sayac'])


# Rebuild phase 4: a database with a raw port and a web service that depends on it, with an address and a UDP port.
ROWS_TEXT = """name: satir
services:
  db:
    image: registry.example/satir/db:1
    ports:
      - "5432"
  web:
    image: registry.example/satir/web:2
    depends_on: [db]
    ports:
      - "8080"
      - "5353/udp"
"""
ROWS_ANSWERS = {'name': 'satir', 'answers': {'port:db:5432/tcp': {'use': 'raw'},
                                             'port:web:8080/tcp': {'use': 'caddy', 'tailscale_name': 'satir'},
                                             'port:web:5353/udp': {'use': 'raw'},
                                             'start:db': {'mode': 'root'}, 'start:web': {'mode': 'root'}}}
DB, WEB = 'konsol-satir_db.service', 'konsol-satir_web.service'
ADDRESS = {'tur': 'adres', 'ad': 'satir', 'tailscale_portu': None, 'internet': ''}


class RowsCase(WorkerCase):
    def setUp(self):
        super().setUp()
        self.install(ROWS_TEXT, ROWS_ANSWERS, 'satir')
        self.host.calls.clear()

    @contextlib.contextmanager
    def settings_caller(self, pending=True, lock=True):
        """What the settings worker holds around a row change: install.lock in this process and a pending change."""
        path = self.root / 'ayarlar-bekleyen.json'
        if pending:
            path.write_text('{"phase": "applying"}')
        self.env['SETTINGS_PENDING_FILE'] = str(path)
        self.state = app_fixtures.write_state(self.root, self.env)
        self.manager = self.make_manager()
        with open(Path(self.env['RUNTIME_DIR']) / 'install.lock', 'a') as held:
            if lock:
                fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                if path.exists():
                    path.unlink()

    def change(self, app, key, row):
        with self.settings_caller():
            return self.manager.row_change(app, key, row)

    def unit(self, service, app='satir'):
        return (Path(self.env['KONTEYNER_BIRIM_DIR']) / ('konsol-%s_%s.container' % (app, service))).read_text()

    def published_lines(self, service, app='satir'):
        return [line for line in self.unit(service, app).splitlines() if line.startswith('PublishPort=')]

    def order(self):
        return [' '.join(c[:2]) + ((' ' + c[-1]) if c[0] == 'systemctl' and c[1] in ('start', 'stop') else '')
                for c in self.host.calls if c[0] in ('guard', 'publish') or c[:2] in (['systemctl', 'start'], ['systemctl', 'stop'],
                                                                                     ['systemctl', 'daemon-reload'])]


class RowChangeTests(RowsCase):
    def test_the_rows_were_seeded_at_install_and_published(self):
        record = self.record('satir')
        self.assertEqual(record['rows'], {'db:5432/tcp': {'tur': 'ham', 'kapsam': 'kapali', 'port': 5432},
                                          'web:8080/tcp': ADDRESS, 'web:5353/udp': {'tur': 'ham', 'kapsam': 'kapali', 'port': 5353}})
        self.assertEqual(record['places']['ports'], {'web:8080/tcp': 62100})
        self.assertEqual(self.published_lines('db'), [], 'a closed raw port publishes nothing')
        self.assertEqual(self.publisher.seen[-1], ['uygulama:satir:db:5432/tcp', 'uygulama:satir:web:5353/udp',
                                                   'uygulama:satir:web:8080/tcp'])

    def test_only_the_settings_transaction_changes_a_row(self):
        row = {'tur': 'ham', 'kapsam': 'tailscale', 'port': 15432}
        for pending, lock, text in ((False, False, 'kurulum kilidini'), (True, False, 'kurulum kilidini'),
                                    (False, True, 'bekleyen bir ayar')):
            with self.subTest(pending=pending, lock=lock), self.settings_caller(pending, lock), \
                    self.assertRaises(cfg.ContainerConfigError) as err:
                self.manager.row_change('satir', 'db:5432/tcp', row)
            self.assertEqual(err.exception.status, 503)
            self.assertIn(text, str(err.exception))
        self.assertEqual(self.host.calls, [])
        self.assertEqual(self.record('satir')['rows']['db:5432/tcp']['kapsam'], 'kapali')

    def test_opening_a_raw_port_publishes_it_and_restarts_its_service_with_the_ones_that_need_it(self):
        revision = self.record('satir')['places']['revision']
        result = self.change('satir', 'db:5432/tcp', {'tur': 'ham', 'kapsam': 'tailscale', 'port': 15432})
        self.assertEqual(result, {'uygulama': 'satir', 'anahtar': 'db:5432/tcp', 'birimler': ['konsol-satir_db.container'],
                                  'yeniden_baslatilan': [DB, WEB]})
        self.assertEqual(self.published_lines('db'), ['PublishPort=100.64.0.2:15432:5432/tcp'])
        record = self.record('satir')
        self.assertEqual(record['rows']['db:5432/tcp'], {'tur': 'ham', 'kapsam': 'tailscale', 'port': 15432})
        self.assertEqual(record['places']['ports'], {'web:8080/tcp': 62100})
        self.assertNotEqual(record['places']['revision'], revision)
        # The guard first (the units' start check reads it), then web and db down, the unit, db and web up.
        self.assertEqual(self.order(), ['guard apply', 'systemctl stop ' + WEB, 'systemctl stop ' + DB, 'systemctl daemon-reload',
                                        'systemctl start ' + DB, 'systemctl start ' + WEB])
        raw = [p for p in self.guard.inputs[-1][0]['publications'] if p['scope'] != 'local']
        self.assertEqual(raw, [{'service': 'db', 'port': 5432, 'protocol': 'tcp', 'scope': 'tailscale', 'host_ip': '100.64.0.2',
                                'host_port': 15432}])
        self.assertEqual((self.host.units[DB], self.host.units[WEB]), ('active', 'active'))
        # Closing it again restarts the same two; the projection is the settings worker's own step.
        result = self.change('satir', 'db:5432/tcp', {'tur': 'ham', 'kapsam': 'kapali', 'port': 15432})
        self.assertEqual(result['yeniden_baslatilan'], [DB, WEB])
        self.assertEqual(self.published_lines('db'), [])
        self.assertNotIn(['publish'], self.host.calls)

    def test_an_address_and_a_raw_port_trade_the_pool_port_and_restart_only_their_service(self):
        result = self.change('satir', 'web:8080/tcp', {'tur': 'ham', 'kapsam': 'internet', 'port': 18080})
        self.assertEqual((result['birimler'], result['yeniden_baslatilan']), (['konsol-satir_web.container'], [WEB]))
        self.assertEqual(self.record('satir')['places']['ports'], {}, 'the pool port is released')
        self.assertEqual(self.published_lines('web'), ['PublishPort=203.0.113.10:18080:8080/tcp'])
        result = self.change('satir', 'web:8080/tcp', dict(ADDRESS, ad='geri'))
        self.assertEqual(result['yeniden_baslatilan'], [WEB], 'web depends on db, not the other way round')
        self.assertEqual(self.record('satir')['places']['ports'], {'web:8080/tcp': 62100})
        self.assertEqual(self.published_lines('web'), ['PublishPort=127.0.0.1:62100:8080/tcp'])
        # A UDP port is raw only; its own scope change works like any raw port.
        result = self.change('satir', 'web:5353/udp', {'tur': 'ham', 'kapsam': 'internet', 'port': 5353})
        self.assertEqual(self.published_lines('web'), ['PublishPort=127.0.0.1:62100:8080/tcp', 'PublishPort=203.0.113.10:5353:5353/udp'])

    def test_a_name_a_tailscale_port_or_an_internet_name_restarts_nothing(self):
        before = self.unit_files(), self.unit('web'), self.unit('db')
        row = dict(ADDRESS, ad='yeni-ad', tailscale_portu=8443, internet='satir.example.org')
        result = self.change('satir', 'web:8080/tcp', row)
        self.assertEqual((result['birimler'], result['yeniden_baslatilan']), ([], []))
        self.assertEqual((self.unit_files(), self.unit('web'), self.unit('db')), before)
        self.assertEqual(self.record('satir')['rows']['web:8080/tcp'], row)
        self.assertFalse([c for c in self.host.calls if c[0] == 'systemctl' and c[1] in ('start', 'stop', 'daemon-reload')])
        # The same row again writes nothing at all.
        self.host.calls.clear()
        records = apps.Records(self.env)
        snapshot = records.snapshot('satir')
        self.assertEqual(self.change('satir', 'web:8080/tcp', row)['birimler'], [])
        self.assertEqual((records.snapshot('satir'), self.host.calls), (snapshot, []))

    def test_a_row_that_cannot_be_stored_or_clashes_changes_nothing(self):
        self.install(app_fixtures.SIMPLE, app_fixtures.SIMPLE_ANSWERS, 'sayac')
        self.change('sayac', 'app:9000/tcp', dict(ADDRESS, ad='sayac', tailscale_portu=19000))
        records = apps.Records(self.env)
        snapshot = records.snapshot('satir')
        self.host.calls.clear()
        cases = [('yok:1/tcp', ADDRESS, 404), ('web:5353/udp', dict(ADDRESS, ad='dns'), 400),
                 ('web:8080/tcp', dict(ADDRESS, ad='Kotu'), 400), ('web:8080/tcp', dict(ADDRESS, ad='panel'), 400),
                 ('db:5432/tcp', {'tur': 'ham', 'kapsam': 'lan', 'port': 5432}, 400),
                 ('db:5432/tcp', {'tur': 'ham', 'kapsam': 'tailscale'}, 400),
                 ('web:8080/tcp', dict(ADDRESS, ad='sayac'), 409),
                 ('web:8080/tcp', dict(ADDRESS, tailscale_portu=19000), 409),
                 ('db:5432/tcp', {'tur': 'ham', 'kapsam': 'tailscale', 'port': 19000}, 409)]
        for key, row, status in cases:
            with self.subTest(key=key, row=row), self.assertRaises(cfg.ContainerConfigError) as err:
                self.change('satir', key, row)
            self.assertEqual(err.exception.status, status)
        self.assertEqual(records.snapshot('satir'), snapshot)
        self.assertEqual(self.host.calls, [])
        # The same number on the internet is another listener.
        self.assertEqual(self.change('satir', 'db:5432/tcp', {'tur': 'ham', 'kapsam': 'internet', 'port': 19000})['anahtar'],
                         'db:5432/tcp')

    def test_a_stopped_application_gets_its_units_and_no_start(self):
        self.execute('uygulama-durdur', {'name': 'satir', 'revizyon': self.record('satir')['places']['revision']})
        self.host.calls.clear()
        result = self.change('satir', 'db:5432/tcp', {'tur': 'ham', 'kapsam': 'internet', 'port': 15432})
        self.assertEqual((result['birimler'], result['yeniden_baslatilan']), (['konsol-satir_db.container'], []))
        self.assertEqual(self.published_lines('db'), ['PublishPort=203.0.113.10:15432:5432/tcp'])
        self.assertNotIn('[Install]', self.unit('db'))
        self.assertFalse([c for c in self.host.calls if c[:2] == ['systemctl', 'start']])

    def test_a_pod_publishes_on_its_pod_and_restarts_whole(self):
        self.install(POD, auto_answers(POD, 'ikili'), 'ikili')
        self.host.calls.clear()
        result = self.change('ikili', 'web:8080/tcp', {'tur': 'ham', 'kapsam': 'tailscale', 'port': 18080})
        self.assertEqual(result['birimler'], ['konsol-ikili.pod'])
        self.assertEqual(result['yeniden_baslatilan'], ['konsol-ikili-pod.service', 'konsol-ikili_web.service',
                                                        'konsol-ikili_cache.service'])
        pod = (Path(self.env['KONTEYNER_BIRIM_DIR']) / 'konsol-ikili.pod').read_text()
        self.assertIn('PublishPort=100.64.0.2:18080:8080/tcp', pod)
        self.assertNotIn('PublishPort', self.unit('web', 'ikili'))

    def test_the_caller_puts_the_files_back_and_the_restore_runs_the_old_units_again(self):
        files = self.manager.row_files('satir')
        folder, units = apps.Records(self.env).dir('satir'), Path(self.env['KONTEYNER_BIRIM_DIR'])
        self.assertEqual(files, [str(folder / 'erisim.json'), str(folder / 'yerler.json'), str(units / 'konsol-satir.network'),
                                 str(units / 'konsol-satir_db.container'), str(units / 'konsol-satir_web.container')])
        snapshot = {path: Path(path).read_bytes() for path in files}
        self.host.fails('systemctl start ' + WEB)
        with self.assertRaises(cfg.ContainerConfigError):
            self.change('satir', 'web:8080/tcp', {'tur': 'ham', 'kapsam': 'internet', 'port': 18080})
        self.assertEqual(self.record('satir')['places']['ports'], {}, 'the failed change is left for the caller to take back')
        for path, data in snapshot.items():
            Path(path).write_bytes(data)
        self.host.calls.clear()
        with self.settings_caller():
            restarted = self.manager.row_restore('satir')
        self.assertEqual(restarted, [DB, WEB], 'not known: every service')
        self.assertEqual({path: Path(path).read_bytes() for path in files}, snapshot)
        self.assertEqual(self.order(), ['guard apply', 'systemctl stop ' + WEB, 'systemctl stop ' + DB, 'systemctl daemon-reload',
                                        'systemctl start ' + DB, 'systemctl start ' + WEB])
        self.assertEqual([p['scope'] for p in self.guard.inputs[-1][0]['publications']], ['local'])
        self.assertEqual(self.host.units[WEB], 'active')
        # After a change that worked and was rolled back, only what it restarted.
        result = self.change('satir', 'web:8080/tcp', {'tur': 'ham', 'kapsam': 'internet', 'port': 18080})
        for path, data in snapshot.items():
            Path(path).write_bytes(data)
        self.host.calls.clear()
        with self.settings_caller():
            self.assertEqual(self.manager.row_restore('satir', result['yeniden_baslatilan']), [WEB])
        self.assertEqual(self.published_lines('web'), ['PublishPort=127.0.0.1:62100:8080/tcp'])
        with self.assertRaises(cfg.ContainerConfigError):
            self.manager.row_restore('satir')


class AddressRefreshTests(RowsCase):
    def setUp(self):
        super().setUp()
        self.change('satir', 'db:5432/tcp', {'tur': 'ham', 'kapsam': 'tailscale', 'port': 15432})
        self.env.pop('SETTINGS_PENDING_FILE')
        self.host.calls.clear()

    def moved(self, **values):
        self.env.update(values)
        self.state = app_fixtures.write_state(self.root, self.env)
        self.manager = self.make_manager()

    def test_a_new_tailscale_address_moves_the_unit_and_restarts_its_services_once(self):
        self.moved(TAILSCALE_IPV4='100.64.0.3')
        self.assertEqual(self.manager.address_refresh(), {'yenilenen': ['satir'], 'hatalar': []})
        self.assertEqual(self.published_lines('db'), ['PublishPort=100.64.0.3:15432:5432/tcp'])
        self.assertEqual(self.order(), ['guard apply', 'systemctl stop ' + WEB, 'systemctl stop ' + DB, 'systemctl daemon-reload',
                                        'systemctl start ' + DB, 'systemctl start ' + WEB])
        self.assertEqual(self.guard.inputs[-1][0]['publications'][-1]['host_ip'], '100.64.0.3')
        self.host.calls.clear()
        self.assertEqual(self.manager.address_refresh(), {'yenilenen': [], 'hatalar': []}, 'idempotent')
        self.assertEqual(self.order(), [])

    def test_only_open_raw_rows_on_another_address_are_moved(self):
        self.install(app_fixtures.SIMPLE, app_fixtures.SIMPLE_ANSWERS, 'sayac')
        self.host.calls.clear()
        self.moved(WAN_IPV4='198.51.100.20')
        self.assertEqual(self.manager.address_refresh(), {'yenilenen': [], 'hatalar': []}, 'a Tailscale row did not move')
        self.assertEqual(self.order(), [])
        with self.settings_caller():
            self.manager.row_change('sayac', 'app:9000/tcp', {'tur': 'ham', 'kapsam': 'internet', 'port': 19000})
        self.env.pop('SETTINGS_PENDING_FILE')
        self.moved(WAN_IPV4='198.51.100.21')
        self.host.fails('systemctl start ' + DB)
        self.moved(TAILSCALE_IPV4='100.64.0.4')
        result = self.manager.address_refresh()
        self.assertEqual(result['yenilenen'], ['sayac'], 'one failure does not stop the others')
        self.assertEqual([e['uygulama'] for e in result['hatalar']], ['satir'])
        self.assertEqual(self.published_lines('app', 'sayac'), ['PublishPort=198.51.100.21:19000:9000/tcp'])

    def test_busy_or_a_pending_change_is_left_for_the_next_run(self):
        out = io.StringIO()
        with open(Path(self.env['RUNTIME_DIR']) / 'install.lock', 'a') as held, patch.object(worker, 'LOCK_WAIT', 0.1), \
                contextlib.redirect_stdout(out):
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            self.assertEqual(worker.main(['--state', str(self.state), '--adres-yenile']), 0)
        self.assertIn('Sonraki çalışmada yeniden denenecek', out.getvalue())
        pending = self.root / 'ayarlar-bekleyen.json'
        pending.write_text('{}')
        self.moved(SETTINGS_PENDING_FILE=str(pending), TAILSCALE_IPV4='100.64.0.3')
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(worker.main(['--state', str(self.state), '--adres-yenile']), 0)
        self.assertIn('Onay bekleyen', out.getvalue())
        self.assertEqual(self.published_lines('db'), ['PublishPort=100.64.0.2:15432:5432/tcp'], 'nothing changed')

    def test_the_entry_reports_what_it_did_and_takes_no_other_flag(self):
        for result, code, text in (({'yenilenen': ['satir'], 'hatalar': []}, 0, 'satir birimleri şimdiki adresle'),
                                   ({'yenilenen': [], 'hatalar': []}, 0, 'değişiklik yok'),
                                   ({'yenilenen': [], 'hatalar': [{'uygulama': 'satir', 'hata': 'olmadı'}]}, 1, 'HATA satir: olmadı')):
            out, err = io.StringIO(), io.StringIO()
            with self.subTest(result=result), patch.object(worker.Manager, 'address_refresh', return_value=result), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(worker.main(['--state', str(self.state), '--adres-yenile']), code)
                self.assertIn(text, out.getvalue() + err.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            for argv in (['--state', str(self.state)], ['--state', str(self.state), '--adres-yenile', 'fazla'], []):
                with self.subTest(argv=argv), self.assertRaises(SystemExit) as stop:
                    worker.main(argv)
                self.assertEqual(stop.exception.code, 2)


class RowLifecycleTests(WorkerCase):
    def test_a_taken_tailscale_name_stops_an_install_before_any_write(self):
        self.install()
        self.host.calls.clear()
        text = app_fixtures.TEXT.replace('name: notlar', 'name: ikinci')
        given = {'name': 'ikinci', 'answers': dict(app_fixtures.answers()['answers'])}
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install(text, given, 'ikinci')
        self.assertEqual(err.exception.status, 409)
        self.assertIn('notlar.ev adı zaten kullanılıyor', str(err.exception))
        self.assertFalse(os.path.lexists(Path(self.env['UYGULAMA_STATE_DIR']) / 'ikinci'))
        self.assertFalse([c for c in self.host.calls if c[:2] == ['podman', 'pull']])

    def test_an_install_publishes_its_rows_after_it_runs_and_a_failed_projection_takes_everything_back(self):
        self.install()
        calls = [' '.join(c) for c in self.host.calls]
        self.assertGreater(calls.index('publish'), max(i for i, c in enumerate(calls) if c.startswith('systemctl start')))
        self.assertEqual(self.publisher.seen, [['uygulama:notlar:web:8080/tcp']])
        self.setUp()
        self.publisher.fail = 1
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.install()
        self.assertIn('Adresler yayımlanıyor', str(err.exception))
        self.assertIn('Yapılan her şey geri alındı', str(err.exception))
        self.assert_nothing_left()

    def test_an_edit_keeps_seeds_and_drops_rows_and_refuses_a_port_answer_that_is_not_its_row(self):
        self.install(ROWS_TEXT, ROWS_ANSWERS, 'satir')
        revision = lambda: self.record('satir')['places']['revision']  # noqa: E731
        given = {'name': 'satir', 'answers': {'start:db': {'mode': 'root'}, 'start:web': {'mode': 'root'},
                                              'port:web:8080/tcp': {'use': 'raw'}}}
        snapshot = apps.Records(self.env).snapshot('satir')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-tanim', {'name': 'satir', 'metin': ROWS_TEXT, 'yanitlar': given, 'revizyon': revision()})
        self.assertEqual(err.exception.status, 400)
        self.assertIn("Bu portun kullanımı Erişim'den değişir", str(err.exception))
        self.assertEqual(apps.Records(self.env).snapshot('satir'), snapshot)
        # The ports that stay need no answer; 9090 is new (an address), 5353/udp went.
        text = ROWS_TEXT.replace('      - "5353/udp"\n', '      - "9090"\n')
        given['answers'] = {'start:db': {'mode': 'root'}, 'start:web': {'mode': 'root'},
                            'port:web:9090/tcp': {'use': 'caddy', 'tailscale_name': 'satir-9090'}}
        self.publisher.seen.clear()
        self.execute('uygulama-tanim', {'name': 'satir', 'metin': text, 'yanitlar': given, 'revizyon': revision()})
        record = self.record('satir')
        self.assertEqual(record['rows'], {'db:5432/tcp': {'tur': 'ham', 'kapsam': 'kapali', 'port': 5432}, 'web:8080/tcp': ADDRESS,
                                          'web:9090/tcp': dict(ADDRESS, ad='satir-9090')})
        self.assertEqual(record['places']['ports'], {'web:8080/tcp': 62100, 'web:9090/tcp': 62101})
        self.assertEqual(sorted(record['answers']['answers']), ['start:db', 'start:web'])
        self.assertEqual(self.publisher.seen, [['uygulama:satir:db:5432/tcp', 'uygulama:satir:web:8080/tcp',
                                                'uygulama:satir:web:9090/tcp']])
        # A new port's name is checked like an install's.
        self.install()
        given['answers']['port:web:7070/tcp'] = {'use': 'caddy', 'tailscale_name': 'notlar'}
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-tanim', {'name': 'satir', 'metin': text.replace('      - "9090"\n', '      - "9090"\n      - "7070"\n'),
                                            'yanitlar': given, 'revizyon': revision()})
        self.assertIn('notlar.ev adı zaten kullanılıyor', str(err.exception))

    def test_a_failed_projection_takes_an_edit_back(self):
        self.install()
        before = apps.Records(self.env).snapshot('notlar')
        self.publisher.fail = 1
        text = app_fixtures.TEXT.replace('LOG_LEVEL: info', 'LOG_LEVEL: debug')
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-tanim', {'name': 'notlar', 'metin': text, 'yanitlar': app_fixtures.answers(),
                                            'revizyon': self.record()['places']['revision']})
        self.assertIn('Önceki durum geri yüklendi', str(err.exception))
        self.assertEqual(apps.Records(self.env).snapshot('notlar'), before)

    def test_a_removal_takes_its_rows_and_says_when_the_projection_failed(self):
        self.install()
        self.install(app_fixtures.SIMPLE, app_fixtures.SIMPLE_ANSWERS, 'sayac')
        self.publisher.seen.clear()
        self.execute('uygulama-kaldir', {'name': 'notlar', 'revizyon': self.record()['places']['revision'], 'veri': 'sakla'})
        self.assertEqual(self.publisher.seen, [['uygulama:sayac:app:9000/tcp']])
        self.publisher.fail = 1
        data = Path(self.env['UYGULAMA_VERI_DIR']) / 'sayac'
        with self.assertRaises(cfg.ContainerConfigError) as err:
            self.execute('uygulama-kaldir', {'name': 'sayac', 'revizyon': self.record('sayac')['places']['revision'],
                                             'veri': 'sil', 'onay': 'sayac'})
        self.assertIn('Uygulama kaldırıldı ama adresleri yayından kaldırılamadı', str(err.exception))
        self.assertFalse(data.exists(), 'the data went as asked')
        self.assert_nothing_left('sayac')


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
