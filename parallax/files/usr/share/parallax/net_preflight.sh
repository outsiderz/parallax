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
[ -f /etc/config/parallax ] && [ ! -L /etc/config/parallax ] &&
[ "$(stat -c %u /etc/config/parallax)" = 0 ] ||
    fail 'unsafe UCI config ownership'
case "$(stat -c %a /etc/config/parallax)" in 600|640|644) ;; *)
    fail 'unsafe UCI config permissions' ;; esac

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
mgmt="$(printenv SSH_CONNECTION 2>/dev/null | awk '{print $1}')" || :
[ -n "$mgmt" ] || fail 'trusted SSH management peer unavailable'
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
    ip "$family" rule show | awk -F: '
        /^[0-9]+:/ { prio=$1+0; if (prio!=0 && prio!=32766 && prio!=32767) bad=1 }
        END { exit bad }
    ' || fail 'foreign ip rule priority/mark requires owner review'
    if ip "$family" rule show | grep -Eq '(fwmark|lookup 20263|^11000:)'; then
        fail 'fwmark, priority or routing table collision'
    fi
    existing="$(ip "$family" route show table 20263 2>/dev/null || :)"
    [ -z "$existing" ] || fail 'routing table 20263 occupied'
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
    leases=/tmp/dhcp.leases
fi
parallax_binding_evidence "$mac" "$ipv4" "$proof" "$neighbour" "$leases" "$(date +%s)" ||
    fail 'MAC/IP/interface binding not proven'
echo "PASS: MVP-c2a-0 read-only preflight for $name [$proof], selected=$ipv4 interface=$iface"
echo 'PASS: no nft, ip rule, routes, conntrack, DNS or DHCP writes performed'
