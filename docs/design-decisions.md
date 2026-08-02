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
admin user to default username and password.` line). There is no config
key for the database path — the image's sample `config.yaml` has none —
so the environment variable is the only surface, and it is already right.
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
> `check_compose_runtime` meant up to four login attempts on a drifted
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
`check_compose_runtime` applies to filebrowser.

**Unplanned benefit.** DD-29 described a deleted policy file as the one state
a re-run could not repair, because Docker recreates the missing bind-mount
source as a *directory*. Reconcile now restores the file within twenty
minutes, long before a container recreate could reach that state. Verified:
file deleted, one reconcile run, file back at `0644 root:root`, container
healthy, `rc 0`.

### DD-33: The default-password probe runs once per cycle, and `429` is reported as unknown (2026-08-02)

**Decision.** The DD-30 check moves out of `check_compose_runtime` into
`report_default_filebrowser_password()`, called exactly once from the main
flow, and grows a `429` branch that says the check could not be performed.

**Why once.** `check_compose_runtime` is called up to four times in a single
cycle — initial detection, the one-second retry, again after a repair, and
once more as the final postcondition. The probe rode along with all four, so
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

If a faster recovery is ever wanted, the place to look is the live
`login-state` health warning in `tailscale status --json`, not the journal.
That was not done here because it would have meant guessing at the field's
shape in the wedged state without a wedged daemon to observe.

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
