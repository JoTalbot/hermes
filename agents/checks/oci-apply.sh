#!/usr/bin/env bash
set -euo pipefail
CONFIG=/etc/hermes/oci/accounts.yaml
POLICY=/etc/hermes/oci/execution-policy.yaml
OCI=/home/ubuntu/oci-venv/bin/oci
[[ -x "$OCI" ]] || OCI="$(command -v oci || true)"
[[ -n "$OCI" ]] || { echo "BLOCK OCI CLI not installed"; exit 0; }
[[ -f "$CONFIG" && -f "$POLICY" ]] || { echo "BLOCK OCI execution config/policy missing"; exit 0; }
python3 - "$CONFIG" "$POLICY" "$OCI" <<'PY'
import hashlib, json, os, subprocess, sys, time
import yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
pol = yaml.safe_load(open(sys.argv[2])) or {}
ex = pol.get("execution") or {}
args = json.loads(os.environ.get("ARGS_JSON","{}"))
action = str(args.get("action","")).strip()
account = str(args.get("account","")).strip()
profile_name = str(args.get("placement_profile","")).strip()
plan_hash = str(args.get("plan_hash","")).strip()
actor = os.environ.get("AGENT_ACTOR","unknown")
audit = ex.get("audit_log") or "/var/lib/hermes-agents/oci-execution.jsonl"
def audit_row(event, ok, reason=""):
    row={"ts":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"event":event,"ok":ok,
         "actor":actor,"action":action,"account":account,"placement_profile":profile_name,
         "plan_hash":plan_hash,"reason":reason}
    try:
        os.makedirs(os.path.dirname(audit),exist_ok=True)
        with open(audit,"a",encoding="utf-8") as f:
            f.write(json.dumps(row,sort_keys=True)+"\n")
    except Exception:
        pass
if not ex.get("enabled",False):
    print("BLOCK execution disabled by policy"); audit_row("blocked",False,"disabled"); sys.exit(0)
if ex.get("allow_paid",False):
    print("BLOCK paid execution is forbidden"); audit_row("blocked",False,"paid"); sys.exit(0)
allowed=set(ex.get("allowed_actions") or [])
if action not in allowed:
    print(f"BLOCK action={action or '-'} is not allowlisted"); audit_row("blocked",False,"action"); sys.exit(0)
if action != "create_instance":
    print("BLOCK only create_instance is implemented in v1.1"); audit_row("blocked",False,"unsupported-action"); sys.exit(0)
if not account or not profile_name or not plan_hash:
    print("BLOCK account, placement_profile and plan_hash are required"); audit_row("blocked",False,"missing-args"); sys.exit(0)
canonical=json.dumps({"account":account,"placement_profile":profile_name,
                      "allowed_actions":sorted(allowed)},sort_keys=True,separators=(",",":"))
expected="sha256:"+hashlib.sha256(canonical.encode()).hexdigest()
if plan_hash != expected:
    print("BLOCK plan hash mismatch"); audit_row("blocked",False,"plan-hash"); sys.exit(0)
approval_dir=ex.get("approval_dir") or "/var/lib/hermes-agents/oci-approvals"
approval=os.path.join(approval_dir, plan_hash.replace(":","_")+".approved")
if ex.get("require_approval",True):
    try:
        age=time.time()-os.stat(approval).st_mtime
        if age > int(ex.get("approval_ttl_seconds",900)):
            print("BLOCK approval expired"); audit_row("blocked",False,"approval-expired"); sys.exit(0)
    except FileNotFoundError:
        print("BLOCK explicit approval is required"); audit_row("blocked",False,"approval-missing"); sys.exit(0)
accounts={a.get("name"):a for a in cfg.get("accounts",[]) if a.get("name")}
a=accounts.get(account)
profiles={x.get("name"):x for x in ex.get("placement_profiles",[]) if isinstance(x,dict) and x.get("name")}
p=profiles.get(profile_name)
if not a or not p:
    print("BLOCK unknown account or placement profile"); audit_row("blocked",False,"unknown-target"); sys.exit(0)
if a.get("allow_paid",False) or (a.get("free_tier") or {}).get("allow_paid",False):
    print("BLOCK target account allows paid resources; execution refuses it"); audit_row("blocked",False,"account-paid"); sys.exit(0)
required=["region","compartment_ocid","availability_domain","subnet_ocid","image_ocid","shape"]
missing=[k for k in required if not p.get(k)]
if missing:
    print("BLOCK placement profile missing: "+",".join(missing)); audit_row("blocked",False,"profile-incomplete"); sys.exit(0)
shape=p["shape"]
if shape not in set(ex.get("allowed_shapes") or []):
    print(f"BLOCK shape={shape} is not execution-allowlisted"); audit_row("blocked",False,"shape"); sys.exit(0)
cmd=[oci,"compute","instance","list","-c",p["compartment_ocid"],"--region",p["region"],
     "--profile",a.get("profile","DEFAULT"),"--all","--output","json"]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=90)
if r.returncode:
    print("BLOCK fresh inventory failed; no mutation attempted"); audit_row("blocked",False,"inventory-failed"); sys.exit(0)
rows=json.loads(r.stdout).get("data",[])
cpu=sum(float(x.get("shape-config",{}).get("ocpus") or 0) for x in rows)
mem=sum(float(x.get("shape-config",{}).get("memory-in-gbs") or 0) for x in rows)
maxcpu=float(ex.get("max_total_ocpus") or 0)
maxmem=float(ex.get("max_total_memory_gib") or 0)
if len(rows)>=int(ex.get("max_instances") or 0) or cpu>=maxcpu or mem>=maxmem:
    print(f"BLOCK no Free Tier headroom: instances={len(rows)} cpu={cpu:g}/{maxcpu:g} memory={mem:g}/{maxmem:g}")
    audit_row("blocked",False,"headroom"); sys.exit(0)
shape_cfg=p.get("shape_config") or {}
ocpus=float(shape_cfg.get("ocpus") or 1)
memory=float(shape_cfg.get("memory_in_gbs") or 6)
if cpu+ocpus>maxcpu or mem+memory>maxmem:
    print("BLOCK requested shape configuration exceeds policy headroom"); audit_row("blocked",False,"requested-headroom"); sys.exit(0)
display=p.get("display_name") or f"hermes-{account}-{int(time.time())}"
cmd=[oci,"compute","instance","launch","-c",p["compartment_ocid"],"--availability-domain",p["availability_domain"],
     "--subnet-id",p["subnet_ocid"],"--image-id",p["image_ocid"],"--shape",shape,
     "--display-name",display,"--region",p["region"],"--profile",a.get("profile","DEFAULT")]
if shape.endswith(".Flex"):
    cmd += ["--shape-config",json.dumps({"ocpus":ocpus,"memoryInGBs":memory})]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
if r.returncode:
    print("FAIL OCI instance launch failed; mutation was attempted. See audit log.")
    audit_row("apply",False,"oci-launch-failed")
    sys.exit(r.returncode or 1)
try:
    result=json.loads(r.stdout)
    instance_id=result.get("data",{}).get("id","unknown")
except Exception:
    instance_id="unknown"
audit_row("apply",True,"created")
print(f"APPLIED account={account} region={p['region']} shape={shape} instance={instance_id}")
PY
