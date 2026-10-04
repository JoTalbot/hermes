#!/usr/bin/env bash
set -euo pipefail
CONFIG="${OCI_ACCOUNTS_CONFIG:-/etc/hermes/oci/accounts.yaml}"
POLICY="${OCI_EXECUTION_POLICY:-/etc/hermes/oci/execution-policy.yaml}"
OCI="${OCI_BIN:-/home/ubuntu/oci-venv/bin/oci}"
[[ -x "$OCI" ]] || OCI="$(command -v oci || true)"
[[ -n "$OCI" ]] || { echo "BLOCK OCI CLI not installed"; exit 0; }
[[ -f "$CONFIG" && -f "$POLICY" ]] || { echo "BLOCK OCI capacity config/policy missing"; exit 0; }

python3 - "$CONFIG" "$POLICY" "$OCI" <<'PY'
import json, subprocess, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
pol = yaml.safe_load(open(sys.argv[2])) or {}
ex = pol.get("execution") or {}
if ex.get("allow_paid", False):
    print("BLOCK paid resources are forbidden")
    sys.exit(0)
profiles = {x.get("name"): x for x in ex.get("placement_profiles", []) if isinstance(x, dict) and x.get("name")}
if not profiles:
    print("BLOCK no placement profiles configured")
    sys.exit(0)

ranked = []
for account in cfg.get("accounts", []):
    name = account.get("name")
    if not name:
        continue
    if account.get("allow_paid", False) or (account.get("free_tier") or {}).get("allow_paid", False):
        continue
    home = account.get("home_region")
    compartments = account.get("compartment_ocids") or ([account.get("tenancy_ocid")] if account.get("tenancy_ocid") else [])
    if not home or not compartments:
        print(f"BLOCK account={name}: missing home_region or compartment")
        continue

    rows = []
    for region in [home]:
        for comp in compartments:
            r = subprocess.run(
                [sys.argv[3], "compute", "instance", "list", "-c", comp,
                 "--region", region, "--profile", account.get("profile","DEFAULT"),
                 "--all", "--output", "json"],
                capture_output=True, text=True, timeout=90)
            if r.returncode:
                print(f"BLOCK account={name} region={region}: inventory failed")
                continue
            try:
                rows.extend(json.loads(r.stdout).get("data", []))
            except Exception:
                print(f"BLOCK account={name} region={region}: invalid inventory")
                continue

    for profile_name in account.get("execution_profiles", []) or []:
        p = profiles.get(profile_name)
        if not p:
            print(f"BLOCK account={name}: undefined profile={profile_name}")
            continue
        if p.get("region") != home:
            print(f"BLOCK account={name} profile={profile_name}: non-home-region")
            continue
        shape = p.get("shape")
        if shape not in set(ex.get("allowed_shapes") or []):
            print(f"BLOCK account={name} profile={profile_name}: shape={shape} not allowlisted")
            continue
        shape_rows = [x for x in rows if x.get("shape") == shape and x.get("region", home) == p["region"]]
        limit = (ex.get("shape_limits") or {}).get(shape) or {}
        max_instances = int(limit.get("max_instances") or ex.get("max_instances") or 0)
        max_cpu = float(limit.get("max_total_ocpus") or ex.get("max_total_ocpus") or 0)
        max_mem = float(limit.get("max_total_memory_gib") or ex.get("max_total_memory_gib") or 0)
        used_cpu = sum(float(x.get("shape-config",{}).get("ocpus") or 0) for x in shape_rows)
        used_mem = sum(float(x.get("shape-config",{}).get("memory-in-gbs") or 0) for x in shape_rows)
        requested = p.get("shape_config") or {}
        req_cpu = float(requested.get("ocpus") or 1)
        req_mem = float(requested.get("memory_in_gbs") or requested.get("memoryInGBs") or 6)
        free_instances = max_instances - len(shape_rows) if max_instances else 999999
        free_cpu = max_cpu - used_cpu if max_cpu else 999999
        free_mem = max_mem - used_mem if max_mem else 999999
        fits = free_instances >= 1 and free_cpu >= req_cpu and free_mem >= req_mem
        score = min(free_cpu / req_cpu if req_cpu else 0, free_mem / req_mem if req_mem else 0,
                    free_instances if free_instances != 999999 else 999999)
        status = "CANDIDATE" if fits else "BLOCK"
        print(f"{status} account={name} profile={profile_name} shape={shape} "
              f"free_instances={free_instances if free_instances != 999999 else '-'} "
              f"free_ocpus={free_cpu:g} free_memory_gib={free_mem:g} score={score:g}")
        if fits:
            ranked.append((score, name, profile_name))
if ranked:
    print("RANKED " + " ".join(f"{n}/{p}:{s:g}" for s,n,p in sorted(ranked, reverse=True)))
else:
    print("RANKED none")
PY
