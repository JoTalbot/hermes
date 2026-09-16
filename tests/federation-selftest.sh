#!/usr/bin/env bash
# federation-selftest.sh — proves TWO nodes really form a federation.
#
# Run on the PRIMARY node with the peer reachable on the bus.
#   sudo NODE2=hermes-node-02 bash /opt/hermes/tests/federation-selftest.sh
#
# Checks
#   1  two nodes are visible on the bus (JetStream consumer per node + nodes.json)
#   2  cross-node call: primary → peer agent (a different host answers)
#   3  cross-node call: peer → primary agent
#   4  broadcast from the peer is mirrored into the primary's local board
#   5  offline replay: a peer that was down receives what it missed
#   6  local autonomy: the peer keeps working while the primary's agents are stopped
set -uo pipefail
NODE2="${NODE2:-hermes-node-02}"
PEER_PREFIX="${PEER_PREFIX:-node-arm-02}"
PASS=0; FAIL=0
ok(){ echo "  PASS  $*"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
export NATS_TOKEN="$(sed -n 's/^NATS_TOKEN=//p' /etc/hermes/nats.env)"
GW="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)"
peer(){ docker exec -e NATS_TOKEN="$NATS_TOKEN" -e NATS_URL="nats://$GW:4222" "$NODE2" \
          bash -lc "export NATS_TOKEN NATS_URL; $*"; }
TAG="fed-$(date -u +%H%M%S)"

echo "=== 1. both nodes visible on the bus ==="
NODES="$(hermes-bus nodes)"
echo "$NODES" | grep -q "$PEER_PREFIX" && ok "peer $PEER_PREFIX is in nodes.json" \
  || bad "peer not in nodes.json: $(echo "$NODES" | tr '\n' ' ')"
hermes-bus-bridge status | grep -q "consumer node-" && ok "primary has its own durable consumer" \
  || bad "primary has no durable consumer"
peer "hermes-bus-bridge status" | grep -q "consumer" && ok "peer has its own durable consumer" \
  || bad "peer has no durable consumer (offline replay would not work)"

echo "=== 2. primary → peer agent (answered by the other host) ==="
OUT="$(hermes-bus request --to "$PEER_PREFIX/server-guardian" --timeout 60 "status" 2>&1)"
if echo "$OUT" | grep -q "reply in"; then
  echo "$OUT" | grep -q "failed\|error" && bad "peer agent replied with an error: $(echo "$OUT"|tail -2|tr '\n' ' ')" \
    || ok "peer agent answered: $(echo "$OUT" | sed -n 2p | cut -c1-80)"
else bad "no answer from the peer agent: $(echo "$OUT" | head -2 | tr '\n' ' ')"; fi

echo "=== 3. peer → primary agent ==="
OUT="$(peer "hermes-bus request --to server-guardian --timeout 60 identity" 2>&1)"
echo "$OUT" | grep -q "reply in" && ok "primary agent answered the peer" \
  || bad "primary agent did not answer: $(echo "$OUT" | head -2 | tr '\n' ' ')"

echo "=== 4. broadcast from the peer reaches the primary's local board ==="
peer "hermes-bus post --channel knowledge --kind event --priority normal 'fedtest $TAG from peer'" >/dev/null
sleep 5
hermes-bus read --channel knowledge -n 30 | grep -q "fedtest $TAG from peer" \
  && ok "peer broadcast visible on the primary (durable local mirror)" \
  || bad "peer broadcast missing on the primary"

echo "=== 5. offline replay for a node that was down ==="
peer "/opt/hermes/deploy/nosystemd/ctl.sh stop bus-bridge" | tail -1
sleep 1
hermes-bus post --channel incidents --kind event --priority normal "offline-for-peer $TAG" >/dev/null
sleep 1
peer "/opt/hermes/deploy/nosystemd/ctl.sh start bus-bridge" >/dev/null
sleep 10
peer "hermes-bus read --channel incidents -n 40" | grep -q "offline-for-peer $TAG" \
  && ok "peer received the message it missed while offline" \
  || bad "peer lost the message published during its downtime"

echo "=== 6. local autonomy while the primary's agents are stopped ==="
systemctl stop hermes-agents
sleep 1
peer "hermes-bus request --to $PEER_PREFIX/server-guardian --timeout 60 ping" | grep -q "reply in" \
  && ok "peer agents keep serving with the primary's runtime down" \
  || bad "peer agents stopped working when the primary went down"
peer "hermes-bus read --channel server -n 40" | grep -q "узел $PEER_PREFIX" \
  && ok "peer local state (its own board) is intact" || bad "peer local board looks empty"
systemctl start hermes-agents
sleep 3
systemctl is-active --quiet hermes-agents && ok "primary runtime restarted" || bad "primary runtime did not restart"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
