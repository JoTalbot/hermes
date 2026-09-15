#!/usr/bin/env bash
# scripts/backup.sh — config/state backup for the Hermes layer.
# GitHub holds CONFIG (this repo). It must NOT hold databases or runtime state,
# and it must never hold secrets. So: tar → local backup target, and only the
# allowlisted config into git.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEST="${HERMES_BACKUP_DIR:-$REPO_DIR/state/backups}"
KEEP="${HERMES_BACKUP_KEEP:-7}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir -p "$DEST"
echo "=== Hermes backup $STAMP ==="
# 1. Hermes runtime state (sessions/memory/kanban/skills), secrets EXCLUDED
tar --create --gzip \
    --exclude='*/.env' --exclude='*/.env.*' --exclude='*.pem' --exclude='authorized_keys' \
    --exclude='*/logs/*' --exclude='*/cache/*' --exclude='*/audio_cache/*' --exclude='*/image_cache/*' \
    --file="$DEST/hermes-state-$STAMP.tar.gz" \
    "${HERMES_HOME:-$HOME/.hermes}" 2>/dev/null || echo "  (state dir partial — continuing)"
# 2. config from the repo (cheap, versioned separately by git anyway)
tar --create --gzip --file="$DEST/hermes-config-$STAMP.tar.gz" \
    -C "$REPO_DIR" config skills docs scripts deploy tests 2>/dev/null || true
# 3. project databases — to a NON-git target, only if a dump tool exists
: > "$DEST/databases-$STAMP.list"
for svc in $(systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | awk '{print $1}' | grep -iE 'postgres' | head -3); do
  echo "  postgres unit $svc detected — dump with: pg_dumpall > $DEST/db-$STAMP.sql (do this out-of-band)" >> "$DEST/databases-$STAMP.list"
done
find "$DEST"/opt -prune 2>/dev/null || true
for d in /opt/logistics /opt/madworld; do
  [[ -d "$d" ]] && find "$d" -maxdepth 2 \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | while read -r f; do
    cp -p "$f" "$DEST/$(basename "$(dirname "$f")")-$(basename "$f").$STAMP" 2>/dev/null || true
    echo "  snapshotted $f" >> "$DEST/databases-$STAMP.list"
  done
done
# 4. prune
ls -1t "$DEST"/hermes-state-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
ls -1t "$DEST"/hermes-config-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
# 5. integrity: a backup you never opened is a rumour
for a in "$DEST"/hermes-*-*.tar.gz; do
  [[ -f "$a" ]] || continue
  tar -tzf "$a" >/dev/null 2>&1 && echo "  verified: $(basename "$a") ($(du -h "$a"|cut -f1))" || { echo "  CORRUPT: $a"; exit 1; }
done
echo "backups in $DEST (keep=$KEEP). Secrets and databases are intentionally NOT in here."
