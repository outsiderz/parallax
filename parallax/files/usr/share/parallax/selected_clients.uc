// SPDX-License-Identifier: MIT
// Shared strict UCI selected-client validation. No filesystem or network writes.
export function inspectSelected(sections, exactCount) {
    if (type(sections) != 'object' || type(sections.main) != 'object' ||
        sections.main['.type'] != 'globals')
        die('parallax-selected: missing globals section\n');

    let schema = sections.main.schema_version;
    if (schema != '2' && schema != '3')
        die('parallax-selected: unsupported schema version\n');

    let selected = [];
    let macs = {};
    let ips = {};
    let names = sort(keys(sections));
    for (let name in names) {
        let section = sections[name];
        if (section['.type'] != 'selected_client')
            continue;
        if (schema != '3')
            die('parallax-selected: selected_client requires schema v3\n');
        if (match(name, /^[A-Za-z][A-Za-z0-9_-]{0,31}$/) == null)
            die('parallax-selected: invalid section name\n');
        for (let key in section)
            if (substr(key, 0, 1) != '.' &&
                index(['enabled', 'mac', 'ipv4', 'interface', 'binding_proof'], key) < 0)
                die('parallax-selected: unknown selected_client option\n');
        if (section.enabled != '0' && section.enabled != '1')
            die('parallax-selected: explicit enabled 0 or 1 required\n');

        let mac = section.mac;
        let ip = section.ipv4;
        let dev = section.interface;
        let proof = section.binding_proof;
        if (type(mac) != 'string' ||
            match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) == null ||
            index(['0', '2', '4', '6', '8', 'a', 'c', 'e'], substr(mac, 1, 1)) < 0 ||
            mac == '00:00:00:00:00:00')
            die('parallax-selected: invalid canonical unicast MAC\n');
        if (type(ip) != 'string' ||
            match(ip, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) == null)
            die('parallax-selected: invalid IPv4 host\n');
        let octets = split(ip, '.');
        for (let value in octets)
            if (+value > 255 || (length(value) > 1 && substr(value, 0, 1) == '0'))
                die('parallax-selected: noncanonical IPv4 host\n');
        if (+octets[0] < 1 || +octets[0] == 127 || +octets[0] >= 224 ||
            (+octets[0] == 169 && +octets[1] == 254) ||
            (+octets[3] == 0) || (+octets[3] == 255))
            die('parallax-selected: reserved IPv4 host\n');
        if (type(dev) != 'string' ||
            match(dev, /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$/) == null)
            die('parallax-selected: invalid ingress interface\n');
        if (proof != 'local_lease' && proof != 'admin_static')
            die('parallax-selected: unsupported binding proof\n');
        if (macs[mac] || ips[ip])
            die('parallax-selected: duplicate MAC or IPv4\n');
        macs[mac] = true;
        ips[ip] = true;
        if (section.enabled == '1')
            push(selected, { name, mac, ipv4: ip, interface: dev, binding_proof: proof });
    }
    if (exactCount != null && length(selected) != exactCount)
        die('parallax-selected: exactly one enabled selected_client required\n');
    return selected;
}
