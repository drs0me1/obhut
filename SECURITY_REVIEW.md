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
`install.sh` is now 4449 lines (unchanged by **H4**, which only added a new
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
was likewise closed as won't-do on 2026-07-28, leaving **M7** as the
only open finding in the project.

| Severity | Open | Resolved |
|----------|------|----------|
| Critical | 0 | 2 (**C2**, 2026-07-27; **C1**, 2026-07-28) |
| High     | 0 | 7 (**H1**, **H2**, **H3**, 2026-07-27; **H4**, 2026-07-28; **H5**, **H6**, **H7**, 2026-07-28 — post-audit) |
| Medium   | 1 (**M7**) | 9 (**M6**, **M5**, **M4**, 2026-07-27; **M2**, **M1**, **M8**, **M9**, **M10**, **M3**, 2026-07-28) |
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
  8 run with no skips on any POSIX host. 40 cases total across `test/`.
- **Remaining:** `check_ipv4_policy`/`check_ipv6_policy` (composite
  functions coupled to real global state, more integration-shaped — left
  for Tier 3 instead); Tier 3 (disposable-VM integration testing); CI
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
