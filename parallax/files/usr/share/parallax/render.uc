// SPDX-License-Identifier: MIT
// MVP-b candidate compiler: prints a secret-bearing JSON document to stdout.
// Never invoke this directly from LuCI/ubus; use the root-only CLI wrapper.
import { cursor } from 'uci';
import { readfile, lstat } from 'fs';

function fail(reason) {
    // Deliberately never include an option value, UUID, path or JSON in errors.
    die('parallax-render: ' + reason + '\n');
}

function allowed(section, fields) {
    for (let key in section)
        if (substr(key, 0, 1) != '.' && index(fields, key) < 0)
            fail('unsupported UCI option');
}

function validName(value) {
    return type(value) == 'string' &&
        match(value, /^[A-Za-z][A-Za-z0-9_-]{0,31}$/) != null;
}

function validHost(value) {
    if (type(value) != 'string' || length(value) < 1 || length(value) > 253)
        return false;

    let labels = split(value, '.');
    for (let label in labels)
        if (length(label) < 1 || length(label) > 63 ||
            match(label, /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/) == null)
            return false;

    return true;
}

function enabledFlag(section) {
    let value = section.enabled ?? '1';
    if (value != '0' && value != '1')
        fail('enabled flag must be 0 or 1');

    return value == '1';
}

function ipv4Cidr(value) {
    let m = match(value, /^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\/([0-9]{1,2})$/);
    if (m == null || +m[2] > 32)
        return false;

    for (let octet in split(m[1], '.'))
        if (+octet > 255)
            return false;

    return true;
}

function getCredential(ref) {
    if (!validName(ref))
        fail('invalid credential reference');

    let dir = '/etc/parallax/credentials';
    let ds = lstat(dir);
    if (!ds || ds.type != 'directory' || ds.uid != 0 ||
        (ds.mode & 0o077) != 0)
        fail('credential directory is missing or insecure');

    let path = dir + '/' + ref + '.json';
    let st = lstat(path);
    if (!st || st.type != 'file' || st.uid != 0 ||
        (st.mode & 0o177) != 0 || st.size > 2048)
        fail('credential file is missing or insecure');

    let content = readfile(path, 2049);
    let credential = content != null ? json(content) : null;
    if (type(credential) != 'object')
        fail('credential JSON is invalid');

    allowed(credential, [ 'uuid' ]);
    if (type(credential.uuid) != 'string' ||
        match(credential.uuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) == null)
        fail('credential UUID is invalid');

    return credential;
}

let sections = cursor().get_all('parallax');
if (type(sections) != 'object' || type(sections.main) != 'object' ||
    sections.main['.type'] != 'globals')
    fail('main globals section is missing');

const main = sections.main;
allowed(main, [ 'schema_version', 'enabled', 'mode', 'apply_mode', 'default_outbound' ]);

if (main.schema_version != '2' || main.mode != 'selective' ||
    main.apply_mode != 'config_only')
    fail('unsupported schema or mode');

if (index([ '0', '1' ], main.enabled) < 0)
    fail('invalid main enabled flag');

let profiles = [];
let tags = { direct: true };
let names = sort(keys(sections));

for (let name in names) {
    let section = sections[name];
    let kind = section['.type'];

    if (name == 'main')
        continue;

    if (!validName(name))
        fail('invalid UCI section name');

    if (kind == 'profile') {
        allowed(section, [
            'enabled', 'protocol', 'server', 'port',
            'credential_ref', 'tls_sni', 'reality_public_key',
            'reality_short_id', 'utls_fingerprint', 'flow'
        ]);

        if (!enabledFlag(section))
            continue;

        if (name == 'direct' || tags[name])
            fail('duplicate or reserved outbound tag');

        if (section.protocol != 'vless')
            fail('unsupported outbound protocol');

        if (!validHost(section.server) || !validHost(section.tls_sni))
            fail('invalid profile server or TLS SNI');

        if (type(section.port) != 'string' ||
            match(section.port, /^[0-9]{1,5}$/) == null ||
            +section.port < 1 || +section.port > 65535)
            fail('invalid profile port');

        let key = section.reality_public_key;
        let shortid = section.reality_short_id ?? '';
        if (type(key) != 'string' ||
            match(key, /^[A-Za-z0-9_-]{43}$/) == null ||
            type(shortid) != 'string' ||
            match(shortid, /^[0-9a-fA-F]{0,16}$/) == null ||
            length(shortid) % 2 != 0)
            fail('invalid Reality key or short ID');

        if (section.utls_fingerprint != null &&
            section.utls_fingerprint != 'chrome')
            fail('unsupported uTLS fingerprint');

        if (section.flow != null && section.flow != 'xtls-rprx-vision')
            fail('unsupported VLESS flow');

        let cred = getCredential(section.credential_ref);
        let outbound = {
            type: 'vless',
            tag: name,
            server: section.server,
            server_port: +section.port,
            uuid: cred.uuid,
            tls: {
                enabled: true,
                server_name: section.tls_sni,
                reality: {
                    enabled: true,
                    public_key: key,
                    short_id: shortid
                }
            }
        };

        if (section.utls_fingerprint != null)
            outbound.tls.utls = {
                enabled: true,
                fingerprint: section.utls_fingerprint
            };

        if (section.flow != null)
            outbound.flow = section.flow;

        tags[name] = true;
        push(profiles, outbound);
    }
    else if (kind != 'rule') {
        fail('unsupported UCI section type');
    }
}

let finalTag = main.default_outbound ?? 'direct';
if (!validName(finalTag) || !tags[finalTag])
    fail('default outbound is not an enabled profile');

let rules = [];
for (let name in names) {
    let section = sections[name];
    if (section['.type'] != 'rule')
        continue;

    allowed(section, [ 'enabled', 'match', 'value', 'outbound', 'priority' ]);
    if (!enabledFlag(section))
        continue;

    if (index([ 'domain', 'domain_suffix', 'ip_cidr' ], section.match) < 0)
        fail('unsupported rule matcher');

    if (type(section.value) != 'array' ||
        length(section.value) < 1 || length(section.value) > 256)
        fail('rule values must be a nonempty UCI list');

    let values = [];
    for (let value in section.value) {
        if (type(value) != 'string' ||
            (section.match == 'ip_cidr' ? !ipv4Cidr(value) : !validHost(value)))
            fail('invalid rule value');

        if (index(values, value) < 0)
            push(values, value);
    }

    sort(values);
    let tag = section.outbound;
    if (!validName(tag) || !tags[tag])
        fail('rule references a missing outbound');

    let prio = section.priority ?? '1000';
    if (type(prio) != 'string' ||
        match(prio, /^[0-9]{1,5}$/) == null || +prio > 65535)
        fail('invalid rule priority');

    let item = { action: 'route', outbound: tag };
    item[section.match] = values;
    push(rules, { name, priority: +prio, rule: item });
}

sort(rules, (a, b) => a.priority != b.priority
    ? a.priority - b.priority
    : a.name < b.name ? -1 : a.name > b.name ? 1 : 0);

let doc = {
    log: { level: 'warn' },
    inbounds: [],
    outbounds: [ { type: 'direct', tag: 'direct' }, ...profiles ],
    route: {
        rules: map(rules, r => r.rule),
        final: finalTag
    }
};

printf('%J\n', doc);
