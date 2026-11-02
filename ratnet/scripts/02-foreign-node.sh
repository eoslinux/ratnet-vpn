#!/usr/bin/env bash
# =============================================================================
#  02 — ИНОСТРАННАЯ НОДА (выход)
#  Готовит сервер как выходной узел: Xray с VLESS+REALITY, сетевой тюнинг
#  (BBR, буферы, MPTCP off), минимальный хардненинг, расписание ребутов.
#  Ничего существующего не удаляет: Amnezia, панели и прочее остаются как есть.
#
#  Запуск:  bash 02-foreign-node.sh
#  Переменные (необязательно):
#    NODE_TAG=proxy-fi3        имя выхода в конфиге РФ (по умолчанию auto)
#    NODE_SNI=www.icloud.com   домен-маскировка
#    NODE_PORT=443             порт входа Xray
#    NODE_TZ=Europe/Helsinki   часовой пояс ('' — не менять)
#    ADBLOCK=1                 включить блокировку рекламы по доменам
#    REBOOT_CRON=1             поставить ребут Пн/Ср/Пт 05:00 местного
# =============================================================================
set -uo pipefail

NODE_SNI="${NODE_SNI:-www.icloud.com}"
NODE_PORT="${NODE_PORT:-443}"
NODE_TZ="${NODE_TZ:-Europe/Helsinki}"
ADBLOCK="${ADBLOCK:-0}"
REBOOT_CRON="${REBOOT_CRON:-1}"
XRAY_VERSION="${XRAY_VERSION:-26.6.27}"

GEO_DIR=/usr/local/share/xray
CFG_DIR=/usr/local/etc/xray
CFG=$CFG_DIR/config.json

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die() { printf '\n\033[31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "запускать от root"

say "0. Окружение"
. /etc/os-release
echo "ОС: $PRETTY_NAME  ядро: $(uname -r)  CPU: $(nproc)"
[ -f "$CFG" ] && { echo "Внимание: Xray уже настроен, конфиг будет заменён"; cp "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"; }
if ss -lntp 2>/dev/null | grep -q ":${NODE_PORT} "; then
  echo "Порт ${NODE_PORT}/tcp уже занят:"
  ss -lntp | grep ":${NODE_PORT} "
  die "освободи порт или задай NODE_PORT"
fi

say "1. Пакеты и обновления"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq upgrade
apt-get -y -qq install curl jq openssl ca-certificates unzip ufw ethtool

say "2. Xray"
if [ -x /usr/local/bin/xray ]; then
  echo "уже установлен: $(/usr/local/bin/xray version | head -1)"
else
  TMP=$(mktemp -d)
  URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
  curl -fsSL --max-time 120 -o "$TMP/x.zip" "$URL" || die "не скачался Xray; положи бинарь в /usr/local/bin/xray"
  unzip -q "$TMP/x.zip" -d "$TMP"
  install -m 755 "$TMP/xray" /usr/local/bin/xray
  rm -rf "$TMP"
fi
mkdir -p "$CFG_DIR" "$GEO_DIR" /var/log/xray
id -u xray >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin xray

say "3. Домен-маскировка"
check_sni() {
  local d=$1 out
  out=$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null)
  echo "$out" | grep -q 'ALPN protocol: h2' || return 1
  echo "$out" | grep -q 'Verify return code: 0' || return 1
}
if check_sni "$NODE_SNI"; then
  echo "OK: $NODE_SNI"
else
  echo "ПРЕДУПРЕЖДЕНИЕ: $NODE_SNI не подходит"
  FOUND=""
  for alt in www.icloud.com www.samsung.com www.nvidia.com; do
    if check_sni "$alt"; then FOUND=$alt; break; fi
  done
  [ -n "$FOUND" ] || die "не нашёл рабочий домен, задай NODE_SNI вручную"
  NODE_SNI=$FOUND; echo "использую $NODE_SNI"
fi

say "4. Ключи и клиент для российского входа"
OUT=$(/usr/local/bin/xray x25519)
PRIV=$(echo "$OUT" | grep -i 'Private' | awk '{print $2}')
PUB=$(echo "$OUT"  | grep -iE 'Public|Password' | awk '{print $NF}')
SID=$(openssl rand -hex 8)
TRANSIT_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "pub=$PUB  sid=$SID"

say "5. Базы доменов (для блокировки рекламы)"
GEO_OK=0
if [ "$ADBLOCK" = "1" ]; then
  for f in geoip geosite; do
    [ -f "$GEO_DIR/$f.dat" ] || curl -fsSL --max-time 180 -o "$GEO_DIR/$f.dat" \
      "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f.dat" || true
  done
  [ -f "$GEO_DIR/geosite.dat" ] && GEO_OK=1
  chown -R xray:xray "$GEO_DIR" 2>/dev/null || true
fi

say "6. Конфиг выхода"
if [ "$ADBLOCK" = "1" ] && [ "$GEO_OK" = "1" ]; then
  ROUTING='{ "domainStrategy": "AsIs", "rules": [ { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" } ] }'
else
  ROUTING='null'
fi

jq -n --arg uuid "$TRANSIT_UUID" --arg priv "$PRIV" --arg sni "$NODE_SNI" --arg sid "$SID" \
      --argjson port "$NODE_PORT" --argjson routing "$ROUTING" \
'{
  log: { loglevel: "warning", access: "none", error: "/var/log/xray/error.log" },
  inbounds: [{
    tag: "vless-in", listen: "0.0.0.0", port: $port, protocol: "vless",
    settings: { clients: [ { id: $uuid, email: "ru-transit", flow: "xtls-rprx-vision" } ], decryption: "none" },
    streamSettings: {
      network: "tcp", security: "reality",
      realitySettings: { show: false, dest: ($sni + ":443"), xver: 0, serverNames: [$sni], privateKey: $priv, shortIds: [$sid] },
      sockopt: { tcpFastOpen: true, tcpCongestion: "bbr", tcpKeepAliveIdle: 60, tcpUserTimeout: 30000 }
    },
    sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
  }],
  outbounds: [
    { tag: "direct", protocol: "freedom" },
    { tag: "block", protocol: "blackhole" }
  ]
}
+ (if $routing == null then {} else { routing: $routing } end)' > "$CFG"

say "7. systemd"
cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=xray
Group=xray
Environment=GODEBUG=multipathtcp=0
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
UMask=0077
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNIT
chown xray:xray "$CFG"; chmod 644 "$CFG"
xray -test -config "$CFG" >/tmp/xr.log 2>&1 || { cat /tmp/xr.log; die "конфиг невалиден"; }
rm -f /var/log/xray/error.log; chown -R xray:xray /var/log/xray
systemctl daemon-reload
systemctl enable --now xray
sleep 2
systemctl is-active xray >/dev/null || die "Xray не стартовал"

say "8. Файрвол"
if ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow "${NODE_PORT}/tcp" >/dev/null 2>&1
  echo "правило для ${NODE_PORT}/tcp добавлено"
else
  echo "ufw неактивен — не включаю (чтобы не отрезать другие сервисы). Порт ${NODE_PORT} и так открыт."
fi

say "9. Сетевой тюнинг"
cat > /etc/sysctl.d/99-vpn-network.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
EOF
cat > /etc/sysctl.d/99-vpn-security.conf <<'EOF'
net.mptcp.enabled = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true
# в /etc/sysctl.conf может стоять свой syncookies — не даём ему перебить
sed -i 's/^net\.ipv4\.tcp_syncookies *= *0/net.ipv4.tcp_syncookies = 1/' /etc/sysctl.conf 2>/dev/null || true
sysctl -q --system 2>/dev/null || true
IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
echo "congestion=$(sysctl -n net.ipv4.tcp_congestion_control) mptcp=$(sysctl -n net.mptcp.enabled) iface=$IFACE"

say "10. Часовой пояс и ребуты"
if [ -n "$NODE_TZ" ]; then
  timedatectl set-timezone "$NODE_TZ" 2>/dev/null && echo "пояс: $(timedatectl | grep -m1 'Time zone' | sed 's/^ *//')"
fi
if [ "$REBOOT_CRON" = "1" ]; then
  ( crontab -l 2>/dev/null | grep -v '/sbin/reboot' | grep -v 'ПЛАНОВЫЙ РЕБУТ'
    echo '# ПЛАНОВЫЙ РЕБУТ: понедельник, среда, пятница в 05:00 по местному времени'
    echo '0 5 * * 1,3,5 /sbin/reboot'
  ) | crontab -
  echo "расписание: Пн/Ср/Пт 05:00 ($(cat /etc/timezone 2>/dev/null))"
fi

say "11. Проверка выхода"
LOCAL_IP=$(curl -4 -s --max-time 10 https://ipv4.icanhazip.com)
echo "внешний IP: $LOCAL_IP"

say "12. Данные для соединения с российской нодой"
TAG="${NODE_TAG:-proxy-$(echo "$LOCAL_IP" | awk -F. '{print $3}')}"
TOKEN=$(jq -nc --arg ip "$LOCAL_IP" --arg tag "$TAG" --arg sni "$NODE_SNI" \
             --arg sid "$SID" --arg pub "$PUB" --arg uuid "$TRANSIT_UUID" --argjson port "$NODE_PORT" \
             '{ip:$ip, port:$port, tag:$tag, sni:$sni, sid:$sid, pub:$pub, uuid:$uuid}' | base64 -w0)

cat > /root/foreign-node.env <<EOF
NODE_IP=$LOCAL_IP
NODE_PORT=$NODE_PORT
NODE_TAG=$TAG
NODE_SNI=$NODE_SNI
NODE_SID=$SID
NODE_PUB=$PUB
NODE_UUID=$TRANSIT_UUID
JOIN_TOKEN=$TOKEN
EOF
chmod 600 /root/foreign-node.env

cat <<EOF

Всё готово. Нода: $LOCAL_IP (тег $TAG, SNI $NODE_SNI, ADBLOCK=$ADBLOCK)

Скопируй ТОКЕН и выполни на российской ноде:

  bash 03-join-node.sh '$TOKEN'

Токен сохранён в /root/foreign-node.env на этой машине.
EOF
