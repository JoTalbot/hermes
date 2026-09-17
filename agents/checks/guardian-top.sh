#!/usr/bin/env bash
# "Что грузит сервер?" — кто именно занимает CPU, память и swap прямо сейчас.
# Read-only. Отвечает на вопрос, а не печатает дамп: имя, проценты, вердикт и что делать.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🔥 ЧТО ГРУЗИТ СЕРВЕР"

CORES=$(nproc)
read -r LOAD1 LOAD5 LOAD15 < /proc/loadavg
read -r RUNNING TOTALP < <(awk '{split($4,a,"/"); print a[1], a[2]}' /proc/loadavg)
RATIO=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%.1f", l/c}')

report_section "📈 ОБЩАЯ КАРТИНА"
report_kv "load 1/5/15" "$LOAD1 / $LOAD5 / $LOAD15 при $CORES ядрах"
report_kv "процессов" "$TOTALP всего, в работе $RUNNING"
report_kv "cpu за секунду" "$(vmstat 2 2 2>/dev/null | tail -1 | awk '{printf "user=%s%% sys=%s%% iowait=%s%% idle=%s%%", $13, $14, $16, $15}')"
SW_T=$(free -m | awk '/Swap:/{print $2}'); SW_U=$(free -m | awk '/Swap:/{print $3}')
if [[ "${SW_U:-0}" -gt 200 ]]; then report_warn "swap занят ${SW_U}Mi из ${SW_T}Mi — признак нехватки памяти"
else report_ok "swap ${SW_U}Mi из ${SW_T}Mi"; fi
if num_gt "$LOAD1" "$CORES"; then report_warn "нагрузка выше числа ядер в ${RATIO}× — процессы ждут CPU"
else report_ok "нагрузка в пределах числа ядер (${RATIO}×)"; fi

report_section "🔥 КТО ЕСТ CPU ПРЯМО СЕЙЧАС (интервал 1 с)"
# Два замера top: первый — с момента загрузки, второй — за прошедшую секунду. Именно
# второй отвечает на вопрос «что грузит сейчас» и не зависит от времени жизни процесса.
SNAP=$(top -bn2 -d 1 2>/dev/null | awk '/^ *PID/{n++} n==2' | sed -n '2,9p')
if [[ -n "$SNAP" ]]; then
  # Память берём из /proc/<pid>/status: в машинном формате top колонка RES у части
  # процессов читается как 0, а VmRSS всегда достоверен.
  echo "$SNAP" | awk '{ printf "%s|%s|%s\n", $1, $9, $12 }' | while IFS='|' read -r pid cpu comm; do
    rss=$(awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/$pid/status" 2>/dev/null)
    printf '  %6s%%  %6s MiB  %s\n' "$cpu" "${rss:-?}" "$comm"
  done
else
  # busybox/минимальные образы без top — падаем на средние значения ps
  ps -eo pcpu,rss,comm --sort=-pcpu --no-headers 2>/dev/null | head -8 | \
    awk '{ printf "  %5.1f%%* %6.0f MiB  %s\n", $1, $2/1024, $3 } END{print "  (* среднее за время жизни процесса)"}'
fi

report_section "🧠 ТОП ПО ПАМЯТИ"
ps -eo rss,pmem,comm --sort=-rss --no-headers 2>/dev/null | head -6 | \
  awk '{ printf "  %6.0f MiB  %4.1f%%  %s\n", $1/1024, $2, $3 }'

report_section "🧩 КТО ЭТО (по группам)"
read -r HERMES OTHER < <(ps -eo pcpu=,args= 2>/dev/null | awk '
  { if ($0 ~ /hermes|nats|bus_bridge/) h+=$1; else o+=$1 } END { printf "%.1f %.1f", h, o }')
report_kv "Hermes (шина, агенты)" "${HERMES}% CPU"
report_kv "прочие проекты" "${OTHER}% CPU"
report_kv "занято ядер" "$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%.0f%%", 100*l/c}')"

# «Первым в списке» не должен оказаться наш собственный ps/awk: он попадает в замер,
# потому что работает в момент замера. Инструменты измерения исключаем явно.
TOP_COMM=$(ps -eo pcpu,comm --sort=-pcpu --no-headers 2>/dev/null | \
  awk '$2 !~ /^(ps|top|awk|sed|head|bash|sh|grep|free|vmstat|date|hostname)$/ {print $2; exit}')
ACTIONS=()
if num_gt "$LOAD1" "$CORES"; then
  ACTIONS+=("нагрузка выше нормы: первым в списке идёт «${TOP_COMM}» — с него и начинать")
  ACTIONS+=("если это контейнер чужого проекта: docker stats --no-stream | head -5")
fi
[[ "${SW_U:-0}" -gt 500 ]] && ACTIONS+=("swap почти полон — это про нехватку памяти, а не CPU")
ACTIONS+=("полный отчёт по узлу: напиши «состояние сервера»")
report_footer "${ACTIONS[@]}"
