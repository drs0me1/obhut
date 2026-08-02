# `Q1-13` — Debian 13 media server, one script

This folder installs a complete, self-contained media and file server onto a
**fresh Debian 13 (trixie)** machine. Everything below is set up by a single
script; there is nothing else to download and nothing to configure by hand
afterwards except the passwords listed under **Do these first**.

| | |
|---|---|
| Version | `2026.08.02-Q1-13` |
| Tags | `Q1-13`, `R2.3` (the `Q1` line marker still points at `Q1-11`; moving it means deleting and recreating it, so it is only done when asked) |
| SHA256 | `f483546a47040886104de5a0b1f2db33df3aae2a89fbc9d30904be0373fba322` |
| Web file manager | FileBrowser Quantum |
| Branch | `quantum` |

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

The server will keep reminding you about the file manager password every 20
minutes in its own logs until you change it.

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

## What changed since `Q1-11`

Both changes are about the server staying tidy on its own over months, not
about anything you interact with:

- **The extraction tool's log file no longer grows forever.** It kept a
  second copy of its log inside your media folder with no size limit — about
  145 MB a year, quietly, on a machine meant to run unattended. It is now
  capped and rotated, the same way the container logs already were.
- **That tool also stopped writing two status lines a minute** when there is
  nothing to do. Real activity — an archive being found, extracted and
  finished — is still logged in full; only the idle pulse is gone, so the
  log is readable when you actually need it.
- **The file manager's database location is now written down explicitly**
  rather than inherited from the container image. Nothing moves; this only
  removes a way a future image update could break the server silently.

Earlier in this line: the file manager was replaced with FileBrowser
Quantum, its security settings became self-repairing, the network drive
notices finished downloads within a minute instead of five, and the disk
check watches for running out of file slots as well as space.

## A note on `R2.3`

`R2.3` marks the same installer as `Q1-13` — the file in this folder is
byte-for-byte what `Q1-13` shipped. What it records is that the revision
was closed out afterwards, not that the installer changed: it was verified
against a real server before tagging, this folder was created, and the
project's own documentation was resynced against the script. Nothing you
install or operate is different from `Q1-13`.
