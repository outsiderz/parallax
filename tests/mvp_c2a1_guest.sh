#!/bin/sh
# SPDX-License-Identifier: MIT
# This proof is disposable QEMU ONLY. It does not implement net enable.
set -eu
umask 077
D=/tmp/parallax-c2a1
NS=px-c2a1
HOST=pxc2a1h
CLIENT=pxc2a1c
MAC=02:51:2a:01:00:02
TESTIP=127.0.0.2
PORT=39091
mkdir -p "$D"
# Test-only directory contains no credentials; allow parallax-sb to traverse it.
chmod 0755 "$D"
sb_pid=
dns_pid=
cleanup() {
    [ -z "$sb_pid" ] || { kill "$sb_pid" 2>/dev/null || :; wait "$sb_pid" 2>/dev/null || :; }
    [ -z "${launcher:-}" ] || { kill "$launcher" 2>/dev/null || :; wait "$launcher" 2>/dev/null || :; }
    [ -z "$dns_pid" ] || { kill "$dns_pid" 2>/dev/null || :; wait "$dns_pid" 2>/dev/null || :; }
    ip link del "$HOST" 2>/dev/null || :
    ip netns del "$NS" 2>/dev/null || :
    rm -f "$D/sb" "$D/probe"
}
trap cleanup EXIT HUP INT TERM
echo "KERNEL: $(uname -srvm)"
echo "SING-BOX: $(sing-box version | head -n 1)"
echo "USER: $(id parallax-sb)"
test "$(id -u parallax-sb)" != 0
command -v setcap >/dev/null
command -v getcap >/dev/null
cp /tmp/parallax-c2a1-socket-probe "$D/probe"
cp /usr/bin/sing-box "$D/sb"
chmod 0755 "$D/probe" "$D/sb"
setcap cap_net_raw=ep "$D/probe"
setcap cap_net_raw=ep "$D/sb"
getcap "$D/probe" "$D/sb"
getcap "$D/probe" | grep -q cap_net_raw
getcap "$D/sb" | grep -q cap_net_raw
# Only the test executables receive CAP_NET_RAW, never CAP_NET_ADMIN.
if getcap "$D/probe" "$D/sb" | grep -E 'cap_net_admin|cap_sys_admin'; then
    echo 'FAIL: prohibited broad capability'; exit 1
fi
# Same socket operation without the file capability must fail for unprivileged UID.
cp "$D/probe" "$D/probe-plain"
chmod 0755 "$D/probe-plain"
if su -s /bin/sh parallax-sb -c "$D/probe-plain" > "$D/no-cap.log" 2>&1; then
    echo 'FAIL: no-capability negative control unexpectedly succeeded'; exit 1
fi
echo 'PASS: unprivileged no-capability transparent socket refused'
su -s /bin/sh parallax-sb -c "$D/probe" > "$D/socket-proof.log" 2>&1 || {
    cat "$D/socket-proof.log"; exit 1;
}
cat "$D/socket-proof.log"
grep -q 'PASS: TCP setsockopt+getsockopt IP_TRANSPARENT=1' "$D/socket-proof.log"
grep -q 'PASS: UDP setsockopt+getsockopt IP_TRANSPARENT=1' "$D/socket-proof.log"
cat > "$D/config.json" <<'JSON'
{
  "log": {"level": "warn"},
  "inbounds": [{"type": "tproxy", "tag": "qemu-only", "listen": "127.0.0.2", "listen_port": 39091}],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}
JSON
chmod 0644 "$D/config.json"
"$D/sb" check -c "$D/config.json"
# Unlike production, this isolated test runs an explicit test configuration.
su -s /bin/sh parallax-sb -c "exec $D/sb run -c $D/config.json" >"$D/singbox.log" 2>&1 &
launcher=$!
ready=0
for n in 1 2 3 4 5 6 7 8 9 10; do
    sb_pid="$(pidof sb 2>/dev/null | awk '{print $1}')" || :
    if [ -n "$sb_pid" ] &&
       awk '$2 == "0200007F:98B3" && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp &&
       awk '$2 == "0200007F:98B3" {found=1} END {exit !found}' /proc/net/udp; then
        ready=1; break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo 'FAIL: TProxy TCP/UDP sockets not bound at 127.0.0.2:39091'
    cat "$D/singbox.log"; exit 1
fi
uid="$(awk '/^Uid:/ {print $2}' "/proc/$sb_pid/status")"
eff="$(awk '/^CapEff:/ {print $2}' "/proc/$sb_pid/status")"
test "$uid" = "$(id -u parallax-sb)"
test "$(printf '%d' "0x$eff")" -eq 8192 || {
    echo "FAIL: expected CAP_NET_RAW alone, effective capability set=$eff"; exit 1;
}
echo "PASS: sing-box TProxy TCP+UDP sockets 127.0.0.2:39091, uid=$uid CapEff=$eff (CAP_NET_RAW only)"
# No redirection, nft rules, ip rule, routes, conntrack or DNS changes.
# A separate dnsmasq instance lives only on this disposable veth.
ip netns add "$NS"
ip link add "$HOST" type veth peer name "$CLIENT"
ip link set "$CLIENT" netns "$NS"
ip addr add 198.19.90.1/24 dev "$HOST"
ip link set "$HOST" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set "$CLIENT" address "$MAC"
ip netns exec "$NS" ip link set "$CLIENT" up
dnsmasq --no-daemon --conf-file=/dev/null --no-hosts --no-resolv --port=0 \
    --interface="$HOST" --bind-interfaces --dhcp-authoritative \
    --dhcp-range=198.19.90.10,198.19.90.20,255.255.255.0,1h \
    --dhcp-leasefile="$D/leases" --pid-file="$D/dnsmasq.pid" \
    >"$D/dnsmasq.log" 2>&1 &
dns_pid=$!
sleep 1
kill -0 "$dns_pid"
ip netns exec "$NS" udhcpc -i "$CLIENT" -n -q -t 5 -T 2 -s /bin/true \
    >"$D/udhcpc.log" 2>&1 || { cat "$D/udhcpc.log"; cat "$D/dnsmasq.log"; exit 1; }
cat "$D/udhcpc.log"
grep -Eiq 'lease of 198[.]19[.]90[.]' "$D/udhcpc.log"
test -s "$D/leases"
leaseip="$(awk -v mac="$MAC" 'tolower($2)==mac {print $3}' "$D/leases")"
test -n "$leaseip"
test "$(printf '%s\n' "$leaseip" | wc -l)" -eq 1
ip netns exec "$NS" ip addr add "$leaseip/24" dev "$CLIENT"
ping -c 1 -W 2 -I "$HOST" "$leaseip" >/dev/null
neigh="$(ip -4 neigh show to "$leaseip" dev "$HOST")"
. /usr/share/parallax/binding_evidence.sh
parallax_binding_evidence "$MAC" "$leaseip" local_lease "$neigh" "$D/leases" "$(date +%s)"
echo "PASS: REAL dnsmasq DHCP ACK, active lease $MAC/$leaseip, REACHABLE neighbour, local_lease parser"
cleanup
sb_pid=
dns_pid=
trap - EXIT HUP INT TERM
test -z "$(ip netns list)"
test ! -e "/sys/class/net/$HOST"
echo 'PASS: QEMU-only TProxy and real DHCP proof cleaned; no network interception'
