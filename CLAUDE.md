# CLAUDE.md

Working guide for any AI assistant in this repository. Read this first.

## Project Overview

Active code lives under `Data/`; the repository root holds only what the
operator double-clicks — the current portable installer (`<V2_VERSION>.command`),
`container-backup.command` — plus the Git-ignored `kurulum/` (installer inputs)
and `backup/`, this file and `README.md`. Bare paths in this file and in `Data/docs/` (`install.sh`,
`config/defaults.env`, `tests/`, `CHANGELOG.md`, …) are relative to `Data/`.

The installer turns a fresh Debian 13
(trixie) or Ubuntu 24.04/26.04 LTS host
into a Tailscale exit-node with a fixed Docker Compose bundle, host
dnsmasq + Caddy on the tailnet, and a persistent firewall. There is no
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
  `admin` / `12345test` for Dozzle and Transmission; `admin` / `12345test1234`
  for FileBrowser (12-character minimum); an empty `TS_AUTH_KEY`; test
  WireGuard keys and peers in the scratch `wireguard/` (never print real
  keys; derive or compare them without output). Answer the
  re-run questions with their defaults and `E` at the confirmation, and report
  what was used. The input file is the truth (**DD-119**): a run rewrites any
  account that differs from it, so save and restore a real credential on
  `nrm` around a test — the operator's WebDAV htpasswd is real (Infuse).
  Non-default config values still need the user.
- **Never ask for, read, store or type a Tailscale auth key.** Only the
  operator puts one in `kurulum/kurulum.env` (**DD-115**, **DD-119**); never
  open, print or copy that file. Running the launcher with the operator's
  folder is allowed only when the user asks for it in chat.
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
| `container-backup.command` (root) | Container settings backup/restore launcher |
| `kurulum/kurulum.env` (root) | Installer inputs, Git-ignored, mode 600; template `Data/config/kurulum.env.example` |
| `kurulum/wireguard/` (root) | WireGuard server key (`sunucu.key`) and one profile per peer (`<device>.conf`), mode 600 (**DD-120**) |
| `backup/` (root) | Encrypted backups, Git-ignored |
| `Data/install.sh` | Orchestrator |
| `Data/common.sh` | Shared helpers |
| `Data/config/defaults.env` | Ports, images, paths, chain names |
| `Data/templates/` | Compose, Caddy, dnsmasq |
| `Data/scripts/` | Firewall, refresh-tailnet, GRO, wait |
| `Data/systemd/` | Unit/timer templates |
| `Data/tests/` | Critical bats suite (`bats Data/tests`) |
| `Data/dev/export-installer.sh` | Portable `.command` exporter |
| `Data/dev/container-backup-remote.sh` | Backup worker copied to the host per run |
| `Data/app/` | Every exported `<V2_VERSION>.command` |
| `Data/docs/contract.md` | What the installer does / refuses |
| `Data/docs/architecture.md` | Layout and data flow |
| `Data/docs/design-decisions.md` | `DD-*` rationale |

## Constraints

- Root-only, single-host. Inputs come from `kurulum/kurulum.env`; the
  installer still needs a TTY and one confirmation. No unattended mode.
- Debian 13 (trixie), Ubuntu 24.04 (noble) or Ubuntu 26.04 (resolute)
  only (**DD-102**). Noble live-verified 2026-08-29; resolute
  live-verified 2026-08-30, including re-run, service restarts and reboot.
- Fixed service bundle — no installation profiles.
- Do not delete or recreate Docker-owned iptables chains; manage only
  project chains and jumps into `DOCKER-USER`.
