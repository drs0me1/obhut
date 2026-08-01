# Exported installer revisions — `quantum` branch

One directory per exported revision. Each is self-contained: the frozen
export, a `deploy.sh` that copies and verifies it, a double-clickable
`deploy.command`, and (where present) a README.

| Directory | Version | Tags | Web file manager | Status |
|---|---|---|---|---|
| [`Q1-4/`](Q1-4/) | `2026.08.01-Q1-4` | `Q1`, `Q1-4` | `ghcr.io/gtsteffaniak/filebrowser:stable` | **Current on this branch** |
| [`V1-20/`](V1-20/) | `2026.07.31-V1-20` | `V1-20`, `R2.0` | `filebrowser/filebrowser:v2` | Branch point, expires 2026-09-01 |

```sh
cd versiyon/Q1-4
./deploy.sh nrm --run
```

From Finder, double-click `deploy.command` instead.

> **This is not `master`.** `master` answered the filebrowser question with
> dufs (`V2-2` / `R2.1`, DD-26). This branch forked from `V1-20` and swaps
> only the web file manager for FileBrowser Quantum — see **DD-27**. The two
> lines are alternatives, not a sequence.

Every export is byte-identical to the tag it is named after:

```sh
git show Q1-4:install.sh | sha256sum
sha256sum Q1-4/install-Q1-4.sh
```

## Why the deploy scripts are duplicated

`deploy.sh` and `deploy.command` are **byte-identical copies** in every
version directory, not a shared script plus wrappers. Each directory has to
work when lifted out on its own, and a wrapper pointing at a parent breaks
the moment you copy one elsewhere.

That trades self-containment for a drift risk this repository has lost to
four times — the repair cooldown, `STACK_SCHEMA`, the architecture stage
table and the "fixed image" strings. The mitigation is that the copies are
*identical* rather than merely similar, so drift is one command away:

```sh
diff versiyon/V1-20/deploy.sh versiyon/Q1-4/deploy.sh
diff versiyon/V1-20/deploy.command versiyon/Q1-4/deploy.command
```

Any change to one copy must be applied to the others in the same commit.

## Adding a new export

```sh
mkdir versiyon/<TAG>
git show <TAG>:install.sh > versiyon/<TAG>/install-<TAG>.sh
chmod +x versiyon/<TAG>/install-<TAG>.sh
cp versiyon/Q1-4/deploy.sh versiyon/<TAG>/deploy.sh
cp versiyon/Q1-4/deploy.command versiyon/<TAG>/deploy.command
```

Keep **exactly one** `install-*.sh` per directory — `deploy.sh` refuses to
run otherwise, on purpose: a second file makes it silently ambiguous which
revision gets installed.
