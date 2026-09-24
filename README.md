# Debian / Ubuntu Server Installer

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, host
dnsmasq + Caddy on the tailnet, a persistent firewall and Konsol, from which
the optional applications are installed. Files, folder WebDAV and ZIP tools
are built in (**DD-159**). No Docker (**DD-152**), no reconcile engine.

**Current version:** `2026.08.06-v2-129` (see `Data/install.sh`).

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
`kurulum/kurulum.env`. A domain subsequently confirmed in Konsol takes
precedence on re-runs (**DD-157**); no account is read from this file.
The portable `.command` embeds
only the runtime files and their archive SHA-256. It uploads them to
`/root/debian-server-installer`, sends the input file to `/run/master-stack`
(`tmpfs`, deleted by the installer as it reads it), then starts `install.sh`.

## Repository layout

```
.
├── <version>.command      # current portable installer (double-click)
├── wireguard.command      # WireGuard peer menu (double-click)
├── kurulum/               # installer inputs, mode 600 (Git-ignored)
│   ├── kurulum.env        #   SSH host and domain
│   └── wireguard/         #   only the profiles + QR pictures you downloaded (DD-143)
├── versiyon/              # copies of verified working versions, each with OKUBENI.txt
├── README.md, CLAUDE.md   # entry points
└── Data/
    ├── install.sh          # orchestrator
    ├── common.sh           # shared helpers
    ├── config/defaults.env # single source of truth for ports/images/paths
    ├── templates/          # Caddyfile, Caddyfile.wg, dnsmasq.conf
    ├── modules/            # app and built-in service templates
    ├── scripts/            # firewall, refresh-tailnet, GRO, wait helpers
    ├── systemd/            # units and drop-ins
    ├── tests/              # Bats, settings worker, browser and isolated Linux tests
    ├── dev/                # installer exporter, backup worker
    ├── app/                # the current exported <version>.command (older ones in Git)
    ├── docs/               # contract, architecture and design rationale
    ├── OKUBENI.txt         # Turkish click order
    └── CHANGELOG.md, SESSION.md
```

## Stack

| Service | Exposure | Role |
|---------|----------|------|
| qBittorrent (host app, **DD-151**) | loopback → Caddy `torrent.<domain>` (its own login); outgoing peer connections only | installed from Konsol → App Store; torrent downloads. The first login's temporary password is shown on its card |
| WireGuard (host kernel; app, **DD-150**) | public UDP; UIs at `10.8.0.1:<port>` via `caddy-wg` | installed from Konsol → App Store; VPN; peers generated on the server with Konsol or `wireguard.command` |
| Built-in folder WebDAV (**DD-158**, **DD-159**) | loopback → Caddy `paylas.<domain>` and `<tailscale-ip>:61010/s/<id>/` | Separate account per folder, RO/RW, expiry and pause. Configure from Files → Details; manage together under Paylaşımlar. Passwords stored only as hashes. |
| Konsol Desktop (**DD-159**) | loopback → Caddy `panel.<domain>` (tailnet only, no password, **DD-147**) | launcher, dock and a single workspace: Files (browse, upload, move, trash, text, ZIP/nested unzip), Settings, server overview, App Store and installed WireGuard; qBittorrent opens its own UI |

Host edge: dnsmasq + Caddy bound to the Tailscale address; `caddy-wg` bound
to the WireGuard address; firewall (custom INPUT/FORWARD/NAT chains) for
Tailscale, WireGuard and WAN SSH.

Konsol → Ayarlar (**DD-156**) manages firewall port overrides, local DNS
names/upstreams and qBittorrent's account/new-download folder in separate
tabs. Firewall addresses include short listening-scope explanations.
Caddy shows routes and offers a local-domain suffix change (**DD-157**).
Review ordinary changes, apply, then confirm within
60 seconds; an independent server-side timer rolls unconfirmed changes back.
Domain changes are separate: configure the new restricted domain in Tailscale
Admin DNS first, then update in Caddy and confirm from the new panel address
within five minutes. Old DNS mapping should stay until confirmation. Service
names, custom DNS records, disabled states and module renderings move together;
IP-based share links do not change. The redundant `health.<domain>` site and
DNS record are removed; installation still checks the real panel and APIs.
Confirmed firewall/DNS/domain choices survive installer re-runs. No settings
backup is embedded in the installer.

Files v09 adds list/cards and a right-hand details pane (below on mobile).
See [folder WebDAV boundaries and migration](Data/docs/folder-shares.md) before
sharing with other people: recipients must not reach passwordless Konsol/SSH.
The v128 upgrade retires old shared-account URLs; create new folder accounts.
Native Finder/Infuse compatibility and fresh Ubuntu acceptance are separate tests.

Desktop v10 is implemented in v129, not a KDE session. Files/WebDAV are always
installed; existing folder accounts survive the upgrade. ZIP jobs run on the
server after the page closes, with cancellation and bounded nested extraction.
See [desktop, archives and upgrade boundaries](Data/docs/desktop-and-archives.md).

## Backups

There is no backup tool. A host is rebuilt from `kurulum/` alone:
- `kurulum/kurulum.env` holds only the SSH host and the domain; Konsol has
  no account (**DD-147**) and the modules make or show their own.
- qBittorrent keeps its settings and torrent list on the server only; a
  fresh install starts it with minimal settings and a new login (**DD-151**).
- WireGuard is not part of that: a fresh install has no WireGuard at all
  (**DD-143**, **DD-150**). Install it from Konsol → App Store → WireGuard, create
  the first network in WireGuard → Yapılandır and add the devices again.
Keep that folder safe.

## Verify (workstation)

```bash
bats Data/tests
bash -n Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
shellcheck -x -s bash Data/install.sh Data/common.sh Data/scripts/* Data/dev/export-installer.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_*.py'
# Browser: PLAYWRIGHT_MODULE=<module path> PLAYWRIGHT_CHROMIUM=<binary> node Data/tests/settings-ui.cjs
# Linux root, disposable network namespace (existing services are not touched):
# unshare --net --fork python3 Data/tests/settings-linux.py
# unshare --net --fork python3 Data/tests/settings-domain-linux.py
# python3 Data/tests/settings-systemd.py
```

## Working conventions

See [`CLAUDE.md`](CLAUDE.md). Change history: [`Data/CHANGELOG.md`](Data/CHANGELOG.md).
Session continuity: [`Data/SESSION.md`](Data/SESSION.md).
