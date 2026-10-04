#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/accounts.yaml" <<'YAML'
version: 1
defaults: {allow_paid: false}
accounts:
  - name: primary
    profile: PRIMARY
    tenancy_ocid: ocid1.tenancy.oc1..primary
    compartment_ocids: [ocid1.compartment.oc1..primary]
    home_region: us-ashburn-1
    regions: [us-ashburn-1, eu-frankfurt-1]
    execution_profiles: [a1-small]
    free_tier: {allow_paid: false}
  - name: secondary
    profile: SECONDARY
    tenancy_ocid: ocid1.tenancy.oc1..secondary
    compartment_ocids: [ocid1.compartment.oc1..secondary]
    home_region: us-phoenix-1
    regions: [us-phoenix-1, us-ashburn-1]
    execution_profiles: [a1-large]
    free_tier: {allow_paid: false}
YAML

cat >"$TMP/policy.yaml" <<'YAML'
version: 1
execution:
  enabled: false
  allow_paid: false
  allowed_shapes: [VM.Standard.A1.Flex]
  max_total_ocpus: 2
  max_total_memory_gib: 12
  max_instances: 2
  placement_profiles:
    - name: a1-small
      region: us-ashburn-1
      compartment_ocid: ocid1.compartment.oc1..primary
      shape: VM.Standard.A1.Flex
      shape_config: {ocpus: 1, memory_in_gbs: 6}
    - name: a1-large
      region: us-phoenix-1
      compartment_ocid: ocid1.compartment.oc1..secondary
      shape: VM.Standard.A1.Flex
      shape_config: {ocpus: 2, memory_in_gbs: 12}
YAML

cat >"$TMP/bin/fake-oci" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ "$*" == *"--profile PRIMARY"* ]]; then
  printf '%s\n' '{"data":[{"shape":"VM.Standard.A1.Flex","shape-config":{"ocpus":1,"memory-in-gbs":6}}]}'
elif [[ "$*" == *"--profile SECONDARY"* ]]; then
  printf '%s\n' '{"data":[]}'
else
  echo "unexpected fake OCI invocation: $*" >&2
  exit 2
fi
SH
chmod +x "$TMP/bin/fake-oci"
FAKE_LOG="$TMP/oci.log" OCI_ACCOUNTS_CONFIG="$TMP/accounts.yaml" \
  OCI_EXECUTION_POLICY="$TMP/policy.yaml" OCI_BIN="$TMP/bin/fake-oci" \
  bash "$ROOT/agents/checks/oci-capacity-plan.sh" >"$TMP/out"

grep -q 'CANDIDATE account=primary profile=a1-small' "$TMP/out"
grep -q 'CANDIDATE account=secondary profile=a1-large' "$TMP/out"
grep -q 'RANKED secondary/a1-large:' "$TMP/out"
grep -q -- '--region us-ashburn-1 --profile PRIMARY' "$TMP/oci.log"
grep -q -- '--region us-phoenix-1 --profile SECONDARY' "$TMP/oci.log"
! grep -q -- '--region eu-frankfurt-1' "$TMP/oci.log"
! grep -q -- '--region us-ashburn-1 --profile SECONDARY' "$TMP/oci.log"

echo "OK  fake OCI multi-account capacity ranking and home-region scoping"
