# Container settings backup

Double-click `container-backup.command` at the repository root. Choose backup
or restore, then enter an SSH config alias such as `nrm`, or `root@address`.
SSH config supplies the user, key and port; `--port` overrides the port.
The target needs Docker, Bash, GNU tar, jq and root access (directly or through
passwordless `sudo`). The script does not install packages.

The utility is separate from the v73 installer. Run the installer on a new
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

Image IDs and published ports/UIDs must match by default. This prevents silently
restoring a newer database into an incompatible version. `--allow-image-change`
explicitly bypasses only the image check after the operator has checked version
compatibility; ports/UID checks still apply. The script does not promise that
all cross-version migrations work.

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
archives. An optional archive argument exercises a real backup against those
isolated targets without restoring production data.

On 2026-09-05, a real backup from the configured Debian 13 `nrm` passed the
SSH download/hash check and target compatibility check. Its 11 data files
(6 Portainer, 2 FileBrowser, 1 qBittorrent, 2 wg-easy) were restored into
isolated temporary targets with matching hashes, numeric ownership and modes.
The live source was not restored over; all six services remained running
after backup, with three WireGuard peers retained.
