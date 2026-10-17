# Retired design decisions

These entries describe removed or replaced behaviour and are kept for history.
They were moved verbatim, in their original order, from
[`../design-decisions.md`](../design-decisions.md), which holds the current
rules; [`../decisions-index.md`](../decisions-index.md) gives each entry's status
and successor. Paths, line numbers and services named here may no longer exist.
Later batches follow, newest first; the entries the rebuild (DD-271 to DD-276)
retired came last, in its phase 6, each ending with the line that retires it.

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

- **Superseded by DD-152 (2026-09-19):** Docker is no longer installed.

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

### DD-63: qBittorrent peer port is TCP+UDP (2026-08-06)

- **Superseded by DD-151 (2026-09-18):** no torrent peer port is opened any
  more; qBittorrent is a host module that only connects out.

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

- **Superseded by DD-152 (2026-09-19):** there is no `MASTER-DOCKER` chain.

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

- **Superseded by DD-152 (2026-09-19):** the share WebDAV is a host service; systemd restarts it.

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

- **Superseded by DD-152 (2026-09-19):** `master-modul` checks the service's command line and sandbox.

- **Decision:** `assert_webdav_readonly_runtime` checks the running
  `webdav` container: `Config.Cmd` contains `--read-only`,
  `HostConfig.ReadonlyRootfs` is true, and the `/downloads` mount has
  `RW=false`. Unauthenticated HTTP PUT is not used as a read-only proof.
- **Why:** A credential-less PUT returns `401` even if the serve were
  writable; that only proved auth. Secrets-free install-time proof belongs
  on Compose/runtime configuration, not on a confused HTTP status set.
- **Still separate:** loopback / Caddy / bare-IP unauthenticated `401`
  checks remain for the auth surface.

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

### DD-78: Caddy WebDAV site aliases the Tailscale IPv4 (2026-08-09) — superseded by DD-98

- **Former decision:** The Caddyfile WebDAV site is
  `http://webdav.${LOCAL_DOMAIN}, http://{$TAILSCALE_IPV4}` → loopback
  rclone (port 80). Compose stays `127.0.0.1` only.
- **Why (then):** Apple TV / tvOS Infuse often cannot use MagicDNS.
- **Superseded (v2-66 / DD-98):** same Caddy ownership, but the Infuse
  address is `${TS_IPV4}:${WEBDAV_PORT}` rather than bare `:80`.

### DD-77: WebDAV runs in Compose on loopback, not as a host unit (2026-08-09)

- **Superseded by DD-152 (2026-09-19):** the share WebDAV runs on the host as `master-paylasim.service`.

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

### DD-97: Prefer upstream stable tracks over patch@digest pins (2026-08-09)

- **Superseded by DD-152 (2026-09-19):** no images remain; rclone is pinned by version and SHA256.

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

### DD-107: Container logs are rotated (2026-09-08)

- **Superseded by DD-152 (2026-09-19):** no containers remain; every module logs to the journal.

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

### DD-110: Daemon config before the daemon; log policy in the service definition (2026-09-11)

- **Superseded by DD-152 (2026-09-19):** Docker and its `daemon.json` are gone.

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

- **Superseded by DD-151 (2026-09-18):** Dozzle was removed; each Konsol
  module card has its own log.

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

- **Superseded by DD-127 (2026-09-14):** the user found Transmission slow and
  went back to qBittorrent, with no installer-written settings or account.

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

- **Transmission part superseded by DD-127 (2026-09-14):** qBittorrent
  returned, and the installer no longer writes torrent preferences. The
  FileBrowser account part stands (now from the input file, DD-119).

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

### DD-127: qBittorrent returns; its settings and account are its own (2026-09-14)

- **Settings part superseded by DD-129 (2026-09-14):** the installer now writes
  qBittorrent's managed settings from a template and the account from
  `TORRENT_USER`/`TORRENT_PASS`. The image choice, ports, the stage 7 `403`
  check and the Transmission gate stand.

- **Context:** the user found Transmission slow again and asked to go back to
  qBittorrent.
  - They were told that the v2-84 preferences carried over from Transmission
    (DHT, PeX and local discovery off, a queue of 12) limit peer discovery
    whatever the client.
  - They chose to keep DHT/PeX/LSD off.
  - Docker against a host package (`qbittorrent-nox` 5.1.0 on Debian 13) was
    weighed. Writing the config is the same work either way (PBKDF2 password,
    qBittorrent rewrites the file on exit), while Docker keeps a current
    version on every OS, logs in Dozzle and one layout. Docker stays.
- **Decision:**
  - `qbittorrent` service, `lscr.io/linuxserver/qbittorrent:latest`
    (measured 5.2.3 with libtorrent 2.0.14):
    - `/config` on `/etc/master-stack/qbittorrent` (`QBITTORRENT_DATA_DIR`),
      and `/downloads`.
    - Web UI `127.0.0.1:61006 → 61006` behind Caddy `torrent.${LOCAL_DOMAIN}`
      and `caddy-wg`. Peer port 61005 TCP+UDP. Stop grace 30 s.
  - **No installer-written settings or account**, at the user's request: they
    set everything in the web UI once. The planned next step (v2-93) pulls the
    whole config file into `kurulum/` and restores it on a fresh install.
    - `ensure_qbittorrent_dir` only creates the directory
      (`0750`, `DOWNLOADS_UID:GID`).
    - The first start prints a temporary `admin` password to the container
      log. The summary points to Dozzle; the installer never reads or logs
      the value.
  - **Ports cannot drift with a restored file:**
    - The image's `svc-qbittorrent/run` passes `--webui-port=${WEBUI_PORT}`
      and `--torrenting-port=${TORRENTING_PORT}` on every start (read from
      the image).
    - `init-qbittorrent-config` copies the default file only when
      `qBittorrent.conf` is absent.
  - **Stage 7:** unauthenticated `GET /api/v2/app/version` through Caddy must
    be `403` (measured: `403`; a wrong login gets `401`).
    - Requests reach the container from the Docker gateway, not localhost.
    - An authentication bypass for localhost or a whitelisted subnet set in
      the UI would therefore let every tailnet or WireGuard client in, and
      the check fails the install.
    - The `docker port qbittorrent` publish checks return.
  - **Input file:**
    - `TRANSMISSION_USER`/`TRANSMISSION_PASS` are removed.
    - `read_input_file` takes an optional list of removed keys and names them
      ("artık kullanılmıyor; bu satırı silin") instead of "unknown field". The
      value is still never echoed.
  - **Leftover gate:** a `transmission` container stops stage 0 before any
    change (it holds the peer port) and prints `docker rm -f transmission`.
    Its directories are not removed (DD-96).
- **Verification:**
  - bats 123 ok (3 skips as before). `shellcheck -x` is clean.
  - Five mutations each failed a test: stage 7 expecting `401`, `WEBUI_PORT`
    dropped, the removed-key message dropped, the gate on `qbittorrent`, and
    a settings write in `ensure_qbittorrent_dir`.
  - **A throwaway container on `nrm`** confirmed:
    - the config paths (`qBittorrent.conf`, `categories.json`,
      `watched_folders.json`, `rss/feeds.json`);
    - the temporary password line in the log (value not printed);
    - `GET /` 200, API 403, wrong login 401;
    - stop in 3 s with exit 0.
  - **Live on `nrm`:** the host held the operator's own v2-90 manual install
    (Tailscale node `nrm-1`, `100.85.4.106`, WireGuard peer `iph0`). The run
    used the scratch test inputs, with the real account files saved and
    restored.
    - The old input file with `TRANSMISSION_*` stopped at stage 0 with
      "satır 37: TRANSMISSION_USER artık kullanılmıyor", changing nothing.
    - With the lines deleted, the Transmission gate stopped at stage 0 and
      the host stayed on v2-90.
    - After `docker rm -f transmission`, the install exited 0 in 22 s:
      - `qbittorrent` was up with 61005 TCP/UDP on `0.0.0.0` and 61006 on
        loopback, and the log held a temporary password line.
      - Through Caddy, `torrent.ayc` answered 200, the API 403 and a wrong
        login 401; `10.8.0.1:61006` answered 200 and 403.
      - 61005/tcp was reachable from the Internet, `--check` passed, no unit
        had failed, and `iph0` was kept.
    - A re-run was a no-op: unit and container start times, `wg0.conf`, both
      Caddyfiles and `compose.yaml` were unchanged.
    - The real WebDAV, Dozzle and FileBrowser files were restored
      hash-identical.
    - The old `/etc/master-stack/transmission{,-auth}` directories remain
      for the operator to delete.

### DD-128: Pulled WireGuard and qBittorrent settings rebuild a server; restored only where absent (2026-09-14)

- **First real rebuild (v2-95, 2026-09-14, by the operator):** `nrm` was reset
  to a bare Debian 13 and the v2-95 `.command` ran with the operator's own
  `kurulum/`, which held the backup from option 6.
  - The install log recorded the accounts written and the qBittorrent file
    created from the template (DD-129).
  - It also recorded "WireGuard kurulum/wireguard'tan geri yüklendi: sunucu
    anahtarı, 4 peer, 4 profil", the login check, "Temel doğrulamalar geçti",
    and no hash or auth-key trace.
  - Checked read-only afterwards:
    - every unit was active with none failed, `--check` passed with
      `MASTER-FORWARD` first, and all 5 containers were up;
    - Tailscale came back as `nrm` on a new IP (100.102.206.71), exit node
      offered and `ayc` split DNS already repointed by the operator;
    - the tailnet UIs, WebDAV `401`, qBittorrent API `403` and DNS/`REFUSED`
      all held.
  - Two devices (`Mcp0`, `NxiPh0`) reconnected with untouched profiles; the
    other two had not come online yet.
  - The server's `wg0.conf` and profiles still hashed identical to the Mac
    backup, and no `RESTORE_DIR` was left.
- **Tool merged (v2-95, 2026-09-14):** `ayarlar.command` is gone. The same pull
  is option 6 "Yedek al" of `wireguard.command`, reusing its SSH connection
  and version check. `remote()` now runs `ssh -n`: a live test showed that an
  ssh reading stdin could swallow queued menu input. The installer and
  launcher only changed their wording.
- **qBittorrent part removed by DD-129 (2026-09-14):** qBittorrent is no longer
  pulled or restored. `ayarlar.command` pulls WireGuard only and deletes a
  `kurulum/qbittorrent/` copy left by v2-93. Stage 0 now rejects a
  `qbittorrent/` file, and the WireGuard part stands.

- **Context:** the user wants a reset server back in one pass, with the same
  WireGuard devices working and qBittorrent configured as they left it.
  - v2-92 deliberately writes no qBittorrent settings: the operator sets them
    once in the UI.
  - DD-124 made a reinstall generate a new WireGuard key.
  - The user proposed pulling both from the server into `kurulum/` and having
    the installer put them back.
- **Decision:**
  - **`ayarlar.command`** (repository root, macOS `/bin/bash` 3.2, reads only
    `SSH_HOST`):
    - One SSH call runs a server-side script. It needs `state.env`, lists only
      `wg0.conf`, `clients/*.conf` and qBittorrent's `qBittorrent.conf`, and
      streams them as a tar relative to `/`.
    - qBittorrent's `categories.json`, `watched_folders.json` and
      `rss/feeds.json` are not pulled: the user changes only the settings
      file. The stage 0 whitelist rejects them.
    - The Mac extracts into a temporary directory inside `kurulum/`, then
      places `wireguard/sunucu/wg0.conf`, `wireguard/<name>.conf` (mirrored:
      a local profile the server no longer has is removed) and
      `qbittorrent/qBittorrent.conf`, all `600` in `700` directories.
    - It prints per file only "değişti/aynı/silindi", plus the peer count, and
      warns if qBittorrent has no password yet.
  - **Launcher:** sends those files with `kurulum.env` when present.
    - Profile names are filtered, and profiles go only with a server
      `wg0.conf`.
    - Each file must be mode `600`.
    - The confirmation summary shows what was sent.
    - Its exit cleanup also removes `RESTORE_DIR`.
  - **Stage 0:** moves `wireguard/` and `qbittorrent/` into the root-only
    `RESTORE_DIR` (`/run`) before the input directory is deleted, then
    validates before any change:
    - Only the names above are allowed, each at most `SNAPSHOT_MAX_BYTES`
      (1 MiB), with no links or special files.
    - `wg_snapshot_check` accepts in `wg0.conf` only what master-stack
      writes:
      - `[Interface]`: `Address`, `ListenPort`, `MTU`, `PrivateKey`.
      - `[Peer]`: `PublicKey`, `PresharedKey`, `AllowedIPs` inside the
        WireGuard `/24` and `/112` as `/32` and `/128`.
      - Peer names must be valid and unique, and public keys unique.
    - Profiles may hold `PrivateKey`/`Address`/`MTU`/`DNS` and one `[Peer]`
      with `PublicKey`/`PresharedKey`/`AllowedIPs`/`PersistentKeepalive`/
      `Endpoint`.
    - Keys are checked by length and alphabet; mawk has no `{n}` intervals.
    - Messages name the line and field, never a key.
  - **Stage 4 / stage 5:** qBittorrent's files are placed only when
    `qBittorrent.conf` is absent, and `wg0.conf` and the profiles only when
    `wg0.conf` is absent.
    - A running qBittorrent is stopped first, because it rewrites its file
      on exit.
    - Profiles whose `Endpoint` is not `${WG_ENDPOINT_HOST}:${WG_PUBLIC_PORT}`
      are counted in a warning.
    - `ensure_wireguard` then keeps the key and peers and rewrites
      `[Interface]` from the installer's values.
  - `RESTORE_DIR` is removed right after stage 5.
- **Why "only where absent":**
  - While a server lives, peers are added with `master-wg` and preferences
    change in the UI. An older snapshot must not undo that.
  - qBittorrent and wg-quick rewrite or compare their own files, so
    enforcing a snapshot on every run would restart services.
  - The rule keeps re-runs no-ops. The operator pulls again after changes.
- **Why validation is strict:** wg-quick runs `PostUp`/`PreUp` lines as root,
  and the file arrives from the workstation. A tampered or hand-edited
  snapshot must stop the install, not execute. qBittorrent's `AutoRun`
  program runs inside the container as the unprivileged user; it is the
  operator's own setting and is not filtered.
- **Trade-off, stated:**
  - `kurulum/` on the Mac now holds the WireGuard server and device private
    keys and qBittorrent's password hash, next to the Tailscale auth key and
    passwords it already held.
  - They stay Git-ignored, `600`, and reach the server only in tmpfs.
  - Protecting that folder (FileVault) is the operator's part.
- **Limits:**
  - A server with a different public IP needs new device profiles; the
    installer warns about this.
  - `ayarlar.command` uses SSH to the public IP, so the Mac must be off its
    own WireGuard tunnel (DD-124's accepted limit).
- **Verification:**
  - bats 128 ok. `shellcheck -x` is clean on install.sh, common.sh and the
    exporter; the launcher and `ayarlar.command` parse under `/bin/bash`.
  - New tests cover:
    - rejection of `PostUp`, out-of-subnet `AllowedIPs`, short keys,
      duplicate or bad names, a missing key, extra `[Peer]` fields,
      `PostDown` and two `[Peer]`s in a profile, with no key echoed;
    - the file whitelist, links, the size limit and profiles dropped without
      a server file;
    - restore versus no-touch, stop/start around the qBittorrent file, bad
      and the Endpoint warning;
    - the stage wiring and `RESTORE_DIR` removal;
    - `ayarlar.command` against a fake server: byte-identical `600` copies,
      a stale profile removed, "aynı" on a second pull, and no key, hash or
      password in the output.
  - Six mutations were each caught.
  - **Live on `nrm`** (the operator's real host: `nrm-1`, peer `iph0`,
    qBittorrent account set), with the scratch inputs. Real account files,
    `/etc/wireguard` and qBittorrent's `/config` were saved and put back:
    - `ayarlar.command` pulled `wg0.conf`, `iph0.conf` and four qBittorrent
      files, all `600`, printing no content. After it was narrowed to
      `qBittorrent.conf` only, a second pull brought exactly `wg0.conf`,
      `iph0.conf` and `qBittorrent.conf`. The restore test was not repeated
      live: the only change removed three optional files from a copy loop,
      and bats covers it.
    - The v2-93 install over the existing v2-92 server reported both
      snapshots "sunucuda var; kullanılmadı". WireGuard, both Caddies,
      qBittorrent and both config files were unchanged, and no restore
      directory was left.
    - **Fresh simulation:** `wg-quick@wg0` was stopped, `wg0.conf`, the
      profiles and qBittorrent's `/config` removed, and the container
      stopped.
      - The install exited 0 in 15 s with both "geri yüklendi" lines.
      - The server public key, `wg0.conf`, the profiles and qBittorrent's
        account lines hashed identical to before.
      - qBittorrent printed no temporary password; the API answered 403 and
        `caddy-wg` was active.
      - The Mac's `iph0` tunnel, never touched, reconnected (handshake 9 s)
        and opened `10.8.0.1:61006`.
    - Afterwards `/etc/wireguard` compared identical to the saved copy, and
      qBittorrent's original `/config` (torrent state included) went back
      while stopped. Only its lockfile and log changed on start. The real
      accounts were restored, and the pulled test copies deleted.

### DD-129: The installer writes qBittorrent's settings from a template and the account from kurulum.env (2026-09-14)

- **Superseded by DD-151 (2026-09-18):** qBittorrent is a host module; its
  settings are seeded once and never rewritten, and the input file holds no
  qBittorrent account.

- **Context:** after DD-128 the user preferred no file pulling for
  qBittorrent: its settings should be part of the installer, the password in
  `kurulum.env`.
  - To take only real changes, qBittorrent was reset on `nrm` and its clean
    file kept. The user then set everything in the UI, and the two files were
    compared.
  - A reset was repeated once when the user picked a wrong option.
- **What the diff showed:** 22 keys in the clean file and 48 after.
  - The user's changes:
    - `Session\MaxActiveDownloads/Torrents/Uploads=12`;
    - `MaxConnections=800`, `MaxConnectionsPerTorrent=220`;
    - `MaxUploads=120`, `MaxUploadsPerTorrent=64`;
    - `Preallocation=true`, `RefreshInterval=600`, `TempPathEnabled=true`;
    - `General\Locale=en`.
  - Written by qBittorrent when options are saved, at their defaults, and not
    managed: `FileLogger\*`, `AutoDeleteAddedTorrentFile`,
    `MailNotification\req_auth`, `WebUI\AuthSubnetWhitelist`, RSS
    `AutoDownloader\*`.
  - DHT, PeX, LSD and anonymous mode stayed at their defaults this time, unlike
    the earlier configuration.
- **Decision:**
  - **`templates/qBittorrent.conf`** holds the managed keys:
    - The clean-file keys the image default provides: `[AutoRun]
      enabled=false`, save/temp paths, `QueueingSystemEnabled`,
      `[LegalNotice] Accepted`, `PortForwardingEnabled=false`, `UPnP=false`,
      `WebUI\Address=*` and `ServerDomains=*`. Without them a fresh file
      would lack what the image would have copied.
    - The user's changes.
    - `WebUI\LocalHostAuth=true` and `WebUI\AuthSubnetWhitelistEnabled=false`,
      so the UI cannot be opened without a login through Caddy.
    - Not managed: ports (`Session\Port`, `WebUI\Port`,
      `Connection\PortRangeMin`: the image passes them on the command line),
      generated values (`Session\SSL\Port`, `MigrationVersion`, `Cookies`)
      and the account lines.
  - **Input:** `TORRENT_USER` (`^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$`) and
    `TORRENT_PASS` (at least `TORRENT_MIN_PASSWORD_LENGTH`, 8), required.
    `python3` joins the base packages.
  - **`sync_qbittorrent_config`** (stage 4, before Compose):
    - Flattens the template, adds `WebUI\Username` and
      `WebUI\Password_PBKDF2`, and compares key by key (INI-aware awk; keys
      contain backslashes and values `=`).
    - No difference: nothing happens.
    - A difference: `docker stop qbittorrent` first, because qBittorrent
      rewrites its file on exit. The merge then sets managed keys in place,
      adds missing ones to their section and missing sections at the end,
      drops a duplicate managed key and keeps every other line. The file is
      written atomically (`0600`, `DOWNLOADS_UID:GID`), and the container
      started again.
    - The log names the changed keys, never a value.
  - **Password hash:** qBittorrent's format `"@ByteArray(salt:key)"`,
    PBKDF2-HMAC-SHA512 with 100000 iterations, a 16-byte salt and a 64-byte
    key.
    - `python3` reads the password from stdin, and the existing hash from the
      environment rather than argv.
    - A new salt every run would be a false change on every run, so the
      existing hash is verified against `TORRENT_PASS` and kept when it
      matches. This is the WebDAV bcrypt pattern.
  - **Stage 7 `qbit_login_check`:**
    - Logs in on loopback with the input account; the body is urlencoded by
      `python3` from stdin and posted with `curl --data @-`.
    - qBittorrent 5.2.3 answers a good login with `204` (measured), so `200`
      or `204` plus a `SID` cookie counts as success.
    - Only "not ready" (`000`/`5xx`) is retried. A refusal stops at once,
      because qBittorrent bans an IP after repeated failures, and every Caddy
      request arrives from the same Docker gateway.
    - It then requires the username and both bypasses off in
      `/api/v2/app/preferences`.
    - `TORRENT_NEW_PASS` is unset afterwards.
  - **Removed:** `restore_qbittorrent_snapshot` and the qBittorrent parts of
    `ayarlar.command`, the launcher and `validate_snapshot` (DD-128).
- **Why this over pulling the file:**
  - The template holds only settings, reviewed in Git, while the file held a
    password hash on the Mac.
  - Password changes follow `kurulum.env` like every other account.
  - A reset server comes up configured without a prior pull.
- **Trade-off:**
  - A managed setting changed in the UI returns to the template on the next
    run. Changing it for good means editing the template.
  - If a future qBittorrent renames a managed key, every run would see a
    difference and restart the client. The log names the key, so this cannot
    go unnoticed.
- **Verification:**
  - bats 132 ok. `shellcheck -x` is clean.
  - New tests cover:
    - the template contents, and the absence of ports, generated keys and the
      account;
    - PBKDF2 format, salt and key length, verify/mismatch/bad-format exit
      codes, fresh salts and a known vector;
    - diff/merge with in-place change, added keys and sections, preserved
      unmanaged lines, `=` in values, duplicate dropping, idempotence and a
      file built from nothing;
    - the sync: write once, no-op, UI-change revert plus a new password with
      stop/start, and no password or hash in the log;
    - the login check: stdin only, no retry on refusal, `204` plus `SID`.
  - Six mutations were each caught (after a duplicate-key fixture was added
    for the merge).
  - **Live on `nrm`** (the operator's host). The real account files and the
    user's own qBittorrent `/config` were saved and put back byte-identical;
    scratch inputs with `TORRENT_USER=admin`:
    - First run over the user's configured qBittorrent: the diff was exactly
      `WebUI\AuthSubnetWhitelistEnabled`, `WebUI\LocalHostAuth` and the two
      account lines, confirming that the template matches the user's
      settings.
      - The login check failed on `HTTP 204`, qBittorrent's success code, and
        was fixed.
      - The Python-generated hash logged in (`204` with a `SID` cookie).
    - Re-run: "şablonla aynı; dokunulmadı". The container start time and the
      file hash were unchanged.
    - A UI change through the API (`max_active_downloads=3`, `dht=false`)
      logged exactly `[BitTorrent] Session\MaxActiveDownloads`. The API
      then showed 12, and `dht` stayed false (unmanaged).
    - A fresh `/config`: "(yeni dosya)", `600 1000:1000`, no temporary
      password. The API showed every template value (12/12/12, 800/220,
      120/64, preallocation, 600 ms, temp path, `en`, queueing, paths, UPnP
      off, ports 61005/61006) and the `403` check held.
    - After `docker restart` made qBittorrent rewrite its file (47 lines),
      the next run was still a no-op.

### DD-176: Local access by default when creating a WireGuard network (2026-09-28; superseded by DD-177)

- **Decision (v2-150):** remove the creation screen's access card, toggle, draft
  state and unused styles. The backend defaults an omitted scope to `ui`; the
  browser submits only port, DNS and label. First and additional networks use
  the same default. Preview and empty-state copy describe Internet + local.
- **Boundary:** Local still means the installed qBittorrent UI at that network's
  own IPv4 address. It never grants SSH, Konsol, WebDAV, DNS, tailnet, cross-network
  or peer access. No new firewall generator or global exception is introduced;
  existing `net-add`/`net-settings` and Caddy/firewall lifecycle remain authoritative.
- Existing network settings retain their Local switch. Explicit API `inet`/`ui`
  and the CLI's required scope remain compatible; invalid explicit scope is not
  silently defaulted. Re-runs never overwrite a saved internet-only choice.
- Existing internet-only networks on nrm may be enabled once through the
  revision-checked settings API, never through an installer migration. Live
  inspection found only wg0, already `ui`, so no existing scope change was needed.
  Keys, peer profiles, DNS, ports and network activity must be preserved.
- Tests cover absent scope, explicit/invalid scopes, request/module gates, first
  and additional network creation, preview, cancelled/failed saves, polling drafts,
  mobile layout and the retained settings switch.

### DD-146: Retire FileBrowser; Konsol is the file manager (2026-09-16)

- **Context:** FileBrowser (classic) was kept beside the console's file
  manager (**DD-139**) because it could still upload, select many items and
  search. **DD-145** added all three to Konsol. The image is maintenance-only
  with an archive risk already recorded in **DD-92**, and it carried its own
  account, port, name, Bolt database and ~150 lines of account code.
- **Decision:** remove it. The input keys, port 61007, the image, the database
  handling and the WireGuard edge entry go; `file.<domain>` keeps resolving and
  redirects to `panel.<domain>` so bookmarks still work.
- **Trade-off, accepted:** FileBrowser was also reachable on a WireGuard network
  with `ui` scope. Konsol is tailnet-only by design (**DD-140**: it manages
  WireGuard itself), so after this change a device that is only on WireGuard
  has no file manager. Exposing the file backend on WireGuard would put the
  account that can create tunnels on that edge; not done.
- **No migration code** (fresh-install rule): a re-run drops the container
  through `docker compose up --remove-orphans`; the old data directory is left
  in place and named in the changelog.

### DD-142: One rclone; the downloads folder is never published (2026-09-16)

- **Context:** with shares working, the user asked to drop the full-folder
  WebDAV and keep a single rclone: "kullanıcı panelden paylaşılacakları seçerek
  ayarlasın, paylaşım için altyapı hazır olsun sadece". They chose to keep the
  share's name and account (`paylas.<domain>`, `SHARE_USER`) and to retire
  `webdav.<domain>`, port 61003 and the `infuse` account.
- **Decision:** the `webdav` service, its name, port, htpasswd and the three
  input keys are removed. What used to be the "share" WebDAV is now simply *the*
  WebDAV: `paylasim`, read-only, rooted at `DOWNLOADS_PATH/.pay/w`.
  - The blast radius of the WebDAV account drops from "every download" to "what
    the operator picked in Konsol", and there is one account, one port and one
    name instead of two of each.
  - `docker compose up -d --remove-orphans` keeps the file the single source of
    truth: the retired container is removed on the next run instead of lingering
    with the old, wide-open root.
  - `unpackerr` still needs the trash and the share folder hidden; the WebDAV
    that needed the same tmpfs is gone with the service.
- **Cost:** devices configured against `webdav.<domain>` must be re-added once
  with the share address and account. Accepted by the user; it is a one-time
  step per device and the reason the whole-folder endpoint existed (Infuse) is
  served by the share.

### DD-141: Share links over one read-only WebDAV, built from symlinks (2026-09-16)

- **Context:** the user asked for a share link for files, served by WebDAV so
  Infuse can open it. Their decision after the design round: **one account for
  everything** — the address, user, password and port stay the same for every
  share, and the duration options (1/7/30 days, open-ended) stay.
- **Decision:**
  - **A second rclone, not the existing WebDAV.** The Infuse WebDAV serves the
    whole downloads folder with the operator's own account; a guest must see
    only what was shared. `paylasim` runs the same image with `--read-only`,
    the downloads folder mounted `:ro`, and its root at
    `DOWNLOADS_PATH/.pay/w`.
  - **Sharing is a symlink, not a copy or a mount.** The panel (uid 1000)
    creates `.pay/w/<name> -> ../../<path>` and rclone follows it with
    `--copy-links`. No data is copied, a file that lands in a shared folder
    later appears by itself, and unsharing is one `unlink`.
    - Per-share bind mounts would need root and mount propagation into the
      container; per-share Docker volumes would mean recreating the container
      for every share, which would give the panel Docker access — that is root.
      The user's own question ("can we add more volumes?") is answered by one
      fixed mount plus links.
    - The registry (`.pay/kayit.json`) lives one level above the served root,
      so it is never served. A link with no registry entry is swept away, and
      so is an expired one; the sweep runs on every listing.
  - **One account, held twice on purpose.** rclone reads a bcrypt htpasswd;
    the console shows and copies the password, so the installer also writes a
    root-only plaintext copy that reaches the file backend as a systemd
    credential. Both come from `kurulum.env` in the same step, so they cannot
    drift. The trade-off is deliberate: the share password protects read access
    to files the operator chose to share, and being able to hand it out (or see
    what it is) is the point of the feature.
  - **What the account holder sees.** Everything currently shared, and nothing
    else: the share root holds only the links. The cost of one account is that
    the password cannot separate one guest from another — stated in the console
    before the share is created.
  - **Hidden from the rest of the stack.** `.pay` is an empty read-only tmpfs
    in `unpackerr` and `webdav` (the trash trick from DD-139), so Infuse does
    not list the same film twice and Unpackerr does not extract an archive a
    second time through a link. The file panel hides `.pay` from listings and
    refuses to walk into it.
- **Second address (v2-107):** Infuse on an Apple TV could not resolve
  `paylas.<domain>` (mobile clients could). The share therefore answers on
  `{$TAILSCALE_IPV4}:{$SHARE_PORT}` as well, exactly as the Infuse WebDAV does
  for the same reason (**DD-98**); the console shows both addresses.
- **Why not Tailscale Funnel or node sharing:** both need changes in the
  Tailscale admin console, which is outside what the installer touches.
- **Known limit:** a malicious symlink *inside* shared content is followed like
  any other (that is what `--copy-links` means); the container only has the
  downloads folder, read-only, so the blast radius is the operator's own
  downloads.
- **Verified (2026-09-16):** bats 154 ok, including the sweep, the refusals
  (root, trash, share folder, escape) and the installer wiring.

### DD-218: qBittorrent's fresh-profile defaults are the user's choice (v2-196)

- **Request (user, 2026-10-04):** after the audit of what the install writes, "qbittorrent için
  düzenlenebilir ayarları listele bir tercihte bulunalım ve default olarak kaydedelim". The list came
  from the shipped qBittorrent 5.2.4 itself (a throwaway, network-less container's
  `/api/v2/app/preferences`). The user chose: no UPnP/NAT-PMP, no LSD, required encryption, anonymous
  mode, 15 active downloads/uploads/torrents, half-finished files in a separate folder, preallocated
  files; seeding unlimited and the English interface (qBittorrent's defaults) were kept.
- **Seed:** `magaza/torrent/qBittorrent.conf` adds exactly `Session\LSDEnabled=false`,
  `[Network] PortForwardingEnabled=false`, `Session\Encryption=1`, `Session\AnonymousModeEnabled=true`,
  `Session\MaxActive{Downloads,Uploads,Torrents}=15`, `Session\TempPathEnabled=true`,
  `Session\TempPath=DOWNLOADS_PATH/incomplete/` and `Session\Preallocation=true`. The key names
  were not assumed: a throwaway container got the values through `setPreferences` and wrote these
  keys itself. The incomplete folder is the package's declared `PAKET_KLASORLER`, already refused by
  shares and reported by `klasorler.py`.
- **Still DD-178's rule otherwise:** the seed is written only into an empty profile; `kur` writes
  only the form's account and folder (and `WebUI\Address`); reapply and reinstall keep every
  preference of an existing profile; the user changes them in qBittorrent, and the defaults test
  proves such a change survives a restart. Existing installs get these defaults only from a fresh
  profile (reinstall with its data removed) or by changing them in qBittorrent.
- **Trade-offs, stated:** required encryption and anonymous mode reduce the number of peers and
  some private trackers refuse anonymous clients; preallocation reserves the full size at the start.
- **Verification:** `tests/torrent-defaults-linux.py` now runs the package's container image (the
  native binary left with DD-209) inside a private network namespace: the chosen values are applied,
  everything else equals the same qBittorrent's defaults, the login gate holds (5.2 answers a good
  login with an empty 204), and user changes persist.
- **Retired (v2-197):** reverted by DD-219 at the user's request; qBittorrent's own defaults apply again.

### DD-250: Favourite folders in Files, kept by the root backend (v2-232)

- **Request (user, 2026-10-07):** "klasörlere bir favoriler tanımı yapalım klasör seçilince alta
  sabitlediğimiz kartta favoriye ekle seçeneği koyalım. favoriye eklenen klasör sağ menüde root yolunun
  üstünde kısayol olarak belirsin"; after a mock-up: "klasör görselinin olduğu yere alalım favoriye ekle
  butonunu, hatta sadece simge olarak yapalım. içi boş ve dolu simge ama temaya uygun renkte olsun".
- **Control:** a star button on the details' folder picture (`.fx-star`, `aria-pressed`, the accent colour;
  hollow adds, filled removes), for a selected folder and for the open folder when nothing is selected.
  Not on a tree's root (Sunucu and Sistem (/) are already places) and not for files or a multi-selection.
- **Places column:** the favourites come first under "Favoriler", above both trees' rows (so above the
  root path in either reading of the request), then a thin separator. Each row: a filled star, the
  folder's name, its parent ("/srv/media", "root · /etc") and a × shown on hover or focus. The automatic
  top-folder list of DD-237 stays as it was.
- **Storage:** on the server, not in the browser, so every device shows the same list:
  `KONSOL_AUTH_DIR/favoriler.json` beside the overview layout (DD-206), through `/api/konsol/favoriler`
  with add/remove operations instead of whole-list writes (two open tabs cannot undo each other). The
  store reads only objects, so the file is `{"favoriler": [...]}`. 20 entries, 1024-byte paths: well
  inside the store's 64 KiB read limit.
- **Channels:** the system view exists only on the tailnet (DD-235), so its favourites are neither listed
  to nor changed from the internet channel; a save from there keeps them.
- **Not done:** no check that the folder still exists (a missing one answers "bulunamadı" and keeps its
  ×), no renaming of a favourite when its folder is renamed or moved, no reordering.
- **Amended (v2-233):** "favori simgesini klasör adının bitişine taşıyalım alt menüde": the star left the
  picture and follows the name inside the title (`h2.fx-titled`: the name in `.fx-title-nm`, cut with an
  ellipsis on a desktop-width screen, then the star), a plain accent-coloured icon button without a badge.
- **Retired (v2-250):** favourites were removed with the old Files window (DD-267);
  `/api/konsol/favoriler` is gone and a re-run deletes `favoriler.json`.

### DD-245: Update control as an icon; Ayarlar → Sistem in three cards (v2-227)

- **Request (user, 2026-10-07):** "güncelle yazısını güncelleme simgesine dönüştürelim", then after
  mock-ups: no words when up to date or when a new version exists, "güncelleme yapılırken aşamayı
  görebilelim"; the health card and "Denetle ve onar" side by side were rejected because the step list
  is long: "panel ve sunucu bilgilerini tek kart ... üstte", Sağlık in one row, "uyumlu bir 3 kart";
  "yerleşik altyapı" removed.
- **Update control:** a 34 px round button with the update icon. Up to date or check failed (warn
  colour): plain; new version: accent with a red dot (`::after`); running: the spinning icon with
  "Güncelleniyor" and the stage. Outside a run there is no visible text and no tooltip; each state's
  sentence is the `aria-label` (version, failure reason, "yalnız Tailscale adresinden").
- **Sistem:** `.server-card` (eight facts in four columns; "Son okuma" is already in the page header)
  ending with the Konsol account (`#konsol-account`, no separate card); `.health-strip` (title, state and
  last check on the left, each check as a coloured dot, name and one-line detail, `auto-fit` columns
  that wrap on narrow screens); `.repair-card` (DD-239's box, steps in three columns, two below
  1100 px, one on phones). The "Yerleşik altyapı" text card is removed.
- **Retired (v2-250):** the old update control and Ayarlar → Sistem went with the old interface
  (DD-267); Sistem → Güncellemeler, Sağlık, Hesap and Sunucu hold them (DD-266).

### DD-244: Files details as one info line with word actions; a "Seç" picking mode (v2-226)

- **Request (user, 2026-10-07):** in the bottom details, the item's description and address "klasör ya da
  dosya simgesi altında tek satır", the actions as words instead of icons ("yeniden adlandır, arşiv
  oluştur, sil gibi"); then "çoklu seçici şeklinde bir seç fonksiyonu ... yükle düğmesi yanında";
  mock-ups were approved.
- **Info line:** under the name one line (`.fx-line`, its full text as the tooltip): type, count or size,
  location, last change, the writing package for a reserved folder and, for a shared folder, its open
  connections with their remaining days ("Paylaşılıyor: Tailscale (6 gün)", else "Paylaşım: <state>")
  or "Paylaşılamaz". The facts list and the share chips (DD-237/243) are gone from the panel; the
  account, addresses and cards stay on Paylaşımlar.
- **Actions:** words; on a desktop-width screen the icon is hidden and the buttons wrap to at most two
  rows on the right (`fit-content(68%)`, smaller type below 1280 px), narrower screens keep icon and
  word. "Adlandır" became "Yeniden adlandır"; a shared folder's Yönet/Kaldır became the actions
  "Paylaşımı yönet"/"Paylaşımı kaldır". Trash stays "Çöpe at" (a delete in the /srv view goes to the
  trash); "Sistem (/)" keeps "Kalıcı sil".
- **Seç:** a toggle (`#fs-pick`, `aria-pressed`) beside Yükle. While on, each item shows a round check
  (drawn with CSS borders: the page's CSP allows no `data:` images), a click on an item or a list row's
  name adds or removes it and never opens it (Shift still selects a range), and "Tümünü seç" is a detail
  action, so the bar never changes width. Seç again, Esc, a click on empty space, "Seçimi bırak" or
  opening another folder ends it and clears the selection.
- **Retired (v2-250):** the old Files window was replaced by Dosyalar (DD-267).

### DD-243: Files as three separate panels; a one-line details panel; no count in the path bar (v2-225)

- **Request (user, 2026-10-07):** "sağda bulunan favoriler ve root panelini yandaki tablodan ayıralım
  arada ufak bir boşluk olsun ve tablo tamamen bağımsız hale gelsin", the fixed details panel "%50
  oranında" lower, separated from the contents by a small gap as its own fixed area, and the item count
  and total size beside the path removed because they resized the screen; a mock-up was approved.
- **Panels (≥ 1101 px):** `.fx` is no longer a glass window but a grid with a 12 px gap; the contents
  (`#fs-body`), the details (`#fs-detail`, 10 px under them) and the places column (`.fx-side`) each
  have their own glass border, radius and shadow. Narrower screens keep the single stacked window.
- **Details (≥ 1101 px):** 82 px, half of DD-237's 164 px, never scrolling: a small icon with the name
  and type/size, a middle column (`.fx-mid`) with the facts on one line or, for a shared folder, the
  location/date and the one-line share, and the actions as 36 px round icon buttons. Each action keeps
  its name as `aria-label` and tooltip (the word is a `.fx-act-label` span, visible on narrow screens).
  "Seçimi bırak" became the last action (it was a link under the buttons). The share line's chips may
  be cut at the panel's edge; Yönet and Kaldır sit outside the chips and are never cut. A shared
  folder's "Paylaşım" fact is dropped; its share line says the same.
- **Path bar:** `#fs-meta` ("N öge · size", "N sonuç", "Yükleniyor…") is gone; it changed the bar's
  width at every folder and search. With nothing selected the details name the open folder's count and
  size (filtered while searching); loading shows the existing progress line.
- **Retired (v2-250):** the old Files window was replaced by Dosyalar (DD-267).

### DD-242: Home widgets in order — Sunucu and Hız side by side, Ağ a 2×1 row below; arrows reorder them (v2-224)

- **Request (user, 2026-10-07):** after mock-ups of a 1×2 network card with direction-aware arrows and
  a free-placement alternative: "1x1 widgetları yan yana alalım önce sunucu sonra hız, ağ kartını 1 kare
  yükseklik 2 kare genişlik olarak yatay uzun olarak altına koyalım oklarla değişim daha mantıklı olsun
  sıralı dursunlar".
- **Block:** the widgets sit in one `.widget-block` over the first two tile columns (the tiles' column
  template is kept, so a 1×1 card is exactly one tile wide). The block fills its two cells per row in
  order: a 1×1 card takes a cell, the 2×1 "Ağ" card a whole row. Phones have two columns, so the block
  looks the same there. Rows are one `--w-row` (150 px) tall; nothing spans two rows any more.
- **Order:** the order of the saved `widgetlar` list, used only when it names every widget; records
  written before this change list some or none (v2-205…209 wrote `[ag]` or `[ag, sunucu]`) and keep
  the default order (Sunucu, Hız, Ağ). The backend is unchanged: it already keeps the list's order.
- **Arrows:** every widget has ◀ ▶ ("öne taşı"/"geriye taşı") beside Gizle in an opaque strip at the
  card's bottom edge, like the tiles' arrows. A step moves the widget one place in the order; the order
  is kept as the block shows it (rows top to bottom, cells left to right), and a step that the block would
  show unchanged (a 2×1 card has no room beside a 1×1 card) goes on until the arrangement changes. A
  button that cannot change anything is disabled: from the default, Sunucu ◀, Hız ▶ and Ağ ▶ are
  disabled and Ağ ◀ takes Ağ above both 1×1 cards in one press. No widget dragging; tiles keep theirs.
- **Ağ (2×1):** one line per application; the title and subtitle share a line so four applications fit
  without scrolling (more scroll inside the card). The column headings stay for screen readers but are
  visually hidden; each total carries the Hız card's download/upload glyph.
- **Narrow cards:** below ~162 px of strip the Gizle/Göster word is dropped (the eye stays, the word
  is the tooltip and the accessible name keeps the widget's name), so the strip never overflows.
- **Rejected:** direction-aware arrows on a 1×2 card (↓ ↑ ← depending on where the widget would land)
  and free placement in empty cells, which would need a new stored position and fall back to order on
  phones anyway.
- **Retired (v2-250):** the home widgets and tiles went with the old interface (DD-267); Genel Bakış
  (DD-261) shows the server, the rates and the applications' totals.

### DD-237: Files details in a fixed panel under the contents; the folder in the address (v2-219)

*(Amended by DD-243: three separate panels, an 82 px one-line details panel, no count in the path bar.)*

- **Request (user, 2026-10-07):** "klasör yolunu ekleyelim" and move the area under Favoriler that opens
  the details and sharing "alta … uzun listelerde karmaşık görülmekte"; mock-up C (a fixed bottom panel,
  a one-line share, a short Favoriler) was approved over B (details pinned at the column's bottom).
- **Panel:** `#fs-detail` moved from the right column into `.fx-main`, under the contents. From 1101 px it
  is a 164 px panel in three columns (icon/name, facts, actions in a 3-wide grid; a share line under
  them). Its height never changes with the selection, so selecting never resizes the contents; what
  does not fit scrolls in the panel. Narrow screens keep it in the flow under the contents.
- **Share line:** `sharesPage.summary()` shows each connection's state and remaining days, the account,
  Yönet and Kaldır. Addresses, copy buttons, permissions and expiry choices stay on Paylaşımlar and in
  Yönet; the access note ("Paylaşmadan önce erişim sınırını…") stays on Paylaşımlar.
- **Favoriler:** the first 8 top folders, plus the one you are in, and "Tümünü göster (N)" /
  "Daha az göster" (not remembered). Konumlar and the disk no longer move out of view.
- **Address:** `#/dosyalar/klasor/<parts>` (`/srv`) and `#/dosyalar/sistem/<parts>`, each part
  URI-encoded. Opening a folder pushes a history entry (`pushState`, no reload, no route run); the
  browser's back/forward and a typed address open the folder in place with its scroll; a reload or a
  bookmark opens it. Bare `#/dosyalar` keeps the folder on screen (the sidebar link) and is rewritten
  with `replaceState`. An undecodable address, `.`/`..` or a part with `/` opens the tree's root; the
  backends still check every path. A failed open rewrites the address back.
- **Retired (v2-250):** the old Files window was replaced by Dosyalar (DD-267); an old
  `#/dosyalar/klasor/…` or `#/dosyalar/sistem/…` address opens the folder in Sunucu klasörleri or Sistem
  dosyaları.

### DD-236: Files navigates like a file manager: a fixed window, only the contents change (v2-218)

- **Request (user, 2026-10-07):** "her klasör tıklamada sayfa yeniden oluşturuyor gibi … pencere ve menü
  davranışını sabit olarak sabitleyelim. klasör tıklamada sadece klasör layout kısmı güncellensin, gerçek
  bir dosya yöneticisi davranışını taklit edelim", after a technical review was approved.
- **Cause:** opening a folder set the listing to null and rebuilt the whole window twice (toolbar,
  search, archive strip, places column, detail), showed "Yükleniyor…" in between and scrolled the
  whole page. v2-216 (held height) and v2-217 (`scrollbar-gutter`) only hid the symptoms.
- **Frame built once:** `renderFs()` builds the toolbar, archive strip and contents box once per tree
  (`/srv` or "Sistem (/)") and afterwards repaints in place: `paintBar()` updates back/forward/up, the
  crumbs, the search text, the view switch and the count; the places column is rebuilt only when its
  entries change, otherwise only the mark moves. The v2-216 held height is gone.
- **Loading:** the listing on screen stays, inert and dimmed after 120 ms, with a thin bar under the
  toolbar; the new path shows at once. Answers for a folder no longer wanted are dropped (token). A
  folder that cannot be opened leaves you where you were (it used to jump to the root).
- **History and cache:** back/forward (buttons, Alt+←/→) within a tree; each folder's scroll is kept
  and restored on back/forward, a new folder starts at its top. The last 20 listings are kept for a
  minute: a cached folder shows at once and is read again behind the scenes; any change (refresh
  after an operation) drops the cache. Switching tree clears history and cache use.
- **Fixed window:** from 1101 px the window has the viewport's height (`fitFs`, CSS `--fx-h`, at
  least 460 px) and the page does not scroll; the contents, the places/detail column and the trash
  or share lists scroll inside it. Phones and narrow windows keep the page scroll.
- **Quiet polling:** an unchanged share list repaints nothing; the 10-second state poll only touches
  counts. Tiles keep their DOM node, focus and hover.
- **Keyboard (contents focused):** arrows move the selection (Shift extends), Enter or Ctrl/⌘+↓
  opens, Backspace or Ctrl/⌘+↑ goes up, Ctrl/⌘+A selects all that may be selected.
- **Not done:** the folder path is not in the browser address (a reload starts at the tree's root);
  that needs the router to treat a Files sub-path as navigation, a separate step.
- **Retired (v2-250):** the old Files window was replaced by Dosyalar (DD-267).

### DD-232: Finder-style Files window and a two-card sidebar (v2-211)

- **Request (user, 2026-10-05):** Files like Finder — icons on the left, a "Dosyalar" menu on the
  right; "alt menüdeki özellikleri … sağdaki menüye taşıyalım ve alt bilgi alanını kaldıralım";
  a multi-selection shown as "tek simge … iki dosya biçiminde"; the sidebar's server resources
  as a separate card under the navigation; "nrm menüsünü değiştirmeyelim" otherwise. Approved
  from mock-ups.
- **Window:** one glass window: contents left, a right column with Favoriler (Sunucu = the files
  root, then the root's folders), Konumlar (Paylaşımlar, Çöp with counts), the detail area and the
  disk. The Files/Paylaşımlar/Çöp tabs and the bottom selection dock (DD-170's dock) are gone;
  every file action lives in the detail area. Under 1100 px the column becomes a strip of places
  above the contents and the detail follows the contents, so share cards and the trash table keep
  the full width; the trash table follows the window's own width (container query).
- **Icons:** folders and file types are inline SVG drawn by `konsol.js` (extension tag, colour per
  kind), no image assets. A shared folder carries a small share badge.
- **Selection:** a click selects one item, a second click (or a double click) opens it once
  (v2-215: a double click is two clicks, so the click after the opening one is ignored and there
  is no separate double-click handler, which opened a folder twice and failed as "bulunamadı");
  Ctrl/Cmd adds, Shift selects a range, Escape or a click on empty space clears. The detail shows the open
  folder (nothing selected), one item with only the actions that apply, or "N öge seçili" with one
  two-document icon and a count badge and six fixed action slots (Arşivi aç and Paylaş disabled).
  Folders a package writes into stay unselectable in the list view, as before.
- **List view:** the previous table stays one click away (▦/☰ in the bar). The choice is the only
  value Files keeps in `localStorage` (`konsol-files-view`): a per-browser convenience, no
  secret, and the page works without it (defaults to icons).
- **Sidebar:** `.side` is a transparent column holding two glass cards, `.side-main` (brand,
  navigation, sign-out) and `.resources` (CPU/RAM/disk); nothing else in it changed.
- **Retired (v2-250):** the old Files window was replaced by Dosyalar (DD-267).

### DD-231: Home widgets in 1×1 and 2×2 cells; live rates split from application traffic (v2-210)

- **Request (user, 2026-10-05):** remove the network chart, keep the numbers; show the overall
  download/upload on one line and the applications below; then, after mock-ups compared on the page
  with four applications: "1x1 sunucu ve anlık ağ kartı, 2x2 uygulama kartı", the 1×1 cards
  stacked to the left of the 2×2 card, the version inside the server card, and
  "hız kartına indirme, yükleme yazıları yerine download-upload simgesi kullanalım".
- **Cells:** `--w-row` (150 px) is one row; `.widgets` keeps the tiles' columns and two rows and
  flows by column, so `sunucu` and `hiz` (1×1) stack in the first column and `ag` (2×2) spans the
  next two columns and both rows. Phones (two columns) flow by row: the two 1×1 cards share a row
  under or above the 2×2 card. Every widget clips to its cell; "Ağ" scrolls its table. Edit
  tools overlay the card instead of growing it.
  - **Amended by DD-242:** Sunucu and Hız share the first row and "Ağ" is a 2×1 row below them, in
    an order the operator changes with ◀ ▶.
- **Hız:** the server's WAN rates with the existing download/upload glyphs in the legend colours;
  each row keeps "İndirme"/"Yükleme" as its accessible name and tooltip. The chart and its code are
  gone (`/api/konsol/ag` still returns its points; nothing reads them).
- **Sunucu:** short labels (TS, WAN, Açık, Sürüm) and the version's last part (`v2-210`, full
  string as the tooltip); the access channel is the subtitle ("Tailscale ile bağlı").
- **Polling:** the network is read while "Hız" or "Ağ" is shown (or in edit mode).
- **Retired (v2-250):** the home widgets and tiles went with the old interface (DD-267); Genel Bakış
  (DD-261) shows the server, the rates and the applications' totals.

### DD-230: Home widgets on the tiles' grid, a "Sunucu" widget and uniform Store cards (v2-208)

- **Request (user, 2026-10-05):** "durdur/başla yerine Dur, Başla yazalım ve puntoyu biraz
  büyütelim", "ana sayfada sunucu kaynakları en alta alalım. ve ip bilgilerinin olduğu bloğu widget
  olarak ağ widget yanına alalım", "caddy sayfasındaki yerel alan adı kartını Adresler ve erişim
  tablosu ile hizalı yapalım", App Store cards narrower and fixed as one standard layout, and the
  network widget narrower, balanced, "altta bulunan iki uygulamanın yatay toplamı ile hizalayalım".
- **One grid:** `.widgets`, `.tiles` and `.store-list` share
  `repeat(auto-fill,minmax(138px,1fr))` (two columns at ≤480 px). A widget spans two columns, so
  the network card is exactly two tiles wide at every width, and Store cards are the same width as
  home tiles (supersedes DD-213's six-slot widget area and the 168 px Store minimum).
- **Sunucu widget:** the sidebar's address block (Tailscale IP, WAN IP, uptime, version, access
  channel) is a second widget (`sunucu`, hideable like `ag`); its values come from the same
  resource/system reads and are painted wherever the widget is shown. The sidebar keeps the
  sign-out button (public channel only) and ends with the resources. The layout backend
  already accepts any widget id; a saved layout without `sunucu` shows it.
- **Network card at two tiles (~270 px content):** its halves stay side by side from 240 px of
  content with a 10 px gutter. Application totals become two-line rows (name across, then
  download and upload with the legend's colour dots) in the same semantic table, so names fit.
- **Tile service word:** "Dur"/"Başla" at 13 px; the accessible name and tooltip keep the full
  verb ("qBittorrent: Durdur").
- **Caddy:** the local-domain card is full width like "Adresler ve erişim"; its input row stays
  at most 620 px wide.
- **Retired (v2-250):** the home widgets and tiles went with the old interface (DD-267); Genel Bakış
  (DD-261) shows the server, the rates and the applications' totals.

### DD-216: Applications open from Ana Menü only; the container page is named Podman (v2-194)

- **Request (user, 2026-10-04):** remove the sidebar's "Kurulu uygulamalar" group: WireGuard and
  qBittorrent must not appear in the sidebar after installation; an application is opened from its
  Ana Menü icon, and a package that gets a home icon gets no sidebar hook. Same request: rename the
  Konteynerler page in the sidebar to Podman.
- **Navigation:** every installed package already has a home tile (DD-212), whose link opens the
  native interface while the app runs and its Konsol page otherwise (DD-210), and whose actions hold
  start/stop, settings and logs. The sidebar entry only duplicated that link, so the shell builds no
  application link at all: `paintNav()`, the `installed-label` span and its styles are gone. Package
  pages are unchanged (DD-200): created from `konsol.json`, reached at `#/<rota>` from the tile, the
  App Store "Aç" and bookmarks. While one is open, Ana Menü stays marked as the current section.
- **Podman page:** the sidebar entry, page title and the detail page's way back read "Podman"; the
  list's eyebrow says "Konteynerler · bu sunucu" and the resource tab keeps "Konteynerler". The route
  stays `#/konteynerler`, so bookmarks and the Settings redirect keep working. The installer summary
  points to "Konsol → Podman".
- **Cold load (fix):** an App Store row's name and icon come from the module catalogue. When the
  container list answered first, the row showed the internal package id ("torrent") until the next
  ten-second refresh. The page now repaints when the catalogue arrives (no extra list read), and
  before that it shows the container's own name, never the package id.
- **Retired (v2-250):** Ana Menü, the sidebar entries and the Podman page went with the old interface
  (DD-267); applications open from Genel Bakış and Uygulamalar, Podman's resources are in Gelişmiş →
  Podman (DD-266).

### DD-213: Compact Ana Menü, five-second refresh and direct container actions (v2-192)

- **Request (2026-10-04):** refine the installed v191 presentation without changing
  the underlying service configuration or control authority.
- **Space:** six desktop widget slots; network spans two. At narrower widths the grid
  becomes four, then two slots. The network chart and borderless totals table retain
  fixed, equal-height areas and internal scrolling. Saved network widths normalize
  to two; visibility and application order keep the existing layout schema.
- **Applications:** home cards are approximately 16% narrower at desktop sizes, with
  the same 193 px normal height and 44 px action targets. Bare icons are ordered
  start/stop → settings → logs; unsupported slots stay blank. Store cards show no
  subtitle; full descriptions remain in Details.
- **Header and updates:** Ana Menü labels the sidebar entry; the compatible route
  remains `#/genel`. Clock/date replace its heading and no longer appear in the
  sidebar. Home has one five-second resources/modules/network tick, no manual Refresh
  and no overlapping ten-second home tick. Other pages retain ten-second polling;
  hidden tabs pause periodic reads and active installation progress keeps its own poll.
- **Containers:** name only, status/resources/access and three icon controls ordered
  start/stop → edit → remove. Remove the owner column and overflow menu from the list.
  Ownership still controls permissions, unsupported actions remain disabled, and
  details retain image information and additional operations. Existing confirmation,
  package lifecycle, stopped-save behavior and data-retention semantics are unchanged.
- **Scope:** frontend presentation only; cumulative traffic sources, authentication,
  firewall and backend APIs are unchanged. Local browser and source checks are recorded
  in `SESSION.md`; the portable installer is exported in the repo, not deployed.
- **Retired (v2-250):** Ana Menü and the old Podman page went with the old interface (DD-267). The
  ownership rules behind the container actions are DD-211's; the new interface puts the actions on
  Uygulamalar and the application's page (DD-261, DD-266).

### DD-204: CasaOS-inspired skin and an overview page for Konsol (v2-178)

- **Scope (user, 2026-10-02: "casaos yapısına internetten bak … panel yapısını tema olarak
  casaos temasına uydurabilir miyiz", then "tasarım çok güzel olmuş uygulayalım" on the
  frozen mockup `docs/design/konsol-casa-v01.html`):** Konsol takes the look of CasaOS — a
  wallpaper behind translucent, blurred ("glass") surfaces, rounded application tiles with
  big tinted icons, an overview with widgets — while keeping its own navigation model.
  CasaOS (studied from casaos.zimaspace.com, the `CasaOS-UI` Vue source and its published
  screenshots; the public demo needs a login the assistant does not enter) is a single
  launcher page: a top bar with account/settings/terminal menus, a widget column, a search
  box and an icon grid; Files and the App Store open as modals. Konsol has deep pages (five
  Settings tabs, package pages), so the sidebar stays and the launcher idea becomes a new
  landing page. This is option C of the analysis: A (theme) plus tiles and an overview.
- **Theme (CSS only, `panel.css`).** The Model A override sheet now carries the palette
  (blue-teal accent, blue-grey neutrals, light and dark), the glass tokens (`--glass`,
  `--glass-2`, `--glass-line`, `--glass-shadow`, `--blur`, `--radius`) and the wallpaper
  colours (`--sky1/2`, `--m1…4`). `index.html` paints the wallpaper with a fixed `.wall`
  (gradient + inline SVG ridges, `fill="url(#…)"` as an attribute) behind a transparent body;
  no external asset, so the CSP (`img-src 'self'`, `style-src 'self'`) is untouched. Sidebar,
  cards, tables, dialogs, rails and store entries are glass; buttons are pills.
  `prefers-reduced-transparency` and engines without `backdrop-filter` get opaque surfaces
  and no wallpaper. The Files panel is translucent without blur on purpose: a
  `backdrop-filter` there would become the containing block of the fixed selection dock
  (found by `files-ui.cjs`). Eyebrows stay untransformed (Model A).
- **Overview (`genel`, the landing page).** A shell route like Dosyalar/App Store/Ayarlar:
  two widgets — clock with host/OS/kernel/uptime, and system status with CPU/RAM rings, a
  storage pie (used share of the data disk, warn colour from 90 %) and the health checks'
  pill (v2-178 also had a storage card with the disk bar and a CPU-history sparkline; the
  user dropped both in v2-179 — the sidebar already carries the figures; v2-182 removed the
  health-check lines from the card and enlarged the three charts to fill it, the pill alone
  carries the verdict and Ayarlar → Sistem → Sağlık has the texts) — and the tiles: Dosyalar, every installed application (name,
  icon and tone from its `konsol.json`, state as text and dot, link to its page), Paylaşımlar,
  App Store (installed/installable counts) and Ayarlar. Everything comes from the existing
  endpoints (`kaynaklar`, `saglik`, `/api/state`, `paylasim`, `moduller`); the page computes
  nothing and polls only while shown. SVG rings and the pie are built from templates like
  the icons (no namespace URL literal, no inline style). An unknown route opens the overview;
  DD-160 made Dosyalar the landing page and Model A removed the old overview — this brings a
  smaller, data-driven one back by the user's choice.
- **App Store as tiles.** The rows keep their markup, ids, buttons, progress lines and the
  details panel (`panel-ui.cjs` still drives them); only CSS lays them out as tiles with the
  same icon shape as the overview. The compact-row height check became a tile check.
- **Not done, deliberately:** no theme/wallpaper switch in production (the mockup's demo
  controls were for evaluation; the system colour scheme decides), no operator wallpaper
  upload (needs a backend and storage), no CasaOS artwork or icons.
- **Retired (v2-250):** the old interface, its skin and its overview were removed (DD-267); Genel Bakış
  (DD-261) is the landing page.

### DD-183: No archive jobs page; results in Günlük, running job as a bar (v2-157)

- **Request:** remove the "Arşiv işleri" tab from Files: if the job states are in
  the log, a separate page is not needed.
- **Finding:** the log held only the start, as an opaque job id, and never the
  result; the page was also the only place for progress and cancel, and
  starting a job navigated to it.
- **Decision (user chose "Günlük + ince çubuk"):** the Files backend audits the
  start (`arsiv-olustur`/`arsiv-ac`, "sources → result name"), the cancel
  request (`arsiv-iptal`) and, from the job worker, the result (`arsiv-sonuc`,
  client "-", ok for done/skipped/cancelled, hata for failed/interrupted,
  including jobs found interrupted at startup). Konsol shows a one-line bar
  above the Files list only while a job is queued/running, with "İptal et";
  completion keeps the existing toast and list refresh. The "Sonucu göster"
  button went with the page. API and private history are unchanged.
- **Retired (v2-250):** Konsol's archive jobs were removed (DD-267); the `arsiv-*` audit lines are no
  longer written.

### DD-170: Contextual Files dock and automatic archive extraction (2026-09-28)

- **Decision (v2-143):** keep the address/search bar stable and show selected-file
  actions in a bottom dock, confined to Files. Reserve scroll space for the last
  row and wrap controls on mobile. Other pages never retain the dock.
- One archive vocabulary: creation always ZIP; extraction resolves supported
  RAR volumes and nested ZIP/RAR automatically. Default destination comes from
  `DOWNLOADS_SUBDIR` via file state, not the current source or torrent save path.
  Browse existing directories with the gated file API; failed/stale picker reads
  cannot select an unverified folder. Submit failures retain the form draft.
- Hide nested/depth controls and verbose explanations/statistics, not server
  protections. Keep shared byte/entry/time/depth limits, cancellation, safe paths,
  private staging and atomic no-replace publication. Automatic depth overflow
  fails the whole job; explicit legacy depth requests keep their earlier contract.
- Preserve original archives and per-archive output directories; assembling
  multipart contents does not mean flattening paths or overwriting same-name data.
- **Visual follow-up (v2-144):** implement approved alternative B: six equal
  icon-over-label cells, count and dismiss in a separate header, compact floating
  surface and a mobile 3×2 grid. Keep ineligible actions disabled in fixed slots
  so selection changes do not shift targets. Trash uses red ink, not a filled
  button; global keyboard focus and existing action/confirmation guards remain.
  No API, archive-worker, permission or sharing behavior changes.
- **Retired (v2-250):** the Files dock and Konsol's archive jobs were removed (DD-267); Gezgin opens and
  creates archives.

### DD-166: Bounded multipart and nested RAR in Files (2026-09-28)

- **Need:** downloaded multipart RAR and inner RAR sets must open through the
  same Files workflow as ZIP, without deleting seeding/source files.
- **Decision:** install distribution `unrar` + `python3-rarfile` as base
  dependencies. Full unrar supports solid/RAR3/RAR5/volumes consistently;
  unrar-free/libarchive is not an equivalent backend. When apt has no candidate,
  add a dedicated signed Debian non-free or Ubuntu universe/multiverse source,
  including updates/security and Ubuntu ports for non-x86. Preserve other sources.
  The package carries the distro's non-free unrar license; no arbitrary binary,
  pip install or root extraction endpoint is introduced.
- **Boundary:** the existing unprivileged worker owns all destination writes.
  Copy descriptor-validated source volumes into bounded private staging, inspect
  metadata in a resource-limited child, then stream each member using `unrar p`.
  Never use extractor-controlled output paths. Bound time/output/memory, kill
  and reap the whole helper process group on cancel/error; reject links, duplicate
  or ambiguous names, encrypted/invalid archives, missing parts and changed sources.
  Preserve atomic publication and the existing aggregate ZIP byte/entry/layer limits.
- **Compatibility:** keep API operation `unzip` for both formats; label it
  “Arşivi aç”. Normalize later-part selection to the first, deduplicate nested
  volume sets and retain every source and inner archive. Compression still creates ZIP.
  Solid archives may re-decompress earlier members per streamed file; time limits
  deliberately win over unlimited CPU for pathological inputs.
- **Evidence:** `test_rar.py` covers volume selection, traversal/link/duplicate
  boundaries, budgets, CRC/source mutation, mixed nesting and real subprocess
  cancellation. Optional upstream fixtures exercise real RAR3/RAR5/solid/volumes;
  current live verification is recorded in `SESSION.md`, not inferred for Ubuntu.
- **Retired (v2-250):** Konsol's archive jobs were removed (DD-267); Gezgin opens and creates archives.
  `unrar` and `python3-rarfile` are no longer installed, and a re-run removes the RAR source file this
  entry added (installed packages stay).

### DD-161: Compact App Store with optional details (2026-09-27)

- **Decision (v2-131):** implement the user's approved second model: a compact
  list, not a grid of large cards. Each row shows icon, name, one-line description,
  live status, Details and Install/Open. A single selected panel below the list
  holds technical information and service/log/removal controls.
- Collapse explanations, not operational feedback. Server progress and failures
  stay visible in rows; mobile keeps both status and controls. Polling retains
  selected details, keyboard focus and log position; unchanged data avoids DOM
  replacement. Log HTTP errors cannot masquerade as successfully fetched logs.
- qBittorrent credentials are requested only from its own page, not by opening
  App Store or expanding technical details. Removal still requires confirmation
  and defaults to retaining profiles; files are not deleted.
- This changes presentation only: no backend/catalogue/dependency, firewall,
  DNS, privilege, CSP or transaction changes. Existing Model A routes remain.
- **Retired (v2-250):** the App Store page went with the old interface (DD-267); the catalogue is in
  Uygulamalar (DD-266).

### DD-269: After the redesign: what only the old interface used is removed (v2-253)

- **Request (user, 2026-10-16):** "Tamamlanan yol haritasına göre tekrar kontrol et. Ölü kod işlevsiz alan
  kalıntı alanları temizle." The redesign is complete (DD-268); the backend, the packages, the installer,
  the tests and the documents still carried code, reply fields and wording only the old interface read.
- **How it was found:** a read-only survey per area (backend, installer and scripts, packages, the Vue
  sources, tests, documents), every claim checked by searching the whole tree for a reader: the Vue
  sources, `obhut`, the packages, the other backends and the tests. A field read only by tests counts as
  unread.
- **Removed from the backend:** the old Settings page's firewall rule groups (`classify_rules`, per-chain
  `iptables -S` reads, six commands on every settings refresh; Erişim's technical rows come from
  `iptables-save`, the check from `master-firewall --check`, DD-155); unread settings-view fields
  (version, domain, addresses, `vpn_installed`, the networks' `server4/6`, the networks' subnets from
  packages); the 12-sample CPU history and the memory graph (`kaynaklar` sends the last CPU sample, `cpu`
  is a number or null); the WAN rate history (`ag` sends the last rate, none older than 120 s, and the
  packages' `{down, up}` only, DD-206); `Modul.runtime`; `GET /api/konsol/konteynerler/gunluk` (an
  application's log is `uygulamalar/gunluk`, DD-266); `master_settings` status `names`/`folders`;
  `master_https` status `wan_ip`/`https_port` (DD-193); the WebDAV row's `mode`/`wan_active` (a share
  walk on every read); the share manager's `pause` action (DD-192); a job label for `uygula`, which never
  runs as a job.
- **Removed from the packages:** qBittorrent's `POST /hesap` and `/dizin` and their worker actions (the
  Ayarlar tab saves through `/ayar`, DD-210), `/durum` down to the form's `username` and `save` (no
  `systemctl` call), `APP_NAME`; the audit template is now `ayar`'s. WireGuard's masked profile preview
  (`?masked=1`, DD-133; the profile is a download or a QR only). The traffic modules' `since`/`at` (one
  `systemctl show` per read for WireGuard). `konsol.json` `ton` (the old tiles' colours) and
  `gunluk_kaynak`.
- **Removed from the installer and scripts:** the always-true full-upgrade switch (DD-228 made it
  unconditional), `master-modul`'s unread `ARACLAR_DEGISTI`, `master-firewall`'s `DEFAULTS_FILE` hook
  nobody sets. Operator messages that named Ayarlar, App Store, Ana Menü, the WireGuard page or the
  archive tool now name Erişim, Uygulamalar, the application's page and the pending-change bar.
- **Documents:** `Data/SESSION.md`, 46 builds behind (it stopped at v2-206), moved verbatim to
  `docs/archive/SESSION-to-v2-206.md`; runs are recorded in CHANGELOG and each DD entry's live check.
  DD-119, superseded by DD-228, moved to the retired entries; DD-154 has a note on what changed since.
- **Removed from the interface:** two functions and two style rules nothing used, comments naming the
  old files. Tests: always-true checks (a `legacy` placeholder, links to `/#/`), the `/yeni` branch and
  unused exports of the harness, the `sayfa` fixture field, a fixture folder nothing read. Four live
  scripts that still asked for `ayarlar/durum` or `/konsol.js` read the current routes and files.
- **Old installs (user, the same day: "Eski kurulumları kaldıralım"):** code kept only for installs from
  before v2-190 goes. The reserved `.pay` name (DD-171, the share tree before v2-145) is no longer hidden in
  Files, WebDAV, qBittorrent, container binds or the permission repair; since that tree may hold old
  account data, stage 0 refuses to install while `SERVER_ROOT/.pay` exists, before anything is written
  (fail closed rather than expose it). The check for the native `qbittorrent-nox@` unit (DD-209), the
  `/data` user area (DD-144), the firewall's default bridge prefix for a state file without
  `KONTEYNER_BRIDGE_PREFIX` (it now stops), the read-only container view and the update-check refusal for
  a state file without `KONTEYNER_STATE_DIR` (DD-211) and the permission helper's private-mode path (only
  the retired archive workspace used it) are removed. The files backend still accepts `--share` for one
  release beside `--archive-dir`, for a unit rendered before the upgrade.
- **Kept on purpose:** the old hash addresses and `/yeni` redirects (bookmarks, DD-267); the one-release
  `--archive-dir` and `--share` shims and the re-run removals of DD-267's leftovers; the files backend's
  `--version`/`--downloads-dir` options and their state fields (removing them needs the script and both
  units to change in one step; a separate change); the schema-3 share registry migration, which the
  current contract still names (DD-192); the three read models' skip of the container inventory when the
  manager's store is not provisioned (they also keep a broken install readable).
- **Amends:** DD-133 (no masked preview), DD-144 (no `/data`), DD-155 (no rule groups), DD-171 (no reserved
  name, an install gate instead), DD-192 (no pause action), DD-193 (no `https_port`), DD-202 (one settings
  route), DD-206 (last rate, totals only), DD-209 (no native-unit check), DD-211 (no view without the
  store), DD-266 (no `konteynerler/gunluk`).
- **Live check (test host, 2026-10-16, v2-253):** the installer with its defaults ran every stage, the
  system upgrade unconditionally; the replies of `kaynaklar`, `ag`, `guvenlik-duvari` (the check and
  111 technical rows), `gelismis`, `erisim`, `yayinlar`, `moduller` and `saglik` had the trimmed shapes,
  `konteynerler/gunluk` answered 404 and an application's log still read. qBittorrent installed from the
  catalogue: `/durum` gave the user name and folder, `/hesap` and `/dizin` 404, `/ayar` saved and wrote the
  `torrent:ayar` journal line, Genel Bakış listed its totals; it was removed with its data afterwards. A
  browser tour of twelve pages had no console error and no 4xx/5xx reply; the backend journal had no
  traceback.
  After the old-install removal, a second run: with an empty `/srv/.pay` stage 0 stopped before any
  write (`state.env` unchanged); without it every stage ran, the files unit passed no `--share`, the
  WebDAV unit hid only the trash and the private state, `master-firewall --check` passed, the container
  routes read the manager's view, and the same route checks and browser tour were clean.
- **Retired by the rebuild (DD-272, v2-255; moved in phase 6):** what it kept on purpose for old installs (the
  `.pay` gate, the `/yeni` and old-address redirects, the `--archive-dir` and `--share` shims, the schema-3
  share migration) went with the 1.x leftovers in DD-272; the removals it made are noted in the entries it
  amended.

### DD-264: Gezgin's WebDAV shares on the Tailscale address (v2-251)

- **Request (user, 2026-10-13):** after a clean install of nrm with the Gezgin package, "paylaşım
  ekranları tasarladığımız gibi değil", then "nrm de geçerli yapıyı kuracak şekilde ayarlama yapalım.
  nrm güncel ve paylaşım için gerekli portları açabilsin".
- **Found:** nrm ran the right image (Gezgin 1.0.0, `77ca4882`, digest pinned by DD-262), its page
  the current one. The package set no `GEZGIN_WEBDAV_PORT` and published only the interface on
  loopback, and Gezgin hides WebDAV without its port: the share window had no "Tür" choice, the share
  settings and information windows held links alone. The same image with the port set shows them.
- **Decision:** `GEZGIN_WEBDAV_PORT=62984` (beside the interface's 62983, DD-219), set inside the
  container and published as `@TAILSCALE_IPV4@:62984:62984/tcp`: Gezgin writes a share's address
  from the name it is opened by and this port (`http://gezgin.<domain>:62984/<hash>/`), so the port
  inside and outside is one. The container guard lets a package's Tailscale publication through
  (DD-217); the tailnet INPUT allowlist (DD-172) stays as it is, since the traffic is forwarded to
  the bridge. The port catalogue names it (`PAKET_PORTLAR`, scope `tailscale`), the hook checks both
  publications, the App Store text names the address.
- **Not on the internet:** Gezgin's WebDAV is plain HTTP; a WAN or public HTTPS route for it is a
  later decision (Gezgin's own HANDOVER keeps the public-address question).
- **The address is the placement's, not the template's:** the installer renders package files in
  stage 2, before it reads the Tailscale address (stage 3), so `__TAILSCALE_IPV4__` would be unset on a
  first install. `master-modul`'s `paket_konteyner_koy` fills `@TAILSCALE_IPV4@` from `state.env`
  (which refresh-tailnet keeps) each time it places a unit, refuses to place one without an address,
  and leaves a unit that did not change as it is. A node that comes back with a new address gets it at
  the package's next start, restart or the installer; nothing rewrites a running unit.
- **Delivered after phase 4b (v2-251):** written on v2-247 and kept on the test host since 2026-10-13, it
  reached `main` after DD-265–DD-267, so its build number is v2-251; Gezgin's quadlet no longer covers
  Konsol's archive folder (DD-267), the rest is as written.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the App Store and the Gezgin package are
  gone, with `master-modul`'s placement fill; Obhut knows no application (DD-271).

### DD-262: Gezgin is an App Store container package (v2-245)

- **Request (user, 2026-10-13):** DD-258's plan ("Gezgin becomes an App Store container package") and
  "faz 2 ye başlayalım o zaman".
- **Package (`magaza/gezgin/`), like qBittorrent (DD-209):** the image `ghcr.io/drs0me1/gezgin` pinned by
  the digest of its 1.0.0 index (amd64 and arm64). Konsol checks the `1.0` tag and moves the pin only on
  the operator's confirmation (DD-214). Its own bridge `gezgin` (DD-217) carries one publication,
  `127.0.0.1:62983` (DD-219: outside Linux's outgoing range, away from the 610xx block), and Caddy serves
  `gezgin.<domain>` on the tailnet. The process runs as the Files account (DD-227) with every capability
  dropped and `no-new-privileges`: Gezgin's image already runs unprivileged and needs none.
- **The user area is one mount:** Gezgin keeps its trash, unfinished uploads and archive jobs in its own
  folders at the root (`.gezgin-cop`, `.gezgin-yukleme`, `.gezgin-arsiv`) and moves items there by
  rename, which fails across bind mounts, so `SERVER_ROOT` is mounted whole at `/srv`. Inside the
  container Konsol's trash (`.cop`) and archive work (`.arsiv`) are covered by an empty, read-only,
  root-owned folder: Gezgin shows two empty folders and cannot write there. The three Gezgin folders
  are the package's declared folders (DD-203): Files does not offer or share them and WebDAV hides them.
- **Application data in `/var/lib/gezgin`** (`database` and `config` belong to the Files account, 0700;
  the folder itself is root's, 0750), not a named volume: removal with data is a plain folder removal.
- **The first administrator comes from the install form (DD-210):** a user name and a password of 12 to
  72 bytes (bcrypt reads at most 72). Python's standard library has no bcrypt and Gezgin's own `hash`
  command takes the password as an argument, so the base's Caddy hashes it from standard input
  (`caddy hash-password`, cost 14); the seed holds only the hash. `kur-uygula` writes the name and the
  hash to `/var/lib/gezgin/ilk.env` (root, 0600), which Podman reads itself (`EnvironmentFile=`, so the
  hash's `$` stays literal). Gezgin's quick setup takes a hash there, never a password, and creates the
  account only while its database is empty. Once the first start is verified (an anonymous API call
  gets 401) the hook empties the file. A database kept from an earlier install keeps its users and the
  form's account is not created; the form says so. Without a form Gezgin would print a random password
  in its log; Konsol's log view masks that line.
- **Verification** (install, start, restart, apply): the unit is active, the process runs as the Files
  account, the mounts are exactly the five above, `/health` answers on loopback, `podman port` lists
  only the loopback publication and nothing listens on the port off loopback; then the tailnet name
  through Caddy and DNS.
- **A same-named container of another manager stops the package:** Quadlet replaces a container of the
  same name, so a Konsol definition called `gezgin`, or a running `gezgin` container of another unit
  (the hand-made setup before this package), must be removed first. Konsol already refuses the name
  for new definitions: a package's container name is reserved.
- **Internet publication (DD-191, DD-199):** Settings → Caddy has a Gezgin row to the loopback port.
  Nothing in Gezgin bypasses its sign-in: user name and password is its only method (a database naming
  another one refuses to start), there is no self sign-up, and failed sign-ins from outside private
  ranges spend a per-address budget. Gezgin takes the client from `X-Forwarded-For` only when the peer
  is private, which the loopback publication's bridge gateway is, and Caddy writes that header. So the
  check (`yayin.py`) has nothing to read while the row is on; turning the row on proves that `/health`
  answers and an anonymous API call is refused.
- **No Konsol page or API:** Gezgin is managed in its own interface, opened in a new tab; Konsol's
  session does not open it. Gezgin's WebDAV shares stay off (no `GEZGIN_WEBDAV_PORT`); Konsol's folder
  WebDAV keeps sharing until DD-258's phase 5. (DD-264 turned Gezgin's WebDAV on, on the Tailscale
  address; DD-268 keeps Konsol's folder shares for good.)
- **Removal:** `kaldir` keeps `/var/lib/gezgin` and the image; with data it removes both (users,
  settings, link shares). The user area and Gezgin's folders in it are never touched.
- **Live check on the test host:** install through the API with the form and sign-in with its account;
  stop, start, restart and the update action through the new action route; the publication probe;
  removal without data, a reinstall with another account (the kept user signs in, the new one does not
  exist) and removal with data.
- **Found by it, for every container package:** right after an install the firewall check called the
  container guard stale. The guard (DD-217) counts only registered packages, and `master-modul kur`
  writes the registry line after the hooks that placed the Quadlet and built the guard; until the
  hourly check or a repair rebuilt it, the new bridge had no rules of its own (for qBittorrent: its
  peer port stayed closed). `cmd_kur` now builds the guard once more after the registry line; a
  failure there is a warning, since the application already runs and the check shows it.
- **Rejected:** mounting only the downloads and media folders (Gezgin's trash and uploads would cross
  mounts); a named Podman volume for the data (removal and backups by name instead of by path); a
  vendored bcrypt in Python; framing Gezgin or a trusted-header sign-in (DD-258).
- **Amended by DD-267 (v2-250):** with Konsol's archive jobs gone the container mounts only the empty
  cover over `.cop` (four mounts in all, which the verification expects exactly), and `paket_gerekli`
  checks only the trash's mount point. The publication row is in Erişim → Adresler.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the App Store and the Gezgin package are
  gone. A file manager is an application like any other, added from its own Compose or Kubernetes file
  (DD-271, DD-274).

### DD-252: Manual Caddy addresses for a loopback port, guarded by the application's own login (v2-235)

- **Request (user, 2026-10-10):** "caddy için local kullanıcı bağlantısı ekleyelim. podman gezgin
  kontainer arayüzü gezgin.<alan adı> olarak bağlayalım", then "kullanıcı caddy manuel adres
  girebilsin". The operator's choices: open on the internet and on Tailscale; the application's own
  login (Konsol's sign-in is not put in front, so its share links keep working); the target only a
  port on this server's loopback.
- **Amends DD-191** ("not a general proxy editor … no arbitrary upstream"): Settings → Caddy now also
  holds addresses the operator enters. Each has a name, a tailnet name (`<local>.<LOCAL_DOMAIN>`,
  never renamed: remove and add again) and an upstream `127.0.0.1:<port>`, plus the usual Tailscale
  and internet switches and HTTPS name. Stored in `SETTINGS_FILE` as `elle` (definitions) and `web`
  (switches), id `elle-<local>`; at most 16.
- **What it writes:** `CADDY_MODULES_DIR/elle-<local>.caddy` (`http://<local>.<LOCAL_DOMAIN>`, Tailscale
  IPv4 via `default_bind`), `elle-<local>-wan.caddy` (the public name on `WAN_IPV4:SHARE_HTTPS_PORT`,
  TLS-ALPN, `X-Forwarded-For` set by Caddy) and one `interface-name` line per open tailnet name in
  `DNSMASQ_CONF_DIR/modul-elle.conf` (under the DNS tab's off switches). The share publisher writes
  the sites with the other projections; Settings writes the DNS file in the same revision-checked
  transaction, snapshots it and restores it on failure. A local-domain change renames both like any
  module file. Public rows count in the shared HTTPS port, its budgets and the WAN firewall line.
- **Limits:** only `127.0.0.1:<port>`; Konsol's own loopback backends (`FILES_PANEL_PORT`, which has
  no login, and `SHARE_PORT`) and every package publication's upstream (qBittorrent keeps its row and
  checks) are refused. The tailnet name may not be one another owner already answers (panel, paylas,
  a package's name, a base/package DNS line or the operator's DNS records). No other host, port range,
  path or Konsol route; no Tunnel or DNS API token; the public DNS A record stays manual.
- **Trade-off (flagged, the operator's choice):** nothing checks the application's login the way
  qBittorrent's row is checked (DD-199): the public name exposes whatever answers on that port, and
  its own password is the only guard. The status line says when nothing answers on the port.
- **Retired by DD-275 (v2-258, the rebuild):** manual `elle-*` addresses are gone; an application port's access row replaces them, with this entry's site and DNS shapes.

### DD-222: A package's unapplied change survives a failed install (v2-200)

- **Finding (nrm, 2026-10-04):** stage 7 re-applied a package only when `MODULES_CHANGED`
  named it, and that list existed only in the running installer's memory. Stage 4 had
  already written the new files to `MODULES_DIR/<id>/`, so after a failure in stage 5
  (`master-firewall`) the next successful run rendered byte-identical files, reported no
  change and never ran `master-modul uygula <id>`. The placed Quadlet/unit stayed old until
  someone ran it by hand. A change to a WebDAV or Files helper had the same gap: its restart
  signal for `master-modul yerlesik` was lost the same way.
- **Decision:** a durable marker per package, `MODULES_PENDING_DIR/<id>`
  (`/etc/master-stack/moduller-bekleyen/`, 0700 root, empty files). `render_package_dir`
  writes it at the first changed or removed file, before the package's remaining files are
  processed. Stage 4 writes `paylasim` when `master_shares.py` or `master_webdav.py` changes,
  and stage 6 writes `dosya` when the Files code or unit changes. `ensure_module_files` puts
  every marked package into `MODULES_CHANGED`, together with changed packages and
  `PAKET_UYGULA_HEP=1` packages. `reapply_modules` removes a marker only after `uygula`
  succeeded, or when the package is not installed (Konsol's `kur` places the current rendered
  files). It also removes the built-ins' markers, because `yerlesik` ran earlier in stage 7
  and stops the install if it fails. A failing `uygula` stays a warning, as before, and
  keeps the marker, so the next run tries again. A marker that cannot be written stops the
  install.
- **Why not `/run`:** `RUNTIME_DIR` is tmpfs; a reboot between the failed and the next run
  would drop the marker and bring the bug back. Why not compare rendered and placed files:
  only the hooks know where each file goes, and the engine stays application-neutral.
  `MODULES_DIR` cannot hold it either: the renderer deletes anything that is not a package
  file.
- **Bounds:** markers stand only for "rendered, not yet applied". They are not a reconcile
  queue. Nothing else reads them, no timer runs, and a marker for a package that was
  removed from the repository is never read. An extra re-apply is harmless (`uygula` is
  idempotent); a missed one is the bug. Hosts that missed a reapply before v2-200 are not
  detected (no migration); run `master-modul uygula <id>` once there.
- **Not covered:** `PANEL_HELPERS_CHANGED` (Konsol backend restart in stage 6) and
  `FIREWALL_NEEDS_RESTART` are in-memory signals of the same kind. They are outside this
  decision.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the store engine, its packages,
  `MODULES_PENDING_DIR`, `ensure_module_files` and `reapply_modules` are gone; Files and WebDAV are installed
  directly by the installer.

### DD-221: The Podman page changes qBittorrent's peer port (v2-199)

- **Request (user, 2026-10-05):** "portların boş olduğunu denetleyen sisteme gerek yok. eş portunu
  Podman sayfasından değiştirme imkânı eklenebilir." Asked how the ports are chosen (fixed numbers in
  `torrent.env`, no decision mechanism), the user declined an install-time free-port search and asked
  for the peer port to be editable like the interface port.
- **Decision:** the package adapter declares `peer_port` next to `listener_port` and `save` (`config`
  and `editable`); the base page shows the field only for an adapter that declares it and still names
  no application. A request without `peer_port` keeps the current one.
- **What moves together** (one transaction under the settings lock: stop → write → daemon-reload →
  guard → start → interface answers; any failure restores every file, reloads, reapplies the guard and
  only then restores the previous service state): both WAN `PublishPort` lines (TCP and UDP) and the image's
  `TORRENTING_PORT` in the rendered and the placed Quadlet, the profile's `Session\Port`, and
  `TORRENT_PEER_PORT` in the durable override (now in `PAKET_AYAR_ANAHTARLAR`), so the installer renders
  the same values and the hook's `podman port` check, Settings' port catalogue and the container guard
  agree. The guard (`master_container_network.py apply`) runs before the start: it reads the placed
  Quadlet, so the new publication is let through and the old one no longer. The main Quadlet is
  patched, not a drop-in: Quadlet merges `PublishPort` lists from drop-ins, and the patched file is
  exactly what the installer writes from the override (the DD-214/DD-217 pattern). `TORRENTING_PORT`
  is patched in the same `Environment=` line, so each value has one place.
- **Checks (the edit's own, before the service stops):** an integer 1024–65535, different from the
  interface port, not another project service's port (base `*_PORT` values, other packages' declared
  ports, saved Konsol container definitions over TCP or UDP), and bindable on the WAN address over
  TCP and UDP (catches a WireGuard network's UDP port or another container's publication). No
  install-time free-port search exists or was added (the user's call). The form recommends
  61000–65535 (outside the ephemeral range, DD-219) but does not enforce it.
- **Consistency:** only a changed peer port is recorded (DD-219's rule) and `kaldir --veri` keeps it
  like the interface port (DD-220). The App Store text no longer names the number, which is rendered at
  install time and would go stale after an edit; the Podman page and Settings show the effective port.
  The Quadlet's comment lines no longer repeat port numbers for the same reason.
- **Limits:** existing peer connections drop with the restart; trackers and the DHT learn the new port
  on the next announce. qBittorrent's own listening-port option is overwritten by `TORRENTING_PORT` at
  every start, so the port is changed here, not in its UI.
- **Amended by DD-267 (v2-250):** the peer port is changed in the adapter card on qBittorrent's Ayarlar
  tab (DD-266) instead of the Podman page; the transaction is unchanged.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package, its adapter and the
  package overrides are gone; an application's ports are its access rows (DD-275).

### DD-220: Removing qBittorrent with its data keeps Konsol's port and image choice (v2-198)

- **Request (user, 2026-10-05):** "öneriyi çalış ve düzeltelim" — the follow-up a multi-agent review
  of v2-197 found and filed as a separate task.
- **Problem:** the package's durable choices (`PAKET_AYAR_ANAHTARLAR`: `TORRENT_UI_PORT` from the
  Podman page, `TORRENT_IMAGE` from an approved update, DD-214) are baked into rendered files by the
  installer: the Quadlet's `PublishPort` loopback line, `WEBUI_PORT` and `Image=`, the manifest's
  `PAKET_IMAJ`, the seed's `WebUI\Port`. `kaldir --veri` deleted the override (and the port drop-in
  `85-konteyner.conf`) but no one re-rendered those files, so a reinstall from App Store before the
  next installer run placed a Quadlet on the chosen port while the hook, Caddy's filter
  (`master_publications.private_site`, override-aware) and the publication expected the package
  default: `torrent_verify` failed and `torrent.<domain>` pointed at the wrong port.
- **Decision:** `--veri` deletes what its dialog names — the profile, the torrent list, the folder
  drop-in and the image — and keeps Konsol's choices: the override and the port drop-in. Every consumer
  then agrees again (rendered files, hook, Caddy filter, publication). The dialog says so. Rejected:
  rewriting the rendered lines back to defaults on `--veri` (a second renderer outside the installer,
  and it would silently downgrade an approved image to the package's older pinned digest).
- **Consequence:** a reinstall after `--veri` uses the chosen port and re-pulls the approved image
  digest. A recorded choice wins over the package's `torrent.env` on every render (`paket_ayar_oku`,
  DD-203/DD-214), so a newer package's `TORRENT_IMAGE` pin or default port does not reach an install
  that has one: the image moves only by another approved update (to the channel's digest), and
  entering the default port on the Podman page records that value as a choice too. There is no
  in-product way back to following the package's values; the manual step is to delete
  `PACKAGE_OVERRIDES_DIR/torrent.env` and `qbittorrent.container.d/85-konteyner.conf` as root and run
  the installer (found by the v2-198 review: the first draft of this entry wrongly promised that a
  newer package version restores the pin).
- Supersedes DD-214's sentence "`kaldir --veri` drops the override with the other package settings".
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package and
  `PACKAGE_OVERRIDES_DIR` are gone; removing an application keeps or deletes its data folder (K9, DD-274).

### DD-219: qBittorrent back to its own defaults; its ports moved to uncommon fixed ports (v2-197)

- **Request (user, 2026-10-04):** "ayar değişikliğini iptal edelim image dosyası varsayılan config
  ayarları ile kurulsun değişikliği geri alalım. arayüz portunu ve peer portlarını değiştirelim. wan
  arayüzden internete açılan portları random taramalardan uzak portlar olarak güncelleyelim." Asked
  to choose, the user picked qBittorrent's own defaults (not the image's `/defaults/qBittorrent.conf`,
  whose `/downloads` paths do not match the same-path mounts; its only other difference is UPnP off),
  kept SSH on 22, left the share HTTP (61010), WireGuard (61001) and Tailscale (41641) ports alone
  ("aralık uzak zaten"), and chose fixed uncommon ports over per-install random ones.
- **Revert:** DD-218 (v2-196) is retired; the seed is again the six integration keys of DD-178 with
  DD-217's `WebUI\Address=*`. A profile seeded by v2-196 keeps its values (fresh-install rule; nrm's
  live profile never received them).
- **Ports:** `TORRENT_UI_PORT=62947` (published on loopback only) and `TORRENT_PEER_PORT=63851` (TCP+UDP
  on the WAN IPv4 address). Both are outside Linux's ephemeral range (32768–60999, so an outgoing
  connection can never hold them first), away from the 610xx block of the other services, and not a
  commonly scanned or registered service port. Everything that names them renders from the package's
  `torrent.env`: Quadlet `PublishPort`/`WEBUI_PORT`/`TORRENTING_PORT`, Caddy upstream, publication
  upstream, the Settings port catalogue, the guard and the hook's checks.
- **Honest limits:** an uncommon port only keeps opportunistic scans of common ports away; full-range
  scanners still find an open TCP port. The peer port is announced to every tracker and peer by
  design, so it cannot be hidden from the swarm. 443 stays (Let's Encrypt TLS-ALPN needs it); UDP
  WireGuard/Tailscale ports do not answer unauthenticated probes.
- **Existing installs:** an installer run re-renders the package and recreates the container on the
  new ports; qBittorrent takes both from its start flags. An operator override of `TORRENT_UI_PORT`
  (Podman page) keeps its value. Before v2-197 every Podman-page save of qBittorrent, even a
  folder-only one, recorded the port shown at the time as such an override, so such an install stays
  on 61006 (loopback only); the manual step is to enter the new port there. Since v2-197 only a
  changed port is recorded.
- **Review fixes (multi-agent review, v2-197):** the App Store text claimed "İnternete eş portu
  açılmaz" since DD-217; it now states the rendered peer port and that it is WAN IPv4 only. Settings'
  port catalogue showed the peer port as an IPv4+IPv6 INPUT permission with a toggle that cannot
  affect a forwarded container publication; package internet ports of a bridge package are now IPv4
  rows marked fixed (no toggle). Stale "host network / outgoing only" statements in the contract
  (R10/R12/R18, §3.1), README, architecture, defaults.env and the Cursor rules were corrected.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package is gone. The port rule
  above (outside Linux's ephemeral range and the 610xx block) now places the applications' loopback pool,
  `UYGULAMA_PORT_ILK`–`UYGULAMA_PORT_SON` in `config/defaults.env`.

### DD-212: Installed application home tiles and one fixed network widget (v2-191)

Presentation amended by DD-213; installed-only tiles and cumulative traffic semantics remain.

- **Request (2026-10-04):** simplify the overview to installed applications and the
  network widget. Dosyalar, Ayarlar and App Store keep their sidebar navigation;
  Paylaşımlar remains a tab inside Dosyalar, not a separate sidebar entry. None has a
  duplicate home card. This changes the overview composition from DD-204 and DD-206
  and extends the DD-210 action row.
- **Stable action positions:** every installed application has three bare-icon slots
  in this order: settings, start/stop, logs. Unsupported slots remain blank and
  non-interactive, so other actions do not move; WireGuard's start/stop slot is empty.
  Keep accessible labels/tooltips, focus, existing settings forms and lifecycle
  confirmation/progress. Logs open a dialog through the existing module journal.
- **Sidebar context:** move clock/date below CPU, memory and disk; retain WAN and
  Tailscale addresses, version and uptime there. Remove the separate home clock/system
  widgets and their unused SVG/CSS. Resource information remains available without
  repeating it in home widgets.
- **Layout compatibility:** `ag` is the only widget, always full width (four columns).
  Keep hide/show, tile reordering and the existing server layout API/schema and safe
  writer. The frontend ignores removed saved widget/tile IDs and normalizes any older
  `ag` width to 4 while retaining its visibility. There is no server data migration
  or per-device layout; new installed tiles follow the saved order as before. On phones
  the edit toolbar stays in normal flow below the tiles, preventing a short viewport
  from covering a card; the desktop toolbar retains its sticky behavior.
- **Network presentation:** equal-width and equal-height sections place live server
  download/upload rates and chart beside a borderless three-column application table:
  icon/name, cumulative download total, cumulative upload total. The table has a
  fixed-height overflow area so more applications do not stretch the widget.
- **Measurement meaning:** the user's clarified contract keeps application `down`/`up`
  counters as cumulative totals formatted in byte units, never bytes/s. Only the server
  rates/chart section shows live speeds. Missing, non-finite or stale measurements stay
  unknown rather than zero, without suppressing other rows or server measurements.
  Existing backend traffic sources and authentication stay unchanged: no new rate
  module or additional qBittorrent login. qBittorrent's existing all-time totals can
  lag between its statistics-file saves; they are not live measurements.
- **Delivery and evidence:** source and repository portable installers are v2-191.
  Per the user's clarified workflow, every version change rebuilds the root and
  `Data/app` installers for the version commit, without a Desktop copy or separate
  snapshot. Local validation is recorded in `SESSION.md`; no live acceptance is claimed.
- **Amended by DD-267 (v2-250):** the home tiles, their action slots, the sidebar context and the layout
  went with the old interface. The measurement meaning holds for Genel Bakış's Ağ card: the
  applications' figures are cumulative totals in bytes; only the server's rates are live speeds.
- **Retired by the rebuild (DD-272, v2-255; moved in phase 6):** the tiles went with the old interface
  (DD-267) and the applications' cumulative totals with the packages' traffic modules (DD-272); Genel Bakış
  shows each application's live rate from its bridge's counters (DD-276).

### DD-210: App Store install form, direct app launch and the tile action row (v2-187…v2-189)

- **Request (user via the project lead, 2026-10-03):** qBittorrent's App Store "Kur" opens a window
  asking for a username, a password and the download folder, and the install uses them; afterwards the
  application's icon on the main menu opens qBittorrent's own web UI, and a small settings icon beneath
  it changes the same three values.
- **Why the install takes the values (instead of the temporary password, DD-151):** with a password
  chosen up front there is no temporary-password step and no window in which the web UI runs with a
  journal password. A "temporary default, patch later" install was rejected: the container would start
  once with credentials the operator did not choose, and a failed patch would leave it that way.
- **Generic, two declarations:** `konsol.json` `form` (generic field types `metin`, `parola`, `klasor`,
  texts, the package API's read and write routes) drives the shell's dialogs; the manifest key
  `PAKET_KUR_AYAR` names the worker that validates the form. The shell, the backend and the engine name
  no application. A package without `PAKET_KUR_AYAR` (WireGuard) installs exactly as before and refuses
  a form.
- **Validation before anything starts:** the backend, under one lock per install, refuses a busy or
  installed package, runs the package worker as a transient root unit with the form on stdin
  (`kur-hazirla`; the same `run_worker` path as every settings write, so the password never reaches
  argv, environment or journal) and spawns `master-modul kur` only after the worker accepted. The worker
  reuses the package's own rules: username pattern, password 8–256 printable characters, the base's
  `safe_dir(writable=True)` user-area policy probed as the downloads user, and the same-path bind-mount
  character check. A refusal is the request's 400; no image is pulled and nothing is written.
- **Seed, not a password, crosses into the engine:** the engine runs detached (`systemd-run`, DD-148), so
  stdin cannot reach it. The worker writes `RUNTIME_DIR/modul-<id>.kur` (tmpfs, 0600, root) with the
  validated username, folder and the password **already hashed** in qBittorrent's PBKDF2 format; no
  plaintext is ever stored. The engine refuses to install such a package without a fresh (≤10 min),
  private, root-owned seed, exposes its path to the hooks as `KUR_TOHUM` and removes it and the hook's
  snapshot on every exit; the backend removes it when the engine could not be started.
- **Before the first start, and reversible:** the hook writes the seed into the new or kept profile
  (`kur-uygula`: only `WebUI\Username`, `WebUI\Password_PBKDF2` and the two save-path keys, plus the
  folder drop-in when outside the downloads tree) after `torrent_profile` and before the quadlet and the
  first `systemctl start`; the image's init copies its defaults only when no profile exists, so the
  values hold. The files as they were are snapshotted next to the seed; every failure path of `kur`
  (`torrent_kur_geri`) stops and removes the unit, then restores the profile and the drop-in
  (`kur-geri`), so a failed reinstall never loses the previous working account, folder, unrelated
  preferences or torrents.
- **Edit:** `POST /api/uygulama/torrent/ayar` takes any of the three fields; the worker validates all of
  them first and makes one stop/write/start (`change()`, DD-165 direct apply with rollback), keeping a
  stopped app stopped. A blank password is simply not sent and the stored hash stays. The dialog reads
  current values from `/durum`, which never carries the hash.
- **Launch:** an app with publication names (`urls`, DD-195/199) opens its web UI in a new tab
  (`noopener noreferrer`) from the tile, the sidebar entry (removed by DD-216) and App Store's "Aç" while it runs — the
  public name on the public HTTPS address, the tailnet name on the tailnet. Stopped, busy or (on the
  public address) unpublished apps open their Konsol page instead; no name is constructed in the page
  and the public address never falls back to a private one. The page remains reachable from App Store
  details and its route, and it keeps its own forms.
- **Stopped apps keep their settings (review fix):** the tile keeps the settings action while the app is
  stopped, so the root backend hands a stopped (`durduruldu`) package's own `/api/uygulama/<id>/*`
  requests to its API module too (`package_api(..., stopped=True)`). For that object `start()` is not run,
  and background callers (`package_apis()`: the sampler, VPN networks) never get it; a state change
  rebuilds the object (stopping a running one). Absent packages still answer 404/409. The qBittorrent page
  reads its status while stopped for the same reason.
- **Dialog ownership (review fix):** the form shares Konsol's one dialog with every other flow. Each call
  puts its content under its own root node and owns the dialog only while that node is the content and
  the dialog has not closed since. A late install or save answer then closes only its own dialog (else it
  only toasts), a late refusal toasts instead of writing into another dialog, and a late settings read
  never replaces a newer dialog; closing still clears the call's password fields and returns focus.
- **Tile action row (v2-188, user: "ana ekran uygulamalarının altında ayarlar, durdur başlat iki seçenek
  olsun"):** v2-187's single settings icon became a compact row beneath the icon of every installed
  App Store application: **Ayarlar** (the declared form; without one, a link to the package's page, so
  WireGuard gets its page) and, only for packages that declare `PAKET_DURDURULABILIR=1`, one
  **Durdur/Başlat** button. WireGuard cannot stop as a whole (its networks switch one by one) and gets no
  invented all-networks switch; built-in navigation tiles get no row. The tile is a container with a
  stretched launch link and the row as a sibling (no nested interactive elements). Durdur asks the App
  Store's own confirmation (`askStop`, the package's stop note); both actions use the same lifecycle
  request and progress (`modStart`), so no backend change. From the click until the server's operation
  ends the button is `aria-disabled` (still focusable, so keyboard focus survives the 1.5 s progress
  redraws) and ignores clicks; its visible label is the short "Duruyor…"/"Başlıyor…" (the narrow tile),
  its accessible name "<app>: Durduruluyor…/Başlatılıyor…". A refused request is a toast and the button
  is usable again; the label follows the server's state when the operation ends. **v2-189** (user: "fon
  rengi olmadan sadece simge"): the controls are bare icons — no visible text, background or border, also
  on hover/press; the name is the `aria-label` and the `title` tooltip, the focus ring stays, the touch area
  is an invisible 44 px pseudo-element. The redraw at the end of a lifecycle request keeps whatever has focus
  by then instead of pulling it back to the tile. Edit mode renders the
  tiles exactly as before (no row, no link). A poll that redraws the tiles keeps keyboard focus on the same
  tile part (`data-act`), and closing the settings dialog returns focus to Ayarlar.
- **Amended by DD-267 (v2-250):** the tiles, their action row, the sidebar launch, App Store's "Aç" and
  the shared-dialog rules went with the old interface; launching and the actions are Uygulamalar' and
  the application page's (DD-261). The install form (`konsol.json` `form`, `PAKET_KUR_AYAR`, the private
  seed) and a stopped package's own API stay: the catalogue in Uygulamalar installs through the same
  `module_install` and the application's Ayarlar tab edits the form (DD-266).
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the App Store, its install forms
  (`konsol.json` `form`, `PAKET_KUR_AYAR`, the private seed) and the packages' APIs are gone; an application's
  settings are its file and its answers in Tanım (K3, DD-274, DD-276).

### DD-209: qBittorrent runs as a Podman container: quadlet, digest-pinned image, host network (v2-186)

- **Request (user, 2026-10-03):** "sunucuda podman üzerinden yüklü qbittorrent ama ekranda ve app
  store içerisinde uygulama gibi görülmesi daha iyi olur" — after the Podman trial
  (DD-208) and having removed the native qBittorrent from Konsol themselves, the qBittorrent that
  runs in Podman should be *the* qBittorrent application. An earlier message had already named
  qBittorrent as the one application worth moving into a container.
- **Decision:** one App Store application `torrent`, now a container. No second "qBittorrent
  (container)" entry: two would collide on the UI port, the Caddy name `torrent.<domain>`, the
  publication row, the page route and the downloads folder. The Debian package `qbittorrent-nox`
  is no longer installed (fresh-install rule: an old enabled `qbittorrent-nox@` unit stops the
  install with the manual `systemctl disable --now …` step instead of a migration).
- **Engine (generic, no application name):** `PAKET_CALISMA=konteyner` (Konsol shows a
  "Konteyner" chip; liveness is the unit's, like `host`); `PAKET_KONTEYNER` names the package's
  quadlet file, placed into `KONTEYNER_BIRIM_DIR` (`/etc/containers/systemd`, from
  `defaults.env`/state) with a `daemon-reload` when it changed, removed on `kaldir`, checked by
  the engine's and the installer's leftover checks and pruned for uninstalled packages like a
  drop-in; `PAKET_IMAJ` is the image, accepted only as `name@sha256:<64 hex>`;
  `paket_imaj_cek` pulls it only when `podman image exists` says no (bounded by `timeout 900`),
  `paket_imaj_sil` removes it by image id (`podman rmi NAME@sha256:…` answers "tag not known",
  found live) and leaves an image that another tag or container uses.
- **Quadlet (`magaza/torrent/qbittorrent.container`):** `Network=host` (no bridge, no
  netavark NAT chains: the firewall stays the project's), `Pull=never` (boots and re-runs never
  download), journald logging (`podman logs` and `journalctl -u` both work), `StopTimeout=45`,
  `DropCapability=NET_BIND_SERVICE SETFCAP SYS_CHROOT`, PUID/PGID = the downloads account,
  `UMASK=002`, `WEBUI_PORT=TORRENT_UI_PORT`, `[Service] Nice=10 CPUWeight=50` (DD-181),
  `After=master-firewall.service`, `[Install] WantedBy=multi-user.target`. Two mounts only: the
  profile `TORRENT_PROFILE_DIR` as `/config` (the image's layout `/config/qBittorrent/` equals the
  native XDG layout, so `ayar.py`, `yayin.py`, `klasorler.py`, `trafik.py` read the same paths) and
  `DOWNLOADS_PATH` **at the same path**, so every path qBittorrent stores is a host path (Files'
  protected folders, share validation and `save_inside` keep working). The trash and the share
  root are simply absent inside. The image is the linuxserver build pinned by its OCI index
  digest (amd64 + arm64) in the package's own `torrent.env` (`TORRENT_IMAGE`; `TORRENT_SURUM`
  only for the App Store text); an update is a new digest plus an installer run (the changed
  quadlet recreates the container). No `AutoUpdate=` and no `podman-auto-update.timer`.
  Amended by DD-214: Konsol checks the channel and the operator may apply a newer digest.
  Amended by DD-217 (v2-195): the container runs on its own bridge with per-address publications,
  not on the host network.
- **Live findings that shaped it (nrm, 2026-10-03):** with `NoNewPrivileges=true` the image's s6
  init ignored SIGTERM and was SIGKILLed after the stop timeout (30–45 s instead of 3 s, the unit
  left "failed" — qBittorrent writes settings and resume data on shutdown), so the quadlet
  carries no `NoNewPrivileges` and the hook resets a failed unit when it stops it. The seeded
  `WebUI\Address=127.0.0.1` survives the image's init (it copies its defaults only when no
  `qBittorrent.conf` exists), so the profile seed must precede the first start. The unit is
  `active` before qBittorrent listens, so the worker waits (≤40 s) for the loopback port before a
  change counts. Journal lines of the container carry the unit's `_SYSTEMD_INVOCATION_ID`, so the
  first-login password is read exactly as before.
- **Lifecycle:** a generated unit cannot be enabled or disabled; `durdur` stops it and removes the
  quadlet (nothing starts at boot), `baslat` places it again, an installer run keeps a stopped app
  stopped. `kaldir` keeps the image (as a kept Debian package was); `--veri` deletes the profile,
  the folder drop-in and the image. Verification on `kur`/`baslat`/`uygula`: the
  `qbittorrent-nox` process's host uid (`podman top … huid`) is `DOWNLOADS_UID`; no mount is `/`,
  `SERVER_ROOT`, the trash or the share root; the UI port listens on `127.0.0.1` only; first
  install still requires the unauthenticated 403 on loopback and through `torrent.<domain>`.
- **Folder choice:** a download folder inside the downloads tree needs nothing; one outside it
  (the library) becomes one quadlet drop-in `qbittorrent.container.d/90-konsol.conf` with a
  same-path `Volume=` (Podman merges drop-ins), replacing the old `ReadWritePaths` drop-in.
  Names with whitespace, `:` or `%` cannot be expressed as a bind mount and are refused.
- **Trade-offs, stated:** memory ~100 MB for the service cgroup versus ~53 MB native; a 228 MB
  image (pulled once, ~1 min); the container's init runs as root inside its namespaces (the app
  itself as PUID), weaker than the native unit's `ProtectSystem=strict` + `NoNewPrivileges`, but
  the container sees only its two mounts. Updates no longer come from apt; they are a digest
  bump in the repository. Not done: rootless/user-namespace mapping, image signature checks,
  automatic updates, a container log view on the app's own page (it links to Settings →
  Konteynerler instead).
- **Amended by DD-269 (v2-253):** the check for an active native `qbittorrent-nox@` unit is gone
  (installs before v2-186 are not supported).
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package and the engine's
  container keys (`PAKET_CALISMA=konteyner`, `PAKET_KONTEYNER`, `PAKET_IMAJ`) are gone. The generator keeps
  the proven unit lines (`Pull=never`, digest pins, journald; DD-274).

### DD-203: Package-declared folders, settings and backend write paths, phase 3 (v2-177)

- **Scope (user, 2026-10-02: "Faz 3 tamamla, kalan kozmetik temizliği de yap"):** the crumbs
  DD-202 left in the base and every remaining application name in base code and comments.
  After this phase the base — installer, `defaults.env`, `state.env`, root backend,
  settings/share/WebDAV helpers, file backend, Konsol shell, unit templates — carries no
  application name or key; adding an application means writing `Data/magaza/<id>/` only.
- **Declared folders (`PAKET_KLASORLER`, `PAKET_KLASOR_MODUL`).** A package declares, as
  absolute paths the installer renders, the folders it writes into
  (`__DOWNLOADS_PATH__/incomplete`: qBittorrent's conventional incomplete folder) and,
  optionally, a Python module (`klasorler.py`, `yazilan(env) → [paths]`) that reports what
  it writes into right now (the temporary folder the user chose in qBittorrent itself, read
  from its profile). The base applies one policy to both: the file backend receives every
  catalogued package's declared folders as root-relative `path=owner` pairs (`--protected`,
  `/api/state.protected`), so the Files page refuses to select, share or trash them and
  says which application writes there; the share manager refuses a share on, inside or
  around them (`validate_path`: declared + reported, fail closed when a report cannot be
  read); the WebDAV server hides and refuses them inside any share that contains them (the
  registry's `protected` list, root-relative, recomputed by `read()` from the catalogue and
  the reports instead of trusted from the saved file). Protection is by actual path, not by
  folder name as before: a folder merely named `incomplete` elsewhere is ordinary.
  `TORRENT_TEMP_DIR`, `temp_name`, `--temp-dir` and the base's reader of qBittorrent's
  profile are gone.
- **Package settings (`<id>.env`).** `magaza/torrent/torrent.env` holds `TORRENT_UI_PORT`
  and `TORRENT_PROFILE_DIR`, as `wireguard.env` holds the `WG_*` keys (DD-201). The
  installer fills a package's own `__KEY__` placeholders from its env file before its own
  variables (`paket_ayar_oku`), so the templates, `PAKET_YAYIN_UPSTREAM` and
  `PAKET_KLASORLER` render without base keys; `defaults.env`/`state.env` carry no
  `TORRENT_*`. The hook sources the file; `api.py`, `ayar.py`, `yayin.py` and
  `klasorler.py` merge it over the state (`package_env`). A `PAKET_PORTLAR` key resolves
  from the state or, failing that, from the package's own env file (root backend `ports()`,
  `master-wg declared_ports`), keeping DD-198's key semantics.
- **Backend write paths (`PAKET_ARKAUC_YOLLAR`).** `master-panel.service` no longer names
  `/etc/wireguard`: the installer renders `ReadWritePaths` from every catalogued manifest's
  declaration (`__WG_CONF_DIR__` for WireGuard), each with `-` so an absent folder never
  keeps the backend down, installed or not — the same catalogue-wide rule as the port
  reservation (DD-201), chosen over a per-install drop-in because that would restart the
  backend the Konsol is talking to in the middle of an install. **Amended by DD-207:** a
  `-` path is bound only if it exists when the backend starts; the installer now creates
  them first.
- **One package-module loader.** `master_settings.load_package_module(env, mid, name,
  attr, label)` replaces the publication-only loader of DD-199: regular file, no symlink,
  mtime cache, `sys.dont_write_bytecode` while executing — the `__pycache__` the base used
  to write into the rendered package folder (found on nrm) is gone. `yayin.py`
  (`security`) and `klasorler.py` (`yazilan`) both load through it.
- **Cosmetics.** The installer's summaries list the catalogue's `PAKET_AD` names
  (`paket_katalog_adlar`), stale WAN sites are removed by the `*-wan.caddy` pattern, the
  Files page's protected-folder notice names the owner the backend reports, the Settings
  port descriptions and the public-panel warning name no application, and base comments
  describe roles ("a package's service", "the download account's services") instead of
  products. Historical DD entries and archived documents keep their names.
- **Fresh install only**, like the rest of the store model (DD-196); an in-place host gets
  the new unit lines, state and package files on the next installer run.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the packages and every `PAKET_*` declaration
  are gone; the base's own write path, `WG_CONF_DIR`, is fixed in the backend's unit (DD-207).

### DD-202: The qBittorrent page and its settings in the package, phase 2c (v2-176)

- **Scope (user, 2026-10-02: "Öneri ile devam" on the phase 2c recommendation):** the last
  application piece leaves the base. The qBittorrent page (service bar, first-login card,
  account and download-folder form) is the package's `sayfa.js`/`sayfa.css`, registered
  through `window.Konsol.sayfa` like WireGuard's; its reads and writes go to the package's
  `api.py` behind `/api/uygulama/torrent/*`; the base settings transaction
  (`master_settings.py`, `ayarlar.js`) has no `torrent` family, no application tab and no
  application draft. The shell, the settings page, `index.html` and the root backend contain
  no qBittorrent code.
- **Option chosen (A, direct apply through a package worker)** over keeping the
  account/folder change inside the base's reviewed transaction. That transaction exists for
  changes that can lock the operator out (firewall, DNS, domain) and so needs the
  confirmation window; a wrong qBittorrent account or folder locks nobody out of Konsol,
  and the account-only path already committed directly (**DD-165**). The folder change
  therefore loses the 60 s confirmation it had; in exchange the base knows nothing about
  the application. A generic "package settings" family inside the base transaction (option
  B) would have kept application knowledge in the base and was not taken.
- **Worker.** `magaza/torrent/ayar.py` (`--state STATE hesap|dizin|durum`, JSON on stdin,
  JSON on stdout, exit 1 with `{"error"}`): validation (username `[A-Za-z0-9._@-]{1,64}`,
  password 8–256 printable characters; the folder through the base's
  `Manager.safe_dir(writable=True)`, so the downloads/library policy and the write probe as
  the service user stay the base's), then stop → snapshot → optional drop-in +
  `daemon-reload` → INI patch of the touched keys only (0640, downloads uid) → start →
  `is-active`; any failure restores both files, reloads systemd and starts the service
  again. The drop-in is `UNIT_DIR/qbittorrent-nox@.service.d/90-konsol.conf` with one
  `ReadWritePaths` line. The worker takes the base settings lock (`Manager.locked()`), so it
  never interleaves with a base transaction. `durum` is the page's read-only view: paths,
  inside-downloads flags, interface, peer port and account name; never the hash.
- **Backend.** `PackageContext.worker(argv, data)` runs a script that must sit under
  `MODULES_DIR/<id>/` (real path; a symlink out of the folder is refused with 400) through
  the same `systemd-run --wait --pipe --collect` path as the base settings/share workers
  (`run_worker`), so a password reaches stdin only, never argv, the environment, the journal
  or the reply; `PackageContext.state_path()` hands the state file to the worker, and the
  module passes the engine's folder as `--lib` so the standalone process finds the base's
  `master_settings.py` (a hand run finds `master-modul` on `PATH`; found live, the first run
  answered 502 because the worker could not import the base). `api.py`
  checks shapes before starting the worker (400), audits `torrent:hesap` with `kullanıcı
  adı`/`parola` and `torrent:dizin` with the path, and returns the worker's error as the
  request's error. `torrent_view`, `TORRENT_KEYS` and `read_torrent_conf` are gone from
  `master-panel`; `GET /api/konsol/ayarlar` carries no `torrent` key and `manage` no
  `username`/`save`.
- **Settings transaction.** Families are firewall, dns, domain, https and web.
  `ini_values`, `ini_patch`, `password_hash`, `q_unit`, `torrent_apply` and the account-only
  shortcut left `master_settings.py`; the package's publication check `yayin.py`
  (**DD-199**) carries its own `ini_values`. A mixed DNS request needs confirmation only
  together with firewall or domain.
- **Shell.** `PAGE_API` gained `credRow`, `copyButton`, `copyText`, `module(id)`, `modPill`,
  `modAct(id, action)` and `reloadModules()`, so a package page can show an account card and
  drive its own service through Konsol's module API; `loadModules` calls the current page's
  `modules()` hook. The page keeps the DD-151/DD-195 behaviour: the temporary password is
  read only on request, shown for 30 s, hidden on tab change or navigation; the Web UI link
  follows the Konsol address in use.
- **Remaining base knowledge, left for a later step on purpose:** `master_shares.py` still
  reads the qBittorrent profile for the incomplete-folder guard of folder shares, the Files
  page still names qBittorrent next to the downloads temp folder, and
  `TORRENT_PROFILE_DIR`/`TORRENT_UI_PORT`/`TORRENT_TEMP_DIR` are still base defaults.
  Moving them needs a package declaration for "folders a package writes to" (done in
  **DD-203**).
- **Hooks.** The package's `paket_kur` places the page (`paket_sayfa_koy`) after the service
  and its name are verified and before the registry line, `paket_uygula` places it on every
  re-run, and the rollback removes it; found live on nrm, where the first v2-176 run left
  `CONSOLE_WEB_DIR/uygulama/torrent` absent because only WireGuard's hooks called the helper.
  The engine's `kaldir` removes the folder for every package (DD-200).
- **Fresh install only**, like the rest of the store model; an in-place host gets the new
  package files on the next installer run (`master-modul uygula`).
- **Amended by DD-267 (v2-250):** the package's page (`sayfa.js`/`sayfa.css`) is gone and its hooks
  place none. qBittorrent's account and download folder are its settings form on the application's
  Ayarlar tab (`konsol.json` `form` with `oku: /durum` and `yaz: /ayar`, DD-266), and its first-login
  account is that tab's account card. The worker, `api.py` and the direct apply are unchanged.
- **Amended by DD-269 (v2-253):** the `/hesap` and `/dizin` routes and worker actions are gone (the
  Ayarlar tab saves through `/ayar`, DD-210); `/durum` gives the form's `username` and `save` only,
  without a `systemctl` call; the audit word is `torrent:ayar`.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package, its worker, `api.py`
  and the `/api/uygulama/*` routes are gone.

### DD-201: A neutral backend, package-owned settings and self-checking packages, phase 2b (v2-175)

- **Scope (user, 2026-10-02: "faz 2b ye başla"):** the second half of phase 2 of the store
  model (DD-196). After it the base names no application in its code, state or defaults:
  the root backend and its socket are renamed, WireGuard's settings live in its package,
  stage 7 asks installed packages to verify themselves, and the launcher and the peer tool
  know other packages only through their manifests. The qBittorrent page and its Settings
  form are the one remaining application piece in the shell (phase 2c, with the settings
  transaction they use).
- **Rename.** `master-wg-panel` → `master-panel` (file, unit, journal unit, `HEALTH_UNITS`,
  `server_version`), `WG_PANEL_SOCKET` → `PANEL_SOCKET` = `/run/master-panel/api.sock`,
  `WG_PANEL_RUNTIME` → `PANEL_RUNTIME`, `ensure_wg_panel` → `ensure_panel`. A fresh-install
  change like the rest of the store model; historical entries and archived documents keep
  the old names.
- **Package-owned settings.** `Data/magaza/wireguard/wireguard.env` holds every `WG_*`
  default (address bases, MTU, client DNS/keepalive/AllowedIPs defaults, config and
  profile directories, the network registry path and slot limit, the modules-load file,
  the suggested first port). The installer copies it into the rendered package folder like
  any other package file; `master-wg`, the hooks (`kanca`, sourced wherever
  `MODULES_DIR` is known: engine, firewall, installer) and the Konsol API module
  (`ctx.read_env`) read it there. `defaults.env` and `state.env` carry no `WG_*` key any
  more; the VPN endpoint is the detected `WAN_IPV4` (no `WG_ENDPOINT_HOST`), and the
  destination block lists the firewall applies to every `vpn` declaration are the base's
  own vocabulary, `VPN_BLOCK_DEST4/6`. The Mac launcher reads the peer-prompt defaults
  from the package file. `master_settings.py` no longer hashes the network registry into
  its revision: a package's own state changes go through its API.
- **Self-checking packages.** Stage 7 runs, for every registered package, the hook
  `paket_denetle` (sourced in a subshell with the installer's variables; a failure prints
  its reason and stops the install under the package's name) and, for every absent
  package, checks that none of its declared tools or drop-ins remain; the re-run prune
  removes such leftovers from the manifests instead of naming WireGuard. The summary takes
  each installed package's note from `paket_not` and its counts from `paket_ozet`, which
  now computes them itself. WireGuard's `paket_denetle` carries the former stage-7 block:
  `master-wg version`, the modules-load file, each registry network's listen port and
  address, and that the file backend does not answer on a VPN address.
- **Reserved ports.** `master-wg net-add` reserves the base ports (SSH, Tailscale, DNS,
  HTTP) and every `PAKET_PORTLAR` key of every package manifest in `MODULES_DIR`,
  installed or not, instead of naming qBittorrent, Files and WebDAV.
- **Still in the shell (phase 2c):** the qBittorrent page (`ROUTES.torrent`,
  `renderTorrentStatus`, the account card) and the Settings form (`torrent` key of the
  settings transaction in `master_settings.py`, `ayarlar.js`).
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the packages are gone and WireGuard is a
  built-in again: its `WG_*` keys are in `config/defaults.env`, `master-wg` is a base script and the firewall
  reads its networks itself. The backend keeps the name `master-panel`, and `VPN_BLOCK_DEST4/6` stays the
  firewall's own vocabulary (DD-224).

### DD-200: Konsol pages and application API from packages, phase 2a (v2-174)

- **Scope (user, 2026-10-01: "faz 2 ye başla"):** the first half of phase 2 of the store
  model (DD-196): Konsol's App Store texts, an installed application's page and its
  root-backend API come from the package. The base shell and the root backend no
  longer contain the word WireGuard. The second half (phase 2b) renames the backend and
  socket (`master-wg-panel` → a neutral name), moves the `WG_*` state keys and the
  qBittorrent page/settings form into their package, and fixes the launcher text and
  `master-wg`'s port-collision list. Each phase is a fresh-install change.
- **Declaration.** Three optional manifest keys: `PAKET_KONSOL="konsol.json"` (App
  Store texts, the page declaration `sayfa {rota, baslik, ustbilgi, detay}` and the
  journal templates `gunluk {verb: "…{detail}…{0}…"}`; a JSON object rendered by the
  installer, so `__LOCAL_DOMAIN__`-style placeholders are filled), `PAKET_SAYFA="sayfa.js
  sayfa.css"` (the page files) and `PAKET_API="api.py"` (the backend module). Names are
  plain file names; folder paths and other extensions are refused.
- **Page files.** `master-modul` copies the declared page files to
  `CONSOLE_WEB_DIR/uygulama/<id>/` on `kur`/`uygula` (`paket_sayfa_koy`, 0644 root) and
  removes the folder on `kaldir`; the trace check fails a removal that leaves it. Caddy
  serves them like the shell's own files, behind the same session gate and CSP
  (`script-src 'self'`). The installer removes an `uygulama/<id>/` folder whose package
  is not registered. Konsol loads `/uygulama/<id>/<file>` only for an installed package
  whose listing carries `sayfa`; the script registers with `window.Konsol.sayfa(id,
  factory)` and receives a small, frozen API (`h`, `svg`, `api`, `post`, `ask`, the
  shared dialog, the clock, the current route and a header repaint). The shell creates
  the section and the sidebar link (removed by DD-216) from `konsol.json`, keeps a bookmark of an
  application until the module list arrives, sends a bookmark of an absent application
  to App Store and unmounts the page when the package is removed; a package that is
  removed and reinstalled is mounted again from the already loaded factory.
- **API module.** The root backend loads `MODULES_DIR/<id>/<PAKET_API>` with importlib
  only while the package is registered `calisiyor` (regular file, cached by mtime; a
  changed file is reloaded, a removed package's object is stopped). `/api/uygulama/<id>/*`
  passes the existing Host, CSRF, channel and session gates first and is then handed to
  `module.create(ctx).handle(request)`. The module sees only `ctx` (state.env, its own
  tool beside `master-modul`, a subprocess runner with the backend's environment, the
  read-only port catalogue, `error(code, text)`, a settings-cache reset and a journal
  line) and the request (method, sub-path, query, JSON body, actor, `audit(verb, detail,
  ok)`). Audit lines are `<id>:<verb>`; Konsol labels the event by the package and reads
  the sentence from the package's templates. A missing, broken or failing module answers
  404/409/502 for that package alone. An absent package: `409 <Ad> kurulu değil; Konsol →
  App Store'dan kurun` on POST, 404 on GET.
- **What the base still knows about VPNs.** Settings → Güvenlik Duvarı keeps its VPN
  category: the networks come from the package modules' `networks()` hook (validated
  fields, no keys), the tab is named after the first such package (`vpn_name`), the port
  rows carry a structural `vpn` flag instead of a name prefix, and the rule kind is `vpn`.
  The resources sampler also refreshes the package API list every 10 s so a package's own
  sampler (WireGuard's connected-peer window, DD-137) runs before any page asks.
- **Still base, by design for now (phase 2b):** the unit and socket names, the `WG_*`
  keys in `state.env` (`WG_CLIENT_DNS_DEFAULT`/`WG_CLIENT_KEEPALIVE_DEFAULT` joined them
  so the package reads its defaults from state instead of unit environment lines), the
  qBittorrent page and its Settings form, `master-wg`'s port-collision list and the
  launcher's intro text.
- **Amended by DD-267 (v2-250):** packages ship no page any more: `PAKET_SAYFA`, `sayfa.js`/`sayfa.css`,
  the `konsol.json` `sayfa` declaration, `CONSOLE_WEB_DIR/uygulama/<id>/` and `window.Konsol.sayfa` are
  gone, and a re-run deletes the old page folders. The new interface draws a package from its
  declarations (App Store texts, install and settings forms, account, stop and removal words; DD-266)
  and loads no package script. The API module behind `/api/uygulama/<id>/*` and the journal templates
  are unchanged; an absent package's 409 now says to install it from the catalogue in Uygulamalar.
  Settings → Güvenlik Duvarı's VPN category is the WireGuard tab of Erişim → Güvenlik duvarı (DD-265).
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the package loader, `/api/uygulama/*` and the
  packages' `konsol.json` are gone; only the route table answers, apart from the session check and the sign-in
  POST.

### DD-199: Publication rows from package declarations, phase 1b (v2-173)

- **Scope:** the last base piece that named an application: Settings → Caddy. The
  built-in WebDAV row and the Konsol row stay fixed (they belong to the base); every
  other row comes from a package manifest.
- **Declaration.** A package publishes by setting `PAKET_YAYIN=1`, `PAKET_YAYIN_AD`
  (row name), `PAKET_YAYIN_YEREL` (local name, `<local>.<domain>` on the tailnet),
  `PAKET_YAYIN_UPSTREAM` (must be `127.0.0.1:PORT`; a placeholder is filled by the
  installer) and optionally `PAKET_YAYIN_DENETIM`, a Python file inside the package
  folder with `security(env, name, probe)`. A manifest that declares publication
  without a loopback upstream produces no row at all: the catalogue never guesses an
  upstream, and no tunnel or arbitrary host can be declared.
- **Engine side.** `master_publications.packages(env)` reads the rendered manifests
  (shared `master_settings.read_manifests`, line pattern, never sourced) and builds
  the rows, the private 403 stubs, the generated `<id>-wan.caddy` sites (one name,
  TLS-ALPN, the loopback upstream, `Host`/`X-Forwarded-Host`/`X-Forwarded-For`
  headers) and the status messages from the declared name. The security module is
  loaded from the package folder as a regular file, cached by mtime; a missing,
  broken or failing module closes the row instead of exposing the app. Saved rows
  of a package that no longer ships stay in the file unused, and its leftover
  public site is removed at the next publish.
- **Consumers.** Settings transactions snapshot every module site, `https_apply`
  waits for the certificate only when the package is active, the share publisher
  signs its projection with the active publication names, the firewall helper opens
  TCP 443 while any publication is active, and Konsol's module listing carries each
  publishing package's tailnet and public addresses. qBittorrent's checks moved
  verbatim into `magaza/torrent/yayin.py`; nothing in the base names it any more.
- **Still base:** the WebDAV row's HTTPS machinery (`master_https`, `master_shares`)
  and the Konsol row (DD-195). Phase 2 moves Konsol's App Store texts and pages into
  packages and renames the backend.
- **Retired by DD-275 (v2-258, the rebuild):** no package rows remain (DD-272 removed the packages).

### DD-198: Firewall, health and port catalogue from package declarations, phase 1b (v2-172)

- **Scope (user, 2026-10-01):** the second half of phase 1 of the store model
  (DD-196/197): the base derives firewall rules, health units and the port
  catalogue from what installed packages declare. Publication rows (Settings →
  Caddy) follow in the next version; Konsol metadata and the backend rename are
  phase 2.
- **Firewall.** Packages never write rules. `master-firewall` reads the registry
  and, for every package in state `calisiyor` whose `kanca` defines
  `paket_firewall`, sources the hook in a subshell and collects its output lines.
  The vocabulary is deliberately one word today: `vpn IFACE UDP_PORT NET4 NET6`,
  which means a WAN UDP endpoint, a tailnet permit for that port, internet-only
  forwarding (DD-177 destination blocks from `WG_BLOCK_DEST4/6`) and NAT for the
  subnets. Every line is validated against strict patterns, interfaces and ports
  must be unique across packages, and a malformed or unknown line stops the run
  before any chain changes, exactly as a corrupt registry did before. The
  WireGuard package's hook prints one `vpn` line per network of its own registry
  and a deliberately invalid line for a non-`inet` scope. `--check` recomputes
  expectations from the same declarations. The recovery guards keep the static
  `-i wg+ DROP`; a package cannot change recovery behaviour. No WAN TCP word
  exists: web interfaces reach the internet only through Caddy's publication port.
- **Health.** `master-modul saglik` prints `id<TAB>unit<TAB>gerekli|ag` for every
  installed package: `paket_saglik` when the hook defines it (WireGuard: one
  `wg-quick@wgN.service` per network, type `ag`, which may be disabled from
  Konsol), otherwise the unit from `paket_birim` as `gerekli`. A hook that finds
  a corrupt registry fails the call and the card says the package services could
  not be verified. The backend keeps its base units and its registry format check
  and no longer knows qBittorrent's or WireGuard's units.
- **Port catalogue.** `PAKET_PORTLAR="KEY:proto:scope:name;…"` in a manifest adds
  rows to Settings → Güvenlik Duvarı while the package is registered; `dosya` got
  a manifest (built-in) for its loopback row and `paylasim` declares the WebDAV
  port. The backend reads manifests with the engine's line pattern (never
  sourcing them) and skips a malformed manifest's rows instead of guessing. The
  base rows are only Tailscale, SSH, Caddy and dnsmasq.
- **Trust:** hooks run as root in the firewall and the engine, like `master-modul`
  did before DD-197; packages come only from this repository, and the firewall's
  validation treats their output as data.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the packages' firewall, health and port
  declarations are gone. The firewall reads WireGuard's networks file and stopped marker itself, with the same
  strict validation (DD-272), and an application's raw ports pass through the container guard (DD-275).

### DD-197: The store engine and package format, phase 1a (v2-171)

- **Scope (user, 2026-10-01: "Faz 1'e başla"):** the first half of phase 1 of the
  store model (DD-196): the engine and the package format. The second half (phase
  1b) makes firewall, health, port catalogue and publication rows derive from
  package declarations; phase 2 renames the backend and loads Konsol pages from
  packages.
- **Package format.** A package is `Data/magaza/<id>/`, rendered by the installer to
  `MODULES_DIR/<id>/`. It holds:
  - `paket.env`, the manifest: `PAKET_AD`, `PAKET_SIRA` (catalogue order),
    `PAKET_CALISMA` (`host`/`konsol`), `PAKET_DURDURULABILIR`, `PAKET_HESAP`,
    `PAKET_APT` (Debian packages), `PAKET_ARACLAR` (files placed in `SBIN_DIR`
    0755), `PAKET_EKLER` (`source:unit.d/file` drop-ins placed under `UNIT_DIR`),
    `PAKET_ADLAR` (has `<id>.caddy` and `dnsmasq.conf` names), `PAKET_GUNLUK`
    (journal unit patterns), `PAKET_KUR_ADIM` (progress total), `PAKET_YAYIN`
    (registry changes republish Caddy), `PAKET_UYGULA_HEP`/`PAKET_UYGULA_NEDEN`
    (re-applied on every installer run, and why) and `PAKET_YERLESIK` (built-in:
    outside the catalogue, never removable). The engine reads it line by line
    with a strict pattern and never sources it.
  - `kanca`, the hooks: a bash file the engine sources, defining only `paket_*`
    functions: `paket_kur`, `paket_kaldir`, `paket_uygula STATE`, `paket_baslat`,
    `paket_durdur`, `paket_birim` (the unit name), `paket_hesap`, `paket_veri_sil`,
    `paket_gunluk_suz` (log filter) and `paket_ozet` (installer summary). Hooks run
    as root like the engine did before; packages come only from this repository.
  - Slot files: `<id>.caddy`, `dnsmasq.conf`, units, drop-ins, tools and seeds.
    Any file with `__KEY__` placeholders is a template filled from the installer's
    own variable of that name; a missing variable stops the install.
- **Engine.** `master-modul` knows no application: the catalogue is the set of
  rendered package folders with a manifest, ordered by `PAKET_SIRA`; `liste`,
  `kur`, `baslat`, `durdur`, `kaldir [--veri]`, `gunluk`, `hesap` and `uygula`
  keep their names, locks, progress file and output format. Apt packages, tools,
  drop-ins and names are placed and removed by engine helpers the hooks call in
  the order the package needs (`paket_apt`, `paket_araclar_koy`, `paket_ekler_koy`,
  `paket_adlar_ac`, their `kaldir`/`kapat` counterparts, `progress_step`,
  `registry_set`, `firewall_apply`). After `kaldir` the engine removes every
  declared artifact itself and fails the operation if any trace remains
  (`paket_iz_kontrol`), so a package cannot leave a tool, drop-in or name behind.
  Built-in Files and WebDAV keep their installer-only `yerlesik` path; `paylasim`
  carries a manifest with `PAKET_YERLESIK=1` so the renderer treats it like any
  package while the catalogue excludes it.
- **Installer.** `render_package_dir` renders or copies every file of every
  package folder (executables 0755); `ensure_module_files` marks a package for
  `uygula` when a file changed or the manifest says always. Summary lines take the
  name from the manifest and one line from the package's `paket_ozet` hook.
- **Unchanged for now:** Konsol's `MOD_META` texts and routes, the backend's
  `ACCOUNT_MODULES`/`PORT_MODULES`/health units and `master_publications`'
  module ids, the firewall's WireGuard registry logic, the `WG_*` state keys.
  Those are phase 1b and phase 2.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** `master-modul`, `magaza/`, the registry and
  the package format are gone.

### DD-196: The store model, phase 0 (v2-170)

- **Request (user, 2026-10-01):** after a clean install without WireGuard, Konsol's log
  still showed "WireGuard" rows and errors. The user asked for a fully independent App
  Store: an app sets up everything it needs on install and takes it all away on removal,
  and for a structural "store" design. They approved the model below and the folder name
  `magaza`, and asked to start with phase 0.
- **Finding:** the rows were mislabelled base events. Konsol's log called every root-backend
  event that was not a module action "WireGuard" (sign-ins, settings, shares), and failed
  sign-ins became "WireGuard errors". Beyond that, the base owned real WireGuard pieces
  with the package absent: the `master-wg` tool and the `wg-quick@` drop-in were installed
  unconditionally, `/etc/wireguard` was created by the base, the root backend's unit was
  described as the "WireGuard backend", the installer probed it through `/api/wg/state`,
  the summary always printed "WireGuard: 0 ağ, 0 peer", Caddy's `--environ` dumped every
  `WG_*` variable of `state.env` into the journal, and the five-minute tailnet timer scanned
  for `wg-quick@` units.
- **Model (approved):** the base knows no app. A package is a folder under `Data/magaza/<id>/`
  that will carry a manifest, lifecycle hooks (`kur`, `kaldir`, `baslat`, `durdur`, `uygula`,
  `saglik`, `hesap`, `gunluk`, `firewall`) and slot files (`<id>.caddy`, `dnsmasq.conf`,
  units, `konsol.js`). One root engine runs the hooks, keeps the registry with each package's
  footprint and verifies that a removal leaves nothing behind. Firewall, health, port catalogue,
  publication rows and Konsol pages derive from installed packages' declarations, validated
  against a narrow vocabulary; packages never write rules themselves. The catalogue stays in
  this repository; no remote store, no third-party packages.
- **Phase 0 (this version):** the repo folder `modules/` became `magaza/`; `master-wg` and
  `wg-quick-master-stack.conf` moved into `magaza/wireguard/`. The installer only renders
  them into `MODULES_DIR/wireguard/`; `master-modul kur`/`uygula wireguard` place the tool
  and the drop-in, `kaldir` removes them (the key folder is data, removed with `--veri`),
  and a re-run removes a tool or drop-in left by an older base install when the package is
  absent. Stage 7 checks the tool only with the package and its absence without it, and
  probes the backend with `/api/konsol/kaynaklar`. The unit is "Konsol root backend"; Caddy
  starts without `--environ`; the tailnet timer and the module log route look at WireGuard
  only while it is installed; the summary and the confirmation screen name WireGuard only
  as a package. Konsol's log labels events by source (Konsol, Ayarlar, Paylaşımlar, Dosyalar,
  Uygulamalar, WireGuard) with words for sign-in, settings and share events, and offers filter
  chips only for kinds present.
- **Still base, by design for now:** `WG_*` keys in `state.env` and `defaults.env` (the
  firewall reads the network registry and block lists), the service and socket names
  `master-wg-panel`, the `/api/wg/*` route and the `wireguard_installed` gates. Phase 1 moves
  the hooks and declarations into the package folders and makes the firewall, health and port
  views manifest-driven; phase 2 renames the backend and API and loads Konsol pages from
  packages. Each phase is a fresh-install change; no compatibility code for earlier state.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the store model is gone; Obhut knows no
  application (DD-271). Two of phase 0's fixes hold: Caddy starts without `--environ`, and İşlem geçmişi names
  every event by its source (DD-276).

### DD-178: Seed qBittorrent integration, not user preferences (2026-09-29)

- **Request:** limit configuration to panel integration and correct service
  operation; leave UPnP/automatic port mapping and local peer discovery to users.
- **Decision (v2-152):** remove forced UPnP, port-mapping and LSD values, and
  forced separate temporary storage, from the new-profile template. Keep only
  the writable default download location (current/compatibility keys), loopback
  WebUI address/port, localhost authentication and the existing headless-startup
  notice acceptance. Absent keys use the installed application's defaults;
  removing `false` does not mean writing `true` instead.
- **Preserve:** nonroot service account, profile ownership, systemd sandbox,
  DNS/Caddy integration and host firewall. No new peer-port permission, routing
  change, automatic tuning or extra package. Existing Files/share guards for the
  conventional incomplete path remain; they do not enable temporary storage.
- **Existing profiles:** no automatic deletion or migration of preference keys;
  old installer defaults cannot be distinguished safely from deliberate user
  choices. Reapply and remove/reinstall without data deletion preserve all of
  them. Users change their current preferences in qBittorrent's own settings.
- **Verification:** exact seed-key allowlist and lifecycle/profile-preservation
  Bats tests; isolated native Linux comparison against the same qBittorrent's
  defaults, anonymous/login gates, nonroot startup and preference persistence
  after restart. Live installed accounts/services are not used by this fixture.
- Supersedes DD-151's enforced UPnP/LSD/temporary-storage defaults only; the
  firewall and other module lifecycle decisions are unchanged.
- **Amended (v2-195, DD-217):** on its own bridge the seeded and installed `WebUI\Address` is `*`
  (loopback is now the Quadlet's only interface publication), and the peer port 61008 is published
  on the WAN address by the user's choice.
- **Amended (v2-196, DD-218; reverted v2-197, DD-219):** chosen fresh-profile defaults were seeded for
  one version and then reverted; the seed is again integration keys only.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package and its seed are gone.

### DD-171: Remove dead sharing lifecycle without deleting legacy data (2026-09-28)

- **Changed in v2-158:** the retired `/api/paylas` and `/api/paylas/kaldir`
  routes lost their 410 handlers and now answer like any unknown route (404). The
  reserved `.pay` name and its exclusions below stay.

- **Decision (v2-145):** remove unreachable public Files/WebDAV lifecycle and
  data-deletion branches, legacy marker readers/writers, shared-password command
  plumbing and credential-path defaults. Built-ins retain their installer-only
  lifecycle and internal registry IDs used by firewall, settings and DNS.
- Fresh installs create no `.pay/w` or `.pay/acik`. Existing `.pay` contents are
  neither migrated/deleted nor included in permission repair. Keep the reserved
  name and service/path exclusions: removing them would expose old metadata.
  The WebDAV unit tolerates a missing legacy path, not an accessible existing one.
- Retired Files endpoints return explicit 410 after security gates; `/api/state`
  stops reporting the misleading marker-derived summary. Current per-folder
  accounts remain exclusively in root-owned `webdav.json` and its gated API.
- Remove dead frontend helpers/styles and stale operational instructions. Keep
  historical decisions/designs/releases as history. Optional-app profiles, keys,
  user files, active API aliases and all actual runtime dependencies remain.
- Dependencies are already minimal for the current feature set: Python/RAR,
  network/firewall/DNS tools, systemd/core utilities and security-update packages
  all have callers. No apt purge/autoremove, package upgrades solely for cleanup,
  replacement runtime or new background service.
- Regression coverage exercises absent legacy directories, preserved metadata
  and private modes, marker symlinks, explicit retired-route errors/gates,
  built-in idempotency, current module lifecycle and temporary-login secrecy.
- **Amended by DD-269 (v2-253):** the reserved `.pay` name and its exclusions are gone; stage 0 refuses
  to install while `SERVER_ROOT/.pay` exists, so an old tree is never exposed.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the `.pay` install gate that replaced the
  reserved name (DD-269) went with the 1.x leftovers; the new generation installs only on a clean system (K1,
  DD-271).

### DD-165: One-click qBittorrent account save (2026-09-27)

- **Decision (v2-135):** replace account staging/review/60-second confirmation
  with one explicit Save. The former first button only staged credentials;
  opening the Web UI immediately afterward therefore still required the old
  login. Native browser username validation also needs an escaped hyphen for
  the modern HTML pattern `v` flag.
- Only an isolated username/password request commits immediately. Eligibility
  is decided by the worker, never a client flag. Folder and mixed requests keep
  confirmation, as do firewall edits; domain migration retains five minutes.
  Account edits cannot remove Konsol's network access, so connectivity approval
  adds no protection here. Successful saves do not revert after disconnect.
- Preserve revision/lock validation, stop/flush/snapshot/write/restart, durable
  pre-write recovery, commit markers and guard recovery for failure/process death.
  Keep stopped services stopped and unrelated profile keys untouched. A blank
  password preserves a stored hash, not a rotating temporary startup password.
- The UI reports success only for an explicit committed response, disables
  duplicate submission, clears secret fields and never stages the password.
  Unrelated drafts remain unapplied and use the refreshed revision afterward.
  Failed/ambiguous requests ask the operator to refresh and re-enter the password;
  no automatic credential retry or new dependency is introduced.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent's package and its settings are
  gone.

### DD-151: qBittorrent is a host module; Dozzle and the base Compose project go (2026-09-18)

- **Context:** stage 4 of **DD-148**. qBittorrent (LinuxServer image) and
  Dozzle were the base Compose project, the input file held both accounts and
  **DD-129** rewrote qBittorrent's settings on every run. The approved design
  lists qBittorrent as a Konsol module. The operator chose (2026-09-18): the
  settings are written once, no peer port is opened, the package stays on
  removal.
- **Decision — qBittorrent:**
  - It becomes the `torrent` module with runtime `host`: the distribution's
    `qbittorrent-nox`, run through the package's template unit as
    `qbittorrent-nox@<downloads account>.service`. Its files keep the owner
    Konsol and Arşiv açıcı use. No image, no container, no bind mounts; its log
    is the unit's journal.
  - The drop-in `qbittorrent-nox@.service.d/master-stack.conf` does what the
    container's mount list did: profile in `TORRENT_PROFILE_DIR`
    (`/var/lib/qbittorrent`, `HOME` and `XDG_*`), `UMask=0002`,
    `ProtectSystem=strict` and `ProtectHome` with only the profile and
    `DOWNLOADS_PATH` writable, the trash and the share root inaccessible (the
    **DD-144** promise), no new privileges, kernel and clock protections,
    address families limited to UNIX, IPv4, IPv6 and netlink.
  - **Settings once (reverses DD-129):** when the profile has no
    `qBittorrent.conf`, `master-modul` seeds a minimal one — save and
    temporary paths, web UI on `127.0.0.1:TORRENT_UI_PORT` with localhost
    authentication on, UPnP and port forwarding off, the legal notice
    accepted. Nothing rewrites it afterwards; `uygula` refreshes only the
    drop-in and the names. What the operator changes in qBittorrent stays.
  - **No account in the installer:** `TORRENT_USER`/`TORRENT_PASS` and
    `DOZZLE_USER`/`DOZZLE_PASS` leave the input file, which now holds only
    `SSH_HOST` and `LOCAL_DOMAIN`. Until a password is set in its UI,
    qBittorrent prints a temporary one to its journal on every start.
    `master-modul hesap torrent` reads only the current start's journal
    (`_SYSTEMD_INVOCATION_ID`), so an old password is never shown. Konsol's
    card shows the user and whether the password is temporary. The temporary
    password itself appears only on request, for 30 s, and is audited like
    Paylaşım's. `gunluk` masks that line.
  - **No inbound peer port (reverses DD-63's publication and the torrent half
    of R12):** qBittorrent only connects out. `TORRENT_PUBLIC_PORT`, the WAN
    `ACCEPT` in `MASTER-INPUT`, the `RETURN` in `MASTER-DOCKER` and the port
    rows go. Trade-off, accepted: fewer peers on poorly seeded torrents, and
    nothing of the torrent client listens on the WAN.
  - **Names:** `torrent.<domain>` comes and goes with the module (a Caddy
    import and a dnsmasq file, as for Paylaşım). `caddy-wg` keeps serving only
    the qBittorrent port on `ui` networks; without the module it answers `502`.
  - **Install checks:** the unit is active, runs as `DOWNLOADS_UID` and
    carries the two inaccessible paths; the API answers `403` without a login
    on loopback and through `torrent.<domain>`; the name resolves. A failed
    install is taken back.
  - **Removal:** `kaldir` removes the names and the drop-in and disables the
    unit; the package stays, as WireGuard's do (**DD-150**). `--veri` deletes
    the profile (settings and torrent list), only under `/var/lib`. A
    downloaded file is never deleted.
- **Superseded in part by DD-209 (2026-10-03):** qBittorrent now runs as a Podman container
  (quadlet, digest-pinned image); the settings seed, account, journal and folder rules below
  still hold. The paragraph that follows is the 2026-09-18 reasoning.
- **Why host and not the container:** one image fewer to follow and pin, a
  sandbox that says what the mounts said, the first-login password in a
  journal Konsol already reads, and the same start/stop path as the other host
  units.
- **Dozzle goes:** every module card has a Günlük panel (**DD-148**) and the
  only containers left belong to modules. Dozzle was the last input-file
  account and an image to follow.
- **No base Compose project:** the installer still installs the Docker engine
  and the Compose plugin for the Docker modules, but renders no
  `/root/docker/compose.yaml`, pulls no image and asks no pull question on
  re-runs. Stage 7 no longer checks containers.
- **Upgrading a v2-117 host:** per the fresh-install rule there is no clean-up
  or adoption code: the old containers, `/root/docker` and the old qBittorrent
  data stay until the host is reset. The four account lines must leave
  `kurulum/kurulum.env`, or the unknown-field gate stops the run before any
  change.
- **Verified:** bats (module lifecycle with fakes, first-login parsing, the
  root backend's account route, Konsol's card) and the Konsol page against a
  mock backend; live on `nrm` (Debian 13, `qbittorrent-nox` 5.1.0) on
  2026-09-18 with v2-119: install, stop/start, remove and reinstall (settings
  file unchanged), `--veri` (profile gone, new temporary password), reboot.
  Inside the unit's mount namespace the trash and the share root are
  unreadable and only `DOWNLOADS_PATH` and the profile are writable.
- **Local Peer Discovery off (v2-120):** the live run showed qBittorrent
  announcing on UDP 6771 on every interface, the provider's LAN included —
  it multicasts the info-hashes of what the server downloads to that
  segment, and there are no local peers to find on a server. The first
  settings now carry `Session\LSDEnabled=false`. The random peer port itself
  still listens on every interface; binding it to the WAN interface was
  rejected because a renamed interface would stall every torrent without a
  clear error, and the firewall already drops new WAN traffic to it.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** qBittorrent left with its package; Dozzle and
  the base Compose project had gone long before (no Docker since DD-152, no Compose runtime by DD-271).

### DD-150: Dosya yöneticisi and WireGuard are Konsol modules (2026-09-18)

- **Context:** stage 3 of **DD-148**. The file backend and the WireGuard layer
  were part of every install; the approved design (v06) lists both as
  one-click Konsol modules, with Paylaşım depending on the file manager.
- **Decision:**
  - `dosya` (Dosya yöneticisi) and `wireguard` (WireGuard) join the catalogue
    as Konsol modules. They are installed or removed, never stopped: a
    stopped file manager or WireGuard layer would only be a broken page.
  - The installer still installs the tools (`master-files-panel`, `master-wg`),
    the downloads account, the `SERVER_ROOT` tree, the `caddy-wg@` template and
    `Caddyfile.wg`. It renders the file backend's unit to `MODULES_DIR/dosya/`
    instead of `UNIT_DIR`, and no longer installs WireGuard packages, loads the
    kernel module or starts networks.
  - `master-modul kur dosya` places the unit, starts it and proves what stage 7
    used to prove (runs as `DOWNLOADS_UID`, answers through Caddy, `403`
    without `X-Konsol`); a failed start is taken back. `kaldir` removes the
    unit; `--veri` empties the trash, which the operator had already deleted.
  - `master-modul kur wireguard` installs the packages, loads the kernel module,
    registers itself, re-applies the firewall and starts the registry's
    networks. `kaldir` closes every `wg-quick@`/`caddy-wg@` unit, unregisters,
    re-applies the firewall and keeps `/etc/wireguard` (a reinstall brings the
    networks back); `--veri` deletes the keys, profiles and registry. The
    packages stay installed: removing them buys nothing and a reinstall
    would only fetch them again.
- **Firewall hook:** `master-firewall` reads the module registry and ignores
  the network registry unless `wireguard` is registered, so a kept registry
  never opens ports after removal. It checks the registry, not a running unit:
  the firewall must be right at boot, before any unit starts. The module is
  registered before the firewall is re-applied on install and unregistered
  before it is re-applied on removal.
- **Other consumers:** `master-wg` refuses every command but `version` without
  the module (wireguard.command then shows why). The root backend never runs
  `master-wg` without it: `/api/wg/state` answers `installed: false` with no
  networks, changes get `409`, profiles `404`.
- **Dependencies:** `kur paylasim` needs `dosya`, `kaldir dosya` refuses while
  `paylasim` is installed. Konsol queues the pair: "… ile birlikte kur"
  installs the dependency first; "Birlikte kaldır" removes the dependent
  first (keeping its data). The queue lives in the page; if the page closes
  mid-way the operator clicks again.
- **Konsol without the modules:** the Dosyalar and WireGuard pages and menu
  items appear with their modules; a bookmark to a missing page opens Modüller.
  The page never asks a backend that is not there (the file backend is behind
  Caddy, which would answer 502). The disk card takes total and free from the
  root backend (`/api/konsol/kaynaklar` → `root`, `disk`) and shows the
  downloads/trash breakdown only with the file manager.
- **Re-runs:** a changed unit or script re-applies an installed file manager
  (restart and checks); WireGuard is re-applied on every run while installed
  (packages after an OS upgrade, kernel module, networks). Stage 7 checks each
  only while its module is installed.
- **Fixed in v2-119:** the root backend's sandbox makes `/etc/wireguard`
  writable, and systemd refuses to start a unit whose `ReadWritePaths=` is
  missing. Before DD-150 `wireguard-tools` created the folder during the
  install; after it, a fresh v2-118 install stopped in stage 7 with Konsol
  down. The installer now creates the folder (`0700`) before starting the
  backend, and the unit marks the path optional (`-`), so a folder deleted by
  hand degrades WireGuard changes instead of taking Konsol down. The folder is
  created in the base rather than by the module because the backend's mount
  namespace is fixed at its start: a folder that appears later is read-only
  inside it until a restart.
- **Upgrading a host installed before v2-117:** its file backend and WireGuard
  layer were started by the installer and are not in the module registry.
  Per the fresh-install rule there is no adoption code; reset the host and
  install the modules from Konsol.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** Files is built in since DD-159 and WireGuard
  again since DD-272 (installed, turned off, K6); the module registry and `master-modul` are gone. The folder
  that must exist before the backend starts is DD-207's rule.

### DD-148: A clean install is the base; Konsol installs modules (2026-09-16)

- **Context:** the installer shipped a fixed bundle. The user wants the server
  to come up with the base only and to add parts from Konsol with one click,
  as an administrator would — "temiz kurulumda sadece docker hazır olarak
  gelsin kalan kontainer yapıyı panelden ayarlalım". The model was tried in
  mockups first (`docs/design/konsol-moduller-v04…v06.html`, v06 approved).
- **Decision (user):**
  - **Base (installer):** Konsol, Tailscale by login link, dnsmasq + Caddy,
    the firewall and an empty Docker engine.
  - **Modules (Konsol → Modüller):** Dosya yöneticisi and WireGuard (Konsol
    pages), qBittorrent (on the host, Debian's `qbittorrent-nox`, no settings
    sync), Paylaşım (rclone, needs Dosya yöneticisi) and Arşiv açıcı
    (Unpackerr, its own module). Dozzle goes; each module card has a
    **Günlük** panel instead.
  - Delivered in stages, each verified on `nrm`: (1) the module mechanism and
    Arşiv açıcı (v2-115); (2) Paylaşım; (3) Dosya yöneticisi and WireGuard;
    (4) qBittorrent on the host and Dozzle's removal.
- **Mechanism:**
  - **The installer renders, Konsol runs.** Module files are templates with
    installer-only values (image pins, uid, paths, log limits), and
    `render_template` refuses leftovers. So the installer renders every
    module's files to `MODULES_DIR/<id>/` on each run and Konsol never renders
    anything; `config/defaults.env` stays the single source.
  - **One root helper, a fixed vocabulary.** `master-modul` accepts a
    catalogued id and `liste`, `kur`, `baslat`, `durdur`, `kaldir [--veri]`,
    `gunluk`. The root backend validates the id against `liste` before
    calling it, so a request can name a module but never a path or an
    argument.
  - **Operations outlive the request.** The backend runs
    `systemd-run --unit=master-modul-<id>.service --collect`. The unit is
    outside the backend's sandbox (an image pull or a package install needs
    more than the backend may do), keeps running when the page closes, and its
    name doubles as the busy check (`systemctl is-active` → `409`). Tried on
    `nrm` before writing it.
  - **State the page can read.** `/etc/master-stack/moduller` holds only
    installed modules and whether the operator left them running or stopped;
    a missing line means "not installed". Progress is one tab-separated line
    in `RUNTIME_DIR/modul-<id>.ilerleme`, ending in `bitti` or `hata` with the
    reason. Changes run under one `flock`, so two modules never pull or
    install at the same time.
  - **Each Docker module is its own Compose project** (`-p <id>`): the base
    project's `--remove-orphans` never touches a module, and removing a module
    (`down --rmi all`) never touches the base.
  - **Re-runs respect the operator's choice.** A module whose rendered file
    changed is restarted only if it is registered as running; a stopped module
    stays stopped and an absent one stays absent. The installer never runs
    `kur`, `durdur` or `kaldir`.
  - **Removal keeps user files.** `kaldir --veri` deletes only what the module
    owns (for Arşiv açıcı, the contents of `downloads/.unpackerr`); files under
    `SERVER_ROOT` are never part of a module's data.
- **Checks move with the module.** Stage 7 no longer checks Unpackerr; `kur`
  checks that the container cannot see the trash or the share folder
  (**DD-144**) and takes the container down if it can.
- **Trade-off:** anyone who can open Konsol can now start root operations —
  bounded to the catalogue and verbs above. That follows from **DD-147**
  (tailnet membership is the boundary) and is why the Host and `X-Konsol` gates
  cover `/api/konsol/*` too.
- **Not doing:** a plugin system, remote catalogues or module versions chosen
  at runtime. The catalogue lives in this repository and changes with a
  release, like everything else.
- **Pages:** Caddy now serves the Konsol pages itself (`file_server`, same
  security headers). A page that must show modules the file backend may not
  exist any more once Dosya yöneticisi becomes a module, so pages cannot
  depend on that backend.
- **Retired by DD-272 (v2-255, the rebuild; moved in phase 6):** the module mechanism became the store engine
  (DD-196, DD-197) and is gone with it; applications are added from their own files (DD-271) as jobs of the
  container broker (DD-211, DD-274).
