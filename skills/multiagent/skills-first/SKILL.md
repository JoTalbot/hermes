---
name: skills-first
description: Mandatory find-use-improve-create order before implementing anything, and where this ecosystem's skill catalogues live. Use before writing new automation, scripts or procedures, so existing skills are reused instead of duplicated.
---
# Why
The owner's directive (`#57 §4-6`, `/root/agents/005-MULTIAGENT-PARALLEL-SKILLS.md §4-5`): agents **must not** solve repeatable or complex work with one-off unstructured commands when a skill exists or can be created. Order is fixed: **find → use → improve → create**. Every finished task is expected to crystallise into a reusable skill (log → skill), because a second agent will meet the same problem.
# Find — local catalogues first (measured 2026-09-16)
| catalogue | path | size |
|---|---|---|
| Octopus skills | `/root/agents/-Octopus/skills/` | **243** `SKILL.md`, index `index.json` (178 KB) + `SKILLS_INDEX.md` (29 KB) |
| instruction corpus | `/root/agents/` | 69 numbered `NN_*.md` + 6 new-style `00N-*.md` + 55 files in `_en/` |
| Hermes skills | `hermes skills list` / this directory | see `/opt/hermes/skills/REGISTRY.md` |
| Octopus MCP skills | `/root/agents/-Octopus/skills/mcp/` | MCP TCP server on :9713-:9720 (`SECURITY.md C1`: 777 perms, unowned) |
```bash
# search the Octopus catalogue by keyword
sudo grep -ril "<keyword>" /root/agents/-Octopus/skills --include=SKILL.md | head
sudo python3 -c "import json;d=json.load(open('/root/agents/-Octopus/skills/index.json'));print(len(d['skills_by_name']))"
# and the Hermes side
hermes skills search "<keyword>"     # registries: skills.sh, GitHub, ClawHub, well-known endpoints
hermes skills list
```
# Use / improve / create
1. Read the candidate skill fully — especially its "Do not" section — before running it.
2. Improve in place when you learn something new (keep the format: frontmatter + Why/Use/Do-not/Lesson).
3. Create only when nothing fits: `SKILL.md` with `name` + `description` frontmatter, plus optional `scripts/`, `references/`, `tests/`.
4. Record in your report **which sources of research and which skills** you used — `#57 §6` requires the sources to be captured, not just the conclusion.
# Cost warning (measured, not theoretical)
Hermes injects every enabled skill's `name` + `description` into the **system prompt** of every run. This box is served through the AIOS balancer, which budgets prompt space tightly.
```
system prompt with 0 skills : 11,845 B   (skills index 0 B)
243 Octopus skills would add: ~20+ KB    → do NOT bulk-register /root/agents/-Octopus/skills
```
So: register a **curated** set (as `/opt/hermes/skills` does), and point at big catalogues with a catalogue skill instead of importing them wholesale.
# Do not
- Do not duplicate an existing skill under a new name — check the catalogue first.
- Do not run an Octopus skill without reading it: many carry code that acts on **production** services.
- Do not leave a finished task as prose only; if it will repeat, make it a skill.
