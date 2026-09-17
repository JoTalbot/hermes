#!/usr/bin/env bash
# container-guard.sh — лимиты, которые владелец одобрил, не исчезают вместе с контейнером.
#
# FACT (2026-09-17): контейнер octopus-browser-chromium пересоздали, новый поднялся без
# лимита памяти (Memory=0), и защита, которую владелец одобрил, исчезла молча. `docker update`
# живёт на контейнере, а не на образе, поэтому любой перезапуск «с нуля» её снимает.
# Этот сторож раз в 15 минут сверяет желаемое с фактическим и возвращает лимит БЕЗ перезапуска
# (docker update меняет лимит на ходу), пишет в журнал узла и в состояние для метрик.
#
#   bash scripts/container-guard.sh            # проверить и восстановить
#   bash scripts/container-guard.sh --dry-run  # только показать расхождения
#   bash scripts/container-guard.sh --check    # тест/доктор: CONTAINER-GUARD: OK|DRIFT
#
# Желаемое берётся из /etc/hermes/container-limits.conf — файла, который правит владелец.
# Ничего своего сторож не выдумывает: нет строки в файле — нет претензий к контейнеру.
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
CONF="${HERMES_CONTAINER_LIMITS:-/etc/hermes/container-limits.conf}"
STATE="${HERMES_GUARD_STATE:-/var/lib/hermes-bus/container-guard.json}"
MODE="${1:-apply}"
export HERMES_ACTOR="${HERMES_ACTOR:-container-guard}"

to_bytes() {  # 8g / 512m / 1073741824
  local v="$1"; [[ -z "$v" ]] && { echo ""; return; }
  case "$v" in
    *[gG]) echo $(( ${v%[gG]} * 1024 * 1024 * 1024 )) ;;
    *[mM]) echo $(( ${v%[mM]} * 1024 * 1024 )) ;;
    *[kK]) echo $(( ${v%[kK]} * 1024 )) ;;
    *[0-9]) echo "$v" ;;
    *) echo "" ;;
  esac
}

if [[ ! -s "$CONF" ]]; then
  [[ "$MODE" == "--check" ]] && { echo "CONTAINER-GUARD: OK (нет файла лимитов — нечего охранять)"; exit 0; }
  echo "нет $CONF — охранять нечего"; exit 0
fi

COMMAND="$(command -v docker || true)"
if [[ -z "$COMMAND" ]]; then
  [[ "$MODE" == "--check" ]] && { echo "CONTAINER-GUARD: UNKNOWN (docker не установлен)"; exit 3; }
  echo "docker не установлен"; exit 3
fi

checked=0; drift=0; fixed=0; absent=0; DETAIL="[]"
while read -r name mem swap _rest; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  want_mem="$(to_bytes "$mem")"; want_swap="$(to_bytes "$swap")"
  [[ -n "$want_mem" ]] || continue
  checked=$((checked+1))
  if ! docker inspect "$name" >/dev/null 2>&1; then absent=$((absent+1)); continue; fi
  have_mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)"
  have_swap="$(docker inspect -f '{{.HostConfig.MemorySwap}}' "$name" 2>/dev/null || echo 0)"
  if [[ "$have_mem" == "$want_mem" && ( -z "$want_swap" || "$have_swap" == "$want_swap" ) ]]; then continue; fi
  drift=$((drift+1))
  echo "  ⚠️ $name: память $((have_mem/1048576))M → должно быть $((want_mem/1048576))M"
  DETAIL="$(python3 - "$DETAIL" "$name" "$have_mem" "$want_mem" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); d.append({"name": sys.argv[2], "have": int(sys.argv[3]), "want": int(sys.argv[4])})
print(json.dumps(d))
PY
)"
  if [[ "$MODE" == "--dry-run" ]]; then continue; fi
  ARGS=(--memory "${want_mem}")
  [[ -n "$want_swap" ]] && ARGS+=(--memory-swap "${want_swap}")
  if docker update "${ARGS[@]}" "$name" >/dev/null 2>&1; then
    NOW="$(docker inspect -f '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo 0)"
    if [[ "$NOW" == "$want_mem" ]]; then
      fixed=$((fixed+1)); echo "  ✅ $name: лимит восстановлен ($((want_mem/1073741824)) GiB)"
      # shellcheck source=/opt/hermes/agents/checks/lib/journal.sh
      [[ -f "$REPO_DIR/agents/checks/lib/journal.sh" ]] && \
        ( source "$REPO_DIR/agents/checks/lib/journal.sh"; journal_write node change \
          "восстановлен лимит памяти $name ($((want_mem/1073741824)) GiB) — кто-то поднял контейнер без него" )
    fi
  else
    echo "  ❌ $name: docker update не сработал"
  fi
done < "$CONF"

mkdir -p "$(dirname "$STATE")" 2>/dev/null
python3 - "$STATE" "$checked" "$drift" "$fixed" "$absent" "$MODE" "$DETAIL" <<'PY'
import json, sys, time
state, checked, drift, fixed, absent, mode, detail = sys.argv[1:8]
json.dump({"ts": int(time.time()), "checked": int(checked), "drift": int(drift),
           "fixed": int(fixed), "absent": int(absent), "mode": mode,
           "detail": json.loads(detail)}, open(state, "w"), ensure_ascii=False, indent=1)
PY

if [[ "$MODE" == "--check" ]]; then
  if (( drift > 0 && fixed == 0 )); then
    echo "CONTAINER-GUARD: DRIFT ($drift контейнер(ов) без одобренного лимита)"; exit 1
  fi
  echo "CONTAINER-GUARD: OK (проверено $checked, восстановлено $fixed, нет на узле $absent)"; exit 0
fi
echo "ПРОВЕРЕНО: $checked · расхождений: $drift · восстановлено: $fixed · нет на узле: $absent"
[[ $drift -eq 0 ]] && echo "все одобренные лимиты на месте"
