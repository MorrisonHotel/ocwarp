#!/bin/sh
# Kill-switch общего сетевого пространства (netns) стека. Применяется до старта
# остальных контейнеров: они ждут файл ready с идентификатором этого netns.
#
# Через eth0 наружу проходят только:
#   - пакеты WireGuard: сокет wg0 помечен fwmark 0xca6c (ставит wg-quick);
#   - ответы на соединения, начатые снаружи (conntrack-направление REPLY):
#     клиенты VPN и прокси;
#   - на время регистрации WARP (нет wg0.conf): DNS и TCP/443, только от root.
# Остальное уходит только через wg0. Нет wg0 — нет связи.
#
# Встроенный DNS Docker (127.0.0.11) пересылает запросы наружу из этого же
# netns: в штатном режиме через wg0, при регистрации — через eth0 от root.
#
# Маршрут ответов: wg-quick ставит правило "всё без метки 0xca6c — в wg0" и
# всегда ставит его первым, поэтому ответным пакетам присваивается та же метка
# (mangle OUTPUT), и они идут по main-таблице через eth0. Исходящие соединения
# процессов в netns — направление ORIGINAL, метку не получают.
#
# Проверка выхода стоит в двух местах: filter/OUTPUT видит интерфейс до
# перемаршрутизации по метке, mangle/POSTROUTING (EGRESS) — фактический.
set -eu

WG_IF=wg0
OC_IF=oc-client+          # TUN-устройства ocserv, по одному на клиента
WG_MARK=0xca6c
WARP_CONF=/config/warp/wg0.conf
READY=/config/state/ready

rm -f "$READY"
mkdir -p /config/warp /config/ocserv /config/3proxy /config/state

public_rules() {
  sources="$(printf '%s' "${ALLOWED_SOURCES:-}" | tr ',' ' ')"
  if [ -z "$sources" ]; then
    echo "-A PUBLIC -j ACCEPT"
    return
  fi
  for src in $sources; do
    echo "-A PUBLIC -s $src -j ACCEPT"
  done
  echo "-A PUBLIC -j DROP"
}

iptables-restore <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
:PUBLIC - [0:0]
:BOOTSTRAP - [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -i eth0 -p tcp -m multiport --dports 443,1080,3128 -j PUBLIC
-A INPUT -i eth0 -p udp --dport 443 -j PUBLIC
-A INPUT -i $OC_IF -p icmp -j ACCEPT
-A FORWARD -m conntrack --ctstate INVALID -j DROP
-A FORWARD -i $OC_IF -o $WG_IF -j ACCEPT
-A FORWARD -i $WG_IF -o $OC_IF -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o $WG_IF -j ACCEPT
-A OUTPUT -o $OC_IF -j ACCEPT
-A OUTPUT -o eth0 -m mark --mark $WG_MARK -j ACCEPT
-A OUTPUT -o eth0 -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
-A OUTPUT -o eth0 -j BOOTSTRAP
$(public_rules)
COMMIT
*mangle
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
:EGRESS - [0:0]
:BOOTSTRAP - [0:0]
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j MARK --set-mark $WG_MARK
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
-A POSTROUTING -o eth0 -j EGRESS
-A EGRESS -m mark --mark $WG_MARK -j RETURN
-A EGRESS -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j RETURN
-A EGRESS -j BOOTSTRAP
-A EGRESS -j DROP
COMMIT
EOF

# NAT клиентов VPN на выходе в wg0. Таблица nat не сбрасывается: в ней правила
# Docker для 127.0.0.11.
iptables -t nat -C POSTROUTING -o $WG_IF -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o $WG_IF -j MASQUERADE

# IPv6 наружу не ходит. Стек включён, чтобы ocserv выдавал клиентам v6-маршрут
# в туннель, где v6 отбрасывается (иначе клиент пустил бы v6 мимо VPN).
ip6tables-restore <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -i $OC_IF -p ipv6-icmp -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o $OC_IF -j ACCEPT
COMMIT
EOF

echo "[netns] kill-switch применён, ALLOWED_SOURCES=[${ALLOWED_SOURCES:-все}]"
readlink /proc/self/ns/net > "$READY"

# Доступ для регистрации WARP: DNS (пересылает dockerd, root) и TCP/443 (wgcf,
# root). Только root: 3proxy работает от uid 65535, трафик VPN-клиентов —
# транзитный, без сокета. Цепочка BOOTSTRAP есть в filter и mangle.
bootstrap() {
  for table in filter mangle; do
    iptables -t $table -F BOOTSTRAP
    [ "$1" = open ] || continue
    iptables -t $table -A BOOTSTRAP -m owner --uid-owner 0 -p udp --dport 53 -j ACCEPT
    iptables -t $table -A BOOTSTRAP -m owner --uid-owner 0 -p tcp --dport 53 -j ACCEPT
    iptables -t $table -A BOOTSTRAP -m owner --uid-owner 0 -p tcp --dport 443 -j ACCEPT
  done
}

state=""
while :; do
  if [ -s "$WARP_CONF" ]; then want=closed; else want=open; fi
  if [ "$want" != "$state" ]; then
    bootstrap $want
    if [ "$want" = open ]; then
      echo "[netns] WARP-профиля нет: открыт доступ для регистрации (DNS, TCP/443, только root)"
    elif [ -n "$state" ]; then
      echo "[netns] WARP-профиль создан: доступ для регистрации закрыт"
    fi
    state=$want
  fi
  sleep 3
done
