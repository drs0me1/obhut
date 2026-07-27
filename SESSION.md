# Session Notes

This file carries context between Claude Code sessions for this
repository. Update it at the end of a working session so the next session
can pick up without re-deriving context.

## Current Task

End-of-session documentation review (2026-07-28): closing out this
session's work on **M7** (testing strategy) — two new `bats-core` test
files were added, and every Markdown document was re-read to sync
`TODO.md`/`SECURITY_REVIEW.md`/`CHANGELOG.md`/`docs/testing.md` and (where
today's work made an existing claim false) `README.md`/`CLAUDE.md`/
`docs/design-decisions.md`. No `install.sh` change was made in this
session; `install.sh` still carries the cumulative, uncommitted edits from
prior sessions (currently 4275 lines, `bash -n`/`shellcheck` clean).

## Completed Work

All fifteen originally-numbered remediations from the 2026-07-27 audit are
resolved, plus one unnumbered cleanup and two partial items:

- **C2** — `TS_AUTHKEY` prompt removed entirely; installer always uses
  Tailscale's interactive browser login.
- **M6** — wg-easy unattended-bootstrap subsystem removed entirely (248
  lines); admin setup is now fully manual, same as Portainer/SFTPGo.
- **M5** — explicit "ip6tables bulunamadı" diagnostic added to
  `check_ipv6_policy()`.
- **H1** — `SYS_MODULE`/`/lib/modules` removed from wg-easy; replaced by
  an independent host-side `modprobe wireguard`, hardened with a
  persistent `/etc/modules-load.d/wg-easy.conf` and a functional
  `ip link add ... type wireguard` probe. Still needs real-server
  functional verification (deferred to the user's live SSH test).
- **H2 / H3** — confirmed intentional by the user (reconcile's
  config-revert behavior; `PartOf` cascading-restart coupling); resolved
  by adding explicit warnings to the final install summary, not by
  changing behavior.
- **Group 1 (M4, L1, L2, L4, L5)** — five low-risk documentation/comment
  fixes (INSECURE comment, apt conffile flags, ephemeral-device note, DNS
  split comment, first-run admin setup warning).
- **M2** — unconditional `chown -R` on the media tree replaced with a
  `find`-scoped `chown` that only touches ownership-mismatched entries.
- **Legacy reboot-timer cleanup** (unnumbered) — deleted
  `remove_managed_scheduled_reboot()` and its Stage 7 re-verification (61
  lines); confirmed with the user this deployment target never has
  r3-era units to migrate away from.
- **L3** — removed `tailscale-udp-gro.service`'s continuous reconcile
  integration (~54 lines); one-time Stage 2 setup unchanged.
- **M1 (🟡 partial)** — `no-new-privileges` and hardware-sized
  `mem_limit`/`cpus` applied to `qbittorrent`/`unpackerr`. `cap_drop:
  [ALL]` and `read_only` deliberately deferred to the live SSH test.
- **C1** — resolved as accepted risk (no code change): Portainer's
  `docker.sock` mount stays as-is; a socket-proxy was reconsidered and
  found a weak fit for Portainer specifically; user confirmed active use
  and accepted the risk, scoped by network exposure. Documented in
  `README.md`.
- **H4** — added `scripts/lint-embedded-scripts.sh`, which extracts and
  independently lints all six embedded heredoc scripts; first real run
  found no actual bugs, only expected excluded `SC2016` notices.
- **M7 (🟡 partial, this session's main work)** — Tier 1 (via H4) done.
  Tier 2 started: two new files under `test/`, run via `bats test/`:
  - `test/reconcile_functions.bats` — `state_value` and `owned_file_ok`
    (`master-network-reconcile` heredoc), 7 cases (2 self-skip on this
    macOS dev workstation's non-GNU `stat`).
  - `test/firewall_functions.bats` — `route_value`, `chain_rules_exact`,
    `jump_is_first_and_single`, `forward_prefix_is_exact`,
    `docker_forward_has_no_terminal_drop`, `no_stale_staging_chains`
    (`docker-tailscale-fw` heredoc), 20 cases, all passing, using fake
    `ip`/iptables/ip6tables stand-ins instead of the real binaries.
  - 27 test cases total, all passing. Neither file sources a full
    heredoc script (both have unsafe top-level side effects — `flock`,
    `systemctl`); each test file extracts only the specific function
    bodies it needs via the same `sed`-marker technique as
    `scripts/lint-embedded-scripts.sh`.
  - Along the way, fixed two test-infrastructure issues (not `install.sh`
    bugs): Turkish-language `@test` names broke bats under this shell's
    `tr_TR.UTF-8` locale — renamed to English, consistent with the
    project's English-code convention; `owned_file_ok`'s GNU-`stat`-
    specific cases now self-skip with a clear reason on this non-GNU-stat
    macOS workstation instead of failing.
  - `install.sh` was not touched by any of this.
- Documentation sync (this session): updated `docs/testing.md`,
  `SECURITY_REVIEW.md` (M7 entry), `TODO.md` (M7 entry), `CHANGELOG.md`
  (two new dated entries), `README.md` ("No CI..." limitation bullet +
  one Roadmap bullet), `CLAUDE.md` (Testing Expectations section), and
  `docs/design-decisions.md` (DD-9's "proposed mitigation" language,
  since a real one now partially exists) — all specifically because
  today's bats-test work made their previous wording inaccurate.

## Remaining Work

- **M1 remainder**: `cap_drop: [ALL]` for `qbittorrent`/`unpackerr` and
  `read_only` rootfs — explicitly deferred to the live SSH test phase.
- **M3**: installation-profile scoping (`docs/profiles.md`) — the user
  explicitly asked to skip this for now ("m3 şimdilik atlayalım").
- **M7 remainder**:
  - `check_ipv4_policy`/`check_ipv6_policy` (the composite functions that
    call the tested predicates together against real global state) are
    more integration-shaped and were left untested here — likely a
    better fit for Tier 3 than a unit test.
  - The other four embedded scripts (`tailscale-udp-gro`,
    `master-compose-ipv4`, `master-docker-netfilter-recovery`,
    `caddy-tailnet-env`) haven't been surveyed yet for further
    pure-logic unit-test candidates.
  - Tier 3 (disposable-VM integration testing) — not attempted.
  - CI pipeline wiring (e.g. GitHub Actions) for both
    `scripts/lint-embedded-scripts.sh` and `bats test/` — no CI exists in
    this repo yet, not confirmed as wanted.
- **Live SSH test** (reserved for "the end" per the user's stated plan):
  verify wg-easy's `wg0` interface actually comes up (H1), verify
  qbittorrent's linuxserver.io entrypoint still starts if/when
  `cap_drop: [ALL]` is applied (M1 remainder), and validate the whole
  stack end-to-end. This assistant must never execute `install.sh` or
  fabricate test results.
- **Known documentation drift found but *not* fixed this session** (out
  of scope per this session's "only touch files affected by today's
  work" instruction — flagged here for a future doc-sync pass instead):
  `README.md`'s "Roadmap" section intro still says only **C2**/**M6** are
  "done so far," and several of its bullets (container hardening, CI/
  static-analysis) describe work that's since been partially completed
  (**M1** Tier 1, **H4**). It needs a fuller pass reconciling it against
  `TODO.md`'s actual Completed section, not just the testing-specific
  edit made this session.

## Recommended Next Step

No explicit next topic was agreed before this session-end review. Natural
options, roughly in order of how directly they continue what's in
progress:

1. Continue **M7**: survey the four remaining embedded scripts
   (`tailscale-udp-gro`, `master-compose-ipv4`,
   `master-docker-netfilter-recovery`, `caddy-tailnet-env`) for further
   pure-logic unit-test candidates, following the same extract-the-
   function-body pattern.
2. Do the flagged `README.md` Roadmap-section drift cleanup (see above) —
   small, low-risk, documentation-only.
3. Pick up **M3** (installation profiles) if the user is ready to revisit
   it, or move toward planning the live SSH test phase, which will also
   resolve **M1**'s remainder and **H1**'s outstanding real-server
   verification.

Whichever is chosen, keep following the standing per-change rule: analyze
and flag risk first, apply only after explicit approval, verify with
`bash -n`/`shellcheck`/`bats test/` (and `scripts/lint-embedded-scripts.sh`
for heredoc changes), show the diff, then update
`TODO.md`/`SECURITY_REVIEW.md`/`CHANGELOG.md`.

## Notes

- `install.sh` must never be executed as part of this work — analysis is
  static only (`bash -n`, `shellcheck`, `bats test/`, manual reading).
- All conversation with the user happens in Turkish; all code, comments,
  commit messages, and documentation stay in English (per `CLAUDE.md`).
- No commits have been created for any of this session's work; the user
  has explicitly asked not to commit each time.
- Reference `SECURITY_REVIEW.md` for finding IDs (C1/C2, H1-H4, M1-M7,
  L1-L5) before starting any remediation so status stays consistent
  across `TODO.md`, `CHANGELOG.md`, and this file.
- The persistent memory file `project_intended_architecture.md` (outside
  this repo, under Claude Code's memory directory) records the user's own
  narrated target architecture; consult it if a future session needs that
  context again.
