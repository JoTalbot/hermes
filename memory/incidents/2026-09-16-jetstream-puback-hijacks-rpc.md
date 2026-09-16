# 2026-09-16 — JetStream PubAck hijacked request/reply

## FACT
The first cross-process RPC test on the Agent Bus returned this as the "agent's answer":

    {"stream":"AGENT_BUS", "seq":6}

## Why
`nc.request(subject, ...)` publishes with a reply inbox. The subject `hermes.rpc.<agent>` was
inside the JetStream stream's subject space (`hermes.>`), and the server answers **any**
publish-with-reply-subject inside a stream with a PubAck. The ack beat the real responder
(0.06 s vs ~1 s).

## Fix
Request/reply moved OUTSIDE the stream: `hermesrpc.rpc.<agent>`. RPC is synchronous and
bounded by a timeout, so it needs no durable history. The stream keeps `hermes.>`.

## LESSON
A transport ack is not an application answer. When two mechanisms can reply on one
channel, the fast one silently wins — pin the fallback and the timeout to the ANSWER
SHAPE, not to the fact that *something* came back.

## Verified
`tests/bus-selftest.sh` check 6 asserts the reply contains an agent envelope;
check 7 asserts an unknown peer *times out* (exit 2) instead of being "answered".
