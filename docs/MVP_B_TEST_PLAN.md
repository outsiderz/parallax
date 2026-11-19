# MVP (б) — test matrix and release gate

This file defines *planned* checks, not evidence that they have passed.

## Host unit tests
- Deterministic render: identical normalized inputs => same JSON bytes and SHA256.
- Valid minimal direct-only output and one synthetic VLESS/Reality profile.
- Invalid UUID, hostname, port, key, short ID, missing reference, duplicate
  names/tags, anonymous sections, invalid or unsupported match, unknown
  UCI option, and invalid schema => fail closed with no active-file change.
- All error messages, diff and metadata redact synthetic credential values.
- Transaction lock, temp-file permissions, atomic rename and recovery from
  interruption before/after promotion.
- Rollback to a verified earlier revision and no history overflow.

## OpenWrt 25.12 SDK and QEMU/KVM
- Build all three APKs, install with apk and verify checksums.
- Test with an **installed** sing-box binary and its actual `check -c`
  command; do not substitute a JSON parser for this gate.
- Confirm UCI schema migration is explicit and disabled by default.
- Create synthetic root-owned credentials; enforce 0700/0600 and reject
  insecure permissions/symlinks.
- Generate, validate, apply config-only, compare hashes, rollback and
  remove packages; capture sanitized metadata only.
- Compare pre/post: /etc/config outside Parallax, nftables normalized rules,
  ip rule, IPv4/IPv6 routes, DNS config, open sockets and process list.
- Verify authenticated LuCI cookie SID -> HTTP rpcd JSON-RPC status/ping returns data,
  while anonymous SID is denied (not just an HTTP 200 page or static ACL JSON).
- Verify standard apk del retains modified /etc/config/parallax, credentials and
  revisions; then reinstall and explicit purge removes all three.
- Verify neither coreutils-stat nor flock is required; use ucode fs.lstat and
  fs.file.lock with a real QEMU runtime test.
- Verify other VPN services remain untouched and sing-box is never launched
  as a daemon by the apply coordinator.

## Release gate
MVP (б) becomes eligible for merge to main ONLY after successful complete
GitHub Actions SDK + QEMU job, no leaked secrets, clean diffs and evidence
artifact review. A branch or draft PR does not imply completion.
