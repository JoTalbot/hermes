#!/usr/bin/env bash
# scripts/install-agents.sh — turn config/agents/*.yaml into real Hermes profiles.
#
# Idempotent: `hermes profile create` runs only for slugs that don't exist yet;
# the description is re-synced every run because that is what the kanban
# orchestrator routes on.
#
# FIXED 2026-09-15: the original version called `hermes profile create <slug> --yes`.
# Hermes 0.19.0 has NO `--yes` flag on this subcommand, so every single profile
# creation died with argparse "unrecognized arguments: --yes" and the script
# reported it as "name rejected?" — a wrong diagnosis that would have sent the
# next reader hunting for a name-validation rule that does not exist. The real
# signature is: `profile create <name> [--description D] [--clone] ...`.
set -uo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HBIN="${HERMES_BIN:-$(command -v hermes || echo /home/hermes/.hermes-venv/bin/hermes)}"
[[ -x "$HBIN" ]] || { echo "hermes binary not found at $HBIN — run scripts/install.sh first"; exit 1; }
export HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"

_desc_of() {
  python3 - "$1" <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    print(""); raise SystemExit
print(" ".join(str(d.get("profile", {}).get("description", "")).split())[:300])
PY
}

# --- collision guard (§: a slug must map to exactly ONE profile) -------------
# Real bug found 2026-09-15: config/agents/orchestrator.yaml (the control agent)
# and config/agents/projects/orchestrator.yaml (the project agent for the
# JoTalbot/orchestrator repo) both resolve to slug "orchestrator". The projects
# file is iterated last, so the PROJECT agent silently overwrote the control
# agent's description — the Orchestrator, which every other agent depends on,
# was shadowed by a leaf. Detect and refuse.
shopt -s nullglob
declare -A _seen=()
_collisions=0
for f in "$REPO_DIR"/config/agents/*.yaml "$REPO_DIR"/config/agents/projects/*.yaml; do
  s="$(basename "$f" .yaml)"
  if [[ -n "${_seen[$s]:-}" ]]; then
    echo "  ! SLUG COLLISION: '$s' from both ${_seen[$s]} and $f" >&2
    echo "    rename one file (project agents should be unique slugs)." >&2
    _collisions=$((_collisions+1))
  fi
  _seen[$s]="$f"
done
(( _collisions == 0 )) || { echo "install-agents: aborting, $ _collisions slug collision(s) must be fixed first" >&2; exit 1; }

existing="$("$HBIN" profile list 2>/dev/null || true)"
created=0; updated=0; failed=0

shopt -s nullglob
for f in "$REPO_DIR"/config/agents/*.yaml "$REPO_DIR"/config/agents/projects/*.yaml; do
  slug="$(basename "$f" .yaml)"
  desc="$(_desc_of "$f")"

  if printf '%s' "$existing" | grep -qw -- "$slug"; then
    echo "  = profile $slug exists"
  else
    if out="$("$HBIN" profile create "$slug" ${desc:+--description "$desc"} 2>&1)"; then
      echo "  + profile $slug"
      created=$((created+1))
    else
      echo "  ! FAILED to create $slug:"
      # Surface the REAL reason. Two known, very different causes:
      #  - "reserved": Hermes refuses names that collide with its own install or
      #    a common binary (we hit this with a project agent for the repo called
      #    "hermes"). Rename the file; this is not a bug in this script.
      #  - "unrecognized arguments": an upstream CLI flag changed. That IS a bug.
      if printf '%s' "$out" | grep -qi "reserved"; then
        echo "      → RESERVED NAME. Rename config/agents[/projects]/$slug.yaml to"
        echo "        something else (e.g. ${slug}-os) — Hermes will not shadow its own binary."
      elif printf '%s' "$out" | grep -qi "unrecognized arguments"; then
        echo "      → CLI FLAG MISMATCH: this script is calling a flag this Hermes"
        echo "        version does not have. Check \`$HBIN profile create --help\`."
      fi
      printf '%s\n' "$out" | sed 's/^/      /' | head -4
      failed=$((failed+1))
      continue
    fi
  fi
  # Keep the description authoritative from the YAML (kanban routing depends on it).
  if [[ -n "$desc" ]]; then
    "$HBIN" profile describe "$slug" --text "$desc" >/dev/null 2>&1 && updated=$((updated+1)) || true
  fi
done

echo "install-agents: $created created, $updated descriptions synced, $failed failed"
echo "verify:  $HBIN profile list"
