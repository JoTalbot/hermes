# LLM Balancer — measured contract

Audited 2026-09-15 on `arm-server-01`. Everything below is from `systemctl cat`,
`ss -lntp`, live `curl`, and reading the unit's `ExecStart` source — not from prose.

## What it is

```
octopus-aios.service
  ExecStart=/opt/aios-venv/bin/python3 /opt/octopus-aios-server.py
  WorkingDirectory=/opt/aios
  EnvironmentFile=/etc/octopus/secrets.env
  listens 0.0.0.0:9600
```

`GET /health` reports the balancer inline:

```json
{"ok":true,"service":"octopus-aios-bridge","version":"1.1.0",
 "aios_kernel_state":"running",
 "llm_balancer":{"total_providers":11,"cache_size":0,
   "providers":[{"name":"cerebras-llama3.3-70b","tier":"fast","healthy":true,"weight":2,
                  "calls":162,"avg_latency_ms":0.0,"keys_count":3}, ...]}}
```

Providers seen, with tier and key count (counts only — never key material):

| provider | tier | weight | keys |
|---|---|---|---|
| cerebras-llama3.3-70b | fast | 2 | 3 |
| groq-gpt-oss-20b | fast | 1 | 13 |
| groq-qwen3.8-27b | fast | 2 | 13 |
| groq-gpt-oss-120b | reasoning | 3 | 13 |
| mistral-small | code | 7 | 1 |
| gemini-gemini-2.5-flash | long_context | 10 | 2 |
| hf-Qwen2.5-72B-Instruct | code | 15 | 1 |
| liza-rpa-gemini-web | long_context | 18 | 0 |
| ollama-qwen2.5:1.5b | local | 20 | 0 |
| ollama-llama3.2:3b | local | 25 | 0 |
| autonomous_heuristic_engine | local | 999 | 0 |

## The correction that matters

**There is no OpenAI-compatible endpoint.** Measured on the live socket:

```
POST /v1/chat/completions  → 404     POST /v1/completions → 404
GET  /v1/models            → 404     POST /chat/completions → 404
POST /models /generate /api/chat /llm/chat /status /metrics → 404
```

The real routes, from the source (`grep -nE '@app\.(get|post)'`):

```
GET  /health
GET  /api/v1/aios/status
POST /api/v1/aios/ask       {"goal": "<text>", "tier": "fast"?}
POST /api/v1/aios/execute   {"goal": "<text>", ...}
GET  /api/v1/aios/tasks/{task_id}
POST /api/v1/aios/debate
```

`goal` is **required**. Confirmed by the balancer's own validation error, which is how we pinned the
field name without guessing:

```json
{"detail":[{"type":"missing","loc":["body","goal"],"msg":"Field required",
            "input":{"question":"...","tier":"fast"}}]}
```

Any plan that says "point Hermes at the balancer's OpenAI-compatible endpoint" cannot be executed as
written. It requires translation: `deploy/shim/aios_openai_shim.py`, bound to `127.0.0.1:9700`.

## Shim contract

| shim route | behaviour |
|---|---|
| `POST /v1/chat/completions` | maps `model`→tier, flattens `messages[]` into `goal`, calls `/api/v1/aios/ask`, returns OpenAI-shaped JSON |
| `GET /v1/models` | the 6 tier aliases |
| `GET /health` | ok/upstream/metrics |
| `GET /metrics` | Prometheus text (`llm_requests_total`, `llm_errors_total`, `llm_latency_ms_*`) |

Failure modes, all verified against a fake AIOS reproducing the real schema:

| condition | result |
|---|---|
| missing/bad bearer token | `401 auth_error` |
| upstream unreachable | `502 upstream_error` with `upstream_status` — process stays up |
| upstream ≥400 | `502` carrying the upstream body (first 500 chars) |
| `HERMES_BALANCER_API_KEY` unset | **refuses to boot** unless `HERMES_SHIM_ALLOW_ANONYMOUS=1` |

## Lossy path (read before relying on it)

`/api/v1/aios/ask` has one `goal` field. Multi-turn history, and any assistant tool-call structure,
are flattened into a single prompt string:

```
[system] be terse
[user] say hello
[assistant] ok
[tool] results here
```

Consequences: no provider-side conversation state, no real function-calling loop through the balancer,
and per-turn token cost is the full flattened transcript. Acceptable for the guardian/monitoring/backup
agents (short, stateless, tool-light). For heavy coding agents, point Hermes at a real
OpenAI-compatible endpoint and keep the balancer for routing metadata — or teach the balancer
`messages[]` and delete the shim.

## Health gating

`healthy` and `weight` come from the balancer; `avg_latency_ms` and `calls` too. So "automatic
switching between available endpoints" is already implemented upstream of Hermes. Hermes' own
`hermes fallback` handles provider-level retries on top of the 502s the shim surfaces.

## Blast radius

`grep -rlE '9600|aios-bridge' /etc/systemd/system/` returned **nothing**: the balancer is reached by
clients that hardcode the port elsewhere. Starting a *new* consumer (the shim) cannot break an existing
one. Do not change the balancer's bind address or port without that grep being re-run.

## Silent truncation at 4000 characters — the most important fact in this file

`llm_balancer.OpenAICompatibleCloudProvider.generate` does:

```python
messages.append({"role": "user", "content": prompt[:4000]})
```

Everything past character 4000 of the shim's `goal` is **invisible to the model**,
and nothing anywhere reports that it was dropped. This produced the two most
expensive failures of the build:

- **FACT** A dispatched kanban task answered `Ready to assist. How can I help you
  today?` — the tool schemas came first in the prompt, so the agent's actual
  instructions were cut off entirely.
- **FACT** With a long system contract plus 42 tools, the model replied
  `{"content":""}` (well-formed, empty) and the worker exited with 0 tool calls,
  three times, each costing a minute of dispatcher retry.

The shim now assembles the goal against an explicit budget (`GOAL_BUDGET = 3900`)
with the sections ordered by importance — `[task]` first, then `[recent]`,
`[system]`, `[tools]`, then whatever history fits. If you change the shim, keep that
order: it is not stylistic, it is the difference between working and not.

`MAX_STRING_IN_HISTORY` and `TOOLS_BUDGET` bound the other contributors. If
`llm_tool_block_degraded_total` climbs, tools are being rendered terser to fit — the
model can still call them, but descriptions are gone.

## The emergency fallback is not an answer

When every provider fails, the balancer returns local boilerplate from
`autonomous_heuristic_engine`:

```
AIOS Reasoner: Запрос '…' проанализирован автономным ядром кластера…
```

It arrives with `status: success`, so a naive client treats it as a completion. An
agent then "completes" a task with no content, or wanders off into unrelated advice.
The shim detects it (`provider` in the fallback set, or the marker phrases), retries
once, and otherwise returns **503** — a visible failure is worth more than a silent
non-answer.

## What not to do (measured, 2026-09-15)

- **Do not add a client-side circuit breaker.** One was tried: 24 fallbacks produced
  **312** instant 503s, because Hermes retries a 5xx immediately and each retry
  re-tripped the breaker. Opening the circuit turned a degraded pool into an outage.
- **Do not add retry loops in the shim.** The balancer already walks its entire
  provider list before falling back; a second call at the shim is pure amplification
  against a pool that is already failing.
- **Do not chase a single provider's health.** `gemini-2.5-flash` was observed
  unhealthy for minutes at a time and the path kept working. Alert on
  `llm_upstream_fallback_total`, not on one provider.

## Tier hints are sent but ignored

The shim maps `hermes-{fast,reason,code,long,local}` to a tier and puts it in the
`goal` payload; `GoalRequest` has no `tier` field and `ask_llm()` never passes
`task_type`, so `classify_task()` always decides. To make tier hints real, one line
in `/opt/octopus-aios-server.py` is enough (`task_type=req.tier or "auto"`). Not
done: it is a production service and the current behaviour is correct, just
unoptimised.
