#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="$(realpath "$1")"
PACKAGES="$(realpath "$2")"
REPORT="$3"
mkdir -p "$REPORT"
REPORT="$(realpath "$REPORT")"
WORK="$(mktemp -d)"
LOOP=""
MOUNTED=0
QEMU_PID=""
cleanup() {
 rc=$?
 if [ -n "$QEMU_PID" ]; then kill "$QEMU_PID" 2>/dev/null || :; fi
 if [ "$MOUNTED" = 1 ]; then sudo umount "$WORK/mnt" || :; fi
 if [ -n "$LOOP" ]; then sudo losetup -d "$LOOP" || :; fi
 echo "$rc" >"$REPORT/exit-code.txt"
}
trap cleanup EXIT
test -c /dev/kvm || { echo "FAIL: missing KVM"; exit 1; }
sudo chmod a+rw /dev/kvm
mkdir -p "$WORK/mnt"
LOOP="$(sudo losetup --find --show --partscan "$IMAGE")"
sudo udevadm settle
PART="$(lsblk -nrpo NAME,FSTYPE "$LOOP" | awk '$2=="ext4"{print $1}' | tail -1)"
test -n "$PART"
sudo mount "$PART" "$WORK/mnt"; MOUNTED=1
sudo tee "$WORK/mnt/etc/config/network" >/dev/null <<'NET'
config interface 'loopback'
 option device 'lo'
 option proto 'static'
 option ipaddr '127.0.0.1'
 option netmask '255.0.0.0'
config device
 option name 'br-lan'
 option type 'bridge'
 list ports 'eth0'
config interface 'lan'
 option device 'br-lan'
 option proto 'dhcp'
NET
sudo python3 - "$WORK/mnt/etc/config/dhcp" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]);s=p.read_text()
pat=r"(?m)^(config\s+dhcp\s+['\"]?lan['\"]?[^\n]*\n)"
if not re.search(pat,s): raise SystemExit("LAN DHCP section missing")
p.write_text(re.sub(pat,r"\1\toption ignore '1'\n",s,count=1))
PY
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
sudo install -d -m 0700 "$WORK/mnt/etc/dropbear"
sudo install -m 0600 "$WORK/key.pub" "$WORK/mnt/etc/dropbear/authorized_keys"
# Disposable QEMU image only: set a random test password for authenticated LuCI HTTP.
TEST_WEB_PASSWORD="$(openssl rand -hex 20)"
TEST_WEB_HASH="$(printf '%s\n' "$TEST_WEB_PASSWORD" | openssl passwd -6 -stdin)"
sudo python3 - "$WORK/mnt/etc/shadow" "$TEST_WEB_HASH" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
found = False
for i, line in enumerate(lines):
    fields = line.rstrip('\n').split(':')
    if fields[0] == 'root':
        fields[1] = sys.argv[2]
        lines[i] = ':'.join(fields) + '\n'
        found = True
if not found:
    raise SystemExit('FAIL: guest root user not found in /etc/shadow')
p.write_text(''.join(lines))
PY
printf '%s' "$TEST_WEB_PASSWORD" > "$WORK/web-password"
chmod 600 "$WORK/web-password"
unset TEST_WEB_PASSWORD TEST_WEB_HASH
sudo sync
sudo umount "$WORK/mnt"; MOUNTED=0
sudo losetup -d "$LOOP"; LOOP=""
CODE="$(find /usr/share/OVMF -name 'OVMF_CODE*.fd' | sort | head -1)"
VARS="$(find /usr/share/OVMF -name 'OVMF_VARS*.fd' | sort | head -1)"
test -f "$CODE" && test -f "$VARS"
cp "$VARS" "$WORK/vars.fd"
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 1024 -smp 2 \
 -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
 -drive "if=pflash,format=raw,file=$WORK/vars.fd" \
 -drive "if=virtio,format=raw,file=$IMAGE" \
 -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
 -device virtio-net-pci,netdev=n0 -display none \
 -serial "file:$REPORT/serial.log" -monitor none >"$REPORT/qemu.log" 2>&1 &
QEMU_PID=$!
guest() { ssh -i "$WORK/key" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 root@127.0.0.1 "$@"; }
send() { scp -O -i "$WORK/key" -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$1" root@127.0.0.1:"$2"; }
READY=0
for n in $(seq 1 120); do
 kill -0 "$QEMU_PID" || { cat "$REPORT/qemu.log"; exit 1; }
 if guest 'echo ssh-ready' >/dev/null 2>&1; then READY=1; break; fi
 sleep 2
done
test "$READY" = 1
guest 'cat /etc/openwrt_release; ip -4 route; test "$(uci -q get network.lan.proto)" = dhcp' | tee "$REPORT/network.log"
guest 'apk update; apk add luci uhttpd-mod-ubus nftables-json curl ca-bundle sing-box ip-full kmod-veth; /etc/init.d/rpcd enable; /etc/init.d/rpcd restart; /etc/init.d/uhttpd enable; /etc/init.d/uhttpd restart' | tee "$REPORT/baseline.log"
guest 'test -x "$(command -v sing-box)"; sing-box version | head -n 2' | tee "$REPORT/sing-box-version.log"
# luci-i18n-parallax-ru post-install registers this language in UCI.
# Establish that stock LuCI setting before the baseline snapshot so a
# successful Parallax installation changes only /etc/config/parallax.
guest 'uci set "luci.languages.ru=Русский (Russian)"; uci commit luci'
snap() {
 mkdir -p "$REPORT/$1"
 guest 'tar -C /etc -cf - config' | tar -xf - -C "$REPORT/$1"
 guest 'nft list ruleset' >"$REPORT/$1/nft.txt"
 guest 'nft --stateless list ruleset' >"$REPORT/$1/nft-static.txt"
 guest 'apk list --installed' >"$REPORT/$1/apk.txt"
 guest 'ip -4 route show table all' >"$REPORT/$1/routes-v4.txt"
 guest 'ip -4 rule show' >"$REPORT/$1/rules-v4.txt"
 guest 'ip -6 route show table all' >"$REPORT/$1/routes-v6.txt"
 guest 'ip -6 rule show' >"$REPORT/$1/rules-v6.txt"
 guest 'cat /etc/resolv.conf' >"$REPORT/$1/resolv-conf.txt"
 guest 'test ! -f /tmp/resolv.conf.d/resolv.conf.auto || cat /tmp/resolv.conf.d/resolv.conf.auto' >"$REPORT/$1/resolv-auto.txt"
 # Capture all TCP listeners and bound UDP sockets, including short-lived
 # ephemeral UDP sockets, as forensic evidence. Those may change while the
 # QEMU guest runs unrelated OpenWrt services and are not stable diff inputs.
 guest 'awk "FNR > 1 && ((FILENAME ~ /tcp/ && \$4 == \"0A\") || (FILENAME ~ /udp/ && \$4 == \"07\")) { print FILENAME, \$2, \$4 }" /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 | sort' >"$REPORT/$1/bound-sockets-raw.txt"
 guest 'cat /proc/sys/net/ipv4/ip_local_port_range' >"$REPORT/$1/ephemeral-port-range.txt"
 read -r ephem_lo ephem_hi <"$REPORT/$1/ephemeral-port-range.txt"
 # Keep every TCP listener and every fixed UDP service port in the diff.
 # Ignore ONLY dynamic UDP ports inside the kernel ephemeral range. Full
 # data remains in bound-sockets-raw.txt. gawk exists on the CI host.
 gawk -v lo="$ephem_lo" -v hi="$ephem_hi" '
   $1 ~ /\/tcp/ { print; next }
   $1 ~ /\/udp/ {
     split($2, addr, ":")
     port = strtonum("0x" addr[2])
     if (port < lo || port > hi) print
   }
 ' "$REPORT/$1/bound-sockets-raw.txt" >"$REPORT/$1/listening-sockets.txt"
 guest 'ps w' >"$REPORT/$1/process-list.txt"
}
snap before
for name in parallax luci-app-parallax luci-i18n-parallax-ru; do
 count="$(find "$PACKAGES" -maxdepth 1 -name "$name-*.apk" | wc -l)"
 test "$count" -eq 1 || { echo "FAIL: missing $name"; exit 1; }
done
# Validate all three APKs use exactly the same release string.
for name in parallax luci-app-parallax luci-i18n-parallax-ru; do
  count="$(find "$PACKAGES" -maxdepth 1 -name "$name-0.4.0-r1.apk" | wc -l)"
  test "$count" -eq 1 || { echo "FAIL: wrong APK version for $name (expected 0.4.0-r1)"; exit 1; }
  echo "PASS: package $name version 0.4.0-r1"
done
for f in "$PACKAGES"/*.apk; do send "$f" /tmp/; done
guest 'apk add --allow-untrusted /tmp/parallax-*.apk /tmp/luci-app-parallax-*.apk /tmp/luci-i18n-parallax-ru-*.apk' | tee "$REPORT/install.log"
guest 'parallax check' | tee "$REPORT/check.log"
# Verify native ucode-mod-digest SHA256 with OpenWrt filesystem; no external sha256sum process.
send "$GITHUB_WORKSPACE/tests/ucode_digest.uc" /tmp/parallax-digest.uc
guest 'ucode /tmp/parallax-digest.uc' | tee "$REPORT/ucode-digest.log"
# A second stop when no Parallax service is registered must be silent.
guest 'set -eu
/etc/init.d/parallax stop
/etc/init.d/parallax stop
echo "PASS: repeated stop on unregistered service is silent"
' 2>&1 | tee "$REPORT/stop-idempotence.log"
if grep -Fq 'Command failed: ubus call service delete' "$REPORT/stop-idempotence.log"; then
  echo "FAIL: repeated stop emitted redundant procd delete"
  exit 1
fi
guest 'uci set parallax.main.enabled=1; uci commit parallax; /etc/init.d/parallax enable; /etc/init.d/parallax restart' 2>&1 | tee "$REPORT/start.log"
if grep -Fq 'Command failed: ubus call service delete' "$REPORT/start.log"; then
  echo "FAIL: restart emitted redundant procd delete"
  exit 1
fi
READY=0
for n in $(seq 1 30); do
 if guest 'ubus list parallax' >/dev/null 2>&1; then READY=1; break; fi
 sleep 1
done
test "$READY" = 1
guest 'ubus -v list parallax' | tee "$REPORT/ubus-list.log"
# Native ucode ubus validates method arguments strictly. The HTTP /ubus
# gateway injects ubus_rpc_session; ensure both read-only methods accept it.
# The all-zero SID here is only an argument-shape fixture on a local root CLI.
guest 'set -eu
echo "CHECK: ubus method policy accepts injected ubus_rpc_session string"
ubus call parallax status "{\"ubus_rpc_session\":\"00000000000000000000000000000000\"}"
ubus call parallax ping "{\"ubus_rpc_session\":\"00000000000000000000000000000000\"}"
if ubus call parallax status "{\"unexpected\":\"value\"}" >/dev/null 2>&1; then
    echo "FAIL: unexpected ubus argument was accepted" >&2
    exit 1
fi
echo "PASS: status/ping accept injected SID; unknown parameter rejected"
' 2>&1 | tee "$REPORT/ubus-session-argument.log"
guest "ubus call parallax status '{}'" | tee "$REPORT/status.log"
guest "ubus call parallax ping '{}'" | tee "$REPORT/ping.log"
# An event-loop timer ticks each 10s; compare two ubus snapshots 18s apart.
guest 'set -eu
first="$(ubus call parallax status "{}" | jsonfilter -e "@.heartbeat_seq")"
echo "CHECK: first heartbeat_seq=$first"
sleep 18
second="$(ubus call parallax status "{}" | jsonfilter -e "@.heartbeat_seq")"
echo "CHECK: second heartbeat_seq=$second after 18 seconds"
case "$first:$second" in
  *[!0-9:]*|:*|*:) echo "FAIL: invalid heartbeat counters"; exit 1 ;;
esac
if [ "$second" -le "$first" ]; then
  echo "FAIL: heartbeat_seq did not advance over 18 seconds"
  exit 1
fi
echo "PASS: heartbeat_seq increased over 18 seconds"
' 2>&1 | tee "$REPORT/heartbeat.log"
guest 'parallax status' | tee "$REPORT/cli-status.log"
send "$GITHUB_WORKSPACE/tests/ucode_runtime.uc" /tmp/ucode_runtime.uc
guest 'ucode /tmp/ucode_runtime.uc' | tee "$REPORT/ucode.log"
# MVP-b config-only candidate: it must be private and contain NO listeners.
send "$GITHUB_WORKSPACE/tests/ucode_permissions.uc" /tmp/parallax-permissions.uc
guest 'set -eu; result="$(parallax render)"; case "$result" in "Candidate written privately: /run/parallax/candidate."*) ;; *) exit 1 ;; esac; candidate="${result##* }"; test -f "$candidate"; ucode /tmp/parallax-permissions.uc "$candidate" file; cp "$candidate" /tmp/parallax-candidate.json; rm -f "$candidate"'
send "$GITHUB_WORKSPACE/tests/ucode_render.uc" /tmp/ucode_render.uc
guest 'ucode /tmp/ucode_render.uc; rm -f /tmp/parallax-candidate.json' | tee "$REPORT/ucode-render.log"

# Full config-only transaction lifecycle against the installed sing-box binary.
# Only metadata (hashes/revision IDs) leaves this guest. No JSON/credentials in logs.
guest 'set -eu
parallax validate
first="$(parallax apply --config-only)"
printf "%s\n" "$first"
rev="$(printf "%s\n" "$first" | sed -n "s/^applied revision=\([^ ]*\) sha256=.*/\1/p")"
test -n "$rev"
ucode /tmp/parallax-permissions.uc /etc/parallax/generated directory
ucode /tmp/parallax-permissions.uc /etc/parallax/generated/active.json file
original="$(sha256sum /etc/parallax/generated/active.json | cut -d " " -f1)"
parallax history
parallax diff | grep -q "^unchanged "
uci set parallax.ci_rule=rule
uci set parallax.ci_rule.enabled=1
uci set parallax.ci_rule.match=domain_suffix
uci add_list parallax.ci_rule.value=example.net
uci set parallax.ci_rule.outbound=direct
uci set parallax.ci_rule.priority=100
uci commit parallax
parallax validate
second="$(parallax apply --config-only)"
printf "%s\n" "$second"
changed="$(sha256sum /etc/parallax/generated/active.json | cut -d " " -f1)"
test "$changed" != "$original"
test "$(parallax history | grep -c "^rev-")" -ge 2
uci set parallax.main.default_outbound=missingoutbound
uci commit parallax
if parallax apply --config-only >/dev/null 2>&1; then
    echo "FAIL: invalid outbound was accepted" >&2
    exit 1
fi
test "$(sha256sum /etc/parallax/generated/active.json | cut -d " " -f1)" = "$changed"
uci set parallax.main.default_outbound=direct
uci commit parallax
parallax rollback "$rev"
test "$(sha256sum /etc/parallax/generated/active.json | cut -d " " -f1)" = "$original"
test -z "$(pidof sing-box || true)"
echo "PASS: validated config-only apply/history/diff/rollback, no sing-box daemon"
' | tee "$REPORT/config-only-transaction.log"

# Validate a synthetic VLESS/Reality outbound with the real installed sing-box.
# The test keypair is created within disposable QEMU, never printed or uploaded.
guest 'set -eu
mkdir -p /etc/parallax/credentials
chmod 0700 /etc/parallax/credentials
printf "%s\n" "{\"uuid\":\"00000000-0000-4000-8000-000000000001\"}" > /etc/parallax/credentials/ci_profile.json
chmod 0600 /etc/parallax/credentials/ci_profile.json
keys="$(sing-box generate reality-keypair)"
public="$(printf "%s\n" "$keys" | awk "/^PublicKey:/ {print \$2}")"
test "$(printf "%s" "$public" | wc -c)" = 43
unset keys
uci set parallax.ci_profile=profile
uci set parallax.ci_profile.enabled=1
uci set parallax.ci_profile.protocol=vless
uci set parallax.ci_profile.server=example.net
uci set parallax.ci_profile.port=443
uci set parallax.ci_profile.credential_ref=ci_profile
uci set parallax.ci_profile.tls_sni=example.net
uci set parallax.ci_profile.reality_public_key="$public"
uci set parallax.ci_profile.reality_short_id=01234567
uci set parallax.ci_profile.utls_fingerprint=chrome
uci set parallax.ci_rule.outbound=ci_profile
uci commit parallax
parallax validate
out="$(parallax apply --config-only)"
printf "%s\n" "$out"
before="$(sha256sum /etc/parallax/generated/active.json | cut -d " " -f1)"
chmod 0644 /etc/parallax/credentials/ci_profile.json
if parallax validate >/dev/null 2>&1; then
    echo "FAIL: insecure credential permissions accepted" >&2
    exit 1
fi
chmod 0600 /etc/parallax/credentials/ci_profile.json
if parallax history | grep -q 00000000-0000-4000-8000-000000000001; then
    echo "FAIL: credential leaked through history" >&2
    exit 1
fi
uci set parallax.ci_profile.credential_ref=missing_secret
uci commit parallax
if parallax apply --config-only >/dev/null 2>&1; then
    echo "FAIL: missing credentials accepted" >&2
    exit 1
fi
test "$(sha256sum /etc/parallax/generated/active.json | cut -d " " -f1)" = "$before"
uci delete parallax.ci_profile
uci set parallax.ci_rule.outbound=direct
uci commit parallax
rm -f /etc/parallax/credentials/ci_profile.json
parallax validate
test -z "$(pidof sing-box || true)"
echo "PASS: real VLESS Reality check, credentials fail-closed and no leaks"
' | tee "$REPORT/vless-reality-validation.log"

# Malformed UCI inputs must fail before promotion. Keep credentials out of logs.
send "$GITHUB_WORKSPACE/tests/negative_validation.sh" /tmp/parallax-negative-validation.sh
guest 'sh /tmp/parallax-negative-validation.sh' 2>&1 | tee "$REPORT/negative-validation.log"

# Live transaction contention and process-crash tests run only inside QEMU.
send "$GITHUB_WORKSPACE/tests/ucode_lock_holder.uc" /tmp/parallax-ci-lock-holder.uc
send "$GITHUB_WORKSPACE/tests/transaction_recovery.sh" /tmp/parallax-ci-transaction-recovery.sh
guest 'sh /tmp/parallax-ci-transaction-recovery.sh' 2>&1 | tee "$REPORT/transaction-recovery.log"

# Protected LuCI pages require an authenticated session: an anonymous
# request returns HTTP 403 + X-LuCI-Login-Required by design.
send "$WORK/web-password" /tmp/parallax-ci-web-password
guest 'chmod 600 /tmp/parallax-ci-web-password'
guest 'test -s /usr/share/luci/menu.d/luci-app-parallax.json; test -s /usr/share/rpcd/acl.d/luci-app-parallax.json; grep -q "parallax/overview" /usr/share/luci/menu.d/luci-app-parallax.json; grep -q "status" /usr/share/rpcd/acl.d/luci-app-parallax.json'
guest 'code=$(curl -sS -c /tmp/parallax-cookie -o /tmp/parallax-auth-response -w "%{http_code}" -d "luci_username=root" --data-urlencode "luci_password@/tmp/parallax-ci-web-password" http://127.0.0.1/cgi-bin/luci/admin/services/parallax); test "$code" = 302 || { echo "FAIL: LuCI login expected 302; got $code"; exit 1; }; grep -q "sysauth_http" /tmp/parallax-cookie; rm -f /tmp/parallax-ci-web-password'
guest 'curl -fsS -b /tmp/parallax-cookie http://127.0.0.1/cgi-bin/luci/admin/services/parallax -o /tmp/page.html; test -s /tmp/page.html; grep -Eq "luci|LuCI" /tmp/page.html; wc -c /tmp/page.html' | tee "$REPORT/luci-authenticated-page.log"
# Run the ACL check before testing the static JS so a LuCI asset failure cannot
# leave rpcd-acl.log empty. Preserve stdout, stderr and the remote exit code.
send "$GITHUB_WORKSPACE/tests/rpcd_acl.sh" /tmp/parallax-rpcd-acl.sh
set +e
guest 'sh /tmp/parallax-rpcd-acl.sh' 2>&1 | tee "$REPORT/rpcd-acl.log"
acl_rc=${PIPESTATUS[0]}
set -e
if [ "$acl_rc" -ne 0 ]; then
  echo "FAIL: rpcd ACL smoke (remote exit=$acl_rc)" | tee -a "$REPORT/rpcd-acl.log"
  exit "$acl_rc"
fi
# Never use curl | grep -q with pipefail: grep may close the pipe early and
# curl then exits 23 (SIGPIPE). Fetch fully and assert HTTP and JS separately.
guest '
  url="http://127.0.0.1/luci-static/resources/view/parallax/overview.js"
  body=/tmp/parallax-ci-overview.js
  headers=/tmp/parallax-ci-overview.headers
  errors=/tmp/parallax-ci-overview.curl-stderr
  if code="$(curl -sS --max-time 15 -b /tmp/parallax-cookie -D "$headers" -o "$body" -w "%{http_code}" "$url" 2>"$errors")"; then
    curl_rc=0
  else
    curl_rc=$?
  fi
  echo "LuCI JS: curl exit=$curl_rc HTTP=$code"
  if [ -s "$errors" ]; then cat "$errors"; fi
  if [ "$curl_rc" -ne 0 ] || [ "$code" != 200 ] || [ ! -s "$body" ]; then
    echo "FAIL: LuCI JS missing or HTTP failure"
    if [ -f "$headers" ]; then sed -n "1,15p" "$headers"; fi
    exit 1
  fi
  if ! grep -Fq daemon_running "$body"; then
    echo "FAIL: LuCI JS response missing daemon_running"
    sed -n "1,15p" "$headers"
    head -c 200 "$body"
    printf "\n"
    exit 1
  fi
  echo "PASS: LuCI JS HTTP=$code bytes=$(wc -c < "$body") contains daemon_running"
' 2>&1 | tee "$REPORT/luci-js.log"
OLD="$(guest 'pidof ucode' | awk '{print $1}')"
test -n "$OLD"
guest "kill -9 $OLD"
NEW=""
for n in $(seq 1 35); do
 NEW="$(guest 'pidof ucode' 2>/dev/null | awk '{print $1}' || :)"
 if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && guest 'ubus call parallax ping "{}"' >/dev/null 2>&1; then break; fi
 sleep 2
done
test -n "$NEW" && test "$NEW" != "$OLD"
echo "old=$OLD new=$NEW" | tee "$REPORT/respawn.log"
# Separate MVP-c1 gate: all probes execute inside this disposable QEMU guest.
# The new package has no network-state ownership: every network diff is empty.
snap c1-before
send "$GITHUB_WORKSPACE/tests/mvp_c1_guest.sh" /tmp/parallax-mvp-c1-guest.sh
guest 'sh /tmp/parallax-mvp-c1-guest.sh' 2>&1 | tee "$REPORT/mvp-c1-gate.log"
snap c1-after
for invariant in nft-static routes-v4 rules-v4 routes-v6 rules-v6 resolv-conf resolv-auto; do
  diff -u "$REPORT/c1-before/$invariant.txt" "$REPORT/c1-after/$invariant.txt" > "$REPORT/mvp-c1-$invariant-diff.txt" || {
    echo "FAIL: MVP-c1 modified $invariant"
    exit 1
  }
done
# The process started and stopped without modifying other UCI config.
diff -ruN "$REPORT/c1-before/config" "$REPORT/c1-after/config" >"$REPORT/mvp-c1-uci-diff.txt"
echo "PASS: MVP-c1 QEMU, rootless procd, security, respawn, zero nft/routes/ip rule/DNS/fw4 diff" |
  tee "$REPORT/mvp-c1-PASS.txt"
# MVP-c2a-0 is OFFLINE UCI + READ-ONLY preflight: no writes to kernel.
# Evidence includes raw before/after snapshots and fail-closed binding fixtures.
snap c2a0-before
send "$GITHUB_WORKSPACE/tests/mvp_c2a0_guest.sh" /tmp/parallax-mvp-c2a0-guest.sh
guest 'sh /tmp/parallax-mvp-c2a0-guest.sh' 2>&1 | tee "$REPORT/mvp-c2a0-gate.log"
# Export separately the actual production-preflight decisions from the
# temporary QEMU network namespace (not synthetic neighbour fixtures).
guest 'cat /tmp/parallax-c2a0/real-reachable.log' > "$REPORT/mvp-c2a0-real-reachable.log"
guest 'cat /tmp/parallax-c2a0/real-stale.log' > "$REPORT/mvp-c2a0-real-stale.log"
snap c2a0-after
guest 'test -z "$(ip netns list)"; ! ip link show dev pxc2a0h >/dev/null 2>&1' |
  tee "$REPORT/mvp-c2a0-netns-cleanup.txt"
for invariant in nft-static routes-v4 rules-v4 routes-v6 rules-v6 resolv-conf resolv-auto; do
  diff -u "$REPORT/c2a0-before/$invariant.txt" "$REPORT/c2a0-after/$invariant.txt" > "$REPORT/mvp-c2a0-$invariant-diff.txt" || {
    echo "FAIL: MVP-c2a-0 changed $invariant"
    exit 1
  }
done
diff -ruN "$REPORT/c2a0-before/config" "$REPORT/c2a0-after/config" > "$REPORT/mvp-c2a0-uci-diff.txt" || {
  echo 'FAIL: MVP-c2a-0 did not restore original committed UCI'
  exit 1
}
echo 'PASS: MVP-c2a-0 offline UCI migration and read-only preflight; zero network and final UCI diff' |
  tee "$REPORT/mvp-c2a0-PASS.txt"
snap after-install
guest 'set -eu
/etc/init.d/parallax stop
/etc/init.d/parallax stop
/etc/init.d/parallax disable
apk del luci-i18n-parallax-ru luci-app-parallax parallax
' 2>&1 | tee "$REPORT/remove.log"
if grep -Fq 'Command failed: ubus call service delete' "$REPORT/remove.log"; then
  echo "FAIL: apk del emitted redundant procd delete"
  exit 1
fi
snap after-remove
for stage in after-install after-remove; do
 diff -ruN "$REPORT/before/config" "$REPORT/$stage/config" >"$REPORT/config-diff-$stage.txt" || :
 diff -u "$REPORT/before/nft.txt" "$REPORT/$stage/nft.txt" >"$REPORT/nft-diff-$stage.txt" || :
 cp -a "$REPORT/$stage/config" "$WORK/config-$stage"
 rm -f "$WORK/config-$stage/parallax"
 diff -ruN "$REPORT/before/config" "$WORK/config-$stage" >"$REPORT/other-config-$stage.txt"
 diff -u "$REPORT/before/nft-static.txt" "$REPORT/$stage/nft-static.txt"
 diff -u "$REPORT/before/routes-v4.txt" "$REPORT/$stage/routes-v4.txt"
 diff -u "$REPORT/before/rules-v4.txt" "$REPORT/$stage/rules-v4.txt"
 for evidence in routes-v6 rules-v6 resolv-conf resolv-auto ephemeral-port-range listening-sockets; do
  diff -u "$REPORT/before/$evidence.txt" "$REPORT/$stage/$evidence.txt" >"$REPORT/$evidence-diff-$stage.txt"
 done
done
if guest 'ubus list parallax' >/dev/null 2>&1; then echo "FAIL: ubus object remains"; exit 1; fi
guest 'test ! -e /run/parallax-singbox/config.json; if /etc/init.d/parallax-singbox enabled >/dev/null 2>&1; then echo "FAIL: c1 package removal left autostart"; exit 1; fi; echo "PASS: apk del leaves no parallax-singbox runtime or boot autostart"' | tee "$REPORT/mvp-c1-remove.log"
# Normal apk removal must preserve edited UCI conffile and private user data.
guest 'set -eu
test -f /etc/config/parallax
test "$(uci -q get parallax.main.enabled)" = 1
test "$(uci -q get parallax.ci_rule.match)" = domain_suffix
test -f /etc/parallax/generated/active.json
test -d /etc/parallax/credentials
echo "AFTER apk del: retained user data (metadata only; no credentials/JSON printed)"
for path in /etc/config/parallax /etc/parallax /etc/parallax/generated /etc/parallax/generated/active.json /etc/parallax/credentials; do
  test -e "$path"
  ls -ld "$path"
done
echo "Revisions retained:"
find /etc/parallax/generated -maxdepth 1 -name "rev-*.json" -type f | wc -l
test -f /etc/parallax/.reinstall-stopped
echo "REINSTALL GUARD: protected marker present after apk del"
echo "PASS: apk del retains edited conffile, credentials directory and revision store"
' 2>&1 | tee "$REPORT/remove-preservation.log"
# Reinstall before explicitly purging so the admin command is available.
guest 'apk add --allow-untrusted /tmp/parallax-*.apk /tmp/luci-app-parallax-*.apk /tmp/luci-i18n-parallax-ru-*.apk' | tee "$REPORT/reinstall.log"
# A retained enabled=1 config must never auto-launch the daemon on reinstall.
# Confirm the package postinst restored manual-start-only policy and cleared
# the temporary marker before checking explicit administrator re-enable.
guest 'set -eu
test ! -e /etc/parallax/.reinstall-stopped
if /etc/init.d/parallax enabled >/dev/null 2>&1; then
  echo "FAIL: init script auto-enabled after reinstall"
  exit 1
fi
if ubus list parallax >/dev/null 2>&1; then
  echo "FAIL: service automatically started after reinstall"
  exit 1
fi
echo "PASS: reinstall retained enabled=1 UCI, but daemon and autostart remain disabled"
' 2>&1 | tee "$REPORT/reinstall-stopped.log"
# procd starts the daemon asynchronously. Wait for a live ubus reply
# after explicit admin start instead of racing registration with ubusd.
guest 'set -eu
echo "COMMAND: /etc/init.d/parallax enable"
/etc/init.d/parallax enable
/etc/init.d/parallax enabled || { echo "FAIL: explicit enable did not create rc.d links"; exit 1; }
echo "COMMAND: /etc/init.d/parallax start"
/etc/init.d/parallax start || { echo "FAIL: explicit start command failed"; exit 1; }
ready=0
for attempt in $(seq 1 30); do
  if ubus list parallax >/dev/null 2>&1 &&
     ubus call parallax ping "{}" >/tmp/parallax-reinstall-ping.json 2>/tmp/parallax-reinstall-ping.err; then
    ready=1
    echo "READY: parallax ubus registered and ping answered (poll=$attempt)"
    cat /tmp/parallax-reinstall-ping.json
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: explicitly started daemon did not register ubus within 30 seconds"
  echo "DIAGNOSTIC: procd service status"
  /etc/init.d/parallax status || :
  echo "DIAGNOSTIC: ping error"
  cat /tmp/parallax-reinstall-ping.err 2>/dev/null || :
  echo "DIAGNOSTIC: recent system messages"
  logread | tail -n 35 || :
  exit 1
fi
ok="$(jsonfilter -i /tmp/parallax-reinstall-ping.json -e "@.ok" 2>/dev/null || :)"
[ "$ok" = true ] || { echo "FAIL: ping did not return ok=true"; exit 1; }
ubus call parallax status "{}"
echo "PASS: explicit administrator enable+start succeeds after reinstall (ubus ready)"
' 2>&1 | tee "$REPORT/reinstall-explicit-start.log"
guest 'set -eu
echo "CHECK: interrupted reinstall guard must fail closed on unsafe marker"
marker=/etc/parallax/.reinstall-stopped
printf "sentinel\n" >/tmp/parallax-purge-sentinel
ln -s /tmp/parallax-purge-sentinel "$marker"
if parallax purge --confirm-delete-all >/tmp/parallax-purge-bad-marker.log 2>&1; then
  echo "FAIL: purge accepted symlink marker"
  exit 1
fi
test "$(cat /tmp/parallax-purge-sentinel)" = sentinel
test -f /etc/config/parallax
test -f /etc/parallax/generated/active.json
echo "PASS: symlink marker rejected without deleting user data"
rm -f "$marker" /tmp/parallax-purge-sentinel
: >"$marker"
chmod 0644 "$marker"
if parallax purge --confirm-delete-all >/tmp/parallax-purge-bad-marker.log 2>&1; then
  echo "FAIL: purge accepted insecure marker permissions"
  exit 1
fi
test -f /etc/config/parallax
test -f /etc/parallax/generated/active.json
echo "PASS: insecure marker rejected without deleting user data"
chmod 0600 "$marker"
echo "COMMAND: parallax purge --confirm-delete-all (recover interrupted reinstall)"
parallax purge --confirm-delete-all
for path in /etc/config/parallax /etc/parallax /etc/parallax/generated /etc/parallax/credentials /etc/parallax/.reinstall-stopped; do
  test ! -e "$path" || { echo "FAIL: remains after purge: $path"; exit 1; }
  echo "ABSENT after purge: $path"
done
echo "COMMAND: apk del luci-i18n-parallax-ru luci-app-parallax parallax"
apk del luci-i18n-parallax-ru luci-app-parallax parallax
test ! -e /etc/config/parallax
test ! -e /etc/parallax
echo "PASS: explicit purge removes UCI, credentials and revisions; apk del leaves nothing"
' 2>&1 | tee "$REPORT/purge.log"
if grep -Fq 'Command failed: ubus call service delete' "$REPORT/purge.log"; then
  echo "FAIL: purge emitted redundant procd delete"
  exit 1
fi

echo "PASS QEMU KVM" | tee "$REPORT/PASS.txt"
