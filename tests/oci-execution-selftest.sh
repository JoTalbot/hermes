#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok(){ echo "OK  $1"; }
bad(){ echo "FAIL $1"; fail=1; }
for f in agents/checks/oci-execution-plan.sh agents/checks/oci-apply.sh; do
  [[ -f "$ROOT/$f" ]] && ok "$f exists" || bad "$f missing"
  bash -n "$ROOT/$f" && ok "$f syntax" || bad "$f syntax"
done
grep -q 'enabled: false' "$ROOT/config/oci/execution-policy.example.yaml" && ok "execution disabled by default" || bad "execution default is not disabled"
grep -q 'allow_paid: false' "$ROOT/config/oci/execution-policy.example.yaml" && ok "paid execution disabled" || bad "paid execution default missing"
grep -q 'require_approval: true' "$ROOT/config/oci/execution-policy.example.yaml" && ok "approval required" || bad "approval gate missing"
grep -q 'max_total_ocpus: 2' "$ROOT/config/oci/execution-policy.example.yaml" && ok "A1 OCPU ceiling is 2" || bad "unsafe OCPU ceiling"
grep -q 'max_total_memory_gib: 12' "$ROOT/config/oci/execution-policy.example.yaml" && ok "A1 memory ceiling is 12 GiB" || bad "unsafe memory ceiling"
grep -q 'shape_limits' "$ROOT/agents/checks/oci-free-tier.sh" && ok "per-shape Free Tier quotas supported" || bad "per-shape quota support missing"
grep -q 'max_instances' "$ROOT/agents/checks/oci-free-tier.sh" && ok "per-shape instance ceilings supported" || bad "per-shape instance ceiling missing"
grep -q 'shape_limits' "$ROOT/agents/checks/oci-apply.sh" && ok "apply enforces per-shape limits" || bad "apply per-shape enforcement missing"
grep -q 'max_actions_per_run' "$ROOT/agents/checks/oci-apply.sh" && ok "apply enforces action-count ceiling" || bad "apply action-count ceiling missing"
grep -q 'inventory-invalid' "$ROOT/agents/checks/oci-apply.sh" && ok "invalid inventory is fail-closed" || bad "invalid inventory is not fail-closed"
if grep -nE 'oci .* (delete|update)|--force|iam .*create|network .*create' "$ROOT/agents/checks/oci-"*.sh >/dev/null 2>&1; then
  bad "OCI handlers contain forbidden delete/update/force/IAM/network mutation patterns"
else
  ok "no forbidden delete/update/force/IAM/network handlers"
fi
if grep -nE 'PRIVATE KEY|password[[:space:]]*=' "$ROOT/config/oci/execution-policy.example.yaml" >/dev/null 2>&1; then
  bad "execution policy contains secret material"
else
  ok "execution policy is secret-free"
fi
exit "$fail"
