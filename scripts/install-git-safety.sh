#!/usr/bin/env bash
# scripts/install-git-safety.sh — чтобы агенты действительно читали состояние репозиториев.
#
# FACT (2026-09-17): 14 из 21 проектных агентов не могли прочитать git-состояние своего
# проекта. Причина не в правах: каталоги принадлежат другим пользователям (ubuntu, opc),
# а агенты работают под root, и git по умолчанию отказывается работать с «чужим» деревом
# («detected dubious ownership»). Все команды возвращали пустоту, а отчёт при этом печатал
# «дерево чистое, всё отправлено» — агент утверждал, что проверил, ничего не прочитав.
#
# Что делает: добавляет КАЖДЫЙ путь проекта из config/agents/projects/*.yaml в
# safe.directory того пользователя, под которым работают агенты (и root как запасной).
# Идемпотентно, только добавление записей, никаких других изменений в git-конфиге.
#
#   bash scripts/install-git-safety.sh            # добавить недостающие записи
#   bash scripts/install-git-safety.sh --check    # проверить (tests/doctor), без изменений
set -uo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

# Пользователи берутся из юнитов, а не угадываются: агенты и экспортёр метрик читают git
# под разными аккаунтами, и «чужим» репозиторий оказывается для обоих.
unit_user() {
  local u; u="$(systemctl show -p User --value "$1" 2>/dev/null)"
  [[ -z "$u" || "$u" == "0" ]] && u=root
  echo "$u"
}
AGENT_USER="$(unit_user hermes-agents)"
USERS=("$AGENT_USER" "root")
METRICS_USER="$(unit_user hermes-metrics)"
for u in "$METRICS_USER"; do
  [[ " ${USERS[*]} " == *" $u "* ]] || USERS+=("$u")
done

paths() {
  python3 - "$REPO_DIR" <<'PY'
import glob, os, sys, yaml
root = sys.argv[1]
seen = []
for f in sorted(glob.glob(os.path.join(root, "config/agents/projects/*.yaml"))):
    try:
        d = yaml.safe_load(open(f)) or {}
    except Exception:
        continue
    p = (d.get("technology") or {}).get("local_path") or ""
    if p and os.path.isdir(os.path.join(p, ".git")) and p not in seen:
        seen.append(p)
print("\n".join(seen))
PY
}

run_as() {   # run_as <user> <git args...>
  local u="$1"; shift
  if [[ "$u" == "root" ]]; then git "$@"
  else sudo -u "$u" -H git "$@" 2>/dev/null; fi
}

check_one() {  # 0 — git читает репозиторий от лица $1
  local u="$1" p="$2"
  local out
  out="$(run_as "$u" -C "$p" rev-parse --verify -q HEAD 2>&1 >/dev/null)"
  [[ -z "$out" ]]
}

git_reason() {   # почему git отказал ("" если отказа не было)
  local u="$1" p="$2"
  run_as "$u" -C "$p" rev-parse --verify -q HEAD 2>&1 >/dev/null | head -1
}

is_access_problem() {   # 1 — это именно доступ/владелец, а не сломанный репозиторий
  grep -qiE "dubious ownership|permission denied|not owned" <<<"$1"
}

MODE="${1:-}"
ADDED=0; BROKEN=0; TOTAL=0
echo "=== git-доступ к проектам (пользователи: ${USERS[*]}) ==="
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  TOTAL=$((TOTAL + 1))
  if check_one "$AGENT_USER" "$p"; then
    [[ "$MODE" == "--check" ]] && ok "$p — читается"
    continue
  fi
  REASON="$(git_reason "$AGENT_USER" "$p")"
  if [[ "$MODE" == "--check" ]]; then
    if is_access_problem "$REASON"; then
      bad "$p — нет доступа (агент отчитается о несуществующей чистоте): ${REASON:0:60}"
      BROKEN=$((BROKEN + 1))
    else
      # Репозиторий сломан (например .git без HEAD): доступом это не лечится, но агент
      # обязан честно сказать «НЕИЗВЕСТНО» — это проверяет project-check.sh.
      warn "$p — git не читает, но причина не в доступе: ${REASON:0:60}"
    fi
    continue
  fi
  # Добавляем safe.directory для пользователя агентов и отдельно для root: разные пути
  # установки (systemd или nosystemd) используют разные аккаунты.
  for u in "${USERS[@]}"; do
    cur="$(run_as "$u" config --global --get-all safe.directory 2>/dev/null || true)"
    if ! grep -qxF "$p" <<<"$cur"; then
      run_as "$u" config --global --add safe.directory "$p"
      ADDED=$((ADDED + 1))
    fi
  done
  if check_one "$AGENT_USER" "$p"; then ok "$p — доступ выдан"
  elif is_access_problem "$(git_reason "$AGENT_USER" "$p")"; then
    bad "$p — доступ не выдан (разобрать вручную)"; BROKEN=$((BROKEN + 1))
  else
    warn "$p — репозиторий нечитаем по другой причине: $(git_reason "$AGENT_USER" "$p" | cut -c1-70)"
  fi
done < <(paths)

echo
if [[ "$MODE" == "--check" ]]; then
  echo "  репозиториев: $TOTAL · недоступных: $BROKEN"
  (( BROKEN == 0 )) && { echo "GIT-SAFETY: OK"; exit 0; }
  echo "GIT-SAFETY: FAIL ($BROKEN)"; exit 1
fi
echo "  репозиториев: $TOTAL · добавлено записей safe.directory: $ADDED · проблем: $BROKEN"
(( BROKEN == 0 )) && { echo "GIT-SAFETY: OK"; exit 0; }
echo "GIT-SAFETY: FAIL ($BROKEN)"; exit 1
