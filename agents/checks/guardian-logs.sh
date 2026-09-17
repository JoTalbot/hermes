#!/usr/bin/env bash
# Ошибки в журнале: что сломалось, когда и в каком юните. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "📜 ОШИБКИ В ЖУРНАЛЕ (последний час)"

report_section "🔴 ПАДАВШИЕ ЮНИТЫ"
FAILED=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [[ -z "$FAILED" ]]; then report_ok "падавших юнитов нет"
else
  while read -r u; do
    [[ -z "$u" ]] && continue
    WHEN=$(systemctl show -p ExecMainExitTimestamp --value "$u" 2>/dev/null)
    CODE=$(systemctl show -p ExecMainStatus --value "$u" 2>/dev/null)
    report_bad "$u (код $CODE, $WHEN)"
  done <<< "$FAILED"
fi

report_section "🧾 ТОП ОШИБОК ПО ИСТОЧНИКАМ"
COUNT=$(journalctl -p err --since -1h --no-pager -o short 2>/dev/null | wc -l)
report_kv "записей уровня err" "$COUNT за час"
journalctl -p err --since -1h --no-pager -o short 2>/dev/null | \
  awk '{ for(i=5;i<=NF;i++){ if ($i ~ /^[a-z0-9_.-]+\[[0-9]+\]:$/ || $i ~ /^[a-z0-9_.-]+:$/) {print $i; break} } }' | \
  sed 's/:$//; s/\[.*\]//' | sort | uniq -c | sort -rn | head -6 | awk '{printf "  %4d  %s\n", $1, $2}'

report_section "🕐 ПОСЛЕДНИЕ 5"
journalctl -p err --since -1h --no-pager -o short 2>/dev/null | tail -5 | cut -c1-140 | sed 's/^/  /'
[[ -z "$(journalctl -p err --since -1h --no-pager -o short 2>/dev/null | tail -1)" ]] && report_empty

ACTIONS=()
[[ -n "$FAILED" ]] && ACTIONS+=("разобрать падающие юниты: journalctl -u <юнит> -n 50")
if num_gt "$COUNT" 50; then ACTIONS+=("много ошибок за час ($COUNT) — искать общий источник в списке выше"); fi
ACTIONS+=("ошибки Hermes-стека: напиши «статус hermes»")
report_footer "${ACTIONS[@]}"
