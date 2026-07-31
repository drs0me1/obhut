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

### DD-10: `wg-easy`'s WireGuard kernel module is loaded independently of Tailscale (2026-07-27)

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
  same Stage 4 block: (1) `/etc/modules-load.d/wg-easy.conf` (content:
  `wireguard`) makes the load persistent across reboots via
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
  WireGuard support at all (module or built-in) — true for a stock Debian
  13 kernel and now functionally verified at install time (not just
  assumed), but the actual target server hasn't been tested by this
  assistant (no access to it). Requires a real functional test after this
  change to confirm end-to-end (wg-easy actually bringing up `wg0`).
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

- **Decision:** `check_compose_runtime()`'s `/setup`-redirect branch (the
  case where wg-easy's admin account hasn't been created yet) sets
  `WG_CONFIGURATION_INVALID=1` but deliberately **not** `runtime_ok=1` —
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
  Anyone extending `check_compose_runtime()` with a new "expected,
  non-actionable" state should follow the same pattern: track it via a
  separate flag consumed by `RECOVERY_FAILED`, not `runtime_ok`.

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

### DD-14: The canonical bundle is published once, atomically, at the end of Stage 6 (2026-07-28)

- **Decision:** Stage 4 writes `/etc/master-stack/state.env` but does not
  publish a canonical copy or a `SHA256SUMS` manifest. The entire
  canonical bundle — `state.env`, `compose.yaml` and the six
  dnsmasq/Caddy files — is published as one atomic set at the end of
  Stage 6.
- **Context:** `SECURITY_REVIEW.md` finding **M8**.
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
- **Alternatives rejected:** deleting Stage 4's manifest write alone (a
  fresh install then has no manifest, and a re-run's stale manifest no
  longer matches the newly written `state.env` — both still fail
  validation); writing the full seven-entry manifest in Stage 4
  (impossible on a fresh install, where those files don't exist yet).
- **Consequence worth knowing:** during Stages 4-6 of a re-run,
  `state_value()` still reads the *previous* run's canonical values. That
  is deliberate — for a half-applied re-run, the last known-good
  configuration is the right thing to enforce.

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
