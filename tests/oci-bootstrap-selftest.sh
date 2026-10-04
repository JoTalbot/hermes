#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/accounts.yaml" <<'YAML'
version: 1
accounts:
  - name: primary
    profile: DEFAULT
    tenancy_ocid: ocid1.tenancy.oc1..test
    user_ocid: ocid1.user.oc1..test
    compartment_ocids: [ocid1.compartment.oc1..test]
    home_region: us-ashburn-1
YAML

cat >"$tmp/fake-oci" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"iam tenancy get"* ]]; then
  printf '{"data":{"id":"ok"}}
'
  exit 0
fi
exit 1
SH
chmod +x "$tmp/fake-oci"

out="$(OCI_ACCOUNTS_CONFIG="$tmp/accounts.yaml" OCI_BIN="$tmp/fake-oci" bash scripts/oci-bootstrap-check.sh)"
grep -q 'OK    primary: authenticated' <<<"$out"
grep -q 'OCI bootstrap validation: PASS' <<<"$out"
echo "OCI-BOOTSTRAP-SELFTEST: PASS"
