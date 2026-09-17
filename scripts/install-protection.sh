#!/usr/bin/env bash
# scripts/install-protection.sh — keep Hermes alive when the box runs out of memory.
#
# MEASURED PROBLEM (2026-09-17): one container belonging to another project
# (octopus-browser-chromium) held 16.6 of 23.4 GiB, swap was 100 % full and only 3.4 GiB was
# available. The Hermes units had OOMScoreAdjust=0 and no memory limit — i.e. the kernel was
# exactly as willing to kill nats-server or the agent runtime as it was to kill a browser
# tab. Losing the bus means losing the chat, the agents and the mirror at the same moment.
#
# WHAT THIS DOES (idempotent, reversible):
#   * OOMScoreAdjust=-800 for the infrastructure units (the kernel now prefers killing
#     anything else first),
#   * MemoryHigh (soft throttle) + MemoryMax (hard ceiling) per unit, sized ~4x above each
#     unit's measured usage — high enough never to interfere, low enough that a runaway
#     handler in one unit cannot take the whole box,
#   * --check mode for the test suite and the doctor, --revert to undo everything.
#
# It does NOT touch other projects' containers: their limits are the owner's call, and the
# alert rules (deploy/monitoring) report the pressure instead. A proposal with the exact
# command is printed at the end.
set -uo pipefail

ACTION="install"
case "${1:-}" in
  --check) ACTION="check" ;;
  --revert) ACTION="revert" ;;
esac

# unit:oom_score:memory_high:memory_max  (usage measured before choosing these)
UNITS=(
  "nats-server:-800:384M:768M"            # ~30 MiB used; the ceiling is for a JetStream burst
  "hermes-bus-bridge:-800:384M:768M"      # ~90 MiB
  "hermes-telegram-inbox:-800:256M:512M"  # ~60 MiB
  "hermes-agents:-800:1024M:2048M"        # ~250 MiB, but handlers run project tests inside
  "hermes-gateway:-700:768M:1536M"        # ~300 MiB
  "hermes-metrics:-700:256M:512M"         # ~40 MiB
  "hermes-shim:-700:256M:512M"            # ~40 MiB
  "hermes-serve:-600:1024M:2048M"         # dashboard, user-facing, gets restarted if it dies
)

GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

# Единожды прочитанный список юнитов: `systemctl ... | grep -q` под pipefail всегда ложь
# (grep выходит на первом совпадении, systemctl получает SIGPIPE), из-за чего исправные
# юниты выглядели как «не установлен».
UNIT_FILES="$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null || true)"
unit_exists() {
  grep -q "^$1.service" <<<"$UNIT_FILES" && return 0
  [[ -f "/etc/systemd/system/$1.service" ]] && return 0
  return 1
}

runtime_score() {   # effective OOMScoreAdjust of a running unit, -1 if not running
  local pid
  pid=$(systemctl show -p MainPID --value "$1" 2>/dev/null)
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    cat "/proc/$pid/oom_score" 2>/dev/null || echo -1
  else echo -1; fi
}

case "$ACTION" in
  check)
    FAILED=0
    echo "=== защита Hermes (память) ==="
    for row in "${UNITS[@]}"; do
      IFS=: read -r unit score high max <<< "$row"
      if ! unit_exists "$unit"; then
        warn "$unit не установлен (пропуск)"
        continue
      fi
      eff=$(systemctl show -p OOMScoreAdjust --value "$unit.service" 2>/dev/null)
      mh=$(systemctl show -p MemoryHigh --value "$unit.service" 2>/dev/null)
      mm=$(systemctl show -p MemoryMax --value "$unit.service" 2>/dev/null)
      if [[ "$eff" == "$score" && "$mh" != "infinity" && "$mm" != "infinity" ]]; then
        ok "$unit: OOM=$eff high=$mh max=$mm"
      else
        bad "$unit: OOM=$eff high=${mh:-?} max=${mm:-?} (ожидается OOM=$score, лимиты заданы)"
        FAILED=$((FAILED+1))
      fi
    done
    echo
    if (( FAILED == 0 )); then echo "PROTECTION: OK"; exit 0; fi
    echo "PROTECTION: FAIL ($FAILED юнитов)"; exit 1
    ;;

  revert)
    for row in "${UNITS[@]}"; do
      IFS=: read -r unit _ _ _ <<< "$row"
      rm -f "/etc/systemd/system/${unit}.service.d/10-memory.conf"
      rmdir "/etc/systemd/system/${unit}.service.d" 2>/dev/null
      echo "  снято с $unit"
    done
    systemctl daemon-reload
    echo "revert: drop-ins удалены (лимиты снимутся при следующем перезапуске юнитов)"
    ;;

  install)
    echo "=== 1. drop-ins (OOM-приоритет + лимиты памяти) ==="
    for row in "${UNITS[@]}"; do
      IFS=: read -r unit score high max <<< "$row"
      if ! unit_exists "$unit"; then
        warn "$unit не установлен (пропуск)"
        continue
      fi
      DIR="/etc/systemd/system/${unit}.service.d"
      install -d -m 0755 "$DIR"
      cat > "$DIR/10-memory.conf" <<EOF
# Managed by scripts/install-protection.sh — do not edit by hand.
# Rationale: when the box runs out of memory the kernel must not pick the agent bus.
[Service]
OOMScoreAdjust=${score}
MemoryHigh=${high}
MemoryMax=${max}
EOF
      ok "$unit: OOM=$score high=$high max=$max"
    done

    echo
    echo "=== 2. применение ==="
    systemctl daemon-reload
    # OOMScoreAdjust takes effect only at process start; memory limits are applied live for
    # running units where systemd allows it. Restarting the stack here would drop the bus for
    # a moment, so restarting is left to the owner's normal cycle — the values are already
    # effective for anything started later, including after a reboot.
    for row in "${UNITS[@]}"; do
      IFS=: read -r unit _ _ _ <<< "$row"
      systemctl show "$unit.service" -p OOMScoreAdjust --value 2>/dev/null | grep -q '^-' \
        || warn "$unit: значение применится при следующем запуске"
    done
    if unit_exists nats-server; then
      S=$(runtime_score nats-server)
      if [[ "$S" != "-1" ]]; then
        [[ "$S" -lt 200 ]] && ok "nats-server уже приоритетнее обычных процессов (oom_score=$S)" \
                          || warn "nats-server запущен до установки (oom_score=$S) — станет ниже после перезапуска"
      fi
    fi

    echo
    echo "=== 3. сколько памяти сейчас занимают чужие проекты ==="
    if command -v docker >/dev/null; then
      # Сортировка по РЕАЛЬНОЙ памяти: строку "16.6GiB / 23.4GiB" нельзя сортировать
      # лексикографически (иначе первым окажется случайный контейнер, как hermes-node-03).
      docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null | python3 -c "
import sys
def to_mib(text):
    num = text.strip().split()[0]
    for unit, mult in (('GiB', 1024), ('MiB', 1), ('KiB', 1/1024), ('B', 1/1048576)):
        if num.endswith(unit):
            try: return float(num[:-len(unit)]) * mult
            except ValueError: return 0.0
    return 0.0
rows = []
for line in sys.stdin:
    if '|' not in line: continue
    name, mem = line.rstrip('\n').split('|', 1)
    rows.append((to_mib(mem), name, mem))
rows.sort(reverse=True)
for mib, name, mem in rows[:4]:
    print(f'  {name:34s} {mem}')
if rows:
    print('__BIG__=' + rows[0][1])
" > /tmp/_mem_top.txt
      sed '/^__BIG__=/d' /tmp/_mem_top.txt
      BIG=$(sed -n 's/^__BIG__=//p' /tmp/_mem_top.txt)
      echo
      echo "  Если крупный контейнер мешает всей машине, ограничить его можно так"
      echo "  (это чужой проект — решение владельца, поэтому только подсказка):"
      echo "    docker update --memory 8g --memory-swap 8g ${BIG:-<контейнер>}"
    fi
    echo
    echo "Проверка: bash scripts/install-protection.sh --check"
    ;;
esac
