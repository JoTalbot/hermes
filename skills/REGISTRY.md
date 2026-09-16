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

## Hermes-native skills (THIS is what Hermes loads)

Layout changed on 2026-09-16: each skill is now `<category>/<name>/SKILL.md` with YAML
frontmatter `name` + `description`. That is not cosmetic — Hermes discovers skills by
`rglob("SKILL.md")` and needs `name`/`description` to build its skills index, so the old flat
`<category>/<name>.md` files were invisible to every agent. `scripts/register-skills.sh` points
Hermes at this directory via `skills.external_dirs` in `$HERMES_HOME/config.yaml`.

| name | category | what it is for | origin |
|---|---|---|---|
| `disk-gate` | backup | refuse installs when the disk cannot hold them | this repo |
| `oci-cloud-firewall` | server | open/verify the CLOUD firewall gate, not just ufw | this repo |
| `step-status-protocol` | multiagent | record step status for parallel agents | `/root/agents/57`, `005-MULTIAGENT-PARALLEL-SKILLS.md` |
| `skills-first` | multiagent | find → use → improve → create, and where catalogues live | `#57 §4-6`, `005 §4-5` |
| `octopus-skill-catalog` | multiagent | pointer to the 243 existing Octopus skills | `/root/agents/-Octopus/skills` |
| `agent-chat-rooms` | multiagent | the shared room where profiles exchange messages | built and tested 2026-09-16 |
| `response-format-ru` | ecosystem | mandated answer format, emoji dictionary, report template | `#70`, `001-GENERAL.md`, `TEMPLATE.md` |
| `chatgpt-backend-export` | chatgpt | export all ChatGPT chats (TLS-fingerprint trick) | `/opt/orchestrator/chatgpt_export` |
| `chatgpt-ui-driver` | chatgpt | drive the ChatGPT web UI over CDP, incl. reconnect rules | `/opt/orchestrator/agent_jo` |

Cost: 9 skills add **870 B** to the system prompt (measured with `hermes prompt-size`; baseline
with 0 skills was 11,845 B). Registering the whole Octopus catalogue would add ~20+ KB and starve
the balancer's prompt budget — that is why `octopus-skill-catalog` is a pointer, not an import.

## New, in this repo

| name | purpose | scope | inputs | outputs | permissions | version | last_updated |
|---|---|---|---|---|---|---|---|
| `doctor` | single health verdict (11 checks + live inference) | whole node | env | `[OK]/[WARN]/[FAIL]` + exit code | read-only | 1.0.0 | 2026-09-15 |
| `secret-scan` | block secrets before commit | repo | `--worktree/--staged/--all` | `clean` or findings | read-only | 1.0.0 | 2026-09-15 |
| `discover-repos` | enumerate git repos as validated TSV | filesystem | — | TSV with `git_ok` | read-only (needs root) | 1.1.0 | 2026-09-15 |
| `gen-project-agents` | project profiles from measured data | repo | TSV | `config/agents/projects/*.yaml` | write repo | 1.0.0 | 2026-09-15 |
| `backup` | verified config/state snapshots; **fails loud on a wrong/empty state dir** | Hermes layer | `HERMES_HOME`, `HERMES_BACKUP_DIR` | tar.gz + entry counts | reads state, writes backup dir | **1.1.0** | 2026-09-15 |
| `verify-backup` | extract the newest archive and compare content hashes to the live tree | Hermes layer | archive path (default: newest) | `VERIFICATION OK/FAILED` | read-only + temp dir | 1.0.0 | 2026-09-15 |
| `oci-cloud-firewall` | open/verify an inbound port on the **cloud** gate, not just ufw | whole node | port number | ingress rule + external proof | writes the OCI security list (root) | 1.0.0 | 2026-09-15 |
| `dashboard-auth` | password-gated dashboard on a public port | remote access | `/etc/hermes/dashboard.env` | 302/401/200 behaviour | writes `$HERMES_HOME`, reads 0600 env | 1.0.0 | 2026-09-15 |
| `register-server` | mint/reuse stable `srv-*` id + manifest | node | hostname | `config/servers/<host>.yaml` | write repo | 1.0.0 | 2026-09-15 |
| `report-balancer-health` | one-line LLM-path verdict (shim, pool, live round trip) | inference | env | `UP/DOWN` lines + exit 0/1/2 | read-only | 1.0.0 | 2026-09-15 |
| `hermes-metrics-exporter` | Prometheus target for the Hermes layer | whole node | — | `/metrics` on 127.0.0.1:9725 | read-only, unprivileged | 1.0.0 | 2026-09-15 |
| `seed-memory` | fold the tagged knowledge base into each profile's `memories/MEMORY.md` | all profiles | repo | 28 memory files | writes `$HERMES_HOME` | 1.0.0 | 2026-09-15 |
| `apply-agent-soul` | propagate the shared operating contract to every profile | all profiles | `config/SOUL.agent.md` | 28 `SOUL.md` | writes profiles | 1.0.0 | 2026-09-15 |
| `aios-openai-shim` | translate chat-completions → `goal` | inference | OpenAI request | OpenAI response | loopback net | **1.3.3** | 2026-09-15 |

## Lessons promoted into skills on 2026-09-15

- `skills/server/oci-cloud-firewall/SKILL.md` — two firewalls, and the cloud one is authoritative. Born from a
  port that was "open" for an hour and unreachable from outside the whole time. Also carries the trap
  that a credential can authenticate yet belong to the wrong tenancy.
- `skills/backup/` — `backup.sh` silently archived `/root/.hermes` (3 entries) and printed "verified";
  a wrong backup that verifies is worse than a missing one. Now it resolves the state dir explicitly,
  refuses a directory without Hermes-home markers, fails on tar errors, and the nightly timer runs
  `verify-backup.sh`, which compares restored content hashes to the live tree.

## Pending proposals (from real repeated work, §15)

| proposal | trigger seen | next step |
|---|---|---|
| `preinstall-disk-gate` | 98%-full box, installs would have died at ENOSPC | promoted: `skills/backup/disk-gate/SKILL.md` |
| `privilege-aware-discovery` | dirty counts wrong without sudo; `/root` size misreported | spec a skill that re-probes with root and refuses on disagreement |
| `quarantine-not-delete` | `rm -rf /opt/liza-mock` deleted two live services mid-audit | move-to-quarantine + kanban event, never delete |
