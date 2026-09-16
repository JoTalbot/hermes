#!/usr/bin/env bash
# deploy/node-entrypoint.sh — a BARE machine (container, VM, bare metal) → a Hermes node.
#
# This is the same path a new physical server takes, only with systemd replaced by the
# PID-file supervisor:
#   1. install the minimum base packages     (the box has nothing)
#   2. clone the repo from GitHub            (GitHub is the source of truth, §11)
#   3. install the Hermes runtime + bus      (own HERMES_HOME, own kanban board)
#   4. register the node                     (mints a stable server_id, announces on the bus)
#   5. wire agents + start runtime
#   6. prove it: local health, then a round trip on the bus
#
# Required env:
#   NATS_TOKEN   shared bus secret (the "join token" the operator copies to a new node)
# Optional env:
#   NATS_URL     default nats://<docker-gateway>:4222
#   GITHUB_TOKEN to clone a private repo / push the manifest
#   NODE_ID      human-readable node name (defaults to the container hostname)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
step() { printf '\033[35m[node]\033[0m %s\n' "$*"; }

step "1/6 base packages"
# Check every tool we actually use. A bare ubuntu image HAS python3 but not sudo/venv, and
# a single "is python3 present?" probe skipped the install and blew up three steps later.
need=""
for t in python3 git curl sudo ps; do command -v "$t" >/dev/null || need="$need $t"; done
python3 -c 'import venv' 2>/dev/null || need="$need python3-venv"
if [[ -n "$need" ]]; then
  step "     installing:$need"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates python3 python3-venv \
      python3-pip git curl sudo procps nano >/dev/null
else
  step "     base tools already present"
fi
step "     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-linux}") · $(uname -m)"
echo "$(hostname)" > /etc/hostname.node-original

step "2/6 clone the source of truth"
if [[ ! -d /opt/hermes/.git ]]; then
  URL="https://github.com/JoTalbot/hermes.git"
  [[ -n "${GITHUB_TOKEN:-}" ]] && URL="https://${GITHUB_TOKEN}@github.com/JoTalbot/hermes.git"
  git clone --depth 1 "$URL" /opt/hermes >/dev/null 2>&1
  # Never leave a credential in .git/config on a box that may be handed to someone else.
  git -C /opt/hermes remote set-url origin https://github.com/JoTalbot/hermes.git
fi
git -C /opt/hermes config user.name  "Hermes Node Agent"
git -C /opt/hermes config user.email "node@$(hostname)"
step "     repo at $(git -C /opt/hermes rev-parse --short HEAD) on $(git -C /opt/hermes rev-parse --abbrev-ref HEAD)"

step "3/6 Hermes runtime + bus client"
mkdir -p /etc/hermes && chmod 0755 /etc/hermes
if [[ ! -s /etc/hermes/nats.env ]]; then
  [[ -n "${NATS_TOKEN:-}" ]] || { echo "FATAL: NATS_TOKEN is required to join the bus"; exit 2; }
  umask 077
  printf 'NATS_URL=%s\nNATS_TOKEN=%s\n' "${NATS_URL:-nats://172.17.0.1:4222}" "$NATS_TOKEN" \
    > /etc/hermes/nats.env
  chmod 0600 /etc/hermes/nats.env
fi
# Hermes itself: a real node, with its own HERMES_HOME and its own kanban board, so the
# local durable mirror of the bus exists here too (§4: no node depends on the control plane).
if [[ "${HERMES_FULL:-1}" == "1" && ! -x /home/hermes/.hermes-venv/bin/hermes ]]; then
  if ! id hermes >/dev/null 2>&1; then useradd -m -s /bin/bash hermes; fi
  sudo -u hermes python3 -m venv /home/hermes/.hermes-venv
  sudo -u hermes /home/hermes/.hermes-venv/bin/pip install --quiet --disable-pip-version-check \
      "hermes-agent==0.19.0" 2>&1 | tail -2 || step "     hermes-agent install failed (bus-only node)"
fi
export HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"
if [[ -x /home/hermes/.hermes-venv/bin/hermes ]]; then
  sudo -u hermes env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes kanban init >/dev/null 2>&1 || true
  sudo -u hermes env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes kanban boards create agents-chat >/dev/null 2>&1 || true
  step "     hermes runtime: $(sudo -u hermes env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes --version 2>/dev/null | head -1)"
fi
bash /opt/hermes/scripts/install-bus.sh --no-systemd 2>&1 | tail -6

step "4/6 register this node"
bash /opt/hermes/scripts/register-server.sh 2>&1 | tail -3

step "5/6 wire + start agents"
# This node serves the core specialists: it has no project checkouts, and running agents
# for paths that do not exist would flood the chat with "path missing".
export HERMES_LOCAL_AGENTS="${HERMES_LOCAL_AGENTS:-core}"
# This node is a peer, not the primary: its agents get node-scoped bus ids
# (<server_id>/<agent>) so the same role can exist on many nodes without colliding.
export HERMES_AGENT_SCOPE="${HERMES_AGENT_SCOPE:-node}"
# Persist the role so a restart (systemd or ctl.sh) cannot drop it.
umask 077
printf 'export HERMES_LOCAL_AGENTS=%s\nexport HERMES_AGENT_SCOPE=%s\n' \
  "$HERMES_LOCAL_AGENTS" "$HERMES_AGENT_SCOPE" > /etc/hermes/node.env
chmod 0600 /etc/hermes/node.env
bash /opt/hermes/scripts/install-agent-runtime.sh --no-systemd 2>&1 | tail -8

step "6/6 prove it"
/opt/hermes/.venv-bus/bin/python /opt/hermes/agents/runtime.py list | head -4
export NATS_TOKEN="$(sed -n 's/^NATS_TOKEN=//p' /etc/hermes/nats.env)"
hermes-bus post --channel server --kind status --priority normal \
  "узел $(hostname) поднят: $(/opt/hermes/.venv-bus/bin/python -c 'import json;print(len(json.load(open("/var/lib/hermes-agents/pending.json"))))' 2>/dev/null || echo 0) задач в очереди, агентов $(ls /opt/hermes/config/agents/*.yaml | wc -l)" \
  | head -3
hermes-bus-bridge status | head -6
step "node ready: $(hostname)"
# No `tail -f /dev/null` here on purpose: this script is also executed through
# `docker exec` during a drill, and an entrypoint that never returns looks exactly
# like a hang — which is how one 28-minute timeout was spent.
