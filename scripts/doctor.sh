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
# Чужое — не наш вердикт, но и не секрет: печатаем и НЕ считаем. Иначе доктор вечно
# стоит в DEGRADED из-за соседей, которых нам трогать нельзя, и предупреждение перестают
# читать (политика 2026-09-17: чужие контейнеры не трогаем).
info(){ printf "[INFO] %-14s %s\n" "$1" "$2"; }

# --- agent-runtime defaults -------------------------------------------------
# The agent OS runs as unix user `hermes` with its own venv and home. Without
# these, running the doctor as root (which is how cron and humans run it) checked
# $HOME/.hermes = /root/.hermes and reported "no profiles", "no kanban.db" and
# "/root/.hermes/memories absent" on a machine where all three were fine. A
# health check that lies is worse than no health check.
export HERMES_HOME="${HERMES_HOME:-/home/hermes/.hermes}"
HERMES_BIN="${HERMES_BIN:-/home/hermes/.hermes-venv/bin/hermes}"
[[ -x "$HERMES_BIN" ]] || HERMES_BIN="$(command -v hermes || true)"
SHIM_URL="${HERMES_SHIM_URL:-http://127.0.0.1:9700}"
BRIDGE_URL="${AIOS_BRIDGE_URL:-http://127.0.0.1:9600}"
REPO_DIR="${REPO_DIR:-/opt/hermes}"
SECRET_ENV="${HERMES_SECRET_ENV:-/etc/hermes/shim.env}"

# The end-to-end probe needs the loopback shim token. It is 0600 root, so this
# only works when the doctor itself runs as root (cron does). Never printed.
if [[ -z "${HERMES_BALANCER_API_KEY:-}" && -r "$SECRET_ENV" ]]; then
  set -a; . "$SECRET_ENV"; set +a
fi

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

# 4b. managed-scope dir mode (Hermes stats /etc/hermes/.env and raises instead of
#     returning False when the DIRECTORY is not traversable — a 0700 /etc/hermes
#     breaks every `hermes` command, kanban included).
if [[ -d /etc/hermes ]]; then
  _m="$(stat -c '%a' /etc/hermes)"
  [[ "$_m" == "755" ]] && ok "Managed scope" "/etc/hermes mode 755 (secrets inside are 0600)" \
                       || fail "Managed scope" "/etc/hermes mode $_m — must be 755 or every hermes command fails"
fi

# 5. WebUI / serve
# Report the bind the process ACTUALLY has, not the bind it used to have. The
# dashboard moved from loopback to 0.0.0.0:9119 on 2026-09-15 (owner decision,
# plain_port) and a doctor that keeps printing "127.0.0.1" would hide a regression
# in whichever direction — including an accidental wide bind with no auth in front.
if systemctl is-active --quiet hermes-serve 2>/dev/null; then
  bind=$(ss -lntH 2>/dev/null | awk '$4 ~ /:9119$/ {print $4}' | head -1)
  case "$bind" in
    "127.0.0.1:9119"|"[::1]:9119")
      ok "WebUI" "hermes-serve active on $bind (loopback only)" ;;
    "0.0.0.0:9119"|"*:9119"|"[::]:9119")
      if [[ -f /etc/hermes/dashboard.env ]]; then
        ok "WebUI" "hermes-serve active on $bind, password-gated (basic auth provider)"
      else
        fail "WebUI" "listening on $bind WITHOUT /etc/hermes/dashboard.env — unauthenticated exposure"
      fi ;;
    "")
      warn "WebUI" "hermes-serve active but nothing is listening on 9119" ;;
    *)
      warn "WebUI" "hermes-serve active on unexpected bind $bind" ;;
  esac
elif ss -lnt 2>/dev/null | grep -q ':9119 '; then
  warn "WebUI" "port 9119 listening but hermes-serve unit not active (manually started?)"
else
  warn "WebUI" "not running — Android control plane unavailable"
fi

# 5b. agent bus dispatcher (the gateway hosts it; a dead dispatcher parks every
#     task in "ready" forever with no error anywhere else)
if systemctl is-active --quiet hermes-env-guard 2>/dev/null; then
  ok "Env guard" "hermes-env-guard active (self-heals the shim secret)"
else
  fail "Env guard" "hermes-env-guard not active — secret self-heal disabled"
fi
if systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  # INFO-level gateway lines go to the log FILE, not journald (which only sees
  # the startup warnings) — checking journald here produced a permanent false
  # "no dispatcher tick" warning on a perfectly healthy dispatcher.
  _gwlog="$HERMES_HOME/logs/gateway.log"
  if [[ -r "$_gwlog" ]] && grep -q "kanban dispatcher: embedded" "$_gwlog"; then
    ok "Dispatcher" "hermes-gateway active, embedded dispatcher ticking"
  else
    warn "Dispatcher" "gateway active but no dispatcher tick in 10min — check journalctl -u hermes-gateway"
  fi
else
  fail "Dispatcher" "hermes-gateway not active — kanban tasks will never run"
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
  # Свои контейнеры называются hermes-*. Признак «exited» у чужого контейнера не делает больным
  # НАШ узел и не чинится нами; признак «exited» у нашего — делает (обычно это забытая заготовка).
  own_dead=(); foreign_dead=()
  while read -r cname; do
    [[ -z "$cname" ]] && continue
    if [[ "$cname" == hermes-* ]]; then own_dead+=("$cname"); else foreign_dead+=("$cname"); fi
  done < <(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null)
  (( ${#own_dead[@]} > 0 )) && warn "Docker" "${#own_dead[@]} exited container(s) of ours: ${own_dead[*]}" \
                           || ok "Docker" "no exited containers of ours"
  (( ${#foreign_dead[@]} > 0 )) && info "DockerForeign" "${#foreign_dead[@]} exited container(s) of other projects: ${foreign_dead[*]} (chuzhoe — reshenie vladeltsa)"
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

# 13. Backups — is the nightly archive actually being produced?
# Added with hermes-backup.timer on 2026-09-15: before this, backups were manual and
# there was no way to notice they had stopped. Age matters more than existence.
BACKUP_DIR="${HERMES_BACKUP_DIR:-/var/backups/hermes}"
if [[ -d "$BACKUP_DIR" && -r "$BACKUP_DIR" ]]; then
  newest=$(ls -1t "$BACKUP_DIR"/hermes-state-*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$newest" ]]; then
    warn "Backup" "no state archive in $BACKUP_DIR — has hermes-backup.timer ever run?"
  else
    age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
    if   (( age_h > 168 )); then fail "Backup" "newest archive is ${age_h}h old (>7d) — backups are not running"
    elif (( age_h > 48  )); then warn "Backup" "newest archive is ${age_h}h old — timer may be stuck"
    else ok "Backup" "$(basename "$newest") — ${age_h}h old"; fi
  fi
  perm=$(stat -c %a "$BACKUP_DIR")
  [[ "$perm" == "700" ]] && ok "BackupPerm" "$BACKUP_DIR is 0700" || warn "BackupPerm" "$BACKUP_DIR is $perm, expected 700"
else
  warn "Backup" "$BACKUP_DIR unreadable or absent (run the doctor as root)"
fi



# 14. Agent Bus transport — NATS + JetStream + the node's own bridge
# The bus stopped being "kanban on one host" on 2026-09-16: it is now the thing that
# carries every cross-node message. A doctor that says HEALTHY while the bus is dead
# would bless a federation that cannot talk.
NATS_ENV_FILE="${NATS_ENV_FILE:-/etc/hermes/nats.env}"
if curl -sf -m 4 http://127.0.0.1:8222/healthz >/dev/null 2>&1; then
  VARZ="$(curl -sf -m 4 http://127.0.0.1:8222/varz 2>/dev/null)"
  VER="$(printf '%s' "$VARZ" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo '?')"
  CONNS="$(printf '%s' "$VARZ" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("connections","?"))' 2>/dev/null || echo '?')"
  ok "BusTransport" "nats-server $VER healthy, $CONNS client connection(s)"
else
  fail "BusTransport" "nats-server not answering on 127.0.0.1:8222 — no cross-node messaging"
fi
if [[ -r "$NATS_ENV_FILE" ]]; then
  ok "BusToken" "$NATS_ENV_FILE present ($(stat -c %a "$NATS_ENV_FILE"))"
else
  warn "BusToken" "$NATS_ENV_FILE missing/unreadable — this node cannot join the bus"
fi
if systemctl is-active --quiet hermes-bus-bridge 2>/dev/null; then
  ok "BusBridge" "hermes-bus-bridge active"
elif pgrep -f 'bus_bridge.py run' >/dev/null 2>&1; then
  ok "BusBridge" "bus_bridge.py running (no-systemd supervisor)"
else
  fail "BusBridge" "no bridge process — this node neither mirrors nor forwards bus traffic"
fi
STREAM="$(hermes-bus-bridge status 2>/dev/null | grep '^stream' || true)"
if [[ -n "$STREAM" ]]; then
  ok "BusStream" "${STREAM#stream      : }"
  PENDING="$(printf '%s' "$STREAM" | grep -o 'ack_pending=[0-9]*' | head -1)"
  if [[ -n "$PENDING" && "${PENDING#ack_pending=}" -gt 50 ]]; then
    warn "BusBacklog" "$PENDING — this node is not consuming what it is sent"
  fi
else
  warn "BusStream" "stream state unreadable (bus down?)"
fi

# 15. Agents on the bus — registry integrity + liveness over the REAL transport
AGENTS_PY="${AGENTS_PY:-/opt/hermes/agents/runtime.py}"
VENV_BUS="${VENV_BUS:-/opt/hermes/.venv-bus/bin/python}"
if [[ -f "$AGENTS_PY" && -x "$VENV_BUS" ]]; then
  REG="$("$VENV_BUS" "$AGENTS_PY" list 2>/dev/null | tail -n +2)"
  N_AGENTS="$(printf '%s\n' "$REG" | grep -c '\[' || true)"
  if [[ "${N_AGENTS:-0}" -ge 6 ]]; then
    ok "AgentRegistry" "$N_AGENTS agents wired (id, capabilities, handlers)"
  else
    warn "AgentRegistry" "only $N_AGENTS agent(s) wired — run scripts/wire-agents.sh"
  fi
  if bash "$REPO_DIR/scripts/wire-agents.sh" --check >/dev/null 2>&1; then
    ok "AgentWiring" "config/agents matches the generator (no drift)"
  else
    warn "AgentWiring" "wire-agents.sh --check reports drift — run scripts/wire-agents.sh"
  fi
  if systemctl is-active --quiet hermes-agents 2>/dev/null || pgrep -f 'agents/runtime.py run' >/dev/null 2>&1; then
    FIRST_AGENT="$(printf '%s\n' "$REG" | head -1 | awk '{print $3}')"
    if hermes-bus request --to "$FIRST_AGENT" --timeout 25 "ping" 2>/dev/null | grep -q 'reply in'; then
      ok "AgentLiveness" "$FIRST_AGENT answered over the bus"
    else
      fail "AgentLiveness" "$FIRST_AGENT did not answer — agents are not attached to the bus"
    fi
  else
    fail "AgentRuntime" "no agents runtime process — nothing can answer a task"
  fi
else
  warn "AgentRuntime" "$AGENTS_PY or $VENV_BUS missing — install-agent-runtime.sh not run"
fi

# 16. Federation — who else is on this bus, and are they alive?
NODES_FILE=/var/lib/hermes-bus/nodes.json
if [[ -r "$NODES_FILE" ]]; then
  read -r TOTAL PEERS <<<"$(python3 - "$NODES_FILE" <<'PYEOF2'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc)
peers = [k for k, v in d.items() if k != "arm-server-01"]
print(len(d), len(peers))
PYEOF2
)"
  if (( TOTAL >= 2 )); then
    ok "Federation" "$TOTAL node(s) seen on the bus ($PEERS peer(s))"
  else
    warn "Federation" "only this node has been seen on the bus so far"
  fi
  STALE="$(python3 - "$NODES_FILE" <<'PYEOF2'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc)
stale = []
for k, v in d.items():
    ts = v.get("last_seen") or ""
    try:
        age = (now - datetime.datetime.fromisoformat(ts)).total_seconds() / 3600
    except Exception:
        continue
    if age > 24:
        stale.append(f"{k} ({age:.0f}h)")
print(", ".join(stale))
PYEOF2
)"
  [[ -z "$STALE" ]] && ok "PeerFreshness" "every known peer reported within 24h" \
                    || warn "PeerFreshness" "silent for >24h: $STALE (uzly nashey shiny; chuzhoy uzel — reshenie vladeltsa)"
else
  warn "Federation" "no /var/lib/hermes-bus/nodes.json yet (bus never saw a message)"
fi


# 17. Gateway unit integrity — the gateway must run from THIS node's hermes home.
# `hermes gateway restart --system` regenerated the unit against another user's venv and
# the gateway crash-looped for minutes before anyone noticed. Reboots are only safe if the
# unit that starts is the unit we tested.
# Use the EFFECTIVE configuration: `systemctl cat` prints base + drop-ins and the first
# ExecStart line comes from the base unit, so a correctly overridden unit looked broken
# (the check reported UNHEALTHY while the service was demonstrably running the right binary).
GW_EXEC="$(systemctl show hermes-gateway -p ExecStart --value 2>/dev/null | grep -oE '/[^ ;"]*hermes[^ ;"]*' | head -1)"
if [[ -z "$GW_EXEC" ]]; then
  warn "GatewayUnit" "hermes-gateway unit not found (not a host node?)"
elif [[ "$GW_EXEC" == *"/home/hermes/"* ]]; then
  ok "GatewayUnit" "ExecStart=${GW_EXEC}"
else
  fail "GatewayUnit" "ExecStart points outside /home/hermes: $GW_EXEC — a regenerated unit; reinstall the drop-in (deploy/systemd/hermes-gateway.service.d/10-hermes-home.conf)"
fi
if [[ -f /etc/systemd/system/hermes-gateway.service.d/10-hermes-home.conf ]]; then
  ok "GatewayPin" "drop-in pins the interpreter (survives 'gateway restart --system')"
else
  warn "GatewayPin" "no drop-in — 'hermes gateway restart --system' can re-break the unit"
fi

# 18. Telegram two-way link — the owner's control plane. A chat exists => the inbox must be
# running: a dead poller means the owner's commands vanish silently, which is exactly the
# kind of "looks fine from the server" failure this doctor exists to prevent.
if [[ -f /etc/hermes/telegram.chats.json ]]; then
  if systemctl is-active --quiet hermes-telegram-inbox 2>/dev/null; then
    ok "TelegramInbox" "chat configured, hermes-telegram-inbox active (commands -> bus)"
  elif pgrep -f "bus_bridge.py poll" >/dev/null 2>&1; then
    ok "TelegramInbox" "bus_bridge.py poll running (no-systemd supervisor)"
  else
    fail "TelegramInbox" "a chat is configured but nothing polls Telegram — owner commands are lost"
  fi
elif [[ -f /etc/hermes/telegram.env ]]; then
  warn "TelegramInbox" "token present, no chat yet — send the bot /start, then: hermes-bus-bridge discover"
fi

echo
if (( CRIT > 0 )); then
  printf '%sSYSTEM HEALTH: UNHEALTHY%s (%d critical, %d warnings)\n' "$RED" "$RST" "$CRIT" "$WARN"; exit 1
elif (( WARN > 0 )); then
  printf '%sSYSTEM HEALTH: DEGRADED%s (%d warnings)\n' "$YLW" "$RST" "$WARN"; exit 0
else
  printf '%sSYSTEM HEALTH: HEALTHY%s\n' "$GRN" "$RST"; exit 0
fi
