// SPDX-License-Identifier: MIT
// MVP-c1: strict read-only gate for root-owned config-only revision.
// Does not produce network configurations or print secrets.
import { readfile, lstat } from 'fs';

function reject(reason) {
    die('Parallax singbox config rejected: ' + reason + '\n');
}
const path = ARGV[0] ?? '';
if (type(path) != 'string' ||
    match(path, /^\/etc\/parallax\/generated\/(active|rev-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{12})\.json$/) == null)
    reject('source file is not an approved revision path');

let st = lstat(path);
if (!st || st.type != 'file' || st.uid != 0 ||
    st.mode != 0o600 || st.size > 262144)
    reject('unsafe source file ownership, mode or size');

let doc;
try {
    doc = json(readfile(path, 262145));
}
catch (e) {
    reject('invalid JSON');
}
if (type(doc) != 'object')
    reject('root must be a JSON object');

for (let key in keys(doc))
    if (index([ 'log', 'inbounds', 'outbounds', 'route' ], key) < 0)
        reject('forbidden top-level configuration field');

if (type(doc.inbounds) != 'array' || length(doc.inbounds) != 0)
    reject('MVP-c1 requires zero inbounds: no TProxy, TUN or listeners');
if (type(doc.outbounds) != 'array' || length(doc.outbounds) < 1)
    reject('missing outbounds');
for (let outbound in doc.outbounds) {
    if (type(outbound) != 'object' ||
        index([ 'direct', 'vless' ], outbound.type) < 0)
        reject('unsupported outbound kind');
}
if (type(doc.route) != 'object')
    reject('missing route settings');
for (let key in keys(doc.route))
    if (index([ 'rules', 'final' ], key) < 0)
        reject('forbidden route setting');
if (type(doc.route.rules) != 'array')
    reject('invalid routing rules');
if (type(doc.log) != 'object' || doc.log.level != 'warn')
    reject('unsafe logging configuration');
for (let key in keys(doc.log))
    if (key != 'level')
        reject('custom logging sinks are forbidden');
// Inbounds=[], no experimental/tun, DNS, listeners or route automation.
// The validated file can be checked and launched without owning network state.
print('MVP-c1 config is inbound-free and network-mutation-free\n');
