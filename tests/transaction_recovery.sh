#!/bin/sh
# SPDX-License-Identifier: MIT
# QEMU-only real lock, SIGKILL boundary and bounded history regressions.
# Never print generated JSON, credentials, candidate paths or live profiles.
set -eu
umask 077

store=/etc/parallax/generated
active=$store/active.json
tmp=/tmp/parallax-ci-atomic
lock_pid=
mkdir -p "$tmp"
chmod 0700 "$tmp"
rm -f /tmp/parallax-ci-lock-ready

cleanup() {
  if [ -n "$lock_pid" ]; then
    kill "$lock_pid" 2>/dev/null || :
    wait "$lock_pid" 2>/dev/null || :
  fi
  uci -q delete parallax.ci_atomic || :
  uci commit parallax || :
  rm -f /tmp/parallax-ci-lock-ready
  rm -rf "$tmp"
}
trap cleanup EXIT

hash_active() { sha256sum "$active" | cut -d ' ' -f1; }
revisions() { find "$store" -maxdepth 1 -type f -name 'rev-*.json' | wc -l; }
unchanged() {
  [ "$(hash_active)" = "$old_hash" ] || { echo "FAIL: active changed during $1"; exit 1; }
  [ "$(revisions)" = "$old_count" ] || { echo "FAIL: history changed during $1"; exit 1; }
}

test -f "$active"
old_hash="$(hash_active)"
old_count="$(revisions)"
uci set parallax.ci_atomic=rule
uci set parallax.ci_atomic.enabled=1
uci set parallax.ci_atomic.match=domain_suffix
uci add_list parallax.ci_atomic.value=initial-atomic.example.net
uci set parallax.ci_atomic.outbound=direct
uci set parallax.ci_atomic.priority=200
uci commit parallax

echo 'CHECK: competing apply is rejected while transaction lock is held'
ucode /tmp/parallax-ci-lock-holder.uc >"$tmp/lock-holder.log" 2>&1 &
lock_pid=$!
ready=0
for i in $(seq 1 10); do
  if [ -f /tmp/parallax-ci-lock-ready ]; then ready=1; break; fi
  if ! kill -0 "$lock_pid" 2>/dev/null; then break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || {
  echo 'FAIL: test holder never acquired transaction lock'
  cat "$tmp/lock-holder.log"
  exit 1
}
if parallax apply --config-only >"$tmp/contended.log" 2>&1; then
  echo 'FAIL: competing apply succeeded while lock held'
  exit 1
fi
grep -Fq 'transaction lock busy or inaccessible' "$tmp/contended.log" || {
  echo 'FAIL: competing apply failed for a reason other than lock contention'
  exit 1
}
unchanged lock-contention
kill "$lock_pid" 2>/dev/null || :
wait "$lock_pid" 2>/dev/null || :
lock_pid=
# Verify lock release before fault injection; a leaking child fd would
# make the next apply fail before reaching its first sync boundary.
if ! parallax history >/dev/null 2>"$tmp/released-lock.log"; then
  echo 'FAIL: transaction lock remained held after lock-owner exit'
  sed -n '1,8p' "$tmp/released-lock.log"
  exit 1
fi
if ! parallax validate >/dev/null 2>"$tmp/released-validation.log"; then
  echo 'FAIL: synthetic configuration invalid after releasing test lock'
  sed -n '1,8p' "$tmp/released-validation.log"
  exit 1
fi
echo 'PASS: competing apply denied; lock released; active hash and history unchanged'

# ucode transaction.uc calls syncDisk twice during publish:
# 1: before atomic rename(active.json); 2: after rename(active.json).
# The test-local PATH shim kills ONLY the transaction.uc apply process.
# No production code or system-wide PATH is modified.
cat >"$tmp/sync" <<'SHIM'
#!/bin/sh
set -eu
dir=/tmp/parallax-ci-atomic
state=$dir/sync-count
n=0
[ ! -f "$state" ] || n="$(cat "$state")"
n=$((n + 1))
printf '%s\n' "$n" >"$state"
if [ "$n" -eq "$PARALLAX_CI_KILL_SYNC_AT" ]; then
  printf '%s\n' "$n" >"$dir/sync-kill-hit"
  for cmdline in /proc/[0-9]*/cmdline; do
    [ -r "$cmdline" ] || continue
    if tr '\000' ' ' <"$cmdline" 2>/dev/null | grep -Fq '/usr/share/parallax/transaction.uc apply '; then
      pid="$(basename "$(dirname "$cmdline")")"
      kill -9 "$pid"
      exit 0
    fi
  done
  exit 79
fi
exec /bin/sync
SHIM
chmod 0700 "$tmp/sync"

# Fail fast when the shell uses a different sync binary or PATH is stripped.
# The marker proves this exact shim is the one seen by child shells.
rm -f "$tmp/sync-count" "$tmp/sync-kill-hit"
if ! PARALLAX_CI_KILL_SYNC_AT=99 PATH="$tmp:$PATH" /bin/sh -c 'sync' >"$tmp/shim-selftest.log" 2>&1; then
  echo 'FAIL: test-local sync interceptor cannot be executed'
  sed -n '1,8p' "$tmp/shim-selftest.log"
  exit 1
fi
[ "$(cat "$tmp/sync-count" 2>/dev/null || :)" = 1 ] || {
  echo 'FAIL: expected test-local sync interceptor did not run'
  exit 1
}
echo 'PASS: sync interceptor is executable and visible through PATH'

crash_at_sync() {
  nth="$1"
  rm -f "$tmp/sync-count" "$tmp/sync-kill-hit"
  if PARALLAX_CI_KILL_SYNC_AT="$nth" PATH="$tmp:$PATH" parallax apply --config-only >"$tmp/interrupted.log" 2>&1; then
    echo "FAIL: apply unexpectedly succeeded despite SIGKILL at sync $nth"
    exit 1
  fi
  [ -f "$tmp/sync-kill-hit" ] || {
    echo "FAIL: SIGKILL fault injection not reached at sync $nth"
    echo 'DIAGNOSTIC: intercepted sync call count'
    cat "$tmp/sync-count" 2>/dev/null || echo 0
    echo 'DIAGNOSTIC: sanitized apply error (QEMU synthetic inputs only)'
    sed -n '1,8p' "$tmp/interrupted.log" 2>/dev/null || :
    exit 1
  }
  [ "$(cat "$tmp/sync-kill-hit")" = "$nth" ]
}

echo 'CHECK: SIGKILL before active rename preserves last known good'
crash_at_sync 1
[ "$(hash_active)" = "$old_hash" ] || { echo 'FAIL: pre-rename SIGKILL changed active'; exit 1; }
# Current apply publishes its validated revision before active promotion.
# A pre-rename crash therefore leaves one recoverable stored revision.
[ "$(revisions)" -eq $((old_count + 1)) ] || {
  echo 'FAIL: pre-rename SIGKILL did not leave expected stored revision'
  exit 1
}
found_stage=0
for stage in "$store"/.stage-*; do
  [ -f "$stage" ] || continue
  ucode /tmp/parallax-permissions.uc "$stage" file >/dev/null
  found_stage=1
done
[ "$found_stage" -eq 1 ] || {
  echo 'FAIL: pre-rename SIGKILL did not leave protected staging file'
  exit 1
}
echo 'PASS: pre-rename SIGKILL preserves active; one validated stored revision and private staging remain'

echo 'CHECK: SIGKILL after active rename preserves fully valid new JSON'
crash_at_sync 2
[ "$(hash_active)" != "$old_hash" ] || {
  echo 'FAIL: post-rename SIGKILL did not promote active.json'
  exit 1
}
[ "$(revisions)" -eq $((old_count + 2)) ] || {
  echo 'FAIL: post-rename SIGKILL did not publish revision'
  exit 1
}
ucode /tmp/parallax-permissions.uc "$active" file >/dev/null
sing-box check -c "$active" >"$tmp/active-check.log" 2>&1 || {
  echo 'FAIL: promoted active JSON failed sing-box check'
  exit 1
}
new_hash="$(hash_active)"
result="$(parallax apply --config-only)"
case "$result" in
  unchanged\ sha256=*) ;;
  *) echo 'FAIL: retry did not recognize unchanged promoted config'; exit 1 ;;
esac
[ "$(hash_active)" = "$new_hash" ]
echo 'PASS: post-rename SIGKILL leaves valid active and idempotent retry'

echo 'CHECK: 14 distinct validated applies retain at most 10 revisions'
first_rev=
prev_rev=
last_rev=
for i in $(seq 1 14); do
  uci -q delete parallax.ci_atomic.value || :
  uci add_list parallax.ci_atomic.value="atomic-$i.example.net"
  uci commit parallax
  result="$(parallax apply --config-only)"
  rev="$(printf '%s\n' "$result" | sed -n 's/^applied revision=\([^ ]*\) sha256=.*/\1/p')"
  [ -n "$rev" ] || { echo "FAIL: iteration $i not applied"; exit 1; }
  [ -f "$store/$rev.json" ] || { echo "FAIL: revision $i missing"; exit 1; }
  if [ "$i" -eq 1 ]; then first_rev="$rev"; fi
  prev_rev="$last_rev"
  last_rev="$rev"
  echo "PASS: revision iteration $i; count=$(revisions)"
done
[ "$(revisions)" -eq 10 ] || { echo "FAIL: expected 10 revisions, got $(revisions)"; exit 1; }
[ ! -e "$store/$first_rev.json" ] || { echo 'FAIL: oldest revision was not pruned'; exit 1; }
[ "$(parallax history | grep -c '^rev-')" -eq 10 ] || {
  echo 'FAIL: history lists more than 10 stored revisions'
  exit 1
}
[ -f "$store/$prev_rev.json" ] || { echo 'FAIL: penultimate revision not retained'; exit 1; }
prev_hash="$(sha256sum "$store/$prev_rev.json" | cut -d ' ' -f1)"
parallax rollback "$prev_rev" >/dev/null
[ "$(hash_active)" = "$prev_hash" ] || { echo 'FAIL: rollback digest mismatch'; exit 1; }
[ "$(revisions)" -eq 10 ] || { echo 'FAIL: rollback changed retention count'; exit 1; }
test -z "$(pidof sing-box || :)"
echo 'PASS: history limited to 10 revisions, oldest pruned, retained rollback verified; no proxy daemon'
