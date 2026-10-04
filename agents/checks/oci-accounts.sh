#!/usr/bin/env bash
set -euo pipefail
CONFIG="${OCI_ACCOUNTS_CONFIG:-/etc/hermes/oci/accounts.yaml}"
OCI="${OCI_BIN:-/home/ubuntu/oci-venv/bin/oci}"
[[ -x "$OCI" ]] || OCI="$(command -v oci || true)"
[[ -n "$OCI" ]] || { echo "WARN oci CLI not installed"; exit 0; }
[[ -f "$CONFIG" ]] || { echo "OBSERVATION OCI registry not configured: $CONFIG"; exit 0; }
python3 - "$CONFIG" "$OCI" <<'PY'
import json, subprocess, sys, yaml
p, oci = sys.argv[1:]
d = yaml.safe_load(open(p)) or {}
for a in d.get("accounts", []):
    name=a.get("name","unnamed"); profile=a.get("profile","DEFAULT")
    r=subprocess.run([oci,"iam","region-subscription","list","--profile",profile,"--output","json"],capture_output=True,text=True,timeout=45)
    if r.returncode:
        print(f"FAIL account={name} profile={profile}: OCI authentication failed")
        continue
    rows=json.loads(r.stdout).get("data",[])
    print(f"FACT account={name} profile={profile} subscribed_regions={len(rows)}")
PY
