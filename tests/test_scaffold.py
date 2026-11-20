#!/usr/bin/env python3
import json
import subprocess
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

class ScaffoldTests(unittest.TestCase):
    def test_packages(self):
        core=(ROOT/"parallax/Makefile").read_text()
        luci=(ROOT/"luci-app-parallax/Makefile").read_text()
        self.assertIn("PKG_NAME:=parallax",core)
        self.assertIn("ucode-mod-ubus",core)
        self.assertIn("render.uc",core)
        self.assertIn("ucode-mod-fs",core)
        self.assertIn("LUCI_DEPENDS:=+luci-base +parallax",luci)
        self.assertIn("feeds/luci/luci.mk",luci)
        # include/scan.mk discovers LuCI recipes via the exact marker.
        self.assertIn("call BuildPackage",luci)
        self.assertIn("define Package/parallax/prerm", core)
        self.assertIn("define Package/parallax/postinst", core)
        self.assertIn(".reinstall-stopped", core)
        self.assertIn("PKG_RELEASE:=1", core)
        self.assertIn("PKG_RELEASE:=1", luci)
        self.assertIn("PKG_PO_VERSION:=0.3.1-r1", luci)
        self.assertIn('$${IPKG_INSTROOT}', core)
        self.assertIn('$${PKG_UPGRADE}', core)
        self.assertIn('$$(uci -q get parallax.main.enabled', core)

    def test_shell_syntax(self):
        for file in ["parallax/files/etc/init.d/parallax",
                     "parallax/files/usr/bin/parallax",
                     "parallax/files/usr/share/parallax/platform.sh",
                     "parallax/files/usr/share/parallax/net_preflight.sh",
                     "parallax/files/usr/share/parallax/schema_migrate.sh",
                     "parallax/files/usr/share/parallax/binding_evidence.sh",
                     "tests/mvp_c2a0_guest.sh"]:

            p=subprocess.run(["sh","-n",str(ROOT/file)])
            self.assertEqual(p.returncode,0)

    def test_safe_uci(self):
        text=(ROOT/"parallax/files/etc/config/parallax").read_text()
        self.assertIn("option enabled '0'",text)
        self.assertIn("option schema_version '2'",text)
        self.assertIn("option apply_mode 'config_only'",text)
        self.assertIn("option mode 'selective'",text)
        init=(ROOT/"parallax/files/etc/init.d/parallax").read_text()
        self.assertIn("[ ! -f /etc/parallax/.reinstall-stopped ] || return 0", init)


    def test_daemon_read_only(self):
        code=(ROOT/"parallax/files/usr/share/parallax/daemon.uc").read_text()
        self.assertIn("connection.publish('parallax'",code)
        self.assertIn("routing_active: false",code)
        self.assertIn("status: {",code)
        self.assertIn("ping: {",code)
        # uhttpd-mod-ubus forwards a SID to the ubus handler on HTTP calls.
        # Each method must explicitly declare it or ucode rejects the request.
        self.assertEqual(code.count("args: { ubus_rpc_session: '' }"), 2)

    def test_luci_acl(self):
        acl=json.loads((ROOT/"luci-app-parallax/root/usr/share/rpcd/acl.d/luci-app-parallax.json").read_text())
        self.assertEqual(acl["luci-app-parallax"]["read"]["ubus"]["parallax"],["status","ping"])
        self.assertNotIn("write",acl["luci-app-parallax"])

    def test_cli(self):
        path=ROOT/"parallax/files/usr/bin/parallax"
        out=subprocess.run(["sh",str(path),"version"],capture_output=True,text=True)
        self.assertEqual(out.returncode,0)
        self.assertIn("0.3.1",out.stdout)
        core=(ROOT/"parallax/Makefile").read_text()
        luci=(ROOT/"luci-app-parallax/Makefile").read_text()
        self.assertIn("PKG_VERSION:=0.3.1", core)
        self.assertIn("PKG_VERSION:=0.3.1", luci)
        self.assertEqual((ROOT/"parallax/files/usr/share/parallax/version").read_text().strip(), "0.3.1")
        daemon=(ROOT/"parallax/files/usr/share/parallax/daemon.uc").read_text()
        self.assertIn("const VERSION = '0.3.1';", daemon)
        self.assertIn("phase: 'mvp-c1'", daemon)
        qemu = (ROOT/"tests/ucode_runtime.uc").read_text()
        self.assertIn("s.version != '0.3.1'", qemu)

if __name__ == "__main__":
    unittest.main()
