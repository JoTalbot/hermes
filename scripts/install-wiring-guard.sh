#!/usr/bin/env bash
# install-wiring-guard.sh — таймер проверки разводки агентов (см. scripts/wiring-guard.sh).
#   bash scripts/install-wiring-guard.sh           # установить/обновить
#   bash scripts/install-wiring-guard.sh --check   # WIRING-GUARD: OK / DRIFT
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
[[ "${1:-}" == "--check" ]] && exec bash "$REPO_DIR/scripts/wiring-guard.sh" --check

cat > /etc/systemd/system/hermes-wiring-guard.service <<UNITEOF
[Unit]
Description=Hermes agent wiring guard (repairs generator drift)
After=network-online.target

[Service]
Type=oneshot
Environment=REPO_DIR=${REPO_DIR}
ExecStart=/bin/bash ${REPO_DIR}/scripts/wiring-guard.sh
Nice=10
UNITEOF
cat > /etc/systemd/system/hermes-wiring-guard.timer <<TIMEREOF
[Unit]
Description=Hermes agent wiring guard every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true
Unit=hermes-wiring-guard.service

[Install]
WantedBy=timers.target
TIMEREOF
systemctl daemon-reload
systemctl enable --now hermes-wiring-guard.timer >/dev/null 2>&1
echo "  таймер разводки включён (каждые 30 минут)"
bash "$REPO_DIR/scripts/wiring-guard.sh" | sed 's/^/  /'
bash "$REPO_DIR/scripts/wiring-guard.sh" --check
