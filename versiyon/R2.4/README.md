# `R2.4` — Debian 13 media server, one script

This folder installs a complete, self-contained media and file server onto a
**fresh Debian 13 (trixie)** machine. Everything below is set up by a single
script; there is nothing else to download and nothing to configure by hand
afterwards except the passwords listed under **Do these first**.

| | |
|---|---|
| Release | `R2.4` — the current full release of this branch |
| Version the script reports | `2026.08.02-Q1-15` |
| SHA256 | `7e2be32d0ff4db59da4ea02badf7088f524900258c2ad877f2bbab3a53a0c5f1` |
| Tags | `R2.4`, `Q1-15` — both name this exact file |
| Web file manager | FileBrowser Quantum |
| Branch | `quantum` |

**Why two names for one file.** `R2.4` is the release; `Q1-15` is the
revision of the installer inside it. They are byte-for-byte the same
script, so the install will print `2026.08.02-Q1-15` rather than `R2.4`.
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

## What this release was checked against

This exact script was installed onto a **freshly reimaged Debian 13
server** before `R2.4` was tagged — a real first-time install, browser
login included, not a repeat run on an already-working machine. It then
had a second, repeat run to confirm re-running is safe. Both finished all
seven stages; the server's own self-check reported no problems, no failed
services and all five containers running. The two warnings it raised were
that the VPN server's and the file manager's first-time setup had not been
done yet — both true, and both are the **Do these first** items above.

## What changed since `R2.3`

One fix, and it is the reason this release exists.

**The install could get stuck forever at the Tailscale login step.** It
happened on a real install. The sequence that causes it is easy to fall
into: the login link appears, you take a moment, you restart the installer
thinking something went wrong — and that quietly kills the link the server
is still waiting for. From then on the server waits for a link that no
longer exists, *and keeps showing it to you as though it were live*. You
log in, nothing happens, and there is no error anywhere. The only way out
was to know the exact command to restart the Tailscale service by hand.

Now the installer gives up waiting after five minutes, resets the service
itself, and prints a **new** link — up to three times — telling you plainly
that the old link is dead and that opening an old browser tab will kill the
new one too. If all three fail it prints the manual recovery steps rather
than sitting there silently.

The advice that used to be only in this README is now enforced by the
script: open the link when it appears, and do not restart the installer
while it is waiting.

Earlier in this line: the file manager was replaced with FileBrowser
Quantum, its security settings became self-repairing, the extraction
tool's log file stopped growing without limit, the network drive notices
finished downloads within a minute instead of five, and the disk check
watches for running out of file slots as well as space.
