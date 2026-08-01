# `Q1-4` — FileBrowser Quantum

The current revision on the `quantum` branch.

| | |
|---|---|
| Tags | `Q1`, `Q1-4` |
| Version | `2026.08.01-Q1-4` |
| SHA256 | `3c14d127af01aa2b579bab8fe2df23075682f86e6305d1d3a188aff453010969` |
| Lines | 5443 |
| `STACK_SCHEMA` | 10 |
| Web file manager | `ghcr.io/gtsteffaniak/filebrowser:stable` (v1.5.0-stable) |

## Deploying

```sh
./deploy.sh nrm          # copy + verify the SHA256 on the host
./deploy.sh nrm --run    # copy + verify + start the install over SSH
```

Or double-click `deploy.command` from Finder.

**Open the Tailscale login link the moment it appears, then leave the
session alone.** Restarting the installer generates a new nodekey and
invalidates the pending auth path (`410 auth path not found`).

## First thing to do after installing

**Change the filebrowser admin password.** Quantum ships a working default
login — `admin` / `admin` — which is different from Portainer and wg-easy,
where no account exists until you create one. Until you change it, any
device on the tailnet has full read-write access to the media tree.

```
http://file.<your-domain>     admin / admin
```

The container owns that account, not the installer, so the change can only
be made through the web UI. It survives installer re-runs: upstream creates
the account only when the database is absent, which was verified by changing
the password and re-running the full install. Reasoning in **DD-27**.

## What differs from `V1-20`

Only the web file manager — firewall, reconcile, Caddy, WebDAV, the
container set and `STACK_SCHEMA` are unchanged. The container name and host
port (`7113`) were kept deliberately so the diff stays on one service.

`stable` is the first floating tag in this stack that satisfies DD-23's rule
("take the finest float the upstream actually publishes"). Quantum ships
both a moving `stable` and exact pins; original filebrowser had only
major-wide `v2`, and dufs on `master` has no float at all. Known risk:
`2.0.0-preview-*` tags exist, so `stable` will cross a major silently one
day.

## Hardening

`read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, non-root
`uid=1000`. The read-only root is possible because `server.cacheDir` is
redirected into the data volume — Quantum otherwise writes its search index,
thumbnails and generated icons into the container's writable layer, where
they were also being destroyed on every recreate. See **DD-27**.

The one property that does not carry over from `master`'s dufs is
statelessness: Quantum keeps a database, so a named volume
(`filebrowser_data`) exists here.

## Also in this revision

`rclone serve webdav` runs with `--dir-cache-time 1m` instead of rclone's
5-minute default. Without it, a file finished by qBittorrent or extracted by
unpackerr could be invisible to Infuse for five minutes — measured, and the
reason is in **DD-28**.
