#!/usr/bin/env python3
"""Explicit rootful container operations, run outside the panel sandbox.

The broker (master_container_manager) runs every job as its own transient unit and hands it here with
the request on standard input only. This module owns every container write: Gelişmiş's Podman resources
(until phase 5) and the application lifecycle (rebuild DD-271, phase 3). Each action is a job with steps
and a durable record (KONTEYNER_STATE_DIR/operations/<id>.json) that never holds the request; a failure
undoes what the job did, in reverse, and names the failed step. Secret values reach Podman on standard
input only: never an argument, a file of Obhut's, a record, a log line or a reply.
"""
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import tempfile
import time
import uuid

import master_applications as apps
import master_container_binds as binds
import master_container_config as cfg
import master_settings as settings

RESOURCE_ACTIONS = ('image-pull', 'image-remove', 'volume-create', 'volume-remove', 'network-create', 'network-remove')
APP_ACTIONS = ('uygulama-kur', 'uygulama-baslat', 'uygulama-durdur', 'uygulama-yeniden-baslat', 'uygulama-guncelle',
               'uygulama-tanim', 'uygulama-kaldir', 'uygulama-taslak')
ACTIONS = RESOURCE_ACTIONS + APP_ACTIONS
# DD-266: the share guard (every 30 s) and the settings worker hold install.lock for a moment;
# a container job waits for them (5 s) instead of failing at once.
LOCK_WAIT = 5.0
# Every unit active, every container running and healthy: within this many seconds of the last start.
READY_SECONDS = 300
PULL_SECONDS = 600
COPY_SECONDS = 1200
QUADLET = ('/usr/lib/systemd/system-generators/podman-system-generator', '/usr/libexec/podman/quadlet')


def run(argv, timeout=60, input=None, **kwargs):
    if input is None:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, **kwargs)
    return subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout, **kwargs)


class Undo:
    """What an application job did so far, for its rollback."""

    def __init__(self):
        self.record = False
        self.folders = []
        self.secrets = []
        self.units = None
        self.started = []
        self.objects = False
        self.reload = False
        self.guard = False


class Manager:
    def __init__(self, state, run=run, network=None, quadlet=None, generator=None, inspector=None,
                 clock=time.monotonic, sleep=time.sleep, now=time.time):
        self.state = str(state)
        self.env = settings.env_read(state)
        self.env['STATE_FILE'] = self.state
        self.run = run
        self.network = network
        self.quadlet = quadlet
        self.generator = generator
        self.inspector = inspector
        self.clock, self.sleep, self.now = clock, sleep, now
        self.operation = None
        self.op_path = None

    @property
    def records(self):
        return apps.Records(self.env)

    # -- tools
    def call(self, argv, timeout=60, check=True, **kwargs):
        try:
            p = self.run(list(argv), timeout=timeout, **kwargs)
        except (OSError, subprocess.TimeoutExpired) as err:
            raise cfg.ContainerConfigError(502, 'Konteyner işlemi zamanında tamamlanamadı veya araç çalıştırılamadı.') from err
        if isinstance(p, tuple):
            p = subprocess.CompletedProcess(argv, p[0], p[1], p[2])
        if isinstance(p.stdout, bytes):
            p.stdout = p.stdout.decode('utf-8', 'replace')
        if isinstance(p.stderr, bytes):
            p.stderr = p.stderr.decode('utf-8', 'replace')
        # Never echo argv/stdout/stderr: a container's error may contain credentials.
        cfg.require(not check or p.returncode == 0, 'Konteyner aracı işlemi reddetti (%s).' % ' '.join(argv[:2]), 502)
        return p

    def json_call(self, argv, **kwargs):
        p = self.call(argv, **kwargs)
        try:
            return json.loads(p.stdout or 'null')
        except (ValueError, TypeError) as err:
            raise cfg.ContainerConfigError(502, 'Konteyner aracı geçerli yanıt vermedi.') from err

    @contextlib.contextmanager
    def locked(self):
        paths = [Path(self.env['RUNTIME_DIR']) / 'install.lock', Path(self.env['KONTEYNER_LOCK'])]
        with contextlib.ExitStack() as stack:
            for path in paths:
                with settings.parent_fd(path, create=True) as (directory, name):
                    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
                f = stack.enter_context(os.fdopen(fd, 'a'))
                info = os.fstat(f.fileno())
                cfg.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid(), 'İşlem kilidi güvenli değil.', 503)
                deadline = time.monotonic() + LOCK_WAIT
                while True:
                    try:
                        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError as err:
                        if time.monotonic() >= deadline:
                            raise cfg.ContainerConfigError(409, 'Kurulum veya başka bir konteyner işlemi sürüyor; biraz sonra yeniden deneyin.') from err
                        time.sleep(0.2)
            pending = self.env.get('SETTINGS_PENDING_FILE')
            cfg.require(not pending or not Path(pending).exists(), 'Onay bekleyen sistem ayarını önce tamamlayın.', 409)
            yield

    # -- the job record
    def step(self, label):
        if self.operation is not None:
            self.operation.update(step=label, updated_at=int(time.time()))
            settings.atomic(self.op_path, json.dumps(self.operation, ensure_ascii=False) + '\n', 0o600)

    def begin(self, action, request, operation):
        cfg.require(isinstance(operation, str) and cfg.REV_RE.fullmatch(operation), 'İşlem kimliği geçersiz.')
        root = Path(self.env.get('KONTEYNER_STATE_DIR', ''))
        cfg.require(root.is_absolute() and '..' not in root.parts, 'Konteyner kayıt yolu eksik; kurulumu yeniden çalıştırın.', 503)
        cfg.private_dir(root)
        cfg.private_dir(root / 'operations')
        self.op_path = root / 'operations' / (operation + '.json')
        # Reserve the id exclusively before any side effect; a replay never repeats an action.
        with settings.parent_fd(self.op_path) as (directory, name):
            try:
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            except FileExistsError as err:
                raise cfg.ContainerConfigError(409, 'Bu işlem kimliği zaten kullanıldı.') from err
            os.close(fd)
        raw = request.get('name') or request.get('image') or ''
        name = raw if isinstance(raw, str) and len(raw) <= 512 and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:/@-]*', raw) else ''
        # The record names the job; the request (and any secret in it) is never stored.
        self.operation = {'id': operation, 'action': action, 'name': name, 'state': 'running',
                          'step': 'Doğrulanıyor', 'created_at': int(time.time()), 'updated_at': int(time.time())}
        self.step('Doğrulanıyor')

    def execute(self, action, request, operation):
        cfg.require(action in ACTIONS and isinstance(request, dict), 'Konteyner işlemi geçersiz.')
        self.begin(action, request, operation)
        try:
            with self.locked():
                result = self.dispatch(action, request)
            self.operation.update(state='done', result=result, finished_at=int(time.time()))
            self.step('Tamamlandı')
            return result
        except Exception as err:
            if not isinstance(err, cfg.ContainerConfigError):
                err = cfg.ContainerConfigError(502, 'Konteyner işlemi tamamlanamadı; işlem kaydındaki durumu kontrol edin.')
            self.operation.update(state='failed', error=str(err), status=err.status, finished_at=int(time.time()),
                                  failed_step=getattr(err, 'failed_step', self.operation['step']))
            self.step('Başarısız')
            raise err

    def dispatch(self, action, request):
        if action in RESOURCE_ACTIONS:
            return self.resource(action, request)
        return {'uygulama-kur': self.app_install, 'uygulama-baslat': self.app_start, 'uygulama-durdur': self.app_stop,
                'uygulama-yeniden-baslat': self.app_restart, 'uygulama-guncelle': self.app_update,
                'uygulama-tanim': self.app_define, 'uygulama-kaldir': self.app_remove,
                'uygulama-taslak': self.app_draft}[action](request)

    def network_module(self):
        if self.network is None:
            try:
                import master_container_network
                self.network = master_container_network
            except ImportError as err:
                raise cfg.ContainerConfigError(503, 'Konteyner ağ ilkesi kurulu değil; kurulumu yeniden çalıştırın.') from err
        return self.network

    def net_call(self, method, *args):
        try:
            return getattr(self.network_module(), method)(self.env, *args, run=self.run)
        except cfg.ContainerConfigError:
            raise
        except Exception as err:
            # The helper's validation errors contain no submitted secrets.
            if hasattr(err, 'status'):
                raise cfg.ContainerConfigError(err.status, str(err)) from err
            raise cfg.ContainerConfigError(502, 'Konteyner ağ ilkesi uygulanamadı.') from err

    def inspect(self, name, kind='container'):
        p = self.call(['podman', kind, 'exists', name], check=False)
        if p.returncode == 1:
            return None
        cfg.require(p.returncode == 0, 'Konteyner envanteri okunamadı.', 502)
        value = self.json_call(['podman', 'inspect', '--type', kind, name])
        cfg.require(isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict), 'Konteyner bilgisi okunamadı.', 502)
        return value[0]

    def exists(self, kind, name):
        """podman <kind> exists: True, False, or a failure for anything else."""
        p = self.call(['podman', kind, 'exists', name], check=False)
        cfg.require(p.returncode in (0, 1), 'Podman envanteri okunamadı.', 502)
        return p.returncode == 0

    # -- Gelişmiş's resources (until phase 5)
    def image(self, reference):
        reference = cfg.image_of(reference)
        self.step('İmaj indiriliyor')
        self.call(['podman', 'pull', '--quiet', reference], timeout=PULL_SECONDS)
        info = self.json_call(['podman', 'image', 'inspect', reference])
        cfg.require(isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict), 'İmaj okunamadı.', 502)
        return apps.pinned(info[0], reference)

    def app_images(self):
        """Every image an application's record pins or names (an image a record uses is never removed)."""
        used = set()
        records = self.records
        for app in records.names():
            record = records.load(app)
            used |= set(record['places']['images'].values())
            used |= {apps.reference(s['image'])[1] for s in record['definition']['services']}
        return used

    def resource_users(self, kind, target):
        rows = self.json_call(['podman', 'ps', '-a', '--filter', ('ancestor' if kind == 'image' else kind) + '=' + target,
                               '--format', 'json'])
        cfg.require(isinstance(rows, list), 'Kaynak kullanımı okunamadı.', 502)
        return bool(rows)

    def managed_network(self, name):
        """A network Gelişmiş made: label konsol and the interface its name gives. An application's network goes
        with the application."""
        info = self.json_call(['podman', 'network', 'inspect', name])
        cfg.require(isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict), 'Ağ bilgisi okunamadı.', 502)
        labels = info[0].get('labels') or {}
        cfg.require(labels.get(cfg.MANAGED_LABEL) != apps.MANAGED, 'Bu ağ bir uygulamanın; uygulamayla birlikte kaldırılır.', 409)
        prefix = self.env.get('KONTEYNER_BRIDGE_PREFIX', '')
        interface = prefix + hashlib.sha256(name.encode()).hexdigest()[:10]
        cfg.require(info[0].get('driver') == 'bridge' and info[0].get('network_interface') == interface and
                    labels.get(cfg.MANAGED_LABEL) == 'konsol', 'Bu ağ Konsol tarafından yönetilmiyor.', 409)

    def create_network(self, request):
        name = cfg.name_of(request.get('name'))
        cfg.require(name not in ('bridge', 'host', 'none', 'podman') and not name.startswith('ksl-'), 'Bu ağ adı ayrılmıştır.')
        cfg.require(type(request.get('internal', False)) is bool, 'Ağ seçeneği geçersiz.')
        prefix = self.env.get('KONTEYNER_BRIDGE_PREFIX', 'ksl')
        cfg.require(prefix.isalnum() and 1 <= len(prefix) <= 5, 'Konteyner köprü öneki geçersiz.', 503)
        interface = prefix + hashlib.sha256(name.encode()).hexdigest()[:10]
        argv = ['podman', 'network', 'create', '--driver', 'bridge', '--interface-name', interface,
                '--label', cfg.MANAGED_LABEL + '=konsol']
        if request.get('internal'):
            argv.append('--internal')
        if request.get('subnet'):
            try:
                subnet = ipaddress.ip_network(request['subnet'], strict=True)
            except (ValueError, TypeError) as err:
                raise cfg.ContainerConfigError(400, 'Ağ alt adresi geçersiz.') from err
            private_ranges = [ipaddress.ip_network(s) for s in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
            cfg.require(subnet.version == 4 and subnet.prefixlen >= 16 and any(subnet.subnet_of(s) for s in private_ranges),
                        'Özel bir IPv4 alt ağı seçin (/16 veya daha dar).')
            self.validate_subnet(subnet)
            argv += ['--subnet', str(subnet)]
        self.call(argv + [name])
        return {'ok': True, 'name': name}

    def validate_subnet(self, subnet):
        """A custom bridge route must not steal traffic from a host, VPN or stopped network."""
        routes = self.json_call(['ip', '-j', '-4', 'route', 'show', 'table', 'all'])
        networks = self.json_call(['podman', 'network', 'ls', '--format', 'json'])
        cfg.require(isinstance(routes, list) and isinstance(networks, list), 'Mevcut ağ adresleri okunamadı.', 502)
        candidates = [r.get('dst') for r in routes if isinstance(r, dict) and r.get('dst') not in (None, 'default')]
        names = [n.get('name') or n.get('Name') for n in networks if isinstance(n, dict)]
        cfg.require(len(names) == len(networks) and all(isinstance(n, str) and cfg.NAME_RE.fullmatch(n) for n in names),
                    'Mevcut ağ adları okunamadı.', 502)
        if names:
            details = self.json_call(['podman', 'network', 'inspect', *names])
            cfg.require(isinstance(details, list) and len(details) == len(names), 'Mevcut ağlar okunamadı.', 502)
            for network in details:
                candidates.extend(s.get('subnet') for s in network.get('subnets', []))
        for value in candidates:
            try:
                current = ipaddress.ip_network(value, strict=False)
            except (ValueError, TypeError) as err:
                raise cfg.ContainerConfigError(502, 'Mevcut ağ adresi çözümlenemedi.') from err
            cfg.require(current.version != subnet.version or not subnet.overlaps(current),
                        'Alt ağ sunucu, VPN veya başka bir konteyner ağıyla çakışıyor.', 409)

    def resource(self, action, request):
        self.step('Kaynak işlemi uygulanıyor')
        if action == 'image-pull':
            return {'ok': True, 'image': self.image(request.get('image'))}
        if action == 'image-remove':
            target = request.get('image')
            cfg.require(isinstance(target, str) and (cfg.IMAGE_RE.fullmatch(target) or re.fullmatch(r'sha256:[0-9a-f]{64}', target)), 'İmaj kimliği geçersiz.')
            data = self.json_call(['podman', 'image', 'inspect', target])
            cfg.require(isinstance(data, list) and len(data) == 1, 'İmaj bulunamadı.', 404)
            info = data[0]
            aliases = {target, info.get('Id', ''), *(info.get('RepoDigests') or []), *(info.get('RepoTags') or [])}
            cfg.require(not aliases & self.app_images(), 'İmaj bir uygulamanın kaydında kullanılıyor.', 409)
            cfg.require(not self.resource_users('image', target), 'İmaj bir konteynerde kullanılıyor.', 409)
            self.call(['podman', 'image', 'rm', target])
            return {'ok': True, 'image': target, 'removed': True}
        name = cfg.name_of(request.get('name'))
        if action == 'volume-create':
            self.call(['podman', 'volume', 'create', '--label', cfg.MANAGED_LABEL + '=konsol', name])
        elif action in ('volume-remove', 'network-remove'):
            kind = action.split('-')[0]
            cfg.require(not self.resource_users(kind, name), 'Kaynak bir konteynerde kullanılıyor.', 409)
            if kind == 'network':
                self.managed_network(name)
            self.call(['podman', kind, 'rm', name])
        elif action == 'network-create':
            return self.create_network(request)
        else:
            raise cfg.ContainerConfigError(400, 'Kaynak işlemi geçersiz.')
        return {'ok': True, 'name': name, 'removed': action.endswith('-remove')}

    # -- applications: the parts every action shares
    def generator_module(self):
        if self.generator is None:
            import master_generator
            self.generator = master_generator
        return self.generator

    def inspector_module(self):
        if self.inspector is None:
            import master_inspector
            self.inspector = master_inspector
        return self.inspector

    def podman(self):
        p = self.call(['podman', 'version', '--format', '{{.Client.Version}}'])
        return apps.podman_version(p.stdout)

    def render(self, app, definition, places, version):
        return apps.render(self.env, app, definition, places, version, self.generator_module())

    def podman5(self, plan, version):
        """A Kubernetes Pod with several containers and a service_healthy dependency need Podman 5."""
        refusal = self.generator_module().podman5_refusal(plan, version)
        cfg.require(refusal is None, refusal or '', 409)

    def checked(self, text, answers, existing=frozenset()):
        """The server's own inspection and check of the file and the answers (never a browser's definition)."""
        apps.checked_text(text)
        inspector = self.inspector_module()
        inspection = inspector.inspect(text)
        refusals = inspection.get('refusals') or []
        if refusals or inspection.get('format') is None:
            first = refusals[0] if refusals else {'line': 1, 'text': 'Dosya okunamadı.'}
            raise cfg.ContainerConfigError(409, 'Dosyada kurulumu durduran satırlar var (satır %d: %s).' % (first['line'], first['text']))
        definition, values, errors = inspector.check(inspection, answers, existing_secrets=frozenset(existing))
        if errors:
            text = '; '.join('%s: %s' % (k, v) for k, v in sorted(errors.items())[:3])
            raise cfg.ContainerConfigError(400, ('Yanıtlar geçersiz: ' + text)[:600])
        return inspection, definition, values

    def app_record(self, request):
        app = apps.app_name(request.get('name'))
        cfg.require(self.records.exists(app), 'Uygulama bulunamadı.', 404)
        record = self.records.load(app)
        cfg.require(request.get('revizyon') == record['places']['revision'],
                    'Uygulama değişmiş; sayfayı yenileyip yeniden deneyin.', 409)
        return app, record

    def objects(self, app, definition):
        return apps.names(app, definition)

    def unit_dir(self):
        value = Path(self.env.get('KONTEYNER_BIRIM_DIR', ''))
        cfg.require(value.is_absolute() and '..' not in value.parts, 'Konteyner birim klasörü eksik; kurulumu yeniden çalıştırın.', 503)
        return value

    def unit_state(self, unit):
        p = self.call(['systemctl', 'show', '-p', 'ActiveState', '--value', unit], check=False)
        return (p.stdout or '').strip() if p.returncode == 0 else ''

    def restarts(self, unit):
        """How often systemd restarted the unit since it was last started by hand (Restart=)."""
        p = self.call(['systemctl', 'show', '-p', 'NRestarts', '--value', unit], check=False)
        value = (p.stdout or '').strip() if p.returncode == 0 else ''
        return int(value) if value.isdigit() else 0

    def srv_folder(self, path):
        """DD-226 at install time: a non-hidden folder below SERVER_ROOT, reached without a link."""
        try:
            source = binds.checked_source(self.env, path)
            fd = binds.walk(source)
        except binds.BindError as err:
            raise cfg.ContainerConfigError(409, str(err)) from err
        os.close(fd)
        return source

    def srv_paths(self, definition):
        for svc in definition['services']:
            for mount in svc.get('mounts', []):
                if mount.get('to') == 'srv':
                    self.srv_folder(mount['path'])

    def make_folders(self, app, folders):
        """The application's data folder (0700 root) and its sub-folders (made 0700 root; an existing one keeps
        the owner its container gave it); the ones this call made."""
        made = []
        if apps.make_dir(apps.data_dir(self.env, app)):
            made.append(apps.data_dir(self.env, app))
        for path in sorted(Path(f) for f in folders):
            if apps.make_dir(path, own=False):
                made.append(path)
        return made

    def write_units(self, plan):
        folder = self.unit_dir()
        for name, text in sorted(plan['units'].items()):
            settings.atomic(folder / name, text, 0o600)

    def unit_snapshot(self, names):
        folder, snap = self.unit_dir(), {}
        for name in sorted(names):
            cfg.require(name.startswith('konsol-') and '/' not in name, 'Birim adı geçersiz: %s' % name, 502)
            try:
                snap[name] = settings.read_regular(folder / name, 1024 * 1024)[0]
            except FileNotFoundError:
                snap[name] = None
        return snap

    def unit_restore(self, snap):
        folder = self.unit_dir()
        for name, data in snap.items():
            if data is None:
                cfg.unlink(folder / name)
            else:
                settings.atomic(folder / name, data, 0o600)

    def dryrun(self, plan):
        """Quadlet checks the candidate set in a private temporary folder before anything is replaced."""
        self.step('Birimler denetleniyor')
        quadlet = self.quadlet or next((p for p in QUADLET if os.path.isfile(p)), None)
        cfg.require(quadlet, 'Podman Quadlet üreticisi bulunamadı.', 503)
        with tempfile.TemporaryDirectory(prefix='uygulama-denetim-', dir=self.env['RUNTIME_DIR']) as temporary:
            for name, text in plan['units'].items():
                settings.atomic(Path(temporary) / name, text, 0o600)
            p = self.call([quadlet, '--dryrun'], env=dict(os.environ, QUADLET_UNIT_DIRS=temporary))
        missing = [u for u in plan['start'] if u not in p.stdout]
        cfg.require(not missing and '[Service]' in p.stdout, 'Quadlet üreticisi birimleri oluşturamadı: %s' % ', '.join(missing), 409)

    def start_units(self, plan, started):
        for unit in plan['start']:
            self.step('Başlatılıyor: %s' % unit)
            started.append(unit)
            self.call(['systemctl', 'start', unit], timeout=READY_SECONDS + 30)

    def stop_units(self, units, check=True):
        """Stops units in the given order; with check, a unit that is still active afterwards is a failure."""
        for unit in units:
            self.step('Durduruluyor: %s' % unit)
            self.call(['systemctl', 'stop', unit], timeout=180, check=False)
            if check:
                cfg.require(self.unit_state(unit) not in ('active', 'activating', 'deactivating'), '%s durmadı.' % unit, 502)

    @staticmethod
    def all_units(plan, objects):
        """The plan's stop order, then the pod's and the network's own units."""
        extra = ([objects['pod_unit']] if objects.get('pod') else []) + [objects['network_unit']]
        return list(plan['stop']) + [u for u in extra if u not in plan['stop']]

    def ready(self, app, definition, objects):
        """Each unit active, each container running and owned by this application, health neither starting
        nor unhealthy, and a direct start proved (DD-227): its user and no capabilities."""
        deadline = self.clock() + READY_SECONDS
        self.step('Hazır olması bekleniyor')
        while True:
            waiting = None
            for svc in definition['services']:
                name = svc['name']
                unit, container = objects['units'][name], objects['containers'][name]
                state = self.unit_state(unit)
                cfg.require(state != 'failed', '%s başlamadı: birimi başarısız oldu (günlüğü: journalctl -u %s).'
                            % (name, unit), 502)
                # A container that stops at once is restarted by systemd (Restart=); waiting the whole time would
                # only hide why. Its journal stays after the rollback removes the unit.
                cfg.require(self.restarts(unit) == 0, '%s başladıktan hemen sonra durdu (günlüğü: journalctl -u %s).'
                            % (name, unit), 502)
                try:
                    info = self.inspect(container) if state == 'active' else None
                except cfg.ContainerConfigError:
                    if self.exists('container', container):
                        raise
                    info = None  # it exited between the two calls (Quadlet's --rm); the next round sees the unit
                current = (info or {}).get('State') or {}
                health = (current.get('Health') or {}).get('Status')
                if state != 'active' or current.get('Running') is not True or health in ('starting', 'unhealthy'):
                    waiting = name
                    break
                labels = (info.get('Config') or {}).get('Labels') or {}
                cfg.require(cfg.ownership(info) == apps.MANAGED and labels.get(apps.APP_LABEL) == app,
                            'Başlayan konteynerin sahibi doğrulanamadı: %s' % name, 502)
                if svc['start'] == 'direct':
                    # Podman prints an empty capability set as null (5.4.2) or []; a missing field fails closed.
                    dropped = all(key in info and info[key] in (None, []) for key in ('EffectiveCaps', 'BoundingCaps'))
                    cfg.require((info.get('Config') or {}).get('User') == svc['user'] and dropped,
                                '%s kendi kullanıcısıyla, yetkisiz başlamadı.' % name, 502)
            if waiting is None:
                return
            if self.clock() >= deadline:
                raise cfg.ContainerConfigError(502, '%s %d saniyede başlamadı ya da sağlık denetimini geçmedi.' % (waiting, READY_SECONDS))
            self.sleep(2)

    def create_secret(self, app, value):
        """A Podman secret holding one value, named obhut_<app>_<8 random hex>; the value goes to Podman's
        standard input only."""
        gen = self.generator_module()
        name = gen.secret_name(app, secrets.token_hex(4))
        argv = ['podman', 'secret', 'create']
        for item in sorted(gen.labels(app).items()):
            argv += ['--label', '%s=%s' % item]
        self.call(argv + [name, '-'], input=value)
        return name

    def remove_secret(self, name):
        self.call(['podman', 'secret', 'rm', name], check=False)
        p = self.call(['podman', 'secret', 'inspect', name], check=False)
        cfg.require(p.returncode != 0, 'Podman secret kaldırılamadı: %s' % name, 502)

    def remove_objects(self, objects):
        """Containers (never their volumes), the pod and the network an application's units made."""
        for container in objects['containers'].values():
            if self.exists('container', container):
                self.call(['podman', 'rm', '--force', container], timeout=120)
        if objects.get('pod') and self.exists('pod', objects['pod']):
            self.call(['podman', 'pod', 'rm', '--force', objects['pod']], timeout=120)
        if self.exists('network', objects['network']):
            self.call(['podman', 'network', 'rm', objects['network']])

    def pull(self, definition, keep=None):
        """{service: repo@sha256} for the definition, one pull per distinct image; keep holds the services whose
        image did not change."""
        images, pulled = {}, {}
        for svc in definition['services']:
            if keep and svc['name'] in keep:
                images[svc['name']] = keep[svc['name']]
                continue
            reference = apps.reference(svc['image'])[1]
            if reference not in pulled:
                self.step('İmaj indiriliyor: %s' % reference)
                self.call(['podman', 'pull', '--quiet', reference], timeout=PULL_SECONDS)
                info = self.json_call(['podman', 'image', 'inspect', reference])
                cfg.require(isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict), 'İmaj okunamadı.', 502)
                pulled[reference] = apps.pinned(info[0], reference)
            images[svc['name']] = pulled[reference]
        return images

    def name_free(self, app, objects):
        """A new application's name: no record, no unit, no container, network or pod of that name."""
        cfg.require(not self.records.exists(app), 'Bu adla bir uygulama zaten var.', 409)
        folder = self.unit_dir()
        taken = sorted({p.name for pattern in ('konsol-%s.*' % app, 'konsol-%s_*' % app) for p in folder.glob(pattern)} |
                       {n for n in objects['files'] if os.path.lexists(folder / n)})
        cfg.require(not taken, 'Bu adın birim dosyaları zaten var: %s' % ', '.join(taken), 409)
        for container in objects['containers'].values():
            cfg.require(not self.exists('container', container), 'Bu adla bir konteyner zaten var: %s' % container, 409)
        cfg.require(not self.exists('network', objects['network']), 'Bu adla bir ağ zaten var: %s' % objects['network'], 409)
        cfg.require(not self.exists('pod', app), 'Bu adla bir pod zaten var: %s' % app, 409)

    # -- taking a standalone container over (source "konteyner")
    def takeover(self, name, app, inspection, answers):
        """The standalone container a draft came from and its named volumes that a to: app mount takes."""
        info = self.inspect(name)
        cfg.require(info is not None, 'Kaynak konteyner bulunamadı: %s' % name, 404)
        cfg.require(cfg.ownership(info) == 'standalone', 'Kaynak konteyner başka bir yöneticiye ait; devralınamaz.', 409)
        given = (answers or {}).get('answers') or {}
        wanted = {}
        for q in inspection.get('questions', []):
            if q.get('kind') == 'mount' and q.get('source_kind') == 'named' and given.get(q['id']) == {'to': 'app'}:
                wanted.setdefault(q['source'], q['folder'])
        copies = []
        mounted = {m.get('Name') for m in info.get('Mounts') or [] if isinstance(m, dict) and m.get('Type') == 'volume'}
        for volume, folder in sorted(wanted.items()):
            if volume not in mounted:
                continue
            data = self.json_call(['podman', 'volume', 'inspect', volume])
            cfg.require(isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict), 'Birim bilgisi okunamadı.', 502)
            point = data[0].get('Mountpoint')
            cfg.require(data[0].get('Driver') == 'local' and not data[0].get('Options') and isinstance(point, str)
                        and point.startswith('/') and '..' not in Path(point).parts,
                        'Birim %s yerel bir birim değil; kopyalanamaz.' % volume, 409)
            # Copied once, into a folder this job makes (so a failed takeover takes the copy back with it).
            target = apps.data_dir(self.env, app) / folder
            cfg.require(not os.path.lexists(target), 'Uygulamanın %s klasörü zaten var; birim kopyalanmadı.' % target, 409)
            copies.append((point, target))
        return {'name': name, 'running': (info.get('State') or {}).get('Running') is True, 'copies': copies}

    def copy_volumes(self, old):
        if old['running']:
            self.step('Eski konteyner durduruluyor')
            self.call(['podman', 'stop', '--time', '60', old['name']], timeout=120)
        for point, target in old['copies']:
            self.step('Birim kopyalanıyor: %s' % target.name)
            apps.make_dir(target)
            self.call(['cp', '-a', '--', point.rstrip('/') + '/.', str(target) + '/'], timeout=COPY_SECONDS)

    # -- uygulama-kur
    def app_install(self, request):
        text = apps.checked_text(request.get('metin'))
        answers = request.get('yanitlar')
        source = apps.request_source(request.get('kaynak'))
        self.step('Dosya denetleniyor')
        inspection, definition, values = self.checked(text, answers)
        app = apps.app_name(definition['name'])
        cfg.require(request.get('name') == app, 'Uygulama adı istekteki adla uyuşmuyor.')
        version = self.podman()
        objects = self.objects(app, definition)
        self.step('Ad, klasörler ve portlar denetleniyor')
        self.name_free(app, objects)
        self.srv_paths(definition)
        old = self.takeover(source['konteyner'], app, inspection, answers) if source['tur'] == 'konteyner' else None
        places = {'revision': uuid.uuid4().hex, 'stopped': False, 'ports': apps.allocate(self.env, app, definition, {}, self.records),
                  'secrets': {}, 'images': {}}
        # Everything the generator cannot express, and what needs Podman 5, stops here, before any write.
        draft = self.render(app, definition, dict(places, images=apps.placeholders(definition),
                                                  secrets=apps.placeholder_secrets(app, definition)), version)
        self.podman5(draft, version)
        undo, plan = Undo(), draft
        try:
            self.step('Kayıt yazılıyor')
            undo.record = True
            self.records.write(app, text=text, source=apps.source_record(source, text, self.now()),
                               answers=apps.stored_answers(inspection, answers), definition=definition, places=places)
            # The guard knows the new bridge before anything can start on it.
            self.step('Ağ koruması uygulanıyor')
            undo.guard = True
            self.net_call('apply')
            self.step('Klasörler oluşturuluyor')
            undo.folders = self.make_folders(app, draft['folders'])
            places['images'] = self.pull(definition)
            self.step('Gizli değerler oluşturuluyor')
            for item in definition['secrets']:
                places['secrets'][item['name']] = podman = self.create_secret(app, values[item['name']])
                undo.secrets.append(podman)
            self.records.write(app, places=places)
            plan = self.render(app, definition, places, version)
            self.records.write_env(app, plan['environment'])
            self.dryrun(plan)
            if old:
                self.copy_volumes(old)
            self.step('Birimler yazılıyor')
            undo.units = self.unit_snapshot(plan['units'])
            self.write_units(plan)
            undo.objects = True
            undo.reload = True
            self.call(['systemctl', 'daemon-reload'])
            self.start_units(plan, undo.started)
            self.ready(app, definition, objects)
            if old:
                self.step('Eski konteyner kaldırılıyor')
                # Never --volumes: the old named volumes stay until Gelişmiş's cleanup.
                self.call(['podman', 'rm', old['name']], timeout=120)
            return {'ok': True, 'ad': app, 'revizyon': places['revision']}
        except Exception as original:
            failed = self.operation['step'] if self.operation else 'Kurulum'
            self.step('Geri alınıyor')
            recovered = self.undo_install(app, plan, objects, undo, old)
            error = cfg.ContainerConfigError(
                original.status if isinstance(original, cfg.ContainerConfigError) else 502,
                ('Kurulum başarısız (%s): %s Yapılan her şey geri alındı.' if recovered else
                 'Kurulum başarısız (%s): %s Geri alma da tamamlanamadı; Gelişmiş → Podman ve İşlem geçmişine bakın.')
                % (failed, str(original) if isinstance(original, cfg.ContainerConfigError) else 'beklenmeyen hata.'))
            error.failed_step = failed
            raise error from original

    def undo_install(self, app, plan, objects, undo, old):
        ok = True

        def attempt(action):
            nonlocal ok
            try:
                action()
            except Exception:
                ok = False
        if undo.started or undo.objects:
            attempt(lambda: self.stop_units(list(reversed(undo.started)) + [u for u in self.all_units(plan, objects)
                                                                             if u not in undo.started], check=False))
        if undo.objects:
            attempt(lambda: self.remove_objects(objects))
        if undo.units is not None:
            attempt(lambda: self.unit_restore(undo.units))
        if undo.reload:
            attempt(lambda: self.call(['systemctl', 'daemon-reload']))
        for name in reversed(undo.secrets):
            attempt(lambda name=name: self.remove_secret(name))
        for path in reversed(undo.folders):
            attempt(lambda path=path: apps.remove_tree(path))
        if undo.record:
            attempt(lambda: self.records.remove(app))
        if undo.guard:
            attempt(lambda: self.net_call('apply'))
        if old and old['running']:
            attempt(lambda: self.call(['podman', 'start', old['name']], timeout=120))
        return ok

    # -- uygulama-baslat, -durdur, -yeniden-baslat
    def app_start(self, request):
        app, record = self.app_record(request)
        definition = record['definition']
        version = self.podman()
        objects = self.objects(app, definition)
        self.srv_paths(definition)
        places = dict(record['places'], stopped=False, revision=uuid.uuid4().hex)
        plan = self.render(app, definition, places, version)
        self.podman5(plan, version)
        before = self.records.snapshot(app)
        units = self.unit_snapshot(plan['units'])
        started = []
        try:
            self.step('Birimler yazılıyor')
            self.records.write(app, places=places)
            self.records.write_env(app, plan['environment'])
            self.write_units(plan)
            self.call(['systemctl', 'daemon-reload'])
            self.start_units(plan, started)
            self.ready(app, definition, objects)
            return {'ok': True, 'ad': app, 'revizyon': places['revision']}
        except Exception as original:
            def recover():
                self.stop_units(list(reversed(started)), check=False)
                self.records.restore(app, before)
                self.unit_restore(units)
                self.call(['systemctl', 'daemon-reload'])
            self.fail_back(original, recover, 'Başlatma başarısız')

    def app_stop(self, request):
        app, record = self.app_record(request)
        definition = record['definition']
        version = self.podman()
        places = dict(record['places'], stopped=True, revision=uuid.uuid4().hex)
        plan = self.render(app, definition, places, version)
        running = [u for u in plan['start'] if self.unit_state(u) == 'active']
        before = self.records.snapshot(app)
        units = self.unit_snapshot(plan['units'])
        try:
            self.stop_units(plan['stop'])
            self.step('Birimler yazılıyor')
            self.records.write(app, places=places)
            self.records.write_env(app, plan['environment'])
            self.write_units(plan)
            self.call(['systemctl', 'daemon-reload'])
            return {'ok': True, 'ad': app, 'revizyon': places['revision']}
        except Exception as original:
            def recover():
                self.records.restore(app, before)
                self.unit_restore(units)
                self.call(['systemctl', 'daemon-reload'])
                for unit in running:
                    self.call(['systemctl', 'start', unit], timeout=READY_SECONDS + 30)
            self.fail_back(original, recover, 'Durdurma başarısız')

    def app_restart(self, request):
        app, record = self.app_record(request)
        definition = record['definition']
        version = self.podman()
        objects = self.objects(app, definition)
        plan = self.render(app, definition, record['places'], version)
        cfg.require(all(self.unit_state(objects['units'][s['name']]) == 'active' for s in definition['services']),
                    'Yalnız çalışan bir uygulama yeniden başlatılır; durmuş bir uygulama için Başlat seçeneğini kullanın.', 409)
        self.srv_paths(definition)
        started = []
        try:
            self.stop_units(plan['stop'])
            self.start_units(plan, started)
            self.ready(app, definition, objects)
        except Exception as original:
            def recover():
                for unit in plan['start']:
                    self.call(['systemctl', 'start', unit], timeout=READY_SECONDS + 30)
            self.fail_back(original, recover, 'Yeniden başlatma başarısız')
        return {'ok': True, 'ad': app, 'revizyon': record['places']['revision']}

    def fail_back(self, original, recover, what):
        failed = self.operation['step'] if self.operation else what
        self.step('Önceki durum geri yükleniyor')
        try:
            recover()
            recovered = True
        except Exception:
            recovered = False
        status = original.status if isinstance(original, cfg.ContainerConfigError) else 502
        reason = str(original) if isinstance(original, cfg.ContainerConfigError) else 'beklenmeyen hata.'
        error = cfg.ContainerConfigError(status, ('%s (%s): %s Önceki durum geri yüklendi.' if recovered else
                                                  '%s (%s): %s Geri dönüş de tamamlanamadı; servis durumunu kontrol edin.')
                                         % (what, failed, reason))
        error.failed_step = failed
        raise error from original

    # -- uygulama-guncelle (DD-214: only on the operator's request)
    def app_update(self, request):
        app, record = self.app_record(request)
        definition, old = record['definition'], record['places']
        version = self.podman()
        objects = self.objects(app, definition)
        followed = [s for s in definition['services'] if apps.channel(s['image'])]
        cfg.require(bool(followed), 'Bu uygulamanın imajları sabit özetli; güncellenecek bir kanal yok.', 409)
        images = self.pull(definition, keep={s['name']: old['images'][s['name']] for s in definition['services']
                                             if not apps.channel(s['image'])})
        if images == old['images']:
            return {'ok': True, 'ad': app, 'revizyon': old['revision'], 'changed': False}
        places = dict(old, images=images, revision=uuid.uuid4().hex)
        plan = self.render(app, definition, places, version)
        self.dryrun(plan)
        if not old['stopped']:
            self.srv_paths(definition)
        before = self.records.snapshot(app)
        units = self.unit_snapshot(plan['units'])
        running = [u for u in plan['start'] if self.unit_state(u) == 'active']
        started = []
        try:
            if running:
                self.stop_units(plan['stop'])
            self.step('Birimler yazılıyor')
            self.records.write(app, places=places)
            self.records.write_env(app, plan['environment'])
            self.write_units(plan)
            self.call(['systemctl', 'daemon-reload'])
            if not old['stopped']:
                self.start_units(plan, started)
                self.ready(app, definition, objects)
            return {'ok': True, 'ad': app, 'revizyon': places['revision'], 'changed': True}
        except Exception as original:
            def recover():
                self.stop_units(list(reversed(started)), check=False)
                self.records.restore(app, before)
                self.unit_restore(units)
                self.call(['systemctl', 'daemon-reload'])
                for unit in running:
                    self.call(['systemctl', 'start', unit], timeout=READY_SECONDS + 30)
            self.fail_back(original, recover, 'Güncelleme başarısız')

    # -- uygulama-tanim: the plan (no write) and its application
    def app_define(self, request):
        app, record = self.app_record(request)
        old_definition, old = record['definition'], record['places']
        text = apps.checked_text(request.get('metin'))
        answers = request.get('yanitlar')
        self.step('Dosya denetleniyor')
        inspection, definition, values = self.checked(text, answers, existing=set(old['secrets']))
        cfg.require(definition['name'] == app, 'Uygulamanın adı değiştirilemez; başka bir adla yeni bir uygulama ekleyin.', 409)
        version = self.podman()
        objects, old_objects = self.objects(app, definition), self.objects(app, old_definition)
        self.srv_paths(definition)
        kept = {s['name'] for s in definition['secrets'] if s.get('keep')}
        cfg.require(kept <= set(old['secrets']), 'Saklanacak eski bir değer yok; bir değer girin.', 409)
        keep_images = apps.kept_images(old_definition, old, definition)
        places = {'revision': uuid.uuid4().hex, 'stopped': old['stopped'],
                  'ports': apps.allocate(self.env, app, definition, old['ports'], self.records), 'secrets': {}, 'images': {}}
        draft = self.render(app, definition, dict(places, images=apps.placeholders(definition, keep_images),
                                                  secrets=apps.placeholder_secrets(app, definition, old['secrets'])), version)
        self.podman5(draft, version)
        old_plan = self.render(app, old_definition, old, version)
        places['images'] = self.pull(definition, keep=keep_images)
        before = self.records.snapshot(app)
        units = self.unit_snapshot(set(old_plan['units']) | set(draft['units']))
        running = [u for u in old_plan['start'] if self.unit_state(u) == 'active']
        created, made, started, stopped = [], [], [], False
        try:
            self.step('Gizli değerler oluşturuluyor')
            for item in definition['secrets']:
                if item['name'] in kept:
                    places['secrets'][item['name']] = old['secrets'][item['name']]
                else:
                    places['secrets'][item['name']] = podman = self.create_secret(app, values[item['name']])
                    created.append(podman)
            plan = self.render(app, definition, places, version)
            self.dryrun(plan)
            self.step('Klasörler oluşturuluyor')
            made = self.make_folders(app, plan['folders'])
            stopped = True
            self.stop_units(self.all_units(old_plan, old_objects))
            self.step('Kayıt ve birimler yazılıyor')
            source = dict(record['source'])
            if source['sha256'] != apps.source_record({'tur': 'dosya'}, text, 0)['sha256']:
                source.update(alindi=int(self.now()), sha256=apps.source_record({'tur': 'dosya'}, text, 0)['sha256'])
            self.records.write(app, text=text, source=source, answers=apps.stored_answers(inspection, answers),
                               definition=definition, places=places)
            self.records.write_env(app, plan['environment'])
            for name in sorted(set(old_plan['units']) - set(plan['units'])):
                cfg.unlink(self.unit_dir() / name)
            self.write_units(plan)
            self.step('Ağ koruması uygulanıyor')
            self.net_call('apply')
            self.call(['systemctl', 'daemon-reload'])
            if gone := set(old_objects['containers'].values()) - set(objects['containers'].values()):
                for container in sorted(gone):
                    if self.exists('container', container):
                        self.call(['podman', 'rm', '--force', container], timeout=120)
            if not places['stopped']:
                self.start_units(plan, started)
                self.ready(app, definition, objects)
        except Exception as original:
            def recover():
                self.stop_units(list(reversed(started)), check=False)
                self.records.restore(app, before)
                self.unit_restore(units)
                self.call(['systemctl', 'daemon-reload'])
                self.net_call('apply')
                for name in reversed(created):
                    self.remove_secret(name)
                for path in reversed(made):
                    apps.remove_tree(path)
                if stopped:
                    for unit in running:
                        self.call(['systemctl', 'start', unit], timeout=READY_SECONDS + 30)
                    if running:
                        self.ready(app, old_definition, old_objects)
            self.fail_back(original, recover, 'Tanım uygulanamadı')
        # Only after the new units run: renewed and dropped values go.
        self.step('Eski gizli değerler kaldırılıyor')
        for logical, podman in sorted(old['secrets'].items()):
            if places['secrets'].get(logical) != podman:
                try:
                    self.remove_secret(podman)
                except cfg.ContainerConfigError as err:
                    raise cfg.ContainerConfigError(502, 'Yeni tanım çalışıyor; eski Podman secret kaldırılamadı: %s' % podman) from err
        return {'ok': True, 'ad': app, 'revizyon': places['revision']}

    # -- uygulama-kaldir (K9: data kept by default; images stay for Gelişmiş's cleanup)
    def app_remove(self, request):
        app, record = self.app_record(request)
        veri = request.get('veri')
        cfg.require(veri in ('sakla', 'sil'), 'Verilerin ne olacağını seçin.')
        cfg.require(veri == 'sakla' or request.get('onay') == app, 'Verileri silmek için uygulamanın adını yazın.')
        definition = record['definition']
        version = self.podman()
        objects = self.objects(app, definition)
        plan = self.render(app, definition, record['places'], version)
        running = [u for u in plan['start'] if self.unit_state(u) == 'active']
        units = self.unit_snapshot(set(plan['units']) | set(objects['files']))
        try:
            self.stop_units(self.all_units(plan, objects))
            self.step('Birimler kaldırılıyor')
            for name in units:
                cfg.unlink(self.unit_dir() / name)
            self.call(['systemctl', 'daemon-reload'])
        except Exception as original:
            def recover():
                self.unit_restore(units)
                self.call(['systemctl', 'daemon-reload'])
                for unit in running:
                    self.call(['systemctl', 'start', unit], timeout=READY_SECONDS + 30)
            self.fail_back(original, recover, 'Kaldırma başarısız')
        # From here on nothing comes back: each step names itself; the record goes last but the data, so a
        # retry finds what is left.
        self.step('Konteynerler, pod ve ağ kaldırılıyor')
        self.remove_objects(objects)
        self.step('Gizli değerler kaldırılıyor')
        for podman in sorted(record['places']['secrets'].values()):
            self.remove_secret(podman)
        self.step('Kayıt kaldırılıyor')
        self.records.remove(app)
        self.net_call('apply')
        if veri == 'sil':
            self.step('Veriler siliniyor')
            apps.remove_tree(apps.data_dir(self.env, app))
        return {'ok': True, 'ad': app, 'veri': veri}

    # -- uygulama-taslak (K2): an image turned into a Compose draft; nothing else is written
    def app_draft(self, request):
        reference = apps.image_ref(request.get('imaj'))
        pulled = apps.reference(reference)[1]
        self.step('İmaj indiriliyor: %s' % pulled)
        self.call(['podman', 'pull', '--quiet', pulled], timeout=PULL_SECONDS)
        info = self.json_call(['podman', 'image', 'inspect', pulled])
        cfg.require(isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict), 'İmaj okunamadı.', 502)
        return {'metin': apps.image_draft(reference, info[0]), 'kaynak': {'tur': 'imaj', 'imaj': reference}}
