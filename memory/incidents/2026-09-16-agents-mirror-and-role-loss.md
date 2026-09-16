# 2026-09-16 — two ways a node silently stopped being useful

## A. Duplicate mirroring
Both the publishing CLI and the node's bridge see every message, so each message was written
to the local board twice. Fixed with a shared, flock-guarded ledger
(`/var/lib/hermes-bus/mirrored-<node>.txt`): whoever writes first wins; the other sees the id.

## B. A peer that answered as the primary
Restarting the peer's agents through a bare `docker exec` (no exported vars) dropped
`HERMES_AGENT_SCOPE=node`, so `node-arm-02`'s agents adopted the PRIMARY's bare names.
Two nodes, one address: `hermes-bus request --to server-guardian` could be answered by a
container. Fixed by persisting the role in `/etc/hermes/node.env` and reading it in the
runtime and in every install/ctl path.

## C. A stale room cache that failed silently
A cached room-task id that no longer existed made EVERY mirror fail. The log said
"board busy?" — a guess — and the messages stayed unacked forever. Fixed: on a failed
comment the cache entry is dropped, the room is re-resolved once, and the actual stderr is
printed (`log_mirror_error`). The consumer backlog then drains on its own.

## LESSON
A node that is "running" can be useless in three different ways at once — duplicating,
impersonating, or silently failing. Each of them needed a test that asserts BEHAVIOUR
(`tests/federation-selftest.sh`), not a check that a process exists.
