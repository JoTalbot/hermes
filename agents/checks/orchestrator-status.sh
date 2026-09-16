#!/usr/bin/env bash
# Orchestrator state: what this node has dispatched, what is still awaited.
set -uo pipefail
echo "PENDING DISPATCHES (/var/lib/hermes-agents/pending.json)"
if [ -s /var/lib/hermes-agents/pending.json ]; then
  python3 - <<'PY'
import json
d = json.load(open("/var/lib/hermes-agents/pending.json"))
if not d:
    print("  (none)")
for corr, rec in d.items():
    print(f"  {corr}  task={rec.get('task')!r} agent={rec.get('agent')} "
          f"handler={rec.get('handler')} at={rec.get('at')}")
PY
else
  echo "  (none)"
fi
echo
echo "AGENTS REGISTERED IN CONFIG"
python3 - <<'PY'
import glob, yaml
rows = []
for f in sorted(glob.glob("/opt/hermes/config/agents/*.yaml")) + sorted(glob.glob("/opt/hermes/config/agents/projects/*.yaml")):
    d = yaml.safe_load(open(f)) or {}
    b = d.get("bus") or {}
    if b.get("agent_id"):
        rows.append((b["agent_id"], ",".join(b.get("capabilities") or [])[:34],
                     ",".join(sorted((b.get("handlers") or {}).keys()))[:40]))
print(f"  total: {len(rows)}")
for r in rows:
    print("  %-34s %-34s %s" % r)
PY
echo
echo "RECENT DISPATCH TRAFFIC (local board, #orchestrator room)"
hermes-bus read --channel orchestrator -n 6 2>/dev/null | tail -8
