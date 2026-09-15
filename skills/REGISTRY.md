# Skill registry

Inventory **before** authoring (§13: don't duplicate what exists). Scope is deliberately wide: on this
box a lot of "skills" already exist as shell automation, and a Hermes skill that shadows one of those
creates two truths.

## Already on the server — reuse, do not reimplement

| name | purpose | location | permissions | note |
|---|---|---|---|---|
| `mcp-tcp-server` | serve skills over MCP TCP | `/root/agents/-Octopus/skills/mcp/tcp_mcp_server.py` (:9713-:9720) | root service | **777 perms — SECURITY.md C1** |
| `skills-index` | skill catalogue | `/root/agents/-Octopus/skills/SKILLS_INDEX.md` (29 KB) | root | read-only for Hermes |
| `octopus-bootstrap.sh` | swarm node bootstrap | `/root/agents/-Octopus/skills/core/` | root | predates Hermes |
| `octopus-slo-guardian` | 15-check SLO machine | `/opt/octopus-slo-guardian.sh` | root | **use it**: `disk_root_lt_85_percent` etc. |
| `octopus-mesh-sentinel` | cross-node self-healing | `/opt/octopus-mesh-sentinel.py` | root | don't start a second supervisor |
| `octopus-multisync` | multi-master directory sync | `/opt/octopus/octopus-multisync.py` | root | relevant to MULTI_SERVER |
| `octopus-agent-recovery` | pairing/approvals API | `/opt/octopus-agent-recovery/server.py` | root | the approval flow we should reuse, not rebuild |
| `jo-agent-*` | 5 ChatGPT project drivers | `systemctl cat jo-agent-{fs,game,logistics,transcribe,ukraine}` | ubuntu | **overlaps project agents — reconcile** |
| `logistics-agent` | remote agent for logistics | `/opt/logistics-agent` | logistics-agent | model=auto via :8787 |
| `prometheus+grafana` | metrics/UI | docker `octopus-prometheus` :9090, `octopus-grafana` :3000 | root | add scrapes, don't replace |

Two collisions to resolve before scaling up: (1) `jo-agent-*` already does per-project autonomous
work — deciding whether Hermes project agents replace, feed, or duplicate it is a design decision for
the owner, not for an agent to make unilaterally. (2) `octopus-agent-recovery` is already an
approval/pairing service; `config/policies/agent-policy.yaml` should call it rather than invent a second
approval store.

## New, in this repo

| name | purpose | scope | inputs | outputs | permissions | version | last_updated |
|---|---|---|---|---|---|---|---|
| `doctor` | single health verdict (11 checks + live inference) | whole node | env | `[OK]/[WARN]/[FAIL]` + exit code | read-only | 1.0.0 | 2026-09-15 |
| `secret-scan` | block secrets before commit | repo | `--worktree/--staged/--all` | `clean` or findings | read-only | 1.0.0 | 2026-09-15 |
| `discover-repos` | enumerate git repos as validated TSV | filesystem | — | TSV with `git_ok` | read-only (needs root) | 1.1.0 | 2026-09-15 |
| `gen-project-agents` | project profiles from measured data | repo | TSV | `config/agents/projects/*.yaml` | write repo | 1.0.0 | 2026-09-15 |
| `backup` | verified config/state snapshots | Hermes layer | env | tar.gz + integrity result | reads state, writes `state/backups` | 1.0.0 | 2026-09-15 |
| `register-server` | mint/reuse stable `srv-*` id + manifest | node | hostname | `config/servers/<host>.yaml` | write repo | 1.0.0 | 2026-09-15 |
| `aios-openai-shim` | translate chat-completions → `goal` | inference | OpenAI request | OpenAI response | loopback net | 1.0.0 | 2026-09-15 |

## Pending proposals (from real repeated work, §15)

| proposal | trigger seen | next step |
|---|---|---|
| `preinstall-disk-gate` | 98%-full box, installs would have died at ENOSPC | promote `install.sh` check into a standalone skill |
| `privilege-aware-discovery` | dirty counts wrong without sudo; `/root` size misreported | spec a skill that re-probes with root and refuses on disagreement |
| `quarantine-not-delete` | `rm -rf /opt/liza-mock` deleted two live services mid-audit | move-to-quarantine + kanban event, never delete |
