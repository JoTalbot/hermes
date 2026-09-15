#!/usr/bin/env bash
# tests/run.sh — contract tests for the shipped files. No network, no server access.
# It runs deploy/shim/aios_openai_shim.py against tests/fake_aios.py, which replays the
# balancer's MEASURED contract (422-on-missing-goal included). If the shim drifts from the
# real API shape, these tests go red — which is the point.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
echo
echo "════ $PASS passed · $FAIL failed · $SKIP skipped ════"
[[ $FAIL -eq 0 ]]
