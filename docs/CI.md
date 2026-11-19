# GitHub Actions: официальный SDK + реальный OpenWrt в QEMU

Файл: `.github/workflows/build-test.yml`. Запуск по push в `main`, pull request или вручную через Actions → `OpenWrt 25.12 x86/64 — SDK build and QEMU KVM smoke` → Run workflow. По умолчанию используется `25.12.6`; номер выпуска вынесен в input и переменную `OPENWRT_VERSION`.

## Что CI действительно делает при успешном запуске

1. Устанавливает SDK/QEMU/OVMF-зависимости на `ubuntu-latest`.
2. Получает официальный HTML-листинг `https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/x86/64/`, находит имя SDK по шаблону (включая GCC/musl), находит `generic-ext4-combined-efi.img.gz`. Оба файла сверяются с `sha256sums`.
3. Обновляет OpenWrt feeds в SDK, добавляет `parallax` и `luci-app-parallax` в `package/`, собирает `.apk`. Пакет перевода `luci-i18n-parallax-ru` производится механизмом `luci.mk`. Шаг требует найти ровно по одному `.apk` для каждого имени.
4. Подготавливает отдельную копию ext4-образа OpenWrt: `br-lan` на `eth0` с `proto dhcp`, выключает DHCP-сервер LAN, прописывает временный SSH-ключ. Смена UCI сети относится к *тестовому образу до baseline*, а не к установке Parallax.
5. Загружает его с QEMU + KVM + OVMF через user-mode NAT, пробрасывает SSH с `127.0.0.1:2222`. Ждёт реального SSH, проверяет выход в официальный репозиторий.
6. Устанавливает штатный LuCI и nftables **до** baseline снимка, поскольку их собственные зависимости могут добавить файлы в `/etc/config`.
7. Снимает снимки `/etc/config`, nftables, apk; ставит 3 локальных `.apk` через `apk add --allow-untrusted` и запускает команды проверки. Реально исполняет `ucode /tmp/ucode_runtime.uc` с вызовами `ubus`, `uci`, `uloop`.
8. Проверяет путь LuCI через HTTP, наличие JS view, `menu.d`, `acl.d`; убивает процесс демона SIGKILL и проверяет появление нового PID и восстановление `ubus` через procd.
9. Удаляет пакеты через `apk del`, снимает новые снимки, формирует raw и нормализованные diff-файлы.

## Артефакты

- `parallax-openwrt-...-apks`: три обязательных `.apk`.
- `parallax-openwrt-...-ci-reports`: host environment, загрузки/checksums, SDK build stdout/stderr, QEMU serial, SSH/сеть, `apk add/del`, ubus responses, реальный `ucode`, проcд respawn и snapshots + diff.

Workflow **не объявляет успех**, если нет `/dev/kvm`, SDK/EFI, если SSH не поднялся, если любой тест или инвариант нарушен. Для временных и неизбежных расхождений счётчиков nft публикуется raw diff, а структурная проверка производится через `nft --stateless list ruleset`.

## Интерпретация диффов

Файл `/etc/config/parallax` **обязан появиться** после установки пакета и меняется при явном `uci set parallax.main.enabled=1`. Поэтому полный `/etc/config` не будет побайтно идентичным до и после установки. Автоматический тест разрешает **только** изменения файла `parallax`; любые изменения остальных конфигов завершают CI с ошибкой. После удаления apk файл `parallax` может остаться как изменённый конфигурационный файл (apk сохраняет изменения администратора), что допустимо и отражается в полном diff.

Это CI acceptance test, а не доказательство работоспособности до фактического зелёного GitHub Actions run. Здесь не создавались APK и не запускалась виртуальная машина.

## Ограничение проверки веб-страницы

В данном CI проверяется получение LuCI URL по HTTP и фактическая раздача JS view, а также наличие menu/ACL JSON. Успешный ответ страницы входа без аутентификации сам по себе не доказывает авторизованный рендер интерфейса. Полноценный браузерный тест после логина потребуется дополнительно при приемке LuCI.
