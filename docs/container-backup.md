# Container settings backup

Double-click `container-backup.command` at the repository root. On Windows,
run `bash container-backup.command` from Git Bash or WSL (the file format and
the script avoid macOS-only tools, but this has not been exercised on Windows
as of 2026-09-11). Choose backup, restore or check, then enter an SSH config
alias such as `nrm`, or `root@address`. SSH config supplies the user, key and
port; `--port` overrides the port. The target needs Docker, Bash, GNU tar, jq
and root access (directly or through passwordless `sudo`). Locally the script
needs `ssh`, `scp`,
`tar`, an `openssl` with `-pbkdf2` (macOS LibreSSL, Git for Windows and every
current Linux qualify) and `sha256sum` or `shasum`. Nothing is installed on
either side.

New backups are encrypted with a password typed when the backup is taken; the
same password is required to check or restore that backup. See
[Encryption](#encryption).

The utility is separate from the installer and does not depend on its
version (it discovers mounts with `docker inspect`). Run the installer on a new
target first, so the four containers and their data mounts exist. The backup
utility never creates containers, pulls images or
changes Compose/network configuration. `dev/container-backup-remote.sh` must
remain beside the launcher in the repository; neither script is embedded in the
portable installer.

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

The installer's own inputs — `/etc/master-stack/config.env` (domain, ports,
downloads path, time zone) and `webdav.htpasswd` — are not part of the backup.
`install.sh` asks for them, and a reinstall answers them the same way; giving
the same WebDAV user and password keeps Infuse working with its stored
credentials once its address is updated. WebDAV has no other server-side
state: the rclone container runs read-only with no configuration file.

Excluded: downloads/media, torrent resume files, categories, RSS, watched
folders, GeoDB, logs, Docker images, WebDAV, Unpackerr, host firewall/DNS and
Tailscale identity. qBittorrent exclusions on the destination are preserved,
not reset, when restoring its single configuration file. WebDAV and Unpackerr
remain installer-configured.

## Files and usage

Each run writes a new directory, for example:

```text
backup/20260911T172611Z-nrm-settings.CqrYkY/
    settings.tar.gz.enc   encrypted archive (manifest.json + four service directories)
    settings.sha256       SHA-256 of the decrypted archive, computed on the server
    files.txt             archive entry names, no contents
```

`settings.sha256` and `files.txt` are deliberately plaintext: the hash lets
the script verify a decryption and the SSH transfer, and the listing shows
what a backup holds without its password. Neither reveals file contents. The
manifest records file SHA-256, numeric ownership/modes, source hostname, time,
container image IDs, user IDs and published ports. No plaintext values are
printed. Failed transfers keep the `.part` suffix and never become selectable
backups. Old snapshots are retained; every backup takes fresh copies of
current settings.

Backups taken before 2026-09-11 are plaintext `settings.tar.gz`. They remain
selectable for `check` and `restore` without a password, and are reported as
unencrypted; a restore from one still asks for a password, to encrypt the
before-restore backup it takes. The archive layout and manifest schema are
unchanged, so old and new backups differ only in the encryption wrapper.

```bash
# Interactive menu (also works by double-clicking in Finder)
./container-backup.command

# Inspect mounts/images without stopping anything
./container-backup.command inspect --host nrm

# Fresh snapshot of the configured source; asks for the password twice
./container-backup.command backup --host nrm --yes

# Validate a backup and the new target without changing application data
./container-backup.command check --host root@NEW_SERVER \
  --archive backup/SNAPSHOT/settings.tar.gz.enc

# Restore; asks for confirmation unless --yes is supplied
./container-backup.command restore --host root@NEW_SERVER \
  --archive backup/SNAPSHOT/settings.tar.gz.enc
```

`--yes` answers the confirmation only; the password is always asked. Passwords
are read from standard input without echo, so automation can pipe them in,
at the cost of leaving them in shell history.

Restore first validates the archive and target, then downloads a
`before-restore` backup of the target into the local `backup/` directory,
encrypted with the same password as the session. The decrypted archive is
uploaded once; validation, the before-restore backup and the restore itself
run in the same remote temporary directory over one multiplexed SSH
connection (or separate connections where multiplexing is unavailable, as on
Windows OpenSSH). Restore also takes a fresh recovery snapshot while the
containers are stopped, immediately before replacing data. A
write/start/health error triggers an attempt to put those old settings back.
Failed operations report the exact remote temporary directory, retaining
recovery material for investigation. Successful operations remove their
remote temporary copies.

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

## Reinstalling a host

1. Take a fresh `backup` of the old host while it still runs, and keep its
   password.
2. Reinstall the OS (Debian 13 or a supported Ubuntu). If the SSH host key
   changed, verify the new fingerprint and replace the old known-hosts entry
   by hand; the script does not do that.
3. Run `install.sh` and answer its prompts as before: the same domain,
   downloads path and ports (restore checks that the published ports match),
   and the same WebDAV user and password, so Infuse needs only a new address.
   Relay the Tailscale login URL when it appears.
4. `./container-backup.command restore --host root@NEW` with the backup. This
   puts the four services' settings, including wg-easy's server key and
   peers, on top of the fresh containers. Run `check` first for a dry run.
5. Tailscale admin console: approve the exit node, and point the tailnet
   nameserver and the split-DNS domain (`LOCAL_DOMAIN`, `ayc` by default) at
   the new host's Tailscale IP. The IP changes on every reinstall, because the
   Tailscale identity is deliberately not cloned.
6. Infuse: change the WebDAV share's address to the new Tailscale IP; the
   port (`WEBDAV_PORT`), user and password are unchanged.
7. wg-easy clients: nothing to do if the public IP or DNS name and
   `WG_PUBLIC_PORT` are unchanged; otherwise update the Endpoint in each
   client profile.

## Encryption

New backups are encrypted on the workstation with `openssl enc`: AES-256-CBC,
with the key and IV derived from the password by PBKDF2-HMAC-SHA256 over
600,000 iterations and a random 8-byte salt
(`-aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt`). The file starts with
`Salted__` and the salt. This is the standard OpenSSL format, so any
OpenSSL 1.1.1+ or LibreSSL 2.9+ on any OS decrypts it without this script:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -in settings.tar.gz.enc -out settings.tar.gz
```

The password is read from standard input, handed to `openssl` on a file
descriptor (never on the command line or in the environment) and cleared when
the script exits. It never reaches the server: decryption happens locally, and
the decrypted archive lives only in a private temporary directory the script
removes when it finishes. The server receives the plaintext archive over SSH
into its tmpfs `/tmp`, as before. A wrong password is caught locally, before
any SSH connection. There is no password recovery: a lost password means an
unusable backup.

The format carries no authentication tag. In its place, the script verifies
the decrypted archive's SHA-256 against `settings.sha256` (which also catches
the one-in-256 case where a wrong password passes the padding check), and the
server validates every file's SHA-256, ownership and mode against the
manifest. Someone who can alter the file but lacks the password cannot make a
decryption match either check. Encryption protects a copied, synced or lost
backup file; it does not protect against someone with write access to this
workstation, who could alter the script itself. Every written backup is
decrypted again and hashed before its plaintext is deleted, so a broken
`openssl` cannot leave an unreadable file behind.

Rejected alternatives: `age` (must be installed on every machine), a
PowerShell or Python rewrite (a second implementation to maintain; Python has
no AES in its standard library), and encrypting on the server (the password
would leave the workstation). See **DD-112**.

## Storage and SSH

Backups contain password hashes, application credentials and VPN private
keys. The directory is mode `0700`, files `0600`, and `/backup/` is
Git-ignored. SHA-256 detects corruption; it is not a signature and does not
make an untrusted backup authentic. Archive extraction rejects unexpected
paths, links, special files, duplicate entries, unsupported schemas and
out-of-scope files.

SSH keeps host verification enabled (`accept-new`): changed known host keys
are rejected. After a server reset, verify the new fingerprint before replacing
that host's record in the known-hosts file configured for the SSH alias. The
script neither deletes all known hosts nor disables host verification. SSH
multiplexing is probed once per run and dropped where it does not work, so
every step then authenticates on its own.

## Verification

Local static checks (the launcher must also parse under macOS `/bin/bash`
3.2, which Finder uses):

```bash
bash -n dev/container-backup-remote.sh tests/backup-roundtrip.sh
/bin/bash -n container-backup.command
shellcheck -x -s bash container-backup.command dev/container-backup-remote.sh tests/backup-roundtrip.sh
bats tests   # includes a static check keeping the launcher on bash 3.2 features
```

`tests/backup-roundtrip.sh` runs as root on Linux, exclusively against temporary
directories, and is part of the host acceptance sequence after every
Debian/Ubuntu install (see `tests/README.md`). It covers archive round-trip,
SHA-256 and ownership/modes, out-of-scope preservation, stale-file removal,
rollback on error, and rejection of traversal/absolute paths, symlinks,
hardlinks, tampered and out-of-scope archives. Target checks cover reordered
PUID/PGID lists as well as rejection of actual UID/GID, user and port changes.
Different image digests/tags are accepted with a warning and no override. An
optional archive argument exercises a real backup against those isolated
targets without restoring production data.

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

On 2026-09-11 the encrypted tool was verified on the Debian 13.6 `nrm` at
v2-79. The isolated round-trip passed on the host. From the Mac under
Finder's `/bin/bash` 3.2: an encrypted backup in 17 s that the LibreSSL
one-liner decrypted to the server's hash; a wrong password stopped before any
SSH connection; short and mismatched passwords were rejected; `check` passed
on the encrypted archive and on the 2026-09-06 plaintext archive (with the
unencrypted warning); `restore` of the encrypted archive onto `nrm` took 30 s
with a single upload, wrote an encrypted before-restore backup
(`kind: rollback`) and left 6/6 containers running, 3/3 healthy, 3 WireGuard
peers and no remote directory. The same day a `seed` action (installer inputs
carried in the archive and placed on a fresh host before `install.sh`) was
built, verified in the same way — including a seed → `install.sh` re-run that
took the seeded values as prompt defaults — and then removed at the user's
request: the few values it carried are ones `install.sh` asks for anyway, and
the tool stays a copy-and-load tool for container settings (**DD-112**). The
two test archives written by that build contain a `host/` directory and are
rejected by the final tool as out of scope. The full runbook from a bare OS
has not been run yet; Windows remains unexercised.
