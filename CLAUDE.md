# CLAUDE.md

Working guide for any AI assistant in this repository. Read this first.

## Project Overview

Active code lives under `Data/`; the repository root holds only what the
operator double-clicks — the current portable installer (`<V2_VERSION>.command`)
`wireguard.command` — plus the Git-ignored `kurulum/` (installer inputs and the WireGuard backup),
`versiyon/` (frozen copies of verified working versions), this file and `README.md`. Bare paths in this file and in `Data/docs/` (`install.sh`,
`config/defaults.env`, `tests/`, `CHANGELOG.md`, …) are relative to `Data/`.

The installer turns a fresh Debian 13
(trixie) or Ubuntu 24.04/26.04 LTS host
into a Tailscale exit-node with a base Docker Compose bundle, host
dnsmasq + Caddy on the tailnet, and a persistent firewall; optional parts
are modules installed from Konsol (**DD-148**). There is no
reconcile / self-healing engine by design.

Authoritative behaviour: [`Data/docs/contract.md`](Data/docs/contract.md).
Architecture: [`Data/docs/architecture.md`](Data/docs/architecture.md).
Non-obvious rationale: [`Data/docs/design-decisions.md`](Data/docs/design-decisions.md)
(`DD-*` entries). Cursor rules for the tree:
`.cursor/rules/master-stack.mdc`.

The installer is destructive: firewall, systemd, Docker daemon, network
state. Treat every change as production-infrastructure work.

## Language Rules

- **Speak to the user in Turkish.** Conversational replies only.
- **Operator-facing strings are Turkish** (messages printed by
  `install.sh` and helpers). Match existing style in each file.
- **Markdown documentation and commit messages stay in English.**
- **`tests/*.bats` stay English** for comments and `@test` names
  (Turkish `@test` names break `bats` under `tr_TR.UTF-8`).
- Keep each artifact internally consistent.

## Execution Rules

- **The `nrm` host is a disposable test target under standing
  authorization (2026-07-31).** Unless the user says otherwise, on `nrm`
  only: run the installer, `sudo`, mutating `systemctl`/`docker`, firewall
  changes, wipes, and reboots without per-turn approval. Drive the installer
  with a scratch test input file, never the operator's `kurulum/kurulum.env`:
  empty domain, path and ports (defaults); WebDAV `infuse` / `12345test`;
  `admin` / `12345test` for Dozzle and qBittorrent (`TORRENT_USER`/`TORRENT_PASS`); `admin` / `12345test1234`
  (Konsol has no account, **DD-147**). Add and
  remove test peers with `master-wg`/`wireguard.command` (never print a
  profile; QR codes of test peers only). Answer the
  re-run questions with their defaults and `E` at the confirmation, and report
  what was used. The input file is the truth (**DD-119**): a run rewrites any
  account that differs from it, so save and restore a real credential on
  `nrm` around a test — the operator's WebDAV htpasswd is real (Infuse).
  Non-default config values still need the user.
- **Never open, print or copy `kurulum/kurulum.env`** — it holds the
  operator's service passwords. There is no Tailscale auth key any more
  (**DD-147**): the node joins through the login link. Running the launcher
  with the operator's folder is allowed only when the user asks for it in chat.
- **Relay only the Tailscale login URL** (`https://login.tailscale.com/a/...`)
  and wait; it expires if left unused.
- That authorization does **not** cover: local Mac outside this repo;
  `git reset --hard`, `git push`, force-push, tag deletion, history
  rewrite; other hosts; Tailscale account/ACL changes; publishing repo
  content elsewhere.
- Read-only inspection is always fine.
- **Report what was actually run** and the real outcomes.

## Working Conventions

- Prefer static analysis first (`bash -n`, `shellcheck`, `bats tests`).
  Escalate to live `nrm` installs when static review cannot catch the
  failure mode — still report destructive commands.
- Analyze before editing; check `docs/design-decisions.md` and
  `docs/contract.md` before "fixing" intentional behaviour.
- Wait for approval before making changes unless the user already asked
  for that change.
- Smallest possible change. No opportunistic refactors.
- Show the diff before committing. Commit only when the user asks (unless
  a user rule says otherwise for that turn).
- Bump `V2_VERSION` in `install.sh` on every behavioural change to the
  installer tree. Record user-facing changes under `[Unreleased]` in
  `CHANGELOG.md` and add a `DD-*` entry when rationale is non-obvious.
- Preserve idempotency: re-runs against a provisioned host must stay safe.
- Prefer security over convenience when both achieve the same result; flag
  the trade-off.
- Single source of truth for ports/images/paths:
  `config/defaults.env`. Do not restate literals elsewhere.
- Do not grow a general-purpose reconcile engine (contract + rules).

## Key Paths

| Path | Purpose |
|------|---------|
| `<V2_VERSION>.command` (root) | Current portable installer, copied from `Data/app/` by the exporter |
| `kurulum/kurulum.env` (root) | Installer inputs, Git-ignored, mode 600; template `Data/config/kurulum.env.example` |
| `wireguard.command` (root) | WireGuard peer menu over SSH (**DD-124**, **DD-143**): pick a network, list/add/remove/QR, 7) DNS change, 8) regenerate the network after typing `onayla`. Nothing is uploaded and nothing is kept on the Mac |
| `versiyon/` (root) | Copies of verified working versions on the user's request: `<V2_VERSION>/` from a commit via `git archive` (no `Data/app`, no `kurulum/`), each with a Turkish `OKUBENI.txt`; index in `versiyon/OKUBENI.txt`. Frozen: never edit a saved copy |
| `kurulum/wireguard/` (root) | Only what `wireguard.command` downloads on request: device profiles and their QR pictures (**DD-132**), mode 600. Since **DD-143** the installer never reads this folder and nothing is sent to the server |
| `Data/templates/qBittorrent.conf` | qBittorrent keys the installer keeps in sync; the account comes from `TORRENT_USER`/`TORRENT_PASS` (**DD-129**) |
| `Data/scripts/master-wg` | Server-side peer tool installed to `/usr/local/sbin` |
| `Data/scripts/master-modul`, `Data/modules/<id>/` | Module helper (root; `liste`/`kur`/`baslat`/`durdur`/`kaldir`/`gunluk`) and module templates the installer renders to `/usr/local/share/master-stack/moduller/`; registry `/etc/master-stack/moduller` (**DD-148**) |
| `Data/console/` | Konsol pages (`index.html`, `konsol.css`, `konsol.js`) at Caddy `panel.<domain>`, tailnet only; `wg.` and `dosya.` redirect there (**DD-140**). Design mockups in `Data/docs/design/` |
| WebDAV (`paylasim`) | The only rclone container: read-only, root `DOWNLOADS_PATH/.pay/w` (symlinks made by the file backend) at Caddy `paylas.<domain>` and `<tailscale-ip>:61010`; one account from `kurulum.env`. The downloads folder as a whole is not published (**DD-141**, **DD-142**) |
| `Data/panel/` | Konsol's WireGuard and system backend (`master-wg-panel`, Python stdlib, root, `127.0.0.1:61008`, `/api/wg/*` only) built on `master-wg`; networks wg1…wg9, peer and network switches (**DD-133**, **DD-136**, **DD-140**) |
| `Data/files-panel/` | Konsol's file backend and page server (`master-files-panel`, Python stdlib, `127.0.0.1:61009`, runs as the downloads uid, same account as the WireGuard backend; trash in `.cop`) (**DD-139**, **DD-140**) |
| `/etc/wireguard/networks` (host) | Panel networks registry written by `master-wg net-add/net-remove`, read by `master-firewall` and the panel (**DD-136**) |
| `Data/install.sh` | Orchestrator |
| `Data/common.sh` | Shared helpers |
| `Data/config/defaults.env` | Ports, images, paths, chain names |
| `Data/templates/` | Compose, Caddy, dnsmasq |
| `Data/scripts/` | Firewall, refresh-tailnet, GRO, wait |
| `Data/systemd/` | Unit/timer templates |
| `Data/tests/` | Critical bats suite (`bats Data/tests`) |
| `Data/dev/export-installer.sh` | Portable `.command` exporter |
| `Data/app/` | Exported `<V2_VERSION>.command` files (older exports pruned in v2-96; history is in Git) |
| `Data/docs/contract.md` | What the installer does / refuses |
| `Data/docs/architecture.md` | Layout and data flow |
| `Data/docs/design-decisions.md` | `DD-*` rationale |
| `Data/docs/archive/` | Historical reviews (v2-27, v2-73) and the original rules source; not current behaviour |

## Constraints

- Root-only, single-host. Inputs come from `kurulum/kurulum.env`; the
  installer still needs a TTY and one confirmation. No unattended mode.
- Debian 13 (trixie), Ubuntu 24.04 (noble) or Ubuntu 26.04 (resolute)
  only (**DD-102**). Noble live-verified 2026-08-29; resolute
  live-verified 2026-08-30, including re-run, service restarts and reboot.
- The installer lays down a fixed base; it never installs modules. Modules
  are a fixed catalogue in `Data/modules/` + `master-modul`, installed from
  Konsol → Modüller (**DD-148**). No installation profiles.
- Do not delete or recreate Docker-owned iptables chains; manage only
  project chains and jumps into `DOCKER-USER`.
