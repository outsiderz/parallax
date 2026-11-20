#!/usr/bin/env python3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class CIChecks(unittest.TestCase):
    def test_discovery_uses_listing(self):
        sample = '<a href="openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst">SDK</a><a href="openwrt-25.12.6-x86-64-generic-ext4-combined-efi.img.gz">EFI</a>'
        with tempfile.TemporaryDirectory() as tmp:
            inp = Path(tmp) / "index.html"
            out = Path(tmp) / "assets.env"
            inp.write_text(sample)
            p = subprocess.run(["python3", str(ROOT/"scripts/ci/discover_assets.py"),
                                "--html", str(inp), "--version", "25.12.6",
                                "--output", str(out)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("SDK_FILE=", out.read_text())
            self.assertIn("IMAGE_FILE=", out.read_text())

    def test_discovery_rejects_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            inp = Path(tmp) / "index.html"
            inp.write_text("bad")
            p = subprocess.run(["python3", str(ROOT/"scripts/ci/discover_assets.py"),
                                "--html", str(inp), "--version", "25.12.6",
                                "--output", str(Path(tmp)/"assets.env")])
            self.assertNotEqual(p.returncode, 0)

    def test_shell_syntax(self):
        for file in ["qemu-smoke.sh", "verify_downloads.sh"]:
            p = subprocess.run(["bash", "-n", str(ROOT/"scripts/ci"/file)])
            self.assertEqual(p.returncode, 0)

    def test_workflow_contract(self):
        wf = (ROOT/".github/workflows/build-test.yml").read_text()
        for token in ["ubuntu-latest", "discover_assets.py", "sha256sums",
                      "qemu-smoke.sh", "actions/upload-artifact@v4"]:
            self.assertIn(token, wf)

    def test_live_ucode_test_in_qemu(self):
        smoke = (ROOT/"scripts/ci/qemu-smoke.sh").read_text()
        for token in ["ucode /tmp/ucode_runtime.uc", "ubus call parallax status",
                      "ubus list parallax", "kill -9", "apk del"]:
            self.assertIn(token, smoke)
        for token in ["rpcd_acl.sh", "remove-preservation.log", "purge.log",
                      "ucode_permissions.uc", "parallax purge --confirm-delete-all"]:
            self.assertIn(token, smoke)
        acl = (ROOT/"tests/rpcd_acl.sh").read_text()
        self.assertIn('http://127.0.0.1/ubus', acl)
        self.assertIn('sysauth_http', acl)
        self.assertIn('00000000000000000000000000000000', acl)
        self.assertIn("session access", acl)
        self.assertIn("HTTP=", acl)
        self.assertIn("set +e", smoke)
        self.assertIn("rpcd-acl.log", smoke)
        self.assertIn("luci-js.log", smoke)
        self.assertIn("heartbeat.log", smoke)
        self.assertIn("heartbeat_seq increased over 18 seconds", smoke)
        self.assertIn("stop-idempotence.log", smoke)
        self.assertIn("apk del emitted redundant procd delete", smoke)
        self.assertIn("purge emitted redundant procd delete", smoke)
        core = (ROOT/"parallax/Makefile").read_text()
        luci = (ROOT/"luci-app-parallax/Makefile").read_text()
        self.assertIn("PKG_VERSION:=0.2.0", core)
        self.assertIn("PKG_RELEASE:=3", core)
        self.assertIn("PKG_VERSION:=0.2.0", luci)
        self.assertIn("PKG_RELEASE:=3", luci)
        self.assertIn("PKG_PO_VERSION:=0.2.0-r3", luci)
        init = (ROOT/"parallax/files/etc/init.d/parallax").read_text()
        self.assertIn("ubus call service list", init)
        self.assertIn("unset USE_PROCD", init)
        self.assertIn("procd service lookup failed", init)

        self.assertIn("negative-validation.log", smoke)
        self.assertIn("transaction-recovery.log", smoke)
        self.assertIn("tests/ucode_lock_holder.uc", smoke)
        self.assertIn("tests/transaction_recovery.sh", smoke)
        recovery = ROOT/"tests/transaction_recovery.sh"
        self.assertTrue(recovery.is_file())
        self.assertEqual(subprocess.run(["sh", "-n", str(recovery)]).returncode, 0)
        recovery_source = recovery.read_text()
        self.assertIn("sleep 1", recovery_source)
        self.assertIn("parallax history >/dev/null", recovery_source)
        self.assertIn("sync interceptor is executable", recovery_source)
        self.assertIn("sanitized apply error", recovery_source)
        self.assertNotIn("sleep 0.", recovery_source)
        for contract in ["crash_at_sync 1", "crash_at_sync 2",
                         "lock-contention", "history limited to 10",
                         "parallax rollback", "sing-box check -c"]:
            self.assertIn(contract, recovery_source)
        holder = (ROOT/"tests/ucode_lock_holder.uc").read_text()
        self.assertIn("lock('xn')", holder)
        self.assertIn("sleep(20000)", holder)
        self.assertNotIn("system('sleep", holder)
        self.assertIn("/etc/parallax/generated/.lock", holder)
        self.assertIn("routes-v6.txt", smoke)
        self.assertIn("rules-v6.txt", smoke)
        self.assertIn("resolv-conf.txt", smoke)
        self.assertIn("listening-sockets.txt", smoke)
        self.assertIn("symlink marker rejected", smoke)
        negative = ROOT/"tests/negative_validation.sh"
        self.assertTrue(negative.is_file())
        self.assertEqual(subprocess.run(["sh", "-n", str(negative)]).returncode, 0)
        for case in ["invalid_uuid", "invalid_hostname", "invalid_port",
                     "invalid_reality_key", "invalid_short_id",
                     "unknown_profile_option", "missing_credential_reference",
                     "missing_outbound_reference", "unknown_main_option",
                     "invalid_priority", "unsupported_matcher", "invalid_ipv4_cidr"]:
            self.assertIn("reject " + case, negative.read_text())

        self.assertIn("reinstall-explicit-start.log", smoke)
        self.assertIn("for attempt in $(seq 1 30)", smoke)
        self.assertIn("ping did not return ok=true", smoke)
        self.assertEqual(subprocess.run(["sh", "-n", str(ROOT/"tests/rpcd_acl.sh")]).returncode, 0)
        code = (ROOT/"tests/ucode_runtime.uc").read_text()
        self.assertIn("conn.call('parallax', 'ping'", code)

if __name__ == "__main__":
    unittest.main()
