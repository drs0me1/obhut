# Design Decisions

## Design decisions and rationale

This document records the *why* behind non-obvious choices in
`install.sh`, so future changes don't accidentally "fix" something that
was deliberate. Entries are derived from reading the script's own inline
comments plus structural inference from the 2026-07-27 audit
(`SECURITY_REVIEW.md`).

### DD-1: Atomic staging-chain swap for firewall rules

- **Decision:** Firewall updates build a brand-new, randomly named chain
  fully, then splice it in and only afterward tear down the old one,
  instead of flushing and rebuilding the canonical chain in place.
- **Context:** `install.sh:1336-1390` (`create_staging_chain`,
  `activate_staging_chain`) and the mangle-table equivalent.
- **Rationale:** Flushing `MASTER-DOCKER`/`MASTER-TS-FORWARD` in place
  would leave a window where the chain is empty — either briefly
  fail-open (dangerous) or briefly fail-closed (drops exit-node traffic).
  The staging-chain-then-rename approach keeps the previous, complete rule
  set live until the new one is fully ready.
- **Trade-off:** More complex code (stale-chain cleanup, `$RANDOM`-based
  naming) than a simple flush-and-rebuild, but avoids any exposure window.

### DD-2: Canonical-bundle SHA256 manifest for reconcile

- **Decision:** Managed config files (state, dnsmasq, Caddy) are copied
  into `/usr/local/share/master-stack/` alongside a `SHA256SUMS` manifest;
  reconcile compares live files against these canonical copies rather than
  re-generating and diffing content on every check.
- **Context:** `install.sh:2235-2268` (`canonical_bundle_ok`).
- **Rationale:** A cheap, atomic-manifest-based comparison is faster than
  re-deriving expected file content every 5 minutes, and it gives a single
  place (the manifest) to validate that the *whole* canonical bundle is
  self-consistent before trusting any individual file comparison.
- **Trade-off:** Any manual edit to the live config files (not the
  canonical copies) is treated as drift and reverted — see DD-3.

### DD-3: Reconcile reverts operator edits instead of merging them

- **Decision:** When live firewall/dnsmasq/Caddy config differs from the
  canonical copy, reconcile restores the canonical version rather than
  attempting to detect or preserve manual changes.
- **Rationale:** Merging arbitrary manual edits safely is not tractable
  for this kind of security-sensitive configuration; a deterministic
  "known-good state always wins" model is simpler to reason about and
  guarantees the fail-closed security posture can't erode over time.
- **Trade-off:** Operators cannot make ad hoc persistent changes without
  either editing `install.sh` and re-running it, or (not currently
  implemented) using an explicit opt-out. Flagged as **H2** in
  `SECURITY_REVIEW.md` for better operator-facing documentation of this
  behavior.

### DD-4: `PartOf` fate-sharing between core daemons and managed units

- **Decision:** `docker-tailscale-fw.service`, `master-compose.service`,
  and (optionally) `caddy.service` declare `PartOf=docker.service` and/or
  `PartOf=tailscaled.service`.
- **Rationale:** If the underlying daemon (Docker or Tailscale) is
  stopped, the firewall/Compose/Caddy state built on top of it is no
  longer meaningful and should not be left running against a torn-down
  dependency.
- **Trade-off:** A routine restart of `docker` or `tailscaled` cascades
  into stopping and restarting the entire dependent stack — a real
  operational surprise, flagged as **H3** in `SECURITY_REVIEW.md`.

### DD-5: Reconcile avoids restarting core daemons synchronously

- **Decision:** `master-network-reconcile.service` does not sit in the
  `After=` graph of the units it manages, and never issues a synchronous
  `systemctl restart docker`/`tailscaled` from within its own execution.
- **Context:** Comment at `install.sh:3462-3467`.
- **Rationale:** Doing so from inside a unit that is itself triggered via
  `OnFailure=` from those same units' dependents would risk a systemd
  self-ordering wait/cycle. Core daemon recovery is left to their own
  built-in restart policies; reconcile only acts once they're confirmed
  active.

### DD-6: Fail-closed masking for optional DNS/Caddy services

- **Decision:** `dnsmasq` and `caddy` are installed already `mask`ed, and
  only `unmask`ed after their generated configuration has been validated
  (`dnsmasq --test`, `caddy validate`).
- **Rationale:** Prevents the packaged default (wildcard-listening)
  configuration from ever being reachable — even transiently across a
  reboot mid-install — before the Tailnet-only configuration is confirmed
  good.
- **Trade-off:** Adds bookkeeping (capturing and restoring prior
  mask/enable/active state in the `EXIT` trap) but is necessary for the
  security guarantee to hold across a failed or interrupted install.

### DD-7: wg-easy admin/peer setup is manual (superseded, 2026-07-27)

- **Original decision (r8 and earlier):** First-run wg-easy admin
  credentials were supplied via a root-only `/run`-based env file and a
  Compose override (`restart: "no"`), then the container was
  force-recreated without that override once the bootstrap was verified,
  so the secret never persisted in the container's running environment.
  This closed the credential-exposure window as tightly as the
  Compose/Docker model allowed, but meant a script failure in the narrow
  window between database creation and the bootstrap marker being written
  left a hard-to-recover dead-end state (**M6** in `SECURITY_REVIEW.md`).
- **New decision (2026-07-27):** At the user's explicit request, the
  entire unattended-bootstrap subsystem was removed. `install.sh` now only
  provisions the wg-easy container and its infrastructure (port, volumes,
  network, firewall rules); the admin account is created manually through
  wg-easy's own web UI on first access — the same model already used for
  Portainer and SFTPGo. See `install.sh` Stage 0 (no more admin prompt),
  Stage 5 (no more bootstrap-apply-verify-scrub sequence), and Stage 7
  (the postcondition is now informational only, feeding the existing
  "complete setup manually" message in the final summary rather than
  failing the install).
- **Rationale:** The user considers wg-easy's admin credentials out of
  scope for the installer to manage at all — consistent with how every
  other service's admin account already works. This also deletes an
  entire secret-handling subsystem (bootstrap env files, container secret
  scrubbing, marker-gated rerun safety), directly resolving **M6** and
  reducing the script by 248 lines.
- **Trade-off:** The removed marker also recorded which public IP was
  baked into already-configured wg-easy peer configs. Without it,
  `state.env`'s `WG_ENDPOINT_HOST` is simply overwritten with the current
  public IPv4 on every `install.sh` run (see `install.sh` Stage 4). The
  reconcile timer still detects a public-IP change that happens *between*
  its own 5-minute checks, but a change that happens between two separate
  `install.sh` reruns is no longer specifically flagged — reconcile will
  just record the new IP as if it were always correct. Operators should
  manually verify existing peer configs after any public-IP change
  followed by a re-run of `install.sh`.

### DD-8: Docker daemon DNS hardcoded to public resolvers

- **Decision:** `/etc/docker/daemon.json`'s `dns` key is forced to
  `["1.1.1.1", "1.0.0.1"]`, merged in via `jq` so other daemon settings are
  preserved.
- **Context:** `install.sh:1014-1039`.
- **Rationale:** If Tailscale's MagicDNS/accept-dns rewrites the host's
  `resolv.conf` to `100.100.100.100`, a container on the default bridge
  that inherits it would have its DNS queries routed through the
  restrictive `FORWARD` firewall path and dropped. Forcing stable public
  resolvers for Docker avoids that failure mode independent of host DNS
  configuration.
- **Trade-off:** Host-level and container-level name resolution now follow
  two different paths on the same machine (see **L4** in
  `SECURITY_REVIEW.md`).
- **Confirmed live (2026-07-28):** on a real installed host with Tailscale
  DNS override active (`/etc/resolv.conf` → `100.100.100.100`), a
  container's own `resolv.conf` correctly showed `127.0.0.11` (Docker's
  embedded resolver) forwarding to `1.1.1.1`/`1.0.0.1`, and
  `nslookup ... 1.1.1.1` from inside a container succeeded with both A and
  AAAA records — the firewall does not block this egress path.

### DD-9: Everything lives in one script, deployed via heredocs

- **Decision:** All generated helper scripts (firewall, reconcile,
  recovery, IP-refresh, Caddy env) are embedded as heredocs inside
  `install.sh` rather than shipped as separate files.
- **Rationale (inferred):** Keeps the installer a single, copy-pasteable /
  curl-pipeable artifact with no additional download or packaging step.
- **Trade-off:** These embedded scripts are invisible to `shellcheck
  install.sh` / `bash -n install.sh` (see **H4** in `SECURITY_REVIEW.md`),
  and the file is large and harder to navigate/test as a result.
  `scripts/lint-embedded-scripts.sh` (static analysis) and `test/*.bats`
  (unit tests for a growing subset of pure-logic functions) now mitigate
  this without abandoning the single-file model — see `docs/testing.md`
  for what's covered and what remains open.
- **Superseded for v2 by DD-58 (2026-08-05).** This entry still describes
  `install.sh`, which is frozen and keeps the single-file model. v2
  abandons it.

### DD-10: `wg-easy`'s WireGuard kernel module is loaded independently of Tailscale (2026-07-27)

- **Superseded by DD-120 (2026-09-14):** wg-easy is removed; WireGuard runs in
  the host kernel from `kurulum/wireguard`.

- **v2 (2026-08-06):** Same policy in `install.sh` (`ensure_wg_kernel_modules`
  during Stage 4, before Compose is written) and `templates/compose.yaml`
  (`cap_add: [NET_ADMIN]` only). Host preloads `wireguard`, `ip_tables`,
  `iptable_nat`, `ip6_tables`, and `ip6table_nat`, persists them via
  `/etc/modules-load.d/wg-easy.conf`, and
  probes with a temporary `wg-easy-probe0` link. Confirmed on a live v2 host:
  without the host preload, container `wg-quick up` failed on legacy
  `ip6tables` (`Module ip6_tables not found`) even with `SYS_MODULE`, because
  `/lib/modules` is not mounted; after host `modprobe`, `wg0` and the
  healthcheck recovered. `SYS_MODULE` was therefore removed from the v2
  compose template rather than kept as a false safety net.
- **v2-73 follow-up (2026-08-30):** Ubuntu 26.04 exposed the symmetric IPv4
  failure. Its host defaults to nft-backed iptables, so the stock kernel's
  loadable `ip_tables`/`iptable_nat` modules remained unloaded. wg-easy uses
  `iptables-legacy` inside the container and cannot load host modules without
  `SYS_MODULE` plus `/lib/modules`; `wg-quick up wg0` therefore failed at its
  IPv4 NAT rule. Stage 4 now preloads and boot-persists both legacy IPv4
  modules as well. Loading them live and restarting only wg-easy recovered a
  healthy interface on the configured UDP port; v2-73's cold-reboot test
  confirmed that `systemd-modules-load` closes the boot path too, with all
  five modules present and no current-boot wg-easy iptables errors.
- **Decision:** Instead of granting `wg-easy` the `SYS_MODULE` capability
  (so it could `modprobe wireguard` itself if needed), `install.sh` now
  runs a standalone `modprobe wireguard` on the **host** in Stage 4 (next
  to the `/data/wg-easy/config` directory creation), mirroring the
  existing `modprobe tun` step already used for Tailscale in Stage 2
  (`install.sh:770-774`) — same best-effort pattern (warn on failure,
  never hard-fail the install), but a separate, independent call.
- **Context/clarification:** `tun` and `wireguard` are two unrelated
  Linux kernel modules — `tun` is a generic virtual-network-device driver
  used by many userspace VPN engines (including, very likely, Tailscale's
  own `tailscaled`, which brings up `tailscale0` via a TUN device plus its
  bundled userspace WireGuard engine, evidenced by the script's own
  `modprobe tun` — not `modprobe wireguard` — in Stage 2); `wireguard` is
  the in-kernel WireGuard protocol implementation that wg-easy's `wg0`
  interface uses instead. Loading one has no effect on, and no dependency
  relationship with, the other. All containers and the host share a
  single Linux kernel (unlike filesystem/network namespaces, a kernel
  module is not container-scoped), which is exactly why granting a
  container the ability to load one (`SYS_MODULE`) reaches further outside
  container isolation than almost anything else a container normally
  does — and why removing it here was worth the trade-off below.
- **Rationale:** Resolves **H1** in `SECURITY_REVIEW.md` — wg-easy now
  runs with only `NET_ADMIN`, no `SYS_MODULE`, no `/lib/modules` mount.
- **Hardening added:** Two follow-up questions from the user — "can we
  guarantee this," "should it persist across reboots," "does it risk
  Tailscale or other WireGuard services" — led to two more changes in the
  same Stage 4 block: (1) `/etc/modules-load.d/wg-easy.conf` makes the
  WireGuard and legacy netfilter loads persistent across reboots via
  `systemd-modules-load.service`, not just the current session; (2) a
  functional probe (`ip link add wg-easy-probe0 type wireguard` then
  delete) replaces reliance on `modprobe`'s exit code — this correctly
  detects a kernel where WireGuard is compiled in directly (`=y`, no
  loadable module at all), which would otherwise make `modprobe` report a
  false "not found" warning. No risk to Tailscale or other services: the
  kernel module is orthogonal to Tailscale's TUN + userspace path, and
  wg-easy is the only kernel-WireGuard consumer on this host — modules
  don't share state or interfere with each other once loaded.
- **Trade-off / open risk:** This assumes the host kernel can provide
  WireGuard and legacy IPv4/IPv6 netfilter support (modules or built-ins).
  That is true for the stock Debian 13 and supported Ubuntu kernels; the
  end-to-end wg-easy path is live-verified on Ubuntu 26.04. A custom kernel
  that omits those features can still leave wg-easy unhealthy because the
  preloads intentionally remain best-effort rather than aborting the whole
  stack installation.
- **Open alternative (not implemented):** Running WireGuard fully in
  userspace inside the container (e.g. `boringtun` or `wireguard-go`)
  would remove any kernel-module dependency at all — no `SYS_MODULE`
  ever, regardless of host kernel state, at a modest throughput cost
  (`boringtun` is typically ~80–90% of kernel WireGuard speed on modern
  hardware, likely immaterial for this server's use case). Not pursued
  because stock wg-easy doesn't officially support a userspace backend;
  doing this would mean forking/customizing the image, a larger effort
  than the host-modprobe approach above.

### DD-11: UDP GRO forwarding is applied once, not continuously reconciled (2026-07-28)

- **Decision:** `tailscale-udp-gro.service`'s one-time Stage 2 setup
  (helper script + oneshot systemd unit, re-applied at every boot) is
  kept, but the ~54 lines that used to make `master-network-reconcile`
  detect and repair GRO drift every 5 minutes were removed.
- **Context:** `install.sh:830-940` (setup); the removed reconcile logic
  previously lived around where `all_critical_state_healthy()` is now
  defined in the `master-network-reconcile` heredoc.
- **Rationale:** UDP GRO forwarding is a pure throughput optimization for
  Tailscale's exit-node traffic — it never affects connectivity, only
  performance under load. It was already excluded from
  `all_critical_state_healthy()`, so its drift never affected any
  pass/fail postcondition; the only thing continuous reconciliation
  bought was auto-fixing a drift that isn't caused by a reboot (ethtool
  NIC flags don't persist across reboots on their own, which is why the
  one-time, per-boot setup step still exists and is not being removed).
  Resolves **L3** in `SECURITY_REVIEW.md`.
- **Trade-off:** If GRO settings are reset by something other than a
  reboot (rare — e.g. a NIC driver hot-reload, or certain virtualization
  live-migration events), the script no longer notices or fixes this
  within 5 minutes. It will be re-applied on the next reboot or the next
  `install.sh` re-run instead. Accepted by the user as a reasonable trade
  given GRO is throughput-only.
- **Side effect caught during this change:** two variables
  (`ETHTOOL_BIN`, `CURRENT_WAN6_IF`) inside the `master-network-reconcile`
  heredoc were only ever used by the removed GRO check, and became dead
  code. `shellcheck install.sh` did **not** flag them, since it cannot see
  inside heredoc bodies (see **H4**) — this had to be caught by manual
  review, a concrete illustration of why H4 is a real gap and not just a
  theoretical one.
- **Amended 2026-07-29 (first pass) — the unit is checked again.**
  Reconcile reads `tailscale-udp-gro.service`'s `ActiveState` and restarts
  it (15-minute cooldown via the existing `restart_budget_available`
  stamp) when it is not active.
- **Amended again 2026-07-29 (second pass) — the flags are checked too,
  because live testing showed the unit check alone proves nothing about
  throughput.** The fault-injection run made the gap concrete: after
  `systemctl stop tailscale-udp-gro`, `ethtool -k eth0` still reported
  `rx-udp-gro-forwarding: on`. Stopping the unit does not undo the flags,
  so a unit-only check verifies bookkeeping rather than the optimization
  it exists to protect. Reconcile now also runs `gro_flags_ok()` against
  `CURRENT_WAN4_IF` (already computed for address-drift detection) and
  repairs on either signal. `ETHTOOL_BIN` is reinstated for this — the
  variable this decision originally noted as dead code.
  - **What is still *not* re-added:** the removed logic polled both the
    IPv4 and IPv6 default interfaces and reimplemented the helper's apply
    path. The new check reads the IPv4 WAN interface only and never
    applies anything itself — repair is always `systemctl restart`, so
    systemd stays the single execution path and the unit's state keeps
    reflecting reality. That is why this is ~15 lines rather than the ~54
    that were removed.
  - **Everything the check cannot evaluate is treated as healthy:** no
    `ethtool` binary, no detected WAN interface, a driver that does not
    report the two features, or one that reports them `[fixed]`. This
    mirrors the helper, which exits successfully in exactly those cases,
    so the two cannot disagree and produce a restart loop.
  - Reported as `gro_flags=` alongside `gro_unit=` in `--check`; both stay
    outside `all_critical_state_healthy()` and the exit code.
- **The gap that motivated the amendment.** The unit is `Type=oneshot`
  with `Restart=no`. If it fails at boot — the exact case Stage 2 already
  anticipates, where the network is not ready yet and `install.sh` prints
  "reconcile yeniden deneyecek" and calls `reset-failed` — then nothing
  retried it. It stayed `failed` until the next reboot or `install.sh`
  re-run. The unit file's own comment claimed reconcile retried every five
  minutes, which had been **false since this decision removed that code**;
  that stale comment is corrected in the same change.
- **Placement detail worth knowing.** The repair runs *before* the
  `all_critical_state_healthy()` early `exit 0`, because otherwise a
  healthy system would return before ever reaching it. It is still
  excluded from that function and from the exit code: a GRO failure is
  throughput-only and must not make `--check` report an unhealthy host.
  It is reported as `gro_unit=` in `--check` output.

### DD-12: wg-easy's pending first-run setup must never gate Stage 7 or `--check` (2026-07-28)

- **Superseded by DD-120 (2026-09-14):** wg-easy is removed; WireGuard runs in
  the host kernel from `kurulum/wireguard`.

- **Decision:** `probe_compose_runtime()`'s `/setup`-redirect branch (the
  case where wg-easy's admin account hasn't been created yet) sets a flag
  but deliberately **not** `runtime_ok=1` —
  so it doesn't count toward `COMPOSE_RUNTIME_DRIFTED` or
  `all_critical_state_healthy()`. The other two branches in the same
  `if`/`elif` chain (WireGuard port mismatch after setup, netfilter
  drift) are unaffected and still count as real drift.
- **Context:** `SECURITY_REVIEW.md` finding **H6**, found via the second
  live Tier 3 install attempt (2026-07-28) — every fresh install failed
  at Stage 7's `master-network-reconcile --check` postcondition call
  specifically because of this branch, before this fix.
- **Rationale:** A pending wg-easy setup is the *expected* state of every
  fresh install (M6 made it fully manual) — not a real problem
  `--check`/Stage 7 should ever fail on. The periodic reconcile timer's
  own, separate `RECOVERY_FAILED` reporting (keyed directly on
  `WG_CONFIGURATION_INVALID`, further down the script) still surfaces it
  to operators via journald on every cycle until the human completes
  setup — this decision only affects the two callers of
  `all_critical_state_healthy()` (`--check` mode and the non-check mode's
  own early-exit), not operator visibility.
- **Trade-off:** None identified — this is a strict correction of an
  oversight in how **M6** interacted with a check written before it.
  Anyone extending `probe_compose_runtime()` with a new "expected,
  non-actionable" state should follow the same pattern: track it via a
  separate flag consumed by `RECOVERY_FAILED`, not `runtime_ok`.

> **Corrected 2026-08-04 (`Q1-29`).** Two details above went stale and were
> wrong as written. (1) The flag: a later revision split the pending-setup
> case into its own `WG_SETUP_PENDING`, so the `/setup` branch has not set
> `WG_CONFIGURATION_INVALID` for some time. (2) The consequence: because
> `RECOVERY_FAILED` is keyed on `WG_CONFIGURATION_INVALID` alone, the claim
> that "the periodic reconcile timer's own, separate `RECOVERY_FAILED`
> reporting still surfaces it to operators via journald on every cycle" had
> stopped being true. After the split the *only* remaining signal for a
> pending setup was a stderr line emitted from inside the probe itself.
> `Q1-29` restores the visibility this decision assumed, deliberately and in
> one place: the detection site reports it once per cycle, and `--check`
> carries `wg_setup=` so `master-network --status` shows it as data. The
> substance is unchanged — a pending setup is still not drift and still must
> not fail `--check` or Stage 7. See DD-48.

### DD-13: Reconcile's disk-space check reports but never auto-repairs (2026-07-28)

- **Decision:** `disk_space_ok()` (checks the filesystem backing
  `$DOWNLOADS_PATH`, now persisted in `state.env`) is wired into
  `all_critical_state_healthy()` and the final postcondition
  re-verification block, but there is **no** repair action anywhere in
  the script for low disk space.
- **Context:** Added after a user-requested final architecture review
  considering the server's actual workload (continuous
  downloading/extraction) — previously the one realistic operational
  failure mode reconcile had zero visibility into.
- **Rationale:** Every other reconcile-managed drift has a safe,
  well-defined repair (reapply a sysctl, rewrite a firewall chain,
  restart a container from a known-good image). There is no equivalent
  safe action for "disk is full" — deleting files would mean guessing at
  which of the user's downloaded/extracted data is safe to remove, which
  this project has no basis to do automatically. The check exists purely
  to surface the condition early (via `--check`'s exit code and the
  periodic timer's own failed-unit visibility), not to fix it.
- **Trade-off:** Unlike most other critical-state components, this one
  will not resolve itself on the next cycle — it stays failed until a
  human frees space or grows the disk. Considered and rejected: an
  automatic prune of the oldest files in the downloads tree (too risky/
  presumptuous to implement without the user's explicit, scoped
  instruction on what's safe to delete).

### DD-20: WebDAV is a hardened host service (rclone), not a container (2026-07-30)

The `sftpgo` container was removed and replaced by
`master-webdav.service`, a systemd unit running `rclone serve webdav
$DOWNLOADS_PATH/media --read-only`, bound to the Tailscale IPv4 only.

**Why, honestly.** The user's stated motivation was intermittent playback
stalls on Apple TV/Infuse, attributed to the container layer. That
attribution is probably wrong and was said so at the time: on the direct
path (`TS_IP:65113`) Docker's DNAT happens in the kernel and
`docker-proxy` is not involved — Docker's own OUTPUT rule excludes
loopback (`! -d 127.0.0.0/8`), so only the `webdav.<domain>` Caddy path
went through a userspace relay. The likelier causes of intermittent
stalls are Tailscale falling back to a DERP relay, `wireguard-go`'s
single-core userspace throughput, or the send-side socket buffer. **None
of those are fixed by this change**, and if the stalls persist, that is
where to look next — not here.

What the change *is* justified by, independently of throughput:

- **The security win is the real one.** The narrow `--ctorigdst
  $TAILSCALE_IPV4 --ctorigdstport 65113` ACCEPT in the mangle guard chain
  was the **only** Tailnet → Docker exception in an otherwise fail-closed
  policy. A host service receives its traffic on the INPUT path, which
  the guard chain never inspects (the same reason Caddy and dnsmasq need
  no exception), so that rule is simply gone. The Tailnet → Docker
  direction now has zero exceptions.
- **Less to keep alive.** One container, one image pin, one DNAT rule,
  three port-binding checks, two `assert_docker_binding` calls and the
  `--ctorigdst` install-time assertion all disappeared.
- **Sandboxing did not regress.** The container gave a `:ro` bind mount.
  The unit gives `ProtectSystem=strict` + `ProtectHome` + `PrivateTmp` +
  `PrivateDevices` + `NoNewPrivileges` + `RestrictAddressFamilies`, plus
  `rclone --read-only`, running as a dedicated `master-webdav` system
  user that holds gid 1000 purely to read the 0750 media tree.

**Why rclone and not Apache/mod_dav or a host SFTPGo.** rclone is in
Debian trixie (1.60.1), is a single binary with no configuration file,
and takes everything as flags. Apache would deliver higher raw throughput
via `sendfile` and could natively `Listen` on two addresses, but the
bottleneck here is `wireguard-go`, not the file server — the extra
package tree and config surface buys nothing. Host SFTPGo was rejected
outright: it is not in Debian, so it would add an external apt repo or a
GitHub release to a project that pins everything, and it keeps all of
SFTPGo's complexity while removing only the veth hop.

**Two constraints that shaped the implementation.**

1. *Single `--addr`.* Debian's rclone is 1.60.1; repeatable `--addr` came
   later. The service therefore binds the Tailscale IPv4 **only**, and
   Caddy's `webdav.<domain>` vhost proxies to `{$TS_IPV4}:65113` rather
   than loopback. Binding `0.0.0.0` and relying on a firewall rule was
   rejected: a specific bind is a stronger primitive than a rule that can
   drift.
2. *`EnvironmentFile` is read before `ExecStartPre`.* The obvious design —
   copy Caddy's `caddy-tailnet-env` `ExecStartPre` writing
   `/run/.../tailscale.env`, consumed via `EnvironmentFile=` — is **broken
   for this service**, and was caught in review before it shipped. systemd
   loads environment files when the unit starts, before any `Exec*`
   command runs, so on a first start the file does not exist yet,
   `${TS_IPV4}` expands to empty, and `--addr :65113` becomes a **wildcard
   bind — the public IPv4**. Caddy escapes this only because the `caddy`
   binary re-reads the file itself via `--envfile`; rclone has no
   equivalent. The fix is to resolve the address *inside* `ExecStart`:
   `master-webdav-serve` waits for `tailscale0`, then `exec`s rclone. This
   removes the failure class rather than working around it.

`rclone --config /dev/null` is passed explicitly: the service uses no
remotes, and without it rclone searches `$HOME/.config`, which does not
exist under `ProtectHome=yes` — behavior there varies by version, so it
is pinned rather than left to chance.

**Candidate cleanup, not done:** `master-webdav-serve` and
`caddy-tailnet-env` now contain the same tailscale0-address wait loop.
They were left separate because `caddy-tailnet-env` is generated only when
local DNS is enabled and is part of the canonical bundle contract, while
the WebDAV helper is unconditional. Merging them means reworking that
contract — worth doing, but not inside this change.

**Live verification (2026-07-30) — the first install failed, and found
three real bugs.** Static analysis had passed cleanly on all of them.

1. **`RestrictAddressFamilies=AF_INET AF_INET6` broke the service.**
   `ExecStart`'s first act is `ip addr show` to find the Tailscale
   address, and iproute2 talks to the kernel over a **netlink** socket —
   a separate address family. Measured directly: with the two-family
   restriction, `Cannot open netlink socket: Address family not supported
   by protocol`; adding `AF_NETLINK`, it works. rclone itself needs only
   AF_INET/AF_INET6.
2. **The failure was invisible.** The wait loop had `2>/dev/null … ||
   true` on the `ip` call, so a hard configuration error was
   indistinguishable from "the address hasn't appeared yet". The unit
   reported `active (running)` for the full 300-second window while
   getting nowhere; the install only failed later, at Stage 7's listener
   assertion. The loop now separates the two cases and reports the first
   `ip` error immediately. (The first attempt at this used `mktemp` for
   stderr, which itself failed under `ProtectSystem=strict` with
   `Read-only file system` — caught in the same session. stderr is now
   captured into a variable, which also avoids creating 300 temp files.)
3. **Every 401 probe was wrong.** rclone deliberately exempts `OPTIONS`
   — the WebDAV discovery preflight — from authentication and answers
   `200`. sftpgo returned `401` there, and all three probes
   (`webdav_direct_ok()`, Stage 7's direct check, `caddy_runtime_ok()`'s
   vhost check) had been written against that behavior. Left as-is,
   Stage 7 would fail every install and reconcile would classify WebDAV
   as drifted on every cycle and restart it. They now use `PROPFIND`
   with `Depth: 0`, a protected method — which is a **stronger** signal
   than the original, since a 401 there proves the htpasswd is actually
   being enforced rather than merely that something answered.

   Worth stating plainly because it looked alarming mid-diagnosis:
   authentication was never broken. Measured on the running service —
   unauthenticated `GET` and `PROPFIND` both `401`, wrong password `401`,
   correct password `207`, and an unauthenticated `GET` returns the body
   `Unauthorized`. Only `OPTIONS` is open, and it discloses nothing.

**Confirmed working after the fixes**, on the live host: the listener
binds `<tailscale-ip>:65113` and nothing else (connection refused on the
public IPv4), unauthenticated `PROPFIND` → 401, authenticated → 207, and
the `master-webdav` user reads the 0750 media tree through its gid 1000
membership exactly as designed. **Still unconfirmed:** Infuse itself has
not been pointed at the service, so real-client `Range`/seek behavior and
playback remain untested.

### DD-21: The reconcile timer runs every 20 minutes, aligned with the repair cooldown (2026-07-31)

- **Decision:** `master-network-reconcile.timer` fires every 20 minutes
  (`OnCalendar=*-*-* *:00/20:00`), not every 5 as it did from R1.0
  through `V1-8`.
- **Rationale — not cost.** A healthy check takes about half a second, so
  at 5-minute intervals the duty cycle was under 0.2%; CPU was never the
  argument. The real problem was a cadence mismatch that had been there
  all along: `RESTART_COOLDOWN_SECONDS` is 900. On a *persistent* fault
  the 5-minute timer produced one run that repaired and then two that
  could only detect — each logging `cooldown içinde; tekrarlanmadı`,
  setting `RECOVERY_FAILED=1`, exiting non-zero and leaving a failed
  unit behind. Two thirds of the runs were noise that could not act. With
  the interval above the cooldown, every scheduled run can actually
  repair, and the budget goes back to being what it was meant to be — a
  brake on the event-driven (`OnFailure`) paths, which can fire at any
  moment.
- **Why 20 specifically:** it divides 60, so the schedule is `:00 :20
  :40` — evenly spaced. Values that do not divide 60 leave a short gap at
  the hour boundary: `*:00/18:00` yields `:00 :18 :36 :54` and then only
  6 minutes to the next `:00`. An interval that is silently uneven is
  worse than a longer even one.
- **What this costs:** drift with no event trigger now takes up to 20
  minutes to be corrected instead of 5 — address changes (Tailscale or
  public IPv4), manual edits to managed config, GRO flags cleared by a
  driver reload, a filling disk. The address case is the one a user would
  feel, since WebDAV, Caddy and dnsmasq all bind the Tailscale IPv4. It
  is accepted because on this deployment the public IPv4 is static and
  the Tailscale address only changes on node re-registration, which in
  practice means a reinstall — and `install.sh` corrects it directly.
- **What this does not change:** crash recovery. Five `OnFailure=` hooks
  plus the `PartOf`/`Wants` cascades from `docker.service` and
  `tailscaled.service` invoke reconcile immediately, independent of the
  timer. The timer was never the mechanism for a service falling over; it
  is the net for *silent* drift, and only that latency moved.
- **Reversing it:** change the single `OnCalendar` line. Nothing else
  depends on the interval — the cooldown is expressed in seconds and the
  checks are stateless.

## Rejected Alternatives

- **Using `nftables` directly instead of `iptables`/`ip6tables`:** not
  pursued; Debian 13's `iptables` package already provides the
  nftables-backed `iptables`/`ip6tables` compatibility binaries, so the
  existing rule-based logic works without a rewrite. **Partially
  verified 2026-07-28:** the host's own `iptables`/`ip6tables` do run
  through the nftables backend (`nf_tables`/`nft_compat` kernel modules)
  — discovered as the root cause of the **H1** regression, where
  wg-easy's container uses the **legacy** backend instead (needing its
  own separate `ip6_tables`/`ip6table_nat` modules the host's nft-backed
  usage never loads). Not verified beyond this one concrete case whether
  anything else in the script assumes one backend over the other.
- **Merging operator config changes into the canonical bundle instead of
  reverting them (see DD-3):** rejected as intractable to do safely for
  security-sensitive firewall/proxy configuration; a deterministic
  "canonical always wins" model was chosen instead.

## Open Trade-offs

- Whether to keep the fixed six-service bundle (simple, one config to
  reason about) vs. introduce installation profiles (more flexible, more
  combinations to test) — see `docs/profiles.md`.
- Whether the `PartOf` fate-sharing model (DD-4) should be loosened for
  operator convenience at the cost of weaker failure-isolation guarantees.
- Whether to keep all logic in one file (DD-9) vs. extract embedded
  scripts into separate, independently lintable/testable files at the
  cost of a more complex deployment/packaging story.
- Whether wg-easy's host-kernel WireGuard module dependency (DD-10) is
  acceptable long-term, or worth replacing with a userspace WireGuard
  backend (`boringtun`/`wireguard-go`) that would need no kernel module at
  all — the latter needs a forked/customized image and hasn't been
  attempted.

### DD-14: The canonical bundle is published through a verified generation pointer (2026-07-28; corrected 2026-08-02)

- **Decision:** Stage 4 writes `/etc/master-stack/state.env` but does not
  publish a canonical copy or a `SHA256SUMS` manifest. At the end of
  Stage 6, all nine bundle files and the manifest are written into a new
  `.generation.*` directory and verified there. Only then is the
  `/usr/local/share/master-stack/current` symlink replaced with one
  same-filesystem `rename(2)` operation. Reconcile reads through that
  pointer.
- **Context:** `SECURITY_REVIEW.md` findings **M8** and **H8**.
- **Rationale:** `canonical_bundle_ok()` validates the manifest's entry
  list, and a partial bundle fails that check. Publishing `state.env` in
  Stage 4 alongside a state.env-only manifest left the bundle incomplete
  for the whole of Stages 4-6, and an interrupted re-run left reconcile
  hard-exiting on every cycle with no self-healing.
  *(As originally written this rationale turned on the manifest being
  validated against the `LOCAL_DNS_ENABLED` value inside the canonical
  `state.env`. `V1-8` removed that key — local DNS is no longer optional —
  so the manifest now has a single fixed shape. The decision stands
  unchanged; only its justification simplified.)*
- **Correction recorded by H8:** the first M8 remediation moved the nine
  individual copies to the end of Stage 6 and atomically renamed only the
  manifest. That narrowed the interruption window but did **not** make the
  bundle atomic: a failed fourth or fifth copy left a mix of old and new
  files behind the old manifest, which then failed its hashes. The word
  "atomic" applies only after Q1-16's generation-pointer design.
- **Alternatives rejected:** deleting Stage 4's manifest write alone (a
  fresh install then has no manifest, and a re-run's stale manifest no
  longer matches the newly written `state.env` — both still fail
  validation); writing the full manifest in Stage 4 (impossible on a fresh
  install, where those files don't exist yet); treating an atomic manifest
  rename as an atomic multi-file publication (the H8 defect).
- **Consequence worth knowing:** during Stages 4-6 of a re-run,
  `state_value()` still reads the *previous* run's canonical values. That
  is deliberate — for a half-applied re-run, the last known-good
  configuration is the right thing to enforce. On the first upgrade from
  Q1-15/R2.4, the new reconcile script temporarily accepts the legacy flat
  bundle until Stage 6 publishes `current`; after that publication the
  legacy files are removed so a later missing pointer fails closed rather
  than silently reverting to stale data. Publication retains at most the
  active and immediately previous generations across regular re-runs.

### DD-15: Docker's chain layout is assumed, and Docker itself is deliberately not pinned (2026-07-28)

- **Decision:** `docker-ce`/`containerd.io`/`tailscale`/`caddy` stay
  unpinned even though container images are pinned to exact tags, and the
  firewall helper keeps assuming Docker's internal chain layout
  (`DOCKER-USER`, `DOCKER-FORWARD` and `ts-forward` existing, and being
  the first three `FORWARD` rules in that order).
- **Context:** `SECURITY_REVIEW.md` finding **M9**.
- **Operational fact worth stating explicitly:** because Stage 3 leaves
  the Docker apt repository configured, **every re-run upgrades Docker to
  the newest upstream release** via Stage 1's `full-upgrade`. A re-run is
  therefore also a Docker upgrade, whether or not that was the intent.
- **Rationale for not pinning:** this host publishes ports to the public
  IPv4, so freezing Docker's version would trade a hypothetical layout
  change for a certain loss of CVE fixes. The coupling is the lesser
  risk.
- **Failure mode, for the record:** if a Docker release restructures
  those chains, `ensure_forward_prefix()` returns non-zero and `set -e`
  aborts the helper before any rule is applied. On a re-run the
  previously-applied chains survive (the staging swap only happens at the
  end), so that path fails safe. The real exposure is a **reboot** after
  such an upgrade: these rules have no persistence layer and are rebuilt
  from scratch at every boot, so a broken helper means the fail-closed
  WAN DROP and the Tailnet → Docker/LAN DROP backbone are simply never
  created.
- **Mitigation applied:** diagnostics only — the helper now names the
  missing chain and the likely cause rather than aborting silently.
  Verified live on 2026-07-28 that Docker 29.6.2 still produces exactly
  the assumed layout.
- **Known asymmetry, deliberately left alone:** `apply_ipv6()` degrades
  gracefully when Docker's IPv6 `DOCKER-USER` chain is missing (warns and
  skips the IPv6 policy), but `ensure_forward_prefix()` treats the same
  condition as fatal for either family. Changing it would loosen a
  fail-closed path, so it is recorded rather than "fixed".

### DD-16: Managed firewall rules never reference container IPs (2026-07-29)

- **Decision:** every rule the `docker-tailscale-fw` helper writes matches
  on interface names (`tailscale0`, the detected WAN interface) and *host*
  addresses (the public IPv4, the Tailscale IPv4). None of them names a
  container's bridge address.
- **Why this matters, measured 2026-07-29:** across a reboot, Docker
  assigns container bridge IPs in start order, and that order is not
  deterministic. On one boot `qbittorrent` held `172.18.0.6`; on the next
  it held `172.18.0.2`, with `filebrowser`, `sftpgo` and `portainer`
  likewise shuffled. Docker correctly rewrote all of its own DNAT and
  ACCEPT rules to match. Because our rules never mention those addresses,
  `MASTER-DOCKER`, `MASTER-TS-FORWARD` and the `FORWARD` prefix came back
  **byte-identical** while Docker's chains legitimately changed.
- **Two consequences worth keeping:**
  - `check_ipv4_policy()`/`check_ipv6_policy()` assert the exact contents
    of our chains and the ordering of the `FORWARD` prefix, but say
    nothing about the contents of Docker's `DOCKER` chain. If they did,
    `--check` would report drift after every reboot.
  - `docker_dnat_rule_exists()` in reconcile resolves the container's
    current IP at check time via `docker_network_tuple()` rather than
    comparing against a stored value. That is what lets it verify Docker's
    DNAT rules without breaking when the address changes.
- **Trade-off:** the narrow public allows are therefore expressed against
  `--ctorigdst` (the pre-DNAT destination) rather than the container, which
  is slightly less obvious to read but is the only formulation stable
  across restarts.
- **What would break this:** giving containers static bridge addresses and
  then writing rules against them. Do not — the current arrangement is why
  a reboot needs no reconciliation at all.

### DD-17: Nothing persists firewall rules to disk (2026-07-29)

- **Decision/observation:** no `iptables-persistent`, no `/etc/iptables`,
  and `nftables.service` left disabled. The complete rule set is rebuilt
  from scratch on every boot by `docker.service` (its own chains),
  `tailscaled` (`ts-*`) and `docker-tailscale-fw.service` (`MASTER-*`).
- **Confirmed 2026-07-29:** packet counters reset across a reboot, proving
  the rules are new objects rather than a restored dump, and the rebuilt
  set matches the previous one apart from Docker's container-IP churn
  (DD-16).
- **Rationale:** a persisted dump would be a second source of truth that
  could drift from `install.sh`, and would restore stale addresses at boot
  before the helpers had a chance to detect the current ones. Rebuilding
  is slower by roughly a second and always correct.
- **Consequence for failure analysis:** if the firewall helper ever fails
  to run, the host does not fall back to an older policy — it has *no*
  managed policy until the helper succeeds. That is why
  `docker-tailscale-fw.service` failing triggers reconcile via
  `OnFailure=` immediately rather than waiting for the 5-minute timer.

### DD-18: UDP socket buffer ceilings are floored by the installer, and they are a Tailscale setting — not a WireGuard one (2026-07-29)

- **Decision:** Stage 2 writes `/etc/sysctl.d/99-master-stack-netbuf.conf`
  with `net.core.rmem_max` / `wmem_max` set to
  `max(current_value, 16 MiB)`. `rmem_default` is deliberately left alone.
- **v2 realignment (2026-08-06, `v2-12`):** Early v2 had hardcoded
  `7500000` in `99-master-tailscale.conf` after `apt install tailscale`.
  That under-shot the legacy floor and violated M11 ordering. v2 now
  matches this decision again via `apply_udp_netbuf_floor` before the
  Tailscale package install; forwarding stays in a separate conf file.
- **Why it was needed:** on the live host both values were already 64 MiB
  — but from `/etc/sysctl.d/99-nc-kernel.conf`, a **file shipped by the
  VPS provider's image**, not by this installer. Nothing in `install.sh`
  set them. On any host without that file they fall back to Debian's
  default of 208 KB.
- **Who actually benefits — and the mis-attribution that produced this
  entry.** This was first proposed as a *WireGuard* optimization. That was
  wrong, and measurement is what caught it. Kernel WireGuard (what
  `wg-easy` uses) attaches an `encap_rcv` callback to its UDP socket;
  `udp_queue_rcv_one_skb()` hands the packet to that callback **before**
  the socket receive queue is involved, so `rmem_max` never gates its data
  path. The evidence, taken inside the container's netns after 6.19 GiB of
  real peer traffic:

  ```
  Udp: InDatagrams 5074319 ... RcvbufErrors 0  SndbufErrors 0  MemErrors 0
  /proc/net/udp  00000000:FE93 (port 65171 = wg0)  rx_queue=00000000  drops=0
  ```

  The setting matters for **Tailscale**, which is *userspace* WireGuard
  (`wireguard-go`) and does read from a UDP socket: `tailscaled` was
  observed holding `rb14680064` (14 MiB). At Debian's 208 KB ceiling that
  request would have been clamped ~70× smaller, silently costing
  exit-node throughput. Since being a Tailscale exit-node is this host's
  primary function, the finding survived — it just changed owner.
- **Why raising a ceiling is safe here, and why the qBittorrent
  experience does not apply.** `mem_limit`/`cpus` are cgroup ceilings that
  *constrain*: hitting one takes throughput away, which is exactly what
  happened in **M1**. `rmem_max` is the opposite kind of ceiling — it
  allocates nothing and only sets the largest value a process may request
  via `setsockopt(SO_RCVBUF)`. Raising it cannot slow anything down; it
  can only stop clamping. `rmem_default` *is* applied to every socket that
  does not ask for a size, so touching that one would have raised baseline
  memory use across the system — which is why it is excluded.
- **Raise-only, never lower.** The value is computed as a `max()` against
  whatever is already in effect, so a provider that sets 64 MiB keeps it
  and a re-run is idempotent. Simulated across the Debian default, a
  provider 64 MiB, an exact-floor value, and malformed/empty input.
- **Not reconciled, and that is deliberate.** Unlike ethtool flags, a
  `sysctl.d` file survives reboots by construction — the file on disk *is*
  the guarantee, so there is nothing for a 5-minute loop to repair. This
  is the same reasoning as DD-11, applied to a setting that happens to be
  persistent rather than volatile.
- **Known limitation:** `sysctl.d` applies files in lexical order, so a
  provider file sorting after ours that sets a *lower* value would win.
  The `max()` handles the realistic case (provider sets it higher); the
  inverted case is accepted as exotic and is not defended against.

### DD-19: The Tailscale login stays in Stage 2 — reordering it was tried, measured, and reverted (2026-07-29)

`install.sh` has exactly one step that blocks on a human: `tailscale up`
prints a `login.tailscale.com` URL and waits for the browser flow. It sits
in the middle of Stage 2, behind `apt-get full-upgrade` and two package
installs. A user reported it as "the link falls behind, I can't see it; it
only shows up after a very long wait", and a reordering was built and
shipped as `v1.1-1`: TUN check, Tailscale repo, sysctls, package install,
daemon start and login all moved into Stage 1, with `full-upgrade` moved
behind them. **It was reverted the same day.** Keep this entry so the
reordering is not proposed a second time on the same reasoning.

- **What the measurement showed.** On a clean install of `v1.1-1`:

  ```
  19:17:15  Stage 1 begins
  19:17:25  login banner on screen        (+10s, was ~4-6 min)
  19:17:25  control: RegisterReq sent
  19:22:06  control: AuthURL is https://login.tailscale.com/a/...
  ```

  The reorder did exactly what it was designed to do — the script reaches
  the login in ten seconds instead of minutes. It did **not** fix the
  complaint, because **4m41s of the wait is Tailscale's control plane
  taking that long to answer the first `RegisterReq`**, and nothing in
  `install.sh` influences that. The URL reached the terminal in the same
  second `tailscaled` received it, which also disproves the buffering
  hypothesis for good: `tee`'s stdout is fd 5 (`/dev/tty`), glibc
  line-buffers it, and delivery is immediate.
- **The network was eliminated as a cause.** IPv4 and IPv6 both reached
  `controlplane.tailscale.com` in ~25 ms, 1500-byte frames passed `-M do`
  on both stacks (no PMTU blackhole), and the TCP connection to the
  control plane was `ESTAB` with an empty queue the whole time.
  `tailscaled` logged nothing between `19:17:30` and `19:22:06`; it was
  simply waiting.
- **Why it was reverted.** The user's call: the reorder bought ~4-6
  minutes of apt work moved behind the login while leaving the dominant
  ~4m41s untouched, so it did not solve the reported problem.
- **The `RegisterReq` latency is control-plane variance, and a warm-up
  race was ruled out.** A V1 install run 22 minutes later on the same
  host, with the original ordering, produced:

  ```
  19:39:47  Starting tailscaled.service
  19:39:48  health(warnable=warming-up): error: Tailscale is starting.
  19:39:48  StartLoginInteractiveAs("root")
  19:39:48  control: RegisterReq: fup=false
  19:39:53  health(warnable=warming-up): ok
  19:39:54  control: RegisterReq: got response; authURL=true
  ```

  **6 seconds instead of 4m41s** — and note that the original ordering
  issues `LoginInteractive` one second after the daemon starts, *inside*
  the same warm-up window. An earlier draft of this entry claimed the GRO
  block gives the daemon "3-6 seconds to settle" that the reorder removed;
  that is wrong, and this measurement is what disproves it. Both orderings
  log in during warm-up, so warm-up cannot explain the difference. The
  4m41s was Tailscale-side variance, not something either ordering
  caused.
- **What a future attempt would have to beat.** With the control-plane
  latency established as variable and usually small, the only thing left
  for a reorder to buy is the apt time ahead of the login — real on a
  genuinely fresh host, near-zero on a re-install (the V1 run above
  completed Stage 1 in 7 seconds because `full-upgrade` and the packages
  were already current). Measure that on a cleanly reimaged host before
  proposing the restructuring again.
- **Separable ideas that did not cause the revert.** The framed login
  banner (bell + bold-cyan frame closing *before* the URL, so the link is
  the last thing on screen) and the Stage 0 heads-up are independent of
  ordering and could be re-applied on their own. So was the **M11** sysctl
  ordering defect, which the reorder happened to fix as a side effect and
  which the revert reintroduced — it was then fixed on its own in `V1-1`
  by moving the netbuf block ahead of `apt-get install -y tailscale`,
  without any of the Stage 1/2 restructuring.
- **A packaging fact both orderings have to respect.** Debian's
  `tailscale.postinst` runs `deb-systemd-invoke restart
  'tailscaled.service'`, so the daemon starts inside `apt-get install -y
  tailscale`; the script's own `systemctl enable --now tailscaled` is a
  no-op. Verified 2026-07-29: `dpkg configure tailscale` 19:17:24,
  `systemd: Starting tailscaled.service` 19:17:24, `status installed`
  19:17:25. This makes the intuitive "install Tailscale first, tune for it
  afterwards" ordering wrong for anything that must be in place before the
  daemon opens its UDP socket — `net.core.rmem_max` in particular. It does
  not apply to `ip_forward`, which is read dynamically and only needs to
  be set before `tailscale set --advertise-exit-node`.

### DD-22: A wg-easy still on its `/setup` screen is reported, not failed (2026-07-31)

- **Superseded by DD-120 (2026-09-14):** wg-easy is removed; WireGuard runs in
  the host kernel from `kurulum/wireguard`.

- **Decision:** the reconcile helper distinguishes "wg-easy is waiting for
  its first web setup" (`WG_SETUP_PENDING`, reported as `UYARI`, no effect
  on the exit code) from "wg-easy's internal WireGuard port does not match
  `WG_PUBLIC_PORT`" (`WG_CONFIGURATION_INVALID`, `HATA`, sets
  `RECOVERY_FAILED` → exit 1). Both still suppress wg-easy's automatic
  restart.
- **Why:** until `V1-11` both used the single `WG_CONFIGURATION_INVALID`
  flag, and the resulting exit code was wrong in a specific and unhelpful
  way. Because `all_critical_state_healthy()` returns early with `exit 0`,
  a fresh install where nothing had drifted looked fine — while any pass
  that actually *repaired* something fell through that gate to the
  `RECOVERY_FAILED` check and exited 1, with every repair having
  succeeded. The signal was therefore correct only while reconcile was
  idle and wrong as soon as it did work, which is the inverse of what a
  monitoring signal is for. `master-network-reconcile.service` being the
  `OnFailure=` target of five other units made it worse: a chronically
  red unit is one an operator learns to ignore.
- **How it was found:** two drift scenarios on a live host on 2026-07-31 —
  stopping `master-webdav.service`, and appending a line to
  `/etc/caddy/Caddyfile`. Both repaired correctly (WebDAV back to 207, the
  Caddyfile restored byte-for-byte) and both exited 1. The healthy pass
  immediately afterwards exited 0. Static review had not caught it, and
  would have had a hard time: the comment above the check already
  described the intended behavior, so reading the comment and the code
  together produced a false sense that the intent was implemented. It was
  — but only along one of the two paths out of the function.
- **The restart suppression stays in both branches** deliberately.
  Restarting a container that is waiting for its first web setup does not
  advance it, and would reset whatever partial setup state exists.
- **Both branches are measured, not one measured and one reasoned.** The
  failing branch stayed untestable while wg-easy sat on `/setup`, because
  `wg show wg0 listen-port` has no interface to report on until setup is
  done. Once the operator completed it (2026-07-31),
  `wg set wg0 listen-port 51820` — runtime-only, reversible, `wg0.conf`
  untouched — produced `HATA: wg-easy iç portu 51820; beklenen 65171.`,
  `compose_runtime=1` and `exit 1`, with wg-easy correctly *not*
  restarted. Restoring the port returned `exit 0` with the peer intact.
  This is worth recording as a method as much as a result: the two
  branches of a split like this one are only trustworthy when the
  *negative* case has been shown to still fail, otherwise "we stopped
  failing" is indistinguishable from "we stopped checking".
- **What would remove the condition entirely:** provisioning wg-easy's
  admin account unattended (the open `INIT_*` item), which is the real fix
  for the underlying awkwardness — a freshly installed stack that is not
  actually finished. `V1-11` only stops it from being misreported.

### DD-23: Container images float at the patch level, and their digests are recorded (2026-07-31)

- **Decision:** the five container images use moving tags rather than
  exact versions, and the digest each tag resolved to is written into
  `state.env` after Stage 5 (`STACK_SCHEMA` 10).

  | Image | Tag | How far it moves |
  |---|---|---|
  | wg-easy | `15.3` | patch only |
  | unpackerr | `0.15` | patch only |
  | filebrowser | `v2` | anything within the major — no `v2.63` tag is published |
  | portainer | `lts` | within the LTS line; jumps a major when Portainer declares a new LTS |
  | qbittorrent | `latest` | upstream stable, including a libtorrent major |

- **Why not exact pins:** they made a re-run deterministic but also froze
  security and bugfix updates. Debian-sourced host packages (kernel,
  dnsmasq, systemd) already behave as "patches arrive, majors do not"
  because trixie is stable; floating container tags extend the same rule
  to the rest of the stack instead of running two opposite policies side
  by side.
- **Why not pin the third-party host packages instead.** That was the
  first proposal (`docker-ce`, `tailscale`, `caddy` from their own repos
  can jump majors on a re-run, since their `sources.list` entries persist
  and Stage 1's `full-upgrade` sees them). The user rejected it on the
  grounds that it trades away security updates, and that is the correct
  reading: the existing safety net — upgrade first, rewrite all managed
  configuration afterwards, then assert in Stage 7 — is what makes an
  unpinned upgrade survivable, and it is already in place.
- **Why the float levels are uneven:** because the upstreams' published
  tags are uneven. Queried from the registries on 2026-07-31; filebrowser
  publishes no minor tag at all, and linuxserver publishes no float tag
  for qbittorrent beyond `latest`. Both `lts` and `latest` were verified
  to resolve to the same digests as the exact pins they replaced, so
  adopting them changed nothing on the day — which is the safest way to
  take on a moving tag.
- **Why digests are recorded, and why that is not optional.** A moving
  tag deletes the answer to "what is actually running": `compose.yaml`
  keeps the same checksum while the image underneath it changes. The
  five `IMAGE_DIGEST_*` keys restore it, `--status` prints the short form
  next to each container, and Stage 7 asserts that the recorded digest
  equals the running one — so the record cannot quietly drift from
  reality. Floating tags without this record would be a straight loss of
  auditability; the pair is the design, not the tag change alone.
- **The asymmetry to keep in mind:** upgrading is safe — every one of
  these containers reads its existing data directory and continues — but
  **downgrading is not.** Portainer migrates its database forward on
  start with no reverse path. Re-pinning an old tag therefore does not
  undo a bad upgrade. The recovery path is a provider-level (netcup) VPS
  snapshot taken before the run, which the user chose deliberately over
  an in-script snapshot: a whole-machine image covers the migrated
  databases, and it keeps rollback out of the installer's scope.
- **Cost accepted:** a patch-level regression can arrive on a routine
  re-run. Two things bound it — reconcile never pulls (only Stage 5's
  explicit `docker compose pull` does, so images never move on the
  20-minute timer), and the digest record names the version to go back
  to.
- **Found while implementing, worth recording:** `RepoDigests` is a field
  of the *image* object, not the container. `docker inspect <container>`
  fails with `map has no entry for key "RepoDigests"`, and the first
  `V1-12` attempt wrote all five digests as `bilinmiyor`. Stage 7's
  assertion caught it and failed the install with `rc=1, aşama=7` — the
  intended behaviour, and the second time in three revisions that a Stage 7
  literal assertion caught a change that `bash -n`, `shellcheck` and the
  bats suite all passed.

### DD-24: Network steps get a bounded retry and a mandatory timeout (2026-07-31)

- **Decision:** every network-dependent step in `install.sh` runs through
  `retry_network` — three attempts, an explicit per-attempt `timeout`,
  5s/15s backoff. Applied to `apt-get update`, the three keyring/repo
  fetches, and `docker compose pull`. Not applied to
  `apt-get full-upgrade` or `apt-get install`.
- **The timeout is the point, not the retry** — the reverse of how the
  finding (L8) was originally framed. What prompted it was a Docker Hub
  502 during `docker compose pull`, and a retry does fix that. But
  reading the surrounding code moved the priority: the script runs under
  `systemd-inhibit --what=shutdown:sleep --mode=block` and holds the
  `flock` it shares with `master-network-reconcile`. A hung download
  therefore blocks shutdown *and* prevents the 20-minute reconcile timer
  from running, with no bound at all. The 502 failed loudly and safely —
  install stopped, re-run succeeded. A hang would have failed silently
  and held two locks while doing it.
- **No error classification, deliberately.** The first design sketched
  matching stderr to decide what was retryable. It is unnecessary:
  permanent failures (`manifest unknown`, `unauthorized`, a full disk)
  return within seconds, so three blind attempts cost them roughly 20s of
  backoff and then the same clear error. Only transient faults and hangs
  consume meaningful time, and those are precisely what we want retried
  or bounded. String-matching upstream error text would also be locale-
  and format-dependent — fragile, for no gain.
- **Budgets measured, not guessed** (2026-07-31, netcup host): cold
  `docker compose pull` 10.9s for 885 MB across three registries, warm
  pull 3.2s, `apt-get update` 0.9s, keyring fetches 36–127 ms. Bulk gets
  300s then 180s (~27× the measured cold pull); small fetches 60s then
  30s. A link would have to be ~27× slower than this host for a legitimate
  pull to be cut — and even then the operator gets a timeout message
  naming the budget rather than a silent stall.
- **Why apt transactions are excluded:** `full-upgrade` and `install`
  drive dpkg. Interrupting one mid-transaction and reissuing it is a
  different problem class, and it interacts with the `--force-confdef
  --force-confold` handling. Wrapping them would relocate the risk rather
  than reduce it. `apt-get update` is wrapped because it is genuinely
  idempotent.
- **The Caddy GPG fetch was restructured** rather than wrapped as-is: it
  used to be `curl … | gpg --dearmor`, and retrying the whole pipeline
  would also retry the local dearmor step, which can never be fixed by
  retrying (bad input is bad three times). The download now goes to a
  temp file inside the retry, and `gpg` runs once outside it.
- **All four control-flow paths are verified**, and the design note that
  preceded this entry was wrong to claim otherwise. It said the recovery
  path — transient failure followed by success — could not be tested
  deterministically without a real flaky network. A stub that fails once
  and then succeeds reproduces it exactly. `test/retry_network.bats`
  covers first-attempt success, exhaustion, timeout (asserting `124` and
  that the message differs from an ordinary failure), recovery, and
  argument pass-through. The suite self-skips where GNU `timeout` is
  absent, so it skips on the macOS workstation and runs for real on the
  Debian target — where the full suite passes with zero skips (62 cases at
  the time; 74 after the `M7` coverage correction later the same day).

### DD-25: The repair cooldown is duplicated on purpose, and asserted (2026-07-31)

- **Decision:** the 15-minute repair cooldown stays written out in both
  embedded scripts — `RESTART_COOLDOWN_SECONDS` in
  `master-network-reconcile`, `COOLDOWN_SECONDS` in
  `master-docker-netfilter-recovery` — with `install.sh` declaring
  `MASTER_RESTART_COOLDOWN_SECONDS` as the single source of truth and
  **Stage 7 asserting all three agree**.
- **Why not actually share one variable.** Every embedded script must be
  self-contained, because `scripts/lint-embedded-scripts.sh` extracts each
  one by its heredoc marker and runs `bash -n` + `shellcheck` on it as a
  standalone program — the mechanism that answers **H4**, since the outer
  `shellcheck install.sh` sees these bodies only as string data. Binding
  the two scripts to a shared variable, or splitting a heredoc so an
  unquoted prelude could interpolate one, would leave the linted fragment
  referencing a variable it never assigns. That trades a real property
  (the linter checks exactly what ships) for a cosmetic one.
- **What the duplication actually risked** was never the second copy
  itself; it was *silent* divergence. DD-21 moved the reconcile timer to
  20 minutes specifically to stop fighting this cooldown, so the two
  numbers are coupled by a design decision — and one of them could have
  been changed with the other quietly left behind. Stage 7 now turns that
  into a failed install naming all three values.
- **Three copies were removed outright**, which is the part that is a
  genuine deduplication rather than a guard: the operator-facing messages
  in both scripts hardcoded the string "15 dakikalık cooldown". They now
  derive it (`$((RESTART_COOLDOWN_SECONDS / 60))`), so the prose cannot
  contradict the behaviour.
- **`StartLimitIntervalSec=900` in three systemd units is deliberately
  left alone.** It shares the value but not the meaning — systemd's
  start-rate limiter is a different mechanism from the repair budget, and
  folding them together would create a coupling that does not exist.
- **The assertion was verified to discriminate, not assumed to:** a copy
  of `install.sh` with the recovery constant changed to `800` was
  installed on the test host and failed at Stage 7 with
  `install.sh : 900 / reconcile : 900 / recovery : 800`. This is the same
  discipline applied to `all_critical_state_healthy`'s coverage guard the
  same day — a guard nobody has seen fail is not yet known to work.

## DD-26 — reserved

**Not used on this branch.** `DD-26` belongs to the dufs migration on
`master` (`V2-1`/`V2-2`). This branch forks from `V1-20`, which predates
it, so the number is left empty rather than reused — two different DD-26s
across two branches would collide the moment they are compared or merged.

### DD-27: FileBrowser Quantum replaces filebrowser, and its admin password is deliberately not set (2026-08-01)

**Decision.** On the `quantum` branch (forked from `V1-20`), swap
`filebrowser/filebrowser:v2` for `ghcr.io/gtsteffaniak/filebrowser:stable`
— FileBrowser Quantum, the actively maintained fork — keeping the
container name, the host port, and every piece of surrounding plumbing
unchanged. Do **not** bootstrap its admin password from the installer.

**Why this branch exists at all.** `master` already answered "what
replaces filebrowser" with dufs (DD-26), driven by filebrowser's
2026-09-01 archival and its three permanently unpatched advisories. That
answer holds on its own terms, but it cost interface quality — recorded as
**L11**, the one axis where the swap went backwards. Quantum is the other
candidate from that same evaluation. This branch tests it against the
`V1-20` line rather than against `master`, because `V1-20` is what is
installed on the host today and because leaving `master` untouched means
the experiment can be abandoned by deleting a branch.

**What Quantum is better at.**

- **Tag hygiene, and it is the best in the stack.** Upstream publishes
  both a moving `stable` tag and exact pins (`1.5.0-stable`). Original
  filebrowser offered only major-wide `v2`; dufs offers no float at all,
  which is precisely what **L9** records as an open cost. `stable` is
  therefore chosen here, and it satisfies DD-23's rule ("take the finest
  float the upstream actually publishes") for the first time in this slot.
  The risk is named rather than hidden: `2.0.0-preview-*` tags already
  exist, so `stable` will one day cross a major boundary silently.
- **Shell commands are removed from the codebase entirely**, per
  upstream's own feature list. That is filebrowser's unpatched
  `GHSA-8c9q-7855-wfxq` (command-allowlist bypass via shell
  metacharacters) eliminated by deletion rather than by configuration —
  strictly stronger than the `Exec Enabled: false` that made it
  unreachable on the old build.
- The interface is the reason the branch exists; that judgement is the
  operator's and is not argued here.

**What it costs.** Quantum is **stateful**: the image declares
`FILEBROWSER_DATABASE=/home/filebrowser/data/database.db`, so a named
volume returns where dufs needed none. Since `Q1-12` the compose file
repeats that value instead of inheriting it. Nothing was wrong with the
inherited one — the point is that `read_only: true` turns it into a
constraint rather than a preference: the path has to land inside the
`filebrowser_data` mount, because a Quantum that opens its database
anywhere else opens it on a read-only root and dies at startup. Two lines
that must agree now sit next to each other in the same file, rather than
one of them living in an image the project does not control. The failure
this guards against is loud (a boot-loop `reconcile` catches), not silent,
which is why it is a small hardening and not a fix.

**The first-boot warning is upstream noise, and pinning does not remove
it.** A first install logs `[WARN] database file could not be found. If
this is unexpected, please set the FILEBROWSER_DATABASE environment
variable to the correct path` one second before `Creating new database`.
Measured on the live host on 2026-08-02: the variable *was* already set to
exactly the path Quantum then created. The message does not distinguish
"the file is missing" from "the path is wrong" — on a first install only
the former is true. It is emitted before the `Using Config file` banner,
i.e. during store initialisation, when the environment variable is the
only knob the program has read yet; that is why the advice names it.
Restart and `docker compose up -d --force-recreate` both log `Using
existing database` with no warning at all, and the operator's changed
admin password survives both (`admin`/`admin` → `401`, and no `Resetting
admin user to default username and password.` line).

> **Correction (2026-08-02, same day).** This entry originally claimed
> there is no config key for the database path, "so the environment
> variable is the only surface". That was wrong. `server.database` exists
> and is the documented way to set the path in `config.yaml`; a newer
> upstream wording of the same first-boot warning names it directly ("please
> double check your configuration file for `server.database` path"). The
> error came from checking the image's *sample* `config.yaml`, finding no
> such key, and generalising from that to the schema — an inference
> presented as a measurement, which is the exact failure this file exists to
> stop.
>
> Nothing about the design changes. `FILEBROWSER_DATABASE` is honoured and
> points at the right path, measured on the live host; `Q1-12`'s pin is
> effective. Both surfaces are equally protected, since `compose.yaml` and
> `filebrowser.yaml` are both canonical bundle entries. The policy file
> deliberately does **not** set `server.database`, which leaves one rough
> edge worth knowing: an operator who follows the warning's advice will open
> `filebrowser.yaml` and find nothing there. Setting it in the policy file
> would be the tidier home for it, and is unclaimed work rather than a
> defect.

`cap_drop: [ALL]` and
`no-new-privileges` are kept; the image already runs as a non-root
`filebrowser` user, which is why no `user:` line is set (the image's own
UID must own the data directory).

**`read_only: true` was first written off here as impossible, and that was
wrong.** The claim was an inference from "Quantum is stateful", never a
measurement — the same shortcut this project avoided for unpackerr (tried,
it worked, kept) and qBittorrent (tried, it broke `PUID`/`PGID`, removed).
Measured on 2026-08-01: the only thing Quantum writes outside its volume is
its cache directory, and `server.cacheDir` is configurable. Pointing it at
`/home/filebrowser/data/cache` puts the cache inside the volume that already
exists, and the root filesystem can then be read-only with **no tmpfs at
all**. Changes in the container's writable layer went from **18 to 1** — the
one remaining entry being the read-only bind mount itself — while login,
listing and writes to the media tree were unaffected.

A tmpfs was tried first and rejected on evidence: Quantum recommends at
least 20 GB of free space for the cache and warned with a 256 MB tmpfs
(`cacheDir only has 0.25 GB of free space`). Thumbnail generation over a
real media library is not something to hold in RAM. Putting the cache on
disk also fixed a smaller thing nobody had noticed — thumbnails and the
search index used to live in the container's writable layer and were
therefore discarded every time the container was recreated; they now
survive, including across a reboot (verified).

So the hardening dufs gave up nothing for is recovered on this line too.
The one thing that genuinely does not carry over is statelessness itself.

> **`read_only: true` later turned out to have a second price — see DD-35
> (2026-08-02).** It is what makes the policy file impossible to fold into
> `compose.yaml`: Compose refuses inline `configs.content` on a read-only
> service. The operator was shown the trade and chose to keep `read_only`.

**The initial admin account is left to the container — revised 2026-08-01
after reading upstream's source.** The installer briefly did bootstrap it,
and that was the wrong call. What upstream actually does:

```go
if !exists {                       // only when the database is absent
    settings.Env.IsFirstLoad = true
    quickSetup(store)
}

func quickSetup(store *bolt.BoltStore) {
    if settings.Config.Auth.AdminPassword == "" {
        settings.Config.Auth.AdminPassword = "admin"   // hardcoded fallback
    }
    user.ShowFirstLogin = settings.Env.IsFirstLoad && user.Permissions.Admin
```

So `admin`/`admin` is a real default rather than a documentation example; it
is created **once**, only when the database does not exist; it is never
re-asserted on later starts; and the UI raises a first-login notice
(`ShowFirstLogin`) without forcing a change. Two supported ways to set it
exist — a `FILEBROWSER_ADMIN_PASSWORD` environment variable read in
`loadEnvConfig()`, and the `filebrowser set -u user,pass -a` CLI.

Neither is used, and the reason is not only the secret-at-rest question:

- The env var would put a plaintext password in `compose.yaml`. That file is
  `0600 root:root` and inside the canonical bundle, so it is better than a
  world-readable file — but it is still plaintext at rest, visible via
  `docker inspect` and in the container's own `/proc/1/environ`.
- The CLI needs the container stopped, because the running process holds the
  SQLite file. The first implementation of that shipped an **idempotency
  bug**: it worked on a fresh host and died on a re-run with `the database is
  locked` (`rc=1, aşama=5`).
- **The decisive reason is behavioural.** The CLI approach ran whenever Stage
  0 re-collected credentials, which means a re-run would have silently reset
  a password the operator had already changed in the UI. Leaving the account
  to the container gets that right for free: upstream's `if !exists` guard
  makes the credential the operator's from first login onward. Verified —
  after changing the password to something else, a full re-run of the
  installer left it untouched (`401` on `admin`/`admin`, `200` on the new
  password).

**`minLength` is therefore fixed at upstream's 5 and cannot be raised.**
`admin` is exactly five characters, so `minLength: 8` makes `quickSetup()`
die with `[FATAL] store.Users.Save: password must be at least 8 characters
long` — and the container then comes up with *no user at all*: healthy to
Docker, 200 to the reconcile probe, clean under `--check`, and impossible to
log into. That was measured, not theorised. The two numbers are tuned to
each other upstream.

**The consequence is stated plainly in the install summary and is the
operator's to close:** unlike Portainer and wg-easy, which ship with no
account, Quantum ships a working `admin`/`admin` login. Until it is changed,
any device on the tailnet has full access to the media tree. The summary
promotes changing it to the first post-install action and says the container
owns the account, so the change can only be made through the web UI.

**Measured on a live host (2026-08-01), and the design changed as a
result.** Everything below replaces the "unverified" list this entry
originally carried.

`FILEBROWSER_CONFIG` **is** honoured, so the policy file lives outside the
volume as intended (`Using Config file: /config.yaml` in the startup log,
sources resolved to `srv: /srv`). The container user is `uid=1000(filebrowser)
gid=1000` — the same 1000:1000 as the media tree's ownership model — and a
fresh named volume comes up correctly owned. `stable` resolved to
`v1.5.0-stable`.

**The default credential is real, and `minLength` does not stop it.** The
config sets `minLength: 8`, and on the very first start that made Quantum's
own bootstrap die with `[FATAL] store.Users.Save: password must be at least
8 characters long` — `admin`/`admin` is 5 characters. The container
restarted into a state with *no* user at all: healthy to Docker, 200 to the
reconcile probe, `--check` clean, and impossible to log into. Worse, the
first reading of that result — "so `minLength` blocks the default" — was
wrong. Creating a user through the CLI against an empty volume produced
**two** admins, `admin` and the requested one: the database-initialisation
path creates the default account and **bypasses the `minLength` check that
only the server's own bootstrap path enforces**.

So the installer now closes it explicitly rather than relying on
configuration. After the image pull and before the stack starts, Stage 5
runs `filebrowser set -u admin,<Stage-0 password> -a`. One call covers both
states: it creates the account if absent and overwrites the auto-created
default if present. Verified — afterwards `admin`/`admin` returns 401,
`admin`/<password> returns 200, and exactly one user exists.

Three consequences worth stating:

- **`minLength: 8` is kept deliberately, as a fail-closed backstop.** If
  Stage 5's bootstrap ever fails to run, the server's own path hits the
  FATAL and the container dies loudly instead of quietly coming up on
  `admin`/`admin`. Lowering it to upstream's 5 would choose the silent
  option.
- **The password is passed as a CLI argument**, so it is briefly visible in
  the host's process list. It is never written to disk. That is the cost
  accepted in exchange for not putting plaintext in a config file, which
  would be permanent and would break **C2**.
- **Stage 7 asserts the property rather than assuming it**: a `POST` to
  `/api/auth/login?username=admin` with `X-Password: admin` must return
  401, or the install stops. This mirrors `V2-2`'s dufs anonymous-401
  assertion, and for the same reason — the health check, the reconcile
  probe and `--check` all report a service with a live default credential
  as perfectly healthy. Proven, not assumed: the admin password was set
  back to `admin` deliberately and the install stopped with
  `rc=1, aşama=7`.

**One idempotency bug was introduced and fixed in the same session.** The
first version of the Stage 5 bootstrap ran fine on a fresh host and failed
on a re-run: the running container holds the SQLite file, so the CLI died
with `the database is locked` and took the install with it
(`rc=1, aşama=5`). Stage 5 now stops the container first, which is safe
because `master-compose` is restarted a few lines later anyway. Both paths
were then re-tested end to end — re-run against a live stack, and a fresh
install with the volume deleted — each completing with `admin`/`admin`
closed, zero FATALs, zero restarts and `--check` at `rc 0`.

**Still unmeasured:** whether the SQLite indexer's first pass over a large
media tree costs anything noticeable. The test host's tree is nearly empty,
so this proves nothing about a real library.

### DD-28: The WebDAV directory cache is one minute, and `--poll-interval` is deliberately absent (2026-08-01)

**Decision.** Pass `--dir-cache-time 1m` to `rclone serve webdav`, overriding
rclone's 5-minute default. Do not pass `--poll-interval`.

**Why it matters here specifically.** This installer exists to serve a media
tree to Infuse over WebDAV while qBittorrent and unpackerr write into that
same tree. The two halves are therefore in a producer/consumer relationship,
and rclone's default put five minutes between them.

Measured on 2026-08-01, with a file created in the media tree:

| | t+0s | t+5s | t+10s |
|---|---|---|---|
| FileBrowser Quantum | visible | visible | visible |
| WebDAV (rclone) | **404** | **404** | **404** |

Quantum sees it immediately because it runs its own SQLite index with
real-time monitoring; rclone was still serving a cached listing. So a
finished download or a freshly extracted archive could be invisible in
Infuse for up to five minutes, with nothing wrong and nothing to see in any
log.

**Why not `--poll-interval`.** It looks like the more precise instrument —
poll for changes rather than blanket-expire the cache — and it is a no-op
here. rclone's own help says "only on supported remotes", and
`rclone backend features` on the media directory reports
`ChangeNotify: false` (measured the same day). The local backend has no
change-notification mechanism, so the poll interval never fires. Directory
cache lifetime is the only effective lever on this backend.

**Why one minute.** The value trades freshness against re-reading the tree:

| Value | Worst-case delay | Judgement |
|---|---|---|
| `5m` (rclone default) | 5 min | The problem above |
| **`1m`** | 1 min | **Chosen** — short enough that "the download finished but it isn't there" never becomes a question |
| `30s` | 30 s | Twice the re-listing cost for a difference the user cannot perceive |
| `0` | none | Disk read on every request; deletes the reason the cache exists, and would degrade browsing a large library |

**Verified, and the first measurement was wrong.** The initial check appeared
to show instant visibility — but the install had just restarted
`master-webdav`, so the cache was *cold* and the first `PROPFIND` read from
disk. That measured nothing about the cache. Re-run correctly — warm the
cache with a `PROPFIND`, then create the file, then poll — the file appeared
after **33 seconds**, consistent with a one-minute entry that was already
partway through its life. Byte-range requests were re-verified at three
offsets afterwards and still return 206 with correct content.

### DD-29: The policy file's target is normalised before writing, container included (2026-08-01)

**Decision.** Before writing `/etc/master-stack/filebrowser.yaml`, delete it
if it is a *directory*, and remove the `filebrowser` container as well.

**The failure it prevents was the only one a re-run could not fix.** This
project's standing answer to a broken host is "run `install.sh` again" —
every other repair path relies on that. One state broke it:

1. The policy file is missing for any reason.
2. Compose starts and cannot find the bind-mount source, so **Docker creates
   a directory** at that path — its documented behaviour for a missing
   source.
3. Quantum reads the directory as its config and fails validation with
   `Settings.Server.Sources ... required`. The container serves nothing.
4. The operator re-runs the installer. `mv -f file dir/` **does not fail** —
   it silently moves the file *into* the directory. The bind mount is still a
   directory, the service is still broken, and the only visible change is one
   more file accumulating inside.

Reconcile does detect the outage (`compose_runtime=1`, `rc=1`, HTTP probe
failing), so it is not silent — but it cannot repair it, and neither could
the installer.

**The first fix was insufficient, and testing is what showed it.**
Normalising the host path alone left the install failing at stage 5. Once a
container has been created with a *directory* mounted at `/config.yaml`, that
mount type is recorded in the container and `runc` rejects the corrected
file with `not a directory: Are you trying to mount a directory onto a file
(or vice-versa)?` — a restart loop rather than a recovery. The container has
to be removed so compose recreates it with a clean mount spec. No data is at
risk: everything persistent lives in the `filebrowser_data` volume, which
outlives the container.

Verified end to end: the broken state was reproduced deliberately
(directory at the config path, container running but serving nothing,
`--check` `rc 1`), then a single installer run restored `-rw-r--r--` at the
path, a healthy container with `RestartCount 0`, HTTP 200, a working admin
login, and `--check` `rc 0`.

**Scope.** `${QUANTUM_CONFIG_FILE}` is the only single-*file* bind mount in
the stack, so it is the only place this applies. Every other bind mount is a
directory, where Docker creating one is correct, and `webdav.htpasswd`
reaches its service through systemd `LoadCredential` rather than a mount —
if that file goes missing the unit fails loudly, which is the behaviour we
want.

### DD-30: Reconcile reports the default filebrowser password without failing on it (2026-08-01)

**Decision.** On every reconcile cycle, attempt a login as `admin`/`admin`
against filebrowser. If it succeeds, warn — and do nothing else. The exit
code, `compose_runtime`, and the restart logic are all untouched.

**Why report at all.** DD-27 leaves the initial account to the container, so
`admin`/`admin` on a fresh install is the *expected* state, not a fault.
What makes it worth surfacing is that it can come back **after** install: if
the volume is deleted or the container is recreated from scratch, Quantum
runs `quickSetup()` again and re-creates the default account. Nothing else in
the system notices — Docker reports the container healthy, the HTTP probe
gets its 200, and `--check` is clean. A security property that can silently
regress and that no existing signal covers is exactly what a 20-minute
reconcile loop is for.

**Why a warning rather than a failure.** Failing would make every fresh
install report `rc 1` until the operator got round to changing the password,
which trains people to ignore the exit code — the precise failure mode
`V1-11` was fixed to avoid. This is the same shape as wg-easy's
`WG_SETUP_PENDING`: an operator step that has not happened yet is reported,
not treated as a fault.

**Why no flag variable.** `WG_SETUP_PENDING` exists because it is *read* —
it suppresses a pointless wg-easy restart. Here there is nothing to suppress:
restarting the container does not change a password. An unread flag would
also fail `shellcheck` (SC2034), which is how the first draft was caught.
The warning is the whole feature.

**Why a login attempt, when something less invasive would be preferable.**
One was looked for and does not exist. The user object exposes
`showFirstLogin`, which tracks whether the first-login notice has been
displayed — not whether the password changed. Measured on 2026-08-01: it had
already flipped to `false` on a host whose password was still `admin`, so
relying on it would produce false negatives for exactly the operator who
dismissed the notice and moved on. The cost of the real check is one log line
per cycle — 72 a day against a `json-file` driver capped at 10 MB × 3.

> **Amended by DD-33 (2026-08-02).** "One log line per cycle" was true of
> the *output* but not of the *requests*: living inside
> `probe_compose_runtime` meant up to four login attempts on a drifted
> cycle, and the endpoint turned out to be rate-limited per source IP.
> DD-33 moves the probe out into its own function called once per cycle,
> and gives `429` its own message.

Verified in both directions: with the default password the warning appears in
`--check`, in `--status`, and in the timer-driven run's journal, with `rc 0`
and `compose_runtime=0` throughout; after changing the password it goes
silent, still at `rc 0`.

### DD-31: Inodes are checked separately from bytes, and `-` counts as healthy (2026-08-01)

**Decision.** `inode_space_ok()` sits alongside `disk_space_ok()` with its
own flag, its own message, and a shared threshold — and treats a `-` in the
`IUse%` column as healthy rather than as unreadable.

**Why a second check at all.** The two are not the same measurement. ext4
fixes its inode table at `mkfs` time, so a tree of many small files can
exhaust it while the filesystem is nearly empty in bytes. Measured on the
Debian target on 2026-08-01 with a 32 MB image made with `-N 64`: after 52
files, `df -h` read **1% used** and `df -i` read **100% used**. The byte
check returned healthy on that filesystem while `touch` returned `ENOSPC` —
which is exactly the state a torrent tree can reach, and exactly what the
existing check structurally cannot see.

**Why a separate flag rather than folding it into `DISK_SPACE_LOW`.** The
remedy differs, and it is counter-intuitive: deleting large files frees
bytes and no inodes at all. An operator reading "filesystem over 90% full"
against a `df -h` showing hundreds of free gigabytes would reasonably
conclude the check was broken. The message says which resource ran out and
that the fix is deleting *many small* files. A separate flag also keeps
`--check` diagnostic (`inode_space_low=`) instead of overloading one key.

**Why `-` is healthy and not fail-closed.** Filesystems that allocate inodes
dynamically report `-` in this column. Measured on the target the same day
against a btrfs loop device: `IUse%` is `-`, and the digit filter the byte
check uses leaves an empty string — which under that check's fail-closed
rule would raise a permanent, unfixable warning on every 20-minute cycle for
anyone on btrfs. `-` does not mean "could not read", it means "there is no
table to exhaust". Genuinely unparseable output still fails closed, and the
two cases are separated by testing the raw field for `-` before filtering
digits, not after.

**Why the threshold is shared.** Both are the same "this filesystem is
filling up" policy; a second constant would be a second thing to keep in
sync for no gain.

Reported, never repaired — the same contract as the byte check, for the same
reason. Wired through detection, `all_critical_state_healthy`, `--check`,
`--status` (a new `inode` column), and the post-repair postcondition. Five
bats cases added, including the btrfs `-` case; suite 74 → 79.

### DD-32: The Quantum policy file joins the canonical bundle (2026-08-02)

**Decision.** `/etc/master-stack/filebrowser.yaml` becomes the ninth entry
in the canonical bundle, verified and restored on every reconcile cycle like
the dnsmasq and Caddy files — and the restore is followed by a container
restart.

**Why it was missing.** It is new to this line. `V1-20`'s filebrowser kept
its settings in the `filebrowser_config` volume, so there was no host file to
drift; DD-27 moved policy to a host file and never added it to the bundle.
Nothing flagged the omission because nothing checks bundle membership against
"files install.sh generates".

**What that cost, measured on 2026-08-01.** Flipping `signup: false` to
`true` moved none of reconcile's signals — `config=0`, `state_config=0`,
`compose_file=0`, `compose_runtime=0`, `rc=0`. Restarting the container then
took the change live: `/api/auth/signup` went from `405` (route absent) to
`400` (route present, payload rejected). So the drift was invisible *and*
self-activating, since reconcile itself restarts containers routinely.
`signup` is not an arbitrary example — self-signup was the mechanism of the
original filebrowser's worst unpatched vulnerability (GHSA-6759, critical),
which is why the generated policy disables it.

**Why restore, not report.** `compose.yaml`'s report-only treatment (M10)
does not transfer: it is report-only because restoring it does nothing
without `docker compose up`, and because it is where an operator legitimately
experiments. Neither holds here. Rewriting this file directly fixes the
policy the container will load, and the file is generated wholesale on every
install run, so there is no operator edit to preserve.

**Why a restart follows the restore.** Quantum reads its config only at
startup, and there is no way from outside to tell whether the drifted file
was already loaded. The property worth guaranteeing is "the policy in force
equals the canonical copy", and only a restart delivers it. It shares the
15-minute per-container budget with every other filebrowser restart, so a
file that keeps being rewritten does not produce a restart loop — it produces
one restart, then a cooldown message.

**One defect found by testing this, worth recording because it recurs.** The
first version waited only for HTTP before returning, and reported `rc 1`
after a repair that had actually succeeded — the `V1-11` class again.
Measured cause: the Quantum image ships its own `HEALTHCHECK` (`start_period
10s`), and after a restart HTTP answers at t+2s while health reaches
`healthy` at t+5s; the wait exited in that gap and the postcondition caught
`starting`. The wait now checks both signals — the same two
`probe_compose_runtime` applies to filebrowser.

**Unplanned benefit.** DD-29 described a deleted policy file as the one state
a re-run could not repair, because Docker recreates the missing bind-mount
source as a *directory*. Reconcile now restores the file within twenty
minutes, long before a container recreate could reach that state. Verified:
file deleted, one reconcile run, file back at `0644 root:root`, container
healthy, `rc 0`.

### DD-33: The default-password probe runs once per cycle, and `429` is reported as unknown (2026-08-02)

**Decision.** The DD-30 check moves out of `probe_compose_runtime` into
`report_default_filebrowser_password()`, called exactly once from the main
flow, and grows a `429` branch that says the check could not be performed.

**Why once.** `probe_compose_runtime` is called up to four times in a single
cycle — initial detection, the one-second retry, again after a repair, and
once more as the final postcondition. *(Corrected 2026-08-04: five, not
four — the filebrowser policy repair added a fifth call site. The reasoning
is unaffected, the multiplier is simply larger than stated. See DD-48.)* The probe rode along with all four, so
a *drifted* cycle sent four login attempts where a clean one sent one. That
went unnoticed until the endpoint was measured.

**What the measurement found (2026-08-02).** Quantum's
`POST /api/auth/login` is rate-limited, and the bucket is keyed on **source
IP, not on the credential**: after 6 failures the endpoint returns `429`, and
from then on the *correct* password also returns `429`. The window is between
3 and 8 minutes of silence. The probe's source is `172.18.0.1`, the Docker
bridge gateway — the same address every Caddy-proxied browser login arrives
from, so reconcile and the operator share one bucket.

Those numbers decide the design. A bucket of 6 against four attempts per
cycle leaves an operator two tries before reconcile's own traffic locks the
login screen — and reconcile can trip the limit unaided. At one attempt per
cycle it cannot: the 20-minute timer interval is longer than the longest
measured window, so attempts never accumulate.

**Why `429` gets its own message.** Without the branch it fell through to the
same silent path as `401`, which means the check reported "nothing to see"
at precisely the moment someone was hammering the login screen — the one
moment it should be loudest. A security check that fails open is worse than
one that does not exist, because it is trusted. The message states plainly
that this is **not** evidence the password was changed, and that the next
cycle will retry.

**Why not fail the run instead.** Same reason as DD-30: a temporary,
self-clearing condition that the operator cannot act on must not produce
`rc 1`. It is reported, not counted.

**Why a separate function rather than a guard variable.** An "already
probed this cycle" flag would have to survive across four call sites and be
reset per-cycle — state to get wrong for no benefit. The probe has nothing to do
with the container-runtime checks it was living among; a named function
called once from the main flow says what it does and cannot be called four
times by accident.

All four paths verified live on `nrm`: the clean case (`rc 0`, one attempt,
down from four on a drifted cycle), the drifted cycle (still one attempt),
the throttled case (the `429` message, `rc 0`), and the regression case
(volume deleted → default account back → the warning fires, `rc 0` in both
the direct run and `--check`). Then confirmed end-to-end through systemd:
`Result=success`, `ExecMainStatus=0`, the warning once in the journal, zero
failed units.

> **Amended by DD-41 / Q1-20.** Once per 20-minute cycle was bounded, but
> still made the documented read-only modes send a real login request and
> spent up to 72 attempts per day after the password changed. The probe is now
> normal-reconcile-only and at most daily; `--check`/`--status` never call it.
> Live R2.5 logs measured zero POSTs for both read-only modes and one total
> across two immediate normal runs.

### DD-34: Unpackerr's file log is given a rotation cap, and the queue heartbeat is slowed to 30m (2026-08-02)

Raised by the operator noticing a long, repetitive tail in `docker logs
unpackerr` and attributing it to the 10-second folder scan. The scan was
the wrong suspect — it is completely silent (`[Folder] Polling @ 10s:
/downloads` and nothing after it). The lines come from `log_queues`,
whose default is `1m1s`: two lines a minute (`Queue: 0 waiting…` and
`Totals: …`) whether or not anything is happening. Measured on the live
host: 62 lines in 20 minutes, exactly 2/min.

**The Docker side was never the problem.** `json-file` with `max-size:
10m`, `max-file: 3` caps that stream at 30 MB, and at the measured
~226 B/min a file fills in about a month, so roughly a quarter of a year
of history is retained. The cost is legibility, not disk: while idle, the
log is 100% heartbeat.

**The real defect was the second log, the one written into the media
tree.** `UN_LOG_FILE` points at `/downloads/.unpackerr/unpackerr.log`, and
the container reported it as `(10 @ 0Mb, mode: 600)` — ten files retained,
rotation threshold zero. Upstream's example config documents
`log_file_mb`'s default as 10 MB, but that default only applies down the
TOML path; this stack configures unpackerr purely through environment
variables (`Using env variables only. Config file not found.`), and on
that path the value arrives as `0`, which upstream defines as "no
size-based rotation". So "keep 10 files" never engaged and one file grew
without bound: ~280 B/min measured, ~400 KB/day, ~145 MB/year — inside the
tree filebrowser serves, Infuse indexes and `disk_space_ok` watches.
`UN_LOG_FILE_MB: "10"` and `UN_LOG_FILES: "3"` bring it to the same 30 MB
ceiling the Docker side already had; the container now reports
`(3 @ 10Mb)`.

**`UN_LOG_QUEUES: "0"` is the intuitive fix and it is wrong.** Upstream
does not document what `0` does here, so it was measured rather than
assumed, in throwaway containers:

| `UN_LOG_QUEUES` | reported at startup | `Queue:` lines in 75s |
|---|---|---|
| unset | `1m1s` | 1 |
| `0` | **`15s`** | **5** |
| `30m` | `30m` | 0 |

Zero does not disable the heartbeat, it clamps it to a 15-second floor —
four times noisier than leaving it alone. `30m` is used instead.

**Nothing real is lost by slowing it.** Verified end to end rather than
inferred: with `log_queues` at `30m`, dropping an archive into a watched
folder still logged `Tracking New Item`, `Queued`, `Extraction Started`
and `Extraction Finished` with the file count and byte total. Only the
idle pulse goes away.

**Only `UN_LOG_FILE_MB` joins the Stage 7 environment assertion.** That
list exists for settings whose drift is *silent*. `UN_LOG_QUEUES` drifting
makes the log noisy, which is visible by definition. `UN_LOG_FILES`
drifting raises the ceiling from 30 MB to 100 MB — still bounded.
`UN_LOG_FILE_MB` drifting to `0` removes the ceiling altogether and puts
an unbounded file back inside the media tree with nothing to announce it.
The assertion was checked against a container configured both ways: it
passes on the configured one and fails on an unconfigured one, so it
discriminates rather than merely passing.

### DD-35: The Quantum policy file stays a separate host file, because `read_only: true` forbids the alternative (2026-08-02)

The operator asked to fold `/etc/master-stack/filebrowser.yaml` into
`compose.yaml` — the file the other four containers are already fully
configured from — on the reasonable grounds that a stack with one
configuration surface is easier to reason about than a stack with two.
Investigated, measured, and **not done**. Recorded here so the same three
experiments are not repeated.

**Environment variables cannot express this policy.** Every
`FILEBROWSER_*` string in the `stable` (v1.5.0) binary is either a secret
or a path: `CONFIG`, `DATABASE`, `FFMPEG_PATH`, `ADMIN_PASSWORD`,
`JWT_TOKEN_SECRET`, `OIDC_*`, `LDAP_USER_PASSWORD`, `TOTP_SECRET`,
`RECAPTCHA_SECRET`, `ONLYOFFICE_SECRET`, `GENERATE_CONFIG`,
`DISABLE_AUTOMATIC_BACKUP`. There is no variable for `server.sources`,
`server.cacheDir`, `auth.methods.password.signup` or `minLength` — that
is, for every setting this stack actually depends on. A YAML file has to
exist.

**Compose can inline it, and that part works.** A `configs:` block with
inline `content:` was tried against the real image: Quantum came up with
`Using Config file: /home/filebrowser/data/config.yaml`, `Sources: [srv:
/srv]`, and served `200`. Compose is v5.3.1 here, far past the v2.23 that
introduced inline content.

**But not on a read-only service.** With `read_only: true` the same file
is refused before the container is created:

```
cannot create config "quantum_policy" in read-only service fbprobe:
`file` is the sole supported option
```

Inline content is materialised *inside* the container at startup, which a
frozen root filesystem forbids; `file:` — a host file that already exists,
i.e. exactly today's bind mount — is all that remains. Pointing the target
at a path inside the writable volume (`/home/filebrowser/data/config.yaml`)
was tried and refused identically: the check is service-level, not
path-level. So the two goals are mutually exclusive, with no third form
available.

**What dropping `read_only` would have cost, measured rather than
asserted.** Nothing functional: `docker diff` against a container running
the same image *without* `read_only` showed **zero** writes to the
writable layer, because DD-27 already moved `cacheDir` into the volume.
That measurement is also the trap — `read_only` is a containment control,
not a functionality one. What it buys is that a compromised Quantum cannot
drop a binary in `/tmp`, edit `/etc`, or alter the application's own files;
it is confined to the two mounts it legitimately needs (`/srv` and
`/home/filebrowser/data`, both still writable, since mounts are exempt).
`docker diff` cannot see the absence of an attack, so a zero there argues
for nothing.

**What the move would have gained, so the rejected side is not
strawmanned.** The canonical bundle would drop from nine entries to eight;
the policy file's separate drift comparison and its restore-plus-restart
repair path (with the restart-budget and cooldown handling around it)
would disappear, since `compose.yaml` is already covered by both; and
DD-29's guard — the one for Docker creating a *directory* where a missing
bind-mount source should be — would become unnecessary, because that
failure mode cannot occur when the content is inline. This was a real
simplification, not a cosmetic one.

**Decision (operator, 2026-08-02): keep `read_only: true`.** The thing
being simplified away is a file the operator never touches — the installer
generates it, the bundle hashes it, reconcile repairs it. The thing given
up would have been a containment control on the one service that is
reachable across the tailnet and serves the entire media tree, and no
other mechanism substitutes for it.

**Reopen if either side of the conflict moves:** Compose gaining support
for inline configs on read-only services, or Quantum gaining environment
variables for `sources`, `cacheDir` and `signup`. Neither is true as of
Compose v5.3.1 and filebrowser Quantum v1.5.0-stable.

### DD-36: Three file-manager alternatives investigated, FileBrowser Quantum kept (2026-08-02)

Three separate investigations in one day, each ending in no change. Recorded
together because they share a conclusion and because none of them left a
trace in the code — without this entry the same searches get run again.

#### Filestash, proposed as the v3 file manager

Named "Filetash" in the request; the software is
[Filestash](https://www.filestash.app) (`machines/filestash`). Rejected on
one structural fact, found in upstream's source rather than its docs.

**Its `config.json` is runtime state, not policy.** `Save()` is called from
`Set()` (admin console writes), from `Default()`, and from `Initialise()` —
so the file is rewritten on the very first start, before anyone touches
anything. That single fact removes the architecture this branch spent most
of its effort on: the file cannot be a read-only bind mount, and it cannot
join the canonical bundle, because reconcile would revert every admin change
within twenty minutes. Going ahead would have deleted the policy-file
mechanism entirely — bundle nine entries → eight, the `quantum_config` drift
flag, the restore-plus-restart repair path, DD-29's directory guard, and
`report_default_filebrowser_password` with DD-30/DD-33 behind it.

Also weighed, none of them decisive on their own:

- **Tag hygiene is a regression.** Only `latest` is maintained (last push
  2026-07-31). No semver tags; commit-hash tags stop in 2023. DD-23 says to
  take the finest float upstream publishes — here the finest available is
  the coarsest there is, worse than every other service in the bundle.
- **The admin window is silent.** Whoever reaches `/admin/setup` first
  becomes the administrator. Quantum at least ships a *known* default that
  the installer and reconcile can both warn about.
- Upstream's own warning that the Local backend "exposes the container
  filesystem to the admin", which makes `read_only` matter more, not less.
- AGPLv3, where the current and previous file managers were not.
- Port 8334, non-root `filestash` user, `debian:stable-slim` carrying ffmpeg
  and ImageMagick.

**One thing was deliberately left unverified rather than assumed.** A
secondary source claims an `ADMIN_CONSOLE` environment variable presets the
admin bcrypt hash, which would close the setup window entirely. The primary
source does not list it and two source lookups failed. No design was built
on it. If Filestash is ever revisited, confirm it against the image first.

Blast radius, for whoever picks this up: `filebrowser` appears 56 times in
`install.sh` across roughly eighteen clusters, and `STACK_SCHEMA` would have
to bump because `IMAGE_DIGEST_FILEBROWSER` is a `state.env` key.

#### A native, non-Docker file manager that extracts RAR

Asked for next. The requirement barely has answers, and the one product that
satisfies it literally is the one to avoid.

- **FileBrowser Quantum** does not extract in place — it only zips a
  selection for download. Still an open upstream request
  ([discussion #1633](https://github.com/gtsteffaniak/filebrowser/discussions/1633)).
- **[copyparty](https://github.com/9001/copyparty)** creates archives but
  does not extract them. Otherwise the strongest candidate: one Python file,
  no dependencies, an upstream systemd unit, a plain config file that *would*
  satisfy the canonical-bundle test Filestash failed, upload hooks, and
  native WebDAV — which could absorb the separate rclone WebDAV service.
- **elFinder** does extract RAR, and that exact code path is its CVE history:
  [CVE-2019-9194](https://vuldb.com/vuln/131229) is command injection through
  crafted archive requests with filenames passed to an external utility
  unsanitised, alongside
  [CVE-2021-32682](https://www.sonarsource.com/blog/elfinder-case-study-of-web-file-manager-vulnerabilities/)
  (multiple RCEs at minimal configuration) and CVE-2022-26960. This project
  deleted filebrowser's shell-command feature specifically to be rid of this
  class; taking elFinder would walk it back in through the same door.
- **Webmin** extracts, and is a root-level system administration panel —
  far too much surface for a service published on the tailnet.

**The reframe is the useful part: RAR extraction is already solved here.**
unpackerr watches the entire media tree recursively every ten seconds and
extracts rar/zip/7z/iso with `move_back`, verified working this same day. Any
file manager that can *write* into the tree therefore already gives
browser-triggered extraction — drop the archive in, it is unpacked within
seconds. The wanted capability was never in the file manager.

Separately, leaving Docker is not free: `cap_drop: ALL`, `read_only: true`,
`mem_limit` and `no-new-privileges` all go, and an equivalent has to be
rebuilt with systemd (`DynamicUser`, `ProtectSystem=strict`,
`ReadWritePaths`, `MemoryMax`, `CapabilityBoundingSet`). That rebuild, not
the file-manager swap, is the actual work of such a migration.

#### Nextcloud as a Docker service

**Capacity is not the objection, and it was measured before saying so.** The
host is 4 vCPU / 7.8 GB RAM / 251 GB, using 863 MB, and the five containers
total roughly 130 MB. Nextcloud with MariaDB and Redis fits comfortably. The
first instinct — "too heavy" — would have been wrong.

Two things block it, both structural:

1. **Nextcloud reads its file list from `oc_filecache`, not from the disk.**
   Anything written outside it is invisible until `occ files:scan`. In this
   stack *two* services write into the media tree — qBittorrent and unpackerr
   — so every finished download and every extracted archive would be missing
   until the next scan, which upstream recommends running about every fifteen
   minutes and warns is "time- and resource-consuming if the whole storage is
   periodically scanned". Quantum reads the disk directly and simply does not
   have this problem.
2. **Major versions cannot be skipped** — "updates between multiple major
   versions and downgrades are unsupported". Bump the pin two majors and the
   container fails unrecoverably; reconcile would then restart it repeatedly
   inside its budget, the self-healing loop grinding against a state it
   cannot repair. No service currently in the bundle has this failure class.

The rest is cost rather than blockage: five containers become eight;
`read_only` is impossible for Nextcloud, which writes to `/var/www/html`
continuously; a database introduces a backup concern this stack has never
had, since losing MariaDB loses every user, share and piece of file
metadata; `cron.php` every five minutes joins `files:scan`; and Caddy needs
`OVERWRITEHOST`/`OVERWRITEPROTOCOL`/`TRUSTED_PROXIES` plus `.well-known`
redirects. The All-in-One image is structurally incompatible — it takes the
Docker socket and manages its own containers, which is the fixed-bundle
model inverted. And it does not solve RAR either.

**Verdict: the wrong tool for replacing the file manager, and the right tool
for something not being asked for.** The valid reasons to want Nextcloud are
groupware — multi-user sharing with public links, calendar and contacts,
phone photo backup, a desktop sync client, in-browser office editing. If any
of those are ever wanted, the shape is *alongside* rather than *instead*:
its own storage and subdomain, the media tree attached read-only through
`files_external`, Quantum still owning the tree. Operator's decision
(2026-08-02): excessive for a single-operator media box.

#### What would reopen each

- **Filestash** — if it starts publishing versioned tags *and* gains a way
  to hold policy separately from mutable state. One without the other is not
  enough; the config-as-state problem is the blocking one.
- **A native file manager** — if the systemd hardening equivalent is
  actually written and confinement equal to `read_only: true` is
  demonstrated, not assumed. copyparty is the candidate to start from, and
  absorbing the WebDAV service is the thing that would justify the move.
- **Nextcloud** — if groupware features are genuinely wanted. Then alongside,
  never instead.

### DD-37: The interactive Tailscale login recovers by timeout, not by diagnosing the failure (2026-08-02)

The installer used to run a bare `tailscale up` and wait forever. On
2026-08-02 a real install wedged there and nothing in the script noticed.

**The failure.** The daemon generates a nodekey, gets an auth path
(`/a/<id>`) bound to it from the control plane, and long-polls that path.
A *new* registration for the same node — which is exactly what restarting
the installer causes — or completing an *older* link in the browser
invalidates the pending path, and the poll returns `410: auth path not
found`. What makes it unrecoverable is the next line:

```
control: doLogin(regen=false, hasUrl=true)
```

`regen=false`: the daemon retries the **same dead path** forever instead of
generating a new key. So one 410 wedges the login permanently, `tailscale
up` blocks indefinitely, and — the part that misleads the operator —
`tailscale status` keeps printing the dead link as though it were live.
The reported symptom was "I logged in but it is still waiting."

Measured on the host: two separate links, each dead ~13 seconds after being
issued, four 410 events, the install stuck until it was killed by hand.
`tailscale logout` did **not** clear it — the daemon still returned the same
dead URL afterwards. Only `systemctl restart tailscaled` cleared it, which
is why recovery is built on the restart.

**The fix deliberately does not diagnose anything.** Three earlier versions
tried to detect the wedge from `journalctl`, and all three were wrong in
different ways. Each was caught by running the function against the real
journal, not by reading it:

1. *"A 410 appeared, therefore wedged."* Wrong — a 410 is part of the
   **successful** flow too. When the operator completes the browser step
   the control plane retires the auth path, the in-flight poll takes a 410,
   and the daemon immediately re-registers and gets `machineAuthorized=true`.
   All within the same second, measured at 18:12:49.
2. *"A 410 with no recovery after it."* The check was
   `journalctl … | grep -q`, and under `pipefail` `grep -q` exits on first
   match, `journalctl` takes SIGPIPE, and 141 becomes the pipeline's status
   — so a **found** match reported failure. Intermittent, because it
   depended on whether journalctl had finished writing.
3. *"No recovery after the last 410", with no upper bound.* A later,
   unrelated login's success counted as recovery for an earlier wedge.

The direction of the false positive is what settled it: wrongly declaring a
wedge kills a login that is one second from succeeding, restarts the daemon
and forces the operator to authenticate again — the fix would manufacture
the very failure it exists to repair. Three wrong iterations were treated as
evidence that the diagnosis itself is fragile, not that the third attempt
needed a fourth.

**What replaced it is dumber and therefore safer.** If the login has not
completed within `TAILSCALE_LOGIN_TIMEOUT` (300s), for *any* reason, the
daemon is restarted and a fresh link is printed, up to
`TAILSCALE_LOGIN_ATTEMPTS` (3). This covers the wedge and every other stall
class, and its worst failure mode is "the operator was handed a new link".
The retry banner says the previous link is dead and that opening an old tab
will kill the new one, since that is what produces the 410 in the first
place. After three attempts it prints the manual recipe, including the
non-obvious part: **`logout` is not enough, restart the daemon.**

**Verified before shipping.** The retry machinery was exercised against
stub `tailscale`/`systemctl` binaries: a login that never completes
produced two links, two `systemctl restart tailscaled` calls, the
"previous link is void" banner between them, and the manual recipe at the
end. The success path was tested the same way — it returns as soon as
`tailscale up` exits, with **no** restart, and streams the URL to both the
terminal and the log. The live success path itself was exercised on a real
from-scratch install the same day.

> **Amended by DD-42 / Q1-21.** The live `login-state` shape was later
> observed twice with two distinct nodekeys, so early recovery no longer
> requires guessing. The timeout remains the unknown-state fallback; only the
> measured, persistent LocalAPI signature can bypass it.

### DD-38: DNS/Caddy file rollback commits with the canonical pointer (2026-08-02)

Stage 6 has a real transaction boundary, not merely a sequence of service
commands. Before it installs packages or writes configuration, Q1-17
snapshots these six managed paths into a root-only directory under `/run`:

- the dnsmasq zone file and dnsmasq systemd drop-in;
- the Caddyfile, Caddy systemd drop-in and `caddy-tailnet-env` helper;
- the tailscaled drop-in that pulls Caddy back after a tailscaled restart.

The snapshot records absence by the absence of a backup entry. That detail
is load-bearing on a fresh install: rollback must remove files introduced by
the failed attempt, not preserve a partial first configuration. Existing
files, directories or symbolic links are copied with metadata. Every managed
path must be absolute and must not be `/`; the restore loop refuses anything
outside that narrow shape before using recursive removal.

On failure, currently-loaded dnsmasq/Caddy units are stopped, the six paths
are restored (or removed if previously absent), systemd is reloaded, and the
entry-time active/enabled/masked vector is restored. An entry-time active
service is `restart`ed rather than merely `start`ed, so even a failed initial
stop cannot leave it running with the new in-memory configuration. The
snapshot is deleted only after every file restores successfully; otherwise
its path is printed and the root-only recovery copy remains available for
manual intervention.

The commit point is Q1-16's atomic canonical `current` swap. Before it, the
old canonical generation is authoritative and a failure restores the old
live files to match. After it, the new generation and new live files are a
consistent pair, so rollback is disabled before any later housekeeping.
This avoids the opposite mixed state: old live files under a new canonical
generation. Because pointer replacement and the shell flag update are two
commands, EXIT also resolves `current` directly: if it already names the
staging generation, the transaction is committed even if INT/TERM arrived
in the few instructions before the flag changed.

Package and apt-repository changes are deliberately outside this rollback.
Uninstalling or downgrading a package during EXIT cleanup is a much broader,
network- and maintainer-script-dependent operation. A newly installed but
disabled/masked daemon is safe, takes little space, and is reused
idempotently on the next run; reversing it adds risk without improving the
continuously-running service state this transaction protects.

### DD-39: Journal classifiers consume their complete producer stream (2026-08-02)

Stage 2 distinguishes a deleted Tailscale node from a general connectivity
failure by looking for `node not found` in tailscaled's journal since the
current install began. The distinction is useful and evidence-based: the
deleted-node branch can safely discard the worthless local profile and open
a new interactive login; the generic branch must stop and ask the operator
to diagnose network/control-plane reachability.

The classifier originally used `journalctl | grep -q` while the whole
installer runs with `set -o pipefail`. That combination is not a reliable
boolean query. `grep -q` exits as soon as it sees a match; if journalctl
still has more than a pipe buffer to write, it receives SIGPIPE and exits
141. Pipefail then makes the **matched** pipeline false. Whether the bug
appears depends on how much unrelated journal data follows the match, which
is why it presents as intermittent.

Q1-18 keeps the pipeline and its failure semantics but replaces quiet grep
with `grep -F ... >/dev/null`. The output stays silent, grep reads to EOF,
and journalctl completes normally. A real journalctl failure still makes the
pipeline fail; capturing output with `|| true` would have fixed SIGPIPE by
hiding that separate error and was therefore rejected.

This is the same shell failure mode encountered while developing DD-37's
abandoned 410 classifier, but the conclusion differs. DD-37 removed journal
diagnosis because 410 itself was ambiguous even with a correct pipeline.
Here `node not found` identifies a distinct recoverable state, so the right
fix is to preserve the classifier and make its transport correct. The old
and new forms were run against one producer with an early match plus 6,000
tail lines: rc 141 versus rc 0. Dedicated tests also cover no match and a
producer that genuinely fails after emitting a matching line.

### DD-40: FileBrowser policy replacement and activation are one retryable operation (2026-08-02)

Quantum reads `filebrowser.yaml` only at process startup. Therefore “the
live file equals the canonical file” is necessary but not sufficient: the
running process must also have restarted after that equality was established.
The earlier reconcile order violated this invariant by copying first and
checking the 15-minute restart cooldown second. If the cooldown refused the
restart, the next cycle saw equal files and lost the only evidence that the
process still held the old policy.

Q1-19 checks the budget before mutation and creates a root-only pending marker
under `/run/master-network-reconcile` before publishing the staged file. The
marker is part of `quantum_config_ok()` and is removed only after Docker health
and the direct HTTP probe both pass. Thus a failed restart, slow healthcheck or
Compose failure remains visible on the next run even though the on-disk file
is already correct. `/run` is intentionally volatile: a reboot clears the
marker, but that same reboot necessarily starts the container against the
current host path, satisfying the activation half of the invariant.

The second state is structural. Docker Compose can create a missing bind-mount
source as a directory. Copying a file to that path succeeds by placing the file
inside it, and restarting the already-created container preserves the wrong
mount contract. For a directory, symlink or other non-regular source, repair
therefore stages the canonical file first, verifies Docker is reachable,
removes only the `filebrowser` container, replaces the host path atomically,
and runs `master-compose.service` to recreate the container. It never removes
the `filebrowser_data` named volume, which is where the database, users, index
and cache live.

The full installer follows the same activation rule. Stage 4 compares both
content and metadata before replacing the generated policy; Stage 5 removes
only FileBrowser when a change was recorded, after image pull and unit
verification, and the normal Compose start recreates it. An unhealthy
FileBrowser is handled the same way, which repairs the legacy state where an
earlier swallowed removal failure left a stale directory mount behind a
now-regular host path. An identical policy on a healthy container is left
untouched. This is not a general “force recreate on every update” policy: the
extra downtime is scoped to the one service whose startup-only host policy
changed or whose runtime has already failed.

### DD-41: Reconcile repairs bounded local state, but exposes core failures (2026-08-02)

The reconcile timer is a post-install safety net, not a second installer or
an autonomous control plane. Q1-20 makes that boundary explicit by separating
two outcomes that previously shared one success-returning helper. A lock
collision or an already-active OnFailure job is transient overlap: normal
timer mode exits zero and lets the existing execution finish. Docker or
tailscaled remaining inactive, or required WAN/Tailscale addresses remaining
absent after a 30-second grace period, is an unhealthy server: reconcile exits
non-zero so systemd and the journal retain a real failure signal.

It deliberately does not restart, logout or authenticate tailscaled, and does
not restart Docker in that precondition path. Restarting either core daemon
propagates through the accepted `PartOf=` graph and can interrupt every
dependent service; a Tailscale login also requires a human browser decision.
Instead, failure reports the daemon state plus Tailscale's backend, self-online,
health and key-expiry fields. The core daemon's own restart policy, an explicit
installer rerun, or the operator remains responsible for the broader action.

Compose recovery follows the same bounded-local-state rule. An existing
regular `root:root 0600` file with different content may be an intentional
operator edit and remains report-only. A genuinely absent file is not an edit:
reconcile restores it atomically from the checksum-verified canonical
generation without restarting healthy containers. Metadata drift is repaired;
a directory, symlink or other unsafe target is refused rather than removed.
The service's `ConditionPathExists` gate was removed because it prevented the
very recovery process that could reconstruct the file from running.

Observation must also be read-only in practice, not only by name. The
FileBrowser default-password check is a real login POST and consumes a
source-IP rate limit, so `--check` and `--status` no longer issue it. Normal
reconcile may probe only a running container and only once per 24 hours, with
an atomic root-only `/run` stamp recorded before the request. This preserves
the useful reminder without turning a 20-minute health timer into a login
storm.

Finally, the host WebDAV unit independently declares
`RequiresMountsFor=$DOWNLOADS_PATH/media`. Compose's mount dependency cannot
protect a separate host service; without its own ordering rclone could serve
the empty directory hidden underneath a late or failed mount while every HTTP
probe still looked healthy. This dependency fails or delays WebDAV instead of
presenting the wrong tree as a healthy service.

**Live confirmation before R2.5.** On Debian, an active tailscaled daemon was
taken offline with `tailscale down`. Reconcile observed `Stopped/false`, waited
exactly 30 seconds, exited 1 and journaled the backend and health messages; it
did not restart or reauthenticate the daemon. Bringing the same node/IP online
and allowing the existing firewall/core recovery returned every drift flag to
zero. Missing, edited, metadata-drifted and symlink Compose targets each took
the branch described above without changing container start times. Container
logs also proved `--check`/`--status` issued no login POST and two immediate
normal runs issued one total. WebDAV's dependency passed both full Stage 7
runs; the host does not use a separate media mount, so no artificial mount
failure was claimed.

### DD-42: Persistent Tailscale 410 is classified from LocalAPI, never the journal (2026-08-02)

DD-37 deliberately rejected three journal-based attempts to identify a dead
interactive-login auth path. The rejection remains correct: a 410 also occurs
inside a successful authorization, journal producer/consumer timing caused a
separate SIGPIPE inversion, and an unbounded window let an unrelated later
success satisfy an earlier failure. A false positive restarts a daemon whose
login may be one second from succeeding.

Q1-21 changes the evidence, not that safety rule. A later clean-image R2.5 run
produced two independent failures without an installer restart. The first
nodekey received its link and entered the dead state 27 seconds later; the
second did so after 42 seconds. In both cases `tailscale status --json` exposed
the same simultaneous state: `BackendState=NeedsLogin`, `Self.Online=false`,
empty `Self.ID`, no Tailscale IP and a `Health` entry containing `http 410:
auth path not found`. The admin console showed an offline record because the
browser side had created/authorized one, but the daemon had never received a
usable machine identity. Restarting only tailscaled and issuing a third link
then produced a non-empty node ID/IP and `Running/Online`; the install finished
7/7.

That structured state is now a named classifier. One sample is still not a
decision: the main loop requires three consecutive samples, two seconds apart,
and resets the count on `pending`, `unknown` or successful state. Thus the
known successful transient 410 cannot survive the persistence gate. A
confirmed dead path terminates only the waiting `tailscale up` child and uses
DD-37's existing daemon restart/fresh-link path immediately. The 300-second
timeout remains unchanged for every state that does not match exactly, so
operator thinking time and unknown control-plane delays are not shortened.

Success is also stronger. Exit code zero from `tailscale up` is followed by a
15-second LocalAPI grace and is accepted only with `Running`, online, a
non-empty node ID and at least one Tailscale IP. Failure of that postcondition
uses the same bounded retry instead of allowing the later Stage 2 probe to be
the first place the inconsistency appears.

> **Amended by `Q1-22` (2026-08-02).** The postcondition stays; its *remedy*
> does not. Sending a failed 15-second grace into the bounded retry restarts
> the daemon and demands a second browser authorization — for a login that
> already succeeded, since `tailscale up` returned zero. That is DD-37's
> false-positive class arriving through a different door, and this time the
> door was narrower than the one already behind it: the very next block in
> Stage 2 waits **180 seconds** for the same condition (`tailscale ip -4` plus
> `tailscale_is_online`). Two gates for one condition, and the strict one held
> the destructive remedy.
>
> The goal above — surface the inconsistency here rather than letting a later
> probe be the first to mention it — was right, and is kept: the grace window
> now prints an explicit note when it expires. What changed is that it returns
> **success** and lets the 180-second check adjudicate. The reasoning is that
> a node which will not come online after an accepted login has a connectivity
> problem, not an authentication one; a fresh browser link cannot fix it,
> while the 180-second wait either resolves it or fails with a clear error.
> The 15 seconds is now a fast path, not a ceiling.
>
> Covered by a fourteenth Bats case, mutation-verified: it fails against the
> `Q1-21` behaviour (`status` non-zero, daemon restarted, a second `tailscale
> up` demanded) and passes against `Q1-22`.

Thirteen Bats cases cover the live JSON signature, incomplete and malformed
states, command failure, a completed node carrying a transient 410 line, the
three-sample early restart and a one-sample 410 followed by success with no
restart. The full local wrapper is clean. The real input signature and the
equivalent manual child-termination/restart path are live measurements; the
exact automatic Q1-21 branch remains deliberately unclaimed until a later
fresh authorization run exercises it. At the operator's explicit request the
same installer was exported untagged as an R2.6 manual-test candidate; that
packaging action does not change the pending live-verification claim.

### DD-43: Exit-node and Tailscale SSH are requested by `tailscale up`, then held by `tailscale set` (2026-08-03)

- **Decision:** the interactive login runs `tailscale up --advertise-exit-node
  --ssh` instead of a bare `tailscale up`, and the `tailscale set` call that
  follows gains `--ssh=true` alongside the flags it already carried. Tailscale
  SSH is now part of the node's steady state: `tailscale_prefs_ok()` requires
  `.RunSSH == true`, so the reconcile timer treats a lost `--ssh` as drift and
  repairs it with the same `tailscale set` invocation it already used for
  exit-node/netfilter drift.
- **Why both places, not one.** `tailscale up` runs **only** when
  `TAILSCALE_NEEDS_LOGIN` is 1 — a fresh node, an expired key, or a node
  deleted from the tailnet. On the ordinary re-run against an already-joined
  host it never executes. So it cannot be the only place these preferences are
  set without making them silently optional on every re-install. `tailscale
  set` runs unconditionally and is the idempotent path; `tailscale up` now
  merely asks for the same end state one step earlier.
- **A second reason to name the flags on `up`.** `tailscale up` refuses to
  silently revert non-default preferences: when the current profile has flags
  set that the command line does not mention, it errors and asks the operator
  to re-run mentioning them. On the re-login paths above the profile can
  already carry `--advertise-exit-node`, which a bare `tailscale up` would be
  proposing to drop. Naming the flags removes that failure mode rather than
  adding one.
- **The security trade-off, stated rather than assumed.** `--ssh` makes
  tailscaled answer SSH on the node's Tailscale address itself, authenticated
  by the tailnet's ACL `ssh` block rather than by the host's `authorized_keys`.
  It is reachable only from the tailnet — the same trust boundary that already
  governs every web interface in the bundle — and adds nothing to the
  internet-facing surface, which stays behind the fail-closed firewall. What it
  does change is that tailnet ACL policy, not the host's SSH configuration,
  becomes the thing that decides who gets a root shell. A new tailnet's default
  policy permits `autogroup:member` → `autogroup:self` as root with `check`
  (periodic browser re-authorization). An operator who does not want that must
  narrow the tailnet's `ssh` block; the installer deliberately does not edit
  account-level ACLs.

### DD-44: `install.sh` comments say what a block does; the rationale lives here (2026-08-03)

- **Decision:** comment blocks in `install.sh` are one to six short lines
  stating what the code does and, where a choice is non-obvious, naming the
  constraint in a clause — not reconstructing how it was found. The
  measurement narratives, the wrong first attempts and the dated evidence stay
  in this file, in `SECURITY_REVIEW.md`'s Review History and in `CHANGELOG.md`.
  A comment that needs the full story points at it (`bkz. DD-42`, `M11`, `H4`)
  rather than repeating it. Applied wholesale in `Q1-24`: 1179 comment lines
  became 517 across 229 blocks, with no change to any non-comment line.
- **Why:** the file had reached the point where reading the code meant reading
  around the commentary. Stage 2's login section carried 37 consecutive comment
  lines before its first statement; the image-tag block ran 28; several blocks
  recounted three superseded designs before describing the current one. That
  material is genuinely valuable — it is why `UN_LOG_QUEUES=0` was not used and
  why the journal is not consulted for the 410 wedge — but it is reference
  material, consulted when changing a decision, not when reading the code that
  implements it. Keeping it inline taxed every read to serve the rare one.
- **Why the rationale is not simply deleted.** Every long block removed here
  already had a durable home. `DD-37`/`DD-42` hold the login archaeology,
  `DD-18`/`M11` the socket-buffer ordering, `DD-23` the float-tag digests,
  `M1` the absent `mem_limit`, `DD-27` the FileBrowser admin account, `DD-40`
  the policy-file activation. The reduction moved the reader one hop away from
  the story, it did not end it — and the surviving one-liners keep the pointer
  so the hop is findable.
- **What was deliberately not touched:** the eight `#!` shebangs, the single
  `# shellcheck disable=SC1091` directive, and the eight `# AŞAMA N — …`
  banners. The first two are load-bearing, and the banners are the file's
  only structural navigation.
- **How it was verified.** The transformation was applied by an explicit
  line-range map rather than a pattern rule, so nothing outside the 229 listed
  ranges could be reached; the script asserts every targeted line is a comment,
  is not a shebang and is not a `shellcheck` directive before writing anything.
  The proof that no behaviour changed is a diff of both revisions with all
  whole-line comments stripped: 5351 lines, byte-identical.
  `./scripts/check-all.sh` clean at 176 cases.

> **Amended 2026-08-03 (`Q1-25`).** The decision above kept a one-to-six-line
> "what this does" comment on each block. The operator's follow-up removed even
> those: *"yorum satırlarını eğer yükleme esnasında ekrana yazılmıyorsa direkt
> kaldırabiliriz. koda çıplak bakmayacağımız için görmemiz mümkün değil
> aslında."* `install.sh` now carries **no explanatory comments at all** —
> 508 further lines removed, 5868 → 5356, leaving nine `#` lines: eight `#!`
> shebangs and one `# shellcheck disable=SC1091`.
>
> Both survivors are load-bearing rather than editorial. The shebangs set the
> interpreter for the seven heredoc-generated helper scripts. The `SC1091`
> directive suppresses a real warning on `source /etc/os-release`; deleting it
> breaks `shellcheck install.sh`, which is check 2 of `./scripts/check-all.sh`.
> The eight `# AŞAMA N — …` banners did **not** survive: each is immediately
> followed by a `progress_stage_begin N "…"` call that prints the same
> information to the operator's screen, so the banner duplicated a line the
> code already emits. Stage boundaries remain locatable by `grep -n
> 'progress_stage_begin [0-7] '`, which is what `docs/architecture.md` already
> told readers to use.
>
> The premise is the operator's own working method rather than a general claim
> about comments: this script is read through its documentation and its printed
> output, not opened in an editor. A comment nobody reads is not neutral — it
> is 22% of the file standing between the reader and the code, and it decays
> silently because nothing verifies it. The rationale is unaffected; it was
> already relocated by `Q1-24` and is still here, in `SECURITY_REVIEW.md`'s
> Review History and in `CHANGELOG.md`.
>
> **Verified the same way, and one class was checked that `Q1-24` did not
> need.** Removal is a blanket rule this time, so a `#` line that was *content*
> rather than a comment would be silently destroyed — a YAML block scalar
> (`key: |`) is the one place in this file where that could happen, since
> `filebrowser.yaml` and `compose.yaml` are both generated from heredocs.
> There are none: the pattern `:\s*[|>]` does not occur anywhere in the
> pre-removal file. Every other generated format treats a leading `#` as a
> comment (dnsmasq, systemd units, Caddyfile, `sysctl.d`, `modules-load.d`).
> The proof that nothing else moved is a diff of both revisions with all
> whole-line comments and blank lines stripped: **4790 lines, byte-identical**.
> Four blank-line runs created by the removal were collapsed to one.
> `./scripts/check-all.sh` clean at 176 cases.

### DD-45: The firewall helper requires ip6tables instead of degrading toward it (2026-08-03)

- **Decision:** `docker-tailscale-fw` hard-fails at the top when
  `command -v ip6tables` finds nothing, before it takes its lock and before it
  touches a single chain. The three `[[ -n "$bin" ]] || return 0` early
  returns in `ensure_forward_prefix`, `apply_tailnet_guard` and `apply_ipv6`
  are gone, and `apply_ipv6`'s "DOCKER-USER missing → warn and skip" branch is
  now the same hard failure `apply_ipv4` already used.
- **Why:** the helper claimed two contradictory contracts. Four branches
  promised graceful degradation when IPv6 tooling was unavailable, and then
  `check_policy` — `check_ipv4_policy && check_ipv6_policy`, with
  `check_ipv6_policy` returning 1 outright on a missing binary — made the run
  exit 1 anyway. The graceful path could not lead anywhere except the same
  failure, so it bought nothing and cost a reader the time to work that out.
- **Why *require* rather than *skip*.** Stage 2 writes
  `net.ipv6.conf.all.forwarding = 1`. Without ip6tables there is no
  `MASTER-DOCKER`/`MASTER-TS-FORWARD` on the v6 side, so continuing would mean
  IPv6 forwarding enabled with no Tailnet isolation guard behind it — the
  exposure the helper exists to prevent. Failing closed is the only answer
  consistent with the rest of the file. In practice nothing changes: the
  `iptables` Debian package installed in Stage 1 provides `ip6tables`.
- **One branch was provably dead, not merely redundant.** `apply_ipv6`'s
  DOCKER-USER warning could never fire: `ensure_forward_prefix
  "$IP6TABLES_BIN"` runs first and returns 1 — under `set -e`, killing the
  helper — if that same chain is absent.
- **`check_ipv6_policy`'s own `[[ -z "$IP6TABLES_BIN" ]]` guard is deliberately
  kept.** It is **M5**'s remediation ("this must not be masked behind the
  generic policy-drift error") and it has a Bats case that calls the extracted
  function directly. The top-level guard makes it unreachable in production,
  but removing it would delete a security finding's test to save four lines,
  and the suite's function-extraction technique cannot test a top-level guard
  in its place. It stands as an independently verified precondition on the
  function rather than as dead code.
- **Measured, not assumed.** The embedded helper was extracted and run against
  a PATH containing stub `ip`/`iptables`/`flock` and **no** `ip6tables`. New
  behaviour: rc 1 in both `apply` and `--check`, the specific message, and
  **zero `iptables` invocations** — proven by an invocation log the stub wrote.
  Old behaviour under the same conditions: `--check` reached rc 1 only after
  address resolution and an `iptables` call, printing the specific message
  *and* the generic "politika sapmış" line; `apply` installs the full IPv4
  policy first, because the apply order is `ensure_forward_prefix →
  apply_tailnet_guard → apply_ipv4 → apply_ipv6 → check_policy`. The old
  `apply` run could not be driven to completion — the crude `iptables` stub
  answers every `-C` probe with success, which makes `remove_legacy_wide_rules`
  loop forever; that is the stub's defect, not the helper's.
  `./scripts/check-all.sh` clean at 176 cases, M5's case among them.

### DD-46: A failed canonical bundle verification degrades reconcile instead of aborting it (2026-08-04)

- **Decision:** `canonical_bundle_ok`'s result is now a flag,
  `CANONICAL_BUNDLE_INVALID`, not an immediate `exit 1`. When it is set,
  reconcile reports the reason, skips **only** the blocks that read the
  canonical bundle, runs every other check and repair as usual, and still
  exits 1 at the end.
- **What is withheld:** the compose.yaml restore, the filebrowser policy
  restore and its container recreate, the `state.env`/dnsmasq/Caddy restores,
  and the dnsmasq/Caddy restarts that only make sense after those restores.
- **What now keeps working:** address re-binding into `/root/docker/.env`,
  IP-forwarding sysctl repair, `tailscale set` prefs/netfilter repair, the
  MASTER firewall renewal and `docker-tailscale-fw` restart, the Docker
  netfilter core-recovery hand-off, the UDP GRO repair, container restarts,
  the master-compose lifecycle, host WebDAV restart, and all disk/inode
  reporting. None of them reads the bundle.
- **Why:** the old gate was the widest blast radius in the script. Any one of
  the nine canonical entries carrying a wrong mode bit — or `SHA256SUMS`
  disagreeing on one byte — disabled the entire self-healing loop, including
  every repair that has nothing to do with the bundle, and produced one line
  of output every 20 minutes forever. A public-IP change on such a host would
  never be picked up; the firewall would never be renewed. The failure the
  gate protects against is "the reference copy is untrustworthy", which is a
  reason to refuse to *copy from* it, not a reason to stop looking at
  anything.
- **Why this shape and not a new one:** the script already answers this exact
  question in `CANONICAL_CONFIG_INVALID` — set a flag when the canonical
  runtime configs do not parse, report it, gate the dependent restore and
  restart blocks, force `RECOVERY_FAILED=1`. Q1-27 applies that established
  pattern to the second, broader case rather than inventing a third
  behaviour. Wherever `CANONICAL_CONFIG_INVALID` gates,
  `CANONICAL_BUNDLE_INVALID` gates too: an unverifiable bundle subsumes an
  unparseable config.
- **Degrading is not passing.** The flag is a member of
  `all_critical_state_healthy`, so `--check` cannot return 0 while it is set;
  it forces `RECOVERY_FAILED=1` alongside `CANONICAL_CONFIG_INVALID`; and the
  end-of-run postcondition sweep still calls `canonical_bundle_ok` directly,
  so a bundle broken *during* the run fails it even if the flag was clear at
  start. `--check` now emits `canonical_bundle=` so the reason is visible in
  `master-network --status` rather than only in the journal.
- **One hard exit is deliberately left in place.** The `STACK_SCHEMA` /
  port-shape gate immediately after still exits 1, because every later check
  consumes those values and there is no honest default to substitute. If the
  bundle is invalid *because* `state.env` is unreadable, reconcile stops
  there — but it prints the bundle diagnosis first, which is why the message
  is emitted at flag time rather than in the later drift report.
- **Amended 2026-08-04 (`Q1-31`) — the drift report was promising a restore
  it would not perform.** Live testing showed reconcile printing "canonical
  kopya geri yüklenecek" and then correctly withholding the restore, because
  that sentence predates this decision and was written when a restore always
  followed. The state/DNS/Caddy and filebrowser policy report lines are now
  conditional: with the bundle or the runtime configs unverifiable they say
  the restore will *not* happen, and go to stderr. The gating itself was
  right the whole time; only the sentence was wrong.
- **Live-verified 2026-08-04.** With one canonical file's mode broken,
  reconcile reported the bundle failure, repaired `net.ipv4.ip_forward`
  0 → 1 (a bundle-independent repair `Q1-22` would never have reached), left
  the drifted `/etc/caddy/Caddyfile` untouched, kept caddy running and exited
  1 with `canonical_bundle=1` in `--check`. Restoring the mode made the next
  run restore the file and exit 0.
- **Verified by mutation.** `test/canonical_bundle_degrade.bats` derives the
  invariant from install.sh's own text rather than restating the current
  lines: it splits reconcile's recovery half into top-level `if` blocks and
  asserts that every block whose body touches `$CANONICAL_DIR/` or calls
  `restore_missing_compose_file`/`restore_quantum_config` is gated on the
  flag, so a *new* ungated restore site fails the suite without anyone
  remembering to extend it. Four mutations were run against install.sh and
  each was caught: ungating the `state.env` restore, restoring the old
  `exit 1`, dropping the flag from `all_critical_state_healthy`, and
  over-gating the bundle-independent forwarding repair.
  `./scripts/check-all.sh` clean at 183 cases.

### DD-47: `cleanup_master_setup` asks `canonical_stage_is_current` instead of re-deriving it (2026-08-04)

- **Decision:** the staged-generation cleanup in `cleanup_master_setup` now
  calls `canonical_stage_is_current` rather than resolving
  `/usr/local/share/master-stack/current` itself and comparing the result
  against the raw `$CANONICAL_STAGE_DIR` string. The local
  `canonical_active_target` and its `readlink` are gone; the
  `.generation.*` `case` allowlist around `rm -rf` stays untouched.
- **Why:** one question was asked twice, two different ways, inside one
  function. `restore_dns_stack_on_failure` — called at the top of the same
  cleanup — used the predicate, which normalises **both** sides with
  `readlink -f`. The staged-directory block a hundred lines later resolved
  only the `current` symlink and compared it against the unresolved `mktemp`
  output, and hardcoded the root path instead of using `$CANONICAL_ROOT`.
- **The failure mode is self-destructive, not merely untidy.** Let any path
  component above the canonical root be a symlink and the two halves of one
  cleanup run answer differently: the DNS rollback snapshot is discarded as
  "already published" while the directory `current` points at is `rm -rf`'d
  as "not published". What remains is a `current` symlink to nothing, so
  `canonical_bundle_ok` fails on every subsequent reconcile. Since Q1-27 that
  no longer stops all repair (DD-46), but canonical restore is dead for good
  and no automatic path recreates the generation.
- **The equality branch is not dead and was not removed.** A signal arriving
  between the `mv -Tf` pointer swap and the `CANONICAL_STAGE_DIR=""` reset
  lands in `cleanup_master_setup` with the variable still set and `current`
  already pointing at the staged directory; keeping it is correct, and
  `test/dns_stack_rollback.bats` pins that ordering deliberately ("a
  committed current pointer closes the signal window before the flag
  update"). What Q1-28 removes is the second implementation of the
  predicate, not the branch it guards.
- **`[[ -n "$CANONICAL_STAGE_DIR" ]]` is kept** even though
  `canonical_stage_is_current` already returns 1 on an empty value. It makes
  "nothing was staged, so there is nothing to clean" explicit instead of
  leaving the `rm -rf` to be stopped by the `case` allowlist alone.
- **Verified by mutation.** `test/canonical_stage_cleanup.bats` lifts the
  block out of `cleanup_master_setup` (which cannot be sourced — it resets
  traps and exits) and runs it, in two forms: verbatim, for the allowlist
  case, and with the allowlist re-rooted at the fixture, without which the
  hardcoded `/usr/local` prefix would make every fixture path survive and
  the behavioural cases would pass vacuously. Four mutations were applied to
  install.sh and each was caught by a specific case: restoring the old inline
  comparison, dropping the allowlist, inverting the predicate, and removing
  the stage-side `readlink -f` inside the predicate — the last of which also
  fails an existing `dns_stack_rollback.bats` case, which is the point.
  `./scripts/check-all.sh` clean at 194 cases.

### DD-48: `probe_compose_runtime` measures; the caller reports (2026-08-04)

- **Decision:** `check_compose_runtime` is renamed `probe_compose_runtime`,
  its two `echo ... >&2` lines are removed, the observed WireGuard port is
  handed back in a new `WG_OBSERVED_PORT` global, the detection site reports
  both wg-easy conditions once per cycle, and `--check` gains
  `wg_setup=`/`wg_config=`.
- **Why:** the function is a predicate, a mutator of four globals, and — until
  now — a reporter, and it is called **five** times in a reconcile cycle:
  initial detection, the one-second retry, again after the filebrowser policy
  repair, as the post-start postcondition, and in the final sweep. Three of
  those five are pure predicate positions (`if ! …`, `elif ! …`, `! … ||`
  inside a compound condition), so each silently recomputed
  `COMPOSE_RESTART_TARGETS`, `WG_CONFIGURATION_INVALID` and
  `WG_SETUP_PENDING` where the caller wanted only a boolean.
- **This is DD-33 finished, not a new idea.** DD-33 moved the filebrowser
  password probe out of this same function for this same reason — "the probe
  rode along with all four" calls. The two stderr lines were left behind and
  kept the multiplier: a host with a wg-easy port mismatch printed the same
  error four times per cycle, plus the caller's own line, every twenty
  minutes, for a condition the script explicitly refuses to auto-repair.
- **`--status` was the visible damage.** It captures `--check` with `2>&1`
  (`status_check_output="$("$0" --check 2>&1)"`), so those prose lines landed
  inside the machine-readable `key=value` block, one or two copies deep.
  They are now data in that block instead.
- **Where the report goes matters.** It sits at the detection site rather
  than in the drift report, because `WG_SETUP_PENDING` deliberately does not
  set `runtime_ok` (DD-12/H6) — a host whose only issue is a pending wg-easy
  setup passes `all_critical_state_healthy` and exits before the drift report
  is ever reached. Reporting there would have silently deleted the signal.
- **No live bug was found.** Every reset was traced against every reader:
  none of them changes a decision today, because `RECOVERY_FAILED` latches
  one-way and the final sweep re-measures. The finding is that correctness
  rests on "nothing reads these after the reset", which nothing enforces.
- **Two things deliberately left alone.** The five calls are not reduced —
  three of them are postconditions whose whole purpose is to re-measure after
  a mutation, and caching would defeat them. And the retry asymmetry (the
  detector retries after `sleep 1`, the postcondition does not) is correct,
  not an oversight: `master-compose.service` is `Type=oneshot` with
  `docker compose up -d --wait --wait-timeout 180`, so `systemctl start`
  returns only after Docker has settled health, while the detector runs cold.
- **The function had no tests at all.** Its component probes are covered in
  `test/reconcile_probes.bats`; the 110-line composite that resets four
  globals from five call sites was not. `test/compose_runtime_probe.bats`
  now pins the contract with stubbed component probes, including DD-12/H6's
  rule that a pending setup must not fail the probe — a regression there
  breaks every fresh install at Stage 7, which is how H6 was found. Seven
  mutations were applied to install.sh and each was caught by a specific
  case: printing from inside the probe, making `/setup` count as drift,
  dropping the reset block, queueing a restart for a port mismatch, treating
  `starting` health as healthy, removing the caller's report, and dropping
  the new `--check` keys. `./scripts/check-all.sh` clean at 206 cases.
- **Corrections made along the way:** DD-12 claimed the `/setup` branch sets
  `WG_CONFIGURATION_INVALID` and that `RECOVERY_FAILED` therefore surfaces it
  every cycle; both stopped being true when `WG_SETUP_PENDING` was split out.
  DD-33 says four call sites; there are five. Both entries carry dated
  amendments. The old function name is kept verbatim in `CHANGELOG.md`,
  `SECURITY_REVIEW.md` and completed `TODO.md` items, which record what was
  true at the time.

### DD-49: Every unit on the `OnFailure` arc is restarted behind the repair cooldown (2026-08-04)

- **The arc.** Five units declare `OnFailure=master-network-reconcile.service`
  — `docker-tailscale-fw`, `master-compose`, `master-webdav`, and the `dnsmasq`
  and `caddy` drop-ins — and reconcile restarts all five. Every edge runs in
  both directions.
- **Why the synchronous case does not spin.** When reconcile's own
  `systemctl restart X` fails, X enters `failed` and raises an `OnFailure`
  start job for reconcile *while reconcile is still active*; systemd merges it
  into the running job, so no second run happens. `master-network-reconcile`
  itself carries neither `OnFailure=` nor `Restart=`, so the arc terminates
  there rather than re-entering.
- **The asynchronous case is the real one.** A daemon that starts cleanly
  (`systemctl restart` returns 0), lets reconcile finish and exit, then dies
  seconds later trips `Restart=on-failure`, hits its start limit, fails, and
  fires `OnFailure` with reconcile inactive. That runs reconcile *immediately*
  rather than on the twenty-minute timer, and the run's first act is to
  restart the same daemon again.
- **Decision:** the `master-webdav`, `dnsmasq` and `caddy` restart paths now
  go through `restart_budget_available` / `record_container_restart`, matching
  the four paths that already did (`tailscale-udp-gro`, `master-compose`,
  the filebrowser policy repair, the generic container targets). A deferred
  restart reports `cooldown içinde; tekrarlanmadı` and sets
  `RECOVERY_FAILED=1`, exactly as the existing paths do.
- **Why those three specifically:** they were the only restart sites in
  reconcile with no budget call, and they are also the three arc units with
  `Restart=on-failure` plus a `StartLimit`. Worse, each called
  `systemctl reset-failed` first — which clears systemd's start-limit counter,
  the *other* brake. So the arc's three most restart-prone units had both
  brakes removed, one by omission and one deliberately.
- **`reset-failed` stays.** Without it a unit parked in "start request
  repeated too quickly" can never be recovered by reconcile at all. It is now
  simply unreachable until the budget allows a restart.
- **This is DD-21's own stated purpose, applied where it was missing.** DD-21
  calls the cooldown "a brake on the event-driven (`OnFailure`) paths, which
  can fire at any moment", and `docs/testing.md` calls it "the only thing
  between a repeatedly-failing repair and a restart loop". Both were written
  while three of the five arc units bypassed it.
- **What bypasses the budget, and why.** `TAILSCALE_ADDRESS_CHANGED` — all
  three daemons bind that address, so deferring the rebind would leave them
  listening on an address that no longer exists; this is the same exemption
  `master-compose` already had for `ADDRESS_CHANGED`. And
  `DNS_CONFIG_DRIFTED` / `CADDY_CONFIG_DRIFTED` — restoring a canonical config
  and then not restarting the daemon would leave it serving the old one.
  Neither is a failure signal. `*_INACTIVE` and `*_RUNTIME_DRIFTED` are, and
  they are gated.
- **One site is deliberately left ungated:** `systemctl start
  master-compose.service`, which is also reached via `COMPOSE_INACTIVE`. There
  the whole stack is down, and a fifteen-minute wait costs far more than a
  slow retry. That loop is bounded by construction anyway — each attempt runs
  `docker compose up -d --wait --wait-timeout 180` under
  `TimeoutStartSec=330`. The `docker-tailscale-fw` restart is also not gated
  in its own block, because it only runs under `STACK_RESTART_REQUIRED`, which
  an earlier block sets behind `restart_budget_available master-compose`.
  Both exemptions are named in `test/onfailure_arc.bats` with their reasons,
  so adding a third is a conscious act rather than an omission.
- **What changes on a live host.** A caddy (or dnsmasq, or WebDAV) that is
  down is now restarted at most once per fifteen minutes instead of once per
  reconcile run. Scheduled runs are unaffected: DD-21 set the interval to
  twenty minutes precisely so it exceeds the cooldown. Only the event-driven
  storm is braked.
- **Verified by mutation.** `test/onfailure_arc.bats` derives the arc's unit
  set from install.sh's own `OnFailure=` lines and walks every top-level
  if-block of the reconcile script, so a *new* unit wired onto the arc and
  restarted unbraked fails the suite without anyone extending it. Seven
  mutations were applied and each was caught: removing caddy's gate, letting
  `CADDY_INACTIVE` bypass it, removing the address-change exemption, renaming
  the restart stamp so writer and reader disagree, dropping the deferral's
  `RECOVERY_FAILED`, giving `master-network-reconcile.service` a `Restart=`,
  and adding a sixth unit to the arc with an ungated restart.
  `./scripts/check-all.sh` clean at 215 cases.
- **Amended 2026-08-04 (`Q1-31`) — the exemption must bypass the brake, not
  consume it.** The first live run found a defect in this decision as
  originally shipped: `record_container_restart` was called on the exempt
  path too, so a legitimate Caddyfile restore stamped the budget and then a
  genuine caddy failure three minutes later was refused for fifteen minutes.
  Caddy sat `inactive` while reconcile reported `cooldown içinde` — strictly
  worse availability than before `Q1-30`. Each block now sets an explicit
  `*_RESTART_EXEMPT` flag and stamps only when the budget path was actually
  taken. The brake still engages, one restart later: a failure-driven restart
  always consults and stamps, so the second one in fifteen minutes is
  refused. Verified on the host in both directions — exempt restart leaves no
  stamp and the following failure is repaired; the failure after that is
  braked, with dnsmasq repaired in the same run to confirm per-unit scoping.
- **`master-compose` has the same property and was left alone.** Its
  `ADDRESS_CHANGED` bypass still calls `record_container_restart`, so an
  address change spends the stack's budget. That is pre-existing behaviour
  outside this decision's scope; it is recorded in `TODO.md` rather than
  changed unasked.
- **Live-verified 2026-08-04** except the systemd job-merging claim, which is
  reasoning about documented behaviour rather than a measurement; confirming
  it needs a deliberately crash-looping daemon.

### DD-50: The installer has one definition of "online", and its waits count time rather than iterations (2026-08-04)

- **Decision:** `tailscale_is_online()` is deleted. Its three call sites in
  Stage 2 now call `tailscale_login_complete()`, which is JSON-backed. Both
  Stage 2 waits are bounded by a wall-clock deadline instead of an iteration
  count.
- **Why the old predicate had to go.** It decided from human-readable output:
  `tailscale status --self | head -n 1`, true when the line was non-empty and
  did not contain the substring `offline`. That is a locale- and
  format-dependent parse standing next to two JSON-based siblings, and it was
  the only one of the three with no test coverage at all.
- **It was not merely fragile — it could say yes when the answer was no.**
  With `BackendState=Starting` the self line prints and contains no "offline",
  so Stage 2's final 180-second gate could pass on a node that was not
  Running. `tailscale_login_complete` requires `BackendState == "Running"`,
  `Self.Online == true`, a non-empty `Self.ID` and non-empty
  `Self.TailscaleIPs`; the `Self.ID` clause is also the signal the surrounding
  code was already trying to infer from the journal for a node deleted in the
  admin panel.
- **Why the loops changed too.** `tailscale_login_complete` wraps
  `tailscale status --json` in `timeout $TAILSCALE_LOGIN_STATUS_TIMEOUT` (3
  seconds). Against a wedged daemon each probe costs seconds rather than
  milliseconds, so `for _ in $(seq 1 90); do …; sleep 2; done` would run for up
  to 450 seconds while its own error message says "180 saniye içinde". Both
  waits now compute a deadline from `SECONDS` — the idiom
  `tailscale_interactive_login` already uses — so the printed durations stay
  true whatever a probe costs. This also removes a smaller pre-existing
  inaccuracy: the old loops were never exactly 60 or 180 seconds either, since
  each probe's own runtime was unaccounted for.
- **Precondition checked, not assumed:** `jq` is in Stage 1's package list, so
  it is present at the first call site, which runs before the interactive
  login.
- **Two things the original audit note got wrong, corrected here.** It claimed
  the change takes three definitions to one; it does not. Reconcile's
  `tailscale_online()` lives in a separately generated script that cannot call
  an installer function, so **two** JSON-based definitions remain in two
  programs, and what is removed is the text-parsing one. The note also missed
  the loop-duration consequence entirely.
- **Reconcile's predicate is deliberately left looser** (`BackendState` and
  `Self.Online` only). It answers a different question — "is this established
  node still online", asked every twenty minutes — rather than "did
  registration complete". Tightening a steady-state health predicate is a
  separate behaviour change with its own blast radius and its own tests.
- **`tailscale status --self` still runs once**, purely to print which node was
  found. That is output, not a decision, and `test/tailscale_online_gate.bats`
  pins that exactly one use survives.
- **Verified by mutation, including the timing claim.** Five mutations were
  applied to install.sh and each was caught: restoring the text predicate and
  using it at the gate, reverting either wait to an iteration-bounded loop, and
  removing the `break` so the success path waits out the deadline. A fifth —
  moving the deadline 30 seconds later while keeping its shape — made the
  wall-clock case fail after ~33 seconds, which is what shows that assertion
  measures the bound rather than passing vacuously. `./scripts/check-all.sh`
  clean at 224 cases.

### DD-51: Stage 2 bounces the tailscaled daemon without bouncing the stack (2026-08-04)

- **Decision:** Stage 2 no longer enqueues dependency-carrying jobs against
  `tailscaled`. `systemctl enable --now tailscaled` became
  `systemctl enable tailscaled` followed by
  `systemctl is-active --quiet tailscaled || systemctl start tailscaled`, and
  the login retry loop's daemon reset became
  `systemctl restart --job-mode=ignore-dependencies tailscaled`.
- **What couples them.** Two drop-ins written later in the same run make
  `tailscaled` the runtime anchor of the whole stack:
  `tailscaled.service.d/98-master-stack.conf` declares
  `Wants=docker-tailscale-fw.service master-compose.service
  master-webdav.service` and `99-caddy-tailnet.conf` adds `Wants=caddy.service`;
  the same four units declare `PartOf=tailscaled.service` back. On a **fresh**
  install neither half exists yet when Stage 2 runs, so this is invisible. On a
  **reinstall** both already exist on disk, and every job Stage 2 enqueues
  against `tailscaled` reaches all four.
- **Two different mechanisms, which is why one fix would not have done.** A
  *start* job pulls the `Wants=` set; a *restart* job propagates through
  `PartOf=`, and that clause lives on the four stack units, not on `tailscaled`.
  Deleting the drop-in would therefore have silenced the first and left the
  second untouched. `--job-mode=ignore-dependencies` suppresses both, which is
  why the restart path needs nothing else.
- **Measured, not reasoned.** On the test host, with the reconcile timer stopped
  and reconcile confirmed inactive so it could not be the cause:
  `systemctl enable --now tailscaled` against an *already active* `tailscaled`
  started `caddy` and `master-webdav` from inactive. The same command returned in
  0 seconds while `master-compose` was still `activating`, so the pulled jobs are
  **not** waited on. And `systemctl restart --job-mode=ignore-dependencies
  tailscaled` restarted the daemon while leaving `caddy`/`master-webdav`
  inactive and `master-compose`'s `ExecMainStartTimestampMonotonic` unchanged.
- **Why non-blocking is the bad news, not the good news.** The pulled units run
  *concurrently* with the rest of the installer. `master-compose`'s `ExecStart`
  (`docker compose up -d --remove-orphans --wait`) and its `ExecStartPre`
  (`master-compose-ipv4`, which rewrites `/root/docker/.env`) take no lock —
  unlike reconcile, which takes `master-stack.lock` with `flock -n` and defers
  with exit 75, and unlike `docker-tailscale-fw`, which has its own separate
  lock. So the installer's own `flock` on `/run/lock/master-stack.lock` does not
  exclude them. A background `docker compose up` against the *previous* version's
  `compose.yaml` therefore overlaps Stage 4 rewriting that file and Stage 5
  running its own compose commands on the same project — the same class as the
  `<id>_<name>` replace-name orphan recorded in `TODO.md`.
- **The case that actually bites is the repair reinstall.** When all four units
  are active, `enable --now` is a no-op for them; that is why every upgrade on
  the test host looked clean. The units are inactive precisely when someone
  reruns the installer *because* something is broken.
- **What the original audit note got wrong.** It named the login retry loop's
  `systemctl restart tailscaled` as the trigger and proposed
  `systemctl stop master-compose.service` before it. Three errors: that line runs
  only when a reinstall *also* needs a fresh login, while the unconditional
  trigger is the `enable --now` that runs on every single invocation; the
  affected set is four units including `caddy`, which is Stage 6, not "Stage 3/4
  units"; and stopping `master-compose` would not have helped, because the
  restart's `Wants=` pull starts it straight back and the other three units are
  not covered at all.
- **The operator recovery hint is deliberately left alone.** The message that
  prints `systemctl restart tailscaled && tailscale up` is advice for a human
  running it with the installer stopped, where pulling the stack back up is the
  entire point. `test/tailscaled_job_isolation.bats` distinguishes the two by
  requiring the guard only on lines whose first word is `systemctl`.
- **Verified by mutation.** Five mutations, each caught by a specific set of
  cases: restoring `enable --now` (cases 2, 3, 6, 7), dropping the job-mode flag
  (4, 8), splitting the restart into a `stop`/`start` pair (4, 8), and removing
  the drop-in's `Wants=` line (1, the case that asserts the coupling still
  exists). A sixth — moving the flag *after* the unit name — was measured on the
  test host and turns out **not** to be a defect: `systemctl` permutes its
  arguments and the job is isolated either way, so the test pins the flag
  reaching `systemctl` in one invocation rather than pinning argument order.
  `./scripts/check-all.sh` clean at 232 cases.

### DD-52: `--check` does not pay a readiness wait for a value no rule uses (2026-08-04)

- **Decision:** `TAILSCALE_IPV4` is deleted from `docker-tailscale-fw`. The WAN
  IPv4 resolution it shared is split into `resolve_wan_ipv4` (one attempt) and
  `wait_for_wan_ipv4` (a wall-clock deadline). `apply` waits; `--check`
  resolves once and exits 1 immediately when the addresses are absent.
- **The value was dead, and its origin is in the history rather than in a
  design.** `V1-3` (`9b8d754`, 2026-07-30) replaced the sftpgo container with
  the host rclone WebDAV service and deleted the only two places
  `$TAILSCALE_IPV4` was used inside the helper — the
  `--ctorigdst "$TAILSCALE_IPV4" --ctorigdstport 65113` allow in
  `MASTER-TS-FORWARD` and its matching string in `check_ipv4_policy`'s expected
  set. The 300-second gate that resolved the value stayed behind. Across the
  helper's 489 lines the name appeared four times, all four inside that gate.
- **Measured before the change, on the test host, against the deployed helper**
  (byte-identical to the repository's, `8ae63f6c…`): a healthy `--check`
  returns in **0.162 s**; with no IPv4 on `tailscale0` it returns in
  **305.9 s** with `HATA: Firewall için Tailscale IPv4 300 saniyede hazır
  olmadı.` The message identifies the branch, which is how we know
  `check_policy` was never reached.
- **What those five minutes cost reconcile.** Reconcile calls `--check` at
  three sites. The first (`FIREWALL_DRIFTED`) is unconditional, and a non-zero
  exit there is indistinguishable from real policy drift, so the wait cannot
  change the outcome — it only delays it. `FIREWALL_DRIFTED=1` then sets
  `STACK_RESTART_REQUIRED=1`, which consumes `master-compose`'s restart budget,
  stops the stack, restarts `docker-tailscale-fw.service` (whose `apply` pays
  the same gate again under `TimeoutStartSec=600s`) and re-runs `--check`. On a
  host whose node has gone addressless one reconcile turn spends roughly
  fifteen of the timer's twenty minutes and bounces the Compose stack — driven
  entirely by a value no rule references. The third call site is spared only
  incidentally: `! tailscale_online` precedes it in the same `||` chain.
- **The apply-side risk was measured, not reasoned about.** Removing the gate
  shortens `apply`'s settling window, so the question is whether it was
  guarding `ensure_forward_prefix`'s real precondition — the `ts-forward`
  chain. A probe sampling every 200 ms across a real reboot of the test host
  answered it: at **+1.16 s** `ts-forward` existed in both families and the
  `FORWARD` jump was installed while `tailscale0` still had **no** IPv4, which
  arrived at **+1.37 s**. The chain is ready *before* the address, so the
  address gate never was what protected it; `ensure_forward_prefix`'s own
  30-second `wait_for_chain` is the guard, and it is unchanged.
  `docker-tailscale-fw.service` ran at +4.6 s and finished in 0.77 s.
- **Why the deadline shape changed too.** The old loop was `for _ in $(seq 1
  300)` with `sleep 1` and three `ip` invocations per turn, so it counted
  iterations while its message promised seconds — DD-50's finding, in the other
  program. The 305.9 s measurement is that drift. `wait_for_wan_ipv4` computes
  a deadline from `SECONDS`, so the printed 300 seconds is the real bound
  whatever a probe costs.
- **`apply` still waits, deliberately.** `PUBLIC_IPV4` is interpolated into
  three `MASTER-DOCKER` rules, so it is load-bearing there and a boot-time
  absence is worth waiting out. In `--check` the same absence means only "this
  cannot be verified right now", which is already what the caller does with it.
- **Verified by mutation, and one mutation corrected the tests rather than the
  code.** Five mutations were applied and each was caught: reintroducing the
  `TAILSCALE_IPV4` resolution, routing `--check` through `wait_for_wan_ipv4`,
  reverting the deadline to an iteration count, sleeping before the first
  attempt, and making `resolve_wan_ipv4` always succeed. The last one initially
  escaped two cases written as `! resolve_wan_ipv4`: bash exempts an
  `!`-inverted command from `set -e`, so that form asserts nothing unless it is
  a test's final line. Those cases now capture the status explicitly. Nine
  other non-final `!` assertions exist across seven `.bats` files and are
  recorded in `TODO.md` as their own item — not all are dead, since several are
  followed by a stronger sibling, but none of them currently prove that.
  `./scripts/check-all.sh` clean at 239 cases.

### DD-53: The media-tree ownership repair never dereferences (2026-08-04)

- **Decision:** Stage 4's `find "$DOWNLOADS_PATH/media" \( ! -uid 1000 -o
  ! -gid 1000 \) -exec chown …` now runs `chown -h`.
- **The defect.** `find` defaults to `-P`: it does not follow symlinks, it
  *reports* them. `chown` without `-h` dereferences whatever path it is
  handed. A symlink inside the media tree owned by anything other than
  `1000:1000` therefore satisfied the predicate and redirected the ownership
  change onto its target, anywhere on the host.
- **Measured before the fix, on the test host.** A root-owned
  `tree/innocent.mkv -> /tmp/d3/SENTINEL` left the symlink at `0:0` and moved
  the sentinel from `0:0` to `1000:1000`. After the fix the same fixture
  leaves the sentinel at `0:0`, moves the symlink itself to `1000:1000`, and
  still repairs a genuine `0:0` regular file — so the repair's actual job is
  intact.
- **Reachability was measured, not assumed.** The tree is bind-mounted into
  `qbittorrent` as `/downloads`; `docker exec qbittorrent id` reports
  `uid=0(root)` because the compose service sets no `user:`; and a symlink
  planted from inside the container appears on the host as `lrwxrwxrwx 1 0 0`,
  which is exactly the ownership the predicate selects. `1000` is the uid
  qbittorrent's own process runs under, so the target becomes a host file the
  container can then read or write. The trigger is an installer re-run, which
  this project does routinely.
- **Why `-h` rather than `! -type l`.** Skipping symlinks would leave a
  root-owned symlink in a tree that is otherwise uniformly `1000:1000`, and
  would leave the next reader to rediscover why. `-h` repairs the link's own
  ownership, which is what the loop was always trying to express, and removes
  the dereference as a class rather than excluding one case of it. On a
  non-symlink `-h` is a no-op, so the regular-file path is unchanged.
- **Deliberately out of scope:** `-xdev`. A separate filesystem mounted inside
  the media tree would still be walked. That is surprising but is not the
  same failure — it cannot be aimed at a chosen file — and bounding the walk
  is its own decision with its own blast radius.
- **Verified by mutation.** Three mutations, each caught by the case that
  claims it: dropping `-h`, moving `-h` after the owner spec where it no
  longer guards the first operand, and adding `! -type l` to the predicate —
  the last one confirms the "find selects the symlink" case measures
  selection rather than passing vacuously. The suite stubs `chown` on `PATH`
  and records its arguments, so the cases need no root and change no real
  ownership. `./scripts/check-all.sh` clean at 242 cases.

### DD-54: Readability is not trust — reconcile stops reading configuration from a bundle it rejected (2026-08-05)

- **Decision:** `state_value` consults `$CANONICAL_DIR/state.env` only when
  `CANONICAL_STATE_TRUSTED` is set, which happens exactly where
  `canonical_bundle_ok` returns true. Otherwise it reads `$STATE_FILE`, the
  live configuration the running system was actually built with.
- **The contradiction, measured in a single run.** With `STACK_VERSION` edited
  in the canonical copy so `sha256sum -c` fails, one `--status` printed
  `canonical_bundle=1` and "bundle doğrulaması başarısız; canonical kopyadan
  geri yükleme yapılmayacak" *and* `Kurulum sürümü :
  TAMPERED-NOT-A-REAL-VERSION` — read from the file it had just declared
  untrustworthy, while the intact `/etc/master-stack/state.env` sat unread.
  Side by side afterwards on the same tampered bundle: `Q1-34` prints the
  tampered string, `Q1-36` prints the real `2026.08.04-Q1-34`.
- **`STACK_VERSION` was only the visible symptom.** The same call supplies
  `QBIT_PUBLIC_PORT`, `WG_PUBLIC_PORT`, `WEBDAV_PORT`, `LOCAL_DOMAIN`,
  `WG_ENDPOINT_HOST` and `DOWNLOADS_PATH`. Those feed the DNAT rule checks,
  the container port-binding checks, the DNS and Caddy probes and the disk
  thresholds — so a bad bundle could have redirected what reconcile *repairs
  toward*, not merely what it reports.
- **This is the missing half of DD-46.** That decision stopped a failed bundle
  check from aborting the run, so bundle-*independent* drift still gets
  repaired. It did not notice that the repairs were still taking their
  parameters from the distrusted file. The two together now say the same
  thing: a bundle that fails verification is not read for any purpose.
- **Why the live file is the right fallback rather than the built-in
  defaults.** `$STATE_FILE` is what the installer wrote and what the running
  units were configured from. Falling back to `state_value`'s defaults would
  invent a configuration the host never had. The existing `STACK_SCHEMA != 10`
  guard still fails the run closed if the live file is missing or malformed.
- **Both entry paths had to be fixed, and only one was obvious.** The main
  path decides at the existing gate. `--status` calls `state_value` roughly a
  hundred lines *earlier* than that gate, which is exactly where the
  contradiction was measured, so it now evaluates `canonical_bundle_ok` before
  printing anything. That is a second `sha256sum -c` over nine small files per
  `--status`; measured as immaterial next to the `--check` subprocess that
  mode already spawns.
- **One older test was rewritten rather than worked around.** DD-46's
  "the bundle gate sets a flag instead of exiting" pinned the literal string
  `if ! canonical_bundle_ok; then`, which the new success arm no longer uses.
  It now asserts the behaviour — the gate calls the predicate, sets the flag,
  never exits, still explains itself, and raises the trust flag — instead of
  the syntax. Its `! grep` line was also converted to an explicit status
  capture, since a non-final `!` asserts nothing.
- **Verified by mutation.** Three, each caught by the case that claims it:
  restoring the readability-only condition, defaulting the flag to trusted,
  and deleting the `--status` branch's decision. `./scripts/check-all.sh`
  clean at 245 cases.

### DD-55: Every wait that promises a duration now measures one (2026-08-05)

- **Decision:** the four remaining waits whose error message names a number of
  seconds compute a deadline from `SECONDS` instead of counting iterations:
  Stage 2's tailscaled-socket wait, `master-compose-ipv4`,
  `master-network-reconcile`'s address-ready retry, and
  `master-webdav-serve`. This finishes what DD-50 started in Stage 2 and
  DD-52 continued in the firewall helper.
- **The rule, stated precisely.** Not "no `seq` loops" — the invariant is that
  *a loop must not count turns while its message promises seconds*. Several
  `for _ in $(seq 1 N)` loops in this file are correctly iteration-bounded and
  were deliberately left alone: `create_staging_chain` and
  `create_ts_guard_staging_chain` retry on a random-name collision and take no
  `sleep` at all, so turns are the right unit; and the postcondition retries
  after a repair (`tailscale_prefs_ok`, filebrowser health, WebDAV, Stage 7's
  probe) make no duration claim to be wrong about. A survey of all nine
  remaining sites found exactly one that qualified — the socket wait — which
  is why this revision fixes four sites rather than three.
- **Measured, on the two sites that are whole embedded scripts.** Both were
  extracted and run for real against a stub `ip` costing three seconds per
  probe, with their budget rewritten to three seconds. Each exits 1 in three
  to seven seconds and names the bound it honoured; an iteration-bounded loop
  under the same stub takes roughly four times as long, which is the
  separation the assertions measure. Lower bounds are asserted too, so a loop
  that never waited would fail rather than pass.
- **The messages now interpolate the bound** rather than repeating a literal,
  so the number printed and the number honoured cannot drift apart again —
  which is how all four got out of step in the first place.
- **One related loop was found and deliberately not changed.**
  `tailscale_daemon_ready` counts thirty turns around `tailscale status
  --json` with no `timeout` wrapper, so an unresponsive daemon makes each
  probe arbitrarily expensive. Its caller's message claims no duration, so it
  is not this defect; but it is the unbounded-probe half of DD-50's argument
  and is recorded in `TODO.md` rather than fixed here.
- **Two older tests pinned the shapes being replaced** and were updated to
  assert the new one: `reconcile_control_flow.bats`'s address-readiness case
  pinned `ADDRESS_READY_WAIT_SECONDS / 2`, and the new suite's whole-file
  backstop replaced an early draft that banned `seq` outright — which would
  have condemned the four legitimate loops above.
- **Verified by mutation.** Four, one per site, each caught by the case that
  claims it; the whole-file invariant independently caught two of them.
  `./scripts/check-all.sh` clean at 250 cases.

### DD-56: The Compose stack does not depend on the Tailscale address (2026-08-05)

- **Decision:** `master-compose-ipv4` no longer treats the Tailscale IPv4 as a
  precondition for starting the stack — it waits for it, records it when it
  arrives, and starts anyway when it does not. `STACK_RESTART_REQUIRED` is
  keyed on `PUBLIC_ADDRESS_CHANGED` rather than the union `ADDRESS_CHANGED`.
  A stale address record is refreshed by running the helper directly, without
  touching any container.
- **The same origin as DD-52.** `V1-3` (`9b8d754`) replaced the sftpgo
  container with the host rclone WebDAV service and deleted
  `"${TAILSCALE_IPV4}:${WEBDAV_PORT}:…"`, the only place compose ever used the
  address. Two consumers were left behind pointing at it: a 120-second hard
  gate in front of the whole stack, and a five-container restart on every
  change.
- **Measured on the test host before the change.** `.env` carried
  `TAILSCALE_IPV4=100.121.18.22`; `compose.yaml` referenced it zero times; the
  address occurred **zero times in the fully rendered `docker compose
  config`**; every container port bound `127.0.0.1` or the public IPv4; and
  the only listeners on the Tailscale address were host services — dnsmasq
  :53, Caddy :80, rclone WebDAV :65113 and tailscaled :53071.
- **`PUBLIC_IPV4` stays a hard precondition** and its wait is unchanged,
  because it *is* interpolated into three container port bindings. The
  asymmetry is the point: one address is in the compose file, the other is
  not.
- **The refresh is the part that is easy to get wrong.** Removing the stack
  restart removes the only thing that used to rewrite `.env`, and `.env` is
  what `TAILSCALE_ADDRESS_CHANGED` is computed against. Left there, the flag
  would latch at 1 and restart dnsmasq, Caddy and WebDAV every twenty minutes
  forever. So reconcile now refreshes the record itself whenever it is stale,
  through the same `master-compose-ipv4` helper, which only rewrites `.env`
  atomically and never touches a container.
- **The predicate is shared rather than duplicated.**
  `compose_env_addresses_current` is what both the refresh and the final
  postcondition ask, so the condition that triggers the repair and the
  condition that accepts it cannot disagree. It is also the reason the refresh
  is correct regardless of which earlier block ran: it asks whether the record
  is stale *now*, not whether some particular repair happened.
- **The three genuine consumers are untouched.** `master-webdav`, `dnsmasq`
  and `caddy` still repair directly on `TAILSCALE_ADDRESS_CHANGED`; a test
  pins that all three arms survive, because the obvious way to get this wrong
  is to delete the signal along with the restart.
- **Verified by mutation.** Five, each caught by the case that claims it:
  restoring the Tailscale hard gate, dropping the WAN hard failure, routing
  the union flag back into the stack restart, deleting the refresh, and
  removing one of the three host-service repair arms. `master-compose-ipv4`
  is extracted and run for real against stub `ip` output, with `STACK_DIR`
  redirected out of `/root` and the budget shortened — both substitutions
  asserted after the fact so the case cannot silently test the wrong script.
  `./scripts/check-all.sh` clean at 258 cases.

### DD-57: A probe in a predicate position puts back what it measured (2026-08-05)

- **Decision:** the two postcondition positions that ask "is the Compose
  runtime still healthy?" call `compose_runtime_still_ok`, a wrapper that saves
  the four globals `probe_compose_runtime` resets, runs the probe, restores
  them and returns the probe's verdict. The three positions that *measure*
  still call the probe directly, because they consume what it publishes.
- **Why it is not simply a probe with no side effects.** DD-48 already moved
  the printing out of this function; the four globals could not follow, because
  they are the function's actual output. `COMPOSE_RESTART_TARGETS` is the list
  the repair loop restarts, and `WG_SETUP_PENDING` /
  `WG_CONFIGURATION_INVALID` / `WG_OBSERVED_PORT` are what the operator report
  and `--status`'s key=value line are built from. A predicate that computes
  them is fine. A predicate that *replaces* them behind the caller's back is
  not, and both shapes were the same call.
- **Latent, not live, and recorded that way.** Nothing reads the four globals
  after either postcondition — the report at the detection site, the wg-easy
  diagnostics and the restart loop all run earlier in the linear script. This
  was measured by ordering, not assumed: the last reader is the eligible-target
  loop, and both wrapper sites are below it. So this changes no behaviour
  today. It is fixed because the failure it sets up is invisible: a later line
  added below the postcondition reads a measurement of the world *after* the
  repair, silently, with nothing in the code to suggest that is what happened.
- **What makes the wrapper's reads safe.** Nothing declares those three `WG_*`
  globals at top level — the probe is their only writer. Under the reconcile
  script's `set -Eeuo pipefail` a wrapper call with no prior probe would abort
  the cycle on an unbound variable rather than measure anything. That is
  currently impossible because the detection call is unconditional, at top
  level, and above both wrapper sites; a case pins exactly that ordering rather
  than trusting it. Adding `:-` defaults was considered and rejected: it would
  turn "this ran too early" from a loud abort into a silent zero.
- **The restart-target restore is guarded on count.** `saved_targets=(
  "${COMPOSE_RESTART_TARGETS[@]}" )` on an empty array is an unbound expansion
  under `set -u` on the target's bash, so both the save and the restore sit
  behind `(( saved_count > 0 ))`, with an unconditional `COMPOSE_RESTART_TARGETS=()`
  ahead of the restore so the probe's own findings cannot leak into a caller
  that had queued nothing.
- **Verified by mutation.** Seven, each caught by a case that names it:
  dropping each of the three `WG_*` restores individually, dropping the array
  clear that precedes the restore, returning `0` instead of the probe's status,
  putting the probe back in a postcondition position, and using the wrapper at
  the detection site so nothing publishes the globals first. The sixth of these
  is the one that matters most — it is the regression this whole item exists to
  prevent, and the derived case catches it by reading the reconcile script's
  own call sites rather than restating them.
- **One mutation initially survived and the test was wrong, not the code.**
  Dropping the `WG_SETUP_PENDING` restore changed nothing, because the case
  left the fixture identical between the two measurements — so the value the
  wrapper restored and the value its probe recomputed were the same number. The
  case now completes the wg-easy setup wizard *between* the measurement and the
  postcondition, which is the realistic shape and the only one where a missing
  restore is observable. Same lesson as `Q1-33`, from the other direction: a
  surviving mutation is either a missing test or a defect that is not one, and
  the way to tell is to make the two measurements disagree.

---

## Installer design decisions

The entries below describe the multi-file successor historically released
with `v2-*` version identifiers (see `docs/contract.md` and
`docs/architecture.md`). The active files now live at the repository root.
They do not apply to the retired single-file monolith, which remains only in
Git history. They are numbered in the same sequence deliberately: a decision
that supersedes an earlier one should be findable next to it, not in a
separate document with its own numbering.

### DD-58: v2 abandons the single-file model — supersedes DD-9 (2026-08-05)

- **Decision:** v2 is a repository tree — one orchestrating `install.sh`,
  two libraries, four templates, four helper scripts and three systemd
  units — rather than a single script that carries its helpers as heredocs.
  DD-9 is superseded for the successor. At the time of this decision, the
  retired monolith kept its single-file model unchanged; DD-9 remains the
  accurate historical record of that file.
- **Rationale:** DD-9's trade-off line predicted this. The embedded scripts
  are invisible to `shellcheck install.sh` and `bash -n install.sh`, which
  is why `scripts/lint-embedded-scripts.sh` had to be written to lint
  string literals. At 5495 lines the mitigation stopped scaling: the file
  had 1179 comment lines removed in `Q1-24`/`Q1-25` partly because nobody
  read it in an editor, and three real bugs (**H1**'s regression, **H5**,
  **H6**) were reachable only through live execution because static review
  could not see into the heredocs. A file per responsibility gets all seven
  helpers under the normal linter with no custom tooling.
- **Replacement delivery model:** `git clone` (or a release tarball of the
  same tree), then `install.sh`. The curl-pipeable single artefact is
  the thing being given up, and that is the real cost of this decision —
  provisioning now needs the repository present on the host.
- **Trade-off accepted:** more files to keep in sync, and a class of bug
  that could not previously exist (a helper referring to a constant the
  installer never rendered). `config/defaults.env` as the single source of
  truth and the hard-error-on-unsubstituted-token rule in the renderer
  exist to bound that class.

### DD-59: The firewall owns two chains, named once (2026-08-05)

- **Decision:** `MASTER-INPUT` holds the host INPUT policy; `MASTER-DOCKER`
  holds the container policy reached through a single jump from
  `DOCKER-USER`. `MASTER-DOCKER-FILTER` is not used. The same two logical
  names are used for IPv4 and IPv6 — the tables are separate, so there is
  no collision — and both are declared in `config/defaults.env` and
  nowhere else. A chain name appearing as a literal in a second file is a
  defect.
- **Rationale:** Two sources proposed names (`MASTER-DOCKER` in
  conversation, `MASTER-DOCKER-FILTER` in `.cursor/rules/`), both as
  examples. The value is cosmetic but it is a single-source-of-truth value:
  the failure it prevents is a helper that creates one chain while the
  verification step looks for another, which fails open — an absent chain
  filters nothing.
- **A third chain was dropped.** `defaults.env` also carried
  `MASTER-TS-FORWARD`, inherited from v1's mangle-table chain. No clause of
  the v2 contract requires it and it was not part of the decided set, so it
  was removed rather than kept in case it turns out to be needed. If the
  firewall phase finds a genuine need for a `FORWARD`- or mangle-table
  chain, that is a new decision with an explicit name.
- **`MASTER-INPUT` is new in v2.** v1 filtered container traffic through
  `DOCKER-USER` but never wrote a host INPUT policy at all, so services
  listening on the host — WebDAV among them — were protected only by what
  they chose to bind to.
- **v2-3 (2026-08-06): `ts-input` must precede `MASTER-INPUT`.** Our
  INPUT jump must not shadow Tailscale's `ts-input` (UDP 41641 / spoof
  guards). `--check` asserts the order when the Tailscale chain exists.
- **v2-16 (2026-08-07): reorder without a gap.** The first
  `ensure_ts_input_precedence` deleted every `MASTER-INPUT` jump and then
  re-inserted it after `ts-input`, leaving INPUT briefly without our
  policy (default ACCEPT risk). Apply now inserts INPUT jumps after
  `ts-input` when present (`activate_named` / `ensure_jump`), and
  precedence repair uses insert-before-delete so a `MASTER-INPUT` jump
  always remains while wrong earlier jumps are removed.
- **v2-3: IPv6 INPUT must allow NDP/ICMPv6.** A terminal DROP of all NEW
  IPv6 (the first `apply_input6` shape) broke neighbor discovery for the
  provider's link-local default (`fe80::1` → `FAILED`), so IPv6 egress and
  Tailscale control-plane Happy Eyeballs paths hung while IPv4 stayed up.
  Essential ICMPv6 types are accepted before the WAN DROP.
- **v2-23 (2026-08-07): oneshot retry + DOCKER-USER wait.** Boot/Docker
  races where `DOCKER-USER` is briefly missing used to fail the oneshot
  once with no retry (`Restart=no`). The unit now uses `Restart=on-failure`,
  `RestartSec=2s`, and `StartLimitBurst=5` / `StartLimitIntervalSec=60`.
  `firewall.sh` waits up to 10s (`DOCKER_USER_WAIT_SECONDS`) for
  `DOCKER-USER` on both iptables and ip6tables before applying
  `MASTER-DOCKER`. No extra timer or recovery script.
- **v2-24 (2026-08-07): also `PartOf`/`WantedBy` `tailscaled`.** A
  Tailscale restart recreates `ts-input` but did not re-run firewall apply,
  so `MASTER-INPUT` ordering was not re-guaranteed. `master-firewall` now
  follows both `docker.service` and `tailscaled.service` stop/restart
  (Compose is never coupled). Expected after **DD-75**: `tailscaled`
  restart → firewall apply only; Caddy/WebDAV stay unless their address
  binding needs refresh.
- **v2-25 (2026-08-07): minimal `--check` content.** Beyond jumps and
  `ts-input` order, `--check` asserts IPv4 `MASTER-INPUT`/`MASTER-DOCKER`
  WAN DROP, WAN wg UDP ACCEPT, and WAN qBit TCP+UDP ACCEPT. Not a return
  to the old multi-flag reconcile surface.
- **v2-32 (2026-08-09): host INPUT no longer `Requires=docker`.** See
  **DD-75**.
- **v2-34 (2026-08-09): stronger invariants.** Exactly one jump, no
  staging leftovers, WAN if drift fail-closed, SSH + IPv6 TS UDP + NS/NA
  in `--check` (still not a reconcile surface).

### DD-60: dnsmasq binds loopback and `tailscale0`, and nothing else (2026-08-05)

- **Decision:** dnsmasq listens on `lo` and `tailscale0` with
  `bind-dynamic`. Not on WAN interfaces, not on ordinary LAN interfaces,
  never on an unbounded `0.0.0.0`, and it serves no DHCP. Records are
  interface-based (`interface-name=…,tailscale0`); the current Tailscale
  IPv4 is never written into the configuration.
- **Rationale for loopback:** the host must be able to resolve its own
  service names, and the installation must be able to verify DNS without
  borrowing a tailnet device to ask from. v1 bound `tailscale0` only, with
  `except-interface=lo`, which made the cheapest possible verification —
  `dig @127.0.0.1` — impossible.
- **Why the address stays out of the file:** `interface-name` resolves to
  whatever address the named interface currently holds, so destroying and
  recreating `tailscale0` requires no file to be regenerated. This is what
  lets **DD-61** leave dnsmasq alone entirely.
- **What a loopback query returns is an expectation, not a measurement.**
  Reading dnsmasq's documentation, `interface-name=NAME,tailscale0` should
  answer with the `tailscale0` address regardless of which interface the
  query arrived on — but this has not been observed on a real host, and the
  whole loopback-testability argument rests on it. It is therefore recorded
  as an acceptance test for the DNS phase, to be run on a clean Debian 13
  target: `dig +short NAME @127.0.0.1` must return the same address as
  `dig +short NAME @${TS_IPV4}`, and that address must be `${TS_IPV4}`. If
  the measurement disagrees — if a loopback query answers `127.0.0.1` or
  `NXDOMAIN` — the loopback listener stops being a test path and this
  decision needs revisiting, not a workaround.
- **Open implementation question, not a decision:** whether
  `systemd-resolved`'s stub listener already holds `127.0.0.1:53` on the
  target host. That is answered by looking at the host during the DNS
  phase.

### DD-61: `refresh-tailnet-config` restarts address-bound units and does nothing else (2026-08-05)

- **Superseded in part by DD-77 (2026-08-09):** host WebDAV no longer
  binds `${TS_IPV4}`; the live restart set is **Caddy only**.
- **Decision:** the helper reads the current Tailscale IPv4 and IPv6,
  compares them with `/etc/master-stack/state.env`, exits successfully
  without touching any service if they match, and otherwise updates
  `state.env` atomically and restarts the units that bind the address
  (originally Caddy and `master-webdav`; after DD-77, Caddy alone).
  Explicitly excluded: regenerating the dnsmasq configuration, restarting
  dnsmasq, restarting the Compose stack or any container, re-applying the
  firewall, cooldown stamps, drift flags, container recovery, and health
  repair of any kind.
- **Rationale:** this is the scope boundary that keeps v2 from regrowing
  `master-network-reconcile`, whose 1821 lines were one third of v1 and
  produced 25 drift flags, a stamp-based cooldown ledger and an image
  digest recovery path — none of which any requirement asked for. The rule
  that makes the small version sufficient is architectural rather than
  disciplinary: only address-bound consumers are restarted, because
  dnsmasq and the firewall are written against the *interface name*
  (**DD-60**) and (after DD-77) WebDAV binds loopback only.
- **Consequence for Caddy:** there is no rendered Caddy environment file.
  The drop-in reads `state.env` directly as its `EnvironmentFile=`, so the
  address exists in one place on disk and the helper has one file to
  update. The cost is that `state.env` must satisfy both `source` in bash
  and systemd's `EnvironmentFile=` parser: plain `KEY=value`, no quoting,
  no spaces around `=`, no expansion.
- **Consequence for a public IPv4 change:** it cannot be solved inside this
  helper without breaking the decision, because it would mean recreating
  containers. That remains an open question with a documented interim
  answer (re-run the installer).

### DD-62: Portainer is proxied to loopback HTTPS on 9443 (revised 2026-08-06)

> **Superseded by DD-116 (2026-09-13):** Portainer was replaced by Dozzle,
> which is proxied over plain loopback HTTP. Kept as history.

- **Decision (revised):** Caddy's upstream for `portainer.${LOCAL_DOMAIN}` is
  `https://127.0.0.1:9443`. Compose publishes `127.0.0.1:9443:9443` only
  (image default HTTPS listener). `--http-enabled` / port 9000 are not used.
  Because Portainer's certificate is self-signed, the site block uses
  `transport http { tls_insecure_skip_verify }` on that **loopback** hop
  only. Operator access remains `http://portainer.${LOCAL_DOMAIN}` on the
  Tailscale-bound Caddy front door (`auto_https off`).
- **Supersedes (2026-08-05):** The earlier choice of plain HTTP `127.0.0.1:9000`
  avoided skip-verify by forcing `--http-enabled`. The operator preferred
  Portainer's native HTTPS listener on 9443; the skip-verify trade-off is
  accepted for same-host loopback and documented here.
- **Rationale for skip-verify on loopback:** TLS to a self-signed process on
  the same host does not add a meaningful trust boundary beyond plain HTTP
  on loopback; skip-verify is the practical way to speak Portainer's
  default listener without mounting its cert into Caddy. It must never be
  copied onto a non-loopback upstream.
- **The publication set is exactly one line:** `127.0.0.1:9443:9443`. Neither
  9443 nor 9000 is published on the tailnet or the WAN.

### DD-62-archive: Portainer plain loopback HTTP (2026-08-05, superseded)

- **Former decision:** Caddy upstream `127.0.0.1:9000` with Compose
  `--http-enabled` and no `tls_insecure_skip_verify`. Kept only as history;
  see the revised DD-62 above.

### DD-64: Tailscale address refresh without a long-running watcher (revised 2026-08-07)

- **Decision (v2-26):** Drop `watch-tailnet-addr`. Address updates go through
  `refresh-tailnet-config` only: `WantedBy=tailscaled.service` (restart path)
  plus `refresh-tailnet-config.timer` (`OnBootSec=2min`,
  `OnUnitActiveSec=5min`). Installer disables/removes any leftover watch
  unit and sbin helper on re-run.
- **Context:** The netlink watcher and the five-minute timer both drove the
  same oneshot. Dual paths added always-on process cost for little gain
  once Tailscale restart already re-applies firewall and restarts
  Caddy/WebDAV (`PartOf=tailscaled`).
- **Rationale:** Prefer one refresh owner. Worst case for a silent CGNAT
  readdress without `tailscaled` restart is up to one timer interval before
  Caddy/WebDAV rebind — accepted for a simpler unit graph.
- **Supersedes:** The 2026-08-06 netlink watcher decision (sub-second IP
  change recovery via `ip monitor address`).

### DD-70: Portable export verifies SHA-256 and extracts atomically (2026-08-07)

- **Decision:** `export-installer.sh` records the runtime tarball SHA-256 only
  inside the `.command` (`PORTABLE_ARCHIVE_SHA256`). The launcher checks
  the hash after decode and again on the host before extract. Remote
  install unpacks into a temp directory, then moves the staged runtime into place
  (no `rm -rf` of the live tree until the new tree is ready to move).
  No separate `.sha256` sidecar is written.
- **Context:** A truncated scp/tar could leave the host without a usable
  installer tree mid-sync. An external sidecar duplicated the same digest
  without adding trust (it travels with the same file).
- **Rationale:** Hash catches corruption; staging extract avoids a window
  with no installer on disk. One deliverable keeps the Desktop/app
  surface a single double-clickable file.
- **Trade-off:** Slightly more remote disk during sync. External
  “checksum without opening the launcher” requires grepping
  `PORTABLE_ARCHIVE_SHA256` from the `.command` (or re-exporting).
- **Amendment (v2-64):** Deterministic pack uses `TZ=UTC` mtime
  `2000-01-01` and bsdtar `--no-xattrs --no-mac-metadata` (plus
  `xattr -cr` on the stage). Local `touch -t 197001010000` in TZ east of
  UTC lands before Unix epoch (stored as 0 → Debian “implausibly old”);
  Apple provenance xattrs became `LIBARCHIVE.*` pax keywords GNU tar
  does not understand. Reproducible hash stays; extract stays quiet.
- **Layout amendment (2026-09-02):** Repository and remote runtime files live
  directly under `debian-server-installer/`. The portable archive uses an
  `installer/` staging directory, atomically replaces the dedicated remote
  root, and starts `/root/debian-server-installer/install.sh`.

### DD-69: Downloads tree is recursively `1000:1000` for stack R/W (2026-08-07)

- **Decision:** Stage 3 always `chown -R ${DOWNLOADS_UID}:${DOWNLOADS_GID}`
  on `${DOWNLOADS_PATH}` (default `1000:1000`), with `0775` dirs and `0664`
  files. FileBrowser Compose service runs as the same uid:gid. qBittorrent
  (`PUID`/`PGID`) and Unpackerr (`user:`) already matched.
- **Context:** Creating only new dirs as `1000:1000` left existing trees
  unreadable/unwritable to the stack; the operator asked for a permanent
  shared R/W setup rather than a warning-only path.
- **Rationale:** One host identity shared by the three writers avoids ACL
  sprawl; WebDAV stays a separate read-only host user.
- **Trade-off:** Custom ownership/modes under downloads are still
  normalized toward the stack identity when they diverge. As of **DD-84**,
  matching entries are left untouched (no full-tree rewrite every re-run).

### DD-68: Stage 7 covers the cheap contract §14 checks (2026-08-07)

- **Decision:** End-of-install verification includes DNS against
  `127.0.0.1` and `${TAILSCALE_IPV4}`, an out-of-domain `REFUSED`, Caddy
  health, WebDAV unauthenticated `401` (direct + `webdav.` host),
  unauthenticated write rejected (`401`/`403`/`405`), public peer
  publishes for wg/qBit, and non-peer UI publishes only on `127.0.0.1`.
- **Context:** Stage 7 previously only checked loopback DNS, health, and
  WebDAV 401 — below contract §14’s success bar.
- **Rationale:** These checks are fast, deterministic, and catch the
  common “install said OK but ports/DNS wrong” failures without needing
  stored WebDAV passwords (authenticated PROPFIND/write remain manual /
  live Tier-3).
- **Trade-off:** Authenticated WebDAV list/write and full Caddy site
  non-5xx for every UI are still not asserted here.

### DD-67: Re-runs skip full-upgrade and unchanged edge/compose restarts (2026-08-07)

- **Decision:** `apt full-upgrade` runs on first install (no `state.env`),
  when `V2_FULL_UPGRADE=1`, or when the operator answers yes to a prompt
  (default **no** on re-run). `apt-get update` and package `install -y`
  still run. dnsmasq/Caddy are restarted only if their rendered files or
  drop-ins changed, or the unit is inactive; Compose `up -d` runs only if
  `compose.yaml`/`.env` changed or fewer than five containers are running.
  Edge `mask`+apt runs only when `dnsmasq`/`caddy` packages are missing.
- **Context:** Every re-run previously paid for a full upgrade and bounced
  the edge and Compose stack even when nothing changed.
- **Rationale:** Matches contract §11 (“no unconditionally expensive
  step”) while keeping first-install freshness and an explicit upgrade
  path.
- **Trade-off:** Operators who want updates on every re-run must answer
  yes or set `V2_FULL_UPGRADE=1`.

### DD-66: Runtime firewall values come from state, not script fallbacks (2026-08-07)

- **Decision:** `master-firewall` requires `CHAIN_*`, `CHAIN_STAGING_PREFIX`,
  and public ports from `state.env` (`${VAR:?}`). Staging chain names are
  `${CHAIN_STAGING_PREFIX}` + `IN-` / `DK-` / `IN6-` / `DK6-`. DNS
  verification loops `SERVICE_NAMES`; wg bridge IPs/subnets live in
  `defaults.env` and are rendered into Compose.
- **Context:** Fallbacks in `firewall.sh` could silently keep an old port
  after the operator changed `defaults.env` / config. `SERVICE_NAMES` and
  bridge literals were declared but not wired.
- **Rationale:** Missing state must fail closed at apply time; a re-run of
  the installer rewrites a complete `state.env`.
- **Trade-off:** Hosts with a pre-v2-17 `state.env` need one installer
  re-run (or a manual state edit) before `master-firewall apply` succeeds.

### DD-65: Edge apt install keeps units masked; quiet the preset noise (revised 2026-08-07)

- **Decision:** Stage 6 **masks** `dnsmasq.service` and `caddy.service`
  before `apt-get install`, writes config/drop-ins, then `unmask` +
  `enable` + `restart`. Apt stdout/stderr is filtered only for the known
  `Failed to preset … is masked` / `deb-systemd-helper` / “static unit,
  not starting” lines (full apt text still appends to the install log).
  `policy-rc.d` is **not** used for this window.
- **Context:** An earlier revision replaced mask with `policy-rc.d` to
  silence apt. That removed the contract’s abort guarantee (§12): a failed
  stage 6 must leave the optional edge units **off** (masked), not merely
  “did not start during postinst”.
- **Rationale:** Mask is the fail-closed primitive the contract already
  documents. Log filtering restores operator clarity without weakening
  abort safety.
- **Trade-off:** Filter patterns are string-matched; a future apt wording
  change could let noise through again — not a safety regression.
- **Follow-up (2026-08-07, `v2-22`):** `retry` passes the command to
  `timeout`, which can only exec PATH binaries. Calling
  `apt_get_install_masked_quiet` through `retry` therefore failed with
  127 on the live host. `retry` now detects shell functions
  (`declare -F`) and wraps them as `export -f` +
  `timeout … bash -c '"$0" "$@"' fn args…`.

### DD-63: qBittorrent peer port is TCP+UDP (2026-08-06)

- **Decision:** Compose publishes `${QBIT_PUBLIC_PORT}` for **both** TCP and
  UDP (1:1 host map, no WAN IP embed). `master-firewall` allows the matching
  NEW WAN rules in `MASTER-INPUT` and `MASTER-DOCKER`. wg-easy remains
  UDP-only.
- **Context:** v2 initially followed an early R12 “qBit UDP only” reading.
  Live review on the test host showed qBittorrent listening on TCP inside
  the container while only UDP was published, which matched weaker peer
  connectivity than legacy (`TCP+UDP` on `${PUBLIC_IPV4}`).
- **Rationale:** BitTorrent peer traffic is still predominantly TCP; UDP
  alone (µTP) is insufficient for expected swarm performance. Restoring TCP
  aligns v2 with legacy behaviour while keeping the v2 “no WAN IP in
  Compose” publish style.
- **Trade-off:** One additional public TCP port on the WAN versus the
  earlier narrower surface. Accepted explicitly by the operator (R12
  revised).
- **v2-27 (2026-08-07): IPv4-only peer publish.** Unqualified Compose
  `host:port` maps also bind `[::]`, while IPv6 `MASTER-DOCKER` drops all
  NEW WAN peer traffic — so `[::]:65171/65173` was dead surface. Peer
  maps are now explicit `0.0.0.0:port:port/...`. Host/Tailscale IPv6,
  NDP INPUT rules, and the wg-easy IPv6 bridge are unchanged.

### DD-71: IPv6 `MASTER-DOCKER` drops WAN only, like IPv4 (2026-08-07)

- **Decision:** `apply_docker6` ends with `-i $WAN_INTERFACE -j DROP`
  followed by `-j RETURN`, the same shape as `apply_docker4`, instead of an
  unconditional `-j DROP`. `--check` gains two IPv6 assertions
  (`MASTER-INPUT` and `MASTER-DOCKER` each carry the WAN-scoped `DROP`), and
  a bats test rejects a bare `-A "$staging" -j DROP` in that function.
- **Context:** The unconditional `DROP` sat in `DOCKER-USER`, which every
  IPv6 `FORWARD` packet traverses — so it dropped **egress** from the
  wg-easy bridge as well as WAN ingress. Compose enables IPv6 on that
  network, wg-easy issues peers an address out of
  `fdcc:ad94:bacf:61a4::/112`, and Docker installs a matching
  `POSTROUTING … MASQUERADE`; the project's own rule then cancelled all of
  it. Measured on the test host: `ping -6` from inside the container lost
  100% of packets while the host itself reached the same address in 3.8 ms,
  and the rule's counter incremented by exactly the test packets.
- **Rationale:** **DD-63**'s v2-27 note justified the rule from its inbound
  effect ("drops all NEW WAN peer traffic — so `[::]:65171/65173` was dead
  surface") and explicitly left the wg-easy IPv6 bridge alone. The outbound
  consequence was not part of that reasoning. A dual-stack peer therefore
  tried IPv6 first for every AAAA-resolved host and fell back to IPv4 after
  a timeout — a per-connection latency cost, not merely "no IPv6".
- **Trade-off:** Container IPv6 egress is now permitted, matching what IPv4
  has always allowed. No public IPv6 publish exists, so no `ACCEPT` precedes
  the WAN `DROP`; NEW WAN → container IPv6 stays closed. Verified live:
  egress 0% loss, `ip6tables -C MASTER-DOCKER -i eth0 -j DROP` still
  present, IPv4 chain unchanged.
- **Alternative rejected:** setting `enable_ipv6: false` on the wg network
  would also remove the fallback delay, but by removing peer IPv6 entirely
  rather than by fixing an asymmetry the contract (§9, "the same shape")
  already required.

### DD-72: Address-bound units wait, fail visibly, and get recovered (2026-08-07)

- **Decision:** Three changes to the Tailscale-address recovery path.
  1. `refresh-tailnet-config` calls `systemctl restart` instead of
     `systemctl try-restart … || systemctl restart …`.
  2. It also calls `recover_failed_bound_units` on the **no-change** path,
     restarting `caddy` / `master-webdav` if they are in `failed`.
  3. The `caddy` drop-in gains `ExecStartPre=$SBIN_DIR/wait-tailnet-addr`,
     `TimeoutStartSec=150s`, `StartLimitIntervalSec=600` and
     `StartLimitBurst=3`.
- **Context:** `try-restart` restarts a unit **only if it is already
  running**. On a failed unit it does nothing *and returns 0*, so the `||`
  fallback was unreachable. Measured on the test host:
  `systemctl try-restart master-webdav.service; echo $?` → `0`, unit still
  `failed`. Separately, `caddy` had no wait for the address: it read
  `{$TAILSCALE_IPV4}` from `state.env`, failed to bind, and retried every
  5 s forever. With no `StartLimit*` it never reached `failed`, so
  `systemctl --failed` stayed empty while the whole tailnet surface was
  down (`NRestarts` observed climbing past 29).
- **Rationale:** The two failure shapes were mirror images. WebDAV waited
  correctly but then exhausted its start limit and stayed `failed` with
  nothing able to resurrect it; Caddy never failed and so was never
  visible. The combination — bounded wait, then visible failure, then
  recovery by the timer that already runs every five minutes — fixes both
  without adding a watcher, a timer, or a service.
- **Why the two waits stay separate:** `wait-tailnet-addr` only answers
  "does an address exist", which is all Caddy needs because it reads the
  value from `state.env`. `webdav.sh` keeps its own in-process wait because
  it needs the address *value* to pass to `rclone --addr`. These are
  different questions, not duplicated code.
- **Trade-off:** Caddy now takes up to 120 s to fail instead of crash-looping
  instantly, and `refresh-tailnet-config` does two `systemctl is-failed`
  checks per five-minute tick. Both are negligible next to a silent outage.
- **Verified live:** a `master-webdav` that had been `failed` for over forty
  minutes was recovered by one `refresh-tailnet-config` run with **no**
  address change. A subsequent `systemctl restart tailscaled` left
  `caddy` at `NRestarts=0` (previously 29 and climbing), containers
  untouched, `systemctl --failed` empty.

### DD-73: `MASTER-INPUT` accepts the Tailscale UDP port itself (2026-08-07)

- **Decision:** `TAILSCALE_UDP_PORT="41641"` is declared once in
  `defaults.env`, written to `state.env`, required by `firewall.sh`
  (`: "${TAILSCALE_UDP_PORT:?}"`), and accepted on the WAN interface in both
  `apply_input4` and `apply_input6`. Stage 0 rejects it as an operator port
  choice. `--check` asserts the IPv4 rule. `refresh-tailnet-config` also
  gains a one-line warning when the tailnet is unusable.
- **Context:** `MASTER-INPUT` carried no rule for Tailscale's own port and
  worked only because `ts-input` sits ahead of it in `INPUT` and accepts
  41641 there. Measured during the `tailscaled` restart test: with no
  netmap, Tailscale removed `ts-input` entirely, and `MASTER-INPUT`'s
  `-i eth0 -j DROP` counted 52 packets while `tailscaled` was still bound to
  `0.0.0.0:41641`. Separately, the node was deleted from the tailnet at
  15:08 and logged `404: node not found` 501 times over four hours while
  `systemctl --failed` stayed empty and every unit reported green.
- **Rationale:** Tailscale reinserts `ts-input` at `INPUT` position 1, so
  the ordering does self-correct and the impact is bounded — a fallback to
  DERP relay rather than an outage. But the correctness of this project's
  chain should not depend on a chain owned by another daemon being present
  and correctly positioned. One additive rule removes the coupling;
  `ensure_ts_input_precedence` stays, demoted from load-bearing to
  belt-and-braces.
- **Trade-off:** One more explicit WAN `ACCEPT`. It duplicates what
  `ts-input` already permits, which is the point: the two are independent
  now. If Tailscale is ever started on a non-default port the constant must
  follow, which is why it lives in `defaults.env` and not in the script.
- **On the warning:** it is a `printf` to stderr, nothing more. It does not
  attempt `tailscale up`, does not retry, and does not gate anything — a
  bats test asserts the helper never calls `tailscale up/set/login`. The
  four-hour silent outage needed visibility, not a repair engine.
- **Verified live:** both chains carry the rule, `--check` passes, and a
  missing `TAILSCALE_UDP_PORT` in `state.env` fails the script closed.

### DD-74: Tailscale stateful filtering stays on, deliberately (2026-08-07)

- **Decision:** `tailscale set … --stateful-filtering=true` is kept.
  Tailscale's own health warning about it in the presence of Docker is
  **expected output on this host**, not a defect to chase.
- **Context:** Tailscale made stateful filtering default-**off** in 1.78
  because it breaks containers that need to reach tailnet nodes, and the
  daemon reports:
  *"Stateful filtering is enabled and Docker was detected; this may prevent
  Docker containers on this host from resolving DNS and connecting to
  Tailscale nodes."*
  The rule it installs is visible in `ts-forward`:
  `-o tailscale0 -m conntrack ! --ctstate RELATED,ESTABLISHED -j DROP`.
- **Rationale:** The warning describes a capability this stack does not use.
  No container needs the tailnet: Docker's resolver is pinned to
  `1.1.1.1`/`1.0.0.1` in `daemon.json`, and none of the five services talks
  to a tailnet peer. Turning the filter off to silence a warning would
  loosen what may leave the host toward the tailnet in exchange for nothing.
- **The one real consequence, accepted:** wg-easy peers cannot reach tailnet
  devices — traffic from the wg bridge toward `tailscale0` is dropped by
  that rule (and by `ts-forward`'s `-s 100.64.0.0/10 -o tailscale0 -j DROP`).
  Reaching tailnet devices over the WireGuard VPN is not a requirement;
  tailnet devices are reached with the Tailscale client. Operator decision,
  2026-08-07.
- **Revisit if:** wg peers ever need to reach tailnet nodes, or a container
  is added that must. Then this is the setting to change first, and the
  contract's §14.2 success criterion must change with it.

### DD-75: Host firewall converges without Docker; address units drop PartOf (2026-08-09)

- **Decision (four changes, one revision):**
  1. `master-firewall.service` uses `Wants=docker.service`, not
     `Requires=`. Host INPUT apply/check always run; `MASTER-DOCKER` is
     applied/checked only when `DOCKER-USER` is present (or Docker is
     active and the wait for the chain succeeds). Docker inactive → skip
     Docker stage without failing the unit; Docker active but chain missing
     after the wait → fail closed.
  2. Stage 5 restarts `master-firewall` / `master-webdav` when
     `state.env`, helper scripts, unit files, or `webdav.env` actually
     changed (`FIREWALL_NEEDS_RESTART` / `WEBDAV_NEEDS_RESTART`), matching
     the Caddy/dnsmasq pattern. Bare `enable --now` on an already-active
     unit is not convergence.
  3. Caddy drop-in and `master-webdav.service` no longer declare
     `PartOf=tailscaled.service`. Firewall keeps `PartOf` for both
     `docker` and `tailscaled` so netfilter order is rebuilt on those
     restarts. Address binding recovery stays on `refresh-tailnet-config`
     (`WantedBy=tailscaled` + 5-minute timer) and `wait-tailnet-addr`.
  4. `tailscale_login` reaps a stuck `tailscale up` child with TERM, a
     bounded wait, then KILL before the next attempt — never an unbounded
     `wait` on a still-running auth process.
- **Why:** Live nrm tests (2026-08-09) showed (a) `systemctl start` on
  active firewall/WebDAV is a no-op so port/state edits never apply on
  re-run, (b) Tailscale restart bounced Caddy/WebDAV while containers and
  IPs stayed put, and (c) Docker boot failure would have blocked host
  INPUT via `Requires=docker` plus a hard `die` when `DOCKER-USER` was
  absent. Rejected on the same evidence: `accept_ra=2`,
  `stateful-filtering=false` (DD-74), treating start-limit as a permanent
  lock, and restoring `watch-tailnet-addr`.
- **Apply order:** host INPUT (IPv4 then IPv6, with `ts-input`
  precedence) first; Docker chains afterward so a missing Docker path
  cannot leave the host without WAN DROP.
- **v2-33 follow-up:** `sed | atomic_write` runs the function in a Bash
  pipe subshell, so `V2_LAST_ATOMIC_CHANGED` is discarded. WebDAV unit
  writes use process substitution (`atomic_write … < <(sed …)`) instead.
  Found on the first live v2-32 re-run: unit on disk updated, PID unchanged.
- **v2-34 follow-up:** `--check` (and apply) fail closed on WAN if drift;
  require exactly one final-chain jump; reject staging-prefix leftovers;
  assert SSH ACCEPT (v4/v6), IPv6 Tailscale UDP, and NS/NA. No automatic
  state rewrite on drift — operator re-runs the installer.

### DD-84: Selective downloads ownership repair + P3 hygiene (2026-08-09)

- **Decision (chown):** Stage 3 `ensure_downloads_tree` only `chown -h` /
  `chmod`s entries whose UID/GID or mode already diverge from
  `${DOWNLOADS_UID}:${DOWNLOADS_GID}` / `0775` dirs / `0664` files. No
  unconditional `chown -R`. Symlink targets are not rewritten (`-h`).
- **Decision (P3):** Drop timer `Requires=` (Unit= is enough); strip stale
  host-WebDAV wording from wait/refresh helpers; Caddyfile matches
  `caddy fmt`; firewall helper drops unused `WAN_IPV4` and `--check`s
  IPv6 `packet-too-big`; export builds a deterministic tarball (`touch`
  epoch + `gzip -n`, stable `PORTABLE_BUILT_AT`). `render_template`
  preserves trailing newlines (so `caddy fmt` stays clean).
- **Why:** Large media trees made every re-run pay a full rewrite; P3 items
  were low-risk noise that dirtied exports and docs without changing
  intent. WG Stage 7 listen/CGNAT checks stay out — operator tracks
  manually.
- **Not doing:** automatic image pull; Watchtower; WG endpoint Stage 7.

### DD-83: Compose images are tag@digest pins, not floating tags (2026-08-09)

> **Partially superseded by DD-97 (v2-63).** Images with an upstream stable
> track now use that track without a digest. Digest pins remain for images
> that only offer `:latest` (qBittorrent). The ban on `latest` / Watchtower
> still stands; Portainer `lts` is an allowed named track under DD-97.

- **Decision:** Every Compose image in `defaults.env` is a concrete
  `name:tag@sha256:…` pin taken from the live `nrm` stack (2026-08-09).
  `latest` / `stable` / `lts` are forbidden. Installer still skips
  `compose up` when the rendered file is unchanged and still does not
  auto-pull on a timer.
- **Why:** Floating tags made “unchanged re-run” quietly freeze an old
  digest while a later recreate could jump unpredictably. Digest pins make
  re-runs and new installs reproduce the accepted set; updates are an
  explicit pin bump + acceptance, not an automatic updater.
- **Not doing:** Watchtower / reconcile-driven pulls.

### DD-82: WebDAV healthcheck and isolated `webdav` network (2026-08-09)

- **Decision:** Compose `webdav` gets a Docker healthcheck that treats an
  unauthenticated local `401` as healthy, and attaches only to a named
  bridge `webdav` (not `internal`). It does **not** join `wg` or the
  project default network. Caddy keeps proxying via host loopback publish.
  No memory or pids limits on this service.
- **Why:** Health makes Compose/`docker compose ps` report real readiness
  without embedding credentials. A dedicated network removes lateral
  reachability from Portainer/qBit/FileBrowser on `docker_default` without
  opening WireGuard-peer bypass of Caddy/Tailscale (which attaching to
  `wg` would allow for peers with `AllowedIPs 0.0.0.0/0`).
- **Not `internal: true`:** On Docker 29 / compose here, a container that
  only joins an `internal` network drops host port bindings
  (`NetworkSettings.Ports` empty → loopback `000`). Live nrm failed Stage 7
  that way; non-internal named bridge restores `127.0.0.1:WEBDAV_PORT`
  while keeping service isolation from `docker_default`.
- **Not doing:** publishing WebDAV on `wg`; memory ceilings (deferred /
  declined for this pass).

### DD-81: Stage 7 proves WebDAV read-only via inspect, not PUT 401 (2026-08-09)

- **Decision:** `assert_webdav_readonly_runtime` checks the running
  `webdav` container: `Config.Cmd` contains `--read-only`,
  `HostConfig.ReadonlyRootfs` is true, and the `/downloads` mount has
  `RW=false`. Unauthenticated HTTP PUT is not used as a read-only proof.
- **Why:** A credential-less PUT returns `401` even if the serve were
  writable; that only proved auth. Secrets-free install-time proof belongs
  on Compose/runtime configuration, not on a confused HTTP status set.
- **Still separate:** loopback / Caddy / bare-IP unauthenticated `401`
  checks remain for the auth surface.

### DD-80: `refresh-tailnet-config` waits with `tailscale wait` (2026-08-09)

- **Decision:** Before reading `tailscale0` addresses, the helper runs
  `tailscale wait --timeout=${REFRESH_TAILNET_WAIT_TIMEOUT:-120s}` when the
  CLI supports it. On timeout it soft-exits 0 (timer retries). The unit sets
  `TimeoutStartSec=150s` so systemd does not kill the wait. The 5-minute
  timer and `WantedBy=tailscaled` both stay.
- **Why:** `WantedBy=tailscaled` fires when the daemon process starts, not
  when the interface has an IP. Live logs showed `BackendState=NoState` and
  immediate “IPv4 yok; atlanıyor”, deferring recovery to the timer.
  `tailscale wait` (supported on host 1.102.2) is the upstream tool for
  “backend running + interface + IP”.
- **Not doing:** removing the timer; infinite wait (`--timeout=0`); coupling
  Compose/WebDAV to this path.

### DD-79: Host WebDAV leftovers are purged on every Stage 4 (2026-08-09)

> **Superseded by DD-96 (v2-62).** The purge was removed: v2 no longer
> migrates hosts provisioned by older revisions. Kept as the record of why
> it existed.

- **Decision:** After Compose WebDAV (**DD-77**), Stage 4 calls
  `purge_host_webdav_leftovers` to remove the host unit/script/`webdav.env`,
  the dedicated `master-webdav` user/group, `u:master-webdav` ACL entries
  under `DOWNLOADS_PATH`, and the Debian `rclone` package (`apt-get purge`).
- **Why:** v2-37 stopped *installing* those artifacts but left them on
  upgraded hosts; contract and GPT re-audit required a real cleanup. Scoped
  to the known v1/v2 identity (`master-webdav` + package name `rclone`) —
  no broad user wipe.
- **Safety:** Idempotent; Compose image rclone is untouched; `setfacl`
  installed only if the user still exists and the tool is missing.

### DD-98: Infuse uses Caddy on Tailscale IP:WEBDAV_PORT (2026-08-10)

- **Decision:** Caddyfile WebDAV site is
  `http://webdav.${LOCAL_DOMAIN}, http://{$TAILSCALE_IPV4}:{$WEBDAV_PORT}`
  → `127.0.0.1:{$WEBDAV_PORT}` (both placeholders from `state.env` via
  Caddy `EnvironmentFile=`). Compose stays loopback-only and never names
  the Tailscale address. Refresh-tailnet still restarts only Caddy; a
  re-run that changes `WEBDAV_PORT` sets `WEBDAV_PORT_CHANGED` so Caddy
  restarts even when the Caddyfile text is unchanged.
- **Why:** Infuse on Apple TV wants an explicit port (`61003`) without
  MagicDNS. Binding that port in Caddy (from `state.env`) keeps Compose
  free of Tailscale IPs while matching Infuse UX. Bare `:80` on the TS IP
  is no longer WebDAV (avoids Host=IP confusion with other sites).
- **Rejected (same day):** Compose publish on `${TS_IPV4}:${WEBDAV_PORT}`
  (brief v2-65) — embeds a moving address into Compose and forces
  `docker compose up -d webdav` on every Tailscale IP change.
- **Supersedes:** DD-78’s bare `http://{$TAILSCALE_IPV4}` (port 80) alias.

### DD-78: Caddy WebDAV site aliases the Tailscale IPv4 (2026-08-09) — superseded by DD-98

- **Former decision:** The Caddyfile WebDAV site is
  `http://webdav.${LOCAL_DOMAIN}, http://{$TAILSCALE_IPV4}` → loopback
  rclone (port 80). Compose stays `127.0.0.1` only.
- **Why (then):** Apple TV / tvOS Infuse often cannot use MagicDNS.
- **Superseded (v2-66 / DD-98):** same Caddy ownership, but the Infuse
  address is `${TS_IPV4}:${WEBDAV_PORT}` rather than bare `:80`.

### DD-77: WebDAV runs in Compose on loopback, not as a host unit (2026-08-09)

- **Decision:** Replace host `master-webdav` (systemd + distro rclone +
  dedicated user) with a Compose service using `rclone/rclone`, published
  only on `127.0.0.1:WEBDAV_PORT`, reverse-proxied by Caddy. htpasswd
  stays at `/etc/master-stack/webdav.htpasswd` (0600). Refresh-tailnet
  restarts only Caddy.
- **Why:** Tailscale IP changes no longer require a WebDAV rebind; WebDAV
  updates with the rest of the stack; host ACL/user/rclone package surface
  shrinks. Double read-only (`:ro` mount + `--read-only`) is preserved.
- **Trade-off accepted:** Docker down ⇒ WebDAV down. Media producers are
  already Docker-backed, so the dependency matches the data path.
- **Follow-up:** Infuse without MagicDNS uses Caddy on
  `${TS_IPV4}:${WEBDAV_PORT}` (**DD-98**), not a Compose publish on the
  Tailscale address.

### DD-76: Compose does not own the WireGuard endpoint hint (2026-08-09)

- **Decision:** `WG_ENDPOINT_HOST` lives only in `state.env` (and the
  install summary). `$COMPOSE_DIR/.env` is not written; Stage 4 removes
  a leftover file. qBittorrent/unpackerr identity tokens are
  `__DOWNLOADS_UID__` / `__DOWNLOADS_GID__`. `DOWNLOADS_PATH` must match
  a narrow absolute charset with no `..` or `//`.
- **Why:** Compose never consumed `.env`; rewriting it on WAN IP change
  set `COMPOSE_NEEDS_UP` for no container benefit. Literal `1000` in the
  template duplicated `defaults.env`. Path charset closes obvious
  injection/traversal shapes without a full path sandbox.
- **Follow-up:** media-tree chown/chmod narrowing done in **DD-84**.
  Stage 7 WG listen / CGNAT warnings remain deferred (operator-tracked).

### DD-85: `wait-tailnet-addr` requires the state IPv4 on the interface (2026-08-09)

- **Decision:** When `TAILSCALE_IPV4` is set in the ExecStartPre
  environment (systemd `EnvironmentFile=state.env`),
  `wait-tailnet-addr` succeeds only if that exact address is present on
  `tailscale0`. If the interface already has a different global IPv4, the
  helper exits `1` immediately with a stale-state message instead of
  waiting out the deadline. If the variable is unset, “any global IPv4”
  remains sufficient.
- **Why:** Caddy binds `{$TAILSCALE_IPV4}` from state, not “whatever is on
  the iface”. The previous any-IP check turned green while Caddy stayed
  `activating` on a poisoned/stale address (measured on `nrm`, 2026-08-09
  resilience pass). Fail-fast hands recovery to the existing
  `refresh-tailnet-config` path (`recover_failed` / IP rewrite + restart)
  without a new watcher.
- **Amends:** DD-72’s “wait only answers does an address exist” for the
  Caddy pre-start helper; refresh still owns rewriting state.

### DD-86: Unusable-tailnet warning names BackendState and Online (2026-08-09)

- **Decision:** `warn_if_tailnet_unusable` logs
  `BackendState=… Online=…` when the node is not both `Running` and
  `Self.Online=true`. Still warning-only; no Tailscale repair.
- **Why:** Live `nrm` resilience pass printed
  `UYARI … (BackendState=Running)` while `Online` was false during a
  `tailscaled` restart — correct trigger, contradictory message. Naming
  both fields makes the line greppable without false “daemon is fine”
  readings.
- **Not doing:** hard-failing refresh; waiting for Online here (`tailscale
  wait` already covers readiness).

### DD-87: Caddy `OnFailure` starts `refresh-tailnet-config` (2026-08-09)

- **Decision:** The Caddy master-stack drop-in sets
  `OnFailure=refresh-tailnet-config.service`. No new timer, watcher, or
  probe oneshot.
- **Why:** After **DD-85**, a stale `state.env` IP fails `ExecStartPre`
  immediately and leaves Caddy `failed` until the next refresh tick
  (up to five minutes, or `OnBootSec=2min`). Wiring failure to the
  existing oneshot updates `state.env` from the interface and restarts
  Caddy in seconds. Refresh still writes the new address *before*
  restarting Caddy when the iface IP differs — it does not resurrect
  Caddy on the stale value.
- **Does not cover:** Silent Tailscale readdress while Caddy stays
  `active` (DD-64 timer / `WantedBy=tailscaled` remain that path).
- **Bounds:** Caddy `StartLimitBurst=3` / `600s` still caps fail loops if
  the tailnet never becomes usable.

### DD-88: Stage 7 asserts Caddy UI sites are non-5xx (2026-08-09)

- **Decision:** After the health probe, Stage 7 requests
  `portainer` / `wg` / `qbit` / `file` via `Host:` on `${TAILSCALE_IPV4}`
  and requires an HTTP status in `1xx–4xx` (not empty/5xx). WebDAV stays
  on its separate `401` checks; `health` stays the `ok` body check.
- **Why:** Contract §14.13 already required this; Stage 7 previously
  stopped at DNS + health + WebDAV auth surface, so a dead upstream behind
  Caddy could still pass install. Cheap and secrets-free.
- **Not doing:** asserting exact `200` (wg returns `302`; first-run UIs
  vary) or authenticated probes.

### DD-92: Classic FileBrowser replaces Quantum (2026-08-09)

- **Decision:** Compose `filebrowser` uses `filebrowser/filebrowser`
  (digest-pinned `v2.63.23`), not FileBrowser Quantum. WebDAV stays
  separate rclone (**DD-77**). UI remains `file.*` → loopback `61007`.
- **Why:** Operator preference after side-by-side trials (classic UI).
  Known shell CVEs are mitigated with `--disableExec` (and no auth
  hooks). Tailnet-only + Caddy exposure is accepted; the residual risk is
  **maintenance-only / planned archive** (no future patches) — recorded
  consciously, not ignored.
- **Data:** Host dir `/etc/master-stack/filebrowser-data` (DOWNLOADS_UID)
  holds the Bolt DB (`/database`) and binds `config/` over the image
  `VOLUME /config` so Compose does not allocate an anonymous volume
  (v2-58). `/downloads` mounts at `/srv`. Quantum `filebrowser.yaml` and
  named volume `filebrowser_data` are removed on Stage 4.
- **Accounts:** Default `admin`/`admin` on first DB bootstrap — end-of-
  install warning; operator must change. *(Superseded by **DD-118**: the
  installer creates the only account from a stage-0 prompt.)*

### DD-93: Firewall Docker re-apply + install path hygiene (2026-08-09)

- **Decision (three fixes, one package):**
  1. Install `docker.service.d/master-stack.conf` with
     `ExecStartPost=-/bin/systemctl --no-block restart master-firewall.service`.
     DD-75 still allows INPUT without Docker, but a later `docker start`
     must not leave published peer ports unprotected when
     `RemainAfterExit` made `WantedBy` start a no-op. `--no-block` avoids
     a start-post deadlock (`After=docker` waiting while Docker waits for
     ExecStartPost).
  2. `master-firewall --check` requires DOCKER allow rules and asserts
     WAN DROP sits after WAN ACCEPT/RETURN in INPUT and DOCKER chains.
  3. Restore DD-8: merge `dns` into `/etc/docker/daemon.json` via `jq`
     instead of overwriting the file. Restrict `DOWNLOADS_PATH` to
     `/downloads`, `/data`, `/srv/downloads` (and subpaths) before
     recursive ownership repair. Scope `filebrowser` container removal to
     this Compose project / known images.
- **Why:** GPT live review of v2-58 on `nrm` (2026-08-09): healthy runtime,
  but fail-open gap after INPUT-only firewall apply, weak `--check`,
  daemon.json clobber, and over-broad downloads/FB cleanup on shared hosts.
- **Not doing:** disk-persisted iptables, reconcile engine, automatic WAN
  endpoint rewrite, or broadening healthchecks beyond the contract.

### DD-94: The firewall converges; it does not fail with no policy (2026-08-09)

- **Decision (one package, v2-60):**
  1. **Live WAN interface.** `resolve_wan_interface` reads the current
     default route on every apply and check. `state.env` `WAN_INTERFACE` is
     a hint: a mismatch is a warning, not a fatal error, and the live name
     is used. It is deliberately not written back — the value is consumed by
     this script alone at runtime.
  2. **Shape check, not presence check.** `check_chain_shape` replaces
     `check_wan_drop_after_allows`: exactly one WAN DROP per chain, after
     every WAN allow, and no unconditional `ACCEPT`/`RETURN` (no `-i`/`-p`/
     `-m`/`--dport` match) before it. The terminal `-j RETURN` is legal
     because it sits after the DROP.
  3. **Orphan staging purge.** An apply removes leftover staging chains that
     nothing jumps to. A referenced one may be the live policy mid-swap and
     is left alone.
  4. **No Docker ordering on the unit.** `After=`, `Wants=` and
     `WantedBy=docker.service` are removed so host `INPUT` lands as early as
     possible and cannot be delayed by a slow Docker start. `MASTER-DOCKER`
     comes from the DD-93 drop-in; `PartOf=docker.service` is kept as a
     belt-and-braces second trigger. The installer deletes the retired
     `docker.service.wants/master-firewall.service` symlink.
  5. **One bounded watchdog.** `refresh-tailnet-config`, which the timer
     already runs every 5 minutes, restarts `master-firewall` when the unit
     is `failed` or `--check` fails, after `reset-failed` so an exhausted
     start limit cannot block recovery. It runs before the Tailscale wait so
     a dead tailnet does not skip it, and it skips the round while the
     oneshot is `activating`.
  6. **Restart pacing** `RestartSec=10s` / `StartLimitIntervalSec=300` /
     `StartLimitBurst=12`: a transient netfilter or Docker-chain race gets
     ~2 minutes of retries instead of burning 5 attempts in 10 seconds.
  7. **Label-only FileBrowser cleanup.** Container and legacy volume removal
     requires `com.docker.compose.project` to match this project. The
     v2-59 image-name fallback could still delete a foreign `filebrowser`.
- **Why:** the v2-58 review's P1 was that the firewall could fail *with the
  host unprotected*: a renamed NIC or a stale state value aborted the apply
  while `INPUT`'s default policy stayed `ACCEPT`. Converging on the live
  interface, checking chain shape instead of rule existence, and giving the
  unit one bounded recovery path removes that class of outcome without
  persisting rules to disk.
- **Not doing:** disk-persisted iptables (DD-66 stands: the unit is the
  single source of policy), a general reconcile engine (contract §2), a
  `PartOf=docker.service` removal (the drop-in plus PartOf is cheap; a
  duplicate apply is idempotent), automatic `WG_ENDPOINT_HOST` rewrite on
  public-IP change, or watchdog coverage of anything but the firewall unit.

### DD-97: Prefer upstream stable tracks over patch@digest pins (2026-08-09)

- **Decision:** Where the vendor publishes a stable track tag, Compose uses
  that tag with **no** `@sha256`. Where it does not, the digest pin stays.

  | Image | Tag | Why this track |
  |---|---|---|
  | Portainer CE | `lts` | Official install docs; Long-Term Support line (`sts` rejected) |
  | FileBrowser | `v2` | Major track; equals current `v2.63.23` tip |
  | qBittorrent (linuxserver) | `latest` | Documented as “Stable qbittorrent + libtorrent v2”; `libtorrentv1` is the other stable line and is rejected |
  | wg-easy | `15` | Official getting-started tag; major line |
  | Unpackerr | `0.15` | Minor track; equals `0.15.2` |
  | rclone | `1.75` | Current stable minor (tips at `1.75.0`; was frozen on `1.74.4`) |

- **Why:** Patch@digest pins made every upstream patch an installer bump.
  The operator wants the current *stable line*. For LinuxServer qBittorrent
  the stable+libtorrent-v2 line is literally named `latest` (there is no
  `libtorrentv2` tag); that is an allowed exception, not a licence to use
  `latest` elsewhere. `libtorrentv1`, `sts`, `edge`, `nightly`, beta stay
  forbidden.
- **Trade-off (accepted):** a pull/recreate can change the running digest
  without a git change. Re-runs that leave `compose.yaml` byte-identical
  still skip `compose up` (**R20**). First install or an explicit recreate
  moves the tip. qBittorrent tip as of this decision:
  `5.2.3_v2.0.13-ls470` (was pinned at `ls469`).
- **Supersedes DD-83** for track-tagged images. Watchtower still out.
- **Not doing:** `libtorrentv1`, Portainer `sts`, or `latest` on any image
  other than linuxserver/qbittorrent.
- **Follow-up:** the "first install or an explicit recreate moves the tip"
  gap is now also reachable on a re-run via an opt-in prompt (**DD-99**),
  without turning the installer into a reconcile engine.

### DD-99: Image pull is a re-run prompt, not a background reconciler (2026-08-23)

- **Decision:** `stage_0` asks, only when `state.env` already exists
  (i.e. a re-run, never on first install), "Konteyner imajları güncel
  sürüme çekilsin mi?" default **hayır**. Answering evet sets
  `PULL_IMAGES=1`; `stage_4` then runs `docker compose pull` right after
  rendering `compose.yaml` and forces `COMPOSE_NEEDS_UP=1` so `stage_7`
  recreates any container whose digest moved. `V2_PULL_IMAGES=1`
  answers the same question non-interactively (same shape as
  `V2_FULL_UPGRADE`).
- **Why:** DD-97 deliberately pins track tags (`lts`, `v2`, `latest`, …)
  and accepts that a byte-identical re-run skips `compose up` (**R20**),
  so a floating tag can drift stale for months with no supported way to
  catch up short of a fresh install. An explicit, operator-driven pull
  closes that gap without adding drift-detection or a timer — the
  operator decides *when*, the installer still does nothing on its own.
- **Why default hayır, not evet:** an unattended `Enter` on a routine
  re-run (e.g. fixing a port) must not silently swap running image
  digests — that is a bigger blast radius than what the operator asked
  for. Matches `upgrade_ans`'s existing default (**R20** intro block).
- **Why skipped on first install:** `docker compose up -d` already pulls
  every missing image; a redundant `pull` right before it is a no-op that
  only adds network time.
- **Cleanup (v2-69):** once `stage_7`'s `docker compose up -d` has
  recreated containers on the new digest, the same `PULL_IMAGES=1` gate
  also runs `docker image prune -f`, so the old (now dangling, untagged)
  layers a pulled floating tag leaves behind don't sit on disk
  indefinitely. A prune failure is logged (`log WARN`) and does not fail
  the run — reclaiming disk is a courtesy, not a correctness requirement.
- **Trade-off accepted (prune scope):** `docker image prune -f` is
  host-wide, not scoped to this stack's images — any dangling image on
  the box is reclaimed, not just ones this pull produced. Acceptable
  under the installer's single-host, root-only contract; an
  image-ID-scoped `docker rmi` of just the pre-pull digests would need
  capturing them before the pull, which the plain `pull` output doesn't
  hand back cheaply.
- **Not doing:** a scheduled/automatic pull (Watchtower-shaped — rejected
  by DD-97), and no attempt to pin/report the pre-pull digest for audit;
  `docker compose pull`'s own output is the record.

### DD-100: Skip a repo's apt-get update when its source file didn't change (2026-08-23)

- **Decision:** `stage_2` and `stage_4` each write an apt source file
  (`tailscale.list`, `docker.sources`) via `atomic_write`, then only run
  `apt-get update` when `V2_LAST_ATOMIC_CHANGED` is `1` from that write.
  Otherwise they log and skip it.
- **Why this is safe, not a staleness risk:** `stage_1` already runs
  `apt-get update` before either repo file is touched. On a re-run both
  files already exist on disk from the prior run, so they're already
  part of the sources `stage_1`'s update just refreshed — a second
  `apt-get update` moments later, with the file byte-identical, re-fetches
  the exact same index data. On first install the files are new
  (`V2_LAST_ATOMIC_CHANGED=1`), so the update still runs — apt has never
  seen that source before.
- **Why not drop the per-stage updates entirely:** a re-run where the
  operator's Tailscale/Docker apt config genuinely changed (key rotation,
  suite bump) still needs its own fresh index before `apt-get install`
  in that same stage; gating on the write result keeps that case correct
  while eliminating the common no-op case (**R20**: no step is
  unconditionally expensive).
- **Not doing:** consolidating all three `apt-get update` calls into one
  pass after every repo file is written — that would cross stage
  boundaries (Tailscale must be installed in stage_2, Docker in stage_4)
  for a saving only the re-run path has; smallest-change preferred.

### DD-101: The opted-in pull has a fail-closed disk floor (2026-08-28)

- **Decision:** when the operator accepts the image-pull prompt (DD-99),
  `stage_4` measures free space on the filesystem holding
  `/var/lib/docker` (`df -Pk`) before running `docker compose pull` and
  `die`s if it is below `PULL_MIN_FREE_GB` (declared once, in
  `defaults.env`; default 5 GiB). An unreadable measurement also dies —
  guessing about disk space before a multi-GB download is not an option.
- **Why:** a pull that fills the disk mid-download does not just fail the
  pull — a full `/var/lib/docker` can wedge the running containers and
  the Docker daemon itself, which is exactly the "failure leaves the host
  worse than before" outcome §12 of the contract forbids. Checking before
  the first byte keeps the failure mode at "nothing happened, message
  says why".
- **Why die, not warn-and-continue:** the operator opted into the pull at
  a prompt seconds earlier; a warning scrolling past in pull output is
  not a decision. Declining is cheap: free space or re-run without the
  pull. Matches the fail-closed posture everywhere else in the tree.
- **Why a fixed floor, not a computed image-size estimate:** the real
  space needed depends on layer overlap the registry only reveals during
  the pull; estimating it would be reconcile-engine-shaped complexity for
  a number that a single conservative constant covers on this fixed
  six-image stack.
- **Not doing:** any disk check on the non-pull path — the ordinary
  re-run downloads nothing and stays gate-free (R20: no step is
  unconditionally expensive).

### DD-102: Supported-OS matrix — Debian 13 plus the two Ubuntu LTS lines (2026-08-29)

- **Decision:** `require_debian_trixie` became `require_supported_os`,
  accepting exactly three ID/codename/major triples: `debian/trixie/13`,
  `ubuntu/noble/24`, `ubuntu/resolute/26`. The gate sets `OS_ID` and
  `OS_CODENAME`, and the Tailscale/Docker apt repo lines are rendered from
  those — verified live (2026-08-29) that both vendors publish
  `stable/ubuntu {noble,resolute}` and `linux/ubuntu` dists with the same
  URL shape as Debian. The Caddy cloudsmith line is already
  distro-agnostic (`any-version`) and Caddy's own Ubuntu instructions use
  the identical line.
- **Why pinned LTS releases, not `ID=ubuntu`:** same reason trixie was a
  hard gate — the installer's behaviour is only known on releases it was
  written against. Interim releases (25.04/25.10) have 9-month lives and
  add nothing; the two LTS lines cover real hosts through 2029+.
- **Ubuntu-specific guards that came with this:**
  - **ufw:** Ubuntu server ships it (inactive by default). If active, it
    manages INPUT alongside MASTER-INPUT — two owners for one chain.
    stage_0 dies before any mutation; the operator runs `ufw disable`
    first. Fail-closed, consistent with the rest of the tree.
  - **resolv.conf stub:** stage_6 already wrote `DNSStubListener=no` when
    systemd-resolved is active; on Ubuntu `/etc/resolv.conf` is a symlink
    to the stub (`127.0.0.53`), so disabling the stub alone breaks host
    DNS. When the symlink targets `stub-resolv.conf` it is repointed to
    `/run/systemd/resolve/resolv.conf` (resolved's uplink file). No-op on
    hosts without the stub symlink, including Debian. This is a safe
    bootstrap, not a permanent ownership claim: with Tailscale DNS enabled,
    Tailscale may later replace the symlink with its direct-mode MagicDNS
    `resolv.conf`. The resolute reboot test confirmed that steady state keeps
    host and split DNS healthy; forcing Tailscale onto the resolved stub would
    create a resolver loop on this dnsmasq layout and is deliberately not done.
    Confirmed end to end on a fresh v2-76 install (2026-09-10): the stub
    symlink was repointed at install time, Tailscale had replaced the file with
    its own after the reboot, host and split DNS stayed healthy throughout, and
    the post-reboot re-run correctly left the repoint alone because `readlink`
    no longer matches the stub.
  - **apt lock:** Ubuntu enables unattended-upgrades by default, so the
    dpkg lock can be held for minutes right when the installer starts.
    Every `apt-get` call now carries `-o DPkg::Lock::Timeout=60`
    (`APT_OPTS`), waiting on the lock instead of failing instantly;
    `retry` still wraps each call above that.
  - **debian-keyring:** installed only when `OS_ID=debian` — it came from
    Caddy's official Debian install set and has no function on Ubuntu
    (repo signing uses the downloaded cloudsmith keyring). **Dropped on every
    OS in v2-90 (DD-125).**
    - The two `apt_get_install_masked_quiet` installs (dnsmasq, Caddy) never
      received `APT_OPTS`, because `retry` runs functions in a child bash that
      does not inherit arrays. This was fixed in v2-90 (DD-125).
- **Verification status:** bats covers the gate matrix (accept ×3,
  reject ×5 including ID/codename and codename/version mismatches) and
  the repo-line derivation. **Live-verified on both Ubuntu lines:** noble
  24.04.4 on 2026-08-29 and resolute 26.04.1 on 2026-08-30. Both fresh
  installs passed stages 0–7 and independent checks for derived repos, host
  DNS, firewall, DNS/Caddy, WebDAV and 6/6 containers. Resolute additionally
  passed a byte/container/service-stable re-run, Tailscale and Docker restart
  recovery, firewall re-application, and a full reboot with no failed units.
- **Not doing:** distro-conditional package name mapping (the full
  package set — dnsmasq, caddy via vendor repo, apache2-utils, dnsutils,
  ethtool, jq, … — resolves identically on both), and no support for
  derivatives (Mint, Pop!_OS) whose os-release IDs differ.

### DD-103: The installer owns every restart it triggers (2026-09-08)

- **Decision:** `stage_1` exports `NEEDRESTART_SUSPEND=1` next to
  `DEBIAN_FRONTEND=noninteractive`.
- **Why:** Ubuntu ships `needrestart` with an apt `DPkg::Post-Invoke` hook.
  `/usr/sbin/needrestart` detects Ubuntu and, absent an explicit
  `$nrconf{ui}`, sets `$nrconf{restart} = 'a'` — **automatic**. Verified on
  `nrm` (needrestart 3.11, Ubuntu 26.04.1). `DEBIAN_FRONTEND=noninteractive`
  does not disable this: it only suppresses the prompt, and only for
  restart mode `i`, which Ubuntu mode has already replaced.
  The effect is that after any `apt-get install`/`full-upgrade` that pulls a
  library update, a process the installer does not own restarts `sshd`,
  `docker`, `containerd`, `tailscaled`, `caddy` and `dnsmasq` in the middle
  of stages 1, 2, 4 and 6. A `docker` restart there also fires the
  `docker.service.d` drop-in (`master-firewall restart`); a `tailscaled`
  restart fires `refresh-tailnet-config`. Both paths are re-entrant, so
  nothing has been observed to break — but this is the same "two owners for
  one thing" class the ufw gate refuses (**DD-102**), only silent.
- **Why the env var and not a config file:** `NEEDRESTART_SUSPEND` is read by
  `/usr/lib/needrestart/apt-pinvoke` and scoped to the installer's own
  process tree. Writing `/etc/needrestart/conf.d/*` would be the installer
  claiming a host policy it does not own after it exits (**DD-96**).
- **Not doing:** an `OS_ID` branch. Debian does not install needrestart by
  default, and an unread environment variable is a no-op there.
- **Live-measured (`nrm`, fresh Ubuntu 26.04.1, 2026-09-10):** with
  needrestart 3.11 installed and hooked into apt, a first install — which
  forces `full-upgrade` — produced zero needrestart journal records, and every
  service start time was attributable to an installer stage. `sshd` kept its
  boot timestamp throughout, which is the direct evidence: it is the daemon
  needrestart would otherwise have restarted mid-stage.

### DD-104: The OS is recorded, not just detected (2026-09-08)

- **Decision:** `require_supported_os` additionally sets `OS_VERSION_ID` and
  `OS_ARCH`; `write_state` records `OS_ID`, `OS_CODENAME`, `OS_VERSION_ID`,
  `OS_ARCH` and `KERNEL_RELEASE`; `stage_0` calls `detect_os_change`, which
  compares the recorded identity against the live one and, on a mismatch,
  sets `OS_CHANGED=1` and `FIREWALL_NEEDS_RESTART=1`. `OS_CHANGED` forces the
  Tailscale and Docker `apt-get update`, the `systemd-resolved` restart and
  one dnsmasq/Caddy restart, even when the written files are byte-identical.
- **Why:** the tree handles Debian/Ubuntu differences by *probing* the host
  (`command -v ufw`, `systemctl is-active systemd-resolved`, `readlink
  /etc/resolv.conf`) rather than branching on the distro label. That design
  is better than a switch statement and is kept. What it lacked was memory:
  after a `do-release-upgrade` from noble to resolute the repo lines change
  (so **DD-100**'s skip correctly triggers an update), but nothing else
  re-evaluates — the probes happen to still be right, by luck rather than by
  design. Recording the identity turns that luck into a decision, and gives
  a provisioned host a support record that previously had to be read live.
- **Absent record is not a change:** a host installed by v2-73 or earlier has
  no `OS_*` lines. That case logs "no OS record" and leaves `OS_CHANGED=0`;
  the fields are simply added on this run. Claiming a release change there
  would force needless work on every upgrading host.
- **Not doing:** gating on the recorded value, migration logic per release
  pair, or any comparison of non-OS state. `OS_CHANGED` re-runs steps that
  already exist unconditionally — it is a cache invalidation, not the
  reconcile engine contract §2 refuses.
- **Architecture:** recorded, warned about outside `amd64`/`arm64`, and not
  gated on. arm64 is untested, not unsupported; both apt vendors and all six
  images publish it.
- **Live-verified (`nrm`, 2026-09-08):** the v73 host logged "no OS record" and
  gained the fields without claiming a change. Seeding
  `OS_CODENAME=noble`/`OS_VERSION_ID=24.04` then produced
  `işletim sistemi değişmiş: ubuntu/noble/24.04 → ubuntu/resolute/26.04` and
  suppressed **every** skip path — both apt updates ran, and the firewall,
  dnsmasq and Caddy all restarted — after which `state.env` self-corrected.

### DD-105: sysctl drop-ins must sort last, and the runtime value is what counts (2026-09-08)

- **Decision:** the two drop-ins move to `99-zz-master-stack-netbuf.conf` and
  `99-zz-master-tailscale.conf` (paths in `defaults.env`), the v2-73 names are
  deleted on upgrade, and `stage_7` asserts the **live**
  `net.ipv4.ip_forward=1` and warns when `net.core.rmem_max` sits below
  `NET_BUF_FLOOR_BYTES`.
- **Why:** `/etc/sysctl.d` is applied in lexicographic order and the last
  assignment wins. On `nrm` the provider image ships
  `/etc/sysctl.d/99-nc-kernel.conf`, which sorts **after** both
  `99-master-*` files and writes `net.core.rmem_max`/`wmem_max` itself. Here
  it is harmless — it sets 64 MiB, four times the floor, and **DD-18**'s
  `max(current, floor)` correctly preserved it. But the same ordering applies
  to `99-master-tailscale.conf`, which carries `ip_forward`. On a host whose
  provider file sorts later and sets `ip_forward = 0`, the installer would
  apply forwarding at install time (`sysctl -p`, immediate) and lose it at the
  next reboot: an exit node that silently stops forwarding, with every unit
  green and every file on disk correct.
- **Why also assert at runtime:** file placement is a claim, not a
  measurement. A `99-zzz-*` file from a future image would beat the rename;
  reading the live value catches the class rather than the instance. This is
  the same reasoning as `master-firewall --check` (**DD-94**) — assert the
  effect, not the intent.
- **Why delete the old names:** two files writing one key is a second source
  of truth, and the old ones would keep losing the same race.
- **Live-verified across a cold reboot (`nrm`, 2026-09-08):** `/etc/sysctl.d`
  now lists `99-nc-kernel.conf` before `99-zz-master-stack-netbuf.conf` and
  `99-zz-master-tailscale.conf`, and after the boot `ip_forward=1`,
  `net.ipv6.conf.all.forwarding=1` and `rmem_max=67108864` (the provider's
  value, preserved by DD-18's `max()`). The rename only matters across a boot,
  so this is the test that counts.

### DD-106: Fail early, with the real cause (2026-09-08)

Three gates, one rationale: every one of them replaces a late, misleading
failure with an early, named one.

1. **Netfilter backend (`require_nft_iptables`, stage 0).** `firewall.sh` and
   Docker must use the same backend. With the alternatives set to
   `iptables-legacy`, Docker writes nft and the script reads legacy, so
   `DOCKER-USER` appears absent and `wait_for_docker_user` dies after 10 s
   with "Docker çalışıyor ama zincir yok" — the symptom, not the cause. The
   gate names the remedy (`update-alternatives --set iptables
   /usr/sbin/iptables-nft`). `nrm` verified `iptables v1.8.11 (nf_tables)`.
2. **Repo suite preflight (`assert_repo_suite`).** A codename the vendor has
   not published yet fails inside `apt-get update`, after 3 attempts of up to
   `APT_LOCK_TIMEOUT` each, with apt's own wording. One `curl -I` against
   `…/dists/$OS_CODENAME/Release` per repo says which vendor is missing which
   suite. Three attempts, because a transient network failure must not be
   reported as an unpublished release. All six current combinations verified
   to return 200 (2026-09-08).
3. **Rendered-config validation.** `dnsmasq --test -C`, `caddy validate` and
   `docker compose config -q` all run on the target — every binary is present
   there — before the unit that consumes the file is restarted. Previously the
   first sign of a bad render was `systemctl restart dnsmasq` failing under
   `set -e`, or Caddy burning its `StartLimitBurst` (**DD-72**). Both work;
   both say "restart failed" instead of "line 20: bad option". The realistic
   trigger is exactly what **DD-104** is about — a dnsmasq or Caddy version
   bump between OS releases dropping a directive. Verified on `nrm` that both
   validators accept the live configs and reject seeded errors with a line
   number and the offending directive.
- **Caddy is validated with the real environment.** The Caddyfile resolves
  `{$TAILSCALE_IPV4}` and `{$WEBDAV_PORT}` at daemon start; validating with an
  empty environment accepted a meaningless `http://:` site, so the values are
  passed in.
- **Not doing:** `systemd-analyze verify` on the generated units. The units are
  static files in the tree, not renders, and the bats suite already reads them.

### DD-107: Container logs are rotated (2026-09-08)

- **Decision:** `merge_docker_daemon_dns` becomes
  `merge_docker_daemon_config` and additionally merges
  `log-opts.max-size`/`max-file` (`defaults.env`) — but **only** when
  `log-driver` is `json-file` or unset, and by adding to any existing
  `log-opts` rather than replacing it.
- **Why:** the json-file driver's default is unbounded, six services run
  `restart: unless-stopped`, and one of them is a torrent client. Measured on
  `nrm`: `/var/lib/docker/containers` at 360 K with no rotation configured —
  small today, unbounded by design.
- **Why conditional:** **DD-8** says write the keys we own and preserve the
  rest. An operator who selected another logging driver has chosen its
  options too; overwriting them would be the installer claiming a setting it
  does not own.
- **Known limitation, deliberately not worked around:** `log-opts` applies to
  containers **created after** the change, and this function does not restart
  Docker (a restart would stop the running containers). On a provisioned host
  the setting therefore takes effect at the next compose recreation, not at
  the end of this run. Forcing it would cost a service interruption to fix a
  problem that has not yet occurred.
- **Superseded in part by DD-110 (2026-09-11):** the limitation above was
  real, but it also applied to fresh installs, not only existing hosts. The
  file was written after the package had already started dockerd, so no
  container ever received these options. DD-110 corrects the order and moves
  the log policy into `compose.yaml`.

### DD-108: A gate may only assert what the host already has (2026-09-08)

- **Decision:** `require_nft_iptables` becomes `check_nft_iptables
  optional|required`. Stage 0 calls it `optional`: it verifies the backend of
  whichever of `iptables`/`ip6tables` exist and, when neither does, logs that
  the check is deferred. Stage 1 calls it `required` immediately after the
  base package install, where the binaries are guaranteed.
- **Why:** DD-106 put the backend gate in stage 0 so a misconfigured host dies
  before any mutation. That was verified on Ubuntu, which ships `iptables`
  preinstalled — and it made **fresh Debian installs impossible**. A minimal
  Debian 13 image has no `iptables` at all (`command not found`, no dpkg
  entry, no `/usr/sbin/iptables*`); the package arrives in stage 1's base set.
  v2-74's gate therefore killed the run at stage 0, before the stage that
  would have installed the very binary it was inspecting. Verified on a fresh
  trixie host on 2026-09-08.
- **The general rule this encodes:** an early gate can only assert properties
  of a host as it *arrives*. A check whose subject the installer itself
  provides belongs after the step that provides it. Stage 0's other gates all
  satisfy this — `root`, `os-release`, TTY, ufw (`command -v` guarded), and
  `flock`, `ip`, `cmp` and `dpkg`, which are `required`/`essential` on both
  distributions and present on any minimal image.
- **Why not simply drop the stage-0 call:** a host whose alternatives were
  deliberately pointed at `iptables-legacy` still has the binaries, and that
  is the case the gate exists for. Checking what is present costs nothing and
  keeps the fail-before-mutation property for every host that can fail it.
- **Both families are checked.** `iptables` and `ip6tables` have separate
  `update-alternatives` links and `firewall.sh` drives both, so the loop
  covers both and names the failing one in the remedy.
- **Not doing:** installing `iptables` earlier just to keep the gate in stage
  0. That would move package installation before the input prompts and the
  lock, for no gain.
- **Live-verified (`nrm`, fresh Debian 13.6 trixie, 2026-09-08):** stage 0
  logged `iptables henüz kurulu değil (Debian minimal); nft arka uç denetimi
  aşama 1'e ertelendi` and the install ran through to stage 7 in 90 seconds.
  After stage 1 both binaries report `v1.8.11 (nf_tables)`. On the second
  run the stage-0 check passes silently, because the package is now present.

### DD-109: A setting whose effect is not guaranteed gets read back (2026-09-10)

- **Decision:** `stage_6` keeps writing `DNSStubListener=no` when
  systemd-resolved is active, and then calls `report_resolved_stub_state`,
  which reads whether `127.0.0.53` is actually bound and logs which way it
  went. Bounded by `RESOLVED_STUB_SETTLE_SECONDS`, because the stub socket
  appears a moment after a resolved restart.
- **Why:** on Ubuntu 26.04 / systemd 259 the key is accepted and ignored — the
  drop-in is present, last in the merge order, and `man resolved.conf` still
  documents it, yet the stub stays up and answering, on a fresh install and
  across a reboot. The installer was reporting success for a step that did
  nothing. Harmless is not the same as true.
- **What was NOT done, and why — a claim of ours that failed its own test.**
  The review's A1 entry also asserted a latent start-order race: that
  `bind-dynamic` "claims every address on the listed interfaces as they
  appear", so a dnsmasq restart while resolved was down would let dnsmasq take
  `127.0.0.53` and lock resolved out. The proposed fix was to replace
  `interface=lo` with `listen-address=127.0.0.1`. Tested on `nrm` before
  implementing: with resolved stopped and `.53` completely free, dnsmasq was
  restarted and **did not take it** — `bind-dynamic` binds the addresses
  *assigned to* an interface, and `lo` carries only `127.0.0.1/8` and
  `::1/128`; `127.0.0.53` is merely reachable through the 127/8 route.
  Resolved then rebound it cleanly. The race does not exist, so the binding
  change would have bought nothing while dropping `[::1]:53` — it was
  withdrawn. `optimization-review.md` §7's protection of `bind-dynamic` now
  rests on a measurement rather than on reputation.
- **Why not delete the ineffective drop-in instead:** it would change behaviour
  on any host where the key still works, and there is no such host to verify
  against — Debian keeps resolved inactive, Ubuntu 26.04 ignores the key.
  Writing it and measuring the result is the honest position until one exists.
- **The general rule:** where the installer cannot guarantee that a setting
  takes effect, it reads the achieved state back and says so. Same principle as
  `master-firewall --check` (**DD-94**) and stage 7's live `ip_forward`
  assertion (**DD-105**): assert the effect, not the intent.
- **Not doing:** failing the install over it. The state is benign here, and a
  gate on a third party's configuration parser would be a new failure mode for
  no gain.

### DD-110: Daemon config before the daemon; log policy in the service definition (2026-09-11)

- **Decision:** two changes.
  1. `stage_4` writes `/etc/docker/daemon.json` **before** installing the
     Docker packages, instead of after.
  2. Log rotation moves into `templates/compose.yaml` as an `x-logging`
     anchor that every service references. The values still come from
     `DOCKER_LOG_MAX_SIZE`/`DOCKER_LOG_MAX_FILE` in `defaults.env`.
     `daemon.json` keeps its `log-opts` copy, but only as the host default for
     containers outside this stack.
  When `daemon.json` changes while dockerd is already running, the installer
  says the new daemon-level settings wait for the next Docker restart instead
  of assuming they took effect.
- **Why 1 — measured on a fresh Ubuntu 26.04 install (`nrm`, 2026-09-10):**
  docker-ce's postinst starts dockerd straight away
  (`deb-systemd-invoke … docker.service`). The journal shows it finished
  initialising at **23:09:43**. `daemon.json` was written at **23:09:45**.
  `systemctl enable --now docker` does nothing to a unit that is already
  running, so dockerd kept its original configuration. The six containers
  created at **23:10:11** all carry `LogConfig {}`, and that is permanent
  because log configuration is fixed when a container is created. After a
  reboot, a probe container created with `docker create` did get
  `{"max-file":"3","max-size":"10m"}`, so the file was correct all along;
  only the order was wrong. The same ordering meant **DD-8's `dns` setting did
  not apply between a fresh install and its first Docker restart**. DNS is
  applied when a container starts, so the reboot fixed it, but until then the
  failure mode DD-8 exists to prevent (containers inheriting
  `100.100.100.100`) was open.
- **Why moving the write earlier is safe:** none of the five Docker packages
  owns `daemon.json`. `dpkg -S` finds no owner, it appears in no package's
  file list, and it is not a conffile. docker-ce only creates the
  `/etc/docker` directory, so the package install cannot overwrite a file that
  is already there, and dockerd reads it on its first start. This is the same
  pattern as **DD-18**, where Tailscale's netbuf floor is written before the
  tailscale package starts its daemon.
- **Why 2 — the order fix alone cannot reach existing hosts.** Log
  configuration is fixed when a container is created. Every container made
  before this fix keeps `{}` until it is recreated, and restarting dockerd
  would not change that. In `compose.yaml` the setting shows up as a change to
  the service definition, so the existing `COMPOSE_NEEDS_UP` path recreates the
  affected services on the next run with no daemon restart. The cost is one
  recreation of the six containers on the upgrading run. Named volumes keep
  their data and the interruption lasts seconds, the same as any other change
  to the service definition.
- **Correction of DD-107 and of the v2-76 acceptance record:** DD-107 said
  `log-opts` "applies to containers created after the change". That is
  technically true, but on a fresh install the containers were created before
  dockerd had read the file, so rotation never applied anywhere. The v2-76
  Ubuntu acceptance reported that `daemon.json` "carries the rotation keys".
  The file did, but the containers did not. The check confirmed what was
  written, not what took effect: the mistake **DD-109** warns against.
- **Not doing:** having the installer restart dockerd. On an existing host that
  would stop and start every running container without changing their fixed
  log configuration, so it would cause an outage and fix nothing.
- **Live-verified on Ubuntu 26.04.1 (`nrm`, 2026-09-11), on both paths:**
  - *Existing host (v2-77 → v2-78):* the rendered `compose.yaml` changed, so
    the run recreated all six containers once. All six ids changed, all six now
    carry `{"max-file":"3","max-size":"10m"}`, 3/3 healthchecks are healthy and
    stage 7 passed. `daemon.json` was untouched, and the new "changed under a
    running dockerd" message correctly stayed silent. A second run recreated
    nothing (0/6), so the anchor does not cause churn on every run.
  - *Fresh Docker install (the ordering itself):* after Docker was purged
    completely and the installer re-run, `daemon.json` was written at 08:50:44
    and dockerd completed its first and only initialisation at 08:50:51. With no
    restart or reboot, container DNS showed `ExtServers: [1.1.1.1 1.0.0.1]`, so
    the DD-8 gap is closed. A `docker create` probe outside compose received the
    daemon `log-opts`, and all six compose containers carry the log options.
- **A test-method pitfall found along the way, not an installer defect:**
  purging Docker without a reboot leaves the old dockerd's kernel bridges in
  place. The networks with dynamic subnets avoided them, because Docker's IPAM
  saw the existing routes and chose new ranges. The fixed-subnet `wg` network,
  however, was created a second time on `WG_BRIDGE_SUBNET`, and the kernel kept
  routing its addresses through the dead old bridge. Stage 7 correctly failed
  on `wg.ayc` (502, `connection reset by peer`), but its message points at Caddy
  rather than at the duplicate route. Deleting the three stale bridges (all
  down, none known to Docker) restored the route, `wg.ayc` returned 302, and
  the re-run exited 0. Recorded in `tests/README.md`.
- **Clean record (2026-09-11):** Docker was purged and the host rebooted, so
  no stale bridge survived (0 kernel bridges before the install). v2-78 then
  installed from a clean Docker state and exited 0 (`INSTALL_EXIT=0`).
  `daemon.json` was written at 09:01:21 and dockerd initialised once, at
  09:01:27. With no restart, container DNS showed
  `ExtServers: [1.1.1.1 1.0.0.1]` and the daemon `log-opts` were in effect. All
  six containers carry the log options and all four UIs returned non-5xx
  responses (`wg` 302). Exactly one interface held the `wg` gateway address,
  there were 0 failed units, 3/3 healthchecks were healthy, and firewall
  `--check` passed.
- **Debian 13.6, fresh install (`nrm`, 2026-09-11):** the same ordering held
  on the other distribution. `daemon.json` was written at 10:23:06 and dockerd
  initialised once, at 10:23:14. With no restart, both probed containers
  showed `ExtServers: [1.1.1.1 1.0.0.1]`, a `docker create` probe received the
  daemon `log-opts`, and all six compose containers carry the log options.

### DD-111: TCP congestion control is BBR, measured before adopting it (2026-09-11)

- **Decision:** stage 2 loads `tcp_bbr` and writes
  `net.ipv4.tcp_congestion_control = bbr` and `net.core.default_qdisc = fq` to
  `99-zz-master-tcp.conf` (values in `defaults.env`), plus a `modules-load.d`
  entry. If the module cannot be loaded, the install continues on the kernel
  default and says so. Stage 7 reads the live value back and warns on a
  mismatch; it does not fail, because this is an optimisation, not a contract
  item.
- **Why — measured on `nrm` (Ubuntu 26.04.1, kernel 7.0.0-31, 2026-09-11):** a
  256 MiB file served by Caddy over WebDAV was downloaded by a MacBook over the
  direct tailnet path (RTT ~59–67 ms, MSS 1228). The runs were interleaved
  (cubic, bbr, bbr, cubic, cubic, bbr), and each run's congestion control was
  confirmed on the live socket with `ss -tin`:

  | | Runs (Mbit/s) | Mean |
  |---|---|---|
  | cubic | 439.9 · 444.8 · 355.1 | 413.3 |
  | bbr + fq | 445.4 · 435.4 · 442.0 | 440.9 |

  An earlier batch adds three more cubic runs: 436.4, 361.1 and 348.4. That
  batch was meant to alternate with BBR, but a harness bug left every run on
  cubic, which the same socket probe confirmed. Across all six cubic runs,
  three hit a burst of about 2,000 retransmissions and lost roughly 20%. None
  of BBR's three runs did. **Peak throughput is the same (~440 Mbit/s, the
  path's ceiling).** BBR's gain is that cubic's loss-driven dips go away.
- **Scope, and a correction to the review:** `os-aware-review.md` D1 said BBR
  would help "an exit node relaying other devices' TCP". It does not. The two
  endpoints of a TCP connection run its congestion control; a router that only
  forwards the flow never does. On this host BBR affects only TCP that ends
  here: Caddy's WebDAV stream to Infuse, qBittorrent's uploads and the web
  UIs. For WebDAV that is the path that matters, and on lossy client networks
  such as a phone or a remote Infuse session, cubic's sensitivity to loss grows
  where BBR's does not.
- **Why adopt it when nothing is broken:** even cubic's worst run (348
  Mbit/s) is 3.5–7× what a 4K HDR remux needs (50–100 Mbit/s), so this does
  not remove a bottleneck. It is adopted because the measured effect was
  consistent, the mechanism is standard, it costs two sysctls in a pattern the
  tree already uses, and a host that cannot load the module simply keeps its
  default. It is an opportunistic improvement, not a fix, and is recorded that
  way.
- **Trade-offs accepted:** mainline `tcp_bbr` is BBRv1. It can take more than
  its share against cubic flows at a shared bottleneck, and it retransmits
  more on shallow buffers. Neither matters on a single-tenant host serving one
  household. qBittorrent uploads become somewhat more assertive toward peers'
  links.
- **Not doing:** replacing existing qdiscs at runtime. `default_qdisc` only
  applies to interfaces created afterwards, so on a re-run `tailscale0` keeps
  `fq_codel` until tailscaled restarts or the host reboots. BBR has paced
  internally since Linux 4.13, so `fq` complements it but is not required.
  Also not doing: per-socket `setsockopt(TCP_CONGESTION)` in any service.
- **Not an OS divergence:** this is a capability probe, not an
  `OS-DIVERGENCE` entry. `tcp_bbr` ships as a module on the Ubuntu 26.04
  kernel and on the Debian 13 kernel (`6.12.107+deb13-amd64`,
  `tcp_bbr.ko.xz`) — both verified live. If a future kernel drops it, the
  install stays on the default, which is what the probe is for.
- **Live-verified on Ubuntu 26.04.1 (`nrm`, 2026-09-11):** before the run the
  host was on cubic with `fq_codel`, and `tcp_bbr` was not loaded. The v2-79
  run logged `TCP: congestion_control=bbr default_qdisc=fq`, stage 7 raised no
  warning, and the run exited 0. Both files were written and no container was
  recreated. **`ss -tin` showed `bbr` on the WebDAV socket Caddy had accepted,**
  so the setting reached the socket that matters. Both qdisc predictions
  held. On the re-run `tailscale0` kept `fq_codel`, because existing qdiscs
  are not replaced. **After a reboot it came up with `fq`,** because
  `default_qdisc` was applied before tailscaled created the interface. After
  the reboot, `modules-load.d` had loaded `tcp_bbr` and the live value was
  still `bbr`. There were 0 failed units, and the post-reboot re-run exited 0
  and recreated nothing. The live-tested code differs from the committed code
  in one comment only. That comment was corrected afterwards so that it no
  longer describes the Debian module as verified.
- **Live-verified on Debian 13.6 (`nrm`, 2026-09-11), fresh install:** the
  preflight found `tcp_bbr.ko.xz` in the 6.12 kernel; stage 2 logged
  `TCP: congestion_control=bbr default_qdisc=fq`; the WebDAV socket Caddy
  accepted ran `bbr`; and after a reboot the module was loaded from
  `modules-load.d`, the live value was still `bbr` and `tailscale0` came up
  with `fq`. Both supported distributions have now had the same measurement.

### DD-112: Backups are password-encrypted with the OS's `openssl`; restore uploads once (2026-09-11)

- **Superseded by DD-122 (2026-09-14):** container-backup is retired.

- **Decision:** `container-backup.command` encrypts every new backup on the
  workstation with `openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256
  -salt`, asking for the password twice at backup and once at check and
  restore. Decryption is local, so the password never reaches the server.
  The restore flow uploads the archive once and runs check and restore in
  one remote directory; it no longer downloads a before-restore backup.
- **Why encrypt now:** the archives hold bcrypt hashes for four services and
  wg-easy's server and peer private keys. They live in a `0700` directory on
  one laptop, but a laptop backup, a sync folder or a copied disk carries
  them unchanged. The user asked for a password on backup and on restore;
  that is what was built.
- **Why `openssl enc`, not `age` or gpg:** the constraint was "works on
  this Mac without installing anything", and at decision time also on
  Windows — a requirement the user withdrew the next day (below). macOS
  ships LibreSSL and every OpenSSL reads and writes this one format.
  Measured: LibreSSL 3.3.6 and OpenSSL 3.6.3 derive the identical key and
  IV from the same salt and password and decrypt each other's files
  byte-for-byte; the host's OpenSSL 3.5.7 does too, which is what lets a
  backup be opened without this script. `age` and gpg are not on the Mac,
  and installing them is outside this repository. Encrypting on the server
  would have sent the password to the one place it must not go.
- **Why no MAC:** `openssl enc` has no authentication tag, and
  encrypt-then-MAC in bash means a second PBKDF2 run plus a hand-rolled HMAC
  (it works under bash 3.2 — checked against RFC 4231 and Python's `hmac` —
  but it is more code than the whole encryption step). The threat encryption
  addresses here is a *copied* file, not an attacker who can rewrite files
  on the workstation; that attacker can rewrite the script. In place of a
  tag, the decrypted archive's SHA-256 is checked against `settings.sha256`,
  which the server computed over the plaintext, and the server checks every
  file against the manifest. Without the password nobody can produce a
  ciphertext whose decryption passes either. The hash check also catches the
  one-in-256 wrong password that passes CBC padding. `settings.sha256` and
  `files.txt` stay plaintext for this reason; they reveal names and a hash,
  not contents.
- **Why the password travels on stdin and fd 3:** `read -s` from standard
  input like every other prompt in the script, then `-pass fd:3` from a
  process substitution. It never appears in `argv` (visible in `ps`) or the
  environment, and the variable is cleared on exit. Standard input rather
  than `/dev/tty` keeps automation possible; a piped password in shell
  history is the caller's choice and is documented.
- **Why one upload:** the old restore ran check, then a fresh remote
  directory for the before-restore backup, then a third for the restore,
  uploading the archive twice. The worker now removes its own intermediate
  outputs at the start of each action, so the steps share one directory and
  the archive goes up once. Same worker, same checks, one round.
- **No before-restore download (2026-09-12):** restore used to take a backup
  of the target and download it to the workstation before replacing
  anything, which stopped the four containers a second time and left a
  `before-restore` directory beside every real backup. The user asked for a
  single copy on backup and a direct load on restore. In this workflow the
  restore target is always a fresh install, so the copy protected nothing.
  What stays is the server-side recovery snapshot taken while the containers
  are already stopped: it costs no extra stop or transfer and is what the
  automatic rollback on a write/start/health failure uses. The trade-off is
  stated at the prompt and in the docs: a *successful* restore cannot be
  undone; back the target up first if its settings matter.
- **macOS only (2026-09-12):** the first version also tried to run from Git
  Bash/WSL (`sha256sum` fallback, `openssl` from `PATH` with a `-pbkdf2`
  preflight, SSH multiplexing probed and dropped where absent, LF forced by
  `.gitattributes`). It was never exercised on Windows, and the user dropped
  the requirement the next day. The launcher went back to the macOS tools
  it is verified with — `shasum`, the system `/usr/bin/openssl`, one
  multiplexed SSH connection — and `.gitattributes` was removed. The file
  format is still standard OpenSSL, so a backup can be decrypted anywhere;
  only the script is Mac-only.
- **Built and removed the same day — `seed`:** the first version of this
  change also saved `/etc/master-stack/config.env` and `webdav.htpasswd` in
  every archive (manifest schema 2) and added a `seed` action that placed
  them on a fresh host before `install.sh`, so the reinstall would reuse the
  previous answers and WebDAV account. It was verified end to end (isolated
  round-trip, minimal Debian/Ubuntu containers without jq or Docker, and a
  seed → `install.sh` re-run on `nrm` that took the seeded values as prompt
  defaults). The user then judged that five installer answers and one
  WebDAV account, which `install.sh` asks for anyway, did not justify a
  third step, a second archive schema and the content validation that came
  with sourcing a restored file as root. The tool went back to copying and
  loading container settings only; the archive layout and schema are the
  ones from 2026-09-05. The verified design is in the history (`d92b338`)
  if it is ever wanted.
- **Not doing:** encrypting `settings.sha256` or `files.txt`; a key file or
  keychain integration; re-encrypting the two existing plaintext backups
  (they stay usable and are reported as unencrypted); a `.bat` wrapper that
  cannot be tested here.
- **Verified (2026-09-11):** `/bin/bash -n` under macOS bash 3.2 and
  `shellcheck` clean on all three scripts; bats green. The isolated
  round-trip passed on the Debian 13.6 `nrm`. From the Mac under Finder's
  `/bin/bash`: an encrypted backup in 17 s that the LibreSSL one-liner
  decrypted to the server's hash; a wrong password stopped before any SSH;
  short and mismatched passwords rejected; `check` passed on the encrypted
  archive and on the 2026-09-06 plaintext archive (unencrypted warning);
  `restore` of the encrypted archive onto `nrm` in 30 s with one upload, its
  before-restore backup encrypted (`kind: rollback`), 6/6 containers, 3/3
  healthy, 3 WireGuard peers, no remote directory left. Not yet run: the
  full runbook from a bare OS; it is the next acceptance item when `nrm` is
  reimaged.

### DD-113: Security updates install themselves; reboots stay with the operator (2026-09-12)

- **Decision:** stage 1 installs `unattended-upgrades` and writes
  `20auto-upgrades` (`Update-Package-Lists "1"`, `Unattended-Upgrade "1"`)
  and a `52master-stack-unattended` drop-in with `Automatic-Reboot "false"`,
  then enables the `apt-daily` timers. The package's origin filter is left
  at the distribution default: Debian stable + security, Ubuntu security
  (+ESM). Stage 7 reads the effective `APT::Periodic::Unattended-Upgrade`
  back and checks `apt-daily-upgrade.timer`; a mismatch warns, as in DD-111.
- **Why:** the netcup Debian 13 image ships without `unattended-upgrades`
  (Ubuntu's ships with it, enabled). Until now a Debian host got security
  fixes only when the operator re-ran the installer and answered the
  full-upgrade prompt. For a host with sshd, WireGuard and Tailscale on the
  WAN, that gap was the one thing the 2026-09-12 review of the fresh Debian
  host found worth changing; everything else measured was already where it
  should be.
- **Why the distribution's filter:** Docker, Tailscale and Caddy come from
  their own repositories (origins `Docker`, `Tailscale`,
  `cloudsmith/caddy/stable`), which the default `Origins-Pattern` does not
  match. So the daemon that runs the containers, the tailnet daemon and the
  reverse proxy are never upgraded behind the operator's back; a re-run of
  the installer updates them, as before. Debian's default also takes stable
  point-release updates (`label=Debian`), which are conservative by design.
- **Why no automatic reboot:** a kernel update lands but takes effect at the
  next reboot, and `/var/run/reboot-required` says so. Rebooting an exit
  node in the night because a kernel arrived is a policy the operator
  should hold, not the package. The drop-in pins the default so a future
  distribution change cannot flip it.
- **Ubuntu interplay:** on Ubuntu `needrestart` runs in automatic mode during
  unattended upgrades and may restart sshd, tailscaled or dockerd after a
  library update; that was already the case before this change, because the
  package was present and enabled. DD-103 suspends it only for the
  installer's own apt calls. On Debian `needrestart` is absent, so updated
  libraries are picked up at the next service restart or reboot.
- **Not an OS divergence:** the same package and files on both
  distributions; on Ubuntu the install is a no-op and the periodic file
  matches what the image already had. Not adding a mail/report hook,
  `-updates` on Ubuntu, or `Remove-Unused-Dependencies`.
- **Live-verified on Debian 13.6 (`nrm`, 2026-09-12):** a re-run over the
  restored v2-79 host installed the package, wrote both files and changed no
  container; the effective apt-config shows the periodic upgrade on and
  automatic reboot off, and a `--dry-run --debug` lists only the three Debian
  origins as allowed. The first attempt exited 141 at the new read-back —
  `apt-config dump | awk '...; exit'` under `pipefail` — after every stage
  had completed; the read-back now lets `awk` consume the whole stream (see
  `tests/README.md`). Ubuntu: not re-run; the files match what the Ubuntu
  image already carries, and the package is present there by default.

### DD-114: Container backups carry one operator-state file per service (2026-09-13)

- **Superseded by DD-122 (2026-09-14):** container-backup is retired.

- **Decision:** `container-backup` saves and restores exactly four files:
  Portainer's `portainer.db`, FileBrowser's `filebrowser.db`, qBittorrent's
  `qBittorrent.conf` and wg-easy's `wg-easy.db`. Restore replaces each one
  atomically with its recorded owner and mode, removes SQLite side files
  beside it, and touches nothing else on the destination. Whole-directory
  archives from before this date still restore; only these four files are
  taken from them.
- **Why:** the user listed everything they do after an install: create the
  Portainer admin from the setup token, change the FileBrowser password,
  change the qBittorrent user name, password and a few preferences, create
  the wg-easy account and the peers. Each of those lives in one file. The
  user's concern was that writing more back — keys, certificates, derived
  configuration — could interfere with what a newer image produces for
  itself. Carrying only the state the operator created removes that
  question.
- **Why the other files are safe to leave behind (measured on `nrm`):**
  - wg-easy wrote `wg0.conf` one second after its container started, so the
    file is rendered from `wg-easy.db` on every start.
  - FileBrowser's `config/settings.json` carries a July image-build date,
    and a fresh FileBrowser created it on first start. The Compose command
    line overrides its address, port, root and database.
  - Portainer's keys, certificates and Edge tunnel key are dated from the
    install. A throwaway Portainer, started once so it generated its own
    keys, was then given only a backed-up `portainer.db`. It served
    `/api/status`, reported the admin as present and rejected a wrong
    password with 422 (the user table was read), and its own keys stayed in
    place. It logged no errors.
  - A throwaway FileBrowser run with the Compose restrictions behaved the
    same with only `filebrowser.db`: healthy, and 403 for a wrong login.
  - Both throwaway containers had no published port and no Docker socket,
    and were removed.
- **SQLite side files:** replacing a single SQLite database while an old
  `-wal` is left beside it would let SQLite replay the destination's
  transactions onto the restored file. Restore removes `-wal`, `-shm` and
  `-journal` next to each restored file. A backup refuses a database whose
  WAL or journal is not empty after the clean stop, and validation refuses an
  archive that carries one. BoltDB and the `.conf` file have none. This
  replaces the protection the old whole-directory copy gave implicitly.
- **Trade-offs:** the following are not carried:
  - Portainer stacks deployed from Portainer, whose compose files live under
    `/data/compose/`.
  - Edits to FileBrowser's `settings.json`.
  - qBittorrent's categories, RSS, watched folders and torrent list.
  - Stale files on the destination, which are no longer cleaned; there is
    nothing to clean on a fresh install.

  The restore semantics also changed: a scope file absent from the archive is
  removed, which is how the server-side recovery snapshot brings back a file
  that did not exist before.
- **Considered and not committed:** widening qBittorrent to its whole
  settings tree minus GeoDB, logs, the RSS article cache and runtime files.
  It was built and verified on 2026-09-13, then reverted before commit when
  the user described what they actually change.
- **Verified (2026-09-13):**
  - The isolated round-trip on `nrm` passed, 18 checks including an archive
    with exactly four files, untouched out-of-scope files, side-file
    clearing, a qBittorrent that never started, whole-directory archives,
    rollback, and non-empty-WAL rejection.
  - Live from the Mac: the backup held exactly the four files (40 KB), and a
    self-restore took 16 s.
  - After the restore, `qBittorrent.conf` and `wg-easy.db` were
    byte-identical to the archive. The two BoltDB files had been updated by
    their applications on open. Owners and modes matched on all four.
  - All 12 out-of-scope files were unchanged in content; 6/6 containers ran,
    3/3 healthy, every peer was present and the web UIs answered.
  - The user's real 2026-09-12 backup lists only entries the validator
    accepts, and `check` on a same-format archive reported "4 to load".

### DD-115: An optional Tailscale auth key replaces the browser step (2026-09-13)

- **Decision:** stage 0 asks `Tailscale auth key (boş bırakın = tarayıcıdan
  giriş)` with hidden input, after the WebDAV prompts, and only when the node
  is not already online.
  - With a key, stage 2 writes it to `$RUNTIME_DIR/tailscale-authkey`
    (tmpfs, root-only directory, file mode `0600`). It runs `tailscale up
    --auth-key=file:<that path> --advertise-exit-node --ssh` under
    `TS_AUTHKEY_LOGIN_SECONDS` (300 s), then removes the file.
  - An `EXIT` trap removes the file if the run is interrupted.
  - If `tailscale up` fails and the node is not online, the installer logs
    a warning and runs the existing interactive login.
  - The variable is unset after stage 2.
- **Why:** the user asked for it. The login URL is the one step of an
  install that needs a browser, and a key lets the install continue by
  itself once the prompts are answered. It is not an unattended mode: every
  other prompt stays, and an empty answer keeps today's behaviour exactly.
- **Why a file, not the argument:** `--auth-key=tskey-…` would be readable by
  any local user in `ps` and `/proc/<pid>/cmdline` for as long as `tailscale
  up` runs. Tailscale 1.102.4 documents `file:` for exactly this ("a path to
  a file containing the authkey"). The key also stays out of `config.env`,
  `state.env`, the install log, the environment of child processes and,
  therefore, container backups. The prompt reuses the `read -s` pattern of
  the WebDAV password, and a bats test rejects any `--auth-key=$TS_AUTH_KEY`,
  `export TS_AUTH_KEY` or a log line carrying it.
- **Why fall back instead of stopping:** a key is a convenience with a
  shelf life. A one-off key already used, an expired key or a typo must not
  strand a fresh install half-way through stage 2. The browser path, with
  its three-attempt 410 recovery (**DD-37**, **DD-42**), is unchanged and
  follows directly.
  - A successful `tailscale up` returns straight to stage 2's online wait,
    which also covers a tailnet with device approval.
  - The exit status is read from `PIPESTATUS`, not from the `tee` it is piped
    through. The first version returned success for a rejected key whenever
    `pipefail` was off; a test caught it.
- **Why validate the shape:** keys start with `tskey-` and contain only
  letters, digits and `-`. OAuth client secrets (`tskey-client-…`) also log
  in only with `--advertise-tags`; stage 0 names that mistake instead of
  letting it fail in stage 2.
- **Which key to create (operator guidance, not enforced):**
  - Reusable or one-off.
  - **Not ephemeral:** an ephemeral node is removed once it has been offline
    for a while, so an exit node that reboots would disappear from the
    tailnet.
  - Pre-approved if the tailnet requires device approval.
  - Exit-node approval and the DNS settings stay manual unless the tailnet
    policy auto-approves them; the install summary still lists them.
- **Verified (2026-09-13):**
  - bats: three tests check that the key reaches `tailscale up` only through
    a `0600` file that is gone afterwards, never appears in argv or the log,
    that a rejected key falls back, and the prompt and persistence rules.
  - Live on `nrm`, inside a throwaway container running the host's
    `tailscaled` 1.102.4 with its own state: the installer's real function
    passed a fake key by `file:`. Tailscale read it and rejected it in 5 s
    (`backend error: invalid key: API key does not exist`); the function
    fell back with the warning, no key file remained and the key was in
    neither log.
  - The prompt trimmed pasted whitespace over a real TTY.
  - A v2-81 re-run on the online production host skipped the prompt, exited
    0 with no warnings and recreated no container.
  - Not yet verified: a successful login with a real key; that needs a key
    from the user's tailnet on the next fresh install.
  - The first attempt at the isolated test had a test-procedure flaw,
    recorded in `tests/README.md`.

- **Amended by DD-119 (2026-09-14):** the key comes from `TS_AUTH_KEY` in
  the installer input file instead of a hidden prompt, and is dropped when
  the node is already online. The `file:` login, the fallback and the
  persistence rules are unchanged.

### DD-116: Dozzle replaces Portainer (2026-09-13)

- **Decision:** the Compose `portainer` service becomes `dozzle`
  (`amir20/dozzle:v11`, loopback `127.0.0.1:61002` → 8080, site
  `dozzle.${LOCAL_DOMAIN}`).
  - It runs with `DOZZLE_AUTH_PROVIDER=simple`,
    `DOZZLE_ENABLE_ACTIONS=true` and `DOZZLE_NO_ANALYTICS=true`. Shell is
    left disabled.
  - Hardening: read-only root, a `/tmp` tmpfs, `cap_drop: ALL`,
    `no-new-privileges`, and a Compose healthcheck (`/dozzle healthcheck`,
    which the image does not wire in by itself).
  - Stage 0 asks for a Dozzle user name and password when
    `/etc/master-stack/dozzle/users.yml` does not exist. Stage 4 writes it
    with the image's own `generate --user-roles actions`, password on stdin,
    in a container without network; `/etc/master-stack/dozzle` is bound to
    `/data`.
  - Stage 7 requires `401` from `/api/events/stream` through Caddy, so a
    Dozzle without its login fails the install.
- **Why:** the user uses Portainer for three things only — container state,
  logs, and removing a container when needed — and said most of its features
  do not fit. Dozzle is built for exactly those three: live logs with search,
  container state and resource use, and start/stop/restart/remove.
  - Two burdens go away: the post-install setup-token step (create the
    Portainer admin within its timeout) and `portainer.db` in the backup.
  - Portainer also offered a way to edit and recreate the installer's
    containers outside `compose.yaml`; Dozzle does not, apart from `update`
    (below).
  - Resource use was not the reason: Portainer used about 96 MB of a 7.8 GB
    host.
- **Why the login comes from the installer:** Dozzle with actions can stop
  and remove every container, and `docker.sock` is root-equivalent whether or
  not it is mounted `:ro` (Dozzle's own documentation says the flag does not
  limit the API). Tailnet-only reachability was offered and not chosen.
  - The account follows the WebDAV pattern: asked once, kept on re-runs,
    replaced by deleting the file and re-running.
  - `generate` owns the file format and bcrypt hashing, so nothing is
    reimplemented. Stdin keeps the password out of `argv`.
  - The `actions` role instead of the empty default (all roles) leaves
    shell and cloud linking out even if they are enabled later.
- **Why `v11`:** DD-97 prefers the vendor's major track. v11.0.0 was
  published on 2026-09-11 with no breaking changes listed; `v10` stopped at
  10.10.0.
- **Measured before adopting (2026-09-13, throwaway container on `nrm`):**
  - The hardened settings ran without restarts, and `/healthcheck`
    answered 200.
  - Without a login: `/` → 307 to `/login` and `/api/events/stream` → 401.
    A wrong password → 401. The right one → 200, and the event stream then
    delivered.
  - The page configuration reported `authProvider: simple`,
    `enableActions: true`, `enableShell: false`.
  - Dozzle writes `session_secret` next to `users.yml` in `/data`, so the
    directory stays writable.
- **Trade-offs:**
  - Dozzle's single actions switch also enables `update`, which pulls and
    recreates a container outside the installer. A re-run restores the
    Compose definition; updating images remains the installer's job
    (DD-97).
  - Portainer's stack/volume/image management is gone.
  - Old backups still restore, with Portainer ignored (**DD-114**).
- **Existing hosts:** per DD-96 the installer does not delete the
  `portainer` container or its `docker_portainer_data` volume. `docker
  compose up` reports it as an orphan, and stage 7 logs a warning with the
  removal commands while it runs. On `nrm` the container was removed by hand
  after verification; the volume was left for the operator.
- **Verified on `nrm` (Debian 13.6, 2026-09-13):**
  - Static: bats 104 ok; `bash -n` and `shellcheck` clean.
  - Install: a v2-81 → v2-82 re-run answered the new prompts, wrote
    `users.yml` (`0600 root:root`, role `actions`) and created a healthy
    `dozzle` with the hardening in effect. The other five containers were not
    recreated.
  - DNS and login: `dozzle.ayc` resolved to the Tailscale IP and
    `portainer.ayc` became NXDOMAIN. Through Caddy the login was enforced
    and a login worked. Stage 7 warned about the running Portainer.
  - After removing the Portainer container, a second run skipped the prompt,
    warned nothing and changed nothing.
  - Backup: the round-trip passed 18/18. A live backup held three files, and
    `check` on a four-file Portainer-era archive reported "4 files, 3 to
    load".

### DD-117: Transmission replaces qBittorrent (2026-09-13)

- **Decision:** the `qbittorrent` service becomes `transmission`
  (`lscr.io/linuxserver/transmission:latest`, Transmission 4.1.3).
  - Web UI at `torrent.${LOCAL_DOMAIN}` (loopback 61006 → 9091).
  - The peer port stays 61005 TCP+UDP (`PEERPORT`).
  - `QBIT_PUBLIC_PORT`/`QBIT_UI_PORT` become
    `TORRENT_PUBLIC_PORT`/`TORRENT_UI_PORT` in `defaults.env`, `state.env`
    and the firewall script alike.
  - `/config` is a bind mount on `/etc/master-stack/transmission`.
  - Credentials: stage 0 asks for a user name and password, stored in
    `/etc/master-stack/transmission-auth/{user,pass}` (`0600 root`, directory
    `0700`), mounted read-only and read through `FILE__USER`/`FILE__PASS`.
  - The installer seeds `settings.json` on a fresh install (download layout,
    port forwarding off, `rpc-port` 9091) and never touches it again.
  - Stage 7 requires `401` from `/transmission/rpc` without a login.
  - A leftover `qbittorrent` container stops stage 0 before any change.
- **Why:** the user uses the torrent client only to download and wanted
  something simpler than qBittorrent. Resource use was not the argument:
  qBittorrent idled at 15.7 MB on `nrm`. The gain is a plain interface and one
  post-install step fewer — reading qBittorrent's temporary password from the
  logs and changing it — because the installer now sets the account.
- **Why the credentials are a plaintext root-only file — measured, not
  assumed (throwaway containers on `nrm`):**
  - Without `USER`/`PASS` the image's init script sets
    `rpc-authentication-required = false` on every start, so authentication
    survives only if the credentials are supplied every time.
  - Its clean-shutdown script calls `transmission-remote --exit` with them.
  - A pre-hashed Transmission password (`{sha1…salt}`) did log in through the
    web UI, but broke that shutdown RPC. `docker stop` waited out its timeout
    and killed the container (exit 137), and a changed setting was lost.
  - `FILE__` keeps the value out of `compose.yaml` and `docker inspect`
    (verified).
  - The host file is `0600 root`, which docker access already trumps.
    Transmission itself keeps only a hash in `settings.json`, even while
    running.
  - The file must hold the plaintext; that is the trade-off, recorded here
    rather than hidden.
- **Why the settings seed includes `rpc-port`:** the image's shutdown and
  readiness scripts read the port with `jq '.["rpc-port"]'`.
  - A first seed without it produced `127.0.0.1:null`, and every stop hung
    until killed, whichever way the password was supplied.
  - With the key, stops took 4–6 s, exited 0, and a changed setting survived
    a restart.
  - The seed is written only when the file is absent; afterwards Transmission
    owns it.
- **Why that layout:** qBittorrent saved to `/downloads/` with partial files in
  `/downloads/incomplete/`. Transmission's LinuxServer default is
  `/downloads/complete`, which would add a level for FileBrowser, WebDAV,
  Infuse and Unpackerr. DHT, PeX and queue limits are left to the operator,
  who sets them in the UI once; the backup then carries them. *(Superseded
  by **DD-118**: the installer writes them.)*
- **Why no host whitelist:** with authentication on, Transmission accepted
  requests under an arbitrary `Host:` (verified), so `HOST_WHITELIST` would add
  nothing.
- **Why a stage-0 gate instead of removing qBittorrent:** its container
  publishes the same peer port, so Compose cannot start Transmission next to
  it. DD-96 keeps deletion with the operator. The gate fails before anything
  changes, prints `docker rm -f qbittorrent`, and leaves the
  `docker_qbit_config` volume alone.
- **Credential changes take effect immediately:** when the installer writes new
  credentials for Dozzle (DD-116) or Transmission, it restarts that container.
  Before, deleting Dozzle's `users.yml` and re-running wrote the file but left
  the running Dozzle on the old account until its next restart. The procedure
  previously given to the user was therefore incomplete.
- **Backups:** the scope becomes `transmission/settings.json` next to
  `filebrowser.db` and `wg-easy.db` (DD-114).
  - qBittorrent- and Portainer-era archives still validate; their extra
    entries are ignored.
  - A service such an archive does not carry (Transmission) is neither
    compared nor written. Restore now skips services absent from the archive
    instead of removing the destination file. A rollback snapshot still
    removes a file that did not exist.
- **Verified on `nrm` (2026-09-13):**
  - bats 106 ok, including functional tests for the settings seed, the
    credential files and the restart; `bash -n` and `shellcheck` clean.
  - With qBittorrent present, the installer exited 1 at stage 0 and
    `state.env`, `compose.yaml` and every container were unchanged.
  - After qBittorrent was removed, the v2-82 → v2-83 run created
    Transmission with the seed and credentials and recreated none of the
    other five containers.
    - `settings.json` showed `/downloads`, peer-port 61005, `rpc-port` 9091
      and a hashed password; `docker inspect` held no password.
    - `state.env` carried `TORRENT_PUBLIC_PORT` and no `QBIT` key.
  - DNS: `torrent.ayc` resolved; `qbit.ayc` became NXDOMAIN.
  - Login through Caddy: the RPC answered 401 without or with a wrong
    login, 409 (authorized) with the right one; the web UI answered 200.
  - `--check` passed and both firewall chains held the 61005 rules. From the
    Mac the public peer port was reachable and 61006 was not.
  - `docker restart` took 4 s and was clean.
  - Credential change: after deleting the Dozzle and Transmission credential
    files and re-running with a new password, the new password worked and
    the old one was rejected, with no manual restart. Reverting worked the
    same way, and a final run asked nothing and changed nothing.
  - Backup: the round-trip passed 19 checks. A live backup held three files,
    and a qBittorrent-era `check` reported two to load. A self-restore
    stopped and started Transmission cleanly.

### DD-118: The installer sets up FileBrowser and Transmission; the backup keeps only wg-easy (2026-09-14)

- **Decision:**
  - Stage 0 asks for a FileBrowser user name and password (at least
    `FILEBROWSER_MIN_PASSWORD_LENGTH`, 12) when `filebrowser.db` is absent.
    Stage 4 creates the database before Compose starts. An existing database
    is kept and nothing is asked.
  - The Transmission settings seed adds `dht-enabled`, `pex-enabled` and
    `lpd-enabled` false, `download-queue-enabled` true and
    `download-queue-size` 12. As before, it is written only when
    `settings.json` is absent.
  - `container-backup` carries `wg-easy.db` only. FileBrowser and
    Transmission join Portainer and qBittorrent as legacy archive entries:
    validated, never written. A backup or restore no longer stops their
    containers.
- **Why:** the user wants the installer to take over from the backup wherever
  it can. After an install they changed only the FileBrowser password and a
  few torrent preferences (DHT/PeX/local discovery off, at most 12 active
  downloads, as they had set in qBittorrent). Both are fixed answers an
  installer can give on every install. wg-easy's server key and peers cannot
  be recreated without re-provisioning every client, so they stay in the
  backup.
- **Where the FileBrowser password comes from — the user chose the prompt
  (2026-09-14) over:**
  - The password from the existing backup: the backup holds only a bcrypt
    hash, and it is encrypted with a password that must not leave the
    workstation (DD-112).
  - A plaintext password in `defaults.env`: it would enter git history and
    every exported `.command`.
  - A git-ignored local secrets file sent over SSH: plaintext on the
    workstation, and a new transfer path in the launcher.
- **How the account is created — measured on `nrm` with throwaway containers
  (FileBrowser 2.63.23):**
  - A first start without a database ("quick setup") creates `admin` with a
    random password written to the container log. Quick setup takes a user
    name and a bcrypt hash as flags of the serving process itself.
  - `config init --viewMode mosaic --sorting.by '' --redirectAfterCopyMove
    --hideLoginButton` produced settings identical to quick setup's apart
    from the random key. Without those flags four defaults differed.
  - The user record is `.settings.defaults` from `config export` plus id,
    name, hash, `lockPassword: false`, `rules: []` and `perm.admin`.
    `users import` reads it from a file. The imported user matched quick
    setup's user field for field apart from name and hash.
  - `htpasswd -niB -C 10` reads the password from stdin. FileBrowser accepted
    its `$2y$` hash: login 200, a wrong password 403, `admin`/`admin` 403.
    Cost 10 is FileBrowser's own.
  - `users import --replace` writes `users.backup.json` into the working
    directory and failed on the container's `/`. A plain import into an
    empty database needs no backup file, and `-w /database` keeps the
    working directory writable anyway.
- **Safety properties:**
  - The CLI runs as `DOWNLOADS_UID` in a one-shot container with
    `--network none` and only a temporary directory mounted. Its stdout
    (`config init` prints the settings, key included) is discarded; stderr
    goes to a file in that directory and is shown only on failure.
  - The password reaches `htpasswd`'s stdin and nothing else: not argv, a
    log, `docker inspect` or a plaintext file.
  - The database is verified — exactly one user, that name, admin, a bcrypt
    hash — and moved into place with one `mv`. A failure removes the
    temporary directory, so no half-made database is left for a re-run to
    keep.
  - A database deleted under a running container is rebuilt, and the
    container restarted, the same rule as the Dozzle and Transmission
    credentials (DD-117).
- **Why 12:** FileBrowser refuses a shorter password when it is changed in its
  UI. The installer enforces the same minimum at the prompt and stores it in
  the database.
- **Trade-offs:** not carried to a new host any more:
  - A FileBrowser password changed later in its UI, other FileBrowser users
    and share links.
  - Transmission preferences changed later in its UI.

  Existing installs keep their `settings.json`: the preference keys reach
  only a fresh install, or a Transmission whose `settings.json` was removed
  while it was stopped. Deleting `filebrowser.db` is the way to recover a
  forgotten FileBrowser password; shares go with it.
- **Verified on `nrm` (2026-09-14):**
  - bats 108 ok, including functional tests for the account creation
    (success, a rebuilt database under a running container, a failed import
    that leaves nothing) and the preference seed; `bash -n` and `shellcheck`
    clean. The isolated backup round-trip passed 20 checks.
  - v2-83 → v2-84 over existing data: exit 0, no FileBrowser prompt, and no
    container recreated or restarted.
  - With `filebrowser.db` deleted, an 11-character password stopped stage 0
    with exit 1; `state.env`, `compose.yaml` and the missing database were
    unchanged.
  - The fresh account, in the same run as a Transmission seed (Transmission
    stopped, `settings.json` moved aside):
    - Exit 0; FileBrowser was restarted on the new database.
    - Through Caddy: login 200, wrong password 403, `admin`/`admin` 403.
    - One user, an admin; `minimumPasswordLength` 12; new-user view `mosaic`.
    - Database `0640 1000:1000`, no temporary directory left, no password line
      in the container log and none in `docker inspect`.
  - Transmission, started by stage 7's `compose up`:
    - RPC `session-get` reported DHT, PeX and LPD off, the queue on at 12,
      `/downloads` and peer port 61005.
    - The image's init script kept the keys and authentication on.
    - After a restart (exit 0) the file still held them.
  - A no-op re-run: exit 0, no prompt, database and containers unchanged,
    firewall `--check` passed.
  - Backup from the Mac:
    - Took 11 s and held `manifest.json` and `wg-easy/wg-easy.db`. Only
      wg-easy was restarted.
    - `check` reported one file to load for the new archive, a v2-83-era
      archive (three files) and a Portainer-era archive (four files), with
      the legacy note on the older two.
    - Restoring the v2-83-era archive took 11 s and restarted only wg-easy.
      The FileBrowser database and Transmission settings were untouched,
      the FileBrowser login still worked, every peer was present and no
      remote temporary directory was left.
- **Superseded in part by DD-119 (2026-09-14):** the accounts come from a
  git-ignored input file instead of prompts. An existing database is synced
  to that file on every run instead of being kept, so a password changed in
  FileBrowser's UI is reset on the next run.

### DD-119: Installer inputs come from one git-ignored file, and that file is the truth (2026-09-14)

- **Decision:**
  - **Where the inputs live:**
    - Every operator input is in `kurulum/kurulum.env` at the repository root:
      SSH host, local domain, downloads path, WireGuard and WebDAV ports, the
      four service accounts and the optional Tailscale auth key.
    - The file is git-ignored and must have mode `600` (or `400`).
    - The template `config/kurulum.env.example` lists every key with no value.
      A test keeps its keys equal to `INPUT_KEYS`.
  - **The launcher:**
    - It stops locally if the file is missing or has a wider mode.
    - It reads `SSH_HOST` and nothing else; no host prompt remains.
    - It sends the file over SSH to `INPUT_FILE`
      (`/run/master-stack/kurulum.env`, declared in `defaults.env`). It
      refuses when that directory is not `tmpfs`.
    - It removes any leftover when it exits.
  - **Stage 0 reads the file right after the root check and deletes it before
    any other gate**, whether or not the file validates. `read_input_file`
    (`common.sh`) never sources it:
    - One `KEY=value` per line, with the value taken literally.
    - An unknown key, a duplicate, a missing key, CRLF, surrounding quotes,
      surrounding whitespace or a malformed line stops the install. The
      message gives the line number and key name, never a value.
    - Every key must be present, and the account keys must be non-empty. An
      empty domain, path or port takes the `defaults.env` value; an empty
      `TS_AUTH_KEY` means the browser login.
  - **Validation and confirmation:**
    - The old prompt rules still apply: user-name character sets, minimum
      password lengths, port conflicts and the `tskey-` shape.
    - The `INPUT_*` variables are unset once mapped.
    - Stage 0 prints a summary without passwords and asks for one `E` before
      `config.env` is written. The re-run questions (full-upgrade, image pull)
      remain.
  - **The file is the single source of truth.** Every run compares each
    account with the file, rewrites only what differs and restarts only that
    container:
    - **WebDAV:** kept when the htpasswd has one line and `htpasswd -vi`
      accepts the password. A rewrite restarts `webdav`, because the secret is
      a bind mount and still points at the replaced file.
    - **Dozzle:** kept when `users.yml` holds exactly one user with that name
      and `htpasswd -vi` accepts the stored hash.
    - **Transmission:** kept when both root-only files hold the file's values.
    - **FileBrowser:** users are exported from a copy of the database. When
      the account differs:
      - the container is stopped;
      - `users import --overwrite` writes the name and hash into a fresh copy,
        keeping the same id;
      - the result is verified and moved in with one `mv`, then the container
        is started.

      Any failure starts the container again on the untouched database. The
      target is the user with the file's name, else the lowest-id admin. Other
      users are left alone.
- **Why:**
  - The user runs a fixed setup and wants a reinstall to need no typed
    answers. Until now the reinstall runbook depended on repeating the same
    answers by hand.
  - This reverses DD-118's choice of the prompt over "a git-ignored local
    secrets file sent over SSH". The two costs recorded there are accepted and
    bounded:
    - Plaintext on the workstation: git-ignored and `600`.
    - A new transfer path: a `tmpfs`-only target, deleted by the installer as
      its first read.
- **Why the file wins over changes made in a UI:** a password changed in
  FileBrowser's UI returns to the file's value on the next run. The user
  agreed to this. The alternative, applying a file change only when the file
  itself changes, would need a stored fingerprint of every password.
- **Measured on `nrm` (2026-09-14, apache2-utils 2.4.68-1~deb13u1, FileBrowser
  v2):**
  - `htpasswd -vi` verifies both a `$2y$` hash (htpasswd) and Dozzle's `$2a$`
    hash from stdin. It returns 0 on a match, 3 on a mismatch and 6 for an
    unknown user.
  - A running FileBrowser holds the Bolt lock: the CLI on the live database
    fails with `Error: timeout`, while `users export` on a copy works.
  - `users import --replace` fails with "the sole admin can't be deleted".
    `users import --overwrite` updates the same id, including a rename, and
    leaves every other field byte-identical.
- **Not doing:**
  - A prompt fallback when the file is absent: two input paths to test and
    document.
  - Validating fields on the Mac: Finder's bash 3.2 would need a second
    validator.
  - Encrypting the file: a password at every run for a file that leaves the
    workstation only as RAM on the server.
- **Consequences:**
  - "No unattended mode" now means one confirmation. The Tailscale login URL
    still needs a browser when no key is given.
  - DD-115's hidden prompt is gone. Its `--auth-key=file:` login and the
    fallback to the browser are unchanged.
- **Verified (2026-09-14):**
  - bats 116 ok, with `bash -n` and `shellcheck` clean.
  - New functional tests: the parser (literal values, eight rejection cases
    and a wrong mode, all deleting the file and never echoing a value),
    `bcrypt_matches`, the WebDAV keep/rewrite, the Dozzle match, the
    Transmission keep, and the FileBrowser sync (match, overwrite that keeps
    other fields and users, failed import that restarts the container on the
    untouched database).
  - Three deliberate code mutations each failed their test.
  - A mid-test `! cmd` or `[[ ]]` does not fail a bats test under macOS bash
    3.2, so the new negative checks use `run !`, `[ ]` or `case`.
  - Live on `nrm`, driving the exported v2-85 `.command` from the Mac under
    `expect`:
    - **Mode 644:** refused on the Mac, before SSH.
    - **Answering `h` at the confirmation:** exit 1; the summary showed no
      password, `config.env` was unchanged, `/run/master-stack` held only the
      lock and the log had no password.
    - **v2-84 → v2-85:** exit 0 in 15 s. The operator's real WebDAV hash was
      saved beforehand and differed from the test file, so the htpasswd was
      rewritten and only `webdav` restarted. Dozzle, Transmission and
      FileBrowser were logged unchanged, and the six container ids plus the
      other five start times were identical. WebDAV answered 401 without
      credentials and 207 with them; the FileBrowser login returned 200.
    - **Same file again:** a full no-op, with every restart skipped.
    - **Three passwords changed in the file:** Dozzle regenerated and
      restarted, Transmission rewritten and restarted, FileBrowser stopped,
      overwritten and started. New passwords: 200, 200, 409 (Transmission's
      RPC session handshake, authenticated). Old passwords: 403, 401, 401.
      `webdav`, `wg-easy` and `unpackerr` were untouched, and there was no
      password in the log or `docker inspect`.
    - **An unknown key (`WEBDAV_PAS`) and an 11-character FileBrowser
      password:** both stopped stage 0 with the line and key named.
      `config.env` and the database were unchanged, and the values were absent
      from the log.
    - **The test passwords restored:** all three services updated and logged
      in again.
    - **Cleanup:** the operator's original WebDAV htpasswd was put back
      byte-identical, `webdav` was restarted, and the saved copy was removed.

### DD-120: WireGuard runs in the host kernel from kurulum/wireguard; wg-easy is removed (2026-09-14)

- **Decision:**
  - **What goes away:** the `wg-easy` Compose service, its bridge network,
    volume definition, `WG_EASY_IMAGE`, `WG_UI_PORT` and `WG_BRIDGE_*`, plus
    the tailnet name `wg.${LOCAL_DOMAIN}` and its Caddy site. WireGuard is
    `wg-quick@wg0` on the host with the same addresses as wg-easy
    (`10.8.0.1/24`, `fdcc:ad94:bacf:61a4::cafe:1/112`, UDP `WG_PUBLIC_PORT`,
    MTU 1420), so existing client profiles connect unchanged.
  - **Inputs:** `kurulum/wireguard/sunucu.key` (the server private key) and
    one wg-easy-format profile per device, `kurulum/wireguard/<device>.conf`.
    The launcher sends them with `kurulum.env` as a tar stream to `INPUT_DIR`
    on `tmpfs`, each file mode-checked. Stage 0 reads the WireGuard folder
    into memory and deletes it before parsing `kurulum.env`, then deletes the
    whole input folder.
  - **Validation in stage 0, before any change:**
    - One `[Interface]` and one `[Peer]` per profile.
    - Well-formed keys and a PSK when present.
    - An IPv4 inside `WG_SUBNET4` that is not the network, broadcast or server
      address, and has no leading zeros.
    - An optional IPv6 in the server's `/112` written the wg-easy way.
    - Unique addresses and private keys, an `Endpoint` port equal to
      `WG_PUBLIC_PORT`, and a safe file name.
    - Messages name the file and the address, never a key.
  - **`ensure_wireguard`, at the end of stage 5, after the firewall:**
    - Installs `wireguard-tools` with `--no-install-recommends`, so no
      `wireguard-dkms`.
    - Checks that every profile's `[Peer] PublicKey` equals `wg pubkey` of
      `sunucu.key`.
    - Derives each peer's public key from its private key, key on stdin.
    - Writes `/etc/wireguard/wg0.conf` (`0600`) with the server key, peer
      public keys, PSKs and `AllowedIPs` only. Client private keys never reach
      the disk, and the file carries no `PostUp`.
    - Restarts `wg-quick@wg0` only when the file changed.
  - **Firewall (`firewall.sh` owns every rule, DD-16/DD-17):**
    - `MASTER-INPUT` accepts, from `wg0`, only TCP to `10.8.0.1` on the three
      UI ports and ping; everything else from `wg0` is dropped (IPv6: all).
    - A new `MASTER-FORWARD` chain at the top of `FORWARD` accepts `wg0` → WAN
      and replies, and drops everything else to or from `wg0`: the tailnet,
      Docker networks, other peers.
    - A new `MASTER-NAT` chain in `nat POSTROUTING` masquerades both WireGuard
      subnets out of the WAN.
    - The WireGuard `ctorigdstport` return leaves `MASTER-DOCKER`; the port
      stays in `MASTER-INPUT`.
    - `--check` asserts the new rules, their order (read from `iptables -S`,
      where `-d` precedes `-i`) and the exact `MASTER-FORWARD` rule count.
  - **UIs over WireGuard:** a second Caddy, `caddy-wg.service` with
    `templates/Caddyfile.wg`, has `admin off` and `default_bind 10.8.0.1`. It
    proxies `http://10.8.0.1:{61002,61006,61007}` to the loopback UIs, with no
    names and no WebDAV. It `Requires`/`PartOf` `wg-quick@wg0` and has no
    Tailscale dependency.
  - **Stage 7:** checks the listen port, that the peer count equals the
    profile count, the `wg0` address, and a non-5xx from each `caddy-wg` port.
  - **No leftover gate:** a stale `wg-easy` container is not detected. The
    operator reinstalls from scratch, and the migration host had it removed by
    hand.
- **Why:** the peers never change, and wg-easy's layers were the source of
  past failures:
  - in-container `iptables-legacy` needing host modules (DD-10);
  - the IPv6 egress drop (DD-71);
  - the fixed bridge IP;
  - the first-run web setup (DD-12/DD-22).

  The tunnel itself was already the host kernel module; only the management
  layer changes.
- **Why a second Caddy and not the tailnet one:** Caddy refuses to start when
  any listener cannot bind, and the tailnet Caddy binds the Tailscale address.
  One process would take the WireGuard path down whenever Tailscale is down,
  which is exactly when the user wants the backup path.
- **Why no tailnet over WireGuard (the user's call, 2026-09-14):** it would
  need NAT to `tailscale0`, and a lost device would become a tailnet member
  with this node's rights. `ts-forward` already drops new connections into the
  tailnet from other interfaces; `MASTER-FORWARD` is a second layer.
- **Measured on `nrm` (2026-09-14):**
  - The OpenSSL 3.5 X25519 derivation equals `wg pubkey`, and macOS LibreSSL
    3.3.6 cannot derive, so key checks run on the server.
  - wg-easy v15's client template is `Address = <v4>/32, <v6>/128`, `DNS`,
    `MTU`, and `[Peer]
    PublicKey`/`PresharedKey`/`AllowedIPs`/`PersistentKeepalive`/`Endpoint =
    host:port`.
  - `caddy validate` accepts the `Caddyfile.wg` shape, and `caddy adapt` shows
    listeners `10.8.0.1:<port>`.
  - Docker leaves the `FORWARD` policy `ACCEPT` here because forwarding was
    already on.
  - `wireguard-tools` recommends `wireguard-dkms`.
- **Rollback:** the `docker_wg_easy_data` volume is kept. Disabling
  `wg-quick@wg0` and `caddy-wg` and re-running v2-85 brings wg-easy back with
  the same keys.
- **Verified (2026-09-14):**
  - bats 119 ok, with `bash -n` and `shellcheck` clean. The new tests cover
    input parsing in wg-easy's format, thirteen rejection cases that never
    echo a key, `wg0.conf` rendering (public keys only, restart only on
    change, a foreign server key stopping before the file changes), firewall
    rule presence and order, the `MASTER-FORWARD` count and order checks, and
    the `caddy-wg` wiring. Four deliberate mutations each failed their test.
  - **Migration on `nrm`:**
    - The four device profiles were generated from wg-easy's database into
      `kurulum/wireguard/` without printing a key.
    - Each profile's derived public key, PSK and server key matched the
      running wg-easy peers, and the interface key matched `sunucu.key`.
    - `docker rm -f wg-easy` (volume kept).
    - The exported v2-86 `.command` then ran with the operator's own
      `kurulum/` folder, never opened. That night the node had been deleted
      from the tailnet (00:52 CEST); the auth key in the file logged it back
      in during stage 2, and it kept its Tailscale IP.
    - Result: exit 0 in 20 s. `wg0` listened on 61001 with 4 peers, `wg0.conf`
      was `0600` with one `PrivateKey`, and `caddy-wg` listened on the three
      `10.8.0.1` ports. `--check` passed, `MASTER-FORWARD` was first in
      `FORWARD`, the input folder was gone and the log held no key material.
  - **A temporary runtime peer in a network namespace** (`wg set`, never
    written to a file):
    - Allowed: ping `10.8.0.1`; Dozzle 307, Transmission 401 and FileBrowser
      200 on `10.8.0.1`; IPv4 and IPv6 internet egress, seen as the WAN
      addresses.
    - Blocked: SSH to `10.8.0.1` and to the WAN address, WebDAV on the TS IP,
      tailnet Caddy, dnsmasq, the WebDAV container's bridge IP, an online
      tailnet device (reachable from the host itself) and another peer.
    - The peer and the namespace were removed afterwards.
  - **A second run with the same folder:** a full no-op; every account, the
    firewall, WireGuard, dnsmasq, Caddy and `caddy-wg` were unchanged, and no
    container or unit start time moved.
  - **A reboot:** every unit active and none failed, Tailscale online, `wg0`
    with 4 peers, `caddy-wg` on its three ports, `--check` passing with
    `MASTER-FORWARD` first, and the UIs, DNS and WebDAV (401) answering.
  - **A real device** (one of the four migrated profiles, unchanged on the
    device) connected, handshook and opened Dozzle at
    `http://10.8.0.1:61002`, confirmed by the user.
  - **Not verified:** a fresh install on a bare Debian host with these
    inputs.

### DD-121: kurulum.env lists the WireGuard peers; the server generates what is missing and hands it back (2026-09-14)

- **Superseded by DD-124 (2026-09-14):** peers are generated and kept on the
  server and managed with `wireguard.command`; `WG_PEERS` and the fetch-back
  are gone.

- **Decision:**
  - **What the operator writes:** `kurulum.env` names the peers (`WG_PEERS`,
    space-separated) and sets `WG_CLIENT_DNS`, `WG_CLIENT_KEEPALIVE` and
    `WG_CLIENT_DNS_OVERRIDE` (`name=dns; name=dns`) for every profile. Empty
    fields take `defaults.env`: wg-easy's DNS, keepalive 0, `AllowedIPs
    0.0.0.0/0, ::/0`.
  - **What `kurulum/wireguard/` holds:** the keys. A listed peer with a
    `<name>.conf` keeps its private key, PSK and addresses. A listed peer
    without one is new: stage 0 gives it the lowest free host in the `/24` and
    the same number in hex on the `/112` (wg-easy's `.2` ↔ `:2`), and
    `ensure_wireguard` generates its key and PSK with `wg genkey`/`wg genpsk`.
    With no `sunucu.key` and no profiles the server key is generated too; with
    profiles but no `sunucu.key` stage 0 stops, since those profiles only work
    with their own server key. A profile not in `WG_PEERS` is ignored with a
    warning and is never deleted.
  - **Profiles are rendered from the keys plus the env settings** (wg-easy's
    layout, `Endpoint = WG_ENDPOINT_HOST:WG_PUBLIC_PORT`). Every profile that
    is new or differs from the one sent — and a generated `sunucu.key` — is
    written only to `OUTPUT_WG_DIR` on `tmpfs`, and a new peer's QR code is
    printed to the terminal, never the log. `wg0.conf` still holds public keys
    and PSKs only.
  - **The launcher fetches the output after the install session, whatever its
    exit code,** into `kurulum/wireguard/` (`600`), and removes the server
    copy only after every file is in place. Stage 0 of the next run clears any
    output that was never fetched; a peer whose profile was lost is generated
    again.
  - `wireguard/` is optional in the launcher; `sunucu.key` is sent only when
    present.
- **Why:** the user asked to manage peers from the one file: they set a
  keepalive of 21 everywhere and a different DNS on one device, and want to
  add a device by adding a name. The Mac cannot generate a profile: macOS
  LibreSSL cannot derive an X25519 public key (measured for DD-120), and the
  server already has `wireguard-tools`.
- **Why the keys stay in files and not in `kurulum.env`:** a profile is what
  the device imports, and the private keys must survive reinstalls. Keeping
  them per device lets the env stay readable and lets a lost device be
  re-provisioned by deleting its file.
- **Why nothing is deleted automatically:** removing a name from `WG_PEERS`
  removes the peer from the server, but deleting its `.conf` would destroy a
  key that cannot be recovered. The warning names the file.
- **Trade-offs:**
  - A client private key now exists on the server for the length of one run
    (memory and `tmpfs`), as with wg-easy's download; it never reaches the
    disk.
  - The QR code shows a private key on screen.
  - An existing profile's `Endpoint` host is rewritten to `WG_ENDPOINT_HOST`
    (the WAN IPv4).
- **Verified (2026-09-14):**
  - bats 121 ok, with `bash -n` and `shellcheck` clean. The new tests cover
    peer planning (kept vs new, the lowest free address skipping used ones,
    hex IPv6 for host 10, DNS overrides, unlisted profiles, a fresh folder),
    twenty rejection cases for profiles and env fields that never echo a key,
    key generation with only public keys in `wg0.conf`, the hand-back of new
    and changed profiles only (with a generated `sunucu.key` when there was
    none), the QR for new peers only, and the launcher removing the server
    copy only after the files are in place. Three deliberate mutations each
    failed their test.
  - **Live on `nrm`, running the exported v2-87 `.command` with the operator's
    `kurulum/` folder:**
    - The operator added `WG_PEERS` with the four migrated devices plus a
      temporary `deneme`, keepalive 21 and a DNS override on one device.
    - Exit 0. `deneme` got `10.8.0.6` (`:6`), a generated key and PSK, and a
      QR code in the terminal.
    - All five profiles came back into `kurulum/wireguard/` (`600`): the four
      existing ones rewritten with keepalive 21 and their DNS, the override on
      its device only.
    - Each profile's derived public key, PSK, server key and `AllowedIPs`
      matched `wg show wg0 dump`, and the server's output folder was gone.
  - **The fetched `deneme` profile, used as a client in a network namespace:**
    handshook; reached the three UIs and the internet over IPv4 and IPv6; was
    refused SSH, WebDAV on the TS IP and another peer.


### DD-122: container-backup is retired; kurulum/ is the only thing to keep (2026-09-14)

- **Decision:** `container-backup.command`, its worker
  `dev/container-backup-remote.sh`, `docs/container-backup.md` and
  `tests/backup-roundtrip.sh` are removed. A test fails if any of them
  returns. `/backup/` stays Git-ignored so old archives cannot be committed;
  nothing reads them.
- **Why:** since v2-86 the backup had nothing left to carry. It saved one file
  per service (DD-114), and every one of them now comes from the installer:
  the accounts from `kurulum.env` (DD-119), the Transmission preferences from
  the installer (DD-118), and the WireGuard keys and peers from
  `kurulum/wireguard/` (DD-120, DD-121) instead of `wg-easy.db`. A reinstall
  from `kurulum/` produces the same host. The user keeps that folder on the
  workstation and asked for the tool to go.
- **Not doing:** a replacement that archives `kurulum/`. The user keeps the
  folder on the workstation and does not want it copied elsewhere.
- **Supersedes:** DD-112 and DD-114 (the tool they describe no longer exists).

### DD-123: WireGuard changes are applied the kernel WireGuard way, without a restart (2026-09-14)

- **Decision:** when `wg0.conf` changes and `wg-quick@wg0` is running with the
  same `Address` and `MTU`, the installer applies it with `wg syncconf wg0
  <(wg-quick strip wg0)`. That covers adding or removing a peer, a PSK, the
  listen port and the server key. The interface is restarted only when it is
  not running, when `Address` or `MTU` changed (the settings only `wg-quick`
  applies), or when `syncconf` fails. An empty `wg-quick strip` is never
  passed on: syncconf would remove the key and every peer.
- **Why:** this is how kernel WireGuard is meant to be changed, and the user
  asked to follow the native protocol rather than wg-easy. v2-86/87 restarted
  the interface on any change, dropping every connected device and restarting
  `caddy-wg` (`PartOf`) just to add one `[Peer]` block. `syncconf` updates
  only what differs, so existing sessions and handshakes stay up.
- **How the WireGuard model maps (for the record):** the server has one key
  pair. Every device has its own random key pair, unrelated to the server's.
  The device profile carries the server's public key, and the server's
  `wg0.conf` carries one `[Peer]` block per device (its public key, PSK and
  `AllowedIPs`). Adding a device adds such a block; nothing is derived from
  the server's private key.
- **Verified:** bats covers the live path, a no-op, a failed syncconf falling
  back to a restart, an empty strip output never reaching syncconf, and an MTU
  change restarting. Two deliberate mutations each failed the test.
- **Live on `nrm` (v2-88, the operator's folder):**
  - The temporary peer `deneme` was removed from `WG_PEERS`. The run logged
    the change as applied live and the unlisted-profile warning for
    `deneme.conf`, and went from 5 peers to 4, the other four unchanged.
  - `wg-quick@wg0` and `caddy-wg` kept their start times. `master-firewall`
    restarted because the version change rewrote `state.env`, as on every
    version bump.
  - After `deneme.conf` was deleted, a further run reported WireGuard, the
    firewall, dnsmasq, Caddy and `caddy-wg` unchanged.

### DD-124: The server generates and owns WireGuard peers; wireguard.command manages them (2026-09-14)

- **Decision:**
  - `/etc/wireguard/wg0.conf` on the server is the WireGuard source of truth.
    The installer writes only its `[Interface]` part: the server key is
    generated with `wg genkey` when the file is missing and kept afterwards,
    together with every `[Peer]` block.
  - Peers are added and removed on the server by `master-wg`, installed to
    `/usr/local/sbin`. It generates the keys and PSK with the `wg` tools,
    allocates the next address, stores the device profile in
    `/etc/wireguard/clients/` and applies the change with `wg syncconf`
    (DD-123). A failed apply is rolled back, and it shares the installer's
    lock.
  - `wireguard.command`, at the repository root, is the operator's menu: list,
    add (name, DNS, keepalive, MTU), remove, show QR. It calls `master-wg`
    over SSH with `%q`-quoted arguments, prints the QR code and saves the
    profile to `kurulum/wireguard/<name>.conf` (`600`). It reads only
    `SSH_HOST` from `kurulum.env` and refuses a server running another
    version.
  - Removed: `WG_PEERS`, `WG_CLIENT_DNS`, `WG_CLIENT_KEEPALIVE` and
    `WG_CLIENT_DNS_OVERRIDE` in `kurulum.env`; profile parsing, validation and
    regeneration in the installer; sending `kurulum/wireguard` to the server;
    and the launcher's fetch-back. The DNS and keepalive defaults moved to
    `defaults.env` as prompt defaults (keepalive 21, the user's value).
- **Why:** the user wanted peer management to work the way WireGuard is
  administered natively, easy to add and remove, with nothing secret sent to
  the server: "the server generates, we take it". Each device profile carries
  its own DNS, keepalive and MTU, which are client-side settings the server
  never uses. Keeping a workstation folder as the truth (DD-120/121) would
  have made the installer overwrite per-peer choices or require sending keys
  up.
- **Trade-off (accepted by the user):** a reinstall generates a new server key
  and starts with no peers; devices are added again with the menu. The copies
  in `kurulum/wireguard/` are for re-importing on a device, not for rebuilding
  the server. `nrm` is a test host and its old peers were not carried over.
- **Also fixed while testing:**
  - `state.env` now quotes `WG_CLIENT_ALLOWED_IPS`: its space made `source
    state.env` run `::/0` as a command, which would have broken `master-wg`
    and `master-firewall`.
  - `master-wg list` used a helper that overwrote the loop's `line` variable,
    losing the next peer's name.
- **Supersedes:** DD-121, and DD-120's input model (the kernel interface,
  firewall and `caddy-wg` parts of DD-120 stand).
- **Verified:** bats 120 ok, with `bash -n` and `shellcheck` clean. Functional
  tests run the real `master-wg` against PATH stand-ins for `wg`, `wg-quick`,
  `systemctl`, `flock` and `qrencode`. They cover: add (keys generated
  server-side, profile `0600` with the asked DNS/keepalive/MTU, next address,
  live apply), list, profile, QR and version; eight rejected inputs and a
  duplicate that change nothing; removal of exactly one block and reuse of its
  address; rollback of a failed apply; an empty strip never reaching syncconf.
  `ensure_wireguard` is covered for a first install, a re-run that keeps the
  peers byte for byte, a live port change, an MTU restart and a missing server
  key. Three deliberate mutations each failed their test.
- **Live on a freshly reset `nrm` (Debian 13), with the operator's `kurulum/`
  folder:**
  - The exported v2-89 `.command` installed from bare metal: exit 0 in about a
    minute. The auth key logged in to Tailscale, a server key was generated,
    `wg0.conf` held `[Interface]` only (`0600`), `master-wg` answered its
    version, `--check` passed, and neither password nor auth key reached the
    log.
  - `wireguard.command`, driven under `expect`:
    - `test1` with the defaults got `10.8.0.2`: DNS `1.1.1.1,
      2606:4700:4700::1111`, keepalive 21, MTU 1420.
    - `test2` with DNS `9.9.9.9, 149.112.112.112`, keepalive 0 and MTU 1380
      got `10.8.0.3`.
    - Both printed a QR code and saved a `600` profile to
      `kurulum/wireguard/`.
    - A second `test1` was refused. The list showed both; the QR display
      re-fetched a profile.
  - The fetched `test1` profile, used as a client in a network namespace:
    handshook and the list showed its transfer. It reached ping, the three UIs
    and the internet over IPv4 and IPv6, and was refused SSH, WebDAV on the TS
    IP, tailnet Caddy and the other peer.
  - Removing `test2` from the menu deleted its block, its server profile and
    the local copy.
  - A re-run with the same folder restarted no unit and no container and left
    `wg0.conf` byte-identical, with `test1` kept.
  - After a reboot every unit was active and none failed, `test1` was still
    there, `--check` passed with `MASTER-FORWARD` first, and the UIs answered.
  - `test1` was removed at the end: the server has no peers and
    `kurulum/wireguard/` is empty.
- **Real devices (2026-09-14):**
  - The operator added `pppp` (`10.8.0.2`) and this Mac, `mmmm` (`10.8.0.3`),
    from the menu. Both handshook and passed traffic.
  - On the Mac, over the tunnel:
    - Egress used the server's IPv4 and IPv6, and the MTU of 1420 held.
    - DNS did not leak: Tailscale's resolver forwards to the tunnel's `1.1.1.1`.
    - The three UIs answered on `10.8.0.1`.
    - These stayed closed when bound to the tunnel interface: SSH on all three
      addresses, WebDAV, tailnet Caddy, dnsmasq, another tailnet node, the other
      peer and the UIs over IPv6. The `wg0` DROP counters rose.
    - With Tailscale also up, the `*.ayc` names and WebDAV kept working.
  - Speed to public test sites was 120–210 Mbit/s through the tunnel against
    265–407 Mbit/s direct. The server CPU stayed about 97% idle, so the limit
    was the server's path to those sites. The Mac-to-server measurement under
    "Failure tests" below replaces it.
- **Known limit, kept by choice:**
  - `SSH_HOST` points at the server's public IP. While the Mac itself is on
    the full tunnel, that IP is routed into `wg0`, where SSH is dropped, so
    `wireguard.command` times out.
  - The operator switches WireGuard off on the Mac before using the menu.
  - A hint, a Tailscale fallback or SSH over `wg0` were offered and declined.
- **Failure tests on `nrm` (2026-09-14), with this Mac on the tunnel:**
  - Setup:
    - Each disruptive step ran as a transient `systemd-run` script on the
      server, so a lost SSH session could not leave it half done. A Mac loop
      polled `10.8.0.1` and the internet meanwhile.
    - Temporary pieces (a sender on `10.8.0.1:5201-5205`, its `MASTER-INPUT`
      accept rule, the scripts and a safety timer) were removed afterwards, and
      `--check` passed.
  - **Throughput, Mac to server** (zeros, no compression; outside the tunnel
    over SSH on the Mac's physical interface):

    | | Through `wg0` | Outside the tunnel (SSH) |
    |---|---|---|
    | Download, 1 stream | 461–498 Mbit/s | 237–241 Mbit/s |
    | Download, 4 streams | 386–465 Mbit/s | 495–526 Mbit/s |
    | Upload, 1 stream | 48 Mbit/s | 51 Mbit/s |

    - With 4 streams the server was 75–80% idle, with the `wg-crypt-wg0`
      workers spread over all 4 cores. The Mac was only about 40% idle.
    - The ceiling is the Mac's WireGuard client and the home line (about 50
      Mbit/s up), not the server.
    - Public test sites began answering 429 and were dropped as a
      measurement.
  - **`wg-quick@wg0`:**
    - `restart`: `caddy-wg` restarted with it (`PartOf`). Both peers came
      back, `wg0.conf` was unchanged, and `--check` passed. The Mac recovered
      in about 15 s, the WireGuard handshake retry.
    - `stop`: `caddy-wg` stopped with it, and the Mac's internet stopped too:
      the client fails closed.
    - `start`: `caddy-wg` came back through its `WantedBy`, and the Mac
      recovered at once.
  - **`systemctl restart docker`:**
    - Containers were healthy again in 11 s; `caddy-wg` answered 502 in
      between.
    - `master-firewall` re-applied itself (`PartOf`), with `MASTER-FORWARD`
      still first and `DOCKER-USER` jumping to `MASTER-DOCKER`.
    - Transmission's bridge IP moved from `.5` to `.4` (DD-16). Bridge IPs
      were unreachable over WireGuard before and after.
    - The Mac's poll with a 1 s timeout showed scattered timeouts around this
      step, some before the restart. They did not recur: 40/40 polls
      succeeded afterwards and ping loss was 0%.
  - **`tailscaled` stopped for 3 min 37 s:**
    - The WireGuard path held: 109/109 Mac polls got the three UIs and
      internet egress.
    - `caddy-wg`, `wg0`, dnsmasq and Docker stayed active, and the firewall
      rules and `--check` held. `master-firewall` showed inactive through
      `PartOf`, but has no `ExecStop`, so its rules stayed in place.
    - Tailnet names, WebDAV and DNS on the TS IP were unreachable, as
      expected.
    - `tailscaled` came back online in 1 s, and names, WebDAV and DNS
      answered at once. Caddy was not restarted: its sockets on the TS IP
      stayed bound.
    - `master-firewall` re-applied with `MASTER-FORWARD` first, the exit node
      was offered again and no unit failed.
  - **Open:** `pppp` had not handshaken since the `wg0` restart. Its tunnel was
    probably off or the phone asleep; the user checks it on the phone.


### DD-125: A smaller footprint — no Docker recommends, no kept apt downloads, no debian-keyring (2026-09-14)

- **Context:** after a fresh v2-89 install the operator saw disk use grow by
  about 1.7 GB.
  - Measured on `nrm`: 672 MB of new packages, 421 MB of images and a 303 MB
    apt cache holding all 73 downloaded `.deb` files.
  - Of the packages, about 200 MB served nothing in this stack: Docker's
    recommends (`git` with `perl`, `docker-ce-rootless-extras`) and
    `docker-buildx-plugin`.
  - The rest of the gap in the provider panel was freed but untrimmed blocks,
    released by the weekly `fstrim.timer`.
- **Decision:**
  - **Docker:** installed with `--no-install-recommends` as `docker-ce
    docker-ce-cli containerd.io docker-compose-plugin apparmor pigz`.
    - The stack never builds images and never runs rootless, so buildx, git
      and rootless-extras go.
    - Two recommends the runtime uses are named explicitly. `apparmor`
      provides the parser for the `docker-default` profile when the kernel has
      AppArmor on. `pigz` speeds up layer decompression.
  - **apt downloads:** `APT_OPTS` carries `APT::Keep-Downloaded-Packages=false`,
    so every `.deb` the installer downloads is deleted once installed.
    Nothing else in the cache is touched (DD-96), and unattended-upgrades is
    not reconfigured.
  - **debian-keyring:** no longer installed. The Caddy repo is verified by
    its `signed-by` cloudsmith keyring, so the package did nothing. This
    removes the tree's only real `if OS = debian` branch (`caddy-keyring-pkg`
    in the OS-divergence inventory).
  - **Fix found on the way:** `retry` runs a shell function through
    `export -f` and `bash -c`, and arrays do not cross into that child.
    - As a result, `apt_get_install_masked_quiet` (dnsmasq, Caddy) had run
      with an empty `APT_OPTS` since DD-102: no lock timeout, and now no
      download cleanup.
    - The callers now pass `"${APT_OPTS[@]}"` as arguments, and a bats test
      runs the helper under `retry` with a mocked `apt-get`.
- **Not doing:**
  - Switching Docker from the containerd image store back to `overlay2`. It
    would drop about 114 MB of compressed layers, but go against the Docker 29
    default.
  - Removing anything from existing hosts. A re-run installs nothing new and
    removes nothing, so buildx, git or debian-keyring already on a host stay
    until the operator removes them.
- **Trade-off:** `apparmor` and `pigz` become manually installed packages in
  apt's view. Both were already present, from the image or through Docker.
- **Verification:**
  - bats 122 ok. `shellcheck -x` is clean.
  - Deliberate mutations each failed a test: recommends back, the apt option
    dropped, buildx back, a masked-quiet caller without `APT_OPTS`.
  - **Live on `nrm` (Debian 13), with the scratch test inputs and the real
    account files saved and restored:**
    - Fresh-path simulation:
      - `apt-get clean`.
      - Docker, containerd, compose, buildx, rootless-extras, git/perl, pigz,
        Caddy, dnsmasq and debian-keyring purged, `/var/lib/docker` and
        `/var/lib/containerd` removed.
      - The Caddy repo list and keyring deleted.
    - The first v2-90 run stopped at stage 7 on a transient registry error
      (`error from registry: retry-after …`) while pulling. A plain re-run
      finished with exit 0.
      - That run showed the two masked-quiet installs without the options: 4
        `.deb` files left, and apt history lines without `-o`. This led to the
        fix above.
    - After the fix, purged again, one run with exit 0 in 41 s:
      - apt's "Recommended packages" listed rootless-extras, git and buildx as
        not installed.
      - All three apt history lines carried both options, and the cache held
        0 `.deb` files.
      - The cloudsmith InRelease verified with no warning and no
        debian-keyring.
      - Docker 29.8.0 with Compose v5.5.1 and no buildx. The AppArmor
        `docker-default` profile was enforced.
      - All 5 containers were up (the 3 with health checks healthy), and every
        unit was active with none failed.
      - `--check` passed with `MASTER-FORWARD` first. Both WireGuard peers were
        kept.
      - The UIs, tailnet names, DNS and WebDAV answered.
      - The log held no test password.
    - A second run was a full no-op, and its before/after snapshot was
      identical: unit and container start times, `wg0.conf`, both
      Caddyfiles, `compose.yaml` and the cache.
    - `df` used on `/`: 2389 MB with v2-89, 1940 MB with v2-90 (−449 MB).
      `fstrim` then returned freed blocks to the virtual disk.

### DD-126: Negated bats assertions must be able to fail under bash 3.2 (2026-09-14)

- **Context:** the suite runs under macOS `/bin/bash` 3.2 (Bats 1.14.0).
  - A mid-test `! cmd` never fails a test, because errexit ignores negated
    commands.
  - A mid-test `[[ ]]` does not fail under bash 3.2 either.
  - So most negative assertions in `tests/common.bats` checked nothing.
  - The finding and a first conversion came from a separate session on a
    v2-84 base. That work was never merged and is kept on branch
    `wip/bats-negation-v2-84`; v2-91 redoes it on the current tree.
- **Decision:**
  - Every negation is `run !`: 115 statements, 86 simple ones converted
    mechanically and the rest by hand. Pipelines are captured into a variable,
    guarded with `[ -n ]` so an empty awk range cannot pass, and checked with
    `run ! grep … <<<"$var"`.
  - Every `[[ ]]` is `[ ]` or `case`.
  - A guard test fails the suite if a bare `! ` or `[[ ` statement appears
    again.
- **What the now-effective assertions exposed:**
  - **Four tests matched comments or deliberate text** and now look at code
    lines only:
    - the deprecated `--disable-exec` named in a compose comment;
    - `try-restart` in refresh-tailnet-config's DD-72 comment;
    - the old FileBrowser password hints matching the DD-118 comment in
      `install.sh`;
    - `docker rm` / `docker volume rm` in the qBittorrent and Portainer
      `die`/`log` messages, which tell the operator what to run
      (DD-116, DD-117). DD-96's guard wording now says so.
  - **One was real:**
    - `stage_6` still recreated `webdav` when it published
      `${TAILSCALE_IPV4}:${WEBDAV_PORT}`. Only the uncommitted v2-65 working
      tree ever had that layout, so no host needs the step.
    - It is migration cleanup, which DD-96 excludes, and the test forbidding
      it had been silent since v2-67. The block is removed. The user chose
      this (option A).
- **Verification:**
  - bats 123 ok; the same 3 `timeout yok` skips as before.
  - `shellcheck -x` is clean.
  - A diagnostic copy of the suite logged the exit code of every negated
    command: all 144 evaluations returned 1, and none passed on a grep error
    (2).
  - Deliberate mutations each failed their test:
    - a real `docker rm` command;
    - a real `try-restart` line;
    - `--disable-exec` in code;
    - the removed WebDAV log line put back;
    - a code line with the old password hint;
    - a bare `!` assertion.
  - The removed block could only run on the uncommitted v2-65 layout, so no
    live run was needed.

### DD-96: The installer owns its own files and nothing else (2026-08-09)

- **Decision:** All migration cleanup is removed (v2-62). The installer no
  longer deletes `master-webdav.service`, its user, group and downloads ACL,
  no longer runs `apt-get purge rclone` / `apt-get autoremove`, no longer
  removes the `filebrowser` container or the legacy `*_filebrowser_data`
  volumes, and no longer deletes `filebrowser.yaml`, the `watch-tailnet-addr`
  unit, the retired `docker.service.wants` symlink, or `$COMPOSE_DIR/.env`.
  The upgrade path is a fresh install, or a re-run that overwrites the files
  the installer itself renders.
- **Why:** three reasons converged.
  1. **Boundary.** A global `apt-get purge`, an `apt-get autoremove` and a
     `userdel` are host-wide actions taken on the installer's own guess about
     what an older revision left behind. The v2-58 review flagged exactly
     this as cleanup exceeding the stack boundary, and narrowing the scope
     (v2-59, v2-60) treated the symptom, not the cause.
  2. **Idempotency.** `remove_stale_filebrowser` ran unconditionally, so a
     re-run recreated the container every time. Measured on `nrm`: all 16
     managed files byte-identical, Caddy/dnsmasq/Docker untouched, but the
     FileBrowser container id changed and the service blinked for ~2 s. That
     is a re-run changing state for no reason (**R20**).
  3. **Cost.** 83 lines and five bats assertions existed only to migrate
     hosts provisioned by revisions we no longer run.
- **Consequence (accepted):** a host installed by an old revision keeps its
  leftovers. It is not repaired by a re-run; it is reinstalled. Single-host,
  interactive, destructive-by-design — reinstalling is the cheap path.
- **Guard:** a bats test fails the suite if `apt-get purge`, `userdel`,
  `setfacl`, `docker rm`, `docker volume rm` or `disable --now` reappear in
  `install.sh`, so the pattern cannot creep back one convenience at a time.
  - `docker rm` and `docker volume rm` count only as commands the installer
    runs. A leftover gate may name them in a `die` or `log` message for the
    operator to run by hand (DD-116, DD-117).
  - Until v2-91 the negated assertions never failed under macOS bash 3.2
    (DD-126), so the guard was silent.
- **Not doing:** an uninstall command. Removing what v2 installed is a
  separate, explicit operation, not a side effect of installing.

### DD-95: Counting WAN allows, and adopting referenced staging (2026-08-09)

- **Decision (two fixes, v2-61):**
  1. **The WAN allow count must match the list.** DD-94's `check_chain_shape`
     treated only a bare `-j ACCEPT` / `-j RETURN` body as a bypass. An
     interface-qualified pass — `-i eth0 -j ACCEPT` in `MASTER-INPUT`, or
     `-i eth0 -j RETURN` in `MASTER-DOCKER` — was instead recorded as a
     legitimate WAN allow, so it satisfied the ordering rule and passed. So
     did an extra port (`--dport 3306`). Pattern checks find a *missing*
     rule; they structurally cannot find an *extra* one. `check_wan_allow_count`
     now asserts that the number of `-i WAN … -j ACCEPT|RETURN` rules equals
     the length of the allow list (5/2 for INPUT v4/v6, 3/0 for DOCKER),
     and the same list feeds the per-rule `check_rule` calls, so the ports
     are still written once.
  2. **Staging cleanup runs at the end of apply and removes the jump.**
     `activate_named` jumps the staging chain from its parent before the
     rename, so an interruption in that window leaves it *referenced*.
     DD-94's purge skipped referenced chains to avoid deleting a live policy;
     the result was a chain nothing would ever adopt, a permanently failing
     `check_no_staging_artifacts`, a permanently failed unit and a watchdog
     restarting it every 5 minutes with the same outcome. Moving the purge to
     the end of a successful apply removes the dilemma: the final chain is
     already bound to the parent, so any remaining staging artifact is dead
     by definition and its parent jump can go with it.
- **Why:** a second review of v2-60 (2026-08-09). Both are drift the stack
  never produces itself; they matter because `--check` is what the watchdog
  trusts, and a check that cannot see a hole is worse than no check.
- **Boot window (no change, measured):** ~850 ms passes between the WAN
  address becoming usable and the policy landing (eth0 DAD 21:33:42.742 →
  apply finished ~21:33:43.6 on `nrm`). The only WAN listener in that window
  is sshd, which the policy allows anyway; Docker and every published
  container port start ~2 s later, behind the policy. Closing it would mean
  either persisting rules to disk (a second source of policy, against DD-66)
  or ordering the unit before `network-online.target`, which DD-94's live
  WAN detection needs. Accepted and documented instead.
