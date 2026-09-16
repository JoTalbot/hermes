#!/usr/bin/env bash
# Service and container inventory, with the expectation from config/servers/*.yaml.
set -uo pipefail
echo "SYSTEMD (hermes + project units)"
systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
  | awk '{print $1, $3, $4}' | grep -E "hermes|nats|jo-agent|octopus|logistics|transcribe|ukraine" \
  | while read -r unit load act sub; do printf "  %-34s %s/%s\n" "$unit" "$load" "$act"; done
echo
echo "TIMERS"
systemctl list-timers --all --no-legend --plain 2>/dev/null | awk '{print "  "$1" "$2" "$3" → "$NF}' | head -12
echo
echo "DOCKER CONTAINERS"
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | sed 's/^/  /'
echo
echo "LISTENING (public-facing check)"
ss -lntH 2>/dev/null | awk '{print $4}' | sort -u | sed 's/^/  /'
