# Hermes — Multi-Agent OS Control Plane

> Infrastructural source of truth for the Hermes agent ecosystem running on `arm-server-01`
> (Oracle Cloud ARM, `129.213.177.56`). This repo is the reproducible definition of the system:
> agent profiles, skills, policies, bootstrap/restore scripts and documentation.
> **It is not a dump of runtime state, databases, logs or secrets.**

## Status

| Area | State |
|---|---|
| Audit of `arm-server-01` | ✅ done (2026-09-15) |
| Hermes runtime | ✅ product runtime (Hermes Agent v0.19.0) at `/home/hermes/.hermes-venv`, 8 systemd units active |
| LLM Balancer | ✅ `octopus-aios-bridge` on `127.0.0.1:9600` (11 providers); the shim on `:9700` exposes 6 tier aliases |
| Hermes → Balancer rewiring | ✅ done (2026-09-17). The 98 %-disk blocker is gone: 52 % used, 71 GB free (2026-09-22) |
| Tailscale | ✅ installed and up (node `100.109.170.74`, 2026-09-22) |
| GitHub sync | ✅ this repo · wave of 2026-09-19 recorded on 2026-09-22 — see `docs/MILESTONE-2026-09-22-wave-20260919.md` |

## What already exists on the server (do not rebuild this)

The server is not a blank box. Before Hermes touches anything, understand the neighbours:

```
octopus-aios-bridge  :9600   THE LLM BALANCER (11 providers, health: llm_balancer)
octopus-webhook-gw   :9610   inbound event bus / webhooks
octopus-browser      :8095   browser automation API
octopus-child@8300-8305      6 swarm child nodes (Docker, octopus-current:latest)
octopus-rag-search   :9555   semantic search (Prometheus+Grafana in Docker)
liza-mock            :8000   OpenAI-compatible MOCK (gemini-rpa via Playwright RPA)
ollama               :11434  local models (embeddings + small LLMs), socat proxy :11435
logistics control    :8787   agent_name=arm-server-01, model=auto
madworld-api         :8090   behind nginx TLS on api.autosklo.org.ua
35 octopus-*.service systemd units, 20 docker containers, 5 jo-agent-*.service
```

**`telegram-hermes.service`** is a pre-existing Liza Telegram ⇄ Hermes bridge. Hermes is therefore
*already* wired to Telegram. Reconfiguring Hermes' provider will move that bridge with it — treat
`liza-mock` and `telegram-hermes` as coupled, not as junk to be replaced.

## Layout

```
hermes/
├── README.md                 you are here
├── docs/                     ARCHITECTURE, BALANCER, SECURITY, RUNBOOK, DISASTER_RECOVERY,
│                             MULTI_SERVER, OBSERVABILITY, MEMORY, AGENT_MODEL, SKILLS,
│                             SKILLS-TODO, AGENT-IMPROVEMENTS, FINAL-REPORT-*, MILESTONE-*
├── config/                   agents/, models/, policies/, servers/  (source of truth, no secrets)
├── skills/                   skill source + REGISTRY.md
├── memory/                   decisions/, architecture/, lessons/ (FACT/OBSERVATION/HYPOTHESIS tagged)
├── scripts/                  doctor.sh, install.sh, bootstrap.sh, backup.sh, restore.sh, register-server.sh
├── deploy/                   systemd units, compose overlays
├── state/                    gitignored runtime state lives on the server, only a manifest here
└── tests/                    contract tests for scripts + hermes↔balancer integration probe
```

## Golden rules

1. **No secrets in git, ever.** `.env` files stay on the server with `0600`; only `.env.example` is committed.
   `scripts/secret-scan.sh` refuses to let a token in, and the contract suite runs it over the worktree
   (there is no CI runner in this repo — the suite *is* the gate).
2. **Idempotency.** `bootstrap.sh` must be safe to run on a healthy server and on a naked one.
3. **GitHub is source of truth for config, not for data.** Databases and runtime state need their own backup target.
4. **Selective context.** An agent gets global + own + project context, never the whole box.
5. **Never break a running service to make an install easier.** If they conflict, the install changes.
