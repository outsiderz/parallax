# Parallax MVP (б) — OpenWrt 25.12 x86/64

До установки на основной маршрутизатор проверяйте GitHub Actions QEMU.
Forkop и существующие VPN/маршруты Parallax MVP (б) не изменяет.

После установки в тестовом OpenWrt:

```sh
parallax version
parallax check
parallax render
parallax validate
parallax diff
parallax apply --config-only
parallax history
parallax rollback REVISION
```

`render` создаёт приватный JSON с секретами; его нельзя отправлять в чат
или публиковать. `apply` сохраняет проверенный JSON, но не запускает sing-box.

Обычное удаление **с сохранением конфигурации**:

```sh
/etc/init.d/parallax stop
/etc/init.d/parallax disable
apk del luci-i18n-parallax-ru luci-app-parallax parallax
```

Внимание: при этом могут сохраниться `/etc/config/parallax`, включая
`enabled=1` и правила, а также секреты и история в `/etc/parallax/`.
При `apk del` с сохранённым `enabled=1` создаётся закрытый одноразовый
маркер `.reinstall-stopped`. При следующем `apk add` он не позволяет
автоматически запустить службу; после установки автозапуск отключается,
а маркер удаляется. Само значение UCI `enabled=1` сохраняется.

После переустановки проверьте конфигурацию и состояние службы.
Чтобы включить демон *явно*:

```sh
/etc/init.d/parallax enable
/etc/init.d/parallax start
```

После прерванной переустановки `purge --confirm-delete-all` допускает
только закрытый маркер (root, `0600`), иначе отказывает без удаления данных.

**Полное необратимое удаление (до удаления APK):**

```sh
parallax purge --confirm-delete-all
apk del luci-i18n-parallax-ru luci-app-parallax parallax
```

Команда purge останавливает и отключает службу, удаляет только настройки
и пользовательские данные Parallax. Подробности: [OPERATIONS.md](OPERATIONS.md).
