#!/usr/bin/env bash
# =============================================================================
#  01 — РОССИЙСКИЙ ВХОДНОЙ УЗЕЛ
#  Всё, что должно жить только на российской ноде: вход для клиентов,
#  маршрутизация рунета напрямую, балансировщик выходов, учёт трафика,
#  квоты, журнал трафика, расписание ребутов, файрвол.
#
#  Запуск:  bash 01-ru-entry.sh
#
#  Выбор транспорта входа:
#    ENTRY_TRANSPORT=reality     (по умолчанию) VLESS + REALITY, TCP
#    ENTRY_TRANSPORT=tls         VLESS + TLS (самоподписанный серт), TCP
#    ENTRY_TRANSPORT=hysteria2   Hysteria2 (QUIC/UDP), через sing-box
#
#  Прочее:
#    ENTRY_PORT=443              порт входа
#    ENTRY_SNI=www.icloud.com    домен-маскировка (reality) / CN сертификата (tls, hysteria2)
#    ADBLOCK=1                   блокировать рекламу и трекеры по доменам
#    REBOOT_TIME="0 5 * * *"     когда проверять расписание (05:00 МСК)
#    REBOOT_INTERVAL_H=48        ребут не чаще, чем раз в N часов
#    DRY=1                       только собрать и проверить конфиг, ничего не ставить
#    FORCE=1                     перезаписать существующий конфиг
# =============================================================================
set -uo pipefail

ENTRY_TRANSPORT="${ENTRY_TRANSPORT:-reality}"
ENTRY_PORT="${ENTRY_PORT:-443}"
ENTRY_SNI="${ENTRY_SNI:-www.icloud.com}"
ADBLOCK="${ADBLOCK:-0}"
XRAY_VERSION="${XRAY_VERSION:-26.6.27}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.14.4}"
REBOOT_TIME="${REBOOT_TIME:-0 5 * * *}"
REBOOT_INTERVAL_H="${REBOOT_INTERVAL_H:-48}"
DRY="${DRY:-0}"

GEO_DIR=/usr/local/share/xray
CFG_DIR=/usr/local/etc/xray
CFG=$CFG_DIR/config.json
SB_DIR=/etc/sing-box
LOCAL_PORT=8443           # внутренний порт Xray для цепочки hysteria2
DNS_PORT=5353

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die() { printf '\n\033[31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }
note() { printf '   %s\n' "$*"; }

[ "$(id -u)" = "0" ] || die "запускать от root"
case "$ENTRY_TRANSPORT" in
  reality|tls|hysteria2) : ;;
  *) die "ENTRY_TRANSPORT должен быть: reality | tls | hysteria2 (получено: $ENTRY_TRANSPORT)" ;;
esac

say "0. Окружение"
. /etc/os-release
echo "ОС: $PRETTY_NAME   ядро: $(uname -r)"
echo "транспорт входа: $ENTRY_TRANSPORT   порт: $ENTRY_PORT   реклама: $([ "$ADBLOCK" = "1" ] && echo 'блокируется' || echo 'не блокируется')"

if [ -f "$CFG" ]; then
  BACKUP=$CFG.bak.$(date +%Y%m%d-%H%M%S)
  [ "$DRY" = "1" ] || cp "$CFG" "$BACKUP"
  echo "Найден существующий конфиг — сохранён в $BACKUP"
  [ "${FORCE:-0}" = "1" ] || [ "$DRY" = "1" ] || { echo "Запусти с FORCE=1, чтобы перезаписать"; exit 2; }
fi

mk_cert() {
  local dir=$1 cn=$2
  mkdir -p "$dir"
  [ -f "$dir/cert.pem" ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" -days 3650 -nodes \
    -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" >/dev/null 2>&1
  chmod 600 "$dir/key.pem" 2>/dev/null || true
  chmod 644 "$dir/cert.pem" 2>/dev/null || true
}

check_sni() {
  local d=$1 out
  out=$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null)
  echo "$out" | grep -q 'ALPN protocol: h2' || return 1
  echo "$out" | grep -q 'Verify return code: 0' || return 1
}

if [ "$DRY" = "0" ]; then
  say "1. Обновление системы и пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y -qq upgrade
  apt-get -y -qq install curl jq openssl ca-certificates unzip ufw qrencode

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

  if [ "$ENTRY_TRANSPORT" = "hysteria2" ]; then
    say "2б. sing-box (нужен для Hysteria2)"
    if [ -x /usr/local/bin/sing-box ]; then
      echo "уже установлен: $(/usr/local/bin/sing-box version | head -1)"
    else
      TMP=$(mktemp -d)
      URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
      curl -fsSL --max-time 180 -o "$TMP/sb.tgz" "$URL" || die "не скачался sing-box"
      tar xzf "$TMP/sb.tgz" -C "$TMP"
      install -m 755 "$TMP"/sing-box-*/sing-box /usr/local/bin/sing-box
      rm -rf "$TMP"
    fi
    mkdir -p "$SB_DIR"
    id -u singbox >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin singbox
  fi

  say "3. Базы доменов и IP"
  for f in geoip geosite; do
    [ -f "$GEO_DIR/$f.dat" ] || curl -fsSL --max-time 180 -o "$GEO_DIR/$f.dat" \
      "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f.dat" || true
  done
  GEO_OK=0; [ -f "$GEO_DIR/geoip.dat" ] && [ -f "$GEO_DIR/geosite.dat" ] && GEO_OK=1
  $GEO_OK && echo "базы на месте" || echo "ПРЕДУПРЕЖДЕНИЕ: базы не скачались, часть правил рунета и реклама работать не будут"
  chown -R xray:xray "$GEO_DIR" 2>/dev/null || true
else
  say "1-3. DRY-режим: пакеты и бинари не трогаем"
  GEO_OK=$([ -f "$GEO_DIR/geosite.dat" ] && echo 1 || echo 0)
fi

say "4. Домен и ключи"
if [ "$ENTRY_TRANSPORT" = "reality" ]; then
  if check_sni "$ENTRY_SNI"; then
    note "OK: $ENTRY_SNI (TLS 1.3 + h2, сертификат валиден)"
  else
    note "ПРЕДУПРЕЖДЕНИЕ: $ENTRY_SNI не прошёл проверку, беру резервный"
    for alt in www.icloud.com www.samsung.com www.nvidia.com; do
      if check_sni "$alt"; then ENTRY_SNI=$alt; note "использую $alt"; break; fi
    done
  fi
fi

OUT=$(xray x25519 2>/dev/null || /usr/local/bin/xray x25519)
PRIV=$(echo "$OUT" | grep -i 'Private' | awk '{print $2}')
PUB=$(echo "$OUT"  | grep -iE 'Public|Password' | awk '{print $NF}')
SID=$(openssl rand -hex 8)
UUID_OWNER=$(cat /proc/sys/kernel/random/uuid)
UUID_LOCAL=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -hex 20)
CERT_CN="entry.local"
[ "$ENTRY_TRANSPORT" != "reality" ] && CERT_CN="$ENTRY_SNI"
if [ "$ENTRY_TRANSPORT" != "reality" ]; then
  if [ "$DRY" = "1" ]; then CERT_DIR=/tmp/drycert; else CERT_DIR=$SB_DIR; fi
  mk_cert "$CERT_DIR" "$CERT_CN"
fi
if [ "$ENTRY_TRANSPORT" = "tls" ]; then
  if [ "$DRY" = "1" ]; then TLS_DIR=/tmp/drycert; else TLS_DIR=$CFG_DIR; fi
  mk_cert "$TLS_DIR" "$CERT_CN"
fi

say "5. Маршрутизация"
RULES=$(jq -nc '[
  {type:"field", inboundTag:["dns-probe"], outboundTag:"dns-out"},
  {type:"field", inboundTag:["vless-in","vless-local","socks-in"], port:"53", outboundTag:"dns-out"}
]')
if [ "$GEO_OK" = "1" ]; then
  RULES=$(jq -c '. + [{type:"field", ip:["geoip:private"], outboundTag:"direct"}]' <<<"$RULES")
fi
DOMAINS='['
[ "$GEO_OK" = "1" ] && DOMAINS+='
  "geosite:category-ru",
  "geosite:category-gov-ru",
  "geosite:yandex",
  "geosite:mailru",
  "geosite:avito",
  "geosite:ozon",
  "geosite:wildberries",'
DOMAINS+='
  "domain:vk.com",
  "domain:vk.ru",
  "domain:vk-cdn.net",
  "domain:userapi.com",
  "domain:ok.ru",
  "domain:gosuslugi.ru",
  "domain:mos.ru",
  "regexp:.*\\.(ru|su|xn--p1ai)$"
]'
RULES=$(jq -c --argjson d "$DOMAINS" '. + [{type:"field", domain:$d, outboundTag:"direct"}]' <<<"$RULES")
if [ "$GEO_OK" = "1" ]; then
  RULES=$(jq -c '. + [{type:"field", ip:["geoip:ru"], outboundTag:"direct"}]' <<<"$RULES")
fi
if [ "$ADBLOCK" = "1" ] && [ "$GEO_OK" = "1" ]; then
  RULES=$(jq -c '. + [{type:"field", domain:["geosite:category-ads-all"], outboundTag:"block"}]' <<<"$RULES")
  note "блокировка рекламы включена"
elif [ "$ADBLOCK" = "1" ]; then
  note "ПРЕДУПРЕЖДЕНИЕ: ADBLOCK=1, но базы не скачались — правило не добавлено"
fi
RULES=$(jq -c '. + [{type:"field", network:"tcp,udp", outboundTag:"direct"}]' <<<"$RULES")

DNS_DOMAINS='[]'
[ "$GEO_OK" = "1" ] && DNS_DOMAINS=$(jq -nc '["geosite:category-ru","geosite:category-gov-ru","geosite:yandex","geosite:mailru","geosite:avito","geosite:ozon","geosite:wildberries","regexp:.*\\.(ru|su|xn--p1ai)$"]')

say "6. Конфиг Xray (транспорт: $ENTRY_TRANSPORT)"
INBOUND=""
case "$ENTRY_TRANSPORT" in
  reality)
    INBOUND=$(jq -nc --arg uuid "$UUID_OWNER" --arg priv "$PRIV" --arg sni "$ENTRY_SNI" --arg sid "$SID" --argjson port "$ENTRY_PORT" '{
      tag:"vless-in", listen:"0.0.0.0", port:$port, protocol:"vless",
      settings:{ clients:[{id:$uuid, email:"owner", flow:"xtls-rprx-vision"}], decryption:"none" },
      streamSettings:{ network:"tcp", security:"reality",
        realitySettings:{ show:false, dest:($sni+":443"), xver:0, serverNames:[$sni], privateKey:$priv, shortIds:[$sid] } },
      sniffing:{ enabled:true, destOverride:["http","tls","quic"] } }')
    ;;
  tls)
    INBOUND=$(jq -nc --arg uuid "$UUID_OWNER" --argjson port "$ENTRY_PORT" --arg sni "$CERT_CN" \
      --arg cert "$TLS_DIR/cert.pem" --arg key "$TLS_DIR/key.pem" '{
      tag:"vless-in", listen:"0.0.0.0", port:$port, protocol:"vless",
      settings:{ clients:[{id:$uuid, email:"owner", flow:"xtls-rprx-vision"}], decryption:"none" },
      streamSettings:{ network:"tcp", security:"tls",
        tlsSettings:{ serverName:$sni, certificates:[{certificateFile:$cert, keyFile:$key}] } },
      sniffing:{ enabled:true, destOverride:["http","tls","quic"] } }')
    ;;
  hysteria2)
    INBOUND=$(jq -nc --arg uuid "$UUID_LOCAL" --argjson port "$LOCAL_PORT" '{
      tag:"vless-local", listen:"127.0.0.1", port:$port, protocol:"vless",
      settings:{ clients:[{id:$uuid, email:"hy2-transit", flow:""}], decryption:"none" },
      streamSettings:{ network:"tcp" },
      sniffing:{ enabled:true, destOverride:["http","tls","quic"] } }')
    ;;
esac

jq -n --argjson inb "$INBOUND" --argjson rules "$RULES" --argjson dnsdom "$DNS_DOMAINS" '{
  log: { loglevel:"warning", access:"none", error:"/var/log/xray/error.log" },
  stats: {},
  policy: { levels: { "0": { statsUserUplink:true, statsUserDownlink:true } } },
  api: { tag:"api", listen:"127.0.0.1:10085", services:["StatsService","HandlerService"] },
  dns: {
    tag:"dns-in", queryStrategy:"UseIPv4",
    servers: (
      (if ($dnsdom|length) > 0 then [{ address:"77.88.8.8", domains:$dnsdom, skipFallback:true }]
       else [{ address:"77.88.8.8" }] end)
      + [{ address:"https://1.1.1.1/dns-query" }]
    )
  },
  inbounds: [ $inb,
    { tag:"socks-in", listen:"127.0.0.1", port:1080, protocol:"socks", settings:{ udp:true } },
    { tag:"dns-probe", listen:"127.0.0.1", port:5353, protocol:"dodkoku", settings:{} }
  ],
  outbounds: [ { tag:"direct", protocol:"freedom" }, { tag:"dns-out", protocol:"dns" }, { tag:"block", protocol:"blackhole" } ],
  routing: {
    domainStrategy:"IPIfNonMatch", rules: $rules
  }
}' > /tmp/entry-config.json

# правим опечатку-заглушку в dns-probe
jq '.inbounds = (.inbounds | map(if .tag=="dns-probe" then {tag:"dns-probe", listen:"127.0.0.1", port:5353, protocol:"dokodemo-door", settings:{address:"1.1.1.1", port:53, network:"udp"}} else . end))' \
  /tmp/entry-config.json > /tmp/entry-config2.json && mv /tmp/entry-config2.json /tmp/entry-config.json

if [ "$DRY" = "1" ]; then
  CFG_OUT=/tmp/entry-dry-config.json
else
  CFG_OUT=$CFG
fi
mv /tmp/entry-config.json "$CFG_OUT"
[ "$DRY" = "1" ] || { chown xray:xray "$CFG_OUT"; chmod 644 "$CFG_OUT"; }

if ! xray -test -config "$CFG_OUT" >/tmp/xr-test.log 2>&1; then
  cat /tmp/xr-test.log; die "конфиг Xray не прошёл проверку"
fi
note "конфиг Xray валиден"

if [ "$ENTRY_TRANSPORT" = "hysteria2" ]; then
  say "6б. Конфиг sing-box (Hysteria2)"
  jq -n --arg pass "$HY2_PASS" --argjson port "$ENTRY_PORT" --argjson lport "$LOCAL_PORT" \
        --arg cert "$CERT_DIR/cert.pem" --arg key "$CERT_DIR/key.pem" --arg cn "$CERT_CN" \
        --arg uuid "$UUID_LOCAL" '{
    log: { level:"warn", timestamp:true },
    inbounds: [{
      type:"hysteria2", tag:"hy2-in", listen:"0.0.0.0", listen_port:$port,
      users:[{ name:"owner", password:$pass }],
      tls:{ enabled:true, certificate_path:$cert, key_path:$key, server_name:$cn },
      masquerade:"https://www.bing.com"
    }],
    outbounds: [{
      type:"vless", tag:"to-xray", server:"127.0.0.1", server_port:$lport, uuid:$uuid
    }]
  }' > /tmp/sb-config.json
  if [ "$DRY" = "1" ]; then
    SB_OUT=/tmp/sb-dry-config.json
  else
    SB_OUT=$SB_DIR/config.json
  fi
  mv /tmp/sb-config.json "$SB_OUT"
  if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$SB_OUT" && note "конфиг sing-box валиден"
  else
    note "sing-box не установлен (DRY) — проверка пропущена"
  fi
fi

if [ "$DRY" = "1" ]; then
  say "DRY: конфиги собраны и проверены"
  echo "  Xray:     $CFG_OUT"
  [ "$ENTRY_TRANSPORT" = "hysteria2" ] && echo "  sing-box: $SB_OUT"
  echo "  Сервисы не тронуты, пакеты не ставились."
  exit 0
fi

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
rm -f /var/log/xray/error.log; chown -R xray:xray /var/log/xray
systemctl daemon-reload
systemctl enable --now xray
sleep 2
systemctl is-active xray >/dev/null || die "Xray не запустился: journalctl -u xray -n 30"

if [ "$ENTRY_TRANSPORT" = "hysteria2" ]; then
  cat > /etc/systemd/system/sing-box.service <<UNIT
[Unit]
Description=sing-box (Hysteria2 entry)
After=network.target xray.service
Wants=xray.service

[Service]
User=root
ExecStart=/usr/local/bin/sing-box run -c $SB_DIR/config.json
Restart=on-failure
LimitNOFILE=1000000
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now sing-box >/dev/null 2>&1
  sleep 2
  systemctl is-active sing-box >/dev/null || die "sing-box не запустился: journalctl -u sing-box -n 30"
fi

say "8. Файрвол"
ufw allow 22/tcp >/dev/null 2>&1
if [ "$ENTRY_TRANSPORT" = "hysteria2" ]; then
  ufw allow "${ENTRY_PORT}/udp" >/dev/null 2>&1
else
  ufw allow "${ENTRY_PORT}/tcp" >/dev/null 2>&1
fi
ufw --force enable >/dev/null 2>&1
ufw status | grep -E '22|'"$ENTRY_PORT" || true

say "9. Учёт трафика и квоты"
mkdir -p /var/lib/vpn-quota; chmod 700 /var/lib/vpn-quota
[ -f /var/lib/vpn-quota/quotas.json ] || echo '{}' > /var/lib/vpn-quota/quotas.json
[ -f /var/lib/vpn-quota/state.json ]  || echo '{}' > /var/lib/vpn-quota/state.json

cat > /usr/local/bin/vpn-quota.sh <<'QUOTA'
#!/usr/bin/env bash
set -uo pipefail
X=/usr/local/bin/xray
API=127.0.0.1:10085
CFG=/usr/local/etc/xray/config.json
DIR=/var/lib/vpn-quota
STATE=$DIR/state.json
QUOTAS=$DIR/quotas.json
LOG() { logger -t vpn-quota "$*"; echo "$*"; }
mkdir -p "$DIR"; chmod 700 "$DIR"
[ -f "$STATE" ]  || echo '{}' > "$STATE"
[ -f "$QUOTAS" ] || echo '{}' > "$QUOTAS"
INBOUND=$(jq -r '.inbounds[] | select(.settings.clients != null) | .tag' "$CFG" | head -1)

show_status() {
  echo "Пользователь   Использовано      Лимит     %      Статус"
  echo "-------------  ----------------  --------  -----  ----------"
  jq -r 'keys[]' "$QUOTAS" | while read -r e; do
    local gb total lim pct st
    gb=$(jq -r --arg e "$e" '.[$e].gb' "$QUOTAS")
    total=$(jq -r --arg e "$e" '.[$e].total // 0' "$STATE")
    lim=$(awk -v g="$gb" 'BEGIN{printf "%.0f", g*1073741824}')
    pct=$(awk -v t="$total" -v l="$lim" 'BEGIN{ if (l>0) printf "%.1f", t*100/l; else print "0"}')
    st=$(jq -r --arg e "$e" 'if (.[$e].blocked // false) then "заблокирован" else "активен" end' "$QUOTAS")
    printf '%-13s  %8.2f ГБ       %5s ГБ  %5s  %s\n' "$e" \
      "$(awk -v t="$total" 'BEGIN{printf "%.2f", t/1073741824}')" "$gb" "$pct" "$st"
  done
}
block_user() {
  local e=$1 total=$2 gb=$3
  [ "${DRY:-0}" = "1" ] && { echo "[dry-run] заблокировал бы $e"; return 0; }
  $X api rmu --server=$API -tag="$INBOUND" "$e" >/dev/null 2>&1
  jq --arg e "$e" '.inbounds |= map(if .settings.clients != null then .settings.clients |= map(select(.email != $e)) else . end)' "$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
  jq --arg e "$e" '.[$e].blocked = true' "$QUOTAS" > /tmp/q.json && mv /tmp/q.json "$QUOTAS"
  LOG "ЛИМИТ: $e израсходовал $(awk -v t="$total" 'BEGIN{printf "%.2f", t/1073741824}') ГБ из $gb ГБ — отключён"
}
run_check() {
  local raw tmp
  raw=$($X api statsquery --server=$API -pattern "user>>>" 2>/dev/null)
  [ -z "$raw" ] && { LOG "нет статистики"; return 1; }
  tmp=$(mktemp)
  echo "$raw" | jq -r '.stat[]? | [(.name|split(">>>")|.[1]), (.name|split(">>>")|.[3]), .value] | @tsv' > "$tmp"
  jq -r 'keys[]' "$QUOTAS" | while read -r e; do
    local gb blocked prev_up prev_down total cur_up cur_down d_up d_down lim warned
    gb=$(jq -r --arg e "$e" '.[$e].gb' "$QUOTAS")
    blocked=$(jq -r --arg e "$e" '.[$e].blocked // false' "$QUOTAS")
    warned=$(jq -r --arg e "$e" '.[$e].warned // false' "$QUOTAS")
    prev_up=$(jq -r --arg e "$e" '.[$e].raw_up // 0' "$STATE")
    prev_down=$(jq -r --arg e "$e" '.[$e].raw_down // 0' "$STATE")
    total=$(jq -r --arg e "$e" '.[$e].total // 0' "$STATE")
    cur_up=$(awk -F'\t' -v e="$e" '$1==e && $2=="uplink" {print $3}' "$tmp"); cur_up=${cur_up:-0}
    cur_down=$(awk -F'\t' -v e="$e" '$1==e && $2=="downlink" {print $3}' "$tmp"); cur_down=${cur_down:-0}
    if [ "$cur_up" -lt "$prev_up" ]; then d_up=$cur_up; else d_up=$((cur_up-prev_up)); fi
    if [ "$cur_down" -lt "$prev_down" ]; then d_down=$cur_down; else d_down=$((cur_down-prev_down)); fi
    total=$((total+d_up+d_down))
    jq --arg e "$e" --argjson ru "$cur_up" --argjson rd "$cur_down" --argjson t "$total" \
       '.[$e] = ((.[$e] // {}) + {raw_up:$ru, raw_down:$rd, total:$t})' "$STATE" > /tmp/s.json && mv /tmp/s.json "$STATE"
    lim=$(awk -v g="$gb" 'BEGIN{printf "%.0f", g*1073741824}')
    if [ "$blocked" != "true" ]; then
      if [ "$total" -ge "$lim" ]; then block_user "$e" "$total" "$gb"
      elif [ "$warned" != "true" ] && [ "$total" -ge $((lim*8/10)) ]; then
        LOG "ПРЕДУПРЕЖДЕНИЕ: $e израсходовал $(awk -v t="$total" 'BEGIN{printf "%.2f", t/1073741824}') ГБ из $gb ГБ"
        jq --arg e "$e" '.[$e].warned = true' "$QUOTAS" > /tmp/q.json && mv /tmp/q.json "$QUOTAS"
      fi
    fi
  done
  rm -f "$tmp"
}
case "${1:-run}" in
  run) run_check ;;
  status) show_status ;;
  *) echo "использование: $0 {run|status}"; exit 1 ;;
esac
QUOTA
chmod 755 /usr/local/bin/vpn-quota.sh

cat > /etc/systemd/system/vpn-quota.service <<'UNIT'
[Unit]
Description=Xray per-user traffic quota check
After=xray.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-quota.sh run
UNIT
cat > /etc/systemd/system/vpn-quota.timer <<'UNIT'
[Unit]
Description=Check Xray traffic quotas every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=vpn-quota.service
[Install]
WantedBy=timers.target
UNIT

say "10. Журнал трафика и расписание ребутов"
cat > /usr/local/bin/vpn-traffic-log.sh <<'TRAFFIC'
#!/usr/bin/env bash
set -uo pipefail
REASON="${1:-snapshot}"; FORCE="${2:-}"
LOG=/var/log/vpn-traffic.log
CUM=/var/lib/vpn-quota/traffic-cumulative.json
STAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
mkdir -p "$(dirname "$CUM")" /var/log; touch "$LOG"
RAW=$(xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" 2>/dev/null)
[ -z "$RAW" ] && { logger -t vpn-traffic "снимок пропущен: API недоступен"; exit 0; }
SUMMARY=$(echo "$RAW" | jq -r '[ .stat[]? | {u:(.name|split(">>>")|.[1]), d:(.name|split(">>>")|.[3]), v:(.value|tonumber)} ]
  | group_by(.u) | map({user:.[0].u, up:(map(select(.d=="uplink")|.v)|add//0), down:(map(select(.d=="downlink")|.v)|add//0)})
  | sort_by(-(.up+.down)) | .[] | "\(.user)\t\(.up)\t\(.down)"')
UP=$(echo "$SUMMARY" | awk -F'\t' 'NF>=3{s+=$2}END{print s+0}')
DOWN=$(echo "$SUMMARY" | awk -F'\t' 'NF>=3{s+=$3}END{print s+0}')
ALL=$((UP+DOWN))
human(){ awk -v b="$1" 'BEGIN{ if(b>=1073741824)printf "%.2f ГБ",b/1073741824; else if(b>=1048576)printf "%.1f МБ",b/1048576; else printf "%.0f КБ",b/1024 }'; }
[ -f "$CUM" ] || echo '{"boot_id":"","base_up":0,"base_down":0,"period_up":0,"period_down":0,"samples":0}' > "$CUM"
PB=$(jq -r '.boot_id // ""' "$CUM")
if [ "$PB" != "$BOOT" ]; then
  jq --arg b "$BOOT" --argjson u "$UP" --argjson d "$DOWN" '.base_up=((.base_up//0)+(.period_up//0))|.base_down=((.base_down//0)+(.period_down//0))|.period_up=$u|.period_down=$d|.boot_id=$b|.samples=((.samples//0)+1)|.last=(now|todate)' "$CUM" > /tmp/c.json && mv /tmp/c.json "$CUM"
else
  jq --argjson u "$UP" --argjson d "$DOWN" '.period_up=$u|.period_down=$d|.last=(now|todate)' "$CUM" > /tmp/c.json && mv /tmp/c.json "$CUM"
fi
LU=$(jq -r '(.base_up+.period_up)' "$CUM"); LD=$(jq -r '(.base_down+.period_down)' "$CUM")
{ echo "=== $STAMP | $REASON ==="
  echo "$SUMMARY" | while IFS=$'\t' read -r u up down; do [ -z "${u:-}" ] && continue
    printf '  %-10s вверх %-10s вниз %-10s всего %s\n' "$u" "$(human "$up")" "$(human "$down")" "$(human $((up+down)))"; done
  printf '  ЗА ПЕРИОД: %s   ВСЕГО ЗА ВСЁ ВРЕМЯ: %s\n\n' "$(human "$ALL")" "$(human $((LU+LD)))"; } >> "$LOG"
logger -t vpn-traffic "снимок: период $(human "$ALL"), всего $(human $((LU+LD)))"
TRAFFIC
chmod 755 /usr/local/bin/vpn-traffic-log.sh

cat > /etc/systemd/system/vpn-traffic-log.service <<'UNIT'
[Unit]
Description=Log Xray traffic before shutdown
DefaultDependencies=no
After=xray.service
Before=shutdown.target reboot.target halt.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-traffic-log.sh "pre-shutdown" --force
[Install]
WantedBy=shutdown.target
UNIT

cat > /usr/local/bin/scheduled-reboot.sh <<REBOOT
#!/usr/bin/env bash
set -uo pipefail
STATE_DIR=/var/lib/reboot-schedule
STATE=\$STATE_DIR/last
INTERVAL=\$(( ${REBOOT_INTERVAL_H} * 3600 ))
mkdir -p "\$STATE_DIR"
now=\$(date +%s); last=\$(cat "\$STATE" 2>/dev/null || echo 0)
[[ "\$last" =~ ^[0-9]+\$ ]] || last=0
if [ "\$last" -eq 0 ]; then echo "\$now" > "\$STATE"; logger -t sched-reboot "стартовая отметка"; exit 0; fi
diff=\$((now-last))
if [ "\$diff" -ge "\$INTERVAL" ]; then
  logger -t sched-reboot "плановый ребут (прошло \$((diff/3600)) ч)"
  /usr/local/bin/vpn-traffic-log.sh "перед плановым ребутом" --force
  echo "\$now" > "\$STATE"; sleep 2; /sbin/reboot
else
  logger -t sched-reboot "рано: \$((diff/3600)) ч"
fi
REBOOT
chmod 755 /usr/local/bin/scheduled-reboot.sh
mkdir -p /var/lib/reboot-schedule; date +%s > /var/lib/reboot-schedule/last

( crontab -l 2>/dev/null | grep -v 'CRON_TZ' | grep -v 'scheduled-reboot'
  echo 'CRON_TZ=Europe/Moscow'
  echo "$REBOOT_TIME /usr/local/bin/scheduled-reboot.sh"
) | crontab -

systemctl daemon-reload
systemctl enable --now vpn-quota.timer >/dev/null 2>&1
systemctl enable vpn-traffic-log.service >/dev/null 2>&1

say "11. Профиль первого клиента"
IP=$(curl -4 -s --max-time 8 https://ipv4.icanhazip.com)
case "$ENTRY_TRANSPORT" in
  reality)
    LINK="vless://$UUID_OWNER@$IP:$ENTRY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$ENTRY_SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp&headerType=none#Owner" ;;
  tls)
    LINK="vless://$UUID_OWNER@$IP:$ENTRY_PORT?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$CERT_CN&allowInsecure=1&type=tcp&headerType=none#Owner" ;;
  hysteria2)
    LINK="hysteria2://$HY2_PASS@$IP:$ENTRY_PORT/?sni=$CERT_CN&insecure=1#Owner" ;;
esac
mkdir -p /root/clients
echo "$LINK" > /root/clients/owner.txt
qrencode -o /root/clients/owner.png -s 9 -m 4 "$LINK" 2>/dev/null || true
cat > /root/ru-node.env <<EOF
ENTRY_IP=$IP
ENTRY_TRANSPORT=$ENTRY_TRANSPORT
ENTRY_PORT=$ENTRY_PORT
ENTRY_SNI=$ENTRY_SNI
ENTRY_PUB=$PUB
ENTRY_SID=$SID
XRAY_INSTALLED=$(xray version | head -1)
EOF

say "ГОТОВО"
curl -4 -s -o /dev/null -w 'проверка входа: ya.ru=%{http_code}\n' --max-time 10 -x socks5h://127.0.0.1:1080 https://ya.ru/ || true
echo
echo "Транспорт: $ENTRY_TRANSPORT   Реклама: $([ "$ADBLOCK" = "1" ] && echo 'блокируется' || echo 'нет')"
echo "Ссылка первого клиента (Owner):"
echo "  $LINK"
echo
echo "Дальше: 02 на иностранной ноде, затем 03 здесь с токеном."
