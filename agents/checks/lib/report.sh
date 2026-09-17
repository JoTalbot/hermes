#!/usr/bin/env bash
# agents/checks/lib/report.sh — the one formatting convention for every agent report.
#
# Why: the owner reads these in Telegram, on a phone. A raw column dump is not an answer.
# Every check script sources this file and prints the same shape:
#
#   🖥 ЧТО ГРУЗИТ СЕРВЕР · arm-server-01 · 2026-09-17 04:12 UTC
#
#   🔥 ПРОЦЕССЫ
#     27.5%  chromium (renderer) — 4.5 GiB
#
#   📈 ИТОГ
#     load   11.65 / 8.46 / 7.28 при 4 ядрах
#     ⚠️ нагрузка выше нормы в 2.9×
#
#   💡 ЧТО ДЕЛАТЬ
#     • проверить octopus-browser — он даёт 183% CPU
#
# The scripts stay deterministic: the format is stable, the numbers are measured, and the
# 💡 line is a rule, not a guess. (For judgement the agent can escalate to `ask`.)
# shellcheck shell=bash

RST=""; BLD=""; if [[ -t 1 ]]; then RST=$'\033[0m'; BLD=$'\033[1m'; fi

_rep_node() { hostname 2>/dev/null || echo node; }

report_header() {                       # report_header "🖥 ЧТО ГРУЗИТ СЕРВЕР"
  printf '%s%s · %s · %s%s\n' "$BLD" "$1" "$(_rep_node)" "$(date -u +'%Y-%m-%d %H:%M UTC')" "$RST"
}

report_section() { printf '\n%s\n' "$1"; }

report_row() { printf '  %-7s %s\n' "$1" "$2"; }        # report_row "27%" "chromium — 4.5 GiB"

report_kv() { printf '  %-22s %s\n' "$1" "$2"; }

report_ok()   { printf '  ✅ %s\n' "$1"; }
report_warn() { printf '  ⚠️ %s\n' "$1"; }
report_bad()  { printf '  🔴 %s\n' "$1"; }
report_info() { printf '  • %s\n' "$1"; }

report_empty() { printf '  (нечего показать)\n'; }

# report_footer "проверить контейнер octopus-browser" "смотреть логи: journalctl -u X"
report_footer() {
  report_section "💡 ЧТО ДЕЛАТЬ"
  local a
  for a in "$@"; do [[ -n "$a" ]] && printf '  • %s\n' "$a"; done
}

# Short numeric helpers so every script agrees on thresholds.
pct_of() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print 0; else printf "%.0f", 100*a/b }'; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 > b+0) }'; }
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a+0 >= b+0) }'; }

# Percentage of used memory/disk with an emoji verdict: report_load_bar 64
report_gauge() {  # report_gauge <percent> <what>
  local p="$1" what="$2" v
  if   num_ge "$p" 90; then v="🔴"
  elif num_ge "$p" 75; then v="⚠️"
  else v="✅"; fi
  printf '  %s %-18s %s%%\n' "$v" "$what" "$p"
}

# ── доказательства ──────────────────────────────────────────────────────────────
# 2026-09-17: 14 проектных агентов печатали «дерево чистое / всё отправлено», не прочитав
# ни одного байта (git отказывал из-за чужого владельца каталога, а пустая строка читалась
# как «всё хорошо»). Поэтому у утверждения теперь может быть строка-источник: команда,
# которой это утверждение получено. Она едет в Telegram рядом с выводом и проверяется
# глазами за секунду.
report_proof() { printf '     ↳ доказательство: %s\n' "$1"; }

# «Посмотреть не удалось» — полноценный ответ, а не пустой отчёт.
report_unknown() { printf '  ❓ %s\n' "$1"; }
