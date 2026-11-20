# SPDX-License-Identifier: MIT
include $(TOPDIR)/rules.mk

PKG_VERSION:=0.2.0
PKG_RELEASE:=3
# luci.mk builds luci-i18n-parallax-ru from po/ and uses this
# explicit translation version rather than PKG_VERSION/PKG_RELEASE.
PKG_PO_VERSION:=0.2.0-r3
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=Parallax - safe read-only scaffold
LUCI_DEPENDS:=+luci-base +parallax
LUCI_PKGARCH:=all

# This package is a sibling of parallax/ in a custom feed or SDK/package/.
# Use the official LuCI infrastructure; it also generates
# luci-i18n-parallax-ru from po/ru/parallax.po.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
