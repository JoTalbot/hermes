#!/usr/bin/env bash
# scripts/install-journal.sh — завести журнал каждому проекту (идемпотентно).
#
# Создаёт /opt/hermes/memory/projects/<slug>/JOURNAL.md для каждого проектного агента.
# Существующие журналы не трогает: история — не то, что перезаписывают.
#   bash scripts/install-journal.sh            # создать отсутствующие
#   bash scripts/install-journal.sh --check    # JOURNAL: OK / список отсутствующих
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
ROOT="$REPO_DIR/memory/projects"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
created=0; missing=0; present=0
for f in "$REPO_DIR"/config/agents/projects/*.yaml; do
  [[ -f "$f" ]] || continue
  slug="$(basename "$f" .yaml)"
  [[ "$slug" == "README" ]] && continue
  jf="$ROOT/$slug/JOURNAL.md"
  if [[ -s "$jf" ]]; then present=$((present+1)); continue; fi
  if (( CHECK )); then printf '  нет: %s\n' "$jf"; missing=$((missing+1)); continue; fi
  mkdir -p "$ROOT/$slug"
  {
    echo "# Журнал: $slug"
    echo
    echo "Строка на событие: \`дата · вид · кто · текст\`. Пишут действия (act.sh) и запуски"
    echo "(project-run.sh); проверки статуса сюда не пишут."
    echo
  } > "$jf"
  created=$((created+1))
done
# Журнал узла: действия, не относящиеся к конкретному проекту (prune, vacuum, рестарт стека).
if [[ ! -s "$ROOT/node/JOURNAL.md" && $CHECK -eq 0 ]]; then mkdir -p "$ROOT/node"; {
  echo "# Журнал: node"; echo
  echo "Действия по узлу целиком: очистка docker, сжатие журнала, рестарт сервисов Hermes."; echo
} > "$ROOT/node/JOURNAL.md"; fi
if (( CHECK )); then
  [[ $missing -eq 0 ]] && echo "JOURNAL: OK ($present журналов)" || echo "JOURNAL: FAIL ($missing отсутствуют)"
  (( missing == 0 ))
else
  echo "JOURNAL: создано $created, уже было $present"
fi
