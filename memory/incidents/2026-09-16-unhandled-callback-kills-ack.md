# 2026-09-16 — an exception in a JetStream callback meant "never ack"

## FACT
`KeyError: 'channel'` raised inside the bridge's message callback (a message without that
field) aborted the callback before `msg.ack()`. JetStream redelivered the message after
`ack_wait`, the callback crashed again, and the consumer's `ack_pending` grew without bound.

## Fix
* the whole callback body is wrapped: log the error and ACK (a message we cannot process
  must not be redelivered forever)
* `mirror_local` uses `.get()` everywhere: the bus is a shared namespace and other tools
  will publish partial envelopes
* agent handler logs use a sanitised filename — a node-scoped agent id contains "/", which
  turned a log path into a directory and failed the write

## LESSON
In an at-least-once system, "crash before ack" is an infinite loop, not a retry. Ack after
the work is durable; make the work total (no unguarded lookups) or accept a poison message.
