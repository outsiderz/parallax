# Parallax — MVP (а) / OpenWrt 25.12+ x86/64

**Version:** `0.1.0` (source scaffold). **Status:** implementation of milestone MVP (a), not a routing engine.

A safe, installable OpenWrt package scaffold with a real event-driven ucode daemon,
UCI settings, procd lifecycle, a read-only ubus API, a read-only CLI, and a tiny LuCI
JS view. The Russian LuCI language package is generated from `po/ru/parallax.po`
by the standard OpenWrt `luci.mk` mechanism.

> **Safety boundary:** this milestone never executes sing-box, touches nftables,
> changes IP rules/routes, alters DNS, or modifies existing Podkop/Forkop/Tachyon
> services. `/etc/config/parallax` ships with `enabled=0`.

## Layout

- `parallax/` — OpenWrt feed package: UCI, CLI, ucode daemon, procd init.
- `luci-app-parallax/` — LuCI JS view, menu, read-only rpcd ACL, Russian PO.
- `tests/` — host-side static and mock lifecycle tests.
- `docs/BUILD.md` — SDK and package build instructions.
- `docs/TESTING.md` — installation, runtime and network-invariance checks.
- `docs/ARCHITECTURE_MVP_A.md` — exact implemented scope and future contracts.

## Quick host tests

```sh
./tests/run.sh
```

Requires Python 3 and `sh`; Node.js is used for JS syntax checking when available.
These tests **do not** substitute for compiling the `.apk` in the matching OpenWrt
25.12 SDK or a live `ubus` smoke test in QEMU.

## Runtime commands (on an OpenWrt test machine, after building/installing)

```sh
parallax version
parallax check
uci show parallax
/etc/init.d/parallax status

# Opt in only to the status daemon (no routing):
uci set parallax.main.enabled='1'
uci commit parallax
/etc/init.d/parallax enable
/etc/init.d/parallax restart
parallax status
ubus call parallax status '{}'
ubus call parallax ping '{}'

# Return to disabled status (no network state to restore):
uci set parallax.main.enabled='0'
uci commit parallax
/etc/init.d/parallax stop
/etc/init.d/parallax disable
```

Open LuCI **Services → Parallax** to view the state. The view cannot perform writes.

## Known limitations

- Sing-box configuration, TProxy, DNS, snapshots, metrics, real VPNs, Telegram,
  install/uninstall and hosted GitHub Actions are subsequent milestones.
- SDK compilation, `.apk` signing and OpenWrt/QEMU live tests have **not** been
  executed by the host-side test suite.
- UCI `enabled` controls registration of a **status-only** process; it does not
  enable traffic routing.
- LuCI depends on the official LuCI feed (`feeds/luci/luci.mk`) at build time.
- The runtime guard rejects OpenWrt earlier than 25.12 and non-x86_64 builds.

## License

MIT. See `LICENSE`.


## CI: SDK + QEMU KVM (следующий контрольный рубеж)

Добавлен workflow [`.github/workflows/build-test.yml`](.github/workflows/build-test.yml).
Он собирает APK официальным SDK 25.12 x86/64, затем **на GitHub Actions**
запускает настоящий OpenWrt combined-efi в QEMU/KVM, устанавливает пакеты,
проверяет ubus/procd/LuCI и сохраняет логи/диффы. См. [`docs/CI.md`](docs/CI.md).
**В этом исходном комплекте нет утверждения о выполненном CI-run; APK-артефакты
появятся только после его успешного запуска в GitHub.**
