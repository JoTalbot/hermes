#!/usr/bin/env bash
# scripts/bootstrap.sh — a clean server → a working Hermes node (master-task §22).
# Order matters: detect, install, wire, register, verify. Never assume a previous step worked.
#
#   git clone https://github.com/JoTalbot/hermes && cd hermes && sudo ./scripts/bootstrap.sh
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log(){ printf '\033[35m[bootstrap]\033[0m %s\n' "$*"; }

log "1/11 os + arch probe"
. /etc/os-release 2>/dev/null || true
log "     ${PRETTY_NAME:-unknown} · $(uname -m) · kernel $(uname -r)"
# aarch64 matters: several upstream images and wheels are amd64-only.
[[ "$(uname -m)" == aarch64 ]] && log "     ARM64 — pin image architectures when pulling (multi-arch or explicit --platform linux/arm64)"

log "2/11 disk gate"
df -h / | sed -n '2p;s/^/     /'
log "3/11 base packages + install"
[[ -f /root/.bashrc ]] && grep -q 'local/bin' /root/.bashrc || { echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc; log "     added ~/.local/bin to PATH"; }
bash "$REPO_DIR/scripts/install.sh"

log "4/11 secrets must already exist — bootstrap never invents them"
[[ -s /etc/hermes/shim.env ]] || { echo "FATAL: /etc/hermes/shim.env missing after install. Put the loopback secret there by hand (see docs/SECURITY.md)."; exit 1; }
grep -q HERMES_BALANCER_API_KEY /etc/hermes/shim.env || { echo "FATAL: /etc/hermes/shim.env has no HERMES_BALANCER_API_KEY"; exit 1; }

log "5/11 balancer reachability"
if ! curl -fsS --max-time 6 http://127.0.0.1:9600/health >/dev/null 2>&1; then
  log "     octopus-aios bridge NOT on 9600 — this is a new server, not arm-server-01."
  log "     Hermes will start with NO model provider. Set model.base_url in ~/.hermes/config.yaml"
  log "     to your balancer before running any agent. Continuing (install is still valid)."
  BOOT_NO_BALANCER=1
else
  log "     balancer healthy: $(curl -fsS --max-time 6 http://127.0.0.1:9600/health | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["llm_balancer"]["providers"]),"providers")' 2>/dev/null || echo '?')"
fi

log "6/11 start shim + serve"
systemctl restart hermes-shim.service 2>/dev/null || log "     shim unit not present — run install.sh first"
sleep 2
log "7/11 skills + agent profiles"
bash "$REPO_DIR/scripts/install-agents.sh" || log "     profile install skipped/failed — not fatal, kanban still works"
log "7b/11 skills registration"
bash "$REPO_DIR/scripts/register-skills.sh" || log "     skills registration failed — profiles would run with 0 skills"
log "8/11 agent bus"
bash "$REPO_DIR/scripts/init-bus.sh" || log "     bus init failed — see doctor output below"
log "9/11 server registration"
bash "$REPO_DIR/scripts/register-server.sh" || log "     registration failed (needs GITHUB_TOKEN to push) — local manifest still written"
log "10/11 services up"
systemctl --no-pager --plain status hermes-shim.service hermes-serve.service 2>/dev/null | grep -E 'Active:|●' | sed 's/^/     /' || true
log "11/11 verify"
if [[ "${BOOT_NO_BALANCER:-}" == 1 ]]; then
  log "skipping inference test (no balancer) — SYSTEM HEALTH unknown"
  exit 0
fi
bash "$REPO_DIR/scripts/doctor.sh"
