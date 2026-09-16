#!/usr/bin/env bash
# Host health report for the Server Guardian agent. Read-only.
set -uo pipefail
SID=$(python3 -c 'import yaml;print((yaml.safe_load(open("/opt/hermes/config/servers/arm-server-01.yaml")) or {}).get("server",{}).get("id","?"))' 2>/dev/null || echo '?')
echo "HOST $(hostname)  $(date -u +%FT%TZ)  node=$SID"
echo "UPTIME $(uptime -p 2>/dev/null)  load=$(cut -d' ' -f1-3 /proc/loadavg)  cores=$(nproc)"
free -m | awk '/Mem:/{printf "MEM used=%dMi total=%dMi avail=%dMi\n", $3,$2,$7}'
df -h / /var /home 2>/dev/null | awk 'NR>1{printf "DISK %-6s %s used of %s (%s)\n", $6,$3,$2,$5}'
echo "SWAP $(free -m | awk '/Swap:/{print $3"Mi used of "$2"Mi"}')"
INODES=$(df -i / | awk 'NR==2{print $5}')
echo "INODES / used=$INODES"
echo
echo "FAILED UNITS"
systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print "  "$1}' | head -20
[ -z "$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null)" ] && echo "  (none)"
echo
echo "HERMES STACK"
for u in hermes-env-guard hermes-shim hermes-serve hermes-gateway hermes-metrics hermes-backup.timer nats-server hermes-bus-bridge hermes-agents; do
  printf "  %-22s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null)"
done
echo
echo "DOCKER"
if command -v docker >/dev/null; then
  docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | sed 's/^/  /'
  UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  echo "  unhealthy: ${UNHEALTHY:-none}"
fi
echo
echo "TOP MEMORY"
ps -eo rss,comm --sort=-rss 2>/dev/null | head -6 | awk 'NR>1{printf "  %6d Mi  %s\n", $1/1024, $2}'
echo
echo "RECENT CRITICAL JOURNAL (last 30 min)"
journalctl -p err --since -30min --no-pager -o short 2>/dev/null | tail -8 | sed 's/^/  /' || echo "  (none)"
