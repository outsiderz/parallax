#!/usr/bin/env python3
"""MVP-c1 source-level invariants; live checks run in QEMU."""
import subprocess
import unittest
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

class MVPC1Contract(unittest.TestCase):
    def test_manual_only_shell(self):
        for f in ["parallax/files/etc/init.d/parallax-singbox",
                  "parallax/files/usr/share/parallax/singbox.sh",
                  "tests/mvp_c1_guest.sh"]:
            self.assertEqual(subprocess.run(["sh", "-n", str(ROOT/f)]).returncode, 0, f)
        init = (ROOT/"parallax/files/etc/init.d/parallax-singbox").read_text()
        self.assertIn("procd_set_param user parallax-sb", init)
        self.assertIn("procd_set_param group parallax-sb", init)
        self.assertIn("procd_set_param respawn 3600 5 3", init)
        self.assertIn("[ -f /run/parallax-singbox/requested ] || return 0", init)
        self.assertNotIn("procd_set_param command /etc/init.d/sing-box", init)

    def test_root_private_credentials_and_fallback(self):
        cli = (ROOT/"parallax/files/usr/share/parallax/singbox.sh").read_text()
        self.assertIn("sing-box check -c", cli)
        self.assertIn("last-good.ref", cli)
        self.assertIn("chmod 0640", cli)
        self.assertIn("chmod 0710", cli)
        self.assertIn("singbox_permissions.uc", cli)
        self.assertNotIn("stat -c", cli)
        permissions = (ROOT/"parallax/files/usr/share/parallax/singbox_permissions.uc").read_text()
        self.assertIn("lstat(path)", permissions)
        self.assertIn("st.gid", permissions)
        self.assertIn("native sing-box is running", cli)
        self.assertIn("/etc/init.d/sing-box stop", cli)
        self.assertIn("/etc/init.d/sing-box disable", cli)
        self.assertIn("pidof_ours", cli)
        gate = (ROOT/"parallax/files/usr/share/parallax/singbox_gate.uc").read_text()
        self.assertIn("doc.inbounds", gate)
        self.assertIn("length(doc.inbounds) != 0", gate)
        self.assertIn("forbidden top-level configuration field", gate)
        self.assertIn("st.mode != 0o600", gate)
        make = (ROOT/"parallax/Makefile").read_text()
        self.assertIn("USERID:=parallax-sb:parallax-sb", make)
        self.assertIn("/etc/init.d/parallax-singbox disable", make)
        self.assertIn("PKG_VERSION:=0.3.1", make)
        self.assertIn("PKG_RELEASE:=1", make)

    def test_mvp_c1_status_and_respawn_gate(self):
        daemon = (ROOT/"parallax/files/usr/share/parallax/daemon.uc").read_text()
        guest = (ROOT/"tests/mvp_c1_guest.sh").read_text()
        self.assertIn("phase: 'mvp-c1'", daemon)
        self.assertIn("singbox: isolatedSingbox()", daemon)
        self.assertIn("pid: null", daemon)
        self.assertIn("parallax-sb", daemon)
        self.assertIn("repeated kill -9 exhausted bounded procd respawn", guest)
        self.assertIn("procd kept restarting sing-box across eight crash cycles", guest)

    def test_031_three_package_release_consistency(self):
        def var(contents, name):
            found = re.search(r"^" + re.escape(name) + r":=(\\S+)$", contents, re.M)
            self.assertIsNotNone(found, name)
            return found.group(1)

        core = (ROOT/"parallax/Makefile").read_text()
        luci = (ROOT/"luci-app-parallax/Makefile").read_text()
        self.assertEqual(var(core, "PKG_VERSION"), "0.3.1")
        self.assertEqual(var(luci, "PKG_VERSION"), var(core, "PKG_VERSION"))
        self.assertEqual(var(core, "PKG_RELEASE"), "1")
        self.assertEqual(var(luci, "PKG_RELEASE"), var(core, "PKG_RELEASE"))
        expected = var(core, "PKG_VERSION") + "-r" + var(core, "PKG_RELEASE")
        # luci.mk builds the generated third package; there is no separate Makefile.
        self.assertIn("include $(TOPDIR)/feeds/luci/luci.mk", luci)
        self.assertEqual(var(luci, "PKG_PO_VERSION"), expected)
        self.assertEqual((ROOT/"parallax/files/usr/share/parallax/version").read_text().strip(), "0.3.1")
        cli = (ROOT/"parallax/files/usr/bin/parallax").read_text()
        self.assertIn("VERSION='0.3.1'", cli)
        daemon = (ROOT/"parallax/files/usr/share/parallax/daemon.uc").read_text()
        self.assertIn("const VERSION = '0.3.1';", daemon)
        smoke = (ROOT/"scripts/ci/qemu-smoke.sh").read_text()
        self.assertIn('name-0.3.1-r1.apk', smoke)
        self.assertIn('wrong APK version for $name (expected 0.3.1-r1)', smoke)

    def test_no_secret_leak_on_native_refusal(self):
        guest = (ROOT/"tests/mvp_c1_guest.sh").read_text()
        controller = (ROOT/"parallax/files/usr/share/parallax/singbox.sh").read_text()
        for command in ("/etc/init.d/sing-box stop", "/etc/init.d/sing-box disable"):
            self.assertIn(command, controller)
            self.assertIn(command, guest)
        self.assertIn("expected_refusal=", guest)
        self.assertIn('[ "$actual_refusal" = "$expected_refusal" ]', guest)
        self.assertIn('NATIVE REFUSAL OUTPUT (exact-match asserted', guest)
        self.assertIn("without secrets", guest)

    def test_no_network_operations(self):
        src = (ROOT/"parallax/files/usr/share/parallax/singbox.sh").read_text()
        init = (ROOT/"parallax/files/etc/init.d/parallax-singbox").read_text()
        for bad in ["nft add", "nft delete", "ip rule add", "ip route add",
                    "uci set", "uci commit", "/etc/config/sing-box"]:
            self.assertNotIn(bad, src + init)
        guest = (ROOT/"tests/mvp_c1_guest.sh").read_text()
        for name in ["kill -9", "last-good", "native sing-box", "parallax singbox start",
                     "parallax singbox stop"]:
            self.assertIn(name, guest)

if __name__ == "__main__":
    unittest.main()
