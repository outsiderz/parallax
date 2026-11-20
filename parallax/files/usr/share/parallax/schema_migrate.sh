#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline UCI v2->v3 schema migration with exact v2 rollback.
# NEVER writes kernel networking state; no automatic migration.
set -eu
umask 077
CONFIG=/etc/config/parallax
STORE=/etc/parallax/generated
BACKUP="$STORE/schema-v2.backup"
HASH="$STORE/schema-v2.backup.sha256"
fail() { echo "Parallax schema: $1" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'root required'
[ "$#" = 1 ] || fail 'usage: parallax schema migrate-v3|rollback-v2'
case "$1" in migrate-v3|rollback-v2) ;; *) fail 'unsupported operation' ;; esac
/usr/bin/ucode /usr/share/parallax/fs_guard.uc config "$CONFIG" ||
    fail 'unsafe UCI configuration'
[ -z "$(uci -q changes parallax)" ] || fail 'uncommitted UCI changes'
if /usr/share/parallax/singbox.sh status 2>/dev/null | grep -q '^running '; then
    fail 'isolated sing-box must be manually stopped before schema migration'
fi
[ ! -e /run/parallax/net-generation ] || fail 'network generation present'
if [ "$1" = migrate-v3 ]; then
    [ "$(uci -q get parallax.main.schema_version)" = 2 ] ||
        fail 'migration requires schema v2'
    [ "$(uci -q get parallax.main.enabled)" = 0 ] ||
        fail 'disable config daemon explicitly before migration'
    . /usr/share/parallax/platform.sh
    parallax_check_config || fail 'v2 config invalid'
    [ ! -e "$BACKUP" ] && [ ! -e "$HASH" ] ||
        fail 'existing rollback backup; restore or archive explicitly'
    mkdir -p "$STORE"
    /usr/bin/ucode /usr/share/parallax/fs_guard.uc private-dir "$STORE" ||
        fail 'unsafe private store'
    cp "$CONFIG" "$BACKUP" || fail 'cannot create v2 backup'
    chmod 0600 "$BACKUP"
    sha256sum "$BACKUP" > "$HASH"
    chmod 0600 "$HASH"
    if ! uci set parallax.main.schema_version=3 ||
       ! uci commit parallax ||
       ! parallax_check_config ||
       ! /usr/bin/ucode /usr/share/parallax/selected_print.uc validate; then
        cp "$BACKUP" "$CONFIG" || fail 'migration failed; manual recovery required'
        uci -q revert parallax || :
        fail 'v3 validation failed; original v2 restored'
    fi
    echo 'PASS: offline UCI migration v2 -> v3, original v2 backup retained'
else
    [ -f "$BACKUP" ] && [ -f "$HASH" ] &&
    [ ! -L "$BACKUP" ] && [ ! -L "$HASH" ] ||
        fail 'root-only v2 rollback backup missing or unsafe'
    /usr/bin/ucode /usr/share/parallax/fs_guard.uc backup "$BACKUP" &&
    /usr/bin/ucode /usr/share/parallax/fs_guard.uc backup "$HASH" ||
        fail 'unsafe v2 backup permissions'
    sha256sum -c "$HASH" >/dev/null || fail 'v2 rollback backup checksum mismatch'
    [ "$(uci -q get parallax.main.schema_version)" = 3 ] ||
        fail 'rollback requires schema v3'
    [ "$(uci -q get parallax.main.enabled)" = 0 ] ||
        fail 'disable config daemon explicitly before rollback'
    TEMP="$(mktemp /etc/config/.parallax-rollback.XXXXXX)" ||
        fail 'cannot stage rollback'
    trap 'rm -f "$TEMP"' EXIT HUP INT TERM
    cp "$BACKUP" "$TEMP" || fail 'cannot stage v2'
    chmod 0600 "$TEMP"
    mv -f "$TEMP" "$CONFIG" || fail 'cannot restore v2'
    uci -q revert parallax || :
    [ "$(uci -q get parallax.main.schema_version)" = 2 ] ||
        fail 'rollback did not restore v2'
    [ "$(sha256sum "$CONFIG" | awk '{print $1}')" =
      "$(sha256sum "$BACKUP" | awk '{print $1}')" ] ||
        fail 'v2 file does not match original checksum'
    rm -f "$HASH" "$BACKUP"
    echo 'PASS: exact original UCI v2 restored; migration backup retired'
fi
