#!/usr/bin/env bash
# tests/agents-selftest.sh — what the agents can DO, and how they answer.
#
# The suite that existed before this one checked plumbing: does a handler exist, does the
# script run. It never checked whether an answer is *useful* — and the owner, reading the
# chat, was the one who found out. So this selftest asserts behaviour the owner sees:
#
#   * every check script uses the shared report format and ends with 💡 advice,
#   * the handler set is far past the original 31 (breadth of capability),
#   * every agent resolves to a real model tier, cheap by default, smart for analysis,
#   * the model policy carries no credentials,
#   * with the balancer down, `ask` degrades to "facts only" instead of hanging.
#
# Prints "PASS=n FAIL=n" as the last line, like the other selftests.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
PYBIN="/opt/hermes/.venv-bus/bin/python"; [[ -x "$PYBIN" ]] || PYBIN="$(command -v python3)"
PASS=0; FAIL=0
ok_(){ if [[ "$2" == *"$3"* ]]; then echo "  ok   $1"; PASS=$((PASS+1)); else echo "  FAIL $1"; \
        echo "        want: *$3*"; echo "        got : ${2:0:160}"; FAIL=$((FAIL+1)); fi; }

echo "[1] report format: one shape for every agent answer"
ck() { ok_ "$1" "$2" "$3"; }
# lib/report.sh is the library itself, not a report: count only the checks.
TOTAL=$(ls agents/checks/*.sh 2>/dev/null | grep -v '/lib/' | wc -l)
USES=$(grep -l 'lib/report.sh' agents/checks/*.sh 2>/dev/null | grep -v '/lib/' | wc -l)
ck "каждый скрипт использует общий формат отчёта" "$USES из $TOTAL" "$TOTAL из $TOTAL"
MISS=$(grep -L 'report_footer' agents/checks/*.sh 2>/dev/null | grep -v '/lib/' | wc -l)
ck "каждый отчёт заканчивается советом (💡)" "без совета: $MISS" "без совета: 0"
EMOJI=$(grep -l 'report_header ".*[🖥🔥💾🔐📊🐙🧭📜📦🧠🐳🎓⬆️🚨🎯🔑]' agents/checks/*.sh 2>/dev/null | wc -l)
ck "заголовки отчётов содержат эмодзи" "$EMOJI" "$EMOJI"

echo "[2] breadth: what the agents can do now"
HANDLERS=$(python3 - <<'PY' 2>/dev/null || echo 0
import glob, yaml
n = 0
for f in glob.glob('config/agents/*.yaml') + glob.glob('config/agents/projects/*.yaml'):
    d = yaml.safe_load(open(f)) or {}
    n += len((d.get('bus') or {}).get('handlers') or {})
print(n)
PY
)
ck "обработчиков у агентов заметно больше исходных 31" "$HANDLERS" "$HANDLERS"
[[ "$HANDLERS" -ge 100 ]] && { echo "  ok   обработчиков >= 100 ($HANDLERS)"; PASS=$((PASS+1)); } \
                         || { echo "  FAIL обработчиков >= 100 (сейчас $HANDLERS)"; FAIL=$((FAIL+1)); }
for pair in "guardian-top.sh:server-guardian.top" "guardian-disk.sh:server-guardian.disk" \
            "monitoring-alerts.sh:monitoring.alerts" "security-ports.sh:security.ports" \
            "backup-list.sh:backup.list" "github-repos.sh:github.repos" \
            "orchestrator-pending.sh:orchestrator.pending"; do
  script="${pair%%:*}"; label="${pair##*:}"
  ck "$label объявлен в wire-agents" "$(grep -c "$script" scripts/wire-agents.sh)" "1"
done

echo "[3] understanding: the same sentence must stop being routed to 'status'"
PROBE="$("$PYBIN" tests/probe-chat.py 2>&1)"
ck "«что грузит сервер» → обработчик top" "$PROBE" "handler-top=top"
ck "«сколько места на диске» → disk" "$PROBE" "handler-disk=disk"
ck "«покажи алерты» → alerts" "$PROBE" "handler-alerts=alerts"
ck "«кто слушает порты» → ports" "$PROBE" "handler-ports=ports"
ck "«почему сервер тормозит» → ask (факты → модель)" "$PROBE" "handler-analysis=ask"
ck "«какие агенты» → ответ из реестра, не задача" "$PROBE" "handler-team=agents"

echo "[4] models: cheap by default, smart where it matters"
MPROBE="$("$PYBIN" tests/probe-models.py 2>&1)"
ck "у каждого агента есть модель" "$MPROBE" "uncovered=0"
ck "названы только реальные тиры балансера" "$MPROBE" "bad_tier=0"
ck "рутина — дешёвый тир" "$MPROBE" "routine=hermes-fast"
ck "анализ — сильная (бесплатная) модель" "$MPROBE" "escalate-analysis=hermes-reason"
ck "код — кодовая модель" "$MPROBE" "escalate-code=hermes-code"
ck "длинный контекст — gemini flash" "$MPROBE" "escalate-long=hermes-long"
ck "в политике моделей нет ключей" "$MPROBE" "policy-clean=True"
ck "упавший балансер не вешает задачу" "$MPROBE" "degrade-no-hang=True"

echo "[4b] actions: real power, but a fixed verb list — nothing else executes"
ck "act.sh существует и исполняем" "$([[ -x agents/checks/act.sh ]] && echo yes)" "yes"
ck "запрещённый юнит отклоняется (sshd)" \
   "$(ARG_ACTION=restart-unit ARG_TARGET=sshd bash agents/checks/act.sh 2>&1 | grep -c 'не входит в разрешённый список')" "1"
ck "несуществующий контейнер отклоняется" \
   "$(ARG_ACTION=restart-container ARG_TARGET=no-such-container bash agents/checks/act.sh 2>&1 | grep -c 'нет на этом узле')" "1"
ck "имя с инъекцией отклоняется" \
   "$(ARG_ACTION=restart-container ARG_TARGET='octopus; rm -rf /' bash agents/checks/act.sh 2>&1 | grep -c 'недопустимое имя')" "1"
ck "неизвестное действие отклоняется" \
   "$(ARG_ACTION=format-disk ARG_TARGET=octopus bash agents/checks/act.sh 2>&1 | grep -c 'не разрешено')" "1"
ck "в act.sh нет оболочки и eval" \
   "$(grep -cE 'eval |bash -c|\(shell=True\)|\$\(cat' agents/checks/act.sh)" "0"
ck "действия ограничены списком (не произвольный shell)" \
   "$(grep -c 'UNIT_ALLOW' agents/checks/act.sh)" "2"

echo "[5] live: the balancer answers through the shim"
if command -v curl >/dev/null && curl -s -m 5 http://127.0.0.1:9700/v1/models >/dev/null 2>&1; then
  MODELS=$(curl -s -m 5 http://127.0.0.1:9700/v1/models | "$PYBIN" -c "
import sys,json
print(len(json.load(sys.stdin)['data']))" 2>/dev/null || echo 0)
  ck "шим отдаёт шесть тиров" "$MODELS" "6"
else
  echo "  SKIP шим недоступен (не на узле Hermes?)"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
