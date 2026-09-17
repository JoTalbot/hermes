#!/usr/bin/env bash
# models.sh — «какие модели отвечают агентам, кто из провайдеров жив и где теряется умность».
#
# FACT (2026-09-17): поле tier в запросе к мосту AIOS игнорировалось, поэтому «умный» запрос
# обслуживала дешёвая модель; тир code вообще не имел рабочего провайдера (mistral-small отдаёт
# HTTP 429, у hf-Qwen2.5-72B нет ключа и его хост не разрешается), а тир local не отвечал,
# потому что служба ollama на узле выключена. Ничего этого не было видно в отчётах: ответы
# приходили, просто не те. Отчёт читает историю прогонов и здоровье балансировщика — и не
# тратит при этом ни одного запроса к модели.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
HIST="${HERMES_HISTORY_FILE:-/var/lib/hermes-agents/history.jsonl}"
BAL="${HERMES_BALANCER_HEALTH_URL:-http://127.0.0.1:9600/health}"
HOURS="${ARG_HOURS:-24}"
report_header "🧠 МОДЕЛИ АГЕНТОВ: КТО ОТВЕЧАЕТ"

# ── 1. что просили и кто ответил ─────────────────────────────────────────────
report_section "🧭 ЧТО ПРОСИЛИ И КТО ОТВЕТИЛ (${HOURS} ч)"
if [[ ! -s "$HIST" ]]; then
  report_unknown "истории прогонов нет: $HIST"
else
  HIST_FILE="$HIST" HOURS="$HOURS" python3 - <<'PY'
import json, os, time
from collections import Counter, defaultdict

want_names = {"hermes-fast": "fast", "hermes-reason": "reasoning", "hermes-code": "code",
              "hermes-long": "long_context", "hermes-local": "local"}
path = os.environ["HIST_FILE"]
hours = int(os.environ.get("HOURS") or 24)
now = time.time()
rows = []
try:
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("handler") != "ask":
            continue
        if now - int(r.get("epoch") or 0) > hours * 3600:
            continue
        rows.append(r)
except OSError as e:
    print(f"  ⚠️ история не читается: {e}")
    raise SystemExit(0)

if not rows:
    print("  к модели за это время не обращались (детерминированные проверки модель не трогают)")
    raise SystemExit(0)

per_tier = defaultdict(lambda: {"n": 0, "ok": 0, "lat": [], "cached": 0})
providers = Counter()
mismatch = 0
fallbacks = 0
last_bad = None
for r in rows:
    tier = str(r.get("tier") or "?")
    t = per_tier[tier]
    t["n"] += 1
    t["lat"].append(int(r.get("took_ms") or 0))
    if r.get("cached"):
        t["cached"] += 1
    if r.get("fallback"):
        fallbacks += 1
    want = want_names.get(tier)
    served = str(r.get("served_tier") or "")
    prov_tier = str(r.get("provider_tier") or "")
    prov = str(r.get("provider") or "?")
    if r.get("provider"):
        providers[f"{prov} [{prov_tier or served or '?'}]"] += 1
    if r.get("tier_mismatch") or (want and served and want != served) or \
       (want and prov_tier and want != prov_tier):
        mismatch += 1
        last_bad = (tier, prov, prov_tier or served)
    else:
        t["ok"] += 1

for tier, t in sorted(per_tier.items(), key=lambda kv: -kv[1]["n"]):
    lat = sorted(t["lat"])
    p95 = lat[max(0, min(len(lat) - 1, int(round(0.95 * (len(lat) - 1)))))]
    flag = "✅" if t["ok"] == t["n"] else "⚠️"
    print(f"  {flag} {tier:14s} запросов {t['n']:3d} · тем же тиром {t['ok']:3d} · "
          f"p95 {p95} мс · из кэша {t['cached']}")
print(f"\n  расхождений тира всего: {mismatch} · фолбэков на локальную модель: {fallbacks}")
if last_bad:
    print(f"  последнее расхождение: просили {last_bad[0]}, ответил {last_bad[1]} "
          f"(тир провайдера: {last_bad[2]})")
if providers:
    print("  кто фактически отвечал: " +
          ", ".join(f"{k} ×{v}" for k, v in providers.most_common(6)))
PY
fi
report_proof "tail -5 $HIST (записи handler=ask: tier/served_tier/provider/provider_tier)"

# ── 2. здоровье провайдеров ──────────────────────────────────────────────────
report_section "🏥 ПРОВАЙДЕРЫ LLM (данные балансировщика)"
if command -v curl >/dev/null 2>&1 && curl -s --max-time 6 "$BAL" -o /tmp/hermes-models-health.$$ 2>/dev/null \
   && [[ -s /tmp/hermes-models-health.$$ ]]; then
  BAL_FILE="/tmp/hermes-models-health.$$" python3 - <<'PY'
import json, os
try:
    d = json.load(open(os.environ["BAL_FILE"], encoding="utf-8"))
except Exception as e:
    print(f"  ⚠️ ответ балансировщика не разобран: {e}")
    raise SystemExit(0)
lb = d.get("llm_balancer") or {}
provs = lb.get("providers") or []
healthy = [p for p in provs if p.get("healthy")]
print(f"  провайдеров {len(provs)} · по данным балансировщика здоровых {len(healthy)} · "
      f"кэш ответов {lb.get('cache_size')}")
dead = [p for p in provs if not p.get("healthy")]
for p in dead:
    print(f"  🔴 {p.get('name')} (тир {p.get('tier')}) помечен как нездоровый")
keyless = [p for p in provs if not p.get("keys_count")]
if keyless:
    print("  ⚠️ без ключей: " + ", ".join(f"{p.get('name')} (тир {p.get('tier')})" for p in keyless))
by_tier = {}
for p in provs:
    t = by_tier.setdefault(str(p.get("tier")), [0, 0])
    t[0] += 1
    t[1] += 1 if p.get("healthy") else 0
for tier, (total, ok) in sorted(by_tier.items()):
    mark = "✅" if ok else "🔴"
    print(f"  {mark} тир {tier:13s} провайдеров {total} · здоровых {ok}")
PY
  rm -f /tmp/hermes-models-health.$$
else
  report_warn "балансировщик не ответил на $BAL — здоровье провайдеров неизвестно"
fi
report_proof "curl -s $BAL (llm_balancer.providers: tier/healthy/keys_count)"

# ── 3. известные обрывы пути ─────────────────────────────────────────────────
report_section "🔌 ЧЕГО НЕ ХВАТАЕТ ПРЯМО СЕЙЧАС"
# systemctl печатает состояние в stdout И возвращает ненулевой код — без || true
# в переменную попадало «inactive\nunknown» (видно было в отчёте).
OLLAMA="$(systemctl is-active ollama 2>/dev/null || true)"; OLLAMA="${OLLAMA:-unknown}"
if [[ "$OLLAMA" == "active" ]]; then
  report_ok "локальная модель (ollama) работает — бесплатный путь есть"
else
  report_warn "служба ollama: $OLLAMA — тир local не может ответить (балансировщик отдаёт служебный текст, шина отвечает 502)"
  report_info "включить: systemctl start ollama (модель 3B, ~2 ГБ RAM при первом запросе)"
fi
report_info "тир code: если провайдеры тира нездоровы, «кодовый» запрос обслужит fast-модель — это видно как ⚠️ выше"

# ── 4. итог ──────────────────────────────────────────────────────────────────
report_section "📈 ИТОГ"
SERVED="$(curl -s --max-time 5 http://127.0.0.1:9700/metrics 2>/dev/null | grep -E '^llm_(served_tier_total|tier_mismatch_total)' | tr '\n' ' ')"
if [[ -n "$SERVED" ]]; then
  report_kv "шлюз (за время работы)" "$(printf '%s' "$SERVED" | tr -s ' ')"
  report_proof "curl -s localhost:9700/metrics | grep -E 'llm_(served_tier_total|tier_mismatch_total)'"
else
  report_unknown "счётчики шлюза недоступны (:9700/metrics)"
fi
report_footer "ИТОГ: отчёт по моделям собран (история прогонов + здоровье провайдеров, без запросов к модели)"
