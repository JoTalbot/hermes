#!/usr/bin/env bash
# scripts/agents-chat.sh — the shared chat room for every Hermes profile.
#
# WHY THIS SHAPE: Hermes has no chat server, but it already has all three things a
# shared chat needs, and they are already durable:
#   * a stable address  -> kanban task created with --idempotency-key (same id forever)
#   * authorship        -> kanban comment --author <profile>
#   * readability       -> kanban show --json / tail, plus the WebUI and the dashboard
# A "room" is a task on the dedicated board `agents-chat` whose comments are messages.
#
# SAFETY INVARIANT (verified 2026-09-16, do not break it):
#   The dispatcher only claims tasks where `status='ready' AND assignee IS NOT NULL`
#   (kanban_db.py: dispatch candidate query), and no `kanban.default_assignee` fallback
#   is configured here. A room is therefore created **unassigned**. Verified live: a
#   room stayed `ready (unassigned)` across a dispatcher tick with no runs and no
#   gateway log entry. If you ever assign a room to a profile, that profile will be
#   launched to "work" it — conversation would turn into model quota burn.
#
# Usage:
#   agents-chat.sh rooms                      # list rooms with message counts
#   agents-chat.sh open  <room> [topic...]    # create/reuse a room, print its id
#   agents-chat.sh say   <room> <text...>     # post a message (--as <name> to override author)
#   agents-chat.sh read  <room> [n]           # last n messages (default 20)
#   agents-chat.sh tail  <room>               # live follow
#   agents-chat.sh subscribe <room> --platform telegram --chat-id <id> [--thread-id <t>]
set -euo pipefail

BOARD="${AGENTS_CHAT_BOARD:-agents-chat}"
HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"
HERMES_BIN="${HERMES_BIN:-/home/hermes/.hermes-venv/bin/hermes}"

# HERMES_HOME is 0700 hermes:hermes, so everything must run as that user. Re-exec
# rather than asking the operator to remember it.
if [[ "$(id -un)" != "hermes" ]]; then
    if [[ "$(id -u)" -eq 0 ]] && id hermes >/dev/null 2>&1; then
        exec sudo -u hermes -H env HERMES_HOME="$HERMES_HOME" \
             HERMES_PROFILE="${HERMES_PROFILE:-human}" bash "$0" "$@"
    fi
    echo "run as root (it re-execs as the hermes user): sudo bash $0 $*" >&2
    exit 2
fi

[[ -x "$HERMES_BIN" ]] || { echo "hermes not found at $HERMES_BIN" >&2; exit 2; }
K=( "$HERMES_BIN" kanban --board "$BOARD" )
AUTHOR="${HERMES_PROFILE:-human}"

_room_id() {  # _room_id <room> -> prints the task id, creating the room if needed
    local room="$1" topic="${2:-}"
    "$HERMES_BIN" kanban --board "$BOARD" create "room: $room" \
        ${topic:+--body "$topic"} \
        --created-by "${HERMES_PROFILE:-human}" \
        --idempotency-key "room-$room" --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))'
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  rooms)
    # NOTE: the python source is single-quoted for the shell, so do NOT escape the
    # double quotes inside it — escaping them makes python see a literal backslash
    # and die with "unexpected character after line continuation character".
    "${K[@]}" list --json 2>/dev/null | python3 -c '
import sys, json
rows = json.load(sys.stdin)
rows = rows if isinstance(rows, list) else rows.get("tasks", [])
rooms = [r for r in rows if str(r.get("title", "")).startswith("room: ")]
if not rooms:
    print("no rooms yet - create one: agents-chat.sh open general")
for r in rooms:
    print("  %-14s %-18s status=%-8s assignee=%s" % (
        r["id"], r["title"][6:], r.get("status"), r.get("assignee") or "-"))'
    ;;
  open)
    room="${1:?usage: agents-chat.sh open <room> [topic]}"; shift || true
    id=$(_room_id "$room" "${*:-}")
    [[ -n "$id" ]] || { echo "could not create room '$room'" >&2; exit 1; }
    echo "room '$room' -> $id  (board $BOARD)"
    echo "post:  sudo bash $0 say $room \"текст\""
    echo "read:  sudo bash $0 read $room"
    ;;
  say)
    room="${1:?usage: agents-chat.sh say <room> <text> [--as <author>]}"; shift
    [[ $# -gt 0 ]] || { echo "nothing to say" >&2; exit 2; }
    # extract --as anywhere in the text, without mangling the message itself
    as="$AUTHOR"; parts=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as) as="${2:?--as needs a value}"; shift 2 ;;
            *) parts+=("$1"); shift ;;
        esac
    done
    text="${parts[*]}"
    id=$(_room_id "$room")
    [[ -n "$id" ]] || { echo "no such room and it could not be created" >&2; exit 1; }
    "${K[@]}" comment "$id" "$text" --author "$as"
    ;;
  read)
    room="${1:?usage: agents-chat.sh read <room> [n]}"; n="${2:-20}"
    id=$(_room_id "$room")
    [[ -n "$id" ]] || { echo "no such room '$room'" >&2; exit 1; }
    "${K[@]}" show "$id" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin); t = d.get('task', d)
print(f\"room: {t.get('title','?')}  [{t.get('id')}]  status={t.get('status')}\")
cs = d.get('comments') or []
if not cs: print('  (no messages yet)')
for c in cs[-$n:]:
    print('  %-16s %s' % (c.get('author') or '?', (c.get('body') or '').replace(chr(10), ' ')))"
    ;;
  tail)
    room="${1:?usage: agents-chat.sh tail <room>}"
    id=$(_room_id "$room"); "${K[@]}" tail "$id"
    ;;
  subscribe)
    room="${1:?usage: agents-chat.sh subscribe <room> --platform <p> --chat-id <id>}"; shift
    id=$(_room_id "$room")
    "${K[@]}" notify-subscribe "$id" "$@"
    ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
