#!/usr/bin/env bash
# scripts/update.sh — update Hermes + this repo without stranding a running system.
# Order: backup → pull → install → verify → (rollback on failure).
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HBIN="${HERMES_BIN:-/home/hermes/.hermes-venv/bin/hermes}"
echo "[1/5] pre-update backup"; bash "$REPO_DIR/scripts/backup.sh" | tail -3
PREV_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "[2/5] repo pull"; git -C "$REPO_DIR" pull --ff-only || echo "  (no fast-forward — resolve manually, NOT with reset)"
echo "[3/5] runtime update"
if "$HBIN" update --check >/dev/null 2>&1; then "$HBIN" update; else echo "  hermes update reported nothing to do / unavailable"; fi
bash "$REPO_DIR/scripts/install.sh"
echo "[4/5] verify"; if bash "$REPO_DIR/scripts/doctor.sh"; then
  echo "[5/5] healthy — leaving services running"; exit 0
fi
echo "[5/5] doctor FAILED — rolling back repo to $PREV_SHA and restarting services"
git -C "$REPO_DIR" reset --hard "$PREV_SHA" >/dev/null
bash "$REPO_DIR/scripts/install.sh" >/dev/null 2>&1 || true
systemctl restart hermes-shim hermes-serve 2>/dev/null || true
echo "rollback complete. Investigate with: journalctl -u hermes-serve -n 80"
exit 1
