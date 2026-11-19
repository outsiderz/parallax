# SPDX-License-Identifier: MIT
include $(TOPDIR)/rules.mk

PKG_NAME:=parallax
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Parallax contributors

include $(INCLUDE_DIR)/package.mk

define Package/parallax
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Parallax safe configuration compiler - development branch
  DEPENDS:=+flock +coreutils-stat +ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uloop +ucode-mod-uci +ubus +uci
  PKGARCH:=all
endef

define Package/parallax/description
 OpenWrt 25.12+ Parallax config-only generator with validated
 sing-box JSON revisions, history and rollback. No network routing changes.
endef

define Package/parallax/conffiles
/etc/config/parallax
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./LICENSE $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/parallax/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/parallax
	$(INSTALL_CONF) ./files/etc/config/parallax $(1)/etc/config/parallax
	$(INSTALL_BIN) ./files/etc/init.d/parallax $(1)/etc/init.d/parallax
	$(INSTALL_BIN) ./files/usr/bin/parallax $(1)/usr/bin/parallax
	$(INSTALL_DATA) ./files/usr/share/parallax/daemon.uc $(1)/usr/share/parallax/daemon.uc
	$(INSTALL_DATA) ./files/usr/share/parallax/render.uc $(1)/usr/share/parallax/render.uc
	$(INSTALL_BIN) ./files/usr/share/parallax/transaction.sh $(1)/usr/share/parallax/transaction.sh
	$(INSTALL_DATA) ./files/usr/share/parallax/platform.sh $(1)/usr/share/parallax/platform.sh
	$(INSTALL_DATA) ./files/usr/share/parallax/version $(1)/usr/share/parallax/version
endef

$(eval $(call BuildPackage,parallax))
