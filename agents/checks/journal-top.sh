#!/usr/bin/env bash
# journal-top.sh — кто пишет в системный журнал больше всех.
#
# FACT (2026-09-17): журнал занимал 1.0 GiB при заданном SystemMaxUse=500M, то есть ротация
# не успевала за писателями. Наши юниты под logrotate, соседские — нет; прежде чем ставить
# им правила (чужой проект — только с согласия владельца), нужно назвать виновника числом.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
HOURS="${ARG_HOURS:-24}"
report_header "📝 КТО ПИШЕТ В ЖУРНАЛ (${HOURS} ч)"

TOTAL="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?' | head -1)"
report_section "📦 ОБЪЁМ"
report_kv "журнал занимает" "${TOTAL:-неизвестно}"
report_kv "потолок (SystemMaxUse)" "$(grep -E '^SystemMaxUse' /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2 || echo 'по умолчанию')"
report_proof "journalctl --disk-usage · grep SystemMaxUse /etc/systemd/journald.conf"

report_section "📝 ПО ЮНИТАМ ЗА ${HOURS} ч"
ROWS=""
while read -r unit; do
  [[ -z "$unit" ]] && continue
  # Считаем байты сами: у journalctl нет прямого «сколько занял юнит».
  bytes=$(journalctl -u "$unit" --since "-${HOURS} hours" --no-pager -o cat 2>/dev/null | wc -c)
  [[ "$bytes" -lt 1024 ]] && continue
  ROWS+="$(printf '%s\t%s\n' "$bytes" "$unit")"$'\n'
done < <(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | head -80)

if [[ -z "$ROWS" ]]; then
  report_empty
  report_info "за ${HOURS} ч ни один работающий юнит не написал заметного объёма"
else
  printf '%s' "$ROWS" | sort -rn | head -10 | while IFS=$'\t' read -r bytes unit; do
    printf '  %-42s %s\n' "$unit" "$(awk -v b="$bytes" 'BEGIN{ if (b>1048576) printf "%.1f MiB", b/1048576; else printf "%.0f KiB", b/1024 }')"
  done
  report_proof "journalctl -u <unit> --since -${HOURS}h | wc -c (по каждому работающему юниту)"
fi

report_section "📈 ИТОГ"
BIG="$(printf '%s' "$ROWS" | sort -rn | head -1 | cut -f2)"
if [[ -n "$BIG" ]]; then
  report_info "самый громкий: $BIG"
  report_info "если это чужой проект — правило ротации ставим только с согласия владельца проекта"
fi
report_footer "сжать журнал до 500 MiB: «почисти журнал» (управляемое действие)" \
              "наши журналы уже под logrotate: /etc/logrotate.d/hermes"
