// SPDX-License-Identifier: MIT
// Run in actual OpenWrt/QEMU after 'parallax render'.
import { readfile } from 'fs';

let raw = readfile('/tmp/parallax-candidate.json');
if (!raw)
    die('FAIL: renderer produced no candidate\n');

let doc = json(raw);
if (type(doc) != 'object')
    die('FAIL: renderer emitted invalid JSON\n');
if (type(doc.inbounds) != 'array' || length(doc.inbounds) != 0)
    die('FAIL: renderer created a network listener\n');
if (type(doc.outbounds) != 'array' || length(doc.outbounds) != 1 ||
    doc.outbounds[0].type != 'direct' || doc.outbounds[0].tag != 'direct')
    die('FAIL: unexpected default outbound\n');
if (doc.route.final != 'direct' || length(doc.route.rules) != 0)
    die('FAIL: default routing is not direct\n');
printf('PASS: MVP-b deterministic direct-only candidate, no inbounds\n');
