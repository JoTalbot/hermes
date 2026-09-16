# Observability

**Reuse, not replacement.** This box already runs a Prometheus + Grafana stack
(`octopus-monitoring`, host network, `:9090` / `:3000`) with a node exporter and an
Octopus control-plane target. The Hermes layer **appends** two scrape jobs to the
existing `prometheus.yml` and changes no existing target. Nothing was re-installed,
no second monitoring stack was started, and the Grafana admin password comes from the
existing `GRAFANA_ADMIN_PASS`.

```
prometheus.yml (octopus-monitoring)
├── octopus_control_plane  127.0.0.1:9100   (pre-existing)
├── octopus_node_exporter  127.0.0.1:9718   (pre-existing)
├── hermes_os_shim         127.0.0.1:9700/metrics   (added)
└── hermes_os_exporter     127.0.0.1:9725/metrics   (added)
```

Reload without downtime: `docker kill --signal=HUP octopus-prometheus`.

## What each target answers

| question | metric | target |
|---|---|---|
| are the four Hermes units up? | `hermes_unit_active{unit=...}` | exporter |
| is the loopback shim alive, which build? | `hermes_shim_up`, `hermes_shim_info{version}` | shim |
| how much is flowing through it? | `llm_requests_total`, `llm_errors_total` | shim |
| how many tool calls does it emit? | `llm_tool_calls_emitted_total` | shim |
| is the model silently returning nothing? | `llm_empty_reply_retries_total` | shim |
| is the tool list being degraded to fit? | `llm_tool_block_degraded_total` | shim |
| is the provider pool shedding? | `llm_upstream_fallback_total` | shim |
| is the LLM chain working right now? | `hermes_llm_balancer_up`, `hermes_llm_provider_healthy` | exporter |
| how many agents exist? | `hermes_agent_profiles` | exporter |
| is the managed-scope invariant intact? | `hermes_managed_dir_ok` | exporter |
| is the secret file present? | `hermes_secret_env_present` | exporter |
| what is on the agent bus? | `hermes_kanban_tasks{board,status}` | exporter |
| is the config committed and pushed? | `hermes_repo_dirty`, `hermes_repo_unpushed` | exporter |
| is the box on the tailnet? | `hermes_tailscale_up` | exporter |

`hermes_managed_dir_ok == 0` is the single most useful alert here: a `/etc/hermes`
that is not `0755` breaks **every** `hermes` command, and this metric notices in
15 seconds instead of at the next human login.

## Suggested alert rules

| alert | expression | why |
|---|---|---|
| agent OS cannot think | `hermes_shim_up == 0 or hermes_llm_balancer_up == 0` | every agent call fails |
| tasks are stalling | `increase(hermes_kanban_tasks{status="running"}[10m]) > 0 and increase(llm_requests_total[10m]) == 0` | a worker is up but producing nothing |
| the model went silent | `increase(llm_empty_reply_retries_total[15m]) > 5` | provider or prompt regression |
| provider pool shedding | `increase(llm_upstream_fallback_total[15m]) > 5` | all providers failing; agents get 503 |
| config drifting | `hermes_repo_dirty > 0` for 1h | reproducible-config guarantee is broken |
| invariant broken | `hermes_managed_dir_ok == 0` | Hermes CLI is about to fail everywhere |

## The exporter itself

`scripts/hermes_metrics_exporter.py` — stdlib-only, read-only, unprivileged
(`User=hermes`), loopback (`:9725`), `ProtectSystem=strict`, `ProtectHome=read-only`.
Each probe is isolated: a failing probe emits a comment, never an exception, so the
endpoint always answers. 10-second cache, so scraping every 15s costs almost nothing.

It deliberately **does not** re-export CPU/RAM/disk — `octopus_node_exporter` already
does, and duplicating it would create two answers to one question.

## Health on demand (no Prometheus needed)

```bash
/opt/hermes/scripts/report-balancer-health.sh      # 0 healthy / 1 degraded / 2 down
curl -s http://127.0.0.1:9700/selfcheck            # end-to-end LLM round trip
sudo /opt/hermes/scripts/doctor.sh                 # whole-node verdict
```

`/selfcheck` exists because agents run as an unprivileged user that deliberately
cannot read `/etc/hermes/shim.env`. It lets an agent answer "can I think right now?"
truthfully without ever holding the credential.

## Incident log

`memory/incidents/` holds one file per real incident, in the same tagged
(FACT/OBSERVATION/HYPOTHESIS/DECISION/LESSON) vocabulary as the knowledge base.
`scripts/seed-memory.sh` folds the machine-wide knowledge base into each profile's
`memories/MEMORY.md`, which is the file Hermes actually reads at the start of a turn.
## Measured 2026-09-16 — the bus, the agents and the peers are observable

Exporter `scripts/hermes_metrics_exporter.py` (job `hermes_os_exporter`, :9725) gained:
`hermes_bus_up`, `hermes_bus_connections`, `hermes_bus_stream_messages`,
`hermes_bus_stream_bytes`, `hermes_bus_consumer_ack_pending`, `hermes_agents_defined`,
`hermes_agents_handlers_total`, `hermes_agents_runtime_up`,
`hermes_agents_dispatched_pending`, `hermes_nodes_known`,
`hermes_node_messages_total{node}`, `hermes_projects_wired`,
`hermes_project_path_present{project}`, `hermes_project_dirty{project}`.

`deploy/monitoring/hermes-agents.rules.yml` (8 alerts, loaded by the existing Prometheus):
bus down, agents runtime down, consumer backlog >50/10m, dispatch stuck >5/30m, project tree
missing, dirty burst, unpushed config, node silent 24h.
`deploy/monitoring/hermes-agents-dashboard.json` — Grafana dashboard "Hermes Agent Bus &
Agents" (12 panels). Install/refresh: `bash scripts/install-monitoring.sh` (backs up what it
replaces, SIGHUP-reloads Prometheus, never edits existing rules or dashboards).

Doctor gates 14-17 close the loop: transport, agents (including a real request to a live
agent), federation freshness, and gateway-unit integrity.
