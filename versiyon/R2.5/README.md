# `R2.5` — Debian 13 media server, one script

This folder installs a complete, self-contained media and file server onto a
**fresh Debian 13 (trixie)** machine. Everything below is set up by a single
script; there is nothing else to download and nothing to configure by hand
afterwards except the passwords listed under **Do these first**.

| | |
|---|---|
| Release | `R2.5` — the current full release of this branch |
| Version the script reports | `2026.08.02-Q1-20` |
| SHA256 | `1762703ecc28e765e454ae32d05a08d3e82a1962734656384a0da12b3a416bb9` |
| Tags | `R2.5`, `Q1-20` — both carry this exact installer |
| Web file manager | FileBrowser Quantum |
| Branch | `quantum` |

**Why two names for one file.** `R2.5` is the release; `Q1-20` is the
revision of the installer inside it. They are byte-for-byte the same
script, so the install will print `2026.08.02-Q1-20` rather than `R2.5`.
That is expected, not a mismatch — the version string identifies the
script, and this is the release that ships it.

## Installing

Double-click **`deploy.command`** in Finder. It asks which server to send
the installer to, copies it there, checks that it arrived intact, and can
start the installation for you.

From a terminal, the same thing:

```sh
./deploy.sh nrm          # copy and verify only
./deploy.sh nrm --run    # copy, verify, and start the install
```

The install asks a handful of questions and then runs on its own for a few
minutes.

## What you end up with

- **A private network of your own.** The server joins your Tailscale
  network and acts as an exit node, so your laptop or phone can route its
  traffic through it from anywhere — no ports opened to the internet for
  any of the web interfaces below.
- **A web file manager** for browsing, uploading, renaming and sharing
  whatever is on the server.
- **A torrent client** with automatic extraction of finished downloads.
- **A VPN server** with a web interface for adding devices, for people you
  want to give access without adding them to your Tailscale network.
- **A container dashboard** for seeing what is running and restarting it.
- **A read-only network drive** the media tree can be mounted from — Infuse,
  VLC, Finder and Windows Explorer can all open it directly, including
  jumping to the middle of a video without downloading it first.
- **Friendly addresses** instead of IP numbers and port numbers:
  `file.ayc`, `qbit.ayc`, `wg.ayc`, `portainer.ayc`, `webdav.ayc` (the
  `ayc` part is yours to choose during install).
- **A firewall that is closed by default**, opening only what these
  services actually need.
- **Self-repair.** Every 20 minutes the server checks its own network
  settings, firewall, containers, security settings and disk, and quietly
  fixes what it can. What it cannot fix safely — a full disk, for instance
  — it reports instead of guessing.

## Do these first, right after installing

**1. Change the file manager password.** It ships with a working default
login of `admin` / `admin`. Until you change it, anyone on your Tailscale
network has full access to your files.

```
http://file.<your-domain>        admin / admin
```

**2. Set up the VPN and dashboard accounts.** `wg.<domain>` and
`portainer.<domain>` have no account at all until you create one on first
visit. Portainer in particular closes its setup window after a few minutes
and then needs a container restart before it will let you in — so visit it
early.

The server checks for the default file-manager password at most once per day
and writes a reminder to its own logs until you change it. Read-only status
commands never send a login request.

## Worth knowing

- **Open the Tailscale login link the moment it appears.** Partway through,
  the installer prints a link you need to open in a browser to authorise the
  server. Don't restart the installer while it's waiting — that invalidates
  the link and you'll see `410 auth path not found`.
- **Re-running is safe.** The script is designed to be run again on a server
  it already installed: it repairs drift, picks up newer container versions,
  and finishes an install that was interrupted. It will not wipe your data.
- **It only runs on Debian 13.** On anything else it refuses to start rather
  than half-work.
- **It takes over the machine's networking.** Firewall rules, IP forwarding
  and the Docker network configuration all become the script's to manage.
  Use a dedicated server, not one already doing something else.
- **The web interfaces are reachable only from your Tailscale network.**
  That is intentional. If you can't reach `file.ayc`, check that Tailscale is
  connected on the device you're using.
- **Your downloads and media survive reinstalls.** They live outside the
  containers.
- **Too many wrong logins lock the file manager's login page for a few
  minutes.** That is the file manager protecting itself, not a fault, and it
  clears on its own. It applies to everyone at once, because every browser
  reaches it through the same internal address.
- **The file manager warns once, on its very first start, that it could not
  find its database.** That is normal: on a brand-new install the database
  does not exist yet, and the next line says it is being created. It does
  not appear again.

## What this release was checked against

This exact script upgraded a healthy `R2.4` Debian 13 host and was then run a
second time unchanged. Both runs completed all seven stages. The second run
left all five container `StartedAt` values unchanged. Final state: Tailscale
`Running/Online`, no failed systemd units, all five containers up, and every
reconcile drift flag zero.

The release-specific recovery paths were also exercised deliberately. A
missing Compose file was restored from the verified canonical copy without
restarting containers; a manual content edit was preserved; bad metadata was
repaired; and a symlink failed closed. `--check` plus `--status` generated
zero FileBrowser login requests, while two normal reconcile runs generated
one request total and one daily stamp. Taking Tailscale down while leaving its
daemon active produced `Stopped/Offline`, a 30-second bounded wait, a non-zero
systemd result and explicit health diagnostics. Bringing the same node back
up and running recovery restored the same Tailscale IP, firewall and Docker
netfilter state, ending again at a clean check.

After release close-out, the same exported file was also run on the host after
a clean Debian 13 reimage. The real Tailscale browser link returned success to
the original waiting process, all seven stages completed, the node was
`Running/Online` and offering exit-node service, and the only install warning
was the expected unfinished wg-easy web setup. FileBrowser created
`/home/filebrowser/data/database.db` once on the persistent volume; a
controlled restart logged `Using existing database`. FileBrowser/Caddy
returned 200, WebDAV returned 401 without credentials and 200 with them, and
there were no failed units. An immediate unchanged full rerun needed neither a
new Tailscale login nor a WebDAV password, retained every container start time,
and again completed 7/7.

## What changed since `R2.4`

This release contains the five post-R2.4 review revisions, Q1-16 through
Q1-20:

- The canonical recovery bundle is now published as one verified atomic
  generation. A failed rerun cannot leave a mixture of old and new files.
- DNS/Caddy updates snapshot and restore their six managed paths until that
  canonical generation is committed.
- Deleted Tailscale nodes are classified without the intermittent
  `journalctl | grep -q`/pipefail inversion.
- FileBrowser policy replacement remains retryable across cooldowns and
  repairs Docker-created directory mounts without removing its data volume.
- Reconcile now reports persistent core/address failure as failure, while
  true lock/job overlap still defers cleanly. It prints Tailscale backend,
  online, health and key-expiry diagnostics without attempting an automatic
  browser login or broad core-daemon restart.
- A deleted `compose.yaml` is restored safely; operator content edits remain
  report-only and unsafe path types are never overwritten automatically.
- FileBrowser's default-password audit is normal-mode-only and daily, so
  `--check` and `--status` no longer consume the login rate limit.
- Host WebDAV now waits for the filesystem that contains the media tree.

The FileBrowser message about a newly created database is still normal on the
very first start: the configured database path is inside the persistent
`filebrowser_data` volume, but the file does not exist until Quantum creates
it. Live restarts during this release test logged `Using existing database`
and did not show the warning again.
