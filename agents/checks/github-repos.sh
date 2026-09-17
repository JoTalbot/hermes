#!/usr/bin/env bash
# Состояние репозиториев: ветка, незакоммиченное, неотправленное. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🐙 РЕПОЗИТОРИИ"

TOTAL=0; DIRTY=0; UNPUSHED=0
report_section "📚 ГИТ-ДЕРЕВЬЯ"
for d in /opt/hermes /opt/logistics /opt/octopus /opt/aios /opt/orchestrator /opt/transcribe /root/logistics; do
  [[ -d "$d/.git" ]] || continue
  TOTAL=$((TOTAL+1))
  BR=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
  DIRT=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
  AHEAD=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  LAST=$(git -C "$d" log -1 --format='%h %ad %s' --date=short 2>/dev/null | cut -c1-70)
  MARK="✅"; [[ "$DIRT" -gt 0 || "$AHEAD" -gt 0 ]] && MARK="⚠️"
  [[ "$DIRT" -gt 0 ]] && DIRTY=$((DIRTY+1)); [[ "$AHEAD" -gt 0 ]] && UNPUSHED=$((UNPUSHED+1))
  printf '  %s %-22s %s  изм=%s  впереди=%s\n' "$MARK" "$(basename "$d")" "$BR" "$DIRT" "$AHEAD"
  printf '       последний: %s\n' "$LAST"
done
[[ "$TOTAL" -eq 0 ]] && report_empty

report_section "📊 ИТОГ"
report_kv "репозиториев" "$TOTAL"
[[ "$DIRTY" -eq 0 ]] && report_ok "незакоммиченного нет" || report_warn "с изменениями: $DIRTY"
[[ "$UNPUSHED" -eq 0 ]] && report_ok "всё отправлено" || report_warn "не отправлено: $UNPUSHED"

ACTIONS=()
[[ "$UNPUSHED" -gt 0 ]] && ACTIONS+=("отправить: git -C <каталог> push")
[[ "$DIRTY" -gt 0 ]] && ACTIONS+=("проверить изменения перед коммитом: git -C <каталог> diff")
ACTIONS+=("полный статус GitHub: напиши «состояние github»")
report_footer "${ACTIONS[@]}"
