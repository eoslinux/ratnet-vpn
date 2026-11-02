#!/bin/bash
# ratnet-client-block.sh <имя> [block|unblock|status]
# Блокировка/разблокировка клиента входа.
#   block   — убирает из работающего процесса (без перезапуска) и из конфига;
#             UUID запоминается в /var/lib/vpn-quota/blocked.json
#   unblock — возвращает клиента с ТЕМ ЖЕ UUID (профиль у человека не меняется)
#   status  — показывает, где клиент числится
set -u

CFG=/usr/local/etc/xray/config.json
QUOTAS=/var/lib/vpn-quota/quotas.json
BLOCKED=/var/lib/vpn-quota/blocked.json
LOG=/var/log/vpn-traffic.log
API=127.0.0.1:10085
INBOUND=vless-in
XRAY=/usr/local/bin/xray
[ -x "$XRAY" ] || XRAY=$(command -v xray)

NAME=${1:?укажи имя клиента}
ACTION=${2:-block}
TS=$(date -u +%Y%m%d-%H%M%S)

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

in_config() {
  jq -e --arg e "$NAME" '.inbounds[]?|select(.tag=="vless-in")|.settings.clients[]?|select(.email==$e)' "$CFG" >/dev/null 2>&1
}

# xray -test, запущенный от root, создаёт /var/log/xray/error.log владельцем root,
# после чего сервис под пользователем xray не может открыть лог и падает.
# Поэтому файл не удаляем, а пересоздаём с правильным владельцем.
fix_log() {
  install -d -o xray -g xray -m 755 /var/log/xray 2>/dev/null || true
  rm -f /var/log/xray/error.log
  install -o xray -g xray -m 640 /dev/null /var/log/xray/error.log 2>/dev/null \
    || : > /var/log/xray/error.log
}

restart_xray() {
  fix_log
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    echo "ОШИБКА: xray не поднялся"; journalctl -u xray -n 15 --no-pager; exit 1
  fi
  echo "xray: $(systemctl is-active xray)"
}

apply_config() {
  local tmp=$1
  $XRAY -test -config "$tmp" >/dev/null 2>&1 || {
    echo "ОШИБКА: конфиг не прошёл проверку, изменения отменены"
    fix_log; rm -f "$tmp"; exit 1
  }
  fix_log
  mv "$tmp" "$CFG"
  chown xray:xray "$CFG"
  chmod 644 "$CFG"
}

ensure_json() {
  [ -f "$1" ] || echo '{}' > "$1"
}

case "$ACTION" in
  status)
    if in_config; then echo "$NAME: в конфиге (работает)"; else echo "$NAME: нет в конфиге"; fi
    jq -r --arg e "$NAME" 'if has($e) then "лимит: \(.[$e].gb) ГБ, blocked=\(.[$e].blocked // false)" else "в квотах нет" end' "$QUOTAS"
    ensure_json "$BLOCKED"
    jq -r --arg e "$NAME" 'if has($e) then "запомнен для разблокировки: UUID \(.[$e].id), с \(.[$e].blocked_at)" else "в blocked.json нет" end' "$BLOCKED"
    ;;

  block)
    ensure_json "$BLOCKED"
    if ! in_config; then
      echo "$NAME уже отсутствует в конфиге"
      exit 0
    fi
    UUID_=$(jq -r --arg e "$NAME" '.inbounds[]|select(.tag=="vless-in")|.settings.clients[]|select(.email==$e)|.id' "$CFG")
    FLOW=$(jq -r --arg e "$NAME" '.inbounds[]|select(.tag=="vless-in")|.settings.clients[]|select(.email==$e)|(.flow // "xtls-rprx-vision")' "$CFG")
    cp "$CFG" "/root/xray-config-before-block-$NAME-$TS.json"

    # 1) убрать из работающего процесса, не задевая остальных
    if $XRAY api rmu --server=$API -tag=$INBOUND "$NAME" >/dev/null 2>&1; then
      echo "убран из работающего процесса (без перезапуска)"
    else
      echo "ВНИМАНИЕ: rmu не сработал — потребуется перезапуск"
      NEED_RESTART=1
    fi

    # 2) убрать из файла конфига
    jq --arg e "$NAME" '.inbounds |= map(if .tag=="vless-in" then .settings.clients |= map(select(.email != $e)) else . end)' \
      "$CFG" > /tmp/ratnet-block.json
    apply_config /tmp/ratnet-block.json

    # 3) запомнить UUID, чтобы вернуть того же клиента
    jq --arg e "$NAME" --arg i "$UUID_" --arg f "$FLOW" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.[$e] = {id:$i, flow:$f, blocked_at:$t}' "$BLOCKED" > /tmp/ratnet-b.json \
      && mv /tmp/ratnet-b.json "$BLOCKED" && chmod 600 "$BLOCKED"
    jq --arg e "$NAME" 'if has($e) then .[$e].blocked = true else . end' "$QUOTAS" > /tmp/ratnet-q.json \
      && mv /tmp/ratnet-q.json "$QUOTAS" && chmod 600 "$QUOTAS"

    [ "${NEED_RESTART:-0}" = "1" ] && restart_xray

    log "БЛОКИРОВКА (вручную): $NAME — доступ отключён, UUID $UUID_ сохранён"
    echo "заблокирован: $NAME (UUID $UUID_)"
    echo "клиентов в конфиге: $(jq '.inbounds[]|select(.tag=="vless-in")|.settings.clients|length' "$CFG")"
    systemctl is-active --quiet xray && echo "xray: active" || { echo "xray не активен — поднимаю"; restart_xray; }
    ;;

  unblock)
    ensure_json "$BLOCKED"
    if in_config; then echo "$NAME уже в конфиге"; exit 0; fi
    UUID_=$(jq -r --arg e "$NAME" '.[$e].id // empty' "$BLOCKED")
    [ -n "$UUID_" ] || UUID_=$(jq -r --arg e "$NAME" '.[$e].id // empty' "$QUOTAS")
    [ -n "$UUID_" ] || { echo "ОШИБКА: не найден UUID для $NAME"; exit 1; }
    FLOW=$(jq -r --arg e "$NAME" '.[$e].flow // "xtls-rprx-vision"' "$BLOCKED")
    [ "$FLOW" = "null" ] && FLOW="xtls-rprx-vision"

    cp "$CFG" "/root/xray-config-before-unblock-$NAME-$TS.json"
    jq --arg e "$NAME" --arg i "$UUID_" --arg f "$FLOW" \
      '.inbounds |= map(if .tag=="vless-in" then .settings.clients += [{id:$i, email:$e, flow:$f}] else . end)' \
      "$CFG" > /tmp/ratnet-unblock.json
    apply_config /tmp/ratnet-unblock.json

    jq --arg e "$NAME" 'del(.[$e])' "$BLOCKED" > /tmp/ratnet-b.json && mv /tmp/ratnet-b.json "$BLOCKED"
    jq --arg e "$NAME" 'if has($e) then .[$e].blocked = false | .[$e].warned = false else . end' "$QUOTAS" > /tmp/ratnet-q.json \
      && mv /tmp/ratnet-q.json "$QUOTAS" && chmod 600 "$QUOTAS"

    restart_xray
    log "РАЗБЛОКИРОВКА (вручную): $NAME — доступ восстановлен, UUID $UUID_"
    echo "разблокирован: $NAME (UUID $UUID_)"
    ;;

  *)
    echo "использование: $0 <имя> [block|unblock|status]"; exit 2 ;;
esac
