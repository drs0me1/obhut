# Architecture

## Overall architecture

`install.sh` provisions a single Debian 13 (trixie) host as a Tailscale
exit-node plus a fixed Docker Compose service bundle, and leaves behind a
continuously self-healing reconcile loop. This section describes the
system as it exists today, derived directly from reading the script.
Nothing here is aspirational: the one document that was
(`docs/profiles.md`) describes a model that was closed as won't-do on
2026-07-28 and is retained only as a design note.

### Installation stages

The script runs as seven sequential stages (0–7), gated by
`progress_stage_begin` / `progress_stage_done`, under `set -Eeuo pipefail`
with `ERR`/`EXIT`/`INT`/`TERM` traps for cleanup:

| Stage | Lines (approx.) | Purpose |
|-------|-----------------|---------|
| 0 | 694–818 | Interactive prompts: downloads path, optional local DNS domain; confirmation summary. Tailscale login is always interactive (browser) unless the host is already connected; wg-easy admin setup is not prompted for here — it's done manually via the web UI after install |
| 1 | 819–912 | Base OS prep: apt/timer quiescing, timezone, `apt-get update` → `full-upgrade` → base packages (in that order, so the base packages arrive already current and are not upgraded twice) |
| 2 | 913–1369 | UDP-socket-buffer sysctl (written **before** the Tailscale package install — see M11/DD-19), Tailscale install, forwarding sysctl, UDP GRO tuning (`tailscale-udp-gro` helper at `983–1055`), bounded interactive login requesting `--advertise-exit-node --ssh` with persistent-410 early recovery (`tailscale_login_state` at `1120–1157`, DD-37/DD-42/DD-43), reliable deleted-node journal classification (DD-39/M12), exit-node + Tailscale SSH + stateful filtering + netfilter configuration |
| 3 | 1370–2003 | Docker install, `daemon.json` DNS override, generation of the `docker-tailscale-fw` firewall helper (`1464–1954`, ip6tables required up front — DD-45/M5) and its systemd unit |
| 4 | 2004–4323 | Data directories, startup-only `filebrowser.yaml` policy with restart/recreate activation tracking (DD-40/M13), `compose.yaml` + `.env` generation, `master-compose-ipv4` (`2286–2327`) and `master-network-reconcile` (`2357–4130`) helpers, `master-docker-netfilter-recovery` (`4134–4180`), `master-webdav-serve` (`4227–4281`), systemd units for Compose, WebDAV and reconcile |
| 5 | 4324–4408 | Image pull, systemd dependency graph verification, changed/unhealthy FileBrowser recreation, firewall + Compose stack startup |
| 6 | 4409–4733 | Transactional Tailnet-only `dnsmasq` + Caddy provisioning (unconditional since `V1-8`) with six-path file rollback (`DD-38`, `H9`; `caddy-tailnet-env` at `4513–4545`), then verified generation construction and atomic `current` pointer publication for the nine-entry canonical bundle (DD-14, DD-32, H8) |
| 7 | 4734–5415 | Full runtime verification (systemd properties, firewall rule content, container/service health, DNS/WebDAV endpoints) and final summary |

(Line numbers as of `install.sh` 5415 lines — `Q1-33`, 2026-08-04.
They drift with every change; regenerate with
`grep -n 'progress_stage_begin [0-7] '` rather than trusting them after a
batch of edits. **This has now drifted six times**: 18 lines across
stages 5–7 before `V1-11` caught it; again in `V1-15`, where a block added
above stage 1 shifted stages 0–4 by 14 lines while only the tail of the
table was refreshed; and again across the whole `quantum` line, where the
table still described `V1-20` at 5305 lines while the file had grown to
5678 — stage 4 alone was understated by 348 lines and every embedded-script
reference in it was wrong. Regenerating the *whole* table is the only
reliable move; patching the rows you think changed is what caused all
three. `Q1-14`/`Q1-15` added 167 lines inside stage 2 and moved every
boundary from stage 3 onward, which is exactly the shape that produced the
`V1-15` drift — this table was regenerated whole rather than patched.
Q1-16 then changed Stage 4's reconcile helper and Stage 6's publication
path together. Q1-17 added rollback helpers before every stage and the
transaction boundary inside Stage 6. Q1-18 inserted the tested journal
classifier inside Stage 2. Q1-19 changed Stage 4's FileBrowser policy
lifecycle and Stage 5's update path; the complete table was regenerated
again after all four revisions. Q1-20 then changed reconcile control flow,
Compose recovery and audit throttling in Stage 4, plus WebDAV dependency
verification in Stages 4/7. Q1-21 then added the structured login classifier
and post-success gate inside Stage 2; the table was regenerated whole once
more.)

Stage 0 is the only interactive stage; once the user confirms, output is
redirected to a root-only log file (`/var/log/master-setup/`) and the
terminal shows only a compact progress bar for the remainder of the run.

Note: as of 2026-07-27, wg-easy's admin/peer configuration is intentionally
**not** automated — the script only provisions the container, port, volume,
network, and firewall rules. The user creates the admin account through
wg-easy's own web UI on first access, the same as Portainer. See
`docs/design-decisions.md` (DD-7) for the history of this decision.

### Systemd unit graph

Custom units created by the script, and their key relationships:

```
tailscaled.service ──Wants/Before──> docker-tailscale-fw.service
                    ──Wants/Before──> master-compose.service
                    ──Wants/Before──> caddy.service (optional)

docker.service      ──Wants───────> docker-tailscale-fw.service
                    ──Wants───────> master-compose.service

docker-tailscale-fw.service ──Requires/After/PartOf──> docker.service, tailscaled.service
                            ──OnFailure──────────────> master-network-reconcile.service

master-compose.service     ──Requires/After/PartOf──> docker.service, docker-tailscale-fw.service, tailscaled.service
                           ──OnFailure──────────────> master-network-reconcile.service

master-network-reconcile.timer ──(every 20 min)──> master-network-reconcile.service
master-network-reconcile.service ──After──────────> docker.service, tailscaled.service
                                  ──(may start)────> master-docker-netfilter-recovery.service

master-webdav.service      ──Wants/After/PartOf──> tailscaled.service
                           ──RequiresMountsFor────> $DOWNLOADS_PATH/media
                           ──OnFailure──────────────> master-network-reconcile.service

dnsmasq.service / caddy.service ──Wants/After──> tailscaled.service
                                 ──OnFailure───> master-network-reconcile.service
caddy.service ──PartOf──> tailscaled.service
```

**Confirmed intentional by the user (2026-07-27):** the `PartOf` coupling
(restarting `docker`/`tailscaled` cascades into the firewall, Compose
stack, and Caddy) is a deliberate choice to enforce strict ordering — not
an oversight. It's now called out explicitly in the final install summary.

**The installer opts out of that cascade for its own jobs (`Q1-33`,
DD-51).** The coupling runs both ways: two `tailscaled.service.d` drop-ins
(`98-master-stack.conf`, `99-caddy-tailnet.conf`) declare `Wants=` on the
same four units, so a *start* job for `tailscaled` pulls them and a
*restart* job propagates through `PartOf=` to them. That is correct at
runtime and wrong during Stage 2 of a **reinstall**, where both drop-ins
already exist on disk while the configs they refer to have not been
rewritten yet. Stage 2 therefore starts `tailscaled` only when it is not
already running, and uses
`systemctl restart --job-mode=ignore-dependencies` for the login retry
loop's daemon reset — the daemon gets bounced, the stack does not. Nothing
about the runtime graph changes; only the jobs the installer enqueues.

Key design point: `master-network-reconcile.service` deliberately does
**not** sit in the `After=` chain of `docker-tailscale-fw.service` or
`master-compose.service`, to avoid a self-ordering wait when it restarts
them from inside its own `OnFailure`-triggered execution.

#### The `OnFailure` arc, and what closes it

The five `OnFailure=` edges above all point at reconcile, and reconcile
restarts all five units. Every edge therefore runs in both directions, and
the loop is closed by three separate mechanisms — worth stating in one place
because no single one of them is sufficient (DD-49):

1. **A synchronous failure cannot spin.** When reconcile's own `systemctl
   restart X` fails, X enters `failed` and raises an `OnFailure` start job
   for reconcile *while reconcile is still active*. systemd merges it into
   the running job, so no second run follows.
2. **The arc terminates at reconcile.** `master-network-reconcile.service`
   carries neither `OnFailure=` nor `Restart=`, so a failed reconcile
   triggers nothing and does not retry itself.
3. **The repair cooldown brakes the asynchronous case**, which is the one
   that can actually loop: a daemon that starts cleanly, lets reconcile exit,
   then dies seconds later trips `Restart=on-failure`, hits its start limit,
   fails, and fires `OnFailure` with reconcile inactive — invoking reconcile
   immediately rather than on the twenty-minute timer. Every restart of an
   arc unit goes through `restart_budget_available` (15 minutes per target,
   stamped under `/run/master-network-reconcile/`), so that path costs one
   restart per quarter hour rather than one per event.

`systemctl reset-failed`, which the daemon restart paths call first, clears
systemd's own `StartLimitBurst` counter — that is why the cooldown rather
than the start limit is the load-bearing brake. `reset-failed` is kept
because a unit parked in "start request repeated too quickly" could otherwise
never be recovered; it is simply unreachable until the budget allows.

Two restarts are deliberately outside the cooldown. `systemctl start
master-compose.service` when `COMPOSE_INACTIVE` is set — the whole stack is
down there, and each attempt is already bounded by `--wait-timeout 180`
under `TimeoutStartSec=330`. And `docker-tailscale-fw.service`, which runs
only under `STACK_RESTART_REQUIRED`, a flag an earlier block sets behind the
budget. A Tailscale address change and a canonical config restore also
bypass the cooldown, because neither is a failure signal and both leave the
daemon wrong until it restarts.

### Firewall model

The `docker-tailscale-fw` helper (generated at `install.sh:1828-2372`,
deployed to `/usr/local/sbin/docker-tailscale-fw`) builds two dedicated
chains:

- `MASTER-DOCKER` (filter table, jumped to from `DOCKER-USER`)
- `MASTER-TS-FORWARD` (mangle table, jumped to from `FORWARD`, ahead of
  Docker's own filter-table jumps)

Both are built using an atomic **staging-chain swap**: a new, randomly
named chain (`MASTER-NEXT-$RANDOM` / `MASTER-TS-NEXT-$RANDOM`) is fully
populated first, spliced in as the first jump target, and only then is the
old chain torn down and the new one renamed into its canonical name. This
means the firewall is never briefly wide-open or briefly fully blocking
during an update.

Default posture is fail-closed: any WAN → Tailnet or Tailnet → Docker/LAN
traffic not explicitly allowed is dropped. The one broad ACCEPT is the
exit-node path itself (`tailscale0` → detected WAN interface, marked and
accepted in both the mangle and filter tables so Tailscale's own
`ts-postrouting` MASQUERADE still applies). Only two narrow allows exist
beyond that:

- qBittorrent's peer port (TCP+UDP) DNAT'd to the public IPv4
- wg-easy's WireGuard UDP port DNAT'd to the public IPv4

Both are WAN → Docker. As of `V1-3` the **Tailnet → Docker direction has
no exceptions at all**: the one that existed — SFTPGo's WebDAV TCP port,
allowed only for packets whose original destination (via `--ctorigdst`)
was the current Tailscale IPv4 — disappeared when WebDAV moved to a host
service, whose traffic arrives on the INPUT path the guard chain never
sees. See DD-20.

### Network topology

- WAN interface and public IPv4 are auto-detected via `ip route get
  1.1.1.1` (`detect_ipv4_route`, reused by the firewall helper and the
  reconcile script).
- Tailscale IPv4 is read from `tailscale0`'s global-scope address.
- Both addresses are dynamic: `master-compose-ipv4` (an `ExecStartPre` for
  `master-compose.service`) and the reconcile timer keep
  `/root/docker/.env`, the firewall rules, and (if enabled) dnsmasq/Caddy
  bindings in sync whenever either address changes.
- `wg-easy` runs on its own Docker bridge network (`wg`,
  `10.42.42.0/24` + a ULA `/64`) rather than the default bridge, isolating
  its internal WireGuard routing from the other five containers.

### Service inventory

See `README.md` → **Docker Services** for the full table of images, ports,
and volumes. All five containers (Portainer, Filebrowser, qBittorrent,
Unpackerr, wg-easy) are defined in one generated
`/root/docker/compose.yaml` with upstream channel tags whose resolved
digests are recorded in `state.env`. WebDAV is the sixth
service but is **not** a container: since `V1-3` it is `master-webdav.service`,
a hardened host unit running `rclone serve webdav` read-only against
`$DOWNLOADS_PATH/media`, bound to the Tailscale IPv4 only (DD-20). Since
`Q1-20` the host unit carries its own `RequiresMountsFor` dependency on that
media path, so a late or failed storage mount cannot expose the empty
underlying directory as a healthy WebDAV tree (DD-41/M15).

`qbittorrent` and `unpackerr` (2026-07-28, **M1**) run with `cap_drop:
[ALL]` and `security_opt: no-new-privileges`. `unpackerr` (already
non-root) also runs `read_only: true` and keeps hardware-sized
`mem_limit`/`cpus` ceilings; `qbittorrent`'s ceilings were removed the
same day after real high-throughput usage showed each raise was chasing
the workload rather than bounding it (see `SECURITY_REVIEW.md` M1 for
the accepted residual risk). `qbittorrent` gets back the
minimal capability set its linuxserver.io entrypoint needs to fix
`PUID`/`PGID` ownership on first run (`cap_add: [CHOWN, SETUID, SETGID,
DAC_OVERRIDE, FOWNER]`) — `read_only` was tested and found to break that
same mechanism (files end up owned by the image's default UID/GID
instead of `1000:1000`), so it's deliberately not applied there. See
`SECURITY_REVIEW.md` (M1) for how these were determined.

### Reconcile and self-healing

`master-network-reconcile` (generated at `install.sh:3031-4966`, 1934
lines) accepts three modes: the default `reconcile` (detect + repair),
`--check` (read-only drift report, used by Stage 7 and by `--status`),
and `--status` (added `V1-2`): a lock-free, read-only one-screen summary
— installed version + script SHA256 from `state.env`, per-container
state/health, failed systemd units, downloads-disk usage, the
`/run`-based repair stamps, and a full `--check` run whose exit code the
mode passes through. It runs every 20 minutes via
`master-network-reconcile.timer` and
checks, in order: WAN/Tailscale address drift, IP forwarding sysctls,
**space on the filesystem backing `$DOWNLOADS_PATH`, in bytes *and* in
inodes*** (bytes added 2026-07-28 via `disk_space_ok()`, inodes `Q1-8`
via `inode_space_ok()`, both at 90% and neither auto-repaired, since
deleting user data isn't a safe automated action; the two are separate
because a filesystem can be empty in bytes and full in inodes — measured
on the target at 1% bytes / 100% inodes, where the byte check reports
healthy while every new file gets `ENOSPC`), Tailscale preferences and netfilter backbone, the dedicated
firewall chains (via `docker-tailscale-fw --check`), Docker's own
DNAT/FORWARD rules, Compose container health and port bindings, the
canonical config-file bundle (state, `compose.yaml`, the FileBrowser
Quantum policy file, dnsmasq and Caddy — nine entries since `Q1-9`), **the
host WebDAV service** (added `V1-3`, unconditional — unlike Caddy/dnsmasq it does not
depend on the local-DNS option), and — if local DNS is enabled — live DNS
and Caddy HTTP responses. WebDAV is checked on two independent signals,
the same shape as UDP GRO's: whether `master-webdav.service` is active,
and whether a real `PROPFIND` request (`Depth: 0`) to the *current*
Tailscale IPv4 returns 401. `PROPFIND` rather than `OPTIONS` because
rclone does not authenticate `OPTIONS` at all and answers it 200 — the
`V1-6` live test found all three of the installer's 401 probes were
measuring a method rclone leaves open, where sftpgo had returned 401.
The second signal catches the case the first cannot — the unit
reading `active` while `rclone` is still bound to a Tailscale address the
host no longer holds, which is exactly what a node re-registration
produces. Repair is `systemctl restart`, whose `ExecStart` re-resolves the
address. It also guards UDP GRO
(added 2026-07-29) on two independent signals: whether
`tailscale-udp-gro.service` is active, and whether the `ethtool` flags on
the IPv4 WAN interface are actually set. The unit is `Restart=no`, so a
boot-time failure would otherwise persist until the next reboot; and
because the unit uses `RemainAfterExit=yes`, flags cleared without the
unit failing would leave it reading `active` while the optimization is
gone. Repair for either signal is `systemctl restart`, keeping systemd the
single execution path. Both checks sit outside
`all_critical_state_healthy()` and do not affect the exit code, because
UDP GRO is a throughput optimization rather than a connectivity
precondition — see DD-11.

Q1-20 separates transient overlap from a persistently unhealthy host.
A lock collision or an already-active OnFailure job is deferred with a
successful timer result; inactive Docker/tailscaled or missing WAN/Tailscale
addresses now fail non-zero. Address reads get a bounded 30-second startup
grace. On failure the helper prints Docker/tailscaled state and Tailscale's
backend, self-online, health and key-expiry fields, but does not restart or
reauthenticate core daemons from inside the reconcile unit (DD-41/H10).

Compose integrity is intentionally asymmetric. Content changes to an existing
safe file remain report-only as an operator-owned edit. A missing file is
restored atomically from the verified canonical generation, owner/mode drift
is repaired, and a directory, symlink or other unsafe target fails closed.
The reconcile unit no longer has `ConditionPathExists=compose.yaml`, because
that condition prevented the only bounded repair path from running
(DD-41/H11).

These Q1-20 boundaries were live-verified before R2.5: an R2.4 upgrade and
unchanged rerun both completed 7/7; missing/edited/metadata/symlink Compose
states behaved as described without container restarts; and an active but
offline Tailscale daemon failed after exactly 30 seconds with structured
diagnostics. Returning the same node/IP and running the existing recovery
ended with every drift flag zero and no failed units.

The exact export was later run from scratch after a clean Debian 13 reimage.
The interactive browser authorization completed in the original installer
process, the resulting node was online and offering exit-node service, and an
immediate unchanged rerun retained the identity and every container start
time. This exercises the first-install control-plane path as well as the
upgrade path above.

Two checks are specific to the `quantum` line and were added after the
`Q1-8` review.

**The FileBrowser Quantum policy file** (`/etc/master-stack/filebrowser.yaml`)
is the ninth bundle entry (`Q1-9`, DD-32). Unlike `compose.yaml`'s
report-only treatment it is *restored* from the canonical copy and
followed by a budgeted container restart, because Quantum reads its config
only at startup and nothing from outside distinguishes "drifted file
already loaded" from "not yet loaded". Before this, editing the file moved
no signal at all — measured `config=0`, `rc=0` — and the change went live
on the next restart, which reconcile itself performs as routine repair.

**The default filebrowser password** is probed at most once per 24 hours by
`report_default_filebrowser_password()` (DD-30, revised by DD-33 and DD-41).
Only normal reconcile mode may issue the real login POST, and only while the
container is running; `--check` and `--status` remain side-effect-free. An
atomic root-only `/run` stamp is recorded before the request to bound retries.
It is
reported, never counted: `admin`/`admin` on a fresh install is the
expected state, and failing on it would train people to ignore the exit
code. What makes it worth a check is that the state can *return* after
install — deleting the volume makes Quantum re-run `quickSetup()` — and no
other signal notices. The probe lives outside `probe_compose_runtime`
because that function is called up to four times per cycle, and the login
endpoint is rate-limited **per source IP, not per credential** (6 failures
→ `429`, after which the correct password also returns `429`). A `429` is
reported as *could not be determined*, explicitly not as "the password was
changed".

A wg-easy container still sitting on its `/setup` screen is reported
(`UYARI`) but is deliberately *not* a failure: it sets `WG_SETUP_PENDING`,
which suppresses wg-easy's automatic restart — restarting a container
waiting for its first web setup fixes nothing — without setting
`RECOVERY_FAILED`. Until `V1-11` both conditions shared the single
`WG_CONFIGURATION_INVALID` flag, which produced a signal that lied exactly
when it mattered: a healthy host exited 0 through the
`all_critical_state_healthy()` early return, but the moment reconcile
actually repaired something it fell past that gate and exited 1 *despite
the repair succeeding*. A genuine internal-port mismatch still sets
`WG_CONFIGURATION_INVALID` and still fails, because that one is a real
misconfiguration no restart can fix.

Repairs are scoped and cooldown-gated:

- Container restarts are throttled to once per 15 minutes per container
  (`RESTART_STATE_DIR/*.last-restart`).
- A full Docker daemon restart (via
  `master-docker-netfilter-recovery.service`) is a last-resort remedy for
  Docker-owned DNAT/FORWARD drift, gated by its own 15-minute cooldown and
  only triggered when the lighter-weight checks fail.
- Core daemons (`docker`, `tailscaled`) are never restarted synchronously
  from inside the reconcile pass itself — the script defers to their own
  systemd restart policies to avoid ordering cycles.

Reconcile treats the canonical (installer-written) copies of
firewall/dnsmasq/Caddy configuration as the source of truth: any drift,
including a manual operator edit, is reverted within one 20-minute cycle.
See `docs/design-decisions.md` for the rationale. **Confirmed intentional
by the user (2026-07-27):** this guarantees dnsmasq/Caddy reachability
against accidental or unauthorized drift, and is documented explicitly in
the final install summary so operators aren't surprised by it.

### Network-dependent steps: bounded retry, mandatory timeout

Every step that talks to the network goes through `retry_network`
(`install.sh:256`): three attempts, an explicit per-attempt `timeout`, and
a 5s/15s backoff. Applied at five call sites — `apt-get update` (four
occurrences), the Tailscale keyring and repo list, the Docker GPG key, the
Caddy GPG key and repo list, and `docker compose pull`.

**The timeout matters more than the retry**, which is the inverse of how
L8 was first framed. The script runs under `systemd-inhibit
--what=shutdown:sleep --mode=block` and holds the `flock` it shares with
reconcile, so a single hung download blocks shutdown *and* leaves the
20-minute reconcile timer unable to run, indefinitely. The Docker Hub 502
that prompted this failed loudly and safely — the install stopped and the
immediate re-run succeeded. A hang would not have.

**No error classification.** Permanent failures (`manifest unknown`,
`unauthorized`, a full disk) return in seconds, so three blind attempts
cost them ~20s of backoff before the same clear error. Only transient
faults and hangs consume real time, and those are the target. Matching
stderr text would be locale- and upstream-format-dependent for no gain.

Budgets were chosen against measured baselines rather than guessed
(2026-07-31, on the netcup host): cold `docker compose pull` 10.9s for
885 MB across three registries, warm pull 3.2s, `apt-get update` 0.9s,
keyring fetches 36–127 ms. Bulk transfers get 300s then 180s — ~27× the
measured cold pull — and small fetches 60s then 30s. Worst case for a true
hang at the pull is about 11 minutes instead of forever.

One measurement worth keeping in mind: **the warm pull still takes 3.2s**,
because it re-checks manifests at all three registries. The pull step is a
hard network dependency on *every* run, including runs where nothing has
changed — which is exactly how a transient registry fault reached an
otherwise no-op re-run.

`apt-get full-upgrade` and `apt-get install` are deliberately **not**
wrapped: they drive dpkg transactions, and interrupting and reissuing one
is a different problem class that interacts with `--force-conf*`. Wrapping
them would move the risk, not reduce it.

### Re-running the installer

`install.sh` is the upgrade path; there is no separate upgrade script,
and adding one would mean a second copy of the canonical
unit/firewall/Compose/DNS definitions when the whole self-healing model
depends on there being exactly one.

Measured on 2026-07-31 against a healthy host: **25 seconds, zero
container restarts** *when no image tag has moved.* All five `StartedAt`
timestamps identical before and after, the wg-easy peer and `wg0` listen
port intact, Portainer's `InstanceID` unchanged, `webdav.htpasswd`
untouched, `--check` rc 0.

Since `V1-12` the qualifier matters: image tags float (DD-23), so
`docker compose pull` can fetch a newer image and `up -d` will then
recreate **exactly those containers whose image actually changed** — the
others still keep their uptime. A re-run is therefore a no-op when
nothing upstream has moved and a scoped upgrade when something has.

That is a property of the unit design rather than a happy accident.
`master-compose.service` is `Type=oneshot` with `RemainAfterExit=yes`
and **no `ExecStop`**, so Stage 5's `systemctl stop master-compose` marks
the unit inactive without signalling the containers; the following
`docker compose up -d --wait` then converges to the same state and does
nothing. Containers are only recreated when `compose.yaml` genuinely
changes. `master-webdav` is the one service restarted unconditionally,
because its unit definition or its `LoadCredential` source may have
changed — a second or two of WebDAV unavailability.

What a re-run rewrites regardless: `compose.yaml`, every embedded helper
script, every systemd unit, the firewall chains, the dnsmasq/Caddy
configuration and the canonical bundle. What it preserves: the media
tree, `/data/*` (wg-easy keys and peers, Portainer's database,
qBittorrent's session), `webdav.htpasswd`, the Tailscale node identity
and login, and gid-1000 group membership.

Stage 6 is transactional across the six dnsmasq/Caddy managed paths. Their
pre-run content or absence is snapshotted under `/run`; a failure restores
it before restoring the two daemons' entry-time systemd state. The atomic
canonical `current` swap is the commit point, because that is when the new
live files and new integrity source first become one consistent pair
(DD-38/H9). Package installation itself is intentionally not rolled back.

Two consequences worth stating plainly:

- **Manual edits to `compose.yaml` are silently overwritten.** Reconcile
  deliberately only reports Compose drift and never reverts it (M10), but
  `install.sh` rewrites the file unconditionally — the asymmetry is
  intentional and easy to be surprised by. A lasting change belongs in
  `install.sh`.
- **A re-run is the explicit container-upgrade path.** The generated
  `compose.yaml` uses upstream channel tags. `docker compose pull` may resolve
  a newer digest and `up -d` then recreates only the affected containers;
  reconcile itself never pulls images. Upstream aliases can cross release
  lines, so a provider-level snapshot before a planned rerun is the rollback
  boundary for database migrations (DD-23).

### State and configuration files

| Path | Mode | Purpose |
|------|------|---------|
| `/etc/master-stack/state.env` | `root:root 0600` | Live copy of stack configuration (schema version, ports, local DNS domain, wg-easy endpoint, downloads path — the last one added 2026-07-28 for reconcile's disk-space check). Since `V1-2` it also records `STACK_VERSION` and `STACK_SHA256` (the installing script's own hash), so a host self-reports which revision built it; both keys are informational — shown by `master-network-reconcile --status`, required by nothing. `STACK_SCHEMA` is `10` as of `V1-12`, which added the five `IMAGE_DIGEST_*` keys; `9` (`V1-8`) had dropped `LOCAL_DNS_ENABLED` when Tailnet DNS/Caddy stopped being optional. The digest keys are appended after Stage 5 rather than written with the heredoc block, because the images only exist locally once they have been pulled (DD-23) |
| `/etc/sysctl.d/99-tailscale.conf` | `root:root 0644` | IPv4/IPv6 forwarding; content and ownership are verified and repaired by reconcile |
| `/etc/sysctl.d/99-master-stack-netbuf.conf` | `root:root 0644` | UDP socket buffer ceilings (`net.core.rmem_max`/`wmem_max`), floored at 16 MiB and never lowered. Written **before** `apt-get install -y tailscale`, because the package's postinst starts `tailscaled` and `wireguard-go` requests its buffer once at socket-open time (M11). Not reconciled — a `sysctl.d` file survives reboots by construction, so the file on disk is the guarantee (DD-18) |
| `/usr/local/share/master-stack/` | `root:root 0755` | Canonical root. Each complete set of state/`compose.yaml`/`filebrowser.yaml`/dnsmasq/Caddy files plus `SHA256SUMS` lives in a root-owned `.generation.*` directory; reconcile reads through the atomically replaced `current` symlink (DD-14, H8). A generation is verified before it can become current, and the target must resolve inside this root. `compose.yaml` is compared and **reported** on drift but never auto-restored (M10), unlike the policy/dnsmasq/Caddy files |
| `/root/docker/compose.yaml`, `/root/docker/.env` | `root:root 0600` | The Compose stack definition and its dynamic address values |
| `/etc/master-stack/webdav.htpasswd` | `root:root 0600` | WebDAV Basic-auth credential (bcrypt) for `master-webdav.service`, generated in Stage 4 from the Stage 0 prompt. The service reads it via systemd `LoadCredential=`, so the file never needs to be readable by the service user. Deliberately **not** part of the canonical bundle: reconcile must not revert or recreate a credential. Preserved across re-runs — delete it and re-run to set a new one |

wg-easy no longer has any dedicated bootstrap/secret files (removed
2026-07-27, see `docs/design-decisions.md` DD-7) — its admin/peer
configuration lives entirely inside its own container state
(`/data/wg-easy/config`), managed manually by the operator.
