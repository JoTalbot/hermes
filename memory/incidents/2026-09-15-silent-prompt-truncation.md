# Incident: every dispatched agent silently received no instructions

- **DATE** 2026-09-15, ~13:50–14:20 UTC
- **IMPACT** Every kanban task dispatched to an agent produced either a generic
  greeting or an empty completion. Three tasks were auto-blocked by the dispatcher
  after repeated protocol violations. No task could succeed.
- **DETECTED BY** reading the worker's task log
  (`…/boards/hermes-os/logs/t_5a7ea448.log`): `Messages: 6 (3 user, 0 tool calls)`
  and a reply of `{"content":""}`.

## FACT
- The shim concatenated `[system] + [tools] + [history]` into one `goal` string.
- `llm_balancer` forwards only `prompt[:4000]` to the provider and reports nothing.
- With the agent's SOUL, tool protocol header and 17–42 tool schemas, the budget was
  consumed before the user's instruction. Measured reproduction: a request whose
  first 2768 tokens are system + tools returned `{"content":""}` with
  `completion_tokens: 3`.

## LESSON
A silent truncation at an integration boundary is worse than a loud error, because
every layer above it reports success. When two systems disagree about how much
context exists, measure the cut and design for it explicitly.

## FIX
Shim 1.3.0 — budgeted goal assembly, `[task]` section first, `[earlier]` last.
Verified by unit test: task text now lands at character 72 with 42 tools present.

## FOLLOW-UP
`llm_tool_block_degraded_total` and `llm_goal_budget_exhausted_total` are exported so
this becomes visible if it regresses.
