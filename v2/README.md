# master-stack v2

Lean Debian 13 / Ubuntu LTS installer: Tailscale exit node, fixed Compose bundle
(including loopback WebDAV), host dnsmasq + Caddy on the tailnet, and a
persistent firewall. No reconcile engine.

Authoritative behaviour: [`docs/v2-contract.md`](../docs/v2-contract.md).
Layout and data flow: [`docs/v2-architecture.md`](../docs/v2-architecture.md).

## Export → versioned portable app (macOS)

```bash
v2/dev/export-v2.sh --desktop
# or double-click: v2/dev/export-v2.command
```

Every export writes:

| Path | Role |
|---|---|
| `app/<V2_VERSION>.command` | Versioned self-contained installer (kept) |
| `app/latest.command` | Copy of the most recent export |
| `~/Desktop/<V2_VERSION>.command` | Optional Desktop copy (`--desktop`) |

The `.command` embeds the v2 runtime and the archive SHA-256
(`PORTABLE_ARCHIVE_SHA256`). Copy it anywhere; no git checkout or sidecar
file is required at click time. Double-click → SSH host → upload →
interactive `install.sh`.

Rebuild after any `v2/` change that should ship. Prior versioned files under
`app/` are left in place.

## Runtime tree (what lands on the server)

```
v2/
├── install.sh
├── common.sh
├── config/defaults.env
├── templates/
├── scripts/
└── systemd/
```

Not embedded: `.cursor/`, `dev/`, `tests/`, `app/`.

## Manual install on the host

```bash
bash /root/debian-server-installer/v2/install.sh
```

Root, interactive TTY, Debian 13 (trixie) or Ubuntu 24.04/26.04 LTS only.
Re-runs are supported.

## Verify (developer workstation)

```bash
bats v2/tests
bash -n v2/install.sh v2/common.sh v2/scripts/*
shellcheck -x -s bash v2/install.sh v2/common.sh v2/scripts/*
```
