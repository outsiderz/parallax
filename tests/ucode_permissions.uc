// SPDX-License-Identifier: MIT
// Run in real OpenWrt guest; validate ownership and mode using fs.lstat.
import { lstat } from 'fs';
let target = ARGV[0];
let kind = ARGV[1];
let expected = kind == 'directory' ? 0o700 : 0o600;
let st = lstat(target);
if (!st || st.type != kind || st.uid != 0 || st.mode != expected)
    die('FAIL: insecure private Parallax filesystem permissions\n');
printf('PASS: protected %s permissions via ucode lstat\n', kind);
