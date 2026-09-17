#!/usr/bin/env bash
# eval-agents.sh — «агент отвечает правильно?»: 22 типовых вопроса владельца с ожидаемым маршрутом.
#
# Зачем: тесты проверяли, что агент не падает и печатает доказательства, но НЕ проверяли,
# что вопрос владельца попадает к нужному агенту и нужному обработчику. Ошибка вида
# «`top` матчит octopus» жила в проде именно поэтому. Здесь проверяется смысл:
# строка вопроса → ожидаемая capability, обработчик и объект.
#
#   bash scripts/eval-agents.sh           # маршруты (быстро, детерминированно)
#   bash scripts/eval-agents.sh --live    # плюс реальный прогон 4 дешёвых проверок
#   bash scripts/eval-agents.sh --json    # машинночитаемо
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
cd "$REPO_DIR"

PY=""
for cand in "$REPO_DIR/.venv-bus/bin/python" /opt/hermes/.venv-bus/bin/python; do
  [[ -x "$cand" ]] && { PY="$cand"; break; }
done
[[ -n "$PY" ]] || PY="$(command -v python3)"

MODE="${1:-}"
"$PY" - "$MODE" <<'PY'
import json, os, sys
sys.path.insert(0, "/opt/hermes")
sys.path.insert(0, "/opt/hermes/agents")
import routing
import runtime

mode = sys.argv[1] if len(sys.argv) > 1 else ""
agents = runtime.load_agents()          # реальный реестр узла, а не выдуманный

# (вопрос, ожидаемая capability, ожидаемый handler, ожидаемый subject/действие)
CASES = [
    ("что там с octopus-multisync", "host-health", "lookup", "octopus-multisync"),
    ("что с процессом chromium", "host-health", "proc", "chromium"),
    ("что грузит сервер", "host-health", "top", ""),
    ("диски", "host-health", "disk", ""),
    ("статус hermes", "host-health", "hermes", ""),
    ("что делали агенты", "host-health", "history", ""),
    ("проверь, сработал ли перезапуск octopus-browser", "host-health", "verify", "octopus-browser"),
    ("какие агенты", "", "agents", ""),
    ("какие проекты", "", "projects", ""),
    ("аудит безопасности", "security", "audit", ""),
    ("какие порты открыты наружу", "security", "ports", ""),
    ("проверить бэкапы", "backup", "verify", ""),
    ("алерты", "monitoring", "alerts", ""),
    ("статус проекта liza", "project:liza", "status", "liza"),
    ("статус проекта octopus", "project:octopus", "status", "octopus"),
    ("прогони тесты в octopus", "project:octopus", "run", "octopus"),
    ("покажи логи madworld", "project:madworld", "run", "madworld"),
    ("склонируй проект liza", "host-health", "act", "clone-project"),
    ("подтяни проект fs", "host-health", "act", "pull-project"),
    ("перезапусти контейнер octopus-browser", "host-health", "act", "restart"),
    ("какие модели отвечают", "host-health", "models", ""),
    ("какие провайдеры llm живы", "host-health", "models", ""),
]

# Набор из 👎 (пишет scripts/feedback-to-eval.sh): владелец уже сказал, что эти вопросы
# обработаны плохо. Ожидание — маршрут на момент оценки, то есть защита от регрессии.
FEEDBACK_CASES: list[tuple[str, str, str, str]] = []
_fb_path = os.path.join("/opt/hermes", "tests", "eval-feedback.tsv")
if not os.path.exists(_fb_path):
    _fb_path = os.path.join(os.getcwd(), "tests", "eval-feedback.tsv")
try:
    with open(_fb_path, encoding="utf-8") as _fh:
        for _line in _fh:
            if _line.startswith("#") or not _line.strip():
                continue
            _p = _line.rstrip("\n").split("\t")
            if len(_p) >= 4 and _p[0].strip():
                FEEDBACK_CASES.append((_p[0], _p[1], _p[2], _p[3]))
except OSError:
    pass
BUILTIN = len(CASES)
CASES = CASES + FEEDBACK_CASES

rows, bad = [], 0
for task, want_cap, want_handler, want_subject in CASES:
    d = routing.route(task, agents)
    got_cap = d.get("capability", "") or ""
    got_handler = d.get("handler", "") or ""
    got_subject = d.get("subject", "") or d.get("action", "") or d.get("target", "")
    # subject проверяем только когда он ожидается: у «какие агенты» объекта нет вовсе,
    # а target при этом заполнен (orchestrator) — это не ошибка маршрута.
    subject_ok = (not want_subject) or got_subject == want_subject
    ok = (got_handler == want_handler and subject_ok
          and (not want_cap or got_cap == want_cap))
    if not ok:
        bad += 1
    # Кто именно ответит: явная цель, иначе первый агент с нужной capability.
    target = d.get("target") or ""
    if not target and got_cap:
        cands = sorted(a.id for a in agents.values() if got_cap in a.capabilities)
        target = cands[0] if cands else "(нет агента)"
    rows.append({"task": task, "want": [want_cap, want_handler, want_subject],
                 "got": [got_cap, got_handler, got_subject], "ok": ok, "agent": target})

if mode == "--json":
    print(json.dumps({"cases": rows, "passed": len(rows) - bad, "failed": bad,
                      "builtin": BUILTIN, "from_feedback": len(FEEDBACK_CASES)},
                     ensure_ascii=False, indent=1))
else:
    print("=== ПРОГОН: понимает ли система вопросы владельца ===")
    for r in rows:
        mark = "ok  " if r["ok"] else "FAIL"
        print(f"  {mark} {r['task'][:44]:46} → {r['agent'][:22]:24} {r['got'][1]}")
        if not r["ok"]:
            print(f"        ожидалось: {r['want']}")
            print(f"        получено : {r['got']}")
    print(f"  (встроенных вопросов {BUILTIN}, из оценок 👎 {len(FEEDBACK_CASES)})\n")
    print(f"ИТОГ: {len(rows) - bad} из {len(rows)} вопросов уходят правильному агенту и "
          f"обработчику · сбоев {bad}")

sys.exit(1 if bad else 0)
PY
RC=$?
if [[ "$MODE" == "--live" && $RC -eq 0 ]]; then
  echo
  echo "=== живой прогон дешёвых проверок ==="
  for c in history.sh lookup.sh feedback.sh journal-top.sh; do
    out="$(ARG_NAME=hermes-agents timeout 120 bash agents/checks/$c.sh 2>&1)"
    if [[ $? -eq 0 && -n "$out" ]]; then
      printf '  ok   %-16s %s\n' "$c" "$(printf '%s' "$out" | head -1 | cut -c1-60)"
    else
      printf '  FAIL %-16s не запустился\n' "$c"; RC=1
    fi
  done
fi
exit $RC
