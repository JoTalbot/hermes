#!/usr/bin/env bash
# scripts/install.sh — install the Hermes runtime for the *hermes* service user.
#
# Idempotent by construction: every step is a version check before an action.
# Deliberately does NOT touch /home/ubuntu/.hermes — that install is wired to the
# liza Telegram bridge and mutating it would re-route a live bot (docs/ARCHITECTURE.md).
#
#   run on the server:  sudo bash scripts/install.sh
# Refuses to run if the root filesystem has < HERMES_MIN_FREE_GB free, because a
# half-installed Python venv is much worse than an uninstalled one.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HERMES_USER="${HERMES_USER:-hermes}"
MIN_FREE_GB="${HERMES_MIN_FREE_GB:-6}"
HERMES_VERSION="${HERMES_VERSION:-}"        # empty = latest from PyPI

log(){ printf '\033[36m[install]\033[0m %s\n' "$*"; }
die(){ printf '\033[31m[install] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "run with sudo (needs a system user + unit files)"

# ---- 0. gate: disk space (this box's real constraint) ----
avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
avail_gb=$((avail_kb / 1048576))
if (( avail_gb < MIN_FREE_GB )); then
  die "only ${avail_gb}G free on / (need ${MIN_FREE_GB}G). A venv install that dies at
       ENOSPC leaves a broken interpreter on PATH. Free space first, then re-run —
       this script is safe to repeat. See memory/incidents/2026-09-15-disk-pressure.md"
fi
log "disk ok: ${avail_gb}G free (threshold ${MIN_FREE_GB}G)"

# ---- 1. service user + dirs ----
if ! id "$HERMES_USER" >/dev/null 2>&1; then
  log "creating system user $HERMES_USER"
  useradd --system --create-home --home-dir "/home/$HERMES_USER" --shell /bin/bash "$HERMES_USER"
else
  log "user $HERMES_USER already exists — leaving its home alone"
fi
install -d -o "$HERMES_USER" -g "$HERMES_USER" -m 0750 "/home/$HERMES_USER/.hermes"
install -d -o "$HERMES_USER" -g "$HERMES_USER" -m 0750 "$REPO_DIR/state/backups"
install -d -m 0750 /etc/hermes

# ---- 2. prerequisites the pip path needs ----
need_pkgs=()
for p in git curl ca-certificates xz-utils; do dpkg -s "$p" >/dev/null 2>&1 || need_pkgs+=("$p"); done
if (( ${#need_pkgs[@]} )); then
  log "installing missing base packages: ${need_pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${need_pkgs[@]}"
else
  log "base packages present"
fi

# ---- 3. python >= 3.11 without touching system python ----
PYVER="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo 0.0)"
py_ok() { python3 -c 'import sys; raise SystemExit(0 if sys.version_info>=(3,11) else 1)' 2>/dev/null; }
if py_ok; then
  log "system python $PYVER is sufficient"
  PYBIN="$(command -v python3)"
elif command -v uv >/dev/null 2>&1; then
  log "using uv-managed python"; PYBIN="$(uv python find 3.11 2>/dev/null || echo /usr/local/bin/python3)"
else
  log "python $PYVER too old — bootstrapping uv (installs its own python, no system change)"
  curl -fsSL https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
  uv python install 3.11 --install-dir /opt/uv-python
  PYBIN="$(uv python find 3.11)"
fi
[[ -x "$PYBIN" ]] || die "no usable interpreter resolved"

# ---- 4. venv + hermes (skip if the right version is already there) ----
HBIN="/home/$HERMES_USER/.hermes-venv/bin/hermes"
have="$(su -s /bin/bash "$HERMES_USER" -c "[[ -x $HBIN ]] && $HBIN --version 2>/dev/null | head -1" 2>/dev/null || true)"
want="${HERMES_VERSION:-}"
if [[ -n "$have" && ( -z "$want" || "$have" == *"$want"* ) ]]; then
  log "hermes already installed ($have) — skipping pip install"
else
  [[ -d "/home/$HERMES_USER/.hermes-venv" ]] || su -s /bin/bash "$HERMES_USER" -c "$PYBIN -m venv /home/$HERMES_USER/.hermes-venv"
  spec="hermes-agent${want:+==$want}"
  log "pip install $spec (as $HERMES_USER)"
  su -s /bin/bash "$HERMES_USER" -c "/home/$HERMES_USER/.hermes-venv/bin/pip install -q --upgrade pip && /home/$HERMES_USER/.hermes-venv/bin/pip install -q '$spec'" \
    || die "pip install failed. Re-run — but check 'df -h /' first; ENOSPC looks like a network error here."
  log "installed: $(su -s /bin/bash "$HERMES_USER" -c "$HBIN --version 2>&1 | head -1")"
fi
# browser/computer-use extras pull ~500MB+ of Playwright Chromium. On a 94%-full
# root fs that is the single most likely thing to break the box, so it is opt-in.
if [[ "${HERMES_WITH_BROWSER:-0}" == "1" ]]; then
  log "HERMES_WITH_BROWSER=1 → installing non-python deps (large)"
  su -s /bin/bash "$HERMES_USER" -c "/home/$HERMES_USER/.hermes-venv/bin/hermes postinstall" || log "postinstall failed (usually disk or network); continuing — browser tools stay unavailable"
else
  log "skipping Playwright/browser deps (set HERMES_WITH_BROWSER=1 to opt in)"
fi

# ---- 5. shim env: generate the loopback secret if absent, never print it ----
if [[ ! -s /etc/hermes/shim.env ]]; then
  log "generating loopback secret for the shim (never written to git, never echoed)"
  umask 077
  KEY="$(head -c 24 /dev/urandom | base64 | tr -d '\n=' | head -c 32)"
  cat > /etc/hermes/shim.env <<ENVEOF
HERMES_BALANCER_API_KEY=${KEY}
HERMES_SHIM_PORT=9700
HERMES_SHIM_BIND=127.0.0.1
AIOS_BRIDGE_URL=http://127.0.0.1:9600
ENVEOF
  chown root:root /etc/hermes/shim.env; chmod 0600 /etc/hermes/shim.env
  log "wrote /etc/hermes/shim.env (0600). Hermes needs this value in its own env file:"
  log "  sudo cp /etc/hermes/shim.env /home/$HERMES_USER/.hermes/.env && sudo chown $HERMES_USER /home/$HERMES_USER/.hermes/.env"
else
  log "/etc/hermes/shim.env already present — leaving it"
fi

# ---- 6. config.yaml pointing at the shim ----
CFG="/home/$HERMES_USER/.hermes/config.yaml"
if [[ -s "$CFG" && "${HERMES_FORCE_CONFIG:-0}" != "1" ]]; then
  log "keeping existing $CFG (set HERMES_FORCE_CONFIG=1 to rewrite)"
else
  log "writing $CFG → shim provider"
  cat > "$CFG" <<'CFGEOF'
model:
  provider: custom
  default: hermes-auto
  base_url: http://127.0.0.1:9700/v1
  # api_key is read from ~/.hermes/.env — never stored in this file
onboarding:
  seen:
    busy_input_prompt: true
CFGEOF
  chown "$HERMES_USER:$HERMES_USER" "$CFG"; chmod 0600 "$CFG"
fi

# ---- 6b. register skills ----
# WHY HERE: the skill loader reads skills.external_dirs from $HERMES_HOME/config.yaml
# ONLY (agent/skill_utils.py -> get_config_path()), never from the managed scope in
# /etc/hermes — verified 2026-09-16. Without this step a freshly installed node runs
# every profile with zero skills and looks healthy while doing it.
if [[ -x "$REPO_DIR/scripts/register-skills.sh" ]]; then
  bash "$REPO_DIR/scripts/register-skills.sh" || log "skills registration failed — agents will run with 0 skills"
fi

# ---- 7. units ----
for u in hermes-shim hermes-serve; do
  install -m 0644 -o root -g root "$REPO_DIR/deploy/systemd/$u.service" "/etc/systemd/system/$u.service"
done
systemctl daemon-reload
systemctl enable hermes-shim.service hermes-serve.service >/dev/null 2>&1 || log "enable failed (non-fatal if units start manually)"
log "done. Next: scripts/install-agents.sh, then scripts/doctor.sh"
