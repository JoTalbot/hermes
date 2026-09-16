#!/usr/bin/env bash
# deploy/nosystemd/ctl.sh — start/stop/status for hosts without systemd.
#
# WHY THIS EXISTS: the same bus and agent runtime must run on a container, a rescue shell
# or any host where systemd is not PID 1 — otherwise "add a server" is a special case, and
# special cases are what break during recovery. This is deliberately small: a PID file, a
# log file, and a process-group kill. On a real host the systemd units remain the answer.
#
#   ctl.sh start|stop|restart|status <service>     # services: bus-bridge | agents
set -uo pipefail

service="${2:-}"; action="${1:-status}"

# Node role lives in a file, not in the shell that happened to start the daemon. Without
# this, restarting the peer's agents through `docker exec` silently dropped
# HERMES_AGENT_SCOPE=node, the peer's agents took the PRIMARY's bare names, and two nodes
# started answering to the same address.
if [[ -f /etc/hermes/node.env ]]; then
  # shellcheck disable=SC1091
  . /etc/hermes/node.env
fi
case "$service" in
  bus-bridge) CMD=(/opt/hermes/.venv-bus/bin/python /opt/hermes/bus/bus_bridge.py run --rpc-echo) ;;
  agents)     CMD=(/opt/hermes/.venv-bus/bin/python /opt/hermes/agents/runtime.py run) ;;
  *) echo "usage: $0 start|stop|restart|status bus-bridge|agents"; exit 2 ;;
esac

PIDFILE="/var/run/hermes-${service}.pid"
LOGFILE="/var/log/hermes-${service}.log"

running() { [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  if running; then echo "$service already running (pid $(cat "$PIDFILE"))"; return 0; fi
  : > "$LOGFILE"
  setsid nohup "${CMD[@]}" >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if running; then echo "$service started (pid $(cat "$PIDFILE"), log $LOGFILE)"; else
    echo "$service FAILED to start; last log lines:"; tail -5 "$LOGFILE"; return 1; fi
}

stop() {
  if ! running; then echo "$service not running"; rm -f "$PIDFILE"; return 0; fi
  local pid; pid="$(cat "$PIDFILE")"
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 15); do running || break; sleep 1; done
  if running; then kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    echo "$service force-killed after 15s"; else echo "$service stopped"; fi
  rm -f "$PIDFILE"
}

status() {
  if running; then echo "$service: running (pid $(cat "$PIDFILE"))"; else echo "$service: stopped"; fi
  [[ -f "$LOGFILE" ]] && tail -3 "$LOGFILE" | sed 's/^/  /'
}

case "$action" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "usage: $0 start|stop|restart|status bus-bridge|agents"; exit 2 ;;
esac
