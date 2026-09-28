# Debian / Ubuntu Server Installer

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, host
dnsmasq + Caddy on the tailnet, a persistent firewall and Konsol, from which
the optional applications are installed. Files, folder WebDAV and ZIP/RAR tools
are built in (**DD-159**, **DD-166**). No Docker (**DD-152**), no reconcile engine.

**Current version:** `2026.08.06-v2-151` (see `Data/install.sh`).

Model A is implemented: Files is the landing page, with one sidebar and live
CPU/RAM/disk indicators. See the [clean-install checklist](Data/docs/model-a-clean-install.md).
App Store uses the compact list (model 2): Install/Open in each row, service
controls and logs under Details. Fresh-host acceptance remains separate from upgrades.

The repository root holds only what is double-clicked: the current portable
installer (`<version>.command`), `wireguard.command` (WireGuard peer management)
and the Git-ignored `kurulum/` (installer inputs and device profiles/QR codes
downloaded on request, not a server backup). Everything else lives under `Data/`; paths in the
documents there are relative to `Data/`. Turkish click order:
[`Data/OKUBENI.txt`](Data/OKUBENI.txt).

Authoritative behaviour: [`Data/docs/contract.md`](Data/docs/contract.md).
Layout and data flow: [`Data/docs/architecture.md`](Data/docs/architecture.md).
Design rationale: [`Data/docs/design-decisions.md`](Data/docs/design-decisions.md).
Earlier reviews (historical, v2-27 and v2-73):
[`Data/docs/archive/`](Data/docs/archive/).

## Quick start

```bash
# Once, only if absent: installer inputs (SSH host and domain; no accounts)
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
    ├── config/defaults.env # single source of truth for ports/paths/chain names
    ├── templates/          # Caddyfile, dnsmasq.conf
    ├── modules/            # app and built-in service templates
    ├── scripts/            # firewall, refresh-tailnet, GRO, wait helpers
    ├── systemd/            # units and drop-ins
    ├── tests/              # Bats, settings worker, browser and isolated Linux tests
    ├── dev/                # portable installer exporter
    ├── app/                # the current exported <version>.command (older ones in Git)
    ├── docs/               # contract, architecture and design rationale
    ├── OKUBENI.txt         # Turkish click order
    └── CHANGELOG.md, SESSION.md
```

## Stack

| Service | Exposure | Role |
|---------|----------|------|
| qBittorrent (host app, **DD-151**) | loopback → Caddy `torrent.<domain>` (its own login); outgoing peer connections only | installed from Konsol → App Store; torrent downloads. Its own page shows first-login information on request |
| WireGuard (host kernel; app, **DD-150**) | public UDP; internet-only VPN | installed from Konsol → App Store; VPN; peers generated on the server with Konsol or `wireguard.command` |
| Built-in folder WebDAV (**DD-158**, **DD-159**) | loopback → Caddy `paylas.<domain>` and `<tailscale-ip>:61010/s/<id>/` | Separate account per folder, RO/RW, expiry and pause. Configure from Files → Details; manage together under Paylaşımlar. Passwords stored only as hashes. |
| Konsol Model A (**DD-160**) | loopback → Caddy `panel.<domain>` (tailnet only, no password, **DD-147**) | one sidebar: Files (browse, upload, move, trash, text, archive creation/extraction), App Store, installed qBittorrent/WireGuard and Settings; CPU/RAM/disk below the menu |

Host edge: dnsmasq + Caddy bound to the Tailscale address; firewall (custom INPUT/FORWARD/NAT chains) for
Tailscale, WireGuard and WAN SSH.
Tailnet host ingress uses an explicit service allowlist (**DD-172**); arbitrary
listeners do not become accessible automatically. Registered WireGuard ports and
outbound/established traffic remain protected; explicit WAN/tailnet rules take precedence.

WireGuard is internet-only for all networks and peers (**DD-177**).
There is no Local access option in creation, settings, API or CLI. Upgrades
normalize existing networks, remove WG-scoped host rules and retire the old WG
Caddy listener without changing keys, profiles, ports, addresses or DNS.
WG cannot reach host services, other VPN networks or private destinations routed
through WAN. Firewall overrides are available only for WAN and Tailscale.

Konsol → Ayarlar (**DD-156/160**) contains System, Firewall, Caddy, Dnsmasq and
Log tabs. qBittorrent's account/new-download folder is on its own application
page. Account-only Save commits directly (**DD-165**); folder edits share the
existing draft/review/rollback controller with Settings.
Firewall uses full tables with service/address explanations, source CIDRs,
policy and on/off controls. Incoming-network tabs are Tailscale (default), Internet,
WireGuard (when installed, with per-network selection) and protected loopback.
Listener binding is labelled separately from permission; Technical rules shows
all chains read-only (**DD-164**). Details stay visible; narrow screens scroll the table.
Caddy shows routes and offers a local-domain suffix change (**DD-157**).
DNS-only changes use one Apply action and persist immediately after validation
and restart, without a timed confirmation (**DD-163**). The panel's own DNS
name cannot be disabled; failed applies restore previous settings.
Account Save sends only username/password, keeps other drafts untouched and
reports success after durable commit. Blank preserves a stored password;
temporary first-login passwords can rotate on restart. Failed applies retain
snapshot recovery. Firewall/qBittorrent folder changes (including mixed drafts) require review,
apply and confirmation within 60 seconds; an independent server-side timer
rolls unconfirmed changes back.
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

Model A replaces v129's application launcher, desktop dock, window controls and
Overview; it is not an OS session. Files has its own contextual action dock when
items are selected (**DD-170**). Files/WebDAV are always installed; existing folder accounts
survive the upgrade. ZIP creation and ZIP/RAR extraction jobs run on the
server after the page closes, with cancellation and bounded nested extraction.
Archive creation produces ZIP. Extraction automatically finds multipart RAR and
nested archives; the destination defaults to downloads and can be chosen with
the folder picker (**DD-170**). RAR3/RAR5, solid and multipart sets are supported;
keep all volumes together. The internal depth limit is five layers.
All source archives are retained. Encrypted archives/ZIP64/7z are not supported;
the existing 2 GiB aggregate job limit also applies to RAR.
See [archive and upgrade boundaries](Data/docs/desktop-and-archives.md) and
[Model A navigation and acceptance](Data/docs/model-a-clean-install.md).

## Backups

There is no backup/restore tool. `kurulum/` supplies installation inputs, not server data:
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
