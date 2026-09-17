#!/usr/bin/env bash
# Сервисы: что работает, что падало, сколько раз перезапускалось. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "⚙️ СЕРВИСЫ"

report_section "🔴 ПАДАВШИЕ"
FAILED=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$')
if [[ -z "$FAILED" ]]; then report_ok "падавших нет"
else
  while read -r u; do
    [[ -z "$u" ]] && continue
    CODE=$(systemctl show -p ExecMainStatus --value "$u" 2>/dev/null)
    N=$(systemctl show -p NRestarts --value "$u" 2>/dev/null)
    report_bad "$u — код $CODE, перезапусков $N"
  done <<< "$FAILED"
fi

report_section "📊 САМЫЕ ПЕРЕЗАПУСКАЕМЫЕ (топ-5)"
systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | \
while read -r u; do
  N=$(systemctl show -p NRestarts --value "$u" 2>/dev/null)
  [[ -n "$N" && "$N" != "0" ]] && echo "$N $u"
done | sort -rn | head -5 | awk '{printf "  ♻️ %-38s %s перезапусков\n", $2, $1}'
[[ -z "$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | head -1)" ]] && report_empty

report_section "🧩 КЛЮЧЕВЫЕ (последние 15)"
systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | \
  awk '{print $1}' | head -15 | sed 's/^/  ✅ /'

report_section "⏱ ТАЙМЕРЫ"
systemctl list-timers --no-pager 2>/dev/null | head -6 | tail -5 | awk '{printf "  %-34s %s %s %s\n", $NF, $1, $2, $3}'

ACTIONS=("тревожный юнит: systemctl status <юнит> && journalctl -u <юнит> -n 50")
ACTIONS+=("много перезапусков = цикл падений: искать причину, а не перезапускать")
report_footer "${ACTIONS[@]}"
