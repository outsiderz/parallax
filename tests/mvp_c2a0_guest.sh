#!/bin/sh
# SPDX-License-Identifier: MIT
# Disposable QEMU: offline filesystem-only UCI migration + read-only preflight.
# Neighbour/lease parser edge cases are SYNTHETIC FIXTURES, never live proofs.
set -eu
umask 077
CFG=/etc/config/parallax
ORIG=/tmp/parallax-c2a0-v2-original
REPORT=/tmp/parallax-c2a0
# This namespace exists ONLY in disposable QEMU. Production net preflight
# remains strictly read-only and never runs these commands.
NS=px-c2a0-ci
HOST_VETH=pxc2a0h
PEER_VETH=pxc2a0n
CLIENT_MAC=02:11:22:33:44:55
CLIENT_IPV4=198.19.88.2
mkdir -p "$REPORT"
cp "$CFG" "$ORIG"
cleanup_netns() {
    ip link del "$HOST_VETH" >/dev/null 2>&1 || :
    ip netns del "$NS" >/dev/null 2>&1 || :
}
cleanup() {
    cleanup_netns
    cp "$ORIG" "$CFG" || :
    uci -q revert parallax || :
    rm -f /etc/parallax/generated/schema-v2.backup /etc/parallax/generated/schema-v2.backup.sha256
    rm -f "$ORIG"
}
trap cleanup EXIT
. /usr/share/parallax/binding_evidence.sh
# The test never writes nft, ip rule, routes, conntrack, sysctl or DNS.
uci set parallax.main.enabled=0
uci commit parallax
sha_v2="$(sha256sum "$CFG" | awk '{print $1}')"
parallax schema migrate-v3
[ "$(uci -q get parallax.main.schema_version)" = 3 ]
test -f /etc/parallax/generated/schema-v2.backup
/usr/bin/ucode /usr/share/parallax/fs_guard.uc backup /etc/parallax/generated/schema-v2.backup
parallax check
echo 'PASS: offline root UCI v2->v3 migration and strict validation'
status="$(ubus call parallax status '{}')"
printf '%s\n' "$status" | jsonfilter -e '@.phase' | grep -qx 'mvp-c2a-0' ||
    { echo 'FAIL: read-only status phase is not mvp-c2a-0'; exit 1; }
for field in interception_ready interception_supported interception_active net_enable_available; do
    printf '%s\n' "$status" | jsonfilter -e "@.$field" | grep -qx false ||
        { echo "FAIL: status must report $field=false"; exit 1; }
done
printf '%s\n' "$status" | jsonfilter -e '@.network_preflight_only' | grep -qx true ||
    { echo 'FAIL: status must explicitly declare preflight-only'; exit 1; }
printf '%s\n' "$status" | jsonfilter -e '@.version' | grep -qx '0.4.0' ||
    { echo 'FAIL: status version mismatch'; exit 1; }
echo 'PASS: status phase=mvp-c2a-0 and interception_ready=false, preflight-only'

uci set parallax.ci_selected=selected_client
uci set parallax.ci_selected.enabled=1
uci set parallax.ci_selected.mac=02:11:22:33:44:55
uci set parallax.ci_selected.ipv4=198.51.100.55
uci set parallax.ci_selected.interface=eth0
uci set parallax.ci_selected.binding_proof=admin_static
uci commit parallax
parallax check
/usr/bin/ucode /usr/share/parallax/selected_print.uc one
echo 'PASS: selected_client v3 accepted with exact MAC/IPv4/ingress/proof'

reject_config() {
    label="$1"
    if parallax check >/dev/null 2>&1; then
        echo "FAIL: invalid UCI selected_client accepted: $label"; exit 1
    fi
    echo "PASS: reject selected_client $label"
}
uci set parallax.ci_selected.mac=01:11:22:33:44:55
uci commit parallax
reject_config multicast_mac
uci set parallax.ci_selected.mac=02:11:22:33:44:55
uci set parallax.ci_selected.ipv4=198.51.100.055
uci commit parallax
reject_config noncanonical_ipv4
uci set parallax.ci_selected.ipv4=198.51.100.55
uci set parallax.ci_selected.unexpected=1
uci commit parallax
reject_config unknown_option
uci -q delete parallax.ci_selected.unexpected
uci set parallax.ci_duplicate=selected_client
uci set parallax.ci_duplicate.enabled=0
uci set parallax.ci_duplicate.mac=02:11:22:33:44:55
uci set parallax.ci_duplicate.ipv4=198.51.100.56
uci set parallax.ci_duplicate.interface=eth0
uci set parallax.ci_duplicate.binding_proof=local_lease
uci commit parallax
reject_config duplicate_mac
uci -q delete parallax.ci_duplicate
uci commit parallax
parallax check
echo 'PASS: strict UCI selected-client negative validation'

# Read-only evidence parser with deterministic synthetic observations.
now="$(date +%s)"
valid="198.51.100.55 dev eth0 lladdr 02:11:22:33:44:55 REACHABLE"
parallax_binding_evidence 02:11:22:33:44:55 198.51.100.55 admin_static "$valid" '' "$now" >/dev/null
echo 'PASS: fixture admin_static plus live-shaped REACHABLE evidence'
reject_binding() {
    label="$1" mac="$2" ip="$3" proof="$4" neighbour="$5" lease="$6"
    if parallax_binding_evidence "$mac" "$ip" "$proof" "$neighbour" "$lease" "$now" >/dev/null 2>&1; then
        echo "FAIL: binding fixture unexpectedly accepted $label"; exit 1
    fi
    echo "PASS: fixture rejects binding $label"
}
reject_binding stale 02:11:22:33:44:55 198.51.100.55 admin_static \
    "198.51.100.55 dev eth0 lladdr 02:11:22:33:44:55 STALE" ''
reject_binding foreign_mac 02:11:22:33:44:55 198.51.100.55 admin_static \
    "198.51.100.55 dev eth0 lladdr 02:11:22:33:44:66 REACHABLE" ''
reject_binding ip_conflict 02:11:22:33:44:55 198.51.100.55 admin_static \
    "198.51.100.55 dev eth0 lladdr 02:11:22:33:44:55 REACHABLE
198.51.100.55 dev eth0 lladdr 02:11:22:33:44:66 REACHABLE" ''
lease="$REPORT/leases"
printf '%s 02:11:22:33:44:55 198.51.100.55 test *\n' "$((now+3600))" > "$lease"
parallax_binding_evidence 02:11:22:33:44:55 198.51.100.55 local_lease "$valid" "$lease" "$now" >/dev/null
echo 'PASS: fixture local_lease plus live-shaped REACHABLE evidence'
printf '%s 02:11:22:33:44:55 198.51.100.56 test *\n' "$((now+3600))" > "$lease"
reject_binding rebind 02:11:22:33:44:55 198.51.100.55 local_lease "$valid" "$lease"
printf '%s 02:11:22:33:44:66 198.51.100.55 test *\n' "$((now+3600))" > "$lease"
reject_binding lease_ip_conflict 02:11:22:33:44:55 198.51.100.55 local_lease "$valid" "$lease"
printf '%s 02:11:22:33:44:55 198.51.100.55 test *\n' "$((now-60))" > "$lease"
reject_binding expired_lease 02:11:22:33:44:55 198.51.100.55 local_lease "$valid" "$lease"
echo 'PASS: STALE/rebind/foreign MAC/IP conflict negative fixtures (no kernel writes)'

# Real root SSH management peer must never be selected.
[ -n "${SSH_CONNECTION:-}" ] ||
    { echo 'FAIL: no real SSH management source'; exit 1; }
mgmt="${SSH_CONNECTION%% *}"
uci set "parallax.ci_selected.ipv4=$mgmt"
uci commit parallax
if parallax net preflight >"$REPORT/mgmt.log" 2>&1; then
    echo 'FAIL: preflight accepted management peer as selected'; exit 1
fi
grep -Fq 'management peer cannot be selected' "$REPORT/mgmt.log" ||
    { echo 'FAIL: wrong management refusal'; cat "$REPORT/mgmt.log"; exit 1; }
echo 'PASS: real SSH management peer excluded by read-only preflight'

uci set parallax.ci_selected.ipv4=198.51.100.55
uci commit parallax
if parallax net preflight >"$REPORT/actual.log" 2>&1; then
    echo 'FAIL: missing real neighbour proof accepted'; exit 1
fi
echo 'PASS: real preflight refuses unverified live binding without network writes'
if parallax net enable >"$REPORT/forbidden.log" 2>&1; then
    echo 'FAIL: unapproved net enable accepted'; exit 1
fi
grep -Fq 'net enable is forbidden' "$REPORT/forbidden.log" ||
    { echo 'FAIL: net enable refusal missing'; exit 1; }
echo 'PASS: net enable and TProxy are NOT implemented'

# Actual kernel neighbour test. Topology is temporary; the process runs
# inside QEMU and the production preflight only issues read-only probes.
echo 'REAL QEMU NETNS: creating isolated veth client'
command -v ip >/dev/null 2>&1 || { echo 'FAIL: iproute2 missing'; exit 1; }
ip netns add "$NS"
ip link add "$HOST_VETH" type veth peer name "$PEER_VETH"
ip link set "$PEER_VETH" netns "$NS"
ip link set "$HOST_VETH" up
ip addr add 198.19.88.1/30 dev "$HOST_VETH"
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set "$PEER_VETH" address "$CLIENT_MAC"
ip netns exec "$NS" ip addr add "$CLIENT_IPV4/30" dev "$PEER_VETH"
ip netns exec "$NS" ip link set "$PEER_VETH" up
uci set "parallax.ci_selected.mac=$CLIENT_MAC"
uci set "parallax.ci_selected.ipv4=$CLIENT_IPV4"
uci set "parallax.ci_selected.interface=$HOST_VETH"
uci set parallax.ci_selected.binding_proof=admin_static
uci commit parallax
# Real ICMP exchange populates an authentic REACHABLE kernel neighbour, no
# mocked 'ip neigh' output. Retry to accommodate ARP and driver scheduling.
seen=0
for attempt in 1 2 3 4 5; do
    ping -c 1 -W 1 -I "$HOST_VETH" "$CLIENT_IPV4" >/dev/null 2>&1 || :
    observed="$(ip -4 neigh show to "$CLIENT_IPV4" dev "$HOST_VETH")"
    case "$observed" in
        *"lladdr $CLIENT_MAC REACHABLE") seen=1; break ;;
    esac
    sleep 1
done
[ "$seen" = 1 ] || {
    echo 'FAIL: real QEMU namespace never produced matching REACHABLE neighbour'
    echo "$observed"
    exit 1
}
echo "REAL NETNS NEIGHBOUR REACHABLE: $observed"
if ! parallax net preflight > "$REPORT/real-reachable.log" 2>&1; then
    echo 'FAIL: preflight rejected authentic REACHABLE MAC/IP/interface evidence'
    cat "$REPORT/real-reachable.log"
    exit 1
fi
grep -Fq 'PASS: MVP-c2a-0 read-only preflight' "$REPORT/real-reachable.log" ||
    { echo 'FAIL: no positive preflight evidence'; exit 1; }
cat "$REPORT/real-reachable.log"
echo 'PASS: real QEMU netns REACHABLE neighbour was accepted by read-only preflight'
# Controlled state change in QEMU kernel; no synthetic parsed strings here.
ip -4 neigh replace "$CLIENT_IPV4" lladdr "$CLIENT_MAC" dev "$HOST_VETH" nud stale
stale="$(ip -4 neigh show to "$CLIENT_IPV4" dev "$HOST_VETH")"
case "$stale" in
    *"lladdr $CLIENT_MAC STALE") ;;
    *) echo 'FAIL: real kernel neighbour did not enter STALE'; echo "$stale"; exit 1 ;;
esac
echo "REAL NETNS NEIGHBOUR STALE: $stale"
if parallax net preflight > "$REPORT/real-stale.log" 2>&1; then
    echo 'FAIL: preflight accepted real STALE neighbour'
    exit 1
fi
grep -Fq 'neighbour is stale, conflicting or wrong MAC' "$REPORT/real-stale.log" ||
    { echo 'FAIL: refusal not caused by STALE evidence'; cat "$REPORT/real-stale.log"; exit 1; }
cat "$REPORT/real-stale.log"
echo 'PASS: real QEMU netns STALE neighbour rejected by read-only preflight'
cleanup_netns
if ip netns list | grep -Fq "$NS"; then
    echo 'FAIL: test network namespace remains'; exit 1
fi
if ip link show dev "$HOST_VETH" >/dev/null 2>&1; then
    echo 'FAIL: test veth remains'; exit 1
fi
echo 'PASS: QEMU veth/netns topology fully cleaned before zero-diff snapshots'

# Rollback restores the exact v2 snapshot taken immediately before migration,
# with profiles/rules intact; no stale rollback backup is left behind.
parallax schema rollback-v2
[ "$(uci -q get parallax.main.schema_version)" = 2 ]
[ "$(sha256sum "$CFG" | awk '{print $1}')" = "$sha_v2" ] ||
    { echo 'FAIL: offline rollback changed original v2 bytes'; exit 1; }
[ ! -e /etc/parallax/generated/schema-v2.backup ]
echo 'PASS: exact UCI v2 rollback and no schema backup leftovers'
echo 'PASS: MVP-c2a-0 QEMU offline-migration/strict-validator/negative-evidence gate'
