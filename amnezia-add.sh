cat > /usr/local/sbin/amnezia-add.sh <<'SCRIPT'
#!/bin/bash
# Добавление устройства в AmneziaWG (awg1) + генерация клиентского конфига.
#
#   amnezia-add.sh <имя>                    — свободный IP подберётся сам
#   amnezia-add.sh <имя> <октет>            — задать IP вручную (17 -> 10.20.20.17)
#   amnezia-add.sh --list                   — список устройств
#   amnezia-add.sh --delete <имя>           — удалить устройство
#   amnezia-add.sh --delete <имя> --purge   — удалить вместе с файлами ключей
#
#   --no-qr    не рисовать QR
#   --force    перезаписать, если имя уже занято

set -u

CONF=/etc/amnezia/amneziawg/awg1.conf
IFACE=awg1
KEYDIR=/root/awg-clients
PREFIX=10.20.20
A_PUB=213.165.61.113
PORT=8443
DNS=1.1.1.1
MTU=1280

ok(){  printf '  [OK]   %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; }
inf(){ printf '  [--]   %s\n' "$1"; }

usage(){ sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---- чтение параметров обфускации прямо из конфига сервера ----
cfgval(){ grep -iE "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '"'; }

# ---- занятые адреса ----
used_octets(){
  { awg show "$IFACE" allowed-ips 2>/dev/null | awk '{print $2}'
    grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$CONF" 2>/dev/null | sed 's/.*=[[:space:]]*//'
  } | tr ',' '\n' | tr -d ' ' | sed -n "s|^${PREFIX}\.\([0-9]\+\)/32$|\1|p" | sort -n | uniq
}

free_octet(){
  local used; used=$(used_octets)
  for i in $(seq 2 254); do
    echo "$used" | grep -qx "$i" || { echo "$i"; return 0; }
  done
  return 1
}

pub_for_name(){
  awk -v name="$1" '
    /^[[:space:]]*\[Peer\]/ { c=0 }
    /^[[:space:]]*#/ { l=$0; sub(/^[[:space:]]*#[[:space:]]*/,"",l); if (l==name) c=1 }
    /^[[:space:]]*PublicKey/ { if (c) { print $3; exit } }
  ' "$CONF"
}

remove_block(){
  awk -v name="$1" '
    function flush(){ if (inp && !drop) printf "%s", buf; buf=""; inp=0; drop=0 }
    /^[[:space:]]*\[Peer\]/ { flush(); inp=1; buf=$0 "\n"; drop=0; next }
    inp { buf = buf $0 "\n"; l=$0; sub(/^[[:space:]]*#[[:space:]]*/,"",l)
          if ($0 ~ /^[[:space:]]*#/ && l==name) drop=1; next }
    { print }
    END { flush() }
  ' "$CONF"
}

# ================= разбор аргументов =================
QR=1; FORCE=0; DELETE=0; PURGE=0; NAME=""; OCTET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-qr) QR=0 ;;
    --force) FORCE=1 ;;
    --purge) PURGE=1 ;;
    --delete) DELETE=1 ;;
    --list) echo "Устройства в $CONF:"; awk '/^[[:space:]]*#/ {l=$0; sub(/^[[:space:]]*#[[:space:]]*/,"",l); print "  " l}' "$CONF"; exit 0 ;;
    -h|--help) usage ;;
    *) if [ -z "$NAME" ]; then NAME="$1"
       elif [ -z "$OCTET" ]; then OCTET="$1"
       else usage; fi ;;
  esac
  shift
done
[ -n "$NAME" ] || usage

case "$NAME" in *[!A-Za-z0-9_.-]*) bad "в имени допустимы только буквы, цифры, _ . -"; exit 1 ;; esac

[ -f "$CONF" ] || { bad "не найден $CONF"; exit 1; }
ip link show "$IFACE" >/dev/null 2>&1 || { bad "интерфейс $IFACE не поднят"; exit 1; }
mkdir -p "$KEYDIR"

# ================= удаление =================
if [ "$DELETE" = "1" ]; then
  PUB=$(pub_for_name "$NAME")
  if [ -z "$PUB" ]; then bad "устройство '$NAME' не найдено в конфиге"; exit 1; fi
  cp -a "$CONF" "$CONF.bak.$(date +%F-%H%M%S)"
  awg set "$IFACE" peer "$PUB" remove 2>/dev/null && ok "пир удалён с $IFACE"
  remove_block "$NAME" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  ok "блок '$NAME' убран из конфига"
  if [ "$PURGE" = "1" ]; then
    rm -f "$KEYDIR/$NAME.key" "$KEYDIR/$NAME.pub" "$KEYDIR/$NAME.conf"
    ok "файлы ключей и конфиг удалены"
  else
    inf "файлы ключей оставлены: $KEYDIR/$NAME.*"
  fi
  printf '\nпиров осталось: %s\n' "$(awg show "$IFACE" peers 2>/dev/null | wc -l)"
  exit 0
fi

# ================= добавление =================
if [ -n "$(pub_for_name "$NAME")" ] && [ "$FORCE" != "1" ]; then
  bad "устройство '$NAME' уже есть в конфиге (используй --force или --delete)"
  exit 1
fi

if [ -n "$OCTET" ]; then
  case "$OCTET" in *[!0-9]*) bad "октет должен быть числом"; exit 1 ;; esac
  [ "$OCTET" -ge 2 ] && [ "$OCTET" -le 254 ] || { bad "октет вне диапазона 2..254"; exit 1; }
  if used_octets | grep -qx "$OCTET"; then bad "адрес $PREFIX.$OCTET уже занят"; exit 1; fi
else
  OCTET=$(free_octet) || { bad "свободных адресов в $PREFIX.0/24 нет"; exit 1; }
  inf "свободный адрес: $PREFIX.$OCTET"
fi

# ---- ключи ----
awg genkey > "$KEYDIR/$NAME.key"
awg pubkey < "$KEYDIR/$NAME.key" > "$KEYDIR/$NAME.pub"
chmod 600 "$KEYDIR/$NAME.key"
CLIENT_PUB=$(cat "$KEYDIR/$NAME.pub")
ok "ключи созданы: $KEYDIR/$NAME.key / .pub"

# ---- пир в конфиг + на живой интерфейс ----
cp -a "$CONF" "$CONF.bak.$(date +%F-%H%M%S)"
if [ "$FORCE" = "1" ] && [ -n "$(pub_for_name "$NAME")" ]; then
  OLD=$(pub_for_name "$NAME"); awg set "$IFACE" peer "$OLD" remove 2>/dev/null
  remove_block "$NAME" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  inf "старая запись '$NAME' заменена"
fi

cat >> "$CONF" <<EOF

[Peer]
# $NAME
PublicKey = $CLIENT_PUB
AllowedIPs = $PREFIX.$OCTET/32
EOF
ok "пир добавлен в $CONF"

awg set "$IFACE" peer "$CLIENT_PUB" allowed-ips "$PREFIX.$OCTET/32" \
  && ok "пир применён на живом интерфейсе (без разрыва сессий)"

if awg show "$IFACE" peers 2>/dev/null | grep -qx "$CLIENT_PUB"; then
  ok "проверка: пир присутствует на $IFACE"
else
  bad "пир НЕ появился на интерфейсе — проверь вручную"
fi

# ---- клиентский конфиг ----
SRV_PUB=$(awg show "$IFACE" public-key 2>/dev/null)
[ -n "$SRV_PUB" ] || SRV_PUB=$(cat /root/awg-vpn.pub 2>/dev/null)
[ -n "$SRV_PUB" ] || { bad "не удалось получить публичный ключ сервера"; exit 1; }

cat > "$KEYDIR/$NAME.conf" <<EOF
[Interface]
# VPN Туннель
PrivateKey = $(cat "$KEYDIR/$NAME.key")
Address = $PREFIX.$OCTET/32
DNS = $DNS
MTU = $MTU
Jc = $(cfgval Jc)
Jmin = $(cfgval Jmin)
Jmax = $(cfgval Jmax)
S1 = $(cfgval S1)
S2 = $(cfgval S2)
S3 = $(cfgval S3)
S4 = $(cfgval S4)
H1 = $(cfgval H1)
H2 = $(cfgval H2)
H3 = $(cfgval H3)
H4 = $(cfgval H4)

[Peer]
PublicKey = $SRV_PUB
Endpoint = $A_PUB:$PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$KEYDIR/$NAME.conf"
ok "клиентский конфиг: $KEYDIR/$NAME.conf"

printf '\n'
inf "устройство:  $NAME"
inf "адрес:       $PREFIX.$OCTET/32"
inf "endpoint:    $A_PUB:$PORT"
inf "всего пиров: $(awg show "$IFACE" peers 2>/dev/null | wc -l)"

if [ "$QR" = "1" ]; then
  if command -v qrencode >/dev/null 2>&1; then
    printf '\n'
    qrencode -t ansiutf8 < "$KEYDIR/$NAME.conf"
  else
    inf "qrencode не установлен — QR пропущен (apt install qrencode)"
  fi
fi
SCRIPT

chmod +x /usr/local/sbin/amnezia-add.sh