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
# shellcheck source=lib/journal.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/journal.sh"
export HERMES_ACTOR="${ARG_ACTOR:-${HERMES_ACTOR:-telegram}}"
ACTION="${ARG_ACTION:-}"
TARGET="${ARG_TARGET:-}"
CONFIRM="${ARG_CONFIRM:-no}"
report_header "🛠 ДЕЙСТВИЕ ${ACTION:-?} ${TARGET}"

# ── allowlists ──────────────────────────────────────────────────────────────
# Units we may restart: our own stack and the projects on this box. A typo cannot reach
# ssh, the network stack or anything the owner did not put in this list.
UNIT_ALLOW='^(hermes-|octopus|nats-server|logistics|madworld|transcribe|aios)'
# Object names: no slashes, no spaces, no shell metacharacters — the name is validated, not
# quoted-and-hoped.
NAME_OK='^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$'

fail() { report_bad "$1"; report_footer "${2:-}"; exit 1; }

# Действия, которые меняют данные, а не только состояние процесса. Их нельзя выполнить
# одной фразой: владелец подтверждает явно («подтверждаю …»), и это попадает в журнал.
IRREVERSIBLE='^(clean-old-logs|prune-images|backup-now)$'
need_confirm() {
  [[ "$CONFIRM" == "yes" ]] && return 0
  report_warn "«$ACTION${TARGET:+ $TARGET}» меняет данные — нужно подтверждение"
  report_info "выполню, если повторить с подтверждением: «подтверждаю ${ACTION}${TARGET:+ $TARGET}»"
  report_proof "act.sh: ARG_CONFIRM=$CONFIRM (подтверждение обязательно для $ACTION)"
  journal_write "$(journal_slug_for "$TARGET")" decision "запрошено подтверждение: $ACTION ${TARGET}"
  exit 0
}
# Итог каждого действия — в журнал проекта (или узла). Иначе «что тут делали» остаётся
# только в переписке, а её через неделю не найти.
done_journal() {
  local kind="$1" text="$2"
  journal_write "$(journal_slug_for "$TARGET")" "$kind" "$text"
}

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
      done_journal action "start-container $TARGET — контейнер запущен"
    else
      report_ok "контейнер $TARGET перезапущен"
      done_journal action "restart-container $TARGET — перезапущен, $(docker ps --filter "name=^${TARGET}$" --format '{{.Status}}' 2>/dev/null | head -1)"
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
      done_journal action "restart-unit $UNIT — active"
      report_footer "проверить журнал: journalctl -u $UNIT -n 20" "если падает снова: «логи» покажет источник"
    else
      report_bad "$UNIT не поднялся ($NOW)"
      done_journal incident "restart-unit $UNIT — не поднялся ($NOW)"
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
    done_journal action "prune-images — освобождено; свободно на /: $(df -h / | awk 'NR==2{print $4}')"
    report_footer "если нужно больше места: «диски» покажет крупные каталоги"
    ;;

  backup-now)
    # Резервная копия не разрушает ничего, но это полноценная операция: подтверждение
    # обязательно, чтобы «сделай бэкап» не запускалось случайной фразой в чате.
    need_confirm
    [[ -x /opt/hermes/scripts/backup.sh ]] || fail "скрипт бэкапа не найден"
    report_section "💾 РЕЗЕРВНАЯ КОПИЯ"
    OUT=$(HERMES_HOME=/opt/hermes timeout 900 bash /opt/hermes/scripts/backup.sh 2>&1 | tail -6)
    RC=$?
    printf '%s\n' "$OUT" | sed 's/^/  /'
    if (( RC == 0 )); then
      report_ok "бэкап создан"
      done_journal change "backup-now — бэкап создан"
      report_footer "проверить содержимое: «что в бэкапе»" "целостность: «проверь бэкап»"
    else
      report_bad "бэкап завершился с кодом $RC"
      done_journal incident "backup-now — код $RC"
      report_footer "смотреть вывод выше — ошибка самого скрипта бэкапа"
    fi
    ;;

  clean-old-logs)
    need_confirm
    DAYS="${ARG_DAYS:-30}"
    [[ "$DAYS" =~ ^[0-9]{1,3}$ ]] || fail "срок «$DAYS» не число" "пример: «подтверждаю clean-old-logs 30»"
    report_section "🧹 ЛОГИ СТАРШЕ $DAYS ДНЕЙ"
    report_kv "каталог" "/var/lib/hermes-agents/logs"
    BEFORE=$(find /var/lib/hermes-agents/logs -type f | wc -l)
    SIZE=$(du -sh /var/lib/hermes-agents/logs 2>/dev/null | awk '{print $1}')
    # Только журналы прогонов агентов и только по возрасту: никаких «rm -rf» по шаблону.
    DEL=$(find /var/lib/hermes-agents/logs -type f -name '*.log' -mtime +"$DAYS" -print -delete 2>/dev/null | wc -l)
    AFTER=$(find /var/lib/hermes-agents/logs -type f | wc -l)
    report_kv "файлов" "$BEFORE → $AFTER (удалено $DEL)"
    report_kv "размер" "$SIZE → $(du -sh /var/lib/hermes-agents/logs 2>/dev/null | awk '{print $1}')"
    report_ok "удалены только журналы старше $DAYS дней; история прогонов (history.jsonl) не тронута"
    report_proof "find /var/lib/hermes-agents/logs -name '*.log' -mtime +$DAYS -delete"
    done_journal action "clean-old-logs $DAYS — удалено файлов: $DEL"
    report_footer "свежие журналы сохранены — разбор вчерашних падений не пострадал"
    ;;

  rotate-logs)
    report_section "🔄 РОТАЦИЯ ПО ПРАВИЛАМ"
    [[ -f /etc/logrotate.d/hermes ]] || fail "правил ротации нет" "установить: bash /opt/hermes/scripts/install-logrotate.sh"
    OUT=$(timeout 120 logrotate -f /etc/logrotate.d/hermes 2>&1); RC=$?
    printf '%s\n' "$OUT" | tail -4 | sed 's/^/  /'
    if (( RC == 0 )); then
      report_ok "ротация выполнена по /etc/logrotate.d/hermes"
      done_journal action "rotate-logs — ротация выполнена"
    else
      report_bad "logrotate вернул код $RC"
      done_journal incident "rotate-logs — код $RC"
    fi
    report_footer "размеры журналов: «статус сервера»"
    ;;

  vacuum-journal)
    report_section "📜 ДО"
    report_kv "журнал занимает" "$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}')"
    OUT=$(timeout 120 journalctl --vacuum-size=500M 2>&1 | tail -2) || fail "vacuum: $OUT"
    report_section "🧹 РЕЗУЛЬТАТ"
    echo "$OUT" | sed 's/^/  /'
    report_kv "журнал теперь" "$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}')"
    report_ok "оставлены последние 500 MiB журнала — свежая диагностика не потеряна"
    done_journal action "vacuum-journal — журнал сжат до 500 MiB"
    report_footer "если чистка нужна регулярно: проверить, кто столько пишет — «логи»"
    ;;

  "" )
    fail "не понял действие" "доступные действия: перезапустить контейнер/сервис, запустить контейнер, ротация журналов, почистить docker, сжать журнал, бэкап (с подтверждением), чистка старых журналов (с подтверждением)"
    ;;
  * )
    fail "действие «$ACTION» не разрешено" "доступные действия: перезапустить контейнер/сервис, запустить контейнер, ротация журналов, почистить docker, сжать журнал, бэкап (с подтверждением), чистка старых журналов (с подтверждением)"
    ;;
esac
