#!/usr/bin/env python3
"""MVP-c2a-0 source and CI contracts. Real OpenWrt behavior is QEMU gated."""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "parallax/files/usr/share/parallax"

class C2A0Contract(unittest.TestCase):
    def test_only_read_only_network_commands_exist(self):
        cli = (ROOT / "parallax/files/usr/bin/parallax").read_text()
        preflight = (BASE / "net_preflight.sh").read_text()
        self.assertIn('exec /usr/share/parallax/net_preflight.sh', cli)
        self.assertIn('net enable is forbidden', cli)
        self.assertNotIn("net enable)", cli)
        for command in ("nft -a list ruleset", "ip \"$family\" rule show",
                        "ip \"$family\" route show table", "fw4 print"):
            self.assertIn(command, preflight)
        for pattern in (r"\bnft\s+(add|delete|flush|replace)\s",
                        r"\bip\s+(-[46]\s+)?rule\s+(add|del|delete|flush)\s",
                        r"\bip\s+(-[46]\s+)?route\s+(add|del|replace|flush)\s",
                        r"\bconntrack\s+-[DF]", r"\buci\s+(set|commit)\s",
                        r"\b(sysctl\s+-w|ethtool\s+-[Kk])"):
            self.assertIsNone(re.search(pattern, preflight), pattern)
        self.assertNotIn("ping ", preflight)
        self.assertNotIn("ip neigh add", preflight)
        self.assertNotIn("ip neigh replace", preflight)

    def test_schema_migration_is_offline_and_explicit(self):
        cli = (ROOT / "parallax/files/usr/bin/parallax").read_text()
        migration = (BASE / "schema_migrate.sh").read_text()
        self.assertIn('exec /usr/share/parallax/schema_migrate.sh "$2"', cli)
        for marker in ("migrate-v3|rollback-v2", "schema-v2.backup",
                       "sha256sum -c", "uci set parallax.main.schema_version=3",
                       "exact original UCI v2 restored"):
            self.assertIn(marker, migration)
        self.assertNotIn("nft add", migration)
        self.assertNotIn("ip rule add", migration)
        self.assertNotIn("ip route add", migration)
        self.assertNotIn("conntrack -D", migration)

    def test_shared_strict_validation_and_bindings(self):
        module = (BASE / "selected_clients.uc").read_text()
        helper = (BASE / "selected_print.uc").read_text()
        render = (BASE / "render.uc").read_text()
        platform = (BASE / "platform.sh").read_text()
        binding = (BASE / "binding_evidence.sh").read_text()
        for token in ("selected_client", "binding_proof", "local_lease",
                      "admin_static", "duplicate MAC or IPv4", "reserved IPv4"):
            self.assertIn(token, module)
        self.assertIn("inspectSelected(sections, null)", render)
        self.assertIn("inspectSelected(sections, cmd == 'one' ? 1 : null)", helper)
        self.assertIn("selected_print.uc validate", platform)
        self.assertIn("REACHABLE", binding)
        self.assertIn("local DHCP lease expired, rebound or conflicting", binding)

    def test_artifact_gate_and_fixture_scenarios(self):
        smoke = (ROOT / "scripts/ci/qemu-smoke.sh").read_text()
        workflow = (ROOT / ".github/workflows/build-test.yml").read_text()
        guest = (ROOT / "tests/mvp_c2a0_guest.sh").read_text()
        for token in ("mvp-c2a0-gate.log", "mvp-c2a0-uci-diff.txt",
                      "mvp-c2a0-PASS.txt", "mvp-c2a0-nft-static-diff.txt"):
            self.assertIn(token, smoke + workflow)
        for scenario in ("stale", "foreign_mac", "ip_conflict", "rebind",
                         "exact UCI v2 rollback", "real SSH management peer excluded",
                         "net enable and TProxy are NOT implemented"):
            self.assertIn(scenario, guest)
        for file in ("schema_migrate.sh", "net_preflight.sh",
                     "binding_evidence.sh", "mvp_c2a0_guest.sh"):
            path = ROOT / ("tests/" + file if file.startswith("mvp_") else
                           "parallax/files/usr/share/parallax/" + file)
            self.assertEqual(subprocess.run(["sh", "-n", str(path)]).returncode, 0, file)

if __name__ == "__main__":
    unittest.main()
