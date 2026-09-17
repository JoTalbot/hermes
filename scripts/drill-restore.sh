#!/usr/bin/env bash
# drill-restore.sh — учение по восстановлению: бэкап → распаковка в отдельный каталог → проверка.
#
# Зачем (пункт 3 владельца, 2026-09-17): дрилл 2026-09-17 вскрыл четыре молчаливых дефекта, но
# делался руками и однажды. Теперь он автоматический (таймер раз в месяц) и результат приходит
# владельцу в Telegram: «восстановление PLAUSIBLE» или «НЕ ВОССТАНОВИЛОСЬ, вот почему».
#
# ЧТО ИМЕННО ПРОВЕРЯЕТСЯ (и чего нет — честно):
#   есть: архив цел, состояние из него РАЗВОРАЧИВАЕТСЯ (тот же разбор пути, что в restore.sh),
#         ключевые файлы на месте (config.yaml, канбан, память, профили, allowlist чата, конфиг
#         узла), restore.sh отказывается затирать непустой каталог без --force, время и размер.
#   нет:  поднятие юнитов systemd и живая работа восстановленного узла — это отдельный дрилл на
#         чужом хосте (node-arm-03), потому что делать это на проде нельзя.
#
#   bash scripts/drill-restore.sh            # учение + уведомление владельцу
#   bash scripts/drill-restore.sh --no-notify
#   bash scripts/drill-restore.sh --keep     # оставить распакованное для разбора
#   bash scripts/drill-restore.sh --check    # когда было последнее учение и чем кончилось
set -uo pipefail
REPO_DIR="${REPO_DIR:-/opt/hermes}"
BACKUP_DIR="${HERMES_BACKUP_DIR:-/var/backups/hermes}"
STATE_FILE="${HERMES_DRILL_STATE:-/var/lib/hermes-bus/restore-drill.json}"
SCRATCH_BASE="${HERMES_DRILL_ROOT:-/var/tmp}"
NOTIFY=1; KEEP=0; CHECK=0
for a in "$@"; do
  [[ "$a" == "--no-notify" ]] && NOTIFY=0
  [[ "$a" == "--keep" ]] && KEEP=1
  [[ "$a" == "--check" ]] && CHECK=1
done
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

if [[ $CHECK -eq 1 ]]; then
  if [[ -s "$STATE_FILE" ]]; then
    python3 - "$STATE_FILE" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8"))
age = (time.time() - float(d.get("ts") or 0)) / 3600
print(f"RESTORE-DRILL: {'OK' if d.get('ok') else 'FAILED'} · последнее учение "
      f"{age:.1f} ч назад · файлов {d.get('files')} · {d.get('seconds')} с · архив {d.get('archive')}")
for r in (d.get("problems") or [])[:5]:
    print(f"  ⚠️ {r}")
PY
  else
    echo "RESTORE-DRILL: учений не было ($STATE_FILE отсутствует)"
  fi
  exit 0
fi

echo "=== учение по восстановлению $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
PROBLEMS=()
ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  ARCHIVE="$(ls -1t "$BACKUP_DIR"/hermes-state-*.tar.gz 2>/dev/null | head -1)"
fi
if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  bad "нет архива бэкапа в $BACKUP_DIR — восстанавливать нечего"
  python3 - "$STATE_FILE" <<PY
import json, os, time
os.makedirs(os.path.dirname("$STATE_FILE"), exist_ok=True)
json.dump({"ts": int(time.time()), "ok": False, "archive": "", "files": 0, "seconds": 0,
           "problems": ["нет архива бэкапа: $BACKUP_DIR пуст"]},
          open("$STATE_FILE", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
  exit 1
fi

SIZE_MB=$(( $(stat -c %s "$ARCHIVE") / 1048576 ))
ok "архив: $(basename "$ARCHIVE") · ${SIZE_MB} MB"

# Место: распаковка занимает примерно вдвое больше архива; на узле диск — узкое место.
FREE_MB=$(( $(df -Pm "$SCRATCH_BASE" | awk 'NR==2 {print $4}') ))
if (( FREE_MB < SIZE_MB * 3 + 200 )); then
  bad "мало места в $SCRATCH_BASE: свободно ${FREE_MB} MB при архиве ${SIZE_MB} MB"
  PROBLEMS+=("мало места: ${FREE_MB} MB")
else
  ok "место под распаковку: ${FREE_MB} MB свободно"
fi

# 1. Проверка архива теми же глазами, что и штатный верификатор бэкапа.
if [[ -x "$REPO_DIR/scripts/verify-backup.sh" ]]; then
  VB="$(bash "$REPO_DIR/scripts/verify-backup.sh" "$ARCHIVE" 2>&1 | tail -3)"
  if printf '%s' "$VB" | grep -q 'RESTORE VERIFICATION OK'; then
    ok "архив: целостность и содержимое подтверждены verify-backup.sh"
  else
    bad "verify-backup.sh не подтвердил архив: $(printf '%s' "$VB" | tail -1 | cut -c1-80)"
    PROBLEMS+=("verify-backup.sh: $(printf '%s' "$VB" | tail -1 | cut -c1-80)")
  fi
fi

# 2. Распаковка в отдельный каталог — тем же способом, каким это делает restore.sh.
SCRATCH="$(mktemp -d "$SCRATCH_BASE/hermes-drill-XXXXXX")"
START=$(date +%s)
tar -xzf "$ARCHIVE" -C "$SCRATCH" || { bad "архив не распаковался"; PROBLEMS+=("tar: распаковка не удалась"); }
WANT="hermes"
if [[ -x "$REPO_DIR/scripts/restore.sh" ]]; then
  CANDIDATE=""
  while IFS= read -r d; do
    for marker in profiles kanban memories config.yaml; do
      if [[ -e "$d/$marker" ]]; then CANDIDATE="$d"; break 2; fi
    done
  done < <(find "$SCRATCH" -type d -name "$WANT" 2>/dev/null; find "$SCRATCH" -mindepth 1 -maxdepth 3 -type d 2>/dev/null)
  if [[ -n "$CANDIDATE" ]]; then
    FILES="$(find "$CANDIDATE" -type f 2>/dev/null | wc -l)"
    ok "состояние найдено в архиве: ${CANDIDATE#$SCRATCH/} · файлов $FILES"
  else
    FILES=0
    bad "в архиве нет каталога вида hermes-home — restore.sh на этом бы упал"
    PROBLEMS+=("структура архива: нет каталога состояния")
  fi
else
  FILES="$(find "$SCRATCH" -type f 2>/dev/null | wc -l)"
  warn "restore.sh не найден рядом — считаю распакованные файлы как есть: $FILES"
fi

# 3. Ключевые вещи, без которых восстановление бессмысленно.
# FACT (2026-09-17): без -maxdepth и без ограничения в 4 уровня — состояние лежит как
# home/hermes/.hermes/memories/MEMORY.md, то есть на пятом уровне, и первый прогон дрилла
# объявил память отсутствующей (ложная тревога самого дрилла).
check_in() {  # check_in <что> <шаблон поиска>
  local label="$1" pattern="$2"
  if find "$SCRATCH" -name "$pattern" -print -quit 2>/dev/null | grep -q .; then
    ok "$label"
  else
    bad "$label — НЕ найден в архиве"
    PROBLEMS+=("нет в архиве: $label ($pattern)")
  fi
}
check_in "config.yaml (настройки Hermes)" "config.yaml"
check_in "канбан (kanban.db)" "kanban.db"
check_in "память (MEMORY.md)" "MEMORY.md"
if find "$SCRATCH" -type d -name memories -print -quit 2>/dev/null | grep -q .; then
  ok "каталоги памяти профилей (memories/)"
else
  bad "каталоги памяти профилей (memories/) — НЕ найдены"
  PROBLEMS+=("нет в архиве: памяти профилей (memories/)")
fi

# Конфиг узла лежит в ОТДЕЛЬНОМ архиве hermes-nodecfg-*.tar.gz (см. scripts/backup.sh).
# Без allowlist восстановленный узел игнорировал бы владельца — это проверяется отдельно.
NODECFG="$(ls -1t "$BACKUP_DIR"/hermes-nodecfg-*.tar.gz 2>/dev/null | head -1)"
if [[ -n "$NODECFG" ]]; then
  NC_LIST="$(tar -tzf "$NODECFG" 2>/dev/null || true)"
  if grep -q 'telegram.chats.json' <<<"$NC_LIST"; then
    ok "allowlist чата в архиве конфига узла ($(basename "$NODECFG")) — бот узнает владельца"
  else
    bad "в архиве конфига узла нет telegram.chats.json — восстановленный бот игнорирует владельца"
    PROBLEMS+=("allowlist чата отсутствует в $NODECFG")
  fi
  if grep -qE 'hermes-bus/(tg-offset|alert-state|nodes|rooms)\.json' <<<"$NC_LIST"; then
    ok "состояние шины (tg-offset/alert-state/узлы) в архиве конфига узла"
  else
    warn "состояние шины в архиве конфига узла не найдено — смещение Telegram и дедуп алертов придётся задать заново"
    PROBLEMS+=("нет состояния шины в $NODECFG")
  fi
  NC_AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$NODECFG") ) / 3600 ))
  AR_AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$ARCHIVE") ) / 3600 ))
  if (( NC_AGE_H > AR_AGE_H + 26 )); then
    warn "архив конфига узла старше архива состояния на $((NC_AGE_H - AR_AGE_H)) ч — проверьте шаг «nodecfg» в scripts/backup.sh"
    PROBLEMS+=("архив конфига узла отстаёт на $((NC_AGE_H - AR_AGE_H)) ч")
  fi
else
  bad "архива конфига узла ($BACKUP_DIR/hermes-nodecfg-*.tar.gz) нет — узел восстановится без allowlist и состояния шины"
  PROBLEMS+=("нет архива hermes-nodecfg-*.tar.gz")
fi

# 4. Свойство безопасности: restore.sh не должен затирать непустой каталог без --force.
if [[ -x "$REPO_DIR/scripts/restore.sh" ]]; then
  GUARD="$(HERMES_HOME="$SCRATCH/guard-home" bash -c "mkdir -p \"\$HERMES_HOME\"; touch \"\$HERMES_HOME/keep\"; HERMES_HOME=\"\$HERMES_HOME\" bash '$REPO_DIR/scripts/restore.sh' '$ARCHIVE' 2>&1 | tail -2" 2>&1)"
  if printf '%s' "$GUARD" | grep -q 'REFUSING'; then
    ok "restore.sh отказывается затирать непустой каталог без --force (защита работает)"
  else
    bad "restore.sh НЕ отказался затирать непустой каталог — проверьте защиту"
    PROBLEMS+=("restore.sh не отказал на непустом каталоге")
  fi
fi

SECONDS_TAKEN=$(( $(date +%s) - START ))
rm -f "$SCRATCH/guard-home/keep" 2>/dev/null
if [[ $KEEP -eq 1 ]]; then
  warn "распакованное оставлено для разбора: $SCRATCH"
else
  rm -rf "$SCRATCH"
fi

if (( ${#PROBLEMS[@]} == 0 )); then
  VERDICT="PLAUSIBLE"; OKJSON="true"
  ok "DRILL: PLAUSIBLE — состояние из свежего бэкапа разворачивается, ключевые файлы на месте"
else
  VERDICT="FAILED"; OKJSON="false"
  bad "DRILL: FAILED — ${#PROBLEMS[@]} проблем(ы)"
fi

python3 - "$STATE_FILE" "$ARCHIVE" "$FILES" "$SECONDS_TAKEN" "$OKJSON" "${PROBLEMS[@]:-}" <<'PY'
import json, os, sys, time
state, archive, files, seconds, ok, *problems = sys.argv[1:]
os.makedirs(os.path.dirname(state), exist_ok=True)
json.dump({"ts": int(time.time()), "ok": ok == "true", "archive": os.path.basename(archive),
           "files": int(files or 0), "seconds": int(seconds or 0),
           "scratch": os.environ.get("HERMES_DRILL_LAST", ""),
           "problems": [p for p in problems if p]},
          open(state, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"  ↳ состояние учения: {state}")
PY

if [[ $NOTIFY -eq 1 ]]; then
  ICON=$([[ "$OKJSON" == "true" ]] && echo "🧪" || echo "🔴")
  MSG="$ICON Учение по восстановлению: $VERDICT
архив: $(basename "$ARCHIVE") (${SIZE_MB} MB) · файлов $FILES · $SECONDS_TAKEN с"
  if (( ${#PROBLEMS[@]} > 0 )); then
    MSG+=$'\n'"проблемы:"
    for p in "${PROBLEMS[@]}"; do MSG+=$'\n'"  • $p"; done
  fi
  MSG+=$'\n'"подробнее: bash scripts/drill-restore.sh --check · отчёт: bash agents/checks/models.sh"
  if [[ -x "$REPO_DIR/.venv-bus/bin/python" ]]; then
    "$REPO_DIR/.venv-bus/bin/python" - "$MSG" <<'PY' 2>&1 | tail -2
import sys
sys.path.insert(0, "/opt/hermes")
sys.path.insert(0, "/opt/hermes/bus")
try:
    import bus_bridge as m
    ok, info = m.tg_send(sys.argv[1], force=True)
    print(("  уведомление отправлено: " if ok else "  уведомление НЕ ушло: ") + str(info))
except Exception as e:
    print(f"  уведомление не отправлено: {type(e).__name__}: {e}")
PY
  else
    warn "нет venv шины — уведомление не отправлено"
  fi
fi

exit $([[ "$OKJSON" == "true" ]] && echo 0 || echo 1)
