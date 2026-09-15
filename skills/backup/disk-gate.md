---
name: disk-gate
purpose: refuse installs/pulls when the root filesystem cannot hold them
scope: pre-flight for any step that writes >100 MB
inputs: HERMES_MIN_FREE_GB (default 6)
outputs: exit 0 + "disk ok" or exit 1 + the exact re-run instruction
permissions: read-only (df)
dependencies: coreutils
projects: all
version: 1.0.0
last_updated: 2026-09-15
---
# Why
On `arm-server-01` the root filesystem sat at 98% (3.8 G free) during this audit. `pip install`,
`docker pull` and Playwright's browser download all fail at ENOSPC in ways that look like network
errors, and a half-written venv is worse than no venv. The gate is the skill; the message is the value.
# Use
`install.sh` calls it before touching anything. A failed gate says "free space, then re-run — this
script is safe to repeat", because idempotency is what makes a retry cheap.
# Do not
Do not "fix" the gate by lowering the threshold. Free space: `journalctl --vacuum-size=200M`,
`docker system prune`, `apt-get clean`. Never `rm -rf` a service's data directory to buy room — see
`memory/incidents/2026-09-15-runtime-deletions.md`.
