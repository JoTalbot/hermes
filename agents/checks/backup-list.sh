#!/usr/bin/env bash
# Последние архивы, их свежесть и размер. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "💾 АРХИВЫ БЭКАПОВ"

DIR=/var/backups/hermes
if [[ ! -d "$DIR" ]]; then report_warn "каталога $DIR нет"; exit 0; fi

report_section "📦 ПОСЛЕДНИЕ АРХИВЫ"
ls -1t "$DIR"/*.tar.gz "$DIR"/*.tgz 2>/dev/null | head -6 | while read -r f; do
  printf '  %-38s %6s  %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(date -r "$f" -u '+%Y-%m-%d %H:%M')"
done
NEWEST=$(ls -1t "$DIR"/*.tar.gz "$DIR"/*.tgz 2>/dev/null | head -1)
[[ -z "$NEWEST" ]] && { report_warn "архивов не найдено"; exit 0; }

AGE_H=$(echo $(( ( $(date +%s) - $(stat -c %Y "$NEWEST") ) / 3600 )))
report_section "📊 СВЕЖЕСТЬ"
report_kv "последний архив" "$(basename "$NEWEST")"
report_kv "возраст" "$AGE_H ч"
if [[ "$AGE_H" -le 30 ]]; then report_ok "бэкап свежий (суточный график соблюдается)"; else report_warn "бэкап старше суток"; fi
report_kv "всего архивов" "$(ls -1 "$DIR" 2>/dev/null | wc -l)"

report_section "🗓 РАСПИСАНИЕ"
systemctl list-timers hermes-backup.timer --no-pager 2>/dev/null | head -2 | tail -1 | sed 's/^/  /'

ACTIONS=()
[[ "$AGE_H" -gt 30 ]] && ACTIONS+=("сделать бэкап сейчас: systemctl start hermes-backup.service")
ACTIONS+=("проверить целостность: напиши «целостность бэкапа»")
report_footer "${ACTIONS[@]}"
