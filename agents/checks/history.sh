#!/usr/bin/env bash
# Что агенты делали, что из этого падало и сколько это занимало. Read-only.
#
# Читает /var/lib/hermes-agents/history.jsonl — по строке на каждый запуск обработчика
# (пишет agents/runtime.py: агент, обработчик, кто попросил, код возврата, время, журнал).
# ARG_N — сколько последних записей смотреть (по умолчанию 500), ARG_AGENT — фильтр.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
HIST="${HERMES_HISTORY_FILE:-/var/lib/hermes-agents/history.jsonl}"
N="${ARG_N:-500}"
FILTER="${ARG_AGENT:-}"
report_header "🕓 ЧТО ДЕЛАЛИ АГЕНТЫ"

if [[ ! -s "$HIST" ]]; then
  report_section "📊 ИСТОРИЯ ПРОГОНОВ"
  report_warn "истории ещё нет: ни один обработчик не запускался через runtime"
  report_unknown "агенты пока ничего не делали — это не ошибка, а отсутствие данных"
  report_proof "ls -l $HIST"
  report_footer "запустить проверку: bash /opt/hermes/agents/checks/guardian-disk.sh" \
                "после первого прогона здесь появятся агенты, ошибки и задержки"
  exit 0
fi

HIST_FILE="$HIST" LIMIT="$N" FILTER="$FILTER" python3 - <<'PY'
import json, os, time
from collections import defaultdict

path = os.environ["HIST_FILE"]
limit = int(os.environ["LIMIT"] or 500)
filt = os.environ["FILTER"]
now = time.time()

rows = []
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue          # обрывок строки — не повод потерять остальные
except OSError as e:
    print(f"  ⚠️ не читается {path}: {e}")
    raise SystemExit(0)


def pct(vals, p):
    if not vals:
        return 0
    vals = sorted(vals)
    k = max(0, min(len(vals) - 1, int(round((p / 100) * (len(vals) - 1)))))
    return vals[k]


def ago(epoch):
    if not epoch:
        return "—"
    d = int(now - epoch)
    if d < 60:
        return f"{d} с назад"
    if d < 3600:
        return f"{d // 60} мин назад"
    if d < 86400:
        return f"{d // 3600} ч назад"
    return f"{d // 86400} дн назад"


window = rows[-limit:]
if filt:
    window = [r for r in window if filt in str(r.get("agent", ""))]
if not window:
    print("  (нет записей в окне)")
    print(f"\n  ↳ доказательство: {path} · фильтр «{filt}»")
    raise SystemExit(0)

per = defaultdict(lambda: {"runs": 0, "fail": 0, "fail1h": 0, "dur": [], "last": 0,
                           "last_fail": 0, "log": "", "what": ""})
for r in window:
    a = per[str(r.get("agent", "?"))]
    a["runs"] += 1
    a["dur"].append(int(r.get("took_ms") or 0))
    epoch = int(r.get("epoch") or 0)
    a["last"] = max(a["last"], epoch)
    if int(r.get("code") or 0) != 0:
        a["fail"] += 1
        if now - epoch <= 3600:
            a["fail1h"] += 1
        if epoch >= a["last_fail"]:
            a["last_fail"] = epoch
            a["log"] = str(r.get("log") or "")
            a["what"] = f"{r.get('handler', '?')} — код {r.get('code')} · «{str(r.get('summary', ''))[:60]}»"

print(f"\n📊 ПОСЛЕДНИЕ {len(window)} ЗАПИСЕЙ" + (f" · фильтр «{filt}»" if filt else ""))
print(f"  {'агент':<34}{'запусков':>9}{'ошибок':>7}{'p50':>9}{'p95':>9}   последний")
for name, a in sorted(per.items(), key=lambda kv: (-kv[1]["fail"], kv[0])):
    print(f"  {name[:33]:<34}{a['runs']:>9}{a['fail']:>7}"
          f"{pct(a['dur'], 50):>7}мс{pct(a['dur'], 95):>7}мс   {ago(a['last'])}")

# Источник — всегда, а не только когда что-то упало: отчёт обязан называть файл, из которого
# взяты числа (конвенция report_proof, см. docs/AGENT-IMPROVEMENTS.md).
print(f"  ↳ доказательство: {path} · записей в файле {len(rows)}, в окне {len(window)}")

fails = [(n, a) for n, a in per.items() if a["fail"]]
print("\n" + ("🔴 ОШИБКИ" if fails else "✅ ОШИБОК НЕТ"))
for name, a in sorted(fails, key=lambda kv: -kv[1]["last_fail"])[:5]:
    print(f"  {name} · {a['what']} · {ago(a['last_fail'])}")
    print(f"     ↳ доказательство: {path}")
    if a["log"]:
        print(f"     ↳ журнал: {a['log']}")
if not fails:
    print("   проблемных прогонов в окне не было")

print("\n💡 ЧТО ДЕЛАТЬ")
if fails:
    print("  • открыть журнал из строки выше — там весь вывод и код возврата")
    print("  • если ошибка повторяется: «статус сервера» покажет состояние узла целиком")
else:
    print("  • ничего: агенты отвечают, ошибок в окне нет")
slow = max(per.items(), key=lambda kv: pct(kv[1]["dur"], 95))
if pct(slow[1]["dur"], 95) > 60000:
    print(f"  • {slow[0]}: p95 {pct(slow[1]['dur'], 95)} мс — обработчик почти упирается в таймаут")
print(f"  • полная история: tail -20 {path}          (ротация: {path}.1 … .3)")
PY
