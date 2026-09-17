#!/usr/bin/env bash
# Обновления безопасности и необходимость перезагрузки. Read-only (без установки).
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "⬆️ ОБНОВЛЕНИЯ СИСТЕМЫ"

report_section "📦 ДОСТУПНЫЕ ОБНОВЛЕНИЯ"
LIST=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
report_kv "пакетов" "${LIST:-0}"
apt list --upgradable 2>/dev/null | grep -E 'security' | head -5 | sed 's/^/  🔐 /'
[[ "${LIST:-0}" -eq 0 ]] && report_ok "все пакеты актуальны"

report_section "🕐 АКТУАЛЬНОСТЬ ИНДЕКСА"
LAST=$(stat -c '%y' /var/lib/apt/periodic/update-success-stamp 2>/dev/null | cut -d. -f1)
report_kv "последний update" "${LAST:-неизвестно}"

report_section "🔁 ПЕРЕЗАГРУЗКА"
[[ -f /var/run/reboot-required ]] && report_warn "требуется перезагрузка: $(cat /var/run/reboot-required 2>/dev/null)" || report_ok "перезагрузка не требуется"

ACTIONS=()
[[ "${LIST:-0}" -gt 0 ]] && ACTIONS+=("обновить: apt-get update && apt-get upgrade -y (согласовать окно)")
ACTIONS+=("ядро обновлено — планировать перезагрузку")
report_footer "${ACTIONS[@]}"
