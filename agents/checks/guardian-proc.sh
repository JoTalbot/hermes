#!/usr/bin/env bash
# «Что с процессом chromium?» — конкретный процесс: CPU, память, потоки, дети, порты,
# контейнер, в котором он живёт, и упоминания в журнале. Read-only.
# Имя приходит из задачи: ARG_SUBJECT (см. agents/routing.py -> subject()).
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
NAME="${ARG_SUBJECT:-}"
[[ -z "$NAME" ]] && NAME="${ARG_NAME:-}"

if [[ -z "$NAME" ]]; then
  report_header "🔎 ПРОЦЕСС"
  report_warn "не понял, о каком процессе речь"
  report_info "пример: «что с процессом chromium»"
  # без имени показываем самые тяжёлые — это тоже полезный ответ
  report_section "🔥 САМЫЕ ТЯЖЁЛЫЕ ПРОЦЕССЫ"
  ps -eo pcpu,pmem,rss,comm --sort=-pcpu --no-headers 2>/dev/null | head -6 | \
    awk '{printf "  %5.1f%%  %5.1f%%  %6.0fMiB  %s\n", $1, $2, $3/1024, $4}'
  report_footer "назвать процесс точно: «что с процессом <имя>»"
  exit 0
fi

report_header "🔎 ПРОЦЕСС ${NAME}"

# Одна строка с разделителями: `read` раскладывает остаток в ПОСЛЕДНЮЮ переменную, поэтому
# список пидов нельзя отдавать как несколько слов (иначе THREADS получал все пиды сразу).
SUMMARY=$(ps -eo pid,pcpu,rss,nlwp,comm,args --no-headers 2>/dev/null | \
  awk -v n="$NAME" 'index($5, n) || index($6, n) || index($0, n) {cpu+=$2; rss+=$3; th+=$4; pids=pids" "$1; c++}
                    END {gsub(/^ /,"",pids); printf "%s|%.1f|%.0f|%d|%d", pids, cpu, rss, th, c}')
IFS='|' read -r PIDS CPU RSS THREADS COUNT <<< "$SUMMARY"

if [[ -z "${PIDS// /}" ]]; then
  report_bad "процессов с именем «${NAME}» не найдено"
  report_section "🔤 ПОХОЖИЕ"
  ps -eo comm --no-headers 2>/dev/null | sort -u | grep -i "${NAME:0:4}" | head -6 | sed 's/^/  • /' || report_empty
  report_footer "проверить имя: ps -eo comm | sort -u | less" "если это контейнер: «статус контейнеров»"
  exit 0
fi

report_section "📊 СВОДКА"
report_kv "процессов с этим именем" "$COUNT"
report_kv "суммарно CPU" "${CPU}% (при $(nproc) ядрах)"
report_kv "память суммарно" "$(awk -v r="$RSS" 'BEGIN{printf "%.0f MiB (%.1f GiB)", r/1024, r/1048576}')"
report_kv "потоков" "$THREADS"

report_section "🧩 ЭКЗЕМПЛЯРЫ (топ по CPU)"
ps -eo pid,ppid,pcpu,pmem,rss,etime,nlwp,args --sort=-pcpu --no-headers 2>/dev/null | \
  awk -v n="$NAME" 'index($8, n) || index($0, n)' | head -6 | \
  awk '{ printf "  pid %-7s cpu %5s%%  mem %5s%%  %6.0fMiB  живёт %-10s потоков %s\n", $1, $3, $4, $5/1024, $6, $7 }'

report_section "👪 ДЕТИ (если это родитель)"
FOUND_KIDS=0
for p in ${PIDS}; do
  KIDS=$(ps --ppid "$p" --no-headers 2>/dev/null | awk '{print $1}' | head -5 | paste -sd' ' -)
  if [[ -n "$KIDS" ]]; then printf '  pid %s → дети: %s\n' "$p" "$KIDS"; FOUND_KIDS=1; fi
done
[[ "$FOUND_KIDS" -eq 0 ]] && report_info "дочерних процессов нет"

report_section "🌐 ПОРТЫ, ОТКРЫТЫЕ ЭТИМИ ПИДАМИ"
PORTS=""
for p in ${PIDS}; do
  S=$(ss -lntp 2>/dev/null | grep "pid=$p," | awk '{print $4}' | sed 's/.*://' | sort -u | paste -sd' ' -)
  [[ -n "$S" ]] && PORTS="$PORTS $S"
done
[[ -n "$PORTS" ]] && echo "$PORTS" | tr ' ' '\n' | grep -v '^$' | sort -un | paste -sd' ' - | sed 's/^/  /' || report_info "портов не слушает"

report_section "🐳 КОНТЕЙНЕР"
CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "${NAME}" | head -3)
if [[ -n "$CONT" ]]; then
  for c in $CONT; do
    docker ps --filter "name=^${c}$" --format '  ✅ {{.Names}} — {{.Status}}' 2>/dev/null
    docker stats --no-stream --format '     CPU {{.CPUPerc}} · MEM {{.MemUsage}} · PIDS {{.PIDs}}' "$c" 2>/dev/null | head -1
  done
else
  report_info "процесс запущен не в контейнере (или контейнер назван иначе)"
fi

report_section "📜 ЧТО ПИШЕТ В ЖУРНАЛ"
# Свои же строки не считаем: задача, в которой встречается имя процесса, попадает в журнал
# агентов и создавала впечатление, что процесс «пишет ошибки».
JL=$(journalctl --since -1h --no-pager -o short 2>/dev/null | grep -iw "$NAME" | \
     grep -viE "hermes-agents|bus-bridge|bus_bridge|telegram-inbox|sudo\[|sudo:|hermes-bus" | tail -6)
if [[ -n "$JL" ]]; then echo "$JL" | cut -c1-130 | sed 's/^/  /'
else report_info "за час упоминаний нет (кроме собственных задач агентов)"; fi

TOP_CPU=$(awk -v c="$CPU" 'BEGIN{printf "%.1f", c}')
ACTIONS=()
if num_gt "$TOP_CPU" "$(awk -v n="$(nproc)" 'BEGIN{printf "%.0f", n*50}')"; then
  ACTIONS+=("${NAME} занимает ${CPU}% CPU — это больше половины машины: решить, нужен ли он в таком объёме")
  ACTIONS+=("прижать по CPU: systemctl set-property <юнит> CPUQuota=200% (или ограничить контейнер)")
fi
if num_gt "$(awk -v r="$RSS" 'BEGIN{printf "%.0f", r/1024}')" 2000; then
  ACTIONS+=("память ${NAME}: $(awk -v r="$RSS" 'BEGIN{printf "%.1f GiB", r/1048576}') — проверить утечку: ps -o rss= -p ${PIDS%% *} в динамике")
fi
ACTIONS+=("подробный разбор с рекомендацией: «почему ${NAME} грузит сервер»")
report_footer "${ACTIONS[@]}"
