#!/usr/bin/env bash
set -euo pipefail
CONFIG="${OCI_ACCOUNTS_CONFIG:-/etc/hermes/oci/accounts.yaml}"
OCI="${OCI_BIN:-/home/ubuntu/oci-venv/bin/oci}"
[[ -x "$OCI" ]] || OCI="$(command -v oci || true)"
[[ -n "$OCI" ]] || { echo "WARN oci CLI not installed"; exit 0; }
[[ -f "$CONFIG" ]] || { echo "OBSERVATION OCI registry not configured: $CONFIG"; exit 0; }
python3 - "$CONFIG" "$OCI" <<'PY'
import json, subprocess, sys, yaml
cfg,oci=sys.argv[1:]
d=yaml.safe_load(open(cfg)) or {}
defs=d.get("defaults",{})
for a in d.get("accounts",[]):
    name=a.get("name","unnamed"); p=a.get("profile","DEFAULT")
    policy={**defs.get("free_tier",{}), **a.get("free_tier",{})}
    allowed=set(policy.get("allowed_shapes") or [])
    max_cpu=float(policy.get("max_total_ocpus",0) or 0)
    max_mem=float(policy.get("max_total_memory_gib",0) or 0)
    regions=a.get("regions") or defs.get("regions") or []
    comps=a.get("compartment_ocids") or ([a.get("tenancy_ocid")] if a.get("tenancy_ocid") else [])
    if not allowed or not max_cpu or not max_mem:
        print(f"BLOCK account={name}: free-tier policy incomplete; provisioning remains disabled")
        continue
    for region in regions:
      for comp in comps:
        r=subprocess.run([oci,"compute","instance","list","-c",comp,"--region",region,"--profile",p,"--all","--output","json"],capture_output=True,text=True,timeout=90)
        if r.returncode:
            print(f"FAIL account={name} region={region}: cannot verify current consumption")
            continue
        rows=json.loads(r.stdout).get("data",[])
        cpu=sum(float(x.get("shape-config",{}).get("ocpus") or 0) for x in rows)
        mem=sum(float(x.get("shape-config",{}).get("memory-in-gbs") or 0) for x in rows)
        bad=[x.get("shape") for x in rows if x.get("shape") not in allowed]
        verdict="SAFE" if not bad and cpu<=max_cpu and mem<=max_mem else "BLOCK"
        print(f"{verdict} account={name} region={region} cpu={cpu:g}/{max_cpu:g} memory_gib={mem:g}/{max_mem:g} disallowed_shapes={','.join(filter(None,bad)) or '-'}")
PY
