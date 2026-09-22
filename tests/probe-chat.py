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


def route(task: str) -> dict:
    return runtime.route(task)


print("agents=%d" % len(runtime.agents))
# ── project actions: a project agent must do real work, not describe itself ────
print("ptask-tests=%s" % route("прогони тесты в logistics")["handler"])
print("ptask-tests-what=%s" % route("прогони тесты в logistics")["action"])
print("ptask-tests-subject=%s" % route("прогони тесты в logistics")["subject"])
print("ptask-build=%s" % route("собери madworld")["action"])
print("ptask-logs=%s" % route("покажи логи octopus")["action"])
print("ptask-deploy=%s" % route("проверь деплой octopus")["action"])
print("ptask-status-still-report=%s" % route("как дела в logistics")["handler"])
print("ptask-needs-project=%s" % bool(route("прогони тесты")["capability"] == "" and
                                     route("прогони тесты").get("need_project")))
print("route-host=%s" % cap_for("проверить загрузку сервера"))
print("route-project=%s" % cap_for("статус проекта logistics"))
print("route-alias=%s" % cap_for("логистика статус"))
print("route-unknown=%s" % cap_for("приготовить кофе"))

# ── адресация упоминанием (регресс волны 2026-09-19) ───────────────────────────
# В общем канале сообщение адресовано УПОМИНАНИЕМ («@node-arm-llm/server-guardian ask …»),
# а обработчик брался из первого слова — то есть из самого упоминания. Такого обработчика
# не существует, и агент молча не отвечал: разговор агентов в общем чате не работал.
# Упоминание — адресат, а не команда; аргументы k=v при этом обязаны уцелеть.
print("mention-handler=%s" % R.Runtime.parse_request(
    {"text": "@node-arm-llm/server-guardian ask почему память растёт"})[0])
print("mention-handler-2=%s" % R.Runtime.parse_request(
    {"text": "@node-arm-llm/monitoring status"})[0])
print("mention-multi=%s" % R.Runtime.parse_request({"text": "@a @b status k=v"})[0])
print("mention-args=%s" % R.Runtime.parse_request({"text": "@a @b status k=v"})[1].get("k"))
print("mention-empty=%s" % R.Runtime.parse_request({"text": "@a @b"})[0])
print("plain-handler=%s" % R.Runtime.parse_request({"text": "status k=v"})[0])
print("plain-args=%s" % R.Runtime.parse_request({"text": "status k=v"})[1].get("k"))
# Контракт конверта: явный обработчик приходит в args (env["handler"] читается вместе с
# args-словарём). Явный обработчик обязан побеждать упоминание.
print("explicit-handler=%s" % R.Runtime.parse_request(
    {"text": "@a ask x", "args": {"handler": "disk"}})[0])
print("envelope-handler=%s" % R.Runtime.parse_request(
    {"text": "@a ask x", "args": {}, "handler": "disk"})[0])
print("handler-top=%s" % handler_for("Что грузит сервер?"))
print("handler-disk=%s" % handler_for("сколько места на диске"))
print("handler-alerts=%s" % handler_for("покажи алерты"))
print("handler-ports=%s" % handler_for("кто слушает порты"))
print("handler-analysis=%s" % handler_for("почему сервер тормозит"))
print("handler-team=%s" % handler_for("какие агенты есть"))
print("handler-proc=%s" % handler_for("Сервер что с процессом chromium"))
print("subject-proc=%s" % runtime.route("Сервер что с процессом chromium")["subject"])
print("handler-docker-q=%s" % handler_for("почему контейнер octopus упал"))
print("handler-ask-fallback=%s" % handler_for("стоит ли обновлять ядро"))
print("action-restart=%s" % runtime.route("перезапусти контейнер octopus-browser")["action"])
print("action-target=%s" % runtime.route("перезапусти контейнер octopus-browser")["target"])
print("action-prune=%s" % runtime.route("почисти docker")["action"])
print("action-refused-broad=%s" % (runtime.route("перезапусти сервер")["action"] or "none"))

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

# ── forwarding filter: silence for tests, never for real output ────────────────
def _env(text: str, kind: str = "result", channel: str = "orchestrator") -> dict:
    return {"text": text, "kind": kind, "channel": channel, "priority": "normal",
            "node": B.server_id()}


print("forward-real-report=%s" % B.should_forward(
    _env("🛠 ПРОЕКТ hermes-os: ТЕСТЫ\n  ok   agents selftest\n  ════ 112 passed ════")))
print("forward-selftest-tagged-silenced=%s" % (not B.should_forward(
    _env("offline-replay selftest-022040"))))
print("forward-error-always=%s" % B.should_forward(
    _env("proj-octopus.run → FAIL (код 2)", kind="error")))


# ── long reports: a document, not a truncated message ──────────────────────────
# The bus used to cut agent output at 1200 characters and print a server path the owner
# cannot open from a phone. A long report must arrive as a file, complete.
_b, _boundary = B._multipart({"chat_id": "1", "caption": "c"}, "report.txt", b"line1\nline2\n")
print("multipart-crlf=%s" % (
    b"\r\n\r\n" in _b and _b.startswith(b"--") and _b.rstrip().endswith(b"--")))
print("multipart-filename=%s" % (b'filename="report.txt"' in _b))

_calls = {}
B.tg_send = lambda reply, **kw: (_calls.__setitem__("message", reply), (True, "sent"))[1]
B.tg_send_document = lambda path, caption="": (
    _calls.__setitem__("document", (path, caption)), (True, "sent"))[1]
B.tg_reply_any("короткий ответ")
_short_as_message = "message" in _calls and "document" not in _calls
_calls.clear()
B.tg_reply_any("длинный ответ\n" * 400)
print("short-reply-is-message=%s" % _short_as_message)
print("long-reply-is-document=%s" % ("document" in _calls and "message" not in _calls))
print("long-reply-caption=%s" % (bool(_calls.get("document", ("", ""))[1])))
