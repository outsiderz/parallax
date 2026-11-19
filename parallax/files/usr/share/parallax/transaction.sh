#!/bin/sh
# SPDX-License-Identifier: MIT
# Config-only transactions; never launch a proxy or alter the network.
set -eu
umask 077
STORE=/etc/parallax/generated
ACTIVE="$STORE/active.json"
MAX_REVISIONS=10

fail() { printf 'Parallax transaction rejected: %s\n' "$1" >&2; exit 1; }
secure_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] || fail 'missing or linked directory'
    [ "$(stat -c '%u:%a' "$1")" = '0:700' ] || fail 'insecure directory'
}
secure_file() {
    [ -f "$1" ] && [ ! -L "$1" ] || fail 'missing or linked file'
    [ "$(stat -c '%u:%a' "$1")" = '0:600' ] || fail 'insecure file'
}
setup() {
    [ ! -L /etc/parallax ] && [ ! -L "$STORE" ] || fail 'unsafe path'
    if [ ! -e /etc/parallax ]; then
        mkdir /etc/parallax || fail 'cannot create store parent'
        chmod 0700 /etc/parallax
    fi
    secure_dir /etc/parallax
    if [ ! -e "$STORE" ]; then
        mkdir "$STORE" || fail 'cannot create store directory'
        chmod 0700 "$STORE"
    fi
    secure_dir "$STORE"
}
lock_store() {
    exec 9>"$STORE/.lock"
    chmod 0600 "$STORE/.lock"
    flock -x -w 15 9 || fail 'another transaction holds the lock'
}
hash_file() { sha256sum "$1" | cut -d ' ' -f1; }
active_hash() {
    if [ -e "$ACTIVE" ] || [ -L "$ACTIVE" ]; then
        secure_file "$ACTIVE"
        hash_file "$ACTIVE"
    fi
}
validate_file() {
    command -v sing-box >/dev/null 2>&1 || fail 'sing-box is not installed'
    sing-box check -c "$1" >/dev/null 2>&1 || fail 'sing-box validation failed'
}
candidate_file() {
    printf '%s\n' "$1" | grep -Eq '^/run/parallax/candidate\.[A-Za-z0-9]{8}$' ||
        fail 'invalid candidate location'
    secure_file "$1"
    validate_file "$1"
}
private_copy() {
    cp "$1" "$2" || fail 'cannot stage configuration'
    chmod 0600 "$2" || fail 'cannot secure configuration'
}
prune() {
    local f count current sum
    current="$(active_hash)"
    count=0
    for f in $(ls -1t "$STORE"/rev-*.json 2>/dev/null); do
        [ -f "$f" ] || continue
        count=$((count + 1))
        if [ "$count" -gt "$MAX_REVISIONS" ]; then
            sum="$(hash_file "$f")"
            [ "$sum" = "$current" ] || rm -f "$f"
        fi
    done
}
apply() {
    local candidate old sum stamp rev stage live
    candidate="$1"
    candidate_file "$candidate"
    old="$(active_hash)"
    sum="$(hash_file "$candidate")"
    if [ "$old" = "$sum" ]; then
        printf 'unchanged sha256=%s\n' "$sum"
        return
    fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    rev="rev-$stamp-$$-$(printf '%.12s' "$sum")"
    stage="$(mktemp "$STORE/.revision.XXXXXXXX")" || fail 'revision staging failed'
    private_copy "$candidate" "$stage"
    mv "$stage" "$STORE/$rev.json" || fail 'revision save failed'
    live="$(mktemp "$STORE/.active.XXXXXXXX")" || fail 'active staging failed'
    private_copy "$STORE/$rev.json" "$live"
    sync
    mv -f "$live" "$ACTIVE" || fail 'atomic promotion failed'
    sync
    prune
    printf 'applied revision=%s sha256=%s\n' "$rev" "$sum"
}
history() {
    local f rev sum current state
    current="$(active_hash)"
    if [ -n "$current" ]; then printf 'active sha256=%s\n' "$current"; else echo 'active none'; fi
    for f in $(ls -1t "$STORE"/rev-*.json 2>/dev/null); do
        [ -f "$f" ] || continue
        secure_file "$f"
        rev="$(basename "$f" .json)"
        sum="$(hash_file "$f")"
        state=stored
        [ "$sum" != "$current" ] || state=active
        printf '%s %s sha256=%s\n' "$rev" "$state" "$sum"
    done
}
diff_hashes() {
    local old sum
    old="$(active_hash)"
    sum="$(hash_file "$1")"
    if [ -z "$old" ]; then
        printf 'changed: no active configuration; candidate_sha256=%s\n' "$sum"
    elif [ "$old" = "$sum" ]; then
        printf 'unchanged sha256=%s\n' "$sum"
    else
        printf 'changed: active_sha256=%s candidate_sha256=%s\n' "$old" "$sum"
    fi
}
rollback() {
    local revision source old sum live
    revision="$1"
    printf '%s\n' "$revision" |
        grep -Eq '^rev-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{12}$' ||
        fail 'invalid revision identifier'
    source="$STORE/$revision.json"
    secure_file "$source"
    validate_file "$source"
    sum="$(hash_file "$source")"
    old="$(active_hash)"
    if [ "$old" = "$sum" ]; then
        printf 'unchanged revision=%s sha256=%s\n' "$revision" "$sum"
        return
    fi
    live="$(mktemp "$STORE/.rollback.XXXXXXXX")" || fail 'rollback staging failed'
    private_copy "$source" "$live"
    sync
    mv -f "$live" "$ACTIVE" || fail 'atomic rollback failed'
    sync
    printf 'rolled_back revision=%s sha256=%s\n' "$revision" "$sum"
}
[ "$(id -u)" = 0 ] || fail 'root required'
[ "$#" -ge 1 ] || fail 'missing command'
mode="$1"
setup
case "$mode" in
    apply)
        [ "$#" = 2 ] || fail 'usage: apply CANDIDATE'
        lock_store
        apply "$2" ;;
    rollback)
        [ "$#" = 2 ] || fail 'usage: rollback REVISION'
        lock_store
        rollback "$2" ;;
    history)
        [ "$#" = 1 ] || fail 'usage: history'
        lock_store
        history ;;
    diff)
        [ "$#" = 2 ] || fail 'usage: diff CANDIDATE'
        candidate_file "$2"
        lock_store
        diff_hashes "$2" ;;
    *) fail 'unsupported command' ;;
esac
