#!/usr/bin/env python3
"""Ownership-aware inventory and asynchronous, bounded container operations.

Reads stay in the panel sandbox. Every write runs this CLI in a separate root transient unit, which
hands it to the dedicated worker (master_container_worker).
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

import master_settings as settings
import master_container_config as config
from master_containers import Containers, ContainerError, epoch, listening, name_of, TAILS, update_status

ACTIONS = frozenset(('create', 'save', 'start', 'stop', 'restart', 'remove', 'adopt', 'image-pull',
                     'image-remove', 'image-update', 'volume-create', 'volume-remove', 'network-create', 'network-remove'))
JOB_RE = re.compile(r'[0-9a-f]{32}\Z')
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


def definition_row(d):
    return {'id': '', 'name': d['name'], 'image': d['image'], 'state': 'stopped', 'status': '',
            'unit': 'konsol-' + d['name'] + '.service', 'network': d.get('network', ''),
            'ports': [], 'mounts': len(d.get('mounts', [])), 'created': None, 'started': None,
            'finished': None, 'exit_code': 0, 'restarts': 0, 'health': ''}


def definition_ports(d, env):
    """A stopped definition's publications as podman would show them."""
    return [{'host_ip': {'local':'127.0.0.1','tailscale':env.get('TAILSCALE_IPV4',''),'public':'0.0.0.0'}[p['scope']],
             **{k:p[k] for k in ('host_port','container_port','protocol')}} for p in d.get('ports', [])]


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


class Inventory(Containers):
    def __init__(self, service):
        super().__init__(lambda argv, timeout: service.panel.run_tool(argv, timeout=timeout))
        self.service = service
        self.env = settings.env_read(service.panel.args.state)
        try:
            self.definitions = {d['name']: d for d in config.Store(self.env).list()} if self.env.get('KONTEYNER_STATE_DIR') else {}
        except config.ContainerConfigError as err:
            raise ContainerError(err.status, str(err)) from err
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

    def decorate(self, row, details=False):
        name = row['name']
        d = self.definitions.get(name)
        row.update(live=bool(row.get('id')), source='external', management_id='external:' + name,
                   revision=None, actions=[], restricted_reason='',
                   cpu_percent=None, memory_bytes=None, busy=self.service.busy(name), health=row.get('health', ''), listening=None)
        raw = self.inspect(name) if row['live'] else None
        if raw:
            row['health'] = ((raw.get('State') or {}).get('Health') or {}).get('Status') or row['health']
        running = row.get('state') == 'running'
        # DD-215: no port mappings on the host network; show the sockets the container listens on.
        if raw and running and (raw.get('HostConfig') or {}).get('NetworkMode') == 'host':
            addresses = lambda *keys: {self.env.get(k, '') for k in keys} - {''}
            row['listening'] = listening((raw.get('State') or {}).get('Pid'), wan=addresses('WAN_IPV4', 'WAN_IPV6'),
                                         tailscale=addresses('TAILSCALE_IPV4', 'TAILSCALE_IPV6'))
        if row['live'] and running:
            row['cpu_percent'], row['memory_bytes'] = self.usage(name, raw)
        lifecycle = ['stop', 'restart'] if running else ['start']
        if d:
            row.update(source='konsol', management_id='konsol:' + name, revision=d['revision'],
                       unit='konsol-' + name + '.service', actions=lifecycle + ['save', 'remove', 'image-update'],
                       effective_autostart=bool(d.get('autostart') and not d.get('manual_stop')))
            if not row['live']:
                row['ports'] = definition_ports(d, self.env)
            if details:
                row.update(config=config.redact(d), editable=['ports','mounts','environment','command','autostart','restart','cpus','memory','image','network','user'], protected_mounts=[])
                if not row['live']:
                    row['mounts'] = [{'type':m['type'], 'source':m['source'], 'destination':m['destination'],
                                      'rw':not m['read_only'], 'name':m['source'] if m['type']=='volume' else ''} for m in d.get('mounts', [])]
        else:
            if raw:
                own = config.ownership(raw)
                # Worker repeats discovery under its mutation lock; the view is not authority.
                standalone = own == 'standalone' or (isinstance(own, dict) and own.get('kind') == 'standalone')
                if standalone:
                    row['actions'] = lifecycle + ['remove','adopt']
                else:
                    row['restricted_reason'] = 'Konteyner başka bir yöneticiye ait veya desteklenmeyen seçenekler kullanıyor.'
            else:
                row['restricted_reason'] = 'Konteynerin yönetim kaynağı doğrulanamadı; listeyi yenileyin.'
        if row['live'] and d:
            if not (raw and config.ownership(raw) == 'konsol'):
                row['actions'] = []
                row['restricted_reason'] = 'Bu adın çalışan konteyneri kayıtlı yöneticiyle eşleşmiyor; işlem yapılmadı.'
        if row['live'] and row['state'] not in ('running','stopped','exited','created','configured'):
            row['actions'] = []
            row['restricted_reason'] = 'Konteyner duraklatılmış veya geçiş durumunda; önce asıl yöneticisinden durumunu düzeltin.'
        row['update'] = self.service.update_of(name) if d else None
        for port in row.get('ports') or []:
            if isinstance(port, dict):
                port['scope'] = port_scope(port.get('host_ip', ''), self.env)
        return row

    def liste(self):
        answer = super().liste()
        rows = {r['name']: r for r in answer['containers']}
        for name, d in self.definitions.items():
            rows.setdefault(name, definition_row(d))
        answer['containers'] = [self.decorate(row) for row in rows.values()]
        answer['storage']['containers'] = len(rows)
        answer['resource_errors'] = {}
        answer['volumes'], answer['networks'] = [], []
        if not answer['runtime']['ok']:
            answer['resource_errors'] = {k:answer['runtime']['error'] for k in ('images','volumes','networks','stats')}
            return answer
        if self.unread:
            answer['resource_errors']['stats'] = 'Kaynak kullanımı okunamadı: ' + ', '.join(sorted(self.unread)) + '.'
        raw_details = [self.inspect(n) for n,r in rows.items() if r.get('id')]
        uses = {'image':{},'volume':{},'network':{}}
        for r in raw_details:
            if not r: continue
            name = str(r.get('Name','')).lstrip('/')
            for image in (r.get('Image'),r.get('ImageName')):
                if image: uses['image'].setdefault(image,set()).add(name)
            for m in r.get('Mounts') or []:
                if m.get('Type') == 'volume': uses['volume'].setdefault(m.get('Name',''),set()).add(name)
            for network in (r.get('NetworkSettings') or {}).get('Networks') or {}:
                uses['network'].setdefault(network,set()).add(name)
        for d in self.definitions.values():
            uses['image'].setdefault(d['image'],set()).add(d['name'])
            network=d.get('network','')
            if network=='bridge': network=self.env.get('KONTEYNER_NETWORK','')
            uses['network'].setdefault(network,set()).add(d['name'])
            for m in d.get('mounts',[]):
                if m['type']=='volume': uses['volume'].setdefault(m['source'],set()).add(d['name'])
        ok, images, error = self.podman('images','--format','json')
        if ok and isinstance(images,list):
            answer['images'] = []
            for i in images:
                refs = i.get('Names') or i.get('names') or i.get('RepoTags') or ['<adsız>']
                ident = i.get('Id') or i.get('ID') or i.get('id') or ''
                digests = set(i.get('RepoDigests') or i.get('repoDigests') or [])
                digest = i.get('Digest') or i.get('digest') or ''
                if re.fullmatch(r'sha256:[0-9a-f]{64}',digest):
                    for ref in refs:
                        repo=ref.split('@')[0]
                        if ':' in repo.rsplit('/',1)[-1]: repo=repo.rsplit(':',1)[0]
                        digests.add(repo+'@'+digest)
                users = set(uses['image'].get(ident,[]))
                for ref in set(refs)|digests: users.update(uses['image'].get(ref,[]))
                for ref in refs:
                    answer['images'].append({'id':ident,'name':ref,'size':i.get('Size',i.get('size')),'created':epoch(i.get('Created',i.get('created'))),
                                              'used_by':sorted(users),'managed':True})
        else: answer['resource_errors']['images'] = 'İmajlar okunamadı: ' + error
        for kind, command in (('volumes','volume'),('networks','network')):
            ok, resources, error = self.podman(command,'ls','--format','json')
            if not ok or not isinstance(resources,list):
                answer['resource_errors'][kind] = ('Birimler' if kind=='volumes' else 'Ağlar') + ' okunamadı: ' + error
                continue
            for r in resources:
                name=r.get('Name') or r.get('name') or ''
                if not name: continue
                labels=r.get('Labels') or r.get('labels') or {}
                row={'name':name,'driver':r.get('Driver') or r.get('driver') or '',
                     'used_by':sorted(uses['volume' if kind=='volumes' else 'network'].get(name,[])),
                     'managed':labels.get('io.master-stack.managed') == 'konsol'}
                if kind=='volumes': row['size']=None
                else:
                    subnets=r.get('Subnets') or r.get('subnets') or []
                    row.update(id=r.get('Id') or r.get('id') or '',
                               subnets=[s.get('subnet','') if isinstance(s,dict) else str(s) for s in subnets],
                               internal=bool(r.get('Internal') or r.get('internal')))
                answer[kind].append(row)
        return answer

    def reach(self):
        """DD-259: Erişim's view of the containers: who manages each, whether it runs and the scope of
        each published port (the container guard admits exactly these, DD-217). One `podman ps`; no
        stats, images or inspect."""
        runtime = self.runtime()
        found = []
        if runtime['ok']:
            ok, found, message = self.ps()
            if not ok:
                runtime = {'version': runtime['version'], 'ok': False, 'error': 'Konteynerler okunamadı: %s' % message}
        rows = {r['name']: r for r in found}
        items = []
        for name in sorted(set(rows) | set(self.definitions)):
            row, d = rows.get(name), self.definitions.get(name)
            if row:
                state, ports = row['state'], row['ports']
            else:
                state, ports = 'stopped', definition_ports(d, self.env)
            items.append({'name': name, 'source': 'konsol' if d else 'external', 'state': state, 'live': bool(row),
                          'ports': [dict(p, scope=port_scope(p.get('host_ip', ''), self.env)) for p in ports]})
        return {'runtime': runtime, 'containers': items}

    def ayrinti(self,name):
        name_of(name)
        try:
            row=super().ayrinti(name)
        except ContainerError as err:
            if err.status!=404: raise
            if name in self.definitions: row=definition_row(self.definitions[name])
            else: raise
        return self.decorate(row,True)

    # DD-251: a Konsol container is a systemd unit whose output goes to the journal, so its log is that
    # unit's journal: every start, restart and re-creation, as it was written. Any other container has
    # only its own `podman logs`.
    def gunluk(self,name,tail):
        name_of(name)
        if name in self.definitions: unit='konsol-'+name+'.service'
        else: return super().gunluk(name,tail)
        tail=int(tail) if str(tail).isdigit() and int(tail) in TAILS else 200
        rc,text,_=self.run(['journalctl','-u',unit,'-n',str(tail),'--no-pager','-o','short-iso'],30)
        if rc: raise ContainerError(502,'Konteyner günlüğü okunamadı.')
        lines=[l for l in text.splitlines() if l.strip()]
        return {'name':name,'lines':lines[-tail:],'truncated':len(lines)>=tail}


class Service:
    def __init__(self,panel):
        self.panel=panel
        self.lock=threading.Lock()
        self.jobs={}
        self.update_lock=threading.Lock()
        self.update_items={}
        self.update_at=0.0
        self.cpu_samples={}

    def cpu_percent(self,key,usage,now):
        """DD-263: percent of one CPU core between two readings of the same container run (key: its ID and
        start time); None for the first. A reading closer than CPU_MIN_INTERVAL to the last one repeats its
        figure, so the list and the detail asked together agree. A counter that went back starts over."""
        with self.lock:
            last=self.cpu_samples.get(key)
            if last and usage>=last[0] and now-last[1]<CPU_MIN_INTERVAL:
                return last[2]
            value=round((usage-last[0])/(now-last[1])/1e4,2) if last and usage>=last[0] else None
            self.cpu_samples.pop(key,None)
            self.cpu_samples[key]=(usage,now,value)
            if len(self.cpu_samples)>CPU_SAMPLES:
                del self.cpu_samples[next(iter(self.cpu_samples))]
            return value

    def update_of(self,name):
        with self.lock:
            value=self.update_items.get(name)
            return dict(value,checked_at=int(self.update_at)) if value else None

    def updates(self,force=False):
        """DD-214: per-container update status, cached; registry manifests only, never a pull."""
        with self.update_lock:
            age=time.time()-self.update_at
            if self.update_at and age<UPDATE_MIN_INTERVAL or (self.update_at and age<UPDATE_TTL and not force):
                with self.lock: items=copy.deepcopy(self.update_items)
                return {'checked_at':int(self.update_at),'items':items,'cached':True}
            view=self.view()
            run=lambda argv,timeout: self.panel.run_tool(argv,timeout=timeout)
            rc,arch,_=run(['podman','info','--format','{{.Host.Arch}}'],20)
            arch=arch.strip()
            items={}
            for name,d in view.definitions.items():
                ref=d.get('image_ref') or ''
                items[name]=update_status(run,d['image'],ref if '@' not in ref else '',arch) if rc==0 and arch else \
                    {'state':'denetlenemedi','channel':ref,'candidate':'','error':'Podman yanıt vermedi.'}
            for value in items.values(): value.pop('candidate',None)
            now=time.time()
            with self.lock:
                self.update_items,self.update_at=items,now
            return {'checked_at':int(now),'items':copy.deepcopy(items),'cached':False}

    def forget_updates(self):
        """An image change makes the cached answer stale; the next view asks the registry again."""
        with self.lock:
            self.update_items,self.update_at={},0.0

    def view(self):
        try: return Inventory(self)
        except (OSError,ValueError,KeyError,settings.SettingsError) as err:
            raise ContainerError(503,'Konteyner yönetim kayıtları okunamadı.') from err

    def busy(self,name):
        with self.lock:
            return next((j['id'] for j in self.jobs.values() if j.get('name')==name and j['state']=='running'),None)

    def operation(self,ident):
        if not isinstance(ident,str) or not JOB_RE.fullmatch(ident): raise ContainerError(400,'İşlem kimliği geçersiz.')
        env=settings.env_read(self.panel.args.state)
        value=None
        if env.get('KONTEYNER_STATE_DIR'):
            try: value=config.read_private(Path(env['KONTEYNER_STATE_DIR'])/'operations'/(ident+'.json'))
            except config.ContainerConfigError as err: raise ContainerError(err.status,str(err)) from err
        if value:
            if value.get('state')=='running':
                # The transient service is the executor. SIGKILL/timeout cannot write a final
                # JSON record; do not keep a browser spinning forever on that stale record.
                rc,_,_=self.panel.run_tool(['systemctl','is-active','--quiet','master-container-'+ident+'.service'],timeout=10)
                if rc in (3,4):
                    value=dict(value,state='failed',status=502,updated_at=int(time.time()),
                               error='İşlem son yanıtı yazmadan durdu; yeniden denemeden önce gerçek konteyner durumunu kontrol edin.')
            with self.lock: self.jobs[ident]=value
            return value
        with self.lock: value=copy.deepcopy(self.jobs.get(ident))
        if value: return value
        raise ContainerError(404,'İşlem bulunamadı; konteyner durumunu yenileyin.')

    def submit(self,data):
        if not isinstance(data,dict) or not isinstance(data.get('action'),str) or data['action'] not in ACTIONS:
            raise ContainerError(400,'Konteyner işlemi geçersiz.')
        action=data['action']; request={k:v for k,v in data.items() if k!='action'}
        if 'config' in request and not isinstance(request['config'],dict):
            raise ContainerError(400,'Konteyner ayarı bir nesne olmalı.')
        name=request.get('name') or (request.get('config') or {}).get('name') or request.get('image') or ''
        if not isinstance(name,str) or not name or len(name)>512: raise ContainerError(400,'İşlem hedefi gerekli.')
        if action in ('image-pull','image-remove'):
            try:
                if action=='image-remove' and re.fullmatch(r'[0-9a-f]{64}',name):
                    request['image']='sha256:'+name
                elif not (action=='image-remove' and re.fullmatch(r'sha256:[0-9a-f]{64}',name)):
                    config.image_of(name)
            except config.ContainerConfigError as err: raise ContainerError(err.status,str(err)) from err
        else: name_of(name)
        if action in ('save','start','stop','restart','remove','image-update','adopt'):
            row=self.view().ayrinti(name)
            if action not in row['actions']: raise ContainerError(409,row.get('restricted_reason') or 'Bu işlem konteyner için desteklenmiyor.')
            if row.get('revision') and request.get('revision')!=row['revision']:
                raise ContainerError(409,'Ayarlar değişmiş; sayfayı yenileyip değişiklikleri yeniden inceleyin.')
        ident=uuid.uuid4().hex
        with self.lock:
            if any(j['state']=='running' and j.get('name')==name for j in self.jobs.values()):
                raise ContainerError(409,'Bu hedefte bir işlem sürüyor.')
            active=sum(j['state']=='running' for j in self.jobs.values())
            if active>=4: raise ContainerError(409,'İşlem sınırına ulaşıldı; süren işlemlerin bitmesini bekleyin.')
            job={'id':ident,'action':action,'name':name,'state':'running','step':'Başlatılıyor', 'updated_at':int(time.time())}
            self.jobs[ident]=job
            # Retain a bounded in-memory dispatch cache. Durable results live in private files.
            for key in list(self.jobs):
                if len(self.jobs)<=256: break
                if self.jobs[key]['state']!='running': del self.jobs[key]
        self._launch(ident,action,request)
        return dict(job)

    def _launch(self,ident,action,data):
        threading.Thread(target=self._execute,args=(ident,action,data),daemon=True).start()

    def _execute(self,ident,action,data):
        argv=['systemd-run','--unit=master-container-'+ident,'--quiet','--wait','--pipe','--collect',
              '--property=UMask=0077','--property=RuntimeMaxSec=900','--setenv=PYTHONDONTWRITEBYTECODE=1',
              '/usr/bin/python3',str(Path(__file__).resolve()),'--state',self.panel.args.state,'--operation',ident,action]
        try:
            p=subprocess.run(argv,input=json.dumps(data),capture_output=True,text=True,timeout=910,env=self.panel.env())
            result=json.loads(p.stdout)
            if not isinstance(result,dict): raise ValueError('worker response')
            # The worker writes the terminal durable record; preserve its truth even if stderr is noisy.
            value=self.operation(ident)
            if value['state']=='running':
                value.update(state='failed' if p.returncode else 'done',result=result if not p.returncode else None,
                             error=result.get('error','İşlem başarısız.') if p.returncode else None,updated_at=int(time.time()))
        except (OSError,subprocess.TimeoutExpired,ValueError,ContainerError):
            with self.lock: value=dict(self.jobs[ident])
            value.update(state='failed',error='İşlem sonucu alınamadı; yeniden denemeden önce konteyner durumunu yenileyin.',updated_at=int(time.time()))
        with self.lock: self.jobs[ident]=value
        if action in ('image-update','save','create','remove','adopt') and value.get('state')=='done': self.forget_updates()
        self.panel.settings_cache=(0,None)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--state',required=True);parser.add_argument('--operation',required=True)
    parser.add_argument('action',choices=sorted(ACTIONS));args=parser.parse_args()
    try:
        if not JOB_RE.fullmatch(args.operation): raise ContainerError(400,'İşlem kimliği geçersiz.')
        raw=sys.stdin.read(65537)
        if len(raw)>65536: raise ContainerError(400,'İstek çok büyük.')
        request=json.loads(raw)
        if not isinstance(request,dict): raise ContainerError(400,'İstek nesne olmalı.')
        from master_container_worker import Manager
        result=Manager(args.state).execute(args.action,request,args.operation)
        print(json.dumps(result,ensure_ascii=False))
    except Exception as err:
        expected=isinstance(err,(ContainerError,config.ContainerConfigError,settings.SettingsError)) or hasattr(err,'status')
        print(json.dumps({'error':str(err) if expected else 'Konteyner işlemi tamamlanamadı.',
                          'status':getattr(err,'status',500)},ensure_ascii=False))
        sys.exit(1)


if __name__=='__main__': main()
