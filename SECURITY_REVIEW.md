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
`install.sh` is now 4587 lines (post-`v1rc`; 4502 at the tag itself, unchanged by **H4**, which only added a new
standalone `scripts/lint-embedded-scripts.sh`; grew net from **H5**'s and
**H1**'s regression fix plus **H6**'s one-line removal, all applied
2026-07-28 across two live Tier 3 test attempts — see below); every
`Location:` reference below for still-open findings has been re-checked
and updated to match the current file after each remediation. Resolved
findings keep their original ("historical") line numbers for the record.

Each finding lists its location, a description, its impact, a recommended
fix, and the estimated risk of making that fix.

## Current findings

18 findings total from the original 2026-07-27 static audit (corrected
from an earlier miscount of 19); 16 resolved, 2 currently **open**. Three
additional findings, **H5**, **H6**, and **H7**, were discovered on
2026-07-28 — the first two via live Tier 3 install tests, **H7** via real
post-R1.0 usage — (not part of the original static audit — static review
alone could not have caught any of them, see their entries below) and all
three resolved the same day. A further five, **M8**, **M9**, **M10**,
**L6** and **L7**, came out of a whole-file review of the post-R1.0
script on 2026-07-28; **M8**, **M9** and **L6** were resolved the same
day, **M10** was resolved with a deliberately narrowed scope, and **L7** was
first deferred and then closed as won't-do (see their entries). **M3**
was likewise closed as won't-do on 2026-07-28. A twenty-seventh finding,
**M11**, was discovered on 2026-07-29 while reordering Stage 1/2 for the
`v1.1-1` login-placement experiment; the reorder fixed it as a side
effect, the revert of that experiment reintroduced it, and it was then
fixed on its own in `V1-1`. **M7** remains the only open finding in the
project.

| Severity | Open | Resolved |
|----------|------|----------|
| Critical | 0 | 2 (**C2**, 2026-07-27; **C1**, 2026-07-28) |
| High     | 0 | 7 (**H1**, **H2**, **H3**, 2026-07-27; **H4**, 2026-07-28; **H5**, **H6**, **H7**, 2026-07-28 — post-audit) |
| Medium   | 1 (**M7**) | 10 (**M6**, **M5**, **M4**, 2026-07-27; **M2**, **M1**, **M8**, **M9**, **M10**, **M3**, 2026-07-28; **M11**, 2026-07-29) |
| Low      | 0 | 7 (**L1**, **L2**, **L4**, **L5**, 2026-07-27; **L3**, **L6**, **L7**, 2026-07-28) |

Note: **H2**, **H3**, **C1** and **M9** were resolved by explicit user
decision to *keep* the existing behavior/design as an accepted trade-off
plus add documentation or diagnostics — not by changing `install.sh`'s
functional behavior.
**M1** is now fully resolved, including the Tier 2 capability testing that
was previously deferred to the live SSH test (see its entry below).
**H5**/**H6**/**H7** are not counted in the "18 findings total" above since they postdate that
audit; they're genuine 19th/20th/21st, separately-tracked findings, as
are **M8**-**M10**/**L6**-**L7** (22nd through 26th).

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
  all (essentially certain on stock Debian 13). A cleaner, capability-free
  alternative (running WireGuard fully in userspace via
  `boringtun`/`wireguard-go`, eliminating any kernel-module dependency at
  all) was discussed as a further research item — see
  `docs/design-decisions.md` (DD-10).
- **Regression found via live Tier 3 test, fixed (2026-07-28):** a real
  end-to-end install on a fresh Debian 13 host (the user's own server,
  reimaged clean — see `docs/testing.md` Tier 3) failed at Stage 5:
  `wg-quick up wg0` aborted because its PostUp/PostDown rules call the
  **legacy** `ip6tables` binary, which needs the `ip6_tables`/
  `ip6table_nat` kernel modules — modules this fix never loaded (only
  `wireguard` was covered). Nothing else on the host loads them either:
  Debian 13's own `ip6tables` runs through the nftables backend
  (`nf_tables`/`nft_compat`), so those legacy modules stay unloaded
  regardless of whether real IPv6 WAN connectivity exists (it does, on
  this host — that was a red herring during diagnosis, not the cause).
  Fixed by extending the same Stage 4 modprobe step (now a loop) and
  `/etc/modules-load.d/wg-easy.conf` to also cover `ip6_tables` and
  `ip6table_nat`. Confirmed live: after loading both modules by hand and
  restarting the `wg-easy` container, `wg-quick up wg0` succeeded and the
  interface came up cleanly. Verified with `bash -n`/`shellcheck` after
  applying the permanent fix to `install.sh`.
- **Reboot persistence confirmed (2026-07-28, same day):** rebooted the
  fully-installed host to verify the fix is genuinely durable, not just
  correct within the install session that set the modules up. Confirmed:
  `wireguard`/`ip6_tables`/`ip6table_nat` were all present in `lsmod`
  immediately after boot, loaded automatically via
  `/etc/modules-load.d/wg-easy.conf` alone (no manual intervention);
  `wg-easy` came back `healthy` within seconds, and its peer
  configuration/keys survived (persisted on the `/data/wg-easy/config`
  volume). This was the specific real-server verification this finding's
  resolution note had originally deferred.

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

### H5 — wg-easy healthcheck deadlocks every fresh install after M6 — ✅ RESOLVED (2026-07-28, found via live Tier 3 test)
- **Location:** `install.sh` → embedded `compose.yaml` heredoc,
  `services.wg-easy.healthcheck`
- **Description:** Found during the first real end-to-end Tier 3 test (see
  `docs/testing.md`) on a freshly reimaged Debian 13 host. Stage 5's
  `docker compose up -d --wait --wait-timeout 180` (`master-compose.service`)
  failed because wg-easy never reported healthy. Root cause: the
  healthcheck asserted `wg show wg0 listen-port` equals the install's
  configured `WG_PUBLIC_PORT` (e.g. `65171`). But wg-easy v15+ no longer
  accepts the WireGuard listen port via environment variable at all — it's
  set only through the web UI's first-run setup wizard and persisted to
  its own database (`wgInterface.port`), which **M6** correctly left fully
  manual. On a genuinely fresh install, WireGuard therefore always starts
  on the image's built-in default port (`51820`) until a human completes
  that one-time manual step — something they can't do until the installer
  itself finishes. The healthcheck's fixed-port assertion made this
  impossible to ever satisfy automatically, deadlocking Stage 5 (and by
  extension Stage 6/7) on every fresh install.
- **Why this wasn't caught by the original audit:** `check_compose_runtime`
  (reconcile, `install.sh:2618-2646`) and Stage 7's final summary
  (`install.sh:4087-4093`) already handle "wg-easy setup not finished yet"
  correctly and deliberately — they detect the `/setup` redirect, skip
  auto-restarting wg-easy for a port mismatch, and just report it. Only
  the Docker-level `healthcheck:` block (a separate, earlier gate that
  `docker compose up --wait` itself blocks on) still assumed the port
  would already be correct — an inconsistency invisible to static review,
  only surfaced by actually running the installer.
- **Impact:** Every fresh install using this compose.yaml + M6's manual
  wg-easy setup would fail at Stage 5, before Stage 6 (DNS/Caddy) or Stage
  7 (final verification) ever ran — a total installer failure, not a
  degraded/partial outcome.
- **Resolution:** Removed the port assertion from the healthcheck; it now
  only checks that the `wg0` interface exists and is up
  (`wg show | grep -q interface`), matching the same "first-run setup is a
  human, out-of-band step" model already accepted for Portainer/SFTPGo.
  Confirmed live (with **H1**'s regression fix also applied) that this
  condition is met immediately once `wg-quick up wg0` succeeds, regardless
  of which port the interface is currently on. Verified with `bash -n` and
  `shellcheck` (the compose.yaml heredoc isn't itself shell, but the
  surrounding `install.sh` was re-verified after the edit).
- **Change risk:** Low — strictly loosens an over-specific healthcheck
  assertion to match a precondition (manual first-run setup) the rest of
  the script already designs around; does not change what the healthcheck
  protects against (a container where WireGuard never starts at all still
  fails it).

### H6 — Stage 7's postcondition gate can never pass on a fresh install after M6 — ✅ RESOLVED (2026-07-28, found via the same live Tier 3 test, second attempt)
- **Location:** `install.sh` → embedded `master-network-reconcile` heredoc,
  `check_compose_runtime()`'s `/setup/*` branch
- **Description:** Found on the second live Tier 3 attempt, after **H1**
  and **H5** were fixed — the install got all the way through Stage 6
  (DNS/Caddy, previously never reached) and failed at Stage 7's own
  `master-network-reconcile --check` postcondition call. Root cause:
  `check_compose_runtime()` set `runtime_ok=1` whenever wg-easy's web UI
  redirected to `/setup` (i.e., first-run admin setup not done yet) — the
  exact same expected-after-**M6** state **H5** already accounts for.
  That `runtime_ok=1` fed into `COMPOSE_RUNTIME_DRIFTED`, which
  `all_critical_state_healthy()` treats as a hard failure — and Stage 7
  calls `master-network-reconcile --check` under `set -e`, so this
  aborted the entire installer. The script's own comment at the final
  summary ("wg-easy admin/peer kurulumu artık elle yapılıyor... kurulumu
  bu yüzden durdurmuyoruz") states the intended tolerance explicitly, but
  this earlier, separate gate didn't implement it — an M6-era
  inconsistency between stated intent and actual control flow, invisible
  to static review, only surfaced by actually reaching Stage 7 live (which
  the **H1**/**H5** fixes were themselves required to reach).
- **Confirmed live before fixing:** manually invoked
  `master-network-reconcile --check` against the live, otherwise fully
  healthy host — every other field it reports (`address`, `forwarding`,
  `wg_endpoint`, `tailscale_*`, `firewall`, `docker_netfilter`,
  `compose_unit`, `config`, `canonical_invalid`, `caddy_*`, `dnsmasq_*`)
  was `0`; only `compose_runtime=1`, solely due to the "wg-easy ilk
  kurulumu tamamlanmamış" condition.
- **Impact:** Every fresh install would fail at Stage 7, even after
  fixing **H1** and **H5** — the final postcondition check itself was
  the last remaining blocker to ever completing a fresh install
  end-to-end.
- **Resolution:** Removed `runtime_ok=1` from the `/setup/*` branch only
  (kept the diagnostic `echo` and `WG_CONFIGURATION_INVALID=1`). This
  means: the periodic reconcile timer's own, separate `RECOVERY_FAILED`
  reporting (a later, independent check keyed on `WG_CONFIGURATION_INVALID`
  directly, unaffected by this change) still surfaces "wg-easy setup
  pending" to operators via journald, but it no longer counts as
  `compose_runtime` drift for `all_critical_state_healthy()` — the
  signal Stage 7's `--check` gate (and the timer's own
  restart-vs-no-restart decision) actually depends on. The other two
  branches of the same `if`/`elif` chain (WireGuard port mismatch after
  setup, netfilter drift) are unchanged and still count as real drift.
  Verified with `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh`,
  and `bats test/` (all clean/passing).
- **Change risk:** Low — a one-line removal scoped to exactly the branch
  that represents an expected, non-actionable state; does not touch the
  two sibling branches that represent genuine drift, nor the periodic
  timer's own separate operator-visible reporting of the same condition.

### H7 — Portainer rejects every write request made through the Tailnet DNS name — ✅ RESOLVED (2026-07-28, found via real post-R1.0 usage)
- **Location:** `install.sh` → `compose.yaml` heredoc,
  `services.portainer.environment`
- **Description:** Found while actually using the server after R1.0 —
  every mutating action in Portainer's UI (stop a container, remove an
  image, etc.) failed silently in the browser when accessed via
  `portainer.$LOCAL_DOMAIN` (the Tailnet DNS name proxied through Caddy).
  Portainer's own logs showed `error="origin invalid"` from its CSRF
  middleware: Caddy always presents `Host: 127.0.0.1:9443` to Portainer
  (its own dial address), but the browser's `Origin`/`Referer` is
  `http://portainer.$LOCAL_DOMAIN` — a mismatch Portainer's CSRF
  protection treats as cross-origin and rejects unless the origin is
  explicitly trusted (`trusted_origins=[]` by default). Read-only
  access (browsing, viewing logs) still worked; only state-changing
  requests were blocked.
- **Impact:** Portainer was effectively read-only when accessed via the
  intended Tailnet DNS path — the one meant for convenient day-to-day
  use without an SSH tunnel. Direct access via `127.0.0.1:9443` (SSH
  tunnel) was unaffected, since there Origin and Host naturally match.
- **Resolution:** Portainer supports a `TRUSTED_ORIGINS` environment
  variable for exactly this reverse-proxy-with-different-hostname case.
  Added it to the `portainer` service, set to `portainer.$LOCAL_DOMAIN`
  only when local DNS is enabled (empty/unset otherwise, since without
  Caddy in the picture there's no mismatch to correct).
- **A wrong fix caught before being applied to `install.sh`:** the first
  attempt used `TRUSTED_ORIGINS=http://portainer.$LOCAL_DOMAIN`
  (`scheme://host`, matching how Portainer's current `develop` branch —
  which has since migrated to Go's native `http.CrossOriginProtection`
  — validates this value). Applied directly to the live deployed
  `compose.yaml` first specifically to test it before committing to
  `install.sh` — Portainer **crashed on startup** (`FTL`: "invalid url
  for trusted origin"), because the pinned `2.39.5` release still uses
  the older `gorilla/csrf` library, whose `validate.IsTrustedOrigin`
  does the *opposite* validation: it explicitly **rejects** any value
  containing `"://"` and expects a bare hostname instead. Confirmed by
  reading `2.39.5`'s actual tagged source (not `develop`, which reflects
  newer, different behavior — the version mismatch was the root cause of
  the first wrong guess). Reverted the live container immediately,
  corrected to the bare-hostname form (`portainer.$LOCAL_DOMAIN`,
  no scheme), and confirmed live: container starts cleanly, and a
  simulated write request with the original failing `Origin`/`Referer`
  headers now returns `401` (reaches the auth layer) instead of `403`
  ("origin invalid").
- **Change risk:** Low once corrected — a single, conditional environment
  variable read directly from an already-known state variable
  (`LOCAL_DOMAIN`); no effect when local DNS is disabled. Verified with
  `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh`, and
  `bats test/`, plus live confirmation against the pinned image version
  specifically (not just the library's current docs/source).

## Medium

### M1 — No per-container resource limits or hardening — ✅ RESOLVED (2026-07-28, Tier 2 confirmed via live testing)
- **Location:** `install.sh:1781-1841` (`compose.yaml` →
  `services.qbittorrent`, `services.unpackerr`)
- **Description:** Neither container defined `mem_limit`/`cpus`,
  `security_opt: no-new-privileges`, `read_only`, or a reduced capability
  set, despite processing untrusted downloaded/archive content.
- **Resolution (Tier 1 + Tier 3, applied 2026-07-28):**
  - `security_opt: ["no-new-privileges:true"]` added to both
    `qbittorrent` and `unpackerr` — zero-risk, blocks setuid/setgid
    privilege-escalation paths.
  - Resource ceilings added, sized against the user's actual hardware
    (4 CPU / 8 GB RAM, typically 1-2 active torrents): `qbittorrent`
    → `mem_limit: 2g`, `cpus: 2.0`; `unpackerr` → `mem_limit: 512m`,
    `cpus: 1.0`. These are ceilings, not reservations — they only bite
    during a runaway/abnormal condition, not during normal light usage.
- **Resolution (Tier 2, applied 2026-07-28 after live capability testing):**
  - `unpackerr`: `cap_drop: [ALL]`, no `cap_add` needed (already runs as
    non-root, `user: "1000:1000"`, no init step of its own). Also added
    `read_only: true` — tested and confirmed clean; its only writes are
    to `/downloads`, already a mounted volume.
  - `qbittorrent`: `cap_drop: [ALL]` plus `cap_add: [CHOWN, SETUID,
    SETGID, DAC_OVERRIDE, FOWNER]`. This is a linuxserver.io image whose
    entrypoint runs a root-level s6-overlay init to fix mount ownership
    for `PUID`/`PGID` before dropping privileges; determined this exact
    minimal set empirically, using throwaway `docker run` test
    containers (same images, isolated from the real stack, all removed
    after testing) rather than guessing: `cap_drop: [ALL]` alone fails
    with `chown: Operation not permitted` and
    `s6-applyuidgid: fatal: unable to set supplementary group list`;
    trimming to just `CHOWN`/`SETUID`/`SETGID` (without `DAC_OVERRIDE`/
    `FOWNER`) fails to create `/config/qBittorrent` on a fresh config
    directory. The 5-capability set starts cleanly with no permission
    errors.
  - `read_only: true` was also tested for `qbittorrent` and found to
    **break** its `PUID`/`PGID` mechanism: even with `--tmpfs /run:exec`/
    `/tmp:exec`/`/var/run:exec` (needed just to get past
    `s6-overlay-suexec: fatal: child failed with exit code 111` and
    `Permission denied` executing from a default `noexec` tmpfs), files
    ended up owned by the image's baked-in default UID/GID (`911:1001`)
    instead of the requested `1000:1000` — this would silently conflict
    with the shared downloads-tree ownership model **M2** depends on. Not
    applied to `qbittorrent`; this confirms the original risk assessment
    below rather than contradicting it.
  - Verified with `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh`,
    and `bats test/` (all clean) after applying to `install.sh`.
- **Testing note:** while iterating on the `qbittorrent` capability
  tests, a `docker rm -f` cleanup command filtered by image name and
  accidentally matched (and removed) the real, already-running
  production `qbittorrent` container alongside the throwaway test ones.
  Caught and fixed immediately via `docker compose up -d --no-deps
  qbittorrent`; no data loss, since `/config` is a host bind mount and
  this particular fresh install had no real qBittorrent configuration set
  yet. Subsequent test containers were tracked and cleaned up by exact
  container ID instead of by name/image filter.
- **Change risk:** Low — all values above are empirically confirmed
  against the real images, not guessed; `qbittorrent`'s `read_only`
  was deliberately left unapplied specifically because testing showed
  real risk.
- **Real-workload confirmation (2026-07-28, same day):** after applying
  this config to a fresh install (the fourth live Tier 3 attempt, which
  also succeeded end-to-end), tested both containers under real
  conditions rather than just idle startup: (1) an isolated throwaway
  container with a 256MB `--memory` limit was pushed past it and cleanly
  `SIGKILL`ed (exit 137) by the cgroup memory controller, without
  affecting the host or any real container — confirms `mem_limit`
  actually enforces, not just being present in `compose.yaml`;
  (2) `unpackerr`, running with its new `cap_drop: [ALL]` +
  `read_only: true`, was given a real test archive in its watched
  downloads folder and successfully detected, extracted, and cleaned it
  up within its normal ~10s poll interval — confirms the hardening
  survives a genuine extraction workload, not only an idle container.
- **`mem_limit` sizing correction (2026-07-28, found via real usage):**
  the user reported a real, significant download-speed regression for
  `qbittorrent` (from ~200MB/s to ~70-80MB/s) after **M1** was applied,
  and asked whether the resource limits were the cause. A live A/B/C
  comparison during an actual high-seed-count torrent download (same
  container, same active transfer, resource limits changed and the
  container recreated between each measurement window) found:
  - `cpus: 2.0, mem_limit: 2g` (original **M1** sizing): throughput
    capped around ~170MB/s, CPU usage reaching ~197% (essentially
    saturating the 2-core limit) at the highest observed speeds.
  - Limits fully removed: 218-278MB/s, CPU using up to ~245% (i.e.,
    *more* than 2 cores when available) — confirming a real ceiling
    existed, not just normal swarm variance.
  - **Isolating the variable** — `cpus` held at `2.0`, only `mem_limit`
    raised to `4g`: throughput reached up to 275MB/s, matching the
    fully-unlimited case, with CPU usage comfortably below the 2-core
    cap (~115-204%) even at peak. This isolates the actual cause: the
    original `2g` memory ceiling, not the CPU ceiling, was constraining
    qBittorrent's disk cache/buffering, which was *also* manifesting as
    higher CPU usage (more frequent, smaller I/O operations) — the CPU
    saturation observed in the first measurement was a downstream
    symptom of the memory limit, not an independent bottleneck.
  - **Resolution:** raised `qbittorrent`'s `mem_limit` from `2g` to `4g`;
    `cpus: 2.0` is unchanged (confirmed not to be the binding
    constraint). Applied to the live deployed `compose.yaml` first for
    the A/B test itself, then to `install.sh` once confirmed.
  - **Change risk:** Low — a single ceiling value raised based on
    empirical peak observation (~4.7GB seen under the fully-unlimited
    test), still well short of the host's total 8GB, leaving headroom
    for the other five containers and the host itself.
- **`qbittorrent` resource ceilings removed entirely (2026-07-28, accepted
  deviation from this finding's original remediation):** after the `4g`
  raise above, sustained high-throughput load showed throughput
  fluctuating again; `6g`/`cpus: 3.0` was tried locally (never committed)
  before the user concluded the ceiling itself, not its value, was the
  problem. The reasoning, which this review accepts: on a 4 CPU / ~8GB
  host, each raise was chasing real usage rather than bounding abuse —
  and the last value tried (`6g`) already sat above the highest observed
  unlimited usage (~4.7GB), so it constrained nothing while remaining
  able to throttle a future workload. Both `mem_limit` and `cpus` were
  therefore removed from `services.qbittorrent`.
  - **Still in force for this container:** `security_opt:
    no-new-privileges`, `cap_drop: [ALL]`, and the empirically-minimal
    `cap_add` set — i.e. the parts of this finding's remediation that
    address privilege, not resource consumption. `unpackerr` keeps both
    of its ceilings (`512m`/`1.0`), which never constrained it under a
    real extraction workload.
  - **Residual risk (accepted, not open):** a runaway or maliciously-fed
    `qbittorrent` can now consume host RAM/CPU until the host's global
    OOM killer intervenes, so that failure mode's blast radius widens
    from one container's cgroup to the host and its five other
    containers. No such runaway has been observed on this host to date;
    the user accepted this in exchange for uncapped download throughput.
    Re-introducing a ceiling would only be worth it as a host-survival
    guard rail (a value near total RAM), not as a workload limit.
  - Verified with `bash -n`, `shellcheck`,
    `scripts/lint-embedded-scripts.sh`, and `bats test/` (all clean).

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

### M3 — No user-selectable installation profile — ✅ CLOSED (2026-07-28, won't do)
- **Location:** `install.sh:523-612` (Stage 0 prompts),
  `install.sh:1777-1930` (compose definition)
- **Description:** The six-service bundle (Portainer, Filebrowser,
  qBittorrent, Unpackerr, wg-easy, SFTPGo) is fixed; there is no way to
  opt out of an individual service despite very different risk profiles.
- **Impact:** A user who only wants VPN or only wants media services must
  still accept exposure they don't need (e.g. Portainer's `docker.sock`
  access).
- **Decision (2026-07-28): closed as won't do.** The finding's premise —
  that an operator is forced to accept exposure they don't need — does
  not hold for this deployment. The user confirmed all six services are
  in active use, the host is single-purpose and single-operator, it is
  always installed from scratch onto an empty server, and even the
  "optional" local DNS is enabled on every install. The security
  motivation specifically (avoiding Portainer's `docker.sock` access) is
  already moot: **C1** records that Portainer is actively used and the
  risk accepted.
- **Why not just leave it open:** the cost is real and one-directional.
  Profiles would make compose generation, the `state.env` schema,
  reconcile's `expected_containers`, the public-port firewall rules and
  every per-service assertion in Stage 7 conditional — turning one
  well-tested path into a combinatorial set, on a project whose Tier 3
  testing is still a manual, human-relayed live install. Carrying it as
  an open item also meant re-evaluating it at every review.
- **What would reopen it:** an intention to run this installer on more
  than this one server, or for someone other than its author. Neither is
  in view today. `docs/profiles.md` is kept as a design note for that
  case rather than deleted.
- **Change risk:** None — no code change.

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
- Also added `test/gro_functions.bats`: 5 test cases for
  `add_default_netdev`, the only standalone function in `tailscale-udp-gro`
  (dedupes discovered default-route interfaces into `NETDEVS`/`SEEN`),
  tested the same way against a fake `ip`. All 5 self-skip on this macOS
  dev workstation: the function's dedup guard needs `SEEN` declared as a
  bash associative array (bash 4+), and this workstation's default
  `/bin/bash` is 3.2, which predates associative arrays entirely — a local
  test-environment gap, not a functional bug (the Debian production target
  ships bash 5.x). Surveyed the other three remaining embedded scripts
  (`master-compose-ipv4`, `master-docker-netfilter-recovery`,
  `caddy-tailnet-env`) for further pure-logic candidates and found none:
  each is almost entirely a `sleep`-based wait loop plus real side effects
  (file writes, `flock`, `systemctl restart/start`), with no standalone
  function to extract. `install.sh` untouched throughout.
- Also added `test/canonical_bundle.bats`: 8 test cases for
  `canonical_bundle_ok()`, reconcile's first gate. Its correctness
  depends on Stage 6's manifest file list agreeing with a hardcoded
  expected list ~2000 lines away, with nothing enforcing that and no
  static check able to see a mismatch; the local-DNS-disabled branch that
  **M8** and **M10** both edited has never executed in a live install.
  The tests extract both lists from `install.sh` itself rather than
  restating them, and were mutation-verified on a scratch copy. Hash
  verification and ownership checking are stubbed as out of scope, so all
  8 run with no skips on any POSIX host.
- **Remaining, and parked (2026-07-28):** only CI wiring. Tier 1 is
  complete and Tier 2 now has 57 cases across five files with no
  identified gaps left — `check_ipv4_policy`/`check_ipv6_policy`, the
  last named candidates, are covered by `test/policy_functions.bats`.
  **The user decided on 2026-07-28 that this repository stays local**,
  with no git remote. A CI runner needs somewhere to build from, so CI is
  not "not scheduled yet" — it is structurally out of scope until that
  decision changes. This finding stays open rather than closed at the
  user's request, but future reviews should treat it as parked and not
  re-propose CI; what would unpark it is a remote, nothing else. Tier 3
  automation would additionally need a non-interactive invocation mode,
  which was separately judged not worth changing the deliberate
  `/dev/tty` prompt design for.
- **Superseded remaining items (all now done):** Tier 3 (disposable-VM integration testing); CI
  pipeline wiring (no CI exists in this repo). See `docs/testing.md` for
  the full staged plan.
- **Change risk:** None so far — new standalone test file only,
  `install.sh` untouched. Extracting logic for further unit tests remains
  medium risk in general (see H4) but this pattern (extract function body
  only, never source the whole heredoc) keeps that risk low in practice.

### M8 — Canonical bundle publication window disabled reconcile after an interrupted re-run — ✅ RESOLVED (2026-07-28, found via whole-file review)
- **Location (historical):** `install.sh` Stage 4 (canonical `state.env`
  copy + manifest write), `canonical_bundle_ok()` in the
  `master-network-reconcile` heredoc
- **Description:** Stage 4 unconditionally truncated
  `/usr/local/share/master-stack/SHA256SUMS` to a single `state.env`
  entry, while the `state.env` it had just published could contain
  `LOCAL_DNS_ENABLED=1`. The full seven-entry manifest was only written at
  the end of Stage 6. `canonical_bundle_ok()` cross-checks the manifest's
  entry list against exactly that `LOCAL_DNS_ENABLED` value, so for the
  whole of Stages 4-6 the canonical bundle was self-inconsistent by
  construction.
- **Impact:** Scoped, and smaller than it first appears — while
  `install.sh` is actually running, reconcile already defers on the shared
  `master-stack` lock and never reaches this check. The window only bites
  after a re-run that *failed* somewhere in Stages 4-6: the `EXIT` trap
  restores the previously-active reconcile timer, and every subsequent
  5-minute cycle then hard-exits at `canonical_bundle_ok()` before
  reaching any repair logic, leaving the half-configured host with no
  self-healing at all. The message ("Canonical master-stack bundle
  manifest doğrulaması başarısız") also reads like corruption or
  tampering rather than "the installer was interrupted". Fresh installs
  are unaffected: the timer isn't enabled until the end of Stage 6.
- **Resolution:** The canonical bundle is now published as a single
  atomic set at the end of Stage 6 — Stage 4 writes
  `/etc/master-stack/state.env` but no longer publishes a canonical copy
  or a manifest. Two considered-and-rejected alternatives: simply
  deleting Stage 4's manifest write (a fresh install would then have no
  manifest, and a re-run's stale manifest would not match the newly
  written `state.env` — both still fail), and writing the full
  seven-entry manifest in Stage 4 (impossible on a fresh install, where
  the dnsmasq/Caddy files don't exist yet).
- **Side benefit:** a re-run that fails mid-way now leaves the *previous*
  run's complete, self-consistent bundle in place, so reconcile keeps
  enforcing the last known-good configuration instead of going silent.
  `state_value()` preferring the canonical copy means it reads those
  older values during the window, which is the correct behavior for a
  half-applied re-run.
- **Change risk:** Low — verified that nothing between Stage 4 and Stage 6
  reads the canonical copy: the firewall helper and `master-compose-ipv4`
  never read `state.env`, and a reconcile run triggered via `OnFailure=`
  during Stage 5 defers on the shared lock before reaching any state
  read.

### M9 — Firewall logic is tightly coupled to Docker's internal chain layout, on unpinned packages — ✅ RESOLVED (2026-07-28, accepted risk + diagnostics)
- **Location:** `install.sh` Stage 1 (`apt-get full-upgrade`), Stage 3
  (`apt-get install docker-ce ...`), `ensure_forward_prefix()` and
  `forward_prefix_is_exact()` in the `docker-tailscale-fw` heredoc
- **Description:** Container images are pinned to exact tags, but
  `docker-ce`/`containerd.io`/`tailscale`/`caddy` are installed unpinned.
  Because Stage 3 leaves the Docker apt repository configured, every
  *re-run* upgrades Docker to the newest upstream release via Stage 1's
  `full-upgrade`. The firewall helper meanwhile assumes Docker's internal
  chain layout exactly: `ensure_forward_prefix()` requires
  `DOCKER-USER`, `DOCKER-FORWARD` and `ts-forward` to exist, and
  `forward_prefix_is_exact()` requires them to be the first three
  `FORWARD` rules in that order. `DOCKER-FORWARD` is an implementation
  detail introduced in Docker 26, not a stable interface.
- **Impact:** If a Docker release renames or restructures these chains,
  `ensure_forward_prefix()` returns non-zero and `set -e` aborts the
  helper before any rule is applied. On a re-run the previously-applied
  chains survive (the staging swap only happens at the end), so that path
  fails safe. The exposure is a **reboot** after such an upgrade: these
  rules have no persistence layer and are rebuilt from scratch at every
  boot by `docker-tailscale-fw.service`, so a broken helper means
  `MASTER-DOCKER`/`MASTER-TS-FORWARD` are never created — losing the
  fail-closed WAN DROP and the Tailnet → Docker/LAN DROP backbone.
  Reconcile would also report firewall drift on every cycle.
- **Decision:** Pinning `docker-ce` was considered and rejected — it
  would freeze CVE fixes on a host that publishes ports to the public
  IPv4, a worse trade than the coupling itself. The coupling is accepted
  as-is.
- **Resolution:** `ensure_forward_prefix()` now names the missing chain
  and the binary explicitly and states the likely cause, instead of
  returning a bare non-zero that `set -e` turns into a silent abort. This
  does not change behavior; it turns a multi-minute diagnosis into a
  single log line. The re-run-upgrades-Docker behavior is documented in
  `docs/design-decisions.md` (DD-15). Verified live on 2026-07-28 that
  Docker 29.6.2 still produces exactly the assumed layout.
- **Known related asymmetry (not changed):** `apply_ipv6()` degrades
  gracefully when Docker's IPv6 `DOCKER-USER` chain is missing (warns,
  skips the IPv6 policy), but `ensure_forward_prefix()` is fatal for the
  same condition on either family. A host where Docker manages IPv4 but
  not IPv6 netfilter would therefore abort the whole helper rather than
  skip IPv6. Not observed on the target host; recorded here rather than
  changed, since altering it would loosen a fail-closed path.
- **Change risk:** None — diagnostics only, no control flow changed.

### M10 — Canonical integrity model excludes the files that carry the security policy — ✅ RESOLVED (2026-07-28, narrowed scope)
- **Location:** `install.sh` Stage 6 (manifest contents),
  `canonical_bundle_ok()` / `config_files_ok()` in the
  `master-network-reconcile` heredoc
- **Description:** The canonical bundle covers `state.env` plus the six
  dnsmasq/Caddy files. It does **not** cover `/root/docker/compose.yaml`
  (which defines all six services, their capabilities, `security_opt`,
  port publications and mounts), `/usr/local/sbin/docker-tailscale-fw`
  (~520 lines of firewall policy), `master-network-reconcile`,
  `master-compose-ipv4`, `master-docker-netfilter-recovery`, or the
  systemd units for any of them. It does cover `caddy-tailnet-env` — i.e.
  the *optional* subsystem's helper is integrity-checked while the core
  subsystem's are not.
- **Impact:** Reconcile validates the firewall by invoking
  `"$FW_HELPER" --check`, so nothing verifies the verifier: a modified
  helper self-certifies. Drift in `compose.yaml` (e.g. a removed
  `cap_drop`) is never detected, and `master-compose.service` applies the
  drifted file on every start. Confirmed concretely on 2026-07-28: the
  live host's `compose.yaml` still carried `mem_limit: 6g`/`cpus: 3.0`
  after the repository dropped them, with reconcile reporting healthy
  throughout.
- **Resolution (scope deliberately narrowed to `compose.yaml` only):**
  `compose.yaml` now has a canonical copy, is listed in the manifest, and
  is compared by a new `compose_file_ok()` alongside the existing
  `state_file_ok()`. Drift is **reported and nothing else** — not
  restored, not part of `CONFIG_DRIFTED`, and not part of
  `all_critical_state_healthy()`, so it produces no failed unit and does
  not block Stage 7.
- **Why `docker-tailscale-fw` was dropped from the scope:** on a
  single-operator host that is always installed fresh, that file is never
  hand-edited, so accidental drift is ~zero; and against deliberate
  tampering the check is close to theater, since reconcile validates the
  firewall by invoking that very helper. `compose.yaml`, by contrast, is
  edited live as a matter of routine on this stack — the `mem_limit`
  A/B/C test on 2026-07-28 is a worked example — so the check earns its
  place by catching the case that actually occurs: a change tested live
  and not yet folded back into `install.sh`.
- **Why report-only:** restoring `compose.yaml` has no effect until a
  `docker compose up -d`, which risks a 5-minute recreate loop if the
  drift recurs, and it would silently undo a deliberate operator change
  mid-experiment. Reporting follows DD-13's precedent (disk space:
  surface it, never act on it).
- **Placement detail worth knowing:** the message is emitted at detection
  time rather than in the drift-reporting block further down, because
  that block sits after `all_critical_state_healthy()`'s early `exit 0`
  — a host whose only deviation is `compose.yaml` would otherwise report
  nothing at all. This mirrors how `check_compose_runtime()` already
  surfaces wg-easy's pending-setup state.
- **Known consequence:** adding an entry to the manifest is a schema
  change, and `canonical_bundle_ok()` compares the entry list exactly. A
  reconcile script from this version cannot validate a bundle published
  by an earlier one. That is harmless under this project's deployment
  model — the helper and the bundle always come from the same
  `install.sh` run — but it does mean DD-14's "a failed re-run keeps
  enforcing the last known-good bundle" guarantee does not hold across a
  run that changes the manifest schema, as this one does.
- **Change risk:** Low — additive; the new check feeds no repair path and
  no health rollup. Verified with `bash -n`, `shellcheck`,
  `scripts/lint-embedded-scripts.sh` and `bats test/`.

### M11 — The UDP socket-buffer sysctl is applied after `tailscaled` has already opened its socket — ✅ RESOLVED (2026-07-29, `V1-1`)
- **Location:** `install.sh` Stage 2 — `apt-get install -y tailscale` runs
  before `/etc/sysctl.d/99-master-stack-netbuf.conf` is written and
  `sysctl -p`'d
- **Description:** DD-18 floors `net.core.rmem_max`/`wmem_max` at
  `max(current, 16 MiB)` so that Tailscale's userspace WireGuard
  (`wireguard-go`) can obtain the large UDP receive buffer it asks for.
  But `wireguard-go` requests that buffer **once**, via
  `setsockopt(SO_RCVBUF)` when it opens the socket, and the kernel clamps
  the request against the ceiling *in effect at that moment*. Stage 2
  raises the ceiling only after `tailscaled` is already running, so on a
  first install the floor does not reach the already-open socket.

  Crucially, the daemon is **not** started by the script's own
  `systemctl enable --now tailscaled` — that line is a no-op. Debian's
  `tailscale.postinst` runs `deb-systemd-invoke restart
  'tailscaled.service'`, so the daemon comes up inside `apt-get install
  -y tailscale` itself. Verified on the 2026-07-29 install: `dpkg
  configure tailscale` at 19:17:24, `systemd: Starting tailscaled.service`
  at 19:17:24, `status installed` at 19:17:25. Any fix must therefore put
  the sysctls **before the package install**, not merely before the
  `systemctl` line.
- **Impact:** On any host where the provider image does not already set a
  high `net.core.rmem_max`, `tailscaled` runs with Debian's 208 KB
  ceiling — roughly 70× below its ~14 MiB request — until something
  restarts the daemon (typically the first reboot). Exit-node throughput
  is silently reduced for that window. The effect is invisible on the
  project's test host because its VPS image sets 64 MiB at boot from its
  own `sysctl.d` file, which is why the defect survived DD-18's original
  verification.
- **Evidence:** On the `v1.1-1` install (which had the sysctls moved
  ahead of the daemon start), `tailscaled`'s IPv4 and IPv6 sockets both
  read `rb14680064` (14 MiB) on the original PID with no restart. That
  measurement does **not** isolate the fix, since this host's ceiling was
  already 64 MiB before either ordering ran — it confirms the request
  succeeds, not that the ordering mattered here.
- **Fix (candidate, not yet applied):** Move the netbuf `sysctl.d` write
  and its `sysctl -p` above `apt-get install -y tailscale`. The two
  sysctls are pure kernel settings with no dependency on the Tailscale
  package, so this is a ~15-line relocation within Stage 2 and needs none
  of the Stage 1/2 restructuring reverted with `v1.1-1` (DD-19). An
  alternative that preserves an "install first, tune after" reading is to
  keep the current order and `systemctl restart tailscaled` after the
  sysctls, at the cost of an extra daemon cycle mid-install.
- **Open question before fixing:** whether `tailscale up`/`tailscale set`
  causes magicsock to rebind its UDP socket later in Stage 2. If it does,
  the ceiling raised before `tailscale up` would already apply and the
  defect would be narrower than described — or absent. This was not
  determined on the 2026-07-29 install because that host's ceiling was
  already 64 MiB at boot, which masks the difference. Determining it
  needs a host without a provider-set `rmem_max`, or a deliberate
  before/after `ss -uapm` around a temporarily lowered ceiling.
- **Status:** Resolved in `2026.07.29-V1-1`. The netbuf block (and only
  that block — the forwarding sysctl deliberately stays where it was, see
  the Fix note above) now sits immediately before `apt-get install -y
  tailscale`, so the ceiling is in effect before the package's postinst
  starts the daemon. Found 2026-07-29 while reordering for the reverted
  `v1.1-1` experiment, which fixed it incidentally; the revert
  reintroduced it, and it was then fixed on its own at the user's
  request. **Ordering live-verified** on the 2026-07-29 `V1-1` install
  (`22% - UDP soket buffer tabanı ayarlanıyor` and
  `net.core.rmem_max = 67108864` both logged before
  `25% - Tailscale paketi kuruluyor`); **effect not verified**, because
  the package was already at its newest version so the postinst never
  ran, and the host's ceiling was already 64 MiB. The open question about
  a later magicsock rebind is moot for correctness — raising a permitting
  ceiling earlier cannot hurt (DD-18) — but is still unanswered, so the
  size of the defect that was fixed is not quantified.

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

### L6 — Stack-level repair path had no restart cooldown — ✅ RESOLVED (2026-07-28, found via whole-file review)
- **Location (historical):** `master-network-reconcile` heredoc,
  `STACK_RESTART_REQUIRED` block
- **Description:** Per-container restarts were budget-gated to once per
  15 minutes (`restart_budget_available`), but the stack-level repair
  path — `systemctl stop master-compose` + `systemctl restart
  docker-tailscale-fw` + `docker compose up --wait` — had no equivalent
  gate. Any drift the pass could not actually repair (most plausibly a
  firewall check that keeps failing) therefore re-ran that sequence on
  every 5-minute cycle indefinitely.
- **Impact:** Bounded. `master-compose.service` has no `ExecStop`, so
  `systemctl stop` does not stop containers and the loop never killed the
  stack; the real cost was a permanently failing unit plus a firewall
  reapply and a Compose convergence pass every five minutes forever.
- **Resolution:** The block now reuses the existing
  `restart_budget_available`/`record_container_restart` helpers with a
  `master-compose` pseudo-target, so an unrepairable drift retries every
  15 minutes instead of every 5. `ADDRESS_CHANGED` is deliberately
  exempt: it self-clears after one successful pass, and deferring it
  would leave published bindings on a stale IP for up to 15 minutes.
- **Deliberate trade-off:** the budget is recorded *before* the repair is
  attempted, not after it succeeds — recording only on success would
  leave exactly the failing-repair loop this fixes. The cost is that a
  genuinely new firewall drift arriving within 15 minutes of a successful
  stack repair is deferred, reported via `RECOVERY_FAILED` rather than
  acted on immediately. This matches the semantics the per-container
  budget already has.
- **Change risk:** Low — reuses existing helpers, no new mechanism.

### L7 — Public port numbers are hardcoded inside the firewall heredoc — ✅ CLOSED (2026-07-28, won't do)
- **Location:** `install.sh:502-503` (`WG_PUBLIC_PORT`,
  `QBIT_PUBLIC_PORT`), against the literals in the `docker-tailscale-fw`
  heredoc (`apply_tailnet_guard`, `apply_ipv4`, `check_ipv4_policy`)
- **Description:** The helper is a single-quoted heredoc, so it cannot
  expand the installer's variables and instead repeats `65171`/`65173`/
  `65113` literally, both when applying rules and in the expected-rule
  lists its own `--check` compares against. The WebDAV port has no
  top-level variable at all — it is written out by hand in `state.env`,
  `compose.yaml` (three times), the `Caddyfile` and Stage 7.
- **Impact:** No defect today; the constants and the literals agree.
  Latent: changing a constant would make Compose publish the new port
  while the firewall keeps allowing the old one, and the two verifiers
  would disagree — the helper's `--check` would pass against its own
  hardcoded expectations while Stage 7 (which uses the variables) fails.
- **Deferred (2026-07-28):** the user noted this tool only ever installs
  onto a fresh, empty server, which makes "operator edits a port constant
  and re-runs" a scenario that effectively does not occur — reimage and
  reinstall is the actual workflow. Left open rather than fixed, since
  the fix (having the helper read ports from `state.env` at runtime, the
  way reconcile already does) touches the most security-critical file in
  the project for a purely latent problem.
- **Decision (2026-07-28): closed as won't do.** Both candidate fixes
  were considered and neither earns its cost. Having the helper read
  ports from `state.env` at runtime is the real single-source fix, but it
  edits the most security-critical file in the project for a problem that
  cannot occur under this deployment model — ports are fixed at install
  time and the workflow for changing anything is reimage-and-reinstall,
  not edit-and-re-run. A Stage 3 tripwire (grep the generated helper for
  the expected literals, fail the install on a mismatch) was the cheaper
  option and was also declined: it adds code to guard a scenario that
  does not arise.
- **What would reopen it:** ports becoming configurable per install, or
  the installer being reused across hosts with different port
  requirements — i.e. the same condition that would reopen **M3**.
- **Change risk:** None — no code change.

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

Sixteen numbered remediations applied so far (**C2**, **M6**, **M5**,
**H1**, **H2**, **H3**, **M4**, **L1**, **L2**, **L4**, **L5**, **M2**,
**L3**, **C1**, **H4**, **M1**) plus three post-audit findings from live
testing and real usage (**H5**, **H6**, **H7**) and one unnumbered cleanup
(legacy reboot-timer removal); only **M3**/**M7** remain open as of this
review.

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
| 2026-07-28 | Claude Code (testing) | New: `test/gro_functions.bats`; surveyed `master-compose-ipv4`, `master-docker-netfilter-recovery`, `caddy-tailnet-env` | **M7** Tier 2 continued: 5 new test cases for `tailscale-udp-gro`'s `add_default_netdev` (all self-skip on this workstation's bash 3.2, which lacks associative arrays; the Debian target's bash 5.x is unaffected); the other three remaining embedded scripts surveyed and found to have no standalone pure-logic functions to extract, only wait-loops plus real side effects — left to Tier 3; `install.sh` untouched |
| 2026-07-28 | User + Claude Code (live Tier 3 test) | Live install on the user's reimaged server (`docs/testing.md` Tier 3, first real attempt) | Real end-to-end install run, driven interactively over SSH/tmux. Failed at Stage 5. Diagnosed two real bugs: **H1** had a regression (`ip6_tables`/`ip6table_nat` never loaded on host, breaking `wg-quick up wg0`'s legacy-ip6tables PostUp rules) and a new finding, **H5** (wg-easy healthcheck's fixed-port assertion could never pass after **M6** made the port a manual, web-UI-only setting). Both confirmed live (manual `modprobe` + container restart before touching `install.sh`) then fixed permanently in `install.sh` Stage 4 and the `compose.yaml` heredoc; `bash -n`/`shellcheck`/`scripts/lint-embedded-scripts.sh`/`bats test/` all clean after the fix |
| 2026-07-28 | User + Claude Code (live Tier 3 test, second attempt) | Second live install on the same server, reimaged clean again, with the **H1**/**H5** fixes in place | Install progressed much further this time — Stages 0-6 all succeeded (including wg-easy passing its healthcheck and DNS/Caddy, neither reached on the first attempt) — then failed at Stage 7's own `master-network-reconcile --check` postcondition call. Diagnosed a new finding, **H6**: `check_compose_runtime()` counted wg-easy's still-pending first-run setup as `compose_runtime` drift, which `all_critical_state_healthy()` (and so `--check`'s exit code) treats as a hard failure — contradicting the script's own stated intent not to block on this expected, **M6**-era state. Confirmed live: a manual `--check` run against the otherwise fully healthy host showed every field `0` except `compose_runtime=1`, solely due to the pending-setup message. An attempt to patch the already-deployed reconcile script directly on the server (to verify without a third reimage) was blocked by the auto-mode classifier as an unreviewed live edit — reasonably so; fixed in tracked `install.sh` instead (one-line removal) and verified with `bash -n`/`shellcheck`/`scripts/lint-embedded-scripts.sh`/`bats test/` |
| 2026-07-28 | User + Claude Code (live Tier 3 test, third attempt) | Third live install on the same server, reimaged clean again, with **H1** (regression), **H5**, and **H6** all fixed | **First fully successful end-to-end install**: all 7 stages completed, ending in "AŞAMA 7/7 TAMAMLANDI" and the script's own success summary. Confirmed live: all 6 containers up (`wg-easy`/`filebrowser` reporting `healthy`), all core systemd units (`docker`, `tailscaled`, `docker-tailscale-fw`, `master-compose`, `caddy`, `dnsmasq`, `master-network-reconcile.timer`) active, no failed units, and a manual `master-network-reconcile --check` now exits `0` (still prints the informational "wg-easy ilk kurulumu tamamlanmamış" diagnostic, exactly as **H6** intended — visible but non-blocking). This closes out the first full validation cycle of the 2026-07-28 remediation work; **M1**'s remainder and **H1**'s original real-server verification are the natural next live-testing items |
| 2026-07-28 | Claude Code (live capability testing) | `compose.yaml` → `services.qbittorrent`, `services.unpackerr` | **M1** fully resolved: determined the minimal working `cap_drop`/`cap_add`/`read_only` configuration for both containers empirically, using isolated throwaway `docker run` test containers (never the real stack) — `unpackerr` confirmed clean with `cap_drop: [ALL]` + `read_only: true`; `qbittorrent` confirmed clean with `cap_drop: [ALL]` + `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER]`, and `read_only: true` confirmed to actively break its PUID/PGID mechanism (911:1001 instead of 1000:1000) so deliberately not applied. Applied to `install.sh`; verified with `bash -n`/`shellcheck`/`scripts/lint-embedded-scripts.sh`/`bats test/`. Mid-testing, a `docker rm -f` filtered by image name accidentally removed the real production `qbittorrent` container alongside test containers — caught immediately, recreated via `docker compose up -d --no-deps qbittorrent` with no data loss (`/config` is a host bind mount; no real config had been set yet on this fresh install) |
| 2026-07-28 | User + Claude Code (live Tier 3 test, fourth attempt + operational testing) | Fourth live install (server reimaged clean, all fixes incl. **M1** in place), followed by a full round of post-install operational testing on the same host | Fourth install succeeded end-to-end again — **M1**'s hardening didn't regress Stage 5. With the user's explicit broad testing latitude (host had no production data), ran a comprehensive operational validation: real admin accounts configured for every service; a real WireGuard client connected (confirmed via `wg show` handshake + `docker exec wg-easy ping`ing the peer from inside the container's netns: 0% loss, ~58-107ms RTT); Tailscale exit-node confirmed genuinely routing real traffic (not just configured) via `MASTER-TS-FORWARD` mangle-chain packet counters; a full host reboot confirmed **H1**'s module-loading fix persists across reboots (not just within the install session) and all services recover automatically; three deliberate drifts injected simultaneously (stopped container, disabled IP forwarding, deleted a firewall rule) were all detected and repaired by reconcile within one 5-minute cycle; **M1**'s `mem_limit` confirmed to actually enforce via a throwaway container OOM test; `unpackerr`'s new hardening confirmed to survive a real archive-extraction workload, not just idle; a 4-core CPU stress test showed all services responding in single-digit milliseconds throughout, with a reconcile cycle completing successfully mid-stress. No new bugs found — this round was confirmatory, validating that today's four fixes hold up under real operational conditions, not just a clean install |
| 2026-07-28 | User + Claude Code (real post-R1.0 usage) | `compose.yaml` → `services.portainer` | **H7** found and resolved: Portainer rejected every write request made via `portainer.ayc` ("origin invalid" CSRF error — Caddy always presents `Host: 127.0.0.1:9443` to Portainer while the browser's Origin is `http://portainer.ayc`). Added `TRUSTED_ORIGINS`. First attempt (`http://portainer.$LOCAL_DOMAIN`, matching Portainer's current `develop`-branch validation) was tested directly against the live deployed `compose.yaml` before touching `install.sh` and **crashed Portainer on startup** — the pinned `2.39.5` release uses the older `gorilla/csrf` library, whose validator does the opposite (rejects any `"://"`, expects a bare hostname). Caught by reading `2.39.5`'s actual tagged source, not `develop`. Reverted immediately, corrected to `portainer.$LOCAL_DOMAIN` (no scheme), confirmed live (container stable, simulated write request now reaches the auth layer — `401` instead of `403`), then applied to `install.sh`; verified with `bash -n`/`shellcheck`/`scripts/lint-embedded-scripts.sh`/`bats test/` |
| 2026-07-28 | User + Claude Code (real post-R1.0 usage) | `compose.yaml` → `services.qbittorrent` | **M1** resource ceilings removed entirely (accepted deviation, not a reopened finding): after the `4g` raise below, sustained high-throughput load fluctuated again and a `6g`/`cpus: 3.0` attempt (tried locally, never committed) made it clear each raise was chasing real usage rather than bounding abuse — `6g` already exceeded the highest observed unlimited usage (~4.7GB) on a ~8GB host, so it constrained nothing while still able to throttle a future workload. Both `mem_limit` and `cpus` dropped from `services.qbittorrent`; `no-new-privileges`/`cap_drop`/`cap_add` and `unpackerr`'s own ceilings unchanged. Residual risk accepted by the user: a runaway `qbittorrent` is now bounded by the host's global OOM killer, widening that failure mode's blast radius from one cgroup to the host. `install.sh` 4370 → 4376 lines; verified with `bash -n`/`shellcheck`/`scripts/lint-embedded-scripts.sh`/`bats test/` |
| 2026-07-28 | User + Claude Code (real post-R1.0 usage) | `compose.yaml` → `services.qbittorrent` | **M1** `mem_limit` correction: user reported a real download-speed regression (~200MB/s → ~70-80MB/s) and asked whether M1's resource limits were the cause. Live A/B/C test during an actual high-seed torrent download (recreating the container between each measurement window, same active transfer): original `cpus=2.0/mem=2g` capped throughput ~170MB/s with CPU saturating near the 2-core limit; removing all limits reached 218-278MB/s; isolating the variable (`cpus` held at `2.0`, only `mem_limit` raised to `4g`) also reached up to 275MB/s with CPU comfortably under the cap — proving the `2g` memory ceiling, not CPU, was the real constraint (the CPU saturation in the first test was a downstream symptom of memory-constrained disk caching). Raised `mem_limit` to `4g`; `cpus: 2.0` unchanged. Applied to the live `compose.yaml` for testing, then to `install.sh` |
| 2026-07-28 | Claude Code (whole-file review) + user (live read-only verification) | Full `install.sh` (4376 lines) re-read end to end after the post-R1.0 **H7**/**M1** changes | Five new findings, none of them regressions from those two changes: **M8** (canonical bundle publication window disabled reconcile after an interrupted re-run), **M9** (firewall logic tightly coupled to Docker's internal chain layout, on unpinned `docker-ce`; every re-run silently upgrades Docker via Stage 1's `full-upgrade`), **M10** (canonical integrity model excludes `compose.yaml` and the firewall helper — the files that actually carry the security policy — while covering the optional Caddy subsystem's helper), **L6** (stack-level repair path had no restart cooldown, unlike per-container restarts), **L7** (public ports hardcoded inside the firewall heredoc, no single source of truth). Verified live, read-only, on the running host: Docker 29.6.2 still produces the exact assumed `FORWARD` layout, manifest has all seven entries, reconcile timer active with last exit status `0`, and the live `compose.yaml` was confirmed to still carry `6g`/`3.0` after the repo dropped them — a concrete instance of **M10**. Also cleared the highest-risk-looking hypothesis by reading Portainer 2.39.5's own source: an empty `TRUSTED_ORIGINS` (the never-tested local-DNS-disabled path) is guarded by `if *flags.TrustedOrigins != ""` before the validation loop, so **H7**'s crash cannot recur there |
| 2026-07-28 | Claude Code (remediation) | Stage 4 + Stage 6 (canonical publication), `ensure_forward_prefix()` in `docker-tailscale-fw`, `STACK_RESTART_REQUIRED` block in `master-network-reconcile`, `MASTER_SETUP_VERSION` | **M8** resolved: canonical bundle now published as one atomic set at the end of Stage 6, so the manifest and the `LOCAL_DNS_ENABLED` value it is validated against always appear together; an interrupted re-run now leaves the previous complete bundle in place instead of bricking reconcile. **M9** resolved as accepted risk plus diagnostics: pinning `docker-ce` rejected (would freeze CVE fixes on a host publishing public ports), `ensure_forward_prefix()` now names the missing chain and the likely cause instead of aborting silently under `set -e`. **L6** resolved: stack-level repair reuses the existing 15-minute `restart_budget_available`/`record_container_restart` budget under a `master-compose` pseudo-target, with `ADDRESS_CHANGED` exempt. Also bumped `MASTER_SETUP_VERSION` from the stale `2026.07.26-r8` to `2026.07.28-v1.1` (`STACK_SCHEMA=8` deliberately unchanged — it versions `state.env`'s format, which did not change) and dropped the "R8" prefix from reconcile's two summary lines. `install.sh` 4376 → 4418 lines; verified with `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` and `bats test/` (all clean) |
| 2026-07-28 | Claude Code (remediation) | Stage 6 (canonical publication + manifest), `canonical_bundle_ok()` / new `compose_file_ok()` in `master-network-reconcile` | **M10** resolved with a deliberately narrowed scope: `/root/docker/compose.yaml` gains a canonical copy, a manifest entry and a `compose_file_ok()` comparison; drift is **reported only** — not restored, not in `CONFIG_DRIFTED`, not in `all_critical_state_healthy()`, so it produces no failed unit and does not block Stage 7. `docker-tailscale-fw` was dropped from the scope on reflection: it is never hand-edited on a single-operator, always-freshly-installed host, and checking it is near-theater given reconcile validates the firewall by invoking that same helper. `compose.yaml` earns the check because it is edited live as routine on this stack (the `mem_limit` A/B/C test being a worked example), so the real value is catching a live change not yet folded back into `install.sh`. The message is emitted at detection time, since the drift-reporting block sits after `all_critical_state_healthy()`'s early exit. `install.sh` 4418 → 4449 lines; verified with `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` and `bats test/` |
| 2026-07-28 | User + Claude Code (live Tier 3 test, fifth run — first re-run against an existing install) | Full re-run on the production host with the post-R1.0 batch (**M8**, **M9**, **L6**, **M10**, version string) in place | All 7 stages completed. Verified read-only: canonical directory now holds `compose.yaml` (`0:0:600`, byte-identical to the live file), manifest lists all eight entries in the expected order, `master-network-reconcile --check` reports every field `0` including the new `compose_file=0` and exits `0`, banner shows `2026.07.28-v1.1`, `state.env` finally carries `DOWNLOADS_PATH`, `qbittorrent` runs with `Memory=0 NanoCpus=0`, zero failed units, reconcile timer active. **The finding:** the deployed `compose.yaml` predated both **H7** and **M1**, so `TRUSTED_ORIGINS` and the `cap_drop`/`read_only` hardening reached the server for the first time in this run — Portainer had still been rejecting writes via `portainer.ayc` in real use despite **H7** being fixed in the repository days earlier. A repository fix is not a deployed fix, which is exactly the gap **M10** now reports on. Cost: all six containers recreated (not just `qbittorrent` as predicted from the compose diff); no Docker daemon restart (already at the candidate version); the two WireGuard peers' handshakes reset, with configuration and keys intact on the volume |
| 2026-07-28 | User + Claude Code (rename) | `MASTER_SETUP_VERSION` | Release string renamed `2026.07.28-v1.1` → `2026.07.28-v1b` at the user's request. The date prefix is kept, matching the format used since `2026.07.26-r8`; only the revision component changes. Rows above that quote `-v1.1` are left as-is — they record what the banner actually showed during that run, before the rename. `STACK_SCHEMA=8` again unaffected |
| 2026-07-28 | Claude Code (testing) | New: `test/canonical_bundle.bats` | **M7** Tier 2 continued, and the first v1b-cycle work: 8 test cases for `canonical_bundle_ok()`, reconcile's first gate — a non-zero return there exits before any detection or repair, silencing self-healing entirely. Its correctness rests on Stage 6's manifest file list agreeing with a hardcoded expected list ~2000 lines away in the same file, which nothing enforced and no static check could see; **M8** and **M10** had both edited the local-DNS-disabled branch, which no live install has ever executed. The tests derive both file lists from `install.sh`'s own source rather than restating them, so the two sides are checked against each other, and were mutation-verified on a scratch copy (dropping `compose.yaml` from Stage 6's list makes the test fail as intended). `sha256sum` and `owned_file_ok` are stubbed as out of scope, so all 8 cases run with no skips on any POSIX host — unlike the three existing `.bats` files. `install.sh` untouched |
| 2026-07-28 | User decision + Claude Code | **M3** (installation profiles), **L7** (hardcoded ports in the firewall heredoc) | Both **closed as won't do**, no code change. The shared reason is the deployment model the user confirmed during this review: a single-purpose, single-operator host, always installed from scratch onto an empty server, with all six services in active use and local DNS enabled every time. **M3**'s premise (an operator forced to accept exposure they don't need) therefore does not hold, and its security motivation is already covered by **C1**'s accepted risk; carrying it open meant re-evaluating it every review while its implementation would turn one well-tested path into a combinatorial set. **L7** has no scenario that can trigger it under the same model — ports are fixed at install time and the workflow for change is reimage-and-reinstall; both candidate fixes (runtime read from `state.env`, and the cheaper Stage 3 tripwire) were declined. Either would reopen if the installer is ever reused across hosts or by someone other than its author; `docs/profiles.md` is kept as a design note for that case. **M7** is now the only open finding |
| 2026-07-28 | Claude Code (testing) | New: `test/policy_functions.bats` | **M7** Tier 2 continued: 17 test cases for `check_ipv4_policy()`/`check_ipv6_policy()`, the two composite verifiers that hold the project's entire expected firewall rule set and whose verdict `docker-tailscale-fw --check` returns — the signal reconcile trusts wholesale when deciding the firewall has drifted. `docs/testing.md` had assumed these were too integration-shaped to unit-test and left them to Tier 3; that proved too pessimistic, since they only read state (`-S`/`-C`) and their remaining dependencies are plain assignable globals. Covers the healthy policy plus eleven specific ways it can be wrong (missing terminal WAN DROP, missing Tailnet DROP, jump not first, duplicated jump, extra rule appended to `DOCKER-USER`, resurrected legacy wide rule, leftover staging chain in either table, terminal DROP inside `DOCKER-FORWARD`, wrong `FORWARD` prefix order, and a WebDAV allow bound to a stale Tailscale address), plus the IPv6 variants including **M5**'s missing-`ip6tables` diagnostic and the reduced no-IPv6-WAN rule set. Uses a table/chain-dispatching fake stand-in that avoids bash associative arrays, so all 17 run with no skips on this workstation's bash 3.2. Documented limitation: these prove the verifier's decisions, not that the apply path produces what it expects — that coupling stays Tier 3's job. 57 cases total across `test/`. `install.sh` untouched |
| 2026-07-28 | User decision | **M7** (CI wiring) | The user decided this repository stays local, with no git remote. CI is therefore parked, not pending: a runner needs somewhere to build from. **M7** is kept open at the user's request rather than closed, but the record now states that the blocker is a deliberate workflow choice, so future reviews should not re-propose CI — only a remote would unpark it. Tier 1 is complete and Tier 2 has 57 cases with no identified gaps remaining, so no further test work is queued either |
| 2026-07-29 | Claude Code (consistency pass) | `install.sh` — `WEBDAV_PORT`, reconcile constants, `ensure_forward_prefix`, comment language | Four same-value cleanups plus one patience fix, all found by measuring rather than recalling: `WEBDAV_PORT` promoted to a top-level variable (`65113` had been hand-written in 17 places; 13 now use the variable, shrinking **L7** from a 17-site to a 3-site problem); `DISK_USAGE_THRESHOLD_PCT`/`RESTART_COOLDOWN_SECONDS` replace duplicated literals, with a cross-reference to `master-docker-netfilter-recovery`'s own copy that cannot share them; `ensure_forward_prefix()` now waits for Docker's chains via a shared `wait_for_chain()` instead of testing once — it ran before the functions that already waited and was fatal under `set -e`. 45 English comment lines translated back to Turkish and `CLAUDE.md`'s language rule reversed to match the file, which had always been ~73% Turkish |
| 2026-07-29 | Claude Code (found via boot journal) | systemd unit file modes | Eight unit files were `0600` because of the script's top-level `umask 077`, producing 12 `marked world-inaccessible` warnings per boot; Stage 6's three drop-ins were already `0644` by hand, making this an internal inconsistency rather than a uniform choice. `0600` bought nothing — unit files hold no secrets and systemd's own message says the restriction has no effect. Replaced with one `set_unit_file_mode()` helper at all eleven write sites. Verified on the live host after a redeploy and reboot: 12 warnings → 0, no `0600` unit files remaining |
| 2026-07-29 | User + Claude Code (live Tier 3, runs 6-7 + two reboots) | Clean install on a reimaged host, re-run, two reboots, netfilter analysis | Both runs completed all 7 stages with `--check` clean. Reboot recovery measured twice: ~35s to SSH, ~13s to all six containers healthy, zero failed units, H1 modules auto-loaded, wg-easy port and both peers intact. Netfilter reconstruction analysed: nothing persists rules to disk, so the full set is rebuilt each boot (packet counters reset confirm it); IPv6 comes back byte-identical, IPv4 differs only inside Docker's own chains because container bridge IPs are assigned in a non-deterministic start order — our `MASTER-*` chains and the `FORWARD` prefix are byte-identical because they never reference container addresses. Written up as DD-16/DD-17. Boot ordering measured: `docker-tailscale-fw` starts exactly when `docker.service` becomes active, so the `After=` guarantee is structural — which is also why `wait_for_chain` never actually waits, recorded honestly as defensive consistency rather than a demonstrated fix. reconcile's first post-boot run changed nothing (rule counts identical before/after, ~3s, exit 0) |
| 2026-07-29 | User + Claude Code (wg-easy connection/service audit + remediation) | Live WireGuard data path, official wg-easy v15 compose comparison, Stage 2 sysctl, `master-network-reconcile` | Audit found no connectivity or throughput defect: 6.19 GiB of real peer traffic with zero drops at every hop, IPv4 and IPv6 egress both working, and our compose deviating from the [official v15 example](https://raw.githubusercontent.com/wg-easy/wg-easy/v15.3.0/docker-compose.yml) only in the security-improving direction (no `SYS_MODULE`, no `/lib/modules` mount, IP-bound ports). Two changes applied. **(1)** `net.core.rmem_max`/`wmem_max` are now floored at `max(current, 16 MiB)` by Stage 2 — they had been 64 MiB on the live host, but from the VPS provider's image file rather than from `install.sh`, so the value was correct by accident. First proposed as a WireGuard fix; measurement disproved that attribution (kernel WireGuard consumes packets via `encap_rcv` before the socket receive queue — the container netns showed `RcvbufErrors 0` after 5,074,319 datagrams), and the real beneficiary is Tailscale's userspace WireGuard, whose `tailscaled` was holding a 14 MiB buffer. Recorded as DD-18, including why raising this ceiling cannot regress performance the way **M1**'s cgroup ceilings did. **(2)** reconcile now restarts `tailscale-udp-gro.service` when inactive — `Restart=no` meant a boot-time failure persisted until the next reboot, and the unit's comment had claimed reconcile retried it, untrue since DD-11. Narrower than the code DD-11 removed: the unit is checked, ethtool flags still are not. Declined by the user in the same session: `cap_drop`/`no-new-privileges` for wg-easy (**M1** coverage gap, still open), and an MTU 1420→1440 raise (~1.4% gain, rejected as not worth the mobile-peer fragmentation risk). `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats pass; `max()` logic simulated across five edge cases under `set -e` |
| 2026-07-29 | User + Claude Code (live Tier 3: reboot + GRO fault injection on a reimaged host) | Post-reboot recovery, all connection paths, `v1rc-1` deployment markers, deliberate `tailscale-udp-gro` failure | Reimaged host, manual install, then verification. **Deployment confirmed:** all three `v1rc-1` markers live — banner version, `/etc/sysctl.d/99-master-stack-netbuf.conf`, and the new `gro_unit=` field in `--check`. DD-18's `max()` behaved as designed, preserving the provider's 64 MiB rather than lowering it to the 16 MiB floor. **Reboot:** SSH back in 38s, six containers healthy in 43s, zero failed units, GRO flags reapplied, sysctl values persisted, `--check` all-zero exit 0. **Connection paths:** Tailscale exit-node online, wg0 listening with two peers, MASTER-DOCKER 9 / MASTER-TS-FORWARD 8 rules with 3 DNAT entries, 4/4 Tailnet DNS names resolving, Caddy 200/200/200/302, WebDAV 401. DD-16 re-confirmed incidentally — qBittorrent's bridge IP moved `172.18.0.2`→`172.18.0.5` across the reboot while the managed chains came back identical. **Fault injection:** `systemctl stop tailscale-udp-gro` was detected and repaired by the *timer-driven* reconcile within 2 seconds (journal-timestamped), exercising the real production path rather than a manual invocation, and writing the cooldown stamp. **Two findings, both fixed in `v1rc-2`:** (1) Stage 0's DNS prompt defaulted to `H` even with a managed install present, and that answer aborts Stage 0 a few lines later — pressing Enter on a re-run killed the installer, which is how the first verification attempt died; detection is now computed once and feeds both the default and the abort check. (2) The fault injection also proved the unit-only GRO check verifies bookkeeping rather than throughput: after the stop, `rx-udp-gro-forwarding` was still `on`, so nothing had actually degraded. Reconcile now checks the ethtool flags too. Declined by the user: a `rmem_default` raise — the qBittorrent socket buffer will be set from the application instead, which the `rmem_max` floor already permits. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats pass; both new code paths pre-flighted read-only against the live host and simulated across five flag states and both prompt branches |
| 2026-07-29 | User (reading the new prompt) + Claude Code (remediation) | Stage 0 domain prompt, traced against Stage 6's config writes | The `v1rc-2` re-run fix stopped the abort but left a worse-hidden defect: the domain question still defaulted to a hardcoded `ayc` while the new banner claimed "varsayılan: korunur". On any host using a different domain, pressing Enter would silently switch it — and because Stage 6 writes both `/etc/dnsmasq.d/local-services.conf` and `/etc/caddy/Caddyfile` with `>` rather than `>>`, the old names are replaced, not duplicated, so nothing would look wrong until DNS stopped resolving the previous hostnames. Found by the user asking what the new prompt actually does rather than by any check; the wording could not answer the question, which was the tell. Fixed: the default now reads `LOCAL_DOMAIN` from `/etc/master-stack/state.env` (flowing through the existing length/charset/label validation, so a corrupt state file is caught) and falls back to `ayc` only when there is nothing to read; the prompt names the detected domain and states both branches explicitly — `E` regenerates from the same domain, `h` stops the installer rather than skipping. Verified across four `state.env` shapes (populated, empty value, different domain, missing file) and all three prompt scenarios. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats pass |
| 2026-07-29 | User (prompt design) + Claude Code (remediation) | Stage 0 re-run branch restructured | Third and final pass on the same prompt. `v1rc-2` stopped Enter aborting and `v1rc-3` made the domain default truthful, but the question itself was still the fresh-install one: asking "kurulsun mu?" against an install that already has DNS made `h` mean "abort the installer" rather than "leave it alone" — a reading no user would arrive at from the prompt text, which is what prompted the user to ask what each answer actually did. The re-run branch now asks whether the *domain* changes: `e` prompts for a new one, Enter/`H` keeps the existing domain and structure and the run continues. The `exit 1` path is removed rather than merely defaulted away from, so declining to change is an ordinary outcome; the guarantee that DNS/Caddy is never silently torn down is now structural (the option is never presented) instead of enforced by aborting, and a note states that removal is not something this script does. Enter means "change nothing" in both branches. Domain validation consolidated into a single block every branch flows through, so the `state.env`-sourced value is validated on exactly the same path as typed input. Verified across nine branch combinations (fresh/existing × Enter/H/e × default/typed domain, plus a non-`ayc` existing domain). `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats pass |
| 2026-07-29 | User (applied the setting mid-download) + Claude Code (measurement) | qBittorrent UDP socket buffer under real load; DD-18's `rmem_max` floor validated end-to-end | The user set qBittorrent's socket receive buffer while a ~278 MB/s download was running, which produced a natural A/B on the same torrent minutes apart. **Before** (208 KB system default): the uTP/DHT socket read `r216576 / rb212992` — queue at 101% of the buffer, saturated — and drops climbed from 14,735 to 15,636 in roughly 90 seconds. **After** (buffer applied live): 288,201 packets received in 30 seconds with **zero** `RcvbufErrors`, queue at 3.4 MB of 128 MiB (2.7%), throughput 222 MB/s sustained. The granted buffer was exactly `2 × net.core.rmem_max` (134,217,728), confirming the kernel clamped the application's 434 MiB request to the ceiling and doubled it — which makes DD-18's floor the load-bearing half of the fix: on Debian's default `rmem_max` of 212,992 the identical request would have yielded 416 KB, 300× smaller, and the saturation would have persisted. This closes the open question from earlier in the session and confirms the user's judgement that no `rmem_default` change was needed: the application requests its own size, so a system-wide default would have been the broader change for no extra benefit. **Residual gap, accepted by the user (2026-07-29):** `install.sh` does not manage qBittorrent's configuration — the same deliberate model as the wg-easy/Portainer/SFTPGo admin accounts — so a fresh install silently reverts to 208 KB and will saturate again at this host's real throughput. Mitigated by documentation only: the final install summary now names the setting, the measured reason, and a suggested 16 MiB value. Note the earlier probe attempt was inconclusive by construction and is not the evidence here — this measurement is |
| 2026-07-29 | User (field report + revert decision) + Claude Code (reorder, live measurement, revert) | Stage 1/2 ordering experiment `v1.1-1`, then reverted to V1 | Shipped a reorder that moved the Tailscale login ahead of `apt-get full-upgrade`, then measured it on a clean install and reverted it the same day at the user's direction. **The reorder worked and did not fix the complaint.** Measured: Stage 1 began 19:17:15, the login banner hit the screen at 19:17:25 (+10s, versus ~4-6 minutes before), `control: RegisterReq` went out at 19:17:25 — and `control: AuthURL is …` did not arrive until 19:22:06. **4m41s of the user's "very long wait" is Tailscale's control plane answering the first registration request**, which no ordering in `install.sh` can affect. The URL reached the terminal in the same second `tailscaled` received it, which also settles the buffering question permanently: `tee`'s stdout is fd 5 (`/dev/tty`), glibc line-buffers it, delivery is immediate. Network eliminated as a cause — IPv4 and IPv6 both reached `controlplane.tailscale.com` in ~25 ms, 1500-byte frames passed `-M do` on both stacks, the control-plane TCP connection stayed `ESTAB` with an empty queue, and `tailscaled` logged nothing at all between 19:17:30 and 19:22:06. The install itself was otherwise clean: 7/7 stages, zero warnings, zero failed units, six containers up, `--check` all-zero exit 0, 7/7 DNS names, Caddy 200/200/200/302/302/401/200, WebDAV reachable on the Tailscale IPv4 and refused on the public IPv4. Reverted because the reorder addressed ~4-6 minutes of apt work while leaving the dominant 4m41s untouched, and cost a real 3-6 second settling window between `systemctl enable --now tailscaled` and `tailscale up` that the GRO block previously provided — `login-interactive` was issued in the same second `tailscaled` logged `health(warnable=warming-up): error: Tailscale is starting. Please wait.` `install.sh` is now byte-identical to `versiyon/install-V1F.sh` (`4fa60e28…`, 4683 lines, `2026.07.29-V1`). Two findings retained from the experiment: **M11** (netbuf sysctl applied after `tailscaled` opens its socket — a real defect the reorder fixed incidentally and the revert reintroduced) is now tracked open, and DD-19 records the measurement so the reorder is not proposed again on the same reasoning. Also unverified in this run and still unknown: `full-upgrade` reported `0 upgraded, 0 newly installed`, so the "upgrade restarts `tailscaled`" path the reorder was designed around never executed |
| 2026-07-29 | User (re-install on V1F) + Claude Code (measurement) | `RegisterReq` → `AuthURL` latency under the original ordering; warm-up race hypothesis | The user reinstalled with `install-V1F.sh` and reported the login link appeared immediately. Measured from the journal: `Starting tailscaled.service` 19:39:47, `health(warnable=warming-up): error` 19:39:48, `StartLoginInteractiveAs("root")` 19:39:48, `RegisterReq fup=false` 19:39:48, warm-up cleared 19:39:53, `got response; authURL=true` 19:39:54 — **6 seconds**, against 4m41s on the `v1.1-1` run 22 minutes earlier on the same host. **This disproves the warm-up-race hypothesis raised during the revert:** the original ordering also issues `LoginInteractive` one second after the daemon starts, inside the same warm-up window, and still got its URL in 6 seconds. The claim in the revert's rationale that the GRO block gives the daemon "3-6 seconds to settle" that the reorder removed was therefore wrong; DD-19 has been corrected. The `RegisterReq` latency is Tailscale control-plane variance that neither ordering influences — the user's read. Also worth recording for any future reorder attempt: this V1 run completed Stage 1 in **7 seconds** because `full-upgrade` and the base packages were already current from the previous install, so it measures the control-plane question well but says nothing about the positional question, which needs a cleanly reimaged host. **M11** is unaffected by any of this and remains open |
| 2026-07-29 | User (directed the fix) + Claude Code (remediation, `V1-1`) | Stage 2 — netbuf `sysctl.d` block relocated ahead of `apt-get install -y tailscale` | **M11 resolved.** The DD-18 socket-buffer floor was being applied after `tailscaled` was already running, so `wireguard-go`'s one-shot `setsockopt(SO_RCVBUF)` request was clamped against whatever ceiling existed at socket-open time. The constraint that determines where the fix has to go was established from the host, not assumed: Debian's `tailscale.postinst` runs `deb-systemd-invoke restart 'tailscaled.service'`, so the daemon starts *inside* the package install (`dpkg configure tailscale` 19:17:24 → `systemd: Starting tailscaled.service` 19:17:24 → `status installed` 19:17:25) and the script's own `systemctl enable --now tailscaled` never performs the start. An earlier draft of M11 proposed moving the sysctls above that `systemctl` line, which would have achieved nothing; that error was caught and corrected before any code changed. Only the netbuf block moved — the forwarding sysctl deliberately stayed in place, since `ip_forward` is read dynamically and is only required before `tailscale set --advertise-exit-node`, and hoisting IPv6 forwarding ahead of the package download would alter routing state earlier than necessary for no benefit. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats pass; 4701 lines. **Not live-verified, and not verifiable on the current test host** — its VPS image sets `net.core.rmem_max` to 64 MiB at boot, which masks the difference entirely. Confirming the fix needs a host without a provider-set ceiling. The related open question — whether `tailscale up`/`set` rebinds magicsock's UDP socket later in Stage 2, which would have made the original defect narrower — is still unanswered; it does not affect the correctness of the fix (raising a permitting ceiling earlier cannot hurt, per DD-18) but does mean the magnitude of what was fixed is unquantified |
| 2026-07-29 | User (approved + answered every prompt) + Claude Code (tmux relay, verification) | Full `V1-1` install on the live host, then a complete post-install sweep | First live run of the M11 fix. Host was in a partially-provisioned state going in — the Tailscale package installed and `tailscaled` running but logged out, `sysctl.d` files present, no Docker, no `state.env` — because two earlier V1F runs had been interrupted at the login (`rc=130`, SIGINT). The re-run handled it as the ordinary idempotent path. Prompts relayed one at a time via a detached `tmux` session and answered by the user (`/downloads`, DNS `e`, domain `ayc`, confirm `E`); no value was chosen on their behalf. **Install:** 19:52:55 → 19:54:45, 1m50s, 7/7 stages, **zero warnings**, zero failed units. **Verification:** six containers up (wg-easy and filebrowser `healthy`), all six managed units plus `dnsmasq`/`caddy` active, `--check` every field 0 including `gro_unit=0 gro_flags=0` at exit 0, 7/7 `.ayc` DNS names resolving, Caddy 200/200/200/302/302/401/200, WebDAV 401 on the Tailscale IPv4 and connection-refused on the public IPv4 (the `--ctorigdst` restriction holding), MASTER-DOCKER 9 / MASTER-TS-FORWARD 8 rules with 10 DNAT entries, GRO flags `on`/`off`, exit-node advertising `0.0.0.0/0` + `::/0` with `NetfilterMode: 2`. **M11 ordering confirmed from the log** (`22% - UDP soket buffer tabanı ayarlanıyor` + `net.core.rmem_max = 67108864` both before `25% - Tailscale paketi kuruluyor`) — **but the effect was not measured**, since `tailscale is already the newest version` meant the postinst never ran and `tailscaled` was never restarted (still PID 1494 from 19:39:47), and the host's ceiling was already 64 MiB regardless. Fourth data point on the login-URL question: `RegisterReq` 19:53:00 → `AuthURL` 19:53:02, **2 seconds**, against 4m41s / 6s / 2s across the four runs — confirming DD-19's conclusion that the latency is control-plane variance and the first observation was an outlier. Two incidental notes: `state.env` had been deleted before this run, so Stage 0 took the fresh-install branch and re-asked for the domain rather than detecting the existing `.ayc` setup (expected — detection is keyed on `state.env` — but worth knowing after an aborted run); and the Tailscale node key was regenerated, moving the host from `100.127.208.28` to `100.69.133.94` and leaving a dead tailnet entry |
| 2026-07-30 | User (approved item 1 of the structural plan) + Claude Code (implementation, `V1-2`) | Host-side version self-reporting (`state.env`) + `master-network-reconcile --status` | Not a security finding — first item of the 2026-07-30 structural-optimization plan. `install.sh` now hashes itself at startup (`sha256sum "${BASH_SOURCE[0]}"`, degrading to `bilinmiyor` when there is no readable path) and writes `STACK_VERSION`/`STACK_SHA256` into `state.env`; both keys are informational, so `STACK_SCHEMA` stays 8 and no reconcile validation changed. The reconcile helper gained a `--status` mode that deliberately enforces **no** preconditions (not even `canonical_bundle_ok`) because a status command must work exactly when the system is broken; the detailed health verdict comes from an embedded child `--check` run, which is also the only thing that takes the lock, and `--status` passes its exit code through. Security posture unchanged: `--status` is read-only, root-run, and prints nothing secret (`state.env` holds no credentials). Attack surface added: none — no new listener, unit, file, or firewall rule. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats; 4792 lines. Static verification only — the new mode has not yet run on a live host |
| 2026-07-30 | User (approved item 2 of the structural plan, chose rclone) + Claude Code (implementation, `V1-3`) | Replacing the `sftpgo` container with a host `rclone` WebDAV service | **Net security improvement, and the main reason to do it.** The narrow `-i tailscale0 -p tcp --ctstate NEW --ctorigdst $TAILSCALE_IPV4 --ctorigdstport 65113 -j ACCEPT` rule in `MASTER-TS-FORWARD` was the **only** exception in the otherwise fail-closed Tailnet → Docker direction; it existed solely to reach the sftpgo container. A host service is reached over INPUT, which the guard chain never inspects (the same reason Caddy and dnsmasq need no rule), so the exception was deleted from both the apply path and `check_ipv4_policy`'s expected set. That direction now has zero exceptions. Sandboxing did not regress in the trade: the container offered a `:ro` bind mount, while `master-webdav.service` runs as a dedicated non-login system user under `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp`, `PrivateDevices`, `ProtectKernelTunables`, `ProtectControlGroups`, `NoNewPrivileges` and `RestrictAddressFamilies=AF_INET AF_INET6`, plus `rclone --read-only`. The user holds gid 1000 only to read the 0750 media tree — chosen over widening the tree's permissions, which would have undone **M2**. **New secret handling, reviewed deliberately:** this is the first credential `install.sh` has touched since **M6** removed the wg-easy bootstrap. Stage 0 reads the password with `read -rsp` from `/dev/tty` (no echo, confirmed twice, 8-char minimum), Stage 4 pipes it straight into `htpasswd -i -B` and `unset`s the variable; only the bcrypt hash reaches disk, at `root:root 0600`, and the service obtains it through systemd `LoadCredential=` rather than a readable path. The file is deliberately **excluded from the canonical bundle** — reconcile must never revert or regenerate a credential — and preserved across re-runs, so an operator resets it by deleting the file. **One latent vulnerability was found and fixed during implementation, before any commit:** the first draft copied Caddy's `ExecStartPre` + `EnvironmentFile=` pattern, but systemd loads environment files before any `Exec*` command runs, so on a first start `${TS_IPV4}` would have expanded to empty and `--addr :65113` would have been a **wildcard bind exposing WebDAV on the public IPv4**. Caddy is safe only because its binary re-reads the file itself via `--envfile`; rclone has no such flag. Resolved by moving address resolution inside `ExecStart` (`master-webdav-serve`), which removes the failure class rather than working around it. Stage 7 now also asserts positively that the listener is on the Tailscale IPv4 and negatively that it is not on the public IPv4 or a wildcard. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` (now covering the seventh embedded script) clean; 57/57 bats after fixture updates; 4988 lines. **Not live-verified** |
| 2026-07-30 | User (approved the install) + Claude Code (tmux relay, diagnosis, `V1-6`) | First live install of the host WebDAV service — **failed at Stage 7**, three bugs found and fixed | The headline: **static analysis passed cleanly on all three of these**, and only a real install surfaced them. (1) `RestrictAddressFamilies=AF_INET AF_INET6` omitted **`AF_NETLINK`**, which iproute2 requires; `ExecStart`'s `ip addr show` failed with `Cannot open netlink socket: Address family not supported by protocol`, so the service never bound. Proven by measurement rather than inference — a transient unit with the two-family restriction reproduced the error, and adding `AF_NETLINK` fixed it. (2) That failure was **invisible**: the wait loop discarded `ip`'s stderr, making a hard configuration error indistinguishable from "the address hasn't appeared yet", and the unit reported `active (running)` for the whole 300-second window. This is the more instructive defect of the two — a fail-fast condition disguised as a wait. The loop now separates the cases and reports the first `ip` error immediately; the first attempt at that used `mktemp`, which itself failed under `ProtectSystem=strict` (`Read-only file system`) and was caught in the same session, so stderr is now captured into a variable. (3) **All three 401 probes were written against sftpgo's behavior**: rclone deliberately exempts `OPTIONS` (the WebDAV discovery preflight) from authentication and returns 200, where sftpgo returned 401. Left uncorrected, Stage 7 would have failed every install and reconcile would have classified WebDAV as drifted on every 5-minute cycle and restarted it indefinitely. `webdav_direct_ok()`, Stage 7's direct check and `caddy_runtime_ok()`'s vhost check now use `PROPFIND` with `Depth: 0` — a **stronger** assertion than the original, because a 401 on a protected method proves the htpasswd is actually enforced rather than merely that something answered. **Security posture was never actually compromised**, and this was verified rather than assumed: on the running service, unauthenticated `GET` and `PROPFIND` both returned 401, a wrong password returned 401, correct credentials returned 207, and an unauthenticated `GET` body was `Unauthorized`. Only `OPTIONS` is open and it discloses nothing. Also confirmed live, closing two of DD-20's three open questions: the `master-webdav` user reads the 0750 media tree through its gid 1000 membership, and the listener binds the Tailscale IPv4 alone with the public IPv4 refusing connections. The firewall change held — `MASTER-TS-FORWARD` showed six rules with **no** `--ctorigdst` WebDAV exception. Two incidental observations: Stage 1 completed in under 30 seconds on a genuinely fresh image (`full-upgrade` plus all base packages), which finally answers DD-19's positional question — hoisting the Tailscale login earlier would buy nothing; and **M11 remains unmeasurable on this host**, whose fresh provider image already sets `net.core.rmem_max` to 64 MiB. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats; 5039 lines. **Still untested: Infuse as a real client** (`Range`/seek behavior, playback) |
| 2026-07-30 | User (standing authorization for defaults) + Claude Code (install, `V1-7`, verification) | Fourth bug, then the first fully successful install of the WebDAV architecture | The `V1-6` re-run died at **Stage 5**, not 7: `systemctl restart master-webdav.service` returned non-zero with `Start request repeated too quickly` and `status=243/CREDENTIALS`. Cause chain, reconstructed from the journal: the old (pre-`V1-6`, netlink-broken) unit had exhausted its 300-second wait, exited 1, been restarted by `Restart=on-failure`, failed again, and tripped `StartLimitBurst=2` — leaving it `failed` and rate-limited. This is the ordinary state of the unit after *any* failed install, so it is a genuine re-run defect rather than a test artifact. **Reconcile's repair path already did `reset-failed` before restarting; Stage 5 did not** — that inconsistency was the actual bug, and Stage 5 now matches. **`V1-7` then installed cleanly: 22:35:51 → 22:36:13, 22 seconds, 7/7 stages, one expected warning** (wg-easy's admin account is a deliberate manual step). Full post-install sweep, all green: `--status` reported `2026.07.30-V1-7` and SHA256 `c062b452…` matching the local file byte-for-byte, which is the **first working use of the `V1-2` version self-reporting** and closes the 2026-07-28 drift gap end-to-end; `--check` every field 0 at exit 0 including `webdav_unit=0 webdav_runtime=0`; five containers up, `master-webdav` active, zero failed units; WebDAV listener on `100.104.105.21:65113` alone, refusing on both the public IPv4 and loopback, unauthenticated `PROPFIND` 401, wrong password 401, correct credentials 207, and a `Depth: 1` listing returning the real media tree (`/movies/`, `/series/`, `/.unpackerr/`); 6/6 `.ayc` DNS names with `sftpgo.ayc` correctly gone; Caddy 307/200/200/302/200 plus webdav 401 unauthenticated and 207 authenticated through the vhost, confirming the `{$TS_IPV4}` reverse-proxy target works; `MASTER-TS-FORWARD` at six rules with **zero** occurrences of 65113, i.e. the fail-closed Tailnet → Docker direction verified with no exceptions; exit node advertising `0.0.0.0/0` + `::/0`, `NetfilterMode: 2`, stateful filtering on, GRO flags `on`/`off`. **Drift test:** stopping `master-webdav.service` was detected as `webdav_unit=1 webdav_runtime=1` and reconcile restarted it back to `active` with a 401 response — the new monitoring works end to end. Also cleaned up: a `run-p8204-i8504.service` left `failed` by this session's own `systemd-run` diagnostics. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats; 5046 lines. **Still untested: Infuse as a real client** |
| 2026-07-31 | User (standing full-control authorization for the test host) + Claude Code (install, live diagnosis, `V1-11`) | Full `V1-10` install on a freshly reimaged host, four-scenario verification sweep, then a reporting defect found and fixed | **Not a security finding — a monitoring-integrity one, and the kind only live execution produces.** `V1-10` installed cleanly on a genuinely fresh image (Tailscale login relayed to the user; every other prompt auto-answered with its default per the new standing authorization) and passed the full sweep: `rclone` bound to `100.66.43.54:65113` alone with the public IPv4 refusing connections, unauthenticated and wrong-password `PROPFIND` 401 against correct-credential 207, a `PUT` creating nothing (`--read-only` holding), `MASTER-DOCKER` at exactly the two narrow public allows (65173 tcp+udp, 65171 udp on the public IPv4 only) with `-o tailscale0 -j DROP` and **zero** Tailnet→Docker exceptions, IPv6 with no allows at all, dnsmasq bound only to `tailscale0` addresses, five `.ayc` names resolving and answering through Caddy, and — after a reboot — seven services, the timer and five containers all returning unaided with WebDAV re-binding itself. Two drift scenarios repaired correctly: `master-webdav` stopped → detected → restarted → 207; a line appended to `/etc/caddy/Caddyfile` → canonical copy restored byte-for-byte. **But reconcile exited 1 on both of them, with every repair having succeeded.** Cause: a `/setup`-screen wg-easy set `WG_CONFIGURATION_INVALID`, the same flag a genuine internal-port mismatch sets, and that flag becomes `RECOVERY_FAILED` → `exit 1`. The comment above the check already stated the intended behavior — a fresh install's `/setup` screen is expected and must not fail the run — and the code delivered it only along the `all_critical_state_healthy()` early-exit path, i.e. **exactly when reconcile did nothing**. Any pass that actually repaired something fell past that gate and reported failure. Because `master-network-reconcile.service` is the `OnFailure=` target of five other units, the effect was an operator signal that went red at the moment the system was working. Confirmed by measurement, not inference: healthy pass exit 0, both repair passes exit 1, and the first post-install timer firing (which had nothing to repair) exit 0 while printing the same `HATA` line. Fixed by splitting the expected case into `WG_SETUP_PENDING` — reported as `UYARI`, still suppressing wg-easy's automatic restart, no longer failing the run — while a real port mismatch keeps `WG_CONFIGURATION_INVALID` and keeps failing. Two doc inaccuracies corrected in the same pass: `docs/architecture.md`'s stage table had silently drifted 18 lines for stages 5–7, and its reconcile section still described the WebDAV probe as `OPTIONS`, which `V1-6` replaced with `PROPFIND` after finding rclone answers `OPTIONS` 200. Incidental: Portainer's 5-minute admin-init lock fired before the account was created (`docker restart portainer` reopens the window) — a concrete argument for the still-open wg-easy/Portainer unattended-bootstrap item. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 56/56 bats; 4984 lines. **Fix live-verified on the same host** by reinstalling `V1-11` over `V1-10` (idempotent re-run path: existing `.ayc` domain and `webdav.htpasswd` both detected and preserved, no password prompt, no Tailscale login) and replaying both drift scenarios against a wg-easy still sitting on `/setup/1` — healthy pass exit 0, `master-webdav` stopped → repaired → 207 → **exit 0**, Caddyfile drifted → restored → **exit 0**, journal now reading `UYARI` and `Ağ, firewall, container, DNS ve Caddy durumu uzlaştırıldı`, zero failed units, `--check` all fields 0 at rc 0, `--status` reporting `2026.07.31-V1-11` / `c33d84f7…` matching the local file. **Re-verified from scratch on a second reimaged host**, and the first attempt there is worth recording because it *failed to test anything*: the user completed wg-easy's web setup three minutes after the install finished (`wg-easy.db` written 12:27:22 against an install that ended 12:24:41), so all three scenarios ran against a `/login` wg-easy, `WG_SETUP_PENDING` never fired, and three `exit 0` results that the *old* code would have produced identically were briefly mistaken for evidence. Caught by noticing the redirect target had changed from `/setup/1` to `/login`. The wg-easy config was then deliberately wiped (`wg0.conf` + `wg-easy.db` removed, container restarted by exact ID) to restore `/setup/1`, and the scenarios replayed: five `UYARI: wg-easy ilk kurulumu tamamlanmamış.` lines across three runs, **zero `HATA` lines**, both repair runs printing the warning twice (the assessment plus the postcondition pass — the exact double-print signature that accompanied `exit 1` under `V1-10`), all three exiting 0, both repairs confirmed, zero failed units, `--check` rc 0. That double print against a zero exit code is the discriminating evidence: it is the same code path that failed before. **The other branch is now live-tested too**, closing the matrix: once the user completed wg-easy's web setup the failing `elif` became reachable, and `docker exec wg-easy wg set wg0 listen-port 51820` — a runtime-only change, reversible without touching `wg0.conf` — produced exactly the designed behavior: `HATA: wg-easy iç portu 51820; beklenen 65171.`, `compose_runtime=1`, `exit 1` / `rc 1`, and **no** automatic wg-easy restart, since restarting a container into the same bad configuration would achieve nothing. Restoring the port returned `exit 0`, `--check` all fields 0, and the peer (`10.8.0.2/32`) intact. So `V1-11`'s two branches are now both measured rather than one measured and one reasoned: expected-setup-pending exits 0 with `UYARI`, genuine misconfiguration exits 1 with `HATA`. Incidental from the same sweep: the first reconcile after the user's wg-easy setup reported `Container sağlık veya port binding sapması` and restarted wg-easy — a transient post-setup state, clean on the next pass with no restart stamp left behind. **Still untested: Infuse as a real client** |
| 2026-07-31 | User (asked whether re-running is safe, and whether separate upgrade/backup scripts are warranted) + Claude Code (measurement, `V1-11`, docs only) | Re-run behavior of `install.sh` against a healthy, fully configured host | **Not a finding — a measurement that replaced an assumption, including one of mine.** Re-running `install.sh` on a host with a completed wg-easy setup, a Portainer admin account and live containers took **25 seconds and restarted no container at all**: all five `StartedAt` timestamps byte-identical before and after, the wg-easy peer and `wg0` listen port intact, Portainer's `InstanceID` unchanged, `webdav.htpasswd` not rewritten, no errors in the log, `--check` rc 0. `master-webdav` was the only service restarted (PID 25946 → 68799), deliberately and unconditionally, since its unit definition or `LoadCredential` source may have changed. The reason containers survive is structural, not incidental: `master-compose.service` is `Type=oneshot` with `RemainAfterExit=yes` and **no `ExecStop`**, so Stage 5's `systemctl stop master-compose` marks the unit inactive without signalling anything, and the subsequent `docker compose up -d --wait` converges to the state already present. **Two beliefs were checked rather than asserted, and one was wrong.** The wrong one: that `docker compose pull` on a re-run could deliver an unintended version upgrade. It cannot — image tags are pinned to exact versions (`portainer-ce:2.39.5`, `wg-easy:15.3.0`, …) and, because the Compose heredoc is unquoted, those pins are expanded into the written `compose.yaml` rather than left as `.env` indirection; the host's `.env` holds only `PUBLIC_IPV4` and `TAILSCALE_IPV4`. Upgrades therefore happen only when the pins in `install.sh` change, which is reviewable in git. The one that held: **manual edits to `compose.yaml` are silently overwritten by a re-run**, a deliberate asymmetry against reconcile, which reports Compose drift but never reverts it (M10). **Conclusions recorded in `README.md` and `docs/architecture.md`:** no separate upgrade script — `install.sh` is the upgrade path, exercised in place (`V1-10` → `V1-11`), and a second script would need its own copy of the canonical unit/firewall/Compose/DNS definitions when the entire self-healing model depends on there being exactly one, and would also defeat `V1-2`'s version/hash self-reporting. On backup, the 2026-07-30 decision to close it stands: a general subsystem still fails on live-`tar` SQLite consistency and on the archive itself becoming a secret (it would contain wg-easy's WireGuard private key). What changed is that the exposure is now nameable — wg-easy's key and peers are the only expensive state, since losing them means re-provisioning every client device, while the Portainer account and qBittorrent session are minutes to recreate. `install.sh` unchanged; documentation only |
| 2026-07-31 | User (rejected the pinning proposal, chose the tag set) + Claude Code (measurement, implementation, `V1-12`/`V1-13`) | Container image version policy: exact pins → floating tags + recorded digests (`STACK_SCHEMA` 10) | **Started as the opposite proposal, and the user's rejection was correct.** The observation behind it stands: re-running `install.sh` also upgrades `docker-ce`, `tailscale` and `caddy`, because those three third-party `sources.list` entries persist from the previous run and Stage 1's `full-upgrade` sees them — Debian-sourced packages (kernel, dnsmasq, systemd) cannot jump majors on trixie stable, so they were never the exposure. Pinning the three was proposed and declined on the grounds that it trades away security updates; that reading also exposed the real inconsistency, since the containers were frozen at exact versions while the host packages were not — two opposite policies in one stack. Tags were then chosen from what the upstreams actually publish, queried rather than assumed: wg-easy `15.3` and unpackerr `0.15` (patch-level), filebrowser `v2` (major-level; no `v2.63` tag exists), portainer `lts` (LTS line; jumps a major when Portainer declares a new LTS), qbittorrent `latest` (linuxserver publishes no float tag). `lts` and `latest` were verified against the registry to resolve to the *same digests* as the exact pins they replaced, so adoption changed nothing on the day — the safest way to take on a moving tag. **The security-relevant half is the digest record, not the tag change.** A moving tag deletes the answer to "what is running": `compose.yaml` keeps its checksum while the image underneath changes, so the canonical bundle would no longer describe the running system. Five `IMAGE_DIGEST_*` keys are therefore appended to `state.env` after Stage 5 (they cannot be written with the Stage 4 heredoc — the images only exist locally once pulled), `--status` prints the short form per container and flags divergence, and **Stage 7 asserts the recorded digest equals the running one**, so the record cannot quietly drift. Auditability is preserved rather than traded. The remaining asymmetry is documented rather than solved: upgrading is safe (each container reads its existing data directory and continues) but downgrading is not, because Portainer migrates its database forward with no reverse path — re-pinning an old tag does not undo a bad upgrade. The user chose a provider-level (netcup) VPS snapshot as the rollback path over an in-script snapshot, which is the stronger choice: a whole-machine image also covers the migrated databases, and it keeps rollback outside the installer's scope. **`V1-13` exists because of a real bug in `V1-12`:** `RepoDigests` belongs to the *image* object, not the container, so `docker inspect <container>` fails with `map has no entry for key "RepoDigests"` and all five digests were written as `bilinmiyor`. **Stage 7's new assertion caught it and failed the install with `rc=1, aşama=7`** — the second time in three revisions that a Stage 7 literal assertion caught a change that `bash -n`, `shellcheck` and the full bats suite had all passed, and the reason the assertion was written to compare against the running image rather than merely check the key exists. The identical wrong lookup in `--status` was fixed in the same revision. Live-verified: 25s install, schema 10, five digests recorded and matching, `--status` showing them, `--check` rc 0, zero failed units, all five containers on their new tags. Incidental: one attempt died at Stage 5 when Docker Hub's anonymous token endpoint returned **502 Bad Gateway** during `docker compose pull` — no script fault, but the pull has no retry, so a transient registry error fails the install; filed as **L8**. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 57/57 bats (one new case covering `state_value` against an appended `IMAGE_DIGEST_*` key); 5104 lines |
| 2026-07-31 | User (approved the design, asked for measurement first) + Claude Code (measurement, implementation, `V1-14`) | **L8** — bounded retry and mandatory timeout for every network-dependent step | **The finding as filed was the smaller half of the problem.** L8 was observed when Docker Hub's anonymous token endpoint returned **502 Bad Gateway** mid-`docker compose pull` and the install died at Stage 5 with `rc=1`; the immediate re-run succeeded. A retry fixes that, but reading the surrounding code inverted the priority: `install.sh` runs under `systemd-inhibit --what=shutdown:sleep --mode=block` and holds the `flock` it shares with `master-network-reconcile`, so a **hung** download would block shutdown *and* leave the 20-minute reconcile timer unable to run, with no bound whatsoever. The 502 at least failed loudly and safely — a hang would hold two locks silently. The timeout, not the retry, is the security-relevant half. `retry_network` (three attempts, explicit per-attempt `timeout --signal=TERM --kill-after=30s`, 5s/15s backoff) now wraps `apt-get update` (four sites), the Tailscale keyring and repo list, the Docker GPG key, the Caddy GPG key and repo list, and the Compose pull. **Error classification was considered and rejected on analysis:** permanent failures (`manifest unknown`, `unauthorized`, a full disk) return within seconds, so three blind attempts cost them ~20s of backoff before the same clear error — only transient faults and hangs consume meaningful time, and those are exactly what should be retried or bounded, so matching locale-dependent upstream stderr text would add fragility for no gain. **Budgets were measured before being chosen**, per the user's instruction to measure first: cold `docker compose pull` 10.9s for 885 MB across three registries, warm pull 3.2s, `apt-get update` 0.9s, keyring fetches 36–127 ms → 300s/180s for bulk (~27× the cold-pull baseline), 60s/30s for small fetches. A hung pull is bounded at ~11 minutes instead of forever; a link would have to be ~27× slower than this host to cut a legitimate pull, and even then the operator gets a timeout message naming the budget. One measurement is worth carrying forward: **the warm pull still costs 3.2s** because it re-checks manifests at all three registries, so the pull is a hard network dependency on *every* run — including no-op re-runs, which is how a transient registry fault reached one. **Scope limits are deliberate:** `apt-get full-upgrade` and `apt-get install` are not wrapped (they drive dpkg transactions; reissuing an interrupted one is a different problem class that interacts with `--force-confdef --force-confold`), and the Caddy GPG fetch was split from its `gpg --dearmor` pipe so the retry covers only the network half — retrying a local dearmor can never fix bad input. **All four control-flow paths are verified, correcting the design note that preceded the change:** it claimed the recovery path (transient failure then success) could not be tested deterministically without a real flaky network, which was wrong — a stub that fails once and then succeeds reproduces it exactly. `test/retry_network.bats` covers first-attempt success, exhaustion, timeout (asserting exit `124` and that its message differs from an ordinary failure), recovery, and argument pass-through; it self-skips where GNU `timeout` is absent, so it skips on the macOS workstation and was run for real on the Debian target, where the **full 62-case suite passes with zero skips** — the first time that has been confirmed. Live-verified: 25s install, no retry warnings (nothing failed), `STACK_SCHEMA=10`, five digests recorded, `--check` rc 0, zero failed units, containers untouched. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 62/62 bats; 5198 lines |
| 2026-07-31 | User (asked for a reboot and a re-scan) + Claude Code (verification only) | Reboot persistence of the full `V1-14` stack, including the `V1-12`/`V1-13` digest record | **No finding — a verification record, and one gap it closes.** The host returned 56 seconds after `systemctl reboot` with all nine managed units active without intervention (`tailscaled`, `docker`, `master-compose`, `docker-tailscale-fw`, `master-webdav`, `dnsmasq`, `caddy`, `tailscale-udp-gro`, the reconcile timer), five containers up with wg-easy and filebrowser `healthy`, and zero failed units. `rclone` re-bound itself to `100.72.56.77:65113` with no manual step — unauthenticated and wrong-password `PROPFIND` 401, correct credentials 207, the public IPv4 refusing connections. The firewall rebuilt to exactly the two narrow public allows (65173 tcp+udp, 65171 udp) over the `-o tailscale0 -j DROP` / `-i eth0 -j DROP` backbone, with the `DOCKER-USER → MASTER-DOCKER` jump present exactly once and no IPv6 allows. Five `.ayc` names resolved and answered through Caddy (`webdav.ayc` 207 authenticated), the exit node was advertised, GRO flags read `off`/`on`, wg-easy's `wg0` was back on 65171 with its peer intact, and `--check` returned rc 0. **The genuinely new datum is the digest record surviving a restart:** `IMAGE_DIGEST_*` was introduced in `V1-12`, corrected in `V1-13`, and until now had only ever been exercised inside a single uptime — introduced, fixed and verified without the host ever restarting. `--status` after the reboot printed all five short digests with **no divergence marker**, so `state.env`'s record still matches the running images across a full restart. That is the property the record exists for, and it had not previously been tested. `install.sh` unchanged; documentation only |
| 2026-07-31 | User (asked what remained in **M7** besides CI wiring) + Claude Code (re-survey, test authoring) | **M7** Tier 2 coverage inventory — re-surveyed and corrected | **The answer to the question was that the entry was wrong.** `M7` had stated since 2026-07-28 that "remaining scope is CI wiring only", written against a ~4550-line script; by 2026-07-31 `install.sh` was 5198 lines and nothing had folded the functions added or grown since back into the inventory. Enumerating the embedded scripts found 35 functions in the reconcile heredoc with 3 covered, and 20 in the firewall helper with 8 covered. Most of the gap is legitimately integration-shaped (`http_endpoint_responds`, `webdav_direct_ok`, `caddy_runtime_ok`, `dns_listeners_ok`, `tailscale_online`, `check_compose_runtime` — all needing real network, systemd or Docker), so the original survey's judgement holds for those. But three were plainly unit-testable and had no coverage: **`restart_budget_available`**, the 15-minute per-container cooldown that decides whether a detected drift is actually repaired — and whose mismatch with the then-5-minute timer is precisely what motivated DD-21, so a constant that drove a design decision had no test behind it; **`disk_space_ok`**, whose threshold comparison is strict (`<`), making the boundary case a silent-drift candidate, and which must fail closed on unparseable `df` output; and **`all_critical_state_healthy`**, entirely pure — twenty flags, one test expression, no external calls — and the early-exit gate implicated in `V1-11`'s exit-code defect. Twelve cases were added (suite 62 → **74, zero skips on the Debian target**, confirmed by running it there). Two notes on test quality rather than product quality: the `all_critical_state_healthy` suite includes a guard case asserting its fixture flag list equals the flags the function actually reads, so a flag added to the reconcile pass but omitted from the gate surfaces instead of silently shrinking what the loop covers — and that guard was validated by deliberately shortening the list and confirming it fails, rather than assumed non-vacuous; and the first `df` stub was built with `printf`, where the stubbed percentage's `%` was read as a format specifier, emitting an error while still passing because `disk_space_ok`'s `tr -dc '0-9'` cleaned up the mangled output — a helper quietly testing the wrong string, rewritten with `echo`. Honest scope statement: `all_critical_state_healthy`'s tests would **not** have caught `V1-11`, whose defect lay in a condition that influenced the exit code without being part of this gate; they pin the invariant that would make a repeat visible, which is a weaker but real claim. This is the third documentation-accuracy defect found on 2026-07-31, after `docs/architecture.md`'s 18-line stage-table drift and its stale `OPTIONS` description of the WebDAV probe — a pattern worth noting in its own right: three separate docs asserted things the code no longer did. `install.sh` unchanged; tests and documentation only |
| 2026-07-31 | User (asked for the duplicated cooldown to be fixed) + Claude Code (implementation, `V1-15`, DD-25) | The repair-cooldown constant duplicated across two embedded scripts and three operator-facing messages | **Investigating first changed what the fix should be.** The duplication was larger than reported: besides `RESTART_COOLDOWN_SECONDS=900` in `master-network-reconcile` and `COOLDOWN_SECONDS=900` in `master-docker-netfilter-recovery`, the figure "15 dakikalık cooldown" was hardcoded as prose in **three** error messages, and `StartLimitIntervalSec=900` appeared in three systemd units. The last group was deliberately left alone — same value, different mechanism (systemd's start-rate limiter is not the repair budget), and folding them together would invent a coupling that does not exist. **The two code copies were kept, and that is the decision rather than a compromise:** every embedded script must be self-contained because `scripts/lint-embedded-scripts.sh` extracts each by its heredoc marker and runs `bash -n` + `shellcheck` on it as a standalone program — the mechanism that answers **H4**, since `shellcheck install.sh` sees these bodies only as string data. Binding both to a shared variable, or splitting a heredoc so an unquoted prelude could interpolate one, would leave the linted fragment referencing a variable it never assigns, trading a real property (the linter checks exactly what ships) for a cosmetic one. What the duplication actually risked was never the second copy but *silent* divergence, and DD-21 makes that concrete: the reconcile timer was moved to 20 minutes specifically to stop fighting this cooldown, so the two numbers are coupled by a design decision and one could have been changed with the other quietly left behind. `install.sh` now declares `MASTER_RESTART_COOLDOWN_SECONDS` as the single source of truth and **Stage 7 asserts all three agree**, printing all three values on mismatch. The three prose copies were removed outright — the messages now derive the figure via `$((RESTART_COOLDOWN_SECONDS / 60))`, so operator-facing text cannot contradict behaviour. **The assertion was verified to discriminate rather than assumed to:** a copy of `install.sh` with the recovery constant set to `800` was installed on the test host and failed at Stage 7 with `install.sh : 900 / reconcile : 900 / recovery : 800`, after which the real version reinstalled clean — the same discipline applied to the `all_critical_state_healthy` coverage guard earlier the same day, on the principle that a guard nobody has watched fail is not yet known to work. Live-verified: 40s install, `--check` rc 0, zero failed units, all three constants reading 900 on the host. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 74/74 bats; 5249 lines |
| 2026-07-31 | User (deleted the node from the Tailscale panel so the path could be exercised) + Claude Code (verification, `V1-18`) | Stage 2's deleted-node diagnosis, live-verified | **Closes a "not live-verified" caveat rather than adding a finding.** `V1-18` taught Stage 2 to distinguish a deleted tailnet node from an unreachable control plane or an expired key, all three of which had produced one message. It shipped unverified on purpose: exercising it requires deleting the node from the Tailscale admin panel, which is account-level and outside the standing authorization for the test host, so the user performed that step. The re-run then produced the intended branch exactly — `NEDEN: Kontrol düzlemi bu düğümü tanımıyor (404 node not found).` followed by the `tailscale logout && bash /root/master.sh` remedy — with the generic network/profile branch correctly not taken, and the install stopping at `rc=1, aşama=2` without leaving the host half-configured. **The measured local state is the reason the message is worth its lines:** `tailscale ip -4` returned `100.86.105.27`, `tailscaled` was `active`, and `BackendState` read `Running` — three healthy indicators out of four. Only `Online: false` and seven `node not found` lines in journald revealed anything wrong, and an operator following the old message would have been sent to check network reachability and profile validity, both of which were perfect. `install.sh` unchanged since `V1-18`; documentation only |
| 2026-07-31 | User (reimaged the host, ran the install, asked for a check) + Claude Code (verification) | Fresh `V1-20` install on a reimaged host | **No finding.** A from-scratch install of `V1-20` verified green across the board: `STACK_VERSION=2026.07.31-V1-20`, `STACK_SCHEMA=10`, five `IMAGE_DIGEST_*` keys recorded, nine managed units active, five containers, zero failed units, `--check` every field 0 at `rc 0`, and the deployed `/root/master.sh` hashing `06c9918a…` identically to the repository and the `versiyon/` export. WebDAV listened on the Tailscale IPv4 alone with the public IPv4 refusing connections; five `.ayc` names resolved and answered through Caddy; `MASTER-DOCKER` carried exactly the two narrow public allows over the `-i eth0 -j DROP` backbone with a single `DOCKER-USER` jump and no IPv6 allows; the exit node was advertised and GRO read `off`/`on`. Two observations rather than defects. First, `--check` printed `UYARI: wg-easy ilk kurulumu tamamlanmamış` and still returned `rc 0` — `V1-11`'s fix behaving correctly on a fresh install, where that condition is expected until the operator opens `wg.ayc`. Second, WebDAV returned 401 for the credential this session had been using: `stat` showed `webdav.htpasswd` created at 21:05:29 during this very install rather than preserved from an earlier one, so the password was simply the one the operator typed at Stage 0 and not the session's `12345test` convention — the service was enforcing exactly what it was given. `install.sh` unchanged since `V1-20`; documentation only |
| 2026-08-01 | User (configured wg-easy, qBittorrent and the panels, then asked for a usage-path test) + Claude Code (measurement, `Q1-2`, DD-28) | First end-to-end test of the *usage* path, not just the install path | **No security finding — one functional defect fixed, and the project's longest-standing unknown finally closed.** Every prior verification in this repository had covered installation and service liveness; what the system is actually *for* — serving a media tree to Infuse over WebDAV while qBittorrent and unpackerr write into it — had never been exercised. **Byte-range requests work correctly**: a 50 MB file was fetched at three offsets (start, middle, last 100 bytes), each returning 206 with content verified byte-for-byte against `dd` reads of the source, alongside `Content-Length: 52428800` and `Accept-Ranges: bytes`. That closes an unknown tracked since `V1` and is the first evidence that seeking works at all. **The defect found sits between the producer and the consumer:** `rclone serve webdav` was on its 5-minute `--dir-cache-time` default, so a file created in the media tree was invisible over WebDAV at t+0s, t+5s and t+10s while FileBrowser Quantum showed it immediately — a finished download or extracted archive could be absent from Infuse for five minutes with nothing wrong and nothing in any log. Fixed with `--dir-cache-time 1m`; `--poll-interval` was evaluated and rejected on measurement rather than intuition, since `rclone backend features` reports `ChangeNotify: false` for a local directory and rclone's own help scopes that flag to supported remotes. **One methodology error is recorded because it nearly passed:** the first verification appeared to show instant visibility, but the install had just restarted `master-webdav` and the cache was cold, so the first request read from disk and measured nothing. Re-run correctly — warm the cache, create the file, then poll — the delay was 33 seconds, consistent with a one-minute entry partway through its life. **Everything else measured clean under real configuration:** wg-easy configured and past its setup screen with the port, INPUT rule and peer all correct and no recurrence of the transient rule drift seen on 2026-08-01's earlier host; Portainer initialised; Quantum holding exactly one admin with `admin/admin` still closed; twenty reconcile cycles completed with **zero repair stamps**, meaning nothing has needed repair since install; `--check` `rc 0`; zero failed units; canonical manifest 8/8. **qBittorrent's socket buffer is confirmed capped and the configured number is meaningless:** the operator set 670756864 (~640 MiB) and the socket reports `rb134217728`, exactly `2 × net.core.rmem_max` — the same value it reported at a 128 MiB setting, proving the request is clipped to the 64 MiB ceiling and doubled for accounting regardless of what is asked for. No drops at either setting (`RcvbufErrors 0`, `SndbufErrors 0`). `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 74/74 bats; install re-run end to end on the live host after the change |
| 2026-08-01 | User (decided to leave the account to the container after reviewing upstream's behaviour) + Claude Code (source reading, `Q1-3`, DD-27 revision) | FileBrowser Quantum's initial admin account: installer bootstrap removed | **A deliberate acceptance of a known exposure, with the reasoning recorded — and the change removed a latent bug rather than only simplifying.** The installer had been overwriting Quantum's default credential with the Stage 0 password. Reading upstream's source rather than inferring from behaviour settled what it actually does: `quickSetup()` is called only `if !exists` (no database present), takes `admin`/`admin` from a hardcoded fallback when no password is configured, is **never re-asserted on subsequent starts**, and sets `ShowFirstLogin` so the UI prompts on first login without compelling a change. That is upstream's design, and the operator chose to keep it: the account is changed by hand immediately after install, exactly as Portainer and wg-easy already are. **The exposure is real and is now stated rather than engineered away:** unlike those two, which ship with no account at all, Quantum ships a *working* login, so until it is changed any device on the tailnet has full read-write access to the media tree. The install summary promotes this to the first post-install action and says the container owns the account. **The decisive argument turned out to be behavioural, not cosmetic.** The removed code ran whenever Stage 0 re-collected credentials, which means a re-run would have silently reset a password the operator had already changed in the UI — a quiet regression of the operator's own security action, and precisely the class of thing that would have been discovered only by someone wondering why their password stopped working. Upstream's `if !exists` guard gets this right for free; verified by changing the password, re-running the full installer, and confirming the new password survived while `admin`/`admin` stayed refused. **`minLength` was forced from 8 back to upstream's 5.** `admin` is exactly five characters, so 8 makes `quickSetup()` die with `[FATAL] store.Users.Save: password must be at least 8 characters long`, leaving a container that Docker reports healthy, the reconcile probe answers 200 for, and `--check` passes — with no user account and no way in. Measured, not theorised. **`FILEBROWSER_ADMIN_PASSWORD` was found in upstream's `loadEnvConfig()` and rejected on its merits:** it would place a plaintext secret in `compose.yaml`, which is `0600 root:root` and inside the canonical bundle but still readable through `docker inspect` and the container's own `/proc/1/environ`. Net effect on the codebase: ~20 lines of Stage 5 removed along with the `docker stop` it needed, the Stage 7 assertion removed, and `WEBDAV_PASSWORD` returned to being cleared in Stage 4 rather than living an extra stage. Live-verified on an emptied volume — zero FATALs, zero restarts, one user carrying `showFirstLogin: true`, `--check` `rc 0`, zero failed units — plus a re-run against the running stack, which the previous implementation had failed with `the database is locked`. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 74/74 bats; 5422 lines |
| 2026-08-01 | User (asked for the read_only test) + Claude Code (measurement, `Q1-4`, DD-27 revision) | `read_only: true` for FileBrowser Quantum — a hardening that had been dismissed without measurement | **A security control recovered, and a methodology failure of mine corrected.** DD-27 recorded that `read_only: true` was "impossible" for Quantum because it is stateful. That was an *inference* from the image declaring a database path, never a measurement — and it is exactly the shortcut this project has otherwise refused to take: `read_only` was added to unpackerr because it was tried and worked, and removed from qBittorrent because it was tried and broke `PUID`/`PGID` handling. Quantum got the conclusion without the experiment. **Measured, the claim collapses:** `docker diff` showed every write outside the volume landing under one directory, `/home/filebrowser/tmp`, holding the search index, thumbnails, diskcache and generated PWA icons — and `server.cacheDir` is a configurable key. Redirecting it to `/home/filebrowser/data/cache` places the cache inside the named volume that already exists, after which the root filesystem needs no write access at all. **Writable-layer changes fell from 18 to 1**, the survivor being the read-only bind mount's own entry, with login, listing and writes to the media tree all unchanged. **A tmpfs was tried first and rejected on evidence rather than taste:** Quantum recommends at least 20 GB free for the cache and emitted `cacheDir only has 0.25 GB of free space` against a 256 MB tmpfs; thumbnail generation across a real media library is not a RAM-resident workload, and sizing a tmpfs for it on this host is not possible. **An unnoticed defect was fixed in passing:** because the cache had been living in the container's writable layer, the search index and every generated thumbnail were destroyed each time the container was recreated — routine during any re-run. They now persist, verified across a reboot. Net security position: the `read_only` hardening that `V2-2`'s dufs provided, and that this branch was documented as having surrendered, is restored — `cap_drop: [ALL]`, `no-new-privileges`, non-root UID and now a read-only root. The only property that genuinely does not carry over from dufs is statelessness itself. Verified three ways, each with zero FATALs, zero container restarts and `--check` `rc 0`: an install over the existing volume, a fresh install with the volume deleted, and a reboot — which also confirmed the operator's changed admin password survives an installer re-run untouched. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 74/74 bats |
| 2026-08-01 | User (asked to work through the reconcile suggestions in order) + Claude Code (measurement, `Q1-5`/`Q1-6`, DD-29) | The single host state that re-running `install.sh` could not repair | **A robustness defect found while testing a *different* proposal, and the proposal itself withdrawn as a result.** The suggestion under examination was that reconcile should detect a deleted policy file, on the theory that Quantum would silently fall back to the image's bundled config. Measuring it disproved the theory — Quantum fails validation with `Settings.Server.Sources ... required` and stops serving, which reconcile already catches via `compose_runtime=1` and the HTTP probe — but the measurement surfaced something worse in its place. When the policy file is absent, **Docker creates a directory** at the bind-mount source, and the installer's `mv -f "$tmp" "$target"` then *succeeds silently by moving the new config inside that directory*. The bind mount stays a directory, the service stays broken, and each additional re-run simply accumulates another file inside — so the project's standing remedy, "run `install.sh` again", was inert against this one state. That matters beyond this file: re-runnability is what every other repair path in this system ultimately depends on. **The first fix was incomplete and only live testing revealed it.** Normalising the host path left the install failing at stage 5, because a container created with a *directory* at `/config.yaml` records that mount type and `runc` rejects the corrected file with `not a directory: Are you trying to mount a directory onto a file (or vice-versa)?`, producing a restart loop rather than a recovery. `Q1-6` therefore removes the container as well, letting compose recreate it with a clean mount spec; nothing persistent is at risk because state lives in the `filebrowser_data` volume, which outlives the container. **Scope was checked rather than assumed:** `${QUANTUM_CONFIG_FILE}` is the only single-*file* bind mount in the stack — every other is a directory, where Docker creating one is the correct behaviour, and `webdav.htpasswd` reaches its service through systemd `LoadCredential`, which fails loudly on a missing file. Verified by reproducing the broken state deliberately (directory at the config path, container up but serving nothing, `--check` `rc 1`) and repairing it with one installer run: file restored, container healthy at `RestartCount 0`, HTTP 200, admin login 200, `--check` `rc 0`, zero failed units. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 74/74 bats |
| 2026-08-01 | User (asked to work through the reconcile proposals in order) + Claude Code (`Q1-7`, DD-30) | Reconcile now reports a still-default filebrowser admin password | **A monitoring gap closed for a property that can regress silently after install.** DD-27 deliberately leaves the initial account to the container, so `admin`/`admin` on a fresh install is expected rather than a fault — but it can *return* later: deleting the volume or recreating the container makes Quantum re-run `quickSetup()` and restore the default, and **no existing signal detects that**. Docker reports the container healthy, the reconcile HTTP probe collects its 200, and `--check` comes back clean while a working default credential sits on the tailnet with full read-write access to the media tree. A twenty-minute loop that already reports unfinished operator steps is the right place for it. **Deliberately a warning, not a failure.** Failing would make every fresh install return `rc 1` until someone changed the password, which teaches operators to disregard the exit code — the exact degradation `V1-11` was fixed to prevent. The implementation mirrors wg-easy's `WG_SETUP_PENDING` in shape and rationale, with one difference recorded in the comment: wg-easy keeps a flag because it is read, to suppress a futile restart, whereas here nothing can be suppressed since restarting a container does not change a password. The first draft carried a flag anyway and `shellcheck` rejected it (SC2034) — the unread variable was removed rather than given a contrived use. **A less invasive check was sought and does not exist**, which is worth recording so it is not re-proposed: the user object's `showFirstLogin` tracks whether the first-login notice has been shown, not whether the password changed, and was measured as already `false` on a host still authenticating with `admin` — so it would produce false negatives for precisely the operator who dismissed the prompt without acting. The real check costs one log line per cycle (72/day against a `json-file` driver capped at 10 MB × 3). One incidental defect was found and fixed during verification: the warning's second line interpolated `${LOCAL_DOMAIN}` literally, because it had been escaped inside a heredoc that is already quoted and performs no expansion — caught by reading the rendered `--status` output rather than by any tool. Verified in both directions: with the default password the warning appears in `--check`, in `--status`, and in the timer-driven run's journal, at `rc 0` with `compose_runtime=0`; after changing the password it goes silent, still `rc 0`, zero failed units. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 74/74 bats |
| 2026-08-01 | User (asked to work through the reconcile proposals in order) + Claude Code (`Q1-8`, DD-31) | Reconcile now checks inode exhaustion alongside byte usage | **A monitoring blind spot, demonstrated rather than argued.** `disk_space_ok()` has watched byte usage on `$DOWNLOADS_PATH` since 2026-07-28, and `df -i` is one flag away from the `df` it already runs, but inodes were never looked at. The two are genuinely different resources: ext4 fixes its inode table at `mkfs` time, so a tree of many small files — precisely what a torrent client produces — can exhaust it while the filesystem is nearly empty. This was measured on the Debian target rather than asserted: a 32 MB image made with `-N 64`, filled with 52 empty files, read **1% used in bytes and 100% used in inodes**, with the existing check returning healthy on it while `touch` returned `ENOSPC`. **Deliberately a separate flag and a separate message**, not folded into `DISK_SPACE_LOW`, because the remedy inverts the operator's intuition: deleting large files frees bytes and no inodes whatsoever, and someone reading "filesystem over 90% full" against a `df -h` showing hundreds of free gigabytes would reasonably conclude the monitor was broken. The message names the resource and states that many small files must go. **The subtler half of the change is the `-` branch.** Filesystems that allocate inodes dynamically report `-` in the `IUse%` column; the byte check's parse (`tr -dc '0-9'`) reduces that to an empty string, and its fail-closed rule turns an empty string into a warning — so a naive copy of the byte check would have raised a permanent, unfixable alarm every twenty minutes on every btrfs host. That behaviour was confirmed by measurement on the target (btrfs loop device: `IUse%` is `-`; the same command on ext4 gives `1%`) before the guard was written, and the distinction is drawn by testing the raw field *before* filtering digits, so genuinely unparseable output still fails closed. The change is wired through detection, `all_critical_state_healthy`, `--check`, `--status`, and the post-repair postcondition; the `all_critical_state_healthy` fixture guard added on 2026-07-31 fired on the new flag, its first real (rather than deliberately induced) catch. Live-verified end to end on the target: `inode_space_low=1` in `--check`, the message rendered, `rc 1` with the postcondition failing, and `rc 0` restored with the real `df`. One wording defect was caught by reading the rendered output — the Turkish message was ungrammatical (`%90 üzerini kullanılmış`) and was corrected. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 5 bats cases added including the `-` case, **74 → 79** |
| 2026-08-02 | User (asked for a fresh critical review of `Q1-8`) + Claude Code (`Q1-9`, DD-32) | The FileBrowser Quantum policy file was outside drift detection | **A generated security-policy file that nothing verified, found by reading the file end to end and confirmed by measurement.** `/etc/master-stack/filebrowser.yaml` is written on every install run and is the only place the stack's file-manager policy lives — including `signup: false`, whose whole justification in the code comment is that self-signup was the mechanism of the original filebrowser's worst unpatched vulnerability (GHSA-6759, critical). It was in none of reconcile's checks: not in the canonical bundle's eight manifest entries, not in `config_files_ok`, and its name did not appear anywhere in the 1540-line reconcile script. **Measured rather than argued**: flipping `signup: false` to `true` on the live host left `config=0`, `state_config=0`, `compose_file=0`, `compose_runtime=0` and `rc=0` — every signal clean — and restarting the container took the change live, `/api/auth/signup` moving from `405` (route absent) to `400` (route present, payload rejected). The drift was therefore both invisible **and** self-activating, since reconcile restarts containers as part of routine repair. **The gap was specific to this line and explains why nothing caught it**: `V1-20` kept filebrowser's settings in the `filebrowser_config` volume, so there was no host file to drift; DD-27 moved policy onto the host and the file never joined the bundle, and nothing cross-checks bundle membership against the set of files install.sh generates. It is now the ninth manifest entry, verified and restored on the dnsmasq/Caddy pattern rather than the report-only `compose.yaml` pattern — that exception does not transfer, because restoring this file *does* fix the policy the container will load and there is no legitimate operator edit to preserve. The restore is followed by a budgeted container restart, since Quantum reads its config only at startup and nothing from outside distinguishes "drifted file already loaded" from "not yet loaded"; the property guaranteed is that the policy in force equals the canonical copy. **A defect of the `V1-11` class was introduced and caught during live testing**: the first version waited only for HTTP after the restart and returned `rc 1` on a repair that had succeeded. Measured cause — the Quantum image carries its own `HEALTHCHECK` (`start_period 10s`) and after a restart HTTP answers at t+2s while health reaches `healthy` at t+5s, so the wait exited inside that window and the final postcondition caught `starting`. The wait now requires both signals, matching exactly what `check_compose_runtime` applies to filebrowser. **Unplanned secondary fix**: DD-29 recorded a deleted policy file as the single state a re-run could not repair, because Docker recreates a missing bind-mount source as a directory; reconcile now restores the file within twenty minutes, ahead of any container recreate — verified by deleting it and confirming one run restored it at `0644 root:root` with the container healthy and `rc 0`. Live-verified end to end on the Debian target across two full installs: nine-entry manifest, clean `--check`, drift detected (`quantum_config=1`, `rc 1`), repaired via the systemd timer path with `rc 0` in 10 seconds, `/api/auth/signup` back to `405`, zero failed units. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 79/79 bats, with the existing bundle-list guard firing on the 8→9 change as designed | **Three findings from the same review remain open** and are recorded here so they are not lost: (1) the default-password probe reads a throttled response as healthy — Quantum returns `429` after 6 failed logins from a source IP, the correct password also returns `429`, and the check only warns on `200`, so it fails open exactly when someone has been hammering the login; the probe's source is the docker bridge gateway `172.18.0.1`, the same source as every Caddy-proxied browser login, so the bucket is shared with the operator (window measured between 3 and 8 minutes of silence); (2) `check_compose_runtime` has four call sites, so a drifted cycle performs up to four login attempts rather than the one DD-30 claims; (3) the Stage 4 progress note still reads "Altı container" where there are five — fixed on `master`, never carried to `quantum` |
| 2026-08-02 | User (asked what to do next after `Q1-9`) + Claude Code (`Q1-10`, DD-33) | The default-password probe failed open on `429` and ran four times a cycle | **Two of the three findings left open by the `Q1-9` row, closed together because the second makes the first worse.** The DD-30 check warned only on `200`, so a rate-limited `429` fell through the same silent path as an ordinary `401` — the check reported nothing wrong at precisely the moment someone was hammering the login screen. That is a security check failing open, which is worse than no check, because a clean `--check` is trusted. **The rate limiter was measured, not assumed**: Quantum's `POST /api/auth/login` buckets on **source IP, not on the credential** — after 6 failures it returns `429`, and from then on the *correct* password also returns `429`, with the window measured between 3 and 8 minutes of silence. The probe's source is `172.18.0.1`, the docker bridge gateway, which is also where every Caddy-proxied browser login arrives, so reconcile and the operator share one bucket. **Those numbers are what makes the second finding structural rather than cosmetic**: the probe lived inside `check_compose_runtime`, which a single cycle calls up to four times (initial detection, the one-second retry, the post-repair check, and the final postcondition), so a drifted cycle spent four of the bucket's six attempts and left the operator two — and reconcile could trip the limit unaided, then read its own `429` as healthy. The probe is now `report_default_filebrowser_password()`, called exactly once from the main flow; at one attempt per 20-minute cycle it cannot accumulate, because the timer interval exceeds the longest measured window. A guard variable was rejected in favour of extraction: an "already probed" flag would have to survive four call sites and reset per cycle, which is state to get wrong for no benefit, and the probe never belonged among the container-runtime checks in the first place. The `429` branch reports explicitly that the check could not be performed and that this does **not** mean the password was changed — reported, never counted, on the same `rc 0` contract as DD-30, since a self-clearing condition the operator cannot act on must not produce `rc 1` (the `V1-11` lesson). Live-verified on the target across all four paths: clean (`rc 0`, one attempt, down from four on a drifted cycle), drifted (still one attempt), throttled (the `429` message, `rc 0`), and the regression case with `filebrowser_data` deleted so `quickSetup()` restored `admin`/`admin` (warning fires, `rc 0` in both the direct run and `--check`). Then confirmed end to end: full install to `KURULUM TAMAMLANDI` with all seven stages, reconcile triggered through systemd with `Result=success`, `ExecMainStatus=0`, the warning appearing exactly once in the journal, and zero failed units. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 79/79 bats. **One finding from the `Q1-9` review remains open**: the Stage 4 progress note still reads "Altı container" where there are five — fixed on `master`, never carried to `quantum` |
| 2026-08-02 | Claude Code (`Q1-11`) | Stage 4 progress note miscounted the bundle | **The last finding left open by the `Q1-9` review, and the smallest.** `progress_stage_note 45` read "Altı container için Compose tanımı yazıldı" — six — where the generated `compose.yaml` defines five services (`portainer`, `filebrowser`, `qbittorrent`, `unpackerr`, `wg-easy`; the sixth `wg:` in the file is the network, not a container). The count was correct before the sixth service was dropped, was fixed on `master`, and the fix was never carried across to `quantum`. Verified against both the generated compose services and reconcile's own `expected_containers` list, which has always said five. Cosmetic — it is a progress line, and nothing reads the number — but a stated count that disagrees with the thing it counts is the kind of detail an operator uses to decide whether the rest of the output can be trusted. `bash -n`, `shellcheck`, `scripts/lint-embedded-scripts.sh` clean; 79/79 bats. **No findings from the `Q1-8` review remain open** |
| 2026-08-02 | User (asked what remained unexamined) + Claude Code (`test/generated_files_bundled.bats`) | Nothing compared "files install.sh generates" against "files the bundle covers" | **The structural gap behind `Q1-9`, closed as a test rather than as another one-off fix.** The `Q1-9` row records the Quantum policy file being outside drift detection; it does not record why nothing caught it. `test/canonical_bundle.bats` verifies that Stage 6's manifest and `canonical_bundle_ok`'s expected list agree with **each other** — a genuine coupling, and the one that broke in **M8**/**M10** — but two lists agreeing is silent about what is absent from both, so no possible addition to that suite could have found `filebrowser.yaml`. The new suite supplies the third side of the triangle: install.sh's own write operations. The generated set is derived from `cat >` destinations plus the atomic `mktemp`/`mv -f` pattern, read from a copy of install.sh with **every heredoc body stripped first** — without that step the `install -m` calls inside the reconcile heredoc, which run on the target rather than during install, would be counted as install.sh's own and the derivation would be quietly wrong in the safe-looking direction. `$VAR` destinations resolve through install.sh's literal assignments. **The allowlist is the substantive part.** 32 generated files: 9 bundled, 23 excluded under four separately stated reasons — the manifest cannot hash itself; secrets and host-measured values have no canonical content (`webdav.htpasswd`, `/root/docker/.env`, and `daemon.json`, which install.sh merges with `jq` rather than generating); the helper scripts reconcile executes and the units invoking them are verified by being run, per **M10**'s recorded reasoning; and boot-time configuration is verified by its effect (`forwarding_config_ok` asserts the two lines that matter and tolerates unrelated edits, `forwarding_ok` and `gro_flags_ok` read live state), which is stronger than a hash. Adding a generated file now fails the suite until someone decides in writing which side it belongs on. **Mutation-verified, all five assertions independently, on scratch copies**: a new uncovered generated file, a full revert of `Q1-9` (both the publish and the manifest entry removed), an entry dropped from `sha256sum` only, a file deleted while still on the allowlist, and a foreign file published into the bundle. Each mutation trips exactly one assertion and no others; the `Q1-9` revert is the load-bearing case, since it proves the suite fails on the real historical defect rather than on a synthetic one. **One inconsistency surfaced while writing the allowlist and is recorded there rather than silently resolved**: `docker.service.d/99-tailscale-forward.conf` and `tailscaled.service.d/98-master-stack.conf` are generated, verified once by Stage 7's dependency-graph assertions and never again — their names do not appear anywhere in the 1659-line reconcile script — while three of the other five generated drop-ins are bundled and restored with a `daemon-reload`. Losing the docker drop-in means Docker starts without pulling `docker-tailscale-fw`, which surfaces up to twenty minutes later as firewall *policy* drift rather than as a missing file, so the consequence is bounded but the diagnosis is misleading. Left on the allowlist as an open question for the user, not decided unilaterally. No change to `install.sh`; 79 → 84 bats cases, verified on the Debian target with **zero skips** as well as on the workstation |
