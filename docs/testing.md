# Testing Strategy

## Planned testing strategy

> **Status (2026-07-28): Tier 1 implemented; Tier 2 partial (57 unit
> tests); Tier 3 had five real, manual install runs. Four were against a
> freshly reimaged host: three of those found and fixed real bugs
> (**H1** regression, **H5**, **H6**) and the fourth added **M1**'s
> hardening and also succeeded. The fifth was the first re-run against an
> existing install, and found that the deployed `compose.yaml` had been
> lagging the repository by several fixes. Plus a full round of
> post-install operational testing (reboot, deliberate drift injection,
> resource-limit enforcement, real WireGuard/Tailscale-exit-node traffic,
> CPU stress) — all passed; CI wiring still not attempted.** There is
> still no automated test suite or CI pipeline for this repository
> (finding **M7** in `SECURITY_REVIEW.md`). This document proposes a
> staged strategy to eventually make Tier 3 repeatable via CI, without
> requiring a human to relay every prompt by hand each time.

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
- **CI: parked, not pending (2026-07-28).** The user decided this
  repository stays local, with no git remote, so there is nowhere for a
  runner to build from. Run the script manually instead, as a
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
- **Also implemented:** `test/canonical_bundle.bats` covers
  `canonical_bundle_ok()` — reconcile's first gate, and the one function
  whose failure silences the entire self-healing loop. 8 cases, none of
  which skip on this workstation: hash verification and ownership
  checking are stubbed (out of scope, and both would drag in GNU
  coreutils), leaving the manifest entry-list logic as the sole subject.
  The expected file lists are extracted from `install.sh`'s own Stage 6
  source rather than restated, so the test compares the two sides of a
  ~2000-line-apart coupling against each other; a scratch-copy mutation
  (dropping `compose.yaml` from Stage 6's list) was used to confirm the
  test actually fails when they diverge. Added because **M8** and **M10**
  both edited the local-DNS-disabled branch, which no live install has
  ever executed.
- **Also implemented:** `test/policy_functions.bats` covers
  `check_ipv4_policy()` and `check_ipv6_policy()` — the composite
  verifiers that hold the entire expected firewall rule set and produce
  the verdict `docker-tailscale-fw --check` returns. 17 cases, no skips.
  - **This supersedes an earlier judgement in this document**, which said
    these two were "more integration-shaped" and "a natural Tier 3 check
    instead". That was too pessimistic: like the five predicates above
    they only read state (`-S` to list a chain, `-C` to probe one exact
    rule), and everything else they touch (`TS_GUARD_CHAIN`,
    `POLICY_CHAIN`, `WAN4_IF`, `WAN6_IF`, `PUBLIC_IPV4`,
    `TAILSCALE_IPV4`) is a plain global a test can assign. A fake that
    dispatches on the `-t` table and the `-S` chain is enough.
  - Covers the healthy policy plus eleven distinct failure shapes:
    missing terminal WAN DROP, missing Tailnet→Docker DROP, mangle jump
    not first, duplicated `DOCKER-USER` jump, an extra rule appended to
    `DOCKER-USER`, a resurrected legacy wide RETURN rule, a leftover
    staging chain in either table, a terminal DROP inside
    `DOCKER-FORWARD`, a wrong `FORWARD` prefix order, and a WebDAV allow
    still bound to a stale Tailscale address. IPv6 adds **M5**'s
    missing-`ip6tables` diagnostic and the deliberately reduced rule set
    for a host with no IPv6 WAN.
  - **Documented limitation:** these prove the verifier's decisions, not
    that `apply_ipv4`/`apply_tailnet_guard` produce what it expects. The
    healthy fixture restates the expected rules, so changing the policy
    makes the healthy case fail — a signal to re-confirm the fixture,
    not a proof of apply/check agreement. Driving the apply path through
    a recording fake founders on its staging-chain activation loops;
    that coupling stays Tier 3's job, and the live install does exercise
    it end to end.
- **Remaining in Tier 2:** nothing specific identified. The surveyed
  gaps are closed; further additions would be opportunistic.
- Longer-term, a small sourceable library file (extracted once, not
  per-test) would remove the need to re-extract function bodies via
  `sed`/`awk` in every test file — a meaningful, low-risk first step
  toward the modularization discussed in `docs/design-decisions.md`
  (DD-9), without requiring the full heredoc-to-file migration up front.

### Tier 3 — Integration testing (disposable VM) — ✅ FIRST FULL SUCCESS (2026-07-28)

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
- **Second real attempt (2026-07-28, same day):** the user reimaged the
  same server clean again specifically to re-test with the H1/H5 fixes
  in place, same tmux-relay methodology. Progress: Stages 0-6 all
  succeeded this time — including wg-easy passing its healthcheck and
  the full DNS/Caddy stage, neither reached on the first attempt — then
  it failed at Stage 7's own `master-network-reconcile --check`
  postcondition call. Found and fixed a third bug, **H6**: the same
  "wg-easy setup pending" condition **H5** already accounts for was also
  independently tripping Stage 7's final health gate, via
  `check_compose_runtime()` counting it as `compose_runtime` drift. An
  attempt to verify the fix by patching the already-deployed reconcile
  script directly on the server (skipping a third reimage) was blocked
  by the auto-mode classifier as an unreviewed live edit — a reasonable
  guardrail; fixed in tracked `install.sh` instead.
- **Third real attempt (2026-07-28, same day) — first full success:** the
  server was reimaged clean a third time with all three fixes (H1
  regression, H5, H6) in place. All 7 stages completed successfully,
  ending in "AŞAMA 7/7 TAMAMLANDI." Confirmed live afterward: all 6
  containers up (`wg-easy`/`filebrowser` healthy), all core systemd units
  active, zero failed units, and `master-network-reconcile --check` now
  exits `0` (still reports wg-easy's pending manual setup informationally,
  as intended, but no longer blocks on it). This is the first time this
  repo's `install.sh` has completed a real, end-to-end install
  successfully — three attempts, three real bugs found and fixed, each
  attempt progressing one stage further than the last.
- **Fourth real attempt (2026-07-28, same day) — M1 hardening included:**
  after **M1**'s deferred `cap_drop`/`cap_add`/`read_only` config
  (determined via throwaway `docker run` tests, see **M1**'s
  `SECURITY_REVIEW.md` entry) was added to `install.sh`, the server was
  reimaged clean a fourth time to verify the full install still succeeds
  with all four fixes in place (H1 regression, H5, H6, M1). All 7 stages
  completed successfully again — the container-hardening changes did not
  regress Stage 5's health-wait gate. This is the run all the operational
  testing below was performed against.
- **Post-install operational testing (2026-07-28, same server/session):**
  once installed, the user configured a real admin account on every
  service that needs one (wg-easy, Portainer, SFTPGo, qBittorrent) and
  added a real WireGuard client profile + enabled Tailscale exit-node
  routing from their own Mac, explicitly asking for the install to be
  exercised under realistic operational conditions, not just a clean
  install/idle state. Findings:
  - **SFTPGo/WebDAV:** investigated a perceived connection delay for a
    real WebDAV client (Infuse app on iOS, user "infuse"). Server-side
    logs showed no technical delay at all — the first login succeeded
    immediately with 0-7ms request times and no retries; the perceived
    delay was almost certainly client-side (Tailscale peer connection
    establishment and/or the time spent creating the user in SFTPGo's
    admin UI), not a server or `install.sh` issue.
  - **Reconcile coverage check:** confirmed all 6 services already have
    a health check in `check_compose_runtime()` (`port_binding_exists`/
    `http_endpoint_responds` for Portainer included) — no monitoring gap
    found, nothing needed adding.
  - **WireGuard tunnel, real client:** a real macOS WireGuard client
    connected; confirmed via `wg show` (successful handshake, real
    transfer bytes) and `docker exec wg-easy ping` to the peer's tunnel
    IP from inside the container's network namespace (the host itself
    has no route to `10.8.0.0/24` — pinging from the host directly gives
    a misleading 100% loss): 0% packet loss, ~58-107ms RTT.
  - **Tailscale exit-node, real client:** confirmed genuinely active (not
    just configured) via `tailscale status` showing the peer `active;
    direct` with real tx/rx bytes, and via the `MASTER-TS-FORWARD` mangle
    chain's packet counters actually incrementing on the
    `tailscale0 -> eth0` MARK/ACCEPT rules.
  - **Reboot test:** rebooted the live host. Confirmed **H1**'s fix is
    genuinely persistent, not incidental to the install session:
    `wireguard`/`ip6_tables`/`ip6table_nat` were all auto-loaded on boot
    via `/etc/modules-load.d/wg-easy.conf` alone. All 6 containers were
    back up (2 already `healthy`) within 22 seconds, all core systemd
    units active, zero failed units, `master-network-reconcile --check`
    exit `0`, and the wg-easy peer configs/keys persisted correctly
    (`/data/wg-easy/config` volume).
  - **Deliberate drift injection (reconcile self-healing, not just
    passive reporting):** in a single test, stopped `qbittorrent`, set
    `net.ipv4.ip_forward=0`, and deleted the
    `MASTER-DOCKER -i tailscale0 -o eth0 -j ACCEPT` firewall rule. The
    next scheduled reconcile cycle (within 5 minutes) detected all three
    drifts and repaired all three: `qbittorrent` restarted, forwarding
    restored to `1`, the firewall rule reinserted — confirmed via
    `--check` returning to a clean, all-zero, exit-`0` state, and via a
    second clean cycle 5 minutes later with no drift messages at all.
  - **Resource-limit (M1) enforcement test:** an isolated throwaway
    container with a 256MB memory limit, pushed past that limit, was
    cleanly `SIGKILL`ed (exit 137) by the cgroup memory controller
    without affecting the host or any real running container — confirms
    `mem_limit` actually bites, not just being present in `compose.yaml`.
  - **`unpackerr` real-workload test (M1):** with its new `cap_drop:
    [ALL]` + `read_only: true`, a real test archive (zip) placed in the
    watched downloads folder was detected, extracted, and cleaned up
    successfully within its normal ~10s poll interval — confirms the new
    hardening survives a real extraction workload, not just idle startup
    (which was all that had been tested when **M1** was first applied).
  - **CPU stress test:** loaded all 4 cores to ~100% for about a minute.
    All 5 web-facing services still responded in single-digit
    milliseconds throughout. A `master-network-reconcile.service` run
    happened to fall inside the stress window and still completed
    successfully in 4 seconds. Zero failed units throughout.
  - All of the above ran against the same already-installed host with
    explicit, broad testing latitude from the user ("test the server
    without worrying about data loss, we're using it purely for
    testing") — a meaningfully different authorization than the
    turn-by-turn approval used for the install runs themselves, granted
    specifically because the host had no production data on it.
- **Fifth real run (2026-07-28) — first re-run against an existing
  install, not a reimage:** run to validate the post-R1.0 batch (**M8**,
  **M9**, **L6**, **M10** plus the version-string correction) on a host
  that already had a full stack, real admin accounts, two WireGuard peers
  and live torrents. Same tmux-relay methodology; the user pre-approved
  the four Stage 0 answers and supplied them, and this assistant never
  chose a value. Partway through, the classifier blocked a
  `tmux send-keys` call; rather than working around it, the remaining two
  prompts were handed back to the user with the exact commands, and they
  completed the run.
  - **Result:** all 7 stages completed. Verified read-only afterwards:
    the canonical directory now contains `compose.yaml` (`0:0:600`,
    byte-identical to the live file), the manifest lists all eight
    entries in the expected order, `master-network-reconcile --check`
    reports every field `0` — including the new `compose_file=0` — and
    exits `0`, the install banner shows `2026.07.28-v1.1` (the release
    string was renamed to `-v1b` immediately afterwards, so the next run
    will show that instead), `state.env`
    finally carries `DOWNLOADS_PATH`, and `qbittorrent` runs with
    `Memory=0 NanoCpus=0`.
  - **The finding this run produced:** the deployed `compose.yaml` was
    far older than assumed — it predated both **H7** and **M1**. So
    `TRUSTED_ORIGINS=portainer.ayc` and the `cap_drop`/`read_only`
    hardening reached the server for the first time here, meaning
    Portainer had still been rejecting writes via `portainer.ayc` in
    real use despite **H7** being "fixed" in the repository days
    earlier. A repository fix is not a deployed fix — this is precisely
    the gap **M10** now reports on, found by the very run that installed
    **M10**.
  - **Cost:** all six containers were recreated (not just `qbittorrent`,
    as predicted from the compose diff alone). Docker was already at the
    candidate version so there was no daemon restart; dnsmasq/Caddy went
    through their mask/reinstall/unmask cycle. The two WireGuard peers'
    `latest-handshakes` reset to `0` — configuration and keys survived on
    the volume, and clients re-handshake on their next traffic.
- **Longer-term proposed approach** (still not built): a CI job (e.g.
  GitHub Actions with nested virtualization, or a local Vagrant/qemu
  Debian 13 box) that provisions a fresh disposable instance, runs
  `install.sh` non-interactively (would require adding a non-interactive/
  answer-file mode — not present today, and the `/dev/tty` prompt design
  would need to change too), and asserts on the same postconditions
  Stage 7 already checks, then destroys the instance. This remains the
  right direction for a repeatable, disposable, no-human-relay version of
  this tier — the 2026-07-28 runs were manual passes on real (borrowed)
  infrastructure, not a repeatable CI-shaped test.
- This tier is the most expensive and the least frequently run (e.g. on
  release branches or nightly, not on every commit).

### Manual test checklist (until Tier 3 exists)

For any change to `install.sh`, the following scenarios should be
exercised manually on a disposable Debian 13 VM before merging. Items
checked below were exercised for real on 2026-07-28 (see the Tier 3
narrative above); unchecked items still describe intent only.

- [x] Fresh install, local DNS enabled (exercised on all four 2026-07-28
      attempts; the no-local-DNS path itself remains unexercised — see
      below)
- [ ] Fresh install, no local DNS — **not a pending gap; effectively
      unused by design.** The user confirmed (2026-07-28) that local DNS
      is always installed on this deployment; the Stage 0 question exists
      only because the *domain name* is decided per install, not because
      the feature is optional in practice. Every live run to date has
      answered `E`. Leave this unchecked as a record of what has not been
      exercised, but do not treat closing it as valuable work on its own
      — the code path's real risk is covered by the unit test tracked in
      `TODO.md` instead, which is cheaper and does not need a host.
- [x] Fresh install, verify wg-easy comes up unconfigured (`/setup`) and
      the final summary instructs manual completion — confirmed via
      `check_compose_runtime()`'s "wg-easy ilk kurulumu tamamlanmamış"
      diagnostic appearing (and correctly not blocking Stage 7, per
      **H6**) on every fresh install before manual setup was done
- [x] Re-run after simulating firewall drift (manually removing a rule) —
      confirmed reconcile restores it within one cycle
- [x] Re-run after simulating a stopped container — confirmed reconcile
      restarts it within one cycle; the 15-minute restart-cooldown
      behavior itself (repeated flapping) was not separately stress-tested
- [x] Reboot the fully-installed host — confirmed all services and
      **H1**'s module-loading fix survive a real reboot, not just the
      install session (this scenario wasn't in the original checklist;
      added after 2026-07-28's testing showed it was a meaningfully
      different — and important — case from "re-run install.sh")
- [x] Re-run against an already-provisioned host — **exercised
      2026-07-28** (the fifth live run, and the first that was not
      against a freshly reimaged host). It was **not** a no-op, and the
      reason is the finding: the deployed `compose.yaml` was much older
      than assumed, predating **H7** and **M1**, so all six containers
      were recreated rather than just `qbittorrent`. Everything else
      behaved as an idempotent re-run should — Docker was already at the
      candidate version so no daemon restart occurred, `daemon.json` was
      unchanged, admin accounts / wg-easy peer configs / qBittorrent
      state all survived on their volumes, and Stage 7 passed clean with
      zero failed units. See the Tier 3 narrative above.
- [ ] Re-run after simulating WAN/Tailscale address drift — reconcile
      should repair it
- [ ] Toggling local DNS from disabled to enabled on a re-run, and the
      reverse
- [ ] A forced failure in each stage (1 through 7) to confirm the `EXIT`
      trap's rollback behavior (timers, DNS/Caddy masking) leaves the host
      in a consistent state — note the wg-easy bootstrap-secret-scrubbing
      path this used to also cover was removed along with **M6**

### CI / Automation

**Status (2026-07-28): parked.** The user decided this repository stays
local, with no git remote, so no CI runner has anywhere to build from.
This is a deliberate workflow choice rather than an unfinished task —
future reviews should not keep proposing it. A remote is the only thing
that would change it.

What the staged rollout looked like, for the record:

1. ~~Tier 1 (heredoc extraction + `shellcheck`)~~ — **done (2026-07-28)**
   as a standalone script, `scripts/lint-embedded-scripts.sh`.
2. ~~Tier 2 (bats-core unit tests)~~ — **done (2026-07-28)**: 57 cases
   across five files, with no identified gaps left.
3. Tier 3 (disposable-VM integration test) — would additionally require a
   non-interactive invocation mode for `install.sh`, which does not exist
   and was judged not worth changing the deliberate `/dev/tty` prompt
   design for, plus a runner with nested virtualization. The manual,
   tmux-relayed process documented above remains the way this tier runs.

In the meantime the full local check sequence is four commands:
`bash -n install.sh`, `shellcheck install.sh`,
`./scripts/lint-embedded-scripts.sh` and `bats test/`.

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
