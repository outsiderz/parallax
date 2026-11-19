#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs inside disposable OpenWrt QEMU after authenticated LuCI login.
# Never print the live SID, cookie or test password to CI artifacts.
set -eu
umask 077

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_json() {
    file="$1" path="$2" expected="$3"
    actual="$(jsonfilter -i "$file" -e "$path" 2>/dev/null || :)"
    echo "ASSERT: $path = $expected (got: ${actual:-<missing>})"
    [ "$actual" = "$expected" ] || fail "JSON assertion $path expected $expected"
}
request() {
    session_id="$1" label="$2" method="$3" destination="$4"
    payload="$(printf '{"jsonrpc":"2.0","id":1,"method":"call","params":["%s","parallax","%s",{}]}' "$session_id" "$method")"
    echo "COMMAND: curl -sS --max-time 15 -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$label\",\"parallax\",\"$method\",{}]}' http://127.0.0.1/ubus"
    rm -f "$destination" "$destination.stderr"
    if http="$(curl -sS --max-time 15 -H 'Content-Type: application/json' -d "$payload" -o "$destination" -w '%{http_code}' http://127.0.0.1/ubus 2>"$destination.stderr")"; then
        curl_rc=0
    else
        curl_rc=$?
    fi
    echo "RESULT: curl_exit=$curl_rc HTTP=$http"
    if [ -s "$destination.stderr" ]; then
        echo 'CURL STDERR:'
        cat "$destination.stderr"
    fi
    if [ -f "$destination" ]; then
        echo 'JSON-RPC RESPONSE:'
        cat "$destination"
        printf '\n'
    else
        echo 'JSON-RPC RESPONSE: <no response file>'
    fi
    [ "$curl_rc" -eq 0 ] || fail "curl failed for $label/$method"
    [ "$http" = 200 ] || fail "HTTP $http for $label/$method (expected 200)"
    [ -s "$destination" ] || fail "empty JSON-RPC body for $label/$method"
}
access_check() {
    method="$1"
    echo "COMMAND: ubus call session access '{\"ubus_rpc_session\":\"[REDACTED]\",\"scope\":\"ubus\",\"object\":\"parallax\",\"function\":\"$method\"}'"
    payload="$(printf '{"ubus_rpc_session":"%s","scope":"ubus","object":"parallax","function":"%s"}' "$sid" "$method")"
    if answer="$(ubus call session access "$payload" 2>&1)"; then
        echo "UBUS RESPONSE: $answer"
    else
        rc=$?
        echo "UBUS ERROR (exit=$rc): $answer"
        fail "session access for parallax/$method"
    fi
    allowed="$(printf '%s\n' "$answer" | jsonfilter -e '@.access' 2>/dev/null || :)"
    [ "$allowed" = true ] || fail "session ACL denied parallax/$method"
    echo "PASS: session access parallax/$method = true"
}

echo 'CHECK: rpcd and uhttpd processes, /ubus backend and installed ACL'
for daemon in rpcd uhttpd; do
    echo "COMMAND: pidof $daemon"
    if pids="$(pidof "$daemon" 2>&1)"; then
        echo "RESULT: $daemon running (PID: $pids)"
    else
        echo "RESULT: $pids"
        fail "$daemon is not running"
    fi
done
echo 'COMMAND: apk list --installed | grep uhttpd-mod-ubus'
if apk list --installed | grep -F 'uhttpd-mod-ubus-'; then
    echo 'PASS: uhttpd-mod-ubus installed'
else
    fail 'uhttpd-mod-ubus missing'
fi
echo 'COMMAND: ubus -v list session'
ubus -v list session || fail 'rpcd session object missing'
test -s /usr/share/rpcd/acl.d/luci-app-parallax.json || fail 'Parallax ACL file missing'
grep -q '"parallax"' /usr/share/rpcd/acl.d/luci-app-parallax.json || fail 'Parallax ACL missing ubus object'
grep -q '"status"' /usr/share/rpcd/acl.d/luci-app-parallax.json || fail 'Parallax ACL missing status permission'
grep -q '"ping"' /usr/share/rpcd/acl.d/luci-app-parallax.json || fail 'Parallax ACL missing ping permission'
echo 'PASS: luci-app-parallax ACL file declares parallax status/ping'

sid="$(awk '$6 == "sysauth_http" { print $7; exit }' /tmp/parallax-cookie)" || fail 'cannot read LuCI cookie'
printf '%s\n' "$sid" | grep -Eq '^[a-f0-9]{32}$' || fail 'LuCI did not create a usable rpcd session'
echo 'PASS: authenticated LuCI rpcd SID obtained (32 hex characters; value redacted)'

access_check status
access_check ping
request "$sid" '[REDACTED]' status /tmp/parallax-rpcd-status.json
assert_json /tmp/parallax-rpcd-status.json '@.result[0]' 0
assert_json /tmp/parallax-rpcd-status.json '@.result[1].name' parallax
assert_json /tmp/parallax-rpcd-status.json '@.result[1].daemon_running' true
assert_json /tmp/parallax-rpcd-status.json '@.result[1].routing_active' false
request "$sid" '[REDACTED]' ping /tmp/parallax-rpcd-ping.json
assert_json /tmp/parallax-rpcd-ping.json '@.result[0]' 0
assert_json /tmp/parallax-rpcd-ping.json '@.result[1].ok' true

# Direct /ubus must not fall back to a LuCI cookie or default root privileges.
request 00000000000000000000000000000000 00000000000000000000000000000000 status /tmp/parallax-rpcd-anon.json
denied_status="$(jsonfilter -i /tmp/parallax-rpcd-anon.json -e '@.result[0]' 2>/dev/null || :)"
denied_error="$(jsonfilter -i /tmp/parallax-rpcd-anon.json -e '@.error.code' 2>/dev/null || :)"
echo "CHECK: anonymous denial (ubus_status=${denied_status:-<missing>}, jsonrpc_error=${denied_error:-<missing>})"
if [ "$denied_status" != 6 ] && [ "$denied_error" != -32002 ]; then
    fail 'anonymous request was not explicitly denied (expected ubus status 6 or JSON-RPC -32002)'
fi
echo 'PASS: authenticated LuCI SID -> rpcd status/ping; 32-zero anonymous SID -> access denied'
