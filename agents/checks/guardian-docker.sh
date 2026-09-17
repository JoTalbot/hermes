#!/usr/bin/env bash
# Контейнеры: что работает, что упало, что перезапускается. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🐳 КОНТЕЙНЕРЫ"

if ! command -v docker >/dev/null; then report_warn "docker не установлен"; exit 0; fi
UP=$(docker ps -q 2>/dev/null | wc -l); ALL=$(docker ps -aq 2>/dev/null | wc -l)
EXITED=$(docker ps -aq --filter status=exited 2>/dev/null | wc -l)
UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)

report_section "📊 ИТОГ"
report_kv "запущено" "$UP из $ALL"
if [[ "$EXITED" -gt 0 ]]; then report_warn "остановлено: $EXITED"; else report_ok "остановленных нет"; fi
[[ -n "$UNHEALTHY" ]] && report_bad "unhealthy: $UNHEALTHY" || report_ok "unhealthy: нет"

report_section "🐳 ЗАПУЩЕННЫЕ"
docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null | head -12 | \
  awk -F'|' '{ printf "  ✅ %-34s %s\n", $1, $2 }'

if [[ "$EXITED" -gt 0 ]]; then
  report_section "⛔ ОСТАНОВЛЕННЫЕ"
  docker ps -a --filter status=exited --format '{{.Names}}|{{.Status}}' 2>/dev/null | head -8 | \
    awk -F'|' '{ printf "  ⛔ %-34s %s\n", $1, $2 }'
fi

RESTARTING=$(docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -i restart | awk '{print $1}')
[[ -n "$RESTARTING" ]] && report_section "♻️ ПЕРЕЗАПУСКАЮТСЯ" && echo "$RESTARTING" | sed 's/^/  ♻️ /'

report_section "💾 МЕСТО ПОД ОБРАЗЫ"
docker system df 2>/dev/null | sed 's/^/  /'

ACTIONS=()
[[ "$EXITED" -gt 0 ]] && ACTIONS+=("посмотреть причину остановленного: docker logs <имя> --tail 40")
[[ -n "$UNHEALTHY" ]] && ACTIONS+=("unhealthy-контейнер: docker inspect --format '{{json .State.Health}}' <имя>")
ACTIONS+=("детали по узлу: напиши «проверить сервер»")
report_footer "${ACTIONS[@]}"
