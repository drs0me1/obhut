# `Q1-11` — Debian 13 media server, one script

This folder installs a complete, self-contained media and file server onto a
**fresh Debian 13 (trixie)** machine. Everything below is set up by a single
script; there is nothing else to download and nothing to configure by hand
afterwards except the passwords listed under **Do these first**.

| | |
|---|---|
| Version | `2026.08.02-Q1-11` |
| Tags | `Q1-11`, `R2.2`, and `Q1` (marks the head of this line) |
| SHA256 | `b3f32a7b821ed69d7288b2e3b0424823245e47f23b6b7cb25c0e3239c3d029c7` |
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
  `file.ayc`, `qbit.ayc`, `wg.ayc`, `portainer.ayc` (the `ayc` part is
  yours to choose during install).
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

## What changed since `Q1-8`

All three are about the self-repair loop being honest and thorough:

- **The file manager's security settings are now protected.** The file that
  holds them — including the switch that stops strangers signing themselves
  up — is now checked every 20 minutes and put back if anything changes it.
  Previously it could be edited and nothing would notice.
- **The default-password reminder no longer gets in its own way.** It used
  to try the login several times per check, which could trip the file
  manager's own lockout and then read that lockout as "all fine". It now
  tries once, and if it is locked out it says so instead of staying quiet.
- **A miscount in the install output was fixed** — it said six containers
  where five are installed.

Earlier in this line: the file manager was replaced with FileBrowser
Quantum, the network drive now notices finished downloads within a minute
instead of five, and the disk check learned to watch for running out of
file slots as well as space.

## A note on `R2.2`

`R2.2` marks the same installer as `Q1-11` — the file in this folder is
byte-for-byte what `Q1-11` shipped. What it records is that the checks
around the installer were tightened afterwards, not that the installer
changed: there is now an automatic guard against a managed file being left
out of the self-repair loop, unit coverage grew from 79 to 120 cases, and
a single command runs every verification the project has. Nothing you
install or operate is different.
