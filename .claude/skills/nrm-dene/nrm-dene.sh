#!/usr/bin/env bash
# Installs the working tree on the test host `nrm` the way kur.sh installs main (CLAUDE.md: standing
# authorization for nrm only; no server-side backup). The archive is shaped like GitHub's and holds only kur.sh's
# runtime items, read from kur.sh itself (so never the Git-ignored installer inputs); it goes with a copy of
# kur.sh to /tmp on nrm, and `sudo KUR_URL=file:///tmp/obhut-deneme.tgz bash /tmp/kur-deneme.sh` runs on a
# terminal with the re-run's default answers and "E" at the confirmation. A first install on a clean host asks
# the local domain: give it as $1.
#
#   .claude/skills/nrm-dene/nrm-dene.sh [domain]
#
# The installer's output goes to a log whose path is printed first; a first install stops at the Tailscale login.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd -P)"
tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${tmp%/}/obhut-nrm.XXXXXX")"
log="$work/kurulum.log"
echo "Günlük: $log"

items="$(sed -n 's/^ *local items="\(.*\)"$/\1/p' "$root/kur.sh")"
[[ -n "$items" ]] || { echo "kur.sh'ta çalışma dosyaları listesi bulunamadı" >&2; exit 1; }
mkdir -p "$work/obhut-deneme/Data"
# shellcheck disable=SC2086 # the item list is words
(cd "$root/Data" && COPYFILE_DISABLE=1 tar -cf - --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
    --exclude='._*' $items) | tar -xf - -C "$work/obhut-deneme/Data"
cp "$root/kur.sh" "$work/kur-deneme.sh"
COPYFILE_DISABLE=1 tar -C "$work" -czf "$work/obhut-deneme.tgz" obhut-deneme
echo "Arşiv: $(grep -m1 '^V2_VERSION=' "$work/obhut-deneme/Data/install.sh")"
scp -q "$work/obhut-deneme.tgz" "$work/kur-deneme.sh" nrm:/tmp/

answers=""
[[ -z "${1:-}" ]] || answers="$1"$'\n'
answers+=$'E\n'
set +e
printf '%s' "$answers" | ssh -tt nrm 'sudo KUR_URL=file:///tmp/obhut-deneme.tgz bash /tmp/kur-deneme.sh' >"$log" 2>&1
rc=$?
set -e
echo "Kurulum çıkış kodu: $rc"
ssh nrm 'sudo grep -h "^V2_VERSION=" /etc/master-stack/state.env' 2>/dev/null || true
exit "$rc"
