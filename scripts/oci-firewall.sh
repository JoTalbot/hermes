#!/usr/bin/env bash
# scripts/oci-firewall.sh — inspect and open ONE ingress port on this instance.
#
# WHY THIS EXISTS: ufw can allow a port and it still be unreachable, because OCI
# filters ingress at the VCN level (security lists + NSGs) before the packet
# reaches the host. Measured 2026-09-15: from six independent external nodes, only
# 22/tcp was reachable — 80, 443, 8080, 8095, 9119, 9600, 10010 were all filtered.
# The box is closed to the internet by design; 80/443 work only because Cloudflare
# is separately allow-listed.
#
# Uses /root/.oci/config ONLY (the ubuntu user's key belongs to a different
# tenancy and returns 401 for this instance — verified).
#
# Usage:
#   oci-firewall.sh                  # inspect, change nothing
#   oci-firewall.sh allow 9119       # add one ingress rule, TCP from 0.0.0.0/0
set -uo pipefail

OCI=/home/ubuntu/oci-venv/bin/oci
export OCI_CLI_CONFIG_FILE=/root/.oci/config
export OCI_CLI_REGION=iad
export SUPPRESS_LABEL_WARNING=True

META=$(curl -s -m 5 -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/)
IID=$(printf '%s' "$META" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
CID=$(printf '%s' "$META" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("compartmentId",""))')

VNIC=$($OCI compute vnic-attachment list --compartment-id "$CID" --instance-id "$IID" \
       --query 'data[0]."vnic-id"' --output raw 2>/dev/null)
SUBNET=$($OCI network vnic get --vnic-id "$VNIC" --query 'data."subnet-id"' --output raw 2>/dev/null)
NSGS=$($OCI network vnic get --vnic-id "$VNIC" --query 'data."nsg-ids"[]' --output raw 2>/dev/null)

echo "instance : $(printf '%s' "$META" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("displayName"))')  (${IID:0:34}…)"
echo "subnet   : ${SUBNET:0:44}…"
echo "nsg count: $(printf '%s' "$NSGS" | grep -c . )"

show_rules() {
  echo
  echo "=== NSG rules (authoritative when an NSG is attached) ==="
  for NSG in $NSGS; do
    echo "--- ${NSG:0:34}…"
    $OCI network nsg rules list --nsg-id "$NSG" \
      --query 'data[].{dir:direction,proto:protocol,src:source,dst:destination,tcp:"tcp-options",udp:"udp-options"}' \
      --output json 2>/dev/null | python3 -c '
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    print("    (unreadable)"); raise SystemExit
for r in rows:
    if r.get("dir") != "INGRESS":
        continue
    ports = ""
    for k in ("tcp", "udp"):
        o = r.get(k) or {}
        dr = (o.get("destination-port-range") or {})
        if dr:
            ports = "{}:{}-{}".format(k, dr.get("min"), dr.get("max"))
    print("    INGRESS {} from {:<42} {}".format(r.get("proto"), str(r.get("src"))[:42], ports))
'
  done
}

show_seclists() {
  echo
  echo "=== Security-list ingress (used when no NSG is attached) ==="
  for SL in $($OCI network subnet get --subnet-id "$SUBNET" --query 'data."security-list-ids"[]' --output raw 2>/dev/null); do
    echo "--- ${SL:0:34}…"
    $OCI network security-list get --security-list-id "$SL" \
      --query 'data."ingress-security-rules"[]' --output json 2>/dev/null | python3 -c '
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    print("    (unreadable)"); raise SystemExit
for r in rows:
    ports = ""
    o = r.get("tcp-options") or {}
    dr = o.get("destination-port-range") or {}
    if dr:
        ports = "tcp:{}-{}".format(dr.get("min"), dr.get("max"))
    print("    INGRESS {} from {:<42} {}".format(r.get("protocol"), str(r.get("source"))[:42], ports))
'
  done
}

case "${1:-inspect}" in
  inspect)
    show_rules
    show_seclists
    ;;
  allow)
    PORT="${2:?usage: oci-firewall.sh allow <port>}"
    echo
    echo "opening ingress tcp/$PORT from 0.0.0.0/0"
    if [[ -n "$NSGS" ]]; then
      for NSG in $NSGS; do
        $OCI network nsg rules add --nsg-id "$NSG" --security-rules "[{
          \"direction\": \"INGRESS\", \"protocol\": \"6\", \"isStateless\": false,
          \"source\": \"0.0.0.0/0\", \"sourceType\": \"CIDR_BLOCK\",
          \"description\": \"Hermes dashboard tcp/$PORT - password auth required\",
          \"tcpOptions\": {\"destinationPortRange\": {\"min\": $PORT, \"max\": $PORT}}}]" \
          --output table 2>&1 | tail -4
      done
    else
      for SL in $($OCI network subnet get --subnet-id "$SUBNET" --query 'data."security-list-ids"[]' --output raw 2>/dev/null); do
        CUR=$($OCI network security-list get --security-list-id "$SL" --query 'data."ingress-security-rules"' 2>/dev/null)
        printf '%s' "$CUR" | python3 -c "
import sys, json
rules = json.load(sys.stdin)
rules.append({'protocol': '6', 'isStateless': False, 'source': '0.0.0.0/0',
              'sourceType': 'CIDR_BLOCK',
              'description': 'Hermes dashboard tcp/$PORT - password auth required',
              'tcpOptions': {'destinationPortRange': {'min': $PORT, 'max': $PORT}}})
print(json.dumps(rules))" > /tmp/sl-rules.json
        $OCI network security-list update --security-list-id "$SL" \
          --ingress-security-rules file:///tmp/sl-rules.json --output table 2>&1 | tail -4
      done
    fi
    ;;
esac
