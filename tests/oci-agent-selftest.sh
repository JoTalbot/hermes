#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok(){ echo "OK  $1"; }
bad(){ echo "FAIL $1"; fail=1; }
for f in agents/checks/oci-accounts.sh agents/checks/oci-inventory.sh agents/checks/oci-free-tier.sh agents/checks/oci-plan.sh; do
  [[ -f "$ROOT/$f" ]] && ok "$f exists" || bad "$f missing"
  bash -n "$ROOT/$f" && ok "$f syntax" || bad "$f syntax"
done
grep -q '"oci-orchestrator"' "$ROOT/scripts/wire-agents.sh" && ok "OCI agent wired" || bad "OCI agent not wired"
grep -q 'agent_id: oci-orchestrator' "$ROOT/config/agents/oci-orchestrator.yaml" && ok "OCI profile bus id" || bad "OCI profile not wired"
grep -q 'allow_paid: false' "$ROOT/config/oci/accounts.example.yaml" && ok "paid resources disabled by default" || bad "paid default missing"
if grep -RInE '(PRIVATE KEY|BEGIN RSA|BEGIN OPENSSH|ocid1\.tenancy\.[^R])' "$ROOT/config/oci" >/dev/null 2>&1; then
  bad "secret/real OCID material detected in OCI config"
else
  ok "OCI config contains no credentials"
fi
if grep -RInE '(^|[[:space:]])(oci (compute|iam|network|identity).*(create|delete|update)|--force)' "$ROOT/agents/checks/oci-"*.sh >/dev/null 2>&1; then
  bad "OCI handlers contain forbidden mutation commands"
else
  ok "OCI handlers contain no forbidden delete/update/force/IAM/network mutations"
fi
exit "$fail"
