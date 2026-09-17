#!/usr/bin/env python3
"""probe-chat.py — structural checks for the owner's chat path (bus -> Telegram -> task).

Prints `key=value` lines that tests/run.sh asserts on. Kept as a file (not an inline
heredoc) so the checks stay readable and can be run by hand when the chat misbehaves:

    /opt/hermes/.venv-bus/bin/python /opt/hermes/tests/probe-chat.py

What is being protected here is behaviour, not plumbing:
  * a free-text task from the owner is ROUTED (before this, it fell through to the first
    agent alphabetically — `backup` was asked about disk load),
  * an unparsable task is REFUSED instead of being handed to a random agent,
  * a project named in the task goes to the base project, not to a worktree variant that
    happens to share the first word,
  * owner text is HTML-escaped before it reaches Telegram (a stray `<` must not make the
    message unparseable — an unparseable message is one the owner never sees),
  * agent-to-agent DMs are not pushed to the owner's phone, but errors always are.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Point the registry at THIS checkout when the default (/opt/hermes) is not what we are
# testing: running the probe from a clone otherwise finds zero agents.
if (ROOT / "config" / "agents").is_dir():
    os.environ.setdefault("HERMES_AGENTS_DIR", str(ROOT / "config" / "agents"))
sys.path.insert(0, str(ROOT / "agents"))
sys.path.insert(0, str(ROOT / "bus"))

import runtime as R          # noqa: E402
import bus_bridge as B       # noqa: E402

runtime = R.Runtime.__new__(R.Runtime)
runtime.agents = R.load_agents()


def cap_for(task: str) -> str:
    """Capability (or named agent) the router picks for a sentence."""
    d = runtime.route(task)
    return d["capability"] or (d["target"] and f"agent:{d['target']}") or "(none)"


def handler_for(task: str) -> str:
    """The handler the route asks for — this is what makes an answer specific."""
    return runtime.route(task)["handler"]


print("agents=%d" % len(runtime.agents))
print("route-host=%s" % cap_for("проверить загрузку сервера"))
print("route-project=%s" % cap_for("статус проекта logistics"))
print("route-alias=%s" % cap_for("логистика статус"))
print("route-unknown=%s" % cap_for("приготовить кофе"))
print("handler-top=%s" % handler_for("Что грузит сервер?"))
print("handler-disk=%s" % handler_for("сколько места на диске"))
print("handler-alerts=%s" % handler_for("покажи алерты"))
print("handler-ports=%s" % handler_for("кто слушает порты"))
print("handler-analysis=%s" % handler_for("почему сервер тормозит"))
print("handler-team=%s" % handler_for("какие агенты есть"))

print("escape=%s" % B.esc("<b>x</b> & y"))

header = B.tg_line({"kind": "task", "channel": "orchestrator", "from": "root",
                    "server": "srv", "text": "проверить загрузку", "priority": "normal"})
print("header-has-kind=%s" % ("ЗАДАЧА" in header))
print("header-html=%s" % ("<b>" in header))
multiline = B.tg_line({"kind": "result", "channel": "orchestrator", "from": "a",
                       "server": "srv", "priority": "normal",
                       "text": "line one\nline two"})
print("body-mono=%s" % ("<pre>line one" in multiline))

dm = B.should_forward({"kind": "result", "priority": "normal", "node": B.server_id(),
                       "to": "server-guardian"})
channel = B.should_forward({"kind": "result", "priority": "normal", "node": B.server_id(),
                            "channel": "orchestrator"})
error = B.should_forward({"kind": "error", "priority": "normal", "node": B.server_id(),
                          "to": "server-guardian"})
print("forward=%s" % ("ok" if (not dm and channel and error) else
                      f"dm={dm} channel={channel} error={error}"))

# ── the owner's console must ANSWER questions about the team ────────────────
# Publishing is stubbed so a probe run cannot post to the real bus.
_calls: list[tuple] = []
B._publish = lambda ch, kind, txt: (_calls.append((ch, kind, txt)) or f"PUBLISHED:{ch}:{kind}")


def answer(text: str) -> str:
    _calls.clear()
    return B.handle_owner_text(text)


team = answer("Какие агенты есть и их функции")
print("meta-answered=%s" % ("Моя команда" in team and not _calls))
print("meta-has-specialists=%s" % ("server-guardian" in team and "backup" in team))
print("meta-has-projects=%s" % ("Проекты" in team))
print("meta-projects=%s" % ("Проекты под наблюдением" in answer("какие проекты")))

print("btn-agents=%s" % ("Моя команда" in answer("🤖 Агенты")))
def publishes_as_task(text: str, expect: str) -> bool:
    answer(text)
    return _calls == [("orchestrator", "task", expect)]


print("btn-server-is-task=%s" % publishes_as_task("💻 Сервер", "проверить загрузку сервера"))
print("btn-backup-is-task=%s" % publishes_as_task("💾 Бэкап", "проверить бэкапы"))
print("free-text-is-task=%s" % publishes_as_task("проверить загрузку сервера",
                                                 "проверить загрузку сервера"))
print("keyboard-buttons=%d" % sum(len(row) for row in B.MAIN_KEYBOARD["keyboard"]))
print("btn-task-map=%s" % B.BUTTON_TASKS.get("сервер"))

# the refusal must stay short and human: the old one dumped every capability token
rt = (ROOT / "agents" / "runtime.py").read_text()
print("refusal-friendly=%s" % ("🤔 Не понял" in rt and "Известные возможности" not in rt))
print("refusal-has-examples=%s" % ("аудит безопасности" in rt and "статус проекта logistics" in rt))
