#!/bin/sh
# SPDX-License-Identifier: MIT
# Disposable QEMU-only MVP-c1 gate. Synthetic configs, no network writes.
set -eu
umask 077
STORE=/etc/parallax/generated
RUN=/run/parallax-singbox
TMP=/tmp/parallax-c1-test
mkdir -p "$TMP"
cleanup() {
  # Do not leave a mutated active revision after a failed test.
  if [ -f "$TMP/active.json" ]; then
    cp "$TMP/active.json" "$STORE/active.json"
    chmod 0600 "$STORE/active.json"
  fi
  if [ -f "$TMP/last-good.ref" ]; then
    mv -f "$TMP/last-good.ref" "$STORE/last-good.ref"
  fi
  parallax singbox stop >/dev/null 2>&1 || :
  rm -rf "$TMP"
}
trap cleanup EXIT

uid="$(id -u parallax-sb)"
gid="$(id -g parallax-sb)"
[ "$uid" -ne 0 ] || { echo 'FAIL: parallax-sb is root'; exit 1; }
if /etc/init.d/parallax-singbox enabled >/dev/null 2>&1; then
  echo 'FAIL: parallax-singbox was enabled for boot'
  exit 1
fi
parallax singbox status | grep -q '^stopped '
[ ! -e "$RUN/config.json" ] || { echo 'FAIL: runtime config exists before manual start'; exit 1; }
echo 'PASS: service disabled at boot, stopped, no runtime credentials'

# Reject a competing native sing-box procd fixture without ever touching
# /etc/init.d/sing-box, /etc/config/sing-box or real native service.
real_ubus="$(command -v ubus)"
cat >"$TMP/ubus" <<'SH'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = service ] && [ "$3" = list ]; then
    case "$4" in
      *'"name":"sing-box"'*)
        echo '{"sing-box":{"instances":{"test":{"running":true,"pid":9999}}}}'
        exit 0 ;;
    esac
fi
exec /bin/ubus "$@"
SH
chmod 0700 "$TMP/ubus"
if PATH="$TMP:$PATH" parallax singbox start >"$TMP/native-conflict.log" 2>&1; then
  echo 'FAIL: native sing-box conflict was accepted'
  exit 1
fi
grep -Fq 'native sing-box is running' "$TMP/native-conflict.log" || {
  echo 'FAIL: rejection did not identify native sing-box conflict'
  exit 1
}
[ ! -e "$RUN/config.json" ] || { echo 'FAIL: port-conflict preflight mutated runtime'; exit 1; }
echo 'PASS: native sing-box service/port conflict refused without touching native service'
rm -f "$TMP/ubus"

parallax singbox start >"$TMP/start.log" 2>&1 || {
  echo 'FAIL: manual start failed'
  sed -n '1,8p' "$TMP/start.log"
  exit 1
}
grep -Fq 'running pid=' "$TMP/start.log" || {
  echo 'FAIL: manual start did not confirm running process'
  exit 1
}
status="$(parallax singbox status)"
pid="$(printf '%s\n' "$status" | sed -n 's/^running pid=\([0-9]*\).*/\1/p')"
[ -n "$pid" ] && [ -r "/proc/$pid/status" ] || {
  echo 'FAIL: missing parallax procd process'
  exit 1
}
proc_uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")"
[ "$proc_uid" = "$uid" ] || { echo 'FAIL: sing-box process not unprivileged'; exit 1; }
echo "$status" | grep -q "uid=$uid "
/usr/bin/ucode /usr/share/parallax/singbox_permissions.uc run "$gid" >/dev/null
/usr/bin/ucode /usr/share/parallax/singbox_permissions.uc config "$gid" >/dev/null
/usr/bin/ucode /usr/share/parallax/singbox_permissions.uc selected >/dev/null
/usr/bin/ucode /usr/share/parallax/singbox_permissions.uc last-good >/dev/null
[ ! -L "$RUN/config.json" ] && [ ! -L "$STORE/last-good.ref" ]
/usr/bin/ucode /usr/share/parallax/singbox_gate.uc "$STORE/active.json" >/dev/null
# Verify process is supervised by our own procd instance, not native sing-box.
ubus call service list '{"name":"parallax-singbox","verbose":true}' |
  grep -Fq '"parallax-singbox"'
echo 'PASS: manual procd instance running as parallax-sb; private config root:group 0640'

kill -9 "$pid"
restarted=''
for n in $(seq 1 30); do
  status="$(parallax singbox status)"
  restarted="$(printf '%s\n' "$status" | sed -n 's/^running pid=\([0-9]*\).*/\1/p')"
  if [ -n "$restarted" ] && [ "$restarted" != "$pid" ]; then break; fi
  sleep 1
done
[ -n "$restarted" ] && [ "$restarted" != "$pid" ] || {
  echo 'FAIL: no bounded procd respawn after kill -9'
  exit 1
}
[ "$(awk '/^Uid:/ {print $2}' "/proc/$restarted/status")" = "$uid" ] ||
  { echo 'FAIL: respawn changed UID'; exit 1; }
echo 'PASS: kill -9 recovered through limited procd respawn with same non-root UID'
parallax singbox stop >/dev/null
parallax singbox status | grep -q '^stopped '
[ ! -f "$RUN/config.json" ] || { echo 'FAIL: stop left runtime config'; exit 1; }
echo 'PASS: stop terminates only parallax instance and deletes runtime credentials'

# A deliberately invalid candidate must recover to last SUCCESSFULLY RUNNING
# revision. The active file is restored before existing package lifecycle tests.
cp "$STORE/active.json" "$TMP/active.json"
chmod 0600 "$TMP/active.json"
ref="$(cat "$STORE/last-good.ref")"
printf '{"inbounds":[{"type":"socks","listen":"0.0.0.0","listen_port":5555}]}\n' >"$STORE/active.json"
chmod 0600 "$STORE/active.json"
parallax singbox start >"$TMP/fallback.log" 2>&1 || {
  echo 'FAIL: last-known-good fallback did not start'
  sed -n '1,8p' "$TMP/fallback.log"
  exit 1
}
[ "$(cat "$RUN/selected.ref")" = "$ref" ] || {
  echo 'FAIL: unexpected fallback revision selected'
  exit 1
}
echo 'PASS: invalid active config falls back to last successfully running revision'
parallax singbox stop >/dev/null
mv "$STORE/last-good.ref" "$TMP/last-good.ref"
if parallax singbox start >"$TMP/no-fallback.log" 2>&1; then
  echo 'FAIL: invalid candidate started without last-known-good'
  exit 1
fi
grep -Fq 'no last-known-good' "$TMP/no-fallback.log" || {
  echo 'FAIL: missing clear rejection when both configs unavailable'
  exit 1
}
echo 'PASS: invalid active and missing last-good fail closed'
mv "$TMP/last-good.ref" "$STORE/last-good.ref"
cp "$TMP/active.json" "$STORE/active.json"
chmod 0600 "$STORE/active.json"
rm -f "$TMP/active.json"
test ! -e "$RUN/config.json"
test ! -e "$RUN/requested"
echo 'PASS: MVP-c1 QEMU manual-only, UID, security, crash recovery and revision fallback'
