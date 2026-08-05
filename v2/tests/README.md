# v2 tests

Narrow critical-behaviour suite for the lean v2 tree. Not a framework
coverage suite.

```bash
bats v2/tests
bash -n v2/install.sh v2/common.sh v2/scripts/*.sh
shellcheck -x -s bash v2/install.sh v2/common.sh v2/scripts/*.sh
```

Host acceptance (Debian 13 target, after install) is separate: DNS loopback
vs Tailscale answers, WebDAV PROPFIND/read-only, firewall `--check`, and
the two public UDP ports.
