#!/usr/bin/env bash
# scripts/doctor.sh — single health gate for the Hermes OS (master-task §28).
# Read-only. Safe to run any time, by hand or by cron. Exit 0 healthy/degraded.
#
#   SYSTEM HEALTH: HEALTHY     → everything critical green
#   SYSTEM_HEALTH: DEGRADED    → a non-fatal check failed (reason printed)
#   exit 1 = critical failure, exit 0 = healthy or degraded-but-functional
set -uo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YLW=""; RST=""; }
CRIT=0; WARN=0
ok(){   printf "[OK]   %-14s %s\n" "$1" "$2"; }
warn(){ printf "[WARN] %-14s %s\n" "$1" "$2"; WARN=$((WARN+1)); }
fail(){ printf "[FAIL] %-14s %s\n" "$1" "$2"; CRIT=$((CRIT+1)); }

HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
[[ -x "$HERMES_BIN" ]] || HERMES_BIN="$(command -v hermes || true)"
SHIM_URL="${HERMES_SHIM_URL:-http://127.0.0.1:9700}"
BRIDGE_URL="${AIOS_BRIDGE_URL:-http://127.0.0.1:9600}"
REPO_DIR="${REPO_DIR:-/opt/hermes}"

echo "=== Hermes OS doctor @ $(hostname) · $(date -Is) ==="

# 1. Hermes CLI
if [[ -n "$HERMES_BIN" && -x "$HERMES_BIN" ]]; then
  v="$("$HERMES_BIN" --version 2>&1 | head -1)"
  ok "Hermes" "$v"
else
  fail "Hermes" "hermes binary not found (looked at \$HOME/.local/bin/hermes, PATH)"
fi

# 2. LLM balancer (the thing everything depends on)
bh="$(curl -fsS --max-time 5 "$BRIDGE_URL/health" 2>/dev/null)"
if [[ -n "$bh" ]]; then
  nprov="$(printf '%s' "$bh" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["llm_balancer"]["providers"]))' 2>/dev/null)"
  unhealthy="$(printf '%s' "$bh" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(1 for p in d["llm_balancer"]["providers"] if not p.get("healthy")))' 2>/dev/null)"
  if [[ "${unhealthy:-0}" -gt 0 ]]; then
    warn "LLM Balancer" "$nprov providers, $unhealthy UNHEALTHY"
  else
    ok "LLM Balancer" "$nprov providers, all healthy"
  fi
  for p in $(printf '%s' "$bh" | python3 -c 'import json,sys;[print(p["name"]) for p in json.load(sys.stdin)["llm_balancer"]["providers"] if not p.get("healthy")]' 2>/dev/null); do
    warn "  provider" "$p reporting unhealthy"
  done
else
  fail "LLM Balancer" "$BRIDGE_URL/health unreachable — no agent can run"
fi

# 3. Shim in front of the balancer
sh="$(curl -fsS --max-time 5 "$SHIM_URL/health" 2>/dev/null)"
if [[ -n "$sh" ]]; then
  ok "Shim" "$(printf '%s' "$sh" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("requests=%s failed=%s"%(d["metrics"]["requests_total"],d["metrics"]["requests_failed"]))' 2>/dev/null)"
else
  fail "Shim" "$SHIM_URL/health down. Start: sudo systemctl start hermes-shim"
fi

# 4. End-to-end inference (real token through the whole chain)
e2e="$(python3 - "$SHIM_URL" <<'PY'
import json,os,sys,urllib.request
u=sys.argv[1]+"/v1/chat/completions"
key=os.environ.get("HERMES_BALANCER_API_KEY","")
body=json.dumps({"model":"hermes-fast","messages":[{"role":"user","content":"Reply with exactly: DOCTOR_OK"}]}).encode()
r=urllib.request.Request(u,data=body,headers={"Content-Type":"application/json",**({"Authorization":"Bearer "+key} if key else {})},method="POST")
try:
    with urllib.request.urlopen(r,timeout=90) as f: print(json.load(f)["choices"][0]["message"]["content"][:80])
except Exception as e: print("ERR:"+str(e)[:120])
PY
)"
case "$e2e" in
  *DOCTOR_OK*) ok "Inference" "round-trip through balancer: ${e2e:0:60}" ;;
  ERR:*)       fail "Inference" "$e2e" ;;
  *)           warn "Inference" "answered but no DOCTOR_OK marker: ${e2e:0:70}" ;;
esac

# 5. WebUI / serve
if systemctl is-active --quiet hermes-serve 2>/dev/null; then
  ok "WebUI" "hermes-serve active on 127.0.0.1:9119"
elif ss -lnt 2>/dev/null | grep -q ':9119 '; then
  warn "WebUI" "port 9119 listening but hermes-serve unit not active (manually started?)"
else
  warn "WebUI" "not running — Android control plane unavailable"
fi

# 6. Agent bus (kanban board + profiles)
if [[ -n "$HERMES_BIN" ]]; then
  prof="$("$HERMES_BIN" profile list 2>&1 | grep -cE '^\s*[-*]? ?[a-z0-9_-]+' || true)"
  [[ "${prof:-0}" -ge 1 ]] && ok "Agents" "$prof profile(s) registered" || warn "Agents" "no profiles — run scripts/install-agents.sh"
  kb="$(find "${HERMES_HOME:-$HOME/.hermes}" -name 'kanban.db' 2>/dev/null | head -1)"
  [[ -n "$kb" ]] && ok "Agent Bus" "kanban board: $kb" || warn "Agent Bus" "no kanban.db — ./scripts/init-bus.sh"
fi

# 7. Skills
if [[ -f "$REPO_DIR/skills/REGISTRY.md" ]]; then
  cnt=$(grep -cE '^\| ' "$REPO_DIR/skills/REGISTRY.md" 2>/dev/null || echo 0)
  ok "Skills" "$cnt registry entries at $REPO_DIR/skills/REGISTRY.md"
else
  warn "Skills" "$REPO_DIR/skills/REGISTRY.md missing (repo not deployed to /opt/hermes?)"
fi

# 8. Memory
memdir="${HERMES_HOME:-$HOME/.hermes}/memories"
if [[ -d "$memdir" ]]; then
  ok "Memory" "$(find "$memdir" -type f 2>/dev/null | wc -l) files in $memdir"
else
  warn "Memory" "$memdir absent — memory-graph will initialise on first write"
fi

# 9. GitHub sync + secret hygiene
if [[ -d "$REPO_DIR/.git" ]]; then
  cd "$REPO_DIR"
  dirty=$(git status --porcelain 2>/dev/null | wc -l)
  ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
  if [[ "$dirty" -gt 0 ]]; then warn "GitHub" "$dirty uncommitted paths, $ahead ahead of upstream"
  else ok "GitHub" "clean tree, $ahead unpushed"; fi
  if command -v git >/dev/null && [[ "${SKIP_SECRET_SCAN:-0}" != "1" ]]; then
    hits=$(bash "$REPO_DIR/scripts/secret-scan.sh" --worktree 2>/dev/null | tail -1)
    [[ "$hits" == "clean" ]] && ok "Secrets" "worktree scan clean" || fail "Secrets" "$hits"
  fi
else
  warn "GitHub" "$REPO_DIR/.git absent — source of truth not deployed here"
fi

# 10. Storage — the check that gates every install on this box
read -r used avail <<<"$(df -P / | awk 'NR==2{print $5, $4}')"
gb_avail=$(( ${avail%G} * 1024 / 1048576 * 1024 / 1024 ))
gb_avail=$((avail / 1048576))
if [[ "$used" =~ ^([0-9]+) ]]; then
  pct="${BASH_REMATCH[1]}"
  if   (( pct >= 95 )); then fail "Storage" "${pct}% used, ${gb_avail}G free — INSTALLS WILL FAIL, prune first"
  elif (( pct >= 85 )); then warn "Storage" "${pct}% used, ${gb_avail}G free (SLO threshold is 85%)"
  else ok "Storage" "${pct}% used, ${gb_avail}G free"; fi
fi

# 11. Docker / systemd
if command -v docker >/dev/null 2>&1; then
  dead=$(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | wc -l)
  (( dead > 0 )) && warn "Docker" "$dead exited container(s): $(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" \
                 || ok "Docker" "no exited containers"
else warn "Docker" "not installed"; fi
failed=$(systemctl --no-pager --plain list-units --state=failed 2>/dev/null | grep -c '\.service')
(( failed > 0 )) && warn "systemd" "$failed failed unit(s): $(systemctl --no-pager --plain list-units --state=failed 2>/dev/null | awk '/\.service/{print $1}' | tr '\n' ' ')" || ok "systemd" "no failed units"

# 12. Tailscale (the plan's transport for Android control)
if command -v tailscale >/dev/null 2>&1; then
  tsip=$(tailscale ip -4 2>/dev/null | head -1)
  [[ -n "$tsip" ]] && ok "Tailscale" "up on $tsip" || fail "Tailscale" "installed but not up"
else
  warn "Tailscale" "absent — Android→GUI path falls back to SSH tunnel (see docs/RUNBOOK.md)"
fi

echo
if (( CRIT > 0 )); then
  printf '%sSYSTEM HEALTH: UNHEALTHY%s (%d critical, %d warnings)\n' "$RED" "$RST" "$CRIT" "$WARN"; exit 1
elif (( WARN > 0 )); then
  printf '%sSYSTEM HEALTH: DEGRADED%s (%d warnings)\n' "$YLW" "$RST" "$WARN"; exit 0
else
  printf '%sSYSTEM HEALTH: HEALTHY%s\n' "$GRN" "$RST"; exit 0
fi
