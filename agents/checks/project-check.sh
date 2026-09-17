#!/usr/bin/env bash
# Статус проекта: путь, git, сервисы, контейнеры, свежие изменения. Read-only.
# Переменные приходят из YAML агента: PROJECT_SLUG, PROJECT_PATH, PROJECT_REPO, PROJECT_SERVICE.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
SLUG="${PROJECT_SLUG:-project}"
PATH_="${PROJECT_PATH:-}"
SERVICES="${PROJECT_SERVICE:-}"
report_header "📦 ПРОЕКТ ${SLUG}"

if [[ -z "$PATH_" || ! -d "$PATH_" ]]; then
  report_section "📁 КАТАЛОГ"
  report_bad "не найден: ${PATH_:-путь не задан}"
  report_info "репозиторий: ${PROJECT_REPO:-неизвестен}"
  report_footer "каталог отсутствует — это отметка, а не ошибка агента: решить, восстанавливать ли проект" \
                "если проект переехал: обновить PROJECT_PATH в config/agents/projects/${SLUG}.yaml и запустить scripts/wire-agents.sh"
  exit 0
fi

report_section "📁 КАТАЛОГ"
report_ok "$PATH_"
report_kv "размер" "$(du -sh "$PATH_" 2>/dev/null | cut -f1)"
report_kv "репозиторий" "${PROJECT_REPO:-—}"

if [[ -d "$PATH_/.git" ]]; then
  report_section "🐙 GIT"
  # FACT (2026-09-17): у 14 из 21 проектов каталог принадлежит другому пользователю
  # (ubuntu, opc), а агент работает под root — git отказывается работать с чужим деревом
  # («detected dubious ownership») и ВСЕ команды возвращают пустоту. Отчёт при этом печатал
  # «дерево чистое / всё отправлено / не отстаёт»: агент утверждал, что проверил, хотя не
  # прочитал ни одного байта. Сначала — доступность репозитория, и только потом выводы.
  GITERR="$(git -C "$PATH_" rev-parse --verify -q HEAD 2>&1 >/dev/null)"
  if [[ -n "$GITERR" ]]; then
    report_bad "git не читает этот репозиторий — состояние НЕИЗВЕСТНО"
    report_info "$(printf '%s' "$GITERR" | head -1 | cut -c1-110)"
    report_info "причина: каталог принадлежит другому пользователю, а агент запущен от $(id -un)"
    report_proof "git -C $PATH_ rev-parse --verify -q HEAD"
    GIT_UNSAFE=1
  else
    BR=$(git -C "$PATH_" rev-parse --abbrev-ref HEAD 2>/dev/null)
    DIRT=$(git -C "$PATH_" status --porcelain 2>/dev/null | wc -l)
    AHEAD=$(git -C "$PATH_" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    BEHIND=$(git -C "$PATH_" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    report_kv "ветка" "$BR"
    [[ "$DIRT" -eq 0 ]] && report_ok "дерево чистое" || report_warn "изменений: $DIRT"
    [[ "$AHEAD" -eq 0 ]] && report_ok "всё отправлено" || report_warn "не отправлено: $AHEAD"
    [[ "$BEHIND" -eq 0 ]] && report_ok "не отстаёт" || report_warn "отстаёт на $BEHIND коммитов"
    report_proof "git -C $PATH_ status --porcelain · rev-list --count @{u}..HEAD · HEAD..@{u}"
    report_section "🕐 ПОСЛЕДНИЕ КОММИТЫ"
    git -C "$PATH_" log -3 --format='  %h %ad %s' --date=short 2>/dev/null | cut -c1-96
  fi
else
  report_section "🐙 GIT"; report_warn "это не git-дерево"
fi

if [[ -n "$SERVICES" ]]; then
  report_section "⚙️ СЕРВИСЫ ПРОЕКТА"
  for s in $SERVICES; do
    ST=$(systemctl is-active "$s" 2>/dev/null)
    case "$ST" in active) printf '  ✅ %s\n' "$s" ;; *) printf '  🔴 %s (%s)\n' "$s" "${ST:-нет}" ;; esac
  done
fi

UNITS=$(systemctl list-units --all --plain --no-legend 2>/dev/null | awk '{print $1}' | grep -i "$SLUG" | head -6)
[[ -n "$UNITS" ]] && { report_section "🧩 ЮНИТЫ ПО ИМЕНИ"; echo "$UNITS" | sed 's/^/  /'; }

if command -v docker >/dev/null; then
  CONT=$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | grep -i "$SLUG" | head -8)
  if [[ -n "$CONT" ]]; then
    report_section "🐳 КОНТЕЙНЕРЫ"
    echo "$CONT" | while IFS='|' read -r n s; do
      case "$s" in Up*) printf '  ✅ %-34s %s\n' "$n" "$s" ;; *) printf '  ⛔ %-34s %s\n' "$n" "$s" ;; esac
    done
  fi
fi

ACTIONS=()
# Одна секция «что делать» на отчёт: подсказку про доступ добавляем в общий список, а не
# печатаем второй footer внутри ветки GIT.
[[ "${GIT_UNSAFE:-0}" == "1" ]] && ACTIONS+=(
  "git не читает дерево — починить доступ (идемпотентно): bash /opt/hermes/scripts/install-git-safety.sh"
  "после починки повторить: «статус проекта ${SLUG}»")
[[ "${DIRT:-0}" -gt 0 ]] && ACTIONS+=("в проекте есть незакоммиченные изменения — посмотреть diff перед любыми действиями")
[[ "${BEHIND:-0}" -gt 0 ]] && ACTIONS+=("проект отстаёт на ${BEHIND} коммитов — обновление согласовать с владельцем проекта")
ACTIONS+=("спросить агента по смыслу: «почему проект ${SLUG} тормозит» (ответит модель по фактам)")
report_footer "${ACTIONS[@]}"
