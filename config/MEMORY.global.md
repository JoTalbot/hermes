# MEMORY — Hermes OS on arm-server-01 (server id srv-oci-arm-01)

Every claim below is tagged. **FACT** = measured on this host. **OBSERVATION** = seen at least
once, may be situational. **HYPOTHESIS** = plausible, unproven — never act on one as if it were
a FACT. **DECISION** = a choice that was made, with the reason. **LESSON** = a generalisation
from something that actually went wrong.

Do not add an entry without a tag. If you cannot say which tag applies, you do not know yet.

---

## 1. The machine

- **FACT** Ubuntu 24.04.4 LTS, kernel 6.17.0-1020-oracle, aarch64 (Neoverse-N1, 4 cores), 23 GiB
  RAM, root fs `/dev/sda1` 145G. Several hundred GB of other projects' data live here.
- **FACT** This is a *shared production* box: 35+ systemd services, ~20 containers, several live
  projects. Somebody else's uptime outranks your task.
- **FACT** Disk has been at 98% in the past. `df -h /` before any install, pull or build.
- **LESSON** A venv that dies at ENOSPC leaves a broken interpreter on PATH — worse than a venv
  that was never created. That is why `scripts/install.sh` refuses below 6 GB free.

## 2. How a model response reaches an agent (the only supported path)

```
agent (profile)
  -> config: model.base_url = http://127.0.0.1:9700/v1   (managed scope /etc/hermes/config.yaml)
  -> hermes-shim.service  (deploy/shim/aios_openai_shim.py, OpenAI-compatible, loopback)
  -> octopus-aios.service :9600   POST /api/v1/aios/ask {"goal": "..."}
  -> LLM balancer (11 providers, 5 tiers, weighted + health-gated)
```

- **FACT** The Octopus AIOS balancer has **no** OpenAI-compatible endpoint. `POST
  /v1/chat/completions` returns 404 there. Routes are `/health`, `/api/v1/aios/status`,
  `POST /api/v1/aios/ask`, `POST /api/v1/aios/execute`, `GET /api/v1/aios/tasks/{id}`,
  `POST /api/v1/aios/debate`.
- **FACT** Provider keys live **only** in the balancer's environment. No agent, profile or
  script in this repo holds a provider credential. Do not add one.
- **FACT** The shim binds 127.0.0.1 only and requires `Authorization: Bearer
  $HERMES_BALANCER_API_KEY` (from `/etc/hermes/shim.env`, 0600 root — not readable by the agent
  user, on purpose).
- **FACT** The shim rewrites the model name into a balancer *tier hint*
  (`hermes-fast|code|reason|long|local|auto`). Model names like `gpt-4o` are **not** valid here.
- **OBSERVATION** The balancer ignores the `tier` field the shim sends (`GoalRequest` has no
  `tier`; `ask_llm` does not pass one). Provider choice is always weight+health ordered.
  Do not build logic that depends on a specific tier being honoured.
- **OBSERVATION** Provider health flaps: individual providers (e.g. `gemini-gemini-2.5-flash`)
  report unhealthy for minutes at a time. The balancer routes around them; this is not an outage.

## 3. Hermes runtime layout

- **FACT** Agent OS runs as unix user `hermes`, venv `/home/hermes/.hermes-venv` (hermes-agent
  0.19.0 = current PyPI release), home `/home/hermes/.hermes`, binary
  `/home/hermes/.local/bin/hermes`.
- **FACT** A legacy Hermes install exists under `/home/ubuntu/hermes-venv` with home
  `/home/ubuntu/.hermes`. It is wired to the live liza Telegram bridge. **Do not touch it.**
- **FACT** `hermes serve` is the *desktop (Electron) backend* and exits without a packaged app.
  The headless WebUI is `hermes dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open`,
  serving the dist bundled in the pip package. Unit: `hermes-serve.service`.
- **FACT** A named profile does **not** inherit `~/.hermes/config.yaml` ("config.yaml not found
  (using defaults)"). The one shared layer is the managed scope at `/etc/hermes/config.yaml`.
  Change a model setting there, not in 27 places.
- **FACT** `/etc/hermes` **must stay mode 0755**. Hermes' managed-scope loader stats
  `/etc/hermes/.env` and raises `PermissionError` instead of returning False when the directory is
  not traversable — which breaks *every* `hermes` command, kanban included. The secrets inside
  stay 0600. `hermes-env-guard.service` enforces the mode.
- **LESSON** This happened twice on 2026-09-15 (install-time 0750, then an `install -d -m 0700`).
  That is why the mode is now a checked invariant, not a convention.

## 4. Units that must be up

| unit | role | why it matters |
|---|---|---|
| `hermes-env-guard.service` | restores `/etc/hermes/shim.env` and fixes the dir mode | without it a deleted secret is a full outage |
| `hermes-shim.service` | the OpenAI↔balancer translator | no shim = no agent can think |
| `hermes-serve.service` | dashboard/WebUI + JSON-RPC on 127.0.0.1:9119 | the human and Android control surface |
| `hermes-gateway.service` | hosts the embedded kanban dispatcher + cron | no gateway = tasks sit in `ready` forever |

- **LESSON** `hermes kanban daemon` is deprecated — the dispatcher lives in the gateway. Running
  both races for claims.
- **LESSON** The dispatcher spawns agent workers as its **children**. A transient unit
  (`systemd-run`) or a default cgroup kill orphans every spawned task in `running` forever with no
  error anywhere. Hence `KillMode=mixed` on the gateway.
- **FACT** INFO-level gateway lines go to `$HERMES_HOME/logs/gateway.log`, not journald. When
  something "didn't happen", read the file before assuming it did not.

## 5. The agent bus is `hermes kanban`

- **DECISION** No bespoke message bus. Hermes ships a durable SQLite board with atomic claims,
  dependencies, comments, attachments and a dispatcher daemon, shared across profiles. A second
  bus would be weaker and unloved. Board: `hermes-os`.
- **FACT** Verified end-to-end: a task was created, claimed by the dispatcher, executed by the
  `server-guardian` profile with a real shell tool call, and completed with its result on the
  board.
- **FACT** Every profile must have its own `SOUL.md` carrying the shared operating contract;
  `profile create` copies whatever exists at creation time, so `scripts/apply-agent-soul.sh` must
  be re-run after adding a profile.
- **LESSON** Without an explicit autonomy clause, a dispatched task stalls on a `clarify` call
  that nobody can answer. Observed: 120 s lost to a question the model asked itself. `clarify`
  is now removed from the tool allowlist in the managed scope, so this cannot recur.
- **FACT** Delegation is **asynchronous and one-way by default**. There is no "call agent B and
  wait for its reply" verb. A worker that ends its run has ended it. Request/reply across agents
  means: the requester creates a card for the specialist and either completes its own card
  saying what it delegated, or makes its own card depend on the specialist's
  (`hermes kanban link <specialist_id> <mine>`), which parks it in `todo` until the specialist
  finishes, then auto-promotes it.
- **LESSON** A worker cannot wait, and telling a small model to try produces a loop. A card whose
  body said "wait for/read its result" resulted in the *same* sub-task being created **16 times**,
  all running at once, all competing for the same provider quota. The fix is structural, not
  rhetorical: `hermes kanban create ... --idempotency-key <stable-slug>`. Verified — a second
  create with the same key returns the first task's id instead of creating another. Any
  delegation from an agent must carry one.
- **OBSERVATION** Concurrency is a cost control here, not just a speed knob. Four workers running
  at once exhausted the provider pool and every one of them failed; a single card, verified,
  finished. The dispatcher spawns at most one worker per 60 s tick — the storms come from agents
  fanning out, not from the dispatcher.

## 6. Hard rules for anything that writes

- **FACT** Never read, echo or commit: `/etc/hermes/shim.env`, `/etc/hermes/git-credentials`,
  `/etc/octopus/*`, `~/.hermes/.env`, `*.pem`, `~/.ssh/*`.
- **FACT** Never `git reset --hard`, `clean -fd`, `push --force` or `checkout -- .` in a project
  tree. Uncommitted files here are live work — audit found 100+ dirty paths.
- **FACT** `scripts/secret-scan.sh` must print `clean` before any commit. It runs as part of the
  install/doctor path and independently before push.
- **DECISION** Secrets are referenced by name (`${VAR}` in config, `EnvironmentFile=` in units),
  never inlined. That is what makes this repo safe to publish.

## 7. Known-broken or known-open (do not re-discover, do not "fix" blind)

- **FACT** `logistics-recurring-demand-scheduler-1` container is `Exited (1)`. Pre-existing, not
  Hermes-owned. Needs an owner decision.
- **OBSERVATION** `octopus-slo-checker` fires `disk_root_lt_85_percent`; historically it was a
  real disk alert, currently green.
- **OBSERVATION** A cron entry restarts the removed `octopus-devpanel.service` every 2 minutes
  ("Unit not found"). Harmless noise, but it masks real unit failures in the log.
- **HYPOTHESIS** `/etc/hermes/shim.env` was deleted at ~13:30 on 2026-09-15 by a concurrent root
  shell (`/usr/bin/bash -s` appears in the sudo audit log in the 17-second window; no `rm` was
  logged). Not proven. The self-heal guard makes the cause non-critical, but if it recurs, treat
  it as evidence of an unmanaged automation and find it.
- **OBSERVATION** `:5434` (postgres for the logistics control plane) listens on 0.0.0.0/[::] with
  a ufw rule from any address. Pre-existing; flag it, do not change it without an owner.
