#!/usr/bin/env python3
"""scripts/hermes-alert-poller.py — Prometheus alerts into the owner's Telegram.

WHY: 10 alert rules existed and 5 of them were firing for hours, but nothing ever reached a
human: Alertmanager is not installed and a webhook had never been configured. An alert that
nobody sees is a config file, not monitoring.

WHAT: a small daemon that polls the Prometheus HTTP API every POLL_INTERVAL seconds,
groups firing alerts by name so one noisy rule is one message (not five), remembers what it
has already told the owner in /var/lib/hermes-bus/alert-state.json (so a restart or a
repeated poll never spams), repeats a still-firing alert at most every REPEAT_AFTER hours,
and always reports a resolution.

Configured by /etc/hermes/telegram.env (token) + /etc/hermes/telegram.chats.json (chat) —
the same files the bus bridge uses, so no second copy of the secret exists.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PROM = os.environ.get("HERMES_PROM_URL", "http://127.0.0.1:9090")
CHATS = Path("/etc/hermes/telegram.chats.json")
STATE = Path("/var/lib/hermes-bus/alert-state.json")
POLL_INTERVAL = int(os.environ.get("HERMES_ALERT_POLL", "60"))
REPEAT_AFTER = int(os.environ.get("HERMES_ALERT_REPEAT", str(6 * 3600)))
SEVERITY_ICON = {"critical": "🔴", "warning": "🟠", "info": "🔵"}

# A bare rule name is not useful on a phone: the owner needs to know whether the router
# needs attention or the box is simply out of memory. Kept deliberately short.
HINTS = {
    "HermesProjectTreeMissing": "агент проекта есть, а самого каталога на диске нет "
                                "(удалён или не клонирован). Скажи «клонируй <проект>» — "
                                "склонирую заново, либо уберём агента",
    "HermesHostMemoryPressure": "память съел другой workload: docker stats, "
                                "подсказка в scripts/install-protection.sh",
    "HermesHostSwapFull": "реальной памяти не хватает, всё ушло в swap",
    "HermesHostLoadHigh": "процессоры заняты: открой 📊 Статус или спроси про процесс",
    "HermesUnprotectedFromOOM": "ядро убьёт шину наравне с браузером — "
                                "scripts/install-protection.sh",
    "HermesProjectPathUnreadable": "каталог есть, но юзеру hermes не видно: "
                                   "setfacl -m u:hermes:x <родитель>",
    "HermesAgentsStale": "агенты давно не отчитывались: systemctl status hermes-agents",
    "HermesUnitDown": "юнит Hermes не работает: systemctl status <unit>",
    "HermesBusBacklog": "очередь шины растёт: hermes-bus-bridge status",
    "HermesBalancerUnhealthy": "LLM-балансировщик недоступен: агенты не ответят на вопросы",
    "HermesShimUnhealthy": "шим моделей недоступен: ask-задачи не выполнятся",
}


def log(msg: str) -> None:
    print(time.strftime("[%Y-%m-%d %H:%M:%S] ") + msg, flush=True)


def token() -> str:
    for path in (Path("/etc/hermes/telegram.env"),):
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if line.startswith("TELEGRAM_BOT_TOKEN=") or line.startswith("BOT_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return os.environ.get("TELEGRAM_BOT_TOKEN", "")


def chat_id() -> str:
    try:
        data = json.loads(CHATS.read_text())
        if isinstance(data, dict):
            chats = data.get("chats") or data
            if isinstance(chats, list) and chats:
                first = chats[0]
                return str(first.get("chat_id") if isinstance(first, dict) else first)
            if isinstance(chats, dict) and chats:
                first = next(iter(chats.values()))
                return str(first.get("chat_id") if isinstance(first, dict) else first)
    except Exception as e:
        log(f"chats unreadable: {type(e).__name__}: {e}")
    return ""


def tg_send(text: str) -> bool:
    tok, chat = token(), chat_id()
    if not tok or not chat:
        log("no telegram token/chat — alert not delivered")
        return False
    body = json.dumps({"chat_id": chat, "text": text[:4000], "parse_mode": "HTML",
                       "disable_web_page_preview": True}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{tok}/sendMessage", data=body,
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            ok = bool(json.loads(r.read()).get("ok"))
        log("telegram: sent alert" if ok else "telegram: rejected alert")
        return ok
    except Exception as e:
        log(f"telegram failed: {type(e).__name__}: {e}")
        return False


def fetch_rules() -> list[dict]:
    """Active alerts from Prometheus, flattened."""
    url = f"{PROM}/api/v1/rules?type=alert"
    with urllib.request.urlopen(url, timeout=15) as r:
        payload = json.loads(r.read())
    out = []
    for group in payload.get("data", {}).get("groups", []):
        for rule in group.get("rules", []):
            for alert in rule.get("alerts", []):
                out.append({
                    "name": rule.get("name", "?"),
                    "state": alert.get("state", "?"),
                    "labels": alert.get("labels", {}),
                    "annotations": alert.get("annotations", {}),
                    "active_at": alert.get("activeAt", ""),
                    "value": alert.get("value", ""),
                })
    return out


def fp(alert: dict) -> str:
    key = alert["name"] + "|" + "|".join(f"{k}={v}" for k, v in sorted(alert["labels"].items())
                                         if k not in ("alertname",))
    return hashlib.sha1(key.encode()).hexdigest()[:12]


def human_age(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 90:
        return f"{seconds} с"
    if seconds < 5400:
        return f"{seconds // 60} мин"
    return f"{seconds // 3600} ч {seconds % 3600 // 60} мин"


def esc(s: str) -> str:
    return html.escape(str(s), quote=False)


def format_group(name: str, items: list[dict], resolved: bool = False) -> str:
    sev = (items[0]["labels"].get("severity") or "warning").lower()
    icon = SEVERITY_ICON.get(sev, "🟠")
    head = f"{'✅' if resolved else icon} <b>{esc(name)}</b>"
    if resolved:
        head += f" — закрылся (было {len(items)})"
    else:
        head += f" — {esc(sev)}" if not resolved else ""
        if len(items) > 1:
            head += f" ×{len(items)}"
    lines = [head]
    now = time.time()
    for a in items[:8]:
        seen = ""
        if a.get("active_at"):
            try:
                ts = a["active_at"].replace("Z", "+00:00")
                seen = human_age(now - time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
                                 + time.timezone)
            except Exception:
                seen = ""
        subject = (a["labels"].get("instance") or a["labels"].get("unit")
                   or a["labels"].get("project") or a["labels"].get("job") or "")
        line = f"• {esc(subject)}" if subject else "•"
        if seen:
            line += f" ({esc(seen)})"
        lines.append(line)
        summary = a["annotations"].get("summary") or a["annotations"].get("description") or ""
        if summary:
            lines.append(f"   {esc(summary[:160])}")
    if len(items) > 8:
        lines.append(f"… и ещё {len(items) - 8}")
    if not resolved and name in HINTS:
        lines.append(f"💡 {esc(HINTS[name])}")
    lines.append("")
    lines.append("<i>подробности: 📊 Статус или «что с процессом …» в этом чате</i>")
    return "\n".join(lines)


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {}


def save_state(state: dict) -> None:
    try:
        STATE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1))
        tmp.replace(STATE)
    except Exception as e:
        log(f"cannot save state: {type(e).__name__}: {e}")


def cycle(state: dict, first_run: bool) -> dict:
    try:
        alerts = fetch_rules()
    except Exception as e:
        log(f"prometheus unreachable ({type(e).__name__}: {e}) — будет повтор")
        return state
    now = time.time()
    firing: dict[str, list[dict]] = {}
    for a in alerts:
        if a["state"] != "firing":
            continue
        firing.setdefault(a["name"], []).append(a)

    seen_now: dict[str, dict] = {}
    fresh: dict[str, list[dict]] = {}
    repeated: dict[str, list[dict]] = {}
    for name, items in firing.items():
        rows = []
        for a in items:
            key = fp(a)
            prev = state.get(key)
            rows.append(a)
            seen_now[key] = {"name": name, "since": (prev or {}).get("since", now),
                             "notified": (prev or {}).get("notified", 0)}
            if not prev:
                fresh.setdefault(name, []).append(a)
            elif now - prev.get("notified", 0) > REPEAT_AFTER:
                repeated.setdefault(name, []).append(a)
        # first run with a long-standing backlog: one message, not five
        if first_run and rows and name not in fresh and now - min(s.get("since", now)
                                                                for s in seen_now.values()) > 900:
            repeated.setdefault(name, rows)

    # resolutions: something we told the owner about is no longer firing
    resolved: dict[str, list[dict]] = {}
    for key, prev in state.items():
        if key in seen_now:
            continue
        if prev.get("notified"):
            resolved.setdefault(prev.get("name", "?"), []).append(
                {"labels": {}, "annotations": {}, "active_at": ""})

    for name, items in sorted(fresh.items()):
        tg_send(format_group(name, items))
        for a in items:
            seen_now[fp(a)]["notified"] = now
    for name, items in sorted(repeated.items()):
        tg_send(format_group(name, items) + "\n<i>⏳ всё ещё горит</i>")
        for a in items:
            key = fp(a)
            if key in seen_now:
                seen_now[key]["notified"] = now
    for name, items in sorted(resolved.items()):
        tg_send(format_group(name, items, resolved=True))

    return seen_now


def main() -> int:
    if "--once" in sys.argv:
        cycle(load_state(), first_run=True)
        return 0
    log(f"alert poller: prometheus={PROM} каждые {POLL_INTERVAL} с, "
        f"повтор не чаще {REPEAT_AFTER // 3600} ч")
    state = load_state()
    first = True
    while True:
        try:
            state = cycle(state, first_run=first)
            save_state(state)
        except Exception as e:                     # never die: a poller that stops is silence
            log(f"cycle error: {type(e).__name__}: {e}")
        first = False
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
