---
name: sinama
description: Runs Obhut's full local check round - static checks (bash -n, shellcheck, py_compile, the generated API files and the committed Konsol build checked against their sources, vue-tsc), bats, the Python unit tests with macOS's eight known failures told apart, every Konsol browser suite with the layout audit, and the sign-in page. Use before calling a change done or committing it, after changing the installer, the backends or Konsol.
---

# sinama: the local check round

`Data/tests/README.md` says what "done" needs: the static checks, `bats tests`, the Python unit tests with only
the known macOS failures, and the browser suites of every screen the change touches. This skill runs them all.

```bash
.claude/skills/sinama/sinama.sh                      # every part (about ten minutes)
.claude/skills/sinama/sinama.sh statik               # seconds: syntax, shellcheck, generated files, build, types
.claude/skills/sinama/sinama.sh statik bats python   # without the browser suites
```

- Run the whole round in the background (or with a long timeout) and wait for it; never poll it in a loop.
- Each part prints one line, `TAMAM`, `HATA` or `ATLA`, and the last line names the folder with every log.
  The exit status is 1 when anything failed.
- On `HATA`, read that part's log in the folder, fix the cause and run that part again. A stale generated file
  means its generator was not run: `python3 panel/master_api.py openapi > docs/konsol-api.json`, the same with
  `ts` for `tools/konsol-ui/src/api/sema.ts`, or `cd Data/tools/konsol-ui && npm run derle` for the build.
- Playwright comes from `$(npm root -g)/playwright`; on macOS the cached headless Chromium is used when
  `PLAYWRIGHT_CHROMIUM` is unset. The suites use fixed local ports (8766 to 8777); run one round at a time.
- Report what actually ran and its real outcome: the lines as printed, and for a failure the log's own words.
