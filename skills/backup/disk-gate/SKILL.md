---
name: disk-gate
description: Refuse an install, pull or download when the root filesystem cannot hold it, and say why in one line. Use before any step that writes more than ~100 MB (pip install, docker pull, model/browser download).
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
