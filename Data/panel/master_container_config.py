#!/usr/bin/env python3
"""Shared pieces of Konsol's rootful Podman code: errors, names, private files, systemd quoting and
who manages a container.

An application's units are written by the generator (master_generator) from its record
(master_applications); no runtime socket, no reconciliation.
"""
import json
import os
from pathlib import Path
import re
import stat

import master_settings as settings

LIMIT = 1024 * 1024
NAME_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z')
REV_RE = re.compile(r'[0-9a-f]{32}\Z')
MANAGED_LABEL = 'io.master-stack.managed'


class ContainerConfigError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def require(ok, message, status=400):
    if not ok:
        raise ContainerConfigError(status, message)


def private_dir(path):
    """No-follow directory creation; never chmod through a user-controlled symlink."""
    with settings.parent_fd(Path(path) / '.directory', create=True) as (fd, _):
        info = os.fstat(fd)
        require(info.st_uid == os.geteuid(), 'Konteyner kayıt klasörünün sahibi geçersiz.', 503)
        os.fchmod(fd, 0o700)


def unlink(path):
    with settings.parent_fd(path) as (directory, name):
        try:
            info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return
        require(stat.S_ISREG(info.st_mode), 'Konteyner kayıt dosyası güvenli değil.', 503)
        os.unlink(name, dir_fd=directory)
        os.fsync(directory)


def read_private(path):
    try:
        raw, info = settings.read_regular(path, LIMIT)
    except FileNotFoundError:
        return None
    except (OSError, settings.SettingsError) as err:
        raise ContainerConfigError(503, 'Konteyner kayıt dosyası güvenli biçimde okunamadı.') from err
    require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) & 0o077 == 0,
            'Konteyner kaydı özel değil; işlem yapılmadı.', 503)
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError) as err:
        raise ContainerConfigError(503, 'Konteyner kaydı okunamadı; üzerine yazılmadı.') from err
    require(isinstance(value, dict), 'Konteyner kaydı geçersiz.', 503)
    return value


def quote(value, command=False):
    """Systemd words: percent specifiers everywhere, dollar expansion only in Exec directives."""
    result = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    return '"' + (result.replace('$', '$$') if command else result) + '"'


def ownership(inspect):
    """Who manages a container: 'uygulama' (a unit of one of Konsol's applications, a pod member too),
    'controlled' (another manager: a pod, a Compose or Kubernetes project, a systemd unit) or
    'standalone' (nothing but Podman itself)."""
    import master_generator as names  # the names table's one home (imported late: it imports this module)
    name = str(inspect.get('Name', '')).lstrip('/')
    labels = (inspect.get('Config') or {}).get('Labels') or inspect.get('Labels') or {}
    unit = labels.get('PODMAN_SYSTEMD_UNIT')
    if labels.get(MANAGED_LABEL) == names.MANAGED_VALUE:
        app = labels.get(names.APP_LABEL)
        try:
            # Its own unit: konsol-<app>_<service>.service for the container <app>_<service>.
            ok = isinstance(app, str) and name.startswith(app + '_') and \
                unit == names.container_unit(app, name[len(app) + 1:]) and name == names.container_name(app, name[len(app) + 1:])
        except names.GeneratorError:
            ok = False
        return names.MANAGED_VALUE if ok else 'controlled'
    if inspect.get('Pod') or inspect.get('PodName') or any(k.startswith(('com.docker.compose.', 'io.podman.compose.', 'io.kubernetes.')) for k in labels):
        return 'controlled'
    if unit or labels.get(MANAGED_LABEL) or labels.get('io.containers.autoupdate') or name.startswith(('master-', 'konsol-')):
        return 'controlled'
    cgroup = str((inspect.get('State') or {}).get('CgroupPath', ''))
    if any(part.endswith('.service') and not part.startswith('user@') for part in cgroup.split('/')):
        return 'controlled'
    return 'standalone'
