#!/usr/bin/env bash
# scripts/report-balancer-health.sh — one-line health verdict for the LLM layer.
#
# WHY A SCRIPT AND NOT A PROMPT: agents on this box are driven by small, fast
# models (the balancer prefers the fast tier for low latency). Asked to compose a
# multi-command health check from scratch they produce a dozen speculative tool
# calls and an empty conclusion. Handing them one deterministic, read-only command
# that prints the finished answer removes the failure mode and makes the check
# identical no matter which agent runs it.
#
# Read-only. Prints no secret. Exit 0 = healthy, 1 = degraded, 2 = down.
set -uo pipefail

shim_url="${HERMES_SHIM_URL:-http://127.0.0.1:9700}"
bal_url="${AIOS_BRIDGE_URL:-http://127.0.0.1:9600}"
rc=0

echo "LLM PATH HEALTH ($(date -Is))"

# 1. loopback shim ------------------------------------------------------------
shim_ver=$(curl -s -m 5 "$shim_url/health" | python3 -c \
  'import sys,json
try:
    print(json.load(sys.stdin).get("version","?"))
except Exception:
    print("")')
if [[ -n "$shim_ver" ]]; then
  echo "  shim            : UP v${shim_ver}"
else
  echo "  shim            : DOWN (no answer from ${shim_url}/health)"
  rc=2
fi

# 2. balancer + provider pool -------------------------------------------------
pool=$(curl -s -m 8 "$bal_url/health" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("unreadable"); raise SystemExit
lb = d.get("llm_balancer") or {}
provs = lb.get("providers") or []
bad = [p.get("name") for p in provs if not p.get("healthy")]
line = "{} providers | {} unhealthy".format(len(provs), len(bad))
if bad:
    line += " (" + ", ".join(bad) + ")"
print(line)
print("BAD=" + str(len(bad)))
' 2>/dev/null)
if [[ -n "$pool" ]]; then
  echo "  balancer        : UP $(echo "$pool" | head -1)"
  bad=$(echo "$pool" | sed -n 's/^BAD=//p')
  [[ "${bad:-1}" == "0" ]] || { [[ $rc -eq 0 ]] && rc=1; }
else
  echo "  balancer        : DOWN (no answer from ${bal_url}/health)"
  rc=2
fi

# 3. a real round trip — the only proof the whole chain works ------------------
# Asked of the shim rather than built from the API key, so an unprivileged agent
# gets a truthful answer without ever holding the credential.
sc=$(curl -s -m 90 "$shim_url/selfcheck")
state=$(printf '%s' "$sc" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("FAIL unreadable"); raise SystemExit
print(("PASS " + str(d.get("provider"))) if d.get("ok")
      else ("FAIL " + str(d.get("reply"))[:120]))
')
if [[ "$state" == PASS* ]]; then
  echo "  round trip      : ${state#PASS } (model answered through the balancer)"
else
  echo "  round trip      : ${state}"
  [[ $rc -eq 0 ]] && rc=1
fi

case "$rc" in
  0) echo "  VERDICT         : the LLM path is healthy end to end" ;;
  1) echo "  VERDICT         : degraded — at least one provider is down, routing continues" ;;
  2) echo "  VERDICT         : DOWN — agents cannot think" ;;
esac
exit "$rc"
