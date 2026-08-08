# TODO

Tasks derived from the 2026-07-27 static audit in `SECURITY_REVIEW.md`
(18 findings total, not 19 — an earlier miscount was corrected), plus
three additional findings (**H5**, **H6**, **H7**) discovered 2026-07-28
— the first two via live Tier 3 install tests, **H7** via real post-R1.0
usage — and five more (**M8**, **M9**, **M10**, **L6**, **L7**) from a
whole-file review of the post-R1.0 script the same day; **M10** was
resolved with a narrowed scope and **L7** deliberately deferred.
`install.sh` line references below were refreshed after sixteen numbered
remediations (**C2**, **M6**, **M5**, **H1**, **H2**, **H3**, **M4**,
**L1**, **L2**, **L4**, **L5**, **M2**, **L3**, **C1**, **H4**, **M1**), a
regression fix to **H1** plus the new **H5**/**H6**/**H7** fixes, one
unnumbered cleanup (legacy reboot-timer removal), and a new disk-space
monitoring check added to `master-network-reconcile` after a final
architecture review; file is now 5305 lines (V1-20). Originally **tagged R1.0**
(2026-07-28) before **H7** was found — the tag itself is not moved/
retagged; **H7** is simply the first fix that postdates it (v1b work).
Do not start work on any item without explicit user approval (per
`CLAUDE.md`).

The 2026-08-02 R2.4 line-by-line review added **H8**, **H9**, **M12** and
**M13**. H8 found
that the canonical bundle was described as atomic although only its
manifest rename was atomic; Q1-16 resolves it with verified generation
directories and an atomic `current` pointer (DD-14). H9 found that Stage
6's rollback restored DNS/Caddy service state but not the files those
services load; Q1-17 snapshots and restores all six managed paths until
the canonical pointer commit (DD-38). M12 found a second live
`journalctl | grep -q` pipeline with the same pipefail/SIGPIPE result
inversion already documented by DD-37; Q1-18 consumes the full stream and
tests both classifier outcomes plus producer failure (DD-39). M13 found
that FileBrowser's startup-only policy could lose its repair signal during
cooldown and that a Docker-created directory bind source could not be
normalized by the timer; Q1-19 makes file replacement, restart/recreate and
the retry signal one bounded operation (DD-40). The same ordered review then
added **H10**, **H11**, **M14** and **M15**: persistent core/address failure
was being returned as success, a missing `compose.yaml` disabled the timer's
service before it could diagnose the loss, the advertised read-only modes sent
a real FileBrowser login request every run, and host WebDAV did not wait for a
separate media mount. Q1-20 resolves all four together (DD-41).

## Critical

_All Critical findings resolved — see Completed below._

## High

_All High findings resolved — see Completed below._

## Medium

- [ ] 🟡 **M7** (partially done; inventory refreshed through `Q1-21`) —
      Tier 1 (static analysis, see **H4**) done. Tier 2 now contains **176
      cases across thirteen files**; 164 execute and 12 self-skip on this
      macOS workstation. The first 74-case milestone covered:
      `state_value`/`owned_file_ok`/`restart_budget_available`/
      `disk_space_ok`/`all_critical_state_healthy`
      (`test/reconcile_functions.bats`); `route_value`, `chain_rules_exact`,
      `jump_is_first_and_single`, `forward_prefix_is_exact`,
      `docker_forward_has_no_terminal_drop`, `no_stale_staging_chains`
      (`test/firewall_functions.bats`, 20 cases, via a fake iptables/`ip`
      stand-in); `check_ipv4_policy`/`check_ipv6_policy`
      (`test/policy_functions.bats`, 17 cases); `canonical_bundle_ok`
      (`test/canonical_bundle.bats`, 12 cases, lists derived from
      `install.sh`'s own Stage 6 source); `add_default_netdev`
      (`test/gro_functions.bats`, 5 cases); and `retry_network`'s four
      control-flow paths plus argument pass-through
      (`test/retry_network.bats`, 5 cases). Several suites self-skip on the
      macOS workstation (non-GNU `stat`, bash 3.2 without associative
      arrays, no GNU `timeout`); **all 74 run for real with zero skips on
      the Debian target**, confirmed 2026-07-31.

      **The "remaining scope is CI wiring only" claim was wrong and has
      been corrected.** It was written on 2026-07-28 against a ~4550-line
      script; by 2026-07-31 the file was 5198 lines and the functions added
      or grown since had never been folded back into this inventory. A
      re-survey found three genuinely unit-testable pure-logic functions
      with no coverage at all, and they are now covered: `restart_budget_available`
      (the 15-minute cooldown gate whose mismatch with the old 5-minute
      timer motivated DD-21 — the constant driving that decision had no
      test behind it), `disk_space_ok` (threshold parse, including the
      strict-`<` boundary and the fail-closed unparseable case), and
      `all_critical_state_healthy` (pure, twenty flags, no external calls;
      the invariant pinned is that *any single* flag makes it false, plus a
      guard test asserting the fixture list matches the flags the function
      actually reads — verified to fail when the list is deliberately
      shortened, so it is not a vacuous check). This is the third
      documentation-accuracy defect found on 2026-07-31, after
      `docs/architecture.md`'s 18-line stage-table drift and its stale
      `OPTIONS` description of the WebDAV probe.

      **Added 2026-08-02: `test/generated_files_bundled.bats` (5 cases,
      79 → 84).** Not a function test — it pins a coupling between
      install.sh and itself: every file it generates must be either
      published into the canonical bundle or on an explicit allowlist with
      a written reason. Written because the `Q1-9` defect (the Quantum
      policy file outside drift detection) was structurally uncatchable by
      the existing suites, which compare the manifest and reconcile's
      expected list against each other and are therefore silent about what
      is missing from both. Mutation-verified on all five assertions,
      including a full revert of `Q1-9`. It surfaced two generated systemd
      drop-ins that are neither bundled nor checked by reconcile while
      three of their five siblings are; measuring that (both deleted, host
      restarted then rebooted — policy applied, `--check` rc 0, zero failed
      units) showed them redundant, and the allowlist records the
      measurement.

      **Added 2026-08-02: `test/reconcile_probes.bats` (36 cases,
      84 → 120).** Closes the second tier listed below as "stub-able but
      with milder failure modes, worth doing, not urgent":
      `port_binding_exists`, `docker_network_tuple`,
      `record_container_restart`, `forwarding_config_ok`, `gro_flags_ok`.
      Four of the five parse external output, where a wrong answer is
      indistinguishable from a right one on a healthy host.
      `record_container_restart` is tested against
      `restart_budget_available` so the stamp filename/format coupling
      that DD-21's cooldown rests on is pinned. Mutation-verified; one
      mutation changed nothing and that fact is recorded in the test
      (the sysctl regex anchor is redundant with the equality check).

      **Added 2026-08-02: `scripts/check-all.sh`.** Runs all four
      verification steps in one command — the local substitute for the CI
      this finding is parked on. Does not stop at the first failure, and
      reports a missing tool as `DOĞRULANAMADI` with a non-zero exit
      rather than as a pass. All four failure paths exercised; the
      instructive one is that a syntax error inside the reconcile heredoc
      is caught by the embedded lint alone, with `bash -n install.sh`,
      `shellcheck install.sh` and all 120 bats cases passing on it.

      **Added 2026-08-02: Q1-16 canonical publication regression coverage
      (6 cases, 120 → 126).** Five cases cover the new generation pointer,
      an unpublished partial generation, an outside-root target, and both
      sides of the R2.4 legacy transition. A sixth structural case proves
      Stage 6 verifies the generation before swapping `current`.

      **Added 2026-08-02: `test/dns_stack_rollback.bats` (7 cases,
      126 → 133).** Covers restoration of prior content and prior absence,
      symlink preservation, managed-path safety, restore-before-restart
      ordering, the canonical pointer as the transaction commit point, and
      the signal window between pointer swap and flag update. A failed
      restore must retain its root-only recovery snapshot.

      **Added 2026-08-02: `test/tailscale_journal.bats` (3 cases,
      133 → 136).** Reproduces the old large-stream `grep -q` pipeline at
      rc 141 and pins that an early `node not found` match stays true, no
      match stays false, and a genuine journalctl failure is not hidden.

      **Added 2026-08-02: `test/quantum_config_repair.bats` (11 cases,
      136 → 147).** Covers regular policy replacement, Docker-created
      directory sources, an already-absent container, daemon/removal
      failures, restart versus Compose recreate selection, cooldown/pending
      ordering, the full installer's policy-change recreation coupling and
      recreation of an unhealthy legacy container with a stale mount spec.

      **Added 2026-08-02: `test/reconcile_control_flow.bats` (15 cases,
      147 → 162).** Covers transient-vs-persistent exit codes, the complete
      WAN/Tailscale address requirement, Compose regular/missing/directory/
      symlink/metadata states, canonical restoration without Compose apply,
      daily FileBrowser audit throttling, and structural assertions that a
      missing Compose file cannot suppress reconcile and WebDAV waits for the
      media mount.

      **Added 2026-08-02: `test/tailscale_login.bats` (13 cases,
      162 → 176).** Covers Q1-21's structured interactive-login state,
      complete ID/IP postcondition, malformed/failed LocalAPI reads, the
      successful transient-410 case, three consecutive dead samples causing
      one early retry, and a single dead sample resetting before success.

      Of the 51 functions in the reconcile heredoc, the ones still
      uncovered are genuinely integration-shaped — `http_endpoint_responds`,
      `webdav_direct_ok`, `caddy_runtime_ok`, `dns_listeners_ok`,
      `tailscale_online`, `probe_compose_runtime` and their neighbours all
      need real network, systemd or Docker. A second tier of parse-only
      functions (`record_container_restart`, `gro_flags_ok`,
      `forwarding_config_ok`, `port_binding_exists`, `docker_network_tuple`)
      was covered by `test/reconcile_probes.bats` above.
      The other three embedded scripts (`master-compose-ipv4`,
      `master-docker-netfilter-recovery`, `caddy-tailnet-env`) remain
      surveyed and rejected — each is a wait loop plus real side effects.

      **CI wiring is parked, not pending:** the user decided on 2026-07-28
      that this repository stays local with no git remote, and a runner
      needs somewhere to build from. Kept open at the user's request, but
      do not re-propose CI at each review — a remote is the only thing that
      would unpark it. Tier 3 automation would additionally need a
      non-interactive invocation mode, separately judged not worth changing
      the `/dev/tty` prompt design for. Tier 3 itself had three real
      attempts on 2026-07-28 (see Completed below and `docs/testing.md`) —
      found and fixed three real bugs (**H1** regression, **H5**, **H6**)
      across the first two, then the third completed all 7 stages
      end-to-end, the first fully clean install of this repo's `install.sh`.

## Low

- [ ] **Compose can leave a container under its temporary replace name, and
      reconcile cannot repair that (found 2026-08-04 during the `Q1-31`
      upgrade).** Recreating `qbittorrent` left it running as
      `<id>_qbittorrent` with `com.docker.compose.replace: qbittorrent`,
      healthy and with its ports published, but never renamed back. Stage 7
      correctly failed on the missing port publication, and reconcile
      correctly could not fix it — its repair model is `docker restart
      <name>`, which has nothing to act on. Repair was manual: stop
      `master-compose`, `docker rm -f` the stray container, start it again.
      Worth deciding whether Stage 5 or reconcile should detect a container
      carrying the `com.docker.compose.replace` label and remove it.

- [ ] **`master-compose`'s address-change exemption still consumes its restart
      budget (found 2026-08-04).** Identical to the defect fixed for
      `master-webdav`/`dnsmasq`/`caddy` in `Q1-31`: `if [[ "$ADDRESS_CHANGED"
      -eq 1 ]] || restart_budget_available master-compose` is followed
      unconditionally by `record_container_restart master-compose`, so an
      address change spends the stack's fifteen-minute budget and a genuine
      stack failure right after is deferred. Pre-existing and out of A5's
      scope, so it was recorded rather than changed unasked.

- [ ] **`tailscale_daemon_ready` counts turns around an untimed probe
      (found 2026-08-05 during `Q1-37`'s survey).** Thirty iterations of
      `tailscale status --json` with a `sleep 1` and no `timeout` wrapper, so
      against a wedged daemon each probe costs an arbitrary amount and the
      loop's real duration is unbounded. Not DD-55's defect — its caller's
      message ("yanıt vermedi") claims no duration to be wrong about — but it
      is the unbounded-probe half of DD-50's argument, and DD-50 solved the
      same problem elsewhere with `TAILSCALE_LOGIN_STATUS_TIMEOUT`. Left
      alone to keep `Q1-37` to one item.

- [ ] **Nine inverted assertions in the test suite cannot fail (found
      2026-08-04 while mutation-verifying `Q1-34`).** Bash exempts a command
      whose status is inverted with `!` from `set -e`, so a bare `! cmd`
      asserts nothing unless it is a test's last line. Two cases written that
      way in `Q1-34` survived a mutation that made them false, and were
      rewritten to capture the status; the same non-final shape appears nine
      more times across `canonical_bundle_degrade`, `canonical_stage_cleanup`,
      `onfailure_arc`, `reconcile_control_flow`, `tailscale_online_gate` and
      `tailscaled_job_isolation`. Not all are necessarily dead — several are
      followed by a stronger sibling assertion that would catch the same
      mutation — but none of them currently demonstrate that, and the only way
      to know is to mutate each. Recorded rather than fixed in `Q1-34`, which
      would have meant touching seven unrelated test files.

_All Low findings resolved or closed — see Completed below._

## Completed

- [x] **v2-32: re-run restart flags, firewall/Docker decoupling, drop
      Caddy/WebDAV `PartOf=tailscaled`, bounded `tailscale up` reap
      (2026-08-09, DD-75).** Live `nrm` tests showed `enable --now` is a
      no-op on active firewall/WebDAV, Tailscale restart bounced Caddy/
      WebDAV without IP change, and `Requires=docker` plus a hard
      `DOCKER-USER` die tied host INPUT to Docker success. Rejected on
      the same evidence: `accept_ra=2`, `stateful-filtering=false`,
      start-limit-as-permanent-lock. Static: `bash -n` + `shellcheck` on
      `v2/install.sh` and `v2/scripts/firewall.sh`. Live re-verify pending.

- [x] **A probe in a predicate position puts back what it measured
      (2026-08-05, `Q1-39`, Stage 4 pass item D5, DD-57).** The last of the
      five, and the only one that changes no behaviour today.
      `probe_compose_runtime` resets four globals on every call —
      `COMPOSE_RESTART_TARGETS`, the list the repair loop restarts, plus the
      three `WG_*` values the operator report and `--status` are built from.
      Three call sites measure and consume them; two only asked a yes/no
      question in a postcondition chain and replaced the measurement the cycle
      had already acted on with a measurement of the world after the repair.
      Latent because nothing reads them afterwards — verified by ordering, not
      assumed — and fixed because the next line added below the postcondition
      would inherit the wrong data silently. Those two positions now call
      `compose_runtime_still_ok`, which saves, probes, restores and returns the
      probe's verdict. Six cases: one derives the measure-versus-check rule
      from the script's own call sites, one pins the ordering that keeps the
      wrapper's reads safe under `set -u`. Seven mutations, each caught — one
      only after the case that missed it was rewritten so the two measurements
      disagree. **Stage 4's pass (D1–D5) is now complete.**

- [x] **The Compose stack stops depending on the Tailscale address
      (2026-08-05, `Q1-38`, Stage 4 pass item D1, DD-56).** DD-52's sibling
      from the same commit: `V1-3` deleted compose's only use of
      `TAILSCALE_IPV4`, leaving a 120-second hard gate in front of the whole
      stack and a five-container restart on every change. Measured: zero
      occurrences of the address in the rendered `docker compose config`,
      every container port on `127.0.0.1` or the public IPv4, and only host
      services listening on it. The helper now records the address when
      present and starts the stack regardless; `PUBLIC_IPV4` stays a hard
      precondition because it is in three port bindings. Reconcile keys the
      stack restart on `PUBLIC_ADDRESS_CHANGED` and refreshes a stale `.env`
      by running the helper directly — necessary, because removing the
      restart removed the only writer of the file the flag is computed
      against, which would have latched it at 1 forever. Refresh and
      postcondition share one predicate. Eight cases added, five mutations
      run and caught. `./scripts/check-all.sh` clean at 258 cases.

- [x] **Every wait that promises a duration now measures one (2026-08-05,
      `Q1-37`, Stage 4 pass item D4, DD-55).** Four sites counted iterations
      while their message named seconds: Stage 2's tailscaled-socket wait,
      `master-compose-ipv4`, reconcile's address-ready retry and
      `master-webdav-serve`. All four now build a deadline from `SECONDS` and
      interpolate the bound into the message so the two cannot drift apart
      again. The rule is not "no `seq`" — a survey of all nine remaining
      sites found four that are correctly iteration-bounded (the two
      staging-chain name retries take no `sleep`; the post-repair retries
      claim no duration) and one more that qualified, which is why this
      fixed four sites rather than the three originally listed. The two
      embedded scripts were extracted and run against a stub `ip` costing
      three seconds a probe: each exits within its three-second budget where
      a counter would take four times as long. Five cases added including a
      whole-file invariant, four mutations run and each caught.
      `./scripts/check-all.sh` clean at 250 cases.

- [x] **Reconcile stops reading configuration from a bundle it rejected
      (2026-08-05, `Q1-36`, Stage 4 pass item D2, DD-54).** `state_value`
      preferred the canonical `state.env` on mere readability and never
      consulted `CANONICAL_BUNDLE_INVALID`. Measured: one `--status` run
      printed `canonical_bundle=1` and "canonical kopyadan geri yükleme
      yapılmayacak" alongside `Kurulum sürümü :
      TAMPERED-NOT-A-REAL-VERSION` read from that same file, while the
      intact live copy sat unread. `STACK_VERSION` was the visible symptom
      only — the same call supplies the ports, domain and paths that drive
      the DNAT checks, port-binding checks, DNS/Caddy probes and disk
      thresholds. Now gated on `CANONICAL_STATE_TRUSTED`, raised only where
      `canonical_bundle_ok` returns true, in both the main path and
      `--status` (which reads state about a hundred lines before the main
      gate). Verified side by side on the same tampered bundle: `Q1-34`
      prints the tampered string, `Q1-36` the real value plus the fallback
      reason. DD-46's gate test was rewritten to assert behaviour rather
      than the literal `if ! canonical_bundle_ok; then`. Four cases added,
      three mutations run and caught. `./scripts/check-all.sh` clean at 245
      cases.

- [x] **The media-tree chown stops dereferencing (2026-08-04, `Q1-35`,
      Stage 4 pass item D3, DD-53).** `find` defaults to `-P` and reports
      symlinks rather than following them, and `chown` without `-h`
      dereferences the path it is handed, so a symlink in the media tree
      owned by anything but `1000:1000` matched the predicate and aimed the
      ownership change at its target anywhere on the host. Measured before
      the fix: a root-owned symlink stayed `0:0` while a sentinel outside the
      tree moved to `1000:1000`. Reachability measured too — `docker exec
      qbittorrent id` is `uid=0(root)`, the tree is its `/downloads`, and a
      symlink planted from inside appears on the host as `0:0`; `1000` is the
      uid that container's process runs under. Fixed with `chown -h`, which
      leaves the sentinel alone, repairs the link itself and still repairs
      ordinary files. `-xdev` deliberately out of scope. Three cases in a new
      `test/media_tree_chown.bats` (stub `chown` on `PATH`, no root needed),
      three mutations run and caught. `./scripts/check-all.sh` clean at 242
      cases.

- [x] **`--check` no longer waits for a value no rule uses (2026-08-04,
      `Q1-34`, Stage 3 pass item C1, DD-52).** `docker-tailscale-fw` resolved
      `TAILSCALE_IPV4` behind a 300-second gate, but `V1-3` (`9b8d754`) had
      deleted both of its uses — the `--ctorigdst` WebDAV allow and its
      `check_ipv4_policy` counterpart — when the sftpgo container became the
      host rclone service, leaving only the gate. Measured against the
      deployed helper: healthy `--check` 0.162 s, addressless `tailscale0`
      305.9 s, with the error naming the Tailscale branch so `check_policy`
      was never reached. Reconcile's unconditional first `--check` treats that
      exit exactly like real drift, then stops the stack and restarts the
      firewall unit, which pays the gate again — about fifteen of the timer's
      twenty minutes on an addressless node. `TAILSCALE_IPV4` removed;
      resolution split into `resolve_wan_ipv4` and a `SECONDS`-deadline
      `wait_for_wan_ipv4`; `apply` still waits because `PUBLIC_IPV4` is in
      three rules, `--check` resolves once. The apply-side risk was measured
      across a real reboot: `ts-forward` and the `FORWARD` jump were in place
      at +1.16 s with no `tailscale0` IPv4 until +1.37 s, so the gate never
      guarded `ensure_forward_prefix`'s precondition. Seven cases added, five
      mutations run and caught. `./scripts/check-all.sh` clean at 239 cases.

- [x] **Stage 2 bounces the daemon, not the stack (2026-08-04, `Q1-33`,
      audit item B2, DD-51).** On a reinstall the tailscaled drop-ins
      (`Wants=` on four stack units) and those units' `PartOf=tailscaled`
      already exist while Stage 2 runs, so `systemctl enable --now tailscaled`
      started whichever of them was inactive — measured on the test host with
      reconcile stopped — and returned in 0s while `master-compose` was still
      activating. Since `master-compose` takes no lock, a background
      `docker compose up` against the previous version's config raced Stages
      4-5 rewriting exactly those files. Two mechanisms needed two fixes: the
      start is now conditional on `is-active`, and the login-retry restart
      carries `--job-mode=ignore-dependencies`, which suppresses both the
      `Wants=` pull and the `PartOf=` propagation. Three corrections to the
      audit note recorded in DD-51 (wrong trigger, wrong unit set, ineffective
      proposal). Five mutations run and caught; a sixth was measured not to be
      a defect. `./scripts/check-all.sh` clean at 232 cases.

- [x] **One definition of "online" in the installer (2026-08-04, `Q1-32`,
      audit item B1, DD-50).** `tailscale_is_online()` parsed
      `tailscale status --self` text for the substring `offline` — the only
      one of three online predicates reading human-readable output, and the
      only one with no tests. It also returned true for
      `BackendState=Starting`, so Stage 2's final gate could pass on a node
      that was not Running. Deleted; its three call sites use
      `tailscale_login_complete()`. Both Stage 2 waits became deadline-bounded
      because the JSON probe is wrapped in `timeout 3`, which would have made
      an iteration-bounded loop run 450 seconds while printing "180 saniye".
      Two corrections to the audit note recorded in DD-50: it does not take
      three definitions to one (reconcile's stays, in a separate script), and
      it missed the loop-duration consequence. Five mutations run and caught.
      Live-verified on `nrm`. `./scripts/check-all.sh` clean at 224 cases.

- [x] **A1–A5 live-verified on the test host; two defects found and fixed
      (2026-08-04, `Q1-31`, DD-46/DD-49 amendments).** Upgraded `nrm` from
      `Q1-22` in place. **Defect 1:** `Q1-30`'s restart exemption called
      `record_container_restart`, so a Caddyfile restore spent the cooldown
      and a real caddy failure minutes later was refused for fifteen minutes
      — worse availability than before the change. Fixed with an explicit
      `*_RESTART_EXEMPT` flag; stamps only on the budget path. **Defect 2:**
      the drift report said "canonical kopya geri yüklenecek" while correctly
      withholding the restore; the message is now conditional. Confirmed on
      the host: A2 degrades and repairs bundle-independent drift, A3's cleanup
      kept the published generation after a Stage 7 failure, A4 prints the
      wg diagnostic exactly once, A5 brakes on the second failure-driven
      restart with per-unit scoping. A1 is unreachable on this host by
      construction. `./scripts/check-all.sh` clean at 217 cases.

- [x] **Every unit on the `OnFailure` arc restarted behind the repair
      cooldown (2026-08-04, `Q1-30`, audit item A5, DD-49).** Five units
      point `OnFailure=` at reconcile and reconcile restarts all five. The
      synchronous case cannot spin (systemd merges the job into the running
      one) and the arc terminates at reconcile (no `OnFailure=`, no
      `Restart=`); the asynchronous case can — a daemon that starts cleanly,
      lets reconcile exit, then dies trips `Restart=on-failure`, hits its
      start limit and fires `OnFailure` with reconcile inactive, running it
      immediately instead of on the timer. `master-webdav`, `dnsmasq` and
      `caddy` were the only restart paths with no `restart_budget_available`
      gate *and* the three arc units with `Restart=on-failure` + a
      `StartLimit` — and each called `reset-failed` first, clearing systemd's
      counter, so both brakes were gone. All three now go through the budget;
      address changes and canonical config restores bypass it, `*_INACTIVE`
      and `*_RUNTIME_DRIFTED` do not; `systemctl start master-compose.service`
      is a documented exception. `test/onfailure_arc.bats` derives the arc
      from install.sh's own `OnFailure=` lines, seven mutations run and
      caught. `./scripts/check-all.sh` clean at 215 cases. Not live-verified —
      the job-merging claim needs a crash-looping daemon on a real host.

- [x] **`probe_compose_runtime` split from its reporting (2026-08-04,
      `Q1-29`, audit item A4, DD-48).** `check_compose_runtime` was a
      predicate, a mutator of four globals and a reporter, called five times
      per reconcile cycle — three of them in pure predicate positions that
      silently recomputed `COMPOSE_RESTART_TARGETS`,
      `WG_CONFIGURATION_INVALID` and `WG_SETUP_PENDING`. DD-33 already moved
      the filebrowser password probe out of this function for this reason and
      left the two `echo` lines behind, so a wg-easy port mismatch printed
      four identical errors per cycle for a condition with no auto-repair,
      and `--status` showed them as prose inside its `key=value` block
      (it captures `--check` with `2>&1`). Renamed, silenced, port handed
      back in `WG_OBSERVED_PORT`; the detection site reports once — there,
      not in the drift report, because a pending wg-easy setup is not drift
      (DD-12/H6) and such a host exits earlier. `--check` gained `wg_setup=`
      and `wg_config=`. No live bug: every reset was traced against every
      reader. The five calls and the retry asymmetry are deliberately left
      alone. The function had zero tests; `test/compose_runtime_probe.bats`
      now pins the contract, seven mutations run and caught. DD-12 and DD-33
      corrected. `./scripts/check-all.sh` clean at 206 cases. Not
      live-verified.

- [x] **`cleanup_master_setup` re-implemented `canonical_stage_is_current`
      inline (2026-08-04, `Q1-28`, audit item A3, DD-47).** The audit called
      this a dead promotion branch; it is not. The branch is reachable
      through the signal window between the `mv -Tf` pointer swap and the
      `CANONICAL_STAGE_DIR` reset, which `dns_stack_rollback.bats` pins
      deliberately. The real finding is that one question was asked twice,
      two ways, inside one function: `restore_dns_stack_on_failure` used the
      predicate (both sides normalised with `readlink -f`) while the
      staged-generation block resolved only `current` and compared it
      against the raw `mktemp` string, with the root path hardcoded. A
      symlink anywhere above the canonical root makes the two halves of one
      cleanup disagree — rollback snapshot discarded as published, live
      generation `rm -rf`'d as unpublished, `current` left dangling and
      canonical restore dead for good. The block now calls the predicate;
      the `.generation.*` allowlist stays. `test/canonical_stage_cleanup.bats`
      runs the lifted block in two forms (verbatim for the allowlist, and
      re-rooted at the fixture so the deleting branch is observable at all);
      four mutations run, four caught by specific cases.
      `./scripts/check-all.sh` clean at 194 cases. Not live-verified.

- [x] **Canonical bundle failure degrades reconcile instead of aborting it
      (2026-08-04, `Q1-27`, audit item A2, DD-46).** `canonical_bundle_ok`
      was reconcile's first gate and exited 1 before any detection or
      repair ran, so one wrong mode bit on one of the nine canonical
      entries disabled address re-binding, forwarding repair, Tailscale
      prefs/netfilter repair, firewall renewal, container restarts and
      disk reporting — none of which read the bundle — and the timer
      failed every 20 minutes with one line of output. The result is now
      `CANONICAL_BUNDLE_INVALID`: report, withhold only the seven
      bundle-dependent blocks, run everything else, still exit 1. Not a
      new design — `CANONICAL_CONFIG_INVALID` already answers the same
      question for unparseable canonical configs, and wherever it gates,
      the new flag gates too. Degrading is not passing: the flag joins
      `all_critical_state_healthy`, forces `RECOVERY_FAILED=1`, appears in
      `--check` as `canonical_bundle=`, and the postcondition sweep still
      calls `canonical_bundle_ok` directly. The `STACK_SCHEMA` gate stays
      a hard exit deliberately. `test/canonical_bundle_degrade.bats`
      derives the invariant from install.sh's own text — every top-level
      recovery block consuming the bundle must be gated — so a new ungated
      restore site fails on its own; four mutations run, four caught.
      `./scripts/check-all.sh` clean at 183 cases. Not live-verified.

- [x] **Firewall helper's contradictory ip6tables contract removed
      (2026-08-03, `Q1-26`, audit item A1, DD-45).** Four branches promised
      graceful degradation without ip6tables while `check_policy` made the
      run exit 1 regardless; one of them (`apply_ipv6`'s DOCKER-USER
      warning) was provably unreachable, since `ensure_forward_prefix`
      checks the same chain earlier and kills the helper under `set -e`.
      Now a single top-level guard fails before the lock and before any
      chain is touched. Requiring rather than skipping is the
      security-consistent choice: Stage 2 enables IPv6 forwarding, so
      continuing without the v6 guard chains would leave forwarding on
      with no Tailnet isolation. `check_ipv6_policy`'s own guard is kept —
      it is M5's remediation and has a Bats case. Verified by extracting
      the helper and running it with no `ip6tables` on PATH: rc 1 in both
      modes with zero `iptables` invocations, against a previous revision
      that installs the full IPv4 policy first in `apply` mode.
      `./scripts/check-all.sh` clean at 176 cases. Not live-verified.

- [x] **All explanatory comments removed from `install.sh` (2026-08-03,
      `Q1-25`, unnumbered, DD-44 amendment).** Operator follow-up to
      `Q1-24`: comments are never printed during an install and the script
      is not read in an editor, so they are read by nobody and decay
      silently. 508 further lines removed, 5868 → 5356. Nine `#` lines
      survive, both classes load-bearing: eight `#!` shebangs and one
      `# shellcheck disable=SC1091` without which `shellcheck install.sh`
      fails. The `AŞAMA` banners went too — each duplicated the
      `progress_stage_begin` line printed directly below it. Checked for
      the one class a blanket rule could destroy silently, a YAML block
      scalar where `#` would be content: none exist in the file. Verified
      by diffing both revisions with comments and blank lines stripped —
      4790 lines, byte-identical. `docs/architecture.md` regenerated;
      `CLAUDE.md` now says explanations go into a `DD-` entry.
      `./scripts/check-all.sh` clean at 176 cases.

- [x] **`install.sh` comment volume cut by 56% (2026-08-03, `Q1-24`,
      unnumbered, DD-44).** Operator request after reading the raw file:
      1179 comment lines across 229 blocks became 517. Blocks now say what
      the code does; the archaeology stays in `docs/design-decisions.md`,
      `SECURITY_REVIEW.md` and `CHANGELOG.md`, reachable through short
      pointers. 6527 → 5868 lines. Applied through an explicit line-range
      map, not a pattern rule, with pre-write assertions that every
      targeted line is a comment and is neither a shebang nor a
      `shellcheck` directive; shebangs, the `SC1091` directive and the
      eight `AŞAMA` banners untouched. Verified by diffing both revisions
      with all whole-line comments stripped — 5351 lines, byte-identical —
      so "no behaviour changed" is measured rather than asserted.
      `docs/architecture.md`'s stage table regenerated. Convention written
      into `CLAUDE.md` so the blocks do not grow back.
      `./scripts/check-all.sh` clean at 176 cases.

- [x] **Tailscale SSH enabled alongside the exit-node role (2026-08-03,
      `Q1-23`, unnumbered, DD-43).** Operator request, not a finding. The
      interactive login now runs `tailscale up --advertise-exit-node
      --ssh` instead of a bare `tailscale up`, so a fresh node asks for
      both in one step. `tailscale set` keeps `--advertise-exit-node` and
      gains `--ssh=true` — it is the unconditional path, since `tailscale
      up` runs only when a login is actually needed and never on an
      ordinary re-run. Naming the flags on `up` also avoids Tailscale's
      refusal to silently revert non-default preferences on a re-login
      where the profile already advertises an exit node.
      `tailscale_prefs_ok()` requires `.RunSSH == true`, so the reconcile
      timer repairs a lost `--ssh` as drift. Security trade-off stated
      rather than assumed: SSH is answered by tailscaled on the node's
      Tailscale address, governed by the tailnet's ACL `ssh` block instead
      of the host's `authorized_keys` — tailnet-only, no change to the
      internet-facing surface, but tailnet policy now decides who gets a
      root shell. `./scripts/check-all.sh` clean at 176 cases. Not
      live-verified.

- [x] **A slow-to-come-online node discarded a successful Tailscale login
      (2026-08-02, `Q1-22`, unnumbered, DD-42).** Found while reviewing
      `Q1-21`, not in use. After `tailscale up` exits zero the node was
      given 15 seconds to reach the verified LocalAPI state, and on expiry
      the daemon was restarted and a second browser authorization
      demanded — for a login that had already succeeded. DD-37's
      false-positive class through a different door, and the stricter of
      two gates for one condition: the next block in Stage 2 already waits
      180 seconds for `tailscale ip -4` plus `tailscale_is_online`, and
      only the 15-second gate had a destructive remedy. A node that will
      not come online after an accepted login has a connectivity problem,
      which a fresh link cannot fix. The window is now a fast path: it
      returns early when verified, and on expiry prints a hand-off note
      and returns success. `outcome="incomplete"` removed. Fourteenth case
      in `test/tailscale_login.bats`, mutation-verified against the
      `Q1-21` behaviour.


- [x] **M16 — persistent interactive-login 410 now retries early
      (2026-08-02, `Q1-21`, DD-42).** A clean install produced two separate
      browser links and nodekeys that each became offline console records
      while LocalAPI remained `NeedsLogin`/offline/empty-ID with the exact 410
      health line. Q1-21 requires that structured signature for three
      consecutive two-second samples, otherwise retaining the five-minute
      fallback. Successful exit now also requires `Running`, online, node ID
      and IP. Thirteen tests cover the classifier and retry/reset paths; the
      full local wrapper is clean. Exact automatic live verification remains
      pending. The operator explicitly requested an untagged R2.6 export for
      that manual test; release tags remain pending.

- [x] **Q1-20/R2.5 live close-out (2026-08-02).** Exact-script R2.4
      upgrade and unchanged rerun both completed 7/7; the second preserved all
      five container start times. Fault injection covered FileBrowser audit
      side effects, all four Compose target classes and an active-but-offline
      Tailscale node. Final state: same node/IP, all drift flags zero, no
      failed units; exported as `versiyon/R2.5/`. After the host was reset,
      that exact export also completed a clean-image first install through the
      real browser-login path and another unchanged rerun. The fresh run
      created FileBrowser's persistent database once; restart and rerun reused
      it, and the rerun preserved all five container start times.

- [x] **H11 — a missing Compose file no longer disables reconcile
      (2026-08-02, `Q1-20`, DD-41).** Removed the service-level
      `ConditionPathExists` that skipped the entire timer pass. Missing files
      are restored from the verified canonical generation without applying
      Compose; modified content stays report-only, metadata is repaired, and
      structural targets fail closed.

- [x] **H10 — persistent core/address failure is no longer returned as
      success (2026-08-02, `Q1-20`, DD-41).** Lock/job overlap still defers
      cleanly, but inactive Docker/Tailscale or addresses absent after a
      bounded 30-second grace now exit non-zero with Tailscale backend, online,
      health and key-expiry diagnostics. No automatic login/logout or
      synchronous core-daemon restart was added.

- [x] **M15 — host WebDAV waits for the media filesystem
      (2026-08-02, `Q1-20`, DD-41).** `master-webdav.service` now carries
      `RequiresMountsFor=$DOWNLOADS_PATH/media`, closing the boot race for the
      already-supported `/mnt` and `/media` external-disk paths.

- [x] **M14 — `--check` and `--status` are read-only again
      (2026-08-02, `Q1-20`, DD-41).** The real FileBrowser login POST is
      limited to a running container in normal reconcile mode and a root-only
      daily stamp, reducing the scheduled rate from 72 requests/day to one
      while preserving detection if the data volume is recreated.

- [x] **M13 — FileBrowser policy repair preserves its restart signal and
      recreates structural mounts (2026-08-02, `Q1-19`, DD-40).** The old
      reconcile copied into a directory without replacing it and restored a
      regular file before checking cooldown, allowing the disk/runtime drift
      signal to disappear. Repair is now staged atomically, budgeted before
      mutation and held by a `/run` pending marker until health + HTTP pass.
      Non-regular sources recreate only FileBrowser through Compose; the
      named data volume is preserved. Full installer re-runs also recreate
      FileBrowser when generated policy content or metadata changes.

- [x] **M12 — Tailscale node-not-found journal classifier no longer
      inverts matches under pipefail (2026-08-02, `Q1-18`, DD-39).** The
      remaining `journalctl | grep -q` could give journalctl SIGPIPE after
      an early match, making pipefail return 141 and sending a deleted node
      down the generic fatal branch instead of automatic logout/re-login.
      Normal fixed-string grep now consumes the full journal stream while
      `/dev/null` suppresses output; real producer failures remain visible.

- [x] **H9 — DNS/Caddy rollback now restores managed files (2026-08-02,
      `Q1-17`, DD-38).** Stage 6 captured active/enabled/masked state but
      overwrote six config/helper files without snapshotting them. A later
      failure could restart an old active service against partial new
      content while the old canonical bundle remained current. The six
      paths are now captured under root-only `/run` storage before any
      mutation; failure restores both content and non-existence before
      `daemon-reload` and service restart. The atomic canonical `current`
      swap is the commit point. Package/repository rollback is deliberately
      excluded as broader, less reliable and unnecessary for an idempotent
      rerun.

- [x] **Interactive Tailscale login could hang forever (2026-08-02,
      `Q1-14`/`Q1-15`, unnumbered, DD-37).** Found in real use, not by
      review: a from-scratch install wedged at the login step and the
      script had no defence at all — `tailscale up` bare, waiting
      indefinitely. The daemon takes `410: auth path not found` when a
      pending auth path is superseded (restarting the installer, or
      opening an older link), then retries the *same dead path* forever
      with `regen=false`, while `tailscale status` keeps printing it as
      though live. `tailscale logout` does not clear it; only restarting
      `tailscaled` does. Now wrapped in `tailscale_interactive_login()`:
      300s per attempt, three attempts, daemon restart and a fresh link
      between them, manual recipe at the end. Deliberately does **not**
      diagnose the wedge from the journal — three attempts to do so were
      all wrong (a 410 also occurs on success; `grep -q` under `pipefail`
      inverted its own result via SIGPIPE; an unbounded window credited a
      later login's success to an earlier wedge), and a false positive
      kills a login that is about to succeed.
      **Amended by Q1-21/M16:** after two later independent failures exposed
      the exact persistent LocalAPI shape, that measured state can now bypass
      the timeout after three consecutive samples. Unknown and merely slow
      states still receive all 300 seconds; journal parsing remains rejected.

- [x] **Unpackerr file log capped, queue heartbeat slowed (2026-08-02,
      `Q1-13`, unnumbered, DD-34).** Raised by the operator seeing a long
      repetitive tail in `docker logs unpackerr`. Two separate things: the
      visible noise (`log_queues`, 2 lines/min, Docker side already capped
      at 30 MB — legibility, not risk) and an actual unbounded file. The
      latter is `/downloads/.unpackerr/unpackerr.log`, reported by the
      container as `(10 @ 0Mb)`: upstream's documented 10 MB default only
      applies via the TOML path, and this stack configures unpackerr by
      environment variable alone, so rotation was off. ~145 MB/year inside
      the media tree. Now `UN_LOG_FILE_MB: "10"` + `UN_LOG_FILES: "3"`
      (30 MB, matching the Docker cap) and `UN_LOG_QUEUES: "30m"` —
      explicitly **not** `0`, which measurement showed clamps to a 15s
      floor and is four times noisier. `UN_LOG_FILE_MB` added to Stage 7's
      environment assertion; the other two deliberately left out, being
      the two whose drift is visible or still bounded.

- [x] **`FILEBROWSER_DATABASE` pinned in `compose.yaml` (2026-08-02,
      `Q1-12`, unnumbered, DD-27).** Raised by the user asking what the
      `database file could not be found` warning on filebrowser's first
      login screen actually meant. Answer: nothing was broken — the
      warning fires because the file does not exist yet on a first
      install, *with the variable already set correctly*, and never again
      afterwards (restart and `--force-recreate` both log `Using existing
      database`; the changed admin password survives both). But answering
      it surfaced that the path was inherited silently from the image's
      own `ENV`, and `read_only: true` makes that path a hard constraint:
      it must land inside the `filebrowser_data` mount or Quantum cannot
      start. The value is now written explicitly beside the volume line it
      has to agree with. Small hardening against an upstream default
      moving, not a fix — the failure mode it guards is a boot loop
      reconcile would catch, not silent data loss.

- [x] **L8 — bounded retry + mandatory timeout for network steps
      (2026-07-31, `V1-14`, DD-24).** Observed when Docker Hub's anonymous
      token endpoint returned **502 Bad Gateway** mid-`docker compose pull`
      and the install died at Stage 5; the immediate re-run succeeded.
      Reading the surrounding code inverted the priority: the retry fixes
      the 502, but the script runs under `systemd-inhibit
      --what=shutdown:sleep --mode=block` and holds the `flock` it shares
      with reconcile, so an unbounded hang would block shutdown *and* stop
      the 20-minute reconcile timer from ever running. The timeout was the
      real gap; the 502 had at least failed loudly. `retry_network` now
      wraps `apt-get update`, the three keyring/repo fetches and the
      Compose pull — three attempts, per-attempt `timeout`, 5s/15s
      backoff, no error classification (permanent failures already return
      in seconds, so blind retries cost them ~20s and stderr matching
      would be locale-dependent). Budgets came from measurement, not
      guesswork: cold pull 10.9s/885 MB, warm pull 3.2s, `apt-get update`
      0.9s, keyrings 36–127 ms → 300s/180s for bulk, 60s/30s for small.
      `full-upgrade`/`install` deliberately excluded (dpkg transactions
      are a different problem class). The Caddy GPG fetch was split from
      its `gpg --dearmor` pipe so the retry covers only the network half.

- [x] **Application-state backup/restore — ✅ CLOSED (2026-07-30, won't
      do).** Proposed as item 3 of the 2026-07-30 structural plan and
      independently recommended as a priority by an external review;
      **the user declined it after seeing the design.** Recorded here so
      it is not re-proposed at each review — only a change in the user's
      workflow should reopen it.

      The design that was scoped and rejected, for reference: a
      **pull** model (`ssh nrm 'master-stack-backup --stdout' > file`
      from the Mac) so the disposable host holds no destination
      credential and needs nothing reinstalled after a reimage;
      consistency via `flock master-stack.lock` + `systemctl stop
      master-compose` around the snapshot (~30s downtime) because
      Portainer/Filebrowser/qBittorrent all use SQLite and a live `tar`
      risks a silently torn database; scope limited to application state
      — `/data/{portainer,qbittorrent,wg-easy}`, the two Filebrowser
      Docker volumes and `/etc/master-stack/webdav.htpasswd` — with
      `state.env`, `compose.yaml` and `.env` **deliberately excluded**,
      since they carry the old host's public and Tailscale addresses and
      restoring them would inject stale values into the canonical bundle
      and fight reconcile. Two caveats that would have needed stating in
      the docs: the archive contains wg-easy's WireGuard private key, so
      it is itself a secret; and restoring wg-easy recovers peers and
      keys but not the endpoint IP baked into existing client configs, so
      a public-IP change still breaks clients regardless.

      **Revisited 2026-07-31 and still closed**, when the user asked
      whether a separate upgrade *and* backup script was warranted. The
      original reasoning holds unchanged. What is now nameable is the
      exposure: wg-easy's WireGuard private key and peer list are the
      only expensive state on the host, because losing them means
      re-provisioning every client device, whereas the Portainer account
      and qBittorrent session are minutes to recreate. If that ever
      becomes worth automating it is roughly ten lines — stop wg-easy,
      `tar` `/data/wg-easy/config`, start it — not the subsystem scoped
      above, and exporting each peer's config from wg-easy's UI at
      creation time covers the same ground with no code at all. The
      separate *upgrade* script was declined outright: `install.sh` is
      the upgrade path (see `docs/architecture.md` → Re-running the
      installer), and a second script would need its own copy of the
      canonical definitions.
- [x] **WebDAV block in the final summary reworked (2026-07-30, `V1-4`
      then `V1-5`).** `V1-4` was a follow-up to `V1-3` after the user
      pointed out the summary did not make clear which address to enter
      in Infuse; it added the username (read back from `htpasswd`, so it
      is right on a re-run that kept an existing credential), the full
      URL, both access paths and several caveats. The user then judged it
      over-long, so `V1-5` cut it to the fields actually needed —
      directory, username, address (`<tailscale-ip>` plus
      `webdav.<domain>` when local DNS is on, using whatever domain was
      chosen), port, protocol, full URL, credential file, reset. The
      explanatory paragraphs about the Caddy path, the removed loopback
      binding and reconcile's re-bind behavior live in DD-20 and
      `docs/architecture.md` instead.
- [x] **sftpgo container → host `rclone` WebDAV service (2026-07-30,
      `V1-3`, DD-20).** Second item of the 2026-07-30 structural plan.
      Replaced the `sftpgo` container with `master-webdav.service`
      (`rclone serve webdav --read-only`, bound to the Tailscale IPv4
      only, credentials from a Stage 0 prompt via bcrypt `htpasswd` +
      systemd `LoadCredential`). Removed the last Tailnet → Docker
      firewall exception, one container, one image pin, a DNAT check,
      three port-binding checks and two Stage 7 binding assertions.
      Reconcile now watches the unit on two signals. **Live-tested
      2026-07-30 and it failed at Stage 7** — three bugs fixed in `V1-6`
      (missing `AF_NETLINK`, a silently-swallowed `ip` error, and all
      three 401 probes written against sftpgo's `OPTIONS` behavior rather
      than rclone's). See below.
- [x] **Stage 5 could not restart a rate-limited `master-webdav.service`
      (2026-07-30, `V1-7`).** Found on the re-run immediately after
      `V1-6`. A unit left `failed` with `StartLimitBurst` exhausted (the
      normal state after a failed install) makes `systemctl restart`
      return non-zero with `Start request repeated too quickly`, killing
      the install at Stage 5. Stage 5 now does `reset-failed` first, the
      same order reconcile's repair path already used — the
      inconsistency between the two was the real defect. **Install then
      succeeded: 7/7 stages in 22 seconds**, `--check` all-zero at exit
      0, and a deliberate drift test (stopping the unit) was detected as
      `webdav_unit=1 webdav_runtime=1` and repaired by reconcile.
- [x] **Three `V1-3` WebDAV bugs found by live testing and fixed
      (2026-07-30, `V1-6`).** All three passed static analysis; only a
      real install surfaced them. (1) `RestrictAddressFamilies` lacked
      `AF_NETLINK`, which iproute2 needs, so `ExecStart` could never
      resolve the Tailscale address and the service never bound. (2) The
      wait loop discarded `ip`'s stderr, so that hard failure looked like
      an ordinary wait and the unit read `active (running)` for 300
      seconds — now the two cases are distinguished and the first error
      is reported immediately. (3) rclone does not authenticate
      `OPTIONS` (it answers 200 where sftpgo answered 401), so every 401
      probe was wrong; they now use `PROPFIND` with `Depth: 0`, which
      additionally proves the htpasswd is enforced. Authentication itself
      was never broken. Re-verified live: listener on the Tailscale IPv4
      only, unauthenticated 401, authenticated 207, gid-1000 media read
      confirmed. **Still untested: Infuse as a real client.**
- [x] **Host-side version self-reporting + `--status` summary
      (2026-07-30, `V1-2`).** `install.sh` now hashes itself at startup
      and writes `STACK_VERSION`/`STACK_SHA256` into `state.env`
      (informational keys, schema stays 8), closing the server-side half
      of the 2026-07-28 version-drift gap. `master-network-reconcile`
      gained a lock-free read-only `--status` mode: version/hash,
      container states, failed units, disk usage, repair stamps, plus an
      embedded `--check` run whose exit code it passes through. First
      item of the 2026-07-30 structural-optimization plan (item 1 of 6).
      Static-verified only (`bash -n`, `shellcheck`, embedded-script
      lint, 57/57 bats); not yet exercised on a live host.
- [x] **M11 — netbuf sysctl moved above `apt-get install -y tailscale`**
      (2026-07-29, `V1-1`). Debian's `tailscale.postinst` runs
      `deb-systemd-invoke restart tailscaled.service`, so the daemon comes
      up inside the package install and the script's own `systemctl enable
      --now tailscaled` never starts it. `wireguard-go` requests its large
      UDP receive buffer once at socket-open time and is clamped against
      the ceiling then in effect, so DD-18's floor was reaching the daemon
      only after the first restart on hosts whose provider image does not
      pre-set `net.core.rmem_max`. The forwarding sysctl deliberately
      stayed put. See `SECURITY_REVIEW.md` M11 and DD-19.

- [x] Full static audit of `install.sh` (4552 lines) across security,
      secrets handling, destructive operations, firewall/network safety,
      Tailscale exit-node config, Compose design, systemd services/timers,
      reconcile/self-healing, idempotency, rollback/cleanup, error
      handling, service coupling, unnecessary services, installation
      profiles, modularization, and testing strategy — results recorded in
      `SECURITY_REVIEW.md` (2026-07-27).
- [x] Created project documentation scaffolding: `README.md`, `CLAUDE.md`,
      `SECURITY_REVIEW.md`, `TODO.md`, `CHANGELOG.md`, `SESSION.md`, and
      `docs/{architecture,design-decisions,profiles,testing}.md`
      (2026-07-27).
- [x] Populated `README.md` with a full description of `install.sh`'s
      current behavior (2026-07-27).
- [x] Populated `CLAUDE.md` with working conventions and guardrails for
      future sessions (2026-07-27).
- [x] **C2** — Removed the `TS_AUTHKEY` prompt entirely from `install.sh`
      (Stage 0 input/summary + Stage 2 connection logic); the installer
      now always uses Tailscale's interactive browser login instead of
      accepting a pasted auth key. Verified with `bash -n` + `shellcheck`
      (2026-07-27).
- [x] **M6** — Removed the entire wg-easy unattended-bootstrap subsystem
      from `install.sh` (Stage 0 admin prompts, Stage 4 `WG_INIT_*` file
      generation + marker-based endpoint tracking, Stage 5
      apply/verify/scrub/marker sequence, Stage 7 hard postcondition, the
      `scrub_wg_bootstrap_container` EXIT-trap cleanup, and the now-dead
      `wg_ui_configured()`/`WG_UI_CONFIGURED` helpers) — 248 lines removed.
      wg-easy admin/peer setup is now fully manual via its web UI, same as
      Portainer/SFTPGo; the script only provisions the container and
      infrastructure. Verified with `bash -n` + `shellcheck` (2026-07-27).
- [x] **M5** — Added an explicit diagnostic to `check_ipv6_policy()`
      (`install.sh:1510-1561`, historical — pre-2026-07-28 numbering) so a
      missing `ip6tables` binary reports
      "ip6tables bulunamadı" instead of a generic policy-drift error.
      Diagnostics-only; fail-closed behavior unchanged. Verified with
      `bash -n` + `shellcheck` (2026-07-27).
- [x] **H1** — Removed `SYS_MODULE` and the `/lib/modules` bind mount from
      wg-easy's `cap_add`/`volumes` (`compose.yaml`), replaced by an
      independent, best-effort `modprobe wireguard` on the host in Stage 4
      (mirrors the existing `modprobe tun` pattern for Tailscale in Stage
      2, but intentionally unrelated to it). wg-easy now runs with only
      `NET_ADMIN`. Hardened further: added `/etc/modules-load.d/wg-easy.conf`
      so the module auto-loads on every future boot (not just the current
      session), and replaced the modprobe-exit-code check with a
      functional probe (`ip link add ... type wireguard` then delete) that
      correctly handles a built-in (non-module) WireGuard kernel too.
      Verified with `bash -n` + `shellcheck`; **still needs real-server
      functional verification** (this assistant cannot access the target
      server) — confirm wg-easy brings up `wg0` successfully after this
      change (2026-07-27).
- [x] **H2 / H3** — Confirmed with the user that reconcile's config-revert
      behavior and the `PartOf` cascading-restart coupling are both
      intentional (not bugs): guaranteeing dnsmasq/Caddy reachability
      against manual drift, and enforcing strict daemon-ordering
      fate-sharing, respectively. No functional change made; added
      explicit warnings to the final install summary naming the affected
      files/units so operators aren't surprised. Verified with `bash -n` +
      `shellcheck` (2026-07-27).
- [x] **M4** — Added an inline comment above `INSECURE: "true"`
      (`compose.yaml` → `services.wg-easy`) explaining the Tailnet-only +
      Caddy-loopback dependency. Comment-only. Verified with `bash -n` +
      `shellcheck` (2026-07-27).
- [x] **L1** — Added `-o Dpkg::Options::="--force-confdef" -o
      Dpkg::Options::="--force-confold"` to the Stage 1 `apt-get
      full-upgrade` call, preventing a theoretical conffile-prompt stall
      in noninteractive mode. Verified with `bash -n` + `shellcheck`
      (2026-07-27).
- [x] **L2** — Documented in `README.md` (Security Notes) that rebuilding
      the server leaves an orphaned, non-ephemeral Tailscale device entry
      in the admin console, to be removed manually (2026-07-27).
- [x] **L4** — Expanded the Docker daemon DNS comment (Stage 3) to
      explicitly state that host and containers deliberately use two
      different DNS resolution paths. Comment-only. Verified with
      `bash -n` + `shellcheck` (2026-07-27).
- [x] **L5** — Added a warning block to the final install summary naming
      Portainer, wg-easy, and SFTPGo, explaining the first-run-race risk,
      and listing each service's URL (with Tailnet hostname if local DNS
      is enabled). Verified with `bash -n` + `shellcheck`, including a
      standalone render test of the conditional URL text for both the
      local-DNS-enabled and local-DNS-disabled cases (2026-07-27).
- [x] **M2** — Replaced the unconditional `chown -R 1000:1000
      "$DOWNLOADS_PATH/media"` (Stage 4) with `find
      "$DOWNLOADS_PATH/media" \( ! -uid 1000 -o ! -gid 1000 \) -exec
      chown 1000:1000 {} +`, so only ownership-mismatched entries incur a
      `chown` write; a fully-correct tree is now a cheap no-op instead of
      a full recursive rewrite. Verified the predicate logic standalone
      (own UID/GID selects nothing; a nonexistent UID selects everything,
      including the root directory) before trusting it. Verified with
      `bash -n` + `shellcheck` (2026-07-28).
- [x] **Legacy reboot-timer cleanup removed** (not a numbered
      `SECURITY_REVIEW.md` finding, but tracked in `SESSION.md` as a
      candidate): deleted `remove_managed_scheduled_reboot()` (Stage 1)
      and its Stage 7 re-verification block — dead weight for this
      deployment target, which is always a fresh Debian 13 install with
      no prior r3-or-earlier version of this script to migrate away from.
      61 lines removed. Verified with `bash -n` + `shellcheck`
      (2026-07-28).
- [x] **L3** — Removed `tailscale-udp-gro.service`'s continuous reconcile
      integration (~54 lines: `GRO_INACTIVE`/`GRO_DRIFTED` detection, the
      `all_managed_state_healthy()` wrapper, `--check` output fields, the
      warning message, and the repair action), replacing its sole caller
      with `all_critical_state_healthy` directly (GRO was already
      excluded from the critical rollup, so no pass/fail semantics
      changed). Also removed two variables that became dead as a result
      (`ETHTOOL_BIN`, `CURRENT_WAN6_IF` inside the reconcile heredoc),
      caught by manual review since `shellcheck` doesn't see inside
      heredoc content (see **H4**). Stage 2's one-time setup (needed for
      per-boot persistence, since ethtool settings don't survive reboots)
      is unchanged. Net 57 lines removed. Verified with `bash -n` +
      `shellcheck` (2026-07-28).
- [x] **C1** — Resolved as accepted risk (no `install.sh` change).
      Reconsidered the original "add a docker-socket-proxy" recommendation
      and found it a weak fit for Portainer specifically: Portainer's own
      management features need close to the same broad Docker API access
      that makes the direct socket mount risky, so a meaningfully
      restrictive proxy would break Portainer's usefulness. (Also noted a
      read-only socket mount isn't a real mitigation — Unix domain sockets
      aren't gated by the mount's `ro` flag.) User confirmed Portainer is
      actively used for container monitoring/intervention and accepted the
      risk, scoped by network exposure (`127.0.0.1` + tailnet-only) rather
      than API restriction. Documented in `README.md` (2026-07-28).
- [x] **H4** — Added `scripts/lint-embedded-scripts.sh`: extracts all six
      embedded heredoc scripts from `install.sh` (`tailscale-udp-gro`,
      `docker-tailscale-fw`, `master-compose-ipv4`,
      `master-network-reconcile`, `master-docker-netfilter-recovery`,
      `caddy-tailnet-env`) via `sed` line-range matching on their known
      start/end markers, then runs `bash -n` + `shellcheck` on each
      independently (`SC2016` excluded — it's a documented false-positive
      class for the intentional single-quoted `awk` programs throughout
      these scripts). First real run: `master-docker-netfilter-recovery`
      clean, the other five had only the expected excluded `SC2016`
      notices — no actual bugs, but ~1900 lines that had never been
      statically checked before are now covered going forward. Verified
      the tool also catches real failures: injected a synthetic syntax
      error into a scratch copy of `install.sh` (never the tracked file)
      and confirmed `bash -n` failure was correctly reported with a
      non-zero exit. CI wiring (e.g. GitHub Actions) not attempted — no
      CI exists in this repo yet; run manually for now. `install.sh` was
      not modified (2026-07-28).
- [x] First live Tier 3 install test (2026-07-28) — see `docs/testing.md`.
      Ran `install.sh` end-to-end, interactively, against the user's own
      server (freshly reimaged to Debian 13, same host that had been in
      production). Install failed at Stage 5.
- [x] **H1 regression fix** — the live test found that **H1**'s fix
      (removing wg-easy's `SYS_MODULE`) only `modprobe`d `wireguard` on
      the host, not `ip6_tables`/`ip6table_nat`, which `wg-quick up wg0`
      also needs for its legacy-ip6tables PostUp/PostDown rules. Fixed by
      extending the same Stage 4 modprobe step (now a loop) and
      `/etc/modules-load.d/wg-easy.conf` to cover all three modules.
      Confirmed live before applying to `install.sh`. `bash -n` +
      `shellcheck` clean (2026-07-28).
- [x] **H5** (new finding, resolved same day) — wg-easy's healthcheck
      asserted a fixed WireGuard listen port, which can never match on a
      fresh install since **M6** made the port a manual, web-UI-only
      setting (no env var). Removed the port assertion; healthcheck now
      only checks that `wg0` exists and is up. `bash -n` + `shellcheck`
      clean (2026-07-28).
- [x] Second live Tier 3 install test (2026-07-28) — server reimaged
      clean again with the **H1**/**H5** fixes in place. Stages 0-6 all
      succeeded this time (a first); failed at Stage 7.
- [x] **H6** (new finding, resolved same day) — `check_compose_runtime()`
      counted wg-easy's still-pending first-run setup as `compose_runtime`
      drift, which Stage 7's `master-network-reconcile --check`
      postcondition gate treats as a hard failure under `set -e` — every
      fresh install would fail here even with **H1**/**H5** fixed.
      Confirmed live (manual `--check` run showed every other field `0`,
      only `compose_runtime=1` due to the pending-setup message). Fixed by
      removing `runtime_ok=1` from that one branch only (kept the
      diagnostic message and `WG_CONFIGURATION_INVALID=1`); the periodic
      reconcile timer's own separate operator reporting of this condition
      is unaffected. `bash -n` + `shellcheck` clean (2026-07-28).
- [x] **Third live Tier 3 install test (2026-07-28) — first full success.**
      Server reimaged clean again with all three fixes (**H1** regression,
      **H5**, **H6**) in place. All 7 stages completed successfully
      end-to-end for the first time. Confirmed live: all 6 containers up
      (`wg-easy`/`filebrowser` healthy), all core systemd units active, no
      failed units, and a manual `master-network-reconcile --check` now
      exits `0` (still prints the informational wg-easy-setup-pending
      message, exactly as **H6** intended — visible, non-blocking).
- [x] **M1 (fully resolved, 2026-07-28)** — determined the minimal
      working `cap_drop`/`cap_add`/`read_only` config for `qbittorrent`/
      `unpackerr` empirically, via isolated throwaway `docker run` test
      containers (never the real stack). `unpackerr`: `cap_drop: [ALL]`
      + `read_only: true`, both clean. `qbittorrent`: `cap_drop: [ALL]` +
      `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER]` (confirmed
      minimal — trimming further breaks config-directory creation);
      `read_only: true` confirmed to break its PUID/PGID mechanism (files
      end up owned by `911:1001` instead of `1000:1000`) so deliberately
      not applied. Applied to `install.sh`; `bash -n`/`shellcheck`/
      `scripts/lint-embedded-scripts.sh`/`bats test/` all clean.
- [x] **Fourth live Tier 3 install + full operational test (2026-07-28).**
      Server reimaged clean once more with all fixes (**H1** regression,
      **H5**, **H6**, **M1**) in place — succeeded end-to-end again. Then,
      with the user's explicit broad testing latitude (host had no
      production data), ran a comprehensive operational validation on the
      live install: real admin accounts configured for every service;
      real WireGuard client connection confirmed (handshake, 0% loss,
      ~58-107ms RTT, tested via `docker exec wg-easy ping` from inside
      the container's own network namespace); Tailscale exit-node
      confirmed genuinely routing real traffic via firewall mangle-chain
      counters, not just configured; a full reboot confirmed **H1**'s
      module-loading fix persists across reboots and all 6 services
      recover automatically within ~22s; three simultaneous deliberate
      drifts (stopped container, disabled IP forwarding, deleted firewall
      rule) were all detected and repaired by reconcile in one 5-minute
      cycle; **M1**'s `mem_limit` confirmed to actually enforce via a
      throwaway-container OOM test; `unpackerr`'s new hardening confirmed
      under a real extraction workload; a 4-core CPU stress test showed
      all services staying responsive and reconcile completing
      successfully mid-stress. Investigated a perceived SFTPGo/WebDAV
      connection delay and found no server-side cause (0-7ms request
      times, no retries) — very likely client-side (Tailscale peer
      connection setup / manual admin-UI configuration time). No new
      bugs found this round — confirmatory testing of the day's four
      fixes under real operating conditions. See `docs/testing.md`
      Tier 3 for the full narrative.
- [x] **Final architecture review + disk-space monitoring (2026-07-28,
      R1.0).** Deep-dive review of `master-network-reconcile`'s full
      monitored-state list, systemd unit dependencies, IPv6, container
      DNS, and wg-easy's kernel-module approach, with live verification
      of each — no functional defects found. Confirmed: IPv6 egress works
      end-to-end (including from inside `wg-easy`); containers reach
      `1.1.1.1`/`1.0.0.1` directly regardless of the host's
      Tailscale-overridden DNS; wg-easy's H1 approach is the standard
      hardening pattern, not indirect; a Tailscale IP change correctly
      cascades to firewall/`.env`/container recreation; Caddy/dnsmasq
      boot ordering is defended in depth (`bind-dynamic`, an active
      `ExecStartPre` wait, a reverse systemd trigger, and reconcile as a
      backstop) and showed zero races in real boot logs. Added the one
      concrete gap found — disk-space monitoring — to
      `master-network-reconcile` (new `disk_space_ok()`, checks the
      filesystem backing `$DOWNLOADS_PATH`, now persisted in
      `state.env`). Tested live: correctly reports healthy on the real
      disk and correctly flags an artificially filled 10MB tmpfs at 90%.
      `install.sh` 4319 → 4343 lines. Verified with `bash -n`,
      `shellcheck`, `scripts/lint-embedded-scripts.sh`, `bats test/`.
      Tailscale key-expiry monitoring was considered and declined by the
      user (tracked manually instead). **Tagged R1.0.**
- [x] **H7 (new finding, resolved, 2026-07-28, first v1b fix).** Found
      via real usage after R1.0: Portainer rejected every write request
      made through `portainer.ayc` (CSRF "origin invalid" — Caddy always
      presents `Host: 127.0.0.1:9443` to Portainer while the browser's
      Origin is `http://portainer.ayc`). Fixed with Portainer's
      `TRUSTED_ORIGINS` env var. First attempt
      (`http://portainer.$LOCAL_DOMAIN`, matching Portainer's `develop`
      branch) was tested against the live deployed `compose.yaml` first
      and **crashed Portainer** — the pinned `2.39.5` release uses the
      older `gorilla/csrf` library, which expects a bare hostname (no
      scheme) and rejects anything containing `"://"`. Caught by reading
      `2.39.5`'s actual tagged source rather than `develop`. Reverted
      immediately, corrected to `portainer.$LOCAL_DOMAIN`, confirmed live
      (container stable; a simulated write request now returns `401`
      instead of `403`), then applied to `install.sh`. `install.sh` 4343
      → 4365 lines. Verified with `bash -n`, `shellcheck`,
      `scripts/lint-embedded-scripts.sh`, `bats test/`.
- [x] **M1 `mem_limit` correction (2026-07-28).** User reported a real
      `qbittorrent` download-speed regression (~200MB/s → ~70-80MB/s)
      after M1 and asked if the resource limits were the cause. Live
      A/B/C test during an actual high-seed torrent download (container
      recreated between each window, same active transfer): original
      `cpus=2.0/mem=2g` capped throughput ~170MB/s (CPU saturating near
      the 2-core limit); limits removed reached 218-278MB/s; isolating
      the variable (`cpus` held at `2.0`, only `mem_limit` raised to
      `4g`) also reached up to 275MB/s with CPU comfortably under the
      cap — proving the `2g` memory ceiling (not CPU) was the real
      constraint; the CPU saturation seen in the first test was a
      downstream symptom of memory-constrained disk caching, not an
      independent bottleneck. Raised `mem_limit` to `4g`; `cpus: 2.0`
      unchanged. Applied to the live `compose.yaml` for the test, then to
      `install.sh`. `install.sh` 4365 → 4370 lines. Verified with
      `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh`,
      `bats test/`.
- [x] **`qbittorrent` resource ceilings removed (2026-07-28).** Even at
      `4g`, sustained high-throughput load fluctuated again; a `6g`/
      `cpus: 3.0` attempt (tried locally, never committed) made it clear
      each raise was chasing real usage rather than bounding abuse — on
      this 4 CPU / ~8GB host, `6g` already exceeded the highest observed
      unlimited usage (~4.7GB), so it constrained nothing while still
      able to throttle a future workload. Both `mem_limit` and `cpus`
      removed from `services.qbittorrent`. **M1**'s privilege hardening
      (`no-new-privileges`, `cap_drop: [ALL]`, minimal `cap_add`) and
      `unpackerr`'s own `512m`/`1.0` ceilings are unchanged. Residual
      risk accepted by the user and recorded under **M1** in
      `SECURITY_REVIEW.md`: a runaway `qbittorrent` is now bounded by the
      host's global OOM killer rather than its own cgroup. `install.sh`
      4370 → 4376 lines. Verified with `bash -n`, `shellcheck`,
      `scripts/lint-embedded-scripts.sh`, `bats test/`.
- [x] **Whole-file review of the post-R1.0 script (2026-07-28).** Re-read
      all 4376 lines end to end after the **H7**/**M1** point fixes, with
      read-only live verification on the running host. Found five new
      findings (**M8**, **M9**, **M10**, **L6**, **L7**) — none of them
      regressions from those two changes. Also cleared the
      highest-risk-looking hypothesis by reading Portainer 2.39.5's own
      source: an empty `TRUSTED_ORIGINS` (the local-DNS-disabled path,
      still never exercised live) is guarded before the validation loop,
      so **H7**'s startup crash cannot recur there.
- [x] **M8 (2026-07-28; atomicity claim corrected by H8/Q1-16).** Canonical
      bundle publication moved out of Stage 4 to the end of Stage 6, so the
      manifest and the `LOCAL_DNS_ENABLED` value it is validated against
      always become visible together. Previously Stage 4 truncated the
      manifest to one entry while publishing a possibly
      `LOCAL_DNS_ENABLED=1` `state.env`, leaving the bundle
      self-inconsistent for all of Stages 4-6; a re-run that failed in
      that window left reconcile hard-exiting at `canonical_bundle_ok()`
      every 5 minutes with no self-healing at all. The old entry called
      that end block atomic, although its nine copies were sequential and
      only the manifest rename was atomic. H8/Q1-16's verified generation
      pointer is what now guarantees that a failed re-run keeps the
      previous complete bundle.
- [x] **M9 (2026-07-28, accepted risk + diagnostics).** Pinning
      `docker-ce` was considered and rejected (it would freeze CVE fixes
      on a host publishing ports to the public IPv4). Instead
      `ensure_forward_prefix()` now names the missing chain, the binary
      and the likely cause rather than returning a bare non-zero that
      `set -e` turns into a silent abort. The coupling itself — the
      firewall assumes Docker's internal `DOCKER-USER`/`DOCKER-FORWARD`/
      `ts-forward` layout, and every re-run upgrades Docker via Stage 1's
      `full-upgrade` — is documented in `docs/design-decisions.md`
      (DD-15). Verified live: Docker 29.6.2 still matches the assumption.
- [x] **L6 (2026-07-28).** The stack-level repair path
      (`STACK_RESTART_REQUIRED`) now reuses the same 15-minute
      `restart_budget_available`/`record_container_restart` budget the
      per-container restarts already use, under a `master-compose`
      pseudo-target, so an unrepairable drift retries every 15 minutes
      instead of re-running the firewall reapply plus
      `docker compose up --wait` on every 5-minute cycle forever.
      `ADDRESS_CHANGED` is exempt — it self-clears after one successful
      pass and deferring it would strand the published bindings on a
      stale IP.
- [x] **Version string corrected (2026-07-28).** `MASTER_SETUP_VERSION`
      `2026.07.26-r8` → `2026.07.28-v1b`, and reconcile's two summary
      lines no longer print an "R8" prefix, so logs identify which
      release actually ran. `STACK_SCHEMA=8` deliberately left alone — it
      versions `state.env`'s on-disk format, which did not change; a
      comment now states that distinction at the definition site.
      `install.sh` 4376 → 4418 lines. Verified with `bash -n`,
      `shellcheck`, `scripts/lint-embedded-scripts.sh`, `bats test/`.
- [x] **M10 (2026-07-28, narrowed scope).** `/root/docker/compose.yaml`
      now has a canonical copy, a manifest entry and a `compose_file_ok()`
      comparison in reconcile. Drift is **reported only** — not restored,
      not part of `CONFIG_DRIFTED`, not part of
      `all_critical_state_healthy()` — so it never produces a failed unit
      and never blocks Stage 7. `docker-tailscale-fw` was dropped from the
      proposed scope: it is never hand-edited on a single-operator host
      that is always installed fresh, and checking it is near-theater
      given reconcile validates the firewall by invoking that same helper.
      `compose.yaml` earns the check because it genuinely is edited live
      on this stack, so the value is catching a live change not yet folded
      back into `install.sh`. Note the message is emitted at detection
      time, since the drift-reporting block sits after
      `all_critical_state_healthy()`'s early exit. `install.sh` 4418 →
      4449 lines. Verified with `bash -n`, `shellcheck`,
      `scripts/lint-embedded-scripts.sh`, `bats test/`.
- [x] **Unit tests for `canonical_bundle_ok()` (2026-07-28, first v1b-cycle
      work).** `test/canonical_bundle.bats`, 8 cases. Covers reconcile's
      first gate — a non-zero return there exits before any detection or
      repair, silencing self-healing entirely. Its correctness depended on
      Stage 6's manifest file list agreeing with a hardcoded expected list
      ~2000 lines away, which nothing enforced and no static check could
      see; **M8** and **M10** had both edited the local-DNS-disabled
      branch, which no live install has ever executed. The tests derive
      both file lists from `install.sh`'s own source rather than restating
      them, and were mutation-verified on a scratch copy (dropping
      `compose.yaml` from Stage 6's list makes the test fail as intended).
      `sha256sum` and `owned_file_ok` are stubbed as out of scope, so all
      8 run with no skips on any POSIX host. 40 cases total across
      `test/`. `install.sh` untouched.
- [x] **Replace FileBrowser Quantum — closed as won't do (2026-08-02,
      DD-36).** Three alternatives investigated in one day, none adopted.
      **Filestash** (proposed as v3) fails structurally: its `config.json`
      is runtime state rewritten by `Initialise()` on first start, so it
      cannot be a read-only bind mount or a canonical bundle entry —
      reconcile would revert admin changes every twenty minutes, and
      adopting it would have deleted the policy-file mechanism this branch
      is built around. It also publishes only `latest`. **A native
      non-Docker file manager with RAR extraction** has no good candidate:
      Quantum does not extract in place, copyparty creates archives but
      does not extract, and elFinder — the one that does — has that exact
      code path as its CVE history, which is the class this project
      deleted filebrowser's shell-command feature to escape. RAR was never
      a file-manager problem here anyway: unpackerr already extracts
      recursively across the whole media tree. **Nextcloud** fits on the
      hardware (measured: 7.8 GB host, 863 MB used, five containers
      ~130 MB) but reads its file list from `oc_filecache` rather than the
      disk, so qBittorrent's and unpackerr's writes stay invisible until
      `occ files:scan`, and it cannot skip major versions — which would
      leave reconcile restarting a container it cannot repair. Each has a
      written reopen condition in DD-36; the Nextcloud one is "only if
      groupware features are wanted, and then alongside, never instead".
- [x] **Fold the Quantum policy file into `compose.yaml` — closed as
      won't do (2026-08-02, DD-35).** Requested by the operator: one
      configuration surface instead of two. Blocked by a hard conflict,
      measured rather than assumed. Environment variables cannot express
      the policy (every `FILEBROWSER_*` string in the v1.5.0 binary is a
      secret or a path; none reaches `sources`, `cacheDir`, `signup` or
      `minLength`). Compose *can* inline it via `configs: content:` — that
      was verified working against the real image — but refuses to on a
      `read_only: true` service: `` `file` is the sole supported option ``,
      a service-level check that a writable target path does not get
      around. So the policy lives in `compose.yaml` **or** the container's
      root filesystem stays frozen, never both. Dropping `read_only` costs
      nothing functionally (`docker diff` measured zero writes without it),
      but that is the wrong measurement — it is a containment control, and
      the operator chose to keep it. Reopens if Compose supports inline
      configs on read-only services, or if Quantum gains environment
      variables for those three settings.
- [x] **M3 — closed as won't do (2026-07-28).** The finding's premise, that
      an operator is forced to accept exposure they don't need, does not
      hold here: all six services are in active use, the host is
      single-purpose and single-operator, always installed from scratch
      onto an empty server, and local DNS is enabled on every install. The
      security motivation (avoiding Portainer's `docker.sock`) is already
      covered by **C1**'s accepted risk. Implementing profiles would make
      compose generation, the `state.env` schema, `expected_containers`,
      the public-port firewall rules and every Stage 7 per-service
      assertion conditional — a combinatorial set on a project whose Tier
      3 testing is still a manual live install. `docs/profiles.md` is kept
      as a design note in case the installer is ever reused across hosts
      or by someone else, which is what would reopen this.
- [x] **L7 — closed as won't do (2026-07-28).** Both candidate fixes were
      declined. The runtime-read-from-`state.env` fix is the real
      single-source solution but edits the most security-critical file in
      the project for a problem that cannot occur under this deployment
      model; the cheaper Stage 3 tripwire adds code to guard a scenario
      that does not arise. Reopens under the same condition as **M3**.
- [x] **Unit tests for `check_ipv4_policy`/`check_ipv6_policy`
      (2026-07-28).** `test/policy_functions.bats`, 17 cases. These two
      functions hold the project's entire expected firewall rule set and
      produce the verdict `docker-tailscale-fw --check` returns — the
      signal reconcile trusts wholesale. `docs/testing.md` had assumed
      they were too integration-shaped to unit-test; that was too
      pessimistic, since they only read state and their remaining
      dependencies are assignable globals. Covers the healthy policy plus
      eleven distinct failure shapes, and the IPv6 variants including
      **M5**'s missing-`ip6tables` diagnostic and the reduced
      no-IPv6-WAN set. A table/chain-dispatching fake avoids bash
      associative arrays, so all 17 run with no skips on this
      workstation. 57 cases total across `test/`. `install.sh` untouched.
- [x] **UDP socket buffer ceilings are now floored by the installer
      (2026-07-29).** Stage 2 writes
      `/etc/sysctl.d/99-master-stack-netbuf.conf` with
      `net.core.rmem_max`/`wmem_max` at `max(current, 16 MiB)`. On the live
      host both were already 64 MiB — but from the VPS provider's own
      image file, not from `install.sh`, so the value was correct by
      accident and would have been Debian's 208 KB anywhere else.
      Originally proposed as a WireGuard optimization; measurement showed
      that was wrong (kernel WireGuard consumes packets via `encap_rcv`
      before the socket receive queue, and the container netns reported
      `RcvbufErrors 0` after 5M datagrams). The real beneficiary is
      Tailscale — userspace WireGuard — whose `tailscaled` was observed
      holding a 14 MiB buffer. Raise-only and idempotent; `rmem_default`
      deliberately untouched. See DD-18.
- [x] **Reconcile now guards `tailscale-udp-gro.service` (2026-07-29).**
      The unit is `Type=oneshot` with `Restart=no`, so a boot-time failure
      — the case Stage 2 already anticipates and `reset-failed`s —
      persisted until the next reboot. Reconcile now reads its
      `ActiveState` and restarts it under the existing 15-minute cooldown.
      Deliberately narrower than the ~54 lines DD-11 removed: the *unit*
      is checked, ethtool flags are still not polled. Excluded from
      `all_critical_state_healthy()` and the exit code since GRO is
      throughput-only; reported as `gro_unit=` in `--check`. Also fixes
      the unit comment, which had claimed reconcile retried it — untrue
      since DD-11.
- [x] **Stage 0's DNS prompt no longer aborts its own re-run
      (2026-07-29, `v1rc-2`).** The prompt defaulted to `H` regardless of
      whether a managed DNS/Caddy install existed — and that answer makes
      Stage 0 abort a few lines later with "Önceki yönetilen DNS/Caddy
      kurulumu bulundu". Pressing Enter on a re-run killed the installer.
      Found the hard way during the 2026-07-29 live verification run, not
      by reading the code. Existing-install detection now happens once and
      feeds both the default (`E`, shown as `[E/h]`) and the abort check,
      so the two cannot drift apart. Fresh installs still default to `H`.
- [x] **Reconcile now guards the UDP GRO ethtool flags, not just the unit
      (2026-07-29, `v1rc-2`).** Fault injection proved the unit check
      alone was insufficient: after `systemctl stop tailscale-udp-gro`,
      `rx-udp-gro-forwarding` was still `on`, so the throughput
      optimization had never actually degraded and a unit-only check
      verifies bookkeeping rather than the thing it protects. Added
      `gro_flags_ok()` reading `CURRENT_WAN4_IF` (already computed) via a
      reinstated `ETHTOOL_BIN`; repair for either signal is `systemctl
      restart`, so systemd remains the single execution path. Everything
      unevaluable (no ethtool, no WAN interface, feature unreported or
      `[fixed]`) counts as healthy, matching the helper's own success
      cases so the two cannot disagree into a restart loop. ~15 lines
      versus the ~54 DD-11 removed. Reported as `gro_flags=` in `--check`.
- [x] **Stage 0's domain prompt now defaults to the installed domain
      (2026-07-29, `v1rc-3`).** The `v1rc-2` fix stopped the re-run abort
      but left the domain question defaulting to a hardcoded `ayc`, and
      told the user "varsayılan: korunur" — a promise the code did not
      keep on any host using a different domain. Stage 6 writes both
      `local-services.conf` and the `Caddyfile` with `>`, so a changed
      domain replaces the old names rather than duplicating them: the
      switch would have been silent until DNS stopped resolving. The
      default now reads `LOCAL_DOMAIN` from `state.env` (validated by the
      existing domain checks, so a corrupt file is caught) and the prompt
      states the detected domain plus what each branch does — `E`
      regenerates, `h` aborts. Found by the user reading the new prompt
      and asking what it actually does, which the wording did not answer.
- [x] **Stage 0's re-run prompt now asks about changing the domain, not
      installing DNS (2026-07-29, `v1rc-4`).** `v1rc-2` and `v1rc-3` fixed
      the default and the domain source, but the question itself was still
      wrong for a re-run: asking "kurulsun mu?" when DNS is already
      installed made `h` mean "abort" rather than "leave it alone", which
      is not what any user reading that prompt would expect. The re-run
      branch now asks "Alan adı değiştirilsin mi? [e/H]" — `e` prompts for
      the new domain, Enter/`H` preserves the existing domain and
      structure and the install continues. The abort path is deleted
      rather than defaulted away from: refusing to change is a normal
      outcome, and the guarantee that DNS is never silently removed is now
      structural, because that option is never offered. Enter means
      "change nothing" in both the fresh and re-run branches. Domain
      validation consolidated into one block that every branch — including
      the `state.env`-sourced value — passes through. Verified across nine
      branch combinations.
- [x] **qBittorrent's socket receive buffer documented as a manual
      post-install step (2026-07-29, `v1rc-5`).** Measured rather than
      assumed: during a real ~278 MB/s download the uTP/DHT socket sat at
      101% of the 208 KB default buffer and accumulated ~900 drops in
      roughly 90 seconds; once the application-level setting was applied
      mid-download, the same load pushed 288,201 packets through in 30
      seconds with **zero** drops. The kernel granted `2 × rmem_max`
      (128 MiB), which proves DD-18's `rmem_max` floor is the load-bearing
      half of the fix — without it the same request would have been
      clamped to 416 KB on Debian's default, 300× smaller. `rmem_default`
      was considered and rejected: the application requests its own size,
      so raising a system-wide default would have been the broader change
      for no additional benefit. Since `install.sh` deliberately does not
      manage qBittorrent's config (same model as the wg-easy/Portainer/
      SFTPGo admin accounts), the setting is lost on a fresh install — so
      the install summary now states it, with the measured rationale and
      a suggested 16 MiB value.
