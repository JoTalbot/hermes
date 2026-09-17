#!/usr/bin/env bash
# Права на файлы с секретами и их наличие. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🔑 СЕКРЕТЫ И ПРАВА"

report_section "📁 /etc/hermes"
if [[ -d /etc/hermes ]]; then
  PERM=$(stat -c '%a' /etc/hermes)
  [[ "$PERM" == "755" ]] && report_ok "/etc/hermes $PERM (как ожидается)" || report_warn "/etc/hermes $PERM (ожидается 755)"
  while read -r f; do
    P=$(stat -c '%a' "$f")
    case "$P" in
      600|640|400) report_ok "$(basename "$f") $P" ;;
      *) report_bad "$(basename "$f") $P — секрет доступен лишним" ;;
    esac
  done < <(find /etc/hermes -maxdepth 1 -type f \( -name '*.env' -o -name '*password*' -o -name '*credential*' \) 2>/dev/null | sort)
else report_warn "/etc/hermes отсутствует"; fi

report_section "🔎 ПОИСК ОТКРЫТЫХ СЕКРЕТОВ"
OPEN=$(find /etc/hermes /opt/hermes/config -maxdepth 2 -type f -perm /044 2>/dev/null | \
  grep -E '\.env$|password|credential|secret|token' | head -5)
[[ -z "$OPEN" ]] && report_ok "readable-for-others секретов не найдено" || echo "$OPEN" | sed 's/^/  🔴 /'

report_section "🧾 КЛЮЧИ И ТОКЕНЫ В GIT"
cd /opt/hermes 2>/dev/null && bash scripts/secret-scan.sh --worktree 2>/dev/null | sed 's/^/  /' | head -5

ACTIONS=("права чинить: chmod 600 <файл>, владелец root:root")
ACTIONS+=("скан истории репозитория: напиши «secret-scan»")
report_footer "${ACTIONS[@]}"
