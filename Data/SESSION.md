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
**2026-09-11 — first production restore with container-backup:** the
2026-09-06 archive (old Debian 13 nrm, v2-73) was restored onto the fresh
Debian 13.6 v2-79 host from this Mac at 13:39 (+03), followed by a reboot.
Verified afterwards: wg-easy config/db byte-identical to the archive with the
three old peers on `wg0`, qBittorrent password hash identical, FileBrowser
settings identical, Portainer admin present, host fully healthy. Recorded in
`docs/container-backup.md`; its stale "v73" wording was corrected (the tool is
version-agnostic and was exercised at v2-79). Open question raised by the user:
whether WebDAV/Infuse state belongs in the backup — analysis in the session
reply; no code change yet.
**2026-09-14 — v2-95, backup merged into wireguard.command:**
- At the user's request `ayarlar.command` became option 6 "Yedek al" of
  `wireguard.command`, and the separate file was removed.
- The live test piped the choices on stdin. The first `remote version` ssh
  read and swallowed that input, so `remote()` now uses `ssh -n`.
- On `nrm`, from a scratch copy pinned to the server's v2-94, the option
  pulled `wg0.conf` and 4 profiles identical to the user's copy; a second run
  showed "aynı". bats 132.
- Open: the user re-runs the installer (v2-95); the menu version check
  needs it.

**2026-09-14 — v2-94, qBittorrent settings from a template, account from kurulum.env (DD-129):**
- The user dropped pulling qBittorrent and asked the installer to write it,
  with the password in `kurulum.env`.
- To isolate real changes:
  - qBittorrent on `nrm` was reset to a clean file; the old config was kept
    at `/root/qbittorrent-onceki-20260914-182545`.
  - The user set it up in the UI; a second reset was needed after a wrong
    pick.
  - The two files were diffed into `templates/qBittorrent.conf`.
  - DHT/PeX/LSD and anonymous mode stayed default this time.
- Code:
  - `TORRENT_USER`/`TORRENT_PASS` inputs and `python3` in base packages.
  - `qbit_pbkdf2`, which keeps a verifying hash.
  - INI-aware `qbit_conf_diff`/`qbit_conf_merge`.
  - `sync_qbittorrent_config`, which stops the client only to change.
  - Stage 7 `qbit_login_check`: qBittorrent 5.2.3 returns `204` on success,
    found live.
  - The qBittorrent parts of DD-128 were removed.
- Live on `nrm`:
  - sync over the user's config: only the account and auth guards differed;
  - no-op re-run;
  - API change reverted;
  - fresh config correct;
  - no-op after qBittorrent's own rewrite.
  - The user's qBittorrent config and the real accounts were restored
    byte-identical. bats 132.
- Open:
  - The user adds `TORRENT_USER`/`TORRENT_PASS` (their qBittorrent login) to
    `kurulum/kurulum.env`.
  - Delete `/root/qbittorrent-onceki-*` on `nrm` if not needed.

**2026-09-14 — v2-93, ayarlar.command and restore-where-absent (DD-128):**
- The old Transmission dirs on `nrm` were deleted at the user's request.
- New:
  - `ayarlar.command` pulls `wg0.conf`, the profiles (mirrored) and
    qBittorrent's `qBittorrent.conf` only (the user's call: categories, RSS
    and watched folders are unused) into `kurulum/`, printing no content.
  - The launcher sends them.
  - Stage 0 moves them to `RESTORE_DIR` and validates strictly (no `PostUp`,
    subnet-bound AllowedIPs, key format, whitelist, size).
  - Stages 4/5 restore only when the server file is absent, and
    `RESTORE_DIR` is removed after stage 5.
- Live on `nrm` (the user's real host), with real accounts, `/etc/wireguard`
  and qBittorrent `/config` saved and put back:
  - pull OK;
  - a run over the existing server was untouched and no-op;
  - a fresh simulation restored identical key, peers and qBittorrent account
    lines, and the Mac's `iph0` reconnected unchanged.
  - bats 128.
- Open:
  - The user runs `ayarlar.command` into their real `kurulum/`, with the Mac
    off WireGuard.
  - Infuse and Tailscale admin for `100.85.4.106`, if not done.

**2026-09-14 — v2-92, qBittorrent returns (DD-127):**
- The user found Transmission slow.
  - We discussed that DHT/PeX off limits peers in any client; the user keeps
    them off.
  - Docker vs. a host package: Docker stays.
  - The user asked for no installer-written qBittorrent settings. They will
    configure the UI once, then (v2-93) an `ayarlar.command` pulls the
    whole `qBittorrent.conf` plus the WireGuard server config and profiles
    into `kurulum/`. A fresh install restores them, and only when absent on
    the server.
- v2-92 changes:
  - The `qbittorrent` service with `/config` on
    `/etc/master-stack/qbittorrent`; ports come from the image's command line.
  - Stage 7 requires API `403` without a login.
  - `TRANSMISSION_*` input keys are removed and named when present.
  - A leftover `transmission` container gate.
- Live on `nrm`:
  - The host was the user's own fresh v2-90 manual install: Tailscale node
    `nrm-1`, **100.85.4.106**, WG peer `iph0`, installed 14:38 server time.
  - Old keys refused, gate refused, then exit 0 after `docker rm -f
    transmission`, and a no-op re-run.
  - Real account files restored. The Mac's `iph0` tunnel was paused for the
    launcher and reconnected. bats 123.
- Open:
  - **v2-93**: `ayarlar.command` plus the restore.
  - The user sets qBittorrent up in the UI (temporary password in Dozzle).
  - The old `/etc/master-stack/transmission{,-auth}` dirs on `nrm`, to delete
    (they hold the old Transmission password in plaintext).

**2026-09-14 — v2-91, negated bats assertions made effective (DD-126):**
- The work from the merged worktree session was redone on the current tree.
  - 115 bare `!`/`[[ ]]` statements were converted, and a guard test was
    added.
  - Four over-broad assertions were narrowed to code lines: `--disable-exec`,
    `try-restart`, the old FileBrowser password hints, and `docker rm` in
    `die`/`log`.
  - The dead v2-65 `webdav` recreate block in `stage_6` was removed, as the
    user had chosen.
  - The DD-96 guard wording was updated.
- Checks:
  - bats 123 ok, 3 `timeout yok` skips.
  - An exit-code diagnostic showed all 144 negated evaluations returning 1.
  - Six mutations were caught.
- No live run: the removed path needed the uncommitted v2-65 layout.
- `wip/bats-negation-v2-84` is kept for reference.

**2026-09-14 — other sessions merged into this one:** at the user's request,
so nothing is lost when those sessions are archived.
- **"SERVER SETUP" (2026-09-08..13):** v2-74..v2-84 decisions. They are all
  committed (`d2f778b` and earlier) and recorded in the entries below and in
  the DDs. Durable user preferences went to Claude's memory.
- **"Make bats negative assertions actually fail" (worktree
  `claude/magical-shannon-e0b514`):**
  - Its uncommitted work was on a v2-84 base. It is now preserved as `fab2643`
    on branch `wip/bats-negation-v2-84`, not merged.
  - Under macOS bash 3.2 a mid-test `! cmd` or `[[ ]]` never fails a test.
  - Open work:
    - Redo the conversion on the current base (~98 `!`, 17 `[[` at v2-90).
    - Remove the dead v2-65 block in `stage_6` that recreates `webdav` when
      it still publishes `${TAILSCALE_IPV4}:${WEBDAV_PORT}`. The user chose
      removal (DD-96).
    - Fix four tests that match comments or operator messages.
    - Update the DD-96 "Guard" wording.
  - That session's read-only disk check listed `kurulum/kurulum.env` keys
    with the values stripped, which showed only `SSH_HOST=nrm`.
- **"DATABASE CORE" (archived, 2026-09-02, old iCloud copy):** the transcript
  and the path are gone, so nothing was recoverable. Its work predates the
  entries here.

**2026-09-14 — v2-90, smaller install footprint (DD-125):**
- The user saw a fresh install grow disk use by 1.7 GB.
  - Measured: Docker recommends and buildx about 200 MB, the kept apt cache
    303 MB, and debian-keyring 34 MB.
  - The rest was untrimmed blocks.
- v2-90 installs Docker with `--no-install-recommends` plus `apparmor pigz`,
  without buildx. apt deletes its downloaded debs, and debian-keyring is
  dropped (the OS-divergence branch goes with it).
- Found live: `retry` runs functions in a child bash, so the masked-quiet
  dnsmasq/Caddy installs never had `APT_OPTS`. Callers now pass it; a bats
  test covers it.
- Live on `nrm`:
  - Purged Docker/Caddy/dnsmasq and ran with the scratch inputs.
  - The first run hit a transient registry rate-limit at the stage 7 pull.
    The re-run was fine but exposed the `APT_OPTS` bug.
  - After the fix: exit 0, 0 debs, no buildx/git/perl/keyring, no-op re-run,
    df 2389 → 1940 MB.
  - Real account files were restored (hash-identical), and `fstrim` ran. The
    Mac's WireGuard was switched off for the launcher. bats 122.
- Open:
  - The user runs the first install manually.
  - `pppp` handshake.
  - Infuse address.

**2026-09-14 — v2-89, server-generated WireGuard peers and wireguard.command (DD-124):**
- The user wanted peers handled the native admin way, with nothing sent to
  the server.
- `master-wg` on the server generates keys, allocates addresses, keeps
  profiles in `/etc/wireguard/clients` and applies them with `wg syncconf`.
- `wireguard.command` on the Mac lists, adds (name/DNS/keepalive/MTU), removes
  and shows QR codes, saving profiles to `kurulum/wireguard/`.
- The installer now manages only `[Interface]`. `WG_PEERS`/`WG_CLIENT_*`,
  profile parsing and the launcher's WireGuard send/fetch were removed.
- A reinstall means new keys, with devices re-added from the menu.
- Found by tests: `state.env` needed quotes for `WG_CLIENT_ALLOWED_IPS`;
  `master-wg list` clobbered its loop variable.
- `nrm` was reset by the user for a clean test; the old WireGuard files in
  `kurulum/wireguard/` were deleted at their request.
- Live: fresh install with the operator's folder; menu adds, duplicate
  refused, list, QR, removal; namespace client test; no-op re-run; reboot.
  Test peers were removed, so `nrm` has 0 peers. bats 120.
- The user set up the Tailscale admin side: the exit node is offered and
  `ayc` splits to `100.73.123.57`.
- Real devices `pppp` and `mmmm` (this Mac) were added from the menu and
  verified over the tunnel: egress, DNS, UIs, MTU and every blocked path.
  Public-site speed tests were path-limited and later rate-limited.
- Found: `wireguard.command` cannot reach `SSH_HOST` (public IP) while the Mac
  itself is on WireGuard. The user chose no code change: switch WireGuard off
  on the Mac first. This is noted in `OKUBENI.txt` and DD-124.
- Failure tests, with this Mac on the tunnel; the steps ran as transient server
  scripts and were cleaned up afterwards (DD-124):
  - Mac-to-server throughput: `wg0` 461–498 Mbit/s single stream against
    237–241 over SSH, and 386–465 with 4 streams. The server was 75–80% idle;
    the Mac and the home line are the ceiling.
  - `wg-quick@wg0` restart, stop and start: `caddy-wg` followed, peers were
    kept, and the client failed closed and recovered.
  - Docker restart: healthy in 11 s, firewall re-applied with `MASTER-FORWARD`
    first, and bridge IPs closed over WireGuard.
  - `tailscaled` down for 3.5 min: WireGuard UIs and egress 109/109, and
    everything recovered when it came back, without a Caddy restart.
- Open:
  - `pppp` has not handshaken since the `wg0` restart; the user checks the
    phone.
  - Update the Infuse address, if not done yet.

**2026-09-14 — container-backup retired (DD-122) and v2-88, live WireGuard changes (DD-123):**
- The backup tool, its worker, document and round-trip test were removed
  (commit `dccdfbb`); `backup/` stays Git-ignored.
- The user wanted peers handled the kernel WireGuard way: `wg genkey`,
  `wg pubkey` and `wg genpsk`, a `[Peer]` block, then `wg syncconf wg0
  <(wg-quick strip wg0)` with no restart. The installer already did the
  first steps; v2-88 now restarts `wg-quick@wg0` only when it is down, when
  its `Address`/`MTU` changed or when `syncconf` fails, and never passes an
  empty strip.
- Live on `nrm`: removing `deneme` from `WG_PEERS` went from 5 peers to 4
  with `wg-quick@wg0` and `caddy-wg` untouched. `deneme.conf` was deleted and
  the next run was a full no-op. bats 120.
- **Open:**
  - Commit v2-88.
  - Tailscale exit-node re-approval.
  - Fresh-install test when `nrm` is reimaged.

**2026-09-14 — v2-87, WireGuard peers from kurulum.env (DD-121):**
- `WG_PEERS` lists the peers; `WG_CLIENT_DNS`, `WG_CLIENT_KEEPALIVE` and
  `WG_CLIENT_DNS_OVERRIDE` (`name=dns; …`) shape every profile.
- A listed peer without a `kurulum/wireguard/<name>.conf` gets `wg genkey`,
  `wg genpsk` and the next free address on the server (plus `sunucu.key` on a
  first install).
- New and changed profiles go to tmpfs `OUTPUT_WG_DIR`, a QR is printed for
  new ones, and the launcher fetches them back into `kurulum/wireguard/`
  before removing the server copy.
- Verified: bats 121 and three mutations caught.
- Live on `nrm` with the operator's folder (4 devices + temporary `deneme`,
  keepalive 21, one DNS override): exit 0, `deneme` = 10.8.0.6, five profiles
  back and matching `wg0` exactly.
- The fetched `deneme` profile worked as a namespace client (UIs, IPv4/IPv6
  egress; SSH, WebDAV and other peers refused).
- **Open:**
  - The operator removes `deneme` from `WG_PEERS`, then one run removes the
    peer; delete `deneme.conf` by hand.
  - Re-import profiles on devices if DNS/keepalive changed.
  - Commit v2-87.
  - Retire `container-backup`.

**2026-09-14 — v2-86, kernel WireGuard replaces wg-easy (DD-120):**
- `kurulum/wireguard/sunucu.key` plus one wg-easy-format `<device>.conf` per
  peer feed `wg-quick@wg0`, using wg-easy's addresses and port 61001.
- The launcher tars them with `kurulum.env` to `/run`. Stage 0 slurps and
  deletes the folder and validates it.
- After the firewall, `wireguard-tools` is installed and the key match is
  checked with `wg pubkey`. `wg0.conf` then gets public keys and PSKs only.
- `master-firewall` gained `MASTER-FORWARD` (`wg0` → WAN only) and
  `MASTER-NAT`; `MASTER-INPUT` lets `wg0` reach only `10.8.0.1` on the three
  UI ports plus ping.
- `caddy-wg` (admin off, bound to `10.8.0.1`) serves the UIs, independent of
  Tailscale.
- The wg-easy service, network, UI name and legacy modules are gone.
- On `nrm`, before the migration run:
  - The user had deleted the node from the tailnet at 00:52 CEST. A first
    test run with a test file therefore stopped at stage 2 (no auth key,
    410 retries); only the WebDAV htpasswd had changed, and it was restored
    byte-identical.
  - The four device profiles were generated from wg-easy's DB into
    `kurulum/wireguard/` without printing keys, and they matched the running
    peers.
  - `docker rm -f wg-easy`, keeping the volume.
- Migration and checks on `nrm`:
  - v2-86 ran with the operator's own `kurulum/` folder, at the user's
    request and never opened: the auth key logged back in, the node kept
    100.76.190.121 and the run exited 0.
  - A namespace test peer confirmed the allowed and blocked matrix; a no-op
    re-run and a reboot came back clean.
  - A real device then handshook and opened Dozzle at `10.8.0.1:61002`
    (the user confirmed it).
- bats 119.
- **Open:**
  - The operator re-approves the exit node and re-checks DNS in the Tailscale
    admin console.
  - Retire `container-backup` in a separate commit.
  - Run a fresh-install test when `nrm` is reimaged.

**2026-09-14 — v2-85, installer inputs from one file (DD-119):** the user runs
a fixed setup and wants a reinstall with no typed answers.
- `kurulum/kurulum.env` holds every input and is the truth on every run.
  - It is git-ignored with mode 600; the template is
    `config/kurulum.env.example`.
  - The launcher reads `SSH_HOST` and sends the file only to `/run` (tmpfs).
  - Stage 0 parses it strictly (never sourced) and deletes it first, then
    validates, shows a summary without passwords and asks for one `E`.
  - Accounts that differ are rewritten and only their container restarts.
    FileBrowser is compared on a DB copy and updated by stop, then
    `users import --overwrite`, then start.
- Verified: bats 116 (new negative checks use `run !`/`[ ]`, because
  mid-test `!` and `[[ ]]` do not fail under macOS bash 3.2 — a suite-wide
  fix was offered as a separate task), static checks clean, three mutations
  caught.
- Live on `nrm` with the exported `.command` under `expect`: mode 644 refused
  on the Mac; cancel changed nothing; v2-84→v2-85 rewrote only WebDAV; a no-op
  re-run; three password changes hit exactly three services; an unknown key
  and a short password stopped stage 0.
- The operator's real WebDAV htpasswd was saved first and restored
  byte-identical (sha prefix `fead38157cb39fb2`). Test credentials on `nrm`
  are unchanged.
- **Next (agreed, not started):** step 2 — kernel WireGuard replaces wg-easy.
  - Peers are `kurulum/wireguard/*.conf`; the 4 existing peers on
    10.8.0.2–.5 migrate without touching devices.
  - Peers get internet egress plus the container UIs on `10.8.0.1:<UI port>`
    only, through a second, Tailscale-independent Caddy. They get no tailnet
    access, and WebDAV stays Tailscale-only.
  - `container-backup` is retired after the migration is verified.

**2026-09-14 — v2-84, FileBrowser account and Transmission preferences from
the installer (DD-118):** the user wants to rely on the backup as little as
possible. Stage 0 asks for the FileBrowser account (12-character minimum);
stage 4 builds the Bolt DB with `config init` (flags matching quick setup)
and `users import` of an htpasswd-made bcrypt hash, in a network-less one-shot
container, verifies it and moves it into place. The user first suggested
embedding the password from the backup or in `defaults.env`, then chose the
prompt after the trade-offs were laid out. The Transmission seed adds DHT/PeX/LPD
off and a download queue of 12. The backup now carries `wg-easy.db` only.
Verified live on `nrm`. Test credentials on `nrm`: FileBrowser `admin` /
`12345test1234`; Dozzle and Transmission `admin` / `12345test`.
**2026-09-13 — v2-83, Transmission replaces qBittorrent (DD-117):** the user
downloads only and wanted a simpler client. Transmission (LinuxServer, 4.1.3)
at `torrent.ayc`, peer port 61005 unchanged, `QBIT_*` → `TORRENT_*`
everywhere (incl. `state.env` and firewall). Credentials are asked in stage 0
and kept as plaintext root-only files passed via `FILE__` — measured necessary:
the image disables auth without them and its clean-shutdown RPC needs the
plaintext (a hash made stops hang and lose settings). The settings seed must
contain `rpc-port` (without it every stop hung). A leftover qbittorrent
container gates stage 0. Credential rewrites now restart the container (also
fixes Dozzle's password change). Backup scope: Transmission `settings.json`.
Verified live on `nrm`, which the user now treats as a test host again and
will reimage. Test credentials on `nrm`: Dozzle and Transmission `admin` /
`12345test`; `docker_portainer_data` and `docker_qbit_config` volumes remain.
**2026-09-13 — v2-82, Dozzle replaces Portainer (DD-116):** the user uses
Portainer only for state, logs and removal. Dozzle (`amir20/dozzle:v11`) is
now the sixth service at `dozzle.ayc`, with login from a stage-0 prompt
(`users.yml` via the image's `generate`, password on stdin, role `actions`),
actions on, shell off, hardened container, stage-7 login check, and a warning
for a leftover Portainer. The backup scope became three files; Portainer-era
archives still restore. Verified live on `nrm`. **On `nrm`:** Dozzle account
set to `admin` / `12345test` (test answer — the user should replace it); the
Portainer container was removed by hand, and its volume
`docker_portainer_data` is kept pending the user's decision.
**2026-09-13 — v2-81, optional Tailscale auth key (DD-115):** stage 0 asks
for an optional key (hidden, skipped when already online); stage 2 logs in
via `--auth-key=file:` from a 0600 tmpfs file and falls back to the browser
URL on rejection/timeout. Verified by bats (including a fixed
pipefail-dependent exit status), a container-isolated real Tailscale
rejecting a fake key, TTY trimming, and a no-op re-run on the online
production host. A successful real-key login is pending the next fresh
install. **Test incident:** the first isolated test started a host-level
`tailscaled` with only `--statedir`; it loaded the production state for a
few seconds and rewrote `/etc/resolv.conf`, which production restored the
same second — no lasting effect (verified: state file, prefs, DNS, peers,
Caddy). Pitfall recorded in `tests/README.md`.
**2026-09-13 — repository reorganised:** at the user's request the root now
holds only what is double-clicked (current `<V2_VERSION>.command`,
`container-backup.command`, `backup/`) plus `README.md`, `CLAUDE.md`,
`.gitignore`, `.cursor/`; everything else moved under `Data/` (`git mv`).
Exporter keeps the root copy current and archives every version in
`Data/app/`; `latest.command` and the `export/` folder are gone (its backup
moved to `backup/`, click-order note to `Data/OKUBENI.txt`). Re-export was
byte-identical; bats 99 ok. Test backups (`…eVtDgc`, `…DGguu4`, `…j8xNnG`,
test password) are still in `backup/` next to the user's real
`…G3rRfA`; deleting them is pending the user's go-ahead.
**2026-09-13 — container-backup narrowed to one file per service (DD-114):**
the user described their whole post-install routine (Portainer admin,
FileBrowser and qBittorrent passwords and a few preferences, wg-easy account
and peers) and asked to minimise the scope. The same morning's uncommitted
widening of qBittorrent to its settings tree was reverted. Backups now carry
`portainer.db`, `filebrowser.db`, `qBittorrent.conf` and `wg-easy.db` only;
restore writes those four and clears SQLite side files, leaving keys,
certificates, `wg0.conf` and `settings.json` to the install/app. Proven with
throwaway Portainer/FileBrowser instances and a live self-restore on `nrm`
(12 out-of-scope files unchanged). The user's 2026-09-12 real backup stays
valid. The test archive `backup/20260913T105036Z-nrm-settings.DGguu4` came
from the reverted widening and is rejected; delete it.
**2026-09-12 — v2-80, unattended security upgrades (DD-113):** the user
reimaged `nrm` as Debian 13.6, installed v2-79 by hand and restored the real
backup — the first bare-OS run of the runbook; the outcome was verified
(18/18 acceptance, 3 wg peers, restored settings, all DD effects). The
optimisation review found one gap: the netcup Debian image has no
`unattended-upgrades`. v2-80 installs it with the distribution's default
origin filter and `Automatic-Reboot "false"`, and stage 7 reads the policy
back. Live-verified on the Debian host (re-run + no-op re-run, exit 0, no
container recreated, Docker/Tailscale/Caddy outside the filter) after a
first attempt exited 141 on a pipefail/SIGPIPE in the new read-back — now a
bats guard and a tests/README pitfall. Portable v2-80 exported; `export/`
refreshed. Not re-run on Ubuntu (package and files pre-exist there).
**2026-09-11 — container-backup: encryption and single upload (DD-112):**
new backups are `settings.tar.gz.enc` (standard `openssl enc`, AES-256-CBC +
PBKDF2-SHA256 600k; password asked twice on backup, once on check/restore;
decrypted locally, never sent to the server; old plaintext backups stay
usable; archive layout/schema unchanged). Restore uploads once and, since
2026-09-12, no longer downloads a before-restore backup (single copy on
backup, direct load on restore; server-side rollback snapshot kept). The
launcher is macOS only again: a Git Bash/WSL-portable variant was dropped
on 2026-09-12 at the user's request. A `seed` action (installer inputs in the
archive, placed before `install.sh`) was built, verified end to end and
removed the same day at the user's request — see DD-112; the design is in
`d92b338`. Verified: static checks, bats green, round-trip on `nrm`, encrypted
backup/check/restore from the Mac. Ready-to-run copies for the operator live
in git-ignored `export/` with a Turkish click-order note (`OKUBENI.txt`).
**Open:** the user will reimage `nrm` (netcup), install by hand with real
answers and a real WebDAV password, configure the services and take the real
backup; the full runbook (bare OS → install → restore) is then the next
acceptance item. The four test
backups under `backup/` are throwaway (two use a session test password; the
two from the seed build contain `host/` and are rejected by the final tool).

**2026-09-11 — Debian 13 acceptance of v2-79 (nrm reinstalled as trixie):**
closes the Debian gap for v2-77…v2-79. Fresh install from bare metal in 80 s,
no-op re-run (0/6 recreated), seeded `ubuntu/resolute` → `debian/trixie`
release-change run, cold reboot, post-reboot re-run — all exit 0. On the
settled post-reboot system the acceptance check passed 20/20: DD-108 deferred
the netfilter gate (`iptables` absent on minimal Debian), DD-109's resolved
block was skipped (resolved inactive, no drop-in created), DD-110's ordering
held (daemon.json before dockerd's only init; container DNS and log options in
effect with no restart), and DD-111's `tcp_bbr` — previously "expected but
unverified" on Debian — loads on the 6.12 kernel, with `bbr` on Caddy's
accepted socket and `fq` on `tailscale0` after the reboot. Two lessons about
the *acceptance script itself* went into tests/README.md: `Self.ExitNodeOption`
depends on admin approval, so it is informational, not an installer assertion;
and healthchecks need settle time after a reboot (filebrowser's first healthy
came 8 s after a premature check). Neither was an installer defect.
**Both supported distributions have now had the same acceptance at v2-79.**
Ubuntu 24.04 remains unverified since v2-72.

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
