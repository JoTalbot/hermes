#!/usr/bin/env bash
# scripts/install-model-policy.sh — the model policy must exist, or the node must say so.
#
# WHY: agents/models.py has built-in defaults, so a node WITHOUT config/models.yaml looks
# perfectly healthy while quietly ignoring the owner's policy ("cheap by default, smart where
# it matters", escalation rules, per-agent tiers). That is the worst kind of gap: nothing
# breaks, the answers just get worse. FACT 2026-09-17: neither install.sh, bootstrap.sh nor
# install-agent-runtime.sh ever placed or verified this file, and `deploy.sh` skips
# `config/` unless it is named explicitly — so a node built by copying the runtime alone
# runs on defaults and reports OK.
#
#   bash scripts/install-model-policy.sh           # восстановить/проверить
#   bash scripts/install-model-policy.sh --check   # только проверка (tests, doctor)
set -uo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
POLICY="${HERMES_MODELS_FILE:-$REPO_DIR/config/models.yaml}"
GREEN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { printf '  %s✅%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$RED" "$RST" "$1"; }
warn() { printf '  %s⚠️%s %s\n' "$YLW" "$RST" "$1"; }

# Проверять надо тем же интерпретатором, что читает политику в рантайме: у системного
# python3 на свежем узле нет PyYAML, и проверка падала с «файл не читается», хотя файл цел
# (drill 2026-09-17). Порядок тот же, что у wire-agents.sh.
for cand in "${REPO_DIR}/.venv-bus/bin/python" /opt/hermes/.venv-bus/bin/python; do
  [[ -x "$cand" ]] && { PY="$cand"; break; }
done
PY="${PY:-$(command -v python3)}"

verify() {   # 0 — файл на месте и читается так, как его читает рантайм
  [[ -s "$POLICY" ]] || return 1
  "$PY" - "$POLICY" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("PyYAML нет у проверяющего интерпретатора — политика не проверена"); sys.exit(3)
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as e:
    print(f"YAML не разбирается: {type(e).__name__}: {e}"); sys.exit(4)
missing = [k for k in ("default", "agents", "escalate") if k not in d]
if missing:
    print("нет обязательных разделов: " + ", ".join(missing)); sys.exit(5)
print(f"тир по умолчанию: {d['default']} · агентов с тиром: {len(d.get('agents') or {})} · "
      f"эскалаций: {len(d.get('escalate') or {})}")
PY
}

case "${1:-}" in
  --check)
    echo "=== политика моделей ==="
    echo "  файл: $POLICY"
    if OUT="$(verify)"; then
      ok "$OUT"
      ok "sha256 $(sha256sum "$POLICY" | cut -c1-12)"
      echo; echo "MODEL-POLICY: OK"; exit 0
    fi
    RC=$?
    if [[ $RC -eq 3 ]]; then
      warn "$OUT (поставить: $PY -m pip install PyYAML)"
      echo; echo "MODEL-POLICY: UNKNOWN"; exit 0
    elif [[ $RC -eq 4 || $RC -eq 5 ]]; then
      bad "файл есть, но читается неверно: $OUT"
    else
      bad "файла нет: агенты молча работают на встроенных умолчаниях"
    fi
    echo "  починить: bash $REPO_DIR/scripts/install-model-policy.sh"
    echo; echo "MODEL-POLICY: FAIL"; exit 1
    ;;

  *)
    echo "=== 1. на месте ли политика моделей ==="
    if [[ -s "$POLICY" ]]; then
      ok "уже есть: $POLICY (не перезаписываю — это может быть правленая владельцем копия)"
    else
      warn "нет $POLICY — пробую достать из репозитория"
      if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$REPO_DIR" checkout -- config/models.yaml 2>/dev/null || true
      fi
      if [[ -s "$POLICY" ]]; then
        ok "восстановлено из git"
      else
        bad "не восстановить автоматически"
        echo "  на управляющем хосте: bash deploy.sh config/models.yaml"
        echo "  или: git -C $REPO_DIR checkout -- config/models.yaml"
        echo; echo "MODEL-POLICY: FAIL"; exit 1
      fi
    fi

    echo
    echo "=== 2. читается ли она рантаймом ==="
    if OUT="$(verify)"; then ok "$OUT"; else bad "${OUT:-не читается}"; \
      echo; echo "MODEL-POLICY: FAIL"; exit 1; fi
    echo
    echo "MODEL-POLICY: OK"
    ;;
esac
