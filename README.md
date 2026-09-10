# Debian / Ubuntu Server Installer

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, fixed
Docker Compose bundle (including loopback WebDAV), host dnsmasq + Caddy on the
tailnet, and a persistent firewall. No reconcile engine.

**Current version:** `2026.08.06-v2-76` (see `install.sh`).
Latest tagged release: `2026.08.06-v2-71`.

Authoritative behaviour: [`docs/contract.md`](docs/contract.md).
Layout and data flow: [`docs/architecture.md`](docs/architecture.md).
Design rationale: [`docs/design-decisions.md`](docs/design-decisions.md).
OS-awareness and optimisation review:
[`docs/os-aware-review.md`](docs/os-aware-review.md).

## Quick start

```bash
# Developer workstation — build a portable macOS .command
dev/export-installer.sh --desktop
# or double-click: dev/export-installer.command

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
├── install.sh          # orchestrator
├── common.sh           # shared helpers
├── config/defaults.env # single source of truth for ports/images/paths
├── templates/          # compose.yaml, Caddyfile, dnsmasq.conf
├── scripts/            # firewall, refresh-tailnet, GRO, wait helpers
├── systemd/            # units and drop-ins
├── tests/              # bats critical-behaviour suite
├── dev/                # portable installer exporter
├── app/                # current portable .command + latest alias
└── docs/               # contract, architecture and design rationale
```

## Stack

| Service | Exposure | Role |
|---------|----------|------|
| Portainer | loopback → Caddy | Docker UI |
| FileBrowser | loopback → Caddy | media tree UI |
| qBittorrent | loopback UI + public peer TCP/UDP | torrents |
| Unpackerr | none | archive extraction |
| wg-easy | loopback UI + public WireGuard UDP | VPN |
| WebDAV (rclone) | loopback → Caddy | read-only media for Infuse etc. |

Host edge: dnsmasq + Caddy bound to the Tailscale address; firewall
(`DOCKER-USER` + custom chains) for Tailscale, the two public peer ports,
and WAN SSH.

## Container settings backup

Double-click `container-backup.command` to back up or restore Portainer,
FileBrowser, wg-easy and qBittorrent preferences over SSH. Snapshots are stored
under the Git-ignored `backup/` directory. This is separate from installation.
See [scope and restore instructions](docs/container-backup.md).

## Verify (workstation)

```bash
bats tests
bash -n install.sh common.sh scripts/* dev/export-installer.sh
shellcheck -x -s bash install.sh common.sh scripts/* dev/export-installer.sh
```

## Working conventions

See [`CLAUDE.md`](CLAUDE.md). Change history: [`CHANGELOG.md`](CHANGELOG.md).
Session continuity: [`SESSION.md`](SESSION.md).
