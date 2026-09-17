#!/usr/bin/env bash
# Память, swap и кто её держит. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🧠 ПАМЯТЬ И SWAP"

read -r TOTAL USED AVAIL CACHE < <(free -m | awk '/Mem:/{print $2, $3, $7, $6}')
PCT=$(pct_of "$USED" "$TOTAL")
report_section "📊 ИТОГ"
report_gauge "$PCT" "RAM $USED из ${TOTAL}Mi"
report_kv "доступно" "${AVAIL}Mi (с кэшем ${CACHE}Mi)"
SW_T=$(free -m | awk '/Swap:/{print $2}'); SW_U=$(free -m | awk '/Swap:/{print $3}')
report_gauge "$(pct_of "$SW_U" "$SW_T")" "swap $SW_U из ${SW_T}Mi"

report_section "🐘 ТОП ПО ПАМЯТИ"
ps -eo rss,pmem,comm --sort=-rss --no-headers 2>/dev/null | head -8 | \
  awk '{ printf "  %6.0f MiB  %4.1f%%  %s\n", $1/1024, $2, $3 }'

report_section "🧩 ПО ГРУППАМ"
grep -c '' /dev/null 2>/dev/null || true
HERM=$(ps -eo rss=,args= 2>/dev/null | awk '$0 ~ /hermes|nats|bus_bridge/ {s+=$1} END{printf "%.1f", s/1024}')
OTH=$(ps -eo rss=,args= 2>/dev/null | awk '$0 !~ /hermes|nats|bus_bridge/ {s+=$1} END{printf "%.1f", s/1024}')
report_kv "Hermes MiB" "$HERM"
report_kv "прочие MiB" "$OTH"

ACTIONS=()
num_ge "$PCT" 90 && ACTIONS+=("память почти кончилась — проверить OOM: journalctl -k | grep -i oom")
num_ge "$(pct_of "$SW_U" "$SW_T")" 50 && ACTIONS+=("swap активно используется — это просадка производительности, искать утечку")
ACTIONS+=("кто именно растёт: ps -eo rss,pmem,args --sort=-rss | head")
report_proof "free -m · /proc/meminfo · ps -eo rss · docker stats --no-stream"
report_footer "${ACTIONS[@]}"
