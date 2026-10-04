# OCI Orchestrator v1.1.0

## Added

- Approval-gated OCI execution policy with secret-free placement profiles.
- Deterministic execution plan hashes.
- Short-lived, exact-hash approval markers.
- Fresh Compute inventory immediately before a mutation.
- Free Tier shape, OCPU, memory and instance-count ceilings enforced again at apply time.
- Release defaults aligned with Oracle Always Free A1: 2 OCPUs and 12 GiB, with Compute restricted to the account home region.
- OCI instance launch executor for `create_instance`.
- Append-only JSONL audit trail for blocked and attempted executions.
- Execution self-test integrated into `tests/run.sh`.
- Agent policy and bus wiring for execution-plan/apply handlers.

## Safety boundary

- Execution is disabled by default.
- Paid resources are always rejected.
- Only `create_instance` is implemented.
- Delete, resize, IAM mutation, security-list mutation and force operations are not implemented.
- Every apply requires an exact plan hash and a fresh, unexpired approval marker.
- Failed launches are not retried automatically.

## Upgrade path

Copy `config/oci/execution-policy.example.yaml` to the runtime policy path only after reviewing the target tenancy, compartment, subnet, image and shape. Keep `allow_paid: false`.

The v1.1 release intentionally makes the dangerous part narrow. Cloud automation should be boring, deterministic and slightly paranoid. Humans have already demonstrated that the alternative is an invoice.
