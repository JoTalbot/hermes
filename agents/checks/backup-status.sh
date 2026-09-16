#!/usr/bin/env bash
# Backup freshness + integrity. `ARGS_JSON={"deep":"1"}` triggers a real verify run.
set -uo pipefail
DIR=/var/backups/hermes
echo "BACKUP DIR $DIR"
ls -lht "$DIR" 2>/dev/null | head -6 | sed 's/^/  /'
LATEST=$(ls -t "$DIR"/hermes-state-*.tar.gz 2>/dev/null | head -1)
if [ -z "$LATEST" ]; then echo "  NO BACKUP FOUND"; exit 1; fi
AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
echo "  latest: $(basename "$LATEST")  age=${AGE_H}h  size=$(du -h "$LATEST" | cut -f1)"
SLA=30
if [ "$AGE_H" -le "$SLA" ]; then echo "  freshness: OK (SLA ${SLA}h)"; else echo "  freshness: VIOLATION (SLA ${SLA}h)"; fi
echo
echo "TIMER"
systemctl list-timers hermes-backup.timer --no-legend --plain 2>/dev/null | awk '{print "  next: "$1" "$2"  last: "$3" "$4}' 
echo
echo "INTEGRITY"
if [ -f "$DIR/$(basename "$LATEST").sha256" ] || [ -f "$DIR/last.sha256" ]; then
  sha256sum -c "$DIR/$(basename "$LATEST").sha256" 2>/dev/null | sed 's/^/  /' || \
    (cd "$DIR" && grep "$(basename "$LATEST")" last.sha256 | sha256sum -c - 2>/dev/null | sed 's/^/  /')
else
  echo "  no sidecar checksum; computing archive test"
  tar tzf "$LATEST" >/dev/null 2>&1 && echo "  archive readable, $(tar tzf "$LATEST" 2>/dev/null | wc -l) entries"
fi
if [ "${ARGS_JSON:-}" != "" ] && echo "${ARGS_JSON}" | grep -q '"deep"'; then
  echo
  echo "DEEP VERIFY (restore into a scratch dir)"
  bash /opt/hermes/scripts/verify-backup.sh "$LATEST" 2>&1 | tail -12 | sed 's/^/  /'
fi
echo
echo "DISK HEADROOM"
df -h /var | awk 'NR==2{print "  /var: "$3" used, "$4" free ("$5")"}'
