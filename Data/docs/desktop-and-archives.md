# Konsol Desktop and archives (DD-159, DD-166)

## Built-in capabilities and App Store

The v129 desktop shell was superseded by Model A in v130: one sidebar and
workspace, no application dock/window controls. The v143 Files selection dock
contains contextual file actions only. v144 uses the approved icon dock (B):
six equal icon/label cells with a separate count/dismiss header, disabled slots
for ineligible actions and a mobile 3×2 grid. It is not KDE or a remote OS session.
Files is the initial view; Settings owns system/firewall/Caddy/Dnsmasq/logs,
and installed qBittorrent owns its account/path form (DD-160).

Files, per-folder WebDAV and ZIP/RAR are built in. All folder accounts are listed
under Files → Paylaşımlar. The App Store has only WireGuard and qBittorrent as
installable/removable applications. Tailscale, DNS/Caddy and the firewall remain
protected base services; there is no arbitrary-package installation endpoint.

The installer calls `master-modul yerlesik` to enable/check the two data services
and publish the existing share name/port. An unchanged rerun does not restart
them. Upgrading an older installation where these services were absent/stopped
activates them as built-ins, but creates no folder account. Existing account
IDs, hashes, permissions and pause/expiry state are not reset. No data migration
or backup is embedded. Public module actions reject `dosya` and `paylasim`;
their staged templates and internal registry IDs remain for domain-change,
firewall and status compatibility. See [folder shares](folder-shares.md) for
credential and recipient-ACL boundaries.

## Archive operations (v2-143, DD-170)

Select files/folders in Files to reveal the bottom action dock; the breadcrumb
and search bar remain in place. “Arşiv oluştur” always creates ZIP (suffix added
automatically), while “Arşiv açıcı” recognizes supported archives/volumes. Choose
an existing destination folder, result name and outer-name collision policy
(rename, skip or stop). Results are new files/folders; sources and existing
destinations are never overwritten or deleted. The destination defaults to the
installer's `DOWNLOADS_SUBDIR`, exposed by `GET /api/state.downloads`, independently
of the source folder and qBittorrent's current save directory. A click-to-browse
picker uses the existing directories-only file API; no free-text path entry.
Nested extraction is automatic and retains inner archives beside their extracted
folders, without flattening conflicting paths. The first archive counts as layer
one. The UI no longer shows nested/depth options or technical statistics/limits.
At the five-layer ceiling automatic extraction fails atomically, never reporting
incomplete nested work as success. A corrupt/unsupported inner archive fails the
whole job; no partial result folder is published.

ZIP Store/Deflate and unencrypted RAR3/RAR5 (including solid archives) are supported,
not encrypted archives, multipart ZIP, large ZIP64 or 7z. All RAR volumes must be
in the same folder: `.rar/.r00/.r01…` or `.part01.rar/.part02.rar…`. Selecting a
later part resolves the first automatically. Missing/ambiguous parts fail closed;
nested multipart sets are opened once, not once per volume. RAR creation is not offered.
Limits are shared across each entire job, including
nested work: 2 GiB processed uncompressed bytes, 10,000 entries (directories
included), five layers, 900 seconds, and a 16 MiB central directory checked
before Python allocates its entry list. Nested archive bytes count when copied
and their contents count again when extracted. These are safety limits, not a
promise that every 2 GiB archive will finish under the service resource cap.
One job runs at a time; a second submission is rejected until it finishes.

Jobs run on a worker thread in the unprivileged file backend, never a root
shell. ZIP uses the standard library. RAR uses the signed distribution packages
`python3-rarfile` (metadata) and `unrar` (content/CRC); no pip or downloaded executable.
`master_rar.py` runs in a separate process with 192 MiB address-space/CPU limits,
bounded metadata output, a 30-second metadata deadline and process-group cancellation.
The service's existing systemd memory/CPU/task limits still apply. RAR volumes are
copied through validated descriptors into a private snapshot (compressed set <=2 GiB).
Only `unrar p` stdout is consumed; unrar never chooses/writes output paths.
The parent validates paths/types, opens new files without following links and
checks sizes/CRC before publishing. Password prompts, shell arguments, link/redirection
members and wildcard member names are refused. The page may close without stopping the job.
The UI shows job state, errors, cancellation and result links; byte/entry counters
remain available in the API only. A destination identity change or source
file change fails closed; this is not a snapshot of a concurrently changing tree.

### Storage and safety

`FILES_ARCHIVE_DIR` in `config/defaults.env` names the private workspace below
`SERVER_ROOT` (currently `/srv/.arsiv`, mode 0700). `jobs.json` is mode 0600;
the installer permission sweep excludes this tree. It stores at most 20 jobs,
not file backups. Private job staging is not exposed by the file API. A complete
result is atomically renamed into place with no replacement on Linux. Failure
or cancellation removes staging. Restart marks unfinished jobs interrupted and
cleans their staging; it does not resume them. A crash between publication and
history persistence can leave a valid result without a success record: inspect
the destination before retrying. History can outlive an output manually removed
by the user.

Descriptor-based access refuses traversal, absolute/ambiguous paths, symlinks,
hard-linked regular files, device files and cross-device children. Internal paths
are reserved. Duplicate/unsafe archive entries fail the job, independently of the
outer-name collision policy. Job history bounds path and name lengths. Files
and DAV still share the downloads UID: this is not isolation from a trusted
host administrator or another process running as that UID.

### API

All endpoints retain the file backend's allowed-Host and `X-Konsol: 1` gates.

| Endpoint | Contract |
|---|---|
| `GET /api/archives` | `{items, limits}` including persisted terminal jobs and `limits.formats` |
| `POST /api/archives` | `{operation, path, names, target, name, nested, layers, conflict}`; relative paths; returns 202 `{job}` |
| `POST /api/archives/cancel` | `{id}`; cooperative cancellation, returns 202 |

`operation` is `zip` or `unzip` (also used for RAR, for API compatibility);
`conflict` is `rename`, `skip` or `stop`. The UI omits `nested` and `layers`:
extraction defaults to recursive/five-layer maximum with `automatic:true` recorded
in the job. Explicit legacy API options still work as before (including reporting
inner archives left packed at the caller's chosen depth); they are not UI options.
No operation accepts shell arguments, absolute paths or executable plugins.

## Verified boundary

See `../SESSION.md` for actual runs. v129 was upgraded/rerun/rebooted on Debian
13.7 `nrm`, with real Caddy/systemd/DAV/ZIP requests and browser App Store
qBittorrent lifecycle tests. Unit tests also cover malformed ZIPs, resource
limits and interrupted-job recovery. A fresh Ubuntu install, native Finder/
Infuse clients and recipient ACL certification were not performed for v129.
