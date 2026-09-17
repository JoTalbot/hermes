#!/usr/bin/env bash
# lookup.sh — «что там с <имя>»: имя ищется сразу во всех реестрах узла.
#
# Зачем: routing различает объект только когда в вопросе есть слово «контейнер/процесс/сервис».
# «Что там с octopus-multisync» уезжало в общий отчёт по узлу, хотя ответ про конкретный юнит.
# Здесь один вход: юнит systemd → контейнер → процесс → проект (конфиг агента) → порт → каталог,
# и в конце — последние записи журнала этого объекта. Каждое утверждение с доказательством.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
NAME="${ARG_NAME:-${ARG_TARGET:-}}"
report_header "🔎 ЧТО ТАКОЕ ${NAME:-?}"

if [[ -z "$NAME" ]]; then
  report_unknown "не назван объект"
  report_footer "пример: «что там с octopus-multisync»" \
                "можно назвать юнит, контейнер, процесс, проект, порт или каталог"
  exit 0
fi
ACCOUNT='^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$'
if [[ ! "$NAME" =~ $ACCOUNT ]]; then
  report_unknown "«$NAME» не похоже на имя объекта"
  report_footer "имена ищутся как есть: латиница, цифры, точка, дефис, подчёркивание"
  exit 0
fi

FOUND=0
UNIT="${NAME%.service}.service"

# ── 1. юнит systemd ────────────────────────────────────────────────────────────
if systemctl list-unit-files "$UNIT" --no-legend 2>/dev/null | grep -q .; then
  FOUND=1
  report_section "⚙️ ЮНИТ SYSTEMD"
  report_kv "юнит" "$UNIT"
  report_kv "состояние" "$(systemctl is-active "$UNIT" 2>/dev/null) / $(systemctl is-enabled "$UNIT" 2>/dev/null)"
  STAMP="$(systemctl show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null)"
  [[ -n "$STAMP" ]] && report_kv "активен с" "$STAMP"
  RESTARTS="$(systemctl show -p NRestarts --value "$UNIT" 2>/dev/null)"
  [[ -n "$RESTARTS" && "$RESTARTS" != "0" ]] && report_warn "перезапусков средствами systemd: $RESTARTS"
  report_kv "память" "$(systemctl show -p MemoryCurrent --value "$UNIT" 2>/dev/null | awk '{printf "%.0f MiB", $1/1048576}')"
  report_proof "systemctl show $UNIT -p ActiveState -p NRestarts -p MemoryCurrent"
  if [[ "$(systemctl is-active "$UNIT" 2>/dev/null)" != "active" ]]; then
    report_section "📜 ПОСЛЕДНИЕ СТРОКИ"
    journalctl -u "$UNIT" -n 6 --no-pager -o cat 2>/dev/null | cut -c1-130 | sed 's/^/  /'
  fi
fi

# ── 2. контейнер docker ────────────────────────────────────────────────────────
if command -v docker >/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  FOUND=1
  report_section "🐳 КОНТЕЙНЕР"
  docker ps -a --filter "name=^${NAME}$" --format '  {{.Names}} · {{.Status}} · {{.Image}}' 2>/dev/null | head -2
  report_kv "образ" "$(docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null)"
  report_kv "создан" "$(docker inspect -f '{{.Created}}' "$NAME" 2>/dev/null | cut -c1-19)"
  REST="$(docker inspect -f '{{.RestartCount}}' "$NAME" 2>/dev/null)"
  [[ -n "$REST" && "$REST" != "0" ]] && report_warn "контейнер перезапускался: $REST раз"
  LIM="$(docker inspect -f '{{.HostConfig.Memory}}' "$NAME" 2>/dev/null)"
  [[ -n "$LIM" && "$LIM" != "0" ]] && report_kv "лимит памяти" "$(awk -v m="$LIM" 'BEGIN{printf "%.0f GiB", m/1073741824}')" \
    || report_warn "лимит памяти не задан — контейнер может съесть узел"
  docker stats --no-stream --format '  {{.Name}}: CPU {{.CPUPerc}}, MEM {{.MemUsage}}' "$NAME" 2>/dev/null
  report_proof "docker inspect $NAME · docker stats --no-stream $NAME"
  if [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]]; then
    report_section "📜 ПОСЛЕДНИЕ СТРОКИ"
    docker logs --tail 6 "$NAME" 2>&1 | cut -c1-130 | sed 's/^/  /'
  fi
fi

# ── 3. процесс ────────────────────────────────────────────────────────────────
# FACT (2026-09-17): `pgrep -f <имя>` находил сам процесс проверки — его командная строка
# тоже содержит искомое имя, поэтому «объекта нет» превращалось в «процесс найден» (пустой).
# Свои процессы фильтруются по /proc/<pid>/cmdline, а заголовок печатается только когда
# под ним действительно есть строки.
# Цепочка своих родителей: вызывающая команда тоже содержит искомое имя (например, текст
# «покажи что там с octopus-browser» в командной строке оболочки). Ищем её вверх по PPid.
declare -A ANC=()
_p=$$
while [[ -n "$_p" && "$_p" != "1" && "$_p" != "0" ]]; do
  ANC[$_p]=1
  _p="$(awk '{print $4}' "/proc/$_p/stat" 2>/dev/null)"
done
PLIST=""
while read -r pid; do
  [[ -n "$pid" ]] || continue
  [[ -n "${ANC[$pid]:-}" ]] && continue
  CARGS="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  case "$CARGS" in *lookup.sh*|*"pgrep -f"*|*tests/run.sh*|*"runtime.py invoke"*) continue ;; esac
  PLIST+=" $pid"
done < <(pgrep -f -- "$NAME" 2>/dev/null | head -10)
PLIST="${PLIST# }"; PLIST="${PLIST// /,}"
if [[ -n "$PLIST" ]]; then
  ROWS="$(ps -o pid,ppid,%cpu,%mem,rss,etime,args -p "$PLIST" 2>/dev/null | tail -n +2)"
  if [[ -n "$ROWS" ]]; then
    FOUND=1
    report_section "🔥 ПРОЦЕСС"
    printf '%s\n' "$ROWS" | awk '{printf "  %-7s %-7s %5s%% %5s%% %6.0f MiB %10s %s\n", $1,$2,$3,$4,$5/1024,$6,substr($0, index($0,$7), 70)}'
    report_proof "pgrep -f $NAME · ps -o pid,%cpu,%mem,rss,etime,args"
  fi
fi

# ── 4. проект (конфиг агента) ─────────────────────────────────────────────────
for f in /opt/hermes/config/agents/projects/*.yaml; do
  [[ -f "$f" ]] || continue
  slug="$(basename "$f" .yaml)"
  case "$slug" in "$NAME"|"proj-$NAME") ;; *) continue ;; esac
  FOUND=1
  report_section "📦 ПРОЕКТ"
  report_kv "агент" "proj-$slug"
  report_kv "путь" "$(grep -E 'local_path:' "$f" | head -1 | sed 's/.*local_path: *//; s/["'"'"']//g')"
  report_kv "репозиторий" "$(grep -E 'repo:' "$f" | head -1 | sed 's/.*repo: *//; s/["'"'"']//g')"
  report_proof "cat $f"
  report_footer "статус проекта: «статус проекта $slug»" "запустить тесты: «прогони тесты в $slug»"
done

# ── 5. порт или каталог ───────────────────────────────────────────────────────
if [[ "$NAME" =~ ^[0-9]{2,5}$ ]]; then
  LISTEN="$(ss -lntup 2>/dev/null | grep -E "[:.]$NAME[[:space:]]" | head -3)"
  if [[ -n "$LISTEN" ]]; then
    FOUND=1
    report_section "🔌 ПОРТ $NAME"
    printf '%s\n' "$LISTEN" | cut -c1-120 | sed 's/^/  /'
    report_proof "ss -lntup | grep :$NAME"
  fi
fi
if [[ -d "/opt/$NAME" || -d "/home/ubuntu/$NAME" ]]; then
  FOUND=1
  DIR="/opt/$NAME"; [[ -d "$DIR" ]] || DIR="/home/ubuntu/$NAME"
  report_section "📁 КАТАЛОГ"
  report_kv "путь" "$DIR"
  report_kv "размер / занято" "$(du -sh "$DIR" 2>/dev/null | awk '{print $1}') · $(find "$DIR" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l) объектов верхнего уровня"
  report_proof "du -sh $DIR"
fi

# ── 6. журнал объекта ────────────────────────────────────────────────────────
JFILE=/opt/hermes/memory/projects/node/JOURNAL.md
[[ -s "/opt/hermes/memory/projects/$NAME/JOURNAL.md" ]] && JFILE="/opt/hermes/memory/projects/$NAME/JOURNAL.md"
if [[ -s "$JFILE" ]]; then
  LAST="$(grep -E '^- ' "$JFILE" 2>/dev/null | tail -3)"
  if [[ -n "$LAST" ]]; then
    report_section "📌 ЧТО БЫЛО С ЭТИМ РАНЬШЕ"
    printf '%s\n' "$LAST" | cut -c1-140 | sed 's/^/  /'
    report_proof "tail -3 $JFILE"
  fi
fi

if [[ $FOUND -eq 0 ]]; then
  report_unknown "на узле нет ничего с именем «$NAME»: ни юнита, ни контейнера, ни процесса"
  report_unknown "ни проекта, ни каталога /opt/$NAME"
  report_proof "systemctl list-unit-files · docker ps -a · pgrep -f · ls /opt /home/ubuntu"
  report_footer "проверить имя: «статус сервера» покажет юниты и контейнеры целиком" \
                "если это проект с GitHub без копии на узле: его агент отвечает «клонировать по запросу»"
  exit 0
fi

report_section "📈 ИТОГ"
report_ok "объект «$NAME» найден — подробности выше"
report_footer "действие над ним: «перезапусти сервис $NAME» или «перезапусти контейнер $NAME»" \
              "ошибки по нему: «что делали агенты» покажет падения обработчиков"
