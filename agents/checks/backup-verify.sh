#!/usr/bin/env bash
# Проверка последнего архива: целостность gzip, состав, размер. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "✅ ПРОВЕРКА АРХИВА"

DIR=/var/backups/hermes
NEW=$(ls -1t "$DIR"/*.tar.gz "$DIR"/*.tgz 2>/dev/null | head -1)
if [[ -z "$NEW" ]]; then
  report_bad "архивов в $DIR нет"
  report_footer "сделать бэкап: systemctl start hermes-backup.service"
  exit 0
fi

report_section "📦 АРХИВ"
report_kv "файл" "$(basename "$NEW")"
report_kv "размер" "$(du -h "$NEW" | cut -f1)"
report_kv "создан" "$(date -r "$NEW" -u '+%Y-%m-%d %H:%M UTC')"

report_section "🔍 ЦЕЛОСТНОСТЬ"
if gzip -t "$NEW" 2>/dev/null; then report_ok "gzip-поток целый"
else report_bad "архив повреждён — gzip -t не прошёл"; fi

CNT=$(tar tzf "$NEW" 2>/dev/null | wc -l)
report_kv "файлов внутри" "$CNT"
if [[ "$CNT" -gt 50 ]]; then report_ok "содержимое присутствует"
else report_warn "файлов подозрительно мало — проверить, что архивируется"; fi
tar tzf "$NEW" 2>/dev/null | grep -c 'config.yaml' | awk '{if ($1>0) print "  ✅ config.yaml внутри"; else print "  ⚠️ config.yaml не найден"}'
tar tzf "$NEW" 2>/dev/null | grep -c 'profiles/' | awk '{printf "  • файлов профилей: %s\n", $1}'

ACTIONS=()
[[ "$CNT" -le 50 ]] && ACTIONS+=("проверить, что таймер вообще собирает состояние: journalctl -u hermes-backup.service -n 30")
ACTIONS+=("репетиция восстановления: bash scripts/restore.sh <архив> --force --no-systemd в отдельном контейнере")
report_proof "tar -tzf <архив> · сравнение состава с ожидаемым списком каталогов"
report_footer "${ACTIONS[@]}"
