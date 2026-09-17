#!/usr/bin/env bash
# Какие порты слушают и как они выставлены наружу. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🔐 СЕТЬ И ПОРТЫ"

report_section "🌍 СЛУШАЮТ НАРУЖУ (0.0.0.0 / ::)"
ss -lntH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | \
  sed 's/.*://' | sort -n -u | awk '{printf "  %s\n", $1}' | head -25
COUNT_WORLD=$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -cE '^(0\.0\.0\.0|\*|\[::\]):')

report_section "🏠 ТОЛЬКО ЛОКАЛЬНО (127.0.0.1)"
ss -lntH 2>/dev/null | awk '{print $4}' | grep -E '^127\.0\.0\.1:' | sed 's/.*://' | sort -n -u | \
  paste -sd' ' - | fold -s -w 90 | sed 's/^/  /'

report_section "🛡 ФАЕРВОЛ"
if command -v ufw >/dev/null; then
  ufw status 2>/dev/null | head -1 | sed 's/^/  /'
  ufw status 2>/dev/null | awk '/^[0-9]/ || /ALLOW|DENY/ {printf "  %s\n", $0}' | head -12
else report_warn "ufw не найден"; fi

report_section "📊 ИТОГ"
report_kv "портов наружу" "$COUNT_WORLD"
if [[ "$COUNT_WORLD" -le 12 ]]; then report_ok "их немного — поверхность атаки узкая"; else report_warn "многовато открытых портов"; fi

ACTIONS=()
[[ "$COUNT_WORLD" -gt 12 ]] && ACTIONS+=("проверить каждый внешний порт: нужен ли он вообще (ufw deny <порт>)")
ACTIONS+=("полный аудит безопасности: напиши «аудит безопасности»")
report_footer "${ACTIONS[@]}"
