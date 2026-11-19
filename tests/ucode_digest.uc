// SPDX-License-Identifier: MIT
// Real OpenWrt/QEMU test for BusyBox applet execution via ucode fs.popen.
import { popen } from 'fs';
let child = popen([ '/bin/busybox', 'sha256sum', '/etc/config/parallax' ], 'r');
if (!child)
    die('FAIL: unable to spawn BusyBox sha256sum through ucode\n');
let line = child.read('line');
let code = child.close();
let m = type(line) == 'string' ? match(line, /^([a-f0-9]{64})  /) : null;
if (code != 0 || !m)
    die('FAIL: cannot parse sha256 from BusyBox output\n');
print('PASS: ucode fs.popen BusyBox sha256sum\n');
