#!/usr/bin/env bash
# Оркестратор: шина, узлы, агенты, незавершённые задачи. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🧭 ОРКЕСТРАТОР"

report_section "📨 ШИНА"
hermes-bus-bridge status 2>/dev/null | sed 's/^/  /' | head -9

report_section "🖥 УЗЛЫ"
hermes-bus nodes 2>/dev/null | sed 's/^/  /' | head -6

report_section "🤖 АГЕНТЫ И ОБРАБОТЧИКИ"
python3 - <<'PY' 2>/dev/null
import glob, yaml
core=[]; proj=0; h=0
for f in glob.glob('/opt/hermes/config/agents/*.yaml')+glob.glob('/opt/hermes/config/agents/projects/*.yaml'):
    d=yaml.safe_load(open(f)) or {}; b=d.get('bus') or {}
    aid=b.get('agent_id'); n=len(b.get('handlers') or {}); h+=n
    if not aid: continue
    (core.append((aid,n)) if not aid.startswith('proj-') else None)
    proj += 1 if aid.startswith('proj-') else 0
for aid,n in sorted(core):
    print(f'  {aid:17s} {n:2d} обработчиков')
print(f'  ── проектных агентов: {proj}, обработчиков всего: {h}')
PY

report_section "⏳ В РАБОТЕ"
PEND=/var/lib/hermes-agents/pending.json
if [[ -f "$PEND" ]]; then
  python3 - "$PEND" <<'PY' 2>/dev/null || report_ok "незавершённых задач нет"
import json, sys, datetime
d=json.load(open(sys.argv[1]))
now=datetime.datetime.now(datetime.timezone.utc)
rows=[]
for corr, rec in d.items():
    try: age=int((now-datetime.datetime.fromisoformat(rec.get('at',''))).total_seconds())
    except Exception: age=-1
    rows.append((age, rec.get('agent','?'), rec.get('handler','?'), (rec.get('task') or '')[:40]))
if not rows: print('  ✅ незавершённых задач нет')
for age, ag, h, t in sorted(rows, reverse=True)[:6]:
    print(f"  {'🔴' if age>900 else '⏳'} {age}s {ag}.{h} {t}")
PY
else report_ok "незавершённых задач нет"; fi

ACTIONS=("задача висит — смотреть journalctl -u hermes-agents -n 50")
ACTIONS+=("что умеет команда: напиши «какие агенты»")
report_footer "${ACTIONS[@]}"
