# Parallax MVP (а): быстрый старт

Сначала проверьте успешную сборку и QEMU-тесты в GitHub Actions.
На действующий маршрутизатор с Forkop непроверенные пакеты не устанавливать.

Работа в тестовой OpenWrt 25.12 x86/64 после установки APK:

    parallax version
    parallax check
    uci show parallax

По умолчанию включение отключено. Чтобы запустить только демон статуса:

    uci set parallax.main.enabled='1'
    uci commit parallax
    /etc/init.d/parallax enable
    /etc/init.d/parallax restart
    ubus list parallax
    ubus call parallax status '{}'
    ubus call parallax ping '{}'
    parallax status

LuCI: Сервисы → Parallax. Интерфейс только для чтения.

Отключение:

    uci set parallax.main.enabled='0'
    uci commit parallax
    /etc/init.d/parallax stop
    /etc/init.d/parallax disable

Этап (а) не управляет sing-box, VPN, DNS, nftables и маршрутизацией.
Исходники и описание CI находятся в этом репозитории.
