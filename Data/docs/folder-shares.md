# Folder WebDAV (DD-158/DD-159/DD-179)

## Network selection and WAN limits (DD-179)

Each folder selects `tailscale`, `wan` or both, with the same ID, account,
password hash, permission and absolute expiry. New shares default to Tailscale.
An empty selection is rejected; adding WAN requires explicit `ack_wan_http: true`.
WAN is **unencrypted HTTP**, deliberately requested for this phase: credentials
and content can be observed or modified in transit. Limits do not provide TLS.
Use temporary credentials/non-sensitive data for public testing.

Caddy binds the server's assigned, globally routable WAN IPv4 on SHARE_PORT
while an unpaused, unexpired, identity-valid WAN share exists. No NAT discovery,
provider forwarding, IPv6 WAN, wildcard bind, admin/API route or ACL change.
Manual firewall denials remain effective; the form notes this prerequisite.
Public results contain labeled URLs; unavailable WAN is not advertised.
**DD-182:** the address must still be assigned to this host (a probe bind). If
the provider changes it, WAN is unavailable with "kurulumu yeniden çalıştırın",
the 30 s guard removes the public site, and a Caddy that could not start on the
old address is started without it. The installer drops a site bound to a stale
address before restarting Caddy; stage 7 publishes it with the new address.

The unprivileged process uses separate loopback addresses on SHARE_PORT:
127.0.0.1 for Tailscale, SHARE_WAN_BACKEND for WAN. Listener scope, not an HTTP
header, selects folder authorization. Caddy overwrites X-Share-Client-IP using
the socket peer; client X-Forwarded-For is not trusted. All DAV methods require
the selected network, including OPTIONS and unsupported methods.

- WAN: 8 backend connections total, 4 simultaneous requests per source IP,
  4 parallel scrypt checks and a 30-second socket inactivity timeout.
- Five supplied bad credentials in a sliding 60 seconds block that IP for
  300 seconds; 429 includes Retry-After. Missing Authorization is the usual
  uncounted 401 challenge. Unknown accounts and malformed credentials count.
  The 4096-entry table fails closed when full; active blocks are never evicted.
- **DD-180:** the same per-IP rule also applies on the Tailscale listener, keyed
  on Caddy's X-Share-Client-IP (local probes without it share one key). Per
  share and listener, 100 bad credentials within an hour close that share for
  an hour to every address that has not logged in to it since the service
  started; the recipient already connected keeps working. The service logs only
  the share ID and the fixed numbers. A wrong user, paused or unknown share
  also costs one scrypt check, so timing does not reveal which part was wrong.
- Tailscale keeps its independent pool of 64 connections (Caddy keeps up to 32
  idle upstream connections). WAN connections close after each
  response; proxy keepalive is off for that upstream. Every closing reply says
  `Connection: close`.
- **DD-181:** a successful login is remembered in memory for 10 minutes (256
  entries, keyed by share, stored hash and an HMAC of the exact Authorization
  value), so repeated Infuse/Finder requests skip the scrypt check. A paused
  share, another password or another listener is checked again; a registry
  edit restarts the service and clears the memory. Per-IP and per-share limits
  still apply to every request. Replies are sent without Nagle delay
  (`TCP_NODELAY`).
- Host TCP admission additionally caps new WAN sockets at 16 per source IP and
  64 total, before manual allow rules. Conntrack can temporarily retain closing
  sockets. These are connection counts, not bandwidth caps or DDoS protection.
- The WAN Caddy listener has a 10-second header deadline and 30-second keepalive
  idle limit; other listener timeouts are unchanged. Caddy startup waits for and
  checks the owned firewall before serving. See the official [Caddy listener
  binding](https://caddyserver.com/docs/caddyfile/directives/bind) and [server
  timeout](https://caddyserver.com/docs/caddyfile/options#timeouts) semantics.
- In-memory login blocks reset on service restart, including account edits;
  unauthenticated clients cannot trigger such restarts.

Registry changes restart the data service, then validate/project Caddy and the
owned firewall rules. Failures restore the old registry/projection; a private
pending snapshot recovers interrupted changes under the same locks. A focused
30-second `master-share-network.timer` closes expired WAN projections and
recovers pending operations, without rewriting unchanged state or restarting
healthy services. Request/chunk expiry remains immediate; listener/rule cleanup
is normally within the next tick and defers during locked/pending settings
operations. Last-share pause/removal closes it synchronously. Reboot reprojects
from the registry. This is not a general service reconciliation engine.

The Files layout is implemented in `console/konsol.js`, `dosyalar.js`
and `dosyalar.css`: list by default, optional cards, selected-item details on
the right (below on mobile), folder search/breadcrumbs and a WebDAV shares tab,
next to upload, text view, move, rename and trash.

## Accounts and lifecycle

- Files and WebDAV are built in. Select a folder, open Details,
  then WebDAV sharing. All accounts appear under Files → Paylaşımlar.
  No folder is published by default; no App Store installation is needed.
- Each of at most 32 non-overlapping folders has an opaque stable 24-hex ID,
  its own unique username and password, RO/RW permission, 1/7/30-day or unlimited
  lifetime and paused state. New forms default to RO and seven days.
- The Shares list has aligned folder/address, account, access,
  duration, state and action columns. Access and duration are native dropdowns
  saved immediately; RW still asks for explicit acknowledgement. Choosing 1/7/30
  days starts that duration now; the current absolute expiry is shown until then.
  Manage edits folder/username/password and networks. Omitted fields preserve the current
  registry values under its lock; access/expiry-only edits never rebind a missing
  or replaced root. Failed writes retain the last confirmed UI values.
- Address: `http://<tailscale-ip>:<SHARE_PORT>/s/<id>/`. The same path works
  through `paylas.<domain>`. A share with WAN enabled also has
  `http://<wan-ipv4>:<SHARE_PORT>/s/<id>/`; the UI labels each address. The
  IP/domain and port come from runtime state.
- Blank password on edit keeps its hash; keep-duration preserves the exact
  expiry. New passwords have 8–256 characters and can be generated in the
  form. They are never retrievable after saving. No password goes into browser
  storage, argv, environment files, progress or audit logs.
- RW explicitly includes upload, overwrite, mkdir, move and deletion. It needs
  an acknowledgement: WebDAV deletion is permanent, not Konsol trash.
- Pause preserves the account and URL. Remove revokes only the share, never
  its folder. Expiry is enforced on requests and transfer chunks without any
  need to open the console. A folder moved/replaced on disk fails closed;
  edit its path to deliberately reconnect the same public ID.
- Every account change atomically writes the registry and restarts an active
  WebDAV service to reload its credential, interrupting **all** current WebDAV
  transfers. A stopped service stays stopped. A failed restart restores the
  previous registry and attempts to restart it. Confirm the list after an
  uncertain/timeout response before repeating a mutation.
  Explicit renewals reset systemd's start counter and wait for the anonymous
  HTTP 401 gate before returning success; automatic crash throttling remains.
- Installer reruns and reboot preserve the registry. Public module
  operations cannot stop/remove Files or WebDAV, even with `--veri`. Remove
  individual accounts in Files → Paylaşımlar; this never removes their files.

## Ownership and API

- `panel/master_shares.py`: root-only registry owner, fixed verbs
  prepare/status/save/pause/remove, scrypt hashes with random salts. The source
  is `SHARE_STATE_FILE` (`/etc/master-stack/webdav.json`, 0600 root), schema 3
  (the only accepted schema; other registries are refused, not converted).
  Public results omit hashes, salts and filesystem identities.
- `master-wg-panel`: existing Host, same-origin and `X-Konsol: 1` gates.
  `GET /api/konsol/paylasim` lists public metadata; POST `.../kaydet`,
  `.../durum`, `.../kaldir` dispatch fixed transient workers with JSON on stdin.
  The worker locks install, module and share operations, in that order; pending
  settings transactions block account changes.
- `panel/master_webdav.py`: Python stdlib server, loopback only, never root,
  runs as DOWNLOADS_UID/GID in `master-paylasim.service`. The service receives
  the registry through `LoadCredential=registry:...`; command line contains
  only its path. Capabilities are empty; system files are read-only, home and
  internal trash/share paths inaccessible, outgoing traffic limited to loopback.
  `SERVER_ROOT` is writable to support shares anywhere inside the user area.
  **Per-folder isolation is enforced in the request handler, not by a separate
  OS sandbox per account**; the supported DAV subset is intentionally bounded.
- Caddy proxies the tailnet name/IP port and an opted-in WAN IPv4 site.
  No Tailscale ACL/grant is created. An address refresh
  restarts only Caddy; WebDAV remains on loopback.

## Filesystem and protocol boundaries

Paths are resolved from directory descriptors with O_NOFOLLOW. Root identity
includes device, inode and birth time (Linux statx); unsupported filesystems
fail closed. Root/internal/hidden directories, known incomplete-download roots,
symlinks, multiply linked regular files, cross-device children and overlapping
share roots are refused. `SHARE_DIR` (`.pay`) below `SERVER_ROOT` is a reserved
internal name (DD-171): the installer never creates, reads or deletes it, Files
hides it and refuses to create it, and WebDAV and qBittorrent cannot access it
when it exists. Do not move a qBittorrent incomplete directory into an
existing shared subtree: remove/recreate the share after such external changes.

PUT uses a hidden sibling temporary file, fsync and atomic rename: an interrupted
request does not replace the previous file. A process kill may leave a hidden
temporary file; it is never served and there is no automatic cleanup daemon.
DELETE may partially complete if a later child cannot be removed; it is not a
transaction and cannot be undone. Trusted host administrators can change the
filesystem concurrently; this is not an isolation boundary against root.

Supported: OPTIONS, GET/HEAD (single byte ranges and ETags), PROPFIND Depth 0/1,
PUT (fixed-length/chunked, up to 64 GiB), MKCOL, DELETE, MOVE and **file** COPY.
PUT and COPY stop with 507 before the filesystem falls under min(5 GiB, 10%)
free space, and remove their temporary file (**DD-180**).
Destination must stay in the same share/host. No DAV locks, PROPPATCH or directory
COPY: these explicitly fail, never report false success. Full WebDAV conformance
and Finder/Infuse interoperability are **not certified** by protocol tests.
Connection limits are listed above; 10,000 entries per PROPFIND listing.

## Network prerequisite

Konsol is passwordless and administrative. Recipients must be allowed only the
WebDAV port, with Konsol/SSH restricted to administrators in Tailscale ACL/grants.
Review broader existing grants; adding a narrow allow does not remove them.
The installer does not change account policy. HTTP is carried inside the
Tailscale tunnel, but clients requiring HTTPS or DAV locking need a separately
validated solution. Do not weaken client security settings to claim compatibility.

## Verification

`tests/test_shares.py` tests real HTTP requests and descriptor boundaries;
`tests/files-ui.cjs` checks production-page forms and five viewport widths.
`tests/shares-live.py prepare` runs through the installed Caddy and systemd
workers on an explicitly authorized disposable host; it prints a private
manifest path (not credentials). Use `verify <manifest>` after rerun/reboot,
then `cleanup <manifest>` to remove only its own test accounts and files.
Native clients and a fresh Ubuntu install require separate acceptance.
