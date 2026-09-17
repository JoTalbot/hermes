#!/usr/bin/env bash
# feedback-to-eval.sh — каждая оценка 👎 становится вопросом регресс-набора.
#
# Зачем (пункт 2 владельца, 2026-09-17): набор проверок «понимает ли система владельца» рос из
# моих догадок. Оценка 👎 — это факт от владельца: такой вопрос система обработала плохо. Здесь
# он переносится в tests/eval-feedback.tsv, который читает scripts/eval-agents.sh, поэтому
# регресс-набор растёт из реальной жизни.
#
# ЧЕСТНО О ГРАНИЦАХ: ожидание в этой строке — маршрут НА МОМЕНТ оценки (какому агенту и какому
# обработчику вопрос уходит). Это защита от регрессии маршрутизации, а не утверждение, что ответ
# был правильным: «мимо» мог быть и сам текст ответа. Строка помечена источником, чтобы человек
# мог уточнить ожидание руками.
#
#   bash scripts/feedback-to-eval.sh          # добавить новые вопросы из 👎
#   bash scripts/feedback-to-eval.sh --check  # только показать, что было бы добавлено
#   bash scripts/feedback-to-eval.sh --list   # что уже в наборе
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
FB="${HERMES_FEEDBACK_FILE:-/var/lib/hermes-agents/feedback.jsonl}"
OUT="${HERMES_EVAL_FEEDBACK_FILE:-$REPO_DIR/tests/eval-feedback.tsv}"
MODE="${1:-}"

PY=""
for cand in "$REPO_DIR/.venv-bus/bin/python" /opt/hermes/.venv-bus/bin/python; do
  [[ -x "$cand" ]] && { PY="$cand"; break; }
done
[[ -n "$PY" ]] || PY="$(command -v python3)"

if [[ "$MODE" == "--list" ]]; then
  if [[ -s "$OUT" ]]; then
    printf 'вопросов из 👎 в наборе: %s\n' "$(grep -cv '^\s*#\|^\s*$' "$OUT" || echo 0)"
    grep -v '^\s*#' "$OUT" | grep -v '^\s*$' | cut -f1,2,3 | sed 's/^/  /'
  else
    echo "набор из оценок пуст: $OUT"
  fi
  exit 0
fi

if [[ ! -s "$FB" ]]; then
  echo "оценок пока нет ($FB) — регресс-набор не изменился"
  exit 0
fi

REPO_DIR="$REPO_DIR" FB="$FB" OUT="$OUT" MODE="$MODE" "$PY" - <<'PY'
import json, os, sys

repo = os.environ["REPO_DIR"]
fb = os.environ["FB"]
out_path = os.environ["OUT"]
mode = os.environ.get("MODE") or ""
sys.path.insert(0, repo)
sys.path.insert(0, os.path.join(repo, "agents"))
try:
    import routing
    import runtime
except Exception as e:                       # маршрут не посчитать — честно скажем
    print(f"  ⚠️ routing недоступен ({e}); вопросы не добавлены")
    raise SystemExit(0)

agents = runtime.load_agents()
known: dict[str, str] = {}
if os.path.exists(out_path):
    with open(out_path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if parts and parts[0]:
                known[" ".join(parts[0].lower().split())] = line.rstrip("\n")

downs: list[tuple[str, str, str]] = []
seen: set[str] = set()
with open(fb, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("verdict") != "down":
            continue
        q = " ".join(str(r.get("question") or "").split())
        if not q:
            continue
        key = q.lower()
        if key in known or key in seen:
            continue
        seen.add(key)
        downs.append((q, str(r.get("ts") or "")[:10], str(r.get("answer") or "")[:60]))

if not downs:
    print(f"новых оценок 👎 нет; в наборе {len(known)} вопрос(ов) — {out_path}")
    raise SystemExit(0)

lines: list[str] = []
for q, ts, answer in downs:
    d = routing.route(q, agents)
    cap = d.get("capability", "") or ""
    handler = d.get("handler", "") or ""
    subject = d.get("subject", "") or d.get("action", "") or d.get("target", "") or ""
    lines.append(f"{q}\t{cap}\t{handler}\t{subject}\t{ts}\tответ при оценке: {answer}")

if mode == "--check":
    print(f"было бы добавлено {len(lines)} вопрос(ов):")
    for l in lines:
        print("  • " + l.split("\t")[0][:80])
    raise SystemExit(0)

header = (
    "# Вопросы владельца, получившие 👎 — регресс-набор (пишет scripts/feedback-to-eval.sh).\n"
    "# Ожидание = маршрут на момент оценки (capability / обработчик / объект), НЕ утверждение,\n"
    "# что ответ был верным: 👎 мог означать и текст ответа. Уточнять руками, если нужно.\n"
    "# Формат: вопрос <TAB> capability <TAB> handler <TAB> subject <TAB> дата <TAB> ответ\n"
)
new_file = not os.path.exists(out_path)
with open(out_path, "a", encoding="utf-8") as fh:
    if new_file:
        fh.write(header)
    for l in lines:
        fh.write(l + "\n")

print(f"добавлено {len(lines)} вопрос(ов) из 👎 → {out_path}")
for l in lines:
    p = l.split("\t")
    print(f"  • {p[0][:70]} → {p[2]}")
PY
