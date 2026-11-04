# ocserv-warp

VPN-сервер (ocserv, совместим с Cisco AnyConnect / OpenConnect) и прокси (HTTP + SOCKS5)
с выходом в интернет **только через Cloudflare WARP**. Если WARP недоступен, трафик
не идёт вообще: реальный IP сервера наружу не попадает.

Один логин и пароль на человека действует и для VPN, и для прокси. Пользователи
добавляются одной командой.

| Контейнер | Образ | Что делает |
|---|---|---|
| `ocwarp-netns` | `ghcr.io/ccbkkb/microwarp` | Владеет сетью и портами, держит kill-switch |
| `ocwarp-warp` | `ghcr.io/ccbkkb/microwarp` | [MicroWARP](https://github.com/ccbkkb/MicroWARP): WireGuard до Cloudflare WARP, интерфейс `wg0` |
| `ocwarp-ocserv` | `r4venme/ocserv` | ocserv 1.6, вход по логину и паролю |
| `ocwarp-proxy` | `3proxy/3proxy` | HTTP-прокси и SOCKS5 с авторизацией |

Как это работает внутри — в разделе [Внутреннее устройство](#внутреннее-устройство).

## Требования

- **Docker Engine 26+** (нужен `volume.subpath`).
- **Portainer** со встроенным docker compose 2.24+ (нужен `configs.content`).
- **Linux-ядро 5.6+** с модулем WireGuard.
- **Свободные порты** на хосте: `443/tcp`, `443/udp`, `1080/tcp`, `3128/tcp` (меняются переменными).
- **Доступ с сервера к GitHub и Cloudflare** при первом запуске: регистрация WARP скачивает `wgcf` с GitHub.

## Развёртывание в Portainer

1. **Stacks → Add stack → Web editor**, вставить содержимое `docker-compose.yml`.
2. В **Environment variables** при необходимости задать:

   | Переменная | По умолчанию | Что это |
   |---|---|---|
   | `VPN_PORT` | `443` | Порт ocserv на хосте (TCP и UDP) |
   | `SOCKS_PORT` | `1080` | Порт SOCKS5 на хосте |
   | `HTTP_PORT` | `3128` | Порт HTTP-прокси на хосте |
   | `VPN_DOMAIN` | `localhost` | Имя сервера в сертификате ocserv |
   | `ALLOWED_SOURCES` | пусто (всем) | Кому можно подключаться ко всем портам стека: IP или CIDR через запятую, например `203.0.113.10,198.51.100.0/24` |
   | `WARP_ENDPOINT` | `162.159.192.1:2408` | Адрес и порт Cloudflare для WireGuard. Менять только если UDP 2408 заблокирован, см. [Диагностика](#диагностика) |

3. **Deploy the stack.**

Первый запуск занимает 1–2 минуты: `ocwarp-warp` регистрирует устройство в Cloudflare
и поднимает `wg0`. Регистрация выполняется один раз, профиль сохраняется в volume.

### Проверка

Все четыре контейнера должны быть `healthy`:

| Контейнер | `healthy` означает |
|---|---|
| `ocwarp-netns` | kill-switch применён |
| `ocwarp-warp` | выход идёт через WARP: `https://1.1.1.1/cdn-cgi/trace` отвечает `warp=on` или `warp=plus` |
| `ocwarp-ocserv` | ocserv слушает порт |
| `ocwarp-proxy` | 3proxy слушает оба порта |

Docker не перезапускает `unhealthy`-контейнеры, это только индикатор.

Затем добавьте пользователя (см. ниже) и проверьте выход через прокси:

```sh
curl -x http://alice:ПАРОЛЬ@<сервер>:3128 https://www.cloudflare.com/cdn-cgi/trace
```

В ответе `warp=on` (или `warp=plus`), а `ip=` не совпадает с IP сервера.

## Пользователи

Одна команда добавляет пользователя и в VPN, и в прокси. Перезапуск не нужен: ocserv
читает пароли при каждом входе, 3proxy перечитывает список в течение минуты.

**Через Portainer:** Containers → `ocwarp-ocserv` → Console → Command `/bin/bash` → Connect, затем:

```sh
vpnuser add alice              # пароль сгенерируется и покажется один раз
vpnuser add bob 'MyPassw0rd'   # или задать свой
vpnuser passwd alice           # новый пароль (сгенерировать)
vpnuser passwd alice 'New0ne'  # новый пароль (свой)
vpnuser del alice              # удалить везде; VPN-сессии рвутся сразу, прокси — в течение минуты
vpnuser list                   # кто есть и где
```

**С хоста:** `docker exec -it ocwarp-ocserv vpnuser add alice`.

- **Логин:** латиница, цифры и `.`, `_`, `-`, до 32 символов.
- **Пароль:** от 2 символов, печатные ASCII без пробелов и двоеточия.

Пароль печатается только в терминал, в логи контейнера не попадает.

> Встроенную команду образа `ocuser` не использовать: она создаёт клиентские сертификаты,
> не трогает прокси и печатает пароли в `docker logs`.

## Подключение

### VPN

Адрес сервера: `<сервер>:443` (порт из `VPN_PORT`). Протокол: AnyConnect.
Сертификат сервера самоподписанный, клиент при первом входе покажет предупреждение.
Отпечаток для сверки:

```sh
docker exec ocwarp-ocserv certtool --certificate-info \
  --infile /etc/ocserv/ssl/current/fullchain.pem | grep -E -A2 'Fingerprint|Public Key PIN'
```

Клиенты:

- **Cisco Secure Client (AnyConnect):** в настройках снять **Block connections to untrusted servers**, при подключении принять сертификат.
- **OpenConnect GUI (Windows), OpenConnect (Android, Linux NetworkManager):** принять сертификат при первом входе. Галка **Disable UDP** в профиле должна быть **снята**: с ней туннель идёт по TCP и в разы медленнее.
- **openconnect (CLI):**

  ```sh
  sudo openconnect --protocol=anyconnect --user=alice \
    --servercert pin-sha256:XXXX <сервер>:443
  ```

Внутри VPN: адреса `10.10.10.0/24`, DNS `1.1.1.1`/`8.8.8.8`, MTU 1280. Весь трафик,
включая DNS и UDP, идёт через WARP. IPv6 блокируется. Клиенты не видят друг друга,
приватные сети и сеть Docker на сервере.

### Прокси

```
HTTP:    http://alice:ПАРОЛЬ@<сервер>:3128
SOCKS5:  socks5://alice:ПАРОЛЬ@<сервер>:1080
```

- **DNS-имена резолвит прокси, через WARP.** Для SOCKS5 используйте `socks5h://`.
- **HTTP-прокси анонимный:** заголовков `X-Forwarded-For` и `Via` нет.
- **Приватные сети через прокси недоступны.**
- **UDP через SOCKS5 не работает.** Для UDP (QUIC, DNS) используйте VPN.

## Обслуживание

### Переменные и порты

Любое изменение переменных стека: **Update the stack**. Контейнер `ocwarp-netns`
пересоздаётся, за ним перезапускаются остальные три. VPN-сессии при этом рвутся.

Опубликованные Docker порты обходят `ufw` и firewall хоста. Ограничивать доступ
нужно переменной `ALLOWED_SOURCES`.

### Обновление образов

Поменять теги в compose, **Update the stack** с **Re-pull image**.

### Правка скриптов и конфигов в compose

Скрипты и конфиг 3proxy лежат в compose (`configs:`). **Update the stack** их изменения
не применяет: контейнеры с прежними конфигами не пересоздаются. Чтобы применить:

```sh
docker rm -f ocwarp-netns ocwarp-warp ocwarp-ocserv ocwarp-proxy
```

затем **Update the stack**.

Исходники скриптов лежат в `build/`; `docker-compose.yml` собирается из них:

```sh
python3 build/gen.py build docker-compose.yml
```

### Где лежат настройки

Всё в одном volume `ocwarp-config`:

```
warp/      wg0.conf — профиль (ключ) устройства WARP
ocserv/    ocserv.conf, ocpasswd (пользователи VPN), certs/, ssl/ (CA и сертификат сервера)
3proxy/    users.cfg — пользователи прокси (строки "users логин:CL:пароль", права 600)
state/     ready — идентификатор сети, в которой применён kill-switch
```

`ocwarp-netns` видит весь volume, остальные контейнеры — свои подкаталоги; ocserv
дополнительно видит `3proxy/` (туда пишет `vpnuser`).

- **`ocserv.conf`** создаётся из шаблона в compose только при первом запуске, дальше правится в volume. Ключи, которые задаёт окружение (порт, сеть, DNS, сертификаты, MTU), там игнорируются. После правки: `docker restart ocwarp-ocserv`.
- **Конфиг 3proxy** лежит в compose (`configs.proxy_cfg`), применяется как описано выше.
- **Пароли прокси** в `users.cfg` хранятся открытым текстом. Файл читается только root на хосте.

### Резервная копия

Создать:

```sh
docker run --rm -v ocwarp-config:/c -v "$PWD":/b alpine tar czf /b/ocwarp-config.tgz -C /c .
```

Восстановить (контейнеры удалены, см. «Правка скриптов»):

```sh
docker run --rm -v ocwarp-config:/c -v "$PWD":/b alpine sh -c 'rm -rf /c/* && tar xzf /b/ocwarp-config.tgz -C /c'
```

затем **Update the stack**.

### Перерегистрация WARP

```sh
docker exec ocwarp-netns rm /config/warp/wg0.conf
docker restart ocwarp-warp
```

ocserv и прокси останавливать не нужно.

### Удаление

**Delete the stack** в Portainer удаляет контейнеры. Volume с профилем WARP и
пользователями остаётся: `docker volume rm ocwarp-config`.

## Логи

В логи пишется только важное: запуск, регистрация WARP, подключение и отключение
VPN-клиентов, ошибки. Каждый лог ограничен 3 × 10 МБ.

Журнал запросов 3proxy выключен. Включить: добавить строку `log` в `configs.proxy_cfg`,
применить как описано в «Правка скриптов». Запросы попадают в `docker logs ocwarp-proxy`.

## Диагностика

```sh
docker logs ocwarp-netns                      # kill-switch применён? доступ для регистрации открыт/закрыт?
docker logs ocwarp-warp                       # регистрация, подъём wg0, выходной IP
docker exec ocwarp-warp wg show               # handshake с WARP идёт?
docker exec ocwarp-netns iptables -S          # правила kill-switch (первый рубеж)
docker exec ocwarp-netns iptables -t mangle -S   # метка ответов (MARK) и второй рубеж (EGRESS)
docker exec ocwarp-ocserv nft list ruleset    # правила самого ocserv (в iptables -S не видны)
docker exec ocwarp-ocserv occtl show users    # кто подключён к VPN
docker exec ocwarp-ocserv occtl show ip ban points   # бан-очки по IP
```

- **Клиент VPN не подключается, другие с того же IP тоже.** IP в бане ocserv. Неверный пароль даёт 10 очков, каждое подключение — 1; при 80 очках IP блокируется на 5 минут, счёт обнуляется каждые 20 минут. Все клиенты за одним NAT делят счёт. Снять бан: `docker exec ocwarp-ocserv occtl unban ip <IP>`. Пороги: `ban-time`, `max-ban-score`, `ban-reset-time` в `ocserv.conf`.
- **VPN работает медленно.** В клиенте включён «Disable UDP» или UDP 443 до сервера не проходит: туннель идёт по TCP. Проверка: `occtl show users`, столбец `dtls-cipher` не должен быть `(no-dtls)`.
- **`ocwarp-warp` не становится `healthy`, в `wg show` нет `latest handshake`.** UDP 2408 до Cloudflare блокируется. Задать `WARP_ENDPOINT` с другим портом (`500`, `1701`, `4500`) или адресом (`162.159.192.0/24`, `162.159.193.0/24`), например `162.159.192.1:4500`, затем **Update the stack**. Адрес задаётся числом: до подъёма `wg0` DNS недоступен.
- **Клиенты получают таймаут, а `curl -k https://127.0.0.1:443` с хоста работает.** Нет правила `MARK … --ctdir REPLY` в `iptables -t mangle -S`: ответы клиентам уходят в `wg0`. Смотреть `docker logs ocwarp-netns`.
- **ocserv, прокси или warp не стартуют, в логах пусто.** Ждут `state/ready` от `ocwarp-netns`. Смотреть `docker logs ocwarp-netns`.
- **Регистрация WARP падает на скачивании `wgcf` или `SERVFAIL` от DNS.** В `docker logs ocwarp-netns` должно быть «открыт доступ для регистрации», в `docker exec ocwarp-netns iptables -L BOOTSTRAP -v -n` растут счётчики. `docker exec ocwarp-warp nslookup api.github.com` должен отвечать.
- **`subpath` / `volume options` в ошибке деплоя.** Docker старше 26.
- **`ocwarp-netns` пересоздан отдельно** (`docker rm` + `up` одного сервиса). Остальные три остались в прежней сети: связи нет, утечки тоже. **Update the stack** пересоздаёт всё в правильном порядке.

## Внутреннее устройство

```
                ┌─ ocwarp-netns: общая сеть всех четырёх контейнеров ──────────────┐
 клиент VPN ────┼─► ocwarp-ocserv ─┐                                               │
   443 tcp/udp  │                  ├─► wg0 (ocwarp-warp) ── шифрует ─┐             │
 клиент прокси ─┼─► ocwarp-proxy  ─┘                                 │             │
   1080 / 3128  │                                                    ▼             │
                │  любой трафик мимо wg0 ─────────► kill-switch на eth0 ───────────┼──► Cloudflare WARP ──► интернет
                │                                   (держит ocwarp-netns)          │
                │                                   ✓ пакеты WireGuard             │
                │                                   ✓ ответы клиентам              │
                │                                   ✗ всё остальное: DROP          │
                └──────────────────────────────────────────────────────────────────┘
```

Все четыре контейнера работают в одной сети (netns), владелец — `ocwarp-netns`.
Единственный выход наружу — `eth0`, на нём kill-switch. Он действует на VPN-клиентов,
клиентов прокси и сами контейнеры. Маршрут по умолчанию ведёт в `wg0`; через `eth0`
проходят только зашифрованные пакеты WireGuard и ответы клиентам.

Порядок запуска: `ocwarp-netns` применяет kill-switch и пишет в `state/ready`
идентификатор своей сети. Остальные три перед стартом ждут, пока идентификатор
совпадёт с их собственным. ocserv и прокси от WARP не зависят: без `wg0` они работают,
но трафик никуда не уходит.

| Ситуация | Что происходит |
|---|---|
| WARP недоступен, но `wg0` есть | Трафик уходит в `wg0` и там пропадает. `ocwarp-warp` становится `unhealthy` |
| Перезапуск или обновление `ocwarp-warp` | Несколько секунд нет `wg0`, kill-switch всё отбрасывает. ocserv и прокси не перезапускаются, клиенты VPN не отключаются |
| Первый запуск, профиля WARP нет | Через `eth0` открыты DNS и TCP/443 только процессам root (цепочка `BOOTSTRAP`). 3proxy работает от uid 65535, трафик VPN-клиентов транзитный. После сохранения профиля доступ закрывается |
| Ответы клиентам VPN и прокси | Пакеты направления REPLY (conntrack) получают метку `0xca6c`, по которой wg-quick пропускает их мимо `wg0`. Исходящие соединения процессов метку не получают |
| Пакет направлен в `eth0` в обход правил | Второй рубеж в `mangle/POSTROUTING` (цепочка `EGRESS`) проверяет фактический интерфейс выхода: только WireGuard, ответы клиентам и `BOOTSTRAP` |
| DNS через резолвер Docker (`127.0.0.11`) | Резолвер пересылает запросы из этой же сети: через `wg0`, при регистрации WARP — через `eth0` от root. 3proxy и VPN-клиенты им не пользуются, их DNS идёт на 1.1.1.1 через WARP |
| IPv6 | Наружу закрыт полностью. Клиентам VPN выдаётся v6-маршрут в туннель, где v6 отбрасывается |
| MTU 1280 у WARP | MTU туннеля VPN 1280, TCP MSS подрезается (`TCPMSS --clamp-mss-to-pmtu`) |
| Перезагрузка сервера | Контейнеры стартуют в произвольном порядке; ocserv, прокси и warp ждут `state/ready` |

Граница доверия: kill-switch обходится только процессом с `NET_ADMIN` внутри этой
сети (метка `0xca6c` или правка правил). Такие права есть у `ocwarp-netns`,
`ocwarp-warp` и `ocwarp-ocserv`; у 3proxy их нет.
