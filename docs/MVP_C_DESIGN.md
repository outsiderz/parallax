# Parallax — Draft 4: безопасное включение сети (MVP-в2)

**Статус:** Draft 4 принят как проект; пять решений раздела 10 утверждены. Разрешён только безопасный подготовительный срез **(в2a-0)** — миграция UCI v2→v3 и read-only preflight/QEMU. **Сетевые записи (в2a/в2b/в2c) НЕ разрешены.** Редакция: 20 ноября 2026 года.  
**Ветка:** docs/mvp-c-draft3, PR #4. Этот текст целиком заменяет предыдущие draft 2 и draft 3, включая старые раздел 12 и блок D3. Других нормативных вариантов списка клиентов или модели состояний нет.  
**Граница:** MVP-в1 принят и находится в main (пакет 0.3.1); реализация сетевой части MVP-в2a, MVP-в2b, MVP-в2c и MVP-в3 не разрешена. Никаких изменений на реальном маршрутизаторе, в действующих VPN или в сетевом коде до отдельного письменного решения владельца.

## 1. Цель, этапы и основные гарантии

Целевая платформа: OpenWrt 25.12.x x86_64, apk, procd, fw4/nftables, iproute2, непривилегированный собственный sing-box. Требование — изменять маршрут только заранее выбранных клиентов, не затрагивая штатный sing-box, Forkop/Podkop/Tachyon, pbr/mwan3, чужие nft/rules/routes, AdGuard/dnsmasq и управление роутером.

| Этап | Возможность | Состояние |
| --- | --- | --- |
| (в1) | Отдельный sing-box от parallax-sb, без inbound, TProxy, nft, маршрутов и DNS | Принято, 0.3.1 |
| (в2a) | **Один IPv4-клиент**, TProxy TCP+UDP, политика direct | Только проект, отдельный QEMU-гейт |
| (в2b) | Независимый kill-switch block для того же IPv4-клиента | Только проект, отдельный QEMU-гейт |
| (в2c) | Выборочный внешний IPv6 reject с ICMPv6 для выбранного клиента | Только проект, отдельный QEMU-гейт |
| (в3) | DNS UDP/TCP 53 и FakeIP только для selected | За пределами (в2), отдельный проект |

Ранее согласованные принципы сохраняются: собственная таблица **inet parallax** и независимый net-agent; отказ при несовместимом fw4 или flow offloading; **90 секунд** на одноразовое подтверждение; direct по умолчанию и block только по явному выбору; IPv6 reject без silent drop; никакого изменения системного DNS; sing-box без root.

**Обязательные инварианты:**

1. Установка, обновление, удаление, загрузка и диагностика не включают перехват. Активное состояние (в2) существует только в ядре и закрытом tmpfs **/run/parallax**; после reboot всегда native.
2. net enable/confirm/disable/restore **не пишут UCI**, DHCP, dnsmasq, AdGuard, resolv.conf, sysctl, ethtool, fw4, постоянные init-скрипты или данные штатного sing-box. Миграция UCI v2→v3 — отдельное офлайновое действие root, **до** net enable.
3. Сетевые команды доступны только root CLI через проверенный SSH management-контекст или физическую консоль для аварийного restore. LuCI/ubus/rpcd остаются read-only.
4. Управляющий SSH-пир, router-local, LAN, DHCP, служебные адреса и трафик невыбранных клиентов остаются native. Невозможность надёжно определить management-peer — отказ до изменения ядра.
5. Неполное доказательство привязки клиента, неясный владелец объектов, отсутствие независимого watchdog, неисправный TProxy listener, конфликт fwmark/routing либо несовместимый fw4/offload — отказ до применения.
6. Удаляются только доказанно **Parallax-owned** nft/rules/routes и точно выбранные conntrack entries. Глобальные flush и удаление по похожему имени запрещены. После проверенного восстановления owned diff пустой, foreign diff нулевой.
7. В артефактах и status не публикуются UUID, private keys, credentials, generated sing-box JSON, cookies, nonce и FakeIP↔domain mappings. Отчётность — метаданные, проверяемые хеши и безопасные packet proofs.

## 2. Компоненты и границы привилегий

| Компонент | Назначение | Ограничение |
| --- | --- | --- |
| parallax-control | Проверка схемы/клиента, preflight, подтверждение, история поколений | root CLI; нет сетевых write-методов в rpcd |
| parallax-net-agent | Применение и отмена только Parallax-owned nft/ip rule/routes по проверенному root-owned manifest и generation | Минимально привилегированный helper, не редактирует чужие объекты |
| parallax-singbox | Отдельный procd-сервис sing-box, TCP/UDP TProxy начиная с (в2a) | parallax-sb, без root; capability только по QEMU-доказательству |
| parallax-recovery | Независимый monotonic deadline, watchdog/health, guard и rollback | Не зависит от живости sing-box и основного control |
| LuCI и ubus | Статус и диагностика, без секретов | Только status/ping, без enable/confirm/disable |

Перед добавлением inbound необходимо проверить на точной версии ядра и sing-box IP_TRANSPARENT, TCP/UDP TProxy, CAP_NET_RAW/CAP_NET_ADMIN и возможность выделить отдельный безопасный socket-setup. Широкие capabilities всему процессу sing-box автоматически не выдаются. Секреты остаются в защищённых root-файлах; процессу доступен лишь минимально необходимый runtime.

## 3. Единственный источник выбранных клиентов — UCI v3

### 3.1. Схема и полномочия

Единственный постоянный источник намерения администратора — именованные UCI-секции **config selected_client** в **/etc/config/parallax**. Никакой второй JSON-allowlist, отдельный файл selected-клиентов, автоматически собранный DHCP-список или правка через LuCI не допускаются. Номер схемы хранится только в **config globals 'main' → option schema_version '3'**, то есть parallax.main.schema_version. Пример будущей схемы:

~~~uci
config globals 'main'
    option schema_version '3'
    option enabled '0'
    option mode 'selective'
    option apply_mode 'config_only'
    option default_outbound 'direct'

config selected_client 'laptop'
    option enabled '1'
    option mac '02:11:22:33:44:55'
    option ipv4 '10.10.20.120'
    option interface 'br-lan.20'
    option binding_proof 'local_lease'
~~~

Строго разрешённые поля каждой секции selected_client: **enabled** (только 0 или 1, обязательно), **mac** (полный канонический unicast MAC), **ipv4** (один IPv4 host, не CIDR), **interface** (реальное точное входящее устройство/VLAN) и **binding_proof** (строго local_lease либо admin_static). Последнее — режим доказательства привязки, а не второй источник данных. Отсутствие поля, неизвестная опция, дубликат MAC/IP, мультикаст/нулевой MAC, неоднозначная VLAN, несуществующий интерфейс, пустой активный список или совпадение с management/router-local — **отказ**.

Только root на локальной системе редактирует раздел через UCI CLI и выполняет явный **uci commit parallax**. Проверяются regular file, lstat, root owner, mode без group/world write, симлинки, размеры и неизменность хеша. Ни LuCI, ни rpcd, ни watcher не имеют права менять выбранный список. Никакие CIDR «весь LAN», имена хостов и неявное включение нового DHCP-устройства в (в2) не поддерживаются.

### 3.2. Миграция schema_version 2 → 3 и строгая валидация

Поставляемый 0.3.1 использует **schema_version 2**: и platform.sh, и render.uc проверяют v2; render.uc сейчас отвергает неизвестный тип UCI-секции. **Просто заменить 2 на 3 без обновления валидатора нельзя.** Описанная ниже миграция — задача только будущей, отдельно разрешённой реализации.

1. **Офлайновый шаг root.** Убедиться, что сетевого поколения нет, валидировать текущую конфигурацию v2, снять root-only резервную копию/хеш. Невалидная v2 или неожиданные опции — отказ без преобразования.
2. Подготовить временную v3, **сохранив существующие profile/rule и значения globals**; изменить только globals.schema_version на 3. Ни один клиент не выводится из старых rules, lease или произвольного файла. Пока root явно не добавит хотя бы одного валидного selected_client, net enable запрещён.
3. Расширить **согласованно** строгие проверки platform.sh, render.uc, transaction/UCI validator и тесты: закрытые поля globals/profile/rule/selected_client; допустимые значения, диапазоны, связи, дубликаты, права, секреты и межсекционные конфликты. Прежние проверки VLESS/Reality и credentials не ослаблять.
4. Валидировать весь кандидат v3, атомарно заменить/commit UCI только после полного PASS, повторно проверить; при ошибке восстановить исходную v2 и её checksum. Никаких сетевых nft/rules/routes на этом шаге; не делать автоконверсию в postinst, при reboot или при net enable.
5. Сетевой control будущей (в2a) требует **строго v3**. v2 остаётся безопасным config-only состоянием. При откате пакета на старый v2-валидатор требуется **явно** восстановить резервную v2, а не пытаться использовать v3 несовместимым бинарником.

Тесты migration gate: сохранение profiles/rules, идемпотентный повтор, отказ на неизвестной опции, дублях MAC/IP, частично записанном файле, пустом selected, несовпадении owner/mode, и нулевой network diff. Миграция сама по себе никогда не включает interception.

### 3.3. Два режима доказательства DHCP/IP-привязки

**Непременное условие net enable:** совпасть должны (1) зафиксированная root-декларация UCI MAC+IPv4+interface и (2) свежий сетевой факт, подтверждающий **тот же MAC на том же IPv4 и входящем L2/VLAN**. Один адрес или один MAC недостаточен.

**local_lease:** локальный действительно авторитетный DHCP-сервер данной VLAN, например dnsmasq, предоставляет доступную только на чтение действующую непосроченную аренду MAC→IPv4. Файл вроде /tmp/dhcp.leases разрешён лишь после проверки владельца этой сети; внешний DHCP не подменяется локальным неавторитетным источником. Дополнительно проверять свежий neighbour по правильному ifindex, bridge FDB при наличии, отсутствие повторного/конфликтующего IP или другого MAC.

**admin_static при внешнем DHCP:** root **в той же секции selected_client** декларативно подтверждает, что на внешнем DHCP действует статическое закрепление указанной тройки MAC–IPv4–сеть/интерфейс. Parallax не подключается к чужому серверу с правами изменения, не пишет вторую базу и не редактирует DHCP. Это доверенное административное утверждение, **не криптографическое подтверждение резервации**; поэтому обязательна **живая проверка соседей**: REACHABLE или эквивалентное доказательство недавнего отклика MAC↔IPv4 на нужном ifindex, проверяемая L2 FDB при применимости и отсутствие конфликтующих ARP. Состояния STALE/INCOMPLETE/FAILED, пропавший neighbour, неподтверждённая VLAN, MAC translation, IP-conflict → отказ. Если доказательства нет, net enable не меняет ни одного сетевого объекта.

MAC может быть подделан. На недоверенном L2 требуется независимый контроль доступа, иначе идентичность не доказана и enable отклоняется. За NAT либо Wi-Fi MAC-NAT, скрывающим источник, нельзя различать selected/unselected только по совпавшему адресу.

**Снимок при enable:** control под lock читает только committed UCI, проверяет права и v3, связывает записи с live proof, вычисляет SHA-256 canonical selection + релевантной UCI-ревизии и сохраняет immutable generation-specific snapshot root 0600 в /run/parallax. Agent читает **только этот снимок**, не UCI. Непосредственно перед первым kernel write ещё раз сравнить hash и binding; изменение → отказ. Любая смена DHCP-адреса, MAC, lease, FDB или UCI в PENDING/ACTIVE выявляется независимым watchdog и ведёт по **единой таблице раздела 6**, а не автоматически назначает перехват новому адресу. Возврат в нормальную работу — только через новое явное enable+confirm.

## 4. IPv4 TProxy, маршрутизация, conntrack и offload

Начиная с (в2a), отдельная **table inet parallax**, не include в inet fw4. Собственный base-chain prerouting с кандидатом priority mangle (ориентир −150, уточняется QEMU), собственные точные sets и правила. Порядок: исключения management, router-local, loopback, DHCP, LAN/infra, multicast, upstream proxy endpoints; отказ от невыбранных источников; точное совпадение IPv4+ingress интерфейс и подтверждённая L2-связь; только внешний TCP/UDP selected → mark + TProxy listener. Не использовать sing-box auto_route, auto_redirect, TUN и другие конкурирующие источники маршрутизации.

**Не резервировать без проверки** примеры: mark 0x00C30000/mask 0x00FF0000, ip rule priority 11000, отдельная table 20263. Обязательны mask-aware пересечения с чужими fwmark/ct mark, всеми IPv4/IPv6 ip rule и routing table IDs, hook priority, pbr/mwan3/Forkop. Маркированные потоки доставляются локально через отдельную policy table, не через смену default route. Отдельно исключать выходящий трафик самого sing-box от зацикливания.

Собственная inet parallax **не может отменить** DROP чужой base-chain fw4. Preflight обязан доказать разрешённую доставку к TProxy socket для selected LAN; если требуются изменения fw4 — **отказ**, а не самостоятельное открытие firewall. Отказ при активном nft software/hardware **flowtable offloading**, который мог бы обойти нужный hook. Никаких автоматических uci set firewall/ethtool. NIC GRO/GSO/TSO/LRO/checksum — отдельная аппаратная тема, их наличие не тождественно nft flowtable; если комбинация несовместима с прозрачной доставкой, QEMU/железный gate не проходит без нового решения.

**Старые сессии:** только прицельный conntrack reset selected по однозначной исходной/обратной tuple и zone на enable/disable/restore. Никогда не сбрасывать management SSH, DHCP, router-local, unselected или чужие mark; no global flush. TCP/UDP/QUIC selected могут оборваться, об этом заранее предупреждают. Ошибка точной фильтрации до enable → отказ; во время восстановления — продолжать owner-scoped cleanup, итог маркировать по разделу 6.

Раздельные netlink-шаги не составляют ACID-транзакцию. Независимый watchdog использует закрытый журнал generation и ownership manifest, отменяет только собственные завершённые шаги в обратном порядке, после чего сверяет baseline; неоднозначные объекты не удаляет.

**Восстановление после перезапуска parallax-recovery (будущие в2a/в2b):** при старте новый экземпляр не предполагает, что сеть чистая. Он читает закрытый root-only журнал, generation, исходные контрольные снимки и ownership manifest из /run/parallax, сверяет идентификаторы, права, хеши и фактические Parallax-owned объекты ядра; при несовпадении фиксирует DEGRADED и не удаляет чужое состояние. Для APPLYING/PENDING либо истёкшего 90-секундного срока запускает owner-only ROLLING_BACK. Для ACTIVE + direct при недоступном или непроверенном sing-box — ROLLING_BACK. Для ACTIVE + block и BLOCKED сохраняет проверенный guard и состояние BLOCKED до администратора; восстановившийся процесс не делает ACTIVE самостоятельно. Если watchdog упал в BLOCKED, **nft guard остаётся в ядре**, пока живо ядро, поскольку это самостоятельный сетевой объект, не принадлежащий процессу watchdog; но без работающего recovery больше нет мониторинга и своевременной диагностики. При повторном старте recovery сначала проверяет фактическую эффективность guard реальным безопасным probe и идентичность generation: лишь затем сообщает BLOCKED; если доказательства нет — DEGRADED и аварийное уведомление. При reboot временные nft-объекты и /run очищаются и система возвращается к DISABLED. **Неповреждённость журнала не равна доказательству наличия guard** — обязательна проверка ядра. Описанное — контракт будущего этапа, в (в2a-0) только чтение без watchdog/guard/net-state.

## 5. Реальный конфликт со штатным sing-box и VPN

В (в1) Parallax отказывал при **любом** работающем штатном sing-box. Для (в2a) сузить правило до реально совместимых/конфликтующих ресурсов можно **лишь после отдельного доказательного QEMU gate**. По умолчанию при неопределённости — отказ. Сам факт «порт свободен» или «стоковый процесс работает» без доказательства владельцев ресурсов недостаточен, чтобы объявить совместимость.

**Проверка:** фактические TCP/UDP bound sockets с PID, namespace, IPv4/IPv6, wildcard 0.0.0.0/:: и loopback 127.0.0.1/::1, IPV6_V6ONLY и dual-stack, races bind/rebind; реальные правила ip -4/-6 rule, fwmark и mask, ct mark, priority/table ID, маршруты, nft hooks/chain priorities, fw4, flowtable, чужие VPN. Совпадающие bind tuple, пересекающиеся mark bits, table IDs, hook ownership или неясные владельцы → отказ до изменений. Никогда не останавливать/disable/править штатный /etc/init.d/sing-box либо /etc/config/sing-box.

**Доказательство QEMU:** установленный native sing-box реально запущен через procd и слушает TCP и UDP; проверяются независимые и пересекающиеся bind IPv4/IPv6, wildcard/specific IP, race, занятые marks/tables и fw4. Настоящий ubus service list, процессы и сокеты; **без mock ubus**. При отказе неизменны native PID, конфиг SHA-256, сокеты, nft/routes/rules других владельцев. В (в2) DNS/AdGuard/dnsmasq только наблюдаются, не меняются.

## 6. Один конечный автомат и одна таблица direct/block

### 6.1. Единственные имена state

**DISABLED** — собственных сетевых перехватов и guard нет, native восстановлен и проверен, после boot всегда DISABLED.  
**APPLYING** — сетевой apply с заранее вооружённым watchdog и runtime journal.  
**PENDING_CONFIRMATION** — применяется временная policy, требуется nonce до 90 секунд.  
**ACTIVE** — подтверждённая policy; независимый health всё ещё контролирует её.  
**ROLLING_BACK** — удаление только собственных объектов, в block guard снимается последним.  
**BLOCKED** — только block: независимый guard **доказанно** блокирует selected external, management/LAN/unselected остаются native, возврат к ACTIVE автоматически запрещён.  
**DEGRADED** — нельзя доказать полный cleanup или наличие/эффективность guard. Ни native, ни блокировка не заявляются как гарантированные.

Слова «нужна помощь администратора», «guard включён» и «native» — пояснения, **не другие имена состояний**. Никаких составных названий состояния.

### 6.2. CLI, подтверждение и одноразовый таймер

Только root в доверенном management SSH: **parallax net enable**, **parallax net confirm NONCE**, **parallax net disable**, **parallax restore_native_internet**. Последний restore работает независимо от sing-box/control, доступен и с физической консоли. LuCI/rpcd только read-only.

До первой сетевой записи выполнить UCI/binding proof, management exclusion, nft/fw4/offload checks, mark/table conflict, listener/health readiness, baseline/undo journal; независимый watchdog обязан быть готов. **90 секунд** monotonic отсчитываются **до первого kernel write**. Неверный nonce, повтор confirm, рестарт или долгая установка таймер не продлевают. Nonce и generation находятся только в закрытом runtime root 0600; подтверждение — однократное из исходного доверенного управления до дедлайна. Disable/restore идемпотентны.

### 6.3. Единая таблица переходов (нормативная для всех трёх в2-гейтов)

| Событие / исходная фаза | direct | block | Обязательная проверка |
| --- | --- | --- | --- |
| Успешный preflight, DISABLED | APPLYING → PENDING_CONFIRMATION | То же, защитный guard должен быть готов раньше риска direct fallback | Watchdog, generation, listener, native management |
| Успешный confirm до 90 секунд | PENDING_CONFIRMATION → ACTIVE | PENDING_CONFIRMATION → ACTIVE | Правильный одноразовый nonce и packet probes |
| Ошибка preflight до первого kernel write | остаётся DISABLED | остаётся DISABLED | Нулевой network diff |
| Ошибка apply, crash в APPLYING/PENDING или таймаут 90 с | ROLLING_BACK → DISABLED | ROLLING_BACK → DISABLED; guard удалить последним | Полный owner-only cleanup, native probe, nonce уничтожен |
| Крах sing-box, потеря здоровья, DHCP/MAC/IP rebind **в ACTIVE** | ROLLING_BACK → DISABLED | ACTIVE → BLOCKED, только если guard подтверждён | Без скрытого direct fallback в block |
| Крах control/net-agent, fw4 reload, outage | Независимый watchdog применяет переход по текущей фазе | Аналогично; ACTIVE → BLOCKED при исправном guard | Не зависит от живого sing-box |
| Явный net disable / restore | ROLLING_BACK → DISABLED | ROLLING_BACK → DISABLED, guard снять последним | Targeted conntrack; foreign diff нулевой |
| Недоказуемый rollback/guard/состояние ядра | DEGRADED | DEGRADED | Аварийная диагностика без ложного BLOCKED/PASS |
| Reboot из любой фазы | DISABLED | DISABLED, без постоянного block | Нет auto-enable; kernel и /run чистые |

**Сигнал при падении sing-box в ACTIVE + direct:** независимый recovery/health детектирует потерю PID/проверки outbound, немедленно фиксирует событие `SINGBOX_CRASH_DIRECT` с timestamp, generation, прежним и итоговым state и причиной в закрытом журнале и в read-only `parallax status` (например, `last_event`, `last_error`, `needs_attention=true`, без credentials). Выполняется ROLLING_BACK → DISABLED; отсутствие подтверждённого rollback даёт DEGRADED и повышенную критичность. Администратор видит остановку и последнюю причину в status; в будущем допускается Telegram-уведомление через **отдельный, явно разрешённый канал событий**, с rate limit, без токенов/секретов в тексте, и никогда не как зависимость rollback. **В (в2a-0) событийного recovery нет**: статус read-only, никаких уведомлений Telegram, запуска или изменения сети.

**Принятое проектное строгое поведение ACTIVE + block:** после смерти sing-box (включая kill -9), хотя procd может автоматически перезапустить PID, **BLOCKED сохраняется до явного действия root**. Наличие живого PID, открытого TCP порта или одного удачного ping не доказывает здоровый outbound/ownership/маршрут и отсутствие утечки. Авто-возврат BLOCKED→ACTIVE в (в2b)/(в2c) **не предусмотрен**. В принципе он допустим лишь как **отдельно одобренная** функция после специального health-gate: фактические selected TCP+UDP через правильный outbound, выбранный mark/rule/route, целостность guard, контроль отсутствия direct leakage, независимая повторная авторизация generation. Пока этого теста нет, root должен выполнить disable/restore до DISABLED, устранить сбой и отдельно новый enable+confirm.

**Гарантия block ограничена временем активного включения:** таймаут неподтверждённого enable, ручное disable и reboot заканчиваются состоянием DISABLED/native, **не вечной блокировкой**. При невозможности доказать guard нельзя отвечать BLOCKED: только DEGRADED с аварийным сигналом. Если guard достоверно остался, до диагностики его не снимают преждевременно, но статус всё равно DEGRADED при неуспешном cleanup.

## 7. IPv6 в (в2c) и DNS только в будущем (в3)

До (в2c) разрешён **только отдельно доказанный IPv4-only selected** в изолированном QEMU. На реальном dual-stack устройстве в (в2a)/(в2b) enable должен отказывать, если нельзя доказать отсутствие выбранного внешнего IPv6 выхода. Parallax не отключает IPv6 изменением RA/DHCP/sysctl или интерфейса.

В (в2c) выбранный **внешний** IPv6 получает ICMPv6 Destination Unreachable / Administratively Prohibited **вместо silent drop**. UCI-источник не меняется: MAC+IPv4+ingress interface. IPv6-классификация выполняется по **реальному ingress L2 source MAC и интерфейсу** выбранного клиента: нельзя делать выбор по общей /64, SLAAC/privacy address или считать IPv4 адрес идентификатором IPv6. В QEMU нужно доказать доступность MAC-поля именно в проверяемом nft hook. Если AP/bridge/MAC NAT/туннель скрывает MAC либо NIC не даёт однозначного L2 признака, enable отказывает.

Не блокировать ND, RA, DHCPv6, link-local, multicast, router-local, local LAN и management. Unselected IPv6 остаётся native. Проверить реальный ICMPv6 reject и отсутствие selected external IPv6; Happy Eyeballs — таймстемпы IPv6 SYN, reject и IPv4 TCP connect через прокси. Предложенные QEMU-пороги: p95 ≤3 с, max ≤5 с, сравнить с native и silent-drop контрольными группами; окончательные цифры согласовать по baseline.

**DNS не перехватывается в (в2a–в2c)**. Системные DNS, AdGuard/dnsmasq, DHCP и resolv.conf неизменны. Только отдельный будущий (в3) может перехватывать **selected UDP/TCP 53** на свой resolver в inet parallax, FakeIP с безопасным TTL/eviction/reverse mapping. Это не покрывает DoH/DoT/DoQ и зашифрованный DNS на HTTPS/QUIC; не обещать полную DNS privacy до отдельного разрешения и gate.

## 8. Три последовательных независимых QEMU-гейта

**Топология:** OpenWrt 25.12 x86_64 QEMU, отдельные искусственные LAN/WAN, selected/unselected client namespaces и **третий независимый management SSH канал**, WAN TCP/UDP peer, синтетические credentials. Нельзя менять реальные сетевые интерфейсы CI host или домашний роутер. Доказательство основано на packet capture и реальной доставке, **не только** nft-счётчиках.

### 8.1. (в2a) — один IPv4-клиент, direct

**Объём:** ровно один selected_client v3, один достоверный MAC+IPv4+interface, только IPv4, TCP/UDP TProxy и direct; независимые watchdog/90-секундный rollback. Guard block не входит.

**QEMU-гейт:** полноценная миграция v2→v3, строгий UCI validator и отказ при незаявленном/дублирующемся клиенте; **оба доказательства DHCP** (local_lease и внешнее admin_static + живой neighbour) с негативными тестами STALE, DHCP rebind, чужой MAC, IP conflict; real selected TCP/UDP через outbound с правильными source/destination; unselected и management native; реальный SSH peer не selected; root CLI и read-only LuCI; targeted conntrack без обрыва чужих сессий; конфликт marks/tables/fw4/offload/native sing-box → отказ до изменений. Timeout, crash control/sing-box/watchdog, reboot, partial apply, повторное disable/restore → только DISABLED после проверенного rollback или DEGRADED с явной ошибкой.

**PASS:** фактический TCP/UDP selected end-to-end, неизменность управления/невыбранных, полный собственный rollback, нулевой foreign diff, закрытые секреты, полный CI artifact. Отдельное разрешение владельца до (в2b).

### 8.2. (в2b) — строгий kill-switch block

**Объём:** тот же доказанный IPv4-only selected, отдельный opt-in block и независимый guard. Ни один procd respawn сам не возвращает BLOCKED в ACTIVE.

**QEMU-гейт:** при подтверждённом ACTIVE выполнить реальный kill -9 sing-box и выключить outbound; доказать packet capture, что selected external не ушёл напрямую, при сохранении native management/LAN/unselected; устойчивый BLOCKED после автоматического procd restart; выход только root через disable/restore → DISABLED. Проверить 90-секундный timeout до confirm, crash в APPLYING/PENDING, reboot, idempotent commands, повреждённый manifest, отсутствие guard, падение watchdog, частичный conntrack reset. Если guard не доказан, должен быть **DEGRADED**, не ложный BLOCKED. Временные/пакетные окна direct leakage = FAIL. Иностранные nft/routes/rules не трогать.

**PASS:** подтверждённое fail-closed поведение в ACTIVE, строгий ручной выход, отсутствие бесконечной блокировки после disable/reboot, точные статусы и полный QEMU artifact. Отдельное разрешение до (в2c).

### 8.3. (в2c) — выборочный IPv6 ICMPv6 reject

**Объём:** selected IPv6 external reject без IPv6 proxy, на основе того же MAC+interface и тех же UCI selected_client. Прежний IPv4 TProxy/block сохраняет испытанные гарантии.

**QEMU-гейт:** selected и unselected в **общем IPv6 /64**, SLAAC и privacy адреса; реальный L2 ingress MAC в nft, без группового блокирования всей подсети; ICMPv6 administratively prohibited, не drop; unselected external IPv6 и ND/RA/DHCPv6/link-local/multicast/native management работают. Измерить Happy Eyeballs и IPv4 TCP connect. Негативные кейсы bridge/AP MAC translation, неопределённый ingress, offload, kill -9, timeout, reboot и rollback; режим block проверить вместе с IPv6 reject. Снимки чужих объектов нулевые.

**PASS:** нет успешного внешнего IPv6 selected, reject корректен, IPv4 fallback реально измерен, unselected/management сохранены, собственная очистка полная. Успех (в2c) **не разрешает (в3)**.

### 8.4. Обязательные доказательства каждого гейта

Хранить stdout/stderr, exit codes, точные timestamp/generation/deadline и PASS/FAIL; настоящие procd/ubus PID + bound sockets, nft JSON **raw и normalized**, ip -4/-6 rule/routes всех таблиц, masks, flowtable/offload, selected conntrack metadata, DHCP/neighbour proof, DNS/resolv.conf, UCI (без секретов), sysctl, ethtool, контроль management и synthetic TCP/UDP/IPv6 packet captures. Только нестабильные счётчики исключаются из normalized diff, raw сохраняется. **Нет доказательства → FAIL**, а не условный PASS. Никаких секретов в отчетах.

## 9. Аппаратный go/no-go — план до любых действий на роутере

Перед установкой на домашний шлюз обязателен **отдельный непродукционный физический x86-тест** и персональное разрешение владельца. Ниже — план **read-only** проверок, выполнять на работающем роутере без нового разрешения нельзя.

| Проверка | Что зафиксировать / когда отказать |
| --- | --- |
| Физические NIC и драйверы | ip -br link, lspci -nnk, ethtool -i, MAC/permanent MAC, PCI ID, driver/firmware; однозначная карта WAN, LAN, trunk/VLAN, management и мостов |
| VLAN/DHCP | Ifindex и tagged/untagged, VLAN 20/30 и фактические сети, authoritative DHCP (локальный или внешний), возможный AP/MAC-NAT и trust boundary |
| Offload | uci show firewall, fw4 print, nft list ruleset/flowtables; software/hardware offload, обход TProxy. Любая неопределённость → отказ |
| NIC features | ethtool -k для GRO/GSO/TSO/LRO/checksum/VLAN/steering; отдельно от nft flowtable, **ничего не выключать автоматически** |
| Routing и VPN conflicts | Все ip -4/-6 rule, tables/route get, fwmark masks, nft hooks, owner sockets и существующие sing-box/Forkop/Podkop/Tachyon/pbr/mwan3 |
| Kernel/сокеты | OpenWrt/kernel/sing-box ABI, nft tproxy, IP_TRANSPARENT, безопасный parallax-sb и независимый watchdog |
| Доступ | Проверенный SSH management peer, local/OOB консоль, резервная native route, запрет выбирать management |
| Откат | Подтверждённые backups /etc/config, baseline nft/rules/routes/DNS, полный restore на **непродукционном** железе, измеренная непрерывность доступа |
| Разрешение | Сначала независимые PASS (в2a→в2b→в2c), затем физический тест, затем отдельное решение по рабочему роутеру |

## 10. Открытые решения и источники

Перед утверждением draft 4 владелец должен отдельно принять: расширение UCI/правила миграции v3; модель доверия **admin_static + live neighbour** для внешнего DHCP; строгий **ACTIVE → BLOCKED до действия администратора**; запрет работы на dual-stack selected до (в2c); критерии ресурсов native sing-box и обязательный аппаратный go/no-go.

Версии sing-box, OpenWrt, kernel/fw4 и требуемые capability должны быть зафиксированы отдельно в каждом QEMU-gate. Приведённые mark, priority, table ID, hook и пороги — проектные кандидаты, не право их применять.

Технические справочные материалы для будущей проверки кода:

- Linux TProxy: https://www.kernel.org/doc/html/latest/networking/tproxy.html
- nftables hooks/priority: https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks
- Linux flowtable: https://cdn.kernel.org/doc/html/latest/networking/nf_flowtable.html
- OpenWrt fw4 include: https://github.com/openwrt/firewall4/blob/master/root/usr/share/nftables.d/README
- sing-box TProxy inbound: https://sing-box.sagernet.org/configuration/inbound/tproxy/
- sing-box migration: https://sing-box.sagernet.org/migration/

**Итог:** пять архитектурных решений раздела 10 утверждены, но допуск к сетевой реализации **не дан**. Одобрен исключительно (в2a-0): офлайновая миграция v2→v3 и read-only `parallax net preflight` в отдельной ветке и QEMU, без создания nft, ip rule, маршрутов, conntrack или изменения DNS. После результатов (в2a-0) требуется отдельное решение о переходе к сетевому (в2a).
