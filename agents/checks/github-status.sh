#!/usr/bin/env bash
# GitHub: состояние репозитория Hermes, изменения, отправленное, сканер секретов. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🐙 GITHUB И РЕПОЗИТОРИЙ"

cd /opt/hermes 2>/dev/null || { report_bad "нет /opt/hermes"; exit 0; }
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
DIRT=$(git status --porcelain 2>/dev/null | wc -l)
AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
BEHIND=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)

report_section "📚 РЕПОЗИТОРИЙ hermes"
report_kv "ветка" "$BR"
[[ "$DIRT" -eq 0 ]] && report_ok "рабочее дерево чистое" || report_warn "изменений: $DIRT"
[[ "$AHEAD" -eq 0 ]] && report_ok "всё отправлено в origin" || report_warn "не отправлено коммитов: $AHEAD"
[[ "$BEHIND" -eq 0 ]] && report_ok "нет отставания от origin" || report_warn "отставание: $BEHIND коммитов (нужен pull)"

report_section "🕐 ПОСЛЕДНИЕ КОММИТЫ"
git log -5 --format='  %h %ad %s' --date=short 2>/dev/null | cut -c1-100

report_section "🔍 СКАНЕР СЕКРЕТОВ"
R=$(bash scripts/secret-scan.sh --worktree 2>&1 | tail -1)
[[ "$R" == *clean* ]] && report_ok "секретов не найдено (рабочее дерево)" || report_bad "$R"

report_section "📦 ДРУГИЕ РЕПОЗИТОРИИ"
for d in /opt/logistics /opt/octopus /opt/aios; do
  [[ -d "$d/.git" ]] || continue
  D=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
  A=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  printf '  %s %-22s изм=%s впереди=%s\n' "$([[ "$D" -eq 0 && "$A" -eq 0 ]] && echo ✅ || echo ⚠️)" "$(basename "$d")" "$D" "$A"
done

ACTIONS=()
[[ "$DIRT" -gt 0 ]] && ACTIONS+=("посмотреть изменения: git -C /opt/hermes diff --stat")
[[ "$AHEAD" -gt 0 ]] && ACTIONS+=("отправить: git -C /opt/hermes push origin $BR")
ACTIONS+=("подробно по всем репозиториям: напиши «репозитории»")
report_footer "${ACTIONS[@]}"
