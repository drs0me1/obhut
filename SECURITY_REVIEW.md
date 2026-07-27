# Security Review

Static audit of `install.sh` (originally 4552 lines), performed 2026-07-27.
Scope covered: secrets handling, destructive operations, firewall/network
safety, Tailscale exit-node configuration, Docker Compose design, systemd
services/timers, reconcile/self-healing behavior, idempotency,
rollback/cleanup traps, error handling, service coupling, unnecessary
services, installation profiles, modularization, and testing strategy.

Fifteen numbered remediations have since been applied (see **C2**,
**M6**, **M5**, **H1**, **H2**, **H3**, **M4**, **L1**, **L2**, **L4**,
**L5**, **M2**, **L3**, **C1**, and **H4** below and `CHANGELOG.md`; **H1**
was further hardened with a persistent module-load config and a functional
probe; **H2**/**H3**/**C1** were resolved by confirming the existing
behavior was an accepted, intentional trade-off and documenting it, not by
changing it), one partial remediation (**M1** — Tier 1/3 applied, Tier 2
deferred to the live SSH test), plus one unnumbered cleanup: the legacy
`remove_managed_scheduled_reboot()` function (Stage 1) and its Stage 7
re-verification block were deleted entirely (2026-07-28, 61 lines) — dead
weight from an old (r3-and-earlier) automatic-reboot mechanism this tool
no longer installs, kept only as a migration shim. The user confirmed this
deployment target is always a fresh Debian 13 install with no r3-or-earlier
history to migrate away from, so the shim had no remaining purpose.
`install.sh` is now 4275 lines (unchanged by **H4**, which only added a new
standalone `scripts/lint-embedded-scripts.sh`); every `Location:` reference
below for still-open findings has been re-checked and updated to match the
current file after each remediation. Resolved findings keep their original
("historical") line numbers for the record.

Each finding lists its location, a description, its impact, a recommended
fix, and the estimated risk of making that fix.

## Current findings

18 findings total (corrected from an earlier miscount of 19); 15 resolved,
3 currently **open**:

| Severity | Open | Resolved |
|----------|------|----------|
| Critical | 0 | 2 (**C2**, 2026-07-27; **C1**, 2026-07-28) |
| High     | 0 | 4 (**H1**, **H2**, **H3**, 2026-07-27; **H4**, 2026-07-28) |
| Medium   | 3 | 4 (**M6**, **M5**, **M4**, 2026-07-27; **M2**, 2026-07-28) |
| Low      | 0 | 5 (**L1**, **L2**, **L4**, **L5**, 2026-07-27; **L3**, 2026-07-28) |

Note: **H2**, **H3**, and **C1** were resolved by explicit user decision to
*keep* the existing behavior/design as an accepted trade-off plus add
documentation — not by changing `install.sh`'s functional behavior.
**M1** is counted as open above but is partially addressed — see its
entry below for what's done vs. deferred to the live SSH test.

## Critical issues

### C1 — Docker socket mounted into Portainer without restriction — ✅ RESOLVED (2026-07-28, accepted risk)
- **Location:** `install.sh:1746-1755` (`compose.yaml` → `services.portainer`)
- **Description:** `/var/run/docker.sock:/var/run/docker.sock` is mounted
  directly, with no socket-proxy and no read-only/API-scoped restriction.
- **Impact:** Compromise of the Portainer container (weak/default admin
  credentials, a future CVE, or lateral movement from another service) is
  equivalent to root on the host. This is the single highest-value target
  in the stack.
- **Analysis (revised from the original recommendation):** A
  docker-socket-proxy (e.g. `tecnativa/docker-socket-proxy`) was
  reconsidered and found to be a weak fit specifically for Portainer:
  Portainer's actual management features (creating/recreating containers,
  deploying stacks, arbitrary volume mounts) require close to the same
  broad API surface that makes the direct mount risky — a proxy locked
  down enough to meaningfully reduce risk would break Portainer's
  usefulness, and one permissive enough to preserve it wouldn't meaningfully
  reduce risk. (Also noted: a read-only socket mount, `:ro`, is a commonly
  suggested but ineffective mitigation — Unix domain sockets aren't gated
  by the mount's read/write flag; full API read-write access remains
  either way.)
- **Decision:** The user confirmed Portainer is actively used for
  container monitoring and manual intervention, considers it the ideal
  interface for that purpose, and accepts the risk as-is — scoped down by
  network exposure (`127.0.0.1` + tailnet-only, never public) rather than
  by API restriction. Removing Portainer entirely (the one change that
  would fully eliminate this finding) was considered and declined since
  it's in active use; making it an opt-in profile component remains
  possible future work under **M3**, not pursued now.
- **Resolution:** No functional change to `install.sh`. Documented the
  full analysis and the accepted-risk decision in `README.md` (Security
  Notes).
- **Change risk:** None — no code change made.

### C2 — Tailscale auth key is echoed to the terminal — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:584-586` (Stage 0 user input),
  contrast with `install.sh:644-649` (wg-easy password prompt)
- **Description:** `read -rp "TS_AUTHKEY: " TS_AUTHKEY_INPUT </dev/tty`
  did not use the silent `-s` flag, so the auth key was displayed on
  screen while typed.
- **Impact:** Terminal scrollback, session recording, screen sharing, or
  shoulder-surfing could leak a reusable Tailscale auth key, which could
  be used to add an unauthorized device to the tailnet.
- **Resolution:** Rather than just silencing the prompt, the user decided
  the installer should always use Tailscale's interactive browser login
  instead of accepting a pasted auth key at all. All 6 references to
  `TS_AUTHKEY_INPUT` (Stage 0 prompt + summary, Stage 2 connection logic)
  were removed from `install.sh`; the existing "already connected" and
  "interactive browser login" code paths in Stage 2 now cover every case.
  Verified with `bash -n` and `shellcheck` (both clean) after the change.
- **Change risk:** None remaining — change applied and verified.

## High

### H1 — `wg-easy` runs with `SYS_MODULE` capability — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:1835-1841` (`volumes`, `cap_add`)
- **Description:** In addition to `NET_ADMIN` (expected for WireGuard),
  the container had `SYS_MODULE` plus a read-only bind mount of
  `/lib/modules`, allowing kernel module loading from inside the
  container if it was compromised — a known container-escape amplifier,
  and a rare case where a container operation reaches past its own
  isolation into the single Linux kernel shared by the whole host.
- **Impact:** Violated least privilege; the container could load
  arbitrary kernel modules regardless of whether the host actually needed
  it to.
- **Resolution:** Added a standalone, best-effort `modprobe wireguard` on
  the host in Stage 4 (`install.sh`, next to the `/data/wg-easy/config`
  directory creation), mirroring the existing `modprobe tun` pattern used
  for Tailscale in Stage 2 (`install.sh:770-774`) — same style, but
  intentionally independent: it exists solely for wg-easy and does not
  assume anything about how Tailscale itself brings up `tailscale0`
  (evidence in the script — `modprobe tun`, not `modprobe wireguard`, in
  Stage 2 — suggests Tailscale here uses a TUN device + its own userspace
  WireGuard engine, not the in-kernel module, so the two are unrelated).
  Hardened further at the user's request: (1) a persistent
  `/etc/modules-load.d/wg-easy.conf` (`root:root 0644`, content
  `wireguard`) ensures the module auto-loads on every future boot via
  `systemd-modules-load.service`, not just the current session; (2) a
  functional probe (`ip link add wg-easy-probe0 type wireguard` then
  delete) verifies actual WireGuard interface capability rather than
  trusting `modprobe`'s exit code alone — this correctly handles the case
  where WireGuard is compiled directly into the kernel (`=y`, no loadable
  module at all), which would otherwise cause `modprobe` to report a false
  "module not found" warning. With the host guaranteeing the capability
  before the container starts, `SYS_MODULE` and the now-unnecessary
  `/lib/modules` bind mount were both removed from wg-easy's
  `cap_add`/`volumes` in `compose.yaml`, leaving only `NET_ADMIN`. No risk
  to Tailscale or any other WireGuard consumer: Tailscale's own path (TUN
  + userspace engine) is architecturally unrelated to the kernel
  `wireguard` module, and wg-easy is the only kernel-WireGuard consumer on
  this host. Verified with `bash -n` and `shellcheck` (clean).
- **Change risk:** Low remaining in practice — the functional probe makes
  this close to a real guarantee on any kernel that supports WireGuard at
  all (essentially certain on stock Debian 13). Still requires a real test
  run on the target server to confirm wg-easy actually brings up `wg0`
  end-to-end (this assistant has no access to it and cannot verify
  directly; deferred to a live SSH test the user will do later). A
  cleaner, capability-free alternative (running WireGuard fully in
  userspace via `boringtun`/`wireguard-go`, eliminating any kernel-module
  dependency at all) was discussed as a further research item — see
  `docs/design-decisions.md` (DD-10).

### H2 — Reconcile silently reverts manual operator changes — ✅ RESOLVED (2026-07-27, by design)
- **Location:** `install.sh:2057-2090` (`canonical_bundle_ok`),
  `install.sh:2633-2669` (`dns_config_files_ok` / `caddy_config_files_ok`),
  `install.sh:3031-3067` (restore logic), warning text at
  `install.sh:4155-4165` (final install summary)
- **Description:** Firewall, dnsmasq, and Caddy configuration are compared
  against a canonical SHA256 manifest every 5 minutes and restored if they
  drift — including drift caused by a manual operator edit.
- **Decision:** The user confirmed this is **intentional, desired
  behavior** — guaranteeing dnsmasq/Caddy reachability against accidental
  or unauthorized manual drift matters more here than accommodating ad hoc
  hand-edits, consistent with the "minimize manual touch, reduce error
  risk" philosophy behind this stack. No functional change was made.
- **Resolution:** Added an explicit warning to the final install summary
  (`install.sh:4155-4165`) naming exactly which files are affected
  (`state.env` always; dnsmasq/Caddy files and drop-ins if Tailnet DNS is
  enabled) and stating that a permanent change requires editing
  `install.sh` and re-running it. Verified with `bash -n` and `shellcheck`.
- **Change risk:** None — documentation-only, no behavior changed.

### H3 — `PartOf=` coupling causes surprising cascading restarts — ✅ RESOLVED (2026-07-27, by design)
- **Location:** `install.sh:1591-1617` (`docker-tailscale-fw.service`,
  `PartOf` at line 1597), `install.sh:1950-1977` (`master-compose.service`,
  `PartOf` at line 1956), `install.sh:3471-3498` (`caddy.service.d`,
  `PartOf=tailscaled.service` at line 3475), warning text at
  `install.sh:4166-4176` (final install summary)
- **Description:** These units are bound via `PartOf` to `docker.service`
  and/or `tailscaled.service`. A routine `systemctl restart tailscaled`
  (e.g. for troubleshooting) also stops and restarts the entire Compose
  stack, the firewall, and Caddy.
- **Decision:** The user confirmed the coupling should stay — they want
  the system to enforce strict ordering/fate-sharing between the core
  daemons and their dependents, not to make restarts more "convenient" at
  the cost of that guarantee. No functional change was made (matches the
  DD-4 rationale already on record).
- **Resolution:** Added an explicit warning to the final install summary
  (`install.sh:4166-4176`) naming the affected units and stating this is a
  deliberate design choice for ordering/consistency, not an oversight.
  Verified with `bash -n` and `shellcheck`.
- **Change risk:** None — documentation-only, no behavior changed.

### H4 — Embedded heredoc scripts are not covered by static analysis — ✅ RESOLVED (2026-07-28)
- **Location:** `install.sh:767-842` (`tailscale-udp-gro`),
  `install.sh:1062-1588` (`docker-tailscale-fw`, ~520 lines),
  `install.sh:1905-1946` (`master-compose-ipv4`),
  `install.sh:1985-3157` (`master-network-reconcile`, now ~1170 lines
  after **L3**'s simplification),
  `install.sh:3161-3207` (`master-docker-netfilter-recovery`),
  `install.sh:3435-3467` (`caddy-tailnet-env`)
- **Description:** These scripts are written as single-quoted heredocs, so
  `bash -n install.sh` and `shellcheck install.sh` never see their
  contents — only the outer script is checked.
- **Resolution:** Added `scripts/lint-embedded-scripts.sh`: extracts all
  six embedded heredoc scripts (via `sed` line-range matching on each
  script's known start/end markers, e.g. `GRO_SCRIPT`, `FW_SCRIPT`,
  `RECONCILE_SCRIPT`) into temp files and runs `bash -n` + `shellcheck` on
  each independently — never executes `install.sh` or any extracted
  script. `SC2016` is deliberately excluded in the tool's `shellcheck`
  invocation: it fires on every single-quoted `awk` program in these
  scripts (e.g. `'$1 == "-A" {...}'`), which is intentional, correct usage
  (that `$1` is awk's own field syntax, not an un-expanded bash variable),
  not a real defect — every other check still runs at full severity.
- **First real run (what H4's blind spot was actually hiding):**
  `master-docker-netfilter-recovery` was completely clean; the other five
  scripts had only the expected `SC2016` awk-quoting notices (now
  excluded) — no actual bugs surfaced this time, but the ~1900 lines this
  covers had genuinely never been checked before, and future changes to
  any of these six scripts will now be caught by running this tool.
  Verified the tool catches real problems too: injected a synthetic syntax
  error into a scratch copy of `install.sh` (never the tracked file) and
  confirmed the tool correctly reported `bash -n` failure and exited
  non-zero.
- **Not done yet:** wiring this into an actual CI pipeline (e.g. GitHub
  Actions) — not attempted since this repo has no CI configuration and it
  wasn't confirmed the user wants one; the script can be run manually
  (`./scripts/lint-embedded-scripts.sh`) in the meantime, and CI wiring is
  a natural, low-effort follow-up if/when wanted. The longer-term option
  from the original recommendation — moving these scripts into separate
  `lib/*.sh` files instead of heredocs — also remains open (bigger,
  packaging-model change, not attempted).
- **Change risk:** None — new standalone script, `install.sh` untouched.

## Medium

### M1 — No per-container resource limits or hardening — 🟡 PARTIALLY RESOLVED (2026-07-28)
- **Location:** `install.sh:1771-1822` (`compose.yaml` →
  `services.qbittorrent`, `services.unpackerr`)
- **Description:** Neither container defined `mem_limit`/`cpus`,
  `security_opt: no-new-privileges`, `read_only`, or a reduced capability
  set, despite processing untrusted downloaded/archive content.
- **Resolution so far (Tier 1 + Tier 3, applied):**
  - `security_opt: ["no-new-privileges:true"]` added to both
    `qbittorrent` and `unpackerr` — zero-risk, blocks setuid/setgid
    privilege-escalation paths.
  - Resource ceilings added, sized against the user's actual hardware
    (4 CPU / 8 GB RAM, typically 1-2 active torrents): `qbittorrent`
    → `mem_limit: 2g`, `cpus: 2.0`; `unpackerr` → `mem_limit: 512m`,
    `cpus: 1.0`. These are ceilings, not reservations — they only bite
    during a runaway/abnormal condition, not during normal light usage.
  - Verified with `bash -n` and `shellcheck` (clean).
- **Deferred (Tier 2 — needs live verification):** `cap_drop: [ALL]` for
  both containers. `unpackerr` already runs as non-root (`user:
  "1000:1000"`) so this is very likely safe, but `qbittorrent` is a
  linuxserver.io image whose entrypoint runs its own root-level s6-overlay
  init (to fix mount ownership for `PUID`/`PGID`) before dropping
  privileges — it likely needs at least `CHOWN`, `SETUID`, `SETGID`,
  `DAC_OVERRIDE`, `FOWNER` back via `cap_add`, and this assistant cannot
  verify the exact minimal set without running the actual image. Explicitly
  deferred to the user's planned live SSH test at the end of this
  engagement rather than guessing.
- **Not pursued:** `read_only: true` root filesystem — highest
  defense-in-depth value but also highest risk of breaking either image
  without knowing their internal writable-path assumptions (would need
  `tmpfs` mounts for whatever they turn out to be); deferred to the same
  live-test phase rather than applied blind.
- **Change risk:** None remaining for what was applied (Tier 1/3, low-risk
  and already verified); Tier 2 risk assessment above stands until tested.

### M2 — Unconditional `chown -R` on every run — ✅ RESOLVED (2026-07-28)
- **Location (historical):** `install.sh:1773`
- **Description:** `chown -R 1000:1000 "$DOWNLOADS_PATH/media"` walked the
  entire media tree on every re-run with no ownership pre-check.
- **Resolution:** Replaced with `find "$DOWNLOADS_PATH/media" \( ! -uid
  1000 -o ! -gid 1000 \) -exec chown 1000:1000 {} +` — only entries whose
  ownership doesn't already match get a `chown` call (which is the
  expensive, disk-write part); a fully-correct tree becomes a no-op chown
  pass. Verified the predicate logic standalone (own UID/GID → nothing
  selected; a nonexistent UID → every entry, including the root directory,
  correctly selected) before trusting it in `install.sh`. Verified with
  `bash -n` and `shellcheck` (clean).
- **Change risk:** None remaining — applied and verified; behavior is a
  strict improvement (same end-state ownership, less unnecessary I/O).

### M3 — No user-selectable installation profile
- **Location:** `install.sh:523-612` (Stage 0 prompts),
  `install.sh:1777-1930` (compose definition)
- **Description:** The six-service bundle (Portainer, Filebrowser,
  qBittorrent, Unpackerr, wg-easy, SFTPGo) is fixed; there is no way to
  opt out of an individual service despite very different risk profiles.
- **Impact:** A user who only wants VPN or only wants media services must
  still accept exposure they don't need (e.g. Portainer's `docker.sock`
  access).
- **Recommendation:** See `docs/profiles.md` for a proposed profile model.
- **Change risk:** Medium-high — touches compose generation, `state.env`
  schema, and reconcile's `expected_containers` list; requires scoping
  before implementation.

### M4 — `INSECURE: "true"` on wg-easy is undocumented in-line — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:1863`
- **Description:** Disabled the wg-easy admin UI's secure-cookie
  enforcement, which is required only because Caddy reverse-proxies it
  over plain HTTP inside the tailnet, without explaining the dependency at
  the point of use.
- **Resolution:** Added a 4-line inline comment directly above
  `INSECURE: "true"` in `compose.yaml` explaining it's required only
  because of the Tailnet-only + Caddy-loopback architecture. Verified
  with `bash -n` and `shellcheck`.
- **Change risk:** None remaining — comment-only, no behavior changed.

### M5 — Unclear diagnosis if `ip6tables` is absent — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:1546-1592` (`check_ipv6_policy`),
  `install.sh:1594-1596` (`check_policy`)
- **Description:** If `IP6TABLES_BIN` was empty, `check_ipv6_policy`
  returned failure, which failed the whole `check_policy` with a generic
  "firewall policy could not be verified" message rather than a specific
  diagnosis — confusing on the rare host where `ip6tables` is genuinely
  missing (unlikely on Debian 13's `iptables` package, but previously
  unguarded).
- **Resolution:** `check_ipv6_policy` now checks `IP6TABLES_BIN` explicitly
  and prints `"HATA: ip6tables bulunamadı; IPv6 firewall politikası
  doğrulanamıyor."` before returning failure, so this specific cause is no
  longer masked behind the generic policy-drift message. Fail-closed
  behavior is unchanged — this was a diagnostics-only fix. Verified with
  `bash -n` and `shellcheck` (clean).
- **Change risk:** None remaining — change applied and verified; purely
  additive (one new early-return branch with a message), no existing
  behavior altered.

### M6 — No recovery runbook for the wg-easy bootstrap dead-end — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:609-632` (marker checks),
  `install.sh:3571-3578` (marker write)
- **Description:** If the script was killed between creating the wg-easy
  database and writing the bootstrap marker, a re-run intentionally
  refused to proceed (correct fail-safe), but there was no documented
  recovery path for that state.
- **Impact:** An operator hitting this narrow window had no guidance and
  might resort to risky manual file surgery.
- **Resolution:** The entire wg-easy unattended-bootstrap subsystem
  (Stage 0 admin prompts, the DB/marker detection state machine, the
  `WG_INIT_ENV_FILE`/`WG_INIT_OVERRIDE_FILE` generation in Stage 4, the
  bootstrap-apply-verify-scrub-marker sequence in Stage 5, and the
  `scrub_wg_bootstrap_container` EXIT-trap cleanup) was removed at the
  user's request. wg-easy's admin account is now created manually via the
  web UI on first access, the same way Portainer's and SFTPGo's are — the
  script only provisions the container and infrastructure, so the
  dead-end state this finding described can no longer occur. Also
  simplified `WG_ENDPOINT_HOST_FOR_STATE` (`install.sh` Stage 4) to always
  use the current public IPv4, since the marker it previously read no
  longer exists — see `docs/design-decisions.md` for the trade-off this
  introduces (state.env can no longer distinguish a fresh install from a
  public-IP change between two `install.sh` reruns). Verified with
  `bash -n` and `shellcheck` (clean, after also removing two now-dead
  helpers, `wg_ui_configured()` and `WG_UI_CONFIGURED`, that ShellCheck
  flagged as unused).
- **Change risk:** None remaining — change applied and verified. Net
  effect: 248 lines removed from `install.sh` and one full secret-handling
  subsystem eliminated.

### M7 — No automated tests or CI — 🟡 PARTIALLY RESOLVED (2026-07-28)
- **Location:** repository-wide
- **Description:** Correctness is verified only by the script's own Stage
  7 runtime checks, executed against a real host. No unit tests, no CI
  pipeline.
- **Impact:** Regressions can only be caught by running the full,
  destructive installer against disposable infrastructure.
- **Resolution so far (Tier 1 + start of Tier 2):**
  - Tier 1 (static analysis) is done — see **H4**:
    `scripts/lint-embedded-scripts.sh` runs `bash -n`/`shellcheck` on all
    six embedded heredoc scripts.
  - Tier 2 (unit tests) started: new `test/reconcile_functions.bats` uses
    `bats-core` to test `state_value` and `owned_file_ok`
    (`master-network-reconcile` heredoc) in isolation. Only these two
    function *bodies* are extracted (same `sed` marker technique as
    `scripts/lint-embedded-scripts.sh`, plus an `awk` pass to isolate one
    function at a time) and sourced into the test shell — the full
    reconcile script is never sourced/executed, since it runs real
    `flock`/`systemctl` calls at its top level. 7 test cases, all passing
    (2 self-skip on this macOS dev workstation, whose BSD `stat` doesn't
    support the GNU `stat -c` syntax `owned_file_ok` depends on — the
    Debian production target has GNU coreutils, so this is a local test
    environment gap, not a functional bug). `install.sh` untouched.
  - Also added `test/firewall_functions.bats`: 20 more test cases across
    six pure-logic functions from `docker-tailscale-fw`
    (`route_value`, `chain_rules_exact`, `jump_is_first_and_single`,
    `forward_prefix_is_exact`, `docker_forward_has_no_terminal_drop`,
    `no_stale_staging_chains`), all passing. The five predicate functions
    only ever call their `bin` argument with `-S`/`-C` (read, never
    mutate), so a fake shell-function stand-in supplies canned rule
    listings/exit codes instead of real `iptables`/`ip6tables` — no root,
    no real firewall touched. `route_value` (the parsing helper behind
    `WAN4_IF`/`PUBLIC_IPV4`/`WAN6_IF` detection) is tested the same way
    against a fake `ip`. Note: `detect_ipv4_route` itself lives in
    `install.sh`'s outer script (not a heredoc) and calls `exit` directly
    on failure — already covered by `bash -n`/`shellcheck` directly, and
    not a fit for this extraction technique, which is why `route_value`
    (its reusable parsing logic) was tested instead.
- **Remaining:** `check_ipv4_policy`/`check_ipv6_policy` (composite
  functions coupled to real global state, more integration-shaped — left
  for Tier 3 instead); pure-logic candidates in the other four embedded
  scripts haven't been surveyed yet; Tier 3 (disposable-VM integration
  testing); CI pipeline wiring (no CI exists in this repo). See
  `docs/testing.md` for the full staged plan.
- **Change risk:** None so far — new standalone test file only,
  `install.sh` untouched. Extracting logic for further unit tests remains
  medium risk in general (see H4) but this pattern (extract function body
  only, never source the whole heredoc) keeps that risk low in practice.

## Low

### L1 — `apt-get full-upgrade -y` without explicit conffile policy — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:755`
- **Resolution:** Added `-o Dpkg::Options::="--force-confdef" -o
  Dpkg::Options::="--force-confold"` to the `full-upgrade` call, so an
  unattended conffile prompt can never stall the (already noninteractive)
  install; existing unmanaged conffiles are preserved, upstream's default
  is applied only where there's no local change. Verified with `bash -n`
  and `shellcheck`.
- **Change risk:** None remaining — applied and verified.

### L2 — Tailscale login doesn't register the device as ephemeral — ✅ RESOLVED (2026-07-27, documentation)
- **Location (historical):** `install.sh:959` (interactive `tailscale up`
  login), `install.sh:978-982` (`tailscale set --advertise-exit-node ...`)
- **Description:** Since **C2** removed the auth-key path entirely
  (2026-07-27), every fresh install now registers via `tailscale up`'s
  plain interactive browser login, which is a normal (non-ephemeral)
  device by default.
- **Resolution:** Documented in `README.md` (Security Notes) that
  rebuilding this server leaves an orphaned device entry in the tailnet
  admin console, to be removed manually; noted this isn't something
  `install.sh` can control from this call (a property of how the device
  authenticates, not a flag on the interactive login flow).
- **Change risk:** None — documentation-only.

### L3 — `tailscale-udp-gro.service` is disproportionately complex for its benefit — ✅ RESOLVED (2026-07-28)
- **Location (historical):** `install.sh:767-866` (setup, kept),
  `install.sh:2845-2899, 2912, 2953, 3150-3161` (reconcile integration,
  removed)
- **Description:** UDP GRO forwarding is a pure throughput optimization
  for Tailscale's exit-node traffic (never affects connectivity) but had
  ~54 lines of dedicated continuous-reconciliation machinery spread across
  detection, a health-rollup function, `--check` output, a warning
  message, and a repair action — on top of ~107 lines for the one-time
  Stage 2 setup.
- **Resolution:** Removed the reconcile-side continuous monitoring
  entirely: the `GRO_INACTIVE`/`GRO_DRIFTED`/`GRO_LOAD_STATE` detection
  block, the now-redundant `all_managed_state_healthy()` wrapper (its only
  caller now calls `all_critical_state_healthy` directly — GRO was
  already excluded from the *critical* health rollup, so this changes
  nothing about pass/fail semantics), the `--check` mode's `gro_unit`/
  `gro_runtime` status fields, the warning echo, and the repair
  (start/restart) action. Also removed two variables that became dead as
  a result: `ETHTOOL_BIN` and `CURRENT_WAN6_IF` inside the reconcile
  heredoc (only ever used by the GRO check; `shellcheck` cannot see this
  on its own since it's heredoc content — see **H4** — so this was
  checked manually). Stage 2's one-time setup (helper script + oneshot
  systemd unit + first-boot enable/start) is unchanged and still applies
  the setting at every boot, since ethtool NIC flags don't persist across
  reboots on their own. Verified with `bash -n` and `shellcheck` (clean).
  Net: 57 lines removed from `install.sh`.
- **Change risk:** Low — if GRO settings are reset by something other
  than a reboot (rare: NIC driver hot-reload, some virtualization
  live-migration events), the script no longer notices/fixes this within
  5 minutes; it's re-applied on the next reboot or `install.sh` re-run
  instead. Since GRO is throughput-only and never breaks connectivity,
  this trade-off was accepted by the user.

### L4 — Host and container DNS resolution paths are inconsistent — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:1014-1039`
- **Resolution:** Added an explicit "host and containers deliberately use
  two different DNS resolution paths" sentence to the existing comment
  block, making the intentional split explicit for future maintainers
  scanning quickly. Verified with `bash -n` and `shellcheck`.
- **Change risk:** None remaining — comment-only, no behavior changed.

### L5 — Portainer's (and now wg-easy's) first-run admin setup is not verified — ✅ RESOLVED (2026-07-27)
- **Location (historical):** `install.sh:1775-1784` (Portainer service
  definition, pre-edit numbering)
- **Description:** Since **M6** removed wg-easy's bootstrap verification
  entirely (2026-07-27), wg-easy joined Portainer and SFTPGo as a third
  service whose first-run admin setup is manual and unverified by the
  script.
- **Resolution:** Added a dedicated warning block to the final install
  summary (`install.sh`, in the "Public IPv4 portları" section) naming
  Portainer, wg-easy, and SFTPGo, explaining that anyone who reaches the
  tailnet before the operator could otherwise complete a service's setup
  screen first, and listing each service's URL (including the Tailnet
  hostname if local DNS is enabled). Verified with `bash -n` and
  `shellcheck`, including a standalone render test of the conditional
  URL text for both the local-DNS-enabled and local-DNS-disabled cases.
- **Change risk:** None remaining — documentation-only, no behavior
  changed.

## Recommendations

Suggested order of remediation (also tracked in `TODO.md`):

1. ~~**C2** — silence the `TS_AUTHKEY` prompt~~ — **done (2026-07-27)**:
   the auth-key input was removed entirely rather than just silenced; the
   installer now always uses Tailscale's interactive browser login.
2. ~~**H4** — add a CI step that lints the embedded heredoc scripts~~ —
   **done (2026-07-28)**: `scripts/lint-embedded-scripts.sh` extracts and
   `bash -n`/`shellcheck`s all six; first real run found no actual bugs
   (only expected, excluded `SC2016` awk-quoting notices), but closes the
   blind spot going forward. Actual CI wiring not attempted (no CI
   configured in this repo yet).
3. ~~**C1** — scope or gate Portainer's `docker.sock` access~~ — **done
   (2026-07-28, accepted risk)**: user confirmed active use of Portainer
   for container monitoring/intervention and accepted the risk, scoped by
   network exposure rather than API restriction; a socket-proxy was
   reconsidered and found to be a weak fit for Portainer specifically.
4. ~~**H1** — verify and, if possible, drop `SYS_MODULE` from wg-easy~~ —
   **done (2026-07-27)**: host-side `modprobe wireguard` added (with boot
   persistence and a functional probe), `SYS_MODULE` and the
   `/lib/modules` mount removed from wg-easy; pending real-server
   verification.
5. ~~**H2 / H3** — document reconcile's config-revert behavior and the
   `PartOf` coupling~~ — **done (2026-07-27)**: user confirmed both
   behaviors are intentional (guarantee dnsmasq/Caddy reachability;
   enforce strict daemon ordering); added explicit warnings to the final
   install summary rather than changing either behavior.
6. 🟡 **M1** — add baseline container hardening for untrusted-content
   services — **partially done (2026-07-28)**: `no-new-privileges` +
   `mem_limit`/`cpus` applied to `qbittorrent`/`unpackerr`; `cap_drop:
   [ALL]` deferred to the live SSH test (needs to confirm qbittorrent's
   linuxserver.io entrypoint still starts with capabilities dropped).
7. ~~**M2** — make the media tree `chown` idempotency-aware~~ — **done
   (2026-07-28)**: replaced with a `find`-scoped `chown` that only touches
   entries whose ownership doesn't already match.
8. ~~**M6** — document the wg-easy bootstrap dead-end recovery path~~ —
   **done (2026-07-27)**: the entire unattended-bootstrap subsystem that
   could reach that dead-end was removed; wg-easy admin setup is now
   fully manual.
9. **M3** — scope an installation-profile design (see `docs/profiles.md`)
   before implementing.
10. **M7** — stand up CI and a testing strategy (see `docs/testing.md`).
11. ~~**M5** — add a diagnostic for a missing `ip6tables` binary~~ —
    **done (2026-07-27)**: explicit error message added to
    `check_ipv6_policy`.
12. ~~**M4** — explain `INSECURE: "true"`~~ — **done (2026-07-27)**:
    inline comment added.
13. ~~**L1** — dpkg conffile policy flags~~ — **done (2026-07-27)**.
14. ~~**L2** — document non-ephemeral Tailscale device registration~~ —
    **done (2026-07-27)**: added to `README.md`.
15. ~~**L4** — document host-vs-container DNS split~~ — **done
    (2026-07-27)**: comment expanded.
16. ~~**L5** — remind operators to complete first-run admin setup~~ —
    **done (2026-07-27)**: added to the final install summary.
17. ~~**L3** — simplify `tailscale-udp-gro.service`~~ — **done
    (2026-07-28)**: removed the reconcile-side continuous-monitoring
    machinery (~54 lines); the one-time Stage 2 setup (needed for
    per-boot persistence) is unchanged.
18. ~~Legacy reboot-timer cleanup~~ (unnumbered, not from the original
    audit) — **done (2026-07-28)**: `remove_managed_scheduled_reboot()`
    and its Stage 7 re-verification deleted entirely; the fresh-install
    deployment target never has these r3-era units to migrate away from.

Fifteen numbered remediations applied so far (**C2**, **M6**, **M5**,
**H1**, **H2**, **H3**, **M4**, **L1**, **L2**, **L4**, **L5**, **M2**,
**L3**, **C1**, **H4**) plus one partial (**M1**) and one unnumbered
cleanup (legacy reboot-timer removal); **M1** (partial) and **M3**/**M7**
remain open as of this review.

## Review History

| Date | Reviewer | Scope | Result |
|------|----------|-------|--------|
| 2026-07-27 | Claude Code (static audit) | Full `install.sh` (4552 lines) | 18 findings (2 Critical, 4 High, 7 Medium, 5 Low), no changes applied |
| 2026-07-27 | Claude Code (remediation) | Stage 0 + Stage 2 (`TS_AUTHKEY` flow) | **C2** resolved: auth-key input removed entirely; `bash -n` + `shellcheck` clean |
| 2026-07-27 | Claude Code (remediation) | Stages 0/4/5/7 + EXIT trap (wg-easy unattended bootstrap) | **M6** resolved: entire bootstrap subsystem removed (248 lines); wg-easy admin setup now fully manual; `bash -n` + `shellcheck` clean |
| 2026-07-27 | Claude Code (remediation) | `docker-tailscale-fw` → `check_ipv6_policy` | **M5** resolved: explicit missing-`ip6tables` diagnostic added; `bash -n` + `shellcheck` clean |
| 2026-07-27 | Claude Code (remediation) | Stage 4 (host `modprobe wireguard`) + `compose.yaml` → `services.wg-easy` | **H1** resolved: `SYS_MODULE`/`/lib/modules` removed from wg-easy, replaced by an independent host-level module load; `bash -n` + `shellcheck` clean; needs real-server functional verification |
| 2026-07-27 | Claude Code (remediation) | Stage 4 (`/etc/modules-load.d/wg-easy.conf` + functional probe) | **H1** hardened further: module load made persistent across reboots via `systemd-modules-load.service`, and a real `ip link add ... type wireguard` probe replaces reliance on `modprobe`'s exit code alone; `bash -n` + `shellcheck` clean |
| 2026-07-27 | Claude Code (remediation) | Final install summary | **H2**/**H3** resolved by user decision to keep existing behavior and document it: explicit warnings added naming the reconcile-managed files and the `PartOf`-coupled units; `bash -n` + `shellcheck` clean |
| 2026-07-27 | Claude Code (remediation) | Stage 1 (`apt-get full-upgrade`), Stage 3 (Docker DNS comment), `compose.yaml` (`INSECURE` comment), final install summary (admin setup reminder), `README.md` (ephemeral device note) | **L1**, **L4**, **M4**, **L5**, **L2** resolved — all documentation/comment-only, no functional change; `bash -n` + `shellcheck` clean; conditional summary text render-tested standalone |
| 2026-07-28 | Claude Code (remediation) | Stage 4 (media tree `chown`) | **M2** resolved: `chown -R` replaced with a `find`-scoped `chown` that only touches ownership-mismatched entries; predicate logic verified standalone before use; `bash -n` + `shellcheck` clean |
| 2026-07-28 | Claude Code (remediation) | Stage 1 (`remove_managed_scheduled_reboot`) + Stage 7 re-verification | Legacy reboot-timer cleanup removed entirely (61 lines, unnumbered): confirmed with the user this deployment target is always a fresh install with no r3-era units to migrate away from; `bash -n` + `shellcheck` clean |
| 2026-07-28 | Claude Code (remediation) | `master-network-reconcile` heredoc (GRO detection/health/repair) | **L3** resolved: removed ~54 lines of continuous UDP GRO reconciliation (detection, `all_managed_state_healthy()`, `--check` output, warning, repair) plus two now-dead variables (`ETHTOOL_BIN`, `CURRENT_WAN6_IF`) caught by manual review since `shellcheck` can't see inside this heredoc; Stage 2's one-time setup unchanged; `bash -n` + `shellcheck` clean; 57 lines removed net |
| 2026-07-28 | Claude Code (remediation) | `compose.yaml` → `services.qbittorrent`, `services.unpackerr` | **M1** partially resolved: `no-new-privileges` and hardware-sized `mem_limit`/`cpus` (2g/2.0 and 512m/1.0, sized against the user's 4 CPU/8 GB host) added to both; `cap_drop: [ALL]` deliberately deferred to the live SSH test (qbittorrent's linuxserver.io entrypoint likely needs some capabilities back); `bash -n` + `shellcheck` clean |
| 2026-07-28 | Claude Code (analysis) | `compose.yaml` → `services.portainer`, `README.md` | **C1** resolved as accepted risk: reconsidered docker-socket-proxy and found it a weak fit for Portainer specifically (its management features need close to the same broad API access); user confirmed active use and accepted the risk, scoped by network exposure rather than API restriction; no `install.sh` functional change, documented in `README.md` |
| 2026-07-28 | Claude Code (remediation) | New: `scripts/lint-embedded-scripts.sh` | **H4** resolved: extracts and lints all 6 embedded heredoc scripts independently (`bash -n` + `shellcheck`, `SC2016` excluded as a documented false-positive class); first real run found `master-docker-netfilter-recovery` clean and only expected `SC2016` notices elsewhere; verified the tool detects real failures too via a synthetic syntax error in a scratch copy; `install.sh` untouched |
