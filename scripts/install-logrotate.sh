#!/usr/bin/env bash
# scripts/install-logrotate.sh — журналы агентов должны ротироваться, сами по себе.
#
# FACT (2026-09-17): /var/lib/hermes-agents/logs — 23 файла и ни одного правила ротации.
# Каждый запуск проверки проектного агента пишет новый файл навсегда: при 21 проектном
# агенте и 151 обработчике это десятки файлов в сутки. Диск на узле кончится не сразу, а
# «внезапно», и вместе с ним перестанут писаться журналы — то есть агенты ослепнут именно
# тогда, когда понадобятся.
#
#   bash scripts/install-logrotate.sh           # поставить/обновить правило
#   bash scripts/install-logrotate.sh --check   # проверка (tests/doctor)
#   bash scripts/install-logrotate.sh --dry     # показать, что ротация сделает сейчас
set -uo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="$REPO_DIR/deploy/logrotate/hermes"
DST="/etc/logrotate.d/hermes"
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

log_dir_summary() {
  local d
  for d in /var/lib/hermes-agents/logs /var/lib/hermes-bus; do
    [[ -d "$d" ]] || continue
    printf '  %-28s %s файлов, %s\n' "$d" "$(find "$d" -maxdepth 1 -type f | wc -l)" \
           "$(du -sh "$d" 2>/dev/null | cut -f1)"
  done
}

case "${1:-}" in
  --check)
    echo "=== ротация журналов ==="
    FAILED=0
    if [[ -f "$DST" ]]; then ok "правило установлено: $DST"; else
      bad "нет $DST — журналы растут без границ"; FAILED=$((FAILED+1)); fi
    if command -v logrotate >/dev/null 2>&1; then
      if logrotate -d "$DST" >/tmp/logrotate-dry.out 2>&1; then
        ok "logrotate разбирает правило без ошибок"
      else
        bad "logrotate не принимает правило: $(tail -2 /tmp/logrotate-dry.out | head -1)"
        FAILED=$((FAILED+1))
      fi
    else
      warn "logrotate не установлен"
    fi
    log_dir_summary
    echo
    (( FAILED == 0 )) && { echo "LOGROTATE: OK"; exit 0; }
    echo "LOGROTATE: FAIL"; exit 1
    ;;

  --dry)
    logrotate -d "$DST" 2>&1 | tail -20
    ;;

  *)
    echo "=== 1. правило ротации ==="
    [[ -s "$SRC" ]] || { bad "нет $SRC в репозитории"; exit 1; }
    install -m 0644 -o root -g root "$SRC" "$DST"
    ok "установлено: $DST"
    echo
    echo "=== 2. проверка ==="
    if command -v logrotate >/dev/null 2>&1; then
      logrotate -d "$DST" >/tmp/logrotate-dry.out 2>&1 \
        && ok "logrotate принял правило" \
        || { bad "ошибка в правиле:"; tail -3 /tmp/logrotate-dry.out | sed 's/^/    /'; exit 1; }
    else
      warn "logrotate отсутствует (apt-get install -y logrotate)"
    fi
    echo
    echo "=== 3. сколько лежит сейчас ==="
    log_dir_summary
    echo
    echo "LOGROTATE: OK"
    ;;
esac
