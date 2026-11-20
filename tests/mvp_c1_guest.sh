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
  if [ -f "$TMP/native-uci.orig" ]; then native_restore; fi
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

# Real native OpenWrt sing-box service fixture, entirely inside disposable QEMU.
# Save and restore both vendor config files; never impersonate ubus/procd.
NATIVE_CONF=/etc/config/sing-box
NATIVE_JSON=/etc/sing-box/config.json
[ -x /etc/init.d/sing-box ] || { echo 'FAIL: native sing-box init script missing'; exit 1; }
[ -f "$NATIVE_CONF" ] && [ -f "$NATIVE_JSON" ] || {
  echo 'FAIL: native sing-box configuration files missing'; exit 1
}
cp -p "$NATIVE_CONF" "$TMP/native-uci.orig"
cp -p "$NATIVE_JSON" "$TMP/native-json.orig"
native_restore() {
  /etc/init.d/sing-box stop >/dev/null 2>&1 || :
  cp -p "$TMP/native-uci.orig" "$NATIVE_CONF"
  cp -p "$TMP/native-json.orig" "$NATIVE_JSON"
}
# Cleanup on any assertion failure must restore the vendor service fixture.
cat >"$NATIVE_JSON" <<'JSON'
{"log":{"level":"warn"},"inbounds":[{"type":"socks","tag":"ci-native","listen":"127.0.0.1","listen_port":39081}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
sing-box check -c "$NATIVE_JSON" >"$TMP/native-check.log" 2>&1 || {
  echo 'FAIL: native fixture sing-box check'
  cat "$TMP/native-check.log"; exit 1
}
uci set sing-box.main.enabled=1
uci commit sing-box
/etc/init.d/sing-box start >"$TMP/native-start.log" 2>&1 || {
  echo 'FAIL: native sing-box service could not start'
  cat "$TMP/native-start.log"; exit 1
}
porthex="$(printf '%04X' 39081)"
native_pid=''
for n in $(seq 1 30); do
  native_pid="$(pidof sing-box | awk '{print $1}' || :)"
  if [ -n "$native_pid" ] &&
    awk -v port="$porthex" '$2 ~ (":" port "$") && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp; then
    break
  fi
  sleep 1
done
[ -n "$native_pid" ] && kill -0 "$native_pid" 2>/dev/null || {
  echo 'FAIL: native sing-box process missing'; exit 1
}
awk -v port="$porthex" '$2 ~ (":" port "$") && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp || {
  echo 'FAIL: native sing-box has no local listener'; exit 1
}
native_ubus="$(ubus call service list '{"name":"sing-box","verbose":true}')"
printf '%s\n' "$native_ubus" >"$TMP/native-ubus-before.log"
printf '%s\n' "$native_ubus" | grep -Fq '"sing-box"' || {
  echo 'FAIL: native sing-box is not registered with real procd'; exit 1
}
printf '%s\n' "$native_ubus" | grep -Eq '"running"[[:space:]]*:[[:space:]]*true' || {
  echo 'FAIL: real native procd does not report running'; exit 1
}
native_config_hash="$(sha256sum "$NATIVE_CONF" "$NATIVE_JSON")"
echo "NATIVE BEFORE: pid=$native_pid socket=127.0.0.1:39081"
echo "NATIVE BEFORE: $(printf '%s' "$native_ubus" | tr '\n' ' ' | cut -c 1-900)"
if parallax singbox start >"$TMP/native-conflict.log" 2>&1; then
  echo 'FAIL: Parallax started while real native sing-box procd service was running'
  exit 1
fi
grep -Fq 'native sing-box is running' "$TMP/native-conflict.log" || {
  echo 'FAIL: Parallax did not identify real native service conflict'
  cat "$TMP/native-conflict.log"; exit 1
}
[ "$(pidof sing-box | awk '{print $1}')" = "$native_pid" ] || {
  echo 'FAIL: Parallax changed native sing-box PID'; exit 1
}
kill -0 "$native_pid" 2>/dev/null || { echo 'FAIL: native sing-box stopped'; exit 1; }
[ "$(sha256sum "$NATIVE_CONF" "$NATIVE_JSON")" = "$native_config_hash" ] || {
  echo 'FAIL: Parallax changed native sing-box config'; exit 1
}
awk -v port="$porthex" '$2 ~ (":" port "$") && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp || {
  echo 'FAIL: Parallax changed native sing-box listener'; exit 1
}
ubus call service list '{"name":"sing-box","verbose":true}' >"$TMP/native-ubus-after.log"
grep -Fq '"running": true' "$TMP/native-ubus-after.log" || {
  grep -Eq '"running"[[:space:]]*:[[:space:]]*true' "$TMP/native-ubus-after.log" || {
    echo 'FAIL: native procd registration stopped'; exit 1
  }
}
[ ! -e "$RUN/config.json" ] || { echo 'FAIL: conflict preflight mutated Parallax runtime'; exit 1; }
echo "NATIVE AFTER: pid=$native_pid socket=127.0.0.1:39081"
echo 'PASS: real native sing-box procd/ubus/process detected; PID, config hashes, socket unchanged; Parallax refused'
native_restore

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
