#!/usr/bin/env bash
# scripts/apply-agent-soul.sh — install the shared operating contract as SOUL.md
# for the machine default profile AND every agent profile.
#
# WHY each profile's own SOUL.md and not the managed scope: `profile create`
# copies the then-current SOUL.md into the new profile, so without this step the
# 27 agents drift — new ones get whatever was current on their creation day, and
# the mandate to stay autonomous (never stall a dispatched kanban task on a
# clarifying question) reaches only some of them. Observed 2026-09-15: a
# dispatched task burned 120s on a `clarify` call that could never be answered.
#
# Idempotent: rewrites only when the content differs. Safe to re-run after
# adding a profile.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${SOUL_SRC:-$REPO_DIR/config/SOUL.agent.md}"
HH="${HERMES_HOME:-/home/hermes/.hermes}"

[[ -s "$SRC" ]] || { echo "FATAL: no shared SOUL at $SRC" >&2; exit 1; }

changed=0; same=0

_apply() {
  local target="$1"
  if [[ -f "$target" ]] && cmp -s "$SRC" "$target"; then
    same=$((same+1)); return 0
  fi
  install -m 0600 "$SRC" "$target"
  changed=$((changed+1))
  echo "  ~ $target"
}

# machine default (used by ad-hoc runs and as the template for new profiles)
_apply "$HH/SOUL.md"

# every existing profile
shopt -s nullglob
for d in "$HH"/profiles/*/; do
  [[ -d "$d" ]] || continue
  _apply "${d%/}/SOUL.md"
done

chown -R hermes:hermes "$HH" 2>/dev/null || true

echo "apply-agent-soul: $changed updated, $same already current"
echo "New profiles inherit this automatically (profile create copies SOUL.md)."
