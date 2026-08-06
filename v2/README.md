# master-stack v2

Lean Debian 13 installer: Tailscale exit node, fixed Compose bundle, host
dnsmasq + Caddy on the tailnet, WebDAV, and a persistent firewall. No
reconcile engine.

Authoritative behaviour: [`docs/v2-contract.md`](../docs/v2-contract.md).
Layout and data flow: [`docs/v2-architecture.md`](../docs/v2-architecture.md).

## One-click (macOS) — single portable file

The install launcher is a **self-contained** `.command`: it embeds the v2
runtime tarball. Copy it anywhere (Desktop, USB, another Mac). No git repo
required on the machine that clicks it.

| File | Role |
|---|---|
| [`dist/Master-Stack-v2-Install.command`](dist/Master-Stack-v2-Install.command) | Double-click → ask SSH host → upload → interactive `install.sh` |
| [`dev/build-portable-installer.command`](dev/build-portable-installer.command) | Rebuild the portable file into `dist/` **and** copy to Desktop |

Rebuild after any `v2/` change:

```bash
v2/dev/build-portable-installer.sh --desktop
```

Flow: SSH host name (default `nrm`) → copy embedded archive → `ssh -t`
install. Prompts use Enter for defaults; only the Tailscale login URL needs
the browser. Override default host with `DEPLOY_HOST=…`.

Requires SSH key auth to the target (`BatchMode` for upload). First macOS
open may need right-click → Open if Gatekeeper quarantines the file.

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

Not shipped in the portable archive: `.cursor/`, `dev/`, `tests/`, `dist/`.

## Repo helpers (optional)

| File | Action |
|---|---|
| `dev/install-v2.command` | Rebuild portable from this checkout, then run it |
| `dev/upload-v2.command` | Upload runtime from this checkout only (no install) |

## Manual install on the host

```bash
bash /root/debian-server-installer/v2/install.sh
```

Root, interactive TTY, Debian 13 (trixie) only. Re-runs are supported.

## Verify (developer workstation)

```bash
bats v2/tests
bash -n v2/install.sh v2/common.sh v2/scripts/*
shellcheck -x -s bash v2/install.sh v2/common.sh v2/scripts/*
```
