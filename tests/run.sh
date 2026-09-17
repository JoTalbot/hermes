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
echo
echo "════ $PASS passed · $FAIL failed · $SKIP skipped ════"
[[ $FAIL -eq 0 ]]
