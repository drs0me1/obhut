# CLAUDE.md

This file is the working guide for Claude Code (or any AI assistant) in
this repository. It is meant to be the **first file read** at the start of
every new session, before touching `install.sh` or any other file.

## Project Overview

This repository contains `install.sh`, a single Bash script that turns a
fresh Debian 13 (trixie) host into a Tailscale exit-node running a fixed
Docker Compose service bundle, plus a 5-minute self-healing reconcile
timer. See [`README.md`](README.md) for the full functional overview and
[`docs/architecture.md`](docs/architecture.md) /
[`docs/design-decisions.md`](docs/design-decisions.md) for deeper technical
context. Known issues and their severity are tracked in
[`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) and [`TODO.md`](TODO.md).

The script is destructive by nature: it changes firewall rules, systemd
units, the Docker daemon configuration, and network state on a real
server. Treat every change to it as a change to production infrastructure,
even when working in this repository only.

## Language Rules

- **Speak to the user in Turkish.** All conversational replies, questions,
  and explanations directed at the user must be in Turkish.
- **Keep all code, comments, and documentation in English.** This applies
  to `install.sh`, generated helper scripts, systemd unit files, Markdown
  docs, and commit messages — regardless of the conversation language.

## Execution Rules

- **Never execute `install.sh`.** Do not run it directly, via `bash`,
  `sh`, `source`, or any wrapper, under any circumstances — it mutates a
  live system (firewall, Docker, systemd, Tailscale) and cannot be safely
  dry-run.
- **Never run `sudo` or any destructive command** (`rm -rf`, `iptables`,
  `ip6tables`, `nft`, `systemctl` mutating verbs, `docker` lifecycle
  commands such as `up`/`down`/`rm`/`restart`, `git reset --hard`,
  `git push --force`, etc.) **unless the user explicitly asks for that
  specific action in that turn.** A prior approval does not carry over to
  later turns or to different commands.
- Read-only inspection commands (`git status`, `git log`, `git diff`,
  `wc -l`, `grep`, `cat`, `bash -n`, `shellcheck`) are always fine.

## Working Conventions

- **Prefer static analysis over execution.** Reason about `install.sh` by
  reading it, tracing logic by hand, and running `bash -n` / `shellcheck`.
  Do not try to validate behavior by running the script or its generated
  helpers.
- **Analyze before modifying code.** Read the relevant section (and any
  functions/variables it depends on) in full before proposing an edit.
  Confirm whether the pattern is intentional by checking
  [`docs/design-decisions.md`](docs/design-decisions.md) first — several
  things that look like bugs (e.g. staging-chain swaps, fail-closed
  masking, `PartOf` coupling) are deliberate.
- **Wait for approval before making changes.** Do not edit files based on
  an analysis or audit request alone. Only modify files when the user asks
  for a change, and only the files/scope they asked for.
- **Make the smallest possible change.** Avoid opportunistic refactors,
  renames, or reformatting outside the requested scope, especially inside
  `install.sh`.
- **Show diff before committing.** Always show the resulting diff (or
  `git diff`) after an edit and before creating any Git commit; let the
  user review it first.
- **Use small Git commits.** Prefer one logical change per commit over
  large batched commits. Only commit when explicitly asked to.
- **Update tracking docs after every `install.sh` change.** Immediately
  after any change to `install.sh` is applied and verified, update
  `TODO.md` (move the item to Completed / adjust its status),
  `SECURITY_REVIEW.md` (mark the finding resolved, adjust counts, add a
  `Review History` row), and `CHANGELOG.md` (record it under
  `[Unreleased]` and in the current day's "Today's Work" section). Do
  this for every change, not just security fixes.
- **Preserve idempotency.** Any change to `install.sh` must keep re-runs
  against an already-provisioned host safe: detect existing state before
  mutating it, and don't reintroduce unconditional destructive/expensive
  operations on every run.
- **Prioritize security.** When a change has a more secure and a less
  secure way to achieve the same result, default to the more secure one
  and flag the trade-off to the user rather than silently choosing
  convenience.
- **Prefer modular architecture.** When adding new logic of any size,
  prefer isolating it into a clearly named function or a separate
  generated helper script over growing an existing block. Long-term, favor
  extracting embedded heredoc scripts over adding more inline logic to
  them.
- **Avoid duplicated code.** Reuse existing helper functions
  (`state_value`, `owned_file_ok`, `assert_unit_property_*`, etc.) instead
  of re-implementing equivalent checks.
- **Follow ShellCheck recommendations.** Any new or modified Bash code
  should be clean under `shellcheck`; do not add `# shellcheck disable`
  directives without a one-line justification comment, matching the
  existing style in the file.

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | The installer itself — the only file that runs against a real host |
| `README.md` | User-facing functional overview |
| `SECURITY_REVIEW.md` | Tracked, line-referenced security findings by severity |
| `TODO.md` | Prioritized outstanding work |
| `CHANGELOG.md` | User-facing change history |
| `SESSION.md` | Cross-session continuity notes |
| `docs/architecture.md` | System/network/systemd architecture detail |
| `docs/design-decisions.md` | Rationale for non-obvious choices |
| `docs/profiles.md` | Installation-profile design (current/future) |
| `docs/testing.md` | Testing strategy and known gaps |

## Constraints and Guardrails

- Root-only, single-host, interactive script — there is no supported
  non-interactive or unattended invocation path today.
- Debian 13 (trixie) only; the script hard-fails on any other OS/version.
- The firewall, Compose, and reconcile logic assume the exact fixed
  six-service bundle described in `README.md`. Do not assume partial or
  configurable service sets exist yet — see `docs/profiles.md` for the
  current state of that idea.
- Several embedded heredoc scripts (the firewall helper, the reconcile
  helper, the recovery helper) are **not** covered by `shellcheck
  install.sh` / `bash -n install.sh` because they are heredoc string
  literals. Treat them with the same scrutiny as the outer script when
  reviewing or editing.

## Common Tasks

- **Security/architecture audits**: read the full file, cross-reference
  `SECURITY_REVIEW.md` for prior findings, and report — do not modify
  `install.sh` as part of an audit unless separately asked.
- **Adding a finding or task**: update `SECURITY_REVIEW.md` and/or
  `TODO.md` directly; keep entries short, prioritized, and line-referenced
  where applicable.
- **Documentation updates**: keep `README.md` and `docs/*.md` in sync with
  the actual current behavior of `install.sh` — verify against the script
  rather than assuming prior documentation was correct.

## Testing Expectations

- There is no CI pipeline yet, and only partial unit-test coverage
  (tracked in `docs/testing.md` / `TODO.md`): `scripts/lint-embedded-scripts.sh`
  statically lints all six embedded heredoc scripts, and `test/*.bats`
  (run via `bats test/`) unit-tests a growing subset of their pure-logic
  functions. The baseline checks before proposing any `install.sh` change
  remain `bash -n install.sh` and `shellcheck install.sh`; also run
  `./scripts/lint-embedded-scripts.sh` and `bats test/` when the change
  touches an embedded heredoc script or a function they cover.
- Do not claim a change "works" without either static verification or the
  user's own confirmation from a real test run — this assistant must never
  execute the script itself (see **Execution Rules**).

## Related Documentation

- [`README.md`](README.md) — what the project does and how it's structured
- [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) — known findings by severity
- [`TODO.md`](TODO.md) — prioritized outstanding work
- [`CHANGELOG.md`](CHANGELOG.md) — history of user-facing changes
- [`SESSION.md`](SESSION.md) — notes carried between sessions
- [`docs/architecture.md`](docs/architecture.md)
- [`docs/design-decisions.md`](docs/design-decisions.md)
- [`docs/profiles.md`](docs/profiles.md)
- [`docs/testing.md`](docs/testing.md)
