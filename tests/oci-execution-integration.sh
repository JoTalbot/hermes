#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/approvals" "$TMP/bin" "$TMP/audit"

cat >"$TMP/accounts.yaml" <<'YAML'
version: 1
defaults: {allow_paid: false}
accounts:
  - name: test
    profile: DEFAULT
    tenancy_ocid: ocid1.tenancy.oc1..test
    compartment_ocids: [ocid1.compartment.oc1..test]
    home_region: us-ashburn-1
    execution_profiles: [a1-test]
    free_tier: {allow_paid: false}
YAML

cat >"$TMP/policy.yaml" <<YAML
version: 1
execution:
  enabled: true
  allow_paid: false
  require_approval: true
  approval_ttl_seconds: 900
  max_actions_per_run: 1
  allowed_actions: [create_instance]
  allowed_shapes: [VM.Standard.A1.Flex]
  max_total_ocpus: 2
  max_total_memory_gib: 12
  max_instances: 2
  audit_log: $TMP/audit/execution.jsonl
  approval_dir: $TMP/approvals
  placement_profiles:
    - name: a1-test
      region: us-ashburn-1
      compartment_ocid: ocid1.compartment.oc1..test
      availability_domain: AD-1
      subnet_ocid: ocid1.subnet.oc1..test
      image_ocid: ocid1.image.oc1..test
      shape: VM.Standard.A1.Flex
      shape_config: {ocpus: 1, memory_in_gbs: 6}
YAML

cat >"$TMP/bin/fake-oci" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"compute instance list"* ]]; then
  printf '%s\n' '{"data":[]}'
elif [[ "$*" == *"compute instance launch"* ]]; then
  printf '%s\n' '{"data":{"id":"ocid1.instance.oc1..fake"}}'
else
  echo "unexpected fake OCI invocation: $*" >&2
  exit 2
fi
SH
chmod +x "$TMP/bin/fake-oci"

HASH=$(python3 - "$TMP/policy.yaml" <<'PY'
import hashlib, json, sys, yaml
p=yaml.safe_load(open(sys.argv[1]))["execution"]
profile=next(x for x in p["placement_profiles"] if x["name"]=="a1-test")
canonical=json.dumps({"account":"test","placement_profile":"a1-test","profile":profile,
                      "allowed_actions":sorted(set(p["allowed_actions"]))},
                     sort_keys=True,separators=(",",":"))
print("sha256:"+hashlib.sha256(canonical.encode()).hexdigest())
PY
)
APPROVAL="${HASH//:/_}"
touch "$TMP/approvals/$APPROVAL.approved"

PLAN_OUT=$(OCI_ACCOUNTS_CONFIG="$TMP/accounts.yaml" OCI_EXECUTION_POLICY="$TMP/policy.yaml" bash "$ROOT/agents/checks/oci-execution-plan.sh")
grep -q "PLAN_HASH $HASH" <<<"$PLAN_OUT"

APPLY_OUT=$(OCI_ACCOUNTS_CONFIG="$TMP/accounts.yaml" OCI_EXECUTION_POLICY="$TMP/policy.yaml" OCI_BIN="$TMP/bin/fake-oci" ARGS_JSON="{\"action\":\"create_instance\",\"account\":\"test\",\"placement_profile\":\"a1-test\",\"plan_hash\":\"$HASH\"}" bash "$ROOT/agents/checks/oci-apply.sh")
grep -q "APPLIED account=test" <<<"$APPLY_OUT"
grep -q '"event": "apply"' "$TMP/audit/execution.jsonl"

BAD_OUT=$(OCI_ACCOUNTS_CONFIG="$TMP/accounts.yaml" OCI_EXECUTION_POLICY="$TMP/policy.yaml" OCI_BIN="$TMP/bin/fake-oci" ARGS_JSON='{"action":"create_instance","account":"test","placement_profile":"a1-test","plan_hash":"sha256:invalid"}' bash "$ROOT/agents/checks/oci-apply.sh" || true)
grep -q "BLOCK plan hash mismatch" <<<"$BAD_OUT"

echo "OK  fake OCI plan -> approval -> apply -> audit -> invalid-plan block"
