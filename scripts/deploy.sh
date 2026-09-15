#!/usr/bin/env bash
# scripts/deploy.sh — push this repo to a server and (re)start the Hermes layer.
# Additive by design: new files under /opt/hermes, a dedicated `hermes` user, two new
# units. It does not edit, stop, or restart any existing service. Reversible with --rollback.
#
#   scripts/deploy.sh ubuntu@129.213.177.56            # deploy + verify
#   scripts/deploy.sh ubuntu@host --rollback           # undo (removes our units + dir)
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?usage: deploy.sh <user@host> [--rollback] [--no-git]}"
ACTION="${2:-}"; NOGIT="${3:-}"
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new}"
SSH="ssh $SSH_OPTS $HOST"      # SSH_OPTS lets you pass -i /path/key or -J bastion without editing this file

if [[ "$ACTION" == "--rollback" ]]; then
  echo "=== rollback: removing Hermes units and /opt/hermes (nothing else touched) ==="
  $SSH 'sudo systemctl disable --now hermes-shim.service hermes-serve.service 2>/dev/null;
         sudo rm -f /etc/systemd/system/hermes-shim.service /etc/systemd/system/hermes-serve.service;
         sudo systemctl daemon-reload; sudo rm -rf /opt/hermes;
         echo "  units removed; /home/hermes left in place for inspection"'
  exit 0
fi

# All remote logic goes through ONE heredoc'd script. Inline `awk "NR==2{print $4}"`
# style got mangled by nested quoting (the $4 was eaten by the local shell) — a remote
# step that silently prints empty fields is how you "verify" something that never ran.
log(){ printf '  %s\n' "$*"; }
echo "=== 0/6 mkdir + transfer ==="
# /opt is root-owned and the ssh user is typically unprivileged: mkdir and extract both
# need sudo. Streaming into `sudo tar` avoids ever leaving the archive world-readable in /tmp.
$SSH 'sudo mkdir -p /opt/hermes && sudo chown $(id -un) /opt/hermes' \
  || { echo "  cannot create /opt/hermes (does the ssh user have sudo?)"; exit 1; }
tar -C "$REPO_DIR" -czf - --exclude=.git --exclude='state/backups/*.tar.gz' --exclude='__pycache__' . \
  | $SSH 'sudo tar -xzf - -C /opt/hermes && sudo chown -R root:root /opt/hermes' \
  || { echo "  transfer failed"; exit 1; }

remote_script=$(cat <<'REMOTE'
set -uo pipefail
step(){ printf '=== %s\n' "$*"; }

step "1/6 pre-flight"
df -P / | awk 'NR==2{printf "  disk: %d MB free (%s used)\n", $4/1024, $5}'
free_gb=$(df -Pk / | awk 'NR==2{print int($4/1048576)}')
echo "  load: $(cut -d' ' -f1-3 /proc/loadavg)  free_gb: $free_gb"
if [ "${free_gb:-0}" -lt 2 ]; then echo "  REFUSING: ${free_gb}G free — a partial deploy is worse than none."; exit 1; fi

step "2/6 transfer landed"
echo "  files: $(find /opt/hermes -type f | wc -l)  scripts: $(ls /opt/hermes/scripts | wc -l)"

step "3/6 install (idempotent)"
cd /opt/hermes && bash scripts/install.sh 2>&1 | sed 's/^/  /' || { echo "  install.sh failed"; exit 1; }

step "4/6 loopback secret → hermes user (never printed)"
if [ ! -s /etc/hermes/shim.env ]; then echo "  FATAL: /etc/hermes/shim.env absent"; exit 1; fi
K=$(sed -n 's/^HERMES_BALANCER_API_KEY=//p' /etc/hermes/shim.env)
[ -n "$K" ] || { echo "  FATAL: key missing from /etc/hermes/shim.env"; exit 1; }
install -d -o hermes -g hermes -m 0750 /home/hermes/.hermes
umask 077
printf 'HERMES_BALANCER_API_KEY=%s\nAIOS_BRIDGE_URL=%s\n' "$K" "$(sed -n 's/^AIOS_BRIDGE_URL=//p' /etc/hermes/shim.env)" > /home/hermes/.hermes/.env
cat > /home/hermes/.hermes/config.yaml <<CFG
model:
  provider: custom
  default: hermes-auto
  base_url: http://127.0.0.1:9700/v1
  api_key: $K
onboarding:
  seen:
    busy_input_prompt: true
CFG
chown -R hermes:hermes /home/hermes/.hermes
chmod 600 /home/hermes/.hermes/.env /home/hermes/.hermes/config.yaml
echo "  config.yaml + .env written at 0600 (contents not displayed)"

step "5/6 start ONLY our units"
systemctl daemon-reload
systemctl enable --now hermes-shim.service >/dev/null 2>&1
sleep 2
echo "  hermes-shim: $(systemctl is-active hermes-shim.service)"
systemctl is-active hermes-shim.service >/dev/null || { journalctl -u hermes-shim -n 12 --no-pager | sed 's/^/    /'; exit 1; }

step "6/6 verify with doctor"
set -a; . /etc/hermes/shim.env; set +a
export HERMES_BIN=/home/hermes/.hermes-venv/bin/hermes REPO_DIR=/opt/hermes
[ -x "$HERMES_BIN" ] || export HERMES_BIN=/usr/local/bin/hermes
cd /opt/hermes && bash scripts/doctor.sh
RC=$?
echo
echo "  shim metrics:"
curl -s --max-time 5 http://127.0.0.1:9700/metrics | sed 's/^/    /'
exit $RC
REMOTE
)
echo "=== deploying to $HOST ==="
$SSH "sudo bash -s" < <(printf '%s\n' "$remote_script")
RC=$?
echo "  deploy rc=$RC"
echo "  (no git on server: $([[ "$NOGIT" == --no-git ]] && echo skipped || echo attempted))"
