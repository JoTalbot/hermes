# Shared memory

Three scopes, and retrieval is **selective**. Shipping an agent the whole server context on every turn
costs tokens and buries the signal — on a box with 88 GB of `/var/lib` and 20 git trees, "full context"
is not a feature, it is a failure mode.

```
Global   memory/architecture/  memory/lessons/  memory/decisions/  config/policies/
Project  memory/projects/<slug>.yaml            (facts/observations/hypotheses/decisions/incidents/lessons)
Agent    <HERMES_HOME>/memories/                (hermes-native, per-profile)
```

An agent assembled for a turn gets: server manifest (neighbours + known problems only) → policy → its
own profile → its project's memory → the task body. Nothing else.

## Epistemic tags — required, not decorative

| tag | meaning | promotion rule |
|---|---|---|
| FACT | measured, with the command that proved it | must cite the probe |
| OBSERVATION | seen once, not generalised | — |
| HYPOTHESIS | explains observations, unproven | must name its test |
| DECISION | chosen approach + what was rejected | links the F/H that drove it |
| LESSON | what to do differently | only after a verified fix |

**"Verified" means the test was run and the output is attached.** This repo's own history is the
cautionary example: in one session I recorded `/root` as wiped (it was `du` without sudo), a repo as
deleted (it was `404` for a private repo), and disk as fixed (someone cleaned it — not me). All three
were plausible, all three were wrong, and all three would have become FACTS in an agent's context and
then been acted on. So:

- A number without a timestamp is not a fact. Disk on this box moved 98% → 33% mid-session.
- A `404` is not absence. A `0` is not emptiness (unprivileged `git status` returns 0 lines; `dirty=0`
  from an unreadable tree would have told an agent it was safe to reset).
- Record the probe alongside the finding, so the next agent can re-run it.
- Promotion HYPOTHESIS → FACT requires the named test to have been run **by the promoting agent**.
- Incidents get a file in `memory/incidents/` even when the cause was someone else's `rm`.
