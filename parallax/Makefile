# SPDX-License-Identifier: MIT
include $(TOPDIR)/rules.mk

PKG_NAME:=parallax
PKG_VERSION:=0.2.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Parallax contributors

include $(INCLUDE_DIR)/package.mk

define Package/parallax
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Parallax safe configuration compiler - development branch
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-digest +ucode-mod-ubus +ucode-mod-uloop +ucode-mod-uci +ubus +uci
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


# OpenWrt's default_prerm disables/stops services on apk del, while
# default_postinst automatically enables/starts them on reinstall. Keep a
# protected one-shot marker across removal, so retained enabled=1 UCI data
# never starts the daemon implicitly during a later package installation.
# The custom prerm runs after default_prerm; postinst after default_postinst.
define Package/parallax/prerm
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ "${PKG_UPGRADE}" = "1" ] && exit 0
if [ "$(uci -q get parallax.main.enabled 2>/dev/null)" = "1" ]; then
	[ ! -L /etc/parallax ] || exit 1
	umask 077
	mkdir -p /etc/parallax || exit 1
	chmod 0700 /etc/parallax || exit 1
	: > /etc/parallax/.reinstall-stopped || exit 1
	chmod 0600 /etc/parallax/.reinstall-stopped || exit 1
fi
exit 0
endef

# Default postinst has already run; guard in init.d prevents a transient
# launch, then disable automatic boot start and remove the temporary marker.
# A later explicit /etc/init.d/parallax enable + start remains supported.
define Package/parallax/postinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ -f /etc/parallax/.reinstall-stopped ]; then
	/etc/init.d/parallax stop || :
	/etc/init.d/parallax disable || exit 1
	rm -f /etc/parallax/.reinstall-stopped || exit 1
fi
exit 0
endef

define Package/parallax/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/parallax
	$(INSTALL_CONF) ./files/etc/config/parallax $(1)/etc/config/parallax
	$(INSTALL_BIN) ./files/etc/init.d/parallax $(1)/etc/init.d/parallax
	$(INSTALL_BIN) ./files/usr/bin/parallax $(1)/usr/bin/parallax
	$(INSTALL_DATA) ./files/usr/share/parallax/daemon.uc $(1)/usr/share/parallax/daemon.uc
	$(INSTALL_DATA) ./files/usr/share/parallax/render.uc $(1)/usr/share/parallax/render.uc
	$(INSTALL_DATA) ./files/usr/share/parallax/transaction.uc $(1)/usr/share/parallax/transaction.uc
	$(INSTALL_DATA) ./files/usr/share/parallax/platform.sh $(1)/usr/share/parallax/platform.sh
	$(INSTALL_DATA) ./files/usr/share/parallax/version $(1)/usr/share/parallax/version
endef

$(eval $(call BuildPackage,parallax))
