#!/bin/sh
# SPDX-License-Identifier: MIT
# Shared pure binding evidence gate. Caller supplies read-only neighbour output
# from ip neigh show to IP dev IFACE and an authoritative local lease file.
# Test fixtures call the same parser but never substitute in net preflight.
parallax_binding_evidence() {
    local expected_mac="$1" expected_ip="$2" proof="$3" neighbour="$4" leases="$5" now="$6"
    [ -n "$neighbour" ] || { echo 'FAIL: neighbour missing'; return 1; }
    printf '%s\n' "$neighbour" | awk -v ip="$expected_ip" -v mac="$expected_mac" '
        $1 == ip {
            hasmac=0
            for (i=2; i<NF; i++)
                if ($i == "lladdr" && tolower($(i+1)) == mac) hasmac=1
            if (!hasmac || $NF != "REACHABLE") bad=1
            else good++
        }
        END { exit !(good == 1 && !bad) }
    ' || { echo 'FAIL: neighbour is stale, conflicting or wrong MAC'; return 1; }
    if [ "$proof" = 'admin_static' ]; then
        echo 'PASS: admin_static declaration and live REACHABLE neighbour'
        return 0
    fi
    [ "$proof" = 'local_lease' ] || { echo 'FAIL: unknown binding proof'; return 1; }
    [ -f "$leases" ] && [ ! -L "$leases" ] || {
        echo 'FAIL: authoritative local lease file absent'; return 1
    }
    awk -v ip="$expected_ip" -v mac="$expected_mac" -v now="$now" '
        NF >= 3 && ($1 == 0 || $1 > now) {
            if ($3 == ip && tolower($2) != mac) conflict=1
            if (tolower($2) == mac && $3 != ip) conflict=1
            if ($3 == ip && tolower($2) == mac) found++
        }
        END { exit !(found == 1 && !conflict) }
    ' "$leases" || { echo 'FAIL: local DHCP lease expired, rebound or conflicting'; return 1; }
    echo 'PASS: local authoritative lease and live REACHABLE neighbour'
}
