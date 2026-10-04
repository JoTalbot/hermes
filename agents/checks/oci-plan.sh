#!/usr/bin/env bash
set -euo pipefail
CONFIG="${OCI_ACCOUNTS_CONFIG:-/etc/hermes/oci/accounts.yaml}"
[[ -f "$CONFIG" ]] || { echo "BLOCK OCI registry not configured: $CONFIG"; exit 0; }
python3 - "$CONFIG" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1])) or {}
defs=d.get("defaults",{})
candidates=[]
for a in d.get("accounts",[]):
    p={**defs.get("free_tier",{}),**a.get("free_tier",{})}
    if p.get("allow_paid",False) or a.get("allow_paid",False) or defs.get("allow_paid",False):
        print(f"BLOCK account={a.get('name','unnamed')}: paid resources are disabled by design")
    for r in a.get("regions") or defs.get("regions") or []:
        for s in p.get("allowed_shapes") or []:
            candidates.append((a.get("name","unnamed"),r,s))
print("PLAN free-tier candidates:" if candidates else "BLOCK no provisionable free-tier candidates are configured")
for a,r,s in candidates: print(f"  account={a} region={r} shape={s}")
print("RULE: provisioning requires fresh inventory + SAFE guard verdict; this planner never creates resources.")
PY
