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
guest 'apk update; apk add luci nftables-json curl ca-bundle sing-box; /etc/init.d/uhttpd enable; /etc/init.d/uhttpd restart' | tee "$REPORT/baseline.log"
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
}
snap before
for name in parallax luci-app-parallax luci-i18n-parallax-ru; do
 count="$(find "$PACKAGES" -maxdepth 1 -name "$name-*.apk" | wc -l)"
 test "$count" -eq 1 || { echo "FAIL: missing $name"; exit 1; }
done
for f in "$PACKAGES"/*.apk; do send "$f" /tmp/; done
guest 'apk add --allow-untrusted /tmp/parallax-*.apk /tmp/luci-app-parallax-*.apk /tmp/luci-i18n-parallax-ru-*.apk' | tee "$REPORT/install.log"
guest 'parallax check' | tee "$REPORT/check.log"
guest 'uci set parallax.main.enabled=1; uci commit parallax; /etc/init.d/parallax enable; /etc/init.d/parallax restart' | tee "$REPORT/start.log"
READY=0
for n in $(seq 1 30); do
 if guest 'ubus list parallax' >/dev/null 2>&1; then READY=1; break; fi
 sleep 1
done
test "$READY" = 1
guest 'ubus -v list parallax' | tee "$REPORT/ubus-list.log"
guest "ubus call parallax status '{}'" | tee "$REPORT/status.log"
guest "ubus call parallax ping '{}'" | tee "$REPORT/ping.log"
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


# Protected LuCI pages require an authenticated session: an anonymous
# request returns HTTP 403 + X-LuCI-Login-Required by design.
send "$WORK/web-password" /tmp/parallax-ci-web-password
guest 'chmod 600 /tmp/parallax-ci-web-password'
guest 'test -s /usr/share/luci/menu.d/luci-app-parallax.json; test -s /usr/share/rpcd/acl.d/luci-app-parallax.json; grep -q "parallax/overview" /usr/share/luci/menu.d/luci-app-parallax.json; grep -q "status" /usr/share/rpcd/acl.d/luci-app-parallax.json'
guest 'code=$(curl -sS -c /tmp/parallax-cookie -o /tmp/parallax-auth-response -w "%{http_code}" -d "luci_username=root" --data-urlencode "luci_password@/tmp/parallax-ci-web-password" http://127.0.0.1/cgi-bin/luci/admin/services/parallax); test "$code" = 302 || { echo "FAIL: LuCI login expected 302; got $code"; exit 1; }; grep -q "sysauth_http" /tmp/parallax-cookie; rm -f /tmp/parallax-ci-web-password'
guest 'curl -fsS -b /tmp/parallax-cookie http://127.0.0.1/cgi-bin/luci/admin/services/parallax -o /tmp/page.html; test -s /tmp/page.html; grep -Eq "luci|LuCI" /tmp/page.html; wc -c /tmp/page.html' | tee "$REPORT/luci-authenticated-page.log"
guest 'curl -fsS http://127.0.0.1/luci-static/resources/view/parallax/overview.js | grep -q daemon_running'
send "$GITHUB_WORKSPACE/tests/rpcd_acl.sh" /tmp/parallax-rpcd-acl.sh
guest 'sh /tmp/parallax-rpcd-acl.sh' | tee "$REPORT/rpcd-acl.log"
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
snap after-install
guest '/etc/init.d/parallax stop; /etc/init.d/parallax disable; apk del luci-i18n-parallax-ru luci-app-parallax parallax' | tee "$REPORT/remove.log"
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
done
if guest 'ubus list parallax' >/dev/null 2>&1; then echo "FAIL: ubus object remains"; exit 1; fi
# Normal apk removal must preserve edited UCI conffile and private user data.
guest 'test -f /etc/config/parallax; test "$(uci -q get parallax.main.enabled)" = 1; test "$(uci -q get parallax.ci_rule.match)" = domain_suffix; test -f /etc/parallax/generated/active.json; test -d /etc/parallax/credentials; echo "PASS: apk del retains conffile, credentials directory and revision store"' | tee "$REPORT/remove-preservation.log"
# Reinstall before explicitly purging so the admin command is available.
guest 'apk add --allow-untrusted /tmp/parallax-*.apk /tmp/luci-app-parallax-*.apk /tmp/luci-i18n-parallax-ru-*.apk' | tee "$REPORT/reinstall.log"
# The service was disabled before removal and must not auto-run on reinstall.
if guest 'ubus list parallax' >/dev/null 2>&1; then echo "FAIL: service automatically started after reinstall"; exit 1; fi
guest 'parallax purge --confirm-delete-all; test ! -e /etc/config/parallax; test ! -e /etc/parallax; apk del luci-i18n-parallax-ru luci-app-parallax parallax; test ! -e /etc/config/parallax; test ! -e /etc/parallax; echo "PASS: explicit purge removes UCI and credentials/revisions"' | tee "$REPORT/purge.log"

echo "PASS QEMU KVM" | tee "$REPORT/PASS.txt"
