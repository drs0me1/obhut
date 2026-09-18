# Debian / Ubuntu Server Installer

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, fixed
Docker Compose bundle, host dnsmasq + Caddy on the
tailnet, and a persistent firewall. No reconcile engine.

**Current version:** `2026.08.06-v2-96` (see `Data/install.sh`).

The repository root holds only what is double-clicked: the current portable
installer (`<version>.command`), `wireguard.command` (WireGuard peers and
their backup) and the Git-ignored `kurulum/` (installer inputs and the
WireGuard backup). Everything else lives under `Data/`; paths in the
documents there are relative to `Data/`. Turkish click order:
[`Data/OKUBENI.txt`](Data/OKUBENI.txt).

Authoritative behaviour: [`Data/docs/contract.md`](Data/docs/contract.md).
Layout and data flow: [`Data/docs/architecture.md`](Data/docs/architecture.md).
Design rationale: [`Data/docs/design-decisions.md`](Data/docs/design-decisions.md).
Earlier reviews (historical, v2-27 and v2-73):
[`Data/docs/archive/`](Data/docs/archive/).

## Quick start

```bash
# Once: installer inputs (SSH host, domain, service accounts)
mkdir -p kurulum && cp Data/config/kurulum.env.example kurulum/kurulum.env
chmod 600 kurulum/kurulum.env   # then fill it in

# Install: double-click the current <version>.command at the repository root
# WireGuard peers (after the install): double-click wireguard.command
# Pick the network: 6) Ağ seç; change a peer's DNS: 7) DNS değiştir
# New server key, all its peers removed: 8) Ağı yeniden üret
# Nothing is kept on the Mac but a profile you download, with its QR code as <name>.png

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
├── kurulum/               # installer inputs, mode 600 (Git-ignored)
│   ├── kurulum.env        #   SSH host, domain, service accounts
│   └── wireguard/         #   only the profiles + QR pictures you downloaded (DD-143)
├── versiyon/              # copies of verified working versions, each with OKUBENI.txt
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
| qBittorrent | loopback → Caddy (login) + public peer TCP/UDP | torrent downloads |
| Arşiv açıcı (Unpackerr) | none; a module, installed from Konsol → Modüller (**DD-148**) | archive extraction in the downloads folder |
| WireGuard (host kernel) | public UDP; UIs at `10.8.0.1:<port>` via `caddy-wg` | VPN; peers generated on the server with `wireguard.command` |
| Paylaşım — WebDAV, shares only (module, **DD-149**) | loopback → Caddy `paylas.<domain>` and `<tailscale-ip>:61010` (tailnet only, one generated account) | installed from Konsol → Modüller; the server's only WebDAV: folders and files shared from Konsol, read-only, with an optional expiry. The downloads folder as a whole is never published (**DD-141**, **DD-142**) |
| Konsol | loopback → Caddy `panel.<domain>` (tailnet only, one login; `wg.` and `dosya.` redirect) | one admin console: server overview (CPU, memory, disk, ports), WireGuard peers and networks (add/remove, QR, DNS, keepalive, on/off switches), the downloads folder (browse, move, rename, trash, text viewer, download) and a log (**DD-133**, **DD-136**, **DD-139**, **DD-140**) |

Host edge: dnsmasq + Caddy bound to the Tailscale address; `caddy-wg` bound
to the WireGuard address; firewall (`DOCKER-USER` + custom INPUT/FORWARD/NAT
chains) for Tailscale, WireGuard, the torrent peer port and WAN SSH.

## Backups

There is no container backup tool. A host is rebuilt from `kurulum/` alone:
- Every login comes from `kurulum/kurulum.env`, qBittorrent's included.
- qBittorrent's settings come from `Data/templates/qBittorrent.conf`
  (**DD-129**).
- WireGuard is not part of that: a fresh install has no network, no key and no
  peers (**DD-143**). You create the first network in Konsol → WireGuard →
  Yapılandır and add the devices again.
Keep that folder safe.

## Verify (workstation)

```bash
bats Data/tests
bash -n Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
shellcheck -x -s bash Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
```

## Working conventions

See [`CLAUDE.md`](CLAUDE.md). Change history: [`Data/CHANGELOG.md`](Data/CHANGELOG.md).
Session continuity: [`Data/SESSION.md`](Data/SESSION.md).
