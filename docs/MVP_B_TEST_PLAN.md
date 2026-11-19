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

## Текущее дополнительное покрытие (требует зелёного CI на финальном коммите)

В реальном QEMU выполняется `tests/negative_validation.sh`, проверяющий
отказ `validate` и `apply --config-only` при неверных UUID, hostname,
port, Reality key/short ID, неизвестных UCI-опциях, ссылках на
несуществующие профили/секреты, ошибках priority/matcher/IPv4 CIDR.
После каждой попытки сравниваются SHA256 `active.json` и количество
ревизий, а также отсутствие UUID в диагностике.

Снимки до установки, после установки и после `apk del` включают IPv6
маршруты и правила, системные DNS resolv.conf, слушающие TCP и привязанные
UDP-сокеты, IPv4 и nftables. Списки процессов сохраняются как evidence,
но не сравниваются побайтно: ожидаемый демон `parallax` меняет список.
`purge` должен отвергать симлинк/небезопасные права маркера установки,
не повреждая пользовательские данные, и удалять корректный root-owned
`0600` маркер.

Не все негативные сценарии закрыты: отдельной работы требуют
краш-тесты атомарной транзакции, гонки конкурентных `apply`, проверка
удержания последних 10 ревизий, IPv6 DNS динамика и более полный
сетевой аудит. Успех старого CI #35 не подтверждает новые тесты.

## Release gate
MVP (б) becomes eligible for merge to main ONLY after successful complete
GitHub Actions SDK + QEMU job, no leaked secrets, clean diffs and evidence
artifact review. A branch or draft PR does not imply completion.
