cat > /usr/local/sbin/up-all-a.sh <<'SCRIPT'
#!/bin/bash
# Поднимает весь входной стек на сервере A:
#   MTProto  — haproxy :443/tcp   -> туннель -> telemt на B
#   Amnezia  — awg1 :8443/udp     -> выход через B
#   SOCKS5   — haproxy :8440/tcp  -> SOCKS5 на B
# Плюс открывает 22 (SSH) и все служебные порты. Идемпотентен.

set -u

# ================= НАСТРОЙКИ =================
CLIENT_IPS="46.32.81.173 46.32.85.48"   # кому разрешён SOCKS5
MT_PORT=443          # MTProto   (TCP)
AWG_PORT=8443        # Amnezia   (UDP)
SOCKS_PORT=8440      # SOCKS5    (TCP)
HAPROXY_DIR=/opt/docker-compose/haproxy
A_PUB=213.165.61.113
B_TUN=10.10.10.1
PEER_B=44jESMOHAx4m6iOx1Bhl5dDzqTZisqWeXmH5Zn8uQVM=

SOCKS_USER=socksuser
SOCKS_PASS=""        # впиши пароль — тогда скрипт проверит SOCKS5 целиком
# =============================================

ok(){ printf '  [OK]   %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; }
inf(){ printf '  [--]   %s\n' "$1"; }
hdr(){ printf '\n=== %s\n' "$1"; }

echo "############ A: подъём стека $(date -Is)"

# ---------- 1. Модуль AmneziaWG ----------
hdr "1. Модуль amneziawg"
if modinfo amneziawg >/dev/null 2>&1 || modprobe amneziawg 2>/dev/null; then
  ok "модуль доступен для ядра $(uname -r)"
else
  bad "модуль НЕТ для ядра $(uname -r) — интерфейсы не поднять"
  inf "лечится: dkms autoinstall -k \$(uname -r)  (см. инструкцию по compat.h)"
fi
printf 'amneziawg\n' > /etc/modules-load.d/amneziawg.conf 2>/dev/null && inf "автозагрузка модуля прописана"

# ---------- 2. Интерфейсы ----------
hdr "2. Интерфейсы туннелей"
for i in awg0 awg1; do
  if ip link show "$i" >/dev/null 2>&1; then
    ok "$i уже поднят"
  else
    inf "$i отсутствует — поднимаю"
    awg-quick up "$i" >/dev/null 2>&1 && ok "$i поднят" || bad "$i не поднялся"
  fi
done

# ---------- 3. Маршрутизация VPN-подсети ----------
hdr "3. Маршрутизация VPN через B"
if [ -x /usr/local/sbin/vpn-exit-up.sh ]; then
  bash /usr/local/sbin/vpn-exit-up.sh >/dev/null 2>&1 && ok "vpn-exit-up.sh применён" || bad "vpn-exit-up.sh завершился с ошибкой"
else
  inf "vpn-exit-up.sh не найден — применяю минимум вручную"
  awg set awg0 peer "$PEER_B" allowed-ips ${B_TUN}/32,0.0.0.0/0 2>/dev/null
  ip rule add from 10.20.20.0/24 lookup 100 2>/dev/null
  ip route replace default dev awg0 table 100 2>/dev/null
  iptables -t nat -C POSTROUTING -s 10.20.20.0/24 -o awg0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.20.20.0/24 -o awg0 -j MASQUERADE
fi
systemctl restart vpn-exit.service >/dev/null 2>&1 && ok "vpn-exit.service перезапущен" || inf "vpn-exit.service не установлен"

# ---------- 4. Docker и haproxy (MTProto + SOCKS5) ----------
hdr "4. Docker и haproxy"
systemctl is-active --quiet docker || systemctl start docker
systemctl is-active --quiet docker && ok "docker активен" || bad "docker не запустился"
systemctl enable docker >/dev/null 2>&1

if [ -d "$HAPROXY_DIR" ]; then
  ( cd "$HAPROXY_DIR" && docker compose up -d >/dev/null 2>&1 ) \
    && ok "haproxy запущен/актуален" || bad "ошибка запуска haproxy"
  docker run --rm -v "$HAPROXY_DIR/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    haproxy:latest haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1 \
    && ok "конфиг haproxy валиден" || bad "конфиг haproxy содержит ошибки"
else
  bad "каталог $HAPROXY_DIR не найден"
fi

# ---------- 5. Порты в ufw ----------
hdr "5. Фаервол (ufw)"
ufw allow 22/tcp >/dev/null 2>&1 && ok "22/tcp (SSH) открыт"
ufw allow ${MT_PORT}/tcp >/dev/null 2>&1 && ok "${MT_PORT}/tcp (MTProto) открыт"
ufw allow ${AWG_PORT}/udp >/dev/null 2>&1 && ok "${AWG_PORT}/udp (Amnezia) открыт"
for ip in $CLIENT_IPS; do
  ufw allow from "$ip" to any port ${SOCKS_PORT} proto tcp >/dev/null 2>&1 \
    && ok "${SOCKS_PORT}/tcp (SOCKS5) разрешён для $ip"
done
# гигиена: широкие правила, от которых мы ушли
if ufw status | grep -q "^1080/tcp.*Anywhere"; then
  ufw delete allow 1080/tcp >/dev/null 2>&1 && inf "убрано широкое правило 1080/tcp"
fi
if ufw status | grep -qE "^${AWG_PORT}/tcp.*Anywhere"; then
  inf "внимание: ${AWG_PORT}/tcp открыт всем — для туннеля нужен только UDP"
fi
ufw status | grep -E "22/tcp|${MT_PORT}/tcp|${AWG_PORT}/udp|${SOCKS_PORT}/tcp" | sed 's/^/  /'

# ---------- 6. Проверка портов ----------
hdr "6. Проверка трёх портов"
ss -tlnp 2>/dev/null | grep -q ":${MT_PORT} "  && ok "TCP ${MT_PORT} слушается (MTProto)"  || bad "TCP ${MT_PORT} НЕ слушается"
ss -ulnp 2>/dev/null | grep -q ":${AWG_PORT} " && ok "UDP ${AWG_PORT} слушается (Amnezia)"  || bad "UDP ${AWG_PORT} НЕ слушается"
ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} " && ok "TCP ${SOCKS_PORT} слушается (SOCKS5)" || bad "TCP ${SOCKS_PORT} НЕ слушается"

# ---------- 7. Функциональные тесты ----------
hdr "7. Функциональные тесты"
MT=$(curl -sS -v --max-time 8 --resolve petrovich.ru:443:${A_PUB} https://petrovich.ru/ -o /dev/null 2>&1 | grep -ci petrovich)
[ "${MT:-0}" -gt 0 ] && ok "MTProto-цепочка A -> B отвечает" || bad "MTProto-цепочка не отвечает"

if [ -n "$SOCKS_PASS" ]; then
  S=$(curl -s --max-time 10 -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" https://ifconfig.me/ip)
  [ -n "$S" ] && ok "SOCKS5 отвечает, выход: $S" || bad "SOCKS5 не ответил"
else
  inf "SOCKS5 не тестируется: не задан SOCKS_PASS"
fi

awg show awg1 2>/dev/null | grep -q 'latest handshake' && ok "Amnezia: есть handshake с устройством" || inf "Amnezia: активных handshake нет"
awg show awg0 2>/dev/null | grep -q 'latest handshake' && ok "туннель до B живой" || bad "туннель до B без handshake"

printf '\n############ A: готово\n'
SCRIPT

chmod +x /usr/local/sbin/up-all-a.sh