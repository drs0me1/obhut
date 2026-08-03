# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### 2026-08-03 — Tailscale SSH enabled alongside exit-node advertisement (`Q1-23`)

The interactive login now runs `tailscale up --advertise-exit-node --ssh`
instead of a bare `tailscale up`, so a fresh node asks for both the exit-node
role and Tailscale SSH in the same step rather than waiting for the
`tailscale set` that follows.

`tailscale set` keeps carrying `--advertise-exit-node` and gains `--ssh=true`.
It is not redundant: `tailscale up` runs only when a login is actually needed,
so on an ordinary re-run against an already-joined host it never executes.
`tailscale set` is the unconditional, idempotent path. Naming the flags on
`up` also avoids Tailscale's refusal to silently revert non-default
preferences on a re-login where the profile already advertises an exit node.

Tailscale SSH is now part of the node's steady state rather than a one-time
setting: `tailscale_prefs_ok()` requires `.RunSSH == true`, so the 20-minute
reconcile timer sees a lost `--ssh` as drift and repairs it with the same
`tailscale set` it already used for exit-node/netfilter drift.

**Security note.** `--ssh` makes tailscaled answer SSH on the node's Tailscale
address, authenticated by the tailnet's ACL `ssh` block instead of the host's
`authorized_keys`. It is reachable only from the tailnet — the same boundary
that already governs every web interface here — and adds nothing to the
internet-facing surface. What changes is that tailnet ACL policy, not host SSH
configuration, decides who gets a root shell; a new tailnet's default policy
allows members into their own devices as root with a periodic browser check.
Narrow the tailnet `ssh` block if that is wider than you want. The installer
does not edit account-level ACLs. See DD-43.

Not live-verified.

### 2026-08-02 — `R2.6` refreshed to `Q1-22` and tagged before live verification

At the operator's explicit request, `Q1-22` and `R2.6` are tagged **before**
any live install, so the file can be carried to a machine and tested by
hand. This inverts the branch's normal order — every other release was
tagged only after a real run — so neither tag carries a live-success claim,
and the tag messages, `versiyon/R2.6/README.md` and `versiyon/README.md` all
say so plainly.

`versiyon/R2.6/install-R2.6.sh` refreshed from the `Q1-21` candidate to
`Q1-22`; the export is byte-identical to both tags and to `HEAD`. With the
tags now created, that directory's verification recipe returns to the normal
`git show R2.6:install.sh` form rather than being pinned to a source commit.
`R2.5` / `Q1-20` remains the last release that was actually live-verified and
is reachable through its tag.

What *has* been done for `R2.6`: full static verification clean, and every
behaviour changed since `R2.5` carries a unit test that was checked to fail
against the old behaviour. What has not: running it on a server.

### 2026-08-02 — a slow-to-come-online node no longer discards a successful login (`Q1-22`, DD-42)

`Q1-21` gave the node 15 seconds after `tailscale up` exits zero to reach
the fully verified LocalAPI state, and on expiry restarted the daemon and
asked the operator to authorize again. But exit code zero means the login
*succeeded* — so that path threw away a good authorization, which is
exactly the false-positive class DD-37 exists to prevent.

It was also the stricter of two gates for the same condition: the very
next block in Stage 2 already waits 180 seconds for `tailscale ip -4` plus
`tailscale_is_online`, and only the 15-second one had a destructive
remedy. A node that will not come online after an accepted login has a
connectivity problem, not an authentication one; a fresh browser link
cannot fix that, while the 180-second wait either resolves it or fails
with a clear error.

The grace window is now a fast path rather than a ceiling: it returns as
soon as the node is verified, and on expiry prints an explicit hand-off
note and returns success. The `incomplete` outcome is gone.

Covered by a fourteenth case in `test/tailscale_login.bats` (175 → 176),
mutation-verified against the `Q1-21` behaviour.

### 2026-08-02 — Q1-21 exported as an untagged R2.6 manual-test candidate

At the operator's explicit request, Q1-21 was exported before its exact
automatic browser-login recovery branch was exercised on the Debian target.
`versiyon/R2.6/install-R2.6.sh` is byte-identical to `install.sh` from source
commit `a10a300` and reports `2026.08.02-Q1-21`; the previous R2.5 directory
was retired under the single-current-export rule. The self-contained deploy
wrappers and operator README travel with the candidate.

This changes packaging status, not verification status. R2.6 is labelled as
a manual-test export throughout, while R2.5/Q1-20 remains the latest
live-verified tagged release. No `R2.6` or `Q1-21` tag was created. A later
successful manual run may close out and tag this exact installer; a failure
must produce a new installer revision rather than rewriting this candidate's
recorded identity.

### 2026-08-02 — persistent Tailscale auth-path death is recovered immediately (`Q1-21`, DD-42, M16)

A clean-image install reproduced the operator's original complaint twice in
one run without restarting the installer. Two distinct nodekeys and browser
links were authorized; each created an offline admin-console entry, while the
daemon remained `BackendState=NeedsLogin`, `Self.Online=false`, with an empty
node ID/IP and the LocalAPI health message `register request: http 410: auth
path not found`. The failures arrived 27 and 42 seconds after their links were
issued. Terminating only the second wedged `tailscale up` child exercised the
existing retry path immediately; its daemon restart produced a third link,
which registered successfully as `Running/Online`, and the exact R2.5 install
then completed 7/7 with five containers, reconcile rc 0 and no failed units.

Q1-15's five-minute timeout remains the fallback for slow operators,
unreachable control planes and every unknown stall. Q1-21 adds a structured
LocalAPI classifier instead of returning to journal parsing. Early recovery
requires three consecutive two-second samples that simultaneously show
`NeedsLogin`, offline, an empty node ID and the exact 410 health substring; any
different sample resets the counter. A successful `tailscale up` must now also
produce `Running`, online, a non-empty node ID and at least one Tailscale IP
within a 15-second grace period before the login function returns success.

Thirteen new cases pin the observed JSON shape, incomplete/unknown states, the
successful transient-410 case, the three-sample restart and the one-sample
reset. The suite grows 162 → 175 across thirteen files; `scripts/check-all.sh`
is clean with 12 expected macOS skips. The installer reports
`2026.08.02-Q1-21` and SHA256
`10b746f891f908f98efd92204a8c238c9e46eb500745c9daf68462d9ae3ccaf8`.
The failure signature and the equivalent early child-termination/restart path
were measured live; the exact Q1-21 automatic branch has not yet been run
through a fresh browser authorization, so no live-success or release-tag claim
is made. It was subsequently exported untagged for the operator's manual test.

### 2026-08-02 — correction: `server.database` does exist (DD-27)

Documentation only, no code change. DD-27 claimed there is no config key
for FileBrowser Quantum's database path, "so the environment variable is
the only surface". Wrong: `server.database` is the documented key, and a
newer upstream wording of the first-boot warning names it directly. The
claim came from checking the image's *sample* `config.yaml`, finding no
such key, and generalising to the schema — an inference written up as a
measurement.

The design is unaffected: `FILEBROWSER_DATABASE` is honoured and points at
the right path, so `Q1-12`'s pin still does what it says, and both
surfaces are equally protected as canonical bundle entries. The one rough
edge now recorded is that the policy file does not set `server.database`,
so an operator following the warning's advice opens `filebrowser.yaml` and
finds nothing.

### 2026-08-02 — `Q1-20` closed out and exported as `R2.5`

Live-verified the exact Q1-20 installer on the disposable Debian 13 host,
first as an R2.4 → Q1-20 upgrade and then as an unchanged idempotent rerun.
Both completed all seven stages; the second preserved all five container
`StartedAt` values. Final state was Tailscale `Running/Online`, no failed
units, five running containers and every reconcile drift flag zero.

The Q1-20 paths were then fault-injected. `--check` and `--status` produced
zero FileBrowser login POSTs; two immediate normal reconciles produced one
POST total and one daily stamp. Missing Compose was restored as `root:root
0600` through the real systemd unit without container restarts; edited content
survived, metadata was repaired independently, and a symlink returned rc 1
without being replaced. With tailscaled still active, `tailscale down`
produced `BackendState=Stopped`, `Self.Online=false`, a measured 30-second
wait, `ExecMainStatus=1` and explicit health diagnostics. Returning the same
node online and running the existing firewall/core recovery restored the same
Tailscale IP and a clean check. Repeating that destructive event inside the
15-minute restart budget intentionally failed loudly; the volatile test stamps
were removed and the normal recovery then completed successfully.

Tagged the live-verified installer revision as `Q1-20`, replaced the retired
`versiyon/R2.4/` directory with `versiyon/R2.5/`, and recorded the release on
the close-out commit as `R2.5`. The exported installer is byte-identical to
both repository states and has SHA256
`1762703ecc28e765e454ae32d05a08d3e82a1962734656384a0da12b3a416bb9`.

The same exported file was subsequently tested from scratch after the host
was reset to a clean Debian 13 image. Its live Tailscale browser link completed
in the original installer process, the node came online as an exit-node, and
all seven stages passed with only the expected unfinished-wg-easy warning. An
independent sweep found no failed units, all five containers running,
`master-network-reconcile --check` at rc 0, FileBrowser/Caddy at HTTP 200 and
WebDAV at 401 without credentials / 200 with them. FileBrowser's one-time
missing-database message was followed by `Creating new database` at the
persistent volume path; a controlled restart then logged `Using existing
database`. An immediate unchanged installer rerun preserved the Tailscale
identity, WebDAV credentials and every container `StartedAt` value and again
completed 7/7 without another browser login.

### 2026-08-02 — reconcile no longer hides persistent failures or mutates read-only checks (`Q1-20`, DD-41, H10/H11/M14/M15)

The timer previously used one `defer_or_fail()` path for both genuine
transaction overlap and persistent unavailability. In normal reconcile mode
that helper always returned success, so an inactive Docker/Tailscale daemon or
a missing WAN/Tailscale address could remain unhealthy forever while systemd
recorded every pass as successful. Q1-20 separates transient deferral from
hard failure, allows a bounded 30-second address grace period, and reports
Tailscale `BackendState`, `Self.Online`, health and key expiry without trying
an unsafe automatic logout/login or synchronous core-daemon restart.

`ConditionPathExists=/root/docker/compose.yaml` also made the timer skip the
entire check when the file it needed to diagnose was missing. The condition is
gone. A missing regular target is restored byte-identically from the verified
canonical generation without applying Compose or restarting containers;
modified content remains report-only, metadata is repaired independently, and
directories/symlinks fail closed.

The FileBrowser default-password probe is a real POST login, so `--check` and
`--status` were not actually read-only and the 20-minute timer shared 72 daily
requests with the operator's source-IP rate-limit bucket. The probe now runs
only in normal reconcile mode, only while FileBrowser is running, and at most
once per day using an atomic root-only `/run` stamp. Finally,
`master-webdav.service` now carries
`RequiresMountsFor=$DOWNLOADS_PATH/media`, matching the storage ordering that
already protected Docker/Compose when the media tree is a separate mount.

Fifteen new regression cases cover exit-code classification, address
readiness, Compose path/content states and restoration, audit throttling and
the two unit-file invariants. The Bats suite grows 147 → 162; the full local
verification wrapper is clean with 12 expected macOS-only skips.

### 2026-08-02 — FileBrowser policy repair survives directory mounts and cooldowns (`Q1-19`, DD-40, M13)

The reconcile path copied canonical `filebrowser.yaml` directly to its live
path before checking the restart budget. Two real recovery states broke that
order. If Docker had recreated a missing bind source as a directory, GNU
`install` successfully copied the file *inside* the directory and reported
success; restarting the existing container retained its directory mount. If
the path was a normal drifted file but the restart cooldown was active, the
disk copy became canonical while Quantum kept the old startup-only policy in
memory. The next cycle saw no file drift and never retried the restart.

Q1-19 checks the budget before mutation and keeps a root-only pending marker
until both container health and HTTP respond. Canonical content is staged in
the target filesystem and atomically renamed. A directory, symlink or other
non-regular bind source causes only the `filebrowser` container to be removed
and `master-compose.service` to recreate it; the `filebrowser_data` named
volume is never removed, so the database, users and index survive. Runtime
targets are then remeasured before generic container recovery, avoiding a
second restart and the cooldown collision.

The full installer update path now also compares generated policy content and
metadata. A change removes/recreates only FileBrowser after image pull and
unit verification; an identical healthy container is left untouched. Generic
runtime recovery also recreates an unhealthy FileBrowser, covering the legacy
state where an earlier swallowed removal failure left a stale directory mount
behind a now-regular host path. This closes the separate case where a
successful `install.sh` re-run could publish a new policy file without proving
the already-running container had loaded it.
Eleven regression cases cover normal files, Docker-created directories, absent
containers, daemon/removal failures, action selection, repair ordering and
the installer/runtime recreation couplings. The Bats suite grows 136 → 147.

### 2026-08-02 — deleted Tailscale nodes are classified reliably (`Q1-18`, DD-39, M12)

When a stored Tailscale profile stayed offline for 60 seconds, Stage 2
searched the current run's journal for `node not found`. The check used
`journalctl | grep -q` under global `pipefail`. With enough journal output
after an early match, grep exited immediately, journalctl received SIGPIPE,
and pipeline status became 141: a found match was intermittently reported
as absent. The installer then stopped with a generic control-plane error
instead of clearing the worthless local profile and opening a fresh login.

Q1-18 moves the classifier into a tested helper and uses normal fixed-string
grep with output redirected to `/dev/null`. Grep consumes the whole stream,
so an early match remains true; `pipefail` still preserves a genuine
journalctl failure. The old form was reproduced at rc 141 and the new form
at rc 0 against the same stream. Three regression cases cover a match ahead
of more than a pipe buffer of output, no match, and producer failure.

### 2026-08-02 — failed DNS/Caddy updates restore their files (`Q1-17`, DD-38, H9)

Stage 6 already captured whether dnsmasq and Caddy were active, enabled or
masked, but its EXIT rollback restored only that service-state vector. It
did not restore the six configuration/helper files overwritten before a
later failure. A previously-active service could therefore be restarted
with partial new configuration, or fail to start, while the old canonical
generation remained current.

Q1-17 snapshots those six managed paths under a root-only `/run` directory
before package/config mutation. On failure it stops any currently-loaded
daemons, restores both prior files and prior absence, reloads systemd, and
restarts only the services that were active at entry. The Q1-16 canonical
`current` swap is the transaction commit point: once it succeeds, live and
canonical configuration both represent the new run and rollback is
disabled.

The scope deliberately excludes package uninstall/downgrade and repository
files. Leaving an installed package behind is safe and idempotently handled
by the next run; attempting to reverse apt state would add a much larger and
less reliable transaction. Seven regression cases cover content/absence,
symlinks, unsafe paths, service restart order, commit-point ordering, and
the signal window immediately after the pointer swap; a failed restore is
also required to retain its recovery snapshot for manual intervention.

### 2026-08-02 — canonical bundle publication is actually atomic (`Q1-16`, DD-14, H8)

The Stage 6 code claimed to publish the canonical bundle atomically, but
only the final `SHA256SUMS` rename was atomic; the nine files it described
were copied one by one into the live directory. An interruption between
copies therefore left old and new files mixed behind the old manifest,
causing every later reconcile cycle to stop at its first integrity gate.

Q1-16 builds all nine files plus the manifest in a unique
`.generation.*` directory, verifies the completed generation, and only
then atomically replaces `/usr/local/share/master-stack/current` with a
relative symlink to it. An unpublished partial generation is invisible to
reconcile and the EXIT trap removes it. Regular re-runs retain at most the
active and previous generations.

The first upgrade from R2.4 has an explicit compatibility path: the new
reconcile helper accepts the old flat bundle until Stage 6 publishes the
first `current` pointer. After publication those legacy files are removed,
so a later missing or externally-directed pointer fails closed. Six
regression cases cover generation selection, an incomplete unpublished
generation, an outside-root target, the legacy transition, publish order,
and the existing manifest/source coupling.

### 2026-08-02 — `Q1-15` closed out: tagged, exported as `R2.4`

Tagged `Q1-15` after the live verification described in the previous
entry, and `R2.4` on the close-out commit. Exported to `versiyon/R2.4/`
with the full four files, byte-identical to both tags and to `HEAD`
(`7e2be32d…`), and functionally tested with a real copy-and-verify to the
test host. `versiyon/R2.3/` retired into it, per the rule that a release
directory supersedes the one before it rather than sitting beside it.

**`Q1-14` is tagged but must not be deployed.** It shipped the same
bounded-login feature with the journal-parsing wedge detector that
`Q1-15` removes; the detector can kill a login that is about to succeed.
The `Q1-15` tag message says so, and there is no export for `Q1-14`.

`docs/architecture.md`'s stage table regenerated whole — `Q1-14`/`Q1-15`
added 167 lines inside stage 2 and moved every boundary from stage 3 on
(5726 → 5893 lines). That is the same shape that produced the `V1-15`
drift, which is why the note under the table now records it.

The `Q1` line marker was **not** moved; it still points at the `R2.3`
close-out commit. Moving it means deleting a tag, which is only done on
an explicit request.

### 2026-08-02 — the interactive Tailscale login can no longer hang forever (`Q1-14`/`Q1-15`, DD-37)

Found by a real install wedging at the login step. `tailscale up` was run
bare and waited indefinitely; when the daemon got `410: auth path not
found` it retried the **same dead auth path** forever
(`doLogin(regen=false, hasUrl=true)`) and `tailscale status` kept printing
that dead link as though it were live. The operator's experience was "I
logged in and it is still waiting", with nothing in the script noticing.
Measured: two links, each dead ~13s after issue, four 410 events, and
`tailscale logout` did not clear it — only restarting `tailscaled` did.

The login now runs under `tailscale_interactive_login()`: output streams
to the terminal and the log as before, but if the login has not completed
within 300s the daemon is restarted and a fresh link is printed, up to
three attempts, after which the manual recipe is shown — including the
non-obvious part that `logout` is not enough.

**It deliberately does not try to detect the wedge.** Three versions that
parsed `journalctl` for the 410 were written and all three were wrong, each
caught by running the function against real journal data: a 410 also occurs
during a *successful* login; `journalctl | grep -q` under `pipefail`
reported found matches as failures via SIGPIPE; and an unbounded window let
a later login's success count as recovery for an earlier wedge. A false
positive there kills a login that is about to succeed, so the diagnosis was
dropped in favour of a plain timeout. Full reasoning in DD-37.

Verified with stub `tailscale`/`systemctl` binaries (never-completing login
→ two links, two restarts, correct banners and final recipe; successful
login → returns immediately, no restart) and live on a from-scratch install
plus an idempotent re-run: `STACK_VERSION=2026.08.02-Q1-15`, `--check
rc=0`, five containers, zero failed units.

### 2026-08-02 — three file-manager alternatives investigated, none adopted (DD-36)

No code change. Filestash (proposed as v3), a native non-Docker file manager
with RAR extraction, and Nextcloud in Docker were each researched and each
declined. Written up together in DD-36 because none of them left a trace in
the code, so without the entry the same searches get repeated.

The three findings worth keeping:

- **Filestash's `config.json` is runtime state, not policy** — `Save()` runs
  from `Initialise()`, so it is rewritten on first start. It therefore cannot
  be a read-only bind mount or a canonical bundle entry; reconcile would
  revert admin changes every twenty minutes. Adopting it would have deleted
  the policy-file mechanism this branch is built around. It also publishes
  only `latest`, which is the coarsest float in the bundle.
- **RAR extraction was never a file-manager problem here.** unpackerr already
  watches the whole media tree recursively and extracts rar/zip/7z/iso, so
  any file manager that can write into the tree already gives
  browser-triggered extraction. The one product that extracts RAR itself,
  elFinder, has that exact code path as its CVE history — which is the class
  this project deleted filebrowser's shell-command feature to escape.
- **Nextcloud's blocker is not weight.** Measured first: the host has 7.8 GB
  with 863 MB in use and the five containers total ~130 MB, so it would fit.
  It fails on reading its file list from `oc_filecache` rather than the disk
  — invisible to qBittorrent's and unpackerr's writes until `occ files:scan`
  — and on being unable to skip major versions, which would leave reconcile
  restarting a container it cannot repair.

### 2026-08-02 — `Q1-13` closed out: live-verified, tagged, exported

Verified on the test host *before* tagging, per the convention that tags
follow live verification. The idempotent re-run finished all seven stages
in 28 seconds: `STACK_VERSION=2026.08.02-Q1-13`, `STACK_SHA256` matching
the repository file exactly, `--check rc=0` with every drift flag `0`, no
failed units, five containers up, canonical bundle nine entries with
`sha256sum -c` clean. Stage 7's unpackerr assertion passed with the new
`UN_LOG_FILE_MB=10` entry — its first execution inside a real install.
The containers confirmed both revisions' changes directly: unpackerr now
reports `(3 @ 10Mb)` and `30m` where it reported `(10 @ 0Mb)` and `1m1s`,
and filebrowser carries the pinned `FILEBROWSER_DATABASE`.

Exported as `versiyon/Q1-13/`, byte-identical to the tag and to `HEAD`.
`versiyon/Q1-11/` retired per the standing one-current-directory rule.

The `Q1` line marker was moved on the operator's instruction, from
`Q1-11`'s commit to the branch head — it had fallen two revisions behind.
It now points at the head rather than at a revision tag, because since
`R2.3` the head carries the export directory and the resynced docs as
well as the installer, and `git show Q1:install.sh` returns the same
script either way. `Q1` remains the only tag in this repository that
moves; every `V*`/`Q*`/`R*` tag is a fixed identity.

Tagged `R2.3` on the operator's instruction. What it records is the
close-out: live verification before tagging, the export, and the
documentation resync — the installer is byte-identical to `Q1-13`.

**Export directories are now named after the release, not the revision**
(operator decision, same day, overriding the earlier reading that a
release point gets no directory at all). `versiyon/R2.3/` was created with
the full four files and `versiyon/Q1-13/` retired into it rather than kept
alongside — two directories holding a byte-identical installer is the one
ambiguity the retirement rule exists to prevent, so a release directory
supersedes the revision directory it was cut from. `versiyon/README.md`
now states that rule, and states that a release directory carries the
revision's version string: `install-R2.3.sh` prints `2026.08.02-Q1-13`,
which its own README explains up front so it does not read as a mismatch.
`R2.2` predates this and keeps no directory.

Documentation resynced in the same pass: `docs/architecture.md`'s stage
table regenerated whole (`Q1-12`/`Q1-13` added 48 lines inside stage 4,
moving every boundary from stage 5 on; 5678 → 5726 lines);
`docs/testing.md` gained the run write-up **and** an explicit note that
its Tier 3 log skipped the `Q1-1`…`Q1-11` runs, so the gap is stated
rather than left to look like completeness; `SESSION.md`'s live sections
rewritten, having still described the `v1rc` era — 57 tests, an execution
policy superseded by the standing test-host authorization, and a memory
inventory that no longer matched what exists.

### 2026-08-02 — folding the Quantum policy into `compose.yaml`: investigated, rejected (DD-35)

No code change. The operator asked to move
`/etc/master-stack/filebrowser.yaml` into `compose.yaml`, where the other
four containers are already configured in full. It cannot be done while
`read_only: true` stands: environment variables do not reach `sources`,
`cacheDir` or `signup`, and Compose refuses inline `configs: content:` on
a read-only service (`` `file` is the sole supported option ``) regardless
of where the target path points. Dropping `read_only` measures as free —
zero writes to the writable layer without it — which is exactly the
misleading measurement, since it is a containment control rather than a
functional one. Kept. Written up in DD-35 with the numbers, the gains that
were given up (bundle 9→8 entries, the policy drift/repair path, DD-29's
guard), and the conditions that would reopen it, so the three experiments
are not run a second time.

### 2026-08-02 — unpackerr's file log now rotates; queue heartbeat slowed (`Q1-13`)

Raised by the operator seeing a long repetitive tail in `docker logs
unpackerr`. The 10-second folder scan they suspected is silent; the lines
come from `log_queues` (default `1m1s`, two lines a minute, idle or not).
The Docker stream was already capped at 30 MB by the `json-file` options,
so that part was noise rather than risk.

The part that was a real defect is the *second* log: `UN_LOG_FILE` writes
into `/downloads/.unpackerr/unpackerr.log` and the container reported it
as `(10 @ 0Mb)` — rotation disabled. Upstream documents a 10 MB default,
but that only applies via the TOML config path; configured purely through
environment variables, as here, the value arrives as `0`. Measured at
~280 B/min, ~145 MB/year, growing forever inside the tree filebrowser
serves and Infuse indexes. Now `UN_LOG_FILE_MB: "10"` + `UN_LOG_FILES:
"3"`, the same 30 MB ceiling the Docker side already had; the container
reports `(3 @ 10Mb)`.

`UN_LOG_QUEUES: "30m"` for the heartbeat. Not `0` — measured, `0` does not
disable it but clamps it to a 15-second floor, four times noisier than the
default. Extraction events are unaffected, verified end to end:
`Tracking New Item` → `Queued` → `Extraction Started` → `Extraction
Finished` all still logged.

Stage 7's unpackerr environment assertion gains `UN_LOG_FILE_MB` only.
That list is for settings whose drift is silent, and this is the only one
of the three that qualifies — the other two degrade to "noisy" and "still
bounded". Checked against containers configured both ways, so it
discriminates.

### 2026-08-02 — `FILEBROWSER_DATABASE` pinned in `compose.yaml` (`Q1-12`)

The database path was inherited silently from the image's own `ENV`
(`/home/filebrowser/data/database.db`). It happened to be correct, but
`read_only: true` makes it a hard dependency on the `filebrowser_data`
volume mount: if upstream ever moves the default outside that directory,
Quantum tries to open its database on a read-only root and the container
dies at startup. The value is now written explicitly next to the volume
line it must agree with, so the two change together.

This does **not** silence the first-boot warning that prompted the
change. Measured on the live host on 2026-08-02: `[WARN] database file
could not be found. If this is unexpected, please set the
FILEBROWSER_DATABASE environment variable to the correct path` is emitted
*while the variable is already set to the correct path*, one second before
`Creating new database`. The warning distinguishes "file missing" from
"path wrong" not at all; on a first install the file is simply not there
yet. Restart and `--force-recreate` both log `Using existing database`
with no warning, and the operator's changed admin password survives both
(default `admin`/`admin` → `401`).

### 2026-08-02 — documentation resynced against the script

`docs/architecture.md`'s stage table still described `V1-20` at 5305
lines; `install.sh` is 5678. Stage 4 alone was understated by 348 lines
and every embedded-script line reference inside it was wrong, including
reconcile itself — listed as `2439-3905, 1466 lines` where it is
`2576-4236, 1659`. The whole table was regenerated the way the note under
it says to, rather than patching the rows that looked wrong; that habit is
what caused all three drifts now on record.

Also corrected: `README.md` claimed seven embedded scripts were six and
that Tier 2 had 57 tests across five files (it has 120 across eight), and
the canonical bundle was still described as state/dnsmasq/Caddy.

Two `quantum`-line reconcile behaviours were documented for the first
time — the Quantum policy file joining the bundle with a restart-backed
restore, and the once-per-cycle default-password probe with its `429`
branch. Both were only in the design decisions until now.

### 2026-08-02 — `scripts/check-all.sh`: the four checks in one command

`bash -n install.sh`, `shellcheck install.sh`,
`scripts/lint-embedded-scripts.sh` and `bats test/` in a single run — the
local substitute for the CI that will not exist while the repository has
no remote.

It does not stop at the first failure, because one command is only worth
having if it gives the complete picture. A check whose tool is missing is
reported as **doğrulanamadı** and exits non-zero rather than passing
silently — the same reasoning as the `429` branch in `Q1-10`. The first
run on the Debian target proved the point by finding `shellcheck` absent
and refusing to call the run clean. It also reports the bats skip count,
so a green run on the workstation does not read as full coverage.

All four failure paths were exercised. The most useful one: a syntax
error planted inside the reconcile heredoc is caught by check 3 alone —
`bash -n install.sh`, `shellcheck install.sh` and the whole bats suite
pass on it, which is exactly why the embedded lint exists.

### 2026-08-02 — unit tests for the last five uncovered reconcile helpers

`port_binding_exists`, `docker_network_tuple`, `record_container_restart`,
`forwarding_config_ok` and `gro_flags_ok` had no coverage at all. Four of
the five reach the outside world through a parsing step, and a parse that
is subtly wrong looks exactly like one that is right when the system is
healthy — `grep -Fx` versus `grep -F` decides whether a substring can
satisfy a port check, `head -n 1` decides which network a multi-homed
container reports, an awk program decides what counts as a configured
sysctl. None of that is visible to a live smoke test.

`record_container_restart` is tested against `restart_budget_available`
rather than alone, because nothing else pins that the writer and the
reader agree on the stamp's filename and format — and the restart
cooldown (DD-21) is the only thing between a repeatedly-failing repair and
a restart loop.

36 cases, mutation-verified. One mutation changed nothing and is recorded
in the test: the start-of-line anchor in the sysctl regex turns out to be
redundant with the string equality that follows it, not load-bearing as
its shape suggests. A stub-fidelity bug was also found and fixed — the
first stubs printed errors to stdout where the real `docker` and `ethtool`
use stderr, which every call site discards.

84 → 120 cases, no skips on the Debian target. No change to `install.sh`.

### 2026-08-02 — a test for the gap that hid the Quantum policy file

`Q1-9` fixed one file being outside the canonical bundle. It did not fix
the reason nothing noticed: **nothing anywhere compares the files
`install.sh` generates against the files the bundle covers.**
`test/canonical_bundle.bats` checks that Stage 6's manifest and
reconcile's expected list agree with each other, and two lists agreeing
says nothing about what is missing from both.

`test/generated_files_bundled.bats` supplies the third side. It derives
the generated set from install.sh's own write operations — with every
heredoc body stripped first, so the helper scripts' `install` calls don't
count as install.sh's — and requires every one of them to be either
published into the bundle or listed on an allowlist with a written reason.

Of the 32 generated files, 9 are bundled and 23 are excluded for four
stated reasons. Writing the allowlist surfaced what looked like an
inconsistency — two generated systemd drop-ins are neither bundled nor
named in reconcile, while three of the other five are bundled — and
measuring it closed it. Both were deleted on the test host, Docker was
restarted and the host rebooted with them absent: firewall policy still
applied, all containers up, reconcile clean, zero failed units. The units
they point at are enabled and carry their own ordering, so the drop-ins
are redundant except for a `RequiresMountsFor` that is inert unless the
download path is a separate mount.

Mutation-verified on scratch copies, all five assertions independently.
The load-bearing one reverts `Q1-9` itself — the suite fails on the real
historical defect. 79 → 84 cases, no skips on the Debian target. No
change to `install.sh`.

### 2026-08-02 — `Q1-11`: the Stage 4 progress note said six containers

There are five. The generated `compose.yaml` defines `portainer`,
`filebrowser`, `qbittorrent`, `unpackerr` and `wg-easy` — the sixth `wg:` in
that file is the network. The count was right before a service was dropped,
was corrected on `master`, and never made it across to `quantum`.
Reconcile's `expected_containers` list has said five all along.

### 2026-08-02 — `Q1-10`: the default-password probe stops fighting the rate limiter

Two defects in the DD-30 check, both found by re-reading `Q1-8` end to end
and then measuring the endpoint it talks to.

**It failed open on `429`.** Quantum's `POST /api/auth/login` is rate
limited, and the bucket is keyed on **source IP, not on the credential**:
measured on the target, 6 failures produce `429`, after which the *correct*
password also returns `429`. The check only warned on `200`, so a throttled
response fell through the same silent path as a plain `401` — the check
reported "nothing to see" at exactly the moment someone was hammering the
login screen. `429` now gets its own message that says the check could not
be performed and that this is not evidence the password was changed.

**It ran up to four times per cycle.** The probe lived inside
`check_compose_runtime`, which a single cycle calls up to four times
(detection, retry, post-repair, final postcondition). Against a 6-attempt
bucket that left the operator two tries before reconcile's own traffic
locked the login screen — and reconcile could trip the limit unaided. The
probe's source is `172.18.0.1`, the docker bridge gateway, which is also
where every Caddy-proxied browser login arrives from, so the bucket is
shared with the operator. It is now `report_default_filebrowser_password()`,
called once from the main flow. One attempt per 20-minute cycle cannot
accumulate: the timer interval is longer than the longest measured window
(3–8 minutes of silence).

Verified live on all four paths — clean, drifted, throttled, and the
regression case with the volume deleted — then end to end through systemd:
`Result=success`, the warning once in the journal, zero failed units. Full
reasoning in **DD-33**, which amends DD-30's cost claim.

### 2026-08-01 — `Q1-3`: the admin account goes back to the container

The installer no longer bootstraps FileBrowser Quantum's admin user. Reading
upstream's source settled it: `quickSetup()` runs only `if !exists` (no
database), creates `admin`/`admin` from a hardcoded fallback, never
re-asserts it on later starts, and sets `ShowFirstLogin` so the UI prompts
without forcing a change. That is a deliberate upstream design, not an
oversight, and overriding it bought less than it cost.

Removed: the Stage 5 `docker stop` + `docker run … set -u` block (~20 lines)
and the Stage 7 `admin/admin` assertion. `WEBDAV_PASSWORD` goes back to
being cleared in Stage 4.

**`minLength` had to drop from 8 to 5, and this is not optional.** `admin` is
exactly five characters, so 8 makes `quickSetup()` die with
`[FATAL] store.Users.Save: password must be at least 8 characters long` and
the container comes up with no user at all — healthy to Docker, 200 to the
reconcile probe, clean under `--check`, and impossible to log into. Upstream's
two numbers are tuned to each other.

**The change also fixed a latent behavioural bug.** The removed code ran
whenever Stage 0 re-collected credentials, so a re-run would have silently
reset a password the operator had already changed in the UI. Verified after
the change: password changed to something else, full installer re-run, and
the new password still works while `admin`/`admin` stays refused.

Also considered and rejected: `FILEBROWSER_ADMIN_PASSWORD`, which upstream
does support. It would have put a plaintext secret in `compose.yaml` —
`0600 root:root`, but still readable via `docker inspect` and the
container's `/proc/1/environ`.

Verified live on a reimaged volume: zero FATALs, zero restarts,
`admin`/`admin` 200 as intended, one user with `showFirstLogin: true`,
`--check` `rc 0`, zero failed units, and a re-run against the live stack
completing cleanly. Full reasoning in **DD-27**.


### 2026-08-01 — `Q1-2`: WebDAV directory cache lowered to one minute

`rclone serve webdav` was running on its 5-minute `--dir-cache-time`
default. That put five minutes between qBittorrent/unpackerr writing a file
and Infuse being able to see it — the exact producer/consumer path this
installer exists for.

Measured: a file created in the media tree was visible to FileBrowser
Quantum immediately (its SQLite index monitors in real time) and still
returned 404 over WebDAV at t+10s. After the change, with a properly warmed
cache, it appeared after 33 seconds.

`--poll-interval` was considered and deliberately not used: it applies
"only on supported remotes", and `rclone backend features` reports
`ChangeNotify: false` for a local directory. Directory cache lifetime is the
only effective lever on this backend. Full reasoning in **DD-28**.

The first verification of this change was invalid and is worth recording:
it appeared to show instant visibility, but the install had just restarted
`master-webdav`, so the cache was cold and the first request read from disk.
A cold cache proves nothing about cache expiry.


`MASTER_SETUP_VERSION` is `2026.07.31-V1-20`; `install.sh` is 5305 lines.

`V1-19` finishes what `V1-18` started. `V1-18` learned to *diagnose* a node
deleted from the Tailscale panel; it still told the operator to run
`tailscale logout && bash install.sh` by hand. But at that point the script
already knows everything it needs: the profile exists locally and has no
counterpart on the control plane, so it is worthless. It now clears the
profile itself and falls straight through to the interactive login.

Structurally this collapsed two paths into one. "No profile at all" and
"profile whose node was deleted" both set `TAILSCALE_NEEDS_LOGIN` and reach
the same single login block, instead of one exiting and the other logging
in.

If the automatic `tailscale logout` fails or takes longer than 60s, the
install stops and says so rather than continuing — `tailscale up` may not
open a fresh registration over a stale profile, and an operator dropped
into that state has no way to see why. The network/control-plane branch
still exits, because there the profile may be perfectly valid and deleting
it would be wrong.

**Live-verified** against a genuinely deleted node: the log shows the
diagnosis, `Yerel profil temizlenip yeni kayıt açılıyor...`, a fresh login
URL, and then a complete install — `STACK_SCHEMA=10`, five digests, nine
units, five containers, WebDAV 401/401/207 with the public IPv4 refusing,
`--check` rc 0.

**`V1-20` fresh-install verified (2026-07-31).** The host was reimaged and
`V1-20` installed from scratch: `STACK_VERSION=2026.07.31-V1-20`,
`STACK_SCHEMA=10`, five image digests recorded, nine units active, five
containers, **zero failed units**, `--check` every field 0 at `rc 0`.
WebDAV bound to the Tailscale IPv4 alone with the public IPv4 refusing,
five `.ayc` names resolving and answering through Caddy, firewall at
exactly two narrow public allows with a single `DOCKER-USER` jump and no
IPv6 allows, exit node advertised, GRO `off`/`on`.

Worth noting in that output: `--check` reported
`UYARI: wg-easy ilk kurulumu tamamlanmamış` and still returned `rc 0`.
That is `V1-11`'s fix working on a fresh install — the condition is
expected before the operator has opened `wg.ayc`, and it no longer
contaminates the exit code.

`V1-20` is a one-word consequence of reading that log: the first line still
said `HATA: Kayıtlı Tailscale profili 60 saniyede online olmadı`, so a
**successful** install left an error line behind it. The severity is now
decided per branch — `UYARI` when the script recovers, `HATA` only when it
exits. This is the same class as `V1-11`: a recoverable condition reported
as failure.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-18`; `install.sh` was 5275 lines.

**Deployment tooling (`versiyon/deploy.sh`, not part of `install.sh`).**
Copies the single export in `versiyon/` to a host, verifies the transfer by
SHA256 and optionally runs the installer. The expected hash is computed
from the local file at run time rather than stored — a stored constant
would be a second copy needing manual update on every export swap, and this
repository has been bitten by exactly that three times (the repair cooldown
across two heredocs, the architecture stage table twice, and the "sabit
image sürümleri" wording surviving four revisions past the change it
described). Both guards — exactly one export present, transferred hash
matching — were verified to fire rather than assumed.

`--run` executes the installer directly over SSH; the `tmux` wrapper was
dropped at the operator's request, since the install can equally be started
from the provider console. The cost is stated in the script and the README
rather than hidden: an SSH drop after Stage 1 leaves the install
incomplete, with re-running (25s, zero container restarts when nothing
moved) as the built-in remedy.

It also warns about the Tailscale login, which is what actually cost time:
restarting the installer generates a new nodekey and invalidates the
pending auth path, producing `410 auth path not found`. Three attempts went
to that before the cause was identified — and the cause was the restarts
themselves. The fix for a slow login is to wait, not retry.

`V1-18` makes Stage 2 say *why* a registered Tailscale profile failed to
come online. Three unrelated faults produced the same message and have
different fixes: the control plane is unreachable, the node key has
expired, or **the node has been deleted from the Tailscale admin panel**.

The third looks entirely healthy locally — profile registered, key valid
until 2027, `tailscaled` active, `tailscale ip -4` returning an address —
and is only distinguishable by `404: node not found` in journald. It
happened for real on 2026-07-31, most likely while clearing out the dead
tailnet entries this project accumulates on every reimage. The install
stopped correctly and left the host on its previous version, but the
message did not say that the only fix is `tailscale logout` followed by a
fresh browser login.

Stage 2 now greps journald for that signature and prints the specific
cause and the exact remedy. The window is scoped to
`MASTER_SETUP_STARTED_AT` rather than a fixed `-5min`, so a resolved
earlier fault cannot misdiagnose a different failure minutes later.

**Live-verified (2026-07-31).** The user deleted the node from the
Tailscale admin panel — an account-level action outside the standing
authorization, so it had to be theirs — and a re-run produced exactly the
intended output:

```
HATA: Kayıtlı Tailscale profili 60 saniyede online olmadı.
NEDEN: Kontrol düzlemi bu düğümü tanımıyor (404 node not found).
Düğüm Tailscale panelinden silinmiş; ...
  tailscale logout && bash /root/master.sh
```

The generic branch was correctly *not* taken, and the install stopped at
`rc=1, aşama=2` without leaving the host half-configured. The state it
diagnosed is worth recording, because it is why the message earns its
keep: `tailscale ip -4` returned an address, `tailscaled` was `active` and
`BackendState` read `Running` — three healthy indicators out of four, with
only `Online: false` and journald telling the truth.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-17`; `install.sh` was 5251 lines.

`V1-17` trims Stage 0's pre-confirmation summary to the four values the
operator actually chose: downloads path, timezone, WebDAV username and the
Tailnet DNS domain. Removed: operating system, Tailscale login behaviour,
public IPv4, the two fixed service ports, and the wg-easy admin reminder.

The block's job is "confirm your choices before anything is mutated", not
"inventory what will be installed", and it had drifted into the second.
Every removed line was verified to survive elsewhere before deleting it —
the public IPv4 and both ports appear in the final summary (which also
shows the resolved addresses rather than "will be auto-detected"), and the
wg-easy admin step appears there as a fuller warning covering Portainer
too. The OS line was pure redundancy: a host that is not Debian 13 exits at
the OS guard long before Stage 0 renders.

Both branches (new credential / existing `htpasswd` preserved) were
render-tested.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-16`; `install.sh` was 5250 lines.

`V1-16` is text only: three operator-facing strings still described the old
world. Stage 4 printed "Sabit image sürümleri" and Stage 5's progress note
said "Sabit container image sürümleri indiriliyor", both left over from
before `V1-12` moved the images to floating tags — the script was telling
the operator the opposite of what it does. The `--status` one-liner in the
final summary also predates `V1-12` and did not mention that the mode now
prints the running image digests.

Caught by the user reading the install output, not by any check. Worth
noting where the gap is: Stage 7 asserts behaviour thoroughly but asserts
nothing about the words the script uses to describe itself, and neither
does the bats suite. Every string of this kind found so far — three
documentation defects on 2026-07-31 plus these three — has been found by
reading, never by tooling.

Not live-verified: the test host was offline. The changed lines were
render-tested locally for alignment; no logic changed.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-15`; `install.sh` was 5249 lines.

`V1-15` closes the last structural item on the list: the repair cooldown
was written out independently in two embedded scripts, and the fact
"15 minutes" appeared in three more places as hardcoded prose in
operator-facing error messages.

The two code copies **stay**, and that is the decision rather than a
compromise. Every embedded script has to be self-contained because
`scripts/lint-embedded-scripts.sh` extracts each one and lints it as a
standalone program — the mechanism that answers **H4**. Binding them to a
shared variable, or splitting a heredoc so an unquoted prelude could
interpolate one, would leave the linted fragment referencing something it
never assigns: trading a real property (the linter checks exactly what
ships) for a cosmetic one.

What the duplication actually risked was *silent* divergence, and DD-21
makes that concrete — the reconcile timer moved to 20 minutes specifically
to stop fighting this cooldown, so the two numbers are coupled by a design
decision and one could have been changed with the other left behind.
`install.sh` now declares `MASTER_RESTART_COOLDOWN_SECONDS` as the single
source of truth and **Stage 7 asserts all three values agree**, naming
them all when they do not.

The three prose copies were removed outright — the messages derive the
figure (`$((RESTART_COOLDOWN_SECONDS / 60))`), so they cannot contradict
the behaviour. `StartLimitIntervalSec=900` in three systemd units is
deliberately untouched: same value, different mechanism.

**The assertion was verified to discriminate rather than assumed to.** A
copy of `install.sh` with the recovery constant set to `800` was installed
on the test host and failed at Stage 7 with `install.sh : 900 /
reconcile : 900 / recovery : 800`, then the real version was reinstalled
clean. Same discipline as the `all_critical_state_healthy` coverage guard
earlier the same day: a guard nobody has watched fail is not yet known to
work.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-14`; `install.sh` was 5198 lines.
**Live-verified:** 25s install, `STACK_SCHEMA=10`, five digests recorded,
`--check` rc 0, zero failed units, containers untouched.

**Test coverage corrected (2026-07-31):** `M7`'s inventory claimed the
only remaining scope was CI wiring. That was written on 2026-07-28 against
a ~4550-line script and had not been revisited as the file grew to 5198
lines. A re-survey found three genuinely unit-testable pure-logic functions
with no coverage at all — `restart_budget_available` (the 15-minute
cooldown gate whose mismatch with the old 5-minute timer motivated DD-21,
i.e. the constant that drove a design decision had no test behind it),
`disk_space_ok` (threshold parse, strict-`<` boundary, fail-closed on
unparseable output) and `all_critical_state_healthy` (pure, twenty flags,
no external calls). All three are now covered; the suite goes from 62 to
**74 cases, all passing with zero skips on the Debian target**.

The `all_critical_state_healthy` suite includes a guard case asserting the
fixture's flag list matches the flags the function actually reads, so a
flag added to the reconcile pass but forgotten in the gate becomes visible
rather than silently reducing what the loop covers. That guard was checked
against a deliberately shortened list and does fail — it is not vacuous.
Two smaller things surfaced while writing it: the `df` stub was built with
`printf` and the stubbed percentage's `%` was read as a format specifier,
so it emitted an error while still passing because `disk_space_ok`'s
`tr -dc '0-9'` cleaned up after it; and this is the third
documentation-accuracy defect of the day, after `docs/architecture.md`'s
18-line stage-table drift and its stale `OPTIONS` description of the WebDAV
probe.

**Reboot-verified (2026-07-31):** the host returned in 56 seconds with all
nine units active unaided, five containers up, `rclone` re-bound to the
Tailscale IPv4 by itself, the firewall rebuilt to exactly two narrow public
allows with a single `DOCKER-USER` jump, five `.ayc` names resolving and
answering, the exit node advertised and GRO flags correct, and `--check`
rc 0 with zero failed units. Also the **first reboot the `V1-12`/`V1-13`
digest record has been through**: `--status` showed all five short digests
with no divergence marker, so the `state.env` record still matches what is
actually running after a full restart — the mechanism had been introduced
and verified within a single uptime until now.

`V1-14` puts every network-dependent step behind `retry_network`: three
attempts, an explicit per-attempt `timeout`, 5s/15s backoff. Applied to
`apt-get update`, the Tailscale keyring and repo list, the Docker GPG key,
the Caddy GPG key and repo list, and `docker compose pull`.

**The timeout turned out to matter more than the retry**, which inverts
how the finding was originally written up. A Docker Hub 502 during
`docker compose pull` is what prompted it, and a retry does fix that — but
that failure was loud and safe: the install stopped and the immediate
re-run succeeded. Reading the surrounding code showed the worse case had
no bound at all. The script runs under `systemd-inhibit
--what=shutdown:sleep --mode=block` and holds the `flock` it shares with
`master-network-reconcile`, so a single hung download blocks shutdown
*and* leaves the 20-minute reconcile timer unable to run, indefinitely.

No error classification, deliberately. Permanent failures (`manifest
unknown`, `unauthorized`, a full disk) return within seconds, so three
blind attempts cost them about 20s of backoff and then the same clear
error; only transient faults and hangs consume real time, and those are
the target. Matching upstream stderr text would be locale- and
format-dependent for no gain.

Budgets came from measurement rather than guesswork: cold
`docker compose pull` 10.9s for 885 MB across three registries, warm pull
3.2s, `apt-get update` 0.9s, keyring fetches 36–127 ms. Bulk transfers get
300s then 180s (~27× the measured cold pull), small fetches 60s then 30s.
A hung pull is now bounded at about 11 minutes instead of forever.

Worth keeping in mind from those numbers: **the warm pull still costs
3.2s** because it re-checks manifests at all three registries. The pull is
a hard network dependency on every run, including runs where nothing has
changed — which is precisely how a transient registry fault reached an
otherwise no-op re-run.

`apt-get full-upgrade` and `apt-get install` are deliberately not wrapped:
they drive dpkg transactions, and reissuing an interrupted one is a
different problem class that interacts with the `--force-conf*` handling.
The Caddy GPG fetch was restructured rather than wrapped as-is — it was
`curl … | gpg --dearmor`, and retrying the pipeline would also retry a
local dearmor that retrying can never fix.

`test/retry_network.bats` covers all four control-flow paths plus argument
pass-through. The design note preceding this change claimed the recovery
path could not be tested deterministically without a real flaky network;
that was wrong, and a stub that fails once then succeeds reproduces it
exactly. The suite self-skips where GNU `timeout` is absent, so it skips
on the macOS workstation and runs for real on Debian — where the **full
62-case suite passes with zero skips** (74 after the `M7` coverage
correction later the same day).

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-13`; `install.sh` was 5104 lines.
**Live-verified:** installed in 25s, `STACK_SCHEMA=10`, all five
`IMAGE_DIGEST_*` keys recorded and matching the running images, `--status`
printing the short digests, `--check` rc 0, zero failed units.

`V1-12` replaces the exact container image pins with floating tags and
records the digest each tag resolves to; `V1-13` fixes the digest lookup
that `V1-12` got wrong.

The change started as the opposite proposal. Re-running `install.sh` also
upgrades `docker-ce`, `tailscale` and `caddy`, because those three
third-party `sources.list` entries persist from the previous run and Stage
1's `full-upgrade` sees them — so pinning *those* was suggested. The user
rejected it: pinning trades away security updates. That reading is right,
and it also pointed at the real inconsistency — Debian-sourced packages
already behave as "patches arrive, majors do not" because trixie is
stable, while the container images were frozen at exact versions. The
stack was running two opposite policies at once.

Tags now (queried from the registries, because the upstreams' published
tags are uneven): wg-easy `15.3` and unpackerr `0.15` move at the patch
level; filebrowser `v2` moves within the major, since no `v2.63` tag is
published; portainer `lts` moves within the LTS line and will jump a major
when Portainer declares a new one; qbittorrent `latest`, because
linuxserver publishes no float tag at all. Both `lts` and `latest` were
verified to resolve to the same digests as the exact pins they replaced,
so adopting them changed nothing on the day.

A moving tag deletes the answer to "what is running" — `compose.yaml`
keeps its checksum while the image beneath it changes. So the five
resolved digests are appended to `state.env` after Stage 5, `--status`
prints them, and **Stage 7 asserts the recorded digest equals the running
one**. Floating tags without that record would be a straight loss of
auditability; the pair is the design.

Upgrading is safe — each container reads its existing data directory and
continues — but downgrading is not: Portainer migrates its database
forward with no reverse path, so re-pinning an old tag does not undo a bad
upgrade. Rollback is a provider-level (netcup) VPS snapshot, chosen over an
in-script snapshot because a whole-machine image also covers the migrated
databases and keeps rollback out of the installer's scope.

`V1-13` exists because `RepoDigests` is a field of the *image* object, not
the container: `docker inspect <container>` fails with `map has no entry
for key "RepoDigests"`, and `V1-12` wrote all five digests as `bilinmiyor`.
**Stage 7 caught it and failed the install with `rc=1, aşama=7`** — the
second time in three revisions that a Stage 7 literal assertion caught a
change that `bash -n`, `shellcheck` and the full bats suite had passed.
The same wrong lookup was present in `--status` and was fixed with it.

One incidental observation from the same session: a `V1-13` attempt died
at Stage 5 because Docker Hub's anonymous token endpoint returned **502
Bad Gateway** during `docker compose pull`. Nothing in the script is at
fault, but the pull has no retry, so a transient registry error fails the
whole install. Recorded in `TODO.md`.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-11`; `install.sh` was 4984 lines.
**Live-verified:** re-installed over `V1-10` on the same host via the
idempotent path, then both drift scenarios replayed against a wg-easy
still on `/setup/1` — healthy pass, WebDAV repair and Caddyfile repair all
exit 0, journal reading `UYARI`, zero failed units, `--check` rc 0,
`--status` reporting `V1-11` / `c33d84f7…`. Re-verified from scratch on a
second reimaged host, where the first attempt accidentally proved nothing:
wg-easy's web setup was completed three minutes after the install, so the
scenarios ran against a `/login` container, `WG_SETUP_PENDING` never fired,
and three `exit 0` results the old code would have produced identically
were briefly mistaken for evidence. After wiping wg-easy's config to
restore `/setup/1`, the replay gave five `UYARI` lines and **zero `HATA`**
across three runs, both repair runs printing the warning twice — the same
double-print that accompanied `exit 1` under `V1-10` — with all three
exiting 0. **The opposite branch is measured too**, once the user
completed wg-easy's web setup and made the failing `elif` reachable:
`wg set wg0 listen-port 51820` (runtime-only, reversible, `wg0.conf`
untouched) gave `HATA: wg-easy iç portu 51820; beklenen 65171.`,
`compose_runtime=1` and `exit 1`, with no automatic wg-easy restart;
restoring the port returned `exit 0`, `--check` all fields 0 and the peer
intact. Both branches of `V1-11` are therefore measured, not one measured
and one reasoned.

`V1-11` separates "wg-easy is waiting for its first web setup" from
"wg-easy is misconfigured". Both used to set `WG_CONFIGURATION_INVALID`,
and the consequence was a reconcile exit code that lied precisely when it
mattered. On a fresh install — before anyone has opened `wg.ayc` — a
healthy pass exited 0 via the `all_critical_state_healthy()` early return,
but any pass that actually *repaired* something fell past that gate into
the `RECOVERY_FAILED` check and exited 1, with every repair having
succeeded. Since `master-network-reconcile.service` is the `OnFailure=`
target of five other units, that turned the operator's red/green signal
red at the exact moment the system was doing its job.

The setup-pending case now has its own `WG_SETUP_PENDING` flag: reported
as `UYARI` rather than `HATA`, still suppressing wg-easy's automatic
restart (restarting a container that is waiting for its first web setup
fixes nothing), but no longer failing the run. A real internal-port
mismatch keeps `WG_CONFIGURATION_INVALID` and keeps failing.

**Found by live testing on a freshly reimaged host, not by review.** The
comment above the check already stated the intent — that a `/setup` screen
on a fresh install is expected and must not fail the run — and the code
delivered that intent only along the early-exit path. The two drift
scenarios (stopping `master-webdav`, appending a line to the Caddyfile)
were the first cases to exercise the other path.

Docs corrected in the same pass: `docs/architecture.md`'s stage table had
silently drifted 18 lines for stages 5–7, and its reconcile section still
described the WebDAV probe as `OPTIONS`, which `V1-6` had already changed
to `PROPFIND` after discovering rclone answers `OPTIONS` 200.

### Previously

`MASTER_SETUP_VERSION` was `2026.07.31-V1-10`; `install.sh` was 4975 lines.
**Live-verified:** timer reads `OnCalendar=*-*-* *:00/20:00` with the next
three firings at `23:40`, `00:00`, `00:20` — evenly spaced across the hour
boundary, which was the point of choosing 20. Install 7/7, `--check` rc 0,
WebDAV 401/207.

`V1-10` is `V1-9` plus one fix: Stage 7 asserts the timer's `OnCalendar`
line against a literal, and that literal still said `*:00/5:00`, so the
first `V1-9` install failed its own verification at Stage 7. Worth noting
as a small vindication of that assertion existing — the script caught an
incomplete change of mine that `bash -n`, `shellcheck` and the bats suite
all passed.

### Changed

- **The reconcile timer now runs every 20 minutes instead of every 5
  (`V1-9`, DD-21).** The user asked for a longer interval on the grounds
  that the system is stable; the measurement found a better reason. A
  healthy check costs about half a second, so cost was never the issue —
  but `RESTART_COOLDOWN_SECONDS` is 900, so on a persistent fault the
  5-minute timer gave one run that repaired and two that could only
  detect, each logging `cooldown içinde; tekrarlanmadı`, exiting
  non-zero and leaving a failed unit. Two thirds of the runs were noise
  that could not act. Above the cooldown, every scheduled run can repair.

  20 was chosen over the suggested 18–24 because it divides 60 evenly
  (`:00 :20 :40`). `*:00/18:00` would give `:00 :18 :36 :54` and then a
  6-minute gap at the hour boundary — a silently uneven interval.

  Cost, stated plainly: drift with no event trigger (address changes,
  manual config edits, GRO flag loss, disk filling) now takes up to 20
  minutes to correct rather than 5. Crash recovery is unaffected — the
  five `OnFailure=` hooks and the `PartOf`/`Wants` cascades still invoke
  reconcile immediately.

## [V1-8] - 2026-07-30

`MASTER_SETUP_VERSION` is `2026.07.30-V1-8`; `install.sh` is 4956 lines.
**Live-verified** by a full install on 2026-07-30 (23:01:37 → 23:01:58,
21 seconds): 7/7 stages, zero failed units, `--check` all-zero at exit 0.
The schema 8 → 9 migration was exercised in place — the host went in with
`STACK_SCHEMA=8` + `LOCAL_DNS_ENABLED=1` and came out with `9` and the key
gone, canonical manifest still eight entries. Two drift tests passed:
appending a line to `/etc/caddy/Caddyfile` was detected as
`config=1 caddy_config=1` and reverted, and the WebDAV checks stayed
green throughout.

### Changed

- **Tailnet DNS + Caddy are no longer optional (`V1-8`, `STACK_SCHEMA`
  8 → 9).** They were always installed in practice, so the "Kurulsun mu?"
  prompt was a branch that existed only to be answered the same way every
  time. Stage 0 now asks for the domain alone (default `ayc`, or the
  existing domain on a re-run; Enter still means "change nothing").

  The user asked whether it was enough to hardcode the flag to `1` and
  leave the plumbing, or better to remove it. Measured first: 36
  references and ~25 conditional branches, plus a two-shape canonical
  bundle and 6 of `canonical_bundle.bats`'s 8 tests devoted to the
  branching. Hardcoding would have kept all of that alive and
  permanently unreachable — still linted, still tested, still needing to
  stay consistent through every future refactor, while `state.env`
  advertised an option that no longer existed. Removed instead:
  - `SETUP_LOCAL_DNS` and `LOCAL_DNS_ENABLED` are gone entirely (0
    references remain).
  - `canonical_bundle_ok()` has **one** manifest shape instead of two,
    which is the part that matters for the planned modularization: the
    bundle contract is now a single fixed eight-entry list.
  - `LOCAL_DNS_ENABLED` dropped from `state.env`, hence the schema bump.
    A host built by an older revision will fail reconcile's state
    validation until it is re-installed — acceptable here because the
    deployment is reimaged routinely, but it *is* a breaking change.
  - `canonical_bundle.bats` rewritten: the DNS-disabled cases are gone,
    replaced by a guard that the old two-entry bundle is now **rejected**
    (a host still carrying one must be caught, not tolerated), plus new
    cases for an extra appended entry and for the manifest being exactly
    eight entries. 7 cases, no skips. Suite total 57 → 56.

  Net effect: `install.sh` 5046 → 4956 lines.

## [V1-7] - 2026-07-30

`MASTER_SETUP_VERSION` is `2026.07.30-V1-7`; `install.sh` is 5046 lines.
**Live-verified** by a full install on 2026-07-30 (22:35:51 → 22:36:13,
22 seconds): 7/7 stages, one expected warning (wg-easy's admin is a manual
step), zero failed units, `--check` all-zero at exit 0.

### Fixed

- **Stage 5 could not restart a rate-limited `master-webdav.service`
  (`V1-7`).** After a failed install the unit can be sitting in
  `failed` with its `StartLimitBurst` exhausted; `systemctl restart` then
  returns non-zero with `Start request repeated too quickly` and the
  install dies at Stage 5. Found on the very next re-run after `V1-6`.
  Stage 5 now issues `systemctl reset-failed` first — idempotent, a no-op
  on a healthy unit, and the same order reconcile's repair path already
  used. The inconsistency between the two paths was the actual defect.


- **Three bugs in the `V1-3` WebDAV service, all found by the first live
  install (`V1-6`, 2026-07-30).** The install failed at Stage 7; static
  analysis had passed cleanly on every one of them. See DD-20 for the
  measurements.
  - **`RestrictAddressFamilies` was missing `AF_NETLINK`.** `ExecStart`
    resolves the Tailscale address with `ip addr show`, and iproute2 uses
    a netlink socket. With only `AF_INET AF_INET6` the call failed with
    `Cannot open netlink socket`, so the service never bound. rclone
    itself needs only the two inet families.
  - **That failure was silent.** The wait loop discarded `ip`'s stderr,
    making a hard configuration error look identical to "the address
    hasn't appeared yet" — the unit read `active (running)` for the full
    300-second window. The loop now distinguishes the two and reports the
    first `ip` error immediately. stderr is captured into a variable
    rather than a temp file, since `mktemp` fails under
    `ProtectSystem=strict`.
  - **All three 401 probes used `OPTIONS`, which rclone does not
    authenticate.** rclone exempts the WebDAV discovery preflight and
    answers `200`; sftpgo had answered `401`, and the probes were written
    against that. Uncorrected, Stage 7 would fail every install and
    reconcile would mark WebDAV drifted every cycle. `webdav_direct_ok()`,
    Stage 7's direct check and `caddy_runtime_ok()`'s vhost check now use
    `PROPFIND` with `Depth: 0` — a protected method, so a 401 also proves
    the htpasswd is enforced. **Authentication itself was never broken:**
    unauthenticated `GET`/`PROPFIND` and wrong passwords all return 401,
    correct credentials return 207.

  Verified on the live host after the fixes: listener on
  `<tailscale-ip>:65113` only (refused on the public IPv4),
  unauthenticated `PROPFIND` 401, authenticated 207, and the
  `master-webdav` user reading the 0750 media tree via gid 1000.

## [V1-5] - 2026-07-30

`MASTER_SETUP_VERSION` is `2026.07.30-V1-5`; `install.sh` is 4996 lines.
Static analysis only.

### Changed

- **The final install summary's WebDAV block was reworked (`V1-4`, then
  trimmed in `V1-5`).** The `V1-3` version left it ambiguous which
  address to type into Infuse: it printed the Tailscale IP and port in
  one block and the served directory in another, with no full URL.
  `V1-4` added the username, the full URL, both access paths and their
  trade-offs; the user judged that over-long, so `V1-5` cut it back to
  the fields actually needed at the end of an install:

  ```
  WebDAV (host rclone servisi, salt okunur):
    Sunulan dizin : /downloads/media
    Kullanıcı adı : infuse
    Parola        : Aşama 0'da belirlediğiniz parola
    Adres         : 100.x.y.z veya webdav.<domain>
    Port          : 65113
    Protokol      : WebDAV (HTTP, HTTPS değil)
    Tam URL       : http://100.x.y.z:65113
    Kimlik dosyası: /etc/master-stack/webdav.htpasswd (bcrypt)
    Sıfırlama     : dosyayı silip install.sh'i yeniden çalıştırın
  ```

  The address line appends `veya webdav.<domain>` only when local DNS is
  enabled, using whichever domain the operator chose. The username is
  read back from the `htpasswd` file rather than from `$WEBDAV_USER`,
  which is empty on a re-run that preserved an existing credential. The
  printed IP has always been the live one — Stage 7 re-derives `TS_IP`
  from `tailscale0` before the summary — and the explanatory material
  (Caddy path trade-off, the removed `127.0.0.1:65113` binding,
  reconcile's re-bind on address change) now lives in DD-20 and
  `docs/architecture.md` rather than the console output.

- **WebDAV is now a host service, not a container (`V1-3`, DD-20).** The
  `sftpgo` container was removed and replaced by `master-webdav.service`,
  running `rclone serve webdav $DOWNLOADS_PATH/media --read-only` bound to
  the Tailscale IPv4 only. Consequences:
  - **The last Tailnet → Docker firewall exception is gone.** The narrow
    `--ctorigdst $TAILSCALE_IPV4 --ctorigdstport 65113` ACCEPT in the
    mangle guard chain existed solely for the sftpgo container; a host
    service receives traffic on the INPUT path the guard chain never
    inspects. That direction now has zero exceptions.
  - Stage 0 prompts for a WebDAV username and password (skipped when
    `/etc/master-stack/webdav.htpasswd` already exists, so re-runs keep
    the existing credential). Only the bcrypt hash is written; the
    plaintext never touches disk. The service reads it via systemd
    `LoadCredential=`, so the file stays `root:root 0600`.
  - The unit runs as a dedicated `master-webdav` system user holding gid
    1000 to read the 0750 media tree, under `ProtectSystem=strict`,
    `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges` and
    `RestrictAddressFamilies` — a tighter sandbox than the `:ro` bind
    mount it replaces.
  - `rclone` and `apache2-utils` (for `htpasswd` only) join the Stage 1
    base packages. The `sftpgo.<domain>` DNS name and Caddy vhost are
    gone; `webdav.<domain>` now proxies to `{$TS_IPV4}:65113` instead of
    loopback, because Debian's rclone (1.60.1) accepts a single `--addr`.
  - Reconcile monitors it on two independent signals — unit active, and a
    real `OPTIONS` 401 against the current Tailscale IPv4 — with restart
    repair, unconditionally (not gated on the local-DNS option).
  - **The user's motivating symptom is not addressed by this.** The
    change was requested to fix intermittent Infuse playback stalls
    attributed to the container layer; the more likely causes are DERP
    relay fallback or `wireguard-go` throughput, and DD-20 records that
    plainly so the question stays open.

  Two implementation notes worth carrying forward. Copying Caddy's
  `ExecStartPre` + `EnvironmentFile` pattern would have been **wrong
  here**: systemd reads environment files before any `Exec*` runs, so on
  first start `${TS_IPV4}` would expand to empty and `--addr :65113`
  would become a wildcard bind on the public IPv4. Caddy escapes this
  only because its binary re-reads the file via `--envfile`. The address
  is therefore resolved inside `ExecStart` by `master-webdav-serve`.
  Separately, `--config /dev/null` is passed explicitly so rclone does
  not search `$HOME/.config`, which does not exist under `ProtectHome`.

- **Test fixtures updated for the removed firewall rule.** The healthy
  IPv4 policy fixture no longer contains the WebDAV allow. Two tests
  changed meaning rather than being deleted: the stale-address test
  became "rejects a resurrected narrow WebDAV allow" (drift detection for
  a rule that should no longer exist anywhere), and the v4/v6 conflation
  test now swaps the *policy* chain instead of the guard chain, because
  with the WebDAV rule gone both families' guard chains are legitimately
  identical and the remaining real difference is the public-port RETURNs.

## [V1-2] - 2026-07-30

`MASTER_SETUP_VERSION` is `2026.07.29-V1-2`; `install.sh` is 4792 lines.

### Added

- **The host now self-reports which installer revision built it.**
  `install.sh` computes its own SHA256 at startup and writes
  `STACK_VERSION` + `STACK_SHA256` into `/etc/master-stack/state.env`
  (falling back to `bilinmiyor` if the script has no readable path, e.g.
  piped stdin). Both keys are informational — no consumer requires them —
  so `STACK_SCHEMA` stays `8`. This closes the server-side half of the
  gap that let the host run several fixes behind the repository on
  2026-07-28 without anything noticing (`MASTER_SETUP_VERSION` itself was
  the script-side half).
- **`master-network-reconcile --status`** — a lock-free, read-only
  one-screen summary: installed version + script hash from `state.env`,
  per-container state/health for all six services, failed systemd units,
  downloads-disk usage, the `/run`-based repair stamps, and a full
  `--check` run (executed as a child process, which takes the lock) whose
  exit code the mode passes through (0 = clean, 75 = another stack
  transaction holds the lock). Deliberately enforces no preconditions —
  not even the canonical-bundle validation — because a status command
  must work exactly when the system is broken; a broken bundle shows up
  in the embedded `--check` output instead. The final install summary
  now points at the command.

## [V1-1] - 2026-07-29

`MASTER_SETUP_VERSION` is `2026.07.29-V1-1`; `install.sh` is 4701 lines.
Exported as `versiyon/install-V1-1.sh`. **Live-verified** by a full
install on 2026-07-29 (19:52:55 → 19:54:45, 1m50s): 7/7 stages, zero
warnings, zero failed units, six containers up, `--check` all-zero exit 0,
7/7 DNS names, Caddy 200/200/200/302/302/401/200, WebDAV reachable on the
Tailscale IPv4 and refused on the public IPv4.

### Fixed

- **M11 — the UDP socket-buffer floor now takes effect before
  `tailscaled` opens its socket.** The netbuf `sysctl.d` write and its
  `sysctl -p` moved from after the Tailscale package install to
  immediately before it. Debian's `tailscale.postinst` runs
  `deb-systemd-invoke restart tailscaled.service`, so the daemon comes up
  *inside* `apt-get install -y tailscale` — the script's own `systemctl
  enable --now tailscaled` only guarantees the enable, it never performs
  the start. Verified from the 2026-07-29 install: `dpkg configure
  tailscale` 19:17:24, `systemd: Starting tailscaled.service` 19:17:24,
  `status installed` 19:17:25. Since `wireguard-go` requests its large UDP
  receive buffer once at socket-open time and is clamped against the
  ceiling then in effect, DD-18's 16 MiB floor was reaching the running
  daemon only after the first restart on any host whose provider image
  does not pre-set `net.core.rmem_max` — a ~70× shortfall against
  Debian's 208 KB default, silently costing exit-node throughput. The
  forwarding sysctl deliberately did **not** move: `ip_forward` is read
  dynamically and is only needed before `tailscale set
  --advertise-exit-node`, and hoisting IPv6 forwarding ahead of the
  package download would change routing state earlier than necessary.
  Invisible on the project's test host, whose VPS image sets 64 MiB at
  boot, which is why DD-18's original verification missed it.

  The install confirmed the **ordering** from the log —
  `Aşama 2: 22% - UDP soket buffer tabanı ayarlanıyor` and
  `net.core.rmem_max = 67108864` both precede
  `Aşama 2: 25% - Tailscale paketi kuruluyor` — but not the **effect**,
  for two independent reasons: the package was already at its newest
  version so the postinst never ran and `tailscaled` was never restarted,
  and the host's ceiling was already 64 MiB before either ordering could
  matter. What was fixed is correct; how much it was worth is still
  unquantified.

### Changed

- **Reverted the `v1.1-1` Stage 1/2 reordering.** It moved the Tailscale
  browser login ahead of `apt-get full-upgrade`, was installed and
  measured on a clean host, and was reverted the same day at the user's
  direction. The reorder did what it was designed to do — the login
  banner reached the screen 10 seconds after confirmation instead of
  4-6 minutes — but it did not fix the reported problem, because
  **4m41s of the wait is Tailscale's control plane answering the first
  `RegisterReq`** (`19:17:25` sent → `19:22:06` `AuthURL` received) and
  nothing in `install.sh` influences that. Reverting also restores the
  3-6 second settling window between `systemctl enable --now tailscaled`
  and `tailscale up` that the GRO block provides, which the reorder had
  cut to zero. See DD-19 for the full measurement and for what a future
  attempt would need to establish first.

### Added

- **DD-19** records the reordering experiment, its measurements, and why
  it was reverted, so it is not proposed a second time on the same
  reasoning. It also notes what was *not* the cause: the display path is
  immediate (`tee`'s stdout is a TTY and line-buffered), and the network
  was eliminated — IPv4/IPv6 both reached the control plane in ~25 ms
  with clean 1500-byte PMTU on both stacks.
- **M11** (Medium, open) — the UDP socket-buffer sysctl from DD-18 is
  applied *after* `tailscaled` is already running, but `wireguard-go`
  requests its large receive buffer once at socket-open time and is
  clamped against the ceiling then in effect. The daemon is started by
  Debian's `tailscale.postinst` (`deb-systemd-invoke restart`) inside
  `apt-get install -y tailscale`, not by the script's own `systemctl
  enable --now tailscaled`, which is a no-op — so a fix has to precede
  the package install. On a host whose provider
  image does not pre-set `net.core.rmem_max`, `tailscaled` runs at
  Debian's 208 KB ceiling — ~70× below its request — until the first
  restart. Invisible on the project's test host, whose VPS image sets
  64 MiB at boot, which is why DD-18's original verification missed it.
  Found while reordering, fixed incidentally by `v1.1-1`, reintroduced by
  the revert, and fixed on its own in `V1-1` (see **Fixed** above). One
  question remains unanswered but is no longer blocking: whether
  `tailscale up`/`set` rebinds magicsock's UDP socket later in the stage,
  which would mean the defect was narrower than described. Raising a
  permitting ceiling earlier cannot hurt either way (DD-18), so the fix
  is safe regardless — but the size of what was fixed is not quantified.

## [V1] - 2026-07-29

Final release. `MASTER_SETUP_VERSION` is `2026.07.29-V1`; `install.sh` is
4683 lines. Exported as `versiyon/install-V1F.sh`.

Everything below this heading shipped in V1. The functional content is
identical to the live-verified `v1rc-4` tag — the only `install.sh`
changes since it are the version string and the qBittorrent socket-buffer
reminder in the final summary, neither of which touches an executable
path.

## [Unreleased]

### Added

- Stage 2 now writes `/etc/sysctl.d/99-master-stack-netbuf.conf`, flooring
  `net.core.rmem_max` / `wmem_max` at `max(current, 16 MiB)`. These were
  previously only correct by accident on the live host — the 64 MiB
  values came from the VPS provider's own image, not from this installer,
  and would have fallen back to Debian's 208 KB anywhere else. The
  beneficiary is Tailscale (userspace WireGuard), whose `tailscaled` was
  measured holding a 14 MiB socket buffer; kernel WireGuard is unaffected.
  Raise-only, so a provider that already sets more keeps it. See DD-18.
- `master-network-reconcile` now checks `tailscale-udp-gro.service`'s
  `ActiveState` and restarts it, with the existing 15-minute cooldown,
  when it is not active. The unit is `Restart=no`, so a boot-time failure
  previously persisted until the next reboot. Reported as `gro_unit=` in
  `--check`; deliberately excluded from `all_critical_state_healthy()` and
  from the exit code, since GRO is throughput-only. Amends DD-11, which
  had removed continuous ethtool-flag polling — that part stays removed.

- `MASTER_SETUP_VERSION` now carries a revision suffix
  (`2026.07.29-v1rc-1`), incremented on every `install.sh` change. A
  deployed host previously could not report which revision it was built
  from, which is how the server ran several fixes behind the repository
  on 2026-07-28 with nothing noticing. Git tags stay separate and are
  created only after live verification. Convention recorded in
  `CLAUDE.md`.

- Reconcile now also verifies the UDP GRO **ethtool flags**, not just the
  unit's `ActiveState`, and repairs on either signal. Live fault injection
  showed the unit check alone proves nothing: after
  `systemctl stop tailscale-udp-gro`, `rx-udp-gro-forwarding` was still
  `on`, so the optimization had never actually degraded. Reported as
  `gro_flags=` in `--check`. Anything the check cannot evaluate (no
  `ethtool`, no WAN interface, feature unreported or `[fixed]`) counts as
  healthy, matching the helper's own success cases. Amends DD-11 a second
  time. (`v1rc-2`)

### Fixed

- The final install summary now names qBittorrent's socket receive buffer
  as a required manual step, with the measured reason and a suggested
  value. This script does not manage qBittorrent's configuration, so the
  setting reverts to the system default on any fresh install — measured
  on 2026-07-29 during a ~278 MB/s download: at the 208 KB default the
  uTP/DHT socket saturates and drops packets; once raised, the same load
  ran 288,201 packets in 30s with zero drops. The `rmem_max` floor from
  DD-18 is what permits the raise (the kernel clamps the request to it),
  so the two are complementary rather than alternatives. (`v1rc-5`)
- Stage 0 now asks a different question on a re-run. When a managed
  DNS/Caddy install is detected the prompt is no longer "should DNS be
  installed?" — DNS is already installed, so the only meaningful question
  is whether the domain changes. It reads
  "Alan adı değiştirilsin mi? [e/H]": `e` asks for the new domain, and
  Enter (or `H`) keeps the existing domain and structure untouched while
  the install continues. This removes the abort path entirely rather than
  just defaulting away from it — declining to change is now a normal
  outcome instead of a fatal one, and the protection against silently
  tearing down DNS becomes structural (the option is never offered)
  instead of a `exit 1`. Enter now means "change nothing" in both
  branches, fresh and re-run. Domain validation moved to a single block
  that every branch flows through, including the value read from
  `state.env`. (`v1rc-4`)
- Stage 0's domain prompt defaulted to a hardcoded `ayc` regardless of the
  domain the existing install actually uses, so on a host configured with
  any other domain, pressing Enter silently switched it — Stage 6 writes
  both `local-services.conf` and the `Caddyfile` with `>`, so the old
  names are replaced rather than duplicated, and the change would have
  been invisible until DNS stopped resolving. The default now comes from
  `LOCAL_DOMAIN` in `/etc/master-stack/state.env` and falls back to `ayc`
  only when there is nothing to read. The prompt also now names the
  detected domain and spells out what each answer does: `E` regenerates
  from the same domain, `h` stops the installer rather than skipping. The
  previous wording ("varsayılan: korunur") overstated the `E` branch,
  which regenerates rather than preserves, and said nothing about `h`
  aborting. (`v1rc-3`)
- Stage 0's Tailnet-DNS prompt defaulted to `H` even when a managed
  DNS/Caddy install was already present — and that answer makes the same
  Stage 0 abort with "Önceki yönetilen DNS/Caddy kurulumu bulundu".
  Pressing Enter on a re-run therefore killed the installer, which is
  exactly what happened during the 2026-07-29 verification run. The
  prompt now detects the existing install once, defaults to `E`, and
  shows `[E/h]`; the abort check reuses that same detection instead of
  re-testing the three files, so the two cannot drift apart. Fresh
  installs are unaffected and still default to `H`. (`v1rc-2`)
- `tailscale-udp-gro.service`'s unit comment claimed reconcile retried it
  every five minutes. That had been untrue since DD-11 removed the code
  in question on 2026-07-28. The change above makes the claim true again;
  the comment is rewritten to state what actually happens.

## [v1rc] - 2026-07-29

Tagged `v1rc` and exported to `~/Desktop/install-v1rc.sh`, hash-verified
identical to `install.sh` at the tag. `install.sh` is 4502 lines.

Consistency and coverage release. No new functionality: everything here
either removes an internal inconsistency, adds test coverage, or closes a
tracked finding by decision. Validated by a clean install on a reimaged
host, a re-run against that install, and two reboots.

### Validated

- **Clean install on a freshly reimaged host** (2026-07-28/29): all 7
  stages, `master-network-reconcile --check` reporting every field `0`
  and exiting `0`. Followed by a re-run to deploy the unit-permission fix
  — also clean, and a second exercise of the idempotent re-run path.
- **Two reboots.** Recovery is ~35s to SSH and ~13s from boot to all six
  containers healthy. `--check` clean afterwards both times, zero failed
  units, H1's kernel modules auto-loaded, wg-easy's two peers and its
  port intact.
- **Netfilter reconstruction analysed across a reboot.** Nothing persists
  rules to disk (`iptables-persistent` absent, `nftables.service`
  disabled), so the whole set is rebuilt every boot — confirmed by packet
  counters resetting. The rebuilt IPv6 set is byte-identical; the IPv4
  set differs only inside Docker's own chains, because containers get
  different bridge IPs depending on start order and Docker rewrites its
  DNAT/ACCEPT rules accordingly. `MASTER-DOCKER`, `MASTER-TS-FORWARD` and
  the `FORWARD` prefix come back byte-identical. See
  `docs/design-decisions.md` DD-16 for why that separation holds and why
  it matters for how reconcile checks Docker's rules.
- **Boot ordering measured:** `docker-tailscale-fw` starts at the exact
  moment `docker.service` becomes active, and Docker is only active once
  it has created its chains — so the `After=` ordering is a structural
  guarantee, not a race that happens to be won.

### Changed

- **`WEBDAV_PORT` is now a top-level variable** alongside
  `WG_PUBLIC_PORT` and `QBIT_PUBLIC_PORT`, which already existed. `65113`
  had been hand-written in **17 places**; the 13 in variable-expanding
  contexts now use it. This also shrinks **L7** from a 17-site problem to
  a 3-site one (the remainder is inside the single-quoted firewall
  heredoc, which cannot expand outer variables).
- **Named constants for two duplicated policy values** in
  `master-network-reconcile`: `DISK_USAGE_THRESHOLD_PCT` and
  `RESTART_COOLDOWN_SECONDS`. `master-docker-netfilter-recovery` is a
  separate script and cannot share them, so both sides now carry a
  comment saying they must change together.
- **`ensure_forward_prefix()` waits for Docker's chains** instead of
  testing once, via a new `wait_for_chain()` that `wait_for_docker_user`
  now wraps. It ran *before* the functions that already waited, and being
  fatal under `set -e` it could in principle have killed the helper at
  boot. Measured across two reboots: it never actually waits, because of
  the ordering guarantee above — so this is defensive consistency, not a
  demonstrated bug fix, and is recorded as such.
- **Comment language rule reversed to match reality** (`CLAUDE.md`).
  `install.sh` had always been ~73% Turkish-commented while the rule said
  English, so following the rule was producing English blocks inside
  Turkish ones — 45 such lines were translated back. The rule now records
  the actual convention, with the principle that each artifact is
  internally consistent: `install.sh` Turkish throughout, Markdown docs
  and commit messages English, `test/*.bats` and `scripts/*.sh` English
  (bats specifically because Turkish `@test` names break under a
  `tr_TR.UTF-8` locale).

### Fixed

- **systemd unit files were written mode `0600`**, so systemd logged
  `marked world-inaccessible ... has no effect` 12 times per boot. Cause:
  the script's top-level `umask 077`. Stage 6's three drop-ins were
  already chmod'ed to `0644` by hand, which is what made this an
  inconsistency rather than a uniform choice. Replaced with one
  `set_unit_file_mode()` helper used at all **eleven** write sites.
  Verified after the fix: **12 warnings → 0**, no `0600` unit files left.
  File contents are unchanged, so canonical checksums are unaffected.

### Added

- **`test/canonical_bundle.bats`** (8 cases) — `canonical_bundle_ok()`,
  reconcile's first gate, where a non-zero return silences the entire
  self-healing loop. Its correctness depends on Stage 6's manifest file
  list agreeing with a hardcoded expected list ~2000 lines away, which
  nothing enforced and no static check could see. The tests derive both
  lists from `install.sh`'s own source rather than restating them, and
  were mutation-verified on a scratch copy.
- **`test/policy_functions.bats`** (17 cases) —
  `check_ipv4_policy()`/`check_ipv6_policy()`, which hold the entire
  expected firewall rule set and produce the verdict
  `docker-tailscale-fw --check` returns. Covers the healthy policy plus
  eleven distinct failure shapes, and the IPv6 variants including **M5**'s
  missing-`ip6tables` diagnostic and the reduced no-IPv6-WAN set.
  `docs/testing.md` had assumed these were too integration-shaped to unit
  test; that judgement is now corrected in place.
- Test suite: **32 → 57 cases**, and the 25 new ones run with no skips on
  any POSIX host.

### Removed

- **M3 (installation profiles) and L7 (ports hardcoded in the firewall
  heredoc) closed as won't-do**, no code change. Same ground for both:
  this installer targets a single-purpose, single-operator host, always
  built from scratch, with all six services in active use and local DNS
  enabled every time. **M3**'s premise does not hold and its security
  motivation is already covered by **C1**'s accepted risk; **L7** has no
  scenario that can trigger it. `docs/profiles.md` is kept as a design
  note, marked closed. Either reopens if the installer is reused across
  hosts or by another author.
- **M7's remaining scope (CI) parked**, not closed: the repository stays
  local with no git remote by decision, so a runner has nowhere to build
  from. Tier 1 is complete and Tier 2 now has no identified gaps, so **M7
  is the only open finding and nothing about it is actionable today.**

## [v1b] - 2026-07-28

Post-R1.0 hardening and review pass. Exported as
`~/Desktop/install-v1b.sh` (hash-verified identical to `install.sh` at
tag `v1b`).

### Verified

- **First live re-run against an already-provisioned host (2026-07-28),**
  validating this whole batch (**M8**, **M9**, **L6**, **M10** and the
  version-string correction) on the production server. All 7 stages
  completed; `master-network-reconcile --check` reports every field `0`,
  including the new `compose_file=0`, and exits `0`.
  - This also closed the last un-exercised idempotency scenario in
    `docs/testing.md` — every prior live run had been against a freshly
    reimaged host.
  - **It immediately found something.** The deployed `compose.yaml`
    predated both **H7** and **M1**, so `TRUSTED_ORIGINS=portainer.ayc`
    and the `cap_drop`/`read_only` hardening only reached the server in
    this run. Portainer had therefore still been rejecting writes via
    `portainer.ayc` in real use, days after **H7** was "fixed" in the
    repository. A repository fix is not a deployed fix — which is
    exactly the gap **M10** was added to report, found by the very run
    that installed it.
  - Cost: all six containers were recreated rather than just
    `qbittorrent` (the compose diff alone had suggested otherwise);
    Docker was already at the candidate version so no daemon restart
    occurred; admin accounts, wg-easy peer configuration and qBittorrent
    state all survived on their volumes.

### Added

- **Reconcile now detects and reports drift in `/root/docker/compose.yaml`**
  (**M10**). The canonical bundle previously covered `state.env` and the
  six dnsmasq/Caddy files, but not the file that defines all six
  services, their capabilities, `security_opt`, port publications and
  mounts — so a change made directly to the deployed `compose.yaml` was
  never noticed, and `master-compose.service` applied it on every start.
  `compose.yaml` now has a canonical copy, a manifest entry and a
  `compose_file_ok()` comparison.
  - **Reported only, never restored**, and deliberately outside both
    `CONFIG_DRIFTED` and `all_critical_state_healthy()`: restoring the
    file has no effect until a `docker compose up -d`, which would risk a
    5-minute recreate loop if the drift recurs and would silently undo a
    deliberate operator change mid-experiment. It therefore produces no
    failed unit and does not block Stage 7. Same "surface it, don't act
    on it" precedent as the disk-space check (DD-13).
  - The originally proposed scope also covered
    `/usr/local/sbin/docker-tailscale-fw`; that was dropped on
    reflection. On a single-operator host that is always installed fresh
    the firewall helper is never hand-edited, and checking it is close to
    theater given reconcile validates the firewall by invoking that same
    helper. `compose.yaml` earns the check because it genuinely is edited
    live on this stack — the `mem_limit` A/B/C test is a worked example —
    so the real value is catching a live change not yet folded back into
    `install.sh`.
  - Note this changes the manifest's entry list, which
    `canonical_bundle_ok()` compares exactly, so a reconcile script from
    this version cannot validate a bundle published by an earlier one.
    Harmless under this project's deployment model (helper and bundle
    always come from the same run), but it does mean DD-14's
    "an interrupted re-run keeps enforcing the last known-good bundle"
    does not hold across a run that changes the manifest schema.

### Fixed

- **Reconcile could be left permanently unable to validate the canonical
  bundle after an interrupted re-run** (**M8**). Stage 4 unconditionally
  truncated the canonical `SHA256SUMS` to a single `state.env` entry
  while publishing a `state.env` that could say `LOCAL_DNS_ENABLED=1`;
  `canonical_bundle_ok()` cross-checks exactly those two against each
  other, so the bundle was self-inconsistent by construction for all of
  Stages 4-6. While `install.sh` is running this is harmless (reconcile
  defers on the shared lock), but a re-run that *failed* in that window
  left the `EXIT` trap restoring the previously-active timer, after
  which every 5-minute cycle hard-exited before reaching any repair
  logic — no self-healing at all on a half-configured host, reported
  with a message that reads like corruption rather than "interrupted
  install". The 2026-07-28 change moved publication to the end of Stage 6
  and described it as one atomic set. **H8 later corrected that claim:**
  only its manifest rename was atomic. Q1-16's verified generation pointer
  is the implementation that actually makes a failed re-run leave the
  previous complete bundle in place.
- **The stack-level repair path had no restart cooldown** (**L6**).
  Per-container restarts were budget-gated to once per 15 minutes, but
  `systemctl stop master-compose` + `systemctl restart
  docker-tailscale-fw` + `docker compose up --wait` was not, so any
  drift the pass could not actually repair re-ran that sequence every 5
  minutes indefinitely. Bounded in practice — `master-compose.service`
  has no `ExecStop`, so containers were never stopped — but a permanent
  failing unit plus a pointless firewall reapply every five minutes. It
  now reuses the existing `restart_budget_available`/
  `record_container_restart` helpers under a `master-compose`
  pseudo-target. `ADDRESS_CHANGED` is exempt: it self-clears after one
  successful pass, and deferring it would leave the published bindings
  on a stale IP.

### Changed

- `MASTER_SETUP_VERSION` corrected from the stale `2026.07.26-r8` to
  `2026.07.28-v1b`, and reconcile's two summary lines no longer print an
  "R8" prefix — logs, the install banner and the success summary now
  identify which release actually ran. `STACK_SCHEMA=8` is deliberately
  unchanged: it versions `state.env`'s on-disk format, which did not
  change. A comment at the definition site now states that distinction,
  since the two were easy to conflate.
- `ensure_forward_prefix()` (`docker-tailscale-fw`) now names the missing
  chain, the binary and the likely cause instead of returning a bare
  non-zero that `set -e` turns into a silent abort (**M9**). Behavior is
  unchanged; this turns a multi-minute diagnosis into one log line. The
  underlying coupling — the firewall assumes Docker's internal
  `DOCKER-USER`/`DOCKER-FORWARD`/`ts-forward` layout, and every re-run
  upgrades Docker via Stage 1's `full-upgrade` because Stage 3 leaves the
  Docker apt repository configured — was accepted rather than fixed;
  pinning `docker-ce` would freeze CVE fixes on a host that publishes
  ports to the public IPv4. See `docs/design-decisions.md` DD-15.
- `install.sh` 4376 → 4418 lines. Verified with `bash -n`, `shellcheck`,
  `scripts/lint-embedded-scripts.sh` and `bats test/` (all clean).

### Fixed

- Portainer rejected every write request (stop a container, remove an
  image, etc.) made through `portainer.$LOCAL_DOMAIN` — the Tailnet DNS
  name proxied through Caddy — with a CSRF "origin invalid" error.
  Found via real usage after R1.0. Root cause: Caddy always presents
  `Host: 127.0.0.1:9443` to Portainer (its own dial address), while the
  browser's `Origin`/`Referer` is `http://portainer.$LOCAL_DOMAIN` — a
  mismatch Portainer's CSRF protection treats as cross-origin. Fixed by
  setting Portainer's `TRUSTED_ORIGINS` environment variable, only when
  local DNS is enabled (**H7** in `SECURITY_REVIEW.md`).
  - **A wrong fix was caught before reaching `install.sh`.** The first
    attempt set `TRUSTED_ORIGINS=http://portainer.$LOCAL_DOMAIN`
    (`scheme://host`), matching how Portainer's current `develop` branch
    validates this value (it recently migrated to Go's native
    `http.CrossOriginProtection`). Tested directly against the live
    deployed `compose.yaml` first, specifically to verify before
    committing to `install.sh` — Portainer **crashed on startup**
    (fatal: "invalid url for trusted origin"). The pinned `2.39.5`
    release still uses the older `gorilla/csrf` library, whose validator
    does the *opposite*: it rejects any value containing `"://"` and
    expects a bare hostname. Caught by reading `2.39.5`'s actual tagged
    source on GitHub rather than trusting `develop`'s (newer, different)
    behavior. Reverted the live container immediately, corrected the
    value to `portainer.$LOCAL_DOMAIN` (no scheme), and confirmed live:
    container starts and stays up, and a simulated write request with
    the original failing `Origin`/`Referer` headers now returns `401`
    (reaches the authentication layer) instead of `403`
    ("origin invalid"). Applied to `install.sh` only after this live
    confirmation.
  - `install.sh` 4343 → 4365 lines. Verified with `bash -n`, `shellcheck`,
    `scripts/lint-embedded-scripts.sh`, and `bats test/` (all clean).

### Changed

- `qbittorrent`'s `mem_limit` raised from `2g` to `4g` after the user
  reported a real download-speed regression (~200MB/s → ~70-80MB/s)
  following **M1**'s container hardening. A live A/B/C comparison during
  an actual high-seed-count torrent download (recreating the container
  between each measurement window, same active transfer throughout)
  isolated the cause:
  - Original `cpus=2.0`/`mem=2g`: throughput capped ~170MB/s, CPU usage
    saturating near the 2-core limit (~197%) at peak.
  - All limits removed: 218-278MB/s, CPU using up to ~245% (more than 2
    cores) — confirming a real ceiling existed, not just swarm variance.
  - `cpus` held at `2.0`, only `mem_limit` raised to `4g`: also reached
    up to 275MB/s, with CPU comfortably under the 2-core cap throughout.
    This isolates the actual cause: the `2g` memory ceiling was
    constraining qBittorrent's disk cache/buffering, which was *also*
    driving up CPU usage indirectly (more frequent, smaller I/O) — the
    CPU saturation seen in the first test was a symptom of the memory
    limit, not an independent bottleneck. `cpus: 2.0` is unchanged,
    confirmed not to be the binding constraint.
  - Applied to the live deployed `compose.yaml` first (for the test
    itself), then to `install.sh` once confirmed. `install.sh` 4365 →
    4370 lines. Verified with `bash -n`, `shellcheck`,
    `scripts/lint-embedded-scripts.sh`, and `bats test/` (all clean).

### Removed

- `qbittorrent`'s `mem_limit` and `cpus` ceilings removed entirely
  (`compose.yaml` → `services.qbittorrent`). Even at `4g`, sustained
  high-throughput download load showed throughput fluctuating again; a
  further raise to `6g`/`3.0` was tried locally (never committed) before
  the user decided the ceiling itself was the problem, not its value. On
  a 4 CPU / ~8GB host, a limit that has to be raised each time real usage
  grows past it stops being containment and only remains a throughput
  risk — the last value tried (`6g`) already sat above the highest
  observed unlimited usage (~4.7GB), so it constrained nothing while
  still being able to throttle a future workload.
  - **What this does not change:** the hardening that actually contains
    this container is untouched — `security_opt: no-new-privileges`,
    `cap_drop: [ALL]`, and the minimal `cap_add` set (**M1**).
    `unpackerr` keeps its own `mem_limit: 512m` / `cpus: 1.0`, which
    never constrained it under a real extraction workload.
  - **Trade-off, accepted by the user:** a runaway `qbittorrent` is now
    bounded by the host's global OOM killer rather than its own cgroup,
    so the blast radius of that (unobserved so far) failure mode widens
    from one container to the host. Recorded under **M1** in
    `SECURITY_REVIEW.md` as an accepted deviation, not a regression to
    re-fix.
  - `install.sh` 4370 → 4376 lines. Verified with `bash -n`,
    `shellcheck`, `scripts/lint-embedded-scripts.sh`, and `bats test/`
    (all clean).

## [1.0.0] - 2026-07-28

### Added

- `master-network-reconcile`: a new `disk_space_ok()` check monitors the
  filesystem backing `$DOWNLOADS_PATH` (persisted to `state.env` as of
  this change) and reports (but cannot auto-repair — deleting user data
  isn't a safe automated action) once usage crosses 90%. Motivated by
  this server's actual workload (continuous downloading/extraction),
  which was previously the one realistic failure mode reconcile had zero
  visibility into. Tested against both a real disk and an artificially
  filled tmpfs on the live server.
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
- **Final architecture review, disk-space monitoring, R1.0.** At the
  user's request, considering the server's actual intended use (a
  personal, long-running download/media/VPN box) and how its systems
  relate to each other, did a deep-dive review of `master-network-reconcile`
  (what it tracks and how), systemd unit dependencies, IPv6, container
  DNS, and wg-easy's kernel-module approach, plus live verification of
  each. Findings, all confirmed working as intended:
  - IPv6 works end-to-end, including real egress from inside the
    `wg-easy` container (`ping -6` to Cloudflare succeeded).
  - Containers reach `1.1.1.1`/`1.0.0.1` directly for DNS via Docker's
    own embedded resolver, entirely independent of the host's
    Tailscale-overridden `/etc/resolv.conf` — confirmed by design (L4)
    and live (`nslookup ... 1.1.1.1` from inside a container).
  - wg-easy's host-side kernel-module approach (H1) is the standard
    hardening pattern, not an indirect workaround; the only more-isolated
    alternative (fully userspace WireGuard) would require forking the
    wg-easy image and wasn't pursued (already documented as DD-10's open
    alternative).
  - A Tailscale IP change correctly cascades through firewall refresh,
    `.env` regeneration, and container recreation (traced via
    `ADDRESS_CHANGED` → `STACK_RESTART_REQUIRED`).
  - Caddy/dnsmasq boot ordering was the most scrutinized part, given the
    real risk (losing Tailnet-DNS/Caddy access, though never root SSH
    access, which is independent) if they raced. Found it's already
    defended in depth: `dnsmasq` uses `bind-dynamic` so a missing
    interface at startup never crashes it; `caddy.service`'s
    `ExecStartPre` actively polls for `tailscale0`'s IPv4 (up to 300s)
    rather than trusting `After=` ordering alone; a reverse
    `Wants=`/`Before=` drop-in on `tailscaled.service` re-triggers Caddy;
    and `OnFailure=master-network-reconcile.service` is the final
    backstop. Confirmed via real boot logs: `tailscaled` → `dnsmasq` (2s)
    → `caddy` (1s), zero races observed.
  - Considered adding Tailscale key-expiry monitoring (the node's key
    expires 2027-01-24; nothing currently warns in advance) — the user
    opted to track this themselves rather than add it to `install.sh`.
- **New: disk-space monitoring for `master-network-reconcile`** (see
  Added, above) — the one concrete gap found, given this server's actual
  workload. `install.sh` 4319 → 4343 lines. Verified with `bash -n`,
  `shellcheck`, `scripts/lint-embedded-scripts.sh`, `bats test/`, and a
  live isolated-function test on the server (real disk: healthy;
  artificially filled 10MB tmpfs: correctly flagged unhealthy at 90%).
- **R1.0**: tagged as the first stable, validated release, given the
  cumulative result of today's work — all resolvable audit findings
  fixed (**H1**-**H6**, **M1**-**M2**, **M4**-**M6**, **C1**-**C2**,
  **L1**-**L5**), four successful live end-to-end installs, a full
  operational stress test (reboot, deliberate drift injection, resource
  limits, real WireGuard/Tailscale traffic, CPU stress), and this final
  architecture review turning up no functional defects. **M3** (install
  profiles) and **M7**'s remainder (CI wiring, a few more unit tests)
  remain open, deliberately deferred, not blocking this tag. The
  annotated `R1.0` git tag was created pointing at this state, and the
  resulting `install.sh` was exported to `~/Desktop/install-R1.0.sh`
  (hash-verified identical to the tracked copy) at the user's request.

## End-of-session documentation pass — 2026-07-28

Reviewed every Markdown document in the repository for accuracy against
the current `install.sh` (4343 lines, tagged `R1.0`) and updated the ones
affected by today's work, beyond what was already synced commit-by-commit
above:

- `README.md`: added a version header (`R1.0`); refreshed the **Current
  Limitations** section, which still claimed containers ran "without
  CPU/memory limits, `no-new-privileges`, or reduced capability sets"
  (stale since **M1** was fully resolved earlier today) and still listed
  the unconditional `chown -R` as a limitation (stale since **M2**,
  resolved in an earlier session) — replaced with an accurate note about
  the new disk-space check's inherent limitation (report-only, no
  auto-repair); refreshed the bats-core test count/list; added **M1**'s
  `cap_drop`/`cap_add`/`read_only` details and the `ip6_tables`/
  `ip6table_nat` addition to the **Docker Services** notes.
- `docs/architecture.md`: refreshed all stage/heredoc line-number ranges
  (shifted by today's edits, now 4343 lines total); added the disk-space
  check to reconcile's described check list; added **M1**'s container
  hardening to the service inventory notes; noted `DOWNLOADS_PATH` now
  being in `state.env`.
- `docs/design-decisions.md`: added **DD-12** (why wg-easy's pending
  first-run setup must never gate Stage 7/`--check` — the **H6** fix) and
  **DD-13** (why the new disk-space check reports but never
  auto-repairs); added a live-confirmation note to **DD-8** (container
  DNS independence, verified today); updated the "nftables vs. legacy
  backend" rejected-alternative note, since today's **H1** investigation
  concretely answered a question that note had previously left open.
- `docs/profiles.md`, `docs/testing.md`: reviewed, found already
  accurate and unaffected by anything not already captured in this
  file's entries above — no changes needed.
- `TODO.md`, `SECURITY_REVIEW.md`, `SESSION.md`: reviewed and confirmed
  current (see `SESSION.md` for this session's final Current
  Task/Completed/Remaining/Next-Step summary).

No changes to `install.sh` in this pass (documentation-only, per
instruction). No commit was created for this pass, per instruction — all
of the above are uncommitted working-tree changes as of this writing.
