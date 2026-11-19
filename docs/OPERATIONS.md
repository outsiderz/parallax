# Parallax 0.2.0 — remove vs explicit purge

## Standard uninstall (preserves user data)

```sh
/etc/init.d/parallax stop
/etc/init.d/parallax disable
apk del luci-i18n-parallax-ru luci-app-parallax parallax
```

This is deliberately non-destructive. A modified `/etc/config/parallax`
may remain as an APK conffile, including `enabled=1`, custom profiles/rules
and tests' `ci_rule`. The unmanaged `/etc/parallax/credentials/` and
`/etc/parallax/generated/` directories with secret material and private
revision files also remain. Package uninstall **does not** run purge.

**Reinstall warning:** retained UCI may still say `enabled=1`. Do not
assume a fresh, disabled configuration after reinstalling. The CI test
explicitly disables/stops the status daemon before removing the APK,
then asserts it did not autostart on reinstall. On another system,
check `/etc/init.d/parallax enabled`, `uci show parallax` and
`ubus list parallax`. Config-only MVP (б) does not activate proxy traffic
even when the status daemon starts.

## Explicit permanent purge (destructive)

Perform **before uninstalling** while `parallax` is still installed:

```sh
parallax purge --confirm-delete-all
apk del luci-i18n-parallax-ru luci-app-parallax parallax
```

The purge command requires root and stops/disables the Parallax status daemon,
then deletes all of the following and nothing belonging to other packages:

- `/etc/config/parallax` — UCI config, including any enabled/test rules
- `/etc/parallax/credentials/` — all secrets, UUIDs, passwords, keys
- `/etc/parallax/generated/` — active JSON, revision history, lock files
- `/etc/parallax/` — only if it contains the recognized private subdirectories

Purging is **not part of normal uninstall or package postrm** and cannot
be reversed unless a separate backup was made securely. It refuses symlink
targets, unfamiliar top-level entries under /etc/parallax and non-root-owned
data. There is no password or JSON output during the operation.

If the APK was already removed and a conffile remains, reinstall on a
*disposable test router*, inspect the UCI and perform explicit purge before
removing again. Never run broad `rm -rf` recipes from unknown sources.

## CI evidence and testing

`scripts/ci/qemu-smoke.sh` exercises the ordinary removal, checks retained
UCI and secrets/revisions, reinstalls, verifies no automatic status service
start in the test scenario, performs explicit purge and asserts absence of
all Parallax user data afterwards.

A LuCI session test calls `parallax.status` and `parallax.ping` via the
authenticated HTTP rpcd JSON-RPC endpoint `/ubus` and separately checks
that an anonymous SID is rejected. Only status/ping are granted in the
read-only `luci-app-parallax` ACL; CLI apply/purge are not exposed via rpcd.

No procedure here touches Forkop/Podkop/Tachyon, native routing or VPNs.
