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
    cap, target, _ = runtime.route_by_text(task)
    return cap or (target and f"agent:{target}") or "(none)"


print("agents=%d" % len(runtime.agents))
print("route-host=%s" % cap_for("проверить загрузку сервера"))
print("route-project=%s" % cap_for("статус проекта logistics"))
print("route-alias=%s" % cap_for("логистика статус"))
print("route-unknown=%s" % cap_for("приготовить кофе"))

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
