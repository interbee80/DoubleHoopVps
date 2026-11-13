cat > /usr/local/sbin/a-ip-change.sh <<'SCRIPT'
#!/bin/bash
# Обновление настроек на сервере A при смене IP.
#
#   a-ip-change.sh b <НОВЫЙ_IP_B> [порт]   — сменился публичный IP выхода B (порт по умолчанию 8443)
#   a-ip-change.sh a <НОВЫЙ_IP_A>          — сменился публичный IP этого сервера A
#   a-ip-change.sh --check                 — показать текущие привязки
#
# Делает: правку живого интерфейса, правку конфигов на диске, обновление
# переменных в скриптах и проверку, что туннель поднялся.

set -u

CONF=/etc/amnezia/amneziawg/awg0.conf
IFACE=awg0
TUN=10.10.10.1
DIAG_SCRIPTS="/usr/local/sbin/diag-a.sh /usr/local/sbin/diag-awg1.sh"
VAR_SCRIPTS="/usr/local/sbin/up-all-a.sh /usr/local/sbin/amnezia-add.sh /usr/local/sbin/diag-a.sh /usr/local/sbin/diag-awg1.sh"
CLIENT_CONF_DIR=/root/awg-clients

ok(){  printf '  [OK]   %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; }
inf(){ printf '  [--]   %s\n' "$1"; }
hdr(){ printf '\n=== %s\n' "$1"; }

valid_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

set_var(){  # файл переменная значение
  local f=$1 v=$2 val=$3
  [ -f "$f" ] || return 0
  if grep -qE "^[[:space:]]*${v}=" "$f"; then
    sed -i -E "s|^[[:space:]]*${v}=.*|${v}=${val}|" "$f" && inf "$v -> $val в $(basename "$f")"
  fi
}

show_state(){
  hdr "Текущие привязки"
  inf "публичный IP этого сервера: $(curl -4 -s --max-time 5 https://ifconfig.me/ip 2>/dev/null || echo '?')"
  inf "интерфейс $IFACE: $(awg show $IFACE 2>/dev/null | sed -n 's/.*endpoint: *//p' | head -1 || echo 'не поднят')"
  inf "endpoint в $CONF: $(grep -iE '^[[:space:]]*Endpoint' "$CONF" 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//' || echo 'не найден')"
  inf "пиров на $IFACE: $(awg show $IFACE peers 2>/dev/null | wc -l)"
  for f in $VAR_SCRIPTS; do
    [ -f "$f" ] || continue
    grep -HE "^[[:space:]]*(A_PUB|B_PUB)=" "$f" 2>/dev/null | sed 's/^/  /'
  done
}

case "${1:-}" in
  --check|"") show_state; exit 0 ;;
  a|b) MODE=$1 ;;
  *) echo "использование: $0 {a|b} <НОВЫЙ_IP> [порт]   |   $0 --check"; exit 1 ;;
esac

NEW="${2:-}"
PORT="${3:-8443}"
valid_ip "$NEW" || { bad "некорректный IP: '$NEW'"; exit 1; }
[ -f "$CONF" ] || { bad "не найден $CONF"; exit 1; }

# ============ СМЕНА IP ВЫХОДА B ============
if [ "$MODE" = "b" ]; then
  echo "############ Смена IP выхода B на $NEW:$PORT"

  PEER=$(awg show $IFACE peers 2>/dev/null | head -1)
  [ -n "$PEER" ] || PEER=$(awk '/^\[Peer\]/{f=1} f&&/PublicKey/{print $3; exit}' "$CONF")
  [ -n "$PEER" ] || { bad "не найден публичный ключ пира B"; exit 1; }
  inf "ключ пира B: ${PEER:0:20}…"

  cp -a "$CONF" "$CONF.bak.$(date +%F-%H%M%S)" && ok "бэкап конфига сделан"

  hdr "1. Живой интерфейс"
  awg set $IFACE peer "$PEER" endpoint "$NEW:$PORT" && ok "endpoint применён на $IFACE"

  hdr "2. Конфиг на диске"
  if grep -qiE '^[[:space:]]*Endpoint' "$CONF"; then
    sed -i -E "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $NEW:$PORT|" "$CONF"
    ok "Endpoint в $CONF обновлён"
  else
    bad "в конфиге нет строки Endpoint — проверь $CONF вручную"
  fi

  hdr "3. Переменные в скриптах"
  for f in $DIAG_SCRIPTS; do set_var "$f" B_PUB "$NEW"; done

  hdr "4. Проверка туннеля"
  ping -c3 -W2 "$TUN" >/dev/null 2>&1 && ok "пинг до B ($TUN) проходит" || bad "пинг до B не проходит"
  sleep 2
  if awg show $IFACE 2>/dev/null | grep -q 'latest handshake'; then
    ok "handshake с B есть"
    awg show $IFACE | sed -n '/peer/,$p' | grep -E 'endpoint|handshake|transfer' | sed 's/^/  /'
  else
    bad "handshake не появился — проверь IP/порт и ufw на B"
  fi

  hdr "5. Цепочка до telemt"
  timeout 5 bash -c "</dev/tcp/$TUN/443" 2>/dev/null && ok "telemt доступен по $TUN:443" || bad "telemt недоступен"
  MT=$(curl -sS --max-time 8 --resolve petrovich.ru:443:213.165.61.113 https://petrovich.ru/ -o /dev/null 2>&1 | grep -ci petrovich)
  [ "${MT:-0}" -gt 0 ] && ok "MTProto-цепочка отвечает" || bad "MTProto-цепочка не отвечает"

  hdr "6. Выход VPN через B"
  V=$(curl -4 -s --max-time 10 --interface 10.20.20.1 https://ifconfig.me/ip)
  [ "$V" = "$NEW" ] && ok "VPN-подсеть выходит через B ($V)" || inf "выход VPN: ${V:-пусто} (устройства могут работать — проверь с телефона)"

  printf '\n############ готово. Не забудь: на B ufw-правило 8443/udp должно разрешать IP этого сервера.\n'
  exit 0
fi

# ============ СМЕНА СОБСТВЕННОГО IP A ============
echo "############ Смена публичного IP сервера A на $NEW"

hdr "1. Переменные в скриптах"
for f in $VAR_SCRIPTS; do set_var "$f" A_PUB "$NEW"; done

hdr "2. Клиентские конфиги в $CLIENT_CONF_DIR"
if [ -d "$CLIENT_CONF_DIR" ]; then
  n=0
  for f in "$CLIENT_CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    sed -i -E "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $NEW:8443|" "$f" && n=$((n+1))
  done
  ok "обновлено файлов: $n"
  inf "устройствам нужно заново импортировать конфиги (старые ссылаются на прежний адрес)"
else
  inf "каталог клиентских конфигов не найден"
fi

hdr "3. Что нужно сделать НА СЕРВЕРЕ B"
cat <<EOF
  # разрешить туннель с нового адреса A
  ufw allow from $NEW to any port 8443 proto udp
  # убрать старое правило (подставь прежний адрес A)
  ufw status | grep 8443

  # обновить публичный адрес в ссылках telemt
  sed -i 's|^[[:space:]]*public_host[[:space:]]*=.*|public_host = "$NEW"|' /etc/telemt/telemt.toml
  systemctl restart telemt
EOF

hdr "4. Что нужно сделать НА КЛИЕНТАХ"
cat <<EOF
  - в Telegram заменить прокси на новый адрес $NEW (или вставить новую ссылку от telemt)
  - в приложении Amnezia переимпортировать конфиг устройства
  - в браузере, где прописан SOCKS5, поменять адрес на $NEW
EOF

printf '\n############ готово. Проверить можно только снаружи — с клиента.\n'
SCRIPT

chmod +x /usr/local/sbin/a-ip-change.sh