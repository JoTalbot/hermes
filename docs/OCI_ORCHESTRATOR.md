# OCI Orchestrator

Hermes now contains an OCI multi-account observe/plan agent for managing Oracle Cloud resources while keeping provisioning inside explicit Free Tier guardrails.

## Design

- config/oci/accounts.example.yaml is the non-secret account registry template.
- Runtime credentials remain in OCI CLI profiles/configuration and are never committed.
- oci-orchestrator validates account access, inventories Compute instances, evaluates configured Free Tier ceilings, and produces placement candidates.
- v1.1 adds a separately gated execution path for approved instance launches.
- allow_paid defaults to false.
- Missing policy, incomplete inventory, unknown shapes, or exhausted headroom produce BLOCK, never an optimistic plan.
- Execution is separately reviewed and approval-gated. v1.1 implements only create_instance, with execution disabled by default, paid resources forbidden, fresh inventory rechecked immediately before mutation, and every attempt audited.

## Runtime registry

Copy the example to /etc/hermes/oci/accounts.yaml, set mode 0600, and configure one OCI CLI profile per account. The registry contains profile names and resource policy, not private keys.

Each account can declare profile, tenancy_ocid, compartment_ocids, regions, free_tier.allowed_shapes, free_tier.max_total_ocpus and free_tier.max_total_memory_gib.

The guardrails are intentionally configurable rather than assuming a universal quota. Oracle availability and Free Tier eligibility can differ by tenancy and region.

## Handlers

| Handler | Purpose | Mutation |
|---|---|---|
| accounts | authentication + subscribed-region check | none |
| inventory | Compute inventory | none |
| free-tier | consumption vs policy | none |
| plan | placement candidates | none |
| execution-plan | deterministic execution candidate + plan hash | none |
| apply | approval-gated instance launch | create_instance only |

## Release boundary

The v1.1 control plane can execute only a narrowly defined, approved create_instance action. It cannot delete or resize resources, mutate IAM, modify security lists, or enable paid provisioning. The execution policy is disabled by default.
