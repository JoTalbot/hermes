#!/usr/bin/env bash
# Hermes OS itself: version, services, skills, profiles, boards, bus, access surface.
set -uo pipefail
echo "VERSION"
sudo -u hermes -H env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes --version 2>/dev/null | head -2 | sed 's/^/  /'
echo
echo "SKILLS"
OUT=$(mktemp)
sudo -u hermes -H env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes skills list >"$OUT" 2>/dev/null
grep -E "hub-installed|local|enabled" "$OUT" | head -4 | sed 's/^/  /'
grep -cE "^\s+\S+\s+.*(enabled|local)" "$OUT" 2>/dev/null | sed 's/^/  rows: /'
rm -f "$OUT"
echo
echo "PROFILES"
ls /home/hermes/.hermes/profiles 2>/dev/null | wc -l | sed 's/^/  count: /'
echo
echo "KANBAN BOARDS"
sudo -u hermes -H env HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes kanban boards 2>/dev/null | head -8 | sed 's/^/  /'
echo
echo "DASHBOARD (loopback)"
echo "  /api/status -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/api/status)"
echo "  /login      -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/login)"
echo
echo "LLM BALANCER (via shim, no provider keys stored in Hermes)"
echo "  shim   :9700 /health -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9700/health)"
echo "  balancer :9600 /health -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9600/health)"
echo
echo "AGENT BUS"
hermes-bus-bridge status 2>/dev/null | sed 's/^/  /'
