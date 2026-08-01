# Exported installer revisions

One directory per exported revision of `install.sh`. Each is
self-contained: the frozen export, a `deploy.sh` that copies and verifies
it, and a README covering what changed and what to watch for.

| Directory | Version | Tags | Web file manager | Status |
|---|---|---|---|---|
| [`V2-2/`](V2-2/) | `2026.08.01-V2-2` | `V2-2`, `R2.1` | `sigoden/dufs:v0.46.0` | **Current — deploy this** |
| [`V1-20/`](V1-20/) | `2026.07.31-V1-20` | `V1-20`, `R2.0` | `filebrowser/filebrowser:v2` | Rollback, expires 2026-09-01 |

```sh
cd versiyon/V2-2
./deploy.sh nrm --run
```

From Finder, double-click `deploy.command` in either directory instead —
macOS runs `.command` files in Terminal, and it prompts for the host and
whether to start the install. It is a thin wrapper around `deploy.sh`,
which stays the canonical interface.

Every export is byte-identical to the tag it is named after:

```sh
git show V2-2:install.sh | sha256sum
sha256sum V2-2/install-V2-2.sh
```

## Why the deploy scripts are duplicated

`V1-20/deploy.sh` and `V2-2/deploy.sh` are **byte-identical copies**, not
a shared script and a wrapper. Each version directory has to work when
lifted out on its own, and a wrapper pointing at a parent breaks the
moment you copy one directory to another machine.

That buys self-containment at the cost of a drift risk, which this
repository has an unhappy history with — the repair cooldown,
`STACK_SCHEMA`, the architecture stage table and the "fixed image" strings
all drifted the same way. The mitigation here is that the two files are
*identical* rather than merely similar, so drift is one command away from
being caught:

```sh
diff versiyon/V1-20/deploy.sh versiyon/V2-2/deploy.sh
diff versiyon/V1-20/deploy.command versiyon/V2-2/deploy.command
```

The same applies to `deploy.command`. Any change to one copy must be
applied to the other in the same commit.

## Adding a new export

```sh
mkdir versiyon/<TAG>
git show <TAG>:install.sh > versiyon/<TAG>/install-<TAG>.sh
chmod +x versiyon/<TAG>/install-<TAG>.sh
cp versiyon/V2-2/deploy.sh versiyon/<TAG>/deploy.sh
cp versiyon/V2-2/deploy.command versiyon/<TAG>/deploy.command
```

Then write the directory's README and add a row to the table above. Keep
**exactly one** `install-V*-*.sh` per directory — `deploy.sh` refuses to
run otherwise, on purpose: a second file makes it silently ambiguous which
revision gets installed, and silent ambiguity is the failure mode this
project keeps paying for.
