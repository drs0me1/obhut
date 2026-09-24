# Konsol Desktop and archives (v2-129, DD-159)

## Built-in capabilities and App Store

The v10 desktop proposal is now the production shell: application launcher,
dock, a single workspace, and close/minimize/maximize controls. It is not KDE,
a remote OS session or independent floating windows. Files is the initial view;
Settings keeps the four live firewall/Caddy/Dnsmasq/qBittorrent tabs.

Files, per-folder WebDAV and ZIP are built in. All folder accounts are listed
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

## ZIP operations

Select files/folders in Files to create a ZIP; select one ZIP to extract. Choose
an existing destination folder, result name and outer-name collision policy
(rename, skip or stop). Results are new files/folders; sources and existing
destinations are never overwritten or deleted. Nested extraction is optional,
defaults to three layers and retains the nested ZIP files beside their extracted
folders. The first archive counts as layer one. Deeper ZIPs remain packed when
the selected limit is reached. A corrupt/unsupported inner archive fails the
whole job; no partial result folder is published.

Only ZIP Store/Deflate is supported, not encrypted archives, multipart ZIP,
large ZIP64, RAR or 7z. Limits are shared across each entire job, including
nested work: 2 GiB processed uncompressed bytes, 10,000 entries (directories
included), five layers, 900 seconds, and a 16 MiB central directory checked
before Python allocates its entry list. Nested archive bytes count when copied
and their contents count again when extracted. These are safety limits, not a
promise that every 2 GiB archive will finish under the service resource cap.
One job runs at a time; a second submission is rejected until it finishes.

Jobs run on a worker thread in the unprivileged file backend, never a root
shell/subprocess. The page may close or minimize without stopping the job.
The UI shows actual processed bytes/entries, cancellation and result links,
not an invented completion percentage. A destination identity change or source
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
are reserved. Duplicate/unsafe ZIP entries fail the job, independently of the
outer-name collision policy. Job history bounds path and name lengths. Files
and DAV still share the downloads UID: this is not isolation from a trusted
host administrator or another process running as that UID.

### API

All endpoints retain the file backend's allowed-Host and `X-Konsol: 1` gates.

| Endpoint | Contract |
|---|---|
| `GET /api/archives` | `{items, limits}` including persisted terminal jobs |
| `POST /api/archives` | `{operation, path, names, target, name, nested, layers, conflict}`; relative paths; returns 202 `{job}` |
| `POST /api/archives/cancel` | `{id}`; cooperative cancellation, returns 202 |

`operation` is `zip` or `unzip`; `conflict` is `rename`, `skip` or `stop`.
No operation accepts shell arguments, absolute paths or executable plugins.

## Verified boundary

See `../SESSION.md` for actual runs. v129 was upgraded/rerun/rebooted on Debian
13.7 `nrm`, with real Caddy/systemd/DAV/ZIP requests and browser App Store
qBittorrent lifecycle tests. Unit tests also cover malformed ZIPs, resource
limits and interrupted-job recovery. A fresh Ubuntu install, native Finder/
Infuse clients and recipient ACL certification were not performed for v129.
