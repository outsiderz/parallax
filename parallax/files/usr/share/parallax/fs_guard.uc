// SPDX-License-Identifier: MIT
// Portable root-owned file checks with ucode-mod-fs; no coreutils-stat.
import { lstat } from 'fs';
let kind = ARGV[0] ?? '';
let path = ARGV[1] ?? '';
if (type(path) != 'string' || length(path) < 1 ||
    index(['config', 'backup', 'private-dir'], kind) < 0)
    die('parallax-fs-guard: invalid operation\n');
let st = lstat(path);
if (!st || st.uid != 0)
    die('parallax-fs-guard: missing or non-root owned path\n');
if (kind == 'private-dir') {
    if (st.type != 'directory' || st.mode != 0o700)
        die('parallax-fs-guard: private directory must be root 0700\n');
}
else if (st.type != 'file' || (kind == 'backup' && st.mode != 0o600) ||
         (kind == 'config' && (st.mode & 0o022) != 0))
    die('parallax-fs-guard: unsafe file kind or permissions\n');
