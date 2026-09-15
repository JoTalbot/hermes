#!/usr/bin/env bash
# Enable and configure the dashboard's own password authentication.
#
# WHY THIS IS NOT OPTIONAL: since the June-2026 hardening a non-loopback bind
# ALWAYS requires an auth provider, and the loopback dashboard is otherwise
# completely unauthenticated — `curl 127.0.0.1:9119/api/status` returns the whole
# control surface with no credentials. Exposing that port without this provider
# would hand shell access on a production box to anyone who scans 9119.
#
# Credentials live in /etc/hermes/dashboard.env (0600 root) — the same pattern as
# shim.env: nothing secret in git, nothing secret in a package-managed file.
set -uo pipefail

ENVF=/etc/hermes/dashboard.env
VENV=/home/hermes/.hermes-venv
PY=$VENV/bin/python3
HB=$VENV/bin/hermes
HH=/home/hermes/.hermes

as_hermes() { sudo -u hermes env HERMES_HOME=$HH "$@"; }

echo "=== 0. confirm the vendor hash function is importable ==="
sudo -u hermes $PY -c '
import sys
sys.path.insert(0, "/home/hermes/.hermes-venv/lib/python3.12/site-packages")
from plugins.dashboard_auth.basic import hash_password
h = hash_password("probe")
print("  hash_password OK, format:", h.split("$")[0] + "$… , length", len(h))
'

echo
echo "=== 1. generate credentials ==="
sudo -u hermes $PY - > /tmp/creds.env 2>/tmp/creds.pw <<'PY'
import base64, os, secrets, sys
sys.path.insert(0, "/home/hermes/.hermes-venv/lib/python3.12/site-packages")
from plugins.dashboard_auth.basic import hash_password

# Typeable on a phone: no shell metacharacters, no look-alike pairs (0/O, 1/l/I).
alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
raw = "".join(secrets.choice(alphabet) for _ in range(24))
password = "-".join(raw[i:i + 6] for i in range(0, 24, 6))

print("HERMES_DASHBOARD_BASIC_AUTH_USERNAME=jotalbot")
print("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=" + hash_password(password))
print("HERMES_DASHBOARD_BASIC_AUTH_SECRET=" + base64.b64encode(os.urandom(32)).decode())
print(password, file=sys.stderr)
PY

sudo install -m 600 -o root -g root /tmp/creds.env $ENVF
printf '%s\n' "$(cat /tmp/creds.pw)" | sudo tee /etc/hermes/dashboard.password >/dev/null
sudo chmod 600 /etc/hermes/dashboard.password
rm -f /tmp/creds.env /tmp/creds.pw

echo "  wrote $ENVF (0600 root):"
sudo sed -E 's/^(HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=)(.*)$/\1scrypt$… [redacted, length kept: '"$(sudo awk -F= '/PASSWORD_HASH/{print length($2)}' $ENVF)"']/; s/^(HERMES_DASHBOARD_BASIC_AUTH_SECRET=).*/\1[redacted]/' $ENVF | sed 's/^/    /'
echo "  retrieval copy: /etc/hermes/dashboard.password (0600 root)"
echo
echo "  PASSWORD: $(sudo cat /etc/hermes/dashboard.password)"

echo
echo "=== 2. enable the bundled 'basic' provider ==="
as_hermes $HB plugins enable basic 2>&1 | tail -4

echo
echo "=== 3. verify it is enabled ==="
as_hermes $HB plugins list 2>&1 | grep -iE "basic" | head -4
