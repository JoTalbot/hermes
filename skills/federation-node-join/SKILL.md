---
name: federation-node-join
description: Add a new server/container as a Hermes node on the Agent Bus (clone → bootstrap → register → wire → verify), and diagnose a node that joined but is not answering. Use for multi-server work, peer nodes, or when a node must be rebuilt from GitHub.
capability: Подключать новый сервер или контейнер к шине (clone → bootstrap → register → wire → verify) и диагностировать «узел присоединился, но не отвечает».
bounds: Не переносит секреты: на новую машину едут только URL репозитория и токен шины; чужие узлы не пересобираются без согласия владельца.
---

# Join a node to the federation

GitHub is the source of truth; a node is disposable. The only things a human must carry to a
new machine are **the repo URL** and **the bus join token** (`NATS_TOKEN`).

## Node (no systemd: container, rescue shell)

```bash
docker run -d --name hermes-node-02 --hostname node-arm-02 ubuntu:24.04 sleep infinity
docker exec -e NATS_TOKEN="$(sed -n 's/^NATS_TOKEN=//p' /etc/hermes/nats.env)" \
            -e NATS_URL="nats://172.17.0.1:4222" hermes-node-02 bash -lc '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends git
  git clone --depth 1 https://github.com/JoTalbot/hermes /opt/hermes
  git config --global --add safe.directory /opt/hermes
  bash /opt/hermes/scripts/bootstrap.sh --no-systemd'
```

`bootstrap.sh --no-systemd` delegates to `deploy/node-entrypoint.sh`, which: installs base
packages → clones → installs Hermes (`hermes-agent`, own `HERMES_HOME` + own kanban board) →
writes `/etc/hermes/nats.env` → registers (`register-server.sh` mints a stable `server_id`
and announces on `#server`) → wires agents → starts bridge + agents under
`deploy/nosystemd/ctl.sh` → proves a round trip.

## Host (systemd)

```bash
git clone https://github.com/JoTalbot/hermes && cd hermes && sudo ./scripts/bootstrap.sh
```
Requires `/etc/hermes/shim.env` (the model credential) to exist by hand — bootstrap never
invents secrets. A host without the local LLM balancer still installs; Hermes then has no
model provider until `model.base_url` is set.

## Rules that were learned the hard way

* **The node's role lives in `/etc/hermes/node.env`** (`HERMES_AGENT_SCOPE=node`,
  `HERMES_LOCAL_AGENTS=core`). The runtime and every install script read it. Without it,
  restarting the peer through a bare `docker exec` made its agents adopt the PRIMARY's bare
  names — two nodes answering one address.
* **Peer agents are node-scoped**: `node-arm-02/server-guardian`. Address a peer explicitly;
  a bare name is the primary's.
* **Firewall**: NATS listens on 0.0.0.0 but ufw allows 4222 only from the tailnet
  (100.64.0.0/10), the local subnet and the docker bridge (`172.17.0.0/16`). A container that
  cannot reach the bus usually means the docker subnet rule is missing.
* **Verify, do not assume**:
  ```bash
  hermes-bus nodes                        # is the peer in nodes.json?
  hermes-bus request --to node-arm-02/server-guardian --timeout 60 ping
  sudo NODE2=hermes-node-02 bash tests/federation-selftest.sh   # 10 checks
  ```
* A container node has no project checkouts, so it runs `HERMES_LOCAL_AGENTS=core`; giving it
  21 project agents would only produce 21 "path missing" reports.
