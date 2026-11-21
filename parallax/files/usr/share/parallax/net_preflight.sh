#!/bin/sh
# SPDX-License-Identifier: MIT
# MVP-c2a-0: strictly read-only preflight. No network mutation, no files written.
set -eu
fail() { echo "Parallax preflight: $1" >&2; exit 1; }
[ "$#" = 0 ] || fail 'unsupported argument'
[ "$(id -u)" = 0 ] || fail 'root required'
. /usr/share/parallax/platform.sh
. /usr/share/parallax/binding_evidence.sh
parallax_check_platform || fail 'unsupported platform'
[ "$(uci -q get parallax.main.schema_version)" = 3 ] ||
    fail 'UCI v3 required; run offline schema migration first'
parallax_check_config || fail 'invalid UCI v3'
[ -z "$(uci -q changes parallax)" ] || fail 'uncommitted UCI changes'
/usr/bin/ucode /usr/share/parallax/fs_guard.uc config /etc/config/parallax ||
    fail 'unsafe UCI config ownership/mode'

selection="$(/usr/bin/ucode /usr/share/parallax/selected_print.uc one)" ||
    fail 'exactly one valid selected_client required'
old_ifs="$IFS"; IFS="$(printf '\t')"
read -r name mac ipv4 iface proof <<EOF
$selection
EOF
IFS="$old_ifs"
[ -n "$name" ] && [ -n "$mac" ] && [ -n "$ipv4" ] && [ -n "$iface" ] ||
    fail 'invalid selected_client fields'

# Do not invent or trust an HTTP-derived management peer.
# Dropbear sets SSH_CONNECTION for an SSH session; BusyBox OpenWrt has no
# external environment-dump utility. Refuse without an identifiable session.
[ -n "${SSH_CONNECTION:-}" ] || fail 'trusted SSH management peer unavailable'
mgmt="${SSH_CONNECTION%% *}"
case "$mgmt" in *:*) fail 'IPv6 management path unsupported by IPv4-only gate' ;; esac
[ "$mgmt" != "$ipv4" ] || fail 'management peer cannot be selected'
ip link show dev "$iface" >/dev/null 2>&1 ||
    fail 'selected ingress interface not present'
if ip -4 addr show dev "$iface" | grep -Fq "$ipv4/"; then
    fail 'router-local IPv4 cannot be selected'
fi

native="$(ubus call service list '{"name":"sing-box","verbose":true}')" ||
    fail 'native sing-box procd state unavailable'
if printf '%s\n' "$native" | grep -Eq '"running"[[:space:]]*:[[:space:]]*true'; then
    fail 'native sing-box running; no automatic stop/disable'
fi
if pidof sing-box >/dev/null 2>&1; then
    fail 'sing-box process present outside proven native/Parallax isolation'
fi
command -v nft >/dev/null || fail 'nft unavailable'
fw4 print >/dev/null 2>&1 || fail 'fw4 inspection failed'
flow="$(uci -q get 'firewall.@defaults[0].flow_offloading' || :)"
hw="$(uci -q get 'firewall.@defaults[0].flow_offloading_hw' || :)"
[ "$flow" != 1 ] && [ "$hw" != 1 ] ||
    fail 'flow offloading enabled'
ruleset="$(nft -a list ruleset)" || fail 'nft ruleset unavailable'
if printf '%s\n' "$ruleset" |
   grep -Eq '(^|[[:space:]])(flowtable|tproxy|meta mark|ct mark|table inet parallax)([[:space:]]|$)'; then
    fail 'foreign nft mark, flowtable or TProxy needs owner review'
fi
for family in -4 -6; do
    rules="$(ip "$family" rule show)" ||
        fail 'cannot inspect kernel policy rules'
    printf '%s\n' "$rules" | awk -F: '
        /^[0-9]+:/ { prio=$1+0; if (prio!=0 && prio!=32766 && prio!=32767) bad=1 }
        END { exit bad }
    ' || fail 'foreign ip rule priority/mark requires owner review'
    if printf '%s\n' "$rules" | grep -Eq '(fwmark|lookup 20263|^11000:)'; then
        fail 'fwmark, priority or routing table collision'
    fi
    # iproute2 can return nonzero when a queried non-existent table is
    # perfectly free. Enumerate ALL tables (which must succeed), then match
    # only the explicit table ID in that successful output.
    all_routes="$(ip "$family" route show table all)" ||
        fail 'cannot inspect routing tables'
    if printf '%s\n' "$all_routes" |
       grep -Eq '(^|[[:space:]])table[[:space:]]+20263([[:space:]]|$)'; then
        fail 'routing table 20263 occupied'
    fi
done
echo 'PASS: read-only fw4/flowtable/marks/ip-rule/table/native-sing-box audit'

# No ARP probe or ping: initiating one would change the neighbour cache.
neighbour="$(ip -4 neigh show to "$ipv4" dev "$iface")" ||
    fail 'cannot read IPv4 neighbour state'
leases=''
if [ "$proof" = local_lease ]; then
    [ -f /tmp/dhcp.leases ] && [ ! -L /tmp/dhcp.leases ] ||
        fail 'local DHCP authority unavailable'
    dnsmasq_service="$(ubus call service list '{"name":"dnsmasq","verbose":true}')" ||
        fail 'dnsmasq state unavailable'
    printf '%s\n' "$dnsmasq_service" |
        grep -Eq '"running"[[:space:]]*:[[:space:]]*true' ||
        fail 'no running local authoritative DHCP service'
    # Lease evidence is authoritative ONLY when a non-ignored local dhcp
    # section actually owns the selected ingress device. Never borrow a
    # matching MAC/IP lease from a different VLAN or upstream server.
    authority=0
    for section in $(uci -q show dhcp | awk -F '[.=]' '$3 == "dhcp" {print $2}'); do
        logical="$(uci -q get "dhcp.$section.interface" || :)"
        device="$(uci -q get "network.$logical.device" || :)"
        ignored="$(uci -q get "dhcp.$section.ignore" || :)"
        if [ "$device" = "$iface" ] && [ "$ignored" != 1 ]; then
            authority=1
        fi
    done
    [ "$authority" = 1 ] || fail 'local DHCP authority for selected interface unproven'
    leases=/tmp/dhcp.leases
fi
parallax_binding_evidence "$mac" "$ipv4" "$proof" "$neighbour" "$leases" "$(date +%s)" ||
    fail 'MAC/IP/interface binding not proven'
echo "PASS: MVP-c2a-0 read-only preflight for $name [$proof], selected=$ipv4 interface=$iface"
echo 'PASS: no nft, ip rule, routes, conntrack, DNS or DHCP writes performed'
