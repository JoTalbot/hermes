#!/usr/bin/env bash
# scripts/init-bus.sh — the agent bus IS `hermes kanban` (docs/COMMUNICATION.md).
# We do not build a bespoke message bus: Hermes already ships a durable, atomic,
# cross-profile SQLite task board with claim/assign/comment/link/attach. Reinventing
# it would give us a second, weaker bus to keep in sync.
set -euo pipefail
HBIN="${HERMES_BIN:-$(command -v hermes || echo /home/hermes/.hermes-venv/bin/hermes)}"
export HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"
BOARD="${HERMES_BOARD:-hermes-os}"
mkdir -p "$HERMES_HOME"
"$HBIN" kanban init
"$HBIN" kanban boards create "$BOARD" 2>/dev/null || true
echo "board '$BOARD' ready at $("$HBIN" kanban boards list 2>/dev/null | head -1 || echo unknown)"
echo
echo "message types → kanban verbs (the §16 vocabulary, mapped not invented):"
echo "  task      → kanban create --assignee <profile>"
echo "  result    → kanban comment + complete"
echo "  event     → kanban comment (no assignee)"
echo "  request   → kanban create --type request"
echo "  reply     → kanban comment --reply-to"
echo "  broadcast → one task per assignee, or notify-subscribe"
echo "  error     → kanban block --reason <err>"
echo "  knowledge → memory write + kanban comment with the memory ref"
