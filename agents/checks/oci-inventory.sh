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
for a in d.get("accounts",[]):
    name=a.get("name","unnamed"); profile=a.get("profile","DEFAULT")
    regions=a.get("regions") or d.get("defaults",{}).get("regions") or []
    comps=a.get("compartment_ocids") or ([a.get("tenancy_ocid")] if a.get("tenancy_ocid") else [])
    if not regions or not comps:
        print(f"WARN account={name}: regions/compartment_ocids not configured")
        continue
    for region in regions:
        for comp in comps:
            r=subprocess.run([oci,"compute","instance","list","-c",comp,"--region",region,"--profile",profile,"--all","--output","json"],capture_output=True,text=True,timeout=90)
            if r.returncode:
                print(f"FAIL account={name} region={region}: compute inventory unavailable")
                continue
            rows=json.loads(r.stdout).get("data",[])
            cpu=sum(float(x.get("shape-config",{}).get("ocpus") or 0) for x in rows)
            mem=sum(float(x.get("shape-config",{}).get("memory-in-gbs") or 0) for x in rows)
            shapes=sorted({x.get("shape") for x in rows if x.get("shape")})
            print(f"FACT account={name} region={region} instances={len(rows)} ocpus={cpu:g} memory_gib={mem:g} shapes={','.join(shapes)}")
PY
