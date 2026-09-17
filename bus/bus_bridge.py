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
import re
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# The agent registry has ONE renderer (agents/roster.py), shared with the bus side: the
# chat and the board can never disagree about who is on the team.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agents"))
from bus import CHANNELS, STATE_DIR, envelope, mirror_local, node_name, server_id  # noqa: E402
import roster  # noqa: E402

NATS_ENV = "/etc/hermes/nats.env"

# Telegram renders HTML in messages: bold headers, monospace output. Every dynamic part is
# escaped (see esc) so that agent output containing < or & cannot break the message — and a
# message that fails to parse is a message the owner never sees.
KIND_STYLE = {
    "event":    ("📣", "СОБЫТИЕ"),
    "decision": ("⚖️", "РЕШЕНИЕ"),
    "task":     ("🧩", "ЗАДАЧА"),
    "result":   ("✅", "РЕЗУЛЬТАТ"),
    "error":    ("❌", "ОШИБКА"),
    "status":   ("📊", "СТАТУС"),
    "request":  ("❓", "ЗАПРОС"),
    "reply":    ("💬", "ОТВЕТ"),
}
PRIO_MARK = {"urgent": "🔥 ", "high": "❗ ", "normal": "", "low": "· "}


# Two buttons give information (кто в команде, что за проекты), two send a real task, two
# report state. Tapping a button is exactly equivalent to typing its label.
MAIN_KEYBOARD = {
    "keyboard": [[{"text": "🤖 Агенты"}, {"text": "📦 Проекты"}],
                 [{"text": "💻 Сервер"}, {"text": "💾 Бэкап"}],
                 [{"text": "📊 Статус"}, {"text": "❓ Помощь"}]],
    "resize_keyboard": True,
    "is_persistent": True,
}

# Buttons that ARE tasks: the label is a shortcut, the task text is what humans would write.
BUTTON_TASKS = {"сервер": "проверить загрузку сервера", "бэкап": "проверить бэкапы",
                "история": "что делали агенты", "очередь": "что делали агенты"}
BUTTON_META = {"агенты": "agents", "проекты": "projects", "статус": "status",
               "сводка": "digest", "узлы": "servers", "помощь": "help"}


def esc(text: str) -> str:
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def prettify(escaped: str) -> str:
    """Markdown leftovers → HTML, applied strictly AFTER escaping.

    A model sometimes answers with **bold** or `code` even when told not to; on the phone
    that reads as literal asterisks. Only the two patterns that actually appear are
    converted, and nothing here can inject a tag (the input is already escaped).
    """
    out = re.sub(r"\*\*([^*\n]{1,120})\*\*", r"<b>\1</b>", escaped)
    return re.sub(r"`([^`\n]{1,80})`", r"<code>\1</code>", out)
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


def tg_send(text: str, channel: str | None = None, force: bool = False, markup: dict | None = None,
            keyboard: bool = False) -> tuple[bool, str]:
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
               "parse_mode": "HTML", "disable_web_page_preview": True}
    if markup:
        payload["reply_markup"] = markup
    elif keyboard:
        payload["reply_markup"] = MAIN_KEYBOARD
    # Forum groups: route each channel to its topic, so #security is a topic, not a wall.
    topic = (chat.get("topics") or {}).get(channel or "")
    if chat.get("is_forum") and topic:
        payload["message_thread_id"] = topic
    try:
        r = tg_api(token, "sendMessage", payload)
        _rate_state["count"] += 1
        if r.get("ok"):
            # Logged (not just failures): "did my message actually leave the node?" is the
            # first question when the owner says the chat is quiet.
            log(f"telegram: sent message_id={(r.get('result') or {}).get('message_id')}")
        return bool(r.get("ok")), "sent" if r.get("ok") else str(r.get("description"))
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"


# Telegram's own cap is 4096 characters; texts longer than this are useless on a phone
# anyway, so a long report is sent as a FILE with a short caption instead of a truncated
# message ending in a path the owner cannot open from his phone.
TG_TEXT_LIMIT = 3200


def _multipart(fields: dict, filename: str, filedata: bytes) -> tuple[bytes, str]:
    """Minimal multipart/form-data encoder — no third-party dependency in the bus venv."""
    boundary = "----hermes" + uuid.uuid4().hex
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
                     f"{value}\r\n".encode())
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
                 f"filename=\"{filename}\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
                 .encode() + filedata + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), boundary


def tg_send_document(path: str, caption: str = "") -> tuple[bool, str]:
    """Send a file to the owner's chat. Used when a report does not fit in a message."""
    token = tg_token()
    chat = tg_chat()
    if not token or not chat:
        return False, "no token or no chat"
    p = Path(path)
    if not p.is_file():
        return False, f"file not found: {path}"
    try:
        data = p.read_bytes()
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"
    if len(data) > 45 * 1024 * 1024:          # Telegram's bot limit
        return False, f"file too large ({len(data) // 1048576} MiB)"
    body, boundary = _multipart(
        {"chat_id": str(chat["chat_id"]), "caption": caption[:1000],
         "parse_mode": "HTML", "disable_notification": "true"},
        p.name, data)
    url = f"https://api.telegram.org/bot{token}/sendDocument"
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            ok = bool(json.loads(r.read()).get("ok"))
        if ok:
            log(f"telegram: sent document {p.name} ({len(data) // 1024} KiB)")
        return ok, "sent" if ok else "rejected"
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"


def _stage_report(text: str) -> str:
    """Положить длинный отчёт в файл, чтобы отправить его документом."""
    tmp = STATE_DIR / f"report-{int(time.time())}.txt"
    try:
        tmp.write_text(text)
    except Exception as e:
        log(f"cannot stage report: {type(e).__name__}: {e}")
    return str(tmp)


# ── оценки ответов ─────────────────────────────────────────────────────────────
FEEDBACK_FILE = Path(os.environ.get("HERMES_FEEDBACK_FILE",
                                    "/var/lib/hermes-agents/feedback.jsonl"))
FEEDBACK_TAGS = STATE_DIR / "feedback-tags.json"


def feedback_tag_new(question: str, answer: str) -> str:
    """Запомнить вопрос и начало ответа под коротким тегом — кнопка вернёт именно их."""
    tag = f"{int(time.time())}-{os.urandom(2).hex()}"
    try:
        data = json.loads(FEEDBACK_TAGS.read_text()) if FEEDBACK_TAGS.exists() else {}
    except Exception:
        data = {}
    data[tag] = {"q": (question or "")[:300], "a": (answer or "")[:300], "at": int(time.time())}
    if len(data) > 200:                     # старые теги не нужны: кнопки живут часы
        for k in sorted(data, key=lambda k: data[k].get("at", 0))[:-200]:
            data.pop(k, None)
    try:
        FEEDBACK_TAGS.write_text(json.dumps(data, ensure_ascii=False))
    except Exception as e:
        log(f"feedback: не сохранить тег ({type(e).__name__}: {e})")
    return tag


def feedback_record(tag: str, verdict: str) -> tuple[bool, str]:
    """Записать оценку владельца. Возвращает (принято, что показать в ответ на нажатие)."""
    try:
        data = json.loads(FEEDBACK_TAGS.read_text()) if FEEDBACK_TAGS.exists() else {}
    except Exception:
        data = {}
    rec = data.pop(tag, None)
    try:
        FEEDBACK_FILE.parent.mkdir(parents=True, exist_ok=True)
        with FEEDBACK_FILE.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                                 "epoch": int(time.time()), "verdict": verdict, "tag": tag,
                                 "question": (rec or {}).get("q", ""),
                                 "answer": (rec or {}).get("a", "")},
                                ensure_ascii=False) + "\n")
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"
    try:
        FEEDBACK_TAGS.write_text(json.dumps(data, ensure_ascii=False))
    except Exception:
        pass
    # Отрицательная оценка — сигнал, а не мусор: он виден в #incidents и в суточной сводке.
    if verdict == "down":
        log(f"feedback: 👎 по ответу на «{((rec or {}).get('q') or '?')[:70]}»")
    return True, ("Спасибо, записал 👍" if verdict == "up" else "Понял: ответ мимо 👎 — учту")


def tg_answer_callback(token: str, callback_id: str, text: str) -> None:
    try:
        tg_api(token, "answerCallbackQuery", {"callback_query_id": callback_id, "text": text[:200]},
               timeout=10)
    except Exception:
        pass


def tg_drop_markup(token: str, chat_id: int, message_id: int) -> None:
    """Убрать кнопки после голосования: второй голос по тому же ответу не имеет смысла."""
    try:
        tg_api(token, "editMessageReplyMarkup",
               {"chat_id": chat_id, "message_id": message_id, "reply_markup": {"inline_keyboard": []}},
               timeout=10)
    except Exception:
        pass


def tg_reply_any(reply: str, keyboard: bool = False, markup: dict | None = None) -> tuple[bool, str]:
    """A reply is a message if it fits; a document if it does not."""
    if len(reply) <= TG_TEXT_LIMIT:
        return tg_send(reply, force=True, keyboard=keyboard, markup=markup)
    plain = re.sub(r"<[^>]+>", "", reply)
    tmp = STATE_DIR / f"reply-{int(time.time())}.txt"
    try:
        tmp.write_text(plain)
    except Exception as e:
        return False, f"cannot stage long reply: {e}"
    head = plain.strip().splitlines()[0][:120] if plain.strip() else "Отчёт"
    ok, detail = tg_send_document(str(tmp), caption=f"📄 {head}\n(полный текст файлом)")
    if ok:
        try:
            tmp.unlink()            # отправленный отчёт не должен мусорить в state-каталоге
        except Exception:
            pass
    else:                           # fall back to a trimmed message, never silence
        ok, detail = tg_send(reply[:TG_TEXT_LIMIT], force=True, keyboard=keyboard)
    return ok, detail


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


SELFTEST_TAG = re.compile(r"\bselftest-\d{4,8}\b")


def should_forward(env: dict) -> bool:
    """Forward to Telegram only messages *this* node authored.

    Every node's bridge hears every message, so "forward what I hear" would send N
    copies to the owner's phone on an N-node federation. "Forward what I published"
    yields exactly one notification per message and stays correct as nodes are added.
    """
    # Channel traffic tells the story (task -> dispatch -> result); agent-to-agent DMs are
    # internal wiring and were landing in the owner's chat as "личка → server-guardian".
    # Errors are kept whatever their routing: a failure is never noise.
    text = (env.get("text") or "").lower()
    return (env.get("kind") in MEANINGFUL_KINDS
            and env.get("priority") != "low"
            and env.get("node") == server_id()
            and (env.get("channel") or env.get("kind") == "error")
            # The bus selftest publishes to real channels (that is how it proves mirroring
            # and priorities), so its messages must not reach the owner's phone. They are
            # identified by the tag they carry ("selftest-HHMMSS", sometimes not the first
            # word) and NOT by the bare English word: a real report whose test output
            # contained the line "ok agents selftest" was silently swallowed, and the owner
            # never saw the result of the task he had just asked for.
            and not SELFTEST_TAG.search(text)
            # The owner's own task is already acknowledged ("Задача принята"); echoing it
            # back from the bus is the same sentence twice.
            and not (env.get("kind") == "task"
                     and (env.get("text") or "").startswith("@orchestrator")))


def tg_line(env: dict) -> str:
    """One message the owner can read at a glance: what kind, where, from whom, what."""
    kind = env.get("kind") or "event"
    icon, title = KIND_STYLE.get(kind, ("•", str(kind).upper()))
    mark = PRIO_MARK.get(env.get("priority") or "normal", "")
    where = f"#{env['channel']}" if env.get("channel") else f"личка → {env.get('to')}"
    body = (env.get("text") or "").strip()
    if len(body) > 1200:
        body = body[:1200] + "…"
    # Two shapes of answer, two presentations:
    #  * a measurement report (check scripts) is column-formatted → monospace;
    #  * a model's explanation is prose with bullets and a "💡" conclusion → HTML text, so
    #    it stays readable on a phone instead of being a wall of fixed-width text.
    prose = "💡" in body or "•" in body
    if (body.count("\n") >= 1 or kind in ("result", "error", "status")) and not prose:
        shown = f"<pre>{esc(body[:900])}</pre>"
    else:
        shown = prettify(esc(body[:1200]))
    lines = [f"{mark}{icon} <b>{title}</b> · {esc(where)}",
             f"👤 {esc(env.get('from') or '?')} @ {esc(env.get('server') or '?')}",
             "",
             shown]
    if env.get("correlation_id"):
        lines.append(f"\n🔗 corr <code>{esc(env['correlation_id'])}</code>")
    for r in (env.get("refs") or [])[:2]:
        lines.append(f"📎 Полный вывод: <code>{esc(r)}</code>")
    return "\n".join(lines)


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
    lines = [f"🖥 <b>{esc(server_id())}</b> · узел на шине"]
    units = ["nats-server", "hermes-bus-bridge", "hermes-telegram-inbox", "hermes-agents",
             "hermes-serve", "hermes-gateway", "hermes-shim", "hermes-metrics"]
    states, down = [], []
    for u_ in units:
        try:
            st = subprocess.run(["systemctl", "is-active", u_], capture_output=True,
                                text=True, timeout=10).stdout.strip() or "unknown"
        except Exception:
            st = "unknown"
        states.append(f"{'✅' if st == 'active' else ('⚪️' if st == 'inactive' else '❌')} {u_}")
        if st == "failed":
            down.append(u_)
    lines.append("⚙️ <b>Юниты</b> " + ("все активны" if not down else f"❌ {len(down)} сбоят"))
    lines.append("<pre>" + esc("\n".join(states)) + "</pre>")
    # Bus numbers come from the bridge's own view (always current); the exporter is only a
    # fallback because its stream gauges are absent whenever its scrape of NATS' monitoring
    # endpoint fails, and "?" in the owner's chat is worse than no line at all.
    bus_lines = []
    st = _run(["/usr/local/bin/hermes-bus-bridge", "status"], limit=1200)
    for ln in st.splitlines():
        if ln.strip().startswith("stream") or "ack_pending" in ln:
            bus_lines.append(ln.strip())
    if bus_lines:
        lines.append("📨 <b>Шина</b>")
        lines.append("<pre>" + esc("\n".join(bus_lines)) + "</pre>")
    try:
        m = u.urlopen("http://127.0.0.1:9725/metrics", timeout=8).read().decode()
        def val(name: str) -> str:
            for ln in m.splitlines():
                if ln.startswith(name + " "):
                    return ln.split()[-1]
            return "?"
        lines.append(f"🤖 <b>Агенты</b> {val('hermes_agents_defined')} определено · "
                     f"{val('hermes_agents_runtime_up')} runtime · "
                     f"{val('hermes_nodes_known')} узла на шине")
        lines.append(f"📦 <b>Проекты</b> {val('hermes_projects_wired')} привязано")
    except Exception as e:
        lines.append(f"metrics: unavailable ({type(e).__name__})")
    return "\n".join(lines)


def owner_agents(arg: str) -> str:
    """Who is on this node and what they do — the team, in one screen."""
    text = roster.detail(arg) if arg.strip() else roster.overview()
    return f"<pre>{esc(text)}</pre>"


def owner_projects() -> str:
    return f"<pre>{esc(roster.projects())}</pre>"


def owner_servers() -> str:
    return ("🖧 <b>Узлы на шине</b>\n<pre>"
            + esc(_run(["/usr/local/bin/hermes-bus", "nodes"])) + "</pre>")


def owner_digest(arg: str) -> str:
    try:
        n = max(1, min(20, int(arg)))
    except (TypeError, ValueError):
        n = 3
    return "🗞 <b>Сводка шины</b>\n<pre>" + esc(_run(["/usr/local/bin/hermes-bus",
                                                      "digest", "-n", str(n)])) + "</pre>"


HELP = """🤖 <b>Hermes на связи</b>

Просто напиши, что нужно, обычными словами:
   <i>проверить загрузку сервера</i>
   <i>статус проекта logistics</i>
   <i>сделать бэкап</i>
   <i>аудит безопасности</i>
   <i>какие агенты</i>

Ещё можно запускать проверки проектов:
   <i>прогони тесты в logistics</i>
   <i>собери madworld</i>
   <i>покажи логи octopus</i>
   <i>проверь деплой octopus</i> — это dry-run, ничего не разворачивается

Или нажми кнопку внизу 👇 — там самые частые вещи.

📋 <b>Команды</b>
/agents — кто в команде и что умеет
/projects — какие проекты под наблюдением
/status — состояние узла
/digest [N] — сводка шины за последние N сообщений
/servers — узлы на шине
/note &lt;текст&gt; — просто записать событие, без исполнения
/help — эта справка

<i>Ответ агента придёт сюда же отдельным сообщением.</i>"""


def handle_owner_text(text: str) -> str:
    """Return the reply for one owner message. Dispatch only — no shell from text."""
    t = (text or "").strip()
    if not t:
        return HELP
    low = t.lower()
    # The phone keyboard sends its button label as text ("📊 Статус"). Accept the LABEL —
    # not any sentence that happens to contain the word: "статус проекта hermes-os" is a
    # task for an agent, and an earlier version of this shortcut swallowed it and answered
    # with the node status instead. Matching a normalized label is the narrow rule.
    label = re.sub(r"[^a-zа-я]+", "", t.lower())
    if label in BUTTON_TASKS:                     # 💻 Сервер / 💾 Бэкап are tasks, not answers
        return _publish("orchestrator", "task", BUTTON_TASKS[label])
    if label in BUTTON_META:
        return {
            "agents": lambda: owner_agents(""),
            "projects": owner_projects,
            "status": owner_status,
            "digest": lambda: owner_digest("3"),
            "servers": owner_servers,
            "help": lambda: HELP,
        }[BUTTON_META[label]]()
    if label in ("start",):
        return HELP
    # A question about the system itself must be ANSWERED, not refused as a task: the owner
    # asked "какие агенты есть и их функции" and got "не понял задачу" plus a dump of
    # capability tokens. (runtime.py answers the same question on the bus.)
    if re.search(roster.META_AGENTS, low):
        return owner_agents("")
    if re.search(roster.META_PROJECTS, low):
        return owner_projects()
    if low.startswith("/status"):
        return owner_status()
    if low.startswith("/digest"):
        return owner_digest(t.split()[1] if len(t.split()) > 1 else "3")
    if low.startswith("/servers") or low.startswith("/nodes"):
        return owner_servers()
    if low.startswith("/agents") or low.startswith("/roster"):
        return owner_agents(t.split(" ", 1)[1] if " " in t else "")
    if low.startswith("/projects"):
        return owner_projects()
    if low.startswith("/task"):
        body = t[5:].strip()
        if not body:
            return "🧩 Формат: <code>/task что сделать</code>"
        return _publish("orchestrator", "task", body)
    if low.startswith("/note"):
        body = t[5:].strip()
        if not body:
            return "📝 Формат: <code>/note текст события</code>"
        return _publish("general", "event", body)
    if low.startswith("/"):
        return "🤔 Не знаю такой команды.\n\n" + HELP
    # Free text in the owner's private chat is an instruction, not a tweet: sending it to
    # #general as a bare event (the old behaviour) looked like it worked and did nothing.
    return _publish("orchestrator", "task", t)


def _publish(channel: str, kind: str, text: str) -> str:
    """Publish to the bus. For #orchestrator the agent is ADDRESSED by name.

    A message in a channel is a broadcast — agents act on direct messages and on
    mentions — so a task without "@orchestrator" was read by nobody and answered by
    nobody. That is exactly the "I sent a task and nothing happened" the owner saw.
    """
    body = f"@orchestrator {text}" if channel == "orchestrator" else text
    r = subprocess.run(["/usr/local/bin/hermes-bus", "post", "--channel", channel,
                        "--kind", kind, "--priority", "normal", body],
                       capture_output=True, text=True, timeout=60)
    out = (r.stdout or r.stderr or "").strip().splitlines()
    mid = out[0].split()[0] if out and out[0] else "?"
    if kind == "task":
        return ("🧩 <b>Задача принята</b>\n"
                f"🆔 <code>{esc(mid)}</code>\n"
                f"🎯 маршрут: #orchestrator → подходящий агент\n"
                f"📝 {esc(text[:400])}\n\n"
                "<i>Отвечу в этот чат, когда агент закончит.</i>")
    return ("📝 <b>Событие опубликовано</b>\n"
            f"🆔 <code>{esc(mid)}</code> · канал #{esc(channel)}\n"
            f"{esc(text[:400])}")


def tg_poll_once(token: str, timeout: int = 25) -> int:
    """One long-poll round. Returns the number of updates handled."""
    offset = tg_offset_load()
    try:
        d = tg_api(token, "getUpdates",
                   {"offset": offset, "timeout": timeout,
                    "allowed_updates": ["message", "channel_post", "callback_query"]}, timeout=timeout + 15)
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

        # ── нажатие на 👍/👎 под ответом агента ────────────────────────────────
        cq = up.get("callback_query") or {}
        if cq:
            data = str(cq.get("data") or "")
            frm = cq.get("from") or {}
            chat_id = ((cq.get("message") or {}).get("chat") or {}).get("id")
            msg_id = (cq.get("message") or {}).get("message_id")
            if data.startswith("fb|") and not frm.get("is_bot"):
                parts = data.split("|", 2)
                verdict = parts[1] if len(parts) > 1 else ""
                tag = parts[2] if len(parts) > 2 else ""
                if verdict in ("up", "down") and tag:
                    ok, note = feedback_record(tag, verdict)
                    tg_answer_callback(token, str(cq.get("id") or ""), note)
                    if ok and chat_id and msg_id:
                        tg_drop_markup(token, int(chat_id), int(msg_id))
                    log(f"telegram callback: {verdict} on {tag} -> {note}")
                    handled += 1
                continue
            continue

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
        want_keyboard = True   # the keyboard is the main way to drive this from a phone
        try:      # a visible "typing…" while a handler runs, so silence never looks like death
            tg_api(token, "sendChatAction", {"chat_id": cid, "action": "typing"}, timeout=10)
        except Exception:
            pass
        reply = handle_owner_text(text)
        # Кнопка оценки: под ответом владельцу, а не в меню — оценивают конкретный ответ.
        tag = feedback_tag_new(text, reply)
        fb_markup = {"inline_keyboard": [[
            {"text": "👍 точный", "callback_data": f"fb|up|{tag}"},
            {"text": "👎 мимо", "callback_data": f"fb|down|{tag}"}]]}
        ok, detail = tg_reply_any(reply, keyboard=want_keyboard, markup=fb_markup)
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
                    body = (env.get("text") or "")
                    ref = next((r for r in (env.get("refs") or []) if Path(str(r)).is_file()),
                               "")
                    if len(body) > 1200:
                        # 1200 — это ровно та граница, на которой текст раньше начинал
                        # резаться (tg_line показывает 900–1200 символов) и владелец получал
                        # путь к файлу на сервере, который с телефона не открыть. Теперь
                        # полный текст уезжает документом .txt, а в сообщении остаётся шапка
                        # и начало отчёта.
                        path = ref or _stage_report(body)
                        head = tg_line(env).split("\n")[0]
                        ok, detail = tg_send_document(path, caption=f"{head}\n\n{esc(body[:700])}…")
                        if not ok:
                            log(f"telegram document failed ({detail}); sending text")
                            ok, detail = tg_send(tg_line(env), channel=env.get("channel"))
                    else:
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
        ok, detail = tg_send(esc(a.text), force=a.force)
        print(("sent: " if ok else "FAILED: ") + detail)
        return 0 if ok else 1
    if a.cmd == "discover":
        return tg_discover()
    if a.cmd == "poll":
        return cmd_poll()
    return cmd_status()


if __name__ == "__main__":
    sys.exit(main())
