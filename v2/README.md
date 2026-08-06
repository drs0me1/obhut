# master-stack v2

Lean Debian 13 installer: Tailscale exit node, fixed Compose bundle, host
dnsmasq + Caddy on the tailnet, WebDAV, and a persistent firewall. No
reconcile engine.

Authoritative behaviour: [`docs/v2-contract.md`](../docs/v2-contract.md).
Layout and data flow: [`docs/v2-architecture.md`](../docs/v2-architecture.md).

## Export → single portable app (macOS)

There is no separate upload/copy helper. Export builds one self-contained
`.command` that embeds the v2 runtime. Copy that file anywhere (Desktop,
another Mac); no git checkout is required at click time.

```bash
v2/dev/export-v2.sh --desktop
# or double-click: v2/dev/export-v2.command
```

| Output | Role |
|---|---|
| `dist/Master-Stack-v2-Install.command` | Portable installer (also copied to Desktop with `--desktop`) |

Double-click the exported file → SSH host name (default `nrm`) → upload
embedded archive → interactive `install.sh`. Enter accepts defaults; only
the Tailscale login URL needs the browser. Override host with
`DEPLOY_HOST=…`.

Requires SSH key auth to the target. First macOS open may need right-click
→ Open if Gatekeeper quarantines the file.

Rebuild the export after any change under `v2/` that should ship.

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

Not embedded in the export: `.cursor/`, `dev/`, `tests/`, `dist/`.

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
