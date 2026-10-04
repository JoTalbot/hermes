# OCI Execution Gate

Hermes v1.1 adds an approval-gated OCI execution path without turning the agent into an unbounded cloud administrator.

## Control flow

fresh inventory -> Free Tier guard -> deterministic plan hash -> explicit approval -> apply -> audit

The executor is intentionally narrow:

- create_instance is the only mutation implemented in v1.1.
- Paid resources are always rejected.
- The target shape must be explicitly allowlisted.
- The target placement must be a named, reviewed profile.
- Inventory is re-read immediately before launch.
- Requested OCPU and memory must fit configured account ceilings.
- An approval file matching the exact plan hash must exist and be younger than the configured TTL.
- Every attempt is appended to an audit JSONL file.
- Secrets and private keys are never accepted as handler arguments.

## Runtime files

- /etc/hermes/oci/accounts.yaml: account registry and Free Tier policy.
- /etc/hermes/oci/execution-policy.yaml: execution policy, allowlists and placement profiles.
- /var/lib/hermes-agents/oci-approvals/: short-lived approval markers.
- /var/lib/hermes-agents/oci-execution.jsonl: append-only execution audit.

The example policy is deliberately disabled. Its A1 defaults are capped at 2 OCPUs and 12 GiB, matching Oracle's current Always Free A1 allowance. Compute execution also requires the account home region. To enable execution on a node, an operator must create the runtime policy with enabled: true, keep allow_paid: false, and define reviewed placement profiles.

## Placement profile

A profile contains non-secret OCI identifiers:

- name
- region
- compartment_ocid
- availability_domain
- subnet_ocid
- image_ocid
- shape
- optional shape_config.ocpus / shape_config.memory_in_gbs
- optional display_name

An account may reference profiles through execution_profiles.

## Failure semantics

Any missing policy, unavailable inventory, policy violation, missing or expired approval, unknown target, or insufficient headroom returns BLOCK and does not launch anything.

A failed OCI launch is recorded as an attempted mutation and returns FAIL. The executor does not retry automatically.

## Capacity allocation

v1.1 also exposes a read-only `capacity-plan` handler. It inventories only each account's home region, evaluates the configured execution profiles against the effective shape limits, and ranks candidates by remaining capacity.

The allocator does not create, delete, resize or move resources. A `CANDIDATE` is only a placement recommendation; normal execution-plan, approval, fresh-inventory and apply gates still apply.


## First real-node bootstrap

After installing the OCI CLI and placing the two-account registry on a Hermes node, run the
read-only validator before any execution policy is enabled:

```bash
bash /opt/hermes/scripts/oci-bootstrap-check.sh
```

The validator checks that the registry is readable, every account has the required non-secret
metadata, and OCI identity calls succeed for each configured profile. It does not create, delete,
resize or otherwise mutate OCI resources. It never prints API keys or private key material.

For an isolated test node, override the paths without modifying the repository:

```bash
OCI_ACCOUNTS_CONFIG=/path/to/accounts.yaml bash scripts/oci-bootstrap-check.sh
```

A successful bootstrap check proves only authentication and registry correctness. It does not
approve execution and does not establish that a requested VM fits current Always Free capacity.
