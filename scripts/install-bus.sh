#!/usr/bin/env bash
# install-bus.sh — install/refresh the Agent Bus (NATS client, CLI, bridge daemon).
#
# Idempotent by design: re-running refreshes the code and restarts the daemon, but
# never touches the NATS data directory, the token, or the local mirror.
#
#   sudo bash /opt/hermes/scripts/install-bus.sh
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

SRC="${SRC:-/opt/hermes}"
VENV=/opt/hermes/.venv-bus
BUS_DIR=/opt/hermes/bus

echo "=== 1. python environment (nats-py) ==="
if [[ ! -x $VENV/bin/python ]]; then
  python3 -m venv "$VENV"
  echo "  created $VENV"
fi
"$VENV/bin/pip" install --quiet --disable-pip-version-check "nats-py>=2.6" 2>&1 | tail -2 || true
"$VENV/bin/python" -c "import nats; print('  nats-py', nats.__version__ if hasattr(nats,'__version__') else 'ok')"

echo "=== 2. code ==="
install -d -m 0755 "$BUS_DIR"
for f in bus.py bus_bridge.py; do
  # SRC is normally /opt/hermes, i.e. the destination itself — copying a file onto
  # itself makes `install` fail, so skip that case (this is the normal path after a
  # `tar -C /opt/hermes` deploy).
  if [[ "$(readlink -f "$SRC/bus/$f")" == "$(readlink -f "$BUS_DIR/$f" 2>/dev/null || echo -)" ]]; then
    echo "  $f already in place"; continue
  fi
  install -m 0644 "$SRC/bus/$f" "$BUS_DIR/$f"
done
install -d -m 0755 /var/lib/hermes-bus
echo "  installed: $(ls "$BUS_DIR" | tr '\n' ' ')"

echo "=== 3. CLI wrapper ==="
cat > /usr/local/bin/hermes-bus <<WRAP
#!/usr/bin/env bash
# Agent Bus CLI — see /opt/hermes/bus/bus.py for the design notes.
exec $VENV/bin/python $BUS_DIR/bus.py "\$@"
WRAP
chmod 0755 /usr/local/bin/hermes-bus
cat > /usr/local/bin/hermes-bus-bridge <<WRAP
#!/usr/bin/env bash
exec $VENV/bin/python $BUS_DIR/bus_bridge.py "\$@"
WRAP
chmod 0755 /usr/local/bin/hermes-bus-bridge

echo "=== 4. bridge daemon ==="
NOSYSTEMD="${NOSYSTEMD:-0}"
[[ "${1:-}" == "--no-systemd" ]] && NOSYSTEMD=1
if [[ "$NOSYSTEMD" == "1" ]]; then
  # Containers and rescue shells have no PID 1 systemd; the very same daemon runs under
  # a PID-file supervisor so that "add a node" is not a special build.
  install -d -m 0755 /opt/hermes/deploy/nosystemd
  place "$SRC/deploy/nosystemd/ctl.sh" /opt/hermes/deploy/nosystemd/ctl.sh 0755
  bash /opt/hermes/deploy/nosystemd/ctl.sh restart bus-bridge
else
  install -d -m 0755 /etc/systemd/system 2>/dev/null || true
  place "$SRC/deploy/systemd/hermes-bus-bridge.service" /etc/systemd/system/hermes-bus-bridge.service 0644
  systemctl daemon-reload
  systemctl enable hermes-bus-bridge >/dev/null 2>&1
  systemctl restart hermes-bus-bridge
  sleep 4
  echo "  active: $(systemctl is-active hermes-bus-bridge)"
  journalctl -u hermes-bus-bridge --since -1min --no-pager -o cat 2>/dev/null | tail -4 | sed 's/^/  /'
fi

echo "=== 5. selftest: bus reachable + stream + CLI round trip ==="
NATS_TOKEN="$(sed -n 's/^NATS_TOKEN=//p' /etc/hermes/nats.env)"
export NATS_TOKEN
hermes-bus channels | head -4
CHECK="$(uuidgen 2>/dev/null || date +%s%N)"
hermes-bus post --channel knowledge --kind decision --priority normal \
  "bus selftest $CHECK: install-bus.sh completed on $(hostname)" | sed 's/^/  /'
hermes-bus-bridge send "bus selftest $CHECK: install-bus.sh completed on $(hostname)" \
  | sed 's/^/  telegram: /' || true
echo
echo "install-bus.sh done."
