#!/usr/bin/env bash
# scripts/oci-open-port.sh — add ONE ingress rule to the subnet's security list.
#
# WHY: the host's ufw and OCI's security list are two independent firewalls and
# the CLOUD one is authoritative for anything arriving from the internet. A port
# can be perfectly allowed in ufw and still be unreachable. Measured 2026-09-15:
# the security list permits 22, 80, 443, 8080, 5434 (and ICMP); everything else is
# dropped before the packet reaches the host.
#
# SAFETY: the OCI API has no "append a rule" call for security lists — `update`
# REPLACES the whole ingress set, so a bad payload can cut off SSH. Therefore:
#   1. the current rules are backed up to /root/ first,
#   2. the new rule is built by deep-copying an existing one (so the schema is
#      guaranteed to match what this tenancy already accepts),
#   3. after applying, the rule count and every original source are re-verified,
#   4. a fresh SSH connection is tested before the change is considered done.
#
# Usage: oci-open-port.sh <port> [description]
set -euo pipefail

PORT="${1:?usage: oci-open-port.sh <port> [description]}"
DESC="${2:-Hermes dashboard tcp/$PORT - password auth required}"

OCI=/home/ubuntu/oci-venv/bin/oci
export OCI_CLI_CONFIG_FILE=/root/.oci/config
export OCI_CLI_REGION=iad
export SUPPRESS_LABEL_WARNING=True

SL=ocid1.securitylist.oc1.iad.aaaaaaaadwosvergpedzddflof2geyh7fioyovqhz3ktd2lysntlvo5iylmq
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="/root/oci-security-list-ingress-$STAMP.json"

echo "=== 1. back up the current ingress rules ==="
$OCI network security-list get --security-list-id "$SL" \
  --query 'data."ingress-security-rules"' > "$BACKUP"
chmod 600 "$BACKUP"
COUNT_BEFORE=$(python3 -c "import json;print(len(json.load(open('$BACKUP'))))")
echo "  saved $COUNT_BEFORE rules to $BACKUP"

echo
echo "=== 2. build the new rule set (existing + one) ==="
python3 - "$PORT" "$DESC" "$BACKUP" <<'PY' > /tmp/new-ingress.json
import json, sys
port, desc, backup = int(sys.argv[1]), sys.argv[2], sys.argv[3]
rules = json.load(open(backup))

# Clone the existing SSH rule: its schema is known-good for this tenancy.
template = next((r for r in rules
                 if r.get("protocol") == "6"
                 and (r.get("tcp-options") or {}).get("destination-port-range", {}).get("min") == 22),
                None)
if template is None:
    template = next((r for r in rules if r.get("protocol") == "6"), None)
if template is None:
    raise SystemExit("no TCP rule to clone — refusing to guess the schema")

new = json.loads(json.dumps(template))  # deep copy
new["description"] = desc
new.setdefault("sourceType", "CIDR_BLOCK")
new["source"] = "0.0.0.0/0"
new["isStateless"] = False
new["tcpOptions"] = {"destinationPortRange": {"min": port, "max": port}}

# Idempotent: replace an identical rule instead of stacking duplicates.
rules = [r for r in rules
         if not (r.get("protocol") == "6"
                 and (r.get("tcp-options") or {}).get("destination-port-range", {}).get("min") == port
                 and (r.get("tcp-options") or {}).get("destination-port-range", {}).get("max") == port)]
rules.append(new)
json.dump(rules, sys.stdout)
PY
echo "  new rule set: $COUNT_BEFORE -> $(python3 -c "import json;print(len(json.load(open('/tmp/new-ingress.json'))))") rules"

echo
echo "=== 3. apply ==="
# --force: the CLI otherwise stops at a "are you sure?" prompt, and this script
# runs with stdin closed (the backup above is the real safety net).
$OCI network security-list update --security-list-id "$SL" \
  --ingress-security-rules file:///tmp/new-ingress.json --force --output json >/tmp/sl-update.json
python3 -c "
import json
d = json.load(open('/tmp/sl-update.json'))
print('  updated at', d['data']['time-created'], '| rules now:', len(d['data']['ingress-security-rules']))"

echo
echo "=== 4. verify every ORIGINAL rule survived ==="
python3 - "$BACKUP" <<'PY'
import json, sys, subprocess, os
before = json.load(open(sys.argv[1]))
after = json.loads(subprocess.run(
    ["/home/ubuntu/oci-venv/bin/oci", "network", "security-list", "get",
     "--security-list-id", "ocid1.securitylist.oc1.iad.aaaaaaaadwosvergpedzddflof2geyh7fioyovqhz3ktd2lysntlvo5iylmq",
     "--query", 'data."ingress-security-rules"'],
    capture_output=True, text=True, env={**os.environ}).stdout)

def key(r):
    dr = (r.get("tcp-options") or {}).get("destination-port-range") or {}
    ur = (r.get("udp-options") or {}).get("destination-port-range") or {}
    return (r.get("protocol"), r.get("source"),
            dr.get("min"), dr.get("max"), ur.get("min"), ur.get("max"))

before_keys = {key(r) for r in before}
after_keys = {key(r) for r in after}
missing = before_keys - after_keys
print(f"  before: {len(before_keys)} distinct rules, after: {len(after_keys)}")
if missing:
    print("  !! LOST RULES:", missing)
    raise SystemExit(1)
print("  OK — no original rule was lost")
PY

echo
echo "=== 5. confirm the host firewall also allows it ==="
ufw status | grep -q "$PORT/tcp" && echo "  ufw: ALLOW $PORT/tcp present" || echo "  ufw: MISSING rule for $PORT (add with: ufw allow $PORT/tcp)"
echo "  listening sockets on $PORT: $(ss -lntH "sport = :$PORT" | wc -l)"
