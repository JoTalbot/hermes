#!/usr/bin/env bash
# repeats.sh — «падало три раза подряд по одной и той же причине?»
#
# Зачем (пункт 4 владельца, 2026-09-17): история прогонов писалась, но отвечать «эти тесты падали
# три раза по той же причине» система не умела — каждый разбор начинался с нуля. Здесь повторяемые
# отказы считаются по самой истории: агент + обработчик + код возврата + первая строка причины.
# С --write они же попадают в память (memory/incidents/REPEATS.md), чтобы следующий разбор начинался
# с истории, а не с чистого листа.
#
#   bash agents/checks/repeats.sh                 # отчёт по истории (7 дней по умолчанию)
#   ARG_DAYS=30 bash agents/checks/repeats.sh
#   ARG_WRITE=1 bash agents/checks/repeats.sh     # плюс запись в память (её делает таймер)
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
HIST="${HERMES_HISTORY_FILE:-/var/lib/hermes-agents/history.jsonl}"
DAYS="${ARG_DAYS:-7}"
WRITE="${ARG_WRITE:-0}"
MEM="${HERMES_REPEATS_MEMORY:-/opt/hermes/memory/incidents/REPEATS.md}"
report_header "🔁 ПОВТОРЯЮЩИЕСЯ СБОИ (${DAYS} дн)"

if [[ ! -s "$HIST" ]]; then
  report_section "📜 ИСТОРИЯ"
  report_unknown "истории прогонов нет: $HIST"
  report_footer "ИТОГ: повторяющихся сбоев 0 (истории нет)"
  exit 0
fi

HIST_FILE="$HIST" DAYS="$DAYS" MEM_FILE="$MEM" DO_WRITE="$WRITE" python3 - <<'PY'
import json, os, re, time
from collections import defaultdict

path = os.environ["HIST_FILE"]
days = int(os.environ.get("DAYS") or 7)
mem_path = os.environ["MEM_FILE"]
do_write = os.environ.get("DO_WRITE") == "1"
now = time.time()

def reason_of(r: dict) -> str:
    """Короткая подпись причины: код возврата + первая содержательная строка вывода."""
    code = r.get("code")
    line = ""
    for raw in str(r.get("summary") or "").splitlines():
        s = raw.strip()
        if len(s) > 3 and not s.startswith(("✅", "🟢", "📈", "ИТОГ")):
            line = s
            break
    line = re.sub(r"\d{4}-\d{2}-\d{2}[T ][\d:]+", "<время>", line)
    line = re.sub(r"\d+", "<n>", line)
    return (f"код {code}: {line[:90]}") if code not in (0, None) else line[:90]

groups: dict[tuple, dict] = defaultdict(lambda: {"n": 0, "last": 0, "first": "", "last_ts": ""})
total_fail = 0
rows = 0
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            rows += 1
            if now - int(r.get("epoch") or 0) > days * 86400:
                continue
            if r.get("handler") == "ask":
                continue
            code = r.get("code")
            ok = (code in (0, None)) and not r.get("fallback")
            if ok:
                continue
            total_fail += 1
            key = (str(r.get("agent") or "?"), str(r.get("handler") or "?"), reason_of(r))
            g = groups[key]
            g["n"] += 1
            g["last"] = int(r.get("epoch") or 0)
            g["last_ts"] = str(r.get("ts") or "")
            g["first"] = g["first"] or str(r.get("ts") or "")
except OSError as e:
    print(f"  ⚠️ история не читается: {e}")
    raise SystemExit(0)

repeat = {k: v for k, v in groups.items() if v["n"] >= 2}
hard = {k: v for k, v in groups.items() if v["n"] >= 3}

print("\n📜 ЧТО ПОВТОРЯЕТСЯ")
if not groups:
    print(f"  за {days} дн отказов нет (прогонов в истории: {rows})")
else:
    print(f"  прогонов {rows} · отказов {total_fail} · разных причин {len(groups)} · "
          f"повторяющихся {len(repeat)} (три и больше раз: {len(hard)})")
    for (agent, handler, reason), g in sorted(repeat.items(), key=lambda kv: -kv[1]["n"])[:8]:
        mark = "🔴" if g["n"] >= 3 else "⚠️"
        print(f"  {mark} {agent}/{handler} — {g['n']} раз(а) за {days} дн")
        print(f"      причина: {reason}")
        print(f"      ↳ первое: {g['first'][:19]} · последнее: {g['last_ts'][:19]}")
    if not repeat:
        print("  повторяющихся причин нет — каждый отказ был разовым")

if do_write and hard:
    os.makedirs(os.path.dirname(mem_path), exist_ok=True)
    # Штамп по неделе: таймер гоняет скрипт ежедневно, а запись в память должна быть одна.
    stamp = time.strftime("%Y-W%V", time.gmtime())
    today = time.strftime("%Y-%m-%d", time.gmtime())
    existing = ""
    if os.path.exists(mem_path):
        with open(mem_path, encoding="utf-8") as fh:
            existing = fh.read()
    if stamp in existing:
        print("\n  (в память ничего не добавлено: запись за это время уже есть)")
    else:
        block = []
        if not existing:
            block.append("# Повторяющиеся сбои (генерируется agents/checks/repeats.sh)\n"
                         "\nFACT/OBSERVATION/LESSON пишет человек; этот файл — измеренные повторы.\n")
        block.append(f"\n## {today} (неделя {stamp}) — окно {days} дн\n")
        for (agent, handler, reason), g in sorted(hard.items(), key=lambda kv: -kv[1]["n"]):
            block.append(f"- **{agent}/{handler}** — {g['n']} раз(а). Причина: {reason}\n"
                         f"  - первое: {g['first'][:19]} · последнее: {g['last_ts'][:19]}\n")
        with open(mem_path, "a", encoding="utf-8") as fh:
            fh.write("".join(block))
        print(f"\n  ↳ записано в память: {mem_path}")

print(f"\nИТОГ: повторяющихся сбоев {len(repeat)} · три и больше раз {len(hard)} · отказов {total_fail}")
PY
