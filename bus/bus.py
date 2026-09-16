#!/usr/bin/env python3
"""bus.py — the Agent Bus CLI: one interface for agent-to-agent messaging.

ARCHITECTURE (why two layers, not one)
--------------------------------------
* **Transport: NATS JetStream** (`hermes.>` subjects). This is what makes the bus
  *distributed*: pub/sub fan-out, direct messages, core-NATS request/reply, and a
  JetStream stream that keeps a replayable history so a node that was offline
  catches up instead of silently missing messages.
* **Local durability: the Hermes kanban board** (`agents-chat`). Every message is
  also written into the local board as a comment on its channel's room. That gives
  three things NATS alone does not: history that survives a bus outage, a surface
  agents already know (`kanban_show`), and a UI — the dashboard's Kanban tab.
  This is the "local state must survive a dead control plane" requirement.

The two layers are deliberately independent: if NATS is down, `post` still writes
locally and reports `transport=degraded`; if the local board is unavailable, the
message still goes out on the wire. Neither failure loses the message silently.

MESSAGE ENVELOPE (structured data on the wire and in the mirror)
---------------------------------------------------------------
{"id","ts","node","server","from","to","channel","kind","priority",
 "correlation_id","refs":[],"audience","text"}

Kinds: event | decision | task | result | error | status | request | reply
Priorities: low | normal | high | urgent  (mapped onto the NATS subject suffix,
so a subscriber can filter by priority without parsing bodies)

Usage
-----
  bus.py post  --channel security --kind decision "текст" [--priority high]
                [--correlation <id>] [--ref <path-or-url> ...]
  bus.py dm    --to github-agent "текст"
  bus.py request --to monitoring-agent --timeout 20 "дай статус диска"
  bus.py reply --correlation <id> --to monitoring-agent "ответ"
  bus.py read  [--channel security] [-n 20] [--json]
  bus.py inbox [--agent <id>] [-n 20]
  bus.py channels
  bus.py nodes
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

CHANNELS = ["general", "orchestrator", "server", "github", "security",
            "monitoring", "projects", "incidents", "knowledge"]
KINDS = ["event", "decision", "task", "result", "error", "status", "request", "reply"]
PRIORITIES = ["low", "normal", "high", "urgent"]

BOARD = "agents-chat"
# Both are overridable so the same bus code runs on a node where Hermes lives elsewhere
# (e.g. a container node with its own HERMES_HOME) instead of forking the code path.
HERMES_HOME = os.environ.get("HERMES_HOME", "/home/hermes/.hermes")
HERMES_BIN = os.environ.get("HERMES_BIN", "/home/hermes/.hermes-venv/bin/hermes")
NATS_ENV = "/etc/hermes/nats.env"
STATE_DIR = Path("/var/lib/hermes-bus")
SUBJECT_PREFIX = "hermes"
# Request/reply lives OUTSIDE the JetStream subject space on purpose. The server answers
# any publish-with-reply-subject inside a stream with a JetStream PubAck
# ({"stream":..,"seq":..}), which races the real responder and wins in ~60 ms — the
# first federation RPC test came back with that ack instead of the agent's answer.
# RPC is synchronous and bounded by a timeout, so it needs no durable history anyway.
RPC_PREFIX = "hermesrpc.rpc"


# ── identity ────────────────────────────────────────────────────────────────
def server_id() -> str:
    """Stable node identity: the same value scripts/register-server.sh mints."""
    m = Path("/opt/hermes/config/servers/arm-server-01.yaml")
    if m.exists():
        for line in m.read_text().splitlines():
            if line.startswith("server_id:"):
                return line.split(":", 1)[1].strip()
    return os.uname().nodename


def node_name() -> str:
    return os.uname().nodename


def default_agent() -> str:
    """Who is speaking when nothing says otherwise.

    A message from a shell on a node is a human action, so it is attributed to the human
    on that node — "unknown" in the chat history was unreadable and, worse, useless for
    auditing who did what.
    """
    return (os.environ.get("HERMES_PROFILE")
            or os.environ.get("HERMES_AGENT_ID")
            or os.environ.get("USER")
            or os.environ.get("LOGNAME")
            or f"human@{server_id()}")


def nats_conf() -> tuple[str, str]:
    """(url, token). Raises with a readable message when the bus is not configured."""
    url, token = os.environ.get("NATS_URL", ""), os.environ.get("NATS_TOKEN", "")
    if not (url and token) and Path(NATS_ENV).exists():
        for line in Path(NATS_ENV).read_text().splitlines():
            if line.startswith("NATS_URL="):
                url = url or line.split("=", 1)[1].strip()
            elif line.startswith("NATS_TOKEN="):
                token = token or line.split("=", 1)[1].strip()
    if not url:
        url = "nats://127.0.0.1:4222"
    if not token:
        raise SystemExit("no NATS_TOKEN: set it in the environment or in " + NATS_ENV)
    return url, token


# ── envelope ────────────────────────────────────────────────────────────────
def envelope(*, channel: str | None, to: str | None, kind: str, text: str,
             priority: str = "normal", correlation: str | None = None,
             refs: list[str] | None = None, audience: str | None = None,
             agent: str | None = None) -> dict:
    if kind not in KINDS:
        raise SystemExit(f"unknown kind {kind!r}; expected one of {KINDS}")
    if priority not in PRIORITIES:
        raise SystemExit(f"unknown priority {priority!r}; expected one of {PRIORITIES}")
    if channel and channel.lstrip("#") not in CHANNELS:
        raise SystemExit(f"unknown channel {channel!r}; known: {', '.join(CHANNELS)}")
    return {
        "id": uuid.uuid4().hex[:12],
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "node": server_id(),
        "server": node_name(),
        "from": agent or default_agent(),
        "to": to,
        "channel": (channel.lstrip("#") if channel else None),
        "kind": kind,
        "priority": priority,
        "correlation_id": correlation,
        "refs": refs or [],
        "audience": audience,
        "text": text,
    }


def subject_for(env: dict) -> str:
    # Priority rides in the subject so subscribers can filter cheaply.
    if env["to"]:
        return f"{SUBJECT_PREFIX}.dm.{env['to']}.{env['priority']}"
    return f"{SUBJECT_PREFIX}.chat.{env['channel']}.{env['priority']}"


# ── local durable mirror (kanban board agents-chat) ─────────────────────────
def _as_hermes(cmd: list[str], timeout: int = 45) -> subprocess.CompletedProcess:
    """Run a hermes CLI call.

    On arm-server-01 the daemon runs as root while the board is 0700 hermes:hermes, so the
    call is wrapped in `sudo -u hermes`. When HERMES_HOME is set explicitly (a container
    node, a test harness, another operator's home) the caller has already decided whose
    home it is, and sudo would fight that decision.
    """
    explicit_home = "HERMES_HOME" in os.environ
    if os.geteuid() == 0 and not explicit_home and os.environ.get("USER") != "hermes":
        cmd = ["sudo", "-u", "hermes", "-H", "env", f"HERMES_HOME={HERMES_HOME}"] + cmd
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    env = dict(os.environ, HERMES_HOME=HERMES_HOME)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def _ledger_path() -> Path:
    return STATE_DIR / f"mirrored-{server_id()}.txt"


def _ledger_has(mid: str) -> bool:
    p = _ledger_path()
    if not p.exists():
        return False
    return mid in set(p.read_text().split())


def _ledger_add(mid: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with _ledger_path().open("a") as fh:
        fh.write(mid + "\n")


def _json_id(raw: str) -> str | None:
    raw = raw.strip()
    for candidate in (raw, raw.splitlines()[-1] if raw else ""):
        try:
            data = json.loads(candidate)
        except Exception:
            continue
        if isinstance(data, dict) and data.get("id"):
            return data["id"]
    return None


def _room_cache() -> dict:
    p = STATE_DIR / "rooms.json"
    try:
        return json.loads(p.read_text()) if p.exists() else {}
    except Exception:
        return {}


def _room_cache_put(channel: str, tid: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    c = _room_cache()
    c[channel] = tid
    (STATE_DIR / "rooms.json").write_text(json.dumps(c, indent=2))


def _room_cache_drop(channel: str) -> None:
    c = _room_cache()
    if channel in c:
        del c[channel]
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / "rooms.json").write_text(json.dumps(c, indent=2))


def room_task_id(channel: str, refresh: bool = False) -> str | None:
    """Resolve/create the room task for a channel.

    The id is stable via --idempotency-key, so creating again is safe; the cache only
    exists to keep the hot path (one message) to a single hermes CLI call.
    """
    cached = None if refresh else _room_cache().get(channel)
    if cached:
        return cached
    cp = _as_hermes([HERMES_BIN, "kanban", "--board", BOARD, "create", f"room: {channel}",
                     "--body", f"Канал #{channel} шины агентов (Agent Bus). Сообщения — комментарии.",
                     "--created-by", "agent-bus", "--idempotency-key", f"room-{channel}",
                     "--json"])
    if cp.returncode != 0:
        return None
    # NB: `kanban create --json` pretty-prints across many lines, so parse the WHOLE
    # stdout first and only then fall back to the last line (the single-line case).
    tid = _json_id(cp.stdout)
    if not tid:
        return None
    if tid:
        _room_cache_put(channel, tid)
    return tid


def mirror_line(env: dict) -> str:
    # Defensive: envelopes from other tools/older versions may lack any of these fields.
    head = (f"[{env.get('kind') or 'event'}·{env.get('priority') or 'normal'}"
            f"·{env.get('from') or 'unknown'}·{env.get('node') or 'unknown'}")
    if env.get("correlation_id"):
        head += f"·corr={env['correlation_id']}"
    head += f"·{env.get('id') or 'noid'}]"
    body = f"{head} {env.get('text') or ''}"
    if env.get("refs"):
        body += "\nrefs: " + ", ".join(env["refs"])
    return body


def log_mirror_error(channel: str, cp) -> None:
    """Print why a mirror failed. Silence here cost an hour of guessing."""
    err = " ".join((cp.stderr or cp.stdout or "").strip().split())[:300]
    print(f"[bus] mirror failed for #{channel}: exit={cp.returncode} {err}", flush=True)


def mirror_local(env: dict) -> bool:
    """Write the message into the local durable board — exactly once per node.

    Both the publishing CLI and the bridge daemon see the same message (the bridge gets
    it back over NATS). A shared, flock-guarded ledger decides who writes it, so the
    board does not accumulate duplicates and the chat stays readable.
    """
    import fcntl
    # The bus is a shared namespace: a message may come from another tool, another node
    # or an older envelope version, so never index blindly here — an exception in this
    # path used to abort the bridge's callback and leave the message unacked forever.
    channel = env.get("channel") or f"dm-{env.get('to') or 'unknown'}"
    mid = env.get("id") or ""
    if mid and _ledger_has(mid):
        return True
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / ".mirror.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if mid and _ledger_has(mid):
            return True
        tid = room_task_id(channel)
        if not tid:
            return False
        cp = _as_hermes([HERMES_BIN, "kanban", "--board", BOARD, "comment", tid,
                         mirror_line(env), "--author", env["from"]])
        if cp.returncode != 0:
            # The cached room id can be stale (board rebuilt, restored from another archive,
            # room deleted). A stale cache made EVERY message fail to mirror while the log
            # only said "board busy?" — so drop the cache and re-resolve once.
            _room_cache_drop(channel)
            tid = room_task_id(channel, refresh=True)
            if tid:
                cp = _as_hermes([HERMES_BIN, "kanban", "--board", BOARD, "comment", tid,
                                 mirror_line(env), "--author", env["from"]])
        if cp.returncode == 0 and mid:
            _ledger_add(mid)
        elif cp.returncode != 0:
            log_mirror_error(channel, cp)
        return cp.returncode == 0


def parse_mirror(line: str) -> dict | None:
    """Turn a stored comment back into an envelope-ish dict (best effort)."""
    m = re.match(r"\[(?P<kind>[a-z]+)·(?P<prio>[a-z]+)·(?P<frm>[^·]+)·(?P<node>[^·]+)"
                 r"(?:·corr=(?P<corr>[^·]+))?·(?P<id>[0-9a-f]+)\]\s*(?P<text>.*)", line, re.S)
    if not m:
        return None
    return m.groupdict()


# ── NATS transport ──────────────────────────────────────────────────────────
async def _publish(env: dict) -> str:
    import nats
    url, token = nats_conf()
    nc = await nats.connect(url, token=token, name=f"bus-cli-{env['from']}", connect_timeout=5)
    try:
        await nc.publish(subject_for(env), json.dumps(env).encode())
        await nc.flush(timeout=5)
    finally:
        await nc.close()
    return subject_for(env)


async def _request(env: dict, timeout: float) -> dict | None:
    import nats
    url, token = nats_conf()
    nc = await nats.connect(url, token=token, name=f"bus-rpc-{env['from']}", connect_timeout=5)
    try:
        inbox_subject = f"{RPC_PREFIX}.{env['to']}"
        msg = await nc.request(inbox_subject, json.dumps(env).encode(), timeout=timeout)
        return json.loads(msg.data.decode())
    except Exception:
        return None
    finally:
        await nc.close()


def publish(env: dict) -> tuple[bool, str, bool]:
    """Publish on the wire AND mirror locally. Returns (wire_ok, detail, mirror_ok)."""
    wire_ok, detail = False, ""
    try:
        subject = asyncio.run(_publish(env))
        wire_ok, detail = True, subject
    except Exception as e:  # transport down is not a reason to lose the message
        detail = f"{type(e).__name__}: {e}"
    mirror_ok = mirror_local(env)
    return wire_ok, detail, mirror_ok


# ── commands ────────────────────────────────────────────────────────────────
def cmd_post(a) -> int:
    env = envelope(channel=a.channel, to=None, kind=a.kind, text=a.text,
                   priority=a.priority, correlation=a.correlation, refs=a.ref,
                   audience=a.audience)
    wire, detail, mirror = publish(env)
    status = "sent" if wire else "degraded (local mirror only)"
    print(f"{env['id']} #{env['channel']} {env['kind']}/{env['priority']} -> {status}")
    print(f"  transport: {'nats ' + detail if wire else detail}")
    print(f"  mirror:    {'board ' + BOARD if mirror else 'FAILED'}")
    return 0 if (wire or mirror) else 1


def cmd_dm(a) -> int:
    env = envelope(channel=None, to=a.to, kind=a.kind, text=a.text,
                   priority=a.priority, correlation=a.correlation, refs=a.ref)
    wire, detail, mirror = publish(env)
    print(f"{env['id']} dm->{a.to} {env['kind']}/{env['priority']} -> "
          f"{'sent' if wire else 'degraded'}")
    print(f"  transport: {'nats ' + detail if wire else detail}")
    return 0 if (wire or mirror) else 1


def cmd_request(a) -> int:
    env = envelope(channel=None, to=a.to, kind="request", text=a.text,
                   priority=a.priority, correlation=a.correlation or uuid.uuid4().hex[:12],
                   refs=a.ref)
    mirror_local(env)
    started = time.time()
    reply = asyncio.run(_request(env, a.timeout))
    if reply is None:
        print(f"{env['id']} request -> NO REPLY within {a.timeout}s "
              f"(corr={env['correlation_id']})")
        return 2
    print(f"{env['id']} request -> reply in {time.time() - started:.2f}s "
          f"from {reply.get('from')} (corr={reply.get('correlation_id')})")
    print(f"  {reply.get('text', '')[:400]}")
    return 0


def cmd_reply(a) -> int:
    env = envelope(channel=None, to=a.to, kind="reply", text=a.text,
                   priority=a.priority, correlation=a.correlation, refs=a.ref)
    wire, detail, mirror = publish(env)
    print(f"{env['id']} reply corr={a.correlation} -> {'sent' if wire else 'degraded'}")
    return 0 if (wire or mirror) else 1


def _read_local(channel: str, limit: int) -> list[dict]:
    tid = None
    cp = _as_hermes([HERMES_BIN, "kanban", "--board", BOARD, "list", "--json"])
    if cp.returncode == 0:
        try:
            rows = json.loads(cp.stdout)
            rows = rows if isinstance(rows, list) else rows.get("tasks", [])
            for r in rows:
                if str(r.get("title", "")) == f"room: {channel}":
                    tid = r["id"]
                    break
        except Exception:
            pass
    if not tid:
        return []
    cp = _as_hermes([HERMES_BIN, "kanban", "--board", BOARD, "show", tid, "--json"])
    if cp.returncode != 0:
        return []
    try:
        d = json.loads(cp.stdout)
    except Exception:
        return []
    out = []
    for c in (d.get("comments") or [])[-limit:]:
        p = parse_mirror(c.get("body") or "")
        if p:
            p["author"] = c.get("author")
            p["ts"] = c.get("created_at") or c.get("updated_at") or ""
            out.append(p)
    return out


def cmd_read(a) -> int:
    chans = [a.channel.lstrip("#")] if a.channel else CHANNELS
    for ch in chans:
        rows = _read_local(ch, a.n)
        print(f"# {ch}  ({len(rows)} shown)")
        for r in rows:
            print(f"  {str(r.get('ts') or '')[11:19]:<8} {r['kind']:>8}/{r['prio']:<6} "
                  f"{r['frm']:<16} {r['text'].strip()[:140]}")
        print()
    return 0


def cmd_inbox(a) -> int:
    me = a.agent or default_agent()
    url, token = nats_conf()
    rows = []
    for ch in CHANNELS:
        for r in _read_local(ch, 50):
            if r["frm"] == me:
                continue
            if r.get("kind") in ("request", "reply") or f"@{me}" in r["text"]:
                rows.append((ch, r))
    for ch, r in rows[-a.n:]:
        print(f"#{ch:<12} {r['kind']:>8} from {r['frm']:<16} {r['text'].strip()[:120]}")
    if not rows:
        print(f"inbox for {me}: nothing addressed to it")
    return 0


def cmd_channels(a) -> int:
    print("channels:")
    for ch in CHANNELS:
        rows = _read_local(ch, 1)
        tid = room_task_id(ch)
        print(f"  #{ch:<12} room={tid or '-':<14} last={'yes' if rows else 'empty'}")
    return 0


def cmd_digest(a) -> int:
    """One screen for the phone: what happened, per channel, facts only."""
    print(f"GLOBAL CHAT digest · узел {server_id()} · {datetime.now(timezone.utc):%Y-%m-%d %H:%M}Z")
    total = 0
    for ch in CHANNELS:
        rows = _read_local(ch, a.n)
        if not rows:
            print(f"  #{ch:<12} —")
            continue
        total += len(rows)
        authors: dict[str, int] = {}
        for r in rows:
            authors[r["frm"]] = authors.get(r["frm"], 0) + 1
        top = ", ".join(f"{k}×{v}" for k, v in sorted(authors.items(), key=lambda x: -x[1])[:3])
        last = rows[-1]
        print(f"  #{ch:<12} {len(rows):>3} сообщ.  [{top}]")
        print(f"      последнее: {last['kind']}/{last['prio']} {last['frm']}: "
              f"{last['text'].strip()[:110]}")
    print(f"\nвсего показано: {total} сообщений (по {a.n} на канал)")
    return 0


def cmd_nodes(a) -> int:
    d = STATE_DIR / "nodes.json"
    if not d.exists():
        print("no nodes registered on the bus yet")
        return 0
    nodes = json.loads(d.read_text())
    for key, n in sorted(nodes.items()):
        # Fields can be missing: any node publishing a hand-made envelope registers a
        # partial entry. Formatting must not decide whether the operator sees the list.
        print(f"  {str(n.get('node') or key):<28} {str(n.get('server') or '?'):<18} "
              f"msgs={n.get('msgs', '?')} last_seen={n.get('last_seen') or '?'}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="bus", description="Agent Bus CLI (NATS + local mirror)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_common(p, correlation=True):
        p.add_argument("--priority", choices=PRIORITIES, default="normal")
        if correlation:   # `reply` declares --correlation itself (it is required there)
            p.add_argument("--correlation", default=None)
        p.add_argument("--ref", action="append", default=[])

    p = sub.add_parser("post"); p.add_argument("--channel", required=True)
    p.add_argument("--kind", default="event", choices=KINDS)
    p.add_argument("--audience", default=None)
    add_common(p); p.add_argument("text"); p.set_defaults(f=cmd_post)

    p = sub.add_parser("dm"); p.add_argument("--to", required=True)
    p.add_argument("--kind", default="event", choices=KINDS)
    add_common(p); p.add_argument("text"); p.set_defaults(f=cmd_dm)

    p = sub.add_parser("request"); p.add_argument("--to", required=True)
    p.add_argument("--timeout", type=float, default=20)
    add_common(p); p.add_argument("text"); p.set_defaults(f=cmd_request)

    p = sub.add_parser("reply"); p.add_argument("--correlation", required=True)
    p.add_argument("--to", required=True)
    add_common(p, correlation=False); p.add_argument("text"); p.set_defaults(f=cmd_reply)

    p = sub.add_parser("read"); p.add_argument("--channel", default=None)
    p.add_argument("-n", type=int, default=10); p.set_defaults(f=cmd_read)

    p = sub.add_parser("inbox"); p.add_argument("--agent", default=None)
    p.add_argument("-n", type=int, default=20); p.set_defaults(f=cmd_inbox)

    p = sub.add_parser("digest"); p.add_argument("-n", type=int, default=5)
    p.set_defaults(f=cmd_digest)

    sub.add_parser("channels").set_defaults(f=cmd_channels)
    sub.add_parser("nodes").set_defaults(f=cmd_nodes)

    a = ap.parse_args()
    return a.f(a)


if __name__ == "__main__":
    sys.exit(main())
