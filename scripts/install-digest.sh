#!/usr/bin/env bash
# install-digest.sh — суточная сводка владельцу в 09:00 (доставка тем же каналом, что алерты).
#
# Один таймер, одна сводка, никакого потока событий: «за сутки» — это 10–15 строк о том,
# всё ли в порядке и что требует решения.
#   bash scripts/install-digest.sh            # установить/обновить
#   bash scripts/install-digest.sh --check    # DIGEST: OK / что не так
#   bash scripts/install-digest.sh --test     # посчитать и отправить сейчас
set -uo pipefail
HERMES_HOME="${HERMES_HOME:-/opt/hermes}"
UNIT=/etc/systemd/system/hermes-digest.service
TIMER=/etc/systemd/system/hermes-digest.timer
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

case "${1:-}" in
  --check)
    F=0
    echo "=== суточная сводка ==="
    systemctl is-enabled --quiet hermes-digest.timer 2>/dev/null \
      && ok "таймер включён" || { bad "таймер не включён"; F=$((F+1)); }
    systemctl is-active --quiet hermes-digest.timer 2>/dev/null \
      && ok "таймер активен" || { bad "таймер не активен"; F=$((F+1)); }
    NEXT="$(systemctl list-timers hermes-digest.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
    [[ -n "$NEXT" ]] && ok "следующий запуск: $NEXT" || warn "время следующего запуска неизвестно"
    [[ -r /etc/hermes/telegram.env ]] && ok "telegram.env читается" \
      || { bad "нет доступа к /etc/hermes/telegram.env"; F=$((F+1)); }
    [[ -x "$HERMES_HOME/agents/checks/digest.sh" ]] && ok "digest.sh на месте" \
      || { bad "нет $HERMES_HOME/agents/checks/digest.sh"; F=$((F+1)); }
    [[ $F -eq 0 ]] && echo "DIGEST: OK" || echo "DIGEST: FAIL ($F)"
    exit $(( F == 0 ? 0 : 1 ))
    ;;
  --test)
    exec python3 "$HERMES_HOME/scripts/hermes-digest.py"
    ;;
esac

echo "=== 1. юнит и таймер ==="
cat > "$UNIT" <<UNITEOF
[Unit]
Description=Hermes daily digest to Telegram
After=network-online.target
Wants=network-online.target

[Service]
# Перед сводкой: оценки 👎 становятся вопросами регресс-набора (пункт 2 владельца).
ExecStartPre=-/bin/bash /opt/hermes/scripts/feedback-to-eval.sh
# И повторы сбоев — в память (одна запись на неделю, файл в .gitignore).
ExecStartPre=-/bin/bash -c 'ARG_WRITE=1 /opt/hermes/agents/checks/repeats.sh >/dev/null'
Type=oneshot
WorkingDirectory=${HERMES_HOME}
Environment=HERMES_HOME=${HERMES_HOME}
ExecStart=/usr/bin/python3 ${HERMES_HOME}/scripts/hermes-digest.py
Nice=10
IOSchedulingClass=idle
UNITEOF
cat > "$TIMER" <<TIMEREOF
[Unit]
Description=Hermes daily digest at 09:00

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true
RandomizedDelaySec=300
Unit=hermes-digest.service

[Install]
WantedBy=timers.target
TIMEREOF
systemctl daemon-reload
systemctl enable --now hermes-digest.timer >/dev/null 2>&1
echo "  юниты записаны и таймер включён"
echo "=== 2. проверка ==="
bash "$0" --check
