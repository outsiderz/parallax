# Parallax MVP (б) — configuration engine contract

Status: approved architecture, implementation in progress; reviewed removal policy in docs/OPERATIONS.md. Base: successful MVP (а),
GitHub Actions #14 on OpenWrt 25.12.6 x86_64 (apk, LuCI, procd, ubus, QEMU/KVM).

## Scope and safety boundary

MVP (б) translates versioned UCI data into a deterministic sing-box JSON
candidate, validates it with the installed sing-box binary, stores approved
revisions atomically and permits a configuration-file rollback. It NEVER
starts or reloads sing-box, attaches a TUN/TProxy listener, changes nftables,
fw4, ip rules/routes, DHCP, DNS, interfaces or other VPN managers.

No real host, existing Forkop/Podkop/Tachyon files or VPN profile is a test
target. QEMU and synthetic credentials only. Applying a generated config is
NOT activating a network data plane.

## UCI schema version 2 (transition from version 1 is explicit)

```uci
config globals 'main'
    option schema_version '2'
    option enabled '0'
    option mode 'selective'
    option apply_mode 'config_only'
    option default_outbound 'direct'

config profile 'sg01'
    option enabled '1'
    option protocol 'vless'
    option server 'example.net'
    option port '443'
    option credential_ref 'sg01'
    option tls_sni 'example.net'
    option reality_public_key '<PUBLIC_KEY>'
    option reality_short_id '01234567'
    option utls_fingerprint 'chrome'
    option flow 'xtls-rprx-vision'

config rule 'ai'
    option enabled '1'
    option match 'domain_suffix'
    list value 'chatgpt.com'
    option outbound 'sg01'
    option priority '100'
```

Only named profile/rule sections are supported, to ensure stable references.
Domain rules are resolved in ascending numeric priority, then by section name.
Only allowed section types/options are accepted; unsupported options fail
closed, never silently pass through to sing-box.

A profile's `credential_ref` is a restricted symbolic identifier.
Credentials MUST be separate from UCI and version control in a root-owned
`0600` file under `/etc/parallax/credentials/`. No UUID, key, password, URL
query parameter or full generated JSON is permitted in the CI logs, user-facing
`ubus` status, ordinary CLI output or diff. Only synthetic credentials are
permitted in QEMU fixtures.

## Config compiler

* Output: JSON with `log`, `inbounds: []`, `outbounds`, and `route`.
* Always include `direct` outbound; default route is `direct` unless
  explicitly configured to a valid enabled profile.
* A supported VLESS/Reality profile compiles to a single outbound; no
  automatic network dial or connectivity probe during generation.
* Rule output uses `route.rules` with `action: "route"` and a referenced tag.
  No implicit TUN, sniff or DNS behavior is generated in MVP (б).
* Validations: supported schema, strict enabled flags, unique names/tags,
  allowed hostname/port/UUID/Reality key/short ID formats, non-empty
  domain/domain_suffix/ip_cidr rules, existing outbound targets, and stable
  ordering.
* A candidate is not approved until both internal checks and
  `sing-box check -c <candidate-file>` succeed. A missing or incompatible
  binary MUST fail closed.

## Transaction and revision storage

Implementation target:

```text
/run/parallax/           mode 0700  temporary candidate files
/etc/parallax/credentials/      mode 0700  secret source files (never snapshotted)
/etc/parallax/generated/        mode 0700  active.json and revision history
```

The apply coordinator uses native ucode fs.file.lock('xn') and fs.lstat for
file ownership/mode checks, with no standalone flock or coreutils-stat APK.
Normal apk del preserves conffiles and user-owned private data, while an
explicit `parallax purge --confirm-delete-all` (before uninstall) deletes
Parallax UCI, credentials and revision store after service stop/disable.

The apply coordinator must hold an exclusive lock, write in the same
filesystem, use `0600` file modes, flush and atomically rename verified
candidate into place. It must preserve last known good content before
promotion and never touch another service's configuration. A crash before
rename cannot replace the active revision. A rollback validates the target
revision, then atomically promotes a copy; it never restarts a process.

History will be bounded and include hash, schema, timestamp, validation
result and revision ID. Presentation is redacted (metadata-only diff).
No secret values or full candidate JSON are logged or placed in Actions
artifacts.

## Compatibility and future stages

MVP (а) remains in `main` until its replacement passes a full
SDK/QEMU CI run. MVP (в) separately owns sing-box process lifecycle,
fw4/nftables TProxy, DNS, native-internet fallback and real route changes.
WireGuard/AmneziaWG support is not inferred from sing-box VLESS support;
it requires a separate adapter and explicit acceptance tests.

Official references:
* https://sing-box.sagernet.org/configuration/route/
* https://sing-box.sagernet.org/configuration/outbound/vless/
* https://sing-box.sagernet.org/configuration/shared/tls/
* https://ucode-lang.org/ucode/
