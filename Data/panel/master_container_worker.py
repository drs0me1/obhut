#!/usr/bin/env python3
"""Explicit rootful container operations, run outside the panel sandbox.

The broker (master_container_manager) runs every job as its own transient unit and hands it here with
the request on standard input only. This module owns every container write: the application lifecycle (rebuild
DD-271, phase 3) and Gelişmiş's cleanup of what nothing uses (K8). Each action is a job with steps
and a durable record (KONTEYNER_STATE_DIR/operations/<id>.json) that never holds the request; a failure
undoes what the job did, in reverse, and names the failed step. The record carries the job's log (gunluk):
each step and fact with its time, and for an install whose container does not come up that container's own last
lines (it is rolled back, so its unit and record go), each secret value the job holds masked. Records older than
RECORD_DAYS go when a job begins. Secret values reach
Podman on standard input only: never an argument, a file of Obhut's, a record, a log line or a reply.

Access rows (rebuild phase 4): install seeds an application's rows, an edit keeps, seeds and drops them,
removal takes them; each of the three then runs the publication projection (master_shares publish). Two
other callers change units for the rows:

  Manager.row_change / row_files / row_restore   the settings worker's container side of one row change
                                                 (their docstrings hold the lock contract)
  master_container_worker.py --state S --adres-yenile
                                                 the address refresh: refresh-tailnet-config starts it as its
                                                 own transient unit after it changes TAILSCALE_IPV4 and at its
                                                 boot and nightly runs (address_refresh)
"""
import argparse
import contextlib
import copy
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import uuid

import master_applications as apps
import master_container_binds as binds
import master_container_config as cfg
import master_settings as settings

CLEANUP_ACTION = 'temizlik'
APP_ACTIONS = ('uygulama-kur', 'uygulama-baslat', 'uygulama-durdur', 'uygulama-yeniden-baslat', 'uygulama-guncelle',
               'uygulama-tanim', 'uygulama-kaldir', 'uygulama-taslak')
ACTIONS = APP_ACTIONS + (CLEANUP_ACTION,)
# DD-266: the share guard (every 30 s) and the settings worker hold install.lock for a moment;
# a container job waits for them (5 s) instead of failing at once.
LOCK_WAIT = 5.0
# Every unit active, every container running and healthy: within this many seconds of the last start.
READY_SECONDS = 300
PULL_SECONDS = 600
COPY_SECONDS = 1200
# The job's log: the newest LOG_LINES lines, each at most LINE_CHARS; a failed install keeps OUTPUT_LINES of its
# container's own output.
LOG_LINES = 300
LINE_CHARS = 400
OUTPUT_LINES = 20
# A multi-line secret's own lines are masked too when they are at least this long (a short line is not a secret's).
SECRET_LINE_CHARS = 8
# A job's record (with a failed install's container lines) stays this long; an older one goes when a job begins.
RECORD_DAYS = 30
ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
MASK = '••••'
# A directly started container that stops at once (DD-227): the usual reason, said beside the error.
DIRECT_HINT = (' Doğrudan başlatma bu imajda çalışmayabilir (imaj root başlayıp kendi kullanıcısına geçiyor olabilir); '
               'Root olarak başlatmayı deneyin.')
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
        self.published = False


class Manager:
    def __init__(self, state, run=run, network=None, quadlet=None, generator=None, inspector=None,
                 clock=time.monotonic, sleep=time.sleep, now=time.time, publisher=None):
        self.state = str(state)
        self.env = settings.env_read(state)
        self.env['STATE_FILE'] = self.state
        self.run = run
        self.network = network
        self.quadlet = quadlet
        self.generator = generator
        self.inspector = inspector
        self.publisher = publisher
        self.clock, self.sleep, self.now = clock, sleep, now
        self.operation = None
        self.op_path = None
        self.told = False

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

    @staticmethod
    def open_lock(path):
        """A lock file opened without following a link: a regular file of this user's."""
        with settings.parent_fd(path, create=True) as (directory, name):
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
        f = os.fdopen(fd, 'a')
        info = os.fstat(f.fileno())
        if not (stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()):
            f.close()
            raise cfg.ContainerConfigError(503, 'İşlem kilidi güvenli değil.')
        return f

    @contextlib.contextmanager
    def lock_file(self, path):
        """One lock, taken within LOCK_WAIT seconds or refused (409); released when the block ends."""
        with self.open_lock(path) as f:
            deadline = time.monotonic() + LOCK_WAIT
            while True:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError as err:
                    if time.monotonic() >= deadline:
                        raise cfg.ContainerConfigError(409, 'Kurulum veya başka bir konteyner işlemi sürüyor; biraz sonra yeniden deneyin.') from err
                    time.sleep(0.2)
            yield

    @contextlib.contextmanager
    def locked(self):
        """A job's locks: install.lock and KONTEYNER_LOCK; a pending settings change refuses the job."""
        with contextlib.ExitStack() as stack:
            stack.enter_context(self.lock_file(Path(self.env['RUNTIME_DIR']) / 'install.lock'))
            stack.enter_context(self.lock_file(Path(self.env['KONTEYNER_LOCK'])))
            pending = self.env.get('SETTINGS_PENDING_FILE')
            cfg.require(not pending or not Path(pending).exists(), 'Onay bekleyen sistem ayarını önce tamamlayın.', 409)
            yield

    @contextlib.contextmanager
    def settings_locked(self):
        """The settings worker's locks for its container side (row_change, row_restore): the caller holds
        install.lock in this process (with its settings and state locks) and owns the pending settings change, so
        only KONTEYNER_LOCK is taken here and the pending change is no refusal. Without a held install.lock or a
        pending change the call is refused (503): this path exists for the settings transaction only."""
        with self.open_lock(Path(self.env['RUNTIME_DIR']) / 'install.lock') as probe:
            try:
                # A second open file description of the same file: flock refuses it while the caller holds its own.
                fcntl.flock(probe.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = False
            except BlockingIOError:
                held = True
        cfg.require(held, 'Erişim satırı yalnız kurulum kilidini tutan ayar işleminden değişir.', 503)
        pending = self.env.get('SETTINGS_PENDING_FILE')
        cfg.require(bool(pending) and Path(pending).exists(), 'Erişim satırı yalnız bekleyen bir ayar işleminden değişir.', 503)
        with self.lock_file(Path(self.env['KONTEYNER_LOCK'])):
            yield

    # -- the job record
    def step(self, label):
        """The job's current step, also a line of its log."""
        if self.operation is not None:
            self.operation['step'] = label
            self.note(label, 'adim')

    def note(self, text, kind='bilgi'):
        """One line of the job's log: adim (a step began), bilgi (a fact), cikti (a container's own output), hata
        (why the job failed) or tamam (it finished)."""
        if self.operation is None:
            return
        if kind == 'hata':
            self.told = True
        log = self.operation.setdefault('gunluk', [])
        log.append({'t': int(self.now()), 'tur': kind, 'ileti': str(text)[:LINE_CHARS]})
        del log[:-LOG_LINES]
        self.save()

    def save(self):
        self.operation['updated_at'] = int(time.time())
        settings.atomic(self.op_path, json.dumps(self.operation, ensure_ascii=False) + '\n', 0o600)

    def container_output(self, container, values):
        """A container's own last lines since the job began (journald's CONTAINER_NAME) as lines of the job's log.
        Each secret value the job holds is masked in the raw output, before anything else touches it, and so is each
        long line of a multi-line one; then a line keeps its printable text only. Reading the journal never hides
        the job's own error."""
        argv = ['journalctl', 'CONTAINER_NAME=' + container, '--since', '@%d' % int(self.operation.get('created_at') or 0),
                '-n', str(OUTPUT_LINES), '-o', 'cat', '--no-pager']
        try:
            p = self.call(argv, timeout=30, check=False)
        except cfg.ContainerConfigError:
            return
        hidden = set()
        for value in values.values():
            if isinstance(value, str) and value:
                hidden.add(value)
                hidden.update(part.strip() for part in value.splitlines() if len(part.strip()) >= SECRET_LINE_CHARS)
        output = (p.stdout or '') if p.returncode == 0 else ''
        for value in sorted(hidden, key=len, reverse=True):
            output = output.replace(value, MASK)
        lines = []
        for raw in output.splitlines():
            text = ''.join(ch if ch.isprintable() else ' ' for ch in ANSI_RE.sub('', raw)).strip()
            if text:
                lines.append(text)
        if not lines:
            self.note('%s konteyneri bir şey yazmadı.' % container)
        for text in lines[-OUTPUT_LINES:]:
            self.note(text, 'cikti')

    @staticmethod
    def prune(folder):
        """Job records older than RECORD_DAYS go (the journal rotates; these would not)."""
        limit = time.time() - RECORD_DAYS * 86400
        for path in folder.glob('*.json'):
            try:
                info = path.lstat()
                if stat.S_ISREG(info.st_mode) and info.st_mtime < limit:
                    path.unlink()
            except OSError:
                pass

    def begin(self, action, request, operation):
        cfg.require(isinstance(operation, str) and cfg.REV_RE.fullmatch(operation), 'İşlem kimliği geçersiz.')
        root = Path(self.env.get('KONTEYNER_STATE_DIR', ''))
        cfg.require(root.is_absolute() and '..' not in root.parts, 'Konteyner kayıt yolu eksik; kurulumu yeniden çalıştırın.', 503)
        cfg.private_dir(root)
        cfg.private_dir(root / 'operations')
        self.prune(root / 'operations')
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
        self.told = False
        self.step('Doğrulanıyor')

    def execute(self, action, request, operation):
        cfg.require(action in ACTIONS and isinstance(request, dict), 'Konteyner işlemi geçersiz.')
        self.begin(action, request, operation)
        try:
            with self.locked():
                result = self.dispatch(action, request)
            self.operation.update(state='done', result=result, finished_at=int(time.time()), step='Tamamlandı')
            self.note('Tamamlandı', 'tamam')
            return result
        except Exception as err:
            if not isinstance(err, cfg.ContainerConfigError):
                err = cfg.ContainerConfigError(502, 'Konteyner işlemi tamamlanamadı; işlem kaydındaki durumu kontrol edin.')
            self.operation.update(state='failed', error=str(err), status=err.status, finished_at=int(time.time()),
                                  failed_step=getattr(err, 'failed_step', self.operation['step']))
            # The question whose answer most likely caused it (a direct start), for Uygulama ekle's way back.
            if getattr(err, 'question', None):
                self.operation['soru'] = err.question
            self.operation['step'] = 'Başarısız'
            # An install already said why before its rollback; any other job says it here.
            if self.told:
                self.save()
            else:
                self.note(str(err), 'hata')
            raise err

    def dispatch(self, action, request):
        if action == CLEANUP_ACTION:
            return self.cleanup(request)
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

    # -- Gelişmiş's cleanup (K8): unused images, networks, volumes and the data folders of removed applications
    def resource_users(self, kind, target):
        """Whether any container, in any state, uses an image (ancestor), a network or a volume (Podman's filters)."""
        rows = self.json_call(['podman', 'ps', '-a', '--filter', ('ancestor' if kind == 'image' else kind) + '=' + target,
                               '--format', 'json'])
        cfg.require(isinstance(rows, list), 'Kaynak kullanımı okunamadı.', 502)
        return bool(rows)

    def mount_sources(self):
        """Every host path a container (in any state) mounts, resolved."""
        rows = self.json_call(['podman', 'ps', '-a', '--format', 'json'])
        cfg.require(isinstance(rows, list), 'Konteynerler okunamadı.', 502)
        sources = set()
        for row in rows:
            ident = row.get('Id') if isinstance(row, dict) else None
            cfg.require(isinstance(ident, str) and re.fullmatch(r'[0-9a-f]{64}', ident), 'Konteynerler okunamadı.', 502)
            info = self.inspect(ident)
            for mount in (info or {}).get('Mounts') or []:
                if isinstance(mount, dict) and isinstance(mount.get('Source'), str) and mount['Source'].startswith('/'):
                    sources.add(os.path.realpath(mount['Source']))
        return sources

    def cleanup(self, request):
        """The selected items, each checked again as unused right before it is removed (cleanup_one). An item that is
        in use or gone stays and is named; the others are removed, and then the job fails naming what stayed."""
        removed, left = [], []
        # The broker names the job (name); everything else is the selection.
        for kind, target in apps.cleanup_items({k: v for k, v in request.items() if k != 'name'}):
            self.step('Kaldırılıyor: %s' % target[:80])
            try:
                self.cleanup_one(kind, target)
                removed.append({'tur': kind, 'ad': target})
            except cfg.ContainerConfigError as err:
                left.append('%s: %s' % (target[:80], err))
        if left:
            raise cfg.ContainerConfigError(409, ('%d öge kaldırılmadı (%d kaldırıldı): %s' % (len(left), len(removed), '; '.join(left)))[:900])
        return {'ok': True, 'kaldirilan': removed}

    def cleanup_one(self, kind, target):
        """One item. An image: no application record names it and no container comes from it; it goes by its tags (the
        last one takes the image) or, untagged, by its ID, never with --force. A network: not Podman's default, not an
        application's, no container on it. A volume: no container mounts it. A data folder: its application has no
        record and no container mounts anything inside it."""
        uses = apps.resource_uses(self.records)
        if kind == 'imaj':
            cfg.require(self.exists('image', target), 'İmaj artık yok.', 404)
            info = self.json_call(['podman', 'image', 'inspect', target])
            cfg.require(isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict), 'İmaj okunamadı.', 502)
            tags = [t for t in info[0].get('RepoTags') or [] if isinstance(t, str)]
            known = {target, info[0].get('Id', ''), *tags, *(d for d in info[0].get('RepoDigests') or [] if isinstance(d, str))}
            cfg.require(not known & set(uses['image']), 'İmaj bir uygulamanın kaydında kullanılıyor.', 409)
            cfg.require(not self.resource_users('image', target), 'İmaj bir konteynerde kullanılıyor.', 409)
            cfg.require(all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,511}', t) for t in tags), 'İmajın etiketi okunamadı.', 502)
            self.call(['podman', 'image', 'rm', *(tags or [target])], timeout=120)
            cfg.require(not self.exists('image', target), 'İmaj kaldırılamadı; başka bir imaj ona dayanıyor olabilir.', 409)
        elif kind == 'ag':
            cfg.require(target != apps.DEFAULT_NETWORK, "Podman'ın varsayılan ağı kaldırılmaz.", 409)
            cfg.require(self.exists('network', target), 'Ağ artık yok.', 404)
            cfg.require(target not in uses['network'], 'Ağ bir uygulamanın; uygulamayla birlikte kaldırılır.', 409)
            cfg.require(not self.resource_users('network', target), 'Ağ bir konteynerde kullanılıyor.', 409)
            self.call(['podman', 'network', 'rm', target])
        elif kind == 'birim':
            cfg.require(self.exists('volume', target), 'Birim artık yok.', 404)
            cfg.require(not self.resource_users('volume', target), 'Birim bir konteynerde kullanılıyor.', 409)
            self.call(['podman', 'volume', 'rm', target], timeout=300)
        else:
            cfg.require(not self.records.exists(target), 'Bu klasörün uygulaması var; verileri uygulamayla birlikte silinir.', 409)
            path = apps.data_dir(self.env, target)
            cfg.require(os.path.lexists(path), 'Klasör artık yok.', 404)
            inside = os.path.realpath(path)
            cfg.require(not any(s == inside or s.startswith(inside + '/') for s in self.mount_sources()),
                        'Klasör bir konteynerde bağlı.', 409)
            apps.remove_tree(path)

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

    def render(self, app, definition, places, version, rows):
        return apps.render(self.env, app, definition, places, version, rows, self.generator_module())

    def publish(self):
        """The publication projection after a job changed access rows (master_shares.Manager.publish: the Caddy
        sites, the local names, the 443 listener). Its contract wants the installer and the share locks: the job
        holds install.lock, the share lock is taken here around the call."""
        if self.publisher is not None:
            return self.publisher()
        import master_shares
        with self.lock_file(Path(self.env['RUNTIME_DIR']) / 'paylasim.lock'):
            try:
                master_shares.Manager(self.state).publish()
            except master_shares.ShareError as err:
                raise cfg.ContainerConfigError(502, str(err)) from err
            except (OSError, KeyError, ValueError) as err:
                raise cfg.ContainerConfigError(502, 'Adresler yayımlanamadı; yayın kaydı okunamadı.') from err
        return None

    def names_free(self, app, definition, rows=None, errors=None):
        """The Tailscale names of the definition's new address ports are free (apps.name_errors), by question: a taken
        one raises, or with errors (an install plan) is added to them under its question."""
        taken = apps.name_errors(self.env, app, definition, rows, self.records)
        if errors is not None:
            for key, text in taken.items():
                errors.setdefault(key, text)
        elif taken:
            text = '; '.join('%s: %s' % (k, v) for k, v in sorted(taken.items())[:3])
            raise cfg.ContainerConfigError(409, ('Yanıtlar geçersiz: ' + text)[:600])

    def podman5(self, plan, version):
        """A Kubernetes Pod with several containers and a service_healthy dependency need Podman 5."""
        refusal = self.generator_module().podman5_refusal(plan, version)
        cfg.require(refusal is None, refusal or '', 409)

    def checked(self, text, answers, existing=frozenset(), record=None):
        """The server's own inspection and check of the file and the answers (never a browser's definition). On an
        edit (record) the questions of the ports that stay are answered from their rows (apps.port_answers)."""
        apps.checked_text(text)
        inspector = self.inspector_module()
        inspection = inspector.inspect(text)
        refusals = inspection.get('refusals') or []
        if refusals or inspection.get('format') is None:
            first = refusals[0] if refusals else {'line': 1, 'text': 'Dosya okunamadı.'}
            raise cfg.ContainerConfigError(409, 'Dosyada kurulumu durduran satırlar var (satır %d: %s).' % (first['line'], first['text']))
        row_errors = {}
        if record is not None:
            answers, row_errors = apps.port_answers(record, inspection, answers)
        definition, values, errors = inspector.check(inspection, answers, existing_secrets=frozenset(existing))
        errors = dict(errors or {}, **row_errors)
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

    def srv_paths(self, definition, errors=None):
        """Every /srv folder of the definition passes DD-226 now: a refused one raises, or with errors (an install
        plan) is added to them under its mount question."""
        for svc in definition['services']:
            for mount in svc.get('mounts', []):
                if mount.get('to') != 'srv':
                    continue
                try:
                    self.srv_folder(mount['path'])
                except cfg.ContainerConfigError as err:
                    if errors is None:
                        raise
                    errors.setdefault('mount:%s:%s' % (svc['name'], mount['target']), str(err))

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

    def forget_units(self, units):
        """Units whose files went: systemd keeps a failed one listed (a container killed because it would not stop
        in time, one that never came up) until it is reset. Resetting one that was not failed is no error, and a
        reset that cannot run never fails the job."""
        names = sorted(u for u in units if isinstance(u, str) and u.endswith('.service'))
        if not names:
            return
        try:
            self.call(['systemctl', 'reset-failed', '--', *names], timeout=30, check=False)
        except cfg.ContainerConfigError:
            pass

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

    def ready(self, app, definition, objects, watch=None):
        """Each unit active, each container running and owned by this application, health neither starting
        nor unhealthy, and a direct start proved (DD-227): its user and no capabilities. watch (an install's) is
        called with the container of a service that does not come up, before the job says so."""
        deadline = self.clock() + READY_SECONDS
        self.step('Hazır olması bekleniyor')
        running = set()
        while True:
            waiting = None
            for svc in definition['services']:
                name = svc['name']
                unit, container = objects['units'][name], objects['containers'][name]
                state = self.unit_state(unit)
                if state == 'failed':
                    self.not_ready(svc, container, '%s başlamadı: birimi başarısız oldu (günlüğü: journalctl -u %s).'
                                   % (name, unit), watch)
                # A container that stops at once is restarted by systemd (Restart=); waiting the whole time would
                # only hide why. Its journal stays after the rollback removes the unit.
                if self.restarts(unit):
                    self.not_ready(svc, container, '%s başladıktan hemen sonra durdu (günlüğü: journalctl -u %s).'
                                   % (name, unit), watch)
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
                if name not in running:
                    running.add(name)
                    self.note('%s çalışıyor.' % name)
            if waiting is None:
                return
            if self.clock() >= deadline:
                if watch:
                    watch(objects['containers'][waiting])
                raise cfg.ContainerConfigError(502, '%s %d saniyede başlamadı ya da sağlık denetimini geçmedi.' % (waiting, READY_SECONDS))
            self.sleep(2)

    def not_ready(self, svc, container, message, watch):
        """A service that did not come up: its container's output first (watch), then the error; a direct start
        says its usual reason and names its question."""
        if watch:
            watch(container)
        direct = svc['start'] == 'direct'
        error = cfg.ContainerConfigError(502, message + (DIRECT_HINT if direct else ''))
        if direct:
            error.question = 'start:' + svc['name']
        raise error

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
                self.note('İmaj sabitlendi: %s' % pulled[reference])
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
    def install_checks(self, request, errors=None):
        """Every check an install makes before its first write, in its order: the file and the answers again on the
        server, the name free everywhere (record, units, containers, network, pod), the Tailscale names free, the /srv
        folders (DD-226), a takeover's source container, the pool ports, and a preliminary render (what the generator
        cannot express, and what needs Podman 5). Nothing is written, pulled or created. The install (errors None)
        stops at the first refusal; the install plan (POST …/kur with plan, run in the backend with read-only commands)
        passes a dict that collects every refusal under its question id or part (podman, name, kaynak, portlar, dosya)
        and gets None back when there was one. Otherwise the install's context."""
        def attempt(key, check):
            if errors is None:
                return check()
            try:
                return check()
            except cfg.ContainerConfigError as err:
                errors.setdefault(key, str(err))
                return None
        text = apps.checked_text(request.get('metin'))
        answers = request.get('yanitlar')
        source = apps.request_source(request.get('kaynak'))
        self.step('Dosya denetleniyor')
        inspection, definition, values = self.checked(text, answers)
        app = apps.app_name(definition['name'])
        cfg.require(request.get('name') == app, 'Uygulama adı istekteki adla uyuşmuyor.')
        version = attempt('podman', self.podman)
        objects = self.objects(app, definition)
        self.step('Ad, klasörler ve portlar denetleniyor')
        attempt('name', lambda: self.name_free(app, objects))
        self.names_free(app, definition, errors=errors)
        self.srv_paths(definition, errors=errors)
        old = attempt('kaynak', lambda: self.takeover(source['konteyner'], app, inspection, answers)) \
            if source['tur'] == 'konteyner' else None
        # The rows are the home of how each port is reached; the stored definition keeps the ports' numbers only.
        rows, stored = apps.next_rows(definition), apps.stored_definition(definition)
        ports = attempt('portlar', lambda: apps.allocate(self.env, app, apps.address_keys(rows), {}, self.records))
        places = {'revision': uuid.uuid4().hex, 'stopped': False, 'ports': ports or {}, 'secrets': {}, 'images': {}}
        # Everything the generator cannot express, and what needs Podman 5, stops here, before any write.
        draft = None
        if version is not None and ports is not None:
            draft = attempt('dosya', lambda: self.render(app, stored, dict(places, images=apps.placeholders(definition),
                                                                           secrets=apps.placeholder_secrets(app, definition)),
                                                         version, rows))
            if draft is not None:
                attempt('podman', lambda: self.podman5(draft, version))
        if errors:
            return None
        return {'text': text, 'answers': answers, 'source': source, 'inspection': inspection, 'definition': definition,
                'values': values, 'app': app, 'version': version, 'objects': objects, 'old': old, 'rows': rows,
                'stored': stored, 'places': places, 'draft': draft}

    def app_install(self, request):
        checks = self.install_checks(request)
        text, answers, source, inspection = checks['text'], checks['answers'], checks['source'], checks['inspection']
        definition, values, app, version = checks['definition'], checks['values'], checks['app'], checks['version']
        objects, old, rows, stored, places = checks['objects'], checks['old'], checks['rows'], checks['stored'], checks['places']
        draft = checks['draft']
        undo, plan = Undo(), draft
        try:
            self.step('Kayıt yazılıyor')
            undo.record = True
            self.records.write(app, text=text, source=apps.source_record(source, text, self.now()),
                               answers=apps.stored_answers(inspection, answers), definition=stored, places=places, rows=rows)
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
            plan = self.render(app, stored, places, version, rows)
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
            self.ready(app, definition, objects, watch=lambda container: self.container_output(container, values))
            # The new rows' names and sites: a failed projection keeps what it applied (its own restore).
            self.step('Adresler yayımlanıyor')
            self.publish()
            undo.published = True
            if old:
                self.step('Eski konteyner kaldırılıyor')
                # Never --volumes: the old named volumes stay until Gelişmiş's cleanup.
                self.call(['podman', 'rm', old['name']], timeout=120)
            return {'ok': True, 'ad': app, 'revizyon': places['revision']}
        except Exception as original:
            failed = self.operation['step'] if self.operation else 'Kurulum'
            cause = str(original) if isinstance(original, cfg.ContainerConfigError) else 'beklenmeyen hata.'
            # The log says why before the rollback's own steps.
            self.note(cause, 'hata')
            self.step('Geri alınıyor')
            recovered = self.undo_install(app, plan, objects, undo, old)
            self.note('Yapılan her şey geri alındı.' if recovered else 'Geri alma tamamlanamadı.', 'bilgi' if recovered else 'hata')
            error = cfg.ContainerConfigError(
                original.status if isinstance(original, cfg.ContainerConfigError) else 502,
                ('Kurulum başarısız (%s): %s Yapılan her şey geri alındı.' if recovered else
                 'Kurulum başarısız (%s): %s Geri alma da tamamlanamadı; Gelişmiş → Podman ve İşlem geçmişine bakın.')
                % (failed, cause))
            error.failed_step = failed
            error.question = getattr(original, 'question', None)
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
            attempt(lambda: self.forget_units(self.all_units(plan, objects)))
        for name in reversed(undo.secrets):
            attempt(lambda name=name: self.remove_secret(name))
        for path in reversed(undo.folders):
            attempt(lambda path=path: apps.remove_tree(path))
        if undo.record:
            attempt(lambda: self.records.remove(app))
        if undo.guard:
            attempt(lambda: self.net_call('apply'))
        if undo.published:
            attempt(self.publish)
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
        plan = self.render(app, definition, places, version, record['rows'])
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
        plan = self.render(app, definition, places, version, record['rows'])
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
        plan = self.render(app, definition, record['places'], version, record['rows'])
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
        plan = self.render(app, definition, places, version, record['rows'])
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
        # A port that stays keeps its row (its answer may be left out and, given, must match it); a new port gets
        # a row from its answer, a port that went loses its row and its pool port.
        inspection, definition, values = self.checked(text, answers, existing=set(old['secrets']), record=record)
        cfg.require(definition['name'] == app, 'Uygulamanın adı değiştirilemez; başka bir adla yeni bir uygulama ekleyin.', 409)
        self.names_free(app, definition, record['rows'])
        rows, stored = apps.next_rows(definition, record['rows']), apps.stored_definition(definition)
        version = self.podman()
        objects, old_objects = self.objects(app, definition), self.objects(app, old_definition)
        self.srv_paths(definition)
        kept = {s['name'] for s in definition['secrets'] if s.get('keep')}
        cfg.require(kept <= set(old['secrets']), 'Saklanacak eski bir değer yok; bir değer girin.', 409)
        keep_images = apps.kept_images(old_definition, old, definition)
        places = {'revision': uuid.uuid4().hex, 'stopped': old['stopped'],
                  'ports': apps.allocate(self.env, app, apps.address_keys(rows), old['ports'], self.records), 'secrets': {},
                  'images': {}}
        draft = self.render(app, stored, dict(places, images=apps.placeholders(definition, keep_images),
                                              secrets=apps.placeholder_secrets(app, definition, old['secrets'])), version, rows)
        self.podman5(draft, version)
        old_plan = self.render(app, old_definition, old, version, record['rows'])
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
            plan = self.render(app, stored, places, version, rows)
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
                               definition=stored, places=places, rows=rows)
            self.records.write_env(app, plan['environment'])
            for name in sorted(set(old_plan['units']) - set(plan['units'])):
                cfg.unlink(self.unit_dir() / name)
            self.write_units(plan)
            self.step('Ağ koruması uygulanıyor')
            self.net_call('apply')
            self.call(['systemctl', 'daemon-reload'])
            self.forget_units(set(self.all_units(old_plan, old_objects)) - set(self.all_units(plan, objects)))
            if gone := set(old_objects['containers'].values()) - set(objects['containers'].values()):
                for container in sorted(gone):
                    if self.exists('container', container):
                        self.call(['podman', 'rm', '--force', container], timeout=120)
            if not places['stopped']:
                self.start_units(plan, started)
                self.ready(app, definition, objects)
            # A new port's name and site, a gone port's removal: a failed projection keeps what it applied.
            self.step('Adresler yayımlanıyor')
            self.publish()
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

    # -- uygulama-kaldir (K9 as amended by DD-281: its unused images go; with sil, its data and job records too)
    def app_remove(self, request):
        app, record = self.app_record(request)
        veri = request.get('veri')
        cfg.require(veri in ('sakla', 'sil'), 'Verilerin ne olacağını seçin.')
        cfg.require(veri == 'sakla' or request.get('onay') == app, 'Verileri silmek için uygulamanın adını yazın.')
        definition = record['definition']
        version = self.podman()
        objects = self.objects(app, definition)
        # Only the units' names and their order matter here: a raw row is rendered closed, so a removal never
        # needs the address an open one is published on.
        closed = {k: dict(r, kapsam='kapali') if r['tur'] == 'ham' else r for k, r in record['rows'].items()}
        plan = self.render(app, definition, record['places'], version, closed)
        running = [u for u in plan['start'] if self.unit_state(u) == 'active']
        units = self.unit_snapshot(set(plan['units']) | set(objects['files']))
        try:
            self.stop_units(self.all_units(plan, objects))
            self.step('Birimler kaldırılıyor')
            for name in units:
                cfg.unlink(self.unit_dir() / name)
            self.call(['systemctl', 'daemon-reload'])
            self.forget_units(self.all_units(plan, objects))
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
        # The rows went with the record: their names and sites go too. A failed projection keeps what it applied
        # (the share guard tries again every 30 s); the data is still deleted when asked, then the job says so.
        self.step('Adresler yayından kaldırılıyor')
        unpublished = None
        try:
            self.publish()
        except cfg.ContainerConfigError as err:
            unpublished = err
        self.remove_images(record['places'].get('images') or {})
        if veri == 'sil':
            self.step('Veriler siliniyor')
            apps.remove_tree(apps.data_dir(self.env, app))
            self.step('İş kayıtları siliniyor')
            self.forget_jobs(app)
        if unpublished is not None:
            raise cfg.ContainerConfigError(502, 'Uygulama kaldırıldı ama adresleri yayından kaldırılamadı: %s' % unpublished) \
                from unpublished
        return {'ok': True, 'ad': app, 'veri': veri}

    def remove_images(self, images):
        """A removed application's images, each unless another record names it or any container comes from it
        (cleanup_one's checks, made after the record went). One that stays is a line of the job's log, never its
        failure: the application is gone either way, and Gelişmiş's cleanup offers the image later."""
        refs = sorted({ref for ref in images.values() if isinstance(ref, str) and ref})
        if refs:
            self.step('İmajlar kaldırılıyor')
        for ref in refs:
            try:
                if not self.exists('image', ref):
                    continue
                info = self.json_call(['podman', 'image', 'inspect', ref])
                ident = info[0].get('Id') if isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict) else None
                cfg.require(isinstance(ident, str) and re.fullmatch(r'(?:sha256:)?[0-9a-f]{64}', ident), 'İmaj okunamadı.', 502)
                self.cleanup_one('imaj', ident.rpartition(':')[2])
                self.note('İmaj kaldırıldı: %s' % ref)
            except cfg.ContainerConfigError as err:
                self.note('İmaj kaldı (%s): %s' % (ref, err))

    def forget_jobs(self, app):
        """The application's earlier job records go with its data (a failed install's record holds its container's
        own lines); this job's record stays. İşlem geçmişi keeps its lines."""
        if self.op_path is None:
            return
        for path in self.op_path.parent.glob('*.json'):
            if path == self.op_path:
                continue
            try:
                if not stat.S_ISREG(path.lstat().st_mode):
                    continue
                with open(path, encoding='utf-8') as handle:
                    job = json.load(handle)
                if isinstance(job, dict) and job.get('name') == app:
                    path.unlink()
            except (OSError, ValueError):
                pass

    # -- uygulama-taslak (K2): an image turned into a Compose draft; nothing else is written
    def app_draft(self, request):
        reference = apps.image_ref(request.get('imaj'))
        pulled = apps.reference(reference)[1]
        self.step('İmaj indiriliyor: %s' % pulled)
        self.call(['podman', 'pull', '--quiet', pulled], timeout=PULL_SECONDS)
        info = self.json_call(['podman', 'image', 'inspect', pulled])
        cfg.require(isinstance(info, list) and len(info) == 1 and isinstance(info[0], dict), 'İmaj okunamadı.', 502)
        return {'metin': apps.image_draft(reference, info[0]), 'kaynak': {'tur': 'imaj', 'imaj': reference}}

    # -- units for access rows (row changes and the address refresh)
    @staticmethod
    def affected(plan, objects, definition, written):
        """The service units to restart for the unit files written, in start order: a container's own unit and
        every service that depends on it (systemd's Requires= takes them down with it); a pod's or the network's
        file: every unit the plan starts."""
        if any(not name.endswith('.container') for name in written):
            return list(plan['start'])
        services = {s for s, unit in objects['units'].items() if unit[:-len('.service')] + '.container' in written}
        needs = {s['name']: {d['service'] for d in s.get('depends_on') or ()} for s in definition['services']}
        while True:
            more = {s for s, deps in needs.items() if deps & services} - services
            if not more:
                break
            services |= more
        units = {objects['units'][s] for s in services}
        return [u for u in plan['start'] if u in units]

    def restart_services(self, app, definition, objects, plan, units, write=None):
        """Stops the given units (reverse order), writes the unit files (write: {name: text}) and reloads systemd,
        then starts them in order and waits until those services are ready."""
        self.stop_units([u for u in plan['stop'] if u in units])
        if write:
            self.step('Birimler yazılıyor')
            folder = self.unit_dir()
            for name, text in sorted(write.items()):
                settings.atomic(folder / name, text, 0o600)
        self.call(['systemctl', 'daemon-reload'])
        self.start_units({'start': [u for u in plan['start'] if u in units]}, [])
        if units:
            self.ready(app, {'services': [s for s in definition['services'] if objects['units'][s['name']] in units]}, objects)

    def replace_units(self, app, definition, places, plan, objects):
        """Writes the plan's unit files that differ from the ones in place; when the application is not stopped,
        restarts the services whose units changed (affected) and waits for them. (written files, restarted units)."""
        current = self.unit_snapshot(plan['units'])
        written = sorted(n for n, text in plan['units'].items() if current.get(n) != text.encode('utf-8'))
        if not written:
            return [], []
        restart = [] if places['stopped'] else self.affected(plan, objects, definition, written)
        self.restart_services(app, definition, objects, plan, restart, {n: plan['units'][n] for n in written})
        return written, restart

    def row_files(self, app):
        """The files row_change may change for one application, for the settings worker's snapshot: its
        erisim.json and yerler.json and every unit file of its definition in KONTEYNER_BIRIM_DIR. Read-only; the
        caller holds install.lock (no job can change the record meanwhile)."""
        app = apps.app_name(app)
        record = self.records.load(app)
        folder = self.unit_dir()
        return ([str(self.records.dir(app) / apps.ROWS_FILE), str(self.records.dir(app) / 'yerler.json')]
                + [str(folder / name) for name in self.objects(app, record['definition'])['files']])

    def row_change(self, app, key, row):
        """One access row of one application changes: the settings worker's container side (master_settings,
        rebuild phase 4). Contract: the caller holds install.lock in this process and owns the pending settings
        change (it wrote SETTINGS_PENDING_FILE, with the snapshot of row_files(app), before this call); only
        KONTEYNER_LOCK is taken here and the pending change is no refusal (settings_locked). The caller has checked
        the row against everything outside the records (state.env ports, VPN ports, listeners, the firewall, DNS,
        the internet consent); here its shape and its clashes with every row of every application are checked.

        An address that becomes a raw port releases its pool port, a raw port that becomes an address gets one.
        Then erisim.json and yerler.json are written, the guard is applied (a unit's start check reads it), the
        units rendered with the generator and the ones that changed written, systemd reloaded, and only the
        services whose units changed (with the services that depend on them) restarted and waited for (up to
        READY_SECONDS), unless the application is stopped. A name or the Tailscale port or internet name of an
        address changes no unit and restarts nothing. A row equal to the stored one writes nothing. A failure
        raises and leaves the rollback to the caller: it restores row_files(app) and calls row_restore.

        Returns {"uygulama", "anahtar", "birimler": [unit files written], "yeniden_baslatilan": [units restarted]}."""
        with self.settings_locked():
            app = apps.app_name(app)
            cfg.require(self.records.exists(app), 'Uygulama bulunamadı.', 404)
            record = self.records.load(app)
            cfg.require(isinstance(key, str) and key in record['rows'], 'Uygulamanın böyle bir portu yok.', 404)
            row = apps.check_row(key, copy.deepcopy(row), 400)
            result = {'uygulama': app, 'anahtar': key, 'birimler': [], 'yeniden_baslatilan': []}
            if row == record['rows'][key]:
                return result
            rows = dict(record['rows'], **{key: row})
            others = [(i['id'], i['anahtar'], i['satir']) for i in apps.access_rows(self.env, self.records) if i['uygulama'] != app]
            clash = apps.row_conflict(others + [(apps.row_id(app, k), k, r) for k, r in sorted(rows.items())])
            cfg.require(clash is None, clash or '', 409)
            old = record['places']
            places = dict(old, ports=apps.allocate(self.env, app, apps.address_keys(rows), old['ports'], self.records),
                          revision=uuid.uuid4().hex)
            version = self.podman()
            plan = self.render(app, record['definition'], places, version, rows)
            self.podman5(plan, version)
            objects = self.objects(app, record['definition'])
            self.step('Erişim satırı yazılıyor')
            self.records.write(app, rows=rows, places=places)
            self.step('Ağ koruması uygulanıyor')
            self.net_call('apply')
            result['birimler'], result['yeniden_baslatilan'] = self.replace_units(app, record['definition'], places, plan, objects)
            return result

    def row_restore(self, app, restarted=None):
        """After a row change failed or was rolled back: the caller (the settings worker, under row_change's
        contract and locks) has put row_files(app) back. The guard is applied again from the restored records,
        systemd reloaded and the services restarted and waited for: the units row_change restarted (its
        yeniden_baslatilan), every service of the application when that is not known (None), none while the
        application is stopped. Returns the units restarted."""
        with self.settings_locked():
            app = apps.app_name(app)
            record = self.records.load(app)
            definition = record['definition']
            version = self.podman()
            plan = self.render(app, definition, record['places'], version, record['rows'])
            objects = self.objects(app, definition)
            self.step('Ağ koruması uygulanıyor')
            self.net_call('apply')
            units = [] if record['places']['stopped'] else [u for u in plan['start'] if restarted is None or u in restarted]
            self.restart_services(app, definition, objects, plan, units)
            return units

    # -- --adres-yenile
    @staticmethod
    def published(text):
        return sorted(line for line in (text or '').splitlines() if line.startswith('PublishPort='))

    def address_refresh(self):
        """--adres-yenile: every application with an open raw row whose unit files publish on another address than
        state.env names now (TAILSCALE_IPV4, WAN_IPV4) gets its units written again (replace_units) and, unless it
        is stopped, the services whose units changed restarted. Idempotent: units that already carry the current
        addresses are left alone. Takes a job's locks (locked: install.lock and KONTEYNER_LOCK, refused while a
        settings change is pending); busy is a 409 the caller reports for the next run. One application's failure
        does not stop the others. Returns {"yenilenen": [app], "hatalar": [{"uygulama", "hata"}]}."""
        result = {'yenilenen': [], 'hatalar': []}
        with self.locked():
            records, version, stale = self.records, None, []
            for app in records.names():
                if not os.path.lexists(records.dir(app) / 'yerler.json'):
                    continue
                try:
                    record = records.load(app)
                    if not any(r['tur'] == 'ham' and r['kapsam'] != 'kapali' for r in record['rows'].values()):
                        continue
                    version = version or self.podman()
                    plan = self.render(app, record['definition'], record['places'], version, record['rows'])
                    current = self.unit_snapshot(plan['units'])
                    if any(self.published(text) != self.published((current.get(name) or b'').decode('utf-8', 'replace'))
                           for name, text in plan['units'].items()):
                        stale.append((app, record, plan))
                except cfg.ContainerConfigError as err:
                    result['hatalar'].append({'uygulama': app, 'hata': str(err)})
            if stale:
                self.net_call('apply')
            for app, record, plan in stale:
                try:
                    self.replace_units(app, record['definition'], record['places'], plan, self.objects(app, record['definition']))
                    result['yenilenen'].append(app)
                except cfg.ContainerConfigError as err:
                    result['hatalar'].append({'uygulama': app, 'hata': str(err)})
        return result


def main(argv=None):
    """master_container_worker.py --state S --adres-yenile: the address refresh (Manager.address_refresh), started by
    refresh-tailnet-config as its own transient unit. Busy (a job, the installer or a pending settings change): one
    line and exit 0, the next run retries; a failure: exit 1. The worker has no other entry of its own (the jobs
    come through master_container_manager)."""
    parser = argparse.ArgumentParser(description='Uygulamaların doğrudan portlarını sunucunun şimdiki adreslerine taşır.')
    parser.add_argument('--state', required=True)
    parser.add_argument('--adres-yenile', action='store_true', dest='refresh', required=True)
    args = parser.parse_args(argv)
    try:
        result = Manager(args.state).address_refresh()
    except cfg.ContainerConfigError as err:
        if err.status == 409:
            print('adres-yenile: %s Sonraki çalışmada yeniden denenecek.' % err)
            return 0
        print('adres-yenile: HATA %s' % err, file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError, settings.SettingsError) as err:
        print('adres-yenile: HATA kayıtlar okunamadı (%s).' % type(err).__name__, file=sys.stderr)
        return 1
    for app in result['yenilenen']:
        print('adres-yenile: %s birimleri şimdiki adresle yeniden yazıldı.' % app)
    for item in result['hatalar']:
        print('adres-yenile: HATA %s: %s' % (item['uygulama'], item['hata']), file=sys.stderr)
    if not result['yenilenen'] and not result['hatalar']:
        print('adres-yenile: değişiklik yok.')
    return 1 if result['hatalar'] else 0


if __name__ == '__main__':
    sys.exit(main())
