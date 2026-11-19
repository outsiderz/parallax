# Parallax MVP (a) — acceptance testing

Host tests:

    ./tests/run.sh

These check shell syntax, package contracts, UCI defaults, LuCI ACL and test infrastructure.

OpenWrt guest acceptance (performed by scripts/ci/qemu-smoke.sh):

1. Boot the official x86/64 combined-efi ext4 OpenWrt image using OVMF and KVM.
2. Configure LAN as a DHCP client of QEMU user-mode networking.
3. Install stock LuCI and nftables tools and capture baseline /etc/config and nft rules.
4. Install all three locally compiled APKs with apk add --allow-untrusted.
5. Run parallax check, enable the status-only daemon and query ubus status and ping.
6. Execute a real ucode runtime integration test against ubus.
7. Validate installed LuCI menu, ACL, HTTP page and JS resource.
8. Kill the ucode daemon and verify procd respawn under a different PID.
9. Remove the three APKs and capture post-removal configuration and nft rules.
10. Save raw diff files; fail if any non-Parallax UCI file or normalized nft rules changed.

Expected configuration delta during installation: /etc/config/parallax alone.
The default UCI value is enabled=0. The smoke test explicitly sets enabled=1.
No proxy service, DNS interception, nft rule changes or ip rule changes are implemented.

A green host-only unittest run is not a substitute for the OpenWrt SDK/QEMU workflow.
