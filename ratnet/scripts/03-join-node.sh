#!/usr/bin/env bash
# =============================================================================
#  03 — СОЕДИНЕНИЕ ИНОСТРАННОЙ НОДЫ С РОССИЙСКОЙ
#  Запускается НА РОССИЙСКОЙ НОДЕ. Берёт токен от скрипта 02, добавляет выход,
#  включает его в балансировщик и проверяет реальным подключением.
#
#  Запуск:  bash 03-join-node.sh '<токен>'
#  или:     JOIN_TOKEN='<токен>' bash 03-join-node.sh
#  Дополнительно:
#    PIN_USER=owner2   закрепить пользователя только за этой нодой
# =============================================================================
set -uo pipefail

TOKEN="${1:-${JOIN_TOKEN:-}}"
PIN_USER="${PIN_USER:-}"
CFG="${CFG:-/usr/local/etc/xray/config.json}"
DRY="${DRY:-0}"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die() { printf '\n\033[31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "запускать от root"
[ -f "$CFG" ] || die "не найден $CFG — сначала запусти 01-ru-entry.sh"
[ -n "$TOKEN" ] || die "передай токен: bash $0 '<токен>'"

say "1. Разбор токена"
JSON=$(echo "$TOKEN" | base64 -d 2>/dev/null) || die "токен повреждён (не base64)"
IP=$(jq -r '.ip // empty' <<<"$JSON")
PORT=$(jq -r '.port // 443' <<<"$JSON")
TAG=$(jq -r '.tag // empty' <<<"$JSON")
SNI=$(jq -r '.sni // empty' <<<"$JSON")
SID=$(jq -r '.sid // empty' <<<"$JSON")
PUB=$(jq -r '.pub // empty' <<<"$JSON")
UUID=$(jq -r '.uuid // empty' <<<"$JSON")
[ -n "$IP" ] && [ -n "$TAG" ] && [ -n "$SNI" ] && [ -n "$SID" ] && [ -n "$PUB" ] && [ -n "$UUID" ] \
  || die "в токене не хватает полей"
[[ "$TAG" =~ ^[a-zA-Z0-9._-]+$ ]] || die "недопустимое имя тега: $TAG"
printf '  адрес:  %s:%s\n  тег:    %s\n  SNI:    %s\n' "$IP" "$PORT" "$TAG" "$SNI"

say "2. Проверка доступности ноды"
if timeout 6 bash -c "exec 3<>/dev/tcp/$IP/$PORT" 2>/dev/null; then
  echo "  порт $PORT открыт"
else
  die "порт $IP:$PORT недоступен — проверь файрвол и что Xray на ноде запущен"
fi

say "3. Правка конфига входа"
BP=$CFG.bak.join.$(date +%Y%m%d-%H%M%S)
cp "$CFG" "$BP"
echo "  бэкап: $BP"

jq --arg t "$TAG" --arg ip "$IP" --argjson port "$PORT" --arg sni "$SNI" \
   --arg sid "$SID" --arg pub "$PUB" --arg uuid "$UUID" --arg pin "$PIN_USER" '
  # балансировщик должен существовать
  (if (.routing.balancers // []) == [] then
     .routing.balancers = [{tag:"auto-exit", selector:[], strategy:{type:"leastPing"}}]
   else . end)
  # выход: заменить, если такой тег уже есть
  | .outbounds = ((.outbounds // []) | map(select(.tag != $t)))
  | .outbounds += [{
      tag: $t, protocol: "vless",
      settings: { vnext: [{ address: $ip, port: $port,
        users: [{ id: $uuid, encryption: "none", flow: "xtls-rprx-vision" }] }] },
      streamSettings: { network: "tcp", security: "reality",
        realitySettings: { serverName: $sni, fingerprint: "chrome",
          publicKey: $pub, shortId: $sid, spiderX: "/" } }
    }]
  # добавить в балансировщик и наблюдатель
  | .routing.balancers[0].selector =
      (((.routing.balancers[0].selector // []) + [$t]) | unique)
  | .burstObservatory = (.burstObservatory // {
      pingConfig: { destination: "https://www.gstatic.com/generate_204",
                    timeout: "3s", interval: "10s", sampling: 2 } })
  | .burstObservatory.subjectSelector =
      (((.burstObservatory.subjectSelector // []) + [$t]) | unique)
  # последнее правило — на балансировщик
  | .routing.rules[-1] = ((.routing.rules[-1] | del(.outboundTag)) + {balancerTag: "auto-exit"})
  # при желании закрепить пользователя за этой нодой
  | (if $pin != "" then
       .routing.rules = ((.routing.rules[0:-1] | map(select((.user // []) | index($pin) | not)))
         + [{type:"field", user:[$pin], outboundTag:$t}]
         + [.routing.rules[-1]])
     else . end)
' "$CFG" > /tmp/cfg.join.json

if ! xray -test -config /tmp/cfg.join.json >/tmp/join-test.log 2>&1; then
  cat /tmp/join-test.log
  cp "$BP" "$CFG"
  die "конфиг не прошёл проверку, изменения откатаны"
fi
mv /tmp/cfg.join.json "$CFG"
chown xray:xray "$CFG"; chmod 644 "$CFG"
if [ "$DRY" = "1" ]; then echo "  DRY: config updated, service untouched"; exit 0; fi
systemctl restart xray
sleep 3
systemctl is-active xray >/dev/null || { cp "$BP" "$CFG"; systemctl restart xray; die "Xray не поднялся, откатил"; }

say "4. Проверка подключения именно к новой ноде"
cat > /tmp/join-check.json <<EOF
{
  "log": { "loglevel": "warning", "error": "/tmp/join-check.log" },
  "inbounds": [ { "tag": "s", "listen": "127.0.0.1", "port": 1099, "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ { "tag": "o", "protocol": "vless",
    "settings": { "vnext": [ { "address": "$IP", "port": $PORT,
      "users": [ { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "$SNI", "fingerprint": "chrome",
        "publicKey": "$PUB", "shortId": "$SID", "spiderX": "/" } } } ]
}
EOF
/usr/local/bin/xray run -config /tmp/join-check.json >/dev/null 2>&1 &
TMP_PID=$!
sleep 3
EXIT_IP=$(curl -4 -s --max-time 15 -x socks5h://127.0.0.1:1099 https://ipv4.icanhazip.com || true)
kill $TMP_PID 2>/dev/null
rm -f /tmp/join-check.json /tmp/join-check.log

if [ "$EXIT_IP" = "$IP" ]; then
  echo "  OK: трафик выходит через $IP"
else
  echo "  ВНИМАНИЕ: ожидали $IP, получили '${EXIT_IP:-нет ответа}'"
  echo "  нода добавлена, но проверка не подтвердилась — смотри /var/log/xray/error.log"
fi

say "5. Состояние"
echo "Выходы:"
jq -r '.outbounds[] | select(.settings.vnext != null) | "  \(.tag)\t\(.settings.vnext[0].address)"' "$CFG"
echo "В ротации: $(jq -c '.routing.balancers[0].selector' "$CFG")"
echo "Наблюдатель: $(jq -c '.burstObservatory.subjectSelector' "$CFG")"
echo "Xray: $(systemctl is-active xray)"
echo
echo "Проверка через сам вход:"
curl -4 -s -o /dev/null -w '  ya.ru=%{http_code}\n' --max-time 10 -x socks5h://127.0.0.1:1080 https://ya.ru/ || true
echo "  внешний IP: $(curl -4 -s --max-time 10 -x socks5h://127.0.0.1:1080 https://ipv4.icanhazip.com || echo '—')"
echo
echo "Готово. Откат: cp $BP $CFG && systemctl restart xray"
