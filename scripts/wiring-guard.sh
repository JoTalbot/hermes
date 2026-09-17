#!/usr/bin/env bash
# wiring-guard.sh — разводка агентов не должна «дрейфовать» молча.
#
# FACT (2026-09-17): контейнер-копия проекта изменил discovery, конфигурация 21 агента уехала
# в DRIFT, doctor стал DEGRADED — и никто об этом не узнал, пока не посмотрел руками. Сторож
# проверяет разводку каждые 30 минут: при дрейфе пересобирает её (это идемпотентно) и пишет
# запись в журнал узла, чтобы факт «кто-то поправил конфиги» не потерялся.
#
#   bash scripts/wiring-guard.sh            # проверить и починить
#   bash scripts/wiring-guard.sh --check    # WIRING-GUARD: OK / DRIFT (только проверка)
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
STATE="${HERMES_GUARD_STATE:-/var/lib/hermes-bus/wiring-guard.json}"
MODE="${1:-apply}"
export HERMES_ACTOR="${HERMES_ACTOR:-wiring-guard}"

out="$(bash "$REPO_DIR/scripts/wire-agents.sh" --check 2>&1 | tail -1)"
drift=0
case "$out" in
  *DRIFT*) drift=1 ;;
esac

if [[ "$MODE" == "--check" ]]; then
  [[ $drift -eq 0 ]] && { echo "WIRING-GUARD: OK"; exit 0; }
  echo "WIRING-GUARD: DRIFT ($out)"; exit 1
fi

repaired=0
if (( drift == 1 )); then
  echo "  ⚠️ $out"
  written="$(bash "$REPO_DIR/scripts/wire-agents.sh" 2>&1 | tail -1)"
  echo "  🔧 $written"
  repaired=1
  if [[ -f "$REPO_DIR/agents/checks/lib/journal.sh" ]]; then
    ( source "$REPO_DIR/agents/checks/lib/journal.sh"
      journal_write node change "разводка агентов пересобрана автоматически: $out" )
  fi
else
  echo "  ✅ разводка в порядке"
fi

mkdir -p "$(dirname "$STATE")" 2>/dev/null
python3 - "$STATE" "$drift" "$repaired" <<'PY'
import json, sys, time
state, drift, repaired = sys.argv[1:4]
json.dump({"ts": int(time.time()), "drift": int(drift), "repaired": int(repaired)},
          open(state, "w"), ensure_ascii=False, indent=1)
PY
