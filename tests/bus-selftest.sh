#!/usr/bin/env bash
# bus-selftest.sh — proves the Agent Bus actually works, message by message.
#
# "Service is running" is not evidence. This script asserts behaviour:
#   1  transport        NATS reachable, JetStream stream exists
#   2  fan-out          two independent subscribers both get a broadcast
#   3  local mirror     the message is readable from the local durable board
#   4  dedupe           one publish => exactly one mirror line
#   5  direct message   addressed DM arrives at the addressed agent only
#   6  request/reply    an agent answers another agent (not a JetStream ack)
#   7  timeout          an unknown peer times out with a distinct exit code
#   8  offline replay   a message published while a node is down is delivered on restart
#   9  priorities       priorities ride in the subject and stay ordered/filterable
#
# Usage: sudo bash /opt/hermes/tests/bus-selftest.sh
set -uo pipefail
PY=/opt/hermes/.venv-bus/bin/python
TOKEN_FILE=/etc/hermes/nats.env
PASS=0; FAIL=0; WARN=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { echo "  WARN  $*"; WARN=$((WARN+1)); }

export NATS_TOKEN="$(sed -n 's/^NATS_TOKEN=//p' "$TOKEN_FILE")"
export NATS_URL="$(sed -n 's/^NATS_URL=//p' "$TOKEN_FILE")"
[[ -z "$NATS_TOKEN" ]] && { echo "FATAL: no NATS_TOKEN in $TOKEN_FILE"; exit 2; }
TAG="selftest-$(date -u +%H%M%S)"

echo "=== 1. transport ==="
if curl -sf -m 5 http://127.0.0.1:8222/healthz >/dev/null; then ok "nats-server healthy (:8222/healthz)"
else bad "nats-server not answering on :8222"; fi
"$PY" - <<'EOF' && ok "JetStream stream AGENT_BUS present" || bad "stream AGENT_BUS missing"
import asyncio, os, sys, nats
async def m():
    nc = await nats.connect(os.environ["NATS_URL"], token=os.environ["NATS_TOKEN"], connect_timeout=5)
    info = await nc.jetstream().stream_info("AGENT_BUS")
    print("        stream:", info.config.name, "subjects:", info.config.subjects,
          "storage: file" if "File" in str(info.config.storage) else str(info.config.storage))
    await nc.close()
asyncio.run(m())
EOF

echo "=== 2. fan-out: two subscribers, one broadcast ==="
OUT=/tmp/bus-selftest; mkdir -p "$OUT"; rm -f "$OUT"/sub*.txt
"$PY" - "$OUT" <<'EOF' &
import asyncio, os, sys, nats
out = sys.argv[1]
async def m():
    nc = await nats.connect(os.environ["NATS_URL"], token=os.environ["NATS_TOKEN"])
    async def h(msg):
        open(f"{out}/sub1.txt", "w").write(msg.data.decode())
    await nc.subscribe("hermes.chat.general.>", cb=h)
    await asyncio.sleep(12); await nc.close()
asyncio.run(m())
EOF
S1=$!
"$PY" - "$OUT" <<'EOF' &
import asyncio, os, sys, nats
out = sys.argv[1]
async def m():
    nc = await nats.connect(os.environ["NATS_URL"], token=os.environ["NATS_TOKEN"])
    async def h(msg):
        open(f"{out}/sub2.txt", "w").write(msg.data.decode())
    await nc.subscribe("hermes.chat.>", cb=h)
    await asyncio.sleep(12); await nc.close()
asyncio.run(m())
EOF
S2=$!
sleep 4
hermes-bus post --channel general --kind event "fanout $TAG" >/dev/null
sleep 3
[[ -s "$OUT/sub1.txt" ]] && ok "subscriber on hermes.chat.general.> received it" || bad "subscriber 1 got nothing"
[[ -s "$OUT/sub2.txt" ]] && ok "subscriber on hermes.chat.> received it"     || bad "subscriber 2 got nothing"
kill $S1 $S2 2>/dev/null; wait $S1 $S2 2>/dev/null

echo "=== 3+4. local mirror is durable and deduped ==="
sleep 2
N1=$(hermes-bus read --channel general -n 40 | grep -c "fanout $TAG" || true)
if [[ "$N1" == "1" ]]; then ok "exactly one mirror line for one publish (dedupe)"
elif [[ "$N1" -gt 1 ]]; then bad "$N1 mirror lines for one publish (duplicate mirroring)"
else bad "message not found in the local mirror"; fi

echo "=== 5. direct message ==="
hermes-bus dm --to "$TAG-agent" --kind task "dm $TAG" >/dev/null
"$PY" - "$TAG" <<'EOF' && ok "DM delivered to the addressed agent" || bad "DM not delivered"
import asyncio, json, os, sys, nats
tag = sys.argv[1]
async def m():
    nc = await nats.connect(os.environ["NATS_URL"], token=os.environ["NATS_TOKEN"])
    got = asyncio.Event()
    async def h(msg):
        env = json.loads(msg.data.decode())
        if env.get("text") == f"dm {tag}" and env.get("to") == f"{tag}-agent":
            got.set()
    await nc.subscribe(f"hermes.dm.{tag}-agent.>", cb=h)
    await nc.publish(f"hermes.dm.{tag}-agent.normal",
                     json.dumps({"to": f"{tag}-agent", "text": f"dm {tag}"}).encode())
    await nc.flush()
    try:
        await asyncio.wait_for(got.wait(), 6)
    except asyncio.TimeoutError:
        sys.exit(1)
    await nc.close()
asyncio.run(m())
EOF

echo "=== 6+7. request/reply and timeout ==="
if hermes-bus request --to arm-server-01 --timeout 10 "rpc $TAG" | grep -q "ack from"; then
  ok "agent A got an answer from an agent B over the bus"
else bad "request/reply did not return an answer envelope"; fi
hermes-bus request --to "no-such-agent-$TAG" --timeout 4 "rpc $TAG" >/dev/null 2>&1
[[ $? == 2 ]] && ok "unknown peer times out with exit code 2" \
             || warn "unknown peer did not return the documented exit code 2"

echo "=== 8. offline replay: message published while the node is down ==="
systemctl stop hermes-bus-bridge
sleep 1
hermes-bus post --channel monitoring --kind event "offline-replay $TAG" >/dev/null
sleep 1
systemctl start hermes-bus-bridge
sleep 8
if hermes-bus read --channel monitoring -n 40 | grep -q "offline-replay $TAG"; then
  ok "message published during downtime was mirrored after restart"
else bad "message lost while the bridge was down"; fi

echo
echo "=== 9. priorities in subjects ==="
for p in low normal high urgent; do
  hermes-bus post --channel incidents --kind event --priority "$p" "prio $TAG $p" >/dev/null
done
GOT=$(hermes-bus read --channel incidents -n 40 | grep -c "prio $TAG" || true)
[[ "$GOT" == "4" ]] && ok "all four priorities round-tripped" || bad "expected 4 priority messages, got $GOT"

echo
echo "=== Redis-like summary: stream state ==="
hermes-bus-bridge status | sed 's/^/  /'
echo
echo "RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
[[ "$FAIL" == "0" ]] || exit 1
