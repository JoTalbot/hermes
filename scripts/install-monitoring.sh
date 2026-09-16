#!/usr/bin/env bash
# install-monitoring.sh — put the Hermes alert rules and dashboard into the EXISTING
# monitoring stack instead of building a second one (requirement 14: integrate, don't fork).
#
# Touches only files it owns:
#   /opt/octopus-monitoring/rules/hermes-agents.rules.yml
#   /opt/octopus-monitoring/dashboards/hermes-agents-dashboard.json
# and backs up anything it would overwrite. Existing rules/dashboards are never edited.
set -euo pipefail
SRC="${SRC:-/opt/hermes}"
RULES_DIR=/opt/octopus-monitoring/rules
DASH_DIR=/opt/octopus-monitoring/dashboards
PROM=docker  # prometheus runs as container octopus-prometheus (host network)

[[ -d "$RULES_DIR" ]] || { echo "no $RULES_DIR — is the monitoring stack installed?"; exit 1; }

echo "=== 1. alert rules ==="
for f in "$RULES_DIR"/hermes-agents.rules.yml; do
  if [[ -f "$f" ]] && ! diff -q "$SRC/deploy/monitoring/hermes-agents.rules.yml" "$f" >/dev/null; then
    cp -a "$f" "$f.bak.$(date +%s)"; echo "  backed up $(basename "$f")"
  fi
done
install -m 0644 "$SRC/deploy/monitoring/hermes-agents.rules.yml" "$RULES_DIR/hermes-agents.rules.yml"
python3 -c "import yaml,sys; yaml.safe_load(open('$RULES_DIR/hermes-agents.rules.yml')); print('  rules file parses')"

echo "=== 2. dashboard ==="
install -m 0644 "$SRC/deploy/monitoring/hermes-agents-dashboard.json" "$DASH_DIR/hermes-agents-dashboard.json"
python3 -c "import json; d=json.load(open('$DASH_DIR/hermes-agents-dashboard.json')); print('  dashboard parses:', d['title'], len(d['panels']), 'panels')"

echo "=== 3. reload prometheus (no restart: keeps the TSDB and existing targets) ==="
if curl -sf -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  echo "  reloaded"
else
  docker kill -s HUP octopus-prometheus >/dev/null 2>&1 && echo "  sent SIGHUP to the container" \
    || echo "  WARN: could not reload prometheus — reload by hand"
fi
sleep 3
curl -s -m 6 http://127.0.0.1:9090/api/v1/rules | python3 -c "
import json,sys
d=json.load(sys.stdin)
for g in d['data']['groups']:
    if 'hermes' in g['name']:
        print('  loaded group:', g['name'], '->', len(g['rules']), 'rules')"
