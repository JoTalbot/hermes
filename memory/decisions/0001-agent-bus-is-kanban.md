# 1. Isolate the runtime; never re-point the existing install
Decision: run the Hermes agent OS as user `hermes` with `HERMES_HOME=/home/hermes/.hermes`.
Rejected: editing `/home/ubuntu/.hermes/config.yaml`. It pointed at `liza-mock` and
`telegram-hermes.service` injected `HERMES_BIN` into the same venv, so one config edit would have
silently re-routed a live bot.
FACT: config.yaml `base_url: http://127.0.0.1:8000/v1`; unit sets `HERMES_BIN`.

# 2. The bus is `hermes kanban`
Decision: implement §16 by mapping verbs onto kanban, not by writing a bus.
FACT: v0.19.0 exposes `kanban {init,create,swarm,assign,claim,comment,link,dispatch,daemon,stats,…}`,
described as "durable SQLite-backed task board shared across Hermes profiles … claimed atomically".
LESSON: check what the upstream already solves before building the requested subsystem.

# 3. Shim over surgery
Decision: OpenAI→AIOS translation in a loopback shim (9700), balancer unchanged.
OBSERVATION: no unit greps for `9600|aios-bridge`, so a new consumer cannot break an existing one; the
converse (patching the balancer) is unbounded risk across 35 units + 20 containers.

# 4. Tier aliases
Decision: `hermes-{fast,code,reason,long,local,auto}`, balancer picks the provider.
FACT: `/health` exposes `healthy`, `weight`, `avg_latency_ms` per provider — failover lives upstream.
LESSON: put "which model" in exactly one place.

# 5. Agents are read-only by default
Decision: `security` proposes; no role gets `rm`; `main` protected; `network_egress: deny`.
HYPOTHESIS (tested): an agent holding both finding and fix escalates incidents.
FACT: a human `rm -rf` on this box took `liza-mock` + `telegram-hermes` down mid-audit. One typo at
that privilege level is an outage — which is why `rm` is denied everywhere.

# 6. Project agent ⇔ on-disk repo
Decision: 20 agents for on-disk repos; 18 public GitHub repos with no checkout get none.
OBSERVATION: the first generator run produced 30 profiles from GitHub alone, including projects the
server cannot read; a second pass silently dropped 3 valid ones to a lowercase-vs-mixed-case slug bug.
LESSON: derive from the filesystem, validate before writing, and never trust "we generated N things"
without checking which N.
