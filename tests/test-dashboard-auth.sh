#!/usr/bin/env bash
# tests/test-dashboard-auth.sh — prove the dashboard auth path end to end.
#
# WHY: "the port is open" is not the same as "the port is safe". This script
# asserts the two things that actually matter after exposing the dashboard:
#   1. an unauthenticated client CANNOT read gated data, and
#   2. the configured credential DOES work, so the owner is not locked out.
# Run it after any change to hermes-serve.service, the credential, or the bind.
set -uo pipefail
BASE="${1:-http://127.0.0.1:9119}"
PW_FILE=/etc/hermes/dashboard.password
JAR=$(mktemp)
pass=0; fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; pass=$((pass+1));
        else echo "  FAIL  $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }

USER_NAME=$(awk -F= '/USERNAME/{gsub(/"/,"",$2);print $2}' /etc/hermes/dashboard.env)
PASSWORD=$(cat "$PW_FILE")

echo "=== dashboard auth test against $BASE ==="

# 1. root redirects to the login page rather than serving the SPA
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -m 10 "$BASE/")
chk "unauthenticated / redirects to /login" "$( [[ "$loc" == *"/login"* ]] && echo yes || echo "$loc")" "yes"

# 2. gated API refuses an anonymous client
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/api/sessions")
chk "unauthenticated /api/sessions is refused" "$code" "401"

# 3. the documented public liveness endpoint stays public (by design)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/api/status")
chk "public liveness /api/status answers" "$code" "200"

# 4. a WRONG password is rejected
wrong=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST "$BASE/auth/password-login" \
  -H 'Content-Type: application/json' \
  -d '{"provider":"basic","username":"'"$USER_NAME"'","password":"definitely-not-it"}')
chk "wrong password rejected" "$wrong" "401"

# 5. the REAL credential is accepted and mints a session
ok=$(curl -s -o /tmp/login.json -w '%{http_code}' -m 20 -X POST "$BASE/auth/password-login" \
  -H 'Content-Type: application/json' -c "$JAR" \
  -d '{"provider":"basic","username":"'"$USER_NAME"'","password":"'"$PASSWORD"'"}')
chk "configured credential accepted" "$ok" "200"
echo "        response: $(head -c 120 /tmp/login.json)"

# 6. that session can read gated data
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -b "$JAR" "$BASE/api/sessions")
chk "authenticated session can read gated API" "$code" "200"

# 7. and the same session can load the dashboard shell
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -b "$JAR" "$BASE/")
chk "authenticated session can load the UI" "$code" "200"

rm -f "$JAR" /tmp/login.json
echo "auth test: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
