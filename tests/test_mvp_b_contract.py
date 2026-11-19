#!/usr/bin/env python3
"""MVP-b safety invariants checked before real SDK/QEMU integration."""
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class MVPBContract(unittest.TestCase):
    def test_generator_inbound_is_always_empty(self):
        source = (ROOT / 'parallax/files/usr/share/parallax/render.uc').read_text()
        self.assertIn('inbounds: []', source)
        self.assertIn("apply_mode != 'config_only'", source)
        self.assertIn('credential file is missing or insecure', source)
        self.assertIn("shortid", source)
        self.assertIn("printf('%J", source)
        self.assertNotIn("system(", source)
        self.assertNotIn("popen(", source)

    def test_cli_protects_candidate_and_suppresses_validation_output(self):
        p = ROOT / 'parallax/files/usr/bin/parallax'
        self.assertEqual(subprocess.run(['sh', '-n', str(p)]).returncode, 0)
        source = p.read_text()
        self.assertIn('umask 077', source)
        self.assertNotIn('stat -c', source)
        self.assertIn('parallax apply --config-only', source)
        self.assertIn('transaction.uc apply', source)
        self.assertIn('transaction.uc rollback', source)
        self.assertIn('mktemp /run/parallax/candidate.', source)
        self.assertIn('sing-box check -c "$candidate" >/dev/null 2>&1', source)
        self.assertIn('rm -f "$candidate"', source)

    def test_ucode_digest_busybox_dispatch(self):
        txn = (ROOT / 'parallax/files/usr/share/parallax/transaction.uc').read_text()
        smoke = (ROOT / 'scripts/ci/qemu-smoke.sh').read_text()
        self.assertIn("popen([ '/bin/busybox', 'sha256sum', path ], 'r')", txn)
        self.assertNotIn("popen([ 'sha256sum', path ], 'r')", txn)
        self.assertIn('tests/ucode_digest.uc', smoke)
        self.assertIn('ucode /tmp/parallax-digest.uc', smoke)

    def test_transaction_manager_safety(self):
        source = (ROOT / 'parallax/files/usr/share/parallax/transaction.uc').read_text()
        for token in ["lock('xn')", "lstat(path)", "open(file, 'wx', 0o600)",
                      "rename(file, ACTIVE)", "LIMIT = 10",
                      "sing-box check -c", "deleteTree(ROOT + '/credentials')"]:
            self.assertIn(token, source)
        for forbidden in ['nft add', 'ip route add', 'sing-box run', 'uci commit']:
            self.assertNotIn(forbidden, source)
        recipe = (ROOT / 'parallax/Makefile').read_text()
        self.assertIn('ucode-mod-fs', recipe)
        self.assertNotIn('+flock', recipe)
        self.assertNotIn('+coreutils-stat', recipe)
        self.assertNotIn('transaction.sh', recipe)

    def test_purge_is_explicit(self):
        cli = (ROOT / 'parallax/files/usr/bin/parallax').read_text()
        self.assertIn('purge --confirm-delete-all', cli)
        self.assertIn('/etc/init.d/parallax disable', cli)

    def test_config_only_explicit(self):
        text = (ROOT / 'parallax/files/etc/config/parallax').read_text()
        self.assertIn("option apply_mode 'config_only'", text)
        self.assertIn("option enabled '0'", text)
        self.assertNotIn("password", text)
        self.assertNotIn("uuid", text)

if __name__ == '__main__':
    unittest.main()
