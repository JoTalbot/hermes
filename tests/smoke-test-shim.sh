#!/usr/bin/env bash
# tests/smoke-test-shim.sh — exercise the shim the way Hermes does.
#
# WHY: a unit test of the prompt builder passed while the deployed shim raised
# NameError on every request, because a refactor had deleted two helper functions
# defined after the function being rewritten. Only an end-to-end call catches that.
# Run this after ANY change to deploy/shim/aios_openai_shim.py.
set -uo pipefail
URL="${HERMES_SHIM_URL:-http://127.0.0.1:9700}"
KEY="${HERMES_BALANCER_API_KEY:-}"
SUDO=""
[[ -r /etc/hermes/shim.env ]] || SUDO="sudo -n"
if [[ -z "$KEY" ]]; then
  KEY=$($SUDO cat /etc/hermes/shim.env 2>/dev/null | grep -m1 '^HERMES_BALANCER_API_KEY=' | cut -d= -f2-)
fi
[[ -n "$KEY" ]] || { echo "FAIL: cannot obtain the shim key"; exit 1; }
pass=0; fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; pass=$((pass+1));
        else echo "  FAIL  $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

# 1 health
ver=$(curl -s -m 10 "$URL/health" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)
[[ -n "$ver" ]] && chk "health returns a version" "yes" "yes" || chk "health returns a version" "no" "yes"
echo "        (version $ver)"

# 2 plain completion
body='{"model":"hermes-fast","stream":false,"messages":[{"role":"user","content":"Reply with exactly: SMOKE_PLAIN"}]}'
got=$(curl -s -m 90 "$URL/v1/chat/completions" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$body" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())
except Exception: print("__ERR__")')
chk "plain completion" "$( [[ "$got" == *SMOKE_PLAIN* ]] && echo ok || echo "$got")" "ok"

# 3 streaming, with a long system prompt and tools — the shape a kanban worker sends
python3 - "$URL" "$KEY" <<'PY' > /tmp/smoke3.json
import json, sys
url, key = sys.argv[1], sys.argv[2]
tools = [{"type":"function","function":{"name":n,
          "description":"Tool %s described at length so the renderer is exercised fully. " % n * 4,
          "parameters":{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}}}
         for n in ["kanban_complete","kanban_block","kanban_show","terminal","read_file","write_file"]]
print(json.dumps({"model":"hermes-auto","stream":True,
    "messages":[{"role":"system","content":"You are a kanban worker. Finish by calling kanban_complete. "*40},
                {"role":"user","content":"Reply with exactly: SMOKE_STREAM"}],
    "tools":tools}))
PY
out=$(curl -s -N -m 120 "$URL/v1/chat/completions" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d @/tmp/smoke3.json 2>&1)
echo "$out" | grep -q 'SMOKE_STREAM' && r3=ok || r3="$(echo "$out" | tail -c 200)"
chk "streaming with tools (long system prompt)" "$r3" "ok"
echo "$out" | grep -qiE "NameError|Traceback|malformed" && chk "no server-side exception" "error" "clean" || chk "no server-side exception" "clean" "clean"

# 4 no unhandled exception during THIS run of the service. Scoped to the service's
#   own start time: a fixed window counts tracebacks from before the restart and
#   fails on a fix that worked.
since=$(systemctl show -p ActiveEnterTimestamp --value hermes-shim 2>/dev/null)
if [[ -n "$since" ]]; then
  tb=$(sudo -n journalctl -u hermes-shim --since "$since" --no-pager 2>/dev/null | grep -c "Traceback")
else
  tb=$(sudo -n journalctl -u hermes-shim --since "-2 min" --no-pager 2>/dev/null | grep -c "Traceback")
fi
chk "no unhandled exception in the shim since it started" "$( [[ "${tb:-0}" == "0" ]] && echo clean || echo "${tb} tracebacks")" "clean"

echo "smoke: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
