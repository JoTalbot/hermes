# Communication & the agent bus

The master task specified a bus with `message | task | result | event | request | knowledge`,
broadcast, direct, and request/reply. It exists already — as `hermes kanban`, which is durable, atomic,
and cross-profile. We map onto it rather than forking a second, weaker bus.

| §16 verb | kanban realisation |
|---|---|
| task | `kanban create "…" --assignee <profile> [--board <project>]` |
| result | `kanban comment` + `kanban complete` |
| event | `kanban comment` (no assignee, nobody must act) |
| request | `kanban create --type request` |
| reply | `kanban comment --reply-to <task>` |
| broadcast | one task per assignee, or `notify-subscribe` |
| status | `kanban stats` / `kanban list --state <s>` |
| error | `kanban block --reason "<error>"` |
| knowledge | memory write + a comment carrying the memory reference |

The §16 JSON envelope is the *wire* shape for anything that needs it (webhooks, the events API). It is
not the storage format, because a task board with atomic claims gives you delivery, retries,
dependencies and an audit trail that a message log does not.

```json
{"id":"<kanban task id>","timestamp":"2026-09-15T10:04:00Z","sender":"server-guardian",
 "recipient":"project:madworld","type":"task","priority":"normal",
 "context":{"server":"srv-oci-arm-01","project":"madworld"},"payload":{"goal":"…"},
 "reply_to":null}
```

## Why a queue and not agent→agent function calls

Direct calls mean a caller is blocked by the callee's failure, and one stalled agent stalls its callers.
Durable claims mean an agent can restart, crash, or be re-tuned mid-task without losing the delegation —
on a box already running 20 containers, 35 units and a load average of ~5, that is the difference
between a self-healing system and a cascade.

## Calling another agent, concretely

```bash
H=/home/hermes/.hermes-venv/bin/hermes
$H kanban create "check CI on JoTalbot/hermes, report red checks" --assignee github --board hermes-os
$H kanban create "is :9222 still bound to 0.0.0.0?" --assignee security
$H kanban dispatch --board hermes-os       # profiles claim atomically and run in their own workspace
$H kanban show <id>                        # caller polls the task; it never holds the callee
```

`orchestrator` is the only profile allowed to *spawn* work (`can_spawn_agents: true`); project agents
may request work but cannot mint agents. That keeps the topology auditable: every task has one author
and one assignee.

## Rules

- One task, one assignee. A task addressed to three agents gets done by none.
- Task bodies carry their own context — assignees do not get the whole box (§MEMORY.md).
- A result that was not verified is not a result; `kanban complete` requires the task's own check to have passed.
- Never put a secret in a task body or comment. The board is versioned, exported and read by every profile.
