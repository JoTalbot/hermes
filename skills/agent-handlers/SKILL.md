---
name: agent-handlers
description: Add a new handler (capability) to a Hermes agent, or add a whole new agent, safely and reproducibly via config/agents YAML + scripts/wire-agents.sh. Use when an agent must do something new, or when a new project/role needs its own agent.
capability: Добавлять обработчик или нового агента через config/agents/*.yaml и scripts/wire-agents.sh, с проверкой разводки (--check).
bounds: Не даёт агенту произвольный shell: обработчиком может быть только объявленный скрипт; править блок bus: руками нельзя — он перезаписывается генератором.
---

# Add an agent capability

Agents are configured, not coded. The runtime (`agents/runtime.py`) reads
`config/agents/*.yaml` and `config/agents/projects/*.yaml` and executes **only** the handlers
declared in the `bus.handlers` block of the agent's own file.

## 1. Write the check script

`agents/checks/<name>.sh` — read-only by default, prints facts, exits non-zero on failure:

```bash
#!/usr/bin/env bash
set -uo pipefail
echo "FACT ..."; df -h / | awk 'NR==2{print "  /: "$5" used"}'
```
Rules: no `rm`, no restarts, no writes unless the agent owns the service; never print secret
values (only modes and names); a missing tool is a WARNING, not a crash.
Then `chmod 0755` and `bash -n` it.

## 2. Declare it in the agent's YAML (never by hand)

`scripts/wire-agents.sh` owns the block between its marker and EOF. Edit the CORE map in the
script (for the six specialists) or re-run `gen-project-agents.sh` (for project agents):

```python
"monitoring": dict(
    purpose="…",
    capabilities=["monitoring", "prometheus", ...],
    handlers={"health": f"bash {CHECKS}/monitoring-health.sh",
              "identity": None, "ping": None}),   # None = runtime built-in
```
Handlers may carry static `env:` (discovered facts: project path, service, containers).

```bash
sudo bash scripts/wire-agents.sh           # apply
sudo bash scripts/wire-agents.sh --check   # drift only, exit 3 when out of sync
sudo systemctl restart hermes-agents
```

## 3. Test before believing it

```bash
sudo /opt/hermes/.venv-bus/bin/python agents/runtime.py list          # is it listed with capabilities?
sudo /opt/hermes/.venv-bus/bin/python agents/runtime.py invoke <agent> <handler>
hermes-bus request --to <agent> --timeout 90 "<handler>"             # the real path
```
The suite gates this too: `tests/run.sh` checks that every declared handler script exists,
that agent ids are unique with non-empty capabilities, and that wiring is in sync
(`bash scripts/wire-agents.sh --check`).

## 4. Capabilities drive routing

The orchestrator picks a target by capability:
`hermes-bus dm --to orchestrator --kind task "dispatch capability=monitoring handler=health task=проверка"`
An agent with no capabilities is unreachable by routing and is a bug (test #8 fails).
Then commit: validate → `scripts/secret-scan.sh --worktree` → `tests/run.sh` → commit → push.
