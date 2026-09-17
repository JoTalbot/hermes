#!/usr/bin/env bash
# feedback.sh — что владелец думает об ответах агентов (кнопки 👍/👎 под ответом).
#
# Зачем: «подобрать модели по функциям» и «стало ли лучше» до сих пор были предположениями.
# Здесь — измерение: сколько оценок, какие вопросы получили 👎, что в них общего.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
FB="${HERMES_FEEDBACK_FILE:-/var/lib/hermes-agents/feedback.jsonl}"
N="${ARG_N:-20}"
report_header "🗳 ОЦЕНКИ ОТВЕТОВ"

if [[ ! -s "$FB" ]]; then
  report_section "📊 ОЦЕНКИ"
  report_unknown "оценок пока нет"
  report_info "под каждым ответом в Telegram есть кнопки 👍 точный / 👎 мимо"
  report_proof "ls -l $FB"
  report_footer "ИТОГ: оценок пока нет (👍 0 / 👎 0) · разбор появится после первой оценки"
  exit 0
fi

FB_FILE="$FB" N="$N" python3 - <<'PY'
import json, os, time
from collections import Counter

path = os.environ["FB_FILE"]
limit = int(os.environ["N"] or 20)
now = time.time()
rows = []
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
except OSError as e:
    print(f"  ⚠️ не читается {path}: {e}")
    raise SystemExit(0)

up = [r for r in rows if r.get("verdict") == "up"]
down = [r for r in rows if r.get("verdict") == "down"]
day_up = [r for r in up if now - int(r.get("epoch") or 0) <= 86400]
day_down = [r for r in down if now - int(r.get("epoch") or 0) <= 86400]
total = len(up) + len(down)
share = (100 * len(up) // total) if total else 0

print("\n📊 ОЦЕНКИ")
print(f"  всего            {total} (👍 {len(up)} / 👎 {len(down)})")
print(f"  за сутки         {len(day_up) + len(day_down)} (👍 {len(day_up)} / 👎 {len(day_down)})")
print(f"  доля точных      {share}%")
print(f"  ↳ доказательство: {path}")

if down:
    print("\n🔻 ЧТО НЕ ПОПАЛО (последние)")
    for r in down[-limit:]:
        q = (r.get("question") or "?").replace("\n", " ")[:90]
        a = (r.get("answer") or "").replace("\n", " ")[:70]
        print(f"  • «{q}»")
        print(f"    ответ был: {a}…")
        print(f"    ↳ доказательство: {path}")
    words = Counter()
    for r in down:
        for w in (r.get("question") or "").lower().split():
            if len(w) > 3:
                words[w.strip("?,.")] += 1
    if words:
        print("  частые слова в неудачных вопросах: " +
              ", ".join(f"{w} ({n})" for w, n in words.most_common(5)))
else:
    print("\n✅ Отрицательных оценок нет")

print("\n💡 ЧТО ДЕЛАТЬ")
if down:
    print("  • если вопросы похожи — расширить таблицу намерений routing.py под их формулировки")
    print("  • если ответ был «мимо» по смыслу — посмотреть, тот ли агент отвечал: «что делали агенты»")
else:
    print("  • ничего: оценок с минусом нет")
print("  • отрицательные оценки видны и в суточной сводке (09:00)")

# Итоговая строка для digest и тестов
print(f"\nИТОГ: оценок {total} · точных {share}% · проблемных {len(down)}")
PY
