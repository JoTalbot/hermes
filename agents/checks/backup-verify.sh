#!/usr/bin/env bash
# Deep backup verification: restore the newest archive into a scratch dir and compare.
set -uo pipefail
DIR=/var/backups/hermes
LATEST=$(ls -t "$DIR"/hermes-state-*.tar.gz 2>/dev/null | head -1)
[ -n "$LATEST" ] || { echo "no archive in $DIR"; exit 1; }
echo "verifying $(basename "$LATEST") ($(du -h "$LATEST" | cut -f1))"
bash /opt/hermes/scripts/verify-backup.sh "$LATEST" 2>&1 | tail -20
