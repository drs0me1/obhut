# Folder WebDAV (v2-128/v2-129, DD-158/DD-159)

The Files v09 layout is implemented in `console/konsol.js`, `dosyalar.js`
and `dosyalar.css`: list by default, optional cards, selected-item details on
the right (below on mobile), folder search/breadcrumbs and a WebDAV shares tab.
Existing file upload, text view, move, rename and trash operations remain.

## Accounts and lifecycle

- Files and WebDAV are built in since v129. Select a folder, open Details,
  then WebDAV sharing. All accounts appear under Files → Paylaşımlar.
  No folder is published by default; no App Store installation is needed.
- Each of at most 32 non-overlapping folders has an opaque stable 24-hex ID,
  its own unique username and password, RO/RW permission, 1/7/30-day or unlimited
  lifetime and paused state. New forms default to RO and seven days.
- Since v142, the Shares list has aligned folder/address, account, access,
  duration, state and action columns. Access and duration are native dropdowns
  saved immediately; RW still asks for explicit acknowledgement. Choosing 1/7/30
  days starts that duration now; the current absolute expiry is shown until then.
  Manage edits folder/username/password only. Omitted fields preserve the current
  registry values under its lock; access/expiry-only edits never rebind a missing
  or replaced root. Failed writes retain the last confirmed UI values.
- Address: `http://<tailscale-ip>:<SHARE_PORT>/s/<id>/`. The same path works
  through `paylas.<domain>`. The IP/domain and port come from runtime state.
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
- Installer reruns and reboot preserve the registry. Since v129 public module
  operations cannot stop/remove Files or WebDAV, even with `--veri`. Remove
  individual accounts in Files → Paylaşımlar; this never removes their files.

## Ownership and API

- `panel/master_shares.py`: root-only registry owner, fixed verbs
  prepare/status/save/pause/remove, scrypt hashes with random salts. The source
  is `SHARE_STATE_FILE` (`/etc/master-stack/webdav.json`, 0600 root), schema 2.
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
  OS sandbox per account**. This differs from the tentative rclone-instance
  proposal and is not a general-purpose externally exposed file server.
- Caddy proxies the existing tailnet name/IP port to the loopback service.
  No extra public listener or Tailscale ACL/grant is created. An address refresh
  restarts only Caddy; WebDAV remains on loopback.

## Filesystem and protocol boundaries

Paths are resolved from directory descriptors with O_NOFOLLOW. Root identity
includes device, inode and birth time (Linux statx); unsupported filesystems
fail closed. Root/internal/hidden directories, known incomplete-download roots,
symlinks, multiply linked regular files, cross-device children and overlapping
share roots are refused. Do not move a qBittorrent incomplete directory into an
existing shared subtree: remove/recreate the share after such external changes.

PUT uses a hidden sibling temporary file, fsync and atomic rename: an interrupted
request does not replace the previous file. A process kill may leave a hidden
temporary file; it is never served and there is no automatic cleanup daemon.
DELETE may partially complete if a later child cannot be removed; it is not a
transaction and cannot be undone. Trusted host administrators can change the
filesystem concurrently; this is not an isolation boundary against root.

Supported: OPTIONS, GET/HEAD (single byte ranges and ETags), PROPFIND Depth 0/1,
PUT (fixed-length/chunked, up to 64 GiB), MKCOL, DELETE, MOVE and **file** COPY.
Destination must stay in the same share/host. No DAV locks, PROPPATCH or directory
COPY: these explicitly fail, never report false success. Full WebDAV conformance
and Finder/Infuse interoperability are **not certified** by protocol tests.
Maximum 16 simultaneous connections, 10,000 entries per PROPFIND listing.

## Network prerequisite

Konsol is passwordless and administrative. Recipients must be allowed only the
WebDAV port, with Konsol/SSH restricted to administrators in Tailscale ACL/grants.
Review broader existing grants; adding a narrow allow does not remove them.
The installer does not change account policy. HTTP is carried inside the
Tailscale tunnel, but clients requiring HTTPS or DAV locking need a separately
validated solution. Do not weaken client security settings to claim compatibility.

## Upgrade from the old shared account

The old rclone shared root and account are retired, not silently retained as an
alternate route. Existing files remain, but legacy URLs/credentials must be
replaced by newly created per-folder shares. This is a breaking change. On `nrm`
the user explicitly authorized test deployment and accepted data loss. Other
operators must accept the migration before upgrading. Old metadata is not
automatically imported or deleted. Since v129 these built-ins no longer expose
the former module metadata cleanup command.

Since v145 (DD-171), the installer no longer creates `.pay/w` or writes
`.pay/acik`, exports old credential paths, or repairs legacy directory permissions.
Existing metadata stays untouched and inaccessible. `SHARE_DIR` and the Files
`--share` argument remain only as reserved-path guards. WebDAV's systemd exclusion
allows that path to be absent on fresh installs while blocking it when present.
The retired Files `/api/paylas` GET/HEAD/POST and `/api/paylas/kaldir` POST answer
410 behind the usual Host/header/origin gates; there is no fake empty active list
or marker-derived share summary. The current folder API and registry are unchanged.

## Verification

`tests/test_shares.py` tests real HTTP requests and descriptor boundaries;
`tests/files-ui.cjs` checks production-page forms and five viewport widths.
`tests/shares-live.py prepare` runs through the installed Caddy and systemd
workers on an explicitly authorized disposable host; it prints a private
manifest path (not credentials). Use `verify <manifest>` after rerun/reboot,
then `cleanup <manifest>` to remove only its own test accounts and files.
Native clients and a fresh Ubuntu install require separate acceptance.
