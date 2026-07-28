# TODO

Tasks derived from the 2026-07-27 static audit in `SECURITY_REVIEW.md`
(18 findings total, not 19 — an earlier miscount was corrected).
`install.sh` line references below were refreshed after fifteen numbered
remediations (**C2**, **M6**, **M5**, **H1**, **H2**, **H3**, **M4**,
**L1**, **L2**, **L4**, **L5**, **M2**, **L3**, **C1**, **H4**) plus one
unnumbered cleanup (legacy reboot-timer removal) and one partial
remediation (**M1** — see below); file is now 4275 lines. Do not start
work on any item without explicit user approval (per `CLAUDE.md`).

## Critical

_All Critical findings resolved — see Completed below._

## High

_All High findings resolved — see Completed below._

## Medium

- [ ] 🟡 **M1** (partially done, 2026-07-28) — `no-new-privileges` and
      `mem_limit`/`cpus` (2g/2.0 for `qbittorrent`, 512m/1.0 for
      `unpackerr`, sized against the user's 4 CPU/8 GB host) are applied.
      Remaining: `cap_drop: [ALL]` for both — deferred to the live SSH
      test, since `qbittorrent`'s linuxserver.io entrypoint runs a
      root-level init (for `PUID`/`PGID` volume-ownership fixing) that
      likely needs some capabilities (`CHOWN`, `SETUID`, `SETGID`,
      `DAC_OVERRIDE`, `FOWNER`?) added back — verify empirically, then
      apply the minimal working set. `unpackerr` (already non-root) is
      likely safe with a bare `cap_drop: [ALL]`, also to be confirmed live.
      `read_only: true` root filesystem was discussed and intentionally
      not pursued (see `SECURITY_REVIEW.md`).
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
      integration-shaped, likely Tier 3 instead); Tier 3 (disposable-VM
      integration test); CI wiring. See `docs/testing.md`.

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
