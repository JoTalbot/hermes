#!/usr/bin/env bash
# Какой арсенал у команды: скиллы, обработчики и их количество. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "🎓 СКИЛЛЫ И АРСЕНАЛ"

report_section "🎓 СКИЛЛЫ HERMES"
OUT=$(mktemp)
sudo -u hermes -H env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes skills list >"$OUT" 2>/dev/null
EN=$(grep -cE "enabled *│" "$OUT" 2>/dev/null || echo 0)
report_kv "включено" "$EN"
grep -E "enabled *│" "$OUT" 2>/dev/null | awk -F'│' '{gsub(/ /,"",$2); printf "  • %s\n", $2}' | head -14
rm -f "$OUT"

report_section "🛠 АРСЕНАЛ АГЕНТОВ"
python3 - <<'PY' 2>/dev/null
import glob, yaml
rows=[]
for f in sorted(glob.glob('/opt/hermes/config/agents/*.yaml')) + sorted(glob.glob('/opt/hermes/config/agents/projects/*.yaml')):
    d=yaml.safe_load(open(f)) or {}; b=d.get('bus') or {}
    aid=b.get('agent_id')
    if not aid or aid.startswith('proj-'): continue
    rows.append((aid, len(b.get('handlers') or {}), ','.join(list((b.get('handlers') or {}).keys())[:9])))
tot=0
for aid,n,hs in rows:
    tot+=n; print(f'  {aid:17s} {n:2d} обработчиков: {hs}')
print(f'  ── всего у специалистов: {tot}')
PY

report_section "📁 СКРИПТЫ"
ls -1 /opt/hermes/agents/checks/*.sh 2>/dev/null | wc -l | awk '{printf "  %s проверочных скриптов\n", $1}'

report_footer "добавить скилл: положить папку в /opt/hermes/skills и запустить scripts/register-skills.sh" "посмотреть конкретный агент: напиши «какие агенты»"
