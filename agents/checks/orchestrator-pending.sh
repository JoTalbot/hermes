#!/usr/bin/env bash
# Что в работе: задачи, ожидающие ответа, и состояние шины. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🧭 ЧТО В РАБОТЕ"

report_section "📨 ШИНА"
hermes-bus-bridge status 2>/dev/null | sed 's/^/  /' | head -8

report_section "⏳ ОЖИДАЮТ РЕЗУЛЬТАТА"
PEND=/var/lib/hermes-agents/pending.json
if [[ -f "$PEND" ]]; then
  python3 - "$PEND" <<'PY' 2>/dev/null || echo "  (нет данных)"
import json, sys, datetime
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit
now=datetime.datetime.now(datetime.timezone.utc)
rows=[]
for corr, rec in (d.items() if isinstance(d, dict) else []):
    at=rec.get('at','')
    try: age=int((now-datetime.datetime.fromisoformat(at.replace('Z','+00:00'))).total_seconds())
    except Exception: age=-1
    rows.append((age, corr, rec.get('agent','?'), rec.get('handler','?'), (rec.get('task') or '')[:44]))
rows.sort(key=lambda r: -r[0])
if not rows: print('  ✅ незавершённых задач нет')
for age, corr, ag, h, task in rows[:8]:
    mark='🔴' if age>900 else '⚠️' if age>300 else '⏳'
    print(f'  {mark} {age}s  {ag}.{h}  {task}')
PY
else report_ok "незавершённых задач нет (реестр пуст)"; fi

report_section "🖥 УЗЛЫ"
hermes-bus nodes 2>/dev/null | sed 's/^/  /' | head -6

ACTIONS=("задача висит >15 мин — проверить журнал агента: journalctl -u hermes-agents -n 50")
ACTIONS+=("детали узла: напиши «статус шины»")
report_footer "${ACTIONS[@]}"
