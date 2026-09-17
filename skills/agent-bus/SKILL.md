---
name: agent-bus
description: Send, read and route messages between agents and nodes on the Hermes Agent Bus (NATS JetStream + local kanban mirror). Use when an agent must talk to another agent, ask another node something, broadcast a decision, or read the shared chat history.
capability: Читать, отправлять и маршрутизировать сообщения агентов и узлов через Agent Bus (NATS JetStream + канбан-зеркало) командой hermes-bus.
bounds: Не публикует в subjects напрямую и не хранит токен шины в коде или в скилле; без живой шины кросс-узловая доставка не работает — доступен только локальный канбан.
---

# Agent Bus

The bus has TWO layers on purpose. Use the CLI; never publish to subjects by hand.

| Layer | What it gives | Where it lives |
|---|---|---|
| Transport | fan-out, DM, request/reply, replay for offline nodes | NATS 2.10 + JetStream stream `AGENT_BUS` (`hermes.>`) |
| Local durability + history | survives a dead bus, readable offline, shown in the UI | kanban board `agents-chat`, one room per channel |

## Commands

```bash
hermes-bus post  --channel security --kind decision --priority high "текст"   # broadcast
hermes-bus dm    --to github-agent --kind task "проверь репозиторий"          # direct
hermes-bus request --to server-guardian --timeout 60 "status"                 # ask, wait, get an answer
hermes-bus reply --correlation <corr> --to <agent> "ответ"                    # answer a request
hermes-bus read  --channel incidents -n 10                                    # history of one channel
hermes-bus digest -n 5                                                        # one screen, all channels (phone view)
hermes-bus inbox  --agent security-agent                                      # what is addressed to me
hermes-bus channels | nodes | digest
```

Kinds: `event decision task result error status request reply`.
Priorities: `low normal high urgent` — the priority rides in the subject, so a subscriber
can filter without parsing bodies.

Channels: `general orchestrator server github security monitoring projects incidents knowledge`.

## Rules

* **Address a role, not a person, unless you mean it.** `--to server-guardian` hits the
  primary node's agent. On a peer node agents are named `<server_id>/<role>`
  (`--to node-arm-02/server-guardian`), because two nodes running one role is not one address.
* **Always carry the correlation id** when you answer something: the orchestrator matches
  results to dispatched tasks by `correlation_id`, and an unmatched result is only an event.
* **Do not narrate.** The chat carries decisions, tasks, results, errors — not internal
  reasoning or token-by-token output. If you have nothing actionable to say, say nothing.
* **A message is not delivered until it is mirrored.** `post` prints both lines:
  `transport:` (NATS) and `mirror:` (local board). `degraded (local mirror only)` means the
  bus is unreachable but the message is not lost — it stays in the local history.
* **Files and long output go as `--ref`**, not inline: `--ref /var/lib/hermes-agents/logs/foo.log`.

## Answering as an agent

Agents are attached to the bus by `agents/runtime.py` (systemd `hermes-agents`). An agent
automatically answers:
* `hermes.dm.<agent_id>.>` — direct messages/tasks
* `hermesrpc.rpc.<agent_id>` — synchronous request/reply
* `hermes.chat.<channel>.>` — channel messages that mention `@<agent_id>`

An agent can ONLY run handlers declared in its own YAML — a message names a handler
(`status`, `audit`, `health`, …), never a shell command. To add one: skill `agent-handlers`.

## When the bus is down

Local work continues: the mirror still records, agents still answer local requests, and the
bridge retries with backoff. A node that was offline replays what it missed via its durable
consumer. Verify with `hermes-bus-bridge status` and `sudo bash tests/bus-selftest.sh`.
