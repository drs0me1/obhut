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
architecture review; file is now 4996 lines (V1-5). Originally **tagged R1.0**
(2026-07-28) before **H7** was found — the tag itself is not moved/
retagged; **H7** is simply the first fix that postdates it (v1b work).
Do not start work on any item without explicit user approval (per
`CLAUDE.md`).

## Critical

_All Critical findings resolved — see Completed below._

## High

_All High findings resolved — see Completed below._

## Medium

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
      real on the Debian target's bash 5.x); `test/canonical_bundle.bats`
      covers `canonical_bundle_ok()`'s two manifest branches (8 cases, no
      skips, lists derived from `install.sh`'s own Stage 6 source) — 40
      cases total. The other
      three remaining embedded scripts (`master-compose-ipv4`,
      `master-docker-netfilter-recovery`, `caddy-tailnet-env`) were
      surveyed and found to have no standalone pure-logic functions worth
      unit-testing — each is essentially a wait loop plus real side
      effects. Remaining: `check_ipv4_policy`/`check_ipv6_policy` (more
      integration-shaped, likely Tier 3 instead — **done 2026-07-28, see
      Completed**). **Remaining scope is CI wiring only, and it is parked
      rather than pending:** the user decided on 2026-07-28 that this
      repository stays local with no git remote, and a runner needs
      somewhere to build from. Kept open at the user's request, but do
      not re-propose CI at each review — a remote is the only thing that
      would unpark it. Tier 3 automation would additionally need a
      non-interactive invocation mode, separately judged not worth
      changing the `/dev/tty` prompt design for. Tier 3 itself
      had three real attempts on 2026-07-28 (see Completed below and
      `docs/testing.md`) — found and fixed three real bugs (**H1**
      regression, **H5**, **H6**) across the first two, then the third
      attempt completed all 7 stages successfully end-to-end, the first
      fully clean install of this repo's `install.sh`.

## Low

_All Low findings resolved or closed — see Completed below._

## Completed

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
      Reconcile now watches the unit on two signals. Static-verified
      only; **not live-verified** — DD-20 lists the three things a live
      run must confirm (gid-1000 read access, rclone 1.60.1 vs Infuse,
      the 401 probes).
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
- [x] **M8 (2026-07-28).** Canonical bundle publication moved out of
      Stage 4 into the single atomic block at the end of Stage 6, so the
      manifest and the `LOCAL_DNS_ENABLED` value it is validated against
      always become visible together. Previously Stage 4 truncated the
      manifest to one entry while publishing a possibly
      `LOCAL_DNS_ENABLED=1` `state.env`, leaving the bundle
      self-inconsistent for all of Stages 4-6; a re-run that failed in
      that window left reconcile hard-exiting at `canonical_bundle_ok()`
      every 5 minutes with no self-healing at all. Side benefit: a failed
      re-run now keeps the previous run's complete bundle, so reconcile
      goes on enforcing the last known-good configuration.
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
