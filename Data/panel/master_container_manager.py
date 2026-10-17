#!/usr/bin/env python3
"""Ownership-aware inventory, the applications' read model and asynchronous, bounded container jobs.

Reads stay in the panel sandbox. Every write runs this CLI in a separate root transient unit, which
hands it to the dedicated worker (master_container_worker); the request travels on standard input only
and the job's record never holds it.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import uuid

import master_applications as apps
import master_settings as settings
import master_container_config as config
from master_containers import Containers, ContainerError, epoch, listening, name_of, update_status

RESOURCE_ACTIONS = frozenset(('image-pull', 'image-remove', 'volume-create', 'volume-remove', 'network-create', 'network-remove'))
APP_ACTIONS = frozenset(('uygulama-kur', 'uygulama-baslat', 'uygulama-durdur', 'uygulama-yeniden-baslat', 'uygulama-guncelle',
                         'uygulama-tanim', 'uygulama-kaldir', 'uygulama-taslak'))
ACTIONS = RESOURCE_ACTIONS | APP_ACTIONS
JOB_RE = re.compile(r'[0-9a-f]{32}\Z')
# A whole file of up to 256 KiB arrives JSON-escaped in an application's request: at most about 2 MiB.
STDIN_LIMIT = 65536
APP_STDIN_LIMIT = 2 * 1024 * 1024
# An application job may pull several images and waits up to 300 s for them to be ready.
RUNTIME_SECONDS = 900
APP_RUNTIME_SECONDS = 1800
# DD-214: image update checks read registry manifests only and are cached; the page asks on open,
# the operator can ask again. No timer and no automatic update: an update is an explicit operation.
UPDATE_TTL = 6 * 3600
UPDATE_MIN_INTERVAL = 60
# DD-263: a running container's CPU and memory come from its own cgroup v2 files. `podman stats` also
# reads network counters inside each container's network namespace, which the backend's
# RestrictNamespaces forbids; the cgroup files need no namespace and stay readable (read-only) under
# ProtectControlGroups.
CGROUP_ROOT = '/sys/fs/cgroup'
CGROUP_PART_RE = re.compile(r'[A-Za-z0-9_.:@\\-]{1,255}\Z')
CPU_MIN_INTERVAL = 2.0
CPU_SAMPLES = 256


def port_scope(ip, env):
    """DD-217: the access a published host address gives; the guard decides what passes."""
    if ip in ('127.0.0.1', '::1'):
        return 'local'
    if ip and ip in (env.get('TAILSCALE_IPV4'), env.get('TAILSCALE_IPV6')):
        return 'tailscale'
    if ip in ('', '0.0.0.0', '::') or ip in (env.get('WAN_IPV4'), env.get('WAN_IPV6')):
        return 'public'
    return 'other'


def cgroup_dir(raw):
    """The running container's own cgroup directory from `podman inspect` (State.CgroupPath), or None.
    Only plain parts under CGROUP_ROOT, and the last one must carry the container's ID (libpod-<id>.scope,
    quadlet's libpod-payload-<id>): a wider cgroup is never read as the container's."""
    ident, path = raw.get('Id'), (raw.get('State') or {}).get('CgroupPath')
    if not isinstance(ident, str) or not re.fullmatch(r'[0-9a-f]{64}', ident) or not isinstance(path, str) or len(path) > 1024:
        return None
    parts = path.split('/')
    if parts[0] or any(p in ('.', '..') or not CGROUP_PART_RE.fullmatch(p) for p in parts[1:]) or ident not in parts[-1]:
        return None
    return os.path.join(CGROUP_ROOT, *parts[1:])


def cgroup_read(directory, name, limit):
    """A cgroup file's text: a regular file reached without following a symlink, at most `limit` bytes."""
    return settings.read_regular(os.path.join(directory, name), limit)[0].decode('ascii')


def flat_keyed(text):
    """cpu.stat and memory.stat lines ("usage_usec 123") as {key: int}."""
    return {k: int(v) for k, _, v in (line.partition(' ') for line in text.splitlines()) if v.isdigit()}


def app_error(err):
    return ContainerError(err.status, str(err))


class Inventory(Containers):
    def __init__(self, service):
        super().__init__(lambda argv, timeout: service.panel.run_tool(argv, timeout=timeout))
        self.service = service
        self.env = settings.env_read(service.panel.args.state)
        self.env['STATE_FILE'] = str(service.panel.args.state)  # as the worker reads it (the units' --state)
        self.cache = {}
        self.unread = set()

    def podman(self, *args, timeout=20):
        if args not in self.cache:
            self.cache[args] = super().podman(*args, timeout=timeout)
        return self.cache[args]

    def inspect(self, name):
        ok, raw, _ = self.podman('inspect', '--type', 'container', name)
        try:
            return json.loads(raw)[0] if ok else None
        except (ValueError, TypeError, IndexError):
            return None

    def records(self):
        try:
            return apps.Records(self.env) if self.env.get('UYGULAMA_STATE_DIR') else None
        except config.ContainerConfigError as err:
            raise app_error(err) from err

    def usage(self, name, raw):
        """DD-263: (cpu_percent, memory_bytes) of a running container from its cgroup; None where unknown.
        Memory is memory.current less the inactive file cache, as `docker stats` counts it; CPU is the
        percent of one core since the previous reading. A file that cannot be read names the container."""
        directory, cpu, memory = cgroup_dir(raw) if raw else None, None, None
        if not directory:
            self.unread.add(name)
            return cpu, memory
        try:
            current = int(cgroup_read(directory, 'memory.current', 64))
            memory = max(current - flat_keyed(cgroup_read(directory, 'memory.stat', 16384))['inactive_file'], 0)
        except (OSError, ValueError, KeyError, settings.SettingsError):
            self.unread.add(name)
        try:
            usec = flat_keyed(cgroup_read(directory, 'cpu.stat', 4096))['usage_usec']
            cpu = self.service.cpu_percent((raw['Id'], str((raw.get('State') or {}).get('StartedAt'))), usec, time.monotonic())
        except (OSError, ValueError, KeyError, settings.SettingsError):
            self.unread.add(name)
        return cpu, memory

    def decorate(self, row):
        """A Podman row as Gelişmiş shows it: who manages it, its resource use, the sockets of a host-network
        container (DD-215). No action: an application is managed on its own page."""
        name = row['name']
        row.update(live=bool(row.get('id')), source='external', uygulama=None, cpu_percent=None, memory_bytes=None,
                   busy=None, health=row.get('health', ''), listening=None)
        raw = self.inspect(name) if row['live'] else None
        if raw:
            row['health'] = ((raw.get('State') or {}).get('Health') or {}).get('Status') or row['health']
            if config.ownership(raw) == apps.MANAGED:
                app = ((raw.get('Config') or {}).get('Labels') or {}).get(apps.APP_LABEL)
                row.update(source=apps.MANAGED, uygulama=app, busy=self.service.busy(app))
        running = row.get('state') == 'running'
        # DD-215: no port mappings on the host network; show the sockets the container listens on.
        if raw and running and (raw.get('HostConfig') or {}).get('NetworkMode') == 'host':
            addresses = lambda *keys: {self.env.get(k, '') for k in keys} - {''}
            row['listening'] = listening((raw.get('State') or {}).get('Pid'), wan=addresses('WAN_IPV4', 'WAN_IPV6'),
                                         tailscale=addresses('TAILSCALE_IPV4', 'TAILSCALE_IPV6'))
        if row['live'] and running:
            row['cpu_percent'], row['memory_bytes'] = self.usage(name, raw)
        for port in row.get('ports') or []:
            if isinstance(port, dict):
                port['scope'] = port_scope(port.get('host_ip', ''), self.env)
        return row

    def app_uses(self):
        """Images and networks the application records name (a stopped application still uses them)."""
        uses = {'image': {}, 'network': {}}
        records = self.records()
        if records is None:
            return uses
        try:
            for app in records.names():
                record = records.load(app)
                for image in record['places']['images'].values():
                    uses['image'].setdefault(image, set()).add(app)
                uses['network'].setdefault(apps.names(app, record['definition'])['network'], set()).add(app)
        except config.ContainerConfigError as err:
            raise app_error(err) from err
        return uses

    def liste(self):
        answer = super().liste()
        rows = {r['name']: r for r in answer['containers']}
        answer['containers'] = [self.decorate(row) for row in rows.values()]
        answer['resource_errors'] = {}
        answer['volumes'], answer['networks'] = [], []
        if not answer['runtime']['ok']:
            answer['resource_errors'] = {k: answer['runtime']['error'] for k in ('images', 'volumes', 'networks', 'stats')}
            return answer
        if self.unread:
            answer['resource_errors']['stats'] = 'Kaynak kullanımı okunamadı: ' + ', '.join(sorted(self.unread)) + '.'
        raw_details = [self.inspect(n) for n, r in rows.items() if r.get('id')]
        uses = {'image': {}, 'volume': {}, 'network': {}}
        for r in raw_details:
            if not r:
                continue
            name = str(r.get('Name', '')).lstrip('/')
            for image in (r.get('Image'), r.get('ImageName')):
                if image:
                    uses['image'].setdefault(image, set()).add(name)
            for m in r.get('Mounts') or []:
                if m.get('Type') == 'volume':
                    uses['volume'].setdefault(m.get('Name', ''), set()).add(name)
            for network in (r.get('NetworkSettings') or {}).get('Networks') or {}:
                uses['network'].setdefault(network, set()).add(name)
        try:
            recorded = self.app_uses()
        except ContainerError as err:
            answer['resource_errors']['images'] = str(err)
            recorded = {'image': {}, 'network': {}}
        for kind in ('image', 'network'):
            for key, users in recorded[kind].items():
                uses[kind].setdefault(key, set()).update(users)
        ok, images, error = self.podman('images', '--format', 'json')
        if ok and isinstance(images, list):
            answer['images'] = []
            for i in images:
                refs = i.get('Names') or i.get('names') or i.get('RepoTags') or ['<adsız>']
                ident = i.get('Id') or i.get('ID') or i.get('id') or ''
                digests = set(i.get('RepoDigests') or i.get('repoDigests') or [])
                digest = i.get('Digest') or i.get('digest') or ''
                if re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
                    for ref in refs:
                        repo = ref.split('@')[0]
                        if ':' in repo.rsplit('/', 1)[-1]:
                            repo = repo.rsplit(':', 1)[0]
                        digests.add(repo + '@' + digest)
                users = set(uses['image'].get(ident, []))
                for ref in set(refs) | digests:
                    users.update(uses['image'].get(ref, []))
                for ref in refs:
                    answer['images'].append({'id': ident, 'name': ref, 'size': i.get('Size', i.get('size')),
                                             'created': epoch(i.get('Created', i.get('created'))),
                                             'used_by': sorted(users), 'managed': True})
        else:
            answer['resource_errors']['images'] = 'İmajlar okunamadı: ' + error
        for kind, command in (('volumes', 'volume'), ('networks', 'network')):
            ok, resources, error = self.podman(command, 'ls', '--format', 'json')
            if not ok or not isinstance(resources, list):
                answer['resource_errors'][kind] = ('Birimler' if kind == 'volumes' else 'Ağlar') + ' okunamadı: ' + error
                continue
            for r in resources:
                name = r.get('Name') or r.get('name') or ''
                if not name:
                    continue
                labels = r.get('Labels') or r.get('labels') or {}
                row = {'name': name, 'driver': r.get('Driver') or r.get('driver') or '',
                       'used_by': sorted(uses['volume' if kind == 'volumes' else 'network'].get(name, [])),
                       'managed': labels.get(config.MANAGED_LABEL) in ('konsol', apps.MANAGED)}
                if kind == 'volumes':
                    row['size'] = None
                else:
                    subnets = r.get('Subnets') or r.get('subnets') or []
                    row.update(id=r.get('Id') or r.get('id') or '',
                               subnets=[s.get('subnet', '') if isinstance(s, dict) else str(s) for s in subnets],
                               internal=bool(r.get('Internal') or r.get('internal')))
                answer[kind].append(row)
        return answer

    def reach(self):
        """DD-259: Erişim's view of the containers: whose each is, whether it runs and the scope of each
        published port (the container guard admits exactly these, DD-217). One `podman ps`; no stats,
        images or inspect."""
        runtime = self.runtime()
        found = []
        if runtime['ok']:
            ok, found, message = self.ps()
            if not ok:
                runtime = {'version': runtime['version'], 'ok': False, 'error': 'Konteynerler okunamadı: %s' % message}
        items = []
        for row in sorted(found, key=lambda r: r['name']):
            app = row.get('uygulama') or None
            items.append({'name': row['name'], 'source': apps.MANAGED if app else 'external', 'uygulama': app,
                          'state': row['state'], 'live': True,
                          'ports': [dict(p, scope=port_scope(p.get('host_ip', ''), self.env)) for p in row['ports']]})
        return {'runtime': runtime, 'containers': items}

    def ayrinti(self, name):
        name_of(name)
        return self.decorate(super().ayrinti(name))

    # -- applications (rebuild DD-271, phase 3)
    def units(self, names):
        """{unit: ActiveState} in one systemctl call."""
        if not names:
            return {}
        rc, out, _ = self.run(['systemctl', 'show', '--no-pager', '--property=Id,ActiveState', *sorted(names)], 20)
        if rc != 0:
            raise ContainerError(502, 'Uygulama birimlerinin durumu okunamadı.')
        states = {}
        for block in out.strip().split('\n\n'):
            props = dict(line.split('=', 1) for line in block.splitlines() if '=' in line)
            if props.get('Id'):
                states[props['Id']] = props.get('ActiveState', '')
        return states

    def app_records(self, errors):
        """Every application's record with its object names; a record that cannot be read is an error line
        (or, while a job works on it, left to that job)."""
        records = self.records()
        out = []
        if records is None:
            return out
        try:
            names = records.names()
        except config.ContainerConfigError as err:
            errors.append(str(err))
            return out
        for app in names:
            try:
                record = records.load(app)
                out.append((record, apps.names(app, record['definition'])))
            except config.ContainerConfigError as err:
                if not self.service.busy(app):
                    errors.append('%s: %s' % (app, err))
        return out

    def live(self, loaded):
        rows = {}
        ok, found, _ = self.ps() if self.runtime()['ok'] else (False, [], '')
        if ok:
            rows = {r['name']: r for r in found}
        units = self.units({u for _record, objects in loaded for u in objects['units'].values()})
        usage = {}
        for _record, objects in loaded:
            for container in objects['containers'].values():
                if rows.get(container, {}).get('state') == 'running':
                    usage[container] = self.usage(container, self.inspect(container))
        return {'containers': rows, 'units': units, 'usage': usage}

    def sources(self):
        """Standalone containers an application can be made from (K2): nothing but Podman manages them."""
        if not self.runtime()['ok']:
            return []
        ok, found, _ = self.ps()
        out = []
        for row in found if ok else []:
            if row.get('uygulama'):
                continue
            raw = self.inspect(row['name'])
            if raw and config.ownership(raw) == 'standalone':
                out.append({'ad': row['name'], 'imaj': str(row.get('image') or ''), 'durum': str(row.get('state') or '')})
        return sorted(out, key=lambda r: r['ad'])

    def applications(self):
        """GET /api/konsol/uygulamalar: every application from its record with its live state."""
        errors = []
        runtime = self.runtime()
        if not runtime['ok']:
            errors.append(runtime['error'])
        loaded = self.app_records(errors)
        live = self.live(loaded)
        items = [apps.summary(record, objects, live, self.service.busy(record['name']), self.service.update_of(record['name']))
                 for record, objects in loaded]
        if self.unread:
            errors.append('Kaynak kullanımı okunamadı: ' + ', '.join(sorted(self.unread)) + '.')
        images, volumes, networks = [], [], []
        if runtime['ok']:
            listed = [self.podman(*args) for args in (('images', '--format', 'json'), ('volume', 'ls', '--format', 'json'),
                                                      ('network', 'ls', '--format', 'json'))]
            images, volumes, networks = [value if ok and isinstance(value, list) else [] for ok, value, _ in listed]
        # An image is used when a container runs from it or an application's record pins it.
        used = {i for record, _o in loaded for i in record['places']['images'].values()}
        used |= {str(row.get('image') or '') for row in live['containers'].values()}
        images = [i for i in images if isinstance(i, dict)]
        unused = sum(1 for i in images if not (set(i.get('Names') or []) | set(i.get('RepoDigests') or [])) & used)
        return {'read_at': int(time.time()), 'items': items, 'kaynaklar': self.sources(),
                'altyapi': {'podman': runtime['version'], 'calisiyor': runtime['ok'], 'imaj': len(images),
                            'kullanilmayan_imaj': unused, 'birim': len(volumes), 'ag': len(networks)},
                'hatalar': errors}

    def application(self, app):
        """GET /api/konsol/uygulamalar/{app}."""
        record = self.record(app)
        try:
            objects = apps.names(app, record['definition'])
        except config.ContainerConfigError as err:
            raise app_error(err) from err
        live = self.live([(record, objects)])
        inspected = {c: self.inspect(c) for c in objects['containers'].values() if c in live['containers']}
        return apps.detail(self.env, record, objects, live, self.service.busy(app), self.service.update_of(app), inspected)

    def journal(self, app, service, lines):
        """An application service's log: its unit's journal (DD-251), as written."""
        record = self.record(app)
        try:
            objects = apps.names(app, record['definition'])
        except config.ContainerConfigError as err:
            raise app_error(err) from err
        if service not in objects['units']:
            raise ContainerError(404, 'Bu uygulamada böyle bir servis yok.')
        tail = int(lines) if str(lines).isdigit() and int(lines) in apps.TAILS else 200
        rc, text, _ = self.run(['journalctl', '-u', objects['units'][service], '-n', str(tail), '--no-pager', '-o', 'short-iso'], 30)
        if rc:
            raise ContainerError(502, 'Uygulama günlüğü okunamadı.')
        rows = [line for line in text.splitlines() if line.strip()]
        return {'satirlar': rows[-tail:], 'kesik': len(rows) >= tail}

    def record(self, app):
        records = self.records()
        if records is None or not records.exists(app):
            raise ContainerError(404, 'Uygulama bulunamadı.')
        try:
            return records.load(app)
        except config.ContainerConfigError as err:
            raise app_error(err) from err

    def version(self):
        runtime = self.runtime()
        if not runtime['ok']:
            raise ContainerError(503, runtime['error'])
        try:
            return apps.podman_version(runtime['version'])
        except config.ContainerConfigError as err:
            raise app_error(err) from err

    def definition_plan(self, app, text, answers):
        """POST …/{app}/tanim with plan: the inspection, the answers' errors or what the edit changes. Nothing
        is written, pulled or created; secret values are checked and dropped."""
        import master_inspector
        record = self.record(app)
        try:
            apps.checked_text(text)
        except config.ContainerConfigError as err:
            raise app_error(err) from err
        inspection = master_inspector.inspect(text)
        if inspection.get('refusals') or inspection.get('format') is None:
            return {'inceleme': inspection}
        definition, _values, errors = master_inspector.check(inspection, answers,
                                                             existing_secrets=frozenset(record['places']['secrets']))
        if errors:
            return {'inceleme': inspection, 'hatalar': errors}
        if definition['name'] != app:
            return {'inceleme': inspection, 'hatalar': {'name': 'Uygulamanın adı değiştirilemez; başka bir adla yeni bir uygulama ekleyin.'}}
        try:
            ports = apps.allocate(self.env, app, definition, record['places']['ports'], self.records())
            fark = apps.edit_plan(self.env, record, inspection, definition, ports, self.version())
        except config.ContainerConfigError as err:
            raise app_error(err) from err
        return {'inceleme': inspection, 'fark': fark}

    def container_draft(self, name):
        """POST …/kaynak {"tur": "konteyner"}: the draft of a standalone container; nothing is written."""
        raw = self.inspect(name_of(name))
        if raw is None:
            raise ContainerError(404, 'Konteyner bulunamadı.')
        if config.ownership(raw) != 'standalone':
            raise ContainerError(409, 'Bu konteyner başka bir yöneticiye ait; taslak çıkarılamaz.')
        ok, image, _ = self.podman('image', 'inspect', str(raw.get('Image') or raw.get('ImageName') or ''))
        try:
            base = json.loads(image)[0] if ok else {}
        except (ValueError, TypeError, IndexError):
            base = {}
        return apps.container_draft(raw, base)


class Service:
    def __init__(self, panel):
        self.panel = panel
        self.lock = threading.Lock()
        self.jobs = {}
        self.update_lock = threading.Lock()
        self.update_items = {}
        self.update_at = 0.0
        self.cpu_samples = {}

    def cpu_percent(self, key, usage, now):
        """DD-263: percent of one CPU core between two readings of the same container run (key: its ID and
        start time); None for the first. A reading closer than CPU_MIN_INTERVAL to the last one repeats its
        figure, so the list and the detail asked together agree. A counter that went back starts over."""
        with self.lock:
            last = self.cpu_samples.get(key)
            if last and usage >= last[0] and now - last[1] < CPU_MIN_INTERVAL:
                return last[2]
            value = round((usage - last[0]) / (now - last[1]) / 1e4, 2) if last and usage >= last[0] else None
            self.cpu_samples.pop(key, None)
            self.cpu_samples[key] = (usage, now, value)
            if len(self.cpu_samples) > CPU_SAMPLES:
                del self.cpu_samples[next(iter(self.cpu_samples))]
            return value

    def update_of(self, app):
        """{service: {state, channel, error}} of the cached check, or None."""
        with self.lock:
            value = self.update_items.get(app)
            return copy.deepcopy(value) if value else None

    def updates(self, force=False):
        """DD-214: per application and service, cached; registry manifests only, never a pull."""
        with self.update_lock:
            age = time.time() - self.update_at
            if self.update_at and age < UPDATE_MIN_INTERVAL or (self.update_at and age < UPDATE_TTL and not force):
                with self.lock:
                    items = copy.deepcopy(self.update_items)
                return {'checked_at': int(self.update_at), 'items': items, 'cached': True}
            view = self.view()
            run = lambda argv, timeout: self.panel.run_tool(argv, timeout=timeout)
            rc, arch, _ = run(['podman', 'info', '--format', '{{.Host.Arch}}'], 20)
            arch = arch.strip()
            items = {}
            for record, _objects in view.app_records([]):
                services = {}
                for svc in record['definition']['services']:
                    pinned = record['places']['images'].get(svc['name'], '')
                    follow = apps.channel(svc['image'])
                    services[svc['name']] = update_status(run, pinned, follow, arch) if rc == 0 and arch else \
                        {'state': 'denetlenemedi', 'channel': follow, 'candidate': '', 'error': 'Podman yanıt vermedi.'}
                    services[svc['name']].pop('candidate', None)
                items[record['name']] = services
            now = time.time()
            with self.lock:
                self.update_items, self.update_at = items, now
            return {'checked_at': int(now), 'items': copy.deepcopy(items), 'cached': False}

    def forget_updates(self):
        """An image change makes the cached answer stale; the next view asks the registry again."""
        with self.lock:
            self.update_items, self.update_at = {}, 0.0

    def view(self):
        try:
            return Inventory(self)
        except (OSError, ValueError, KeyError, settings.SettingsError) as err:
            raise ContainerError(503, 'Konteyner yönetim kayıtları okunamadı.') from err

    def busy(self, name):
        with self.lock:
            return next((j['id'] for j in self.jobs.values() if j.get('name') == name and j['state'] == 'running'), None)

    def operation(self, ident):
        if not isinstance(ident, str) or not JOB_RE.fullmatch(ident):
            raise ContainerError(400, 'İşlem kimliği geçersiz.')
        env = settings.env_read(self.panel.args.state)
        value = None
        if env.get('KONTEYNER_STATE_DIR'):
            path = Path(env['KONTEYNER_STATE_DIR']) / 'operations' / (ident + '.json')
            try:
                value = config.read_private(path)
            except config.ContainerConfigError as err:
                # The worker reserves the id with an empty file before it writes its first step; a read in
                # that moment is the job starting, which the in-memory record below answers.
                try:
                    reserved = os.lstat(path).st_size == 0
                except OSError:
                    reserved = False
                if not reserved:
                    raise ContainerError(err.status, str(err)) from err
        if value:
            if value.get('state') == 'running':
                # The transient service is the executor. SIGKILL/timeout cannot write a final
                # JSON record; do not keep a browser spinning forever on that stale record.
                rc, _, _ = self.panel.run_tool(['systemctl', 'is-active', '--quiet', 'master-container-' + ident + '.service'], timeout=10)
                if rc in (3, 4):
                    value = dict(value, state='failed', status=502, updated_at=int(time.time()),
                                 error='İşlem son yanıtı yazmadan durdu; yeniden denemeden önce gerçek konteyner durumunu kontrol edin.')
            with self.lock:
                self.jobs[ident] = value
            return value
        with self.lock:
            value = copy.deepcopy(self.jobs.get(ident))
        if value:
            return value
        raise ContainerError(404, 'İşlem bulunamadı; konteyner durumunu yenileyin.')

    def submit(self, data):
        """Gelişmiş's Podman resource jobs (until phase 5)."""
        if not isinstance(data, dict) or data.get('action') not in RESOURCE_ACTIONS:
            raise ContainerError(400, 'Konteyner işlemi geçersiz.')
        action = data['action']
        request = {k: v for k, v in data.items() if k != 'action'}
        name = request.get('name') or request.get('image') or ''
        if not isinstance(name, str) or not name or len(name) > 512:
            raise ContainerError(400, 'İşlem hedefi gerekli.')
        if action in ('image-pull', 'image-remove'):
            try:
                if action == 'image-remove' and re.fullmatch(r'[0-9a-f]{64}', name):
                    request['image'] = 'sha256:' + name
                elif not (action == 'image-remove' and re.fullmatch(r'sha256:[0-9a-f]{64}', name)):
                    config.image_of(name)
            except config.ContainerConfigError as err:
                raise ContainerError(err.status, str(err)) from err
        else:
            name_of(name)
        return self.launch(action, name, request)

    def submit_app(self, action, name, request):
        """An application job: the request (a file, answers, secret values) goes to the worker's standard
        input only; the job names the application."""
        if action not in APP_ACTIONS or not isinstance(request, dict):
            raise ContainerError(400, 'Uygulama işlemi geçersiz.')
        if action == 'uygulama-taslak':
            try:
                apps.image_ref(name)
            except config.ContainerConfigError as err:
                raise ContainerError(err.status, str(err)) from err
        elif not isinstance(name, str) or not apps.APP_NAME_RE.fullmatch(name):
            raise ContainerError(400, 'Uygulama adı geçersiz.')
        return self.launch(action, name, dict(request, name=name))

    def launch(self, action, name, request):
        ident = uuid.uuid4().hex
        with self.lock:
            if any(j['state'] == 'running' and j.get('name') == name for j in self.jobs.values()):
                raise ContainerError(409, 'Bu hedefte bir işlem sürüyor.')
            active = sum(j['state'] == 'running' for j in self.jobs.values())
            if active >= 4:
                raise ContainerError(409, 'İşlem sınırına ulaşıldı; süren işlemlerin bitmesini bekleyin.')
            # The in-memory job names its target; the request never stays here.
            job = {'id': ident, 'action': action, 'name': name, 'state': 'running', 'step': 'Başlatılıyor', 'updated_at': int(time.time())}
            self.jobs[ident] = job
            # Retain a bounded in-memory dispatch cache. Durable results live in private files.
            for key in list(self.jobs):
                if len(self.jobs) <= 256:
                    break
                if self.jobs[key]['state'] != 'running':
                    del self.jobs[key]
        self._launch(ident, action, request)
        return dict(job)

    def _launch(self, ident, action, data):
        threading.Thread(target=self._execute, args=(ident, action, data), daemon=True).start()

    def _execute(self, ident, action, data):
        seconds = APP_RUNTIME_SECONDS if action in APP_ACTIONS else RUNTIME_SECONDS
        argv = ['systemd-run', '--unit=master-container-' + ident, '--quiet', '--wait', '--pipe', '--collect',
                '--property=UMask=0077', '--property=RuntimeMaxSec=%d' % seconds, '--setenv=PYTHONDONTWRITEBYTECODE=1',
                '/usr/bin/python3', str(Path(__file__).resolve()), '--state', self.panel.args.state, '--operation', ident, action]
        try:
            p = subprocess.run(argv, input=json.dumps(data), capture_output=True, text=True, timeout=seconds + 10, env=self.panel.env())
            result = json.loads(p.stdout)
            if not isinstance(result, dict):
                raise ValueError('worker response')
            # The worker writes the terminal durable record; preserve its truth even if stderr is noisy.
            value = self.operation(ident)
            if value['state'] == 'running':
                value.update(state='failed' if p.returncode else 'done', result=result if not p.returncode else None,
                             error=result.get('error', 'İşlem başarısız.') if p.returncode else None, updated_at=int(time.time()))
        except (OSError, subprocess.TimeoutExpired, ValueError, ContainerError):
            with self.lock:
                value = dict(self.jobs[ident])
            value.update(state='failed', error='İşlem sonucu alınamadı; yeniden denemeden önce konteyner durumunu yenileyin.',
                         updated_at=int(time.time()))
        with self.lock:
            self.jobs[ident] = value
        if action in APP_ACTIONS and action not in ('uygulama-taslak',) and value.get('state') == 'done':
            self.forget_updates()
        self.panel.settings_cache = (0, None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--operation', required=True)
    parser.add_argument('action', choices=sorted(ACTIONS))
    args = parser.parse_args()
    try:
        if not JOB_RE.fullmatch(args.operation):
            raise ContainerError(400, 'İşlem kimliği geçersiz.')
        limit = APP_STDIN_LIMIT if args.action in APP_ACTIONS else STDIN_LIMIT
        raw = sys.stdin.read(limit + 1)
        if len(raw) > limit:
            raise ContainerError(400, 'İstek çok büyük.')
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ContainerError(400, 'İstek nesne olmalı.')
        from master_container_worker import Manager
        result = Manager(args.state).execute(args.action, request, args.operation)
        print(json.dumps(result, ensure_ascii=False))
    except Exception as err:
        expected = isinstance(err, (ContainerError, config.ContainerConfigError, settings.SettingsError)) or hasattr(err, 'status')
        print(json.dumps({'error': str(err) if expected else 'Konteyner işlemi tamamlanamadı.',
                          'status': getattr(err, 'status', 500)}, ensure_ascii=False))
        sys.exit(1)


if __name__ == '__main__':
    main()
