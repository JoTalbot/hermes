#!/usr/bin/env bash
# Полное состояние узла: ресурсы, юниты, docker, свежие ошибки. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🖥 СОСТОЯНИЕ УЗЛА"

read -r LOAD1 < <(awk '{print $1}' /proc/loadavg); CORES=$(nproc)
read -r TOTAL USED AVAIL < <(free -m | awk '/Mem:/{print $2, $3, $7}')
SW_T=$(free -m | awk '/Swap:/{print $2}'); SW_U=$(free -m | awk '/Swap:/{print $3}')
UP_S=$(cut -d. -f1 /proc/uptime)

report_section "📈 РЕСУРСЫ"
report_gauge "$(pct_of "$LOAD1" "$CORES")" "CPU (load $LOAD1 из $CORES)"
report_gauge "$(pct_of "$USED" "$TOTAL")" "RAM ($USED из ${TOTAL}Mi)"
report_gauge "$(pct_of "$SW_U" "$SW_T")" "SWAP ($SW_U из ${SW_T}Mi)"
for m in / /var /home; do
  [ -d "$m" ] || continue
  P=$(df -h "$m" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  [ -n "$P" ] && report_gauge "$P" "диск $m"
done
report_kv "uptime" "$(awk -v s="$UP_S" 'BEGIN{printf "%d дн %d ч", s/86400, (s%86400)/3600}')"

report_section "⚙️ ЮНИТЫ"
FAILED=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' | head -10)
if [[ -z "$FAILED" ]]; then report_ok "падавших юнитов нет"
else while read -r u; do [[ -n "$u" ]] && report_bad "$u"; done <<< "$FAILED"; fi
ACTIVE=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l)
report_kv "работающих сервисов" "$ACTIVE"

report_section "🧩 СТЕК HERMES"
for u in hermes-env-guard hermes-shim hermes-serve hermes-gateway hermes-metrics \
         hermes-bus-bridge hermes-telegram-inbox hermes-agents nats-server; do
  ST=$(systemctl is-active "$u" 2>/dev/null)
  case "$ST" in
    active) printf '  ✅ %s\n' "$u" ;;
    inactive) printf '  ⚪️ %s (не запущен)\n' "$u" ;;
    *) printf '  🔴 %s (%s)\n' "$u" "$ST" ;;
  esac
done

report_section "🐳 КОНТЕЙНЕРЫ"
if command -v docker >/dev/null; then
  U=$(docker ps -q 2>/dev/null | wc -l); E=$(docker ps -aq --filter status=exited 2>/dev/null | wc -l)
  report_kv "запущено" "$U"
  [[ "$E" -gt 0 ]] && report_warn "остановлено: $E" || report_ok "остановленных нет"
else report_warn "docker не установлен"; fi

report_section "📜 ОШИБКИ ЗА ЧАС"
ERRC=$(journalctl -p err --since -1h --no-pager 2>/dev/null | wc -l)
report_kv "записей err" "$ERRC"
journalctl -p err --since -1h --no-pager -o short 2>/dev/null | tail -3 | cut -c1-120 | sed 's/^/  /'

ACTIONS=()
[[ -n "$FAILED" ]] && ACTIONS+=("разобрать упавшие юниты: journalctl -u <юнит> -n 50")
[[ "$E" -gt 0 ]] && ACTIONS+=("проверить остановленные контейнеры: docker ps -a")
[[ "$(pct_of "$SW_U" "$SW_T")" -ge 90 ]] && ACTIONS+=("swap почти полон — проверить память (напиши «память»)")
ACTIONS+=("детально по нагрузке: напиши «что грузит сервер»")
report_footer "${ACTIONS[@]}"
