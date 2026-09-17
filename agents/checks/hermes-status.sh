#!/usr/bin/env bash
# Стек Hermes: юниты, шина, агенты, скиллы. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🧭 СТЕК HERMES"

report_section "⚙️ ЮНИТЫ"
for u in hermes-shim hermes-serve hermes-gateway hermes-metrics hermes-bus-bridge hermes-telegram-inbox hermes-agents nats-server hermes-backup.timer; do
  ST=$(systemctl is-active "$u" 2>/dev/null)
  case "$ST" in
    active) printf '  ✅ %s\n' "$u" ;;
    *) printf '  🔴 %s (%s)\n' "$u" "${ST:-нет}" ;;
  esac
done

report_section "📨 ШИНА"
hermes-bus-bridge status 2>/dev/null | head -8 | sed 's/^/  /'

report_section "🤖 АГЕНТЫ"
DEF=$(ls /opt/hermes/config/agents/*.yaml /opt/hermes/config/agents/projects/*.yaml 2>/dev/null | wc -l)
HANDLERS=$(python3 -c "
import glob,yaml
n=0
for f in glob.glob('/opt/hermes/config/agents/*.yaml')+glob.glob('/opt/hermes/config/agents/projects/*.yaml'):
    d=yaml.safe_load(open(f)) or {}; n+=len((d.get('bus') or {}).get('handlers') or {})
print(n)" 2>/dev/null || echo "?")
report_kv "конфигураций агентов" "$DEF"
report_kv "обработчиков всего" "$HANDLERS"
report_kv "узлов на шине" "$(hermes-bus nodes 2>/dev/null | wc -l)"

report_section "🎓 СКИЛЛЫ"
OUT=$(mktemp)
sudo -u hermes -H env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes skills list >"$OUT" 2>/dev/null
report_kv "включено" "$(grep -cE 'enabled *│' "$OUT" 2>/dev/null || echo '?')"
rm -f "$OUT"

report_section "🧠 МОДЕЛИ"
if curl -s -m 5 http://127.0.0.1:9700/v1/models >/dev/null 2>&1; then
  report_ok "балансер отвечает на 127.0.0.1:9700"
  report_kv "доступные тиры" "$(curl -s -m 5 http://127.0.0.1:9700/v1/models | python3 -c "
import sys,json
try: print(', '.join(m['id'] for m in json.load(sys.stdin)['data']))
except Exception: print('?')" 2>/dev/null)"
else report_bad "балансер не отвечает — агенты будут отвечать только фактами"; fi

ACTIONS=("если юнит красный: systemctl restart <юнит> и проверить журнал")
ACTIONS+=("что умеют агенты: напиши «какие агенты»")
report_footer "${ACTIONS[@]}"
