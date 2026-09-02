# Debian / Ubuntu Server Installer (v2)

Lean Bash installer for a fresh **Debian 13 (trixie)**, **Ubuntu 24.04 LTS
(noble)** or **Ubuntu 26.04 LTS (resolute)** host: Tailscale exit node, fixed
Docker Compose bundle (including loopback WebDAV), host dnsmasq + Caddy on the
tailnet, and a persistent firewall. No reconcile engine.

**Current version:** `2026.08.06-v2-77` (see `v2/install.sh`).
Latest tagged release: `2026.08.06-v2-71`.

Authoritative behaviour: [`docs/v2-contract.md`](docs/v2-contract.md).  
Layout and data flow: [`docs/v2-architecture.md`](docs/v2-architecture.md).  
Design rationale: [`docs/design-decisions.md`](docs/design-decisions.md).

## Quick start

```bash
# Developer workstation — build a portable macOS .command
v2/dev/export-v2.sh --desktop
# or double-click: v2/dev/export-v2.command

# Optional private build: passwordless first-install settings for four services.
# These files contain live credentials/keys; keep them under gitignored private/.
v2/dev/export-v2.sh \
  --settings-bundle v2/private/master-stack-settings-v3.tar.gz \
  -o v2/private/2026.08.06-v2-77-WITH-SETTINGS.command

# On the host (after upload)
bash /root/debian-server-installer/v2/install.sh
```

Root, interactive TTY, Debian 13 or Ubuntu 24.04/26.04 LTS only. Re-runs are
supported.

## Runtime tree

```
v2/
├── install.sh          # orchestrator
├── common.sh
├── config/defaults.env # single source of truth for ports/images/paths
├── templates/          # compose.yaml, Caddyfile, dnsmasq.conf
├── scripts/            # firewall, refresh-tailnet, gro, wait helpers
├── systemd/
├── tests/              # bats critical-behaviour suite
├── dev/                # export-v2.sh
└── app/                # versioned portable .command exports
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

## Verify (workstation)

```bash
bats v2/tests
bash -n v2/install.sh v2/common.sh v2/scripts/*
shellcheck -x -s bash v2/install.sh v2/common.sh v2/scripts/*
```

## Working conventions

See [`CLAUDE.md`](CLAUDE.md). Change history: [`CHANGELOG.md`](CHANGELOG.md).
Session continuity: [`SESSION.md`](SESSION.md).
