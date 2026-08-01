# Rollback exports

Frozen copies of older `install.sh` revisions, kept so a known-good
version can be redeployed without a `git checkout`. Each file here is
byte-identical to the tag it is named after — verify with:

```sh
git show <tag>:install.sh | sha256sum
sha256sum versiyon/rollback/install-<tag>.sh
```

**These are deliberately outside `deploy.sh`'s glob.** That script matches
`versiyon/install-V*-*.sh` (non-recursive) and refuses to run unless
exactly one export is present — the guard exists so a stale artifact can
never be deployed by accident. Files in this directory don't trip it, and
are deployed explicitly by path instead (command below).

## `install-V1-20.sh`

| | |
|---|---|
| Tag | `V1-20` / `R2.0` (commit `d5e4881`) |
| Version | `2026.07.31-V1-20` |
| SHA256 | `06c9918a79dfcfce2e6c4571257c39d4803d65c221c956310b7d96b2f1aa2159` |
| Lines | 5305 |
| `STACK_SCHEMA` | 10 |

**The last revision that ships filebrowser** (`filebrowser/filebrowser:v2`).
`V2-1` replaced it with dufs — see **DD-26** for why.

Kept as a one-month safety net: filebrowser's upstream is archived on
**2026-09-01**, after which it receives no releases and no security
fixes, and three of its advisories are already permanently unpatched
(one critical). After that date this file is a historical artifact, not a
rollback option.

### Clean install only — do not downgrade a running host

`V1-20` writes and expects `STACK_SCHEMA=10`. A host currently running
`V2-2` has schema 11, and `V1-20`'s reconcile rejects it outright with
"Canonical master-stack state içeriği geçersiz". There is no supported
in-place downgrade; reimage first.

Two further consequences of rolling back:

- **Credentials.** `V1-20` doesn't know about `dufs.auth`. It preserves
  `webdav.htpasswd` if present, so on a reimaged host you will be asked
  for the WebDAV credential exactly once, as normal.
- **filebrowser's admin password.** Its named volumes were removed on
  2026-08-01, so filebrowser initialises fresh and prints a randomly
  generated admin password to its container log on first start:
  `docker logs filebrowser | grep 'randomly generated password'`.

### Deploying it

```sh
scp -o ClearAllForwardings=yes versiyon/rollback/install-V1-20.sh nrm:/root/master.sh
ssh -o ClearAllForwardings=yes nrm 'sha256sum /root/master.sh'   # must match the table above
ssh -t -o ClearAllForwardings=yes nrm 'bash /root/master.sh'
```

`ClearAllForwardings=yes` is required: the `nrm` host entry in
`~/.ssh/config` carries five `LocalForward` directives plus
`ExitOnForwardFailure yes`, so the connection fails outright if any of
those local ports is already bound.

Open the Tailscale login link the moment it appears and leave the session
alone — restarting the installer generates a new nodekey and invalidates
the pending auth path with `410 auth path not found`.
