---
name: octopus-skill-catalog
description: Pointer to the 243 existing Octopus skills and how to search them, so they are reused instead of reimplemented. Use when a task looks like something this ecosystem has already automated (alerting, drills, backup, scheduling, triage, memory).
---
# Why
`/root/agents/-Octopus/skills/` holds a large, older skill library written for the Octopus project. Duplicating any of it inside Hermes creates **two truths** for the same operation, which is exactly what the "skills-first" rule exists to prevent. This skill is the pointer, not a copy: it stays small in the prompt while making the catalogue findable.
# What is there (measured 2026-09-16)
```
/root/agents/-Octopus/skills/          243 SKILL.md  (1,275 md + 596 py = code and tests included)
  core 132   meta 36   swarm 34   memory 32   research 4   dr 2   mcp 2
  aios 0     marketplace 0   auto_mined 0      <- categories that exist but are EMPTY
  index.json (178 KB, 2026-09-02) — {"version","timestamp","audit","skills","skills_by_name"}
  SKILLS_INDEX.md (29 KB, 2026-08-24)   skills_health.json   loader/   _backup_*/   _reorg_backups/
```
Representative names worth checking before writing anything new: `incident-triage`, `octopus-alert-thresholds`, `octopus-alerting`, `octopus-alerts-tg`, `load-aware-scheduler`, `task-prioritizer`, `chaos-monkey-lite`, `dr-config-preflight`, `octopus-eternal-snapshot`, `reproduction-guard`, `orphan-session-drift-guard`, `octopus-multisync`, `octopus-db-cleanup`, `e2e-tests`, `integration-testing`, `octopus-rag-indexer`, `people-graph-octopus`, `llm-evaluation-lite`, `resource-demand-evaluator`, `market-rate-calculator`.
# Use
```bash
# keyword search across the catalogue
sudo grep -ril "<keyword>" /root/agents/-Octopus/skills --include=SKILL.md | head -20
# read one (name + description live in the frontmatter, body = the procedure)
sudo sed -n '1,40p' /root/agents/-Octopus/skills/core/incident-triage/SKILL.md
# machine-readable index (names + descriptions + health)
sudo python3 -c "
import json; d=json.load(open('/root/agents/-Octopus/skills/index.json'))
print(list(d['skills_by_name'])[:20])"
```
# Two formats inside the catalogue — expect both
- newer: `--- name: … description: … ---` frontmatter (Hermes-compatible, see `core/octopus-voice-rag/SKILL.md`);
- older: `# SKILL: <name>` heading with `**Категория:**` / `## Описание` (`core/chaos-monkey-lite/SKILL.md`).
When reusing an older one in Hermes, add the frontmatter header first — Hermes discovers skills by `SKILL.md` + `name`/`description`, without it the skill is invisible.
# Do not
- Do not register the whole catalogue in Hermes: 243 descriptions would roughly triple the system prompt and starve the balancer's prompt budget (measured baseline: 11,845 B with 0 skills).
- Do not run these skills blind: they are written for the Octopus production stack (containers `octopus-*`, ports :8300-8310, :9300-9310, Grafana/Prometheus) and can act on live services.
- Do not edit them from Hermes — they belong to the Octopus project; propose changes through its own process.
- Do not assume `index.json` is current: it was rebuilt 2026-09-02 and categories `aios`, `marketplace`, `auto_mined` are empty.
