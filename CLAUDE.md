# CLAUDE.md

This file is the working guide for Claude Code (or any AI assistant) in
this repository. It is meant to be the **first file read** at the start of
every new session, before touching `install.sh` or any other file.

## Project Overview

This repository contains `install.sh`, a single Bash script that turns a
fresh Debian 13 (trixie) host into a Tailscale exit-node running a fixed
Docker Compose service bundle, plus a 20-minute self-healing reconcile
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
- **`install.sh` is Turkish throughout** — both its comments and the
  messages it prints. This includes the generated helper scripts and
  systemd unit descriptions embedded in it. (Revised 2026-07-29: the rule
  used to say "keep all code and comments in English", but the file had
  always been ~73% Turkish-commented, and following the old rule was
  producing English blocks inside Turkish ones. The rule now matches the
  file; the English comments added on 2026-07-28 were translated back.)
- **Markdown documentation and commit messages stay in English.** These
  are already consistently English across every file, and they are the
  project's technical record rather than something read alongside the
  script's Turkish output. Do not mix languages within either.
- **`test/*.bats` and `scripts/*.sh` stay English** for comments and, in
  the case of bats, for `@test` names specifically: Turkish `@test` names
  were found to break `bats` under this workstation's `tr_TR.UTF-8`
  locale. Their user-facing error strings may be Turkish, matching
  `install.sh`.
- The short version: **each artifact is internally consistent.** When
  adding to a file, match the language already in it rather than the
  language of the conversation.

## Execution Rules

- **The `nrm` host is a disposable test target under standing
  authorization (2026-07-31).** The user's instruction: unless they say
  otherwise, that server exists to test whatever needs testing, the data
  on it is worthless, and the assistant may take full control of it. So
  on `nrm` — and only on `nrm` — running `install.sh`, `sudo`,
  `systemctl` mutating verbs, `docker` lifecycle commands, firewall
  changes, service resets, wiping state, and rebooting no longer need
  per-turn approval. Answer every `install.sh` prompt automatically —
  the default for each value, `E` (yes) for each confirmation, and
  `12345test` for the WebDAV password (see
  [`docs/testing.md`](docs/testing.md) Tier 3 for the `tmux` relay
  methodology, still needed because the prompts read `/dev/tty` and
  can't be driven via piped stdin) — and report the answers used rather
  than asking. A *non*-default configuration value is still the user's
  call.
- **The one prompt that must still be relayed is the Tailscale login
  URL.** Only the user can complete that browser authentication, so
  forward the `https://login.tailscale.com/a/...` link the moment it
  appears and wait. It expires (410) if it sits unused while other
  round-trips happen — which is exactly why every *other* prompt is now
  answered locally instead of relayed.
- **That authorization is scoped to the test host and does not travel.**
  Everything below still needs the user's explicit, specific approval in
  the turn it happens:
  - anything on the user's local Mac outside this repository's working
    tree — and inside it, `git reset --hard`, `git push`,
    `git push --force`, tag deletion, or any history rewrite;
  - anything on a *different* host, or on the user's Tailscale account
    itself (removing tailnet nodes, changing ACLs, rotating auth keys)
    — account state outlives the reimaged server;
  - anything whose blast radius reaches outside the disposable host,
    including publishing, sending, or otherwise transmitting repository
    content anywhere.
- Read-only inspection commands (`git status`, `git log`, `git diff`,
  `wc -l`, `grep`, `cat`, `bash -n`, `shellcheck`) are always fine, on
  either machine.
- **Report what was actually run.** The point of the standing
  authorization is to remove approval latency, not visibility: state the
  destructive commands executed and their real outcomes, including
  failures.

## Working Conventions

- **Default to static analysis; escalate to live execution only with
  explicit approval.** Reason about `install.sh` by reading it, tracing
  logic by hand, and running `bash -n` / `shellcheck` first — this
  remains the right default for most changes. Live testing (see
  **Execution Rules** and [`docs/testing.md`](docs/testing.md) Tier 3)
  is the tool for anything static review structurally can't catch (three
  real bugs — **H1**'s regression, **H5**, **H6** — were only found this
  way) and for validating fixes actually hold up (a reboot, deliberate
  drift injection, resource-limit enforcement, and a real workload all
  confirmed **H1**/**M1** on 2026-07-28), but it's still an escalation
  that needs the user's go-ahead, not the default mode.
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
  `git diff`) after an edit and before creating any Git commit.
- **Use small Git commits, and commit after every completed unit of
  work.** Prefer one logical change per commit over large batched
  commits. Commit as soon as a change is verified (`bash -n`/`shellcheck`/
  `bats test/` clean, diff shown) without waiting to be asked each time
  (reversed 2026-07-28 from an earlier "only commit when explicitly
  asked" convention) — but this doesn't apply to actions outside git
  commits (file edits, live host commands, etc.), which still need their
  own explicit approval per the rules above.
- **Bump the version suffix on every `install.sh` change.**
  `MASTER_SETUP_VERSION` (line 8) carries a revision suffix after the base
  version: `2026.07.29-v1rc-1`, `-2`, and so on. Increment it as part of
  the same edit that changes `install.sh`, and state the resulting version
  when reporting the change back to the user. The counter restarts at `-1`
  when the base version changes (e.g. `v1rc` → `v1`). Its purpose is
  identification, not release management: it makes a deployed host
  self-report exactly which revision it was built from, which is the gap
  that let the server run several fixes behind the repository on
  2026-07-28 without anything noticing. Git tags remain separate and are
  created only after live verification.
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
- **Do not add comments to `install.sh`.** As of 2026-08-03 (`Q1-24` then
  `Q1-25`) the script carries no explanatory comments at all: 1179 comment
  lines went to nine, and those nine are load-bearing rather than
  editorial — eight `#!` shebangs for the heredoc-generated helper
  scripts, and one `# shellcheck disable=SC1091` without which
  `shellcheck install.sh` fails. The operator reads this script through
  its documentation and its printed output, never in an editor, so an
  inline comment is read by nobody and decays silently because nothing
  verifies it. **Every explanation goes in a `DD-` entry in
  `docs/design-decisions.md`**, with the finding in `SECURITY_REVIEW.md`
  and the user-visible change in `CHANGELOG.md`. If a block seems to need
  a comment to be understandable, that is a signal to name the function
  better or write the `DD-` entry, not to add the comment. Stage
  boundaries are found with `grep -n 'progress_stage_begin [0-7] '`; the
  `AŞAMA` banners were removed because each merely duplicated the
  `progress_stage_begin` line printed to the operator directly below it.
  This applies to `install.sh` only — `test/*.bats`, `scripts/*.sh` and
  the Markdown docs keep their normal commenting. See **DD-44**.

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
  statically lints all seven embedded heredoc scripts, and `test/*.bats`
  (run via `bats test/`) unit-tests a growing subset of their pure-logic
  functions.
- **`./scripts/check-all.sh` runs all four verification steps in one
  command** — `bash -n install.sh`, `shellcheck install.sh`, the embedded
  lint and `bats test/` — and is the normal way to run them. It does not
  stop at the first failure, and a check whose tool is missing is reported
  as *doğrulanamadı* with a non-zero exit rather than passing silently.
  The individual commands still work and are the right thing when
  iterating on one of them. The baseline before proposing any `install.sh`
  change remains `bash -n` and `shellcheck`; run the embedded lint and
  `bats test/` too when the change touches an embedded heredoc script or a
  function they cover — or just run the wrapper.
- Do not claim a change "works" without either static verification or the
  user's own confirmation from a real test run — this assistant must never
  execute the script itself (see **Execution Rules**).
