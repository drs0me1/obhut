# Session Notes

Cross-session continuity for this repository.

## Current Task

**2026-09-08 — v2-74, OS-aware install (live-verified on `nrm`):**
Full OS-awareness + optimisation review written to
[`docs/os-aware-review.md`](docs/os-aware-review.md), based on source review
plus read-only live discovery on `nrm` (Ubuntu 26.04.1, systemd 259, kernel
7.0.0-31, Docker 29.8.0, Tailscale 1.102.3). Conclusion: detection was already
correct and the probe-over-identity design is kept; what was missing was
*recording* the detected OS and *verifying* that OS-conditional steps landed.
Plan steps 1–5 implemented as v2-74 (**DD-103…107**): needrestart suspended
during apt (it runs in automatic restart mode on Ubuntu and was silently
restarting sshd/docker/tailscaled/caddy/dnsmasq mid-stage); OS identity in
`state.env` with `OS_CHANGED` forcing re-application; `sysctl.d` drop-ins
renamed `99-zz-*` so they sort after provider files, plus a live `ip_forward`
assertion in stage 7; three fail-early gates (nft backend, repo-suite preflight,
rendered-config validation on the target); Docker container log rotation.
Verified: `bash -n` and `shellcheck -x` clean, bats **86 passed / 3 skipped**,
`detect_os_change` exercised across four state files, `assert_repo_suite` and
the `jq` merge exercised against real inputs, and both validators plus the nft
gate and stage-7 assertions exercised read-only on `nrm`.
**Live acceptance on `nrm` (Ubuntu 26.04.1):** four default re-runs plus a cold
reboot, all exit 0. Run 1 (v73→v74) logged "no OS record", deleted both legacy
`99-master-*` sysctl files and rewrote them as `99-zz-*`, added the five `OS_*`
lines to `state.env` and `log-opts` to `daemon.json` — **6/6 container IDs and
start times bit-identical**. Run 2 a full no-op. Run 3 with a seeded
`OS_CODENAME=noble` proved DD-104: logged the release change and re-applied both
apt updates, the firewall, dnsmasq and Caddy (every skip message absent), then
self-corrected `state.env`. After the reboot — the real DD-105 test —
`99-zz-*` sorts after the provider's `99-nc-kernel.conf`, `ip_forward=1`,
`rmem_max` 64 MiB preserved, 0 failed units, 6/6 healthy, firewall `--check`
passes, all five wg modules loaded, dual-path DNS + out-of-domain REFUSED,
Caddy health `ok`, WebDAV 401 on both paths, Tailscale Running/Online/exit-node.
Run 4 (post-reboot) a no-op with container start times unchanged.
**2026-09-11 — v2-79, BBR adopted after measuring it:** stage 2 now loads
`tcp_bbr` and sets `bbr` and `fq` in `99-zz-master-tcp.conf`. If the module
does not load, the install stays on the kernel default (the DD-108 lesson).
Stage 7 reads the live value back and warns on a mismatch instead of failing
(DD-111). Live on nrm (Ubuntu 26.04): the run logged bbr/fq, the WebDAV socket
Caddy accepted used `bbr`, no container was recreated, and the install exited
0. `tailscale0` stayed on `fq_codel` until the reboot and came up on `fq`
afterwards, as predicted. After the reboot the module was loaded from
modules-load.d, the setting was still bbr, and a re-run exited 0. This also
corrects the review's D1 claim that BBR speeds up exit-node traffic.
Congestion control runs on the endpoints of a connection, so only TCP that
terminates on this host benefits. **Debian verification of v2-77 through
v2-79 is still outstanding** (nrm runs Ubuntu). These changes are either
OS-agnostic or behind a probe, but that is an argument, not a measurement.

**2026-09-11 — Ubuntu smoke test → v2-78 (Docker DNS and log rotation now take
effect):** The smoke test passed 23/23. The one FAIL on the first pass was a
mistake in the test: it expected 403/405/500 from WebDAV, but rclone's
read-only mode returns 404. Nothing was written, and both read-only layers
were intact. An optimisation survey measured the host instead of assuming
anything:
- resources were idle;
- boot took 8.4 s, most of it in the provider's devices;
- tailnet peers sat on DERP while idle and switched to a direct path once
  traffic started (70 → 58 ms);
- the WebDAV hot path has no userspace bottleneck (rclone 475, docker-proxy
  476, Caddy 500 MiB/s);
- UDP offloads already match Tailscale's recommendation;
- no MSS clamp is needed, because the tailnet client advertises an MSS of 1240.
**The real finding:** DD-107's log rotation had never reached a single
container. docker-ce's postinst starts dockerd 2 s before the installer
wrote daemon.json, so every container was created with `LogConfig {}`. The
same ordering left DD-8's container DNS off until the first Docker restart.
v2-78 writes daemon.json before the Docker packages are installed (the DD-18
pattern) and moves the log policy into compose.yaml as an `x-logging` anchor,
so existing hosts get it through a one-time recreate (DD-110). Verified on
the existing-host path, on the fresh-Docker path, and as a clean
purge → reboot → install that exited 0. Along the way, a test-method pitfall
turned up and is now in tests/README.md: a Docker purge without a reboot
leaves stale kernel bridges that collide with the fixed `wg` subnet. That was
the cause of the stage-7 `wg.ayc` 502, and deleting the bridges proved it.
**BBR** was measured with an interleaved A/B, confirming the congestion
control on each run's socket. Peak throughput was identical (~440 Mbit/s).
Cubic dropped ~20% after loss bursts on 3 of 6 runs; BBR did not drop on any
of its 3. BBR is adopted separately as v2-79 (DD-111).

**2026-09-10 — v2-77, A1 closed (and a claim of ours withdrawn):** the fix that
was planned for A1 — narrowing dnsmasq from `interface=lo` to
`listen-address=127.0.0.1` — was tested before implementing and its premise
failed. With resolved stopped and `127.0.0.53` completely free, dnsmasq was
restarted and did **not** take it: `bind-dynamic` binds the addresses *assigned
to* an interface, and `lo` carries only `127.0.0.1/8` and `::1/128`, so the
"start-order bind race" the review claimed cannot happen. The binding change
would have bought nothing and dropped `[::1]:53`; it is withdrawn and
`os-aware-review.md` §4 is corrected. What remained real is that the installer
wrote a setting this release ignores and called it success, so v2-77 reads the
achieved stub state back and reports it either way (**DD-109**), with no
binding change. Live on Ubuntu 26.04: the line appears immediately, run exits 0.
The opposite branch cannot occur where the key is ignored, so it plus a missing
`ss` were exercised in isolation; the wait is wall-clock bounded.
**Debian re-verification of v2-77 is outstanding** — the resolved block is
skipped entirely there, so the change is a no-op by construction, but nrm is
Ubuntu now and that is an argument, not a measurement.

**2026-09-10 — v2-76 accepted on Ubuntu 26.04.1 (nrm reinstalled as resolute):**
closes the gap left at v2-75. Fresh install from bare metal in 95 s, no-op
re-run (6/6 container ids identical), seeded release-change run, cold reboot,
post-reboot re-run — all exit 0, 0 failed units, every §14 check passing.
With the Debian run, **each capability probe is now measured on both branches**:
resolved active (drop-in written) vs inactive (block skipped); stub symlink
repointed vs absent; needrestart present vs absent; iptables present vs
deferred; `debian-keyring` installed vs not. DD-103 measured rather than
assumed — zero needrestart journal records and `sshd` kept its boot timestamp
through a first-install full-upgrade, while every other service start mapped to
an installer stage. DD-102's resolv.conf lifecycle confirmed end to end:
repointed at install, replaced by Tailscale after the reboot, and correctly a
no-op on the next run. **A1 is a standing Ubuntu 26.04 defect, not an upgrade
artifact** — reproduced on a fresh install and across a reboot; still benign,
still deliberately unfixed.

**2026-09-11 — v2-76, OS-divergence inventory (no behaviour change):** after
the Debian regression, the distro-dependent surface was made enumerable rather
than forked. Measured first: of 1159 lines exactly one is a real
`if OS = debian` branch, two are identity-substituted repo URLs, five are
capability probes — so a per-distribution fork would duplicate ~1150 lines to
isolate ~10, double every OS-agnostic fix (5 of this week's 6 DD entries), and
break the single-artifact export model, without creating any test coverage.
Instead: `# OS-DIVERGENCE: <slug>` markers in code, a delimited table in
`architecture.md` §7.1, and bats asserting the two sets are equal with a `DD-*`
on every row. Added the missing `resolved-stub` coverage. Both new tests were
verified by mutation (remove a marker / a table row / a DD citation / move
`DNSStubListener` outside the probe — each fails). A1 stays open.

**2026-09-08 — v2-75, Debian 13 acceptance (nrm reinstalled as trixie):** the
Debian run immediately caught a v2-74 regression: a minimal Debian image ships
**no `iptables` at all**, so the stage-0 netfilter gate died before stage 1
could install it — fresh Debian installs were impossible. Ubuntu ships the
package preinstalled, which is why its acceptance missed it. Fixed as a
two-phase `check_nft_iptables optional|required` (**DD-108**), with the rule
recorded: an early gate may only assert what the host arrives with. Nothing
else needed changing; a dry run of stage 1's package set on trixie resolved
cleanly (`dnsutils` → `bind9-dnsutils`).
Fresh install on a bare trixie host: stages 0–7 in 90 s, exit 0; re-run a
7 s no-op with 6/6 container IDs identical; cold reboot with `99-zz-*` sorting
after the provider file and `ip_forward=1`; post-reboot re-run a no-op; a
seeded `ubuntu/noble/24.04` proved DD-104 on Debian too. All Debian probe
paths confirmed rather than assumed: resolved **inactive** (block skipped,
no drop-in created), no needrestart, no ufw, `debian-keyring` installed.
**Both supported distributions have now had the same acceptance** (trixie
systemd 257 / kernel 6.12; resolute systemd 259 / kernel 7.0).
Steps 6 (dnsmasq `listen-address`) and 7 (BBR/`fq`) still deliberately not
taken; both need before/after measurement on both OS families.

**2026-09-06 follow-up:** Per user request, backup transfer between already
provisioned v73 Debian/Ubuntu hosts no longer requires matching image IDs.
Differences warn by default; `--allow-image-change` is a compatibility no-op.
There is no backup OS/release gate; the installer's OS matrix is unchanged.
Keep actual user/group/port, mount and archive checks, recovery snapshots and
rollback. The suite and existing 11-file settings backup passed on Debian and
inside disposable Ubuntu 24.04/26.04 containers; these are isolated file and
rollback tests, not application-version migration guarantees. Live `nrm`
archive/target check passed; no production restore was performed.

**2026-09-06:** Fixed a false restore UID/GID incompatibility: the saved
qBittorrent environment listed `PGID=1000` before `PUID=1000`, while the
live `nrm` listed them in the opposite order. Normalize both sides when
checking existing schema-1 backups; retain real user/group/port checks and
print field-specific mismatch details. The regression failed with the old
helper and passed with the fix. Existing snapshot
`backup/20260905T174849Z-nrm-settings.iGQ0JK/settings.tar.gz` passed the live
non-mutating target check and isolated 11-file restore/hash/ownership/mode
verification. No production restore or installer change was made. Bash
syntax and ShellCheck passed; Bats: 80 passed, 3 skipped (no local `timeout`).

**2026-09-05:** Added separate `container-backup.command` and Linux helper
`dev/container-backup-remote.sh`. Scope: Portainer data, FileBrowser DB/config,
wg-easy DB/keys/config, qBittorrent `qBittorrent.conf` only. Backups are private,
unencrypted and Git-ignored under `backup/`; no installer seed integration.
Initial live snapshot: `backup/20260905T173254Z-nrm-settings.nceicd/settings.tar.gz`.
All 11 data files passed isolated restore/hash/ownership/mode verification;
production restore was not performed. See `docs/container-backup.md`.

**v2-73 in [Unreleased] (2026-08-30):** Ubuntu 26.04's nft-default host did
not load the legacy IPv4 `ip_tables`/`iptable_nat` modules required by
wg-easy's in-container `iptables-legacy`; `wg-quick up wg0` therefore failed
at its IPv4 NAT rule. Stage 4 now preloads and boot-persists those modules
alongside `wireguard`, `ip6_tables` and `ip6table_nat` (**DD-10**). The live
host recovered after loading both modules and restarting only wg-easy. A
v2-73 default re-run preserved all six container IDs/start times; a cold
reboot then loaded all five modules through `systemd-modules-load`, brought
wg-easy up healthy on UDP 61001 with no current-boot iptables errors, and
passed firewall, dual-path DNS, Caddy, authenticated/read-only WebDAV and
zero-failed-unit checks.

**v2-72 (2026-08-29):** Ubuntu 24.04/26.04 LTS support —
`require_supported_os` matrix, repo lines from `os-release`, ufw gate,
resolv.conf stub repoint, dpkg-lock wait (**DD-102**). **Live-verified on
both Ubuntu lines:** noble 24.04.4 on 2026-08-29 and resolute 26.04.1 on
2026-08-30. The resolute run covered a fresh install through stages 0–7,
independent contract checks, a byte/container/service-stable re-run,
Tailscale and Docker restart recovery, firewall re-application, and a full
reboot. Six containers, dual-resolver DNS, Caddy, authenticated/read-only
WebDAV and host DNS all passed. On reboot Tailscale may replace the stage-6
uplink symlink with its direct-mode MagicDNS `resolv.conf`; this is expected
and host DNS remains healthy. Last release: **v2-71** (2026-08-28, tag
`2026.08.06-v2-71`) — pull disk floor, single-pass downloads repair,
plus the v2-65…70 line (**DD-98…101**).

| | |
|---|---|
| Version | `2026.08.06-v2-79` (unreleased) |
| Branch | `quantum` |
| Last tag | `2026.08.06-v2-71` |
| Tests | 95 Bats: 92 passed, 3 skipped (no workstation `timeout`); isolated backup tests passed |

### Operator preferences (locked)

- Do not restore `watch-tailnet-addr`.
- Do not shorten `refresh-tailnet-config.timer`.
- No reconcile / master-compose / iptables-persistent revival.
- `MASTER-INPUT` already accepts Tailscale UDP `${TAILSCALE_UDP_PORT}`
  (**DD-73**); do not treat that as a missing rule.
- No `COMPOSE_PROJECT_NAME` change on provisioned hosts: named volumes
  (`qbit_config`, `wg_easy_data`, …) live under the project-name prefix
  and would be orphaned. The host-wide prune trade-off stays as decided
  in **DD-99**.

### Evaluated and rejected (2026-08-28 review)

- Gating `apt-get install` calls on dpkg state — would silently drop the
  "re-run refreshes docker/tailscale to the current repo version"
  behaviour.
- Timestamp/state gating of the downloads-tree repair — reconcile-engine
  shaped; the single-pass find is the accepted optimization instead.
