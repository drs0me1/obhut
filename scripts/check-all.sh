#!/usr/bin/env bash
# Runs every static verification this repository has, in one command.
#
# There is no CI and there will not be one while the repository stays
# local with no remote (see M7), so these four checks are run by hand
# before every change. Running them one at a time is four round trips and
# an easy place to skip the slow one; this is the local substitute.
#
# Static analysis only — install.sh is never executed, and nothing here
# touches a real host.
#
# Deliberately does NOT stop at the first failure. The point of one
# command is one complete picture; an early exit would put the operator
# back to running them individually to find out what else is broken.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL_SH="install.sh"
TEST_DIR="test"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASSED=0
FAILED=0
UNVERIFIED=0
declare -a SUMMARY=()

# A check whose tool is missing is reported as "doğrulanamadı", never as a
# pass, and it makes the overall result non-zero. A verification that
# fails open is worse than one that does not exist, because a green run is
# what gets trusted — the same reasoning as DD-33's 429 branch.
missing_tool() {
    local label="$1" tool="$2"
    UNVERIFIED=$((UNVERIFIED + 1))
    SUMMARY+=("DOĞRULANAMADI  $label  ($tool kurulu değil)")
    printf '  ATLANDI — %s bulunamadı, bu adım DOĞRULANMADI\n' "$tool"
}

run_check() {
    local label="$1"
    shift
    local logfile="$WORKDIR/$((PASSED + FAILED + UNVERIFIED)).log"

    if "$@" >"$logfile" 2>&1; then
        PASSED=$((PASSED + 1))
        SUMMARY+=("TAMAM          $label")
        printf '  tamam\n'
        return 0
    fi

    FAILED=$((FAILED + 1))
    SUMMARY+=("HATA           $label")
    printf '  HATA — çıktı:\n'
    sed 's/^/  | /' "$logfile"
    return 1
}

printf '=== 1/4  bash -n %s\n' "$INSTALL_SH"
run_check "bash -n $INSTALL_SH" bash -n "$INSTALL_SH" || true

printf '=== 2/4  shellcheck %s\n' "$INSTALL_SH"
if command -v shellcheck >/dev/null 2>&1; then
    run_check "shellcheck $INSTALL_SH" shellcheck "$INSTALL_SH" || true
else
    missing_tool "shellcheck $INSTALL_SH" shellcheck
fi

printf '=== 3/4  scripts/lint-embedded-scripts.sh\n'
if command -v shellcheck >/dev/null 2>&1; then
    # Lints the seven bash heredocs neither of the checks above can see:
    # from the outer script's point of view they are string data, not
    # parsed bash (H4).
    run_check "gömülü script lint" ./scripts/lint-embedded-scripts.sh || true
else
    missing_tool "gömülü script lint" shellcheck
fi

printf '=== 4/4  bats %s\n' "$TEST_DIR"
if command -v bats >/dev/null 2>&1; then
    BATS_LOG="$WORKDIR/bats.log"
    if bats "$TEST_DIR" >"$BATS_LOG" 2>&1; then
        PASSED=$((PASSED + 1))
        ok_count="$(grep -cE '^ok ' "$BATS_LOG" || true)"
        skip_count="$(grep -c '# skip' "$BATS_LOG" || true)"
        if [[ "$skip_count" -gt 0 ]]; then
            # Several suites self-skip where the workstation lacks GNU
            # stat/timeout or runs bash 3.2. Surfacing the count keeps a
            # green local run from reading as full coverage — all of them
            # run for real on the Debian target.
            SUMMARY+=("TAMAM          bats: $ok_count geçti, $skip_count atlandı")
            printf '  tamam — %s geçti, %s atlandı (bu iş istasyonunda; hedefte hepsi koşar)\n' \
                "$ok_count" "$skip_count"
        else
            SUMMARY+=("TAMAM          bats: $ok_count geçti, atlama yok")
            printf '  tamam — %s geçti, atlama yok\n' "$ok_count"
        fi
    else
        FAILED=$((FAILED + 1))
        SUMMARY+=("HATA           bats $TEST_DIR")
        printf '  HATA — düşen testler:\n'
        grep -E '^not ok ' "$BATS_LOG" | sed 's/^/  | /' || true
        printf '  Tam çıktı için: bats %s\n' "$TEST_DIR"
    fi
else
    missing_tool "bats $TEST_DIR" bats
fi

printf '\n=== Özet\n'
for line in "${SUMMARY[@]}"; do
    printf '  %s\n' "$line"
done

printf '\n'
if [[ "$FAILED" -eq 0 && "$UNVERIFIED" -eq 0 ]]; then
    printf 'Dört kontrol de temiz.\n'
    exit 0
fi

if [[ "$FAILED" -gt 0 ]]; then
    printf 'HATA: %s kontrol başarısız' "$FAILED" >&2
    [[ "$UNVERIFIED" -gt 0 ]] &&
        printf ', %s kontrol doğrulanamadı' "$UNVERIFIED" >&2
    printf '.\n' >&2
else
    printf 'HATA: %s kontrol doğrulanamadı; eksik araçları kurmadan\n' \
        "$UNVERIFIED" >&2
    printf 'bu çalıştırma "temiz" sayılmaz.\n' >&2
fi
exit 1
