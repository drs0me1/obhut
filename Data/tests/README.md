# Tests

Narrow critical-behaviour suite for the lean installer tree. Not a framework
coverage suite.

```bash
cd Data   # from the repository root; paths below are relative to Data/
bats tests
bash -n install.sh common.sh scripts/*
shellcheck -x -s bash install.sh common.sh scripts/*
```

`bats tests` runs every Bats file (`common.bats` and `share-networks.bats`);
`bats tests/common.bats`, used in some sections below, runs only the first.

The Bats fixture resolves its temporary directory with `pwd -P`: macOS `/var`
is a symlink and production no-follow readers correctly reject it. No shell
wrapper or relaxed production traversal is needed.
Mode/inode checks capture only successful GNU/BSD stat output; hashes use the
fixture's Python helper. Linux Bats needs the source guards' docs, exporter,
root `.gitignore`, root launcher and `Data/app` copy too, not only the runtime
tarball. Copy only these allowlisted test inputs; never include private
`kurulum/` or WG profiles.
For a root-created test checkout under `mktemp -d`, set that checkout directory
to mode `0755` (`chmod 0755 /absolute/path/to/test-checkout`): non-root fixture
processes must traverse it. Do not relax private input/credential permissions.
Template tests exercise literal ampersands/backslashes and preservation of
Bash 5.2's `patsub_replacement` setting (Bash 3.2 has no such option).

Host acceptance (Debian 13 or supported Ubuntu target, after install) is
separate: DNS loopback vs Tailscale answers, WebDAV PROPFIND/read-only,
firewall `--check`, and the public ports: WAN SSH TCP, Tailscale UDP, each
registered WireGuard UDP port (if installed), plus the mode-selected WAN IPv4
WebDAV port: legacy HTTP `SHARE_PORT` only while a WAN share is active, or
configured HTTPS `SHARE_HTTPS_PORT` retained for renewal with no active folders.
Explicit HTTPS disable closes both WAN ports; Tailscale HTTP is unchanged.
With DD-191, an independently enabled qBittorrent publication keeps the shared
HTTPS port open; disable both rows to close it. A Tailscale row switch gates
that named route, not the shared Caddy listener.

Portable validation should compare the complete embedded file set with runtime
sources, excluding Python caches, metadata, tests, docs and private input.

## Public Konsol over HTTPS (v2-167, DD-195)

`test_publications.py` covers the Panel row: the tailnet switch cannot close, an
account and the server-checked word `onayla` are required when turning on or
renaming, DNS/duplicate/legacy-HTTP checks, the generated
`panel-wan.caddy` (WAN bind, TLS-ALPN, HSTS, only `import konsol internet`), its
certificate status, the shared TCP 443 firewall output with WebDAV's WAN off,
removal at the next publish after an account reset and rollback after a
certificate failure. `test_konsol_auth.py` covers the shared public failure
budget, one password check per address and two at once, and the root backend's
channel rules on a Unix socket: closed publication, refused setup code, `Secure`
cookie, own-address and unmarked clients refused, `kanal` in the session state and
the 5-second publication cache, and the budget re-check after a hash slot.
`test_settings.py` checks that a local-domain change rewrites the snippet's
backend Host and that a confirmation through the public channel is refused.
`common.bats` checks the snippet, the Caddy-written channel header, the backend
connection cap, the forwarded host and channel on confirmations, and the
installer cleanup; `publications-ui.cjs`
drives the editable Panel row and the typed `onayla` dialog; `giris-ui.cjs` the
Tailscale/internet label.

v2-168: `test_resources.py` checks the module listing's `urls` for qBittorrent
(tailnet name always; the public name only while that publication is active or
`null`); `panel-ui.cjs` opens Konsol on an `https://` origin with intercepted
requests and checks that the qBittorrent page links the public name, falls back
to a Settings → Caddy hint without one, and keeps the tailnet link on `http://`.

v2-173 (DD-199, store phase 1b): `test_publications.py` renders the qBittorrent
manifest and copies `yayin.py` into the fixture `MODULES_DIR`, so rows, sites and
checks come from the package; it also covers a failing, unparsable and missing
check module (row closed, app never exposed) and a manifest without a loopback
upstream (no row). `publications-proxy-linux.py` does the same against real
Caddy and qBittorrent, and `firewall-linux.py` copies the manifest and module so
the shared TCP 443 permission still follows an active qBittorrent row.

v2-172 (DD-198, store phase 1b): the firewall Bats test and `firewall-linux.py`
copy the WireGuard package's hook into the fake `MODULES_DIR` and drive the
firewall through its `vpn` declarations (malformed or clashing declarations stop
before any chain changes); `test_stage4_health.py` derives the fake
`master-modul saglik` output from the fixture registry; `test_resources.py` and
`test_firewall_view.py` build port rows from copied manifests, including a
malformed manifest whose rows are skipped.

v2-171 (DD-197, store phase 1a): the Bats fixtures copy each package's
`paket.env` and `kanca` from `magaza/` into the fake `MODULES_DIR`, so the
module tests run the real engine against the real hooks; the engine itself is
checked to contain no application id. Installer tests check the generic
renderer (`render_package_dir`), the manifest-driven reapply flag and the
summary built from manifests and `paket_ozet`.

v2-170 (DD-196, store phase 0): the Bats test "store phase 0" checks the repo
layout (`magaza/`, the WireGuard tool and drop-in inside the package), that the
base installer neither installs nor keeps them, that `master-modul` places and
removes them, the package-neutral stage-7 probe, the Caddy unit without
`--environ`, the backend's unit name and Konsol's log labels by source.

v2-169: `test_publications.py` adds the fresh-install case: with WebDAV in
legacy HTTP mode, Panel/qBittorrent HTTPS is refused only while a folder is
actually shared over plaintext HTTP, publishes once that connection is closed,
keeps legacy HTTP unavailable (cards and the WebDAV row say why) while the
HTTPS row is on, and reopens it when the row is turned off; the firewall port
follows. `settings-https-ui.cjs` checks both notes (`wan_active` on/off).

```bash
python3 Data/tests/panel-public-live.py --host nrm --domain konsol.example.com
```

`panel-public-live.py` is opt-in and **mutating**: it needs the operator's existing
Konsol account and a name with a DNS-only A record to the host's WAN IPv4 (no
AAAA). It publishes Panel on that name through the real Settings API, checks HSTS,
the sign-in page, session protection of pages/Files/root APIs, the refused setup
code, one wrong sign-in and a root-issued automation session over the public
address, then restores the Panel row exactly and checks that the name no longer
reaches Konsol. It exits 3 without changes when there is no account or Panel is
already public.

## Konsol sign-in (v2-166, DD-194)

`test_konsol_auth.py` covers the account store (one-time code format/expiry/single
use, user and password rules, scrypt-only storage, decoy work for unknown users,
session expiry/limit/malformed tokens, password change keeping only the current
session, reset, automation sessions, unsafe directory/symlink/FIFO/oversized/corrupt
records), the per-address attempt limit, the root CLI and the real root-backend
endpoints on a Unix socket: `/oturum-denetle` answers (302 page, 401 API, 204 with a
session, 403 for host-local or foreign Host), cookie attributes, 429 with
Retry-After, sign-out and password change, and audit lines without secrets.
`common.bats` checks the Caddy `forward_auth` matcher and order, the open sign-in
files, installer wiring/stage-7 probes and that the code is printed, never logged.

`giris-ui.cjs` (shared preview on port 8766) drives `giris.html` with intercepted
APIs and the production CSP: first account with and without a valid code, client
checks, wrong code, sign-in failure/limit/success, return to the original page, the
signed-in shortcut and Konsol's redirect after a 401. `settings-ui.cjs` covers the
account card, the password dialog and sidebar sign-out.

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/giris-ui.cjs
python3 Data/tests/konsol-login-live.py --host nrm
```

`konsol-login-live.py` is an opt-in **mutating** test for an authorized host that
has **no** Konsol account yet (it exits 3 otherwise and changes nothing). It issues
its own code over SSH, creates a temporary account through the real Caddy path,
checks page/file/API protection, sign-in/out, password change and the attempt
limit, then resets the account and restarts the root backend to clear the limit.
The operator then gets a new code with `sudo master-konsol sifirla`. Codes,
passwords and tokens are never printed.

Live tests that call Konsol through Caddy from the Mac (`share-connections-live`,
`https-live`, `publications-live`, `backend-hardening-live`) open a short
root-issued session with `master-konsol oturum-ac` via `konsol_session.py` and close
it at the end. Host-side tests (`shares-live.py`, `archives-live.py`) use the
loopback Files backend and the root socket instead, because Caddy refuses
host-local Konsol callers (DD-180). The browser live suites
(`share-connections-browser.cjs`, `desktop-live.cjs`) take a session value in
`KONSOL_COOKIE`.

## Per-connection WebDAV policies and dual-card Shares (v2-164, DD-192)

From the repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_share_connections.py'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_webdav_connections.py'
```

These fixtures cover exact schema-3 migration and idempotent schema-4 preparation,
malformed/conflicting policies, independent defaults, nested partial saves under
locks, preserved omitted expiry, both-off, per-scope RW acknowledgement, legacy
HTTP consent, global publication gates and candidate-versus-active URLs. Protocol
checks cover both RO/RW directions, listener/header isolation, cached authentication,
all DAV writes, disabled/expired scopes, live chunks and staged-publication checks.
`files-ui.cjs` checks the two-card controls and scoped payloads with intercepted
APIs; its responsive matrix covers ten widths from 320 to 2560 in both themes.

Optional read-only acceptance against the installed console (Playwright required):

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/share-connections-browser.cjs
# Override the default http://panel.ayc when needed:
KONSOL_URL=http://panel.example PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/share-connections-browser.cjs
```

This requires at least one existing share and creates none. Every API mutation
(any method other than GET/HEAD) is aborted and fails the check. It checks two
cards, four selects and two switches per share, address/Infuse host-port-path
consistency and copy-button presence, no overflow at 1440/900/390 in both themes,
and no browser errors. It does not exercise actual clipboard writes. Screenshots
go to an OS temporary directory, not the Desktop.

Opt-in **mutating** acceptance from an authorized Tailscale client against a
disposable host with schema 4, working public HTTPS and both global routes enabled:

```bash
python3 Data/tests/share-connections-live.py --host nrm
```

It creates one temporary folder/account and checks independent RO/RW in both
directions, listing/ranges, scope-header spoof rejection, both switches/both-off,
preserved peer expiry and stale global-policy/pause API rejection. WAN-only expiry
is accelerated only for its fixture using an atomic registry write under
`install.lock` → `modul.lock` → `paylasim.lock`, then restart/publication. Cleanup
removes only its own account/files and verifies the original registry is
byte-identical by SHA-256. Credentials remain in memory/SSH stdin and are not
printed; Caddy settings are not changed. **Share edits restart active WebDAV and
interrupt all transfers/playback.** Run outside active playback and do not edit
real shares concurrently.

The main implementation task reports: 36 new tests passed on macOS and Debian;
full Python suite 366 tests (macOS four skips, Linux one); Bats 165 tests (three
skips); six browser fixture suites passed with screenshots reviewed. After a
successful portable deployment on `nrm`, both opt-in scripts above passed: live
HTTPS/Tailscale policies and byte-identical cleanup, and installed UI at three
widths/two themes with zero errors or API writes. See [SESSION.md](../SESSION.md)
for exact run evidence and final host health. These results do not certify native
Infuse/Finder clients or a fresh supported-OS installation.

## Caddy publication table (v2-162, DD-191)

`test_publications.py` covers immutable Panel, exact catalogue/payloads,
independent DAV network gates, remembered off domains, native qBittorrent auth
requirements, duplicate/DNS rejection, first-row certificate failure, crash
rollback and module projection persistence. It reuses isolated transaction
fixtures and does not claim real ACME issuance.

`PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/publications-ui.cjs`
starts its own local static server and runs the actual console with intercepted
APIs/CSP. It checks draft-only switches, single-click saves after typing, locked
Panel, validation, pending/failure/retry, reload and five widths in both themes.
Screenshots go to an OS temporary directory, not the Desktop.

`python3 Data/tests/publications-live.py --host nrm` is an opt-in **mutating**
test for a provisioned disposable host with verified DAV HTTPS and qBittorrent
installed (private or already public). It reads the public names from the host
and probes a missing name under the reserved `example.net`. It rejects Panel
WAN/duplicate/missing DNS through the real API, toggles each private route across
module reapply (every template address must answer 403, DD-193), and
disables/restores DAV HTTPS; a public qBittorrent must keep serving meanwhile.
It restores effective network choices and checks the folder-account digest. It
may interrupt transfers, never enables a new public hostname and never changes
application credentials.

On a Linux host with Caddy, qBittorrent, OpenSSL, iproute2 and setpriv:

```bash
unshare --net --fork python3 Data/tests/publications-proxy-linux.py --port 443
unshare --net --fork python3 Data/tests/publications-proxy-linux.py --port 18443
# exits 3 without changes when the host has no qbittorrent-nox package
```

This refuses the host network namespace and uses a temporary profile and local
test certificate (no ACME or trust-store change). The generated Caddy route is
real: native login/cookies, API access, incorrect password, CSRF, overwritten
forwarded Host, strict SNI/Host and Panel isolation are tested on both ports.
Host omits the public port for native listener validation; X-Forwarded-Host
keeps the external authority for CSRF. This does not certify public DNS/ACME.
`firewall-linux.py` additionally tests qBittorrent-only and shared DAV HTTPS
permissions, one shared port rule, and stopped/unsafe-native-auth closure.

## Public WebDAV HTTPS (v2-161, DD-190)

From the repository root, run the local tests without a live domain:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_https_*.py'
```

`test_https_settings.py` covers full-domain/DNS validation (exact assigned WAN
IPv4, no AAAA/proxy), pinned chain/hostname verification, durable commit,
failure/crash rollback, explicit off without HTTP downgrade, retained renewal
listener after last-share pause, preserved accounts/local domain and legacy
HTTP consent. `test_https_panel.py` covers status/expiry warnings at 14 days or
less, unknown/error handling, selected firewall ports, Caddy scheme/source
parsing and the existing gated Settings API. These are fixtures, not real
Let's Encrypt issuance or public-reachability tests.

With the local console preview below running on port 8766 and Playwright installed:

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/settings-https-ui.cjs
```

This runs the production Settings/Shares UI with intercepted APIs and the actual
Caddy CSP. Since DD-193 public WebDAV HTTPS is edited only in the “Adresler ve
erişim” table, so the suite drives that row: isolated publication/local-domain
drafts, validation, long pending saves, repeated-click blocking,
ready/pending/error/expiry displays, failure/retry, draft switch/discard,
persisted off with the remembered name, the legacy-HTTP port note,
scheme-specific share links (a closed WAN card is labelled “WAN”) and HTTP
consent. It checks four widths in both themes. It does not modify a server.

External acceptance is opt-in, from an authorized Tailscale client to a disposable
host. Supply a real public domain whose DNS resolves only to that host's assigned
WAN IPv4, with no AAAA/proxy, and permit inbound TCP 443. Settings' pinned local
certificate probe does not itself prove that external path. From the repository root:

```bash
# Requires the matching domain already saved and certificate status ready:
python3 Data/tests/https-live.py --host nrm --domain dav.example.com
# Alternatively, deliberately save the real domain through Settings first:
python3 Data/tests/https-live.py --host nrm --domain dav.example.com --configure
```

Replace the example domain; the script uses public TCP 443. `--configure` is a
real, persistent Settings change: **the domain remains saved after cleanup**.
Without that flag, the script requires the matching saved domain to be ready.
It verifies public TLS trust, denies `/` and administrative routes, checks old
WAN HTTP closed, and creates three temporary shares: RO and RW on both networks,
plus Tailscale-only. It exercises HTTPS/Tailscale reads, PROPFIND, ranges, download
integrity, RO rejection, WAN scope, PUT/MOVE/DELETE and both connections off.
Cleanup removes only its accounts/files and checks the original registry digest;
credentials stay in memory/SSH stdin and are not printed. Account creation,
connection changes and removal restart
WebDAV and interrupts current transfers: run outside active playback and do not
edit real shares concurrently. Domain disable/re-enable, reboot, supported-OS
fresh installs and native-client acceptance are separate tests.

This runbook describes test scope, not completed results. Record actual runs in
`CHANGELOG.md`/`SESSION.md`.

## Remaining audit stages (v2-160, DD-187–189)

`test_install_hardening.py` checks descriptor-based selective permission repair,
unsafe parents, replacement races, hard links, special files and excluded trees.
`install-hardening-linux.py` adds real root ownership and competing/inherited
flock tests; run as root in a temporary test tree, never by sourcing install.sh.
`firewall-linux.py` adds cold malformed-registry rescue, valid-policy/manual-deny
preservation, secondary-interface default drop and successful recovery in isolated
network namespaces. It does not alter the host's policy.

`test_stage3_webdav.py` covers separate auth pools, short waits/cache rechecks,
single-flight sharing of identical concurrent logins and its failed/slow-leader
fallbacks (DD-193), 503 versus credential 429, bounded overload replies, slow PUT/COPY independence,
late target/source/parent/share/expiry/precondition conflicts and stage cleanup.
`test_stage3_files.py` covers deep JSON and socket inactivity; share-path tests
distinguish incomplete/internal roots from existing-share overlap.
`test_stage4_dns_json.py` covers `/4` projection and explicit IPv6 records plus
controlled deep HTTP/worker JSON. `test_stage4_health.py` tests required/inactive
and deliberately stopped units, unknown probes and kernel boot-link evidence.

Live acceptance must additionally validate Caddy/dnsmasq/systemd, cgroup OOM
events under WAN/Tailscale transfers, real A/AAAA replies and health before/after
reboot. Synthetic clients do not certify native Infuse or a fresh Ubuntu image.

## Backend admission and filesystem guards (v2-159, DD-186)

`test_backend_hardening.py` opens 24 real sockets per server before starting
the accept loop, isolating the listen backlog from HTTP processing limits.
Temporary fixtures exercise both qBittorrent readers against FIFOs (with a
subprocess deadline), final/parent symlinks, directories and oversized files.
Files tests cover reserved sources, all-selection validation before mutation,
reserved destination promotion, safe restore and ordinary file operations.
Run this suite on Linux too; no host configuration or credentials are used.
The backlog test is not a throughput benchmark or a substitute for cold-cache
Infuse concurrency tests. Existing WAN budgets are intentionally unchanged.

`backend-hardening-live.py --host nrm` runs 100 requests per API with 20
parallel fresh client connections and 120 direct cold Unix-socket requests.
It then creates a disposable RO WAN+Tailscale share, reads two 256 MiB files
with SHA256 verification, samples cgroup `anon`/`file`/`current`/`peak`, and
checks parallel PROPFIND and ranges on each network. Only the test files'
clean cache pages are evicted before reading, not the host cache. Cleanup
removes the temporary account/files and compares the original registry digest.
This restarts WebDAV twice; use an authorized test host outside active playback.
The measured cache increase does not prove the cause of a historical peak.
The WAN half follows the host's mode (DD-193): HTTPS on the configured public
name, or legacy HTTP on `SHARE_PORT`; a host with WAN off is refused up front.

## Folder network selection and WAN admission (v2-153, DD-179)

`test_share_manager_networks.py` covers opt-in, immutable
credentials/identity/expiry on network edits, public projection, rollback and
interrupted-change recovery. `test_webdav_networks.py` checks scope before
hash/filesystem work, header spoofing, sliding failure windows, bounded tables,
parallel hashes/requests, distinct loopback pools, timeout/abort cleanup and
expect-continue/pipeline behavior. Run on Linux as well: macOS skips the test
that binds the same port on a second loopback address. `share-networks.bats`
checks deployment wiring and conditional firewall/edge limits.

With explicit disposable-host authorization, run from an external client against
legacy HTTP WAN mode (no HTTPS setting; use `https-live.py` for HTTPS). On any
other host it prints `SKIP` and exits 3 before creating anything (DD-193):

```bash
python3 Data/tests/share-networks-live.py --host nrm
```

Only temporary folders/accounts are published, with random credentials kept in
memory/SSH stdin. The test exercises actual WAN and Tailscale Caddy endpoints,
cross-scope refusal, GET/PROPFIND/ranges, RO/RW, forged Host/client-IP, idle TCP
admission, simultaneous-request/login caps, tailnet availability, last-share
pause and timed expiry. WAN ingress packet counters confirm external routing.
Cleanup removes only the fixture prefix/accounts, never existing shares.
Fresh supported-OS installation, reboot and native Infuse/Finder acceptance are
separate; protocol tests do not certify every DAV client.

## Model A and compact App Store (DD-160/DD-161, v2-131)

Serve the real `Data/console` tree locally as below, then run
`node Data/tests/panel-ui.cjs` from the repository root. It applies the actual
Caddy CSP and fixtures all API calls: clean/installed sidebar, qBittorrent
lifecycle and own settings, keyboard tabs, five widths, resource
stale/offline/recovery, ZIP create/cancel/nested-unzip/result routes, and async
WireGuard new-network bookmarks. No server is modified.
App Store checks include compact row height, only one details panel, keyboard
focus across polls, real-progress fixtures, failures with details closed,
stop/start/removal and cancellation, default data retention, log HTTP errors
and safe text rendering, no account reads, and visible status at mobile widths.
`test_resources.py` covers independent sampling, guest CPU accounting, unknown
measurements and real HTTP Host/header/origin gates.

## qBittorrent integration-only seed (DD-178, v2-152)

Bats requires an exact six-key seed allowlist (startup notice, two download-path
compatibility keys and three authenticated loopback WebUI keys). The module
fixture renders that real seed; reapply and remove/reinstall must preserve user
UPnP/discovery/temporary-path choices byte-for-byte and never apply the firewall.

On an authorized Linux test host with qBittorrent, iproute2 and setpriv installed:

```bash
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/torrent-defaults-linux.py
```

This refuses the host network namespace, starts native qBittorrent as uid 1000
in disposable profiles, and compares the actual seed against application
defaults. It checks loopback/local authentication, download location and native
restart persistence of user choices. No torrents are added, no installed config
is read, no host service is controlled, and fixture passwords are never printed.
It does not replace clean Debian/Ubuntu installation or service-sandbox tests.

## Reserved `.pay` path (DD-171)

The Bats suite checks that stage 3 never creates the reserved `SHARE_DIR`
(`.pay`), that stage 3 and `master-modul yerlesik` leave an existing one (contents,
modes, marker symlink) untouched, that registry preparation is idempotent and
public lifecycle actions refuse, and that the Files backend refuses to list it
and writes nothing into it. Folder-sharing tests are described below.

## Built-in ZIP/RAR (DD-159, DD-166, DD-170)

v143 adds automatic nested extraction/default depth-ceiling rollback tests and
installer-driven default-destination state. The native RAR suite submits without
the optional depth fields. `panel-ui.cjs` checks the compact form, automatic ZIP
suffix, default downloads, folder picker navigation/cancel/read-error/retry and
failed submit draft retention. `files-ui.cjs` checks the bottom selection dock at eight
widths/both themes, stable breadcrumbs/search, hidden-view/selection lifecycle,
and notifications never covering its actions. Run browser suites sequentially
against the simple preview server to avoid parallel request-queue timeouts.
v144 additionally checks six stable icon/label slots, single-file/archive/folder
and mixed-selection eligibility, keyboard focus and activation, download excluding
folders, archive/share/move dialog routing, equal cells, a mobile 3×2 grid and
unfilled danger styling under both themes.

From the repository root, run all Python suites with an OpenSSL-enabled Python:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p 'test_*.py'
```

`test_archives.py` covers round trips, nested depth on/off, name collisions,
traversal/links/duplicates, byte/entry/central-directory/deadline limits,
malformed inner archives, cancellation/concurrency and interrupted-job recovery.
`KONSOL_FILES_BACKEND` can point at the installed backend for Linux tests.

`test_rar.py` adds mocked multipart/unsafe-input/budget tests and real subprocess
deadline/cancel/output-cap checks on all hosts. Native RAR→ZIP→RAR is tested on
Linux with `/usr/bin/unrar` and distro `python3-rarfile`; otherwise it is explicitly
skipped. Set `RAR_FIXTURES` to a private directory containing the upstream
markokr/rarfile `test/files` fixtures named by the optional native test to cover
compressed RAR3/RAR5, solid/old/new volumes, Unicode, encryption and link rejection.
Tests copy them into TemporaryDirectory; no downloads or package installs happen
inside tests. Browser fixtures test `.rar`, `.r00`, `.part01.rar` selection and
submission as well as ZIP; ordinary files never offer extraction.

`archives-live.py prepare` is a **mutating disposable-host test** through the
installed Caddy/file service. Keep the printed manifest for `verify <manifest>`
after rerun/reboot and `cleanup <manifest>` afterward. Cleanup removes only its
scratch tree/manifest, retaining ordinary job history as an audit record.

`desktop-live.cjs` tests the **real host**, not fixtures. Set `ARCHIVE_FIXTURE`
to the basename of that live test tree; it creates/extracts browser ZIP outputs.
It checks Model A navigation/resource indicators, built-in shares, settings and five
viewport widths. `TEST_APP_LIFECYCLE=1` explicitly enables qBittorrent
install/stop/start/remove (requires it absent initially, leaves its package and
profile, never requests data deletion). `KONSOL_URL` defaults to `http://panel.ayc/`.
Playwright variables below also apply; screenshots go to a temporary directory.
Do not run live tests against an unauthorized host.

## Settings management (DD-156/DD-157, v2-127)

WireGuard internet-only (DD-177): `wireguard-ui.cjs` tests creation/settings with
no Local selector, DNS-only saves, polling/error/cancel/stopped-network behavior,
explicit regeneration and four widths/CSP. Since DD-200 the page is the package's
(`magaza/wireguard/sayfa.js`): the suite serves `/uygulama/wireguard/*` from the
`magaza/` folder through Playwright routes and uses `/api/uygulama/wireguard/*`;
`panel-ui.cjs` does the same for the WireGuard deep link and reads both packages'
`konsol.json` for the App Store texts. `test_wg_settings.py` drives the package's
API module through the root backend's dispatcher: it rejects a supplied `scope`
field on both routes, checks revision/gates, the `master-wg` argument lines and
the `wireguard:<verb>` audit prefix; `test_resources.py` covers the module listing's
`konsol`/`sayfa` fields and the API module's load/unload with the registry. Bats
verifies DNS-only preservation and rejects access-scope CLI arguments.
`firewall-linux.py` tests actual IPv4/IPv6 host deny (including prior flows),
internet forwarding/NAT, private destinations through WAN, and tailnet isolation.
Veth fixtures pin WG IPv6 neighbors because real WireGuard uses no NDP.

Firewall categories (DD-164, v2-134): `test_firewall_view.py` covers read-only
socket scope classification, IPv6 normalization/zones, read failures, public-only
network metadata, service-name reuse and WAN endpoint versus tunnel permissions.
`settings-ui.cjs` tests default Tailscale, nested keyboard tabs, draft retention,
absent/empty/multiple WireGuard networks, read-only internet-only WG policy, protected
loopback and listener-versus-policy labels (including unknown/unreadable).

Minimum tailnet exposure (DD-172, v2-146): `test_tailnet.py` verifies configured
service ports, validated Self-only PeerAPI discovery and daemon-startup fallback.
The view suite also rejects listener-implies-access and preserves WG endpoints.
Run `unshare --net --fork python3 Data/tests/firewall-linux.py` as root on the
authorized Linux test host. It refuses the host namespace and uses nested veth
clients/echo listeners to test actual IPv4/IPv6 WAN, tailnet and WG input packets,
operator allow/deny precedence, idempotency and extra-rule detection. No installed
service, account or host firewall is modified; all fixtures are temporary.

Tailnet catalogue cleanup (DD-173, v2-147): the view tests exclude arbitrary
peer/backend/admin sockets, retain configured per-family ports even without
listeners, and keep registered WG endpoints with no active peers/sockets.
Browser fixtures preserve explicit tailnet allow/deny rules, editable drafts,
remove/cancel behavior and fallback to default deny without invented port rows.
Live checks must also verify raw diagnostics and required local services remain.

WAN/tunnel catalogue cleanup (DD-174, v2-148): view tests cover configured SSH/
Tailscale ports and IPv4-only WAN WG endpoints independent
of sockets/peer count; retired tunnel permits stay absent. Browser fixtures exercise
explicit allow/deny toggle/remove/cancel for WAN and Tailscale; a closed
user rule remains visible even where no automatic row exists.

Firewall source cleanup (DD-175, v2-149): `firewall-linux.py` additionally starts
from absent module/network files, then verifies preserved networks cannot revive
an absent/empty/stopped module. Test teardown/re-add, no empty forwarding/NAT
chains, repeatability of both tables/families, stale extra INPUT/FORWARD/NAT rules,
unchanged third-party jumps/chains and retained network files. The view suite
covers single-port WG rules and intentionally absent chains versus real failures.
These are isolated policy fixtures, not a fresh Debian/Ubuntu image installation.

DNS-only Apply (DD-163, v2-133): unit tests cover immediate persistence past
the old deadline/reboot, pre-write panel-name protection, mixed confirmation,
restart/commit failure rollback, pre/post-commit crashes and recovery retries.
Browser fixtures assert a single Apply request, no dialog/countdown/confirmation,
reload persistence, failed-apply draft retention and retry. The isolated Linux
DNS test checks immediate commit and failed-apply recovery with real dnsmasq.

Firewall tables (DD-162, v2-132): `settings-ui.cjs` additionally verifies full
semantic tables at five widths, row explanations/source CIDRs, filter/empty
states, protected loopback, on/off drafts, edit/remove, lock during confirmation,
payload/rollback, production CSP and keyboard scrolling without page overflow.

Folder sharing (v2-128, DD-158): also run `python3 -m unittest discover -s
Data/tests -p test_shares.py` and `node Data/tests/files-ui.cjs` from the repository
root. Python must have OpenSSL scrypt (the macOS system Python may not; use an
OpenSSL-enabled Python 3.12+). Linux distribution Python is the production runtime.
The Files UI suite also checks exact share clipboard input and adjacent address/
copy-button geometry in the list and folder details at five widths (v2-138).
Copy APIs are intercepted in fixtures; native iPhone clipboard behavior is not
covered by those checks.
Inline Shares and compact trash (v2-142, DD-169): `files-ui.cjs` checks partial
access/expiry payloads, RW confirmation/cancel/Escape, failed saves, disabled
in-flight controls, account-only editing, eight responsive widths and short
long-filename trash dialogs in both themes. Existing permanent-delete guards
remain tested. `test_shares.py` covers omitted-field preservation, required RW
acknowledgement, rollback and never rebinding a replaced folder via inline edits.
Password policy (v2-141, DD-168): the settings/shares Python and browser suites
reject seven-character passwords and accept eight, preserving blank edits.
`test_shares.py` also verifies real WebDAV GET/PROPFIND authentication and the
read-only write boundary with eight characters. `settings-linux.py` verifies
native qBittorrent login and restart persistence with a disposable eight-character
account inside its private network namespace; it never changes installed accounts.
`shares-live.py prepare` is a **mutating disposable-host test**, using installed
services, two scratch accounts and a random folder. Keep its printed manifest
path for `verify <manifest>` after rerun/reboot and `cleanup <manifest>` afterward.
It does not certify Finder/Infuse clients or Tailscale recipient ACLs.

From the repository root:

```bash
LC_ALL=C PYTHONDONTWRITEBYTECODE=1 bats Data/tests/common.bats
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Data/tests -p test_settings.py
python3 -m http.server 8766 --bind 127.0.0.1 --directory Data/console
# In a second terminal, with Playwright installed:
node Data/tests/settings-ui.cjs
```

On the operator Mac (2026-09-30) Node comes from Homebrew and Playwright is a
global npm package outside the repository, so point the suites at it:

```bash
PLAYWRIGHT_MODULE="$(npm root -g)/playwright" node Data/tests/panel-ui.cjs
```

The fixture suites (`panel-ui`, `files-ui`, `settings-ui`, `settings-https-ui`, `wireguard-ui`,
`giris-ui`) share the same `http.server` on port 8766. `settings-ui.cjs` also covers the
health card and the stuck-rollback discard (DD-182); `panel-ui.cjs` the archive
bar that replaced the jobs page (DD-183).

`PLAYWRIGHT_MODULE`, `PLAYWRIGHT_CHROMIUM` and `KONSOL_URL` may override the
module, browser executable and preview URL. The test intercepts APIs with
fixtures; it never modifies a server. It covers tabs, review/discard, custom
rules, DNS, credentials/folder, confirmation/rollback, address explanations,
account-only single Save (validation, duplicate blocking, failure/retry, reload,
blank-password preservation, unrelated-draft retention and revision refresh),
domain review/new-address links/old-host confirmation refusal, four widths and dark
mode. Screenshots go to a fresh temporary directory.

On a Linux test host with root, iptables/ip6tables, dnsmasq, dig, qBittorrent
and systemd (no additional packages are installed by these tests):

```bash
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/settings-linux.py
PYTHONDONTWRITEBYTECODE=1 python3 Data/tests/settings-systemd.py
PYTHONDONTWRITEBYTECODE=1 unshare --net --fork python3 Data/tests/settings-domain-linux.py
```

The first refuses the host network namespace, uses scratch profiles and
dummy interfaces, and substitutes only service control; firewall, DNS and
qBittorrent are real. Account-only save verifies real new/old login results,
restart persistence, failed-commit recovery and stopped-state preservation.
A local upstream fixture verifies forwarding without
internet access and proves private names are not forwarded. The second uses
real transient systemd work/timer units with a scratch pending record and no
firewall/DNS/qBittorrent changes. Both remove only their own scratch state.
These checks do not replace a fresh Debian/Ubuntu installer acceptance run.

`settings-domain-linux.py` needs Caddy, dnsmasq, dig, curl, setpriv and Python,
but not qBittorrent. It starts the real Caddy and both production API backends
against scratch files, with private DNS/network interfaces. It checks domain
apply/rollback/confirm, real Caddy reload, both Host/header gates, no `health.`
name or site, persisted domain and staged templates. Only systemctl is adapted to
those processes; host services and their settings are never touched. Unit tests
also cover timeout/reboot/crash recovery, state IP preservation, invalid suffixes,
stale renderings, inactive services and installer saved-domain readback.

## Acceptance-check lessons (2026-09-11)

- `tailscale status --json .Self.ExitNodeOption` is **not** an installer
  assertion. It turns true only after the exit node is approved in the admin
  console — the manual step the install summary lists. The installer's own
  obligation is `AdvertiseRoutes` containing `0.0.0.0/0` in
  `tailscale debug prefs`; assert that, and report `ExitNodeOption` as
  information.

## Pitfall: an early-exiting pipe consumer under `pipefail` (2026-09-12)

`install.sh` runs with `set -Eeuo pipefail`. A read-back written as
`apt-config dump | awk '/pattern/{print $2; exit}'` looked harmless and
passed every static check, but on the host it aborted the install with exit
141 after all seven stages had run: `awk` exits on the first match,
`apt-config` gets SIGPIPE writing the rest, `pipefail` turns that into 141,
and `set -e` exits at the assignment. Let the consumer read the whole stream
(`{v=$2} END{print v}`) or guard the pipeline with `|| true`, as the `dig |
head -n1 || true` read-backs do. A bats test now rejects `| awk … exit`
patterns in the installer tree.

## Pitfall: a second `tailscaled` on a provisioned host (2026-09-13)

`tailscaled --statedir=DIR` does not isolate a test daemon. `--state` has a
compiled default of `/var/lib/tailscale/tailscaled.state`, so the daemon
loads the production node's identity and preferences. On `nrm` such a daemon
came up `Running` as the production node for a few seconds and rewrote
`/etc/resolv.conf`; the production daemon restored it within the same second
(`trample: resolv.conf again matches expected content`). The state file,
login and prefs were unaffected, and a `BackendState == NeedsLogin` gate
stopped the test before `tailscale up`.

Run test daemons inside a container with the binaries bind-mounted
read-only, pass `--state` explicitly, and gate on `NeedsLogin` before any
`up`.
