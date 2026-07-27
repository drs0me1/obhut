# Installation Profiles

## Planned installation profiles

> **Status: proposed / not yet implemented.** `install.sh` currently
> deploys one fixed bundle of six services with no opt-out (finding
> **M3** in `SECURITY_REVIEW.md`). Everything in this document describes
> a design proposal for future work, not current behavior. Do not
> implement any part of this without first scoping it with the user (see
> `CLAUDE.md` — "Wait for approval before making changes").

### Motivation

The current bundle (Portainer, Filebrowser, qBittorrent, Unpackerr,
wg-easy, SFTPGo) mixes services with very different risk profiles into a
single all-or-nothing install:

- Portainer requires full `/var/run/docker.sock` access (see **C1**) —
  a user who doesn't want a Docker GUI still gets this exposure today.
- qBittorrent/Unpackerr process untrusted downloaded content and expose a
  public peer port.
- wg-easy exposes a public WireGuard port and needs elevated container
  capabilities (see **H1**).
- SFTPGo/Filebrowser are comparatively low-risk, Tailnet/loopback-only
  services.

A profile model would let an operator choose only the services they
actually need, reducing attack surface for the common case (e.g.
"I only want a VPN exit-node, not a media stack").

### Proposed profile concept

| Profile | Services included | Public exposure | Intended use case |
|---------|--------------------|------------------|--------------------|
| `full` (current default/behavior) | Portainer, Filebrowser, qBittorrent, Unpackerr, wg-easy, SFTPGo | qBittorrent peer port, wg-easy WireGuard port | Existing all-in-one behavior, preserved for backward compatibility |
| `vpn-only` | wg-easy | wg-easy WireGuard port | Exit-node + VPN only, no media/file stack, no `docker.sock` exposure |
| `media` | Filebrowser, qBittorrent, Unpackerr, SFTPGo | qBittorrent peer port | Media/download management without a Docker GUI or VPN admin surface |
| `minimal-secure` | wg-easy, SFTPGo | wg-easy WireGuard port | VPN + Tailnet-only file access, no Portainer, no public torrent port |

This table is a starting proposal, not a final spec — profile names,
boundaries, and inclusion lists should be confirmed with the user before
implementation.

### Profile comparison (risk-relevant differences)

| Concern | `full` | `vpn-only` | `media` | `minimal-secure` |
|---------|--------|-----------|---------|-------------------|
| `docker.sock` exposure (Portainer) | Yes | No | No | No |
| Public torrent peer port | Yes | No | Yes | No |
| Public WireGuard port | Yes | Yes | No | Yes |
| Untrusted-content processing (qBittorrent/Unpackerr) | Yes | No | Yes | No |
| Tailnet-only DNS/Caddy still optional in all profiles | Yes | Yes | Yes | Yes |

### Implementation sketch (not yet built)

If pursued, this would require changes across several parts of
`install.sh` that today assume a fixed set of six services:

1. **Stage 0**: an additional prompt (or a `--profile=` flag for
   non-interactive use, if that becomes supported) to select a profile
   before the existing questions.
2. **Compose generation** (`install.sh:1742-1887`): conditionally emit
   only the services in the selected profile, including their shared
   `x-logging` anchor and any cross-service dependencies (e.g. Unpackerr
   only makes sense alongside qBittorrent).
3. **`state.env` schema** (`install.sh:1711-1728`): record the selected
   profile so reconcile and re-runs know which services *should* exist.
4. **Reconcile's `expected_containers`** (`install.sh:2514-2515`) and all
   downstream port/health checks: must be derived from the recorded
   profile rather than hardcoded to all six services.
5. **Firewall rules**: public-port allow rules (qBittorrent, wg-easy) must
   be conditional on whether those services are part of the selected
   profile.
6. **Stage 7 verification**: all per-service assertions
   (`assert_docker_binding`, endpoint probes, etc.) must be scoped to the
   active profile.

### Open questions

- How should switching profiles on an existing host be handled — is it
  supported at all, or does changing profiles require a fresh install?
- Should Portainer become a profile of its own (opt-in "GUI" add-on) that
  can be layered onto any other profile, rather than a fixed member of
  only `full`?
- Does `minimal-secure` need its own hardened container defaults (see
  **M1** in `SECURITY_REVIEW.md`) as part of its definition, or is
  hardening orthogonal to profile selection?
- How much of Stage 0's existing question set (downloads path, local DNS)
  still applies unchanged across all profiles vs. needs to be
  profile-specific?

These should be resolved with the user before any implementation work
begins, per the scoping note in `TODO.md` (**M3**).
