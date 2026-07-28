# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Project documentation scaffolding: `README.md`, `CLAUDE.md`,
  `SECURITY_REVIEW.md`, `TODO.md`, `CHANGELOG.md`, `SESSION.md`, and
  `docs/{architecture,design-decisions,profiles,testing}.md`.
- Full `README.md` description of `install.sh`'s current architecture,
  installation flow, Docker services, networking, and known limitations.
- `CLAUDE.md` working guide for future Claude Code sessions (language
  rules, execution restrictions, review-before-edit workflow, security and
  modularity conventions).
- `SECURITY_REVIEW.md` populated with 18 findings (2 Critical, 4 High, 7
  Medium, 5 Low; corrected from an initial miscount of 19) from a full
  static audit of `install.sh`.
- `TODO.md` populated with prioritized remediation tasks derived from the
  security review.
- `scripts/lint-embedded-scripts.sh`: extracts `install.sh`'s six embedded
  heredoc scripts and lints each independently with `bash -n` +
  `shellcheck` (with `SC2016` excluded as a documented false-positive
  class for intentional single-quoted `awk` programs). Resolves **H4**.
- `test/reconcile_functions.bats`: `bats-core` unit tests for
  `state_value` and `owned_file_ok` (`master-network-reconcile` heredoc),
  extracting only these two function bodies rather than sourcing the
  whole reconcile script. Part of **M7**.
- `test/firewall_functions.bats`: `bats-core` unit tests for six
  pure-logic functions from `docker-tailscale-fw` (`route_value`,
  `chain_rules_exact`, `jump_is_first_and_single`,
  `forward_prefix_is_exact`, `docker_forward_has_no_terminal_drop`,
  `no_stale_staging_chains`), using fake `ip`/iptables/ip6tables
  stand-ins instead of the real binaries. Part of **M7**.
- `test/gro_functions.bats`: `bats-core` unit tests for
  `add_default_netdev`, the only standalone function in
  `tailscale-udp-gro`, using a fake `ip` stand-in. All 5 cases self-skip
  on this macOS dev workstation's bash 3.2, which lacks associative
  arrays (the function's dedup guard needs `SEEN` declared as one); they
  run for real on the Debian target's bash 5.x. Part of **M7**.

### Changed

- Stage 2 (`install.sh`): the "already connected to a tailnet" path no
  longer contains an auth-key-conflict warning, since auth-key input no
  longer exists.
- Stage 4 (`install.sh`): the media tree `chown` no longer unconditionally
  rewrites ownership on every run — it now only touches entries whose
  ownership doesn't already match `1000:1000`, via a scoped `find -exec`
  instead of a blanket `chown -R`.
- `master-network-reconcile` (`install.sh`): `tailscale-udp-gro.service`
  is no longer part of the continuous 5-minute reconciliation pass — its
  one-time Stage 2 setup (which still re-applies at every boot) is
  unchanged, but reconcile no longer detects or repairs GRO drift that
  happens outside of a reboot.
- `compose.yaml` → `services.qbittorrent`, `services.unpackerr`: both now
  set `security_opt: ["no-new-privileges:true"]` and hardware-sized
  resource ceilings (`qbittorrent`: `mem_limit: 2g`, `cpus: 2.0`;
  `unpackerr`: `mem_limit: 512m`, `cpus: 1.0`), tuned against the target
  server's actual 4 CPU / 8 GB RAM and typical 1-2 concurrent torrents.
- `compose.yaml` → `services.unpackerr`: now `cap_drop: [ALL]` and
  `read_only: true` — confirmed empirically to run cleanly with neither
  (**M1**).
- `compose.yaml` → `services.qbittorrent`: now `cap_drop: [ALL]` with
  `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER]` — the minimal
  set its linuxserver.io entrypoint needs, confirmed empirically
  (**M1**). `read_only: true` was tested and deliberately **not**
  applied — it breaks the entrypoint's `PUID`/`PGID` handling.

### Removed

- **`TS_AUTHKEY` input removed entirely** (`install.sh`, Stage 0 + Stage
  2): the installer no longer prompts for or accepts a Tailscale auth
  key. It now always uses Tailscale's interactive browser login when the
  host isn't already part of a tailnet.
- **wg-easy unattended-bootstrap subsystem removed entirely**
  (`install.sh`, Stages 0/4/5/7 + EXIT trap): the installer no longer
  prompts for or provisions a wg-easy admin account. The DB/marker
  detection state machine, `WG_INIT_ENV_FILE`/`WG_INIT_OVERRIDE_FILE`
  generation, the bootstrap-apply-verify-scrub-marker sequence, the
  `scrub_wg_bootstrap_container` cleanup, and the Stage 7 hard
  postcondition are all gone (248 lines net). wg-easy's admin account is
  now created manually via its web UI on first access, matching
  Portainer/SFTPGo — the script only provisions the container and
  infrastructure.
- **Legacy reboot-timer cleanup removed entirely** (`install.sh`, Stage 1
  + Stage 7): deleted `remove_managed_scheduled_reboot()` and its Stage 7
  re-verification block (61 lines). This existed only to clean up a daily
  04:15 automatic-reboot mechanism installed by versions of this script
  from the r3 era or earlier — dead weight for a deployment target that
  is always a fresh Debian 13 install with no such history.
- **UDP GRO continuous reconciliation removed** (`install.sh`,
  `master-network-reconcile`): deleted the `GRO_INACTIVE`/`GRO_DRIFTED`
  detection block, the `all_managed_state_healthy()` wrapper function
  (now redundant — its sole caller uses `all_critical_state_healthy`
  directly), the `--check` mode's `gro_unit`/`gro_runtime` output fields,
  the drift warning, and the repair (start/restart) action — roughly 54
  lines. Also removed two now-dead variables inside the same heredoc
  (`ETHTOOL_BIN`, `CURRENT_WAN6_IF`). Stage 2's one-time setup (helper
  script + oneshot systemd unit, re-applied at every boot) is unchanged.

### Fixed

- `check_ipv6_policy()` (`docker-tailscale-fw`) now reports a specific
  "ip6tables bulunamadı" diagnostic instead of a generic policy-drift
  failure when the `ip6tables` binary is missing.
- Stage 1 `apt-get full-upgrade` now passes explicit dpkg conffile-policy
  flags (`--force-confdef`/`--force-confold`) so a theoretical
  unattended conffile prompt can never stall the noninteractive install.
- Stage 4 now also `modprobe`s `ip6_tables` and `ip6table_nat` on the host
  (added to the existing `wireguard` modprobe/`modules-load.d` step) — a
  regression in **H1**'s fix that broke `wg-quick up wg0`'s legacy-mode
  ip6tables PostUp/PostDown rules, found via the first live Tier 3 install
  test (2026-07-28).
- wg-easy's `healthcheck` (`compose.yaml`) no longer asserts a fixed
  WireGuard listen port — only that `wg0` exists and is up. The port
  assertion could never pass on a fresh install now that **M6** made the
  port a manual, web-UI-only setting, deadlocking Stage 5 on every fresh
  install (**H5**, found via the same live test).
- `check_compose_runtime()` (`master-network-reconcile`) no longer counts
  wg-easy's still-pending first-run setup (`/setup` redirect) as
  `compose_runtime` drift — only the diagnostic message and
  `WG_CONFIGURATION_INVALID` are still set. Previously this made Stage
  7's own `master-network-reconcile --check` postcondition gate fail on
  every fresh install, even after **H1**/**H5** were fixed (**H6**, found
  via a second live Tier 3 test, 2026-07-28).

### Documentation

- Final install summary now explicitly warns about two previously-silent,
  confirmed-intentional behaviors: (1) reconcile reverts
  `state.env`/dnsmasq/Caddy config drift (including manual edits) every 5
  minutes; (2) `docker`/`tailscaled` restarts cascade into the firewall,
  Compose stack, and Caddy via `PartOf`. No functional change — both
  behaviors were already in place and are staying as-is by explicit user
  decision.
- Final install summary now also warns that Portainer, wg-easy, and
  SFTPGo all need a manually-created admin account on first access, and
  lists each service's URL (including its Tailnet hostname if local DNS
  is enabled).
- Added an inline comment above `INSECURE: "true"` (`compose.yaml` →
  `services.wg-easy`) explaining its Tailnet-only + Caddy-loopback
  dependency.
- Expanded the Docker daemon DNS override comment (Stage 3) to explicitly
  state the intentional host-vs-container DNS resolution split.
- Documented in `README.md` (Security Notes) that Tailscale device
  registration isn't ephemeral, so rebuilding this server leaves an
  orphaned device entry in the tailnet admin console.
- Rewrote the `README.md` "Docker socket exposure" note to record the
  final accepted-risk decision on Portainer's `docker.sock` mount: a
  socket-proxy was reconsidered and rejected as a weak fit for Portainer
  specifically, and a read-only socket mount was noted as an ineffective
  mitigation (Unix domain sockets aren't gated by the mount's `ro` flag).

### Security

- **Resolved C2** (`SECURITY_REVIEW.md`): the Tailscale auth key was
  previously echoed to the terminal (`read -rp` instead of `read -rsp`).
  Rather than just silencing the prompt, the auth-key input was removed
  entirely, closing the exposure at its source. See `SECURITY_REVIEW.md`
  for details.
- **Resolved M6** (`SECURITY_REVIEW.md`): removing the wg-easy
  unattended-bootstrap subsystem eliminates the dead-end failure state it
  previously documented, along with an entire secret-handling subsystem
  (bootstrap env files, container secret scrubbing). Trade-off: the
  installer can no longer distinguish "public IP changed since wg-easy
  was last configured" across separate `install.sh` reruns — see
  `docs/design-decisions.md`.
- **Resolved H1** (`SECURITY_REVIEW.md`): removed `SYS_MODULE` and the
  `/lib/modules` bind mount from wg-easy's `cap_add`/`volumes`. The
  WireGuard kernel module is now loaded independently on the host (Stage
  4, best-effort `modprobe wireguard`), so wg-easy runs with only
  `NET_ADMIN`. Hardened further: the module load is made persistent across
  reboots via `/etc/modules-load.d/wg-easy.conf`
  (`systemd-modules-load.service`), and a functional probe (`ip link add
  ... type wireguard` + delete) replaces reliance on `modprobe`'s exit
  code, correctly handling a built-in (non-module) WireGuard kernel too.
  See `docs/design-decisions.md` (DD-10) for the tun-vs-wireguard
  clarification and the open userspace-WireGuard alternative this
  surfaced. **Needs real-server functional verification** (wg-easy
  bringing up `wg0` successfully) — not something this assistant can check
  directly.
- **Resolved H4** (`SECURITY_REVIEW.md`): added
  `scripts/lint-embedded-scripts.sh` so `install.sh`'s six embedded
  heredoc scripts (previously invisible to `bash -n install.sh` /
  `shellcheck install.sh`) get independently linted. First real run
  surfaced no actual bugs — only the expected, excluded `SC2016`
  awk-quoting notices — but the ~1900 lines this covers are now checked
  going forward instead of trusted blindly.
- **Resolved C1** (`SECURITY_REVIEW.md`, accepted risk): Portainer's
  `docker.sock` mount stays as-is. A socket-proxy was reconsidered and
  found to be a weak mitigation specifically for Portainer (its
  management features need close to the same broad API access that makes
  the direct mount risky). User confirmed active use and accepted the
  risk, scoped by network exposure rather than API restriction.

## Today's Work — 2026-07-27

- Performed a full static audit of `install.sh` (4552 lines) covering
  security, secrets handling, destructive operations, firewall/network
  safety, Tailscale exit-node configuration, Docker Compose design,
  systemd services/timers, reconcile/self-healing behavior, idempotency,
  rollback/cleanup traps, error handling, service coupling, unnecessary
  services, installation profiles, modularization opportunities, and
  testing strategy. No changes were made to `install.sh` — it was read
  only.
- Created the target project structure (top-level docs + `docs/`
  subdirectory) without touching or deleting any existing file.
- Filled in `README.md` end-to-end based on the audit findings.
- Filled in `CLAUDE.md` as the working guide for future sessions, encoding
  the language, execution, and review-workflow rules the user specified.
- Filled in `SECURITY_REVIEW.md`, `TODO.md`, `CHANGELOG.md`, `SESSION.md`,
  and all four `docs/*.md` files based on the audit results.
- `install.sh` remained unmodified through all of the above documentation
  work. Later in the same session, the user walked through the intended
  target architecture verbally; it was cross-checked against `install.sh`
  and found to match, aside from one planned future change (moving
  wg-easy's admin account setup from automatic to manual).
- Made the first actual `install.sh` change: removed the `TS_AUTHKEY`
  prompt entirely (Stage 0 input/summary + Stage 2 connection logic),
  resolving **C2**. Verified with `bash -n` and `shellcheck` (both
  clean); diff shown to the user before any commit.
- Established a standing workflow rule (added to `CLAUDE.md`): update
  `TODO.md`, `SECURITY_REVIEW.md`, and `CHANGELOG.md` after every
  `install.sh` change.
- Agreed a stage-by-stage remediation order with the user (Stage 0 →
  Stage 4/5 wg-easy → Stage 3 firewall → reconcile scope → legacy
  reboot-timer cleanup → Stage 7), and worked through it together: the
  user explains intended architecture piece by piece, this assistant
  analyzes the matching code and flags risk before any edit, and applies
  only what's explicitly approved.
- Removed the entire wg-easy unattended-bootstrap subsystem from
  `install.sh` at the user's request (**M6**): admin/peer setup is now
  fully manual via wg-easy's web UI; the script only builds the container
  and infrastructure. 248 lines removed across Stages 0/4/5/7 and the
  EXIT trap; verified with `bash -n` and `shellcheck` (also cleaned up two
  helpers ShellCheck flagged as newly-dead: `wg_ui_configured()` and
  `WG_UI_CONFIGURED`).
- End-of-session documentation pass: reviewed every Markdown file in the
  repository against the current `install.sh` and fixed drift left over
  from the two remediations above — `README.md` (feature list, stage
  table, installation flow, security notes, limitations, roadmap all
  referenced the now-removed `TS_AUTHKEY` prompt and wg-easy bootstrap),
  `docs/testing.md` (manual test checklist had two scenarios for
  behavior that no longer exists), and `docs/profiles.md` (stale
  `install.sh` line numbers in the implementation sketch). `SECURITY_REVIEW.md`
  and `TODO.md` line numbers were already refreshed earlier in the
  session. `install.sh` itself was not touched during this pass.
- Reviewed Stage 3 (`install.sh:993-1682`, Docker install + firewall
  helper) fresh at the user's request: no new issues found beyond what was
  already tracked (**M5**, still open at that point).
- **Remediation 3 (M5, Medium — resolved):** added an explicit "ip6tables
  bulunamadı" diagnostic to `check_ipv6_policy()` instead of a generic
  policy-drift failure. Diagnostics-only; fail-closed behavior unchanged.
- Discussed **H1** (`wg-easy`'s `SYS_MODULE` capability) in depth with the
  user, including correcting an earlier overreach on this assistant's
  part: the assumption that Tailscale's own operation would already have
  loaded the kernel `wireguard` module turned out to be unsubstantiated —
  the script's own `modprobe tun` in Stage 2 points to Tailscale using a
  TUN device + userspace WireGuard, not the kernel module. Clarified for
  the user that `tun` and `wireguard` are two fully independent kernel
  modules, and that a kernel module is a host-kernel-wide change shared by
  every container on the host, unlike most other container-scoped
  operations — directly explaining why `SYS_MODULE` was the container's
  biggest remaining host-touching surface.
- **Remediation 4 (H1, High — resolved):** removed `SYS_MODULE` and the
  `/lib/modules` mount from wg-easy; added an independent, best-effort
  `modprobe wireguard` on the host in Stage 4. Also discussed and recorded
  (as an open trade-off in `docs/design-decisions.md`, not implemented) a
  cleaner long-term alternative: running WireGuard fully in userspace
  (`boringtun`/`wireguard-go`) to remove the kernel-module dependency
  entirely.
- Both remediations verified with `bash -n` and `shellcheck` (clean);
  refreshed every affected `install.sh:NNNN` reference across
  `SECURITY_REVIEW.md` and `TODO.md` again after these two changes shifted
  line numbers throughout the file (4304 → 4317 lines). **H1** still needs
  a real functional test on the target server, which this assistant
  cannot perform.
- User asked whether the `modprobe wireguard` assumption could be made
  more of a guarantee, whether it should persist across reboots, and
  whether it risks breaking Tailscale or any other WireGuard consumer.
  Answered: added `/etc/modules-load.d/wg-easy.conf` for boot persistence,
  and replaced the modprobe-exit-code check with a functional
  `ip link add/del` probe (correctly handles a built-in, non-module
  WireGuard kernel); confirmed no risk to Tailscale (unrelated TUN +
  userspace code path) or to any other service (wg-easy is the only
  kernel-WireGuard consumer on this host). Refreshed line references
  again across `SECURITY_REVIEW.md` and `TODO.md` (4317 → 4334 lines);
  verified with `bash -n` and `shellcheck`.
- User asked for a deeper look at the remaining H1 risk, pointing out that
  wg-easy's own entrypoint is what actually brings up `wg0` (not
  `compose.yaml` directly) and that our new host-level probe already
  exercises the same kernel operation. Narrowed the real residual risk
  down to two specific, well-defined questions (container-namespace
  interface creation behavior, and wg-easy's own image-internal handling
  of a missing `SYS_MODULE`) instead of a vague "might not work." Offered
  to research wg-easy's actual entrypoint source to resolve this without
  waiting for server access; user chose to defer that to a live SSH test
  at the end of the engagement instead.
- **Remediation 5 (H2) and 6 (H3), both resolved by confirming intent, not
  by changing behavior:** user confirmed reconcile's config-revert
  behavior and the `PartOf` cascading-restart coupling are both desired,
  not bugs. Added two explicit warning blocks to the final install
  summary (`install.sh:4253-4278`) naming the affected files/units, and
  added confirming notes to `docs/architecture.md`. Verified with
  `bash -n` and `shellcheck` (clean; also test-rendered the
  conditional-text logic standalone to confirm correct output in both the
  local-DNS-enabled and local-DNS-disabled cases before trusting it).
  `install.sh` now 4356 lines.
- Agreed a logical order for the remaining `SECURITY_REVIEW.md`/`TODO.md`
  items with the user (quick low-risk group first, then M2, legacy
  reboot-timer cleanup, L3, M1, C1, M3, H4, M7, then a final Stage 7
  review, with the live SSH test still deferred to the end).
- **Remediations 7–11 (M4, L1, L2, L4, L5), the agreed "quick low-risk
  group":** all documentation/comment-only, no functional changes to
  `install.sh`. Added an inline comment for `INSECURE: "true"`; added
  dpkg conffile-policy flags to `apt-get full-upgrade`; expanded the
  Docker DNS comment to state the host-vs-container split explicitly;
  documented non-ephemeral Tailscale device registration in `README.md`;
  and added a first-run-admin-setup warning (Portainer/wg-easy/SFTPGo,
  with URLs) to the final install summary. Verified with `bash -n` and
  `shellcheck` (clean); render-tested the new conditional summary text
  standalone before trusting it. `install.sh` now 4378 lines. While
  updating `SECURITY_REVIEW.md`/`TODO.md` afterward, caught and corrected
  a long-standing arithmetic error: both files had said "19 findings"
  since the original audit, but only 18 are actually named (2 Critical +
  4 High + 7 Medium + 5 Low = 18).

## Today's Work — 2026-07-28

- **Remediation 12 (M2, Medium — resolved):** replaced the unconditional
  `chown -R 1000:1000 "$DOWNLOADS_PATH/media"` in Stage 4 with `find
  "$DOWNLOADS_PATH/media" \( ! -uid 1000 -o ! -gid 1000 \) -exec chown
  1000:1000 {} +`, so a re-run against an already-correctly-owned tree no
  longer pays the I/O cost of rewriting every file's ownership — only
  genuinely mismatched entries (including newly added files, or the root
  directory itself if needed) get touched. Verified the `find` predicate
  standalone in an isolated scratch directory before trusting it in
  `install.sh`: matching the current user's own UID/GID selected nothing;
  a nonexistent UID selected every entry, root directory included.
  Verified with `bash -n` and `shellcheck` (clean). `install.sh` now 4385
  lines. Refreshed every downstream `install.sh:NNNN` reference in
  `SECURITY_REVIEW.md` and `TODO.md` that shifted as a result.
- Presented analysis of the next agreed topic (legacy reboot-timer
  cleanup): `remove_managed_scheduled_reboot()` (Stage 1) plus its Stage 7
  re-verification is the only "old script version" migration shim left
  anywhere in `install.sh` (confirmed via `grep` for `r3` — one match).
  It's already idempotent/safe (a no-op when the legacy units don't
  exist), but on this deployment target — always a fresh Debian 13 install
  — it's guaranteed to always be a no-op, since those units never existed
  there. Asked the user whether this script would ever run against a
  genuinely old (pre-r8) host; they confirmed it would not.
- **Unnumbered remediation (legacy reboot-timer cleanup, resolved):**
  deleted `remove_managed_scheduled_reboot()` and its Stage 7
  re-verification block entirely — 61 lines removed, `install.sh` now
  4324 lines. Updated the Stage 1/2/3/4/5/6/7 line-range tables in
  `README.md` and `docs/architecture.md` to match (Stage 1's description
  no longer mentions "legacy reboot-timer removal"). Verified with
  `bash -n` and `shellcheck` (clean); refreshed every downstream
  `install.sh:NNNN` reference across `SECURITY_REVIEW.md` and `TODO.md`
  that shifted as a result (a larger sweep this time, since the removal
  sits early in Stage 1 and shifts nearly the entire rest of the file).
- Presented analysis of the next agreed topic (**L3**,
  `tailscale-udp-gro.service` complexity): mapped its full ~160-line
  footprint across Stage 2 setup, reconcile detection, reconcile
  health-rollup/repair, and Stage 5/7 sanity checks; noted GRO was
  already excluded from `all_critical_state_healthy()`, so its drift
  never affected pass/fail postconditions — only the "do nothing, early
  exit" shortcut in reconcile. Proposed removing the continuous
  reconcile-side monitoring while keeping the one-time Stage 2 setup
  (needed for per-boot persistence, since ethtool flags reset on reboot).
- **Remediation 13 (L3, Low — resolved):** removed
  `tailscale-udp-gro.service`'s reconcile-side continuous monitoring
  entirely (~54 lines: detection, `all_managed_state_healthy()`,
  `--check` fields, warning, repair action), redirecting its sole caller
  to `all_critical_state_healthy` directly. While removing this, manually
  caught two variables that became dead as a side effect —
  `ETHTOOL_BIN` and `CURRENT_WAN6_IF` inside the same
  `master-network-reconcile` heredoc — since `shellcheck` cannot see
  inside heredoc content and didn't flag them (a live demonstration of
  **H4**'s blind spot). Removed those too. Net 57 lines off `install.sh`
  (4324 → 4267). Verified with `bash -n` and `shellcheck` (clean);
  refreshed every downstream `install.sh:NNNN` reference across
  `SECURITY_REVIEW.md` and `TODO.md`.
- Presented analysis of **M1** (container hardening for `qbittorrent`/
  `unpackerr`), tiered by risk: Tier 1 (`no-new-privileges`, zero risk),
  Tier 2 (`cap_drop: [ALL]`, moderate risk — flagged that qbittorrent's
  linuxserver.io entrypoint runs a root-level init for `PUID`/`PGID`
  volume-ownership fixing and likely needs some capabilities back, unlike
  `unpackerr` which already runs as non-root), Tier 3 (`mem_limit`/`cpus`,
  needs the user's actual hardware specs to size safely — asked for them).
  Also discussed, at the user's prompt, whether qBittorrent's peer port
  could avoid public-IP exposure entirely: laid out the three real
  options (keep the current narrowly-scoped public port; fully un-forward
  it and accept degraded connectivity/seed-ability; or route qBittorrent
  through a third-party commercial VPN sidecar à la `gluetun`, which is
  the self-hosting community's standard answer to this exact question).
  Recommended scoping the VPN-sidecar option as its own future decision
  rather than folding it into this hardening pass.
- User approved Tier 1 immediately, deferred Tier 2 to the live SSH test,
  provided hardware specs (4 CPU / 8 GB RAM, 1-2 concurrent torrents) for
  Tier 3, and chose to keep the public IP port open (accepted as a
  narrow, reasonable risk) rather than pursue the VPN-sidecar option.
- **Remediation 14 (M1, Medium — partially resolved):** applied Tier 1
  (`security_opt: ["no-new-privileges:true"]`) and Tier 3 (`mem_limit`/
  `cpus`: `2g`/`2.0` for `qbittorrent`, `512m`/`1.0` for `unpackerr`) to
  both containers in `compose.yaml`. Tier 2 (`cap_drop: [ALL]`) and
  `read_only` remain deliberately deferred to the live SSH test phase.
  Verified with `bash -n` and `shellcheck` (clean). `install.sh` now 4275
  lines.
- Presented analysis of **C1** (Portainer's `docker.sock` mount),
  revisiting the original "add a socket-proxy" recommendation more
  critically: found it a weak fit for Portainer specifically, since
  Portainer's real management features (creating/recreating containers,
  deploying stacks) need close to the same broad API surface that makes
  the direct mount risky — a proxy restrictive enough to help would break
  Portainer, one permissive enough to preserve it wouldn't meaningfully
  reduce risk. Also flagged that a read-only socket mount (`:ro`) is a
  commonly suggested but ineffective mitigation. Asked whether Portainer
  is actively used, since removing it entirely is the one change that
  would fully eliminate the finding.
- User confirmed the risk is acceptable: Portainer is actively used for
  container monitoring and manual intervention and considered the ideal
  interface for that; declined to remove it.
- **Remediation 15 (C1, Critical — resolved as accepted risk):** no
  `install.sh` change. Documented the full analysis and the
  accepted-risk decision in `README.md` (Security Notes), replacing the
  original "add a socket-proxy or make it opt-in" recommendation with the
  reasoning above and the network-exposure-based mitigation already in
  place. All Critical findings are now resolved.
- Analyzed **H4** (embedded heredoc scripts not covered by static
  analysis): confirmed exactly which six heredocs are actual bash scripts
  (`tailscale-udp-gro`, `docker-tailscale-fw`, `master-compose-ipv4`,
  `master-network-reconcile`, `master-docker-netfilter-recovery`,
  `caddy-tailnet-env` — the rest write YAML/INI/plain-text config, out of
  scope for shellcheck) and prototyped a `sed`-based extraction approach
  against the real file before writing the final tool.
- **Remediation 16 (H4, High — resolved):** added
  `scripts/lint-embedded-scripts.sh` (new file, `install.sh` untouched).
  Ran it for real: `master-docker-netfilter-recovery` came back
  completely clean; the other five had only `SC2016` (single-quoted `awk`
  program field references, e.g. `'$1 == "-A" {...}'` — intentional,
  correct, not real defects), which the tool now excludes so its output
  stays actionable. Verified the tool actually catches failures too:
  injected a synthetic syntax error into a scratch copy of `install.sh`
  (never the tracked file) and confirmed a non-zero exit with a clear
  `bash -n` error. CI wiring (e.g. GitHub Actions) intentionally not
  attempted — no CI exists in this repo yet, and standing this up wasn't
  confirmed as wanted; the tool runs manually
  (`./scripts/lint-embedded-scripts.sh`) for now. All High findings are
  now resolved. Only **M1** (partial), **M3**, and **M7** remain open.
- User asked to skip **M3** for now and move to **M7** (testing
  strategy). Presented the M7 analysis: Tier 1 (static analysis) already
  done via **H4**; Tier 2 (unit tests) is achievable now without root or
  live infrastructure; Tier 3 (VM integration) and CI wiring are not
  achievable/confirmed right now.
- **Remediation 17 (M7, Medium — partially resolved):** added
  `test/reconcile_functions.bats`, covering `state_value` and
  `owned_file_ok` from the `master-network-reconcile` heredoc. Reused the
  same `sed` marker-based extraction as `scripts/lint-embedded-scripts.sh`
  to pull the heredoc body out of `install.sh`, then an `awk` pass to
  isolate just these two function definitions — the full reconcile script
  is never sourced, since it runs real `flock`/`systemctl` calls at its
  top level the moment it's loaded. Fixture-based test cases (temp
  `state.env` files for `state_value`; temp files with controlled `chmod`
  for `owned_file_ok`) exercise both functions without root, systemd, or
  Docker. First run surfaced two issues, both fixed before trusting the
  suite: (1) Turkish-language `@test` names broke under this shell's
  `tr_TR.UTF-8` locale (bats failed to resolve three test names containing
  `ğ`) — renamed all test descriptions to English, consistent with the
  project's English-code/comments convention, which also resolved the
  locale issue; (2) `owned_file_ok`'s uid:gid:mode match/mismatch cases
  depend on GNU coreutils' `stat -c` syntax, which this macOS dev
  workstation's BSD `stat` doesn't support — added a `HAS_GNU_STAT` probe
  in `setup()` so those two cases self-skip with an explicit reason on
  non-GNU-stat platforms instead of failing on an environment gap
  unrelated to the function's logic (they run for real on the Debian
  production target). All 7 cases pass (2 skipped here). `chown` to an
  arbitrary UID/GID isn't testable without root, so the UID/GID-mismatch
  case for `owned_file_ok` is intentionally not covered. `install.sh`
  untouched. Remaining for **M7**: unit tests for `chain_rules_exact`,
  `jump_is_first_and_single`, `detect_ipv4_route` parsing (all in
  `docker-tailscale-fw`); Tier 3; CI wiring.
- **Remediation 18 (M7, Medium — still partial, further progress):** added
  `test/firewall_functions.bats`, covering six more pure-logic functions
  from the `docker-tailscale-fw` heredoc: `route_value`,
  `chain_rules_exact`, `jump_is_first_and_single`,
  `forward_prefix_is_exact`, `docker_forward_has_no_terminal_drop`, and
  `no_stale_staging_chains`. The five predicate functions each take an
  iptables/ip6tables binary path as their first argument and only ever
  call it with `-S`/`-C` to read state, never to mutate rules, so a fake
  shell-function stand-in (`fake_bin`) supplies canned `-S` rule
  listings/`-C` exit codes per test instead of calling real
  `iptables`/`ip6tables` — no root, no real firewall state touched.
  `route_value` (the shared parsing helper behind `WAN4_IF`/
  `PUBLIC_IPV4`/`WAN6_IF` detection, reused by `detect_ipv4_route` in
  Stage 2) is tested the same way against a fake `ip` returning canned
  `ip route get` output. Investigated `detect_ipv4_route` itself first:
  found it actually lives in `install.sh`'s outer script (not inside any
  heredoc) and calls `exit 1` directly on failure, so it's already
  covered by `bash -n install.sh`/`shellcheck install.sh` directly and
  isn't a fit for the extract-a-function-body technique used here — its
  reusable parsing logic (`route_value`) was tested instead, which is
  what was actually meant by "detect_ipv4_route's parsing logic" in the
  original Tier 2 candidate list. 20 new test cases, all passing (27
  total across both `.bats` files in `test/`). `install.sh` untouched.
  Remaining for **M7**: `check_ipv4_policy`/`check_ipv6_policy` (more
  integration-shaped — coupled to real global state and direct
  `$IPTABLES_BIN -C` calls — likely better suited to Tier 3 than a unit
  test); a survey of the other four embedded scripts
  (`tailscale-udp-gro`, `master-compose-ipv4`,
  `master-docker-netfilter-recovery`, `caddy-tailnet-env`) for further
  pure-logic candidates; Tier 3; CI wiring.
- Surveyed the four remaining embedded scripts for further Tier 2
  candidates, as agreed with the user. `tailscale-udp-gro` has one
  standalone function, `add_default_netdev` (dedupes discovered
  default-route interfaces). The other three
  (`master-compose-ipv4`, `master-docker-netfilter-recovery`,
  `caddy-tailnet-env`) turned out to have none: each is almost entirely a
  `sleep`-based wait loop plus real side effects (`mktemp`+`mv` file
  writes, `flock`, `systemctl restart/start`), with no isolable pure logic
  to extract without first refactoring `install.sh` itself (out of scope
  for a testing-only pass).
- **Remediation 19 (M7, Medium — still partial, further progress):** added
  `test/gro_functions.bats`, covering `add_default_netdev` from the
  `tailscale-udp-gro` heredoc, tested against a fake `ip` returning canned
  `ip route get` output — same extraction technique as the other two
  `.bats` files. 5 new test cases. All 5 self-skip here: the function's
  dedup guard reads/writes `SEEN`, a bash associative array (bash 4+
  only), and this macOS dev workstation's default `/bin/bash` is 3.2,
  which pre-dates associative arrays entirely, unlike the Debian 13
  target's bash 5.x — detected via a `declare -gA` probe in `setup()`,
  mirroring the existing `HAS_GNU_STAT` self-skip pattern from
  `test/reconcile_functions.bats`. 32 test cases total across all three
  `.bats` files in `test/`. `install.sh` untouched. Remaining for **M7**:
  `check_ipv4_policy`/`check_ipv6_policy` (Tier 3 candidate); Tier 3
  itself; CI wiring.
- **First live Tier 3 install test.** With the user's explicit approval,
  ran `install.sh` for real, end-to-end, against the user's own server —
  freshly reimaged to a clean Debian 13 install (same host/IP that had
  been running the pre-remediation, week-old production stack; the user
  wiped it themselves before this session). Verified the target was
  genuinely fresh first (2-minute uptime, 1% disk used, no Docker
  installed) rather than trusting the hostname alias alone. Transferred
  `install.sh` via `scp`, verified its SHA-256 matched the local copy.
  Since `install.sh`'s interactive prompts read from `/dev/tty` directly
  (not stdin — deliberate, so the script stays pipeable from `curl`), a
  simple stdin/heredoc-based automation wouldn't work; instead ran it
  inside a `tmux` session (real PTY) on the server, relaying each prompt's
  text into the conversation for the user to answer, then sending their
  answer back via `tmux send-keys`. This assistant did not choose any
  configuration values itself. Confirmed as instructed each time before
  the corresponding command ran (this includes: `apt-get install tmux`,
  `scp`, the interactive install itself, a targeted `qbittorrent`
  container restart to verify a previously-stale log line, and — after
  the failure below — a diagnostic `modprobe` + `systemctl restart
  master-compose.service`/`docker restart wg-easy` to confirm the root
  cause before touching `install.sh`).
- The install completed Stages 0-4 cleanly (package install, Tailscale
  browser re-authentication, Docker/image pulls, systemd units) and
  failed at Stage 5: `docker compose up --wait` timed out because
  `wg-easy` never reported healthy. Diagnosed via container health logs,
  `docker exec wg-easy wg show`/`ip link`, and `docker logs wg-easy`:
  `wg-quick up wg0` was aborting because its legacy-ip6tables PostUp rules
  needed `ip6_tables`/`ip6table_nat`, which were never loaded on this host
  (a regression in **H1**'s fix — see `SECURITY_REVIEW.md`). Host IPv6 WAN
  connectivity is real and was correctly detected (`ping6` to
  `2001:4860:4860::8888` succeeded, ~15ms) — a red herring raised and
  investigated at the user's prompt, ruled out once it became clear the
  host's own `ip6tables` uses the nftables backend and so never loads the
  legacy modules wg-easy's container needs.
- Loaded both modules by hand and restarted `wg-easy`: `wg0` came up
  successfully, but a **second**, unrelated problem surfaced — `wg show
  wg0 listen-port` returned the image's default (`51820`), not the
  install's configured `65171`, because wg-easy v15+ only accepts the
  WireGuard port via its web UI's first-run setup wizard (persisted to its
  own database), not an environment variable — something **M6** correctly
  designed around, but the healthcheck's fixed-port assertion didn't
  account for. Confirmed the fix (dropping the port assertion, checking
  only that the interface exists) would work by running the proposed
  healthcheck command directly against the live container before changing
  `install.sh`.
- **H1 regression + H5 (new finding), both resolved:** applied both fixes
  to `install.sh` — Stage 4's modprobe step now covers `ip6_tables`/
  `ip6table_nat` alongside `wireguard` (loop instead of one-off, plus
  `/etc/modules-load.d/wg-easy.conf` updated for reboot persistence), and
  the `compose.yaml` heredoc's wg-easy `healthcheck` no longer checks the
  listen port. `install.sh` 4275 → 4290 lines. Verified with `bash -n`,
  `shellcheck`, `scripts/lint-embedded-scripts.sh`, and `bats test/` (all
  clean/passing). Synced `SECURITY_REVIEW.md` (H1 addendum + new **H5**
  entry + updated findings table) and `TODO.md`.
- The server itself is still mid-install (Stage 5 failed before Stage 6/7
  ran) — a follow-up run is needed to actually reach a complete, verified
  install with these fixes in place.
- **Second live Tier 3 install test.** User reimaged the same server clean
  again and gave explicit approval to re-run the (now fixed) `install.sh`
  end-to-end. Same tmux-relay methodology as the first attempt. Progress
  this time: Stages 0-4 succeeded as before, and — for the first time —
  Stage 5 completed cleanly too (wg-easy's healthcheck now passed), then
  Stage 6 (DNS/Caddy, dnsmasq, Caddy, the 5-minute reconcile timer) also
  completed cleanly, all previously unreached. The install then failed at
  Stage 7's own `master-network-reconcile --check` postcondition call.
- Confirmed the underlying system was otherwise fully healthy: all 6
  containers up (wg-easy included, now reporting `healthy`), all core
  systemd units active. A manual `--check` run against the live host
  showed every diagnostic field at `0` except `compose_runtime=1`, traced
  to `check_compose_runtime()` treating wg-easy's still-pending first-run
  setup (`/setup` redirect) as drift — the same condition **H5** already
  accounts for, but this earlier, separate gate didn't. This directly
  contradicted the script's own stated intent (a comment at the final
  summary explicitly says this state shouldn't stop the installer) — an
  M6-era inconsistency invisible until Stage 7 was actually reached, which
  the H1/H5 fixes were themselves needed for.
- Attempted to verify the fix quickly by patching the already-deployed
  `/usr/local/sbin/master-network-reconcile` directly on the server
  (to avoid a third reimage) — this specific action was blocked by the
  auto-mode classifier as an unreviewed live edit outside the tracked
  `install.sh` source. Reasonable call; fixed in `install.sh` instead.
- **H6 (new finding), resolved:** removed `runtime_ok=1` from
  `check_compose_runtime()`'s `/setup/*` branch only — the diagnostic
  message and `WG_CONFIGURATION_INVALID=1` stay, so the periodic
  reconcile timer's own separate operator-facing reporting of this
  condition is unaffected, but it no longer counts as `compose_runtime`
  drift for `all_critical_state_healthy()` (and so Stage 7's `--check`
  gate). The sibling branches (port mismatch after setup, netfilter
  drift) are untouched and still count as real drift. `install.sh` 4290 →
  4296 lines. Verified with `bash -n`, `shellcheck`,
  `scripts/lint-embedded-scripts.sh`, and `bats test/` (all clean).
  Synced `SECURITY_REVIEW.md` (new H6 entry + updated findings
  table/count) and `TODO.md`.
- **Third live Tier 3 install test — first full success.** User reimaged
  the server clean a third time and gave explicit approval to re-run
  `install.sh` again, with all three fixes (H1 regression, H5, H6) in
  place. Same tmux-relay methodology, same default answers as before
  (default downloads path, local DNS enabled, domain `ayc`). All 7 stages
  completed successfully end-to-end for the first time, ending in
  "AŞAMA 7/7 TAMAMLANDI" and the script's own success summary.
- Confirmed live afterward: all 6 containers up (`wg-easy`/`filebrowser`
  reporting `healthy`), all core systemd units (`docker`, `tailscaled`,
  `docker-tailscale-fw`, `master-compose`, `caddy`, `dnsmasq`,
  `master-network-reconcile.timer`) active, zero failed units, and a
  manual `master-network-reconcile --check` now exits `0` — it still
  prints the informational "wg-easy ilk kurulumu tamamlanmamış" message
  (wg-easy's admin account still needs manual first-time setup via its
  web UI, exactly as **M6** intends), but no longer treats that as a
  blocking failure, exactly as **H6** intended.
- This closes out the first full validation cycle for the 2026-07-28
  remediation work (H1 regression, H5, H6) across three live attempts,
  each progressing one stage further than the last (Stage 5 → Stage 7 →
  full success). Synced `SECURITY_REVIEW.md` (Review History), `TODO.md`,
  and `docs/testing.md` to record the successful outcome.
- **M1's remainder, resolved via live capability testing.** User asked to
  test and apply M1's deferred Tier 2 items. Rather than guess at
  `qbittorrent`'s minimal capability needs, tested empirically: spun up
  isolated, throwaway `docker run` containers (same images, never the
  real running stack) with progressively adjusted `--cap-drop`/
  `--cap-add`/`--read-only` flags and inspected their logs.
  `unpackerr` (already non-root) started and ran cleanly with
  `--cap-drop=ALL` and `--read-only` together, no `cap_add` or `tmpfs`
  needed. `qbittorrent`'s root-level s6-overlay init failed under a bare
  `--cap-drop=ALL` (`chown: Operation not permitted`,
  `s6-applyuidgid: fatal: unable to set supplementary group list`);
  adding back `CHOWN`/`SETUID`/`SETGID` alone still failed to create
  `/config/qBittorrent` on a fresh config dir; adding `DAC_OVERRIDE`/
  `FOWNER` on top made it start cleanly — confirmed as the minimal
  working set. Separately tested `--read-only` for `qbittorrent`
  (needing `--tmpfs /run:exec`/`/tmp:exec`/`/var/run:exec` just to get
  past `s6-overlay-suexec` and `noexec`-tmpfs failures) and found it
  broke `PUID`/`PGID` handling outright: files ended up owned by the
  image's default `911:1001` instead of the requested `1000:1000` — a
  real conflict with the shared downloads-tree ownership model **M2**
  depends on, so deliberately not applied.
- **Incident during testing, caught and fixed the same turn:** while
  cleaning up throwaway test containers with `docker rm -f` filtered by
  image name, the filter also matched (and removed) the real, running
  production `qbittorrent` container. Noticed immediately via the
  container list, recreated it with `docker compose up -d --no-deps
  qbittorrent` — no data loss (`/config` is a host bind mount, and this
  fresh install had no real qBittorrent configuration set yet). All
  subsequent test containers were tracked and cleaned up by their exact
  container ID instead.
- **M1 (fully resolved):** applied the confirmed-safe config to
  `install.sh`'s `compose.yaml` heredoc for both containers. `install.sh`
  4296 → 4319 lines. Verified with `bash -n`, `shellcheck`,
  `scripts/lint-embedded-scripts.sh`, and `bats test/` (all clean).
  Synced `SECURITY_REVIEW.md` (M1 now fully resolved, findings table
  updated) and `TODO.md`.
- **Fourth live install + full operational stress test.** With M1's fix
  applied, the user reimaged the server clean a fourth time and re-ran
  `install.sh`; all 7 stages succeeded again, confirming the container
  hardening didn't regress Stage 5. The user then explicitly granted
  broad testing latitude ("test the server without worrying about data
  loss, we're using it for testing") and asked for the install to be
  exercised under realistic operating conditions rather than just
  idle/clean state — configuring real admin accounts, a real WireGuard
  client, and Tailscale exit-node routing from their own Mac.
- Investigated a perceived SFTPGo/WebDAV connection delay (a real client,
  the Infuse app, connecting as user "infuse"): server-side logs showed
  no technical delay whatsoever — 0-7ms request times on the very first
  login, no retries or errors. The delay was almost certainly client-side
  (Tailscale peer setup and/or manual admin-UI configuration time), not
  an `install.sh` or server issue.
- Confirmed reconcile already covers all 6 services (including Portainer,
  via `port_binding_exists`/`http_endpoint_responds`) — no monitoring gap
  found, nothing added.
- Tested the real WireGuard tunnel end-to-end: a real macOS client
  connected, confirmed via `wg show` (successful handshake, real transfer
  bytes) and `docker exec wg-easy ping` to the peer's tunnel IP *from
  inside the container's network namespace* (the host itself has no
  route to `10.8.0.0/24`, so pinging from the host gives a misleading
  100% loss) — 0% packet loss, ~58-107ms RTT.
- Tested the real Tailscale exit-node path: confirmed genuinely active
  (not just configured) via `tailscale status` showing the peer
  `active; direct` with real tx/rx bytes, and via the
  `MASTER-TS-FORWARD` mangle chain's packet counters actually
  incrementing on the `tailscale0 -> eth0` rules.
- **Reboot test.** Rebooted the fully-installed, now-realistically-used
  host. Confirmed **H1**'s fix is genuinely persistent, not incidental to
  the install session: `wireguard`/`ip6_tables`/`ip6table_nat` all
  auto-loaded via `/etc/modules-load.d/wg-easy.conf` alone. All 6
  containers were back up (2 already `healthy`) within 22 seconds, all
  core systemd units active, zero failed units, `master-network-reconcile
  --check` exit `0`, and wg-easy's peer configs/keys persisted correctly.
- **Deliberate drift injection, three at once.** Stopped `qbittorrent`,
  set `net.ipv4.ip_forward=0`, and deleted the
  `MASTER-DOCKER -i tailscale0 -o eth0 -j ACCEPT` firewall rule. The next
  scheduled reconcile cycle detected and repaired all three within 5
  minutes: container restarted, forwarding restored, firewall rule
  reinserted — confirmed via `--check` returning to a clean, exit-`0`
  state, and a second clean cycle 5 minutes later with no drift at all.
  This is the first time this project's self-healing reconcile loop has
  been proven to actively repair injected drift, not just passively
  report a healthy no-op state.
- **Resource-limit (M1) enforcement test.** An isolated throwaway
  container with a 256MB memory limit, pushed past it, was cleanly
  `SIGKILL`ed (exit 137) by the cgroup memory controller without
  affecting the host or any real container — confirms `mem_limit`
  actually enforces.
- **`unpackerr` real-workload test (M1).** With its new `cap_drop: [ALL]`
  + `read_only: true`, a real test archive placed in the watched
  downloads folder was detected, extracted, and cleaned up successfully
  within its normal ~10s poll interval — confirms the new hardening
  survives a genuine extraction workload, not only idle startup.
- **CPU stress test.** Loaded all 4 cores to ~100% for about a minute.
  All 5 web-facing services still responded in single-digit milliseconds
  throughout; a `master-network-reconcile.service` run happened to fall
  inside the stress window and still completed successfully in 4
  seconds. Zero failed systemd units throughout.
- No new bugs found in this round — confirmatory testing validating that
  the day's four fixes (H1 regression, H5, H6, M1) hold up under real
  operational conditions, not just a clean install. Synced
  `SECURITY_REVIEW.md` (H1 reboot-persistence note, M1 real-workload
  note, new Review History row), `TODO.md`, and `docs/testing.md` (Tier
  3 narrative + manual checklist items checked off).
