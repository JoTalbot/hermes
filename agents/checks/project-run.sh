#!/usr/bin/env bash
# agents/checks/project-run.sh — реальные действия в проекте, а не разговоры о нём.
#
# Зачем: у проектного агента было только «покажи статус». Владелец спрашивал «почему тесты
# падают», а получал дамп дерева. Здесь агент реально запускает проверки проекта.
#
# Что можно: tests, build, lint, logs, deploy-check.
#   1) Команда НЕ угадывается: она берётся из маркеров самого проекта (Makefile-цель,
#      npm-скрипт, pytest-конфиг, go.mod, Cargo.toml, compose-файл). Если ни одного
#      маркера нет — честный отказ со списком того, что искали.
#   2) deploy-check НИЧЕГО не разворачивает. Это dry-run: показать, что было бы запущено.
#   3) Никогда не выполняется eval и не подставляются строки из задачи в shell.
#   4) Ограничение по времени и хвост вывода: длинный лог не должен ломать сообщение.
#   5) PROJECT_RUN_DRY=1 — только показать найденную команду (используется в тестах).
#
# Переменные: PROJECT_SLUG, PROJECT_PATH, PROJECT_REPO, PROJECT_SERVICE, PROJECT_CONTAINERS,
#             PROJECT_DEPLOY (из YAML агента), ARG_WHAT (tests|build|lint|logs|deploy-check).
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
# shellcheck source=lib/journal.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/journal.sh"

SLUG="${PROJECT_SLUG:-project}"
P_="${PROJECT_PATH:-}"
WHAT="${ARG_WHAT:-${ARG_ACTION:-tests}}"
DRY="${PROJECT_RUN_DRY:-0}"
RUN_TIMEOUT="${PROJECT_RUN_TIMEOUT:-300}"
TAIL_LINES="${PROJECT_RUN_TAIL:-25}"

case "$WHAT" in
  tests)        TITLE="ТЕСТЫ" ;;
  build)        TITLE="СБОРКА" ;;
  lint)         TITLE="ЛИНТ" ;;
  logs)         TITLE="ЛОГИ" ;;
  deploy-check) TITLE="ПРОВЕРКА ДЕПЛОЯ (dry-run)" ;;
  *)            TITLE="$WHAT" ;;
esac

report_header "🛠 ПРОЕКТ ${SLUG}: ${TITLE}"

if [[ "$WHAT" != "tests" && "$WHAT" != "build" && "$WHAT" != "lint" && \
      "$WHAT" != "logs" && "$WHAT" != "deploy-check" ]]; then
  report_section "❓ ЧТО ПРОСИЛИ"
  report_bad "«${WHAT}» — неизвестное действие"
  report_info "разрешено: tests, build, lint, logs, deploy-check"
  report_footer "скажи, например: «прогони тесты в ${SLUG}»"
  exit 2
fi

if [[ -z "$P_" || ! -d "$P_" ]]; then
  report_section "📁 КАТАЛОГ"
  report_bad "не найден: ${P_:-путь не задан}"
  report_info "репозиторий: ${PROJECT_REPO:-неизвестен}"
  report_footer "запускать нечего: каталога проекта нет на этом сервере" \
                "скажи «клонируй ${SLUG}» — склонирую репозиторий заново"
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Makefile: цель объявлена и make умеет её разобрать (без выполнения).
make_target() {
  local target="$1"
  [[ -f "$P_/Makefile" || -f "$P_/makefile" || -f "$P_/GNUmakefile" ]] || return 1
  ( cd "$P_" && timeout 20 make -n "$target" >/dev/null 2>&1 )
}

# package.json: нужен именно объявленный скрипт, а не «npm умеет тесты вообще».
npm_script() {
  [[ -f "$P_/package.json" ]] || return 1
  python3 - "$P_/package.json" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        scripts = (json.load(fh) or {}).get("scripts") or {}
except Exception:
    sys.exit(1)
sys.exit(0 if sys.argv[2] in scripts else 1)
PY
}

# Интерпретатор проекта важнее системного: в проектах лежат свои venv (FACT 2026-09-17:
# ни pytest, ни ruff в системе не установлены, а у madworld есть .venv — проверять надо
# тем питоном, которым проект и пользуется).
project_python() {
  local cand
  for cand in .venv/bin/python venv/bin/python env/bin/python; do
    [[ -x "$P_/$cand" ]] && { echo "$P_/$cand"; return 0; }
  done
  have python3 && { command -v python3; return 0; }
  return 1
}

py_has() {  # py_has <интерпретатор> <модуль>
  local py="$1" mod="$2"
  [[ -n "$py" ]] && "$py" -c "import $mod" >/dev/null 2>&1
}

# Маркеры тестов: конфиг pytest или каталог с test_*.py. Наличие tests/ без тестов —
# не повод запускать «pytest» наугад.
py_test_marker() {
  [[ -f "$P_/pytest.ini" || -f "$P_/tox.ini" ]] && return 0
  grep -qs '\[tool.pytest' "$P_/pyproject.toml" 2>/dev/null && return 0
  grep -qs '\[tool:pytest\]' "$P_/setup.cfg" 2>/dev/null && return 0
  local d
  for d in tests test; do
    [[ -d "$P_/$d" ]] && find "$P_/$d" -maxdepth 2 -name 'test_*.py' -o -maxdepth 2 -name '*_test.py' \
      2>/dev/null | head -1 | grep -q . && return 0
  done
  return 1
}

compose_file() {
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f "$P_/$f" ]] && { echo "$P_/$f"; return 0; }
  done
  return 1
}

# Найденная команда печатается в stdout как «cmd|обоснование». Пусто = нечего запускать.
detect() {
  case "$WHAT" in
    tests)
      make_target test  && { echo "make test|цель test в Makefile"; return; }
      make_target tests && { echo "make tests|цель tests в Makefile"; return; }
      npm_script test   && { echo "npm run --silent test|скрипт test в package.json"; return; }
      # shell-раннер тестов: своя конвенция репозитория (tests/run.sh) — команда видна
      # в самом проекте и не требует догадок про язык.
      for r in tests/run.sh test.sh run_tests.sh; do
        if [[ -f "$P_/$r" ]]; then
          echo "bash $r|в проекте есть собственный раннер тестов"; return
        fi
      done
      if py_test_marker; then
        PY="$(project_python)"
        if [[ -n "$PY" && -x "$(dirname "$PY")/pytest" ]]; then
          echo "$(dirname "$PY")/pytest -q|pytest из окружения проекта"
        elif py_has "$PY" pytest; then
          echo "${PY} -m pytest -q|найдены тесты и установленный pytest"
        elif [[ -n "$PY" ]]; then
          echo "!нет pytest|в проекте есть тесты, но в ${PY} нет pytest"
        fi
        return
      fi
      [[ -f "$P_/go.mod" ]] && have go && { echo "go test ./...|модуль go.mod"; return; }
      [[ -f "$P_/Cargo.toml" ]] && have cargo && { echo "cargo test|манифест Cargo.toml"; return; }
      ;;
    build)
      make_target build && { echo "make build|цель build в Makefile"; return; }
      npm_script build  && { echo "npm run --silent build|скрипт build в package.json"; return; }
      [[ -f "$P_/go.mod" ]] && have go && { echo "go build ./...|модуль go.mod"; return; }
      [[ -f "$P_/Cargo.toml" ]] && have cargo && { echo "cargo build|манифест Cargo.toml"; return; }
      if [[ -f "$P_/pyproject.toml" || -f "$P_/setup.py" ]]; then
        PY="$(project_python)"
        if py_has "$PY" build; then echo "${PY} -m build|pyproject.toml в корне"; else
          echo "!нет пакета build|собирать нечем: в ${PY:-python3} нет модуля build"
        fi
        return
      fi
      ;;
    lint)
      make_target lint && { echo "make lint|цель lint в Makefile"; return; }
      npm_script lint  && { echo "npm run --silent lint|скрипт lint в package.json"; return; }
      PY="$(project_python)"
      for tool in ruff flake8; do
        if [[ -n "$PY" && -x "$(dirname "$PY")/$tool" ]]; then
          echo "$(dirname "$PY")/$tool check .|${tool} из окружения проекта"; return
        fi
        have "$tool" && { echo "$tool check .|${tool} установлен в системе"; return; }
      done
      ;;
  esac
}

detect_logs() {
  local compose svc unit logs
  if compose="$(compose_file)"; then
    svc="$(cd "$P_" && (docker compose config --services 2>/dev/null || true) | head -1)"
    # Имя сервиса приходит из файла проекта. В команду оно попадает только после проверки
    # по белому списку символов: иначе имя сервиса вида "x; rm -rf /" стало бы shell-кодом.
    if [[ "$svc" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]]; then
      echo "docker compose logs --tail=120 ${svc}|сервис ${svc} из $(basename "$compose")"; return
    fi
    [[ -n "$svc" ]] && { echo "!имя сервиса в compose-файле недопустимо: отказ|безопасность"; return; }
  fi
  if [[ -n "${PROJECT_SERVICE:-}" ]]; then
    unit="${PROJECT_SERVICE%% *}"
    echo "journalctl -u ${unit} -n 120 --no-pager|юнит ${unit} проекта"; return
  fi
  logs="$(find "$P_" -maxdepth 2 -name '*.log' -type f -size -50M 2>/dev/null | head -1)"
  if [[ -n "$logs" ]]; then
    printf -v q '%q' "$logs"      # путь с пробелами не должен стать двумя аргументами
    echo "tail -n 120 ${q}|найден файл журнала"
  fi
}

report_section "🔎 ЧТО НАШЁЛ"
report_kv "каталог" "$P_"
report_kv "просили" "$TITLE"
[[ -n "${PROJECT_REPO:-}" ]] && report_kv "репозиторий" "$PROJECT_REPO"

if [[ "$WHAT" == "deploy-check" ]]; then
  CMD=""
  if make_target deploy; then
    CMD="make -n deploy"; REASON="цель deploy в Makefile — будет показана, но не выполнена"
  elif compose_file >/dev/null; then
    CMD="docker compose config"; REASON="compose-файл проверяется на корректность, контейнеры не трогаем"
  elif [[ -n "${PROJECT_DEPLOY:-}" ]]; then
    CMD=""; REASON="объявленная команда деплоя: ${PROJECT_DEPLOY}"
  fi
  report_section "▶️ РЕЖИМ DRY-RUN"
  report_info "ничего не разворачивается: deploy-check только показывает план"
  if [[ -n "$REASON" ]]; then report_info "$REASON"; else
    report_warn "в проекте нет ни цели deploy, ни compose-файла — проверить нечего"
  fi
  if [[ -n "$CMD" ]]; then
    report_section "🔍 ЧТО ВЫПОЛНИТСЯ (если запустить по-настоящему)"
    if [[ "$DRY" == "1" ]]; then
      report_ok "$CMD (не запускалось: тестовый режим)"
      report_footer "dry-run: решение о настоящем деплое принимает владелец"
      exit 0
    fi
    OUT="$( cd "$P_" && timeout 60 bash -c "$CMD" 2>&1 )"; RC=$?
    printf '%s\n' "$OUT" | tail -"$TAIL_LINES" | sed 's/^/  /'
    report_kv "код возврата" "$RC"
    (( RC == 0 )) && report_ok "план деплоя читается без ошибок" || report_warn "план деплоя не разобрался (код $RC)"
  fi
  report_footer "настоящий деплой не выполнялся — это только проверка плана" \
                "если нужно развернуть по-настоящему, скажи это отдельно и явно"
  exit 0
fi

if [[ "$WHAT" == "logs" ]]; then
  FOUND="$(detect_logs)"
  if [[ "$FOUND" == '!имя сервиса'* ]]; then
    report_section "▶️ ЧТО ЗАПУСКАЮ"
    report_bad "сервис в compose-файле назван недопустимо — команду не выполняю"
    report_footer "приведи имя сервиса в docker-compose к обычному виду (буквы, цифры, _.-)"
    exit 0
  fi
  if [[ -z "$FOUND" ]]; then
    report_section "▶️ ЧТО ЗАПУСКАЮ"
    report_warn "источника журналов не нашёл: нет compose-файла, объявленного юнита и *.log"
    report_footer "уточнить, где проект пишет логи (compose, systemd-юнит или файл)"
    exit 0
  fi
  CMD="${FOUND%%|*}"; REASON="${FOUND#*|}"
else
  FOUND="$(detect)"
  if [[ -z "$FOUND" ]]; then
    report_section "▶️ ЧТО ЗАПУСКАЮ"
    report_warn "не нашёл, чем запускать «${WHAT}» в этом проекте"
    report_info "искал: цель $WHAT в Makefile · скрипт $WHAT в package.json · pytest · go.mod · Cargo.toml"
    report_footer "не угадываю команду: неверная команда в чужом репозитории хуже отказа" \
                  "добавь подтверждённую команду в config/agents/projects/${SLUG}.yaml" \
                  "или запусти вручную и скажи мне результат"
    exit 0
  fi
  if [[ "$FOUND" == '!нет'* ]]; then
    CMD=""; REASON="${FOUND#*|}"
    report_section "▶️ КОМАНДА"
    report_bad "не запускаю: ${REASON}"
    report_footer "инструмент можно доставить в окружение проекта" \
                  "для тестов: <интерпретатор> -m pip install pytest, затем повтори запрос" \
                  "не угадываю и не подменяю команду проекта"
    exit 0
  fi
  CMD="${FOUND%%|*}"; REASON="${FOUND#*|}"
fi

report_section "▶️ КОМАНДА"
report_kv "команда" "$CMD"
report_kv "почему" "$REASON"
report_kv "таймаут" "${RUN_TIMEOUT} с"

if [[ "$DRY" == "1" ]]; then
  report_ok "тестовый режим: команда найдена, но не выполнялась"
  report_footer "это проверка распознавания, а не прогон"
  exit 0
fi

report_section "📊 РЕЗУЛЬТАТ"
START=$(date +%s)
OUT="$( cd "$P_" && timeout "$RUN_TIMEOUT" bash -c "$CMD" 2>&1 )"; RC=$?
TOOK=$(( $(date +%s) - START ))

# Хвост и счётчики: по телефону читают конец лога, а не первые 25 строк.
TOTAL=$(printf '%s\n' "$OUT" | grep -c '' || true)
printf '%s\n' "$OUT" | tail -"$TAIL_LINES" | sed 's/^/  /'
[[ "$TOTAL" -gt "$TAIL_LINES" ]] && report_info "показаны последние $TAIL_LINES строк из $TOTAL"

report_section "📈 ИТОГ"
report_kv "код возврата" "$RC"
report_kv "время" "${TOOK} с"
if (( RC == 0 )); then
  report_ok "${TITLE}: успешно"
  journal_write "$SLUG" run "${TITLE}: успешно (${TOOK} с)"
  report_footer "ничего делать не нужно — результат выше"
elif (( RC == 124 )); then
  report_bad "${TITLE}: не уложилось в ${RUN_TIMEOUT} с и было остановлено"
  journal_write "$SLUG" incident "${TITLE}: таймаут ${RUN_TIMEOUT} с"
  report_footer "похоже, ${SLUG} ждёт внешний ресурс: проверить, что ${WHAT} не требует сети" \
                "таймаут можно поднять в config/agents/projects/${SLUG}.yaml"
else
  report_bad "${TITLE}: ошибка (код $RC)"
  journal_write "$SLUG" incident "${TITLE}: код $RC в ${TOOK} с"
  FAILED_LINE="$(printf '%s\n' "$OUT" | grep -m1 -iE 'fail|error|ошибк' | cut -c1-120)"
  [[ -n "$FAILED_LINE" ]] && report_info "первое сообщение об ошибке: ${FAILED_LINE}"
  report_footer "разобрать последние строки выше — это вывод самого проекта, не агента" \
                "спроси меня «почему падают тесты в ${SLUG}» — разберу вывод моделью"
fi
