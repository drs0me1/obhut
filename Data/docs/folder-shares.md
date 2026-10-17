# Folder WebDAV (DD-158, DD-159, DD-179, DD-190, DD-191, DD-192)

The built-in folder sharing of Obhut: what it publishes, how its accounts and connection policies work,
its limits and what it does not do. The behaviour contract's summary is
[contract.md §3.9 and §5.4](contract.md); the layout is in [architecture.md §6.7](architecture.md).

## Shares and accounts

- Shares are managed in Dosyalar → Paylaşımlar (**DD-267**): "Paylaşım ekle", or "Paylaş" on a folder in
  Sunucu klasörleri (`?yeni=<folder>`); a shared folder carries a mark and "Paylaşımı yönet"
  (`?paylasim=<id>`). Nothing is shared by default.
- Each of at most 32 non-overlapping folders under `SERVER_ROOT` has an opaque, stable 24-hex ID, the
  path `/s/<id>/`, and its own user name (3–32 characters, `[A-Za-z0-9][A-Za-z0-9._-]`, unique without
  regard to case) and password (8–256 characters, no `:` and no control character; typed or generated in
  the sheet, **DD-168**). The root, hidden folders and the trash (`.cop`) are never shared; a folder that
  contains or lies inside another share is refused.
- Every share has exactly two connection policies, `connections.tailscale` and `connections.wan`, each
  `{enabled, permission: "ro"|"rw", expires: Unix seconds | null}` (`null` is unlimited). Both use the same
  folder, ID, user name and password; either or both may be off (an account with both off is a paused
  share). A new share starts with Tailscale on (while WebDAV's Tailscale side is published), read-only, seven
  days, and the internet off, read-only, seven days.
- RW includes upload, overwrite, new folders, move, file copy and permanent deletion (WebDAV has no trash).
  Every explicit choice of RW needs its own acknowledgement for that connection.
- Passwords are never retrievable after saving. A blank password on an edit keeps the hash; an omitted
  path never rebinds the folder.

## The registry

- `SHARE_STATE_FILE` (`/etc/master-stack/webdav.json`, 0600 root) is the only source, schema 4. Any other
  schema, an item without both connection policies or a key this version does not write fails closed
  ("Paylaşım kaydı desteklenmiyor"). Hashes are scrypt with a random salt; each folder's identity is its
  device, inode and birth time (statx), so a replaced folder is detected.
- `panel/master_shares.py` owns it: fixed `prepare`, `status`, `save`, `remove`, `publish` and `guard`
  actions. Konsol's `POST /api/konsol/paylasim/kaydet` and `…/kaldir` run it as a transient worker with JSON
  on standard input, under `install.lock` and `paylasim.lock`; a pending settings change or an interrupted
  share change refuses a new one.
- A save accepts only `id`, `path`, `username`, `password`, `connections` and `ack_wan_http`. `connections`
  holds one or both scopes, each a patch of `{enabled?, permission?, days?, ack_write?}`: `days` is 0
  (unlimited), 1, 7 or 30 and starts that connection's duration at save time; omitted scopes and fields,
  the exact expiry included, are kept. `permission: "rw"` in a patch needs `ack_write: true` in the same
  patch, even when the connection is already RW or off. Switching a connection on never renews an expired
  one. Turning the internet connection on in legacy HTTP mode needs `ack_wan_http: true`.
- Every change writes a private `.pending` snapshot, the registry, restarts an active WebDAV service (and
  waits for its anonymous 401), and publishes the projection; a failure restores the previous registry and
  restarts again. **Every share edit interrupts all running transfers**; the page says so. A stopped service
  stays stopped. After an uncertain answer, reload the list before repeating a change.
- `GET /api/konsol/paylasim` returns no hash, salt or folder identity. Each `row.connections[scope]` adds
  `expired`, `available` (the transport is published), `active` (enabled, unexpired, the folder valid, the
  transport available), `reason` and `url` (a candidate address whenever the transport is available, even
  when the connection is off or expired; empty otherwise). `row.urls` holds only active connections and
  `row.url` the first of them. A candidate address is not proof of access or reachability.

## The service

- `master-paylasim.service` runs `panel/master_webdav.py` as `DOWNLOADS_UID`/`DOWNLOADS_GID`, never as root
  (it refuses to start as root). It reads the registry as a systemd credential (`LoadCredential`); its
  command line holds only the credential's path. No capabilities, system files read-only, `SERVER_ROOT`
  writable, the trash and `PRIVATE_STATE_ROOT` (`/var/lib`) inaccessible (**DD-225**), network to and from
  loopback only, a system-service syscall filter, private IPC, hidden foreign processes, 96 tasks and
  512 MiB (page cache included); at most five automatic restarts in ten minutes.
- It listens on two loopback addresses of `SHARE_PORT`: `127.0.0.1` for the Tailscale connection and
  `SHARE_WAN_BACKEND` for the internet connection. **The listener, not a header, chooses the policy**:
  Tailscale RW never grants write on the internet listener, or the reverse.
- Caddy publishes the Tailscale side as `http://paylas.<domain>/s/<id>/` and, for clients without names
  (Infuse on Apple TV, **DD-98**), `http://<tailscale-ip>:SHARE_PORT/s/<id>/`; Caddy sets
  `X-Share-Client-IP` from the socket peer, and the client's own `X-Forwarded-For` is never trusted.
- Per-folder isolation is enforced in the request handler, not by a separate OS sandbox per account. Root
  administrators and Konsol's administrators remain outside this boundary.

## Publication gates (DD-191, DD-192)

WebDAV's fixed row in Erişim → Adresler (`paylasim` in `SETTINGS_FILE` `web`) gates both sides globally; a
gate only restricts folder policies, it never widens them or changes accounts. Its changes go through the
settings plan: an opening waits for the 60 s confirmation from Tailscale, a closing commits at once
(**DD-275**).

- **Tailscale switch:** off writes a 403 site on exactly the same addresses (the name and the IP:port);
  the service keeps running and listeners shared with other sites stay.
- **Internet:** the internet mode follows the row (**DD-179**, **DD-190**):

  | WebDAV row | Internet endpoint |
  |---|---|
  | never saved | consent-gated plaintext HTTP on `WAN_IPV4:SHARE_PORT`, only while an enabled, unexpired, identity-valid internet connection exists and no internet name of Konsol or an application is enabled |
  | internet on with a name | HTTPS on `WAN_IPV4:SHARE_HTTPS_PORT` (443), kept for certificate issuance and renewal even with no active folder |
  | saved, internet off | closed; the name is remembered for a later re-enable; never a fallback to HTTP |

- Konsol's and the applications' internet names share TCP 443 with WebDAV. While one of them is enabled,
  plaintext WebDAV is unavailable until WebDAV has an HTTPS name; and an internet name cannot be switched
  on while folders are shared over plaintext HTTP (save WebDAV's HTTPS name or close those connections
  first). With no internet name and no plaintext share, no public Caddy listener exists.
- The cards in Paylaşımlar show both connections and explain a closed gate with its reason; no address is
  advertised through a closed gate.

## Optional public HTTPS (DD-190)

- The name is a full public domain such as `dav.example.org` (not a URL, port, path, IP address or
  wildcard); it does not rename `LOCAL_DOMAIN` or the local names. Public DNS must resolve to exactly the
  assigned `WAN_IPV4`: a DNS-only A record, no AAAA, no provider proxy. Obhut writes no public DNS.
- Caddy owns the keys, issuance and renewal through Let's Encrypt TLS-ALPN on TCP 443; the HTTP challenge
  and the port-80 redirect are disabled; no DNS API token or extra certificate daemon exists.
- The internet site passes only `/s/*` to `SHARE_WAN_BACKEND` (WAN keepalive off); `/`, `/api/*` and every
  other path answer 404. A Host/SNI mismatch on the shared listener is 421 (`strict_sni_host`).
- Switching it on checks DNS, applies the projection, checks that the listener is up (failing at once with
  the cause otherwise) and waits up to 60 s for a certificate verified by a probe that connects to the
  assigned WAN IPv4 with the name as SNI. Certificate ready is not proof of reachability from the internet;
  check public DNS, CAA and inbound TCP 443 separately. Erişim shows the expiry; health warns at 14 days or
  less. Switching it off closes new internet connections through a graceful Caddy reload; existing
  transfers may finish.

## Connection policies on the wire

- Every request authenticates against exactly one share (Basic authentication on `/s/<id>/`) and is checked
  against the receiving listener's policy, a cached login included. All methods, `OPTIONS` and unsupported
  ones included, need an enabled, unexpired connection; every write method (`PUT`, `MKCOL`, `DELETE`,
  `MOVE`, file `COPY`) needs RW on that listener. Expiry is enforced on requests and on live transfer
  chunks, without opening Konsol; one connection's expiry never expires the other.
- A folder moved or replaced on disk fails closed (410); edit the share's path to reconnect the same ID on
  purpose. Removing a share revokes both connections and the account, never the files.
- The 30 s `master-share-network.timer` closes an expired plaintext internet publication, finishes an
  interrupted share change from its snapshot and publishes the access projection again when it differs; it
  waits while the installer, a settings change or a share change holds the locks. Disabling or removing the
  last active plaintext internet connection closes the listener at once; HTTPS keeps it for renewal. Reboot
  re-projects from the saved row and registry.
- **DD-182:** the WAN address must still be assigned to the host (a bind probe). When the provider changes
  it, the internet side reports "kurulumu yeniden çalıştırın", the 30 s projection removes the internet
  site, and a Caddy that could not start on the old address is started without it. A re-run records the new
  address and publishes the site again in stage 7.

## Limits (DD-179, DD-180, DD-181, DD-188, DD-193)

- **Internet listener:** 8 backend connections in total, 4 simultaneous requests per source IP, a 30 s
  socket inactivity timeout; connections close after each response. The host additionally caps new sockets
  to the shared WAN port at 16 per source and 64 in total, before any operator rule. Caddy's WAN listener has
  a 10 s header deadline and a 30 s idle limit. These are connection counts, not bandwidth caps or DDoS
  protection.
- **Tailscale listener:** 64 connections and a 60 s idle timeout; Caddy keeps its upstream connections alive
  for 30 s.
- **Password checks:** two at once on the Tailscale listener and four on the internet listener; a request
  waits up to 200 ms for a slot and checks the login cache again first. Capacity exhaustion is 503 with
  `Retry-After`.
- **Bad credentials:** five within 60 s from one address block it for 300 s (429 with `Retry-After`), on
  both listeners (the Tailscale listener keys on Caddy's client address). Per share and listener, 100 bad
  credentials within an hour close that share for an hour to every address that has not logged in to it
  since the service started. A missing `Authorization` is the usual uncounted 401; an unknown account or a
  wrong share costs one scrypt check too, so timing does not reveal which part was wrong. The table holds
  4,096 entries and fails closed when full. Blocks live in memory and reset on a restart (which only an
  administrator can cause).
- **Login cache (DD-181):** a successful login is remembered for 10 minutes (256 entries, keyed by share,
  stored hash and an HMAC of the exact `Authorization` value); a hit never bypasses the listener's enabled
  state, permission or expiry. Concurrent requests with the same credentials share one verification for up
  to 2 s (**DD-193**).
- **Disk reserve:** `PUT` and `COPY` stop with 507 before the file system falls under min(5 GiB, 10 %)
  free and remove their temporary file (**DD-180**).

## Filesystem and protocol boundaries

- Paths are resolved from directory descriptors with `O_NOFOLLOW`. Symlinks, multiply linked regular
  files, special files, mounted sub-file-systems and hidden names are never served.
- `PUT` and `COPY` stage content in a hidden sibling without holding the global mutation lock; publishing
  it re-checks the listener's policy, the share's identity, the root and parents, the target and source
  versions and the request's preconditions under the lock, then syncs and renames. A concurrent change fails
  instead of being overwritten. A killed process may leave a hidden temporary file; it is never served.
- `DELETE` of a folder may complete partly when a child cannot be removed; it is not a transaction.
- **Supported:** `OPTIONS`, `GET`/`HEAD` (single byte ranges, ETags), `PROPFIND` with depth 0 or 1 (at most
  10,000 entries), `PUT` (fixed length or chunked, up to 64 GiB), `MKCOL`, `DELETE`, `MOVE` and file `COPY`,
  with the destination in the same share and host. **Not supported, and refused instead of faking success:**
  `LOCK`, `UNLOCK`, `PROPPATCH`, folder `COPY`, depth infinity. Full WebDAV conformance and Finder or Infuse
  interoperability are not certified by the protocol tests.

## Who can manage shares

Konsol is administrative: every tailnet device that reaches `panel.<domain>`, and the one internet account
(**DD-194**, **DD-205**), manages every folder and share. Never give recipients Konsol access. In the
Tailscale ACL or grants, allow recipients only the WebDAV port and restrict Konsol and SSH to
administrators; review broader existing grants, as adding a narrow allow removes none. Obhut changes no
account policy. Do not weaken a client's security settings to make it work.

## Verification

- `tests/test_shares.py`, `test_share_connections.py`, `test_share_manager_networks.py`,
  `test_stage3_webdav.py` and `test_stage3_share_paths.py` run real HTTP requests and descriptor boundaries;
  `test_https_settings.py` and `test_https_panel.py` cover the internet name; `tests/yeni-paylasim-ui.cjs`
  checks Dosyalar → Paylaşımlar (cards, sheets, both connections) and `yeni-erisim-ui.cjs` WebDAV's row in
  Erişim → Adresler.
- Opt-in live checks on a disposable host: `tests/shares-live.py prepare|verify <manifest>|cleanup
  <manifest>` (through the installed Caddy and workers; it prints a private manifest path, never
  credentials), `tests/share-connections-live.py --host <host>` (one temporary folder and account; it
  restarts WebDAV and interrupts transfers, then checks a byte-identical registry), and
  `tests/https-live.py --host <host> --domain <name>` (`--configure` leaves the name saved).
- Commands and limits are in [the test runbook](../tests/README.md); a described test is not a completed
  live run. Native clients need their own acceptance.
