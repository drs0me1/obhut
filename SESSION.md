# Session Notes

This file carries context between Claude Code sessions for this
repository. Update it at the end of a working session so the next session
can pick up without re-deriving context.

## Current Task

**`Q1-21` implements persistent Tailscale 410 early recovery and is locally
verified. At the operator's explicit request it is exported, without prior
live verification, as the untagged `R2.6` manual-test candidate. `R2.5`
remains the latest live-verified tagged release.**

Branch is `quantum`, which forked from `V1-20` and swaps only the web file
manager for FileBrowser Quantum (DD-27). `master` answered the same
question with dufs (`V2-2`/`R2.1`, DD-26) — the two lines are alternatives,
not a sequence.

Current release:

| | |
|---|---|
| Version | `2026.08.02-Q1-21` (6506 lines) |
| SHA256 | `10b746f891f908f98efd92204a8c238c9e46eb500745c9daf68462d9ae3ccaf8` |
| Export | `versiyon/R2.6/`, byte-identical to source commit `a10a300`; manual-test candidate, no `Q1-21`/`R2.6` tags yet |
| Live | Q1-21 input signature measured twice on clean R2.5 and equivalent early child/restart recovery succeeded; exact automatic Q1-21 branch still pending |
| Tests | 175 cases across thirteen `.bats` files (163 executed, 12 expected macOS skips); `./scripts/check-all.sh` clean |
| Bundle | nine canonical entries, `sha256sum -c` all OK |

Q1-21 is the Stage 2 follow-up to the repeated offline-node login failure:

- Two independent R2.5 links/nodekeys entered `NeedsLogin`, offline, empty-ID
  state with the exact 410 health line after 27/42 seconds. The admin-console
  rows existed but were offline because the daemon never received an identity.
- `tailscale_login_state()` reads LocalAPI JSON. Three consecutive dead
  samples trigger DD-37's existing daemon restart/new-link path immediately;
  any other sample resets the counter and every unknown stall keeps the
  300-second fallback.
- A zero exit from `tailscale up` now gets 15 seconds to prove `Running`,
  online, node ID and IP. Thirteen cases cover classification, persistence and
  the successful transient-410 path. No journal classifier was reintroduced.

Q1-20 remains the reconcile/dependency remediation requested after the R2.4
line-by-line review:

- Persistent Docker/tailscaled/address failure now exits non-zero after a
  bounded address grace and prints Tailscale backend/online/health/key-expiry
  diagnostics. Lock/job overlap alone remains a successful deferral. Reconcile
  still does not restart/logout/authenticate core daemons.
- A missing `compose.yaml` no longer suppresses the reconcile unit. Absence is
  restored atomically from the verified canonical generation; content edits
  stay report-only, metadata is repaired, unsafe path types fail closed.
- FileBrowser's default-password login POST is normal-mode-only and limited to
  once per 24 hours by an atomic root-only `/run` stamp. `--check`/`--status`
  are now truly read-only.
- `master-webdav.service` independently requires `$DOWNLOADS_PATH/media`.
- Fifteen focused cases live in `test/reconcile_control_flow.bats`; decisions
  and findings are DD-41, H10/H11 and M14/M15.

Release verification details worth retaining:

- `--check` + `--status` caused zero FileBrowser login POSTs; two immediate
  normal reconciles caused one total and one daily stamp.
- Missing/edited/metadata/symlink Compose states all took the intended live
  path. The missing file was restored through systemd without restarting any
  container; the symlink failed closed.
- `tailscale down` left tailscaled active but the node `Stopped/false`; the
  real unit waited 30 seconds and failed with structured diagnostics. The same
  node/IP plus existing firewall/core recovery returned every drift flag to
  zero. A deliberately repeated event inside cooldown failed loudly; volatile
  test stamps were removed and final recovery succeeded.
- The second full Q1-20 run preserved every container `StartedAt`. Quantum
  logged `Using existing database`, not the one-time missing-database warning.
- After the host was subsequently reset, the exact exported R2.5 installer
  also completed a genuinely fresh 7/7 run. Its Tailscale browser link
  returned success to the same waiting process, and the resulting node was
  `Running/Online` at `100.95.10.49` and advertising exit-node capability.
  FileBrowser created its database once at
  `/home/filebrowser/data/database.db`; a deliberate restart used that same
  database. Caddy/FileBrowser returned 200, WebDAV returned 401 unauthenticated
  and 200 with the configured credential, and a subsequent unchanged full run
  kept all five pre-run `StartedAt` values unchanged without asking for a new
  Tailscale login or WebDAV password.

Three things from the recent sessions are worth carrying forward more than
the change list:

- **A repository fix is not a deployed fix.** The server once lagged the
  repo by several fixes; **H7** stayed broken in real use for days after
  being marked resolved here. `MASTER_SETUP_VERSION`'s revision suffix and
  `STACK_VERSION`/`STACK_SHA256` in `state.env` now make a host
  self-identifying, so the comparison is one command.
- **Measure before asserting, and re-measure your own claims.** Several
  findings this line came only from measurement, and two *corrections*
  did too: the unbundled systemd drop-ins were framed as a gap until a
  deliberate delete-and-reboot showed the firewall still applied, and
  `UN_LOG_QUEUES=0` was almost recommended before a throwaway container
  showed it makes the log four times noisier.
- **Docs drift silently and the stage table is the worst offender.** It
  has now drifted three times. Regenerate the whole table from
  `grep -n 'progress_stage_begin [0-7] '`; never patch the rows that look
  wrong.
- **A clever detector that can misfire is worse than a dumb timeout.**
  DD-37 is the case: three attempts to diagnose the Tailscale login wedge
  from `journalctl` were each wrong, and the false-positive direction —
  killing a login about to succeed — was worse than the bug being fixed.
  All three were caught by running the function against real data, none by
  reading it. Watch for `journalctl | grep -q` under `pipefail`
  specifically; SIGPIPE turns a found match into a failed pipeline. DD-42
  does not reverse that decision: only after the structured LocalAPI shape
  was measured twice did Q1-21 add a three-sample gate, with unknown state
  still falling back to the dumb timeout. The one
  remaining useful journal classifier was corrected in Q1-18 by consuming
  the complete producer stream.
- **Reconcile is not a second installer.** It may restore bounded local state
  from a verified source, but it must expose core daemon/authentication
  failures rather than taking broad `PartOf=` actions or inventing a browser
  decision. DD-41 records this boundary.

## Completed Work

> **This section is the `v1rc`-era record (2026-07-27/29) and is kept as
> history.** Everything from `V1-20` onward — the whole `quantum` line
> including `Q1-13` — is recorded in `CHANGELOG.md` and
> `docs/design-decisions.md` instead, which are the current sources.

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
- **M1** — `no-new-privileges`, `cap_drop`/`cap_add` and resource
  ceilings for `qbittorrent`/`unpackerr`. (Later revised twice: the
  `mem_limit` was raised 2g → 4g, then `qbittorrent`'s ceilings were
  dropped entirely — see the post-R1.0 section below.)
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

- **Post-R1.0 batch (2026-07-28, after the R1.0 tag).** In order:
  - `qbittorrent`'s `mem_limit`/`cpus` removed entirely (commit
    `0b67afe`). The M1 ceiling had been raised 2g → 4g → 6g/3.0 chasing
    real throughput until it no longer constrained anything on an ~8GB
    host; the user's call was that a ceiling you keep raising is a
    throughput risk, not containment. Privilege hardening untouched.
  - Whole-file review of all 4376 lines, with read-only live
    verification. Five findings: **M8**, **M9**, **M10**, **L6**, **L7**.
    Also cleared the riskiest-looking hypothesis by reading Portainer
    2.39.5's source — an empty `TRUSTED_ORIGINS` on the never-tested
    local-DNS-disabled path is guarded before validation, so **H7**'s
    crash can't recur there.
  - **M8**/**M9**/**L6** fixed plus the stale `MASTER_SETUP_VERSION`
    (`2026.07.26-r8` → `2026.07.28-v1b`; `STACK_SCHEMA=8` deliberately
    left alone) — commit `77be777`. Added DD-14 and DD-15.
  - **M10** fixed with a narrowed scope — `compose.yaml` drift is
    detected and reported, never restored, and deliberately outside
    `all_critical_state_healthy()` so it can't produce a failed unit or
    block Stage 7 (commit `26c9d1d`). The firewall helper was dropped
    from the proposed scope; reasoning is in **M10**'s entry.
  - Fifth live Tier 3 run — the first re-run against an existing install
    rather than a reimage. All 7 stages passed, `--check` clean including
    the new `compose_file=0`, and the `6g`/`3.0` live drift is gone.
- **v1b cycle (2026-07-28, after the tag).**
  - `test/canonical_bundle.bats` (8 cases, commit `a3269e9`) —
    `canonical_bundle_ok()`, reconcile's first gate. Derives both manifest
    file lists from `install.sh`'s own Stage 6 source rather than
    restating them, and was mutation-verified on a scratch copy. Written
    because **M8** and **M10** had both edited the local-DNS-disabled
    branch, which no live install has ever executed.
  - `test/policy_functions.bats` (17 cases, commit `c2c423b`) —
    `check_ipv4_policy`/`check_ipv6_policy`, which hold the entire
    expected firewall rule set. `docs/testing.md` had called these too
    integration-shaped to unit-test; that was too pessimistic and the
    document now says so. Covers the healthy policy plus eleven distinct
    failure shapes, and the IPv6 variants.
  - **M3** and **L7** closed as won't-do, same commit. Shared reasoning:
    the deployment model — single-purpose, single-operator host, always
    built from scratch, all six services in use, local DNS always on.
    `docs/profiles.md` kept as a design note, marked closed.
  - Release string renamed `v1.1` → `v1b` at the user's request; README
    version header updated to match.
- **v1rc cycle (2026-07-29).**
  - `WEBDAV_PORT` promoted to a top-level variable; `65113` went from 17
    hand-written sites to 5, shrinking **L7** to a 3-site problem.
  - `DISK_USAGE_THRESHOLD_PCT`/`RESTART_COOLDOWN_SECONDS` named.
  - `wait_for_chain()` shared by `ensure_forward_prefix` and
    `wait_for_docker_user`. Measured across two reboots: it never waits,
    because `docker-tailscale-fw` starts exactly when `docker.service`
    goes active. Recorded as defensive consistency, not a proven fix.
  - `set_unit_file_mode()` at all eleven unit write sites — 12
    `world-inaccessible` warnings per boot went to 0.
  - 45 English comment lines translated back; `CLAUDE.md`'s language rule
    reversed to match the file.
  - `test/canonical_bundle.bats` (8) and `test/policy_functions.bats`
    (17) — the latter corrects an earlier `docs/testing.md` judgement
    that those functions were too integration-shaped to unit test.
  - **M3** and **L7** closed as won't-do; **M7**'s CI parked.

## Remaining Work

- **M7 — the only open finding, and parked.** Tier 1 complete; Tier 2 is
  now 120 cases across eight files with no identified gaps left, and
  `./scripts/check-all.sh` runs every verification in one command. All
  that remains is CI, and the user decided (2026-07-28) that **the
  repository stays local with no git remote**, so a runner has nowhere to
  build from. Do not re-propose CI at each review; a remote is the only
  thing that would unpark it. Tier 3 automation would additionally need a
  non-interactive invocation mode, separately judged not worth changing
  the deliberate `/dev/tty` prompt design for.
- **Deploy lag has no dedicated check.** Open question, not a decision:
  the user declined recording it in `state.env` on 2026-07-29 on the
  grounds that a clean reinstall settles it. That reasoning holds while
  the server is a test target and should be revisited if it becomes
  long-lived. Note `STACK_VERSION`/`STACK_SHA256` do let one command
  compare host against repo today.
- **Deliberately outside M10's scope:** the firewall helper, the reconcile
  script itself and the core systemd units are still not in the canonical
  bundle. Reasoning is in **M10**'s entry — chiefly that reconcile
  validates the firewall by invoking the very helper it would be
  checking. Two systemd drop-ins are also deliberately excluded, and that
  exclusion was *measured* rather than assumed (2026-08-02): both were
  deleted, Docker restarted and the host rebooted, and the firewall still
  applied with `--check rc=0` and zero failed units.
- **Two won't-do closures that would reopen together:** **M3**
  (installation profiles) and **L7** (ports hardcoded in the firewall
  heredoc). Both were closed because this installer targets a
  single-purpose, single-operator host built from scratch every time.
  Both reopen if it is ever reused across hosts or by another author.
- **Folding the Quantum policy file into `compose.yaml` — closed, DD-35.**
  Blocked by a hard conflict: Compose refuses inline `configs: content:`
  on a `read_only: true` service, and Quantum has no environment variable
  for `sources`/`cacheDir`/`signup`. Reopens only if either side moves.
- **Never measured:** the SQLite indexer's cost on a real-size media tree.
  The test host's tree is small.
- **Outside the repository:** the root password + provider console, and a
  second SSH key from the MacBook.

## Recommended Next Step

1. **Nothing is blocked or half-finished.** Repository, server and the
   exported artifact all agree at `Q1-13`.
2. The user has said the next move is **a change opening a higher
   version** — so the next session most likely starts by bumping
   `MASTER_SETUP_VERSION` past `Q1-13` for whatever that change is.
3. One carried decision needing the user's word because it deletes a tag:
   the `Q1` line marker still points at the `R2.3` close-out commit,
   behind the head. Also note `Q1-14` is tagged but must never be
   deployed — it carries the unsafe wedge detector that `Q1-15` removed,
   and it has no export directory for that reason.
4. Whatever is chosen, keep the standing per-change rule: analyze and flag
   risk first, apply only what was asked, bump the version suffix in the
   same edit, verify with `./scripts/check-all.sh`, show the diff, then
   update `TODO.md`/`SECURITY_REVIEW.md`/`CHANGELOG.md` (and
   `docs/design-decisions.md` when the *reasoning* is the durable part),
   then commit.

## Notes

- **`install.sh` execution policy — superseded again (2026-07-31).** The
  earlier rule here ("only with explicit per-turn approval, and never
  choose configuration values on the user's behalf") no longer describes
  practice. The user granted **standing authorization over the `nrm` test
  host**: it is disposable, its data is worthless, and mutating commands
  there — including running `install.sh`, `sudo`, `systemctl`, Docker
  lifecycle, firewall changes and reboots — need no per-turn approval.
  Every install prompt is answered locally (defaults, `E`, `12345test`)
  and the answers reported. **The Tailscale login URL is the one prompt
  that must still be relayed.** That authorization does not travel: the
  local Mac outside this working tree, `git push`/history rewrite/tag
  deletion, other hosts, the Tailscale account itself, and anything that
  transmits repository content all still need explicit approval. See
  `CLAUDE.md` **Execution Rules**, which is authoritative.
- All conversation with the user happens in Turkish. `install.sh` is
  Turkish throughout (comments and output); markdown docs and commit
  messages stay English; `test/*.bats` and `scripts/*.sh` stay English.
  Each artifact is internally consistent — match the file, not the
  conversation. See `CLAUDE.md` **Language Rules**.
- **Commit policy (changed 2026-07-28):** commit after every completed
  unit of work, without asking first.
- Reference `SECURITY_REVIEW.md` for finding IDs before starting any
  remediation, so status stays consistent across `TODO.md`,
  `CHANGELOG.md`, and this file.
- **Cross-session memory — the older note here was wrong and is
  corrected.** There is no `project_intended_architecture.md`. Six files
  exist as of 2026-08-02: language preference, commit policy, version
  suffix, the SSH/tmux relay, test-host authorization, and the export
  folder rule. They record *working conventions*, not architecture — for
  anything about the system itself rely on this repo's own docs
  (`docs/architecture.md`, `docs/design-decisions.md`).
- **Where things are recorded, so the right file gets updated:**
  `CHANGELOG.md` for what changed, `docs/design-decisions.md` for *why*
  (including options investigated and rejected — DD-35 is the model),
  `TODO.md` for status, `SECURITY_REVIEW.md` for the finding ledger and
  its Review History table, `versiyon/README.md` for export/tag rules.
