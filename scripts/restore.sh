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
# Экспорт обязателен: install-bus.sh и install-agent-runtime.sh читают REPO_DIR из
# окружения и без него цепляются к СВОЕМУ /opt/hermes. В дрилле 2026-09-17 из-за этого шаг
# установки молча выполнялся старым кодом узла, а «дрилл на новом коде» проверял не то.
export REPO_DIR HERMES_HOME
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
  echo "  Archive top-level entries:"; tar -tzf "$ARCHIVE" | sed 's/^/    /' | awk 'NR <= 5'
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
echo "--- 3b/4 node configuration (allowlist, node role, bus state) ---"
# The state archive never contained these (they live outside HERMES_HOME), which is how a
# restored node could come back "healthy" but functionally mute: the Telegram allowlist was
# empty, so the bot ignored its owner. Restored from hermes-nodecfg-*.tar.gz if present.
NODECFG="$(ls -1t "$(dirname "$ARCHIVE")"/hermes-nodecfg-*.tar.gz 2>/dev/null | head -1)"
if [[ -n "$NODECFG" ]]; then
  echo "  from $(basename "$NODECFG")"
  # awk вместо `head -12`: под `set -o pipefail` ранний выход head даёт SIGPIPE, sed
  # умирает с 141, и скрипт молча обрывается прямо здесь — уже случалось в дрилле.
  tar -tzf "$NODECFG" | sed 's|^\./|    |' | awk 'NR <= 12' 
  # Explicitly refuse to overwrite secrets that exist on this host; add only what is missing.
  TMPC="$(mktemp -d)"; tar -xzf "$NODECFG" -C "$TMPC"
  for rel in etc/hermes/telegram.chats.json etc/hermes/node.env etc/hermes/alerts.env \
             var/lib/hermes-bus/tg-offset.json var/lib/hermes-bus/alert-state.json \
             var/lib/hermes-agents/pending.json; do
    src="$TMPC/$rel"; dst="/$rel"
    [[ -f "$src" ]] || continue
    if [[ -f "$dst" ]]; then
      echo "    keeping existing $dst (не перезаписываю)"
    else
      install -D -m 0644 "$src" "$dst" && echo "    restored $dst"
    fi
  done
  rm -rf "$TMPC"
  echo "  secrets (telegram.env, nats.env, shim.env) must be placed BY HAND: they are not in any archive"
else
  echo "  no nodecfg archive next to $(basename "$ARCHIVE") — /etc/hermes must be rebuilt by hand"
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
