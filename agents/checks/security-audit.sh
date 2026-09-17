#!/usr/bin/env bash
# Аудит безопасности: периметр, права секретов, обновления, утечки в git. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🔐 АУДИТ БЕЗОПАСНОСТИ"

report_section "🌍 ПЕРИМЕТР"
WORLD=$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -cE '^(0\.0\.0\.0|\*|\[::\]):')
LOCAL=$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -cE '^127\.0\.0\.1:')
report_kv "портов наружу" "$WORLD"
report_kv "только локально" "$LOCAL"
ss -lntH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | sed 's/.*://' | sort -n -u | paste -sd' ' - | fold -s -w 88 | sed 's/^/  /'
if command -v ufw >/dev/null; then ufw status 2>/dev/null | head -1 | sed 's/^/  /'; else report_warn "ufw не найден"; fi

report_section "🔑 СЕКРЕТЫ"
BAD=0
for f in /etc/hermes/*.env /etc/hermes/*password* /etc/hermes/*credential*; do
  [[ -f "$f" ]] || continue
  P=$(stat -c '%a' "$f")
  case "$P" in 600|640|400) printf '  ✅ %-34s %s\n' "$(basename "$f")" "$P" ;;
    *) printf '  🔴 %-34s %s — доступен лишним\n' "$(basename "$f")" "$P"; BAD=$((BAD+1)) ;; esac
done
[[ "$BAD" -eq 0 ]] && report_ok "права на секретах корректные (0600)" || report_bad "$BAD файл(ов) с неверными правами"

report_section "🧾 УТЕЧКИ В GIT"
cd /opt/hermes 2>/dev/null && {
  R=$(bash scripts/secret-scan.sh --worktree 2>&1 | tail -1)
  [[ "$R" == *clean* ]] && report_ok "секретов в рабочем дереве нет" || report_bad "$R"
}

report_section "⬆️ ОБНОВЛЕНИЯ"
UPD=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
report_kv "пакетов к обновлению" "${UPD:-0}"
[[ -f /var/run/reboot-required ]] && report_warn "требуется перезагрузка" || report_ok "перезагрузка не требуется"

report_section "🛡 SSH"
SSHD=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2} /^passwordauthentication/{print "password="$2}')
[[ -n "$SSHD" ]] && echo "$SSHD" | sed 's/^/  /' || report_info "параметры sshd недоступны без прав"

ACTIONS=()
[[ "$WORLD" -gt 12 ]] && ACTIONS+=("проверить внешние порты по списку выше: каждый должен быть обоснован")
[[ "$BAD" -gt 0 ]] && ACTIONS+=("исправить права: chmod 600 <файл>")
ACTIONS+=("детально по портам: напиши «кто слушает порты»")
report_footer "${ACTIONS[@]}"
