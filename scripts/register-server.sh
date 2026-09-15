#!/usr/bin/env bash
# scripts/register-server.sh — mint/refresh the server manifest for THIS machine.
# server.id is stable: it is created once and then never re-derived (a hostname change
# must not fork an identity). Pushes config only, never state.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="$REPO_DIR/config/servers"; mkdir -p "$CFG"
host="$(hostname)"
existing="$(grep -rl "^  hostname: $host\$" "$CFG"/*.yaml 2>/dev/null | head -1 || true)"
if [[ -n "$existing" ]]; then
  sid="$(grep -m1 -E '^  id: ' "$existing" | sed 's/.*id: //')"
  echo "reusing stable server id '$sid' from $(basename "$existing")"
  out="$existing"
else
  sid="srv-$(printf '%s' "$host" | sha1sum | cut -c1-8)"
  out="$CFG/$host.yaml"
  echo "new server id $sid → $out"
fi
umask 022
{ echo "# generated $(date -Is) by scripts/register-server.sh — measured facts, not hand-typed"
  echo "server:"
  echo "  id: $sid"
  echo "  name: $host"
  echo "  hostname: $host"
  echo "  environment: ${SERVER_ENV:-production}"
  echo "  registered_at: \"$(date -u +%F)\""
  echo "measured:"
  echo "  os: \"$(. /etc/os-release; echo "$PRETTY_NAME")\""
  echo "  kernel: $(uname -r)"
  echo "  arch: $(uname -m)"
  echo "  cpu: $(nproc) cores"
  echo "  memory_gib: $(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)"
  echo "  disk_root: \"$(df -h / | awk 'NR==2{print $3" used of "$2", "$5}')"\""
  echo "  load: \"$(cut -d' ' -f1-3 /proc/loadavg)\""
  echo "neighbours: {}   # fill via audit; see config/servers/arm-server-01.yaml for the shape"
} > "$out"
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  bash "$REPO_DIR/scripts/secret-scan.sh" --worktree | tail -1 | grep -q '^clean$' || { echo "secret scan blocked the commit"; exit 1; }
  git -C "$REPO_DIR" add "config/servers/$(basename "$out")"
  git -C "$REPO_DIR" diff --cached --quiet || { git -C "$REPO_DIR" commit -q -m "chore(register): update $host manifest" && echo "committed (push with scripts/push.sh)"; }
fi
echo "manifest: $out"
