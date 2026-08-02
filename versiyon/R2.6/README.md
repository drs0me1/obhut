# `R2.6` — Debian 13 media server, manual-test export

This folder installs a complete, self-contained media and file server onto a
**fresh Debian 13 (trixie)** machine. Everything below is set up by a single
script; there is nothing else to download and nothing to configure by hand
afterwards except the passwords listed under **Do these first**.

| | |
|---|---|
| Release | `R2.6` — tagged for manual testing; **not yet live-verified** |
| Version the script reports | `2026.08.02-Q1-22` |
| SHA256 | `32b0f085c9515f25f70988bc2171da30d1e659ed243931866d42c23caa62df2e` |
| Tags | `R2.6`, `Q1-22` — both name this exact file |
| Web file manager | FileBrowser Quantum |
| Branch | `quantum` |

**Why two names for one file.** `R2.6` is the release; `Q1-22` is the
revision of the installer inside it. They are byte-for-byte the same script,
so the install prints `2026.08.02-Q1-22`, not `R2.6`.

**Read this before trusting the tag.** Every other release on this branch was
tagged only after it had been installed on a real server. This one was tagged
first, at the operator's explicit request, so it can be carried to a machine
and tested by hand. **No successful install has been observed for it.** The
static checks are clean and every changed path has unit coverage, but that is
not the same claim. Treat it as a candidate until you have run it yourself.

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
  server. If the measured persistent 410/offline state survives three
  consecutive checks, this revision restarts tailscaled and prints a fresh
  link instead of waiting the full five minutes. Use only the newest link;
  do not restart the installer while it is waiting.
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

## What this export was checked against

**Not a live install.** What has been done: the project's full static
verification is clean (syntax, shellcheck, the seven embedded helper scripts,
and 176 unit tests), and each behaviour changed since `R2.5` has a unit test
that was checked to actually fail against the old behaviour — so the tests are
not decoration. What has **not** been done is running this file on a server.

The two changes below were the reason `R2.5` needed a successor, and the first
of them was itself measured on a real host before being written; only the
automatic recovery branch and the `Q1-22` correction remain unobserved in a
real run.

## What changed since `R2.5`

- Persistent `NeedsLogin`/offline/empty-ID/410 state is sampled from
  `tailscale status --json`. Three consecutive matches trigger an early
  tailscaled restart and a fresh browser link; any different sample resets
  the counter.
- After a successful login the installer checks, for up to 15 seconds, that
  the node really is `Running`, online, has a node ID and has an address. If
  it is, the install moves on immediately instead of waiting.
- **If that 15 seconds is not enough, nothing is thrown away.** An earlier
  draft of this release restarted the connection and asked you to authorize
  in the browser a second time — even though your first authorization had
  succeeded. It now says so and hands the waiting to the 180-second check
  that follows, which is where a genuinely unreachable node is reported. You
  will only ever be asked to authorize again if the link itself is dead.
- Fourteen regression cases cover the exact observed failure, unknown and
  incomplete states, transient 410 success, persistent recovery, sample reset
  and the slow-but-successful login above.

The FileBrowser new-database message remains normal only on the very first
start: the configured database path is inside the persistent
`filebrowser_data` volume, and the file does not exist until Quantum creates
it. A later start should report that it is using the existing database.
