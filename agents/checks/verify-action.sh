#!/usr/bin/env bash
# verify-action.sh — «действие сработало?»: проверка результата тем, кто его не выполнял.
#
# Зачем: результат действия раньше подтверждал сам act.sh сразу после выполнения («стало:
# active»). Если юнит через минуту упал снова, в чате оставалось «перезапущен ✅».
# Здесь состояние проверяется ПОСЛЕ, по журналу прогонов, и вердикт выносится заново.
# ARG_TARGET — юнит/контейнер, ARG_ACTION — необязательно (иначе берём последнее из истории).
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
TARGET="${ARG_TARGET:-${ARG_NAME:-}}"
ACTION="${ARG_ACTION:-}"
HIST="${HERMES_HISTORY_FILE:-/var/lib/hermes-agents/history.jsonl}"

report_header "🔁 ПРОВЕРКА ДЕЙСТВИЯ ${ACTION:+$ACTION }${TARGET:-?}"

if [[ -z "$TARGET" ]]; then
  report_unknown "не назван объект проверки"
  report_footer "пример: «проверь, сработал ли перезапуск octopus-browser»"
  exit 0
fi

# ── 1. что вообще делали с этим объектом (из истории прогонов) ─────────────────
REC="{}"
if [[ -s "$HIST" ]]; then
  REC="$(HIST_FILE="$HIST" NAME="$TARGET" python3 - <<'PY'
import json, os
name = os.environ["NAME"].lower()
last = None
try:
    with open(os.environ["HIST_FILE"], encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if name in json.dumps(r, ensure_ascii=False).lower() and \
                    r.get("handler") in ("act", "run", "restart", "start"):
                last = r
except OSError:
    pass
print(json.dumps(last or {}, ensure_ascii=False))
PY
)"
  if [[ -n "$REC" && "$REC" != "{}" ]]; then
    report_section "📜 ЧТО ДЕЛАЛИ"
    printf '%s\n' "$REC" | python3 - <<'PY'
import json, sys
r = json.loads(sys.stdin.read() or "{}")
slot = r.get("args") or {}
det = " ".join(f"{k}={v}" for k, v in slot.items() if k in ("action", "target", "n", "days"))
print("  когда            " + str(r.get("ts", "")))
print("  действие         act." + str(r.get("handler", "")) + " (код " + str(r.get("code")) + ")")
if det:
    print("  параметры        " + det)
print("  тогда ответил    " + str((r.get("summary") or ""))[:110])
print("  журнал           " + str(r.get("log", "")))
PY
    report_proof "grep -i «$TARGET» $HIST"
  else
    report_unknown "в истории нет действий с «$TARGET»"
    report_proof "grep -i $TARGET $HIST"
  fi
else
  report_unknown "история прогонов ещё не создана"
fi

# ── 2. состояние сейчас ───────────────────────────────────────────────────────
VERDICT="неизвестно"
report_section "📊 СОСТОЯНИЕ СЕЙЧАС"
UNIT="${TARGET%.service}.service"
if systemctl list-unit-files "$UNIT" --no-legend 2>/dev/null | grep -q .; then
  NOW="$(systemctl is-active "$UNIT" 2>/dev/null)"
  SINCE="$(systemctl show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null)"
  report_kv "юнит" "$UNIT"
  report_kv "состояние" "$NOW"
  report_kv "активен с" "${SINCE:-—}"
  report_proof "systemctl is-active $UNIT · show -p ActiveEnterTimestamp"
  if [[ "$NOW" == "active" ]]; then VERDICT="подтверждено"; else VERDICT="не подтверждено"; fi
  if [[ "$NOW" != "active" ]]; then
    report_section "📜 ПРИЧИНА"
    journalctl -u "$UNIT" -n 8 --no-pager -o cat 2>/dev/null | cut -c1-130 | sed 's/^/  /'
  fi
elif command -v docker >/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$TARGET"; then
  STATUS="$(docker ps -a --filter "name=^${TARGET}$" --format '{{.Status}}' 2>/dev/null | head -1)"
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$TARGET" 2>/dev/null)"
  UPTIME="$(docker inspect -f '{{.State.StartedAt}}' "$TARGET" 2>/dev/null | cut -c1-19)"
  report_kv "контейнер" "$TARGET"
  report_kv "состояние" "$STATUS"
  report_kv "health" "$HEALTH"
  report_kv "запущен с" "$UPTIME"
  report_proof "docker ps --filter name=^$TARGET$ · docker inspect -f .State.Health.Status"
  if [[ "$STATUS" == Up* && "$HEALTH" != "unhealthy" ]]; then VERDICT="подтверждено"
  else VERDICT="не подтверждено"; fi
else
  report_unknown "«$TARGET» сейчас нет среди юнитов и контейнеров"
  report_proof "systemctl list-unit-files · docker ps -a"
fi

# ── 3. вердикт ────────────────────────────────────────────────────────────────
report_section "📈 ВЕРДИКТ"
case "$VERDICT" in
  "подтверждено")
    report_ok "действие с объектом «$TARGET» подтверждено: он работает сейчас"
    report_footer "если поведение всё равно неправильное — «что с процессом $TARGET» покажет детали"
    ;;
  "не подтверждено")
    report_bad "действие НЕ подтверждено: «$TARGET» не работает"
    report_footer "смотреть причину выше — повторный перезапуск без разбора не поможет" \
                  "история: «что делали агенты» покажет, падал ли он раньше"
    ;;
  *)
    report_unknown "подтвердить нечем: объект не найден ни как юнит, ни как контейнер"
    report_footer "проверить имя: «что там с $TARGET» покажет, что вообще есть на узле"
    ;;
esac
