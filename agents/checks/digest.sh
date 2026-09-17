#!/usr/bin/env bash
# digest.sh — суточная сводка: что случилось за 24 часа и что требует решения владельца.
#
# Не поток событий и не дамп токенов: 10–15 строк, из которых видно, всё ли в порядке.
# Источники — только измерения: история прогонов, Prometheus (алерты), конфиги проектов,
# каталог бэкапов, pending-задачи.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
HIST="${HERMES_HISTORY_FILE:-/var/lib/hermes-agents/history.jsonl}"
report_header "📅 ЗА СУТКИ"

# ── 1. прогоны агентов ────────────────────────────────────────────────────────
if [[ -s "$HIST" ]]; then
  HIST_FILE="$HIST" python3 - <<'PY'
import json, os, time
from collections import defaultdict

path, now = os.environ["HIST_FILE"], time.time()
runs = fails = asks = fb = 0
per_fail = defaultdict(int)
examples = []
queue = []
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if now - int(r.get("epoch") or 0) > 86400:
                continue
            hand = r.get("handler")
            if hand == "ask":
                asks += 1
                if r.get("fallback"):
                    fb += 1
                continue
            runs += 1
            if int(r.get("code") or 0) != 0:
                fails += 1
                per_fail[str(r.get("agent"))] += 1
                if len(examples) < 3:
                    examples.append(f"{r.get('agent')}.{hand} → код {r.get('code')} · "
                                    f"{str(r.get('summary', ''))[:70]}")
            if r.get("queue_ms"):
                queue.append(int(r["queue_ms"]))
except OSError:
    pass

print("\n🤖 АГЕНТЫ")
print(f"  прогонов обработчиков  {runs}")
print(f"  из них с ошибкой       {fails}")
print(f"  ответов моделью (ask)  {asks}" + (f", сорвались на локальную/факты: {fb}" if fb else ""))
if queue:
    q = sorted(queue)
    print(f"  ожидание в очереди     p95 {q[int(0.95 * (len(q) - 1))] // 1000} с")
if per_fail:
    top = ", ".join(f"{a} ({n})" for a, n in sorted(per_fail.items(), key=lambda kv: -kv[1])[:4])
    print(f"  чаще падали            {top}")
for e in examples:
    print(f"    • {e}")
if not fails:
    print("  ✅ ошибок за сутки не было")
PY
else
  report_unknown "истории прогонов пока нет"
fi

# ── 2. алерты ─────────────────────────────────────────────────────────────────
report_section "🚨 АЛЕРТЫ"
ALERTS="$(curl -s --max-time 6 http://127.0.0.1:9090/api/v1/alerts 2>/dev/null)"
if [[ -n "$ALERTS" ]]; then
  # JSON пишем в файл, а не передаём в python через кавычки: экранирование внутри
  # f-строки уже один раз сломало эту секцию (беззвучно, в пустой отчёт).
  printf '%s' "$ALERTS" > /tmp/hermes-digest-alerts.json
  python3 - <<'PY'
import json

try:
    alerts = json.load(open("/tmp/hermes-digest-alerts.json"))["data"]["alerts"]
except Exception:
    print("  ⚠️ Prometheus не ответил в ожидаемом формате")
    raise SystemExit(0)
firing = [x for x in alerts if x.get("state") == "firing"]
if not firing:
    print("  ✅ ничего не горит")
for x in firing[:5]:
    lbl = x.get("labels", {})
    name = lbl.get("alertname", "?")
    summary = lbl.get("summary") or lbl.get("instance", "")
    since = str(x.get("activeAt", ""))[:19]
    print(f"  🔴 {name}: {summary}"[:150])
    print(f"     ↳ доказательство: /api/v1/alerts · с {since}")
PY
else
  report_unknown "Prometheus не ответил — состояние алертов неизвестно"
  report_proof "curl http://127.0.0.1:9090/api/v1/alerts"
fi

# ── 3. проекты: что изменилось и что ждёт решения ─────────────────────────────
report_section "📦 ПРОЕКТЫ"
CHANGED=0; DIRTY=0; AHEAD=0; BEHIND=0; DETAIL=""
for f in /opt/hermes/config/agents/projects/*.yaml; do
  [[ -f "$f" ]] || continue
  slug="$(basename "$f" .yaml)"; [[ "$slug" == "README" ]] && continue
  path_="$(grep -E 'local_path:' "$f" | head -1 | sed 's/.*local_path: *//; s/["'"'"']//g')"
  [[ -d "$path_/.git" ]] || continue
  if [[ -n "$(git -C "$path_" rev-parse --verify -q HEAD 2>&1 >/dev/null)" ]]; then continue; fi
  d="$(git -C "$path_" status --porcelain 2>/dev/null | wc -l)"
  a="$(git -C "$path_" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  b="$(git -C "$path_" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
  if [[ "$a" =~ ^[0-9]+$ && "$a" -gt 0 ]]; then AHEAD=$((AHEAD+1)); DETAIL+="  • $slug: не отправлено $a коммитов"$'\n'; fi
  if [[ "$b" =~ ^[0-9]+$ && "$b" -gt 0 ]]; then BEHIND=$((BEHIND+1)); DETAIL+="  • $slug: отстаёт на $b коммитов (локальная копия старее GitHub)"$'\n'; fi
  [[ "$d" =~ ^[0-9]+$ && "$d" -gt 0 ]] && DIRTY=$((DIRTY+1))
  # свежие изменения за сутки
  if [[ -n "$(find "$path_" -maxdepth 2 -newermt '-24 hours' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]]; then
    CHANGED=$((CHANGED+1))
  fi
done
report_kv "с изменениями за сутки" "$CHANGED"
report_kv "с неотправленным" "$AHEAD"
report_kv "с незакоммиченным" "$DIRTY"
report_kv "отстают от GitHub" "$BEHIND"
[[ -n "$DETAIL" ]] && printf '%s' "$DETAIL" | head -6
report_proof "Обход config/agents/projects/*.yaml → git status/rev-list по каждому пути"

# ── 3b. оценки владельца ──────────────────────────────────────────────────────
FB="${HERMES_FEEDBACK_FILE:-/var/lib/hermes-agents/feedback.jsonl}"
if [[ -s "$FB" ]]; then
  report_section "🗳 ОЦЕНКИ ОТВЕТОВ"
  FB_FILE="$FB" python3 - <<'PY'
import json, os, time
up = down = 0
questions = []
now = time.time()
try:
    for line in open(os.environ["FB_FILE"], encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if now - int(r.get("epoch") or 0) > 86400:
            continue
        if r.get("verdict") == "up":
            up += 1
        elif r.get("verdict") == "down":
            down += 1
            questions.append((r.get("question") or "?").replace("\n", " ")[:60])
total = up + down
if total == 0:
    print("  за сутки оценок не было")
else:
    share = 100 * up // total
    print(f"  👍 {up} · 👎 {down} · точных {share}%")
    for q in questions[:3]:
        print(f"    • не попал ответ на «{q}»")
PY
  report_proof "tail /var/lib/hermes-agents/feedback.jsonl"
fi

# ── 4. бэкап и очередь ────────────────────────────────────────────────────────
report_section "💾 БЭКАП И ОЧЕРЕДЬ"
LAST_BK="$(ls -1t /var/backups/hermes/hermes-state-*.tar.gz 2>/dev/null | head -1)"
if [[ -n "$LAST_BK" ]]; then
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LAST_BK") ) / 3600 ))
  report_kv "последний бэкап" "$(basename "$LAST_BK") · $((AGE_H/24)) дн назад"
  (( AGE_H > 48 )) && report_warn "бэкап старше двух суток" || report_ok "бэкап свежий"
else
  report_warn "бэкапов не найдено"
fi
PEND="$(python3 -c 'import json;print(len(json.load(open("/var/lib/hermes-agents/pending.json"))))' 2>/dev/null || echo "?")"
report_kv "задач без ответа" "$PEND"
[[ "$PEND" =~ ^[0-9]+$ && "$PEND" -gt 0 ]] && report_warn "есть задачи, ответа по которым нет (TTL 6 ч)" \
  || report_ok "незавершённых задач нет"
report_footer "подробнее: «что делали агенты» · «статус сервера» · «алерты»" \
              "если что-то требует решения — оно названо выше"
