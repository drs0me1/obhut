# Debian / Ubuntu Server Installer

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, fixed
Docker Compose bundle (including loopback WebDAV), host dnsmasq + Caddy on the
tailnet, and a persistent firewall. No reconcile engine.

**Current version:** `2026.08.06-v2-93` (see `Data/install.sh`).
Latest tagged release: `2026.08.06-v2-71`.

The repository root holds only what is double-clicked: the current portable
installer (`<version>.command`), `wireguard.command` (WireGuard peers),
`ayarlar.command` (pull server settings) and the Git-ignored `kurulum/`
(installer inputs and pulled settings). Everything else lives under `Data/`; paths in the
documents there are relative to `Data/`. Turkish click order:
[`Data/OKUBENI.txt`](Data/OKUBENI.txt).

Authoritative behaviour: [`Data/docs/contract.md`](Data/docs/contract.md).
Layout and data flow: [`Data/docs/architecture.md`](Data/docs/architecture.md).
Design rationale: [`Data/docs/design-decisions.md`](Data/docs/design-decisions.md).
OS-awareness and optimisation review:
[`Data/docs/os-aware-review.md`](Data/docs/os-aware-review.md).

## Quick start

```bash
# Once: installer inputs (domain, ports, accounts, optional Tailscale auth key)
mkdir -p kurulum && cp Data/config/kurulum.env.example kurulum/kurulum.env
chmod 600 kurulum/kurulum.env   # then fill it in

# Install: double-click the current <version>.command at the repository root
# WireGuard peers (after the install): double-click wireguard.command
# Keep a rebuildable copy of WireGuard + qBittorrent settings: double-click ayarlar.command

# Developer workstation — rebuild it (writes Data/app/<version>.command and
# replaces the root copy)
Data/dev/export-installer.sh --desktop
# or double-click: Data/dev/export-installer.command

# On the host (after upload; needs the input file in /run/master-stack)
bash /root/debian-server-installer/install.sh
```

Root, interactive TTY (one confirmation), Debian 13 or Ubuntu 24.04/26.04 LTS
only. Re-runs are supported.

The installer asks nothing it configures: every input comes from
`kurulum/kurulum.env`, which is also the truth on re-runs — an account that
differs from the file is updated (**DD-119**). The portable `.command` embeds
only the runtime files and their archive SHA-256. It uploads them to
`/root/debian-server-installer`, sends the input file to `/run/master-stack`
(`tmpfs`, deleted by the installer as it reads it), then starts `install.sh`.

## Repository layout

```
.
├── <version>.command      # current portable installer (double-click)
├── wireguard.command      # WireGuard peer menu (double-click)
├── ayarlar.command        # pull WireGuard + qBittorrent settings into kurulum/
├── kurulum/               # installer inputs, mode 600 (Git-ignored)
│   ├── kurulum.env        #   domain, ports, accounts, Tailscale auth key
│   ├── wireguard/         #   device profiles; sunucu/wg0.conf = server key + peers
│   └── qbittorrent/       #   qBittorrent.conf: settings incl. its account
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
| qBittorrent | loopback → Caddy (login) + public peer TCP/UDP | torrent downloads |
| Unpackerr | none | archive extraction |
| WireGuard (host kernel) | public UDP; UIs at `10.8.0.1:<port>` via `caddy-wg` | VPN; peers generated on the server with `wireguard.command` |
| WebDAV (rclone) | loopback → Caddy | read-only media for Infuse etc. |

Host edge: dnsmasq + Caddy bound to the Tailscale address; `caddy-wg` bound
to the WireGuard address; firewall (`DOCKER-USER` + custom INPUT/FORWARD/NAT
chains) for Tailscale, WireGuard, the torrent peer port and WAN SSH.

## Backups

There is no container backup tool. A host is rebuilt from `kurulum/` alone:
- Every login comes from `kurulum/kurulum.env`.
- `ayarlar.command` pulls the WireGuard server key, peers and profiles plus
  qBittorrent's settings and account into `kurulum/`.
- A fresh install restores them only where the server has none (**DD-128**).
  Devices reconnect unchanged, and qBittorrent comes up configured.
- Pull again after changing peers or qBittorrent settings.
Keep that folder safe. `container-backup` was retired after v2-87 (**DD-122**);
old archives in a Git-ignored `backup/` folder are no longer read by anything.

## Verify (workstation)

```bash
bats Data/tests
bash -n Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
shellcheck -x -s bash Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
```

## Working conventions

See [`CLAUDE.md`](CLAUDE.md). Change history: [`Data/CHANGELOG.md`](Data/CHANGELOG.md).
Session continuity: [`Data/SESSION.md`](Data/SESSION.md).
