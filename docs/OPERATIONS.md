# Parallax 0.3.1 — operations, uninstall and explicit purge

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

**Reinstall policy:** a retained UCI conffile may still say `enabled=1`.
The package pre-removal hook creates a private one-shot
`/etc/parallax/.reinstall-stopped` guard if `enabled=1`. During a later
`apk add`, the init script refuses an implicit status-daemon start.
The post-install hook disables autostart and removes the guard.
The administrator can explicitly re-enable/start it using:

```sh
/etc/init.d/parallax enable
/etc/init.d/parallax start
```

The UCI `enabled` value is deliberately preserved, not silently reset.
Inspect `/etc/init.d/parallax enabled`, `uci show parallax` and
`ubus list parallax` after installation. If installation was interrupted
while the guard existed, `purge --confirm-delete-all` recognizes and
removes the *root-owned, mode 0600 regular* guard. An unsafe symlink or
wrong permission mode fails closed without deleting credentials/revisions.
Config-only MVP-b does not activate proxy traffic.

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
  and optional protected `.reinstall-stopped` guard

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

New QEMU regressions also check invalid UCI/credential inputs (unchanged active
SHA256 and revision count), IPv4/IPv6 routes and rules, DNS resolver state,
TCP listening/UDP-bound sockets, and fail-closed purge behavior for invalid
guard symlinks and permissions. Process lists are captured for review,
not diff-gated because the Parallax status daemon is expected to change.

A LuCI session test calls `parallax.status` and `parallax.ping` via the
authenticated HTTP rpcd JSON-RPC endpoint `/ubus` and separately checks
that an anonymous SID is rejected. Only status/ping are granted in the
read-only `luci-app-parallax` ACL; CLI apply/purge are not exposed via rpcd.

No procedure here touches Forkop/Podkop/Tachyon, native routing or VPNs.


## MVP-c1: native sing-box interlock and operator recovery

In the tested OpenWrt 25.12.6 QEMU image, installing the stock `sing-box` APK **automatically enables its native init service** (`/etc/init.d/sing-box`). Treat it as potentially running and boot-enabled after package installation. Its boot policy is independent of Parallax. For safety, MVP-c1 refuses to start its separate inbound-free `parallax-singbox` instance whenever the native `sing-box` procd service is running. It does not stop, disable, restart, edit, or otherwise mutate native sing-box. Its error contains no proxy config, keys or credentials, only these administrator-run commands:

```sh
/etc/init.d/sing-box stop
/etc/init.d/sing-box disable
parallax singbox start
```

Only execute the first two commands if the administrator has intentionally chosen to stop the existing VPN; they **will interrupt** any traffic relying on the native service. Check `ubus call service list '{"name":"sing-box","verbose":true}'` and `/etc/init.d/sing-box enabled` first. Do not confuse stopping the native service with terminating Parallax's own process. Parallax never runs the suggested native-service commands itself.

`ubus call parallax status '{}'` reports `phase: mvp-c1` and a read-only `singbox` object with `running`, `pid`, and `user`; `pid` is `null` when stopped. This is informational only and does not grant rpcd permission to start or stop a service.


## MVP-c1: bounded procd respawn and operator status

Parallax uses a **separate** procd instance, not the native `sing-box` service. Its init script sets `procd_set_param respawn 3600 5 3`: a 3600-second threshold, a 5-second restart delay and a limit of 3 crash attempts in that threshold window. The QEMU gate actually issued repeated `kill -9` to the isolated process: after the first and second abrupt deaths, procd restarted it approximately 5 seconds later; **after the third abrupt death within the 3600-second window, it remained stopped**, confirmed by a 40-second no-replacement interval plus another 15 seconds of observation. The bounded behavior means it must not enter an endless restart loop.

An administrator can check the actual state without changing it:

```sh
ubus call parallax status '{}'
parallax singbox status
```

After exhaustion, the read-only `parallax status` reports `phase: mvp-c1` and `singbox: { running: false, pid: null, user: "parallax-sb" }`. It shows that **the isolated process is stopped**; these fields do not independently prove why it stopped, so consult `logread` and the procd service state before manually starting it again. An administrator must diagnose the crash before issuing `parallax singbox start`; this is not an automatic recovery promise. Neither status, respawn nor startup is allowed to change routing, nftables, DNS or the stock sing-box service.

## MVP-c1: release 0.3.1 version matrix

All three packages must share the exact release `0.3.1-r1`: `parallax`, `luci-app-parallax`, and the generated `luci-i18n-parallax-ru` package (built by `luci.mk` from the LuCI translation `po/ru/parallax.po`). The QEMU build checks the resulting three APK filenames and emits `package-version-consistency.log`; host tests also compare Makefile versions with the CLI, daemon and installed version file.


## MVP-c2a-0 — strictly offline schema migration and diagnostic preflight

MVP-c2a-0 does **not** provide net enable, TProxy, nftables, ip rule, routes,
conntrack manipulation, DHCP writes or DNS changes. Its read-only preflight
cannot make a selected client use the proxy, even if all diagnostics pass.

Only root may perform the **separate offline UCI migration** after explicitly
disabling the config daemon and stopping the isolated Parallax sing-box.
The original version-2 config is protected under
/etc/parallax/generated/schema-v2.backup with 0600 permissions until rollback.
On a failure, the original file is restored. This is the only persistent write
operation in this stage, and it changes UCI **not kernel networking state**.

~~~sh
uci set parallax.main.enabled=0
uci commit parallax
parallax singbox stop
parallax schema migrate-v3
# Root manually adds selected_client sections through uci and commits.
parallax check
parallax net preflight
# If returning to schema v2 is required:
parallax schema rollback-v2
~~~

The future v3 selected_client section has exact enabled, mac, ipv4, interface
and binding_proof options. Proof local_lease needs authoritative local DHCP
plus a live REACHABLE neighbour. Proof admin_static is a root declaration of
static reservation at an external DHCP server, **plus** a live REACHABLE
neighbour on the intended ingress interface. Stale, conflicting or missing
evidence refuses preflight. No probes that mutate neighbour cache are issued.
The preflight also rejects management SSH peers, unknown fw4/flowtable or mark
ownership, routing-table conflicts and a running native sing-box. It never
stops the native service. Lua/LuCI/rpcd do not get migration or preflight
write privileges.

QEMU compares kernel nft/rules/routes, resolver files and all UCI conffiles
before and after test, requiring empty diffs. Binding corner cases use
**synthetic in-memory fixture observations** for the pure parser and are
explicitly not counted as real L2 neighbour discovery. A live preflight must
reject unverified neighbours. Passing MVP-c2a-0 does not authorize net enable.
