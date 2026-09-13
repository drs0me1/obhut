# Debian / Ubuntu Server Installer

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, fixed
Docker Compose bundle (including loopback WebDAV), host dnsmasq + Caddy on the
tailnet, and a persistent firewall. No reconcile engine.

**Current version:** `2026.08.06-v2-80` (see `Data/install.sh`).
Latest tagged release: `2026.08.06-v2-71`.

The repository root holds only what is double-clicked: the current portable
installer (`<version>.command`), `container-backup.command` and the
Git-ignored `backup/`. Everything else lives under `Data/`; paths in the
documents there are relative to `Data/`. Turkish click order:
[`Data/OKUBENI.txt`](Data/OKUBENI.txt).

Authoritative behaviour: [`Data/docs/contract.md`](Data/docs/contract.md).
Layout and data flow: [`Data/docs/architecture.md`](Data/docs/architecture.md).
Design rationale: [`Data/docs/design-decisions.md`](Data/docs/design-decisions.md).
OS-awareness and optimisation review:
[`Data/docs/os-aware-review.md`](Data/docs/os-aware-review.md).

## Quick start

```bash
# Install: double-click the current <version>.command at the repository root

# Developer workstation — rebuild it (writes Data/app/<version>.command and
# replaces the root copy)
Data/dev/export-installer.sh --desktop
# or double-click: Data/dev/export-installer.command

# On the host (after upload)
bash /root/debian-server-installer/install.sh
```

Root, interactive TTY, Debian 13 or Ubuntu 24.04/26.04 LTS only. Re-runs are
supported.

The portable `.command` embeds only the runtime files and their archive
SHA-256. It uploads them to `/root/debian-server-installer`, then starts
`install.sh`; no Git checkout or sidecar file is required.

## Repository layout

```
.
├── <version>.command      # current portable installer (double-click)
├── container-backup.command  # container settings backup/restore (double-click)
├── backup/                # encrypted backups (Git-ignored)
├── README.md, CLAUDE.md   # entry points
└── Data/
    ├── install.sh          # orchestrator
    ├── common.sh           # shared helpers
    ├── config/defaults.env # single source of truth for ports/images/paths
    ├── templates/          # compose.yaml, Caddyfile, dnsmasq.conf
    ├── scripts/            # firewall, refresh-tailnet, GRO, wait helpers
    ├── systemd/            # units and drop-ins
    ├── tests/              # bats critical-behaviour suite
    ├── dev/                # installer exporter, backup worker
    ├── app/                # every exported <version>.command
    ├── docs/               # contract, architecture and design rationale
    ├── OKUBENI.txt         # Turkish click order
    └── CHANGELOG.md, SESSION.md
```

## Stack

| Service | Exposure | Role |
|---------|----------|------|
| Dozzle | loopback → Caddy (login) | container state, live logs, start/stop/remove |
| FileBrowser | loopback → Caddy (login) | media tree UI |
| Transmission | loopback → Caddy (login) + public peer TCP/UDP | torrent downloads |
| Unpackerr | none | archive extraction |
| wg-easy | loopback UI + public WireGuard UDP | VPN |
| WebDAV (rclone) | loopback → Caddy | read-only media for Infuse etc. |

Host edge: dnsmasq + Caddy bound to the Tailscale address; firewall
(`DOCKER-USER` + custom chains) for Tailscale, the two public peer ports,
and WAN SSH.

## Container settings backup

Double-click `container-backup.command` to back up or restore the wg-easy
account and peers over SSH; the installer asks for every other login and
writes the Transmission preferences. Snapshots are
password-encrypted and stored under the Git-ignored `backup/` directory. This
is separate from installation.
See [scope, the reinstall runbook and encryption](Data/docs/container-backup.md).

## Verify (workstation)

```bash
bats Data/tests
bash -n Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
shellcheck -x -s bash Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
```

## Working conventions

See [`CLAUDE.md`](CLAUDE.md). Change history: [`Data/CHANGELOG.md`](Data/CHANGELOG.md).
Session continuity: [`Data/SESSION.md`](Data/SESSION.md).
