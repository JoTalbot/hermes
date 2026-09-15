# Architecture

## The one-line summary

Hermes agents on `arm-server-01` get their models from a **loopback OpenAI-compatibility shim**,
which forwards to the **Octopus AIOS LLM balancer** (11 providers, health-gated, weighted), which
holds every provider key. Agents never hold credentials.

```
                       Android (browser or PWA)
                                │  SSH tunnel today · Tailscale when installed
                                ▼
                    127.0.0.1:9119  hermes serve      ← JSON-RPC/WS, WebUI
                                │
                                ▼
     ┌───────────── Hermes profiles (hermes profile) ─────────────┐
     │ orchestrator  server-guardian  github  security  monitoring │
     │ backup        + one profile per on-disk project (20)        │
     └───────────────┬──────────────────────────┬─────────────────┘
                     │ tasks/results             │ chat/task handoff
                     ▼                           ▼
        127.0.0.1:9700  hermes-aios-shim   hermes kanban (SQLite board)
                     │  POST /v1/chat/completions   ← the agent bus, §16
                     ▼
        127.0.0.1:9600  octopus-aios.service  (FastAPI)
                     │  POST /api/v1/aios/ask {"goal": "..."}
                     ▼
     11 providers across 5 tiers: groq(13 keys) · cerebras(3) · gemini · mistral
     hf-Qwen2.5-72B · ollama local(2) · liza-rpa · autonomous_heuristic_engine
```

## Deliberate decisions

**1. We did not move the existing Hermes install.**
`/home/ubuntu/.hermes` (v0.19.0, pip, `hermes-venv`) was pointed at `127.0.0.1:8000` — the liza mock —
and `telegram-hermes.service` set `HERMES_BIN` into that same venv. Rewiring that install to a real
provider would have re-routed a live Telegram bot mid-audit. So Hermes for the *agent OS* is a
**second, isolated instance** under user `hermes` (`HERMES_HOME=/home/hermes/.hermes`), and the legacy
one is left alone until its owner decides otherwise.

**2. The agent bus is `hermes kanban`, not new code.**
The master task specified a JSON message bus (message/task/result/event/request/knowledge, broadcast,
request-reply). Hermes already ships a durable SQLite board with atomic claims, dependencies, per-task
workspaces, comments, attachments and a dispatch daemon — cross-profile by design. §16's vocabulary maps
onto it (see `docs/COMMUNICATION.md`). Writing a second bus would have produced two systems, one of
which is weaker and unloved.

**3. A shim instead of editing the balancer.**
The plan assumed the balancer was OpenAI-compatible. It is not (§BALANCER.md). Adding
`/v1/chat/completions` to `/opt/octopus-aios-server.py` would mean patching a production unit that 35
systemd services and 20 containers sit on. A 280-line stdlib process bound to loopback is reversible,
testable, and removable without touching anything.

**4. Tier aliases, not model names.**
Agents ask for `hermes-fast` / `hermes-code` / `hermes-reason` / `hermes-long` / `hermes-local`, and the
balancer picks a provider by weight + health. Swapping groq for something else changes nothing in agent
config, and a dead provider is excluded by the balancer rather than by 20 agent configs.

## What "project agent" means here

20 profiles, one per **git repo that actually exists on this filesystem** — not one per GitHub repo.
The distinction is load-bearing: an agent for a repo the server cannot read answers confidently about
code it has never seen. 18 public JoTalbot repos have no checkout here and got no agent; they are listed
in `memory/projects/INVENTORY.yaml` as clone-on-demand candidates.

Each profile carries measured facts (path, branch, uncommitted-file count) rather than assumed ones. At
audit, 143 paths were dirty across those trees. Every profile therefore inherits the rule: an uncommitted
file is someone's work — commit it or leave it, never `reset --hard` / `clean -fd`.

## Known architectural gaps (open, not hidden)

| Gap | Consequence | Status |
|---|---|---|
| Shim flattens chat → one `goal` string | No true multi-turn via the balancer; tool-call round trips are lossy | Accepted for v1. For real multi-turn, point `model.base_url` at a genuinely OpenAI-compatible endpoint |
| No Tailscale on the box | Android control depends on an SSH tunnel to loopback | Needs an auth key — user decision |
| Balancer has no auth on :9600 | Anything on the host can burn 11 providers' quota | Loopback-only today; bind to a VPN interface before adding servers |
| `security` agent has no teeth by design | Findings are proposals; nothing auto-remediates | Intentional |
