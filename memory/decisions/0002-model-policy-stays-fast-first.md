# 3. The model policy stays fast-first (local-first stays an inactive scenario)

Decision: keep `config/models.yaml` as the active policy — default `hermes-fast`, per-agent
profiles as committed, escalation by task shape — and keep the local-first variant as an
inactive, valid scenario in `config/models.arm-pending.yaml`.

Rejected: making `hermes-local` (ollama qwen2.5:3b on this box) the default for routine agents,
which is what the scenario proposes. Measured on `arm-server-01`, 2026-09-22, through the shim
(`127.0.0.1:9700`, so both go through the same balancer path):

| Request | `hermes-local` (arm-qwen2.5-3b) | `hermes-fast` (groq-gpt-oss-20b) |
|---|---|---|
| "скажи одним словом" | 0.80 s | 0.41 s |
| routine ask, 900-char facts, ≤300 tokens out | **18.77 s**, 137 tokens, answer drifts and repeats the input | **0.74 s**, 248 tokens, structured answer |

FACT: the cost argument does not apply. Both tiers are free to the owner (free Groq/Cerebras keys
behind the fast tier; ollama runs on this box). The local tier is 25× slower on a realistic
routine prompt and needs facts truncated to 900 characters (`agents/models.py`, `fact_limit`) to
stay inside the provider timeout at all — the 173.6 s first-pass measurement recorded by the code
author on 2026-09-19 is the same effect at full prompt size.

FACT: `hermes-local` is also the degradation path (`agents/models.py` falls back to it when the
balancer is unreachable) and is used by other services on this box through the balancer's `local`
tier. Making it the default would put every routine agent ask on the same 3B model and the same
four ARM cores that the rest of the box shares (load 1.9 at the time of the measurement).

LESSON: "prefer free/cheap models" (the owner's rule in `config/models.yaml`) does not choose
between two free tiers. When price is equal, the deciding evidence is latency and answer quality
on a realistic prompt — measured, not assumed.

How to flip later: apply the scenario exactly as its header describes (copy over
`config/models.yaml`, run `scripts/install-model-policy.sh --check`, restart `hermes-agents`), and
measure again before keeping it: `curl` the shim with `hermes-local` on a routine prompt with
full-size facts, not on "скажи одним словом".
