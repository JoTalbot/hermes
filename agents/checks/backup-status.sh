#!/usr/bin/env bash
# Бэкапы: свежесть, размер, расписание, проверка целостности. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "💾 БЭКАПЫ"

DIR=/var/backups/hermes
report_section "📦 АРХИВЫ"
if [[ -d "$DIR" ]]; then
  N=$(ls -1 "$DIR" 2>/dev/null | wc -l)
  report_kv "всего" "$N"
  ls -1t "$DIR"/*.tar.gz "$DIR"/*.tgz 2>/dev/null | head -4 | while read -r f; do
    printf '  📄 %-34s %6s  %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(date -r "$f" -u '+%m-%d %H:%M')"
  done
  NEW=$(ls -1t "$DIR"/*.tar.gz "$DIR"/*.tgz 2>/dev/null | head -1)
  if [[ -n "$NEW" ]]; then
    AGE=$(( ( $(date +%s) - $(stat -c %Y "$NEW") ) / 3600 ))
    report_section "📊 СВЕЖЕСТЬ"
    report_kv "возраст последнего" "${AGE} ч"
    [[ "$AGE" -le 30 ]] && report_ok "суточный график соблюдается" || report_warn "старше суток — проверить таймер"
  else report_warn "архивов нет"; fi
else report_bad "каталога $DIR нет"; fi

report_section "🗓 РАСПИСАНИЕ"
systemctl list-timers hermes-backup.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  /'
report_kv "служба" "$(systemctl is-active hermes-backup.service 2>/dev/null)"

report_section "✅ ПРОВЕРКА ПОСЛЕДНЕГО"
bash "$(dirname "${BASH_SOURCE[0]}")/backup-verify.sh" 2>/dev/null | tail -4 | sed 's/^/  /'

ACTIONS=("проверка выборочного восстановления: bash scripts/restore.sh <архив> --force (в контейнере)")
ACTIONS+=("сделать бэкап сейчас: systemctl start hermes-backup.service")
report_footer "${ACTIONS[@]}"
