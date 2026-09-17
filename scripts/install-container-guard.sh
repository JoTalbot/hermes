#!/usr/bin/env bash
# install-container-guard.sh — сторож контейнерных лимитов (см. scripts/container-guard.sh).
#
# Ставит файл желаемых лимитов, юнит и таймер на 15 минут. Файл лимитов создаётся только
# при первом запуске: он принадлежит владельцу, и повторная установка его НЕ перезаписывает.
#   bash scripts/install-container-guard.sh           # установить/обновить
#   bash scripts/install-container-guard.sh --check   # CONTAINER-GUARD: OK / DRIFT
#   bash scripts/install-container-guard.sh --seed    # записать текущие лимиты контейнеров как желаемые
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
CONF=/etc/hermes/container-limits.conf
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

case "${1:-}" in
  --check) exec bash "$REPO_DIR/scripts/container-guard.sh" --check ;;
  --seed)
    echo "=== текущие лимиты контейнеров (для решения владельца) ==="
    for n in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
      m=$(docker inspect -f '{{.HostConfig.Memory}}' "$n" 2>/dev/null || echo 0)
      s=$(docker inspect -f '{{.HostConfig.MemorySwap}}' "$n" 2>/dev/null || echo 0)
      printf '  %-52s memory=%s swap=%s\n' "$n" "$m" "$s"
    done
    exit 0 ;;
esac

echo "=== 1. файл желаемых лимитов ==="
if [[ -s "$CONF" ]]; then
  ok "уже есть, не трогаю: $CONF ($(grep -cv '^\s*#\|^\s*$' "$CONF") строк)"
else
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" <<'CONFEOF'
# Лимиты контейнеров, которые владелец одобрил. Формат: <имя> <память> <memory-swap>
# Строка = обязательство: сторож вернёт лимит, если контейнер пересоздадут без него.
# Пусто/0 в памяти означает «владелец лимит не ставит» — такие строки не пишем вообще.
#
# 2026-09-17, одобрено владельцем («+»): браузер — чужой проект, но именно он выедал память узла.
octopus-browser-chromium 8g 8g
CONFEOF
  ok "создан: $CONF"
fi

echo "=== 2. юнит и таймер ==="
install -d -m 755 /etc/systemd/system
cat > /etc/systemd/system/hermes-container-guard.service <<UNITEOF
[Unit]
Description=Hermes container limit guard (restores owner-approved limits)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=REPO_DIR=${REPO_DIR}
ExecStart=/bin/bash ${REPO_DIR}/scripts/container-guard.sh
Nice=10
UNITEOF
cat > /etc/systemd/system/hermes-container-guard.timer <<TIMEREOF
[Unit]
Description=Hermes container limit guard every 15 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
Persistent=true
Unit=hermes-container-guard.service

[Install]
WantedBy=timers.target
TIMEREOF
systemctl daemon-reload
systemctl enable --now hermes-container-guard.timer >/dev/null 2>&1
ok "таймер включён (каждые 15 минут)"
echo "=== 3. первый прогон ==="
bash "$REPO_DIR/scripts/container-guard.sh" | sed 's/^/  /'
echo "=== 4. проверка ==="
bash "$REPO_DIR/scripts/container-guard.sh" --check
