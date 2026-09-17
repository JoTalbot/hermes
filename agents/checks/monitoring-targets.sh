#!/usr/bin/env bash
# Цели Prometheus: кто скрейпится и кто отвалился. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🎯 ЦЕЛИ PROMETHEUS"

curl -s -m 8 'http://127.0.0.1:9090/api/v1/targets' 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception:
    print('  ⚠️ Prometheus не отвечает на 127.0.0.1:9090'); raise SystemExit
ts=d['data']['activeTargets']
up=[t for t in ts if t.get('health')=='up']; down=[t for t in ts if t.get('health')!='up']
print('📊 ИТОГ')
print(f'  ✅ доступно: {len(up)} из {len(ts)}')
print()
print('🎯 ПО ЗАДАНИЯМ')
jobs={}
for t in ts:
    j=t['labels'].get('job','?'); jobs.setdefault(j,[0,0])
    jobs[j][0 if t.get('health')=='up' else 1]+=1
for j,(u,dwn) in sorted(jobs.items()):
    mark='✅' if dwn==0 else '🔴'
    print(f'  {mark} {j:28s} up={u} down={dwn}')
if down:
    print()
    print('🔴 ЧТО ОТВАЛИЛОСЬ')
    for t in down[:6]:
        print(f\"  🔴 {t['labels'].get('job')} {t['scrapeUrl']}\")
        if t.get('lastError'): print(f\"       {t['lastError'][:90]}\")
" 2>/dev/null

report_footer "отвалившуюся цель проверить вручную: curl -s <scrapeUrl>" "конфиг целей: /opt/octopus-monitoring/prometheus.yml"
