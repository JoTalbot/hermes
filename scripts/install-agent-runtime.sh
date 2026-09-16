#!/usr/bin/env bash
# install-agent-runtime.sh — put every agent on the bus. Idempotent.
#
#   1. wire the agent configs (agent_id / capabilities / handlers)
#   2. install the runtime daemon
#   3. prove it works: local handler run, then a real request over the bus
#
#   sudo bash /opt/hermes/scripts/install-agent-runtime.sh
set -euo pipefail
# A node's role (agent scope, local agent subset) lives in a file so that every
# install/restart path agrees on it — not only the shell that first set it up.
[[ -f /etc/hermes/node.env ]] && . /etc/hermes/node.env
# `install` refuses to copy a file onto itself, and that is the NORMAL case when the repo
# lives at the install target (/opt/hermes). Every self-copy goes through this helper.
place() { local src="$1" dst="$2" mode="${3:-0644}"
  if [[ "$(readlink -f "$src")" == "$(readlink -f "$dst" 2>/dev/null || echo -)" ]]; then
    return 0
  fi
  install -m "$mode" "$src" "$dst"
}

REPO_DIR="${REPO_DIR:-/opt/hermes}"
VENV=/opt/hermes/.venv-bus
export PYTHONPATH="$REPO_DIR"

echo "=== 1. wire agent configs ==="
bash "$REPO_DIR/scripts/wire-agents.sh"

echo "=== 2. runtime install ==="
[[ -x $VENV/bin/python ]] || { echo "no bus venv — run scripts/install-bus.sh first"; exit 1; }
# PyYAML is required, not optional: the reduced fallback parser cannot read list values
# like `capabilities`, and capability routing silently degrades without them.
"$VENV/bin/pip" install --quiet --disable-pip-version-check PyYAML 2>&1 | tail -1 || true
"$VENV/bin/python" -c "import yaml; print('  PyYAML', yaml.__version__)"
install -d -m 0755 /var/lib/hermes-agents /var/lib/hermes-agents/logs
NOSYSTEMD="${NOSYSTEMD:-0}"
[[ "${1:-}" == "--no-systemd" ]] && NOSYSTEMD=1
if [[ "$NOSYSTEMD" == "1" ]]; then
  install -d -m 0755 "$REPO_DIR/deploy/nosystemd"
  place "$REPO_DIR/deploy/nosystemd/ctl.sh" "$REPO_DIR/deploy/nosystemd/ctl.sh" 0755
  bash "$REPO_DIR/deploy/nosystemd/ctl.sh" restart agents
else
  place "$REPO_DIR/deploy/systemd/hermes-agents.service" /etc/systemd/system/hermes-agents.service 0644
  systemctl daemon-reload
  systemctl enable hermes-agents >/dev/null 2>&1
  systemctl restart hermes-agents
  sleep 4
  echo "  active: $(systemctl is-active hermes-agents)"
  journalctl -u hermes-agents --since -1min --no-pager -o cat | tail -4 | sed 's/^/  /'
fi

echo "=== 3. registry ==="
"$VENV/bin/python" "$REPO_DIR/agents/runtime.py" list | head -12

echo "=== 4. selftest: local handler, then over the bus ==="
"$VENV/bin/python" "$REPO_DIR/agents/runtime.py" invoke server-guardian identity | head -6 | sed 's/^/  /'
FIRST_AGENT="$(HERMES_LOCAL_AGENTS="${HERMES_LOCAL_AGENTS:-all}" REPO_DIR="$REPO_DIR" "$VENV/bin/python" -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO_DIR"], "agents"))
import runtime
ids = sorted(runtime.load_agents())
print(ids[0] if ids else "")' 2>/dev/null)"
echo "  --- bus request: hermes-bus request --to $FIRST_AGENT 'ping' ---"
if hermes-bus request --to "${FIRST_AGENT:-server-guardian}" --timeout 90 "ping" 2>&1 | head -8 | sed 's/^/  /'; then
  echo "  bus → agent → bus: OK"
else
  echo "  bus → agent round trip FAILED (see journalctl -u hermes-agents)"
fi
echo
echo "install-agent-runtime.sh done."
