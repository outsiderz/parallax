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
  fixture_stop
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

# QEMU-only live socket fixture: start a separate sing-box process without
# invoking or editing the native /etc/init.d/sing-box or /etc/config/sing-box.
# Its SOCKS listener owns a real TCP port. The procd response remains mocked
# because registering the native service would violate the isolation contract.
FIXTURE_PID=''
fixture_stop() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || :
    wait "$FIXTURE_PID" 2>/dev/null || :
    FIXTURE_PID=''
  fi
}
cat >"$TMP/native-fixture.json" <<'JSON'
{"log":{"level":"warn"},"inbounds":[{"type":"socks","tag":"native-fixture","listen":"127.0.0.1","listen_port":39081}],"outbounds":[{"type":"direct","tag":"direct"}]}
JSON
sing-box check -c "$TMP/native-fixture.json" >"$TMP/fixture-check.log" 2>&1 || {
  echo 'FAIL: live socket fixture configuration was rejected'
  cat "$TMP/fixture-check.log"
  exit 1
}
sing-box run -c "$TMP/native-fixture.json" >"$TMP/fixture-run.log" 2>&1 &
FIXTURE_PID=$!
porthex="$(printf '%04X' 39081)"
listening=0
for n in $(seq 1 30); do
  kill -0 "$FIXTURE_PID" 2>/dev/null || break
  if awk -v port="$porthex" '$2 ~ (":" port "$") && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp; then
    listening=1
    break
  fi
  sleep 1
done
if [ "$listening" -ne 1 ]; then
  echo 'FAIL: competing sing-box did not bind TCP port 39081'
  cat "$TMP/fixture-run.log"
  exit 1
fi
echo "FIXTURE: live sing-box pid=$FIXTURE_PID bound 127.0.0.1:39081"
cat >"$TMP/ubus" <<'SH'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = service ] && [ "$3" = list ]; then
    case "$4" in
      *'"name":"sing-box"'*)
        printf '{"sing-box":{"instances":{"test":{"running":true,"pid":%s}}}}\\n' "$MVP_C1_FIXTURE_PID"
        exit 0 ;;
    esac
fi
exec /bin/ubus "$@"
SH
chmod 0700 "$TMP/ubus"
if MVP_C1_FIXTURE_PID="$FIXTURE_PID" PATH="$TMP:$PATH" parallax singbox start >"$TMP/native-conflict.log" 2>&1; then
  echo 'FAIL: live sing-box/procd conflict fixture was accepted'
  exit 1
fi
grep -Fq 'native sing-box is running' "$TMP/native-conflict.log" || {
  echo 'FAIL: conflict refusal did not identify competing sing-box'
  exit 1
}
kill -0 "$FIXTURE_PID" 2>/dev/null || {
  echo 'FAIL: conflict refusal terminated a foreign sing-box process'
  exit 1
}
awk -v port="$porthex" '$2 ~ (":" port "$") && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp || {
  echo 'FAIL: conflict refusal released foreign listener'
  exit 1
}
[ ! -e "$RUN/config.json" ] || { echo 'FAIL: conflict preflight mutated runtime'; exit 1; }
echo 'PASS: live TCP socket occupied by competing sing-box; synthetic procd registration rejected without stopping foreign process'
rm -f "$TMP/ubus"
fixture_stop

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
