# MVP (a): architecture contract

This milestone is a safe, read-only scaffold.

* parallax/Makefile: OpenWrt apk package for a procd-controlled ucode daemon.
* /etc/config/parallax: UCI globals with schema_version=1, enabled=0, mode=selective.
* /etc/init.d/parallax: procd start/stop and bounded respawn.
* /usr/bin/parallax: version, check, status and ping commands.
* /usr/share/parallax/daemon.uc: ubus object parallax, methods status and ping.
* luci-app-parallax: read-only LuCI JS view and rpcd ACL, RU translation.

No sing-box process is started. No routes, firewall rules, nft tables, DNS or installed
Forkop/Podkop/Tachyon configurations are changed by the daemon.

Next milestones, not implemented:

* (b) UCI-to-sing-box JSON generation, validation and rollback.
* (c) nftables/fw4 TProxy and DNS interception.
* Lists/subscriptions, metrics, broader LuCI dashboard, installers and Telegram integration.

Use GitHub Actions QEMU acceptance results before beginning (b).
