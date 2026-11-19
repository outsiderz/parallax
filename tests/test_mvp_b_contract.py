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
        self.assertIn('mktemp /run/parallax/candidate.', source)
        self.assertIn('sing-box check -c "$candidate" >/dev/null 2>&1', source)
        self.assertIn('rm -f "$candidate"', source)

    def test_config_only_explicit(self):
        text = (ROOT / 'parallax/files/etc/config/parallax').read_text()
        self.assertIn("option apply_mode 'config_only'", text)
        self.assertIn("option enabled '0'", text)
        self.assertNotIn("password", text)
        self.assertNotIn("uuid", text)

if __name__ == '__main__':
    unittest.main()
