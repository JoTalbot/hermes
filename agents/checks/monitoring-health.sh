#!/usr/bin/env bash
# Мониторинг: Prometheus, цели, алерты, экспортёр Hermes, Grafana. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "📊 МОНИТОРИНГ"

report_section "🔥 PROMETHEUS"
if curl -s -m 5 http://127.0.0.1:9090/-/healthy >/dev/null 2>&1; then
  report_ok "Prometheus отвечает (:9090)"
  curl -s -m 5 http://127.0.0.1:9090/api/v1/targets 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']['activeTargets']
up=sum(1 for t in d if t.get('health')=='up'); down=[t for t in d if t.get('health')!='up']
print(f'  ✅ цели: {up} из {len(d)} доступны')
for t in down[:4]: print(f\"  🔴 {t['labels'].get('job')} — {t.get('lastError','')[:60]}\")
" 2>/dev/null
else report_bad "Prometheus не отвечает на :9090"; fi

report_section "🚨 АЛЕРТЫ"
A=$(curl -s -m 5 http://127.0.0.1:9090/api/v1/alerts 2>/dev/null | python3 -c "
import sys,json
al=json.load(sys.stdin)['data']['alerts']
print('none' if not al else '\n'.join(f\"{a['state']} {a['labels'].get('alertname')} — {a['annotations'].get('summary','')[:50]}\" for a in al))" 2>/dev/null)
[[ "$A" == "none" || -z "$A" ]] && report_ok "активных алертов нет" || echo "$A" | sed 's/^/  /'
RULES=$(curl -s -m 5 http://127.0.0.1:9090/api/v1/rules 2>/dev/null | python3 -c "
import sys,json
print(sum(len(g['rules']) for g in json.load(sys.stdin)['data']['groups']))" 2>/dev/null)
report_kv "правил загружено" "${RULES:-?}"

report_section "📤 ЭКСПОРТЁР HERMES"
if curl -s -m 5 http://127.0.0.1:9725/metrics >/dev/null 2>&1; then
  M=$(curl -s -m 5 http://127.0.0.1:9725/metrics)
  report_ok "экспортёр отвечает (:9725)"
  echo "$M" | grep -E '^hermes_(bus_up|agents_defined|nodes_known|projects_wired|repo_dirty)' | sed 's/^/  /'
else report_warn "экспортёр не отвечает — Grafana без данных Hermes"; fi

report_section "📈 GRAFANA"
curl -s -m 5 -o /dev/null -w '  HTTP %{http_code} на :3000\n' http://127.0.0.1:3000/api/health 2>/dev/null || report_warn "Grafana не отвечает"

ACTIONS=("дашборд: http://129.213.177.56:3000 (Hermes Agent Bus & Agents)")
ACTIONS+=("если цель отвалилась: curl <scrapeUrl> вручную")
report_footer "${ACTIONS[@]}"
