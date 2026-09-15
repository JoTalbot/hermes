# Incident: a reliability feature caused 312 failures

- **DATE** 2026-09-15, ~14:30 UTC
- **IMPACT** 312 requests failed instantly; the LLM path was effectively down.
- **DETECTED BY** new shim counters after the fact
  (`llm_upstream_short_circuit_total 312` vs `llm_upstream_fallback_total 24`).

## FACT
- A client-side circuit breaker was added to the shim: after an upstream emergency
  fallback, refuse to try for 45 seconds.
- Hermes retries a 5xx immediately. Each retry re-tripped the breaker, so 24 real
  upstream fallbacks turned into hundreds of self-generated failures.
- **OBSERVATION** The breaker's premise ("stop hammering a bad pool") was right; the
  placement was wrong. Fast-failing a client that immediately retries is an
  amplifier, not a damper.

## LESSON
Reliability features must be measured, not assumed. A guard that converts a slow
failure into a fast failure multiplies load whenever the caller has its own retry
loop. The counter that caught it was added for a different reason, twenty minutes
earlier.

## FIX
Breaker removed in 1.3.3. The shim now asks once — the balancer already walks its
whole provider list before falling back, so a second attempt at the shim is pure
amplification — and reports the fallback as a 503 instead of passing boilerplate
through as an answer.

## FOLLOW-UP
Do not re-add a breaker here without evidence. If pool protection is needed, it
belongs in the balancer, which is the layer that knows what a provider cooldown is.
