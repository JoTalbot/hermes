#!/usr/bin/env bash
# Monitoring stack: are the scrapers up, are the exporters answering, is the bus flowing?
set -uo pipefail
echo "PROMETHEUS"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/-/healthy)
echo "  /-/healthy -> $code"
curl -s -m 5 'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print("  targets: unreadable:", e); raise SystemExit
rows=d.get("data",{}).get("activeTargets",[])
print(f"  active targets: {len(rows)}")
for t in rows:
    h=t.get("health"); print(f"    {t.get(\"labels\",{}).get(\"job\"):<24} {t.get(\"scrapeUrl\"):<40} {h}")
' 2>/dev/null
echo
echo "ALERT RULES"
curl -s -m 5 http://127.0.0.1:9090/api/v1/rules 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); n=0
for g in d.get("data",{}).get("groups",[]):
    n+=len(g.get("rules",[]))
print(f"  loaded rules: {n}")
' 2>/dev/null || echo "  rules: unreadable"
echo
echo "GRAFANA"
echo "  /api/health -> $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/health)"
echo
echo "EXPORTERS"
for p in 9100 9400 9700 9718 9725; do
  printf "  :%s/metrics -> %s\n" "$p" "$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/metrics")"
done
echo
echo "AGENT BUS"
curl -s -m 5 http://127.0.0.1:8222/varz 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  nats up:", d.get("uptime"), "conns:", d.get("connections"), "msgs_in:", d.get("in_msgs"))' 2>/dev/null || echo "  nats: unreachable"
NATS_TOKEN="$(sed -n 's/^NATS_TOKEN=//p' /etc/hermes/nats.env 2>/dev/null)"
if [ -n "${NATS_TOKEN:-}" ]; then
  NATS_TOKEN="$NATS_TOKEN" hermes-bus-bridge status 2>/dev/null | grep -E "stream|consumer" | sed 's/^/  /'
fi
echo
echo "TELEGRAM BRIDGE"
hermes-bus-bridge status 2>/dev/null | grep telegram | sed 's/^/  /'
