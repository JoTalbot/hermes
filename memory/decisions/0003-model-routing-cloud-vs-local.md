# 4. Cloud where it counts, the second server where it suffices (2026-09-22)

Owner directive (2026-09-22): use the cloud APIs where they are needed, and the local models on
the second server where they are enough. Decision 0002 (fast-first, local-first stays inactive)
still holds; what changes is that the `local` tier becomes REAL and is served from server 2.

FACT (defect, found and fixed 2026-09-22). `/opt/aios/llm/llm_balancer.py` registered
`ollama-qwen2.5:1.5b` (w20) and `ollama-llama3.2:3b` (w25) as `OllamaLocalProvider`s while the
ollama on this host has exactly one model, `qwen2.5:3b` (`GET /api/tags` on 127.0.0.1:11434).
Both reported `healthy: true`, because `BaseLLMProvider.is_available()` trusts its own memory and
never asks the node — so the degradation path spent a full provider timeout per attempt and then
landed on the boilerplate engine. Fix, in place:
* `OllamaLocalProvider.is_available()` now probes the node (`GET /api/tags`, 60 s cache): a
  provider whose model is not on disk is skipped, not tried;
* the two phantom entries are replaced by the one that exists (`ollama-qwen2.5:3b`, w20), which
  is this host and therefore the backup behind server 2.

FACT (second server = "the local models" of the directive). Server 2 is 130.61.16.167, reached
over WireGuard (`wg0`, 10.99.0.2:8080): ollama 0.34.2 behind nginx. Real models: `qwen2.5:3b`
(3.1B Q4_K_M) and `qwen2.5-coder:7b` (7.6B), plus `nomic-embed-text`; the remaining names in
`/v1/models` are aliases. The balancer already had them registered as ARM providers
`arm-qwen2.5-3b` (local, w5) and `arm-qwen2.5-coder-7b` (local, w6), `strict_tier=True`, using
`MODEL_API_URL` from `/etc/octopus/secrets.env`.

MEASURED (2026-09-22, through the shim on 127.0.0.1:9700, i.e. the path an agent takes; provider
attribution = delta of the balancer's own `total_calls` counters):

| request | tier asked | served by | latency | answer |
|---|---|---|---|---|
| «Назови одним предложением, зачем нужен health-check сервиса.» | `hermes-local` | **arm-qwen2.5-3b** (server 2, wg0) | 4.04 s | correct, coherent, 197 chars |
| the same prompt | `hermes-fast` | groq-gpt-oss-20b | 0.63 s | correct, 156 chars |

MEASURED (degradation — cloud dead). In a throwaway process with all ten cloud providers forced
to raise, `ask(auto)` returned `status=success`, `provider=ollama-qwen2.5:3b` (this host), in
6.9 s with a real answer: a cloud outage now lands on a local model, not on the boilerplate
engine. ARM providers are skipped for non-`local` tiers by design (`strict_tier=True`), so an
outage on a `fast` request is answered by this host's ollama.

POLICY — what runs where:

| work | tier | where it actually runs |
|---|---|---|
| agent↔human answers, triage, diagnosis | `hermes-fast` | cloud (Groq / Cerebras free keys) |
| analysis, planning, risk | `hermes-reason` | cloud (Groq gpt-oss-120b) |
| diffs, review, refactors | `hermes-code` | cloud (Mistral, HuggingFace) |
| summaries over journals/documents | `hermes-long` | cloud (Gemini Flash) |
| non-egress data, bulk/background jobs, explicit "keep it local", outage fallback | `hermes-local` | server 2 over wg0; this host's ollama as backup |

Rejected: making `hermes-local` the default for routine agents. Re-confirmed against 0002's
measurement: 18.77 s vs 0.74 s on a realistic routine prompt, and both tiers are free to the
owner, so price cannot decide. Server 2 makes the local tier usable (4.0 s for a short ask;
31.1 s for a 200-token 7B generation) but it stays roughly 6× slower than cloud and shares four
ARM cores.

Deliberately NOT changed: `config/models.arm-pending.yaml` stays inactive; the internal AIOS
callers (`consensus/multi_agent_debate.py`, `evolution/auto_evolution_engine.py`,
`memory_fabric/knowledge_graph.py`) keep their tiers — `/api/v1/aios/debate` is user-triggered and
quality-critical; arena stays manual (adaptive 900 s interval by design, `healthy=False`).

Limitations. (1) `/opt/aios/llm/llm_balancer.py` is untracked in the AIOS git repo (adjacent
files are untracked too), so the fix lives in the file plus the backup
`/home/ubuntu/hermes-wave-20260922/llm_balancer.py.pre-20260922` — not committed upstream without
the owner's word. sha256 of the patched file: `69c173545204002fe0e71e9f05892dbc8ce6777fdd907b768ce220e6604731fe`. (2) `hermes-local` still escalates to
`hermes-fast` (cloud) when the local tier fails — deliberate, and logged by the shim. (3) Server
2's 7B coder is registered inside `local` with weight 6, so it answers only when the 3B does not
(weight order 5 → 6 → 20).
