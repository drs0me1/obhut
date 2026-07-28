# Session Notes

This file carries context between Claude Code sessions for this
repository. Update it at the end of a working session so the next session
can pick up without re-deriving context.

## Current Task

**Session complete.** This was one continuous, very large session:
docs scaffolding and the original static audit (prior sub-session) → M7
Tier 2 unit-test survey → a full live audit of the user's server →
four live Tier 3 install attempts (three found and fixed real bugs —
**H1** regression, **H5**, **H6** — the fourth, with **M1**'s hardening
added, succeeded cleanly) → a full operational stress test (reboot,
deliberate drift injection, resource-limit enforcement, real
WireGuard/Tailscale-exit-node traffic, CPU stress — everything passed)
→ a final architecture review (reconcile's monitored-state list, systemd
dependencies, IPv6, container DNS, wg-easy's kernel-module approach,
Caddy/dnsmasq boot-race safety — no functional defects found) → one new
feature from that review (disk-space monitoring in reconcile) → tagging
**R1.0** and exporting `install.sh` to `~/Desktop/install-R1.0.sh` → this
end-of-session documentation pass (reviewed every `.md` file in the repo
for accuracy against the final 4343-line `install.sh`; fixed several
that had gone stale during the day — see `CHANGELOG.md`'s "End-of-session
documentation pass" entry for exactly what changed and why).

**As of this update, the working tree has uncommitted documentation
changes** (this pass) — the user explicitly asked not to commit them.
Everything else through the `R1.0` tag (commit `7138c2f`) is committed.

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
- **H6 + third/fourth live installs + M1 completion (2026-07-28)**: a
  second live attempt reached Stage 7 before failing on a different bug
  (**H6** — see `SECURITY_REVIEW.md`/`docs/design-decisions.md` DD-12);
  fixed, then a third attempt completed all 7 stages successfully for the
  first time. **M1**'s deferred `cap_drop`/`cap_add`/`read_only` config
  was then determined empirically via throwaway `docker run` containers
  (never the real stack) and applied; a fourth live install confirmed no
  regression. See `CHANGELOG.md` for full detail on each attempt.
- **Full operational stress test (2026-07-28)**: with the user's explicit
  broad testing latitude (no production data on the host), validated real
  admin-configured services, a real WireGuard client (0% loss, ~58-107ms
  RTT), genuinely-active Tailscale exit-node routing, a full host reboot
  (confirming **H1**'s fix persists, not incidental), deliberate
  simultaneous drift injection (all three repaired within one reconcile
  cycle — the first proof this project's self-healing loop actively
  repairs, not just reports), cgroup memory-limit enforcement, a real
  `unpackerr` extraction workload, and a 4-core CPU stress test. No new
  bugs found — confirmatory.
- **Final architecture review + disk-space monitoring + R1.0
  (2026-07-28)**: reviewed reconcile's full monitored-state list, systemd
  dependencies, IPv6, container DNS, and wg-easy's kernel-module approach
  against the server's actual intended use, with live verification of
  each — no functional defects found (see `docs/design-decisions.md`
  DD-12/DD-13 and `CHANGELOG.md` for the full writeup, including the
  Caddy/dnsmasq boot-race analysis). Added the one real gap found —
  disk-space monitoring — to `master-network-reconcile`, tested live
  against both a real disk and an artificially filled tmpfs. Tagged
  **R1.0** and exported `install.sh` to `~/Desktop/install-R1.0.sh`
  (hash-verified identical).
- **End-of-session documentation pass (2026-07-28, this update, not
  committed)**: reviewed every `.md` file in the repo; found and fixed
  staleness in `README.md` (Current Limitations still claimed containers
  had no resource limits/hardening — false since **M1**; still listed
  `chown -R` as a limitation — false since **M2**, an earlier session)
  and `docs/architecture.md` (stage/heredoc line ranges had drifted from
  today's edits); added `docs/design-decisions.md` DD-12/DD-13. See
  `CHANGELOG.md`'s "End-of-session documentation pass" entry for the
  complete list.

## Remaining Work

- Nothing security/functionality-related is open that isn't a deliberate,
  user-confirmed deferral: **M3** (installation profiles — "m3 şimdilik
  atlayalım") and **M7**'s remainder (CI wiring needs a non-interactive
  invocation mode that doesn't exist yet; `check_ipv4_policy`/
  `check_ipv6_policy` unit tests are more integration-shaped; Tier 3
  itself stays manual/relayed rather than CI-automated).
- **The server itself**: configured with real admin accounts on every
  service, a real WireGuard client (the user's Mac), and Tailscale
  exit-node routing enabled — no longer a "just installed" blank state.
  Whether the user keeps using this specific host as real production or
  keeps reimaging it for further test cycles is their call, not yet
  decided in-session.
- **This documentation pass is uncommitted** (by explicit instruction) —
  a future session (or the user directly) should commit it once reviewed,
  or ask for the commit if it's still needed.

## Recommended Next Step

1. Commit this documentation pass (`README.md`, `docs/architecture.md`,
   `docs/design-decisions.md`, `CHANGELOG.md`, `TODO.md`, `SESSION.md`) —
   left uncommitted per this turn's explicit instruction, but there's no
   reason to leave it that way indefinitely once reviewed.
2. Decide the server's fate: real production vs. continued disposable
   test target — affects how freely future sessions can test against it.
3. If more work is wanted: **M3** (installation profiles) or **M7**'s
   remainder, both deliberately deferred, not urgent.

Whichever is chosen, keep following the standing per-change rule: analyze
and flag risk first, apply only after explicit approval, verify with
`bash -n`/`shellcheck`/`bats test/` (and `scripts/lint-embedded-scripts.sh`
for heredoc changes), show the diff, then update
`TODO.md`/`SECURITY_REVIEW.md`/`CHANGELOG.md`, then commit (unless told
not to, as in this turn).

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
  remediation, so status stays consistent across `TODO.md`,
  `CHANGELOG.md`, and this file.
- **Correction:** an earlier version of this file referenced a persistent
  memory file, `project_intended_architecture.md`, as recording the
  user's own narrated target architecture. That file does not actually
  exist in this assistant's cross-session memory directory (verified
  2026-07-28) — the reference was stale/incorrect. This project's two
  real memory files are `debian-server-installer-language-pref` and
  `debian-server-installer-commit-policy`; there is no separate
  architecture-narration memory. Rely on this repo's own docs
  (`docs/architecture.md`, `docs/design-decisions.md`) instead.
