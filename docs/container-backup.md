# Container settings backup

Double-click `container-backup.command` at the repository root. Choose backup
or restore, then enter an SSH config alias such as `nrm`, or `root@address`.
SSH config supplies the user, key and port; `--port` overrides the port.
The target needs Docker, Bash, GNU tar, jq and root access (directly or through
passwordless `sudo`). The script does not install packages.

The utility is separate from the installer and does not depend on its
version (it discovers mounts with `docker inspect`). Run the installer on a new
target first, so the four containers and their data mounts exist. The backup
utility never creates containers, pulls images or changes Compose/network
configuration. `dev/container-backup-remote.sh` must remain beside the launcher
in the repository; neither script is embedded in the portable installer.

## Scope

Mount sources are discovered with `docker inspect`, not guessed from a Compose
project prefix. The current `nrm` inventory on 2026-09-05 was:

| Service | Container path | Saved content |
|---|---|---|
| Portainer | `/data` | Database, users, settings, keys, certificates and Portainer stack definitions; `bin/` cache and `backups/` are excluded |
| FileBrowser | `/database` and its nested `/config` bind | `filebrowser.db` and `config/settings.json`, including user accounts and preferences |
| qBittorrent | `/config/qBittorrent/qBittorrent.conf` | Only this file: Web UI account/password hash and user preferences |
| wg-easy | `/etc/wireguard` | Database, server/client keys and WireGuard configuration; currently `wg-easy.db` and `wg0.conf` |

Portainer data is configuration for Portainer itself, not a backup of the
containers it manages. See [Portainer's backup scope](https://docs.portainer.io/faqs/getting-started/what-does-portainers-backup-include).
LinuxServer persists application settings under `/config`; this utility
intentionally narrows qBittorrent to the one requested preferences file.
See [LinuxServer's volume documentation](https://docs.linuxserver.io/general/volumes/).

Excluded: downloads/media, torrent resume files, categories, RSS, watched
folders, GeoDB, logs, Docker images, WebDAV, Unpackerr, host firewall/DNS and
Tailscale identity. qBittorrent exclusions on the destination are preserved,
not reset, when restoring its single configuration file. WebDAV and Unpackerr
remain installer-configured.

## Files and usage

Each run writes a new directory, for example:

```text
backup/20260905T120000Z-nrm-settings.ABC123/
    settings.tar.gz
    settings.sha256
    files.txt
```

`settings.tar.gz` contains `manifest.json` and four service directories.
The manifest records file SHA-256, numeric ownership/modes, source hostname,
time, container image IDs, user IDs and published ports. No plaintext values
are printed. `files.txt` lists archive entries without their contents.
Failed transfers keep the `.part` suffix and never become selectable backups.
Old snapshots are retained; every backup takes fresh copies of current settings.

```bash
# Interactive menu (also works by double-clicking in Finder)
./container-backup.command

# Inspect mounts/images without stopping anything
./container-backup.command inspect --host nrm

# Fresh snapshot of the configured source
./container-backup.command backup --host nrm --yes

# Validate a backup and the new target without changing application data
./container-backup.command check --host root@NEW_SERVER \
  --archive backup/SNAPSHOT/settings.tar.gz

# Restore; asks for confirmation unless --yes is supplied
./container-backup.command restore --host root@NEW_SERVER \
  --archive backup/SNAPSHOT/settings.tar.gz
```

Restore first validates the archive and target, then downloads a
`before-restore` backup of the target into the local `backup/` directory.
It also takes a fresh recovery snapshot while the containers are stopped,
immediately before replacing data. A write/start/health error triggers an
attempt to put those old settings back. Failed operations report the exact
remote temporary directory, retaining recovery material for investigation.
Successful operations remove their remote temporary copies.

The four applications are stopped briefly to flush databases and preferences.
Only previously running containers are restarted. WebDAV/Unpackerr and the
host SSH/Tailscale services are not restarted. Use public SSH or Tailscale to
reach the target: an SSH session routed through this wg-easy server will be
interrupted while it is stopped. Backups and installation share the host
installer lock.

A freshly installed wg-easy may be running but unhealthy before its setup
wizard is completed. The pre-restore safety backup accepts that existing
baseline; a settings restore then requires the restored services to become
healthy. A recovery snapshot also records the original health baseline.

The backup utility does not gate on the host distribution, release or kernel:
settings can move between already-provisioned Debian and Ubuntu hosts.
It requires the expected containers, writable local mounts and command-line
dependencies, not matching OS versions. This does not expand the installer's
separate supported-OS matrix.

Different container image IDs produce a warning, not a refusal. Fresh
installs can pull newer images under the same moving tags; no extra option is
needed to transfer an existing backup. `--allow-image-change` is accepted as a
backward-compatible no-op. Application/database compatibility across arbitrary
versions, especially downgrades, is not guaranteed. Restore still takes recovery
snapshots and attempts rollback on write/start/health failures; passing health
checks cannot prove every application setting migrated correctly.

Published ports and runtime user/group IDs must still match: these affect
service connectivity and access to the restored files, not OS version matching.
The utility does not rewrite target Compose, ports, users or host networking.

PUID/PGID are compared by value, regardless of their order in Docker's
environment list. Existing schema-1 backups remain compatible; they do not
need to be recreated. A genuine user/group or port mismatch reports the
service, field and source/target values before any settings are replaced.

wg-easy server/client keys are preserved. A move to a new public IP or DNS name
still requires the correct endpoint in wg-easy and existing client profiles;
using a stable DNS name avoids editing every client when only the IP changes.
Do not operate two independent wg-easy servers with the cloned identities.
Tailscale state is deliberately not cloned.

## Storage and SSH

Backups are **unencrypted**, as requested for the single-user workflow. They
contain password hashes, application credentials and VPN private keys. The
directory is mode `0700`, files `0600`, and `/backup/` is Git-ignored. SHA-256
detects corruption; it is not a signature and does not make an untrusted backup
authentic. Archive extraction rejects unexpected paths, links, special files,
duplicate entries, unsupported schemas and out-of-scope qBittorrent files.

SSH keeps host verification enabled (`accept-new`): changed known host keys
are rejected. After a server reset, verify the new fingerprint before replacing
that host's record in the known-hosts file configured for the SSH alias. The
script neither deletes all known hosts nor disables host verification.

## Verification

Local static checks:

```bash
bash -n container-backup.command
bash -n dev/container-backup-remote.sh
shellcheck -x -s bash container-backup.command dev/container-backup-remote.sh tests/backup-roundtrip.sh
```

`tests/backup-roundtrip.sh` runs as root on Linux, exclusively against temporary
directories. It covers archive round-trip, SHA-256 and ownership/modes,
out-of-scope preservation, stale-file removal, rollback on error, and rejection
of traversal/absolute paths, symlinks, hardlinks, tampered and out-of-scope
archives. Target checks cover reordered PUID/PGID lists as well as rejection
of actual UID/GID, user and port changes. Different image digests/tags are
accepted with a warning and no override. An optional archive argument
exercises a real backup against those isolated targets without restoring
production data.

On 2026-09-05, a real backup from the configured Debian 13 `nrm` passed the
SSH download/hash check and target compatibility check. Its 11 data files
(6 Portainer, 2 FileBrowser, 1 qBittorrent, 2 wg-easy) were restored into
isolated temporary targets with matching hashes, numeric ownership and modes.
The live source was not restored over; all six services remained running
after backup, with three WireGuard peers retained.

On 2026-09-06, a reordered PUID/PGID regression failed with the old helper
and passed with the fix. The existing 11-file settings archive passed the
live `nrm` compatibility check and an isolated restore with matching hashes,
ownership and modes. No live settings were replaced during verification.

The version-independent transfer policy was also tested on 2026-09-06:
the isolated suite and the same existing 11-file Debian backup passed on the
Debian host and inside disposable Ubuntu 24.04 and 26.04 containers. Each
service's changed image digest, plus changed image tags, was accepted with a
warning. These are file-transfer/validation/rollback tests, not full application
database migration tests or fresh Ubuntu host installs. The live Debian target
check also passed without replacing application data.

On 2026-09-11 the first **production restore** was performed: the 2026-09-06
archive, taken on the previous Debian 13 `nrm` at v2-73, was restored onto a
freshly installed Debian 13.6 `nrm` at v2-79. `check` passed with no image
warning (the image IDs were identical). The restore produced the
`before-restore` snapshot of the fresh host (`kind: rollback`, 11 files,
SHA-256 verified) and completed with remote cleanup, so no recovery material
was left behind. Verified afterwards on the live host: wg-easy `wg0.conf` and
`wg-easy.db` byte-identical to the archive, with all three peer public keys
present on `wg0`; the qBittorrent Web UI password hash identical; FileBrowser
`config/settings.json` identical (`filebrowser.db` differs because the
application rewrites it on start, as in the isolated tests); Portainer admin
account present. 0 failed units, 6/6 containers, 3/3 healthchecks healthy,
firewall `--check` passed. The host was rebooted immediately after the restore;
nothing else was needed, and the wg-easy endpoint did not change because the
host kept its public IP. Apart from a small "before-restore" archive, nothing in
the fresh host's state was worth keeping: it had not been configured yet.
