#!/bin/sh
set -eu
. /usr/local/sbin/wait-ready.sh

# Файл пользователей (строки "users логин:CL:пароль") должен существовать,
# пустой допустим. Пишет его vpnuser из контейнера ocserv.
touch /conf/users.cfg
chown 65535:65535 /conf/users.cfg
chmod 600 /conf/users.cfg

exec /bin/3proxy /etc/3proxy/3proxy.cfg
