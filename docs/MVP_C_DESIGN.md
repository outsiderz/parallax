# Parallax MVP (в) — проект безопасного включения сети

**Статус:** draft 2 утверждён для начала только (в1); draft 3 — уточнения перед будущим (в2), НЕ разрешение на реализацию (в2)/(в3). **Ревизия:** 20 ноября 2026.  
**Ветка:** `feature/mvp-c`. После merge PR #1 новая база — `main` на merge commit `5a980d70da9895fcb7e36499a24635d492c385da`.  
**Граница:** настоящий документ **не является разрешением** изменять сеть, запускать прокси, создавать nftables-правила или менять DNS. До утверждения draft 2 запрещена реализация (в1), (в2), (в3). PR #1 уже принят и слит в `main`; этот документ обновляется на новой базе, без реализации сетевых функций.

## 1. Контракт и условия допуска

Цель — добавлять функции минимальными, откатываемыми изменениями, не затрагивая существующие Forkop, Podkop, Tachyon, pbr, mwan3, штатный `sing-box`, другие VPN и управление маршрутизатором.

### Пять решений владельца — утверждены

| № | Решение |
| --- | --- |
| 1 | `inet parallax` и независимый net-agent; отказ при flow offloading/несовместимом fw4, никаких изменений чужих правил |
| 2 | 90 секунд на подтверждение; kill-switch `direct` по умолчанию, `block` — только явно включаемая опция |
| 3 | В (в2) `block_selected_ipv6_external` через **ICMPv6 reject**, dual-stack — отдельный будущий gate |
| 4 | В (в3) DNS **только selected**: отдельный резолвер и перехват UDP/TCP 53 в `inet parallax` без UCI/DHCP/dnsmasq/AdGuard |
| 5 | `parallax-sb` без root, узкие привилегированные net-agent/recovery; отдельные QEMU-gates для (в1), (в2), (в3) |

Утверждение решений — не разрешение писать код. Только после отдельного утверждения draft 2 можно начинать (в1).


| Подэтап | Функция | Значение по умолчанию | Независимый gate |
| --- | --- | --- | --- |
| (в1) | Собственный экземпляр `sing-box` под `procd`, **без** TProxy, TUN, nft, маршрутов и DNS | `disabled` | проверка запуска, прав, рестартов и отсутствия сетевых изменений |
| (в2) | Только явно выбранные клиенты, TProxy TCP/UDP, собственная таблица nft и policy routing; **без** перехвата DNS | `disabled` | управляемый маршрут пакетов, offload, watchdog, полный rollback, IPv6 |
| (в3) | Контролируемая DNS-политика, FakeIP, защита от DNS-утечек для выбранных клиентов | `disabled` | проверка запросов A/AAAA, согласованности DNS/FakeIP/маршрута и очистки |

**Нет подразумеваемого перехода:** успех (в1) не включает (в2); успех (в2) не включает (в3). Параметры политики и версия схемы могут существовать в ранее сохранённом конфиге, но (в2) **не изменяет UCI** ради enable/confirm/disable. Активация всегда явная через SSH CLI; никакой автоматической реактивации после reboot. Стартовый режим каждого подэтапа — `disabled`; при несовместимой версии схемы, отсутствии контрольного канала, конфликте или неполных снапшотах — отказ без изменения сети.

Область применения: OpenWrt 25.12.x, x86_64, пакетный менеджер apk, fw4, procd, nftables, iproute2; версии зависимостей и расширения ядра фиксируются в конкретном CI. Тестовый `sing-box` для QEMU на момент MVP-b — 1.13.x, **синтаксис и поля будущих конфигураций сверяются с фактически установленной версией**, а не с документацией на latest. Реальная установка на домашний шлюз запрещена до отдельного разрешения.

### Неприкосновенные инварианты

1. Установка, обновление и удаление пакета **не активируют** перехват.
2. `restore_native_internet` выполняется независимо от `sing-box`, его PID, сокетов, DNS и конфигурации; доступна с локальной консоли и SSH с правами root.
3. Не редактировать таблицу `inet fw4`, чужие nft-таблицы, чужие `ip rule`, таблицы маршрутизации и `dnsmasq`. Если выбранный механизм требует изменения чужого состояния, **отказать**, а не молча переписать.
4. После `stop` и аварийного восстановления nft / ip rule / routes **Parallax-owned** отсутствуют; чужие состояния совпадают с исходным снимком с поправкой только на заранее перечисленную динамику ядра. Незнакомый объект никогда не удаляется «по совпадению похожего имени».
5. Для выбранного клиента политика fail-open (`direct`) или fail-closed (`block`) задаётся отдельно; управление маршрутизатором, локальная связность и аварийный доступ не зависят от неё.
6. Никакие креденшелы, полный generated JSON, cookie/SID и FakeIP↔domain mappings не попадают в GitHub Actions artifacts.
7. **Только временное состояние (в2):** не изменять постоянные UCI, `ethtool`, DHCP, `dnsmasq`, `AdGuard`, sysctl, `/etc/iproute2/rt_tables`, init-скрипты. Только временные nft, ip rule, routes, выборочно conntrack и файлы в tmpfs `/run/parallax`.
8. Управляющий SSH-хост **не может быть selected**, даже через выбранный CIDR или IPv6. Неизвестный/неоднозначный management peer — отказ до применения.
9. (в2) административные операции доступны только root CLI по SSH; LuCI и ubus остаются read-only.
10. После перезагрузки kernel state и `/run` очищены, перехват не восстанавливается. Boot recovery только проверяет native; никаких постоянных network objects.

## 2. Состав компонентов и граница привилегий

| Компонент (проект) | Задачи | Права |
| --- | --- | --- |
| `parallax-control` | валидация схемы, предварительная проверка конфликтов, управление состояниями, подтверждение, журнал событий | root, **без** прямого обращения через HTTP RPC к изменяющим сеть методам |
| `parallax-net-agent` | применяет/удаляет исключительно описанные в манифесте Parallax-owned nft + policy-route объекты, воспроизводит rollback из журнала | отдельный минимальный привилегированный helper под контролем procd |
| `parallax-singbox` | отдельный экземпляр sing-box с собственным конфигом, отдельным runtime и логами | пользователь/группа `parallax-sb`, без root; capabilities по результатам тестов |
| `parallax-recovery` | независимый watchdog подтверждения и восстановления, доступен после смерти daemon/sing-box и при загрузке | root, запускается штатным init/procd, не зависит от proxy |
| LuCI/ubus | только статус и диагностика **read-only**; никакого enable/confirm/disable/restore в LuCI или rpcd | существующие ACL `status`/`ping` остаются read-only |

**Секреты:** исходные credentials `0600/root`; `parallax-control` формирует ровно один ограниченный runtime-конфиг для `parallax-sb` с минимальным доступом к файлу (root создаёт, группа/UID читает), вне web root. Никакого `chmod 644`, логов с JSON, env с UUID/ключами и shell-аргументов с секретами. Для доступа к TProxy-сокету проверить потребность в `IP_TRANSPARENT` и `CAP_NET_RAW` или `CAP_NET_ADMIN`. Не выдавать `CAP_NET_ADMIN` автоматически: в (в1) он не нужен; в (в2) рассматривается отдельная socket-setup граница либо строго минимальная capability (проверить на целевой версии ядра). `parallax-sb` не имеет полномочий изменять маршруты, firewall или DNS. Защита от symlink, проверка owner/mode, атомарная запись и fsync — по контракту MVP-b.

### Независимость от системного sing-box

Используем установленный бинарник `sing-box`, **но никогда** `/etc/init.d/sing-box`, `/etc/config/sing-box` и его включение через `enable`. Запуск — только через отдельный procd service/instance `parallax-singbox` с собственными UID, конфигурацией, каталогом и портами. Перед (в1): обнаружить зарегистрированный сервис и работающие процессы штатного sing-box; не останавливать и не переписывать их, а сверить порты/ресурсы и при конфликте отказать. `sing-box check` обязательный до каждого первого запуска и рестарта после смены конфигурации. Если candidate отвергнут — сохранить текущую рабочую ревизию; попытаться валидировать последнюю известную рабочую, не переписывая её; если и она невалидна, оставить Parallax выключенным. Никогда не запускать неизвестный кандидат. `procd` отвечает за supervised restart с ограничением числа повторов; бесконечный respawn запрещён.

**(в1) без сети:** прокси-процесс может проверяться по process/socket readiness, но конфигурация (в1) не содержит активного inbound, TUN/redirect, DNS listener и любых auto-route. Если отсутствие inbound не поддерживается конкретной версией sing-box, этот подэтап не считается выполненным без альтернативной проверенной non-intercept конфигурации. Сравнение nft, IPv4/IPv6 rules/routes, resolv.conf и fw4 — строго пустой Parallax diff.

## 3. (в2) nftables + TProxy — концептуальная схема, не исполняемые правила

**Решение:** отдельная контролируемая Parallax таблица семейства `inet` с именем `parallax`. Она не включается как часть `table inet fw4`. Основной кандидат — собственный base chain `prerouting` с priority `mangle` (ориентир: −150, до route lookup; окончательно подтвердить на OpenWrt/QEMU), а также собственные узкие `filter`-цепочки/sets для защитных политик. Объекты создаются только из собранного и проверенного манифеста.

**Почему не include в fw4:** независимый владелец, удаление только своей таблицы, отсутствие перезаписи сгенерированных fw4 chain и меньшая зависимость от формата шаблонов fw4. Такой подход **не означает**, что `accept` в Parallax сможет отменить `drop` другого base chain. Особенно важно: пакет, доставленный TProxy на локальный socket, проходит через `input`, и если `fw4` блокирует этот трафик, отдельная таблица его не «разрешит». Поэтому preflight должен убедиться в уже разрешённом доступе к Parallax TProxy socket для *выбранного* LAN/zone; в противном случае (в2) отказ без автоизменения fw4. Администратор может отдельно, вне Parallax, разрешить точечный доступ в fw4 и повторить preflight. Не предлагать общее открытие LAN→router или WAN→router.

`fw4 include` как альтернативу **отвергаем для MVP-в2**: хотя OpenWrt имеет штатные pre/post include, он встраивается в чужой жизненный цикл и может усложнить полную уборку/проверку ownership. Повторно рассмотреть только через отдельный дизайн и тест после fw4 reload, без правки сгенерированных правил и с явным согласованием.

### Нормативная схема nft-объектов (не синтаксис для исполнения)

```text
inet parallax  [owner=Parallax, создаётся/удаляется атомарно]
├── prerouting_tproxy       [hook prerouting, priority mangle/−150]
│   ├── исключить loopback, router-local, LAN/multicast/broadcast,
│   │   management/SSH/LuCI, DHCP/DHCPv6/RA/ND и endpoint'ы апстрима
│   ├── пропустить все невыбранные источники
│   ├── выбранный источник + допустимый TCP/UDP + public destination
│   │      → mark с собственными mask/bits → TProxy socket
│   └── остальные → без изменений
├── selected_clients_v4    [набор идентичностей, явный allowlist]
├── selected_clients_v6    [только при утверждённой dual-stack политике]
├── bypass_destinations    [LAN, router, VPN/server endpoint'ы, management]
├── protected_services     [управление и инфраструктура]
├── guard_forward_v6       [selected external IPv6: REJECT с ICMPv6 administratively prohibited]
└── dns53_selected         [только в (в3), отдельный resolver UDP/TCP :53]
```

Наборы клиентов создаются из фиксированных IP/подсетей (при DHCP — обязательная привязка к выбранной идентичности и проверка отсутствия смены адреса). MAC без IP/bridge корреляции не является достаточным критерием безопасности. Новые клиенты не включаются автоматически. LAN и WAN выбираются по наблюдаемым ifindex/interface и fw4 zone, а не по захардкоженному `eth0`. Гости из других VLAN не становятся выбранными без явного указания.

**Запрет управления через selected:** preflight получает фактический IP SSH-пира и management route, нормализует IPv4/IPv6, проверяет вхождение в каждый selected адрес/CIDR и конфликт динамических источников/NAT. При совпадении — `Parallax: management host <address> is included in selected clients; enable refused (SSH must remain native)`. Если надёжно определить management peer нельзя, enable отказывает. Для недоверенных HTTP-заголовков не делать исключений.

### Уже открытые соединения: прицельный conntrack reset

**Выбор: при включении и отключении прицельно сбрасывать conntrack-записи выбранных клиентов**, а не ждать неопределённого закрытия TCP/UDP. Старые established/NAT потоки иначе могут обходить новую политику или оставаться на TProxy после disable. Использовать фильтр по обеим сторонам conntrack tuple с проверенным выбранным IP и зоной. **Никогда не выполнять глобальный flush**, не сбрасывать management SSH, router-local, DHCP или unselected. В случае невозможности точной фильтрации preflight отказывает.

На enable сначала готовый listener и policy, затем адресный reset и проверка новых TCP/UDP соединений до `PENDING_CONFIRMATION`. На disable/restore сначала снять собственный перехват, затем адресно сбросить selected entries для восстановления native. Обрывы существующих TCP/QUIC/видеосессий выбранного клиента — ожидаемый риск и показываются администратору перед enable; могут понадобиться переподключения. При ошибке reset на enable — rollback; на restore — выполнить удаление Parallax-owned objects в любом случае, отметив `DEGRADED` и возможные старые соединения. Для режима `block` guard нельзя снять до безопасного перехода, иначе краткая утечка.


### Путь TCP/UDP, маркировка и policy routing

Порядок концептуально: входящий **от выбранного клиента** пакет → исключения → выбор протокола → отметка Parallax fwmark → policy routing по **собственной** таблице → локальная доставка TProxy на socket, который сохраняет исходный destination → sing-box использует outbound с необходимой проверкой bypass (чтобы не зациклить трафик самого proxy).

- Резервировать **только свободное** mark/mask пространство. Предложение для тестов: значение `0x00C30000`, маска `0x00FF0000`; priority `11000` и routing table ID `20263` — **кандидаты, а не право занять их**. Preflight перечисляет все `ip rule`, таблицы, nft `meta mark`/`ct mark`, fw4, pbr/mwan3, проверяет пересечения *с масками*. При любой неоднозначности — отказ; автоматический поиск и запись в чужой диапазон недопустимы.
- Выделенная policy table содержит локальную доставку IPv4 выбранного mark через loopback (для IPv6 — только если допущен полный dual-stack). Локальная маршрутизация на `lo` здесь не равна глобальному default route. Таблица не должна перехватывать управление роутером или трафик невыбранных клиентов.
- Нужны kernel nft tproxy modules, `IP_TRANSPARENT`, `ip rule` и listener TCP/UDP (проверка `nft -c` и runtime). Прежде чем делать mark, проверяется готовность обоих сокетов. TCP и UDP проверяются независимо; неподдерживаемый протокол не должен молча идти напрямую для политики `block`.
- Не использовать `auto_redirect`/`auto_route`, сторонние sing-box route helpers или TUN с параллельно работающей ручной схемой — один владелец net-state.
- **Идемпотентность:** повторная активация той же generation не добавляет цепочки, rules или routes; новый generation целиком валидируется, применяется с journal и может быть удалён по собственному тегу. Отдельные netlink операции могут упасть между собой; agent ведёт журнал выполненных действий и применяет rollback в обратном порядке, затем сверяет снимки. Если undo невозможно — состояние `degraded` и явная диагностика, не `active`.

### Forwarding и flow offloading

**Критичный preflight.** nft flowtable offload может обходить обычные netfilter hooks после попадания соединения в flowtable; маркировка на prerouting сама по себе не гарантирует, что уже offloaded поток вернётся в TProxy. Для MVP-в2 при активном software/hardware flow offloading в fw4 на затрагиваемых LAN/WAN интерфейсах — **отказ во включении**, без скрытого переключения `flow_offloading` и без изменения `fw4`. Администратор может отдельно отключить offload на тестовом роутере и подтвердить изменение; после этого новое preflight. Будущий selective-offload вариант возможен лишь после дополнительного доказательства, что selected и bypass потоки не имеют конфликтующих flowtable entries, включая уже существующие соединения. Нельзя считать простой `accept`/mark достаточной защитой.

Для x86 отдельно опросить `ethtool -k`, GRO/LRO/GSO/TSO/RX/TX checksum и hardware offload. Эти настройки NIC — **не то же самое**, что nft `flow offloading`. По умолчанию не выключать GRO/GSO/TSO системно. При проблемах TProxy/packet reassembly добавить QEMU-тесты и **отказать**, если для (в2) требуется правка NIC. Ни временно, ни постоянно Parallax в (в2) не меняет `ethtool`. Оператор может сам отдельно настроить NIC, затем повторить read-only preflight.

## 4. CLI-only управление, подтверждение и аварийный возврат

**В (в2) LuCI и rpcd остаются строго read-only.** Единственная точка административного enable/confirm/disable/restore — CLI с правами root в SSH-сессии с выделенного management хоста. Сам IP управляющего SSH-клиента и выбранный CIDR, его включающий, запрещены в selected. Preflight получает реальный SSH peer и проверяет сетевой путь; при отсутствии однозначного адреса — отказ. Локальная физическая консоль пригодна для аварийной команды, но не заменяет проверку SSH management пути при enable.

### Контракт команд (пока не реализация)

| Команда | Поведение |
| --- | --- |
| `parallax net enable` | Preflight владельца, mgmt exclusion, offload/fw4, готовность watchdog, TCP/UDP listener и baseline; применить только временное kernel state, прицельно очистить selected conntrack, запустить deadline и вывести nonce **только в защищённый SSH CLI** |
| `parallax net confirm <nonce>` | Единожды подтвердить generation/hash за 90 секунд из того же доверенного SSH management контекста; неверный, просроченный или уже использованный nonce — отказ |
| `parallax net disable` | Идемпотентный stop, удаление Parallax-owned nft/ip rule/routes, адресный conntrack reset, сравнение native |
| `parallax restore_native_internet` | Независимая аварийная CLI-команда, работает без sing-box, DNS и основного Parallax daemon, удаляет только owned network objects, повторный вызов отвечает `already native` |

**Ровно 90 секунд**, без конфигурируемого диапазона в (в2). Отсчёт monotonic clock начинается до первой операции изменения сети (watchdog предварительно готов и вооружён). Apply не продлевает deadline; к моменту `PENDING_CONFIRMATION` остаётся остаток времени. Не хранить nonce в логах, LuCI, статусе ubus или URL. Его проверка и однократное использование реализуются через закрытое временное runtime-хранилище `/run/parallax`, доступное только root. Watchdog независим от sing-box; отсутствие watchdog — отказ до применения. Timeout → rollback; неудачное подтверждение таймер не обнуляет.

### Исключения управления и отказ при выборе management-клиента

До маршрутизации исключить router-local и все LAN/VLAN адреса, loopback, локальный multicast/broadcast, SSH/LuCI на действительных портах роутера, DHCPv4/v6, ND/RA, management-пиры, proxy endpoint и сервисы локальной инфраструктуры. Исключения раньше любого TProxy mark и conntrack reset. Нельзя исключать весь destination :443 — это сломало бы перехват обычного HTTPS; управленческие исключения определяются парой адрес/порт и зоной.

Preflight сверяет выбранные IPv4/IPv6 адреса и CIDR с фактическим SSH peer, IP его NAT boundary и выделенными management сетями; при совпадении или неопределённости — отказ до создания сетевых объектов с понятным сообщением, например: `Parallax: management host <address> is in selected_clients; SSH access must remain native; enable refused`. Не брать peer из HTTP заголовков. Управляющий SSH-канал независимо проверяет native WAN. Никакой подтверждающей операции через LuCI в (в2).

### Аварийная команда

`restore_native_internet` использует только runtime ownership manifest и фиксированную консервативную схему идентификаторов Parallax. Удалять допустимо только `inet parallax` и точно проверенные Parallax-owned rules/routes; нельзя выполнять `flush ruleset`, глобальный `ip rule flush`, редактировать чужой `fw4` или таблицы иных систем. При повреждении manifest (но работающем ядре) удалить лишь несомненно owned объекты; неоднозначный объект — `DEGRADED` с диагностикой, без удаления чужого. После восстановить native WAN probe и проверить нулевой owned diff.

В (в2) DNS не перехватывается; запросы selected могут оставаться native. Это явно отмечается read-only UI. В (в3) действуют отдельные, выбранные пользователем DNS политики.

## 5. Runtime state и подтверждаемая транзакция

```text
DISABLED [native default]
  | root SSH: net enable, mgmt+offload+fw4 preflight
  v
APPLYING ------ failure / process kill ------> ROLLING_BACK
  | temporary routes/rules/nft + targeted conntrack reset
  v
PENDING_CONFIRMATION -- 90s timeout -------> ROLLING_BACK
  | root SSH: net confirm <nonce>
  v
ACTIVE -------- net disable / restore -------> ROLLING_BACK
  |                                              |
  |                                      zero owned diff?
  |                                              v
  +------------------------------------------ DISABLED
                 cleanup ambiguity ----------> DEGRADED (recovery only)
```

**Только временное состояние (в2):** nftables-таблица, ip rule, policy routes и адресно изменённый conntrack существуют в ядре; generation, baseline hashes, monotonic deadline, nonce, ownership manifest и журнал операций — только в `tmpfs /run/parallax` (закрытые root файлы `0600`). **Никаких изменений UCI, DHCP, dnsmasq, AdGuard, ethtool, sysctl, fw4 или постоянных init-скриптов.** Никакой постоянной базы активного состояния или записей о повторном применении.

**Почему reboot безопаснее:** после перезапуска ядра его временные nft/rules/routes/conntrack уничтожаются, `/run` очищается. Parallax всегда стартует в `DISABLED` и не воспроизводит перехват даже если до сбоя был `ACTIVE` или `block`. Единственно допустимая загрузочная функция — read-only проверка native и health, а не автоматический apply. Это упрощает crash recovery при полном reboot, **но не** решает проблему сбоя одного daemon без reboot, когда сетевые правила ещё существуют: нужен заранее запущенный независимый watchdog и runtime undo.

Порядок: 1) read-only preflight и baseline; 2) проверить `sing-box check`, запустить непривилегированный `parallax-sb`, проверить готовность TCP/UDP; 3) вооружить watchdog на 90 с, атомарно сохранить временный undo journal; 4) установить собственные локальные policy routes/rules и nft generation в контролируемом порядке; 5) адресно удалить conntrack выбранных клиентов, проверить фактические selected/unselected probes, перейти в `PENDING_CONFIRMATION`; 6) только root SSH `net confirm` переводит в `ACTIVE`; 7) timeout/stop/crash вызывает строго owner-scoped rollback, conntrack cleanup и zero-diff verification. Ошибки между разными netlink операциями не образуют общую ACID-транзакцию и обрабатываются journal + watchdog. Успешное удаление не требует восстановления UCI/NIC/DNS, поскольку (в2) никогда их не меняет.

## 6. Сбои, kill-switch, IPv6 и существующие соединения

| Сценарий | `direct` — default | `block` — отдельный opt-in |
| --- | --- | --- |
| `kill -9 sing-box`, падение процесса | watchdog снимает TProxy/rules/routes и выполняет native restore; до подтверждённого cleanup UI не показывает ACTIVE | временная IPv4/IPv6 guard-политика удерживает selected внешние потоки, не блокируя LAN/management; независимый watchdog должен поддерживать её без sing-box |
| Смерть Parallax control | независимый recovery по deadline/health, без вызова упавшего daemon | изоляция selected до восстановления или аварийного решения |
| Сбой между netlink-операциями | reverse-order runtime journal/ownership cleanup | deny selected через свою guard до завершения rollback; при ambiguity DEGRADED |
| Истечение 90 секунд | автооткат и native WAN, nonce уничтожен | выбранные потоки изолируются только до безопасного rollback; следовать подтверждённой политике, не оставлять постоянный block |
| Потеря WAN/прокси или fw4 reload | preflight повторяется; автоматического включения перехвата нет | никакого неконтролируемого direct fallback, сохранять management native |
| **Любая перезагрузка** | **всегда native, никаких перехватывающих правил**, т.к. ядро и tmpfs сброшены | **тоже native**, даже если до reboot выбран `block`; автозапуск guard/перехвата не допускается для (в2) |

### Уже открытые TCP/UDP/QUIC потоки (conntrack)

**Принято: только прицельный reset** conntrack для адресов selected клиентов на enable и disable, не ожидание естественного закрытия. Старые established/UDP NAT-потоки иначе могут обойти новую policy или остаться на старой метке. Удалять можно лишь записи, однозначно связанные с selected source/destination tuple и проверенной зоной; никогда не выполнять глобальный flush. Не трогать management SSH, router-local, DHCP, unselected или службы, управляемые чужими fwmarks. Проверить отсутствие flow offload до сброса.

На **enable**: после readiness и установки согласованной policy сбросить старые выбранные записи, проверить new-flow TCP/UDP, только затем переходить в `PENDING_CONFIRMATION`. На **disable/timeout/restore**: в безопасном порядке снять own TProxy/route/rule и адресно сбросить выбранные записи, проверить native. При ошибке targeted reset на enable — откат; при ошибке во время restore — снять own objects несмотря на ошибку и явно обозначить `DEGRADED`/stale sessions.

**Риск для клиента:** существующие TCP сессии, видеозвонки, QUIC/UDP могут оборваться; приложениям может потребоваться переподключение. В CI специально держать established-соединения selected/unselected/management и доказать, что перезапускаются только selected, а management SSH и unselected остаются целыми. Убедиться, что DHCP не переназначил selected IP в момент операции, иначе reject enable.

### IPv6 (в2): `block_selected_ipv6_external` через ICMPv6 reject

**Утверждено** не выполнять dual-stack proxy в (в2). Для *только selected* external forwarded IPv6 нужен быстрый `reject` с ICMPv6 Destination Unreachable / Administratively Prohibited, **не** silent `drop`. Это даёт IPv6-клиенту явную ошибку, а не ожидание таймаута. Локальные link-local, ND/RA/DHCPv6, multicast, router-local и management SSH — исключения; unselected IPv6 — native. Правило/guard находится исключительно во временной `inet parallax`, не в чужом fw4. Если недоступна достоверная классификация external IPv6 или fd/offload bypass, enable отказывает.

**IPv4 fallback тестировать измерением**, а не предположением: QEMU-клиент с A+AAAA доменом инициирует IPv6, фиксируются timestamp первого IPv6 SYN, ICMPv6 reject, timestamp IPv4 TCP connected и фактическая передача через proxy. Контрольная группа с `drop` и native сравнивается отдельно. **Предложенный gate:** p95 от попытки IPv6 до подтверждённого IPv4 connect не более 3 секунд в контролируемом QEMU и ни одного зависания больше 5 секунд; пороги уточнить по baseline, но не скрывать ухудшения. Проверить и поведение Happy Eyeballs, и CLI-клиента, а также отсутствие успешных внешних IPv6 потоков selected, сохранение SLAAC/ND/RA и unselected IPv6. Это не гарантия скорости всех приложений в реальном интернете. Полноценный `proxy_dual_stack` отложен до нового дизайн-gate и отдельного утверждения.

DNS privacy и шифрованные обходы (`DoH`, `DoT`, `DoQ`) не гарантируются на (в2): только в (в3) решается порт 53, а encrypted DNS требует отдельной политики/ограничений.

## 7. (в3) Только выбранный DNS и FakeIP — отдельный gate

**Утверждённый метод:** использовать свою временную `table inet parallax` для перехвата **и UDP, и TCP destination port 53 от selected клиентов** на отдельный Parallax DNS resolver/listener. Не менять DHCP options, `dnsmasq`/`AdGuard` UCI, default resolver, их сервисы и DNS настройки роутера. DNS выбранных клиентов перенаправляется даже если они явно указали другой **обычный** сервер port 53, при условии что packet идёт через проверенный маршрутизатор. DNS невыбранных клиентов и роутера остаётся native.

Порядок классификации: management/SSH/DHCP/ND/RA и localhost исключения, затем строго selected DNS53 правила, после этого общие TProxy/bypass. Не допускать доступа с WAN или unselected к resolver. Preflight проверяет доступность socket, его unique address/port, bind collision, fw4 input/filter path, транспорт TCP/UDP и корректность обратного направления. При несовместимости с fw4 или необходимости правки чужого ruleset — **отказ**, не скрытое изменение. Политика реализуется только после отдельного (в3) gate и требует согласованного rollback одновременно с TProxy/conntrack.

**Пределы покрытия:** перехват port 53 *не перехватывает* DoH через HTTPS/443, DoT/853, DoQ/QUIC и жёстко прописанные DNS-over-HTTPS endpoints в приложениях. Нет TLS MITM, нет обещания полного DNS leak prevention для зашифрованных протоколов. DNS-over-HTTPS в собственной браузерной конфигурации может обойти DNS53. Обычный hardcoded UDP/TCP 53 — в охвате, encrypted hardcoded DoH — вне его. Эти ограничения показываются администратору и проверяются отдельными тестами.

FakeIP включается только при проверенной согласованности selected resolver/route и reverse mapping: не допускать выдачи неактивной FakeIP записи, не пересекаться с LAN/VLAN/VPN/CGNAT и реальным адресным пространством. Утверждённый протокол (в3) должен определить TTL и eviction, только runtime приватный cache с правами root, без утечек доменов в logs. При сбое resolver в `direct` — согласованный rollback DNS+TProxy; в `block` — никаких direct DNS fallback. На `disable`/`restore`/reboot удалять только свои временные DNS53 rules/listener/cache, системный DNS никогда не менять.

**Версии:** зафиксировать фактический sing-box в QEMU gate и проверить синтаксис FakeIP для этой версии; legacy поля недопустимы без теста. Перенос на новую версию sing-box — отдельный тест совместимости, до этого DNS (в3) не активируется.

## 8. Детектор конфликтов и остановка до изменения сети

Предварительный аудит проверяет `service list` в procd, процессы/порты, nft JSON listing (таблицы, base chains/hook/priority, sets, flowtable), `ip -4/-6 rule`, маршрутизаторы policy tables, `/etc/iproute2/rt_tables`, fwmarks и masks, `uci show firewall/network/dhcp`, активные DNS listeners, flowoffload и ethtool features. Источники read-only; снятые снимки с секретами не загружать.

| Интеграция | Признаки потенциального конфликта | Действие |
| --- | --- | --- |
| Forkop | собственный sing-box, сетевые marks/policy, nft redirect/TProxy, DNS redirect | сравнить реальные объекты, не полагаться на имя; пересечение → отказ |
| Podkop | nft/sets, маршруты, policy routing, DNS или mark | отказ при пересечении owned resources или непредсказуемом hook |
| Tachyon | VPN/transparent routing, dnsmasq overrides, nft/mark | отказ до применения при коллизии |
| pbr | `pbr` таблицы, fwmarks и правила приоритета | mask-aware обнаружение; коллизия → отказ |
| mwan3 | policy tables/fwmarks/`ip rule` на WAN | отказ при коллизии или неоднозначной маршрутизации |
| Штатный `sing-box` | procd instance, bind-port, TUN/redirect listener, service autostart | не выключать; отказ только при реальном конфликте |
| fw4 | flowtable offload, input DROP TProxy socket, reload/integration | fail-closed; предложить независимую ручную корректировку и повторный preflight |
| AdGuard/dnsmasq | listener bind и DHCP DNS, split-horizon, DNS64 | (в2) только наблюдение; (в3) отдельное разрешение и отказ при коллизии |

Результат preflight: список конкретных конфликтующих объектов (таблица, chain, mark/mask, ip rule priority, resolver/port) и требуемое **ручное** решение. Секреты конфигурации и исходные proxy URI не отображать. Существующий конфликтный сервис не отключать автоматически.

## 9. QEMU-топология и критерии приёмки

```text
                  CI host / separate network namespaces
                          ┌──────────────────────┐
                          │ WAN test peer         │
                          │ synthetic TCP/UDP     │
                          └─────────┬────────────┘
                                    │ tap-WAN / isolated veth
                           ┌────────▼─────────────┐
Management namespace ─────▶│ OpenWrt QEMU router   │
(out-of-band control)       │ WAN + LAN interfaces  │
                           │ fw4 + Parallax        │
                           └────────┬─────────────┘
                                    │ tap-LAN / veth
                          ┌─────────▼────────────┐
                          │ client namespaces    │
                          │ selected / unselected│
                          └──────────────────────┘
```

В отличие от однопортового MVP-b smoke, тест (в) требует два отдельных виртуальных сетевых интерфейса LAN/WAN, клиент `selected` и `unselected` в отдельном пространстве имён на CI host или отдельные изолированные QEMU guests; **управляющий доступ — третьим, не перехватываемым каналом** (например отдельный host-forward только для CI). Не использовать реальную LAN/WAN хоста. WAN peer тестирует фиктивный прокси, TCP/UDP reply, недоступность апстрима и таймауты; все credentials синтетические. Разрешить топологию на уровне `veth`/tap/test namespace, не включать ip_forward/route на реальном runner глобально. Все тесты делают cleanup, сохраняют baseline и после смерти теста.

### Матрица проверок — отдельный CI для каждого gate

| Gate | Сценарий | Обязательная проверка |
| --- | --- | --- |
| в1 | установка, включение и остановка procd | экземпляр собственный/UID, `sing-box check`, no TProxy, nft/rules/routes/DNS diff пустой |
| в1 | плохой кандидат, падение, kill -9 | known-good fallback или `disabled`; ограниченный restart, штатный sing-box не затронут |
| в2 | selected client TCP+UDP | трафик доходит через TProxy и outbound; проверяются фактические destination и source, не только счётчики |
| в2 | unselected client | native WAN напрямую, ни одного Parallax mark |
| в2 | management traffic | CLI root SSH остаётся native, LuCI read-only; router-local/LAN/DHCP/ND не меняют маршрут и не обрываются |
| в2 | management host как selected / selected CIDR включает SSH peer | `net enable` отказывает **до** изменения ядра с адресом конфликта; нулевой diff |
| в2 | flow offloading fw4 включён | preflight **отказывает**, ничего не меняет; с offload disabled проходит |
| в2 | marks/pbr/mwan3/Podkop конфликт | отказ с именем ресурса и нулевым diff |
| в2 | SSH CLI: `net enable`, `net confirm <nonce>`, `net disable` | Только root по SSH; nonce одноразовый; LuCI/HTTP RPC не может менять сеть |
| в2 | подтверждение за 90 с | `ACTIVE` лишь после nonce/management probe до monotonic deadline |
| в2 | timeout без подтверждения | автоматический rollback, native WAN доступен, нулевой owned diff |
| в2 | `net disable` и `restore_native_internet` | nft/`ip rule`/routes нулевой owned diff, UCI/DHCP/`ethtool` неизменны, повторное restore идемпотентно |
| в2 | `kill -9` control/sing-box, reboot, interruption mid-apply | при crash живого ядра работает watchdog; после reboot **всегда DISABLED/native**, без persistent network state |
| в2 | established TCP/UDP selected/unselected/management при enable/disable | targeted conntrack reset только selected; SSH management и unselected не рвутся |
| в2 | read-only pre/post UCI, DHCP, sysctl, `ethtool` | нулевой diff постоянных настроек и NIC |
| в2 | IPv6 reject, SLAAC/RA/ND/DHCPv6 | selected внешние IPv6 получают ICMPv6 admin-prohibited, не drop; unselected и local ND работают |
| в2 | Happy Eyeballs IPv6→IPv4 | измеренные timestamps; предлагаемый p95 ≤3 с, max ≤5 с в QEMU, native/drop comparison |
| в3 | selected DNS UDP+TCP port 53 на чужой DNS | только selected перенаправлен на собственный Parallax resolver, включая hardcoded обычный DNS; unselected и router native |
| в3 | A/AAAA/FakeIP/reverse mapping | выбранный DNS идёт через утверждённый resolver; невыбранный native |
| в3 | resolver failure, DNS64/DoH/DoT/QUIC | DoH/DoT/DoQ **не покрываются** port 53, видимое предупреждение, отсутствие скрытого fallback |
| в3 | `stop`/`restore`/reboot | client-scoped DNS state убран; системные resolver/`dnsmasq` unchanged |

**Дополнительное QEMU-доказательство (в2):** принудительная перезагрузка в `PENDING_CONFIRMATION` и `ACTIVE` должна оставлять пустой owned nft/rules/routes, чистый `/run/parallax` и native WAN без автозапуска. Отдельно проверять команды CLI через root SSH, отказ через LuCI/ubus, точную очистку conntrack, отсутствие изменения UCI/ethtool/DHCP. Нельзя подменять реальный тест трафика nft-счётчиками.

**Обязательные snapshots до/после:** полный nft JSON + нормализованный diff, nft handles/owner table, IPv4/IPv6 rules/routes всех таблиц, conntrack/flowtable (metadata-only), fw4 zones/offload flags, NIC offload `ethtool`, `resolv.conf` и DNS listeners, `uci` чужих пакетов, procd services, `ss`/socket list, фактические TCP/UDP probes и непрерывный management health. Сырые и нормализованные диффы нужны оба; меняющиеся счётчики исключаются **только** из нормализованного diff, не из evidence. Время событий (generation/deadline/restore), exit codes, PASS/FAIL по каждому сценарию, причина отказа и ревизия артефакта обязательны.

**Gate = PASS** только когда все сценарии данного подэтапа пройдены в реальном QEMU, evidence zip загружен, stderr/exit codes доступны, нет secret leaks и проверка `stop`, `restore`, timeout и reboot доказывает полный cleanup. Пропущенный / неполный / «условно прошедший» тест ≠ PASS. До подтверждения дизайн-документа нельзя писать ни код (в1), ни код сети (в2/в3). Без отдельного разрешения нельзя переходить к следующему gate или ставить на реальный OpenWrt.

## 10. Риски, принятые ограничения и решение по draft 2

| Риск | Важность | Принятое ограничение / критерий отказа |
| --- | --- | --- |
| Потеря доступа к роутеру | критично | SSH peer не может быть selected, native management, только CLI confirm 90 с, независимый watchdog |
| nft flow offload / fw4 DROP | критично | отказ при offload и невозможности безопасной TProxy-доставки; не переписывать fw4 |
| Пересечение VPN/fwmark/pbr/mwan3 | критично | mask-aware preflight; чужие объекты не трогать |
| IPv6 утечки selected | критично | external IPv6 selected получает ICMPv6 reject, SLAAC/ND/RA и unselected не затронуты |
| DNS-утечки через DoH/DoT/DoQ | высокий | (в3) перехватывает только selected TCP/UDP 53; шифрованные протоколы вне гарантий |
| Прерванный apply при живом ядре | критично | runtime journal в tmpfs + независимый watchdog; conservative owner-scoped rollback |
| Перезагрузка роутера | средний | никаких постоянных правил и активирующих UCI; boot всегда native |
| Сброс conntrack повредил чужую сессию | высокий | только selected и точные tuples; management/unselected исключены; предупредить о разрыве selected |
| Чрезмерные привилегии sing-box | высокий | без root и только необходимые capabilities после QEMU-проверки |
| Конфликт FakeIP/cache | высокий | mapping только для selected, TTL/eviction и синхронное снятие DNS + TProxy |
| Неполные артефакты CI | высокий | отдельный gate каждого подэтапа, полный snapshot и zero-diff; пропуск теста = FAIL |

### Зафиксированные владельцем решения

Все пять решений раздела 1 утверждены: независимая `inet parallax` и net-agent, отказ при offload/несовместимом fw4, 90 секунд, default `direct` и отдельный opt-in `block`, IPv6 reject в (в2), selected DNS53 в (в3) без DHCP/dnsmasq/AdGuard, непривилегированный `parallax-sb` и независимые QEMU-gates. В (в2) дополнительно действует абсолютный запрет на постоянные изменения сети.

**Draft 2 ожидает отдельного утверждения.** До него не писать код (в1), (в2), (в3), не включать VPN/TProxy/DNS и не изменять реальный OpenWrt. После утверждения draft 2 можно начать **только (в1)** с отдельным CI/QEMU; (в2) и (в3) требуют своих gates.

## 11. Технические первоисточники и оговорки версий

- [Linux kernel: Transparent proxy support](https://www.kernel.org/doc/html/latest/networking/tproxy.html) — IP_TRANSPARENT и policy routing.
- [Linux man-pages: IP_TRANSPARENT capability](https://linuxman7.org/linux/man-pages/man2/IP_TRANSPARENT.2const.html) — CAP_NET_ADMIN или CAP_NET_RAW.
- [nftables: chain hooks and priority](https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks) — порядок base chains, нет глобального «accept» через другие chains.
- [Linux kernel: flowtable infrastructure](https://cdn.kernel.org/doc/html/latest/networking/nf_flowtable.html) — fast path / обход classic hooks.
- [OpenWrt fw4 includes](https://github.com/openwrt/firewall4/blob/master/root/usr/share/nftables.d/README) — допустимые точки includes; выбранная архитектура их не использует.
- [sing-box: TProxy inbound](https://sing-box.sagernet.org/configuration/inbound/tproxy/) — прозрачный TCP/UDP listener.
- [sing-box: FakeIP DNS server](https://sing-box.sagernet.org/configuration/dns/server/fakeip/) и [deprecated legacy FakeIP](https://sing-box.sagernet.org/configuration/dns/fakeip/) — версионное отличие.
- [sing-box: migration guide](https://sing-box.sagernet.org/migration/) — обязательна при переходе на следующую версию sing-box.

**Примечание:** приведённые имена, mark, table ID и chain priorities — проектные кандидаты; проверка их применимости на OpenWrt 25.12.x обязательна **до** реализации. В этом файле нет исполняемых nftables, iproute2, DNS или procd-конфигураций.


## 12. Draft 3 — уточнения перед (в2), на утверждение владельца

**Статус:** проектное решение, не реализация. Функции (в2) и (в3) остаются выключенными и не входят в PR MVP-c1. Эти пункты уточняют draft 2 и не меняют принятое правило: (в2) никогда не сохраняет активное состояние и не изменяет UCI/DHCP/ethtool.

### 12.1. Источник selected clients и чтение на enable

**Предложение:** единственный источник allowlist — заранее подготовленный администратором файл `/etc/parallax/selected-clients.json` с root-owned обычным файлом `0600` и родительским каталогом root `0700`; симлинки, world/group write и неизвестные JSON-поля отвергаются. Такой конфиг — **постоянный входной набор намерений**, но `parallax net enable/confirm/disable/restore` в (в2) никогда не пишет его, UCI, DHCP или сетевые постоянные настройки. Отключение роутера не приводит к повторной активации, даже при наличии файла.

Схема концептуально содержит explicit selected IPv4 CIDR/host, идентификатор разрешённой LAN/VLAN и отдельный список идентифицируемых выбранных IPv6 источников для политики reject. Никаких wildcard «весь LAN», автоматического выбора новых DHCP-хостов, DNS имён либо неявного inheritance. При проверке клиент определяется **не только** IP, но и входящим LAN интерфейсом/VLAN; NAT перед роутером, случайный IPv6 SLAAC/privacy address или переиспользованный DHCP-адрес делают идентификацию неоднозначной и приводят к отказу (в2) до записи ядра, пока оператор не установит надёжную адресную привязку. Если общая IPv6 /64 содержит и выбранных, и невыбранных клиентов и выделить отдельного выбранного невозможно, нельзя блокировать всех: enable отказывает.

При вызове `parallax net enable` привилегированный control-agent **читает файл только на чтение**, проверяет lstat, owner/mode, схему и непересечение, распознаёт фактический SSH peer, проверяет отсутствие его адреса во всех selected host/CIDR, фиксирует SHA256 и immutable snapshot в `/run/parallax` на generation. Net-agent получает уже проверенный snapshot + generation/hash по контролируемому IPC и не перечитывает файл после старта; изменение исходного файла во время ACTIVE не меняет действующие правила автоматически. Новое содержимое требует `net disable` и нового явного `net enable`/confirm. Snapshot/nonce/ownership manifest удаляются при stop или reboot. Отсутствие файла, пустой allowlist либо несовпадение SHA256/схемы → понятный отказ, никаких nft/rule/route изменений.

**Примечание:** этот путь и формат нужно отдельно утвердить для (в2); в (в1) файл не создаётся и не читается.

### 12.2. Конечные состояния kill-switch после timeout и краша

| Причина | Политика direct | Политика block | После перезагрузки |
| --- | --- | --- | --- |
| Истёк срок **первичного неподтверждённого enable** (90 с) | `ROLLING_BACK → DISABLED/native` | **тот же** `ROLLING_BACK → DISABLED/native`: неподтверждённая конфигурация не оставляет block guard | `DISABLED/native` |
| `sing-box` умер/kill -9 **после подтверждённого ACTIVE** | independent watchdog убирает Parallax-owned правила, `DISABLED/native` | `DEGRADED_BLOCKED`: independent watchdog удерживает **временный** запрет внешних потоков selected, не затрагивая SSH/LAN/unselected; без автоматического direct fallback. Восстановить ACTIVE можно только через повторное явное enable+confirm, либо root CLI `net disable`/`restore_native_internet` делает DISABLED/native | `DISABLED/native`, даже для block |
| Crash net-agent или потеря runtime ownership state при живом ядре | строгое owner-only recovery; неопределённость → `DEGRADED`, без заявления об успехе | `DEGRADED_BLOCKED` разрешён только когда отдельный watchdog уже **проверенно** удерживает защитный guard; иначе это авария, не гарантия отсутствия утечки | `DISABLED/native` |

**Ключевое ограничение:** `block` — не долговечный firewall-policy. По принятому принципу «только временное состояние» после reboot **всегда native**. При таймауте первичного enable выбранный block режим **не сохраняет** блокировку: трафик станет обычным native после полной уборки. Это заранее явно показывается в CLI и read-only LuCI, чтобы пользователь не предполагал постоянный kill-switch.

**Safety-gate для (в2):** симуляции 90-секундного timeout (direct и block), `kill -9 sing-box` при ACTIVE/direct и ACTIVE/block, убийства watchdog, случайного незавершённого rollback и reboot должны подтвердить точно указанные конечные состояния, ACL управления, нулевые Parallax-owned правила после native restore и отсутствие выбранных утечек **пока** guard существует. Если безопасный `DEGRADED_BLOCKED` при живом ядре нельзя гарантировать с отключённым flow offloading и независимым watcher, opt-in `block` **недоступен**, даже если `direct` (в2) работает.

**Следующий gate:** владелец утверждает раздел 12 до написания кода (в2). Пока реализация ограничена (в1) и QEMU.

### MVP-c1 boundary: native sing-box and port collision (QEMU gate)

MVP-c1 deliberately compiles an **inbound-free** configuration (`inbounds: []`). Parallax therefore does **not** bind a local inbound socket or port at this stage; a literal collision between native and Parallax listeners cannot occur in c1. The c1 QEMU gate must still start the **real, package-installed** `/etc/init.d/sing-box` with a harmless 127.0.0.1-only inbound and verify its actual procd registration via real `ubus call service list`, actual sing-box PID and bound socket. Starting Parallax must fail closed while leaving native PID, configuration hash and listening socket unchanged. The disposable QEMU fixture must restore vendor files and service state after the test. No mocked ubus response counts as this gate.

**Mandatory MVP-c2 gate (not implemented or authorized in c1):** once Parallax has its own TCP/UDP listeners, bind native sing-box to the same relevant IPv4/IPv6 addresses/ports in isolated QEMU tests. Verify each family and protocol separately, including wildcard/loopback bind overlap and port release/rebind races, and require Parallax to refuse launch without stopping, reconfiguring or replacing native sing-box. Capture socket ownership, PID/config hashes, ubus service state and full logs as CI artifacts. No c2 network state changes may be performed until separately approved.
