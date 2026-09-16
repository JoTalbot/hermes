#!/usr/bin/env bash
# Security posture, read-only. Never prints secret values — only file modes and names.
set -uo pipefail
echo "FIREWALL"
if command -v ufw >/dev/null; then ufw status verbose 2>/dev/null | sed 's/^/  /' | head -25; fi
echo
echo "EXPOSED PORTS (0.0.0.0/* listeners)"
ss -lntH 2>/dev/null | awk '$4 ~ /(0\.0\.0\.0|\*):/ {print "  "$4"  pid="$6}' | sort -u
echo
echo "EXPECTED PUBLIC: 22 (ssh), 80/443 (nginx), 9119 (dashboard, basic-auth)"
echo
echo "SECRET FILE MODES"
for f in /etc/hermes/*.env /etc/hermes/*.password /etc/hermes/git-credentials /root/.oci/config /home/hermes/.hermes/config.yaml; do
  [ -e "$f" ] || continue
  mode=$(stat -c '%a %U:%G' "$f" 2>/dev/null)
  case "$(stat -c %a "$f")" in
    600|640|400) flag="ok" ;;
    *) flag="LOOSE" ;;
  esac
  printf "  %-42s %s  %s\n" "$f" "$mode" "$flag"
done
stat -c '  %n %a %U:%G' /etc/hermes 2>/dev/null
echo
echo "SSH CONFIG (summary)"
sshd -T 2>/dev/null | grep -E "^(passwordauthentication|permitrootlogin|pubkeyauthentication|port) " | sed 's/^/  /'
echo
echo "UPDATES"
if command -v apt-get >/dev/null; then
  echo "  security updates pending: $(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -ci security || echo '?')"
fi
systemctl is-active unattended-upgrades 2>/dev/null | sed 's/^/  unattended-upgrades: /'
echo
echo "DOCKER EXPOSURE (published on 0.0.0.0)"
docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E "0\.0\.0\.0" | sed 's/^/  /' || echo "  none"
echo
echo "REPO SECRET SCAN"
if [ -x /opt/hermes/tests/secret-scan.sh ]; then
  bash /opt/hermes/tests/secret-scan.sh --worktree 2>&1 | tail -3 | sed 's/^/  /'
fi
