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

## Headless invariants

These are properties of *this* deployment — nobody sits at an agent's terminal, so
anything that assumes a human presence is a defect here.

1. **`clarify` is disabled**, via `platform_toolsets` in the managed scope. A
   dispatched worker cannot ask a question: it burned 120s per invocation and stalled
   tasks twice before the tool was removed from the allowlist. Agents decide, state
   the assumption in their result, and proceed. The same instruction is in
   `config/SOUL.agent.md`; the config change makes it a property of the system
   instead of a request to the model.
2. **A run must end with `kanban_complete` or `kanban_block`.** Exiting cleanly
   without either is a *protocol violation* and counts as a crash, no matter how much
   useful work the run did. This is enforced by the dispatcher, not by convention.
3. **Repeated self-blocking escalates.** Blocking twice with the same block kind
   routes the task to a human instead of looping forever.
4. **Retries are finite.** `failure_limit: 2` → a card that crashes twice is
   auto-blocked (`gave_up`). Clear it with `kanban unblock` once the cause is fixed.
5. **Concurrency is a cost control, not just a speed knob.** Four workers dispatched
   at once exhausted the provider pool and every one of them failed. One task at a
   time, verified, beats four in parallel and none finished.

## Delegation semantics (async, via the board)

The board is a queue, not an RPC channel. There is no "call agent B and wait" verb.
The correct pattern:

```bash
# B's work item — no parents, so it runs now
hermes kanban create "Report LLM balancer health" --assignee monitoring
# A waits for it; A is promoted automatically when B completes
hermes kanban link <B_id> <A_id>
```

`A` then sits in `todo` (not `blocked` — nobody has to intervene), and when `B`
finishes the dispatcher promotes `A` to `ready`. `A` reads `B`'s result in its next
run with `kanban_show <B_id>`.

Do **not** write a task body that says "wait for the result" — a worker cannot wait.
Observed: an orchestrator asked to "wait for/read its result" created the same card
four times and then added a comment asking for clarification, which no human answered.

Adding a **comment** with the dependency's ID is worth it: small models read the
comment stream more reliably than they infer relationships from parent links.

## Tier policy (2026-09-17)

`config/models.yaml` + `agents/models.py` decide which model each agent uses. Rules:

1. **Deterministic handlers use no model at all.** A load average is not a matter of opinion;
   `top`, `disk`, `alerts`, `audit` are scripts, so most answers cost nothing.
2. **Routine model work stays on the free fast tier** (Groq/Cerebras free keys).
3. **Escalate only for shape of task:** analysis → `hermes-reason`, code → `hermes-code`,
   long context → `hermes-long`. The escalation is logged with its reason.
4. **Degrade, never fail:** balancer down → local tier (server 2 over wg0, then this host's
   ollama) → facts alone.
5. **No provider keys in agents.** The policy names tiers; only the balancer holds keys.

Measured evidence (2026-09-17): `ask` on the host question answered in ~1.1-1.4 s via
`hermes-reason` (Groq gpt-oss-120b, free tier), while Hermes' own CPU footprint stayed ~2 %.
