# OCI Orchestrator

Hermes now contains an OCI multi-account observe/plan agent for managing Oracle Cloud resources while keeping provisioning inside explicit Free Tier guardrails.

## Design

- config/oci/accounts.example.yaml is the non-secret account registry template.
- Runtime credentials remain in OCI CLI profiles/configuration and are never committed.
- oci-orchestrator validates account access, inventories Compute instances, evaluates configured Free Tier ceilings, and produces placement candidates.
- allow_paid defaults to false.
- Missing policy, incomplete inventory, unknown shapes, or exhausted headroom produce BLOCK, never an optimistic plan.
- The first release deliberately has no create/delete/update handlers. Execution must be introduced later as a separately reviewed capability with policy gates.

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

## Release boundary

This release is a control-plane foundation. It can observe and plan across multiple OCI accounts, but cannot provision, resize, delete, mutate IAM, or modify security lists. That separation prevents an agent hallucination from becoming an unexpectedly billable cloud resource.
