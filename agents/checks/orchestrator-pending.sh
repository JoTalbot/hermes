#!/usr/bin/env bash
# Что в работе: задачи, ожидающие ответа, и состояние шины. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🧭 ЧТО В РАБОТЕ"

report_section "📨 ШИНА"
hermes-bus-bridge status 2>/dev/null | sed 's/^/  /' | head -8

report_section "⏳ ОЖИДАЮТ РЕЗУЛЬТАТА"
PEND=/var/lib/hermes-agents/pending.json
# TTL тот же, что у рантайма: задача без ответа снимается с ожидания и владельцу уходит
# предупреждение. Иначе «в работе» показывалось вечно — агент давно молчит, а задача висит.
TTL="${HERMES_PENDING_TTL:-21600}"
if [[ -f "$PEND" ]]; then
  python3 - "$PEND" "$TTL" <<'PY' 2>/dev/null || echo "  (нет данных)"
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
ttl=int(sys.argv[2]) if len(sys.argv)>2 else 21600
if not rows: print('  ✅ незавершённых задач нет')
for age, corr, ag, h, task in rows[:8]:
    if age > ttl: mark='⏰'          # снимается с ожидания на ближайшей проверке
    elif age>900: mark='🔴'
    elif age>300: mark='⚠️'
    else: mark='⏳'
    print(f'  {mark} {age}s  {ag}.{h}  {task}')
if any(r[0] > ttl for r in rows):
    print(f'  ⏰ старше {ttl//3600} ч — рантайм снимает их с ожидания и пишет в #incidents')
PY
else report_ok "незавершённых задач нет (реестр пуст)"; fi

report_section "🖥 УЗЛЫ"
hermes-bus nodes 2>/dev/null | sed 's/^/  /' | head -6

ACTIONS=("задача висит >15 мин — проверить журнал агента: journalctl -u hermes-agents -n 50")
ACTIONS+=("⏰ — задача без ответа дольше TTL (6 ч) и будет снята с ожидания")
ACTIONS+=("детали узла: напиши «статус шины»")
report_footer "${ACTIONS[@]}"
