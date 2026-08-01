# `V1-20` — the fallback revision

Same server as `Q1-8`, with the **original filebrowser** as its web file
manager. This is the point both current lines branched from, kept so there
is something known-good to fall back to.

| | |
|---|---|
| Version | `2026.07.31-V1-20` |
| Tags | `V1-20`, `R2.0` |
| SHA256 | `06c9918a79dfcfce2e6c4571257c39d4803d65c221c956310b7d96b2f1aa2159` |
| Web file manager | filebrowser (original) |
| Branch | branch point for `master` and `quantum` |

> **Install `Q1-8` instead unless you specifically need this one.** The
> file manager here is on a container image its authors have stopped
> updating, and it is expected to stop working after **2026-09-01**.
> Everything else is a few revisions behind as well.

## Installing

Double-click **`deploy.command`** in Finder. It asks which server to send
the installer to, copies it there, checks that it arrived intact, and can
start the installation for you.

From a terminal, the same thing:

```sh
./deploy.sh nrm          # copy and verify only
./deploy.sh nrm --run    # copy, verify, and start the install
```

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
  settings, firewall, containers and disk, and quietly fixes what it can.

## Do these first, right after installing

**Create your accounts.** Unlike `Q1-8`, the file manager here has no
default login — `file.<domain>`, `wg.<domain>` and `portainer.<domain>` all
ask you to create an account on first visit. Do it promptly: Portainer
closes its setup window after a few minutes and then needs a container
restart before it will let you in.

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
- **The file manager logs a deprecation warning on every start.** That is
  the reason this revision was replaced, and it is not something you can fix
  from here.

## Where the two lines went from here

Both replaced the file manager, and only the file manager — everything else
in the server is the same in all three:

| | Web file manager | Where |
|---|---|---|
| `V1-20` | filebrowser (original), deprecated | this folder |
| `Q1-8` | FileBrowser Quantum — full-featured, ships with `admin`/`admin` | [`../Q1-8/`](../Q1-8/) |
| `V2-2` | dufs — plainer interface, no accounts, no database | `master` branch |
