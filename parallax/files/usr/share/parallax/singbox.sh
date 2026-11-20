#!/bin/sh
# SPDX-License-Identifier: MIT
# Manual-only MVP-c1 sing-box controller. No nft, TProxy, routing or DNS writes.
set -eu
umask 077
RUN=/run/parallax-singbox
STORE=/etc/parallax/generated
ACTIVE=$STORE/active.json
LKG=$STORE/last-good.ref
INIT=/etc/init.d/parallax-singbox
GATE=/usr/share/parallax/singbox_gate.uc

fail() { echo "Parallax singbox: $*" >&2; exit 1; }
root() { [ "$(id -u)" = 0 ] || fail 'root required'; }
deps() {
  command -v sing-box >/dev/null 2>&1 || fail 'sing-box binary missing'
  command -v ucode >/dev/null 2>&1 || fail 'ucode binary missing'
  id -u parallax-sb >/dev/null 2>&1 || fail 'parallax-sb user missing'
  id -g parallax-sb >/dev/null 2>&1 || fail 'parallax-sb group missing'
}
pidof_ours() {
  local f cmd
  for f in /proc/[0-9]*/cmdline; do
    [ -r "$f" ] || continue
    cmd="$(tr '\000' ' ' <"$f" 2>/dev/null || :)"
    case "$cmd" in
      *'/usr/bin/sing-box run -c /run/parallax-singbox/config.json '*)
        f="${f#/proc/}"; echo "${f%/cmdline}"; return 0 ;;
    esac
  done
  return 1
}
native_conflict() {
  local s
  s="$(ubus call service list '{"name":"sing-box","verbose":true}' 2>&1)" ||
    fail 'cannot inspect native sing-box procd state'
  # No inbound sockets in c1; nevertheless fail closed if a native instance
  # runs and its port/process ownership cannot be conclusively disjoint.
  if printf '%s\n' "$s" | grep -Eq '"running"[[:space:]]*:[[:space:]]*true'; then
    fail 'native sing-box is running (potential port conflict); no changes made'
  fi
}
runtime_dir() {
  local gid st
  gid="$(id -g parallax-sb)"
  [ ! -L "$RUN" ] || fail 'runtime path is a symlink'
  if [ -d "$RUN" ]; then
    /usr/bin/ucode /usr/share/parallax/singbox_permissions.uc run "$gid" >/dev/null ||
      fail 'unsafe runtime ownership/permissions'
  else
    [ ! -e "$RUN" ] || fail 'runtime path is not a directory'
    mkdir -m 0710 "$RUN" || fail 'runtime mkdir failed'
    chown "0:$gid" "$RUN" || fail 'runtime chown failed'
    chmod 0710 "$RUN"
  fi
}
valid_source() {
  /usr/bin/ucode "$GATE" "$1" >/dev/null 2>&1 &&
    sing-box check -c "$1" >/dev/null 2>&1
}
matching_rev() {
  local hash f
  hash="$(sha256sum "$ACTIVE" | cut -d ' ' -f1)" || return 1
  for f in "$STORE"/rev-*.json; do
    [ -f "$f" ] || continue
    /usr/bin/ucode "$GATE" "$f" >/dev/null 2>&1 || continue
    [ "$(sha256sum "$f" | cut -d ' ' -f1)" = "$hash" ] || continue
    f="${f##*/}"; echo "${f%.json}"; return 0
  done
  return 1
}
pick_revision() {
  local ref
  if valid_source "$ACTIVE"; then
    ref="$(matching_rev)" && [ -n "$ref" ] ||
      fail 'active file has no stored validated revision; run parallax apply --config-only'
    echo "active:$ref"; return 0
  fi
  [ -f "$LKG" ] && [ ! -L "$LKG" ] ||
    fail 'active revision invalid; no last-known-good revision'
  /usr/bin/ucode /usr/share/parallax/singbox_permissions.uc last-good >/dev/null ||
    fail 'last-known-good reference is unsafe'
  ref="$(cat "$LKG")"
  printf '%s\n' "$ref" | grep -Eq '^rev-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{12}$' ||
    fail 'last-known-good revision name invalid'
  valid_source "$STORE/$ref.json" ||
    fail 'active and last-known-good revisions both invalid'
  echo "fallback:$ref"
}
prepare() {
  local selection mode ref source tmp gid
  root; deps
  [ -f "$RUN/requested" ] && [ ! -L "$RUN/requested" ] ||
    fail 'service needs manual parallax singbox start'
  native_conflict
  selection="$(pick_revision)"
  mode="${selection%%:*}"; ref="${selection#*:}"
  if [ "$mode" = active ]; then source="$ACTIVE"; else source="$STORE/$ref.json"; fi
  runtime_dir
  gid="$(id -g parallax-sb)"
  tmp="$(mktemp "$RUN/.config.XXXXXXXX")" || fail 'runtime stage failed'
  cp "$source" "$tmp" || { rm -f "$tmp"; fail 'cannot copy revision'; }
  chown "0:$gid" "$tmp" && chmod 0640 "$tmp" ||
    { rm -f "$tmp"; fail 'cannot protect runtime file'; }
  sing-box check -c "$tmp" >/dev/null 2>&1 ||
    { rm -f "$tmp"; fail 'runtime sing-box check failed'; }
  mv -f "$tmp" "$RUN/config.json" || fail 'runtime publish failed'
  printf '%s\n' "$ref" >"$RUN/selected.ref"
  chmod 0600 "$RUN/selected.ref"
  echo "PASS: sing-box check; selected $mode revision; no inbound listeners"
}
remember_good() {
  local ref tmp
  ref="$(cat "$RUN/selected.ref")" || fail 'missing selected revision'
  printf '%s\n' "$ref" | grep -Eq '^rev-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{12}$' ||
    fail 'invalid selected revision'
  [ ! -L "$LKG" ] || fail 'last-good symlink refused'
  tmp="$(mktemp "$STORE/.lastgood.XXXXXXXX")" || fail 'cannot stage last-good'
  printf '%s\n' "$ref" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$LKG" || fail 'last-good update failed'
}
registered() {
  local s
  s="$(ubus call service list '{"name":"parallax-singbox"}' 2>&1)" || {
    echo "Parallax singbox: procd lookup failed: $s" >&2; return 2;
  }
  case "$s" in *'"parallax-singbox"'*) return 0;; *) return 1;; esac
}
stop_ours() {
  if registered; then "$INIT" stop || fail 'procd stop failed'
  else local rc=$?; [ "$rc" = 1 ] || fail 'procd registry unavailable'; fi
}
stop_all() {
  local n
  root
  [ ! -L "$RUN" ] || fail 'runtime symlink refused'
  rm -f "$RUN/requested"
  stop_ours
  for n in $(seq 1 15); do
    pidof_ours >/dev/null 2>&1 || break
    sleep 1
  done
  if pidof_ours >/dev/null 2>&1; then fail 'procd did not stop sing-box'; fi
  rm -f "$RUN/config.json" "$RUN/selected.ref"
  rmdir "$RUN" 2>/dev/null || :
  echo 'Parallax singbox stopped; runtime credentials removed'
}
start_all() {
  local pid uid expected i
  root; deps
  if pid="$(pidof_ours)" && [ -n "$pid" ]; then
    echo "Parallax singbox already running pid=$pid"
    return 0
  fi
  native_conflict
  runtime_dir
  printf 'requested\n' >"$RUN/requested"
  chmod 0600 "$RUN/requested"
  # Preflight in a subshell: fail early and clean volatile marker if there
  # is no approved source. procd also rechecks at the final start boundary.
  if ! (prepare); then
    rm -f "$RUN/requested" "$RUN/config.json" "$RUN/selected.ref"
    fail 'preflight refused startup'
  fi
  "$INIT" start || { rm -f "$RUN/requested"; fail 'procd start failed'; }
  expected="$(id -u parallax-sb)"
  for i in $(seq 1 30); do
    if pid="$(pidof_ours)" && [ -n "$pid" ]; then
      uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || :)"
      if [ "$uid" != "$expected" ]; then
        stop_all || :
        fail 'procd launched wrong UID'
      fi
      remember_good
      echo "Parallax singbox running pid=$pid uid=$uid (inbound-free)"
      return 0
    fi
    sleep 1
  done
  stop_all || :
  fail 'procd did not keep a sing-box process alive'
}
status() {
  local pid uid ref
  if pid="$(pidof_ours)" && [ -n "$pid" ]; then
    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || :)"
    ref="$(cat "$RUN/selected.ref" 2>/dev/null || echo unknown)"
    echo "running pid=$pid uid=$uid revision=$ref service=parallax-singbox"
  else
    echo 'stopped service=parallax-singbox'
  fi
}
case "${1:-}" in
  prepare) [ "$#" = 1 ] || exit 2; prepare ;;
  start) [ "$#" = 1 ] || exit 2; start_all ;;
  stop) [ "$#" = 1 ] || exit 2; stop_all ;;
  status) [ "$#" = 1 ] || exit 2; status ;;
  *) echo 'Usage: parallax singbox start|stop|status' >&2; exit 2 ;;
esac
