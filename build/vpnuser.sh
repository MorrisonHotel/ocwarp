#!/usr/bin/env bash
# vpnuser: один логин/пароль для VPN (ocserv) и прокси (3proxy).
# ocserv читает ocpasswd при каждом входе; 3proxy перечитывает users.cfg
# (строки "users логин:CL:пароль") в течение 60 с. Перезапуск не нужен.
set -Eeuo pipefail
export LC_ALL=C

readonly OCPASSWD=/etc/ocserv/ocpasswd
readonly PROXY_USERS=/proxy/users.cfg
readonly PROXY_UID=65535
readonly LOCK=/etc/ocserv/.vpnuser.lock

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Использование:
  vpnuser add <логин> [пароль]      создать (без пароля — сгенерировать)
  vpnuser passwd <логин> [пароль]   сменить пароль
  vpnuser del <логин>               удалить и разорвать VPN-сессии
  vpnuser list                      список пользователей
EOF
  exit 1
}

check_login() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]] \
    || die "логин: латиница, цифры и . _ - (до 32 символов)"
}

# Двоеточие — разделитель в обоих файлах, пробел — разделитель в 3proxy.cfg
check_pass() {
  (( ${#1} >= 2 )) || die "пароль короче 2 символов"
  [[ "$1" =~ ^[!-~]+$ && "$1" != *:* ]] \
    || die "пароль: печатные ASCII-символы без пробелов и двоеточия"
}

gen_pass() {
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20
}

has_vpn_user()   { awk -F: -v u="$1" '$1 == u { f = 1 } END { exit !f }' "$OCPASSWD"; }
has_proxy_user() { awk -v u="$1" '$1 == "users" && index($2, u ":") == 1 { f = 1 } END { exit !f }' "$PROXY_USERS"; }
has_user()       { has_vpn_user "$1" || has_proxy_user "$1"; }

# proxy_write LOGIN [PASSWORD]: убрать LOGIN из users.cfg и, если задан пароль,
# добавить заново. Файл подменяется атомарно.
proxy_write() {
  local tmp
  tmp="$(mktemp "${PROXY_USERS}.XXXXXX")"
  awk -v u="$1" '!($1 == "users" && index($2, u ":") == 1)' "$PROXY_USERS" > "$tmp"
  [[ $# -lt 2 ]] || printf 'users %s:CL:%s\n' "$1" "$2" >> "$tmp"
  chown "$PROXY_UID:$PROXY_UID" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROXY_USERS"
}

set_password() {
  printf '%s\n' "$2" | ocpasswd -c "$OCPASSWD" "$1" > /dev/null
  chmod 600 "$OCPASSWD"
  proxy_write "$1" "$2"
}

show_credentials() {
  cat <<EOF
Готово: $1
  Логин:   $1
  Пароль:  $2
  VPN:     <сервер>:${VPN_PUBLIC_PORT:-443}
  SOCKS5:  socks5://$1:$2@<сервер>:${SOCKS_PUBLIC_PORT:-1080}
  HTTP:    http://$1:$2@<сервер>:${HTTP_PUBLIC_PORT:-3128}
Пароль показан один раз и нигде не логируется. Прокси применит изменения в течение минуты.
EOF
}

cmd_add() {
  local login="$1" pass="${2:-}"
  check_login "$login"
  ! has_user "$login" || die "пользователь $login уже есть (смена пароля: vpnuser passwd $login)"
  [[ -n "$pass" ]] || pass="$(gen_pass)"
  check_pass "$pass"
  set_password "$login" "$pass"
  show_credentials "$login" "$pass"
}

cmd_passwd() {
  local login="$1" pass="${2:-}"
  check_login "$login"
  has_user "$login" || die "пользователя $login нет (создать: vpnuser add $login)"
  [[ -n "$pass" ]] || pass="$(gen_pass)"
  check_pass "$pass"
  set_password "$login" "$pass"
  show_credentials "$login" "$pass"
}

cmd_del() {
  local login="$1"
  check_login "$login"
  has_user "$login" || die "пользователя $login нет"
  ! has_vpn_user "$login" || ocpasswd -c "$OCPASSWD" -d "$login"
  chmod 600 "$OCPASSWD"
  proxy_write "$login"
  occtl disconnect user "$login" > /dev/null 2>&1 || true
  printf 'Удалён: %s. VPN-сессии разорваны, прокси закроет доступ в течение минуты.\n' "$login"
}

cmd_list() {
  local login
  printf '%-32s %-4s %s\n' LOGIN VPN PROXY
  { awk -F: 'NF { print $1 }' "$OCPASSWD"
    awk '$1 == "users" { split($2, a, ":"); print a[1] }' "$PROXY_USERS"; } \
    | sort -u \
    | while read -r login; do
        printf '%-32s %-4s %s\n' "$login" \
          "$(has_vpn_user "$login" && echo yes || echo -)" \
          "$(has_proxy_user "$login" && echo yes || echo -)"
      done
}

(( $# >= 1 )) || usage

touch "$OCPASSWD" "$PROXY_USERS"
chmod 600 "$OCPASSWD"
exec 9> "$LOCK"
flock -w 30 9 || die "vpnuser уже запущен в другом терминале"

case "$1" in
  add)    (( $# == 2 || $# == 3 )) || usage; cmd_add "$2" "${3:-}" ;;
  passwd) (( $# == 2 || $# == 3 )) || usage; cmd_passwd "$2" "${3:-}" ;;
  del)    (( $# == 2 )) || usage; cmd_del "$2" ;;
  list)   (( $# == 1 )) || usage; cmd_list ;;
  *)      usage ;;
esac
