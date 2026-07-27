#!/usr/bin/env bash
# Extracts install.sh's embedded heredoc scripts and lints each one with
# bash -n + shellcheck independently. `bash -n install.sh` and
# `shellcheck install.sh` never see this content on their own, since it's
# heredoc string data from the outer script's point of view, not parsed
# bash — see SECURITY_REVIEW.md finding H4. This script only performs
# static analysis; it never executes install.sh or any extracted script.
set -Eeuo pipefail

INSTALL_SH="${1:-install.sh}"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "HATA: $INSTALL_SH bulunamadı." >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# name:marker — one entry per embedded bash script heredoc in install.sh.
# Update this list if a new embedded script is added (the other heredocs
# in install.sh write YAML/INI/plain-text config, not bash, and are out
# of scope for shellcheck).
SCRIPTS=(
    "tailscale-udp-gro:GRO_SCRIPT"
    "docker-tailscale-fw:FW_SCRIPT"
    "master-compose-ipv4:IP_REFRESH_SCRIPT"
    "master-network-reconcile:RECONCILE_SCRIPT"
    "master-docker-netfilter-recovery:CORE_RECOVERY_SCRIPT"
    "caddy-tailnet-env:CADDY_ENV_SCRIPT"
)

# SC2016 fires on every single-quoted awk program passed to `awk`/`gawk`
# (e.g. '$1 == "-A" {...}') because it can't tell that literal $1 there is
# awk's own field syntax, not an un-expanded bash variable. All of this
# script's embedded scripts intentionally single-quote awk programs for
# exactly that reason, so SC2016 is excluded here to keep output
# actionable; every other check still applies at full severity.
SHELLCHECK_EXCLUDE="SC2016"

overall_rc=0
for entry in "${SCRIPTS[@]}"; do
    name="${entry%%:*}"
    marker="${entry##*:}"
    outfile="$WORKDIR/$name.sh"

    sed -n "/<<'${marker}'\$/,/^${marker}\$/p" "$INSTALL_SH" |
        sed '1d;$d' >"$outfile"

    if [[ ! -s "$outfile" ]]; then
        echo "HATA: '$marker' işaretçisi $INSTALL_SH içinde bulunamadı (script adı değişmiş olabilir): $name" >&2
        overall_rc=1
        continue
    fi

    echo "=== $name ($(wc -l <"$outfile" | tr -d ' ') satır) ==="

    if ! bash -n "$outfile"; then
        echo "HATA: $name -> bash -n başarısız." >&2
        overall_rc=1
        continue
    fi

    if ! shellcheck --exclude="$SHELLCHECK_EXCLUDE" "$outfile"; then
        echo "HATA: $name -> shellcheck başarısız." >&2
        overall_rc=1
    fi
done

if [[ "$overall_rc" -eq 0 ]]; then
    echo
    echo "Tüm gömülü script'ler temiz."
else
    echo
    echo "HATA: bir veya daha fazla gömülü script'te sorun var." >&2
fi

exit "$overall_rc"
