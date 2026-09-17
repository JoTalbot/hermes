#!/usr/bin/env bash
# install-restore-drill.sh — таймер автоматического учения по восстановлению (раз в месяц).
#
#   bash scripts/install-restore-drill.sh          # поставить/обновить
#   bash scripts/install-restore-drill.sh --check  # RESTORE-DRILL: OK / FAILED / НЕ БЫЛО
#   bash scripts/install-restore-drill.sh --now    # прогнать учение сейчас
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

case "${1:-}" in
  --check)
    out="$(bash "$REPO_DIR/scripts/drill-restore.sh" --check 2>&1 | tail -1)"
    printf '  %s\n' "$out"
    if systemctl is-active hermes-restore-drill.timer >/dev/null 2>&1; then
      ok "таймер активен · следующий запуск: $(systemctl show -p NextElapseUSecRealtime --value hermes-restore-drill.timer 2>/dev/null | cut -c1-19)"
    else
      warn "таймер не активен — учение по расписанию не пойдёт"
    fi
    case "$out" in RESTORE-DRILL:\ OK*) echo "  ${GREEN}RESTORE-DRILL: OK${RST}"; exit 0 ;; esac
    echo "  ${YLW}RESTORE-DRILL: проверить${RST}"; exit 3 ;;
  --now) exec bash "$REPO_DIR/scripts/drill-restore.sh" ;;
esac

echo "=== 1. юнит учения ==="
cat > /etc/systemd/system/hermes-restore-drill.service <<'UNIT'
[Unit]
Description=Hermes restore drill: unpack the newest backup elsewhere and verify it
Documentation=file:///opt/hermes/docs/RUNBOOK.md
After=hermes-backup.service

[Service]
Type=oneshot
User=root
ExecStart=/bin/bash /opt/hermes/scripts/drill-restore.sh
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1800
UNIT
ok "юнит: hermes-restore-drill.service"

echo "=== 2. таймер (раз в месяц, 04:30 UTC; после бэкапа 03:42) ==="
cat > /etc/systemd/system/hermes-restore-drill.timer <<'TIMER'
[Unit]
Description=Monthly Hermes restore drill

[Timer]
OnCalendar=*-*-01 04:30:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now hermes-restore-drill.timer >/dev/null 2>&1
ok "таймер: $(systemctl is-active hermes-restore-drill.timer) · следующий запуск: $(systemctl show -p NextElapseUSecRealtime --value hermes-restore-drill.timer 2>/dev/null | cut -c1-19)"

echo "=== 3. проверка, что учение запускается (--check) ==="
bash "$REPO_DIR/scripts/drill-restore.sh" --check | sed 's/^/  /'
echo
echo "  ${GREEN}RESTORE-DRILL: установлен${RST} — учение пойдёт 1-го числа каждого месяца и сообщит результат в Telegram"
