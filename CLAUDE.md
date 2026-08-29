# CLAUDE.md

Working guide for any AI assistant in this repository. Read this first.

## Project Overview

Active code lives under **`v2/`**. It turns a fresh Debian 13 (trixie)
or Ubuntu 24.04/26.04 LTS host
into a Tailscale exit-node with a fixed Docker Compose bundle, host
dnsmasq + Caddy on the tailnet, and a persistent firewall. There is no
reconcile / self-healing engine by design.

Authoritative behaviour: [`docs/v2-contract.md`](docs/v2-contract.md).  
Architecture: [`docs/v2-architecture.md`](docs/v2-architecture.md).  
Non-obvious rationale: [`docs/design-decisions.md`](docs/design-decisions.md)
(`DD-*` entries). Cursor rules for the tree:
`v2/.cursor/rules/master-stack.mdc`.

The installer is destructive: firewall, systemd, Docker daemon, network
state. Treat every change as production-infrastructure work.

## Language Rules

- **Speak to the user in Turkish.** Conversational replies only.
- **`v2/` operator-facing strings are Turkish** (messages printed by
  `install.sh` and helpers). Match existing style in each file.
- **Markdown documentation and commit messages stay in English.**
- **`v2/tests/*.bats` stay English** for comments and `@test` names
  (Turkish `@test` names break `bats` under `tr_TR.UTF-8`).
- Keep each artifact internally consistent.

## Execution Rules

- **The `nrm` host is a disposable test target under standing
  authorization (2026-07-31).** Unless the user says otherwise, on `nrm`
  only: run the installer, `sudo`, mutating `systemctl`/`docker`, firewall
  changes, wipes, and reboots without per-turn approval. Answer installer
  prompts automatically — defaults, `E` for confirmations, `12345test` for
  the WebDAV password — and report what was answered. Non-default config
  values still need the user.
- **Relay only the Tailscale login URL** (`https://login.tailscale.com/a/...`)
  and wait; it expires if left unused.
- That authorization does **not** cover: local Mac outside this repo;
  `git reset --hard`, `git push`, force-push, tag deletion, history
  rewrite; other hosts; Tailscale account/ACL changes; publishing repo
  content elsewhere.
- Read-only inspection is always fine.
- **Report what was actually run** and the real outcomes.

## Working Conventions

- Prefer static analysis first (`bash -n`, `shellcheck`, `bats v2/tests`).
  Escalate to live `nrm` installs when static review cannot catch the
  failure mode — still report destructive commands.
- Analyze before editing; check `docs/design-decisions.md` and
  `docs/v2-contract.md` before "fixing" intentional behaviour.
- Wait for approval before making changes unless the user already asked
  for that change.
- Smallest possible change. No opportunistic refactors.
- Show the diff before committing. Commit only when the user asks (unless
  a user rule says otherwise for that turn).
- Bump `V2_VERSION` in `v2/install.sh` on every behavioural change to the
  installer tree. Record user-facing changes under `[Unreleased]` in
  `CHANGELOG.md` and add a `DD-*` entry when rationale is non-obvious.
- Preserve idempotency: re-runs against a provisioned host must stay safe.
- Prefer security over convenience when both achieve the same result; flag
  the trade-off.
- Single source of truth for ports/images/paths:
  `v2/config/defaults.env`. Do not restate literals elsewhere.
- Do not grow a general-purpose reconcile engine (contract + rules).

## Key Paths

| Path | Purpose |
|------|---------|
| `v2/install.sh` | Orchestrator |
| `v2/common.sh` | Shared helpers |
| `v2/config/defaults.env` | Ports, images, paths, chain names |
| `v2/templates/` | Compose, Caddy, dnsmasq |
| `v2/scripts/` | Firewall, refresh-tailnet, GRO, wait |
| `v2/systemd/` | Unit/timer templates |
| `v2/tests/` | Critical bats suite |
| `v2/dev/export-v2.sh` | Portable `.command` exporter |
| `docs/v2-contract.md` | What v2 does / refuses |
| `docs/v2-architecture.md` | Layout and data flow |
| `docs/design-decisions.md` | `DD-*` rationale |

## Constraints

- Root-only, interactive, single-host. No unattended mode.
- Debian 13 (trixie), Ubuntu 24.04 (noble) or Ubuntu 26.04 (resolute)
  only (**DD-102**). Noble live-verified 2026-08-29; resolute
  statically verified only.
- Fixed service bundle — no installation profiles.
- Do not delete or recreate Docker-owned iptables chains; manage only
  project chains and jumps into `DOCKER-USER`.
