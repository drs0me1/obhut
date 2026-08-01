# `V1-20` — rollback

**The last revision that ships filebrowser.** Kept as a safety net for the
dufs migration; `../V2-2/` is the current build and the one to deploy by
default.

| | |
|---|---|
| Tag | `V1-20` / `R2.0` (commit `d5e4881`) |
| Version | `2026.07.31-V1-20` |
| SHA256 | `06c9918a79dfcfce2e6c4571257c39d4803d65c221c956310b7d96b2f1aa2159` |
| Lines | 5305 |
| `STACK_SCHEMA` | 10 |
| Web file manager | `filebrowser/filebrowser:v2` |

Byte-identical to the tag. Verify at any time:

```sh
git show V1-20:install.sh | sha256sum
sha256sum install-V1-20.sh
```

## Shelf life ends 2026-09-01

filebrowser's upstream archives on that date — no further releases, no
security fixes, and three advisories already permanently unpatched
(critical `GHSA-6759-996p-gpj6`, high `GHSA-8c9q-7855-wfxq`, medium
`GHSA-v7vv-5wj2-gfcj`). After it passes, this directory is a historical
artifact rather than a rollback option. See **DD-26** for the full
reasoning behind the replacement.

None of the three were reachable on the host as configured — signup off,
shell/exec off, `Auth Method: json`, container on loopback, Caddy bound to
the Tailscale IPv4 alone. That is why the migration was scheduled rather
than urgent, and it is also why rolling back here is *currently* safe.

## Clean install only — do not downgrade a running host

`V1-20` writes and expects `STACK_SCHEMA=10`. A host running `V2-2` is on
schema 11, and `V1-20`'s reconcile rejects it outright with
`Canonical master-stack state içeriği geçersiz`. There is no supported
in-place downgrade path; reimage first.

Two further consequences:

- **Credentials.** `V1-20` knows nothing about `dufs.auth`. It preserves
  `webdav.htpasswd` if one exists, so on a reimaged host you are asked for
  the WebDAV credential exactly once, as normal. A leftover `dufs.auth`
  from a `V2-2` install is simply ignored.
- **filebrowser's admin password.** Its named volumes (`filebrowser_database`,
  `filebrowser_config`) were removed on 2026-08-01, so filebrowser
  initialises fresh and prints a randomly generated admin password to its
  container log on first start — it is *not* the Stage 0 credential:

  ```sh
  docker logs filebrowser | grep 'randomly generated password'
  ```

## Deploying

```sh
./deploy.sh nrm          # copy + verify the SHA256 on the host
./deploy.sh nrm --run    # copy + verify + start the install over SSH
```

The host argument defaults to `nrm`. This script is byte-identical to
`../V2-2/deploy.sh` — it reads whichever export sits beside it, so the
directory you run it from decides the version. `ClearAllForwardings=yes`
is set for you: the `nrm` entry in `~/.ssh/config` carries five
`LocalForward` directives plus `ExitOnForwardFailure yes`, so the
connection fails outright if any of those local ports is already bound.

From the provider console instead, after copying the file by hand:

```sh
bash /root/master.sh
```

**Open the Tailscale login link the moment it appears, then leave the
session alone.** Restarting the installer generates a new nodekey and
invalidates the pending auth path (`410 auth path not found`). A slow
login is waited out, not retried.
