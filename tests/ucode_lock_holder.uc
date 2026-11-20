// SPDX-License-Identifier: MIT
// Disposable QEMU-only holder for the real Parallax transaction lock.
import { open } from 'fs';

const file = open('/etc/parallax/generated/.lock', 'a', 0o600);
if (!file || !file.lock('xn'))
    die('LOCK_HOLDER: lock acquisition failed\n');

const ready = open('/tmp/parallax-ci-lock-ready', 'w', 0o600);
if (!ready || ready.write('locked\n') != 7 || !ready.flush() || !ready.close())
    die('LOCK_HOLDER: cannot signal readiness\n');

// Keep the lock handle open until the caller terminates this process.
// Native ucode sleep avoids spawning a child that may inherit the locked fd.
// The owner must release the lock immediately when killed by the test.
sleep(20000);
