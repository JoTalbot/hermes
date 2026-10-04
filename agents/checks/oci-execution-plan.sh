#!/usr/bin/env bash
set -euo pipefail
CONFIG=/etc/hermes/oci/accounts.yaml
POLICY=/etc/hermes/oci/execution-policy.yaml
[[ -f "$CONFIG" ]] || { echo "BLOCK OCI registry not configured: $CONFIG"; exit 0; }
[[ -f "$POLICY" ]] || { echo "BLOCK execution policy not configured: $POLICY"; exit 0; }
python3 - "$CONFIG" "$POLICY" <<'PY'
import hashlib, json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
pol = yaml.safe_load(open(sys.argv[2])) or {}
ex = pol.get("execution") or {}
if not ex.get("enabled", False):
    print("BLOCK execution disabled by policy")
    sys.exit(0)
if ex.get("allow_paid", False):
    print("BLOCK paid resources are forbidden")
    sys.exit(0)
allowed = set(ex.get("allowed_actions") or [])
if not allowed:
    print("BLOCK no execution actions are allowlisted")
    sys.exit(0)
plans = []
for a in cfg.get("accounts", []):
    fp = {**(cfg.get("defaults",{}).get("free_tier",{}) or {}), **(a.get("free_tier",{}) or {})}
    if fp.get("allow_paid", False) or a.get("allow_paid", False) or cfg.get("defaults",{}).get("allow_paid",False):
        print(f"BLOCK account={a.get('name','unnamed')}: paid resources disabled")
        continue
    for name in a.get("execution_profiles", []) or []:
        plans.append({"account":a.get("name","unnamed"),"placement_profile":name})
profiles = {x.get("name"):x for x in ex.get("placement_profiles",[]) if isinstance(x,dict) and x.get("name")}
if not plans:
    print("BLOCK no execution placement profiles are referenced by accounts")
    sys.exit(0)
for p in plans:
    if p["placement_profile"] not in profiles:
        print(f"BLOCK account={p['account']}: placement profile {p['placement_profile']} is not defined")
        continue
    canonical = json.dumps({"account":p["account"],"placement_profile":p["placement_profile"],
                            "allowed_actions":sorted(allowed)}, sort_keys=True, separators=(",",":"))
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    print(f"PLAN execution_candidate account={p['account']} profile={p['placement_profile']} action=create_instance")
    print(f"PLAN_HASH sha256:{digest}")
print("RULE: apply requires fresh inventory, exact plan hash, and an unexpired approval file.")
PY
