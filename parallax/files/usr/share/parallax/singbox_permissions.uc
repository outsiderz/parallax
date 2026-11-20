// SPDX-License-Identifier: MIT
// MVP-c1 private file checks via native fs.lstat (no coreutils stat).
import { lstat } from 'fs';
function fail() { die('Parallax singbox permissions rejected\n'); }
let kind = ARGV[0] ?? '';
let gid = ARGV[1] != null ? +ARGV[1] : null;
let path, mode, group = null;
if (kind == 'run') {
    path = '/run/parallax-singbox';
    mode = 0o710;
    group = gid;
}
else if (kind == 'config') {
    path = '/run/parallax-singbox/config.json';
    mode = 0o640;
    group = gid;
}
else if (kind == 'selected') {
    path = '/run/parallax-singbox/selected.ref';
    mode = 0o600;
}
else if (kind == 'last-good') {
    path = '/etc/parallax/generated/last-good.ref';
    mode = 0o600;
}
else fail();
if ((kind == 'run' || kind == 'config') && (group == null || group <= 0))
    fail();
let st = lstat(path);
if (!st || st.uid != 0 || st.mode != mode ||
    st.type != (kind == 'run' ? 'directory' : 'file') ||
    (group != null && st.gid != group))
    fail();
print('PASS: private owner/group/mode checked by fs.lstat\n');
