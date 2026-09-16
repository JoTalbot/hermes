#!/usr/bin/env bash
# scripts/restore.sh — rebuild Hermes on a naked box from this repo + one archive.
# Refuses to overwrite a non-empty HERMES_HOME unless --force. Prints a plan first.
set -euo pipefail
ARCHIVE="${1:?usage: restore.sh <hermes-state-*.tar.gz> [--force] [--no-systemd]}"
FORCE=""
MODE=host
for a in "${@:2}"; do
  [[ "$a" == "--force" ]] && FORCE="--force"
  [[ "$a" == "--no-systemd" ]] && MODE=node
done
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
echo "--- 2/4 runtime state ---"
# The archive stores paths with the leading "/" stripped by tar ("home/hermes/.hermes/..."),
# so extracting into dirname($HERMES_HOME) only worked when HERMES_HOME was the very path
# the backup came from. On any other host it silently produced nothing and the script said
# "extracted" — a restore that restores nothing while reporting success.
# Extract to a scratch dir, find the real state directory by its content, then move it.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
tar -xzf "$ARCHIVE" -C "$SCRATCH"
WANT="$(basename "$HERMES_HOME")"
CANDIDATE=""
while IFS= read -r d; do
  for marker in profiles kanban skills memories config.yaml; do
    if [[ -e "$d/$marker" ]]; then CANDIDATE="$d"; break 2; fi
  done
done < <(find "$SCRATCH" -type d -name "$WANT" 2>/dev/null; find "$SCRATCH" -mindepth 1 -maxdepth 3 -type d 2>/dev/null)
if [[ -z "$CANDIDATE" ]]; then
  echo "  FAILED: could not find a '$WANT'-shaped state directory inside the archive."
  echo "  Archive top-level entries:"; tar -tzf "$ARCHIVE" | head -5 | sed 's/^/    /'
  exit 1
fi
echo "  found state dir inside archive: ${CANDIDATE#$SCRATCH/}"
mkdir -p "$HERMES_HOME"
cp -a "$CANDIDATE"/. "$HERMES_HOME"/
echo "  restored $(find "$HERMES_HOME" -type f 2>/dev/null | wc -l) files into $HERMES_HOME"
if [[ "$MODE" == "node" ]]; then
  echo "--- 3/4 install (node mode: no systemd, no /home/hermes layout) ---"
  bash "$REPO_DIR/scripts/install-bus.sh" --no-systemd
  bash "$REPO_DIR/scripts/install-agent-runtime.sh" --no-systemd
else
  echo "--- 3/4 install (idempotent) ---"; bash "$REPO_DIR/scripts/install.sh"
fi
echo "--- 4/4 verify: what actually came back ---"
RESTORED=0
for probe in profiles skills kanban memories config.yaml; do
  if [[ -e "$HERMES_HOME/$probe" ]]; then
    n="$(find "$HERMES_HOME/$probe" -maxdepth 1 2>/dev/null | wc -l)"
    echo "  present: $probe ($n entries)"; RESTORED=$((RESTORED+1))
  else
    echo "  MISSING: $probe"
  fi
done
[[ "$RESTORED" -ge 4 ]] && echo "  restore: PLAUSIBLE" || { echo "  restore: INCOMPLETE — investigate before trusting this node"; exit 1; }
if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
  bash "$REPO_DIR/scripts/doctor.sh"
else
  echo "  (no systemd here: doctor's host gates do not apply; bus/agent gates were run above)"
fi
