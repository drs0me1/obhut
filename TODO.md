# TODO

Tasks derived from the 2026-07-27 static audit in `SECURITY_REVIEW.md`
(18 findings total, not 19 — an earlier miscount was corrected), plus
three additional findings (**H5**, **H6**, **H7**) discovered 2026-07-28
— the first two via live Tier 3 install tests, **H7** via real post-R1.0
usage.
`install.sh` line references below were refreshed after sixteen numbered
remediations (**C2**, **M6**, **M5**, **H1**, **H2**, **H3**, **M4**,
**L1**, **L2**, **L4**, **L5**, **M2**, **L3**, **C1**, **H4**, **M1**), a
regression fix to **H1** plus the new **H5**/**H6**/**H7** fixes, one
unnumbered cleanup (legacy reboot-timer removal), and a new disk-space
monitoring check added to `master-network-reconcile` after a final
architecture review; file is now 4365 lines. Originally **tagged R1.0**
(2026-07-28) before **H7** was found — the tag itself is not moved/
retagged; **H7** is simply the first fix that postdates it (v1.1 work).
Do not start work on any item without explicit user approval (per
`CLAUDE.md`).

## Critical

_All Critical findings resolved — see Completed below._

## High

_All High findings resolved — see Completed below._

## Medium

- [ ] **M3** — Scope and design an opt-in/opt-out installation profile
      model (see `docs/profiles.md`) before implementing any change to
      the fixed six-service bundle.
- [ ] 🟡 **M7** (partially done, 2026-07-28) — Tier 1 (static analysis,
      see **H4**) done. Tier 2 in progress: `test/reconcile_functions.bats`
      covers `state_value`/`owned_file_ok` (7 cases; 2 self-skip on this
      macOS dev workstation's non-GNU `stat`); `test/firewall_functions.bats`
      covers `route_value`, `chain_rules_exact`, `jump_is_first_and_single`,
      `forward_prefix_is_exact`, `docker_forward_has_no_terminal_drop`,
      `no_stale_staging_chains` (20 cases) via a fake iptables/`ip`
      stand-in; `test/gro_functions.bats` covers `tailscale-udp-gro`'s
      `add_default_netdev` (5 cases, all self-skipping on this
      workstation's bash 3.2, which lacks associative arrays — runs for
      real on the Debian target's bash 5.x) — 32 cases total. The other
      three remaining embedded scripts (`master-compose-ipv4`,
      `master-docker-netfilter-recovery`, `caddy-tailnet-env`) were
      surveyed and found to have no standalone pure-logic functions worth
      unit-testing — each is essentially a wait loop plus real side
      effects. Remaining: `check_ipv4_policy`/`check_ipv6_policy` (more
      integration-shaped, likely Tier 3 instead); CI wiring. Tier 3 itself
      had three real attempts on 2026-07-28 (see Completed below and
      `docs/testing.md`) — found and fixed three real bugs (**H1**
      regression, **H5**, **H6**) across the first two, then the third
      attempt completed all 7 stages successfully end-to-end, the first
      fully clean install of this repo's `install.sh`.

## Low

_All Low findings resolved — see Completed below._

## Completed

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
- [x] **H7 (new finding, resolved, 2026-07-28, first v1.1 fix).** Found
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
