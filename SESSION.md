# Session Notes

This file carries context between Claude Code sessions for this
repository. Update it at the end of a working session so the next session
can pick up without re-deriving context.

## Current Task

Same session, continued into a much bigger phase: after finishing the M7
Tier 2 survey (see below), did a full live audit of the user's actual
production server over SSH (`ssh nrm`), then — with the user's explicit,
turn-by-turn approval — ran three real Tier 3 install tests against that
same server, reimaged clean each time. First attempt failed at Stage 5
(**H1** regression + **H5**, both fixed). Second attempt got all the way
through Stage 6 (a first) and failed at Stage 7 (**H6**, found and
fixed). **Third attempt completed all 7 stages successfully
end-to-end** — the first fully clean install of this repo's `install.sh`,
confirmed live (all containers healthy, all core units active, zero
failed units, `master-network-reconcile --check` exits `0`). See
`CHANGELOG.md`'s three "live Tier 3 install test" entries for the full
narrative. This closes out the first full validation cycle of the
2026-07-28 remediation work.

Note: as of this session start, all prior work (docs scaffolding +
`install.sh` hardening through **M2**/**L3**/**M1**-partial/**C1**/**H4**
+ the first two `.bats` files) was already committed as `b549d59`; the M7
Tier 2 survey work (`test/gro_functions.bats`) was committed as `cf4c257`
partway through this session, once the user changed the commit policy to
"commit after every completed unit of work" (see Notes below).

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
- Documentation sync (prior session): updated `docs/testing.md`,
  `SECURITY_REVIEW.md` (M7 entry), `TODO.md` (M7 entry), `CHANGELOG.md`
  (two new dated entries), `README.md` ("No CI..." limitation bullet +
  one Roadmap bullet), `CLAUDE.md` (Testing Expectations section), and
  `docs/design-decisions.md` (DD-9's "proposed mitigation" language,
  since a real one now partially exists) — all specifically because
  that session's bats-test work made their previous wording inaccurate.
- **M7 continued (this session, 2026-07-28)**: surveyed the four
  remaining embedded scripts for pure-logic unit-test candidates.
  `tailscale-udp-gro` has one standalone function, `add_default_netdev`;
  the other three (`master-compose-ipv4`,
  `master-docker-netfilter-recovery`, `caddy-tailnet-env`) have none —
  each is almost entirely a `sleep`-based wait loop plus real side
  effects (file writes, `flock`, `systemctl restart/start`), with no
  isolable pure logic short of refactoring `install.sh` itself (out of
  scope for a testing-only pass; flagged in `docs/testing.md` instead of
  attempted). Added `test/gro_functions.bats` (5 cases) using the same
  extraction technique as the other two `.bats` files. All 5 cases
  self-skip on this dev workstation: this macOS's default `/bin/bash` is
  3.2, which has no associative-array support at all (unlike the
  reconcile tests' GNU-`stat` gap, which was just a flag difference) —
  `add_default_netdev`'s dedup guard needs `SEEN` declared as one, so a
  `declare -gA` feature probe in `setup()` self-skips with a clear reason
  instead of misbehaving under a plain array. Runs for real on the
  Debian 13 target's bash 5.x (not verified live here — this assistant
  never executes `install.sh` or its embedded scripts). 32 test cases
  total across `test/`. `install.sh` untouched throughout.
  Synced `TODO.md`, `SECURITY_REVIEW.md` (M7 entry + a new Review History
  row), `docs/testing.md`, and `CHANGELOG.md` to match. Committed as
  `cf4c257` ("test: add gro_functions.bats for tailscale-udp-gro; sync M7
  docs") once the user changed the commit policy this session (see Notes).
- **Live server audit (this session, 2026-07-28, read-only)**: at the
  user's request, connected to the live production server (`ssh nrm`,
  connects directly as `root`) and checked service health, container
  status, and logs across all 6 services plus `tailscaled`/`docker`/
  `caddy`/`dnsmasq`/the reconcile timer. Found the stack fully healthy
  (2+ days with zero reconcile repairs, real traffic flowing through
  `qbittorrent`/`wg-easy`/`sftpgo`, no errors in any container log). Also
  discovered the live server was still running the **original,
  pre-remediation** script (wg-easy still had `CAP_SYS_MODULE`, no `M1`
  container hardening) — none of this repo's fixes had been deployed yet.
  A restart of `qbittorrent` (explicitly requested) confirmed its
  earlier-reported "temporary password" log line was stale — a real
  password had since been set via the WebUI, so **Critical finding C3**
  from the original ad-hoc audit report (not a `SECURITY_REVIEW.md`
  finding — that was from an earlier, pre-`SECURITY_REVIEW.md` audit
  report given directly to the user in conversation) was already
  resolved on the live box, just not by this repo's tracked remediations.
- **Live Tier 3 install test (this session, 2026-07-28)**: user asked to
  re-run `install.sh` against the live server to bring it up to date, and
  to use the opportunity to test the script itself. This assistant
  initially declined to execute `install.sh` per the standing rule, and
  the user then reimaged the server clean specifically to serve as a
  disposable test target. Identity was verified independently (same
  public IP as before, but 2-minute uptime / 1% disk / no Docker — an
  independent check, not just trusting the `ssh nrm` alias). Given the
  target was now genuinely empty and the user gave explicit, informed,
  turn-by-turn approval for each step, this assistant proceeded — see
  `docs/testing.md` Tier 3 for the full methodology (tmux-based prompt
  relay, since `install.sh`'s prompts read `/dev/tty` directly and can't
  be driven via piped stdin) and `CHANGELOG.md` for the full narrative.
  Result: Stages 0-4 succeeded; Stage 5 failed on wg-easy's healthcheck.
  Diagnosed and fixed, live-confirmed then applied to `install.sh`:
  - **H1 regression**: Stage 4 only `modprobe`d `wireguard`, not
    `ip6_tables`/`ip6table_nat`, which `wg-quick up wg0`'s legacy-ip6tables
    PostUp rules also need — and nothing else on this host loads them
    (Debian 13's own `ip6tables` uses the nftables backend). Fixed:
    Stage 4's modprobe step is now a loop covering all three modules, and
    `/etc/modules-load.d/wg-easy.conf` was updated to match.
  - **H5 (new finding)**: wg-easy's `healthcheck` asserted a fixed
    WireGuard listen port, which can never be right on a fresh install
    since wg-easy v15+ only accepts the port via its web UI's first-run
    setup wizard (a deliberate consequence of **M6**, not accounted for
    when the healthcheck was written). Fixed: the healthcheck now only
    checks that `wg0` exists and is up.
  - Both fixes verified with `bash -n`, `shellcheck`,
    `scripts/lint-embedded-scripts.sh`, and `bats test/` (all clean).
    `install.sh` 4275 → 4290 lines. `SECURITY_REVIEW.md` (H1 addendum +
    new H5 entry + updated findings table/count), `TODO.md`, and
    `CHANGELOG.md` all synced. Committed (see git log for the exact
    commit — created per the new "commit after every operation" policy).
  - The server itself is still mid-install: Stage 6 (DNS/Caddy) and
    Stage 7 (final verification) never ran because Stage 5 aborted first.
    It needs a follow-up install run (or a manual continuation) to reach
    a complete, verified state.

## Remaining Work

- **M1 remainder**: `cap_drop: [ALL]` for `qbittorrent`/`unpackerr` and
  `read_only` rootfs — was deferred to "the live SSH test phase," which
  has now happened and produced a fully working server; a good next
  candidate to test live, empirically, on this same host.
- **H1's original deferred item**: real-server confirmation that wg-easy
  brings up `wg0` successfully — now confirmed, repeatedly, across all
  three Tier 3 attempts.
- **M3**: installation-profile scoping (`docs/profiles.md`) — the user
  explicitly asked to skip this for now ("m3 şimdilik atlayalım").
- **M7 remainder**:
  - `check_ipv4_policy`/`check_ipv6_policy` — more integration-shaped,
    likely a Tier 3 concern rather than a unit test.
  - `master-docker-netfilter-recovery`'s restart-cooldown check is a
    possible future unit-test candidate, but only after extracting it
    into a named function (a small `install.sh` refactor, not attempted).
  - CI pipeline wiring — no CI exists in this repo yet, not confirmed as
    wanted. Tier 3 itself remains manual/relayed rather than automated;
    real CI wiring would also need a non-interactive invocation mode,
    which doesn't exist today.
- **Known documentation drift, still not fixed** (flagged in a prior
  session, still open): `README.md`'s "Roadmap" section intro still says
  only **C2**/**M6** are "done so far," undercounting everything done
  since, including today's **H1** regression fix and **H5**/**H6**.

## Recommended Next Step

1. Revisit **M1**'s remainder (`cap_drop: [ALL]`, `read_only`) live on
   the now fully-installed server — the natural next live-testing item,
   directly enabled by the Tier 3 success.
2. The `README.md` Roadmap drift cleanup remains a small, low-risk,
   documentation-only task that could be picked up any time.
3. Consider whether the user wants to keep this specific server as the
   long-term production box now, or continue treating it as a disposable
   test target for further changes.

Whichever is chosen, keep following the standing per-change rule: analyze
and flag risk first, apply only after explicit approval, verify with
`bash -n`/`shellcheck`/`bats test/` (and `scripts/lint-embedded-scripts.sh`
for heredoc changes), show the diff, then update
`TODO.md`/`SECURITY_REVIEW.md`/`CHANGELOG.md`, then commit.

## Notes

- **`install.sh` execution policy (revised 2026-07-28):** the original
  blanket "never execute `install.sh`" rule has been superseded by real
  practice — see the Tier 3 write-up above and in `docs/testing.md`. The
  actual working rule now is: this assistant may run `install.sh` (or any
  other mutating command against a real host) only with the user's
  explicit, specific approval for that exact action in that turn, never
  by inferring consent from an earlier, different approval, and never by
  choosing configuration values on the user's behalf — those are always
  relayed to and answered by the user directly. Static analysis
  (`bash -n`, `shellcheck`, `bats test/`) remains the default mode for
  everything else.
- All conversation with the user happens in Turkish; all code, comments,
  commit messages, and documentation stay in English (per `CLAUDE.md`).
- **Commit policy (changed 2026-07-28):** the user reversed the earlier
  "don't commit each time" preference — commit after every completed unit
  of work now, without asking first. (Recorded in this assistant's
  cross-session memory as well, not just here.)
- Reference `SECURITY_REVIEW.md` for finding IDs (C1/C2, H1-H6, M1-M7,
  L1-L5 — note **H5**/**H6** are new, post-audit) before starting any
  remediation
  so status stays consistent across `TODO.md`, `CHANGELOG.md`, and this
  file.
- The persistent memory file `project_intended_architecture.md` (outside
  this repo, under Claude Code's memory directory) records the user's own
  narrated target architecture; consult it if a future session needs that
  context again.
