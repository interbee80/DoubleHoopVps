cat > /usr/local/sbin/up-all-b.sh <<'SCRIPT'
#!/bin/bash
# Поднимает выходной стек на сервере B:
#   telemt  — MTProto на 10.10.10.1:443
#   SOCKS5  — на 10.10.10.1:1080
#   awg0    — туннель до A + форвард и NAT для VPN
# Плюс открывает 22 и служебные порты. Идемпотентен.

set -u

# ================= НАСТРОЙКИ =================
A_PUB=213.165.61.113     # публичный IP A
A_TUN=10.10.10.2         # адрес A на туннеле
B_TUN=10.10.10.1         # свой адрес на туннеле
VPN_SUBNET=10.10.10.0/24 # что выпускаем в интернет
MT_PORT=443
SOCKS_PORT=1080
TELEMT_SERVICE=telemt
SOCKS_SERVICE=socks5     # или 3proxy — подставь своё имя юнита
SSH_OPEN_ANYWHERE=yes    # yes = 22 открыт всем; no = только для A
# =============================================

ok(){ printf '  [OK]   %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; }
inf(){ printf '  [--]   %s\n' "$1"; }
hdr(){ printf '\n=== %s\n' "$1"; }

echo "############ B: подъём стека $(date -Is)"

# ---------- 1. Модуль и туннель ----------
hdr "1. Модуль amneziawg и туннель"
if modinfo amneziawg >/dev/null 2>&1 || modprobe amneziawg 2>/dev/null; then
  ok "модуль доступен для ядра $(uname -r)"
else
  bad "модуль НЕТ для ядра $(uname -r) — awg0 не поднять"
fi
printf 'amneziawg\n' > /etc/modules-load.d/amneziawg.conf 2>/dev/null

if ip link show awg0 >/dev/null 2>&1; then
  ok "awg0 уже поднят"
else
  awg-quick up awg0 >/dev/null 2>&1 && ok "awg0 поднят" || bad "awg0 не поднялся"
fi

# ---------- 2. telemt (MTProto) ----------
hdr "2. telemt (MTProto)"
systemctl enable "$TELEMT_SERVICE" >/dev/null 2>&1
systemctl is-active --quiet "$TELEMT_SERVICE" || systemctl start "$TELEMT_SERVICE"
systemctl is-active --quiet "$TELEMT_SERVICE" && ok "telemt запущен" || bad "telemt не запустился"

# ---------- 3. SOCKS5 ----------
hdr "3. SOCKS5"
systemctl enable "$SOCKS_SERVICE" >/dev/null 2>&1
systemctl is-active --quiet "$SOCKS_SERVICE" || systemctl start "$SOCKS_SERVICE"
systemctl is-active --quiet "$SOCKS_SERVICE" && ok "$SOCKS_SERVICE запущен" || bad "$SOCKS_SERVICE не запустился"

# ---------- 4. Форвард и NAT для VPN ----------
hdr "4. Форвард и NAT"
sysctl -qw net.ipv4.ip_forward=1
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-forward.conf
[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] && ok "ip_forward = 1" || bad "ip_forward не включён"

ufw route allow in on awg0 out on eth0 from "$VPN_SUBNET" >/dev/null 2>&1 && inf "ufw route для $VPN_SUBNET"

iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o eth0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o eth0 -j MASQUERADE
iptables -t nat -S POSTROUTING | grep -q "$VPN_SUBNET.*MASQUERADE" \
  && ok "MASQUERADE для $VPN_SUBNET на месте" || bad "MASQUERADE отсутствует"

if grep -q 'MASQUERADE' /etc/ufw/before.rules 2>/dev/null; then
  ok "NAT закреплён в before.rules (переживёт ребут)"
else
  bad "NAT НЕ закреплён — после ребута VPN-выход отвалится"
fi

# ---------- 5. Порты в ufw ----------
hdr "5. Фаервол (ufw)"
if [ "$SSH_OPEN_ANYWHERE" = "yes" ]; then
  ufw allow 22/tcp >/dev/null 2>&1 && ok "22/tcp (SSH) открыт всем"
else
  ufw allow from "$A_PUB" to any port 22 proto tcp >/dev/null 2>&1 && ok "22/tcp (SSH) только для A"
fi
ufw allow from "$A_PUB" to any port 8443 proto udp >/dev/null 2>&1 && ok "8443/udp разрешён для A (туннель)"
ufw allow from "$A_TUN" to any port ${MT_PORT} proto tcp >/dev/null 2>&1 && ok "${MT_PORT}/tcp разрешён для A (telemt)"
ufw allow from "$A_TUN" to any port ${SOCKS_PORT} proto tcp >/dev/null 2>&1 && ok "${SOCKS_PORT}/tcp разрешён для A (SOCKS5)"
ufw status | grep -E "22|8443|${MT_PORT}|${SOCKS_PORT}" | sed 's/^/  /'

# ---------- 6. Проверка портов ----------
hdr "6. Проверка портов и туннеля"
ss -tlnp 2>/dev/null | grep -q "${B_TUN}:${MT_PORT} "    && ok "telemt слушает ${B_TUN}:${MT_PORT}"        || bad "telemt не слушает ${B_TUN}:${MT_PORT}"
ss -tlnp 2>/dev/null | grep -q "${B_TUN}:${SOCKS_PORT} " && ok "SOCKS5 слушает ${B_TUN}:${SOCKS_PORT}"     || bad "SOCKS5 не слушает ${B_TUN}:${SOCKS_PORT}"
ss -ulnp 2>/dev/null | grep -q ":8443 "                  && ok "UDP 8443 слушается (туннель)"             || bad "UDP 8443 не слушается"
awg show awg0 2>/dev/null | grep -q 'latest handshake'   && ok "handshake с A есть"                        || bad "нет handshake с A"

# ---------- 7. Функциональные тесты ----------
hdr "7. Тесты"
OUT=$(curl -4 -s --max-time 6 https://ifconfig.me/ip)
[ -n "$OUT" ] && ok "выход B в интернет: $OUT" || bad "B не выходит в интернет"
NATP=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null | awk '/10\.10\.10\.0\/24/ {print $1; exit}')
inf "через NAT прошло пакетов: ${NATP:-0}"

printf '\n############ B: готово\n'
SCRIPT

chmod +x /usr/local/sbin/up-all-b.sh