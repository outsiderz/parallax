// SPDX-License-Identifier: MIT
// Real OpenWrt/QEMU verification of ucode-mod-digest without subprocesses.
import { sha256, sha256_file } from 'digest';

if (sha256('abc') !=
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    die('FAIL: native ucode SHA256 known-answer test\n');

let h = sha256_file('/etc/config/parallax');
if (type(h) != 'string' || match(h, /^[a-f0-9]{64}$/) == null)
    die('FAIL: native file SHA256 failed\n');

print('PASS: native ucode sha256 and sha256_file (no external applet)\n');
