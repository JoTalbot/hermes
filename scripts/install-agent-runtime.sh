#!/usr/bin/env bash
# install-agent-runtime.sh — put every agent on the bus. Idempotent.
#
#   1. wire the agent configs (agent_id / capabilities / handlers)
#   2. install the runtime daemon
#   3. prove it works: local handler run, then a real request over the bus
#
#   sudo bash /opt/hermes/scripts/install-agent-runtime.sh
set -euo pipefail
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
install -m 0644 "$REPO_DIR/deploy/systemd/hermes-agents.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable hermes-agents >/dev/null 2>&1
systemctl restart hermes-agents
sleep 4
echo "  active: $(systemctl is-active hermes-agents)"
journalctl -u hermes-agents --since -1min --no-pager -o cat | tail -4 | sed 's/^/  /'

echo "=== 3. registry ==="
"$VENV/bin/python" "$REPO_DIR/agents/runtime.py" list | head -12

echo "=== 4. selftest: local handler, then over the bus ==="
"$VENV/bin/python" "$REPO_DIR/agents/runtime.py" invoke server-guardian identity | head -6 | sed 's/^/  /'
echo "  --- bus request: hermes-bus request --to server-guardian 'status' ---"
if hermes-bus request --to server-guardian --timeout 90 "status" 2>&1 | head -8 | sed 's/^/  /'; then
  echo "  bus → agent → bus: OK"
else
  echo "  bus → agent round trip FAILED (see journalctl -u hermes-agents)"
fi
echo
echo "install-agent-runtime.sh done."
