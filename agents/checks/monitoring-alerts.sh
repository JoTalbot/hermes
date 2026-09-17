#!/usr/bin/env bash
# Активные алерты Prometheus: что горит прямо сейчас. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🚨 АЛЕРТЫ МОНИТОРИНГА"

report_section "🔔 СЕЙЧАС ГОРИТ"
ACT=$(curl -s -m 8 'http://127.0.0.1:9090/api/v1/alerts' 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for a in d.get('data',{}).get('alerts',[]):
    l=a.get('labels',{}); print(f\"{a.get('state'):9s} {l.get('alertname')} {l.get('severity','')} — {a.get('annotations',{}).get('summary','')[:60]}\")
" 2>/dev/null)
[[ -z "$ACT" ]] && report_ok "активных алертов нет" || echo "$ACT" | sed 's/^/  /'

report_section "📐 ЗАГРУЖЕННЫЕ ПРАВИЛА"
curl -s -m 8 'http://127.0.0.1:9090/api/v1/rules' 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for g in d.get('data',{}).get('groups',[]):
    print(f\"  {g['name']}: {len(g['rules'])} правил\")
" 2>/dev/null

report_section "🎯 ЦЕЛИ"
curl -s -m 8 'http://127.0.0.1:9090/api/v1/targets' 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
up=sum(1 for t in d['data']['activeTargets'] if t.get('health')=='up')
down=[t for t in d['data']['activeTargets'] if t.get('health')!='up']
print(f'  ✅ up: {up}')
for t in down[:5]: print(f\"  🔴 {t['labels'].get('job')} {t['scrapeUrl']} — {t.get('lastError','')[:50]}\")
" 2>/dev/null

ACTIONS=("если алерт горит: смотреть деталь и историю в Grafana http://129.213.177.56:3000")
ACTIONS+=("проверить экспортёр Hermes: напиши «проверить мониторинг»")
report_proof "curl /api/v1/rules · /api/v1/alerts · список таргетов Prometheus"
report_footer "${ACTIONS[@]}"
