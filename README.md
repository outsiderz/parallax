# Parallax — MVP (б), OpenWrt 25.12+ x86/64

**Version:** 0.2.0 (development branch `feature/mvp-b`).
**Status:** configuration-only MVP, draft PR #1. No production network activation.

Parallax compiles a deterministic sing-box JSON configuration from a strict
version 2 UCI schema, checks it using the installed sing-box binary and supports
atomic config-only revisions, hash-only diffs and validated rollback.

**Safety boundary:** no sing-box daemon is started, no DNS changes are made,
and fw4/nftables, IP routes/rules, existing VPN services (including Forkop)
and other network settings are never modified by the renderer or transaction
manager. The default UCI option `enabled=0` is retained.

## Packages

- `parallax` — ucode renderer, CLI, status daemon, locked revision manager.
- `luci-app-parallax` — read-only LuCI status page.
- `luci-i18n-parallax-ru` — Russian interface translation.

## Commands on disposable OpenWrt/QEMU

```sh
parallax version
parallax check
parallax render                 # private file in /run/parallax (sensitive)
parallax validate               # requires real sing-box check -c
parallax diff                   # hashes only
parallax apply --config-only    # config file only; never launches sing-box
parallax history                # revisions and SHA256; no secrets
parallax rollback REVISION      # validates stored config before atomic restore
```

Only root may perform the operations. JSON candidates contain credentials and
must **never be pasted into logs, GitHub issues or public chat**. UCI profiles use
a `credential_ref`, and the corresponding root-owned JSON secret belongs at
`/etc/parallax/credentials/<ref>.json` (directory 0700, file 0600).
The `generated` store at `/etc/parallax/generated` is also private (0700).
All status/diff/history output omits JSON content.

Schema 2 defaults to a direct-only, no-inbound configuration. Supported
optional outbound: VLESS/Reality. Supported rule selectors: domain,
domain_suffix and IPv4 ip_cidr. No AmneziaWG support is implied.

## Tests and provenance

Run host checks with `bash ./tests/run.sh`. Real acceptance requires all
three APKs to build using the pinned OpenWrt 25.12.6 x86/64 SDK, and then
a real QEMU/KVM OpenWrt guest, sing-box check, Lua-free ucode runtime checks,
permission/credential tests, apply/rollback and network invariance tests.

Last observed passing **MVP (б) code** build:
[GitHub Actions #20](https://github.com/outsiderz/parallax/actions/runs/44507902751),
commit `8339af5c0c3905d9c863b32b4e417ceefd1f9db6`. Subsequent commits must
pass CI independently before acceptance or merge.

See [MVP (б) architecture](docs/ARCHITECTURE_MVP_B.md),
[release gate](docs/MVP_B_TEST_PLAN.md) and
[CI instructions](docs/CI.md).

## Status and next stage

The branch is developed in
[draft PR #1](https://github.com/outsiderz/parallax/pull/1).
**Do not deploy to an active router or merge before reviewing the final CI.**
MVP (в) will separately own sing-box lifecycle, network interception and safe
native-internet fallback.

MIT license; see [LICENSE](LICENSE).
