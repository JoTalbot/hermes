# Agent model

Seven roles plus one profile per on-disk project. Every profile is a real `hermes profile`
(`scripts/install-agents.sh`) plus a YAML in `config/agents/` — the YAML is the reviewable source, the
profile is the running thing.

| role | model tier | shell | owns | must not |
|---|---|---|---|---|
| orchestrator | hermes-auto | none | decomposition, priority, conflict arbitration, DECISION records | execute; mark done without verification |
| server-guardian | hermes-fast | allowlist | CPU/RAM/disk/docker/systemd/logs, `hermes-*` units | restart a service it doesn't own |
| github | hermes-code | git, gh | this repo, sync, PRs, CI, docs | push `main`; force-push; skip secret scan |
| security | hermes-reason | read-only | exposure, permissions, CVEs, secret hygiene | remediate — proposals only |
| monitoring | hermes-fast | curl/systemctl | doctor cadence, metrics, alert trends, loop detection | break existing Octopus monitoring |
| backup | hermes-fast | tar/pg_dump/rsync | config+state snapshots, restore drills, DB dumps | read `secrets.env` / `.env` |
| project:\<slug\> ×20 | hermes-code | inside its tree | its own repo, tests, CI, docs | touch another project; reset dirty files |

Two choices worth defending:

**The orchestrator has no shell.** Planning that can also execute is how a misread instruction becomes
an action. It decomposes, assigns and adjudicates; if it wants something run it files a task.

**Security is read-only.** Its output is a patch proposal with a blast-radius estimate. The C1 finding
in SECURITY.md sat unfixed for months precisely because fixing "obvious" permission problems on a live
root service is a change that can stop that service — and an agent that owns both the finding and the fix
has no one to argue with.

Delegation is a kanban task to a named assignee (`docs/COMMUNICATION.md`), never a direct call — so a
restarted or failing agent cannot cascade, and every handoff is auditable.

Skills are capability, not permission: a skill in `skills/` that a role's allowlist forbids is
unreachable, and nothing auto-escalates because a new skill appeared (§15).
