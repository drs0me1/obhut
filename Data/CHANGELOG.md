# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### 2026-10-01 — Per-connection WebDAV policies and dual-card Shares (v2-164)

- Each folder keeps one ID/account while Tailscale and WAN independently control
  enabled state, RO/RW and expiry (DD-192). Both off is valid. New shares use
  Tailscale on/RO/seven days and WAN off/RO/seven days.
- Schema 4 stores both connection policies. Valid schema 3 converts in memory
  and `prepare` persists it without rotating accounts, changing identity/timestamps
  or renewing expiry. Schema 2 and conflicting legacy fields in schema 4 fail
  closed. Stale global-policy updates and pause requests require a page refresh.
- Nested partial saves preserve omitted values under the locks. Explicit RW needs
  acknowledgement in the selected scope; toggles never renew expiry. The receiving
  listener enforces its policy on DAV writes, transfer chunks and staged uploads,
  including cached logins.
- Shares shows two cards with independent controls, address/copy and Infuse
  details, HTTPS or honest legacy-HTTP labeling, and global Caddy gate reasons.
  Candidate card URLs may remain while off; `row.urls` lists only active scopes.
  Shared account/path/password management remains separate. Share edits still
  restart active WebDAV and interrupt all transfers; configured HTTPS renewal
  remains available with no active folders under its existing global gate.
- **Verification (reported by the main implementation task):** 36 new tests
  passed on macOS/Debian; full Python 366 (four macOS skips, one Linux skip);
  Bats 165 (three skips); six browser fixture suites passed, including Files at
  ten widths in both themes, with screenshots reviewed. Portable deployment on
  `nrm` exited 0; schema-3 migration matched the expected normalized schema 4
  exactly, preserving credentials, identities, IDs and absolute expiry. Settings
  and qBittorrent bytes and qBittorrent PID stayed unchanged. Real HTTPS/Tailscale
  connection acceptance passed with byte-identical registry cleanup; read-only
  installed UI passed at three widths/two themes with zero errors or API writes.
  See [SESSION.md](SESSION.md) for exact evidence and final host health; native
  client acceptance is not implied.

### 2026-09-30 — Compact local-domain settings and DNS guide (v2-163)

- Limit the Caddy local-domain card to 620 px, with its input and Update button
  on one row. Keep the publication table full-width and the mobile layout fluid.
- Add four manual Tailscale Admin DNS steps below the input, linking to the DNS
  console and showing the current server IP and saved local suffix. Unsaved
  edits do not change the guide. No Tailscale account/API changes are made.
- Preserve local-domain validation/confirmation/rollback and all independent
  HTTPS settings. The operator has now enabled `qbit.example.net` successfully.
- **Verified locally:** publication-table browser/CSP tests at five widths in
  both themes, dynamic guide values, cancelled domain-change flow, existing
  Settings and HTTPS UI regressions; 330 Python cases (4 platform/optional skips),
  JavaScript/Bash syntax, ShellCheck and exact 49-file portable payload parity.
- **nrm:** portable upgrade with scratch inputs, default no full-upgrade and E,
  exit 0. Read-only live browser checks pass at three widths in both themes;
  current IP/suffix and both ready certificates appear without browser errors.
  Settings/share/qBittorrent file digests and qBittorrent PID are unchanged.
  External trusted HTTPS returns qBittorrent login 200, anonymous API 403 and
  WebDAV root 404. Health is green; eight services active, no failed units;
  Caddy, dnsmasq, firewall and systemd validation pass. No fresh OS/reboot,
  authenticated client/transfer test, commit or Desktop copy for this UI change.

### 2026-09-30 — Independent Caddy address table (v2-162)

- Settings → Caddy now lists Panel, qBittorrent and WebDAV with independent
  Tailscale/Internet choices, public domain, certificate state and per-row Save.
  Panel stays private and locked in both UI/API. Local-domain configuration
  remains separate; the effective Caddy configuration is a collapsed detail.
  Responsive rows support both themes (DD-191).
- Direct HTTPS only; no Tunnel, DNS API, arbitrary upstream or new daemon.
  Native qBittorrent login, CSRF/Host protection and login-attempt limits are
  prerequisites, not silently rewritten preferences. Public names share one
  TCP443 permission and the existing connection budgets. Legacy DAV HTTP must
  be disabled or converted before enabling public qBittorrent.
- Off retains the domain without HTTP fallback. Private off answers 403 and
  survives module reapply. Folder accounts/network permissions are unchanged;
  disabled global networks no longer produce copyable share URLs. Transaction
  snapshots restore private routes after first-save failure/crash too.
- Real API rejection exposed duplicate Python exception classes when the
  Settings CLI imported itself via helpers; fixed module identity and added a
  subprocess regression. Native proxy tests caught nondefault-port Host
  rejection: upstream Host omits the public port, while X-Forwarded-Host keeps
  the external authority for CSRF without weakening either protection.
- **Verified:** 330 Python cases on macOS/Linux (4/1 skips), 165 Bats on both
  (3/1 skips), publication-table browser/CSP tests at five widths in both themes,
  existing HTTPS/settings/files/panel/WireGuard browser regressions,
  actual nrm page with no browser errors, syntax/ShellCheck and exact 49-file
  source/bundle/installed-tree parity. Linux firewall packet tests cover
  qBittorrent-only/shared HTTPS, stopped/unsafe-auth closure, manual denies and
  cold recovery. Real native password/settings and isolated Caddy/qBittorrent
  login/cookie/CSRF/Host/Panel-isolation tests pass on ports 443 and 18443.
- **nrm:** three portable runs with scratch SSH_HOST=nrm/blank LOCAL_DOMAIN,
  default no full-upgrade, E, exit 0. Actual private off/on, module reapply and
  public DAV off/on preserve effective choices, verified TLS and folder-account
  bytes. External HTTPS/Tailscale PROPFIND, RO/RW, Unicode PUT, absolute MOVE,
  DELETE, ranges and SHA-verified download pass (31.07 MB/s on a short 32 MiB
  sample; not a speed ceiling). Temporary test accounts/files were removed.
- Final state: Panel private/locked; qBittorrent private; WebDAV Tailscale plus
  `dav.example.net` HTTPS, certificate expiry 2026-12-29. `torrent.example.net` has no
  DNS record yet, so its public DNS/ACME path was not enabled or claimed tested.
  Caddy/dnsmasq/firewall checks pass, no failed units. Final Settings API burst
  (8 parallel, 32 requests) returns 32/32 HTTP200, slowest 213 ms; health is green.
  No fresh OS, reboot,
  native Infuse or future renewal test; no commit or Desktop copy.

### 2026-09-30 — Panel-managed public WebDAV HTTPS (v2-161)

- Settings → Caddy gains a separate public-domain card with DNS guidance,
  save/disable actions, certificate status and expiry. Local names and private
  administration stay unchanged. Only the public WebDAV endpoint moves to HTTPS;
  Files → Shares shows its new copyable address (DD-190).
- DNS must resolve exactly to the assigned public IPv4, without AAAA or proxy.
  Caddy obtains/renews Let's Encrypt certificates using TLS-ALPN on TCP 443;
  no DNS token, WAN port 80, UDP 443 or new daemon. The HTTPS listener requires
  matching Host/SNI. Account scope, password throttles and connection limits stay.
- Existing revision/lock/pending recovery owns the operation. Save commits after
  verified certificate chain/hostname; failure restores the prior setting.
  Explicit removal closes WAN without HTTP downgrade; accounts and Tailscale
  URLs survive. The configured HTTPS listener stays for renewal with no active
  folders. Certificate health is a local probe, not public-reachability proof.
- **Verified:** 318 Python cases on macOS/Linux (4/1 skips); 165 Bats on macOS/Linux
  (3/1 skips), five fixture browser suites, shell syntax/ShellCheck and exact
  48-file portable parity. Linux settings/DNS/domain/native qBittorrent tests
  pass. Isolated firewall packets cover HTTPS renewal/limits, legacy closure,
  Tailscale/WG preservation and cold corruption/recovery. DNS/certificate
  failure, pending crash recovery, stale/mixed requests,
  renewal with paused folders and no-plaintext fallback have regression coverage.
- **nrm:** three portable runs, scratch inputs, no full-upgrade, confirmation E,
  exit 0. Saved `dav.example.net` through the real Settings API; trusted TLS 1.3,
  Let's Encrypt certificate expires 2026-12-29. External HTTPS PROPFIND, RO/RW,
  GET/Range, Unicode PUT, absolute MOVE, DELETE, pause and network isolation pass.
  Private paths return 404; mismatched TLS/Host returns 421. A SHA-verified
  ~32 MiB transfer measured 29.53 MB/s (short acceptance run, not a speed ceiling).
- Actual disable/re-enable closes both WAN ports without breaking Tailscale;
  rerun preserves the domain/certificate. Original share registry remains
  byte-identical after temporary test-account cleanup. Live Caddy page has no
  browser errors, health is green and Caddy/dnsmasq/firewall validation passes.
  No fresh OS, reboot, native Infuse UI or real future certificate renewal was
  exercised. The old WAN HTTP URL no longer works after HTTPS is enabled;
  clients must use the newly displayed HTTPS address. No commit or Desktop copy.

### 2026-09-30 — Remaining audit stages: boot safety, WebDAV and health (v2-160)

- Firewall retains valid owned protection on registry errors; a cold boot gets
  a narrow rescue guard while strict health/pre-start checks still fail. Both
  INPUT policies deny otherwise unhandled interfaces (DD-187).
- Installer creates/repairs user directories through no-follow descriptors,
  skipping special/multiply-linked files and private trees. Module mutations
  share the install lock without nested deadlock; CLI account lookup also uses
  the safe qBittorrent reader.
- Full Linux shell verification found Bash 5.2's `patsub_replacement` changing
  literal ampersands in templates. Rendering now temporarily disables that
  option and restores the caller's setting; Bash 3.2 remains supported.
- Separate bounded scrypt pools, short wait/cache recheck and overload 503 with
  Retry-After preserve credential throttles. PUT/COPY stage outside the global
  mutation lock and revalidate before atomic publication. WebDAV sandbox,
  process/memory/start limits and proxy/backend idle ordering are tightened
  (DD-188); TCP/request budgets and explicit HTTP WAN remain unchanged.
- IPv4-only generated DNS, accurate parser projection, desired-service health,
  Debian kernel reboot detection, controlled deep-JSON errors and actionable
  incomplete-folder versus share-overlap messages (DD-189).
- **Verified:** 281 Python tests on macOS (4 skips) and Linux (1 optional RAR
  corpus skip); 165 Bats on both (Mac 3 skips, Linux 1 negative-flock skip),
  four fixture browser suites, shell syntax/shellcheck and complete 47-file
  portable parity. Real Linux ownership/flock: 28 tests. Isolated firewall
  (including cold settings/share/WG corruption, preserved denies, retry/recovery,
  second NIC and third-party rules), settings, domain/DNS, native qBittorrent
  defaults and transient systemd recovery all pass.
- **nrm:** three portable runs, exit 0; rebooted from 6.12.107 to
  6.12.111+deb13-amd64. Core/optional services and firewall healthy, two WG peers
  retained; kernel warning before reboot becomes green after. All three service
  names return A only, not unusable AAAA. Caddy/dnsmasq/unit validation passed.
- After reboot, 320 burst API requests all 200; 80 parallel PROPFIND all 207;
  WAN 59.36 MB/s and Tailscale 55.22 MB/s on separate SHA-verified 256 MiB
  transfers. Peak DAV cgroup usage reaches its 512 MiB cap by reclaiming cache,
  not growing anonymous memory (~35 MB); OOM and oom_kill remain zero.
- Temporary RO/RW accounts prove password rotation, isolation, pause, Unicode,
  ranges and persistence across rerun/reboot; cleaned afterwards. Original share
  account metadata is identical. qBittorrent config bytes stayed identical across
  installer reruns but its digest changed across the native service reboot;
  the pre-boot contents were not saved, so byte-for-byte profile persistence is
  not claimed. Native fixture tests do prove preservation of chosen preferences.
  No Desktop copy or commit. No fresh Ubuntu installation, native Infuse UI or remote WG-client
  session was tested; HTTP WAN and account-level Tailscale policy are unchanged.

### 2026-09-30 — Audit stage 1: burst admission and filesystem guards (v2-159)

- The Konsol Unix socket, Files and both WebDAV listeners now queue up to
  128 pending connections instead of Python's default 5. This addresses the
  observed Unix-socket admission failures; WAN request, login and TCP limits
  are unchanged (DD-186).
- Both root readers of the service-owned qBittorrent configuration use the
  existing descriptor-safe, bounded regular-file reader. Symlink components,
  FIFOs and other special files are rejected without waiting for input. A
  missing profile still works; an unsafe profile prevents share changes.
- Files rejects root `.cop`, `.pay` and `.arsiv` sources before a rename,
  move or trash batch starts. Moving a nested reserved name into the root is
  also refused; restoring an old trash entry chooses a harmless alternate name.
- Regression tests cover actual socket bursts, bounded FIFO rejection,
  symlink parents, oversized files, mixed selections and ordinary file actions.
- **Verified:** portable payload matches all 46 runtime files; deployed to nrm
  using scratch inputs, default no full-upgrade and `E` (exit 0). All four
  backend listeners report backlog 128; services active and firewall check
  passes. Local Python: 206 tests (4 skips); Linux Python: 206 (1 skip).
  Mac Bats: 163 (3 skips), with physical temporary paths for the no-follow
  fixtures. Shell syntax, shellcheck and diff whitespace checks pass.
  Live: Konsol and Files each 100/100 HTTP 200 at 20 parallel fresh client
  connections; direct Unix socket 120/120 at 24 parallel. Separate 256 MiB
  downloads: WAN 59.72 MB/s, Tailscale 57.53 MB/s, both SHA256 verified;
  each network passed 40 PROPFINDs at four parallel and byte ranges.
  Service memory grew from 15.3 MB to 559.2 MB, including 523.0 MB file cache
  and 34.4 MB anonymous memory. This demonstrates the speed-test/cache
  mechanism, not the cause of the historical 670 MB peak. Test account/files
  removed, existing share registry byte-for-byte unchanged. No reboot or
  fresh-OS/native Infuse test in this stage.

### 2026-09-30 — Tailscale/Caddy auto-updates and maintenance cleanup (v2-158)

- Unattended upgrades now also install Tailscale and Caddy updates from their
  own repositories, besides Debian/Ubuntu security updates. The daily run is
  moved to 04:00 (up to 30 min random delay) so a Tailscale or Caddy restart
  happens at night; stage 7 warns if either repository is missing from the
  policy (DD-184). Reboots stay manual.
- Removed code that only served hosts installed with earlier versions (fresh
  install only, DD-185): the WireGuard registry upgrade helper, the old
  `GET /api/wg/sistem` view, schema-2 share registry conversion, the retired
  health-site and old-share-link answers (now 404), Konsol's rewrites of retired
  bookmarks, the `ui`/`ping` WireGuard rule kinds in the settings view, log
  labels no backend writes and 93 lines of unused CSS. A host installed with an
  older version needs a fresh install.
- Documentation trimmed to current behaviour: retired decisions, CHANGELOG
  entries before v2-145 and older session notes moved verbatim to
  `docs/archive/`; new `docs/decisions-index.md` lists every DD with its status.
- **Verified on nrm:** deployed with the portable launcher and scratch inputs
  (exit 0). `apt-config` lists both new patterns; `unattended-upgrade --dry-run`
  names them as allowed origins and the installed tailscale and caddy packages
  match them; the timer's next run is 04:00. Over the tailnet
  `/api/wg/sistem` and `/api/paylas*` answer 404, resources and health 200.
  Linux unit tests (197), firewall/settings/domain/torrent namespace suites,
  settings-systemd, shares/archives/RAR live and the external WAN share test
  pass. Locally: 163 Bats, 197 Python, the four browser suites, shellcheck.

### 2026-09-30 — Archive jobs page removed (v2-157)

- Files no longer has an "Arşiv işleri" tab. A running job shows as one bar above
  the list with its progress and "İptal et"; starting a job stays in Files (DD-183).
- Ayarlar → Günlük now shows archive jobs readably: start ("sources → result"),
  cancel request and the result with the server's message, including jobs found
  interrupted after a restart. Before, only an opaque job id was logged.
- **Verified:** deployed to nrm; archives-live (ZIP, nested, conflict, invalid
  path, cancel) wrote readable arsiv-olustur/ac/iptal/sonuc lines and Konsol's
  Günlük API returned them. Local mock with recorded nrm replies: no jobs tab,
  bar with İptal et while running, gone after completion, old bookmark opens
  Files, no console errors. 163 Bats, 203 Python. With Node/Playwright now on the
  Mac, all four fixture browser suites pass, updated for the archive bar
  (panel-ui) and the health card plus typed discard (settings-ui).

### 2026-09-30 — Stuck rollback, WAN address change, watchdog, health card (v2-156)

- A settings rollback that keeps failing is retried after 15/30/60/120 s and
  then waits as "takıldı": Konsol shows the error with "Yeniden dene" and
  "Bırak" (typed onayla) instead of retrying every 2 s forever (DD-182).
- A WAN share whose address the provider changed is closed with a reason; a
  Caddy that could not start on the old address is started without it, and the
  installer no longer dies in stage 6 on that address.
- The Tailscale watchdog resets Caddy's start limit before restarting it and
  checks the firewall again once Tailscale answers.
- A damaged archive history is set aside instead of keeping Files from starting.
- New read-only Sağlık card on Settings → Sistem: failed services, Tailscale and
  key expiry, firewall, reboot needed, clock sync, disk/inodes, pending settings.
- A new archive job waits for the previous one to finish removing its staging
  area instead of answering "işlem sürüyor" right after it showed "done".
- **Verified on nrm:** installer removed a WAN site bound to a stale address in
  stage 6 and republished it; a runtime address change closed the site with a
  reason and a Caddy stuck on the old address came back; five failing rollbacks
  became "takıldı" (health red, timer idle), then retry and discard (wrong word
  refused) both worked; damaged history set aside with no restart; reboot into
  kernel 6.12.111: all units active, wg0 after the firewall, sockets 0660/0700,
  no TCP 61008/2019, health green after NTP sync. Caddy's start limit could not
  be reached on Debian 13 (automatic restarts continued), so the reset-failed
  change is precautionary. Local 163 Bats, 201 Python; Linux unit, namespace,
  systemd, share/archive/RAR and external WAN suites pass.

### 2026-09-30 — Faster WebDAV logins, quieter journal, compressed Konsol (v2-155)

- WebDAV remembers a successful login for 10 minutes, so Infuse/Finder requests
  no longer pay one scrypt check each; every limit and check still applies
  (DD-181). Tailnet WebDAV slots 16 → 64; closing replies say so.
- WebDAV and Files replies through Caddy no longer wait ~40 ms each for a
  delayed ACK (Nagle was on for the kept-alive loopback connection).
- The settings rollback timer runs only while a change is pending (it used to
  start every 2 s). Both short timers keep systemd's per-run lines out of the
  journal. The root backend logs audit lines only, no request lines.
- Konsol pages and API replies are compressed; page files revalidate (304)
  instead of downloading again. Concurrent settings refreshes share one run.
- qBittorrent gets lower CPU priority than Tailscale and Konsol; archive jobs
  run niced and store already-compressed media without re-deflating it.
- **Verified on nrm (with v2-154):** WebDAV PROPFIND through Caddy 44 → 1 ms;
  konsol.js 119 → 37 KB (zstd) and 304 on revalidation; guard/share timers wrote
  0 journal lines in 3 min (was ~200); real apply started and then stopped the
  timer; an unconfirmed firewall rule was rolled back after 66 s and the timer
  stopped; qBittorrent nice 10 / CPUWeight 50.

### 2026-09-30 — Private sockets and login, disk and WireGuard safeguards (v2-154)

- The root Konsol backend has no TCP port: a Unix socket for root and Caddy's
  group (`SO_PEERCRED` checked); Caddy's admin API moves from `127.0.0.1:2019`
  to a socket in a `0700` folder. What Caddy relays to the root backend must
  come from another tailnet device, not from the server itself. Downloads-account
  programs (qBittorrent, unrar) can no longer reach either, directly or through
  Caddy. Stage 7 proves it and reloads Caddy (DD-180).
- WebDAV: the 5-failure/60 s IP block also covers Tailscale; 100 failures in
  an hour close a share for an hour to addresses not yet logged in; wrong user,
  paused or unknown shares cost the same hash as a real check.
- WebDAV PUT/COPY and Files uploads stop with 507 before free space falls under
  min(5 GiB, 10%) and remove their temporary file.
- Files backend (unrar) sandbox: loopback-only network, system-call filter,
  hidden processes, private IPC, no writable-executable memory.
- WireGuard networks start only after `master-firewall --check` passes; the
  refresh timer reopens a network that failed for that reason.
- Root backend closes the connection after an error or an unread request body,
  so a body hidden in a cross-site POST can no longer run as a second request.
- **Verified on nrm (installed as v2-154, then v2-155):** no TCP 61008/2019;
  socket modes; downloads uid refused on both sockets and through Caddy (403);
  a supplementary-caddy-group user refused by SO_PEERCRED; Caddy reload works;
  tailnet WebDAV 5th bad login → 429 while local probes stay 401; nested
  RAR/ZIP/RAR extracted by real unrar in the sandbox (exposure 3.0 → 1.4); a
  broken firewall kept wg0 down until the timer repaired both. Local: 162 Bats
  (3 macOS skips), 191 Python (4 skips); Linux: 191 Python (1 skip), four
  namespace suites, real-systemd timer test, share/archive/WAN acceptance pass.

### 2026-09-29 — Per-folder Tailscale / HTTP WAN sharing (v2-153)

- Select Tailscale, WAN IPv4 or both per folder; one account/ID/permission/expiry.
  Existing schema-2 and new shares default to Tailscale; adding WAN requires
  explicit acknowledgement that HTTP exposes credentials/content (DD-179).
- Separate trusted listener scopes and connection pools; Caddy replaces the
  client-IP header. WAN: 5 bad logins/60s → 300s IP block with Retry-After,
  4096-entry bounded history, 4 parallel hashes, 8 backend connections total,
  4 requests/IP. Tailnet retains 16 connections. Edge TCP: 16/IP, 64 total;
  WAN header/idle timeouts are 10s/30s. No bandwidth limiter or new package.
- Open only the existing WebDAV port and `/s/*`; no admin interfaces, public
  IPv6, wildcard bind, NAT/ACL change or automatic exposure of existing shares.
  Manual firewall denies remain effective. Last active WAN share removal/pause
  closes the listener/owned rules; a scoped timer projects expiry and recovers
  interrupted registry operations. Caddy startup checks the firewall first.
- Show labeled copyable URLs/network badges, HTTP consent and limits. Keep
  inline RO/RW and duration controls. Caddy/firewall inventory identifies WAN
  correctly and parses proxy blocks as well as single-line upstreams.
- Add manager migration/publication/recovery tests, real-HTTP budget/scope
  regressions, UI network tests and a disposable external-client acceptance
  script. HTTP remains unsuitable for confidential internet traffic.
- **Verified on nrm:** portable upgrade, Caddy/systemd/DNS/firewall checks,
  external WAN/Tailscale isolation, TCP/request/login caps, pause/expiry cleanup
  and 66 installed Linux share tests. Local 159 Bats and 170 Python cases have
  three platform skips each. No fresh-OS/reboot/native-client certification.

### 2026-09-29 — Integration-only qBittorrent defaults (v2-152)

- Stop forcing UPnP/automatic port mapping, local peer discovery and separate
  temporary storage in new qBittorrent profiles (DD-178). Leave these and other
  user preferences at the installed application's defaults until changed.
- Keep the download path, authenticated loopback WebUI and headless startup
  notice, plus existing nonroot service/sandbox and DNS/Caddy integration.
  Existing profiles and host firewall permissions are unchanged.
- Add exact seed-key and reapply/reinstall preservation checks, plus a native
  isolated Linux comparison and user-choice restart test.
- **Verified:** 155 Bats cases (three platform skips), 126 Python cases (two
  optional native-RAR skips), Bash syntax/ShellCheck and 44-file portable payload
  equality. Native Debian qBittorrent 5.1.0-2 passed the isolated default/login/
  preference-persistence test twice. No installed profile/service was changed;
  full host upgrade, fresh OS installation and reboot were not run this turn.

### 2026-09-28 — WireGuard internet-only (v2-151)

- Retire Local access entirely (DD-177): no creation/settings selector, API
  scope or CLI argument. Network settings now change default DNS only.
- Drop WG host ingress before established/ICMP/Tailscale acceptance; block
  private/CGNAT/link-local destinations even via WAN. Keep internet NAT/return
  traffic and required user-created UDP endpoints.
- Upgrade existing registry policies without modifying keys, profiles, DNS,
  ports or addresses. Remove WG host-rule overrides and only the retired WG
  Caddy instances/template/env files; clean/repeat installs never recreate them.
- Firewall host overrides remain available for WAN/Tailscale only.
- **Verified:** 155 Bats cases (three platform skips), 126 Python cases (two
  native-RAR skips), WireGuard/Settings/Panel/Files browser suites and syntax/
  ShellCheck. Isolated Linux tests cover IPv4/IPv6 NAT, host/old-flow denial,
  private WAN destinations, retained networks and third-party chain preservation.
  nrm upgrade passed stages 0–7; real kernel WG clients on existing wg0 and an
  own new test network reached IPv4/IPv6 internet and public DNS, not host services.
  Test peers/network were removed; original keys/settings/accounts and qB process
  stayed unchanged. Transport was host-loopback to WG, not an external WAN device.
  Fresh OS installation and reboot acceptance are separate, not claimed here.

### 2026-09-28 — Default WireGuard Local access (v2-150)

- New Konsol networks default to Internet + local at the backend. Remove the
  creation access card/toggle and its unused code/styles; update preview/help.
- All peers inherit access to the installed qBittorrent UI on their own network;
  all other isolation remains. Existing network settings can still disable Local,
  and re-runs preserve that saved choice. Explicit CLI/API scopes remain supported
  (DD-176). No key/profile regeneration, new dependency or firewall widening.
- **Verified:** 157 Bats cases (three macOS skips), 121 Python cases (two
  native-RAR skips), WireGuard/Panel/Settings browser suites, syntax/ShellCheck.
  nrm portable upgrade passed stages 0–7. A scope-less test network created with
  `ui`, active WG/Caddy, the narrow firewall permit and qB UI HTTP 200; removed
  only that empty fixture. Eight services healthy, live desktop/mobile passed;
  original registry/configuration hashes, qB process and full normalized firewall
  match before/after. Existing wg0 was already Local-enabled. No fresh OS/reboot
  or external WG-client acceptance claimed.

### 2026-09-28 — Firewall source and rule cleanup (v2-149)

- Missing WireGuard module registration no longer revives retained networks.
  Omit/remove unused project forwarding/NAT chains when no networks are configured.
- Remove redundant terminal returns and single-element multiport generation.
  Preserve required VPN endpoints, actual permissions, user overrides and all
  third-party rules; no legacy service installer is restored (DD-175).
- Strengthen INPUT/NAT drift checks and add clean/repeat/removal regression
  fixtures, while keeping the panel accurate for intentionally absent chains.
- **Verified:** 157 Bats cases (three platform skips), 119 Python cases (two
  native-RAR skips), Settings browser suite, isolated Linux IPv4/IPv6 input and
  routed WG NAT/isolation tests. Portable upgrade and repeat install on nrm
  passed stages 0–7. Project rules decreased 81 → 73; all other firewall content,
  user settings, WG profiles and qB process remained unchanged. Eight services
  healthy; live API/desktop/mobile tests passed. No fresh OS/reboot claim.

### 2026-09-28 — Simplify Internet and WireGuard port lists (v2-148)

- Remove synthetic closed WAN rows for local/tailnet services, arbitrary sockets
  and unsupported IPv6 WG endpoints at the backend source (DD-174).
- List tunnel-local qBittorrent permissions only for IPv4 networks with Local
  access configured. Keep required VPN UDP endpoints regardless of peer/socket
  activity, explicit user allows/denies, network selectors and raw diagnostics.
  Actual firewall policy, services and saved settings are unchanged.
- **Verified:** 157 Bats cases (three platform skips), 117 Python cases (two
  native-RAR skips), Settings browser tests, syntax/ShellCheck and portable nrm
  upgrade. Live API/browser checks confirm WAN 4/2 rows (IPv4/IPv6), one wg0
  IPv4 UI row and no synthetic wg1/IPv6 UI rows; explicit-rule fixtures remain
  editable. Normalized full firewall rules, configuration hashes and qB process
  match before/after; eight services healthy. No fresh-install/reboot claim.

### 2026-09-28 — Remove synthetic Tailscale port entries (v2-147)

- Generate Tailscale port rows from the configured per-family allowlist and WG
  registry, not arbitrary host listeners (DD-173). Remove irrelevant peer/local
  backend/Caddy admin rows at their source; preserve explicit user rules and
  unfiltered technical diagnostics. No hardcoded port exclusions.
- Preserve default-deny protection, required local services, every configured
  WG endpoint, socket bindings, torrent settings and all forwarding/NAT policy.
- **Verified:** 157 Bats cases (three platform skips), 114 Python cases (two
  native-RAR skips), Settings browser suite, portable nrm upgrade and live
  IPv4/IPv6 API/socket checks. Desktop/mobile show only configured tailnet rows;
  raw diagnostics remain intact. Eight services active, no failed units; account,
  share, module/WG registry/profile hashes and qBittorrent process unchanged.
  No fresh install, Ubuntu, reboot or authenticated Infuse claim for this change.

### 2026-09-28 — Minimum tailnet host exposure (v2-146)

- Replace implicit all-port tailnet access with an explicit host allowlist before
  Tailscale's own INPUT acceptance (DD-172). Keep SSH, Caddy, DNS, folder WebDAV,
  self-advertised PeerAPI and every registered WireGuard endpoint. Block other
  new inbound ports by default, including qBittorrent peers and direct backends.
- Preserve operator overrides, loopback, established replies, ICMP, all WAN/WG
  and forwarding/NAT policies. No network deletion, credential change or package
  removal. Peer counts and counters never determine whether a WG port is needed.
- Make the port table use the same allowlist instead of treating any listener
  as tailnet-accessible. Add real IPv4/IPv6 packet, override and drift tests;
  helper changes now trigger both firewall refresh and panel restart.
- **Verified:** 157 Bats cases (three platform skips), 113 Python cases (two
  local RAR skips, native Debian coverage), Settings browser suite and isolated
  Linux packet/settings tests. Portable nrm upgrade and live dual-stack checks
  preserve service/config/WG state; qBittorrent's PID is unchanged. No clean
  Ubuntu/reboot, VPN client throughput or authenticated Infuse acceptance claim.

### 2026-09-28 — Runtime and installer cleanup (v2-145)

- Align active documentation, input-template and launcher messages with built-in
  Files/WebDAV/archive tools, App Store, current settings and no automatic backup.
  Remove unused frontend helpers, old shared-account UI and obsolete CSS.
- Remove unreachable built-in module install/remove/data-delete branches and
  shared-password plumbing. Stop creating `.pay/w` and its marker, exporting old
  credential paths or repairing legacy metadata permissions (DD-171).
- Preserve current folder accounts and all existing data; retain reserved-path
  guards and tolerate absent legacy paths in the WebDAV sandbox. Retired Files
  share routes now consistently answer 410; drop their obsolete state summary.
- Keep all used dependencies and runtime files; no package purge, automatic
  migration, data deletion or extra background service. Add regression checks
  for fresh/legacy trees, retired API gates and first-login secret handling.
- **Verified:** 157 local Bats cases (three platform skips), 108 local Python
  cases (two native RAR skips), four browser suites; all 108 Python cases pass
  on native Debian including real RAR. Reproducible 45-file portable payload,
  nrm upgrade, live UI/API, systemd absent/present-path sandbox and built-in
  idempotency checks pass. Accounts, settings, WG configs and qBittorrent process
  are unchanged. No fresh Ubuntu/full fresh-install/reboot acceptance claim.

Older entries (v2-144 and earlier) are archived verbatim in [`docs/archive/CHANGELOG-before-v2-145.md`](docs/archive/CHANGELOG-before-v2-145.md).
