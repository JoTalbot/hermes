#!/usr/bin/env bash
# scripts/restore.sh — rebuild Hermes on a naked box from this repo + one archive.
# Refuses to overwrite a non-empty HERMES_HOME unless --force. Prints a plan first.
set -euo pipefail
ARCHIVE="${1:?usage: restore.sh <hermes-state-*.tar.gz> [--force]}"; FORCE="${2:-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
[[ -f "$ARCHIVE" ]] || { echo "no such archive: $ARCHIVE"; exit 1; }
tar -tzf "$ARCHIVE" >/dev/null 2>&1 || { echo "archive fails integrity check — refusing"; exit 1; }
echo "PLAN"
echo "  1. git-sync config/skills/agents from $REPO_DIR (authoritative)"
echo "  2. restore runtime state into $HERMES_HOME"
echo "  3. re-run install.sh so the venv/units match this repo"
echo "  4. doctor.sh decides whether the node is healthy"
echo "  secrets: NOT in the archive. You must place /etc/hermes/shim.env yourself."
if [[ -d "$HERMES_HOME" && -n "$(ls -A "$HERMES_HOME" 2>/dev/null)" && "$FORCE" != "--force" ]]; then
  echo "REFUSING: $HERMES_HOME is not empty. Re-run with --force (after you've backed it up)."
  exit 1
fi
echo "--- 1/4 repo config ---"; git -C "$REPO_DIR" pull --ff-only 2>/dev/null || echo "  (offline or no upstream — using local tree)"
echo "--- 2/4 runtime state ---"; mkdir -p "$(dirname "$HERMES_HOME")"
tar -xzf "$ARCHIVE" -C "$(dirname "$HERMES_HOME")" && echo "  extracted"
echo "--- 3/4 install (idempotent) ---"; bash "$REPO_DIR/scripts/install.sh"
echo "--- 4/4 verify ---"; bash "$REPO_DIR/scripts/doctor.sh"
