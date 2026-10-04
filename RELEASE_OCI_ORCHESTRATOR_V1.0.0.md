# OCI Orchestrator v1.0.0

## Added
- Multi-account OCI registry template with secret-free configuration.
- OCI account authentication and subscribed-region checks.
- Compute inventory across configured accounts, regions and compartments.
- Configurable Free Tier guardrails for shapes, total OCPU and memory.
- Placement planner that only emits candidates and never provisions resources.
- Dedicated Hermes profile: oci-orchestrator.
- Bus handlers: accounts, inventory, free-tier, plan.
- Release self-test integrated into tests/run.sh.

## Safety boundary
This release is observe/plan only. It cannot create, delete or resize OCI resources, mutate IAM, mutate security lists, or enable paid provisioning. Missing or stale information produces BLOCK.

## Next phase
A separately reviewed execution layer can add provisioning/recovery only after account policy, quota verification, approval and audit gates are implemented.
