#!/usr/bin/env bash
# act.sh — the guarded equivalent of "дать агенту полный доступ к системе".
#
# WHY NOT A SHELL. The owner asked for real power over the box. The honest answer is that a
# chat message must never become an arbitrary root command: the bot token, the Telegram
# account and the chat itself (anywhere on a phone) are all weaker than an SSH key, and a
# leaked token would then equal total control of the server — including the other teams'
# projects running on it. So this script gives the agent the ACTIONS an operator actually
# needs, over named objects, with no expansion of arbitrary text:
#
#   restart-container <name>   docker restart   (name must exist)
#   start-container   <name>   docker start     (exited containers only)
#   restart-unit      <name>   systemctl restart, ALLOWLISTED unit prefixes only
#   prune-images               docker image prune (dangling only)
#   vacuum-journal             journalctl --vacuum-size (bounded)
#
# What is deliberately NOT possible: stop/kill of anything, restart of core units
# (ssh, systemd-logind, networking), package management, arbitrary path or shell arguments,
# `docker run`, deletion of data. Everything executed is printed, and every call is logged
# by the runtime with the actor, so `journalctl -u hermes-agents | grep act:` is an audit
# trail of who asked for what.
#
# The target comes from ARG_TARGET / ARG_ACTION (routing.parse_action), never from a shell.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
ACTION="${ARG_ACTION:-}"
TARGET="${ARG_TARGET:-}"
report_header "🛠 ДЕЙСТВИЕ ${ACTION:-?} ${TARGET}"

# ── allowlists ──────────────────────────────────────────────────────────────
# Units we may restart: our own stack and the projects on this box. A typo cannot reach
# ssh, the network stack or anything the owner did not put in this list.
UNIT_ALLOW='^(hermes-|octopus|nats-server|logistics|madworld|transcribe|aios)'
# Object names: no slashes, no spaces, no shell metacharacters — the name is validated, not
# quoted-and-hoped.
NAME_OK='^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$'

fail() { report_bad "$1"; report_footer "${2:-}"; exit 1; }

valid_name() {
  [[ "$1" =~ $NAME_OK ]] || fail "недопустимое имя «$1»" \
    "имена проверяются строго: буквы, цифры, точка, дефис, подчёркивание"
}
unit_exists()    { systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .; }
container_exists() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

case "$ACTION" in
  restart-container|start-container)
    [[ -z "$TARGET" ]] && fail "не указано имя контейнера" "пример: «перезапусти контейнер octopus-browser»"
    valid_name "$TARGET"
    command -v docker >/dev/null || fail "docker не установлен"
    container_exists "$TARGET" || fail "контейнера «$TARGET» нет на этом узле" \
      "посмотреть список: «статус контейнеров»"
    report_section "🐳 КОНТЕЙНЕР"
    docker ps -a --filter "name=^${TARGET}$" --format '  было: {{.Status}}' 2>/dev/null
    if [[ "$ACTION" == "restart-container" ]]; then
      OUT=$(timeout 90 docker restart "$TARGET" 2>&1) || fail "docker restart $TARGET: $OUT"
    else
      OUT=$(timeout 90 docker start "$TARGET" 2>&1) || fail "docker start $TARGET: $OUT"
    fi
    sleep 3
    docker ps --filter "name=^${TARGET}$" --format '  стало: {{.Status}}' 2>/dev/null
    if docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | grep -qx "$TARGET"; then
      report_warn "контейнер поднялся, но health = unhealthy"
      report_section "📜 ПОСЛЕДНИЕ СТРОКИ"
      docker logs --tail 8 "$TARGET" 2>&1 | cut -c1-130 | sed 's/^/  /'
      report_footer "смотреть причину в логах выше" "если это чужой проект — сообщить владельцу проекта"
    elif [[ "$ACTION" == "start-container" ]]; then
      report_ok "контейнер $TARGET запущен (если уже работал — состояние не изменилось)"
    else
      report_ok "контейнер $TARGET перезапущен"
      report_footer "проверить его ресурсы: «что с процессом ${TARGET}»" "проверить логи: docker logs $TARGET --tail 30"
    fi
    ;;

  restart-unit)
    [[ -z "$TARGET" ]] && fail "не указано имя сервиса" "пример: «перезапусти сервис nats-server»"
    valid_name "$TARGET"
    [[ "$TARGET" =~ $UNIT_ALLOW ]] || fail "юнит «$TARGET» не входит в разрешённый список" \
      "разрешены только: hermes-*, octopus*, nats-server, logistics*, madworld*, transcribe*, aios*"
    UNIT="$TARGET"; [[ "$UNIT" == *.service ]] || UNIT="$TARGET.service"
    unit_exists "$UNIT" || fail "юнита $UNIT нет на этом узле"
    report_section "⚙️ ЮНИТ"
    report_kv "было" "$(systemctl is-active "$UNIT" 2>/dev/null)"
    OUT=$(timeout 60 systemctl restart "$UNIT" 2>&1) || report_warn "systemctl вернул замечание: ${OUT:0:120}"
    sleep 3
    NOW=$(systemctl is-active "$UNIT" 2>/dev/null)
    report_kv "стало" "$NOW"
    if [[ "$NOW" == "active" ]]; then
      report_ok "$UNIT работает"
      report_footer "проверить журнал: journalctl -u $UNIT -n 20" "если падает снова: «логи» покажет источник"
    else
      report_bad "$UNIT не поднялся ($NOW)"
      report_section "📜 ПРИЧИНА"
      journalctl -u "$UNIT" -n 8 --no-pager -o cat 2>/dev/null | cut -c1-130 | sed 's/^/  /'
      report_footer "юнит возвращается в failed — нужен разбор, а не повторный перезапуск"
    fi
    ;;

  prune-images)
    command -v docker >/dev/null || fail "docker не установлен"
    report_section "🐳 ДО ОЧИСТКИ"
    docker system df --format '  {{.Type}}: {{.Size}} ({{.Reclaimable}} можно освободить)' 2>/dev/null
    BEFORE=$(df -h / | awk 'NR==2{print $4}')
    OUT=$(timeout 180 docker image prune -f 2>&1 | tail -2) || fail "prune: $OUT"
    report_section "🧹 РЕЗУЛЬТАТ"
    echo "$OUT" | sed 's/^/  /'
    report_section "📦 ПОСЛЕ"
    report_kv "свободно на /" "$BEFORE → $(df -h / | awk 'NR==2{print $4}')"
    docker system df --format '  {{.Type}}: {{.Size}}' 2>/dev/null
    report_ok "удалены только неиспользуемые (dangling) образы; работающие контейнеры не затронуты"
    report_footer "если нужно больше места: «диски» покажет крупные каталоги"
    ;;

  vacuum-journal)
    report_section "📜 ДО"
    report_kv "журнал занимает" "$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}')"
    OUT=$(timeout 120 journalctl --vacuum-size=500M 2>&1 | tail -2) || fail "vacuum: $OUT"
    report_section "🧹 РЕЗУЛЬТАТ"
    echo "$OUT" | sed 's/^/  /'
    report_kv "журнал теперь" "$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}')"
    report_ok "оставлены последние 500 MiB журнала — свежая диагностика не потеряна"
    report_footer "если чистка нужна регулярно: проверить, кто столько пишет — «логи»"
    ;;

  "" )
    fail "не понял действие" "доступные действия: перезапустить контейнер/сервис, запустить контейнер, почистить docker, сжать журнал"
    ;;
  * )
    fail "действие «$ACTION» не разрешено" "доступные действия: перезапустить контейнер/сервис, запустить контейнер, почистить docker, сжать журнал"
    ;;
esac
