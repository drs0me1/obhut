# Testing Strategy

## Planned testing strategy

> **Status (2026-07-28): Tier 1 implemented; Tier 2 partial (32 unit
> tests); Tier 3 had its first real, manual attempt (found and fixed two
> real bugs, **H1** regression + **H5** — see below); CI wiring still not
> attempted.** There is still no automated test suite or CI pipeline for
> this repository (finding **M7** in `SECURITY_REVIEW.md`). The only
> end-to-end correctness signal remains a real, human-supervised install
> run — Stage 7's own runtime verification never actually ran to
> completion in the 2026-07-28 attempt, since it failed earlier at Stage
> 5. This document proposes a staged strategy to eventually make this
> repeatable via CI, without requiring a human to relay every prompt by
> hand each time.

### Why this is hard

`install.sh` is inherently destructive: it rewrites firewall rules,
systemd units, the Docker daemon configuration, and network state on a
real host. It cannot be meaningfully "dry-run" — most of its logic
(firewall staging-chain swaps, systemd dependency graphs, Tailscale
exit-node state) only means something against a live `systemd` + real
network interfaces. Any test strategy has to accept that the deepest
level of testing requires disposable infrastructure, not local unit tests
alone.

### Tier 1 — Static analysis (cheapest, run on every change) — ✅ IMPLEMENTED (2026-07-28)

- `bash -n install.sh` and `shellcheck install.sh` — usable today, and
  should be run before proposing any change to `install.sh`.
- **Gap closed:** `scripts/lint-embedded-scripts.sh` now extracts all six
  embedded heredoc scripts (`tailscale-udp-gro`, `docker-tailscale-fw`,
  `master-compose-ipv4`, `master-network-reconcile`,
  `master-docker-netfilter-recovery`, `caddy-tailnet-env`) into temp files
  via `sed` line-range matching on their known start/end markers, then
  runs `bash -n` + `shellcheck` on each independently (`SC2016` excluded —
  a documented false-positive class for the intentional single-quoted
  `awk` programs throughout these scripts). Resolves **H4** in
  `SECURITY_REVIEW.md`. Run it with `./scripts/lint-embedded-scripts.sh`
  (optionally pass a path to a different install script as the one
  argument); it requires no root privileges and makes no real system
  changes — it never executes `install.sh` or any extracted script, only
  `bash -n`/`shellcheck` them. First real run: `master-docker-netfilter-recovery`
  was clean; the other five had only the expected, now-excluded `SC2016`
  notices.
- **Not done yet:** wiring this into an actual CI pipeline (e.g. GitHub
  Actions) — this repo has no CI configuration yet, and standing one up
  wasn't confirmed as wanted. Run the script manually for now, e.g. as a
  pre-commit/pre-push habit whenever `install.sh` changes.

### Tier 2 — Unit tests for pure-logic functions — 🟡 STARTED (2026-07-28)

- Several functions in the embedded scripts are pure logic that doesn't
  require root or real network state to test in isolation, e.g.
  `state_value`, `owned_file_ok`, `chain_rules_exact`,
  `jump_is_first_and_single`, `detect_ipv4_route`'s parsing logic.
- **Implemented so far:** `test/reconcile_functions.bats` covers
  `state_value` and `owned_file_ok`, both from the `master-network-reconcile`
  heredoc. It reuses the same `sed` marker-based extraction as
  `scripts/lint-embedded-scripts.sh` to pull the heredoc body out of
  `install.sh`, then an `awk` pass to isolate just these two function
  definitions (from `name() {` to the matching top-level `}`) — the full
  reconcile script is never sourced, since it runs real `flock`/`systemctl`
  calls at its top level the moment it's loaded, which would be unsafe
  outside a provisioned host. Only the extracted function bodies are
  sourced into the test shell and exercised against throwaway fixture
  files (temp `state.env` files; temp files with controlled `chmod`) — no
  root, no systemd, no Docker. Run with `bats test/reconcile_functions.bats`.
  - `owned_file_ok`'s uid:gid:mode match/mismatch cases depend on GNU
    coreutils' `stat -c '%u:%g:%a'` syntax, which matches install.sh's
    Debian target but not a macOS dev workstation's BSD `stat` (no `-c`
    support). Those two cases self-skip with an explicit reason when GNU
    `stat` isn't available, rather than failing on an environment gap
    unrelated to the function's actual logic; they run for real on Linux.
  - `chown` to an arbitrary UID/GID isn't testable without root, so
    `owned_file_ok`'s UID/GID-mismatch case is not covered — only the mode
    mismatch is.
- **Also implemented:** `test/firewall_functions.bats` covers six more
  pure-logic functions from the `docker-tailscale-fw` heredoc:
  `route_value`, `chain_rules_exact`, `jump_is_first_and_single`,
  `forward_prefix_is_exact`, `docker_forward_has_no_terminal_drop`, and
  `no_stale_staging_chains`. All five predicate functions take an
  iptables/ip6tables binary path as their first argument and only ever
  call it with `-S`/`-C` to read state, never to mutate rules, so tests
  substitute a fake shell-function stand-in (`fake_bin`) that returns
  canned `-S` rule listings / `-C` exit codes instead of calling real
  `iptables`/`ip6tables` — no root, no real firewall touched.
  `route_value` (the shared parsing helper behind `WAN4_IF`/
  `PUBLIC_IPV4`/`WAN6_IF` detection) is tested the same way against a fake
  `IP_BIN` returning canned `ip route get` output. 20 test cases, all
  passing. Run with `bats test/firewall_functions.bats` (or
  `bats test/` for the whole suite).
  - Note: `detect_ipv4_route` itself (which calls `route_value` in
    Stage 2) lives in `install.sh`'s outer script, not a heredoc, and
    calls `exit` directly on failure — it's already covered by
    `bash -n install.sh`/`shellcheck install.sh` directly and isn't a good
    fit for the extract-a-function-body technique used here, which is why
    `route_value` (its underlying reusable parsing logic) is tested
    instead.
- **Also implemented:** `test/gro_functions.bats` covers
  `add_default_netdev`, the one standalone function in the
  `tailscale-udp-gro` heredoc (dedupes discovered default-route interfaces
  into `NETDEVS`/`SEEN`). Tested the same way, against a fake `IP_BIN`
  returning canned `ip route get` output. 5 test cases.
  - All 5 cases self-skip on this macOS dev workstation: the function's
    dedup guard requires `SEEN` to be a bash associative array (bash 4+),
    and this workstation's default `/bin/bash` is 3.2, which pre-dates
    associative arrays entirely — unlike the Debian 13 target's bash 5.x.
    They run for real on Linux (or with a bash 4+ install on macOS, e.g.
    via `brew install bash`, not done here since it wasn't requested).
- Surveyed the other three embedded scripts
  (`master-compose-ipv4`, `master-docker-netfilter-recovery`,
  `caddy-tailnet-env`) for further pure-logic candidates and found none:
  each is almost entirely a `sleep`-based wait loop plus real side effects
  (file writes via `mktemp`+`mv`, `flock`, `systemctl restart/start`) with
  no standalone function to extract. The one piece of non-trivial logic
  worth calling out — `master-docker-netfilter-recovery`'s restart-cooldown
  check (timestamp read + `NOW - LAST < COOLDOWN_SECONDS`) — is inline at
  the script's top level, not in a function; extracting it into a testable
  function would be an `install.sh` behavior-preserving refactor, not just
  a test addition, so it's left for a future session if the user wants to
  pursue it explicitly, rather than folded into this survey.
- **Remaining:** `check_ipv4_policy`/`check_ipv6_policy` (the composite
  functions that call the above predicates together against real global
  state like `TS_GUARD_CHAIN`/`POLICY_CHAIN`/`WAN4_IF`) are not unit
  tested — they're more integration-shaped (many globals, real `-C`
  calls against `$IPTABLES_BIN` directly) and are a natural Tier 3
  (live-host) check instead.
- Longer-term, a small sourceable library file (extracted once, not
  per-test) would remove the need to re-extract function bodies via
  `sed`/`awk` in every test file — a meaningful, low-risk first step
  toward the modularization discussed in `docs/design-decisions.md`
  (DD-9), without requiring the full heredoc-to-file migration up front.

### Tier 3 — Integration testing (disposable VM) — 🟡 FIRST REAL ATTEMPT (2026-07-28)

- Full end-to-end verification requires actually running `install.sh` —
  this must only ever happen against a host with no data worth losing,
  never a shared or long-lived host with real user data on it.
- **First real attempt (2026-07-28):** the user reimaged their own server
  clean (same host/IP that had been running the pre-remediation
  production stack for about a day) specifically to use as this tier's
  target, and gave explicit, turn-by-turn approval to run `install.sh`
  against it. This assistant verified the target was genuinely fresh
  first (2-minute uptime, 1% disk used, no Docker installed) rather than
  trusting the hostname alias alone.
  - **How the interactivity problem was solved:** `install.sh`'s prompts
    read from `/dev/tty` directly (not stdin — deliberate, so the script
    stays pipeable from `curl`), so a stdin/heredoc automation trick
    doesn't work. Instead, the script was run inside a `tmux` session
    (a real PTY) on the server; this assistant relayed each prompt's
    text into the conversation, the user supplied every answer, and the
    answer was sent back via `tmux send-keys`. This assistant chose no
    configuration values itself.
  - **What "never initiated by this assistant directly" meant in
    practice:** every mutating step — installing `tmux`, transferring
    `install.sh`, starting the interactive install, a targeted container
    restart to check a log, and the diagnostic `modprobe`/`systemctl
    restart`/`docker restart` used to confirm a root cause — was proposed
    first and only run after the user's explicit, specific approval in
    that turn. The original wording ("never initiated by this assistant
    directly") predates this first attempt and undersold what turned out
    to be workable: explicit per-action approval, not zero assistant
    involvement, is the actual safeguard.
  - **Result:** Stages 0-4 completed cleanly; Stage 5 failed
    (`docker compose up --wait` timed out on `wg-easy`'s healthcheck).
    Diagnosis found two real bugs invisible to static review — a
    regression in **H1** (missing `ip6_tables`/`ip6table_nat` modprobe)
    and a new finding, **H5** (a healthcheck assertion that could never
    pass after **M6**) — both confirmed live before being fixed
    permanently in `install.sh`. See `SECURITY_REVIEW.md` for details.
    The server itself is still mid-install (Stage 6/7 never ran); a
    follow-up run is needed to reach a complete, verified install with
    the fixes in place.
  - This is exactly the kind of bug static analysis structurally cannot
    catch — validates the value of this tier even at the cost of the
    manual, relayed-interactivity overhead.
- **Longer-term proposed approach** (still not built): a CI job (e.g.
  GitHub Actions with nested virtualization, or a local Vagrant/qemu
  Debian 13 box) that provisions a fresh disposable instance, runs
  `install.sh` non-interactively (would require adding a non-interactive/
  answer-file mode — not present today, and the `/dev/tty` prompt design
  would need to change too), and asserts on the same postconditions
  Stage 7 already checks, then destroys the instance. This remains the
  right direction for a repeatable, disposable, no-human-relay version of
  this tier — the 2026-07-28 run was a one-off manual pass on real
  (borrowed) infrastructure, not a repeatable CI-shaped test.
- This tier is the most expensive and the least frequently run (e.g. on
  release branches or nightly, not on every commit).

### Manual test checklist (until Tier 3 exists)

For any change to `install.sh`, the following scenarios should be
exercised manually on a disposable Debian 13 VM before merging:

- [ ] Fresh install, no local DNS (Tailscale login is always interactive
      browser login as of 2026-07-27 — see **C2**)
- [ ] Fresh install, local DNS enabled
- [ ] Fresh install, verify wg-easy comes up unconfigured (`/setup`) and
      the final summary instructs manual completion — no automated
      bootstrap exists anymore (see **M6**)
- [ ] Re-run against an already-provisioned host (no drift) — should be a
      near no-op
- [ ] Re-run after simulating WAN/Tailscale address drift — reconcile
      should repair it
- [ ] Re-run after simulating firewall drift (manually removing a rule) —
      reconcile should restore it within one cycle
- [ ] Re-run after simulating a stopped/crash-looped container — restart
      cooldown behavior should be respected
- [ ] Toggling local DNS from disabled to enabled on a re-run, and the
      reverse
- [ ] A forced failure in each stage (1 through 7) to confirm the `EXIT`
      trap's rollback behavior (timers, DNS/Caddy masking) leaves the host
      in a consistent state — note the wg-easy bootstrap-secret-scrubbing
      path this used to also cover was removed along with **M6**

### CI / Automation

Proposed staged rollout; only Tier 1 is implemented so far, as a
standalone script (no CI runner wired up yet):

1. ~~Tier 1 (heredoc extraction + `shellcheck`)~~ — **done (2026-07-28)**,
   see above.
2. Tier 2 (bats-core unit tests) — requires extracting pure-logic
   functions; can proceed incrementally, function by function.
3. Tier 3 (disposable-VM integration test) — requires a non-interactive
   invocation mode for `install.sh` that doesn't exist today, and a CI
   runner with nested virtualization; largest lift, highest confidence.

### Known gaps

- No non-interactive/answer-file mode exists for `install.sh` today,
  which blocks fully automated Tier 3 testing.
- iptables/systemd/Docker-level logic cannot be meaningfully unit-tested
  without either heavy mocking (Tier 2, partial coverage only) or a real
  environment (Tier 3).
- No monitoring/alerting hook exists for reconcile failures beyond
  journald log lines — testing that operators actually notice a
  persistent reconcile failure is out of scope for automated testing and
  would need to be a documented operational procedure instead.
- This document will need further updates as Tiers 2/3 and CI wiring are
  implemented — Tier 1 is real (`scripts/lint-embedded-scripts.sh`), the
  rest still describes intent only.
