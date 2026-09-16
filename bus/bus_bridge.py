#!/usr/bin/env python3
"""bus_bridge.py — the node's connection to the global Agent Bus.

WHAT IT DOES
------------
1. Ensures the JetStream stream `AGENT_BUS` exists (subjects `hermes.>`, file storage,
   7-day window, bounded size) so history is replayable for a node that was offline.
2. Subscribes with a **durable consumer per node** (`node-<server_id>`): JetStream
   remembers the last acked message, so messages published while this node was down are
   delivered on reconnect — that is what makes "the control plane was down" a pause
   rather than a data loss.
3. Mirrors every inbound message into the LOCAL kanban board (unless this node already
   wrote it — dedupe by envelope id), which is the durable, offline-readable history and
   the surface the dashboard shows.
4. Tracks peer nodes in /var/lib/hermes-bus/nodes.json (last_seen, message count).
5. Forwards *meaningful* messages to Telegram when a chat is configured. Meaningful
   means: kind in {event, decision, task, result, error, status}, priority != low, and a
   per-minute rate cap. Internal model chatter never reaches the chat — the bus carries
   decisions and results, not token streams.
6. Optionally answers RPC (`--rpc-echo`) — used by the federation selftest to prove
   request/reply across nodes without pretending a real agent is behind it.

It never exits on a transport error: it reconnects with backoff. Local work must keep
running when the bus is unreachable (that is an explicit requirement, not politeness).

Usage
-----
  bus_bridge.py run                 # the daemon (systemd: hermes-bus-bridge.service)
  bus_bridge.py send "text"         # one-off Telegram send (for scripts/cron/alerts)
  bus_bridge.py discover            # find chats that have talked to the bot, persist them
  bus_bridge.py status              # what this node sees on the bus right now
  bus_bridge.py poll                # Telegram -> bus: run the owner's commands
                                    # (systemd: hermes-telegram-inbox.service)

DIRECTION 2: TELEGRAM -> BUS
----------------------------
The chat is a control plane, not only a feed. `poll` long-polls getUpdates and answers
commands from chats that `discover` has persisted. Rules that make it safe:

* Only allow-listed chats may command the node. An unknown chat is logged and ignored —
  a leaked bot token must not become a remote shell.
* The command set is a hard-coded dispatch table. Owner text is never interpolated into a
  shell; the only thing done with arbitrary text is publishing it on the bus (which is a
  message, not an execution).
* Replies go through tg_send, so the per-minute cap and the forum-topic routing apply.
* The update offset is persisted, so a restart does not replay yesterday's commands.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bus import CHANNELS, STATE_DIR, envelope, mirror_local, node_name, server_id  # noqa: E402

NATS_ENV = "/etc/hermes/nats.env"
TG_ENV = "/etc/hermes/telegram.env"
TG_CHATS = "/etc/hermes/telegram.chats.json"
STREAM = "AGENT_BUS"
SUBJECTS = "hermes.>"
MEANINGFUL_KINDS = {"event", "decision", "task", "result", "error", "status"}
RATE_LIMIT_PER_MIN = 20


# ── small helpers ───────────────────────────────────────────────────────────
def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc):%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def read_env(path: str) -> dict:
    out = {}
    p = Path(path)
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


def nats_cfg() -> tuple[str, str]:
    env = read_env(NATS_ENV)
    return (os.environ.get("NATS_URL") or env.get("NATS_URL") or "nats://127.0.0.1:4222",
            os.environ.get("NATS_TOKEN") or env.get("NATS_TOKEN") or "")


# ── Telegram ────────────────────────────────────────────────────────────────
def tg_token() -> str | None:
    return read_env(TG_ENV).get("TELEGRAM_BOT_TOKEN") or os.environ.get("TELEGRAM_BOT_TOKEN")


def tg_api(token: str, method: str, payload: dict | None = None,
           timeout: int = 20) -> dict:
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def tg_chat() -> dict | None:
    p = Path(TG_CHATS)
    if not p.exists():
        return None
    try:
        d = json.loads(p.read_text())
        return d if d.get("chat_id") else None
    except Exception:
        return None


_rate_state = {"window": 0, "count": 0}


def tg_send(text: str, channel: str | None = None, force: bool = False) -> tuple[bool, str]:
    token = tg_token()
    chat = tg_chat()
    if not token:
        return False, "no TELEGRAM_BOT_TOKEN in " + TG_ENV
    if not chat:
        return False, ("no chat yet: open Telegram, send the bot /start or add it to a group, "
                       "then run bus_bridge.py discover")
    now = int(time.time() // 60)
    if _rate_state["window"] != now:
        _rate_state["window"], _rate_state["count"] = now, 0
    if not force and _rate_state["count"] >= RATE_LIMIT_PER_MIN:
        return False, "rate limit (bus message flood suppressed)"
    payload = {"chat_id": chat["chat_id"], "text": text,
               "disable_web_page_preview": True}
    # Forum groups: route each channel to its topic, so #security is a topic, not a wall.
    topic = (chat.get("topics") or {}).get(channel or "")
    if chat.get("is_forum") and topic:
        payload["message_thread_id"] = topic
    try:
        r = tg_api(token, "sendMessage", payload)
        _rate_state["count"] += 1
        return bool(r.get("ok")), "sent" if r.get("ok") else str(r.get("description"))
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"


def tg_discover(as_json: bool = False) -> int:
    token = tg_token()
    if not token:
        print("no bot token configured at " + TG_ENV, file=sys.stderr)
        return 2
    u = tg_api(token, "getUpdates", {"limit": 100})
    chats: dict[str, dict] = {}
    for upd in u.get("result", []):
        for key in ("message", "channel_post", "edited_message", "my_chat_member"):
            m = upd.get(key) or {}
            c = m.get("chat") or {}
            if c.get("id"):
                chats[str(c["id"])] = {
                    "type": c.get("type"),
                    "title": c.get("title") or c.get("username") or c.get("first_name"),
                    "is_forum": bool(c.get("is_forum")),
                }
    if not chats:
        print("no chats yet. In Telegram: either send the bot a message (/start), or add the\n"
              "bot to a group (Bots cannot create groups — only a human can). Then re-run\n"
              "  bus_bridge.py discover")
        return 1
    print("chats seen:")
    for cid, c in chats.items():
        print(f"  chat_id={cid} type={c['type']} forum={c['is_forum']} name={c['title']}")
    if len(chats) == 1:
        cid, c = next(iter(chats.items()))
        Path(TG_CHATS).write_text(json.dumps(
            {"chat_id": int(cid), "title": c["title"], "is_forum": c["is_forum"],
             "topics": {}}, indent=2))
        os.chmod(TG_CHATS, 0o600)
        print(f"persisted {TG_CHATS} (chat_id={cid}). Set per-channel topics in that file if "
              f"the chat is a forum.")
        return 0
    print("more than one chat: pick one and write it into " + TG_CHATS)
    return 3


# ── node bookkeeping ────────────────────────────────────────────────────────
def note_node(env: dict) -> None:
    # Messages from hand-made envelopes (debug probes) have no node field. Registering them
    # as "unknown" put a phantom peer in `hermes-bus nodes` and in the doctor's federation count.
    if not env.get("node"):
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = STATE_DIR / "nodes.json"
    try:
        nodes = json.loads(p.read_text()) if p.exists() else {}
    except Exception:
        nodes = {}
    key = env["node"]
    entry = nodes.get(key, {"node": key, "server": env.get("server"), "msgs": 0})
    entry.update({"last_seen": env.get("ts") or datetime.now(timezone.utc).isoformat(),
                  "msgs": int(entry.get("msgs", 0)) + 1})
    nodes[key] = entry
    p.write_text(json.dumps(nodes, indent=2))


def seen_load() -> set[str]:
    p = STATE_DIR / f"seen-{server_id()}.json"
    if p.exists():
        try:
            return set(json.loads(p.read_text())[-8000:])
        except Exception:
            return set()
    return set()


def seen_save(seen: set[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = STATE_DIR / f"seen-{server_id()}.json"
    p.write_text(json.dumps(sorted(seen)[-8000:]))


def should_forward(env: dict) -> bool:
    """Forward to Telegram only messages *this* node authored.

    Every node's bridge hears every message, so "forward what I hear" would send N
    copies to the owner's phone on an N-node federation. "Forward what I published"
    yields exactly one notification per message and stays correct as nodes are added.
    """
    return (env.get("kind") in MEANINGFUL_KINDS
            and env.get("priority") != "low"
            and env.get("node") == server_id())


def tg_line(env: dict) -> str:
    where = f"#{env['channel']}" if env.get("channel") else f"→{env.get('to')}"
    refs = ("\n" + "\n".join(f"• {r}" for r in env.get("refs") or [])) if env.get("refs") else ""
    return (f"{env['kind'].upper()} {where} · {env['from']}@{env['server']}\n"
            f"{env['text'][:1200]}{refs}")


# ── Telegram -> bus: the owner's control plane ───────────────────────────────
TG_OFFSET = STATE_DIR / "tg-offset.json"
TG_MAX_TEXT = 3500          # Telegram's own limit is 4096; leave room for a header


def tg_offset_load() -> int:
    try:
        return int(json.loads(TG_OFFSET.read_text()).get("offset") or 0)
    except Exception:
        return 0


def tg_offset_save(offset: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    TG_OFFSET.write_text(json.dumps({"offset": offset}))


def tg_allowlist() -> set[int]:
    """Chats allowed to command this node: exactly those `discover` persisted."""
    ids: set[int] = set()
    chat = tg_chat() or {}
    for key in ("chat_id",):
        try:
            if chat.get(key) is not None:
                ids.add(int(chat[key]))
        except (TypeError, ValueError):
            pass
    for extra in chat.get("extra_chats") or []:
        try:
            ids.add(int(extra))
        except (TypeError, ValueError):
            pass
    return ids


def _run(args: list[str], limit: int = TG_MAX_TEXT - 200) -> str:
    """Run a FIXED command. Owner text never reaches a shell."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=90)
        out = (r.stdout or "").strip() or (r.stderr or "").strip()
    except Exception as e:
        out = f"{type(e).__name__}: {e}"
    return (out or "(no output)")[:limit]


def owner_status() -> str:
    import urllib.request as u
    lines = [f"Hermes node {server_id()} ({node_name()})"]
    units = ["nats-server", "hermes-bus-bridge", "hermes-agents", "hermes-serve",
             "hermes-gateway", "hermes-shim"]
    states = []
    for u_ in units:
        try:
            st = subprocess.run(["systemctl", "is-active", u_], capture_output=True,
                                text=True, timeout=10).stdout.strip() or "unknown"
        except Exception:
            st = "unknown"
        states.append(f"{u_}={st}")
    lines.append("units: " + ", ".join(states))
    # Bus numbers come from the bridge's own view (always current); the exporter is only a
    # fallback because its stream gauges are absent whenever its scrape of NATS' monitoring
    # endpoint fails, and "?" in the owner's chat is worse than no line at all.
    st = _run(["/usr/local/bin/hermes-bus-bridge", "status"], limit=1200)
    for ln in st.splitlines():
        if ln.strip().startswith(("stream", "consumer")) or "ack_pending" in ln:
            lines.append("bus: " + ln.strip())
    try:
        m = u.urlopen("http://127.0.0.1:9725/metrics", timeout=8).read().decode()
        def val(name: str) -> str:
            for ln in m.splitlines():
                if ln.startswith(name + " "):
                    return ln.split()[-1]
            return "?"
        lines.append(f"agents: defined={val('hermes_agents_defined')} "
                     f"runtime_up={val('hermes_agents_runtime_up')} "
                     f"nodes_known={val('hermes_nodes_known')}")
        lines.append(f"projects wired={val('hermes_projects_wired')}")
    except Exception as e:
        lines.append(f"metrics: unavailable ({type(e).__name__})")
    return "\n".join(lines)


def owner_digest(arg: str) -> str:
    try:
        n = max(1, min(20, int(arg)))
    except (TypeError, ValueError):
        n = 3
    return _run(["/usr/local/bin/hermes-bus", "digest", "-n", str(n)])


HELP = """Hermes control — команды:
/status — состояние узла (юниты, шина, агенты)
/digest [N] — сводка последних N сообщений по каналам
/task <текст> — задача в #orchestrator (агенты разберут по capability)
/servers — узлы на шине
/help — эта справка
любой другой текст → публикуется в #general как событие"""


def handle_owner_text(text: str) -> str:
    """Return the reply for one owner message. Dispatch only — no shell from text."""
    t = (text or "").strip()
    if not t:
        return HELP
    low = t.lower()
    if low in ("/start", "/help", "help", "/?"):
        return HELP
    if low.startswith("/status"):
        return owner_status()
    if low.startswith("/digest"):
        return owner_digest(t.split()[1] if len(t.split()) > 1 else "3")
    if low.startswith("/servers") or low.startswith("/nodes"):
        return _run(["/usr/local/bin/hermes-bus", "nodes"])
    if low.startswith("/task"):
        body = t[5:].strip()
        if not body:
            return "Формат: /task <что сделать>"
        return _publish("orchestrator", "task", body)
    if low.startswith("/"):
        return "Неизвестная команда.\n\n" + HELP
    return _publish("general", "event", t)


def _publish(channel: str, kind: str, text: str) -> str:
    r = subprocess.run(["/usr/local/bin/hermes-bus", "post", "--channel", channel,
                        "--kind", kind, "--priority", "normal", text],
                       capture_output=True, text=True, timeout=60)
    out = (r.stdout or r.stderr or "").strip().splitlines()
    mid = out[0].split()[0] if out and out[0] else "?"
    return (f"{kind} → #{channel}  [{mid}]\n"
            f"агенты увидят это на шине; зеркало: board agents-chat")


def tg_poll_once(token: str, timeout: int = 25) -> int:
    """One long-poll round. Returns the number of updates handled."""
    offset = tg_offset_load()
    try:
        d = tg_api(token, "getUpdates",
                   {"offset": offset, "timeout": timeout,
                    "allowed_updates": ["message", "channel_post"]}, timeout=timeout + 15)
    except Exception as e:
        log(f"telegram poll failed: {type(e).__name__}: {e}")
        time.sleep(5)
        return 0
    if not d.get("ok"):
        log(f"telegram poll refused: {d.get('description')}")
        time.sleep(10)
        return 0
    allowed = tg_allowlist()
    handled = 0
    for up in d.get("result") or []:
        tg_offset_save(int(up["update_id"]) + 1)
        m = up.get("message") or up.get("channel_post") or {}
        chat = m.get("chat") or {}
        frm = m.get("from") or {}
        text = (m.get("text") or "").strip()
        try:
            cid = int(chat.get("id"))
        except (TypeError, ValueError):
            continue
        if not text:
            continue
        if frm.get("is_bot"):
            continue
        if cid not in allowed:
            # Logged, never executed: an unknown chat must not be able to command.
            log(f"telegram: ignoring command from non-allowlisted chat {cid} "
                f"({chat.get('type')}, {(chat.get('title') or frm.get('username') or '?')}) "
                f"— run `bus_bridge.py discover` if this is the owner")
            continue
        log(f"telegram <- {frm.get('username') or cid}: {text[:80]!r}")
        reply = handle_owner_text(text)
        ok, detail = tg_send(reply, force=True)
        handled += 1
        if not ok:
            log(f"telegram reply failed: {detail}")
    return handled


def cmd_poll() -> int:
    token = tg_token()
    if not token:
        log(f"no TELEGRAM_BOT_TOKEN in {TG_ENV}; inbox disabled")
        return 2
    if not tg_allowlist():
        log("no chat configured yet — send the bot /start, then run `bus_bridge.py discover`")
    log(f"telegram inbox up as {server_id()} (long polling)")
    while True:
        try:
            tg_poll_once(token)
        except KeyboardInterrupt:
            return 0
        except Exception as e:
            log(f"poll loop error: {type(e).__name__}: {e}")
            time.sleep(5)


# ── the daemon ──────────────────────────────────────────────────────────────
async def _ack(msg) -> None:
    try:
        await msg.ack()
    except TypeError:      # older nats-py had a sync ack()
        msg.ack()
    except Exception as e:
        log(f"ack failed for {msg.subject}: {type(e).__name__}: {e}")


async def ensure_stream(js) -> None:
    from nats.js.api import StreamConfig, StorageType, DiscardPolicy
    try:
        await js.stream_info(STREAM)
    except Exception:
        await js.add_stream(StreamConfig(
            name=STREAM, subjects=[SUBJECTS], storage=StorageType.FILE,
            max_age=168 * 3600, max_msgs=200_000, max_bytes=2 * 1024 ** 3,
            discard=DiscardPolicy.OLD, duplicate_window=120,
            description="Hermes Agent Bus: chat, DMs, RPC and node events"))


async def run_daemon(rpc_echo: bool = False) -> None:
    import nats
    from nats.js.api import ConsumerConfig, DeliverPolicy
    from nats.errors import Error as NatsError

    url, token = nats_cfg()
    if not token:
        log(f"FATAL: no NATS_TOKEN ({NATS_ENV})")
        sys.exit(2)
    node = server_id()
    backoff = 2
    seen = seen_load()

    while True:
        try:
            nc = await nats.connect(url, token=token, name=f"bridge-{node}",
                                    connect_timeout=5, max_reconnect_attempts=-1,
                                    reconnect_time_wait=2)
            log(f"connected to {url} as node {node} ({node_name()})")
            js = nc.jetstream()
            await ensure_stream(js)
            log(f"stream {STREAM} ready (subjects {SUBJECTS})")

            async def _handle(msg):
                # Never let an exception escape: an unhandled error in a JetStream
                # callback means no ack, which means endless redelivery of a message
                # this node cannot process anyway.
                try:
                    env = json.loads(msg.data.decode())
                except Exception as e:
                    log(f"unparseable message on {msg.subject}: {e}")
                    await _ack(msg)
                    return
                mid = env.get("id")
                note_node(env)
                mirrored = True
                if mid and mid not in seen:
                    mirrored = mirror_local(env)
                    if mirrored:
                        seen.add(mid)
                        if len(seen) % 25 == 0:
                            seen_save(seen)
                    else:
                        log(f"local mirror unavailable for {mid} (board busy?) — "
                            f"leaving it unacked so JetStream redelivers")
                else:
                    log(f"dupe (already mirrored locally): {mid}")
                # Ack only once the message is durable locally: an unacked message is
                # redelivered by JetStream, so a dead board delays the message instead
                # of losing it. Redelivery is harmless — the mirror is deduped by id.
                if mirrored:
                    await _ack(msg)
                if should_forward(env) and tg_chat():
                    ok, detail = tg_send(tg_line(env), channel=env.get("channel"))
                    if not ok:
                        log(f"telegram: {detail}")
                log(f"← {env.get('kind')} #{env.get('channel') or 'dm'} "
                    f"from {env.get('from')}@{env.get('server')} [{mid}] {env.get('text', '')[:70]}")

            async def handler(msg):
                try:
                    await _handle(msg)
                except Exception as e:
                    # Log and ACK: a message we cannot process must not be redelivered
                    # forever. It is already on the wire and visible to other nodes.
                    log(f"handler error for {msg.subject}: {type(e).__name__}: {e} (acked)")
                    await _ack(msg)

            # Durable consumer: position survives restarts and offline periods.
            await js.subscribe(SUBJECTS, durable=f"node-{node}", cb=handler,
                               stream=STREAM, manual_ack=True,
                               config=ConsumerConfig(durable_name=f"node-{node}",
                                                     deliver_policy=DeliverPolicy.NEW,
                                                     ack_wait=30))

            if rpc_echo:
                async def rpc(msg):
                    env = json.loads(msg.data.decode())
                    reply_env = envelope(channel=None, to=env.get("from"), kind="reply",
                                         text=f"ack from {node}: received "
                                              f"{env.get('kind')}/{env.get('priority')} "
                                              f"corr={env.get('correlation_id')}",
                                         correlation=env.get("correlation_id"),
                                         agent=f"bridge-{node}")
                    await msg.respond(json.dumps(reply_env).encode())
                    log(f"rpc echo -> {env.get('from')} corr={env.get('correlation_id')}")
                # RPC subjects are deliberately outside the stream (see bus.py), and the
                # bridge answers ONLY for its own node id — a wildcard listener would
                # make an unreachable agent look alive by answering for it.
                rpc_subject = f"hermesrpc.rpc.{node}"
                await nc.subscribe(rpc_subject, cb=rpc)
                log(f"rpc echo enabled ({rpc_subject})")

            backoff = 2
            while True:  # keep the process alive; nats-py reconnects underneath
                await asyncio.sleep(5)
                if nc.is_closed:
                    raise NatsError("connection closed")
        except Exception as e:
            log(f"bus unavailable ({type(e).__name__}: {e}) — retrying in {backoff}s; "
                f"local work continues, messages stay in the local mirror")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)


def cmd_status() -> int:
    url, token = nats_cfg()
    chat = tg_chat()
    print(f"node        : {server_id()} ({node_name()})")
    print(f"bus url     : {url}  token: {'set' if token else 'MISSING'}")
    print(f"telegram    : {'chat_id=' + str(chat['chat_id']) if chat else 'not configured'}")
    print(f"state dir   : {STATE_DIR}")
    try:
        import nats
        async def probe():
            nc = await nats.connect(url, token=token, connect_timeout=5)
            js = nc.jetstream()
            info = await js.stream_info(STREAM)
            state = info.state
            out = (state.messages, state.bytes, state.first_seq, state.last_seq)
            consumers = await js.consumers_info(STREAM)
            cons = [(c.name, getattr(c, "num_ack_pending", None)) for c in consumers]
            await nc.close()
            return out, cons
        (msgs, nbytes, first, last), cons = asyncio.run(probe())
        print(f"stream      : {STREAM} msgs={msgs} bytes={nbytes} seq={first}..{last}")
        for name, pending in cons:
            print(f"  consumer {name}: ack_pending={pending}")
    except Exception as e:
        print(f"stream      : unreachable ({type(e).__name__}: {e})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="bus-bridge")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run"); p.add_argument("--rpc-echo", action="store_true")
    p = sub.add_parser("send"); p.add_argument("text"); p.add_argument("--force", action="store_true")
    sub.add_parser("discover")
    sub.add_parser("status")
    sub.add_parser("poll")
    a = ap.parse_args()
    if a.cmd == "run":
        asyncio.run(run_daemon(rpc_echo=a.rpc_echo))
        return 0
    if a.cmd == "send":
        ok, detail = tg_send(a.text, force=a.force)
        print(("sent: " if ok else "FAILED: ") + detail)
        return 0 if ok else 1
    if a.cmd == "discover":
        return tg_discover()
    if a.cmd == "poll":
        return cmd_poll()
    return cmd_status()


if __name__ == "__main__":
    sys.exit(main())
