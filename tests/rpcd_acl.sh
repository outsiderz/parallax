#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs inside OpenWrt QEMU after authenticated LuCI login.
set -eu
sid="$(awk '$6 == "sysauth_http" { print $7 }' /tmp/parallax-cookie)"
printf '%s\n' "$sid" | grep -Eq '^[a-f0-9]{32}$' || {
  echo "FAIL: LuCI did not create a usable rpcd session" >&2
  exit 1
}
request() {
  local sid_arg="$1" method_arg="$2" destination="$3" payload
  payload="$(printf '{"jsonrpc":"2.0","id":1,"method":"call","params":["%s","parallax","%s",{}]}' "$sid_arg" "$method_arg")"
  curl -fsS -H 'Content-Type: application/json' --data "$payload" \
    http://127.0.0.1/ubus -o "$destination"
}
request "$sid" status /tmp/parallax-rpcd-status.json
test "$(jsonfilter -i /tmp/parallax-rpcd-status.json -e '@.result[0]')" = "0"
test "$(jsonfilter -i /tmp/parallax-rpcd-status.json -e '@.result[1].name')" = parallax
test "$(jsonfilter -i /tmp/parallax-rpcd-status.json -e '@.result[1].daemon_running')" = true
test "$(jsonfilter -i /tmp/parallax-rpcd-status.json -e '@.result[1].routing_active')" = false
request "$sid" ping /tmp/parallax-rpcd-ping.json
test "$(jsonfilter -i /tmp/parallax-rpcd-ping.json -e '@.result[0]')" = "0"
test "$(jsonfilter -i /tmp/parallax-rpcd-ping.json -e '@.result[1].ok')" = true
# A synthetic anonymous session must NOT read the status object.
request 00000000000000000000000000000000 status /tmp/parallax-rpcd-anon.json
test "$(jsonfilter -i /tmp/parallax-rpcd-anon.json -e '@.result[0]')" != "0"
rm -f /tmp/parallax-rpcd-status.json /tmp/parallax-rpcd-ping.json /tmp/parallax-rpcd-anon.json
echo 'PASS: authenticated LuCI session -> rpcd status/ping; anonymous denied'
