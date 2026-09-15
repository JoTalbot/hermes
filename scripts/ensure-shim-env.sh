#!/usr/bin/env bash
# scripts/ensure-shim-env.sh — self-heal /etc/hermes/shim.env.
#
# WHY (real incident, 2026-09-15):
#   /etc/hermes/shim.env existed and was verified at 13:29:31 UTC, then was
#   GONE by 13:31:58 UTC. Consequence: hermes-shim crash-looped with
#   "FATAL: HERMES_BALANCER_API_KEY is unset" and hermes-serve lost its model
#   endpoint. Root was recoverable only because a hand-made .bak happened to
#   exist. The sudo audit trail shows a concurrent root shell (`/usr/bin/bash -s`)
#   in that window; the exact deleter is NOT proven (memory/incidents/…).
#
#   The lesson is not "who" but "a single missing file took the whole stack
#   down". So the units now call this as ExecStartPre: the secret is restored
#   from a root-only canonical copy before either service is allowed to start.
#
# CONTRACT
#   * Never prints a secret value.
#   * Idempotent: an intact file is left byte-for-byte alone.
#   * Exit 0 = env present and usable; exit 1 = cannot proceed (unit fails loudly).
#   * Only ever writes /etc/hermes/shim.env, mode 0600 root:root.
set -euo pipefail

ENV_FILE="/etc/hermes/shim.env"
CANON="/var/backups/hermes/shim.env.canonical"
HERMES_ETC="/etc/hermes"

log() { printf '[ensure-shim-env] %s\n' "$*" >&2; }

# --- directory-mode invariant (regression guard, seen TWICE) ------------------
# Hermes' managed-scope loader stats /etc/hermes/.env even when that file does not
# exist, and its fail-open try/except wraps get_managed_dir() but NOT the later
# .exists() call:
#     managed_env = managed_dir / ".env"
#     if not managed_env.exists():        <-- raises PermissionError, not False
# So a mode-0700/0750 /etc/hermes makes EVERY `hermes ...` invocation die with
# "PermissionError: [Errno 13] Permission denied: '/etc/hermes/.env'" — including
# `hermes kanban list`. It bit us twice on 2026-09-15: once from the original
# install (0750) and once from a careless `install -d -m 0700 /etc/hermes`.
# The secrets inside stay 0600; the DIRECTORY must stay traversable.
if [[ -d "$HERMES_ETC" ]]; then
  _mode="$(stat -c '%a' "$HERMES_ETC")"
  if [[ "$_mode" != "755" ]]; then
    chmod 755 "$HERMES_ETC"
    log "FIXED $HERMES_ETC mode was $_mode, must be 755 (secrets inside stay 0600)"
  fi
fi

_has_key() { [[ -s "$1" ]] && grep -q '^HERMES_BALANCER_API_KEY=' "$1"; }

if _has_key "$ENV_FILE"; then
  # Present. Make sure OPENAI_API_KEY is mirrored for the agent runtime, then stop.
  if ! grep -q '^OPENAI_API_KEY=' "$ENV_FILE"; then
    k="$(grep '^HERMES_BALANCER_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
    printf 'OPENAI_API_KEY=%s\n' "$k" >> "$ENV_FILE"
    log "added missing OPENAI_API_KEY mirror"
  fi
  chown root:root "$ENV_FILE" 2>/dev/null || true
  chmod 0600 "$ENV_FILE" 2>/dev/null || true
  exit 0
fi

log "WARN $ENV_FILE missing or incomplete — attempting self-heal"
install -d -m 0700 -o root -g root "$(dirname "$CANON")"

if _has_key "$CANON"; then
  install -m 0600 -o root -g root "$CANON" "$ENV_FILE"
  log "restored from $CANON (secret not shown)"
  exit 0
fi

# No canonical copy either: mint one. This is a key rotation from the shim's
# point of view — anything holding the old value (an agent's ~/.hermes/.env)
# must be re-synced. Say so loudly rather than failing silently into 401s.
log "WARN no canonical copy at $CANON — generating a NEW loopback secret"
umask 077
KEY="$(head -c 24 /dev/urandom | base64 | tr -d '\n=' | head -c 32)"
{
  printf 'HERMES_BALANCER_API_KEY=%s\n' "$KEY"
  printf 'OPENAI_API_KEY=%s\n' "$KEY"
  printf 'HERMES_SHIM_PORT=9700\n'
  printf 'HERMES_SHIM_BIND=127.0.0.1\n'
  printf 'AIOS_BRIDGE_URL=http://127.0.0.1:9600\n'
} > "$ENV_FILE"
chown root:root "$ENV_FILE"; chmod 0600 "$ENV_FILE"
install -m 0600 -o root -g root "$ENV_FILE" "$CANON"
log "ROTATED: new secret written and archived. Re-run scripts/install.sh so"
log "        /home/hermes/.hermes stays in sync, then restart hermes-shim."
exit 0
