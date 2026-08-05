#!/usr/bin/env bash
# Host WebDAV: yalnız güncel Tailscale IPv4 üzerinde, salt okunur rclone.
set -Eeuo pipefail
umask 077

: "${DOWNLOADS_PATH:?DOWNLOADS_PATH tanımlı değil}"
: "${WEBDAV_PORT:?WEBDAV_PORT tanımlı değil}"
: "${CREDENTIALS_DIRECTORY:?systemd LoadCredential dizini yok}"
: "${TAILSCALE_IF:=tailscale0}"

WAIT_SECONDS="${WEBDAV_ADDR_WAIT_SECONDS:-120}"
deadline=$((SECONDS + WAIT_SECONDS))
ts_ipv4=""

while [[ "$SECONDS" -lt "$deadline" ]]; do
    ts_ipv4="$(
        ip -4 -o addr show dev "$TAILSCALE_IF" scope global 2>/dev/null |
            awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }'
    )" || true
    if [[ "$ts_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        break
    fi
    ts_ipv4=""
    sleep 1
done

[[ -n "$ts_ipv4" ]] || {
    printf 'HATA: %s IPv4 adresi %ss içinde oluşmadı.\n' "$TAILSCALE_IF" "$WAIT_SECONDS" >&2
    exit 1
}

htpasswd_file="$CREDENTIALS_DIRECTORY/htpasswd"
[[ -r "$htpasswd_file" ]] || {
    printf 'HATA: htpasswd credential okunamıyor.\n' >&2
    exit 1
}

printf 'WebDAV: %s:%s -> %s (salt okunur)\n' "$ts_ipv4" "$WEBDAV_PORT" "$DOWNLOADS_PATH"
exec rclone serve webdav "$DOWNLOADS_PATH" \
    --config /dev/null \
    --addr "${ts_ipv4}:${WEBDAV_PORT}" \
    --htpasswd "$htpasswd_file" \
    --dir-cache-time 1m \
    --read-only
