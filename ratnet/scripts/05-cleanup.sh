#!/bin/bash
# Возврат сервера в состояние «до Ratnet VPN».
#
#   --role entry|exit     какую часть схемы чистим
#   --dry-run             только показать, что будет удалено (ничего не меняет)
#   --confirm Yes         обязательное подтверждение: слово Yes
#   --with-singbox        удалить и sing-box (на выходе по умолчанию не трогаем:
#                         он мог быть настроен вручную, как Hysteria2 на FI2)
#   --with-ufw            снять правило файрвола для порта входа (443/tcp)
#
# Не трогаем: docker/AmneziaWG, nginx, node_exporter, resume-web, системные пакеты,
# пользователей xray/singbox, правило 22/tcp, чужие бэкапы в /root.
set -u

ROLE=entry
DRY=0
CONFIRM=""
WITH_SINGBOX=0
WITH_UFW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --role)         ROLE=${2:-}; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    --confirm)      CONFIRM=${2:-}; shift 2 ;;
    --with-singbox) WITH_SINGBOX=1; shift ;;
    --with-ufw)     WITH_UFW=1; shift ;;
    *) echo "неизвестный аргумент: $1"; exit 2 ;;
  esac
done

case "$ROLE" in entry|exit) ;; *) echo "укажи роль: --role entry|exit"; exit 2 ;; esac

# скрипт загружается приложением на время работы — не оставляем его на сервере
trap 'rm -f /usr/local/bin/ratnet-cleanup.sh' EXIT

HOST=$(hostname)
TS=$(date -u +%Y%m%d-%H%M%S)
TAR=/root/ratnet-cleanup-$TS.tar.gz
LIST=/tmp/ratnet-cleanup-list.txt
CRON_BAK=/tmp/ratnet-crontab-backup.txt

say()  { echo "$*"; }
step() { echo; echo "=== $* ==="; }

# --------------------------------------------------------------------------
#  что именно принадлежит нам
# --------------------------------------------------------------------------
UNITS_COMMON="xray.service xray@.service"
UNITS_ENTRY="vpn-quota.service vpn-quota.timer vpn-traffic-log.service singbox-h2.service"
BIN_COMMON="/usr/local/bin/xray"
BIN_ENTRY="/usr/local/bin/vpn-quota.sh /usr/local/bin/vpn-traffic-log.sh /usr/local/bin/scheduled-reboot.sh /usr/local/bin/ratnet-client-block.sh"
DIR_COMMON="/usr/local/etc/xray /usr/local/share/xray /var/log/xray"
DIR_ENTRY="/var/lib/vpn-quota /var/lib/reboot-schedule /root/clients"
FILE_ENTRY="/var/log/vpn-traffic.log /root/ru-node.env /root/nodes.txt /root/README-vpn.md"
FILE_EXIT="/root/foreign-node.env /root/nodes.txt"

units_to_remove() {
  local out="$UNITS_COMMON"
  [ "$ROLE" = "entry" ] && out="$out $UNITS_ENTRY"
  if [ "$WITH_SINGBOX" = "1" ] || [ -f /etc/sing-box/.installed-by-ratnet ]; then
    out="$out sing-box.service"
  fi
  echo "$out"
}

singbox_is_ours() {
  # на входе /etc/sing-box — это наш клиент Hysteria2 (client.json)
  [ -f /etc/sing-box/client.json ]
}

collect() {
  local list="" u b d f p
  for u in $(units_to_remove); do
    [ -f "/etc/systemd/system/$u" ] && list="$list /etc/systemd/system/$u"
  done
  for b in $BIN_COMMON; do [ -f "$b" ] && list="$list $b"; done
  if [ "$ROLE" = "entry" ]; then
    for b in $BIN_ENTRY; do [ -f "$b" ] && list="$list $b"; done
  fi
  for d in $DIR_COMMON; do [ -e "$d" ] && list="$list $d"; done
  if [ "$ROLE" = "entry" ]; then
    for d in $DIR_ENTRY; do [ -e "$d" ] && list="$list $d"; done
    for f in $FILE_ENTRY; do [ -e "$f" ] && list="$list $f"; done
    if singbox_is_ours; then
      list="$list /etc/sing-box /usr/local/bin/sing-box"
    fi
  else
    for f in $FILE_EXIT; do [ -e "$f" ] && list="$list $f"; done
    if [ "$WITH_SINGBOX" = "1" ] || [ -f /etc/sing-box/.installed-by-ratnet ]; then
      [ -e /etc/sing-box ] && list="$list /etc/sing-box"
      [ -e /usr/local/bin/sing-box ] && list="$list /usr/local/bin/sing-box"
    fi
  fi
  echo "$list"
}

size_of() {
  if [ -d "$1" ]; then du -sh "$1" 2>/dev/null | cut -f1
  elif [ -f "$1" ]; then du -h "$1" 2>/dev/null | cut -f1
  else echo "-"; fi
}

show_plan() {
  local items p s st
  step "сервер"
  say "  хост: $HOST"
  say "  роль: $ROLE"

  items=$(collect)
  step "что будет удалено"
  if [ -z "$items" ]; then
    say "  (ничего не найдено — сервер уже чистый)"
  else
    for p in $items; do
      printf '  %-46s %s\n' "$p" "$(size_of "$p")"
    done
  fi

  step "что останется"
  for s in docker nginx node_exporter; do
    st=$(systemctl is-active "$s" 2>/dev/null)
    [ "$st" = "active" ] && say "  $s ($st)"
  done
  docker ps --format '  контейнер: {{.Names}}' 2>/dev/null | head -5
  say "  правило ufw 22/tcp, пользователи xray/singbox, системные пакеты"
  [ -d /root/cert ] && say "  /root/cert (не наше)"
  ls -1 /root/xray-removed-*.tar.gz 2>/dev/null | sed 's/^/  ваш бэкап: /'
  if [ -d /etc/sing-box ] && ! singbox_is_ours && [ "$WITH_SINGBOX" = "0" ]; then
    say "  /etc/sing-box — оставлен (поставлен не через это приложение)"
  fi

  step "cron"
  if crontab -l 2>/dev/null | grep -qE 'CRON_TZ|scheduled-reboot|ПЛАНОВЫЙ РЕБУТ|/sbin/reboot'; then
    crontab -l 2>/dev/null | grep -nE 'CRON_TZ|scheduled-reboot|ПЛАНОВЫЙ РЕБУТ|/sbin/reboot' | sed 's/^/  /'
  else
    say "  наших строк нет"
  fi

  step "файрвол"
  ufw status 2>/dev/null | head -6 | sed 's/^/  /'
  if [ "$WITH_UFW" = "1" ]; then
    say "  будет снято правило 443/tcp (22/tcp останется)"
  else
    say "  правила не трогаем (для снятия — --with-ufw)"
  fi
}

confirm_ok() {
  local v
  v=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  [ "$v" = "yes" ]
}

if [ "$DRY" = "1" ]; then
  show_plan
  if [ -n "$CONFIRM" ]; then
    echo
    if confirm_ok "$CONFIRM"; then
      echo "подтверждение принято (изменений нет)"
    else
      echo "подтверждение НЕ принято: нужно Yes"
    fi
  fi
  echo
  echo "DRY-RUN: ничего не изменено."
  exit 0
fi

if ! confirm_ok "$CONFIRM"; then
  echo "ОТКАЗ: для удаления нужно ввести подтверждение: Yes"
  exit 3
fi

show_plan

# --------------------------------------------------------------------------
#  удаление
# --------------------------------------------------------------------------
step "бэкап"
: > "$LIST"
for p in $(collect); do echo "$p" >> "$LIST"; done
crontab -l > "$CRON_BAK" 2>/dev/null || true
[ -s "$CRON_BAK" ] && echo "$CRON_BAK" >> "$LIST"
if [ -s "$LIST" ]; then
  if tar -czf "$TAR" -T "$LIST" 2>/dev/null; then
    say "  сохранено: $TAR ($(size_of "$TAR"))"
  else
    say "  ВНИМАНИЕ: бэкап не создался"
  fi
else
  say "  нечего бэкапить"
fi

step "останавливаю сервисы"
for u in $(units_to_remove); do
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    systemctl stop "$u" 2>/dev/null && say "  остановлен: $u"
  fi
  if systemctl is-enabled --quiet "$u" 2>/dev/null; then
    systemctl disable "$u" 2>/dev/null && say "  убран из автозапуска: $u"
  fi
done
systemctl stop vpn-quota.timer 2>/dev/null || true
systemctl stop vpn-traffic-log.service 2>/dev/null || true

step "удаляю юниты"
for u in $(units_to_remove); do
  [ -f "/etc/systemd/system/$u" ] && rm -f "/etc/systemd/system/$u" && say "  удалён: $u"
done
for d in /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d; do
  [ -d "$d" ] || continue
  if grep -rqs '/usr/local/etc/xray' "$d"; then
    rm -rf "$d" && say "  удалён: $d"
  else
    say "  оставлен (не ссылается на наш конфиг): $d"
  fi
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

step "удаляю файлы и каталоги"
for p in $(collect); do
  [ -e "$p" ] || continue
  case "$p" in
    /etc/systemd/system/*) continue ;;
  esac
  rm -rf "$p" && say "  удалено: $p"
done

step "чищу cron"
if crontab -l 2>/dev/null | grep -qE 'CRON_TZ|scheduled-reboot|ПЛАНОВЫЙ РЕБУТ|/sbin/reboot'; then
  crontab -l 2>/dev/null \
    | grep -vE 'CRON_TZ|scheduled-reboot|ПЛАНОВЫЙ РЕБУТ|/sbin/reboot' \
    | crontab -
  say "  наши строки удалены"
else
  say "  наших строк не было"
fi

if [ "$WITH_UFW" = "1" ]; then
  step "файрвол"
  ufw delete allow 443/tcp >/dev/null 2>&1 && say "  443/tcp закрыт (22/tcp на месте)"
  ufw delete allow 443/udp >/dev/null 2>&1 || true
fi

step "следы прошлых настроек"
for f in /root/xray-config-before-*.json; do
  [ -e "$f" ] && rm -f "$f" && say "  удалён: $(basename "$f")"
done
for f in /root/nodes.txt.bak-*; do
  [ -e "$f" ] && rm -f "$f" && say "  удалён: $(basename "$f")"
done

step "итог"
for s in xray vpn-quota.timer vpn-traffic-log.service singbox-h2.service; do
  printf '  %-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
done
say "  слушателей на 443: $(ss -lntp 2>/dev/null | grep -c ':443')"

rm -f /usr/local/bin/ratnet-cleanup.sh

echo
say "ГОТОВО. Бэкап: $TAR"
say "Откат: tar -xzf $TAR -C / && systemctl daemon-reload"
