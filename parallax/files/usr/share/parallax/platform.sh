#!/bin/sh
# SPDX-License-Identifier: MIT
# Shared platform guards. Safe to source; no side effects.

parallax_check_platform() {
    if [ ! -r /etc/openwrt_release ]; then
        echo 'Parallax requires OpenWrt 25.12+ (missing /etc/openwrt_release)' >&2
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/openwrt_release

    local release major minor suffix
    release="${DISTRIB_RELEASE%%-*}"
    case "$release" in
        *.*) ;;
        *) echo 'Invalid OpenWrt release number' >&2; return 1 ;;
    esac
    major="${release%%.*}"
    suffix="${release#*.}"
    minor="${suffix%%.*}"
    case "$major:$minor" in
        *[!0-9:]*|:*|*:) echo 'Invalid OpenWrt release number' >&2; return 1 ;;
    esac
    if [ "$major" -lt 25 ] || { [ "$major" -eq 25 ] && [ "$minor" -lt 12 ]; }; then
        echo "Unsupported OpenWrt release: ${DISTRIB_RELEASE:-unknown}" >&2
        return 1
    fi

    if [ "$(uname -m)" != 'x86_64' ]; then
        echo 'Parallax MVP (a) supports x86_64 only' >&2
        return 1
    fi

    if ! command -v apk >/dev/null 2>&1; then
        echo 'Parallax requires the OpenWrt apk package manager' >&2
        return 1
    fi
}

parallax_check_config() {
    local enabled schema mode apply_mode default_outbound
    if ! uci -q show parallax >/dev/null 2>&1; then
        echo 'Cannot read UCI configuration: parallax' >&2
        return 1
    fi
    schema="$(uci -q get parallax.main.schema_version)" || return 1
    enabled="$(uci -q get parallax.main.enabled)" || return 1
    mode="$(uci -q get parallax.main.mode)" || return 1
    apply_mode="$(uci -q get parallax.main.apply_mode)" || return 1
    default_outbound="$(uci -q get parallax.main.default_outbound)" || return 1
    if [ "$schema" != '2' ] && [ "$schema" != '3' ]; then
        echo 'Unsupported parallax UCI schema_version (expected 2 or 3)' >&2
        return 1
    fi
    case "$enabled" in
        0|1) ;;
        *) echo 'parallax.main.enabled must be 0 or 1' >&2; return 1 ;;
    esac
    if [ "$apply_mode" != 'config_only' ]; then
        echo 'MVP-b only accepts apply_mode=config_only' >&2
        return 1
    fi
    case "$default_outbound" in
        ''|*[!a-zA-Z0-9_-]*) echo 'Invalid default_outbound tag' >&2; return 1 ;;
    esac
    if [ "$schema" = 3 ]; then
        # Share the same strict selected-client validator as render.uc.
        /usr/bin/ucode /usr/share/parallax/selected_print.uc validate || return 1
    fi
    if [ "$mode" != 'selective' ]; then
        echo 'MVP (a) only accepts mode=selective' >&2
        return 1
    fi
}
