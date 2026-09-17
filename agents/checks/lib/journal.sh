#!/usr/bin/env bash
# lib/journal.sh — «что в этом проекте уже происходило».
#
# Зачем: memory/projects/<slug>/ хранил факты (путь, ветка, риски), но не события.
# На вопрос «почему вчера трогали liza» системы не было: журналы прогонов лежат по
# агентам, а не по проектам. Теперь каждое действие и каждый прогон оставляют строку
# в JOURNAL.md самого проекта, и статус проекта показывает последние строки.
#
# Пишут только те, кто действительно что-то менял (act.sh, project-run.sh). Read-only
# проверки (project-check.sh) журнал ТОЛЬКО читают: иначе «посмотрел» выглядело бы как «сделал».
# shellcheck shell=bash

JOURNAL_ROOT="${HERMES_JOURNAL_ROOT:-/opt/hermes/memory/projects}"

# slug проекта по имени объекта: юнит, контейнер или путь. Сопоставление — по конфигам
# проектных агентов, а не по догадке: если имя не найдено, действие относится к узлу.
journal_slug_for() {
  local name="$1" f slug service containers path_
  [[ -n "$name" ]] || { echo ""; return 0; }
  for f in /opt/hermes/config/agents/projects/*.yaml; do
    [[ -f "$f" ]] || continue
    slug="$(basename "$f" .yaml)"
    # читаем только нужные ключи: полноценный YAML-парсер здесь не нужен и не всегда есть
    service="$(grep -E '^\s+service:' "$f" 2>/dev/null | head -1 | awk '{print $2}')"
    containers="$(grep -E '^\s+containers:' "$f" 2>/dev/null | head -1 | awk '{print $2}')"
    path_="$(grep -E 'local_path:' "$f" 2>/dev/null | head -1 | sed 's/.*local_path: *//; s/["'"'"']//g')"
    if [[ -n "$service" && ( " $service " == *" $name "* || "$name" == "${service%.service}" ) ]]; then
      echo "$slug"; return 0
    fi
    if [[ -n "$containers" && " $containers " == *" $name "* ]]; then
      echo "$slug"; return 0
    fi
    if [[ -n "$path_" && ( "$name" == "$(basename "$path_")" || "$path_" == *"/$name" ) ]]; then
      echo "$slug"; return 0
    fi
  done
  echo "node"     # действие не про конкретный проект — пишем в журнал узла
}

journal_file() { echo "${JOURNAL_ROOT}/$1/JOURNAL.md"; }

# journal_write <slug> <kind> <text...>
# kind: action | run | incident | decision | change
journal_write() {
  local slug="${1:-node}" kind="${2:-action}"; shift 2 || true
  local text="$*" file; file="$(journal_file "$slug")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  if [[ ! -s "$file" ]]; then
    {
      echo "# Журнал: ${slug}"
      echo
      echo "Строка на событие: \`дата · вид · кто · текст\`. Пишут действия (act.sh) и запуски"
      echo "(project-run.sh); проверки статуса сюда не пишут."
      echo
    } >> "$file"
  fi
  printf -- '- %s · %s · %s · %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$kind" \
    "${HERMES_ACTOR:-$(id -un)}" "$(printf '%s' "$text" | tr '\n' ' ' | cut -c1-300)" >> "$file" 2>/dev/null || return 0
  return 0
}

# journal_tail <slug> [n] — последние n записей (без заголовка), для отчётов.
journal_tail() {
  local slug="${1:-}" n="${2:-5}" file
  file="$(journal_file "$slug")"
  [[ -s "$file" ]] || return 0
  grep -E '^- ' "$file" 2>/dev/null | tail -"$n"
}
