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
guest 'apk update; apk add luci nftables-json curl ca-bundle; /etc/init.d/uhttpd enable; /etc/init.d/uhttpd restart' | tee "$REPORT/baseline.log"
snap() {
 mkdir -p "$REPORT/$1"
 guest 'tar -C /etc -cf - config' | tar -xf - -C "$REPORT/$1"
 guest 'nft list ruleset' >"$REPORT/$1/nft.txt"
 guest 'nft --stateless list ruleset' >"$REPORT/$1/nft-static.txt"
 guest 'apk list --installed' >"$REPORT/$1/apk.txt"
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
guest 'test -s /usr/share/luci/menu.d/luci-app-parallax.json; test -s /usr/share/rpcd/acl.d/luci-app-parallax.json; curl -fsS http://127.0.0.1/cgi-bin/luci/admin/services/parallax -o /tmp/page.html; test -s /tmp/page.html'
guest 'curl -fsS http://127.0.0.1/luci-static/resources/view/parallax/overview.js | grep -q daemon_running'
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
done
if guest 'ubus list parallax' >/dev/null 2>&1; then echo "FAIL: ubus object remains"; exit 1; fi
echo "PASS QEMU KVM" | tee "$REPORT/PASS.txt"
