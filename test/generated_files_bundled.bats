#!/usr/bin/env bats
# Guards the invariant that produced Q1-9: every file install.sh generates
# is either in the canonical bundle or on an explicit, reasoned allowlist.
#
# Why this exists. `/etc/master-stack/filebrowser.yaml` — the file holding
# the web file manager's whole security policy, including the `signup:
# false` that closes GHSA-6759 — was generated on every install run and was
# in none of reconcile's checks. Editing it moved no signal at all
# (measured 2026-08-01: config=0, rc=0), and the change went live on the
# next container restart. Nothing caught the omission for the length of the
# `quantum` line, because nothing anywhere compares "files install.sh
# writes" against "files the bundle covers". `canonical_bundle.bats` checks
# that Stage 6's manifest and reconcile's expected list agree with each
# other — but two lists agreeing says nothing about what is missing from
# both.
#
# So this file compares against a third thing: install.sh's own write
# operations. Adding a generated file now fails the suite until it is
# either published into the bundle or added to the allowlist with a reason. The
# allowlist is the deliverable as much as the assertion is — it turns
# twenty-odd silent omissions into twenty-odd recorded decisions.
#
# Both sides are derived from install.sh's source rather than restated
# here, on the same principle as canonical_bundle.bats: a test that
# hardcodes what it is checking only ever confirms itself.

INSTALL_SH="${BATS_TEST_DIRNAME}/../install.sh"

# ---------------------------------------------------------------------------
# excluded_paths(): generated files that deliberately stay out of the bundle.
#
# Grouped by reason. Anything not listed here and not published into the
# bundle fails the first test below — that is the whole point. Removing a
# generated file without removing its line here fails the second test, so
# the list cannot rot into fiction.
# ---------------------------------------------------------------------------
# Emitted from a plain heredoc inside the function rather than assigned at
# the top level: bash 3.2 (this workstation) cannot parse a heredoc inside
# $( ), and every apostrophe below would become an unterminated quote.
excluded_paths() {
    cat <<'EXCLUDED_LIST' |
# Secret, or host-measured: a canonical copy would either duplicate a
# secret or pin a value that is legitimately different on every host.
# webdav.htpasswd is a bcrypt hash of the operator's password (C2, DD-29);
# .env carries the detected public IPv4 and friends.
/etc/master-stack/webdav.htpasswd
/root/docker/.env

# Not generated wholesale: install.sh asserts the .dns key with jq and
# preserves every other key the operator has set, so there is no canonical
# content to compare against. Validated instead by
# `dockerd --validate --config-file`.
/etc/docker/daemon.json

# The helper scripts reconcile itself runs, and the units that invoke them.
# M10's recorded reasoning: reconcile validates the firewall by invoking
# the very helper it would be hashing, which is near-theater, and the
# reconcile script cannot meaningfully verify itself. Their behaviour is
# checked by running them and asserting the result.
/usr/local/sbin/docker-tailscale-fw
/usr/local/sbin/master-compose-ipv4
/usr/local/sbin/master-docker-netfilter-recovery
/usr/local/sbin/master-network-reconcile
/usr/local/sbin/master-webdav-serve
/usr/local/sbin/tailscale-udp-gro
/etc/systemd/system/docker-tailscale-fw.service
/etc/systemd/system/master-compose.service
/etc/systemd/system/master-docker-netfilter-recovery.service
/etc/systemd/system/master-network-reconcile.service
/etc/systemd/system/master-network-reconcile.timer
/etc/systemd/system/master-webdav.service
/etc/systemd/system/tailscale-udp-gro.service

# Boot-time or apt-time system configuration whose *effect* reconcile
# checks directly, which is stronger than a hash: forwarding_config_ok()
# asserts the two lines that matter in 99-tailscale.conf and tolerates
# unrelated edits, forwarding_ok() reads the live sysctls, and
# gro_flags_ok() reads the live interface features.
/etc/sysctl.d/99-tailscale.conf
/etc/sysctl.d/99-master-stack-netbuf.conf
/etc/modules-load.d/wg-easy.conf
/etc/apt/sources.list.d/docker.sources

# Ordering/activation drop-ins that turn out to be redundant, measured
# 2026-08-02 rather than argued. Both were deleted from the target and the
# host was restarted and then rebooted: firewall policy still applied
# (docker-tailscale-fw --check rc 0), both units active, all five
# containers up, reconcile clean, zero failed units. The reason is in the
# units themselves, not in these files — docker-tailscale-fw.service and
# master-compose.service are enabled with WantedBy=multi-user.target, so
# boot pulls them regardless, and the firewall unit carries its own
# Requires=/After= on docker.service and tailscaled.service plus
# PartOf=docker.service, which is what makes it follow a Docker restart.
#
# The only thing the docker.service drop-in adds that nothing else does is
# RequiresMountsFor=$DOWNLOADS_PATH, and that is inert unless the download
# path is a separate mount (it is not on the test host). Bundling them
# would guard that one case; it is not guarding an exposure, because the
# web interfaces publish on 127.0.0.1 and reach the tailnet only through
# Caddy. Excluded on the evidence, not by omission.
/etc/systemd/system/docker.service.d/99-tailscale-forward.conf
/etc/systemd/system/tailscaled.service.d/98-master-stack.conf
EXCLUDED_LIST
    sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' |
        grep -E '^/' |
        sort -u
}

# ---------------------------------------------------------------------------
# Derivations
# ---------------------------------------------------------------------------

# install.sh with every heredoc body removed. Without this, write
# operations inside the generated helper scripts (which run on the target,
# not during install) would be counted as install.sh's own, and the
# reconcile heredoc alone contains a dozen `install -m` calls.
outer_script() {
    awk '
        { if (in_doc) { if ($0 == marker) in_doc = 0; next } }
        match($0, /<<'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/) {
            m = substr($0, RSTART, RLENGTH)
            sub(/^<</, "", m)
            gsub(/'"'"'/, "", m)
            marker = m
            in_doc = 1
        }
        { print }
    ' "$INSTALL_SH"
}

# Resolve a "$VAR" path reference through install.sh's own literal
# assignment, so QUANTUM_CONFIG_FILE reads as the path it holds. Anything
# that cannot be resolved is returned unchanged and will fail the
# absolute-path filter, which is the loud outcome we want.
resolve_path_var() {
    local raw="$1" var="" val=""
    case "$raw" in
        \$*)
            var="${raw#\$}"
            var="${var#\{}"
            var="${var%\}}"
            val="$(
                grep -m1 -E "^${var}=\"?/" "$OUTER" |
                    sed -E "s/^${var}=\"?([^\"]*)\"?\$/\1/"
            )"
            if [ -n "$val" ]; then printf '%s\n' "$val"
            else printf '%s\n' "$raw"; fi
            ;;
        *) printf '%s\n' "$raw" ;;
    esac
}

# Every absolute path the outer script writes: heredoc redirections plus
# the destination of the atomic mktemp/mv pattern. Temp files drop out —
# they only ever exist between those two steps.
generated_files() {
    {
        grep -oE 'cat >>?"?[/$][^ "<]*' "$OUTER" | sed -E 's/^cat >>?"?//'
        grep -oE '^[[:space:]]*mv -f "\$[A-Za-z_]+" +"?[/$][^ "]*' "$OUTER" |
            sed -E 's/^.*" +"?//'
        awk '/^[[:space:]]*mv -f "\$[A-Za-z_]+" \\$/ {
                 if ((getline d) <= 0) next
                 gsub(/^[ \t]+|"/, "", d)
                 print d
             }' "$OUTER"
    } | while IFS= read -r p; do
        [ -n "$p" ] && resolve_path_var "$p"
    done | grep -E '^/' | grep -vE '_TMP$|^/dev/null$' | sort -u
}

# The source side of Stage 6's canonical publish: the file on the host that
# each bundle entry is a copy of.
bundled_sources() {
    awk '
        /^install -m [0-7]+ -o root -g root \\$/ {
            if ((getline src) <= 0) next
            if ((getline dst) <= 0) next
            gsub(/^[ \t]+|[ \t]*\\$|"/, "", src)
            gsub(/^[ \t]+|"/, "", dst)
            if (dst ~ /^\$CANONICAL_STAGE_DIR\//) print src
        }
    ' "$OUTER" | while IFS= read -r p; do
        [ -n "$p" ] && resolve_path_var "$p"
    done | sort -u
}

# The bundle-side names, in publish order.
bundled_names() {
    awk '
        /^install -m [0-7]+ -o root -g root \\$/ {
            if ((getline src) <= 0) next
            if ((getline dst) <= 0) next
            gsub(/^[ \t]+|"/, "", dst)
            if (sub(/^\$CANONICAL_STAGE_DIR\//, "", dst)) print dst
        }
    ' "$OUTER"
}

# The file list Stage 6 hands to sha256sum. Same extraction as
# canonical_bundle.bats.
manifest_entries() {
    awk '
        /sha256sum -- \\$/ { collecting = 1; next }
        collecting {
            sub(/^[[:space:]]+/, "")
            if (sub(/[[:space:]]*\\$/, "")) { print; next }
            print
            exit
        }
    ' "$OUTER"
}

setup() {
    FIXTURE_DIR="$(mktemp -d)"
    OUTER="$FIXTURE_DIR/outer.sh"
    outer_script >"$OUTER"

    # Every assertion below is a set difference, so an empty derivation
    # would pass vacuously. Pin non-emptiness first, and pin that the
    # heredoc stripper actually stripped something — if the marker regex
    # ever stops matching, OUTER becomes the whole file and the reconcile
    # heredoc's own `install -m` calls start polluting the results.
    [ "$(wc -l <"$OUTER")" -lt "$(wc -l <"$INSTALL_SH")" ]
    [ -n "$(generated_files)" ]
    [ -n "$(bundled_sources)" ]
    [ -n "$(excluded_paths)" ]
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

@test "every generated file is either bundled or explicitly excluded" {
    # The Q1-9 catch. A new managed file added to install.sh lands here
    # until someone decides, in writing, which side it belongs on.
    local unaccounted=""
    unaccounted="$(
        comm -23 \
            <(generated_files) \
            <(cat <(bundled_sources) <(excluded_paths) | sort -u)
    )"

    if [ -n "$unaccounted" ]; then
        printf 'install.sh generates these, and nothing covers them:\n%s\n' \
            "$unaccounted" >&2
        printf 'Publish them into the canonical bundle, or add them to\n' >&2
        printf 'excluded_paths() in this file with the reason.\n' >&2
    fi
    [ -z "$unaccounted" ]
}

@test "no stale entries on the exclusion allowlist" {
    # Keeps the allowlist honest in the other direction: a path that
    # install.sh no longer writes must not keep sitting here implying a
    # decision that no longer applies.
    local stale=""
    stale="$(comm -13 <(generated_files) <(excluded_paths))"

    if [ -n "$stale" ]; then
        printf 'The allowlist names paths install.sh no longer generates:\n%s\n' \
            "$stale" >&2
    fi
    [ -z "$stale" ]
}

@test "nothing is both bundled and excluded" {
    local both=""
    both="$(comm -12 <(bundled_sources) <(excluded_paths))"

    if [ -n "$both" ]; then
        printf 'Listed as excluded but also published into the bundle:\n%s\n' \
            "$both" >&2
    fi
    [ -z "$both" ]
}

@test "the canonical publish and the sha256sum list name the same files" {
    # canonical_bundle.bats compares the manifest against reconcile's
    # expected list. This compares it against the publish commands that
    # create the files being hashed — the third side of the same triangle.
    # A file published but left out of sha256sum is unverified; one hashed
    # but never published makes the manifest step fail outright.
    local published="" hashed=""
    published="$(bundled_names | sort)"
    hashed="$(manifest_entries | sort)"

    [ "$published" = "$hashed" ]
}

@test "every bundled source is a file install.sh actually generates" {
    # Guards against publishing a copy of something install.sh does not
    # own — the bundle is meant to be the canonical copy of generated
    # state, not of whatever happens to be on the host.
    local foreign=""
    foreign="$(comm -13 <(generated_files) <(bundled_sources))"

    if [ -n "$foreign" ]; then
        printf 'Published into the bundle but not generated by install.sh:\n%s\n' \
            "$foreign" >&2
    fi
    [ -z "$foreign" ]
}

@test "canonical publication verifies a generation before swapping current" {
    local stage_line="" verify_line="" swap_line=""

    stage_line="$(
        grep -n -m1 'mktemp -d "\$CANONICAL_ROOT/.generation.XXXXXX"' \
            "$OUTER" | cut -d: -f1
    )"
    verify_line="$(
        grep -n -m1 'sha256sum -c --status SHA256SUMS' "$OUTER" |
            cut -d: -f1
    )"
    swap_line="$(
        grep -n -m1 'mv -Tf "\$CANONICAL_LINK_TMP" "\$CANONICAL_ROOT/current"' \
            "$OUTER" | cut -d: -f1
    )"

    [ -n "$stage_line" ]
    [ -n "$verify_line" ]
    [ -n "$swap_line" ]
    [ "$stage_line" -lt "$verify_line" ]
    [ "$verify_line" -lt "$swap_line" ]

    # The EXIT cleanup allowlist must describe the same unique link name
    # Stage 6 creates; a drift here leaves dangling publication links after
    # a failed swap.
    grep -Fq 'CANONICAL_LINK_TMP="${CANONICAL_STAGE_DIR}.link"' "$OUTER"
    grep -Fq '/usr/local/share/master-stack/.generation.*.link)' "$OUTER"
}
