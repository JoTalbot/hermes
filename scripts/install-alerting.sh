#!/usr/bin/env bash
# scripts/install-alerting.sh — make alerts actually reach the owner.
#
# MEASURED PROBLEM (2026-09-17): 10 rules in deploy/monitoring/hermes-agents.rules.yml,
# 5 of them firing (HermesProjectTreeMissing), no Alertmanager installed and no webhook
# configured anywhere. Prometheus had been shouting into an empty room.
#
# DECISION: instead of adding Alertmanager (a second service, its own config language and
# its own failure modes) the bridge-side poller scripts/hermes-alert-poller.py reads the
# Prometheus API and writes to the same Telegram chat, with the same token file, that the
# agent bus already uses. One less moving part, and the message format is ours.
#
#   bash scripts/install-alerting.sh            # установить/обновить и запустить
#   bash scripts/install-alerting.sh --check    # проверка (для tests/run.sh и doctor)
#   bash scripts/install-alerting.sh --test     # послать пробный алерт в Telegram
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-/opt/hermes}"
UNIT=/etc/systemd/system/hermes-alert-poller.service
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

case "${1:-}" in
  --check)
    FAILED=0
    echo "=== алерты → Telegram ==="
    systemctl is-active --quiet hermes-alert-poller \
      && ok "hermes-alert-poller активен" || { bad "hermes-alert-poller не работает"; FAILED=$((FAILED+1)); }
    if [[ -f /var/lib/hermes-bus/alert-state.json ]]; then
      AGE=$(( $(date +%s) - $(stat -c %Y /var/lib/hermes-bus/alert-state.json) ))
      (( AGE < 1800 )) && ok "состояние обновлялось $((AGE/60)) мин назад" \
                       || { warn "состояние старое ($((AGE/60)) мин)"; }
    else
      warn "состояние ещё не создано (алертов может просто не быть)"
    fi
    [[ -r /etc/hermes/telegram.env ]] && ok "telegram.env читается" \
      || { bad "нет доступа к /etc/hermes/telegram.env"; FAILED=$((FAILED+1)); }
    CNT=$(curl -s --max-time 5 http://127.0.0.1:9090/api/v1/rules?type=alert 2>/dev/null \
          | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["data"]["groups"]
    print(sum(1 for g in d for r in g["rules"]))
except Exception: print("?")' 2>/dev/null)
    [[ "$CNT" != "?" && -n "$CNT" ]] && ok "Prometheus отвечает, правил: $CNT" \
      || { bad "Prometheus недоступен на 127.0.0.1:9090"; FAILED=$((FAILED+1)); }
    FIRING=$(curl -s --max-time 5 http://127.0.0.1:9090/api/v1/alerts 2>/dev/null \
             | python3 -c 'import json,sys
try: print(sum(1 for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"))
except Exception: print(0)' 2>/dev/null)
    echo "  ℹ️  сейчас горит: ${FIRING:-?}"
    echo
    (( FAILED == 0 )) && { echo "ALERTING: OK"; exit 0; }
    echo "ALERTING: FAIL ($FAILED)"; exit 1
    ;;

  --test)
    python3 - "$HERMES_HOME" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("poller", f"{sys.argv[1]}/scripts/hermes-alert-poller.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("token:", "есть" if m.token() else "НЕТ", "| chat:", m.chat_id() or "НЕТ")
print("отправка:", m.tg_send("🧪 Проверка канала алертов Hermes. Если вы это видите — алерты доходят."))
PY
    ;;

  *)
    echo "=== 1. юнит hermes-alert-poller ==="
    cat > "$UNIT" <<EOF
[Unit]
Description=Hermes alert poller (Prometheus rules -> Telegram)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/hermes/alerts.env
ExecStart=/usr/bin/python3 ${HERMES_HOME}/scripts/hermes-alert-poller.py
Restart=always
RestartSec=15
# Алерты — это про выживание остальных: сам поллер не должен стать причиной OOM.
MemoryMax=192M
OOMScoreAdjust=-500
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
ReadWritePaths=/var/lib/hermes-bus

[Install]
WantedBy=multi-user.target
EOF
    ok "юнит записан: $UNIT"
    systemctl daemon-reload
    systemctl enable --now hermes-alert-poller 2>/dev/null
    sleep 3
    systemctl is-active --quiet hermes-alert-poller \
      && ok "hermes-alert-poller запущен" || bad "не запустился: journalctl -u hermes-alert-poller -n 20"
    echo
    echo "=== 2. первый проход (что уже горит) ==="
    journalctl -u hermes-alert-poller -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/  /'
    echo
    echo "=== 3. проверка ==="
    bash "${BASH_SOURCE[0]}" --check
    ;;
esac
