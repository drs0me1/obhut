# `Q1-1` — FileBrowser Quantum

The current revision on the `quantum` branch.

| | |
|---|---|
| Tags | `Q1`, `Q1-1` |
| Version | `2026.08.01-Q1-1` |
| SHA256 | `66b6ae05ea04985b0f4c1cb40fd6cc0a2489754dfcea1375f27bd9bf034ef9f2` |
| Lines | 5453 |
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

## What differs from `V1-20`

Only the web file manager. Everything else — firewall, reconcile, Caddy,
WebDAV, the container set, `STACK_SCHEMA` — is unchanged, which is why the
container name and host port (`7113`) were kept: the diff stays on one
service instead of rippling through eight places.

`stable` is the first floating tag in this stack that actually satisfies
DD-23's rule. Quantum publishes both a moving `stable` and exact pins
(`1.5.0-stable`); original filebrowser had only major-wide `v2`, and dufs on
`master` has no float at all (tracked as **L9** there). Known risk:
`2.0.0-preview-*` tags exist, so `stable` will cross a major silently one
day.

## The admin account is created for you

Unlike Portainer and wg-easy, which ship with no account, **Quantum ships a
working `admin`/`admin` login**. Configuration alone does not close it — the
database-initialisation path creates that account and bypasses the config's
`minLength` check.

So Stage 5 runs `filebrowser set -u admin,<Stage 0 password> -a` after the
image pull and before the stack starts. One call creates the account when
absent and overwrites the default when present. **Log in with `admin` and
the password you set at Stage 0** — the same one WebDAV uses.

Stage 7 asserts `admin`/`admin` returns 401 and stops the install if it
doesn't, because no other signal catches this: Docker's health check, the
reconcile probe and `--check` all report a service with a live default
credential as perfectly healthy.

## Known cost versus `master`'s dufs

Quantum is **stateful** — its database, index and cache live in the
`filebrowser_data` volume. `read_only: true` is therefore impossible, and a
named volume returns. Both were things dufs had removed, and statelessness
was a substantive part of DD-26's argument. `cap_drop: [ALL]`,
`no-new-privileges` and a non-root `uid=1000` are kept.

Full reasoning, and what live testing changed about it, in **DD-27**.
