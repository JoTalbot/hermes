#!/usr/bin/env bash
# tests/run.sh — contract tests for the shipped files. No network, no server access.
# It runs deploy/shim/aios_openai_shim.py against tests/fake_aios.py, which replays the
# balancer's MEASURED contract (422-on-missing-goal included). If the shim drifts from the
# real API shape, these tests go red — which is the point.
set -uo pipefail
# Resolve the repo root from THIS file. Relying on `git rev-parse` meant that running the
# suite by absolute path from another directory (e.g. `bash /opt/hermes/tests/run.sh` out of
# /root) turned every gate into "no such file" — 25 red lines that described the caller's
# cwd, not the code.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$PWD"
PASS=0; FAIL=0; SKIP=0
ck(){ local name="$1" want="$2" got="$3"
  if [[ "$got" == *"$want"* ]]; then echo "  ok   $name"; PASS=$((PASS+1))
  else echo "  FAIL $name"; echo "        want: *$want*"; echo "        got : ${got:0:200}"; FAIL=$((FAIL+1)); fi; }
skip(){ echo "  SKIP $1 ($2)"; SKIP=$((SKIP+1)); }

echo "[1] syntax: python + every shell script"
python3 -m py_compile deploy/shim/aios_openai_shim.py tests/fake_aios.py 2>&1 | grep -q . && ck "py_compile" "" "FAIL" || ck "py_compile" "" "ok"
for f in scripts/*.sh; do bash -n "$f" 2>&1 | grep -q . && ck "bash -n $f" "" "FAIL" || ck "bash -n $f" "" "ok"; done

echo "[2] yaml: every config parses and keeps required safety fields"
out=$(python3 - <<'PY' 2>&1
import glob, sys, yaml
bad=[]
for f in glob.glob('config/**/*.yaml', recursive=True):
    try:
        d=yaml.safe_load(open(f))
        if f.startswith('config/agents/') and 'projects/README' not in f and isinstance(d,dict):
            for k in ('profile','safety'):
                if k not in d: bad.append(f"{f}: missing {k}")
            if 'destructive_operations' not in d.get('safety',{}) and d.get('status')=='active':
                bad.append(f"{f}: active agent without destructive_operations")
            if d.get('status')=='active' and not str(d['profile'].get('workdir','')).startswith('/'):
                bad.append(f"{f}: workdir not absolute")
    except Exception as e: bad.append(f"{f}: {e}")
print("\n".join(bad) or "OK")
PY
)
ck "yaml configs valid" "OK" "$out"

echo "[3] shim: auth, upstream failure, happy path, models, metrics"
python3 tests/fake_aios.py & FAKE=$!
AIOS_BRIDGE_URL=http://127.0.0.1:9699 HERMES_SHIM_PORT=9799 HERMES_BALANCER_API_KEY=t \
  python3 deploy/shim/aios_openai_shim.py >/tmp/shim.log 2>&1 & SHIM=$!
sleep 1.5
ck "health" '"ok": true' "$(curl -s http://127.0.0.1:9799/health)"
ck "no-token → 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:9799/v1/chat/completions -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"x"}]}')"
ck "chat round-trip" "FAKE_OK[code]" "$(curl -s -H 'Authorization: Bearer t' -X POST http://127.0.0.1:9799/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"hermes-code","messages":[{"role":"system","content":"s"},{"role":"user","content":"u"}]}')"
ck "OpenAI shape" '"choices"' "$(curl -s -H 'Authorization: Bearer t' -X POST http://127.0.0.1:9799/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"hermes-fast","messages":[{"role":"user","content":"u"}]}')"
ck "usage present" "total_tokens" "$(curl -s -H 'Authorization: Bearer t' -X POST http://127.0.0.1:9799/v1/chat/completions -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"u"}]}')"
ck "unknown route 404" "not_found" "$(curl -s -X POST http://127.0.0.1:9799/v1/completions -H 'Content-Type: application/json' -d '{}')"
ck "empty messages 400" "messages" "$(curl -s -X POST http://127.0.0.1:9799/v1/chat/completions -H 'Authorization: Bearer t' -H 'Content-Type: application/json' -d '{"model":"hermes-fast","messages":[]}')"
ck "/v1/models lists aliases" "hermes-auto" "$(curl -s http://127.0.0.1:9799/v1/models)"
ck "/metrics prometheus" "llm_requests_total" "$(curl -s http://127.0.0.1:9799/metrics)"
kill $SHIM $FAKE 2>/dev/null; wait $SHIM $FAKE 2>/dev/null
sleep 0.3
echo "[4] shim: refuses to start unauthenticated by default"
ck "no-key refusal" "Refusing to start" "$(HERMES_BALANCER_API_KEY= AIOS_BRIDGE_URL=http://127.0.0.1:9699 HERMES_SHIM_PORT=9798 timeout 3 python3 deploy/shim/aios_openai_shim.py 2>&1)"
echo "[5] secret scanner"
# Fixtures must not contain the literals the scanner hunts for, or the scanner correctly
# flags this very test file (it did). Both samples are assembled at runtime.
tok_prefix="ghp_"; tok_body=$(printf '%036d' 7 | tr 0 A)
pem_head="-----BEGIN OPENSSH"; pem_tail="PRIVATE KEY-----"
tmp=$(mktemp -d); mkdir -p "$tmp/scripts"; cp .gitignore "$tmp"/; cp scripts/secret-scan.sh "$tmp"/scripts/
( cd "$tmp" && git init -q . && printf 'token=%s%s\n' "$tok_prefix" "$tok_body" > leak.txt )
ck "catches synthetic ghp token" "finding(s)" "$(bash scripts/secret-scan.sh --worktree "$tmp" 2>&1)"
( cd "$tmp" && printf '%s %s\nabc\n' "$pem_head" "$pem_tail" > leak2.txt )
ck "catches PEM header" "finding(s)" "$(bash scripts/secret-scan.sh --worktree "$tmp" 2>&1)"
( cd "$tmp" && rm -f leak.txt leak2.txt )
ck "passes when clean" "clean" "$(bash scripts/secret-scan.sh --worktree "$tmp" 2>&1)"
rm -rf "$tmp"
echo "[6] generator validation (must refuse untrustworthy input)"
t=$(mktemp); printf 'slug\tpath\tbranch\torigin\tdirty\tlang\tgit_ok\nfoo\t/opt/foo\tmain\tfoo\t0\tpython\t0\n' > "$t"
ck "refuses git_ok=0" "REFUSING to write profiles" "$(ALLOW_UNREADABLE=0 bash scripts/gen-project-agents.sh "$t" 2>&1)"
printf 'slug\tpath\tbranch\torigin\tdirty\tlang\tgit_ok\nfoo\t/opt/foo\tmain\tfoo\t0\tpython\t1\nfoo\t/opt/foo2\tmain\tfoo\t0\tpython\t1\n' > "$t"
ck "refuses duplicate slugs" "duplicate slugs" "$(bash scripts/gen-project-agents.sh "$t" 2>&1)"
rm -f "$t"
echo "[7] doctor.sh is well-formed and dry-runnable"
# Was a magic constant ("12"), which broke the moment a gate was ADDED — a test that
# fails on improvement teaches people to ignore it. Assert the property instead:
# enough gates, numbered contiguously from 1, and the ones we care about present.
sections=$(grep -cE '^# [0-9]+\.' scripts/doctor.sh)
ck "doctor has at least 12 gate areas" "yes" "$( (( sections >= 12 )) && echo yes || echo "no: $sections" )"
nums=$(grep -oE '^# [0-9]+\.' scripts/doctor.sh | sed 's/^# //; s/\.$//' || true)
maxn=$(printf '%s\n' $nums | sort -n | tail -1)
uniqn=$(printf '%s\n' $nums | sort -nu | wc -l)
ck "doctor gate numbers contiguous 1..N" "yes" "$( [[ "$maxn" == "$uniqn" ]] && echo yes || echo "gap: max=$maxn unique=$uniqn" )"
ck "doctor covers the backup gate" "yes" "$( grep -qE '^# 13\. Backups' scripts/doctor.sh && echo yes || echo no )"
ck "doctor verdict strings present" "SYSTEM HEALTH: HEALTHY" "$(grep -o 'SYSTEM HEALTH: HEALTHY' scripts/doctor.sh)"
ck "secret scan clean on repo" "clean" "$(bash scripts/secret-scan.sh --worktree)"
echo "[8] agent bus + agent wiring (static)"
ck "bus.py compiles" "ok" "$(python3 -m py_compile bus/bus.py && echo ok || echo fail)"
ck "bus_bridge.py compiles" "ok" "$(python3 -m py_compile bus/bus_bridge.py && echo ok || echo fail)"
ck "runtime.py compiles" "ok" "$(python3 -m py_compile agents/runtime.py && echo ok || echo fail)"
ck "agent wiring in sync (scripts/wire-agents.sh --check)" "in sync" \
   "$(bash scripts/wire-agents.sh --check 2>&1 | tail -1)"
ck "agent ids unique + capabilities non-empty + a status handler" "ok" "$(
python3 - <<'PYEOF'
import glob, sys, yaml
ids, problems = set(), []
for f in glob.glob("config/agents/*.yaml") + glob.glob("config/agents/projects/*.yaml"):
    d = yaml.safe_load(open(f)) or {}
    b = d.get("bus") or {}
    aid = b.get("agent_id")
    if not aid:
        problems.append(f"{f}: no bus.agent_id"); continue
    if aid in ids:
        problems.append(f"{f}: duplicate agent_id {aid}")
    ids.add(aid)
    if not b.get("capabilities"):
        problems.append(f"{aid}: no capabilities")
    if not b.get("handlers"):
        problems.append(f"{aid}: no handlers")
print("ok" if not problems else "; ".join(problems[:4]))
PYEOF
)"
ck "every declared handler script exists" "ok" "$(
python3 - <<'PYEOF'
import glob, os, shlex, yaml
missing = []
for f in glob.glob("config/agents/*.yaml") + glob.glob("config/agents/projects/*.yaml"):
    d = yaml.safe_load(open(f)) or {}
    for name, spec in ((d.get("bus") or {}).get("handlers") or {}).items():
        if not isinstance(spec, dict) or not spec.get("run"):
            continue
        parts = shlex.split(spec["run"])
        script = next((p for p in parts if p.endswith(".sh")), None)
        if script and not os.path.exists(script):
            missing.append(f"{f}:{name}->{script}")
print("ok" if not missing else "; ".join(missing[:4]))
PYEOF
)"
ck "agent actions stay inside /opt/hermes (no handler runs outside the managed scope)" "ok" "$(
grep -hE 'run: bash' config/agents/*.yaml config/agents/projects/*.yaml | grep -v '/opt/hermes' | head -3 | \
  { read -r l && echo "outside: $l" || echo ok; }
)"
echo "[9] agent bus: live round trip (skipped when the bus is down)"
if systemctl is-active --quiet nats-server 2>/dev/null; then
  if bash tests/bus-selftest.sh >/tmp/bus-selftest.out 2>&1; then
    ck "live bus selftest" "PASS=10 FAIL=0 WARN=0" "$(grep -o 'PASS=[0-9]* FAIL=[0-9]* WARN=[0-9]*' /tmp/bus-selftest.out | tail -1)"
  else
    ck "live bus selftest" "PASS=10 FAIL=0 WARN=0" "$(grep -o 'PASS=[0-9]* FAIL=[0-9]* WARN=[0-9]*' /tmp/bus-selftest.out | tail -1) $(tail -3 /tmp/bus-selftest.out | tr '\n' ' ')"
  fi
else
  SKIP=$((SKIP+1)); echo "  SKIP  nats-server is not running on this host"
fi
echo "[10] telegram inbox: the owner's control plane is guarded"
ck "poll subcommand exists in the bridge" "poll" "$(grep -cE 'add_parser\(\"poll\"\)' bus/bus_bridge.py) poll"
ck "unknown chats are ignored, never executed" "non-allowlisted" "$(grep -o 'ignoring command from non-allowlisted chat' bus/bus_bridge.py | head -1)"
ck "owner text never reaches a shell" "ok" "$(grep -qE 'handle_owner_text' bus/bus_bridge.py && ! grep -qE 'shell=True|os\.system' bus/bus_bridge.py && echo ok)"
ck "inbox unit shipped for a new node" "hermes-telegram-inbox.service" "$(grep -o 'hermes-telegram-inbox.service' scripts/install-bus.sh | head -1)"
ck "inbox unit installed when a chat exists" "hermes-telegram-inbox" "$(systemctl list-unit-files 2>/dev/null | grep -o 'hermes-telegram-inbox' | head -1)"
echo "[11] owner chat: a task typed in Telegram really reaches an agent"
PYBIN="/opt/hermes/.venv-bus/bin/python"
[[ -x "$PYBIN" ]] || PYBIN="$(command -v python3)"
CHAT_PROBE="$("$PYBIN" tests/probe-chat.py 2>&1)" || true
ck "free text is routed (not handed to the alphabetically first agent)" "route-host=host-health" "$CHAT_PROBE"
ck "a named project goes to the base project, not a worktree variant" "route-project=project:logistics" "$CHAT_PROBE"
ck "a Russian alias for a project is understood" "route-alias=project:logistics" "$CHAT_PROBE"
ck "an unparsable task is refused, not routed at random" "route-unknown=(none)" "$CHAT_PROBE"
ck "owner text is HTML-escaped for Telegram" "escape=&lt;b&gt;x&lt;/b&gt; &amp; y" "$CHAT_PROBE"
ck "forwarded messages carry a readable kind header" "header-has-kind=True" "$CHAT_PROBE"
ck "multi-line agent output is shown as a monospace block" "body-mono=True" "$CHAT_PROBE"
ck "a question about a named process targets THAT process" "handler-proc=proc" "$CHAT_PROBE"
ck "the process name is extracted from the sentence" "subject-proc=chromium" "$CHAT_PROBE"
ck "a question about a container gathers container facts" "handler-docker-q=ask" "$CHAT_PROBE"
ck "an unmatched question is still answered (facts + model)" "handler-ask-fallback=ask" "$CHAT_PROBE"
ck "an action sentence routes to act with its verb and object" "action-restart=restart" "$CHAT_PROBE"
ck "the action object is extracted" "action-target=octopus-browser" "$CHAT_PROBE"
ck "«перезапусти сервер» is too broad to act on — refused" "action-refused-broad=none" "$CHAT_PROBE"
ck "internal agent DMs stay off the phone, errors always arrive" "forward=ok" "$CHAT_PROBE"
ck "a question about the team is answered, not refused" "meta-answered=True" "$CHAT_PROBE"
ck "the answer names the specialists" "meta-has-specialists=True" "$CHAT_PROBE"
ck "'какие проекты' is answered too" "meta-projects=True" "$CHAT_PROBE"
ck "the 📦 Проекты button answers" "btn-agents=True" "$CHAT_PROBE"
ck "💻 Сервер is a task, not an answer" "btn-server-is-task=True" "$CHAT_PROBE"
ck "💾 Бэкап is a task too" "btn-backup-is-task=True" "$CHAT_PROBE"
ck "free text is still a task" "free-text-is-task=True" "$CHAT_PROBE"
ck "the phone keyboard offers six actions" "keyboard-buttons=6" "$CHAT_PROBE"
ck "an unparsable task is refused in plain language, without a token dump" "refusal-friendly=True" "$CHAT_PROBE"
ck "the refusal teaches by example" "refusal-has-examples=True" "$CHAT_PROBE"
ck "a long report leaves as a file, not a truncated message" "long-reply-is-document=True" "$CHAT_PROBE"
ck "a short answer is still a message" "short-reply-is-message=True" "$CHAT_PROBE"
ck "the uploaded report is valid multipart (CRLF framing)" "multipart-crlf=True" "$CHAT_PROBE"
ck "a real report mentioning a selftest word still reaches the owner" \
   "forward-real-report=True" "$CHAT_PROBE"
ck "tagged bus-selftest messages stay off the phone" \
   "forward-selftest-tagged-silenced=True" "$CHAT_PROBE"
ck "a failed handler always reaches the owner" "forward-error-always=True" "$CHAT_PROBE"
echo "[12] agents: capabilities, answer format and model policy"
if bash tests/agents-selftest.sh >/tmp/agents-selftest.out 2>&1; then
  ck "agents selftest" "PASS=" "$(grep -o 'PASS=[0-9]* FAIL=[0-9]*' /tmp/agents-selftest.out | tail -1)_$(echo ok)"
else
  ck "agents selftest" "FAIL=0" "$(grep -o 'PASS=[0-9]* FAIL=[0-9]*' /tmp/agents-selftest.out | tail -1)"
fi
echo "[13] resilience: memory protection and alerts that actually reach the owner"
ck "host pressure is measured (the box OOMs on someone else's browser)" \
   "def probe_host_pressure" "$(grep -o 'def probe_host_pressure' scripts/hermes_metrics_exporter.py | head -1)"
ck "an unreadable project is not reported as a missing one" \
   "def _path_state" "$(grep -o 'def _path_state' scripts/hermes_metrics_exporter.py | head -1)"
ck "path present is tri-state in HELP (0/1/2)" "0 if absent" \
   "$(grep -o '0 if absent' scripts/hermes_metrics_exporter.py | head -1)"
ck "pressure probes are actually wired into the exporter" "probe_host_pressure," \
   "$(grep -o 'probe_host_pressure,' scripts/hermes_metrics_exporter.py | head -1)"
ck "memory pressure rules exist" "HermesHostMemoryPressure" \
   "$(grep -o 'HermesHostMemoryPressure' deploy/monitoring/hermes-agents.rules.yml | head -1)"
ck "swap rule exists" "HermesHostSwapFull" \
   "$(grep -o 'HermesHostSwapFull' deploy/monitoring/hermes-agents.rules.yml | head -1)"
ck "unprotected-Hermes rule exists" "HermesUnprotectedFromOOM" \
   "$(grep -o 'HermesUnprotectedFromOOM' deploy/monitoring/hermes-agents.rules.yml | head -1)"
ck "alert rules parse" "ok" "$(python3 -c 'import yaml;yaml.safe_load(open("deploy/monitoring/hermes-agents.rules.yml"));print("ok")' 2>/dev/null)"
ck "units are pinned above ordinary processes (OOMScoreAdjust)" "OOMScoreAdjust" \
   "$(grep -o 'OOMScoreAdjust' scripts/install-protection.sh | head -1)"
ck "memory ceilings are set, not left infinite" "MemoryMax" \
   "$(grep -o 'MemoryMax=\${max}' scripts/install-protection.sh | head -1)"
ck "protection installer is revertible" "revert" \
   "$(grep -o '^  revert)' scripts/install-protection.sh | head -1)"
ck "alerts are deduplicated between polls" "alert-state.json" \
   "$(grep -o 'alert-state.json' scripts/hermes-alert-poller.py | head -1)"
ck "a repeat is rate-limited, not repeated every poll" "REPEAT_AFTER" \
   "$(grep -o 'REPEAT_AFTER' scripts/hermes-alert-poller.py | head -1)"
ck "the poller groups noisy alerts instead of sending one message each" "format_group" \
   "$(grep -o 'def format_group' scripts/hermes-alert-poller.py | head -1)"
ck "an alert carries an actionable hint, not just a rule name" "HINTS" \
   "$(grep -o 'HINTS = {' scripts/hermes-alert-poller.py | head -1)"
ck "poller unit survives a crash (Restart=always)" "Restart=always" \
   "$(grep -o 'Restart=always' scripts/install-alerting.sh | head -1)"
# NOTE: `systemctl ... | grep -q` under `set -o pipefail` is always "false" — grep exits on
# the first match, systemctl dies of SIGPIPE (141) and pipefail reports failure. Hence the
# captured variable instead of a pipe: v1 of this gate silently skipped the live checks.
UNIT_FILES="$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null || true)"
if grep -q 'hermes-alert-poller' <<<"$UNIT_FILES"; then
  if bash scripts/install-alerting.sh --check >/tmp/alerting-check.out 2>&1; then
    ck "live: alerting reaches the owner" "ALERTING: OK" "$(grep -o 'ALERTING: OK' /tmp/alerting-check.out | head -1)"
  else
    ck "live: alerting reaches the owner" "ALERTING: OK" "$(tail -1 /tmp/alerting-check.out)"
  fi
  ck "live: memory protection is in force" "PROTECTION: OK" \
     "$(bash scripts/install-protection.sh --check 2>&1 | grep -o 'PROTECTION: OK' | head -1)"
else
  ((SKIP++)); ((SKIP++))
  echo "  ~ live alerting/protection checks skipped (юниты не установлены здесь)"
fi
echo "[14] restore and installation gaps: the things that failed silently"
ck "wire-agents refuses to run without a YAML-capable interpreter" \
   "не умеет читать YAML" "$(grep -o 'не умеет читать YAML' scripts/wire-agents.sh | head -1)"
ck "wire-agents prefers the bus venv (system python3 may lack PyYAML)" \
   ".venv-bus/bin/python" "$(grep -o '\${REPO_DIR}/.venv-bus/bin/python' scripts/wire-agents.sh | head -1)"
ck "install-agent-runtime resolves the node-scoped agent id" \
   'invoke "${FIRST_AGENT' "$(grep -o 'invoke \"\${FIRST_AGENT' scripts/install-agent-runtime.sh | head -1)"
ck "restore exports REPO_DIR so install uses the code it restored with" \
   "export REPO_DIR HERMES_HOME" "$(grep -o 'export REPO_DIR HERMES_HOME' scripts/restore.sh | head -1)"
ck "restore puts the node config back (allowlist, node role, bus state)" \
   "node configuration" "$(grep -o 'node configuration' scripts/restore.sh | head -1)"
ck "restore does not abort on SIGPIPE from head" \
   "awk 'NR <= 12'" "$(grep -o "awk 'NR <= 12'" scripts/restore.sh | head -1)"
ck "backup includes node config and bus state" \
   "nodecfg" "$(grep -o 'hermes-nodecfg-' scripts/backup.sh | head -1)"
# Проверяем ИМЕННО список включений (строки «for f in ...»), а не комментарий рядом:
# подстрока «telegram.env» встречается в пояснении и ловилась старым выражением.
BACKUP_INCLUDES="$(grep -h '^for f in' scripts/backup.sh)"
ck "backup includes only non-secret node config" "0" \
   "$(printf '%s' "$BACKUP_INCLUDES" | grep -cE 'telegram\.env|nats\.env|shim\.env|password|credentials')"
ck "pending tasks expire instead of waiting forever" \
   "def expire_pending" "$(grep -o 'def expire_pending' agents/runtime.py | head -1)"
ck "an expired task is reported to the owner" \
   "def sweep_pending" "$(grep -o 'def sweep_pending' agents/runtime.py | head -1)"
ck "overdue tasks are exported as a metric" \
   "hermes_agents_pending_overdue" "$(grep -o 'hermes_agents_pending_overdue' scripts/hermes_metrics_exporter.py | head -1)"
ck "a rule fires when a task has no answer for six hours" \
   "HermesPendingOverdue" "$(grep -o 'HermesPendingOverdue' deploy/monitoring/hermes-agents.rules.yml | head -1)"
ck "the /pending report knows about the TTL" \
   "старше" "$(grep -o 'старше' agents/checks/orchestrator-pending.sh | head -1)"
ck "log rotation is shipped as a rule" \
   "copytruncate" "$(grep -o 'copytruncate' deploy/logrotate/hermes | head -1)"
ck "log rotation runs as root without a signal to the writer" \
   "su root root" "$(grep -o 'su root root' deploy/logrotate/hermes | head -1)"
ck "the model policy has its own installer" \
   "MODEL-POLICY: OK" "$(grep -o 'MODEL-POLICY: OK' scripts/install-model-policy.sh | head -1)"
ck "install.sh checks both config gaps" "install-model-policy.sh" \
   "$(grep -o 'install-model-policy.sh' scripts/install.sh | head -1)"
ck "bootstrap.sh checks both config gaps" "install-logrotate.sh" \
   "$(grep -o 'install-logrotate.sh' scripts/bootstrap.sh | head -1)"
ck "install-agent-runtime.sh checks both config gaps" "install-model-policy.sh" \
   "$(grep -o 'install-model-policy.sh' scripts/install-agent-runtime.sh | head -1)"
if [[ -s config/models.yaml ]]; then
  if bash scripts/install-model-policy.sh --check >/tmp/mp.out 2>&1; then
    ck "live: the model policy actually loads" "MODEL-POLICY: OK" "$(grep -o 'MODEL-POLICY: OK' /tmp/mp.out | head -1)"
  else
    ck "live: the model policy actually loads" "MODEL-POLICY: OK" "$(tail -1 /tmp/mp.out)"
  fi
else
  ((SKIP++)); echo "  ~ model policy check skipped (нет config/models.yaml в этом дереве)"
fi
if [[ -f /etc/logrotate.d/hermes ]]; then
  ck "live: log rotation is installed here" "LOGROTATE: OK" \
     "$(bash scripts/install-logrotate.sh --check 2>&1 | grep -o 'LOGROTATE: OK' | head -1)"
else
  ((SKIP++)); echo "  ~ logrotate check skipped (правило не установлено здесь)"
fi
ck "a project report never claims clean state it could not read" \
   "git не читает этот репозиторий" "$(grep -o 'git не читает этот репозиторий' agents/checks/project-check.sh | head -1)"
ck "the fix for unreadable repos is shipped" "GIT-SAFETY: OK" \
   "$(grep -o 'GIT-SAFETY: OK' scripts/install-git-safety.sh | head -1)"
ck "the runtime installer hands the agent git access to its projects" "install-git-safety.sh" \
   "$(grep -o 'install-git-safety.sh' scripts/install-agent-runtime.sh | head -1)"
# Живая проверка на самом узле: репозиторий, принадлежащий другому пользователю, не должен
# выглядеть «чистым», а после починки — должен читаться.
if command -v git >/dev/null && command -v useradd >/dev/null && [[ "$(id -u)" == "0" ]]; then
  TMPD="$(mktemp -d)"; mkdir -p "$TMPD/repo"
  git -C "$TMPD/repo" init -q 2>/dev/null
  git -C "$TMPD/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if id -u testsafe >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin testsafe 2>/dev/null; then
    chown -R testsafe:testsafe "$TMPD/repo"
    OUT="$(PROJECT_SLUG=t PROJECT_PATH="$TMPD/repo" bash agents/checks/project-check.sh 2>&1)"
    ck "live: чужой репозиторий не выдаётся за чистый" "НЕИЗВЕСТНО" "$OUT"
    ck "live: в отчёте названа причина, а не только факт" "dubious ownership" "$OUT"
    chown -R root:root "$TMPD/repo"
    OUT2="$(PROJECT_SLUG=t PROJECT_PATH="$TMPD/repo" bash agents/checks/project-check.sh 2>&1)"
    ck "live: свой репозиторий читается и отчёт честный" "дерево чистое" "$OUT2"
  else
    ((SKIP++)); ((SKIP++))
  fi
  rm -rf "$TMPD"
else
  ((SKIP++)); ((SKIP++)); echo "  ~ live git-ownership checks skipped (нужен root и git)"
fi
if ls /var/backups/hermes/hermes-nodecfg-*.tar.gz >/dev/null 2>&1; then
  ck "live: the newest backup carries node config" "hermes-nodecfg-" \
     "$(ls -1t /var/backups/hermes/hermes-nodecfg-*.tar.gz | head -1 | sed 's|.*/||' | cut -c1-15)"
else
  ((SKIP++)); echo "  ~ nodecfg backup check skipped (бэкап ещё не делался здесь)"
fi
echo "[15] agents remember their runs and show their evidence"
cd "$REPO_ROOT"
ck "report.sh carries the evidence convention" "report_proof()" \
   "$(grep -o 'report_proof()' agents/checks/lib/report.sh | head -1)"
ck "report.sh can say «посмотреть не удалось»" "report_unknown()" \
   "$(grep -o 'report_unknown()' agents/checks/lib/report.sh | head -1)"
ck "runtime records who ran what" '"agent": agent.id' \
   "$(grep -o '"agent": agent.id' agents/runtime.py | head -1)"
ck "runtime records on whose behalf" '"actor": actor' \
   "$(grep -o '"actor": actor' agents/runtime.py | head -1)"
ck "runtime keeps what the owner typed out of the history" "HISTORY_SKIP_ARGS" \
   "$(grep -o 'HISTORY_SKIP_ARGS' agents/runtime.py | head -1)"
ck "the history file is bounded by rotation, not growth" "HISTORY_MAX_BYTES" \
   "$(grep -o 'HISTORY_MAX_BYTES' agents/runtime.py | head -1)"
ck "history never breaks the work it records" "history_append" \
   "$(grep -o 'history_append' agents/runtime.py | head -1)"
ck "history.sh is the readable view of that file" "ЧТО ДЕЛАЛИ АГЕНТЫ" \
   "$(grep -o 'ЧТО ДЕЛАЛИ АГЕНТЫ' agents/checks/history.sh | head -1)"
ck "project-check cites the command behind its git verdict" "report_proof" \
   "$(grep -o 'report_proof' agents/checks/project-check.sh | head -1)"
ck "the exporter counts failed runs per agent" "hermes_agent_failures_1h" \
   "$(grep -o 'hermes_agent_failures_1h' scripts/hermes_metrics_exporter.py | head -1)"
ck "a failing agent fires an alert now" "HermesAgentFailing" \
   "$(grep -o 'HermesAgentFailing' deploy/monitoring/hermes-agents.rules.yml | head -1)"

HISTLIVE="${HERMES_HISTORY_FILE:-/var/lib/hermes-agents/history.jsonl}"
PYBIN=".venv-bus/bin/python"; [[ -x "$PYBIN" ]] || PYBIN="/opt/hermes/.venv-bus/bin/python"
[[ -x "$PYBIN" ]] || PYBIN="python3"
AG1="$("$PYBIN" agents/runtime.py list 2>/dev/null | grep -o '[^ ]*server-guardian[^ ]*' | head -1)"
if [[ -n "$AG1" ]]; then
  BEFORE=$(grep -c . "$HISTLIVE" 2>/dev/null || echo 0)
  "$PYBIN" agents/runtime.py invoke "$AG1" disk >/tmp/hist-live.out 2>&1 || true
  AFTER=$(grep -c . "$HISTLIVE" 2>/dev/null || echo 0)
  ck "live: a real handler run lands in the history" "yes" \
     "$([[ ${AFTER:-0} -gt ${BEFORE:-0} ]] && echo yes || echo "no ($BEFORE -> $AFTER)")"
  OUT3="$(ARG_N=50 bash agents/checks/history.sh 2>&1)"
  ck "live: history.sh reads that run back" "запусков" "$(printf '%s' "$OUT3" | grep -o 'запусков' | head -1)"
  ck "live: history.sh names its evidence" "доказательство" "$(printf '%s' "$OUT3" | grep -o 'доказательство' | head -1)"
else
  ((SKIP++)); ((SKIP++)); ((SKIP++)); echo "  ~ live history checks skipped (агентов в этом чекауте нет)"
fi


echo "[16] everything done in this batch: journal, lookup, scoped actions, model telemetry"
cd "$REPO_ROOT"
ck "journal lib writes per-project events" "journal_write()" \
   "$(grep -o 'journal_write()' agents/checks/lib/journal.sh | head -1)"
ck "journal lib maps an object name back to its project" "journal_slug_for()" \
   "$(grep -o 'journal_slug_for()' agents/checks/lib/journal.sh | head -1)"
ck "status reads the journal and never writes it" "ЧТО БЫЛО С ПРОЕКТОМ" \
   "$(grep -o 'ЧТО БЫЛО С ПРОЕКТОМ' agents/checks/project-check.sh | head -1)"
ck "a project run records its outcome" 'journal_write "$SLUG" run' \
   "$(grep -o 'journal_write \"\$SLUG\" run' agents/checks/project-run.sh | head -1)"
ck "install-journal is idempotent (--check mode)" "JOURNAL: OK" \
   "$(grep -o 'JOURNAL: OK' scripts/install-journal.sh | head -1)"
ck "lookup searches the unit registry" "ЮНИТ SYSTEMD" \
   "$(grep -o 'ЮНИТ SYSTEMD' agents/checks/lookup.sh | head -1)"
ck "lookup says so when an object does not exist" "report_unknown" \
   "$(grep -o 'report_unknown' agents/checks/lookup.sh | head -1)"
ck "routing sends an untyped object name to lookup" 'handler="lookup"' \
   "$(grep -o 'handler="lookup"' agents/routing.py | head -1)"
ck "routing keeps system words out of lookup" "SYSTEM_WORDS" \
   "$(grep -o 'SYSTEM_WORDS' agents/routing.py | head -1)"
ck "the octopus/top routing bug stays fixed" '\btop\b' \
   "$(grep -o -F '\btop\b' agents/routing.py | head -1)"
ck "irreversible actions need explicit confirmation" "need_confirm" \
   "$(grep -o 'need_confirm' agents/checks/act.sh | head -1)"
ck "confirmation reaches act.sh through routing" '"confirm", "days"' \
   "$(grep -o '"confirm", "days"' agents/routing.py | head -1)"
ck "backup-now is an allowed verb" "backup-now)" \
   "$(grep -o 'backup-now)' agents/checks/act.sh | head -1)"
ck "clean-old-logs deletes only old agent logs" "mtime +\"\$DAYS\"" \
   "$(grep -o 'mtime +"\$DAYS"' agents/checks/act.sh | head -1)"
ck "verify-action re-checks the object afterwards" "ВЕРДИКТ" \
   "$(grep -o 'ВЕРДИКТ' agents/checks/verify-action.sh | head -1)"
ck "runtime keeps a separate queue for background runs" "MAX_BACKGROUND" \
   "$(grep -o 'MAX_BACKGROUND' agents/runtime.py | head -1)"
ck "runtime tells the owner when a task waits too long" "ещё в очереди" \
   "$(grep -o 'ещё в очереди' agents/runtime.py | head -1)"
ck "model telemetry records the tier and the fallback" '"tier": model' \
   "$(grep -o '"tier": model' agents/runtime.py | head -1)"
ck "the exporter exposes per-tier model metrics" "hermes_model_requests_1h" \
   "$(grep -o 'hermes_model_requests_1h' scripts/hermes_metrics_exporter.py | head -1)"
ck "silent model degradation fires an alert" "HermesModelFallbackStorm" \
   "$(grep -o 'HermesModelFallbackStorm' deploy/monitoring/hermes-agents.rules.yml | head -1)"
ck "digest covers agents, alerts, projects, backup" "ЗА СУТКИ" \
   "$(grep -o 'ЗА СУТКИ' agents/checks/digest.sh | head -1)"
ck "digest is delivered through the existing telegram channel" "import bus_bridge" \
   "$(grep -o 'import bus_bridge' scripts/hermes-digest.py | head -1)"
ck "digest has a timer and a check mode" "DIGEST: OK" \
   "$(grep -o 'DIGEST: OK' scripts/install-digest.sh | head -1)"
ck "skills audit finds duplicates without deleting anything" "дубли" \
   "$(grep -o 'дубли' scripts/audit-skills.sh | head -1)"
ck "wiring gives every agent the lookup handler" "lookup.sh" \
   "$(grep -o 'lookup.sh' scripts/wire-agents.sh | head -1)"
ck "the installer wires journal and digest on a new node" "install-journal.sh install-digest.sh" \
   "$(grep -o 'install-journal.sh install-digest.sh' scripts/install-agent-runtime.sh | head -1)"

LKUPDIR="$(mktemp -d)"; mkdir -p "$LKUPDIR/bin"
cat > "$LKUPDIR/bin/systemctl" <<'SYSEOF'
#!/usr/bin/env bash
# Заглушка отвечает ТОЛЬКО про hermes-digest. Первая версия отвечала «юнит существует» на
# любое имя — и проверка «неизвестное имя честно не находится» падала на собственной заглушке.
case " $* " in
  *hermes-digest*)
    case " $* " in
      *" list-unit-files "*) echo "hermes-digest.timer enabled" ;;
      *" is-active "*)       echo "active" ;;
      *" is-enabled "*)      echo "enabled" ;;
      *) echo "" ;;
    esac ;;
  *) echo "" ;;
esac
SYSEOF
chmod +x "$LKUPDIR/bin/systemctl"
OUT4="$(PATH="$LKUPDIR/bin:$PATH" ARG_NAME=hermes-digest bash agents/checks/lookup.sh 2>&1)"
ck "live: lookup finds a unit by name" "ЧТО ТАКОЕ hermes-digest" \
   "$(printf '%s' "$OUT4" | head -1 | grep -o 'ЧТО ТАКОЕ hermes-digest' | head -1)"
ck "live: lookup reports the unit state" "состояние" "$(printf '%s' "$OUT4" | grep -o 'состояние' | head -1)"
ck "live: lookup cites its evidence" "доказательство" "$(printf '%s' "$OUT4" | grep -o 'доказательство' | head -1)"
OUT5="$(PATH="$LKUPDIR/bin:$PATH" ARG_NAME=no-such-object-xyz bash agents/checks/lookup.sh 2>&1)"
ck "live: an unknown name is answered honestly" "нет ничего с именем" "$(printf '%s' "$OUT5" | grep -o 'нет ничего с именем' | head -1)"
# Журнал для этого прогона — временный: тест не должен оставлять следов в рабочих журналах
# (первый прогон добавил три записи «запрошено подтверждение» в журнал узла).
OUT6="$(HERMES_JOURNAL_ROOT="$LKUPDIR/journal" ARG_ACTION=clean-old-logs ARG_DAYS=30 bash agents/checks/act.sh 2>&1)"
ck "live: an irreversible action refuses without confirmation" "нужно подтверждение" "$(printf '%s' "$OUT6" | grep -o 'нужно подтверждение' | head -1)"
rm -rf "$LKUPDIR"


echo "[17] guards, staleness, feedback and the eval that checks understanding"
cd "$REPO_ROOT"

# сторожа
ck "container guard exists and is idempotent" "CONTAINER-GUARD: OK" \
   "$(grep -o 'CONTAINER-GUARD: OK' scripts/container-guard.sh | head -1)"
ck "the guard restores limits without restarting the container" "docker update" \
   "$(grep -o 'docker update' scripts/container-guard.sh | head -1)"
ck "limits live in an owner-owned config file" "container-limits.conf" \
   "$(grep -o 'container-limits.conf' scripts/install-container-guard.sh | head -1)"
ck "the install keeps an existing limits file" "не трогаю" \
   "$(grep -o 'не трогаю' scripts/install-container-guard.sh | head -1)"
ck "wiring guard repairs drift and records it" "journal_write node change" \
   "$(grep -o 'journal_write node change' scripts/wiring-guard.sh | head -1)"
ck "the new installers run on a fresh node" "install-container-guard.sh" \
   "$(grep -o 'install-container-guard.sh' scripts/install-agent-runtime.sh | head -1)"

# метрики и правила
ck "exporter reports project staleness" "hermes_project_behind" \
   "$(grep -o 'hermes_project_behind' scripts/hermes_metrics_exporter.py | head -1)"
ck "exporter reports backup freshness" "hermes_backup_age_hours" \
   "$(grep -o 'hermes_backup_age_hours' scripts/hermes_metrics_exporter.py | head -1)"
ck "exporter reports guard state" "hermes_container_limit_drift" \
   "$(grep -o 'hermes_container_limit_drift' scripts/hermes_metrics_exporter.py | head -1)"
ck "exporter reports the journal size" "hermes_journal_bytes" \
   "$(grep -o 'hermes_journal_bytes' scripts/hermes_metrics_exporter.py | head -1)"
ck "exporter reports owner feedback" "hermes_feedback_total" \
   "$(grep -o 'hermes_feedback_total' scripts/hermes_metrics_exporter.py | head -1)"
for rule in HermesContainerLimitDrift HermesWiringDrift HermesProjectStaleCopy HermesBackupStale HermesJournalGrowing; do
  ck "alert rule $rule is shipped" "$rule" \
     "$(grep -o "alert: $rule" deploy/monitoring/hermes-agents.rules.yml | head -1)"
done

# действия из чата
ck "clone-project is a guarded verb" "clone-project)" \
   "$(grep -o 'clone-project)' agents/checks/act.sh | head -1)"
ck "clone only from the owner's GitHub" "github.com/JoTalbot/*" \
   "$(grep -o 'github.com/JoTalbot/\*' agents/checks/act.sh | head -1)"
ck "pull refuses on a dirty tree" "незакоммиченное — чья-то работа" \
   "$(grep -o 'незакоммиченное — чья-то работа' agents/checks/act.sh | head -1)"
ck "pull requires confirmation" '"confirm": "yes" if (verb == "clone-project" or confirmed)' \
   "$(grep -o '"confirm": "yes" if (verb == "clone-project" or confirmed)' agents/routing.py | head -1)"
ck "routing knows the clone verb" "clone-project" \
   "$(grep -o 'clone-project' agents/routing.py | head -1)"

# оценки ответов
ck "the bus can receive callback_query" "callback_query" \
   "$(grep -o 'callback_query' bus/bus_bridge.py | head -1)"
ck "the bus records a rating with its question" "def feedback_record" \
   "$(grep -o 'def feedback_record' bus/bus_bridge.py | head -1)"
ck "the reply carries the rating buttons" "fb|up|" \
   "$(grep -o 'fb|up|' bus/bus_bridge.py | head -1)"
ck "feedback is reported to the owner" "ОЦЕНКИ ОТВЕТОВ" \
   "$(grep -o 'ОЦЕНКИ ОТВЕТОВ' agents/checks/feedback.sh | head -1)"
ck "the day digest includes ratings" "ОЦЕНКИ ОТВЕТОВ" \
   "$(grep -o 'ОЦЕНКИ ОТВЕТОВ' agents/checks/digest.sh | head -1)"

# журнал и скиллы
ck "journal-top names the loudest writer" "самый громкий" \
   "$(grep -o 'самый громкий' agents/checks/journal-top.sh | head -1)"
ck "the skills audit can be strict" "--strict" \
   "$(grep -o '\-\-strict' scripts/audit-skills.sh | head -1)"
ck "the skills audit writes a plan instead of deleting" "SKILLS-TODO.md" \
   "$(grep -o 'SKILLS-TODO.md' scripts/audit-skills.sh | head -1)"
ck "core checks now cite their commands" "report_proof" \
   "$(grep -o 'report_proof' agents/checks/guardian-disk.sh | head -1)"

# живое: прогон «понимает ли система вопросы владельца»
if [[ -x .venv-bus/bin/python ]]; then
  EV="$(bash scripts/eval-agents.sh 2>&1 | tail -1)"
  ck "live: every sample question reaches the right agent" "20 из 20" "$EV"
  OUT7="$(bash agents/checks/journal-top.sh 2>&1 | head -3 | tr '\n' ' ')"
  ck "live: journal-top runs on this node" "КТО ПИШЕТ В ЖУРНАЛ" "$OUT7"
  # Фикстура, а не боевой файл: тест не должен писать в то, что проверяет.
  FBDIR="$(mktemp -d)"; printf '%s\n' \
    "{\"epoch\": $(( $(date +%s) - 300 )), \"verdict\": \"up\", \"question\": \"сколько памяти\", \"answer\": \"5.5 GiB\"}" \
    "{\"epoch\": $(( $(date +%s) - 120 )), \"verdict\": \"down\", \"question\": \"что с хромом\", \"answer\": \"не знаю\"}" \
    > "$FBDIR/feedback.jsonl"
  OUT8="$(HERMES_FEEDBACK_FILE="$FBDIR/feedback.jsonl" bash agents/checks/feedback.sh 2>&1 | tail -1)"
  ck "live: feedback report renders" "ИТОГ" "$OUT8"
  ck "live: feedback counts up and down" "точных 50%" "$OUT8"
  OUT9="$(bash agents/checks/feedback.sh 2>&1 | tail -1)"
  ck "live: feedback report renders on the node file too" "ИТОГ" "$OUT9"
  rm -rf "$FBDIR"
else
  ((SKIP++)); ((SKIP++)); ((SKIP++)); ((SKIP++)); echo "  ~ live eval checks skipped (нет venv шины)"
fi


echo "[18] the answer says which model really served it"
cd "$REPO_ROOT"

ck "the shim reports the served tier and provider" "aios_tier" \
   "$(grep -o 'aios_tier' deploy/shim/aios_openai_shim.py | head -1)"
ck "the shim counts tier mismatches" "tier_mismatch_total" \
   "$(grep -o 'tier_mismatch_total' deploy/shim/aios_openai_shim.py | head -1)"
ck "the shim says it in the log, not only in a metric" "tier mismatch: asked" \
   "$(grep -o 'tier mismatch: asked' deploy/shim/aios_openai_shim.py | head -1)"
ck "agents read the served tier, not the requested one" "served_tier" \
   "$(grep -o 'served_tier' agents/models.py | head -1)"
ck "a mismatch is called a mismatch" "tier_mismatch" \
   "$(grep -o 'tier_mismatch' agents/models.py | head -1)"
ck "the run history keeps the provider that answered" '"provider": meta.get' \
   "$(grep -o '"provider": meta.get' agents/runtime.py | head -1)"
ck "the exporter exposes served tiers" "hermes_model_served_1h" \
   "$(grep -o 'hermes_model_served_1h' scripts/hermes_metrics_exporter.py | head -1)"
ck "the exporter exposes tier mismatches" "hermes_model_tier_mismatch_1h" \
   "$(grep -o 'hermes_model_tier_mismatch_1h' scripts/hermes_metrics_exporter.py | head -1)"

if [[ -x .venv-bus/bin/python ]]; then
  ANS="$(./.venv-bus/bin/python - <<'PY' 2>/dev/null
import sys
sys.path.insert(0, "agents")
import models
text, meta = models.ask("Ответь одним словом: сколько будет два плюс два?",
                        "факты: калькулятор недоступен", "server-guardian",
                        purpose="проверка телеметрии модели", model="hermes-fast", timeout=40)
tiers = ("fast", "reasoning", "code", "long_context", "local")
marks = []
if meta.get("provider"):
    marks.append("телеком-провайдер-ок")
if meta.get("served_tier") in tiers:
    marks.append("телеком-тир-ок")
print(" ".join(marks) + " | провайдер=%s тир=%s ответ=%s" % (
    meta.get("provider"), meta.get("served_tier"), meta.get("ok")))
PY
)"
  ck "live: the answer names the provider that served it" "телеком-провайдер-ок" "$ANS"
  ck "live: the served tier is a real balancer tier" "телеком-тир-ок" "$ANS"
else
  ((SKIP++)); ((SKIP++)); echo "  ~ live model telemetry checks skipped (нет venv шины)"
fi


echo
echo "════ $PASS passed · $FAIL failed · $SKIP skipped ════"
[[ $FAIL -eq 0 ]]
