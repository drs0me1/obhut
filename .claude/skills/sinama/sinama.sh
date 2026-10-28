#!/usr/bin/env bash
# Obhut's local check round (Data/tests/README.md): static checks with the generated files' and the Konsol build's
# freshness, bats, the Python unit tests, every Konsol browser suite with the layout audit and the sign-in page.
#
#   .claude/skills/sinama/sinama.sh [statik] [bats] [python] [arayuz]      (no argument: every part)
#
# One line per part; each part's output goes to a fresh temporary folder, printed at the end. On macOS the eight
# Python failures Data/tests/README.md names are told apart; any other failure fails the round (exit 1).
set -u
root="$(cd "$(dirname "$0")/../../.." && pwd -P)"
data="$root/Data"
tmp="${TMPDIR:-/tmp}"
out="$(mktemp -d "${tmp%/}/obhut-sinama.XXXXXX")"
parts=" ${*:-statik bats python arayuz} "
failed=0
want() { [[ "$parts" == *" $1 "* ]]; }
line() { printf '%-6s %s\n' "$1" "$2"; }
pass() { line "TAMAM" "$1"; }
fail() { failed=1; line "HATA" "$1"; }
py=python3.13
command -v "$py" >/dev/null 2>&1 || py=python3
cd "$data" || exit 1

if want statik; then
    log="$out/statik.log"
    ok=1
    for f in install.sh common.sh scripts/* ../kur.sh ../*.command; do
        bash -n "$f" >>"$log" 2>&1 || { ok=0; echo "bash -n: $f" >>"$log"; }
    done
    shellcheck -x -s bash install.sh common.sh scripts/* ../kur.sh >>"$log" 2>&1 || ok=0
    "$py" -m py_compile panel/*.py panel/master-panel files-panel/master-files-panel >>"$log" 2>&1 || ok=0
    if [[ $ok == 1 ]]; then pass "statik: bash -n, shellcheck, py_compile"; else fail "statik: bash -n, shellcheck ya da py_compile ($log)"; fi
    # The two generated files and the committed build must match their sources.
    if "$py" panel/master_api.py openapi | cmp -s - docs/konsol-api.json &&
        "$py" panel/master_api.py ts | cmp -s - tools/konsol-ui/src/api/sema.ts; then
        pass "statik: konsol-api.json ve sema.ts yol tablosuyla aynı"
    else
        fail "statik: konsol-api.json ya da sema.ts eski (python3 panel/master_api.py openapi|ts)"
    fi
    if [[ "$(sh tools/konsol-ui/kaynak-ozeti.sh)" == "$(cat console/yeni/kaynak.sha256)" ]]; then
        pass "statik: Konsol derlemesi kaynaklarıyla aynı"
    else
        fail "statik: Konsol derlemesi eski (cd tools/konsol-ui && npm run derle)"
    fi
    if [[ -d tools/konsol-ui/node_modules ]]; then
        if (cd tools/konsol-ui && npx --no-install vue-tsc --noEmit) >>"$log" 2>&1; then pass "statik: vue-tsc"; else fail "statik: vue-tsc ($log)"; fi
    else
        line "ATLA" "statik: vue-tsc (tools/konsol-ui'de önce npm ci)"
    fi
fi

if want bats; then
    log="$out/bats.log"
    LC_ALL=C bats tests >"$log" 2>&1
    rc=$?
    summary="$(grep -cE '^ok ' "$log") ok, $(grep -cE '^not ok ' "$log") not ok"
    if [[ $rc == 0 ]]; then pass "bats: $summary"; else fail "bats: $summary ($log)"; fi
fi

if want python; then
    log="$out/python.log"
    "$py" -m unittest discover -s tests -p 'test_*.py' >"$log" 2>&1
    rc=$?
    ran="$(grep -m1 -E '^Ran [0-9]+ tests' "$log")"
    # Data/tests/README.md's eight macOS-only failures, by name: nothing else may fail.
    known=" test_text_edit.TextEditTests.test_a_failed_write_removes_the_temporary_file
        test_text_edit.TextEditTests.test_a_swap_between_the_check_and_the_rename_is_refused
        test_text_edit.TextEditTests.test_extended_attributes_are_copied
        test_text_edit.TextEditTests.test_legacy_encodings_are_written_back_and_unencodable_text_is_refused
        test_text_edit.TextEditTests.test_line_endings_and_utf8_bom_are_kept
        test_text_edit.TextEditTests.test_save_replaces_the_file_atomically_and_keeps_its_metadata
        test_system_files.SystemGateTests.test_text_save_through_the_handler
        test_onar.RepairTests.test_address_change_hands_over_to_refresh_tailnet_config "
    unknown=()
    while IFS= read -r id; do
        [[ "$(uname -s)" == Darwin && "$known" == *[[:space:]]"$id"[[:space:]]* ]] && continue
        unknown+=("$id")
    done < <(sed -nE 's/^(FAIL|ERROR): [^ ]+ \(([^)]+)\)$/\2/p' "$log")
    if [[ ${#unknown[@]} == 0 && ( $rc == 0 || "$(uname -s)" == Darwin ) ]] && grep -qE '^(OK|FAILED)' "$log"; then
        pass "python: $ran$([[ $rc != 0 ]] && echo ', yalnız macOS'"'"'un bilinen hataları')"
    else
        fail "python: $ran; beklenmeyen: ${unknown[*]:-çıktıya bakın} ($log)"
    fi
fi

if want arayuz; then
    export PLAYWRIGHT_MODULE="${PLAYWRIGHT_MODULE:-$(npm root -g 2>/dev/null)/playwright}"
    if [[ -z "${PLAYWRIGHT_CHROMIUM:-}" ]]; then
        for shell in "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/*/chrome-headless-shell; do
            [[ -x "$shell" ]] && export PLAYWRIGHT_CHROMIUM="$shell"
        done
    fi
    if [[ ! -d "$PLAYWRIGHT_MODULE" ]]; then
        fail "arayüz: Playwright yok ($PLAYWRIGHT_MODULE)"
    else
        for suite in tests/yeni-*.cjs; do
            name="$(basename "$suite" .cjs)"
            [[ "$name" == yeni-harness ]] && continue
            if node "$suite" >"$out/$name.log" 2>&1; then pass "arayüz: $name"; else fail "arayüz: $name ($out/$name.log)"; fi
        done
        # The sign-in page needs the installed layout served on 8766 (Data/tests/README.md).
        preview="$out/giris-onizleme"
        mkdir -p "$preview"
        cp -R console/yeni/. "$preview"/
        cp console/giris.html console/giris.js console/giris.css console/duzenleyici.js console/obhut.svg console/obhut.png "$preview"/
        "$py" -m http.server 8766 --bind 127.0.0.1 --directory "$preview" >"$out/giris-sunucu.log" 2>&1 &
        server=$!
        sleep 1
        if node tests/giris-ui.cjs >"$out/giris-ui.log" 2>&1; then pass "arayüz: giris-ui"; else fail "arayüz: giris-ui ($out/giris-ui.log)"; fi
        kill "$server" 2>/dev/null
    fi
fi

echo "Çıktılar: $out"
exit "$failed"
