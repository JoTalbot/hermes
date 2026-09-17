#!/usr/bin/env python3
"""roster.py — one place that knows who is on this node and what they do.

Why it exists: the owner asked the chat *"какие агенты есть и их функции"* and the system
answered "не понял задачу" plus a dump of 30 capability tokens. The information was already
on disk — every agent YAML carries a human `purpose` — it was simply never rendered for a
human.

Both callers read the SAME registry through this module, so the chat and the bus can never
disagree about who is on the team:

  * `bus_bridge.py` renders it in Telegram (`/agents`, `/projects`, and the buttons),
  * `runtime.py` answers a task like "какие агенты есть" on the bus, so the question also
    works from the board or another node.

Output is plain text (the chat escapes it and the bus carries it as-is); no HTML here.
"""
from __future__ import annotations

import os
from pathlib import Path

try:                                    # the bus venv has PyYAML; a bare host python may not
    import yaml
except Exception:                       # pragma: no cover
    yaml = None

AGENTS_DIR = Path(os.environ.get("HERMES_AGENTS_DIR", "/opt/hermes/config/agents"))

CORE_ORDER = ["server-guardian", "backup", "security", "monitoring", "github", "orchestrator"]

# a plain-language example for the specialists, so "что написать?" is never a mystery
CORE_EXAMPLE = {
    "server-guardian": "проверить загрузку сервера",
    "backup": "сделать бэкап",
    "security": "аудит безопасности",
    "monitoring": "проверить мониторинг",
    "github": "проверить github",
    "orchestrator": "какие агенты",
}

ICONS = {
    "server-guardian": "🖥",
    "backup": "💾",
    "security": "🔐",
    "monitoring": "📊",
    "github": "🐙",
    "orchestrator": "🧭",
}

# Questions about the team itself. Asked in the chat or on the bus, they must be answered —
# they are not tasks for a specialist.
META_AGENTS = (r"какие агент|какие у тебя агент|список агент|агенты и их|кто умеет|"
               r"что ты умеешь|что умеешь|что ты можешь|кто есть в команде|какие функции|"
               r"состав команды|кто может")
META_PROJECTS = (r"какие проект|какие у тебя проект|список проект|что за проект|"
                 r"проекты под наблюдением")


def _exists(path: str) -> bool:
    """Path check that never raises: a project under /root is readable by the agent (root)
    but not by every caller of this module, and a roster must not crash on that."""
    if not path:
        return False
    try:
        return Path(path).exists()
    except OSError:
        return False


def _env_of(handler: dict) -> dict:
    return (handler or {}).get("env") or {}


def load_registry() -> tuple[list[dict], list[dict]]:
    """Return (core, projects). Each record: id, purpose, caps, handlers, path."""
    core: list[dict] = []
    projects: list[dict] = []
    if yaml is None or not AGENTS_DIR.is_dir():
        return core, projects
    paths = sorted(AGENTS_DIR.glob("*.yaml")) + sorted(AGENTS_DIR.glob("projects/*.yaml"))
    for path in paths:
        try:
            d = yaml.safe_load(path.read_text()) or {}
        except Exception:
            continue
        b = d.get("bus") or {}
        aid = b.get("agent_id")
        if not aid:
            continue
        handlers = b.get("handlers") or {}
        status_env = _env_of(handlers.get("status"))
        rec = {
            "id": aid,
            "purpose": (b.get("purpose") or "").strip(),
            "caps": list(b.get("capabilities") or []),
            "handlers": list(handlers.keys()),
            "path": status_env.get("PROJECT_PATH") or "",
        }
        (projects if aid.startswith("proj-") else core).append(rec)
    core.sort(key=lambda r: (CORE_ORDER.index(r["id"]) if r["id"] in CORE_ORDER else 99, r["id"]))
    # the slack report first in each list: it is what an owner checks most often
    projects.sort(key=lambda r: (0 if _exists(r["path"]) else 1, r["id"]))
    return core, projects


def _shorten(text: str, width: int) -> str:
    """Cut on a word boundary: "репетиция восстановл…" reads like a bug, "репетиция…" does not."""
    text = text.strip().rstrip(".")
    if len(text) <= width:
        return text
    cut = text[:width].rsplit(" ", 1)[0]
    return (cut or text[:width]).rstrip(" ,;:") + "…"


def _one_line(rec: dict, width: int = 70) -> str:
    icon = ICONS.get(rec["id"], "🛠")
    purpose = rec["purpose"] or "(без описания)"
    # A purpose is "Тема: перечисление" — the topic alone is enough in a list view.
    head = purpose.split(":")[0] if ":" in purpose.split(" ")[0] or purpose.count(":") else purpose
    return f"{icon} {rec['id']} — {_shorten(head, width)}"


def overview(width: int = 78) -> str:
    """The whole team in one screen."""
    core, projects = load_registry()
    if not core and not projects:
        return "🤖 Реестр агентов пуст — ни одного агента не найдено в " + str(AGENTS_DIR)
    live = [p for p in projects if _exists(p["path"])]
    lines = [f"🤖 Моя команда: {len(core) + len(projects)} агентов", ""]
    if core:
        lines.append(f"🛠 Специалисты ({len(core)}) — по хозяйству узла:")
        lines += ["  " + _one_line(r, width) for r in core]
        lines.append("")
    if projects:
        lines.append(f"📦 Проекты ({len(projects)}) — по одному агенту на проект:")
        names = ", ".join(p["id"][5:] for p in projects)
        lines.append("  " + names)
        if len(live) != len(projects):
            missing = [p["id"][5:] for p in projects if p not in live]
            lines.append(f"  ⚠️ каталога нет у {len(missing)}: {', '.join(missing)}")
        lines.append("")
    lines.append("💡 Пиши задачу обычным текстом — агента подберу сам.")
    lines.append("Подробнее: /agents <имя> · список проектов: /projects")
    return "\n".join(lines)


def detail(match: str, width: int = 300) -> str:
    """Everything about the agents matching `match` (id or purpose)."""
    core, projects = load_registry()
    low = (match or "").strip().lower()
    hits = [r for r in core + projects if low in r["id"].lower() or low in r["purpose"].lower()]
    if not hits:
        return f"🤷 Не нашёл агента по «{match}».\n\n" + overview()
    out = []
    for r in hits[:4]:
        out.append(f"{ICONS.get(r['id'], '🛠')} {r['id']}")
        out.append(f"   {r['purpose'][:width] or '(без описания)'}")
        if r["path"]:
            exists = "есть" if _exists(r["path"]) else "НЕТ"
            out.append(f"   путь: {r['path']} ({exists})")
        out.append(f"   возможности: {', '.join(r['caps'][:8])}")
        out.append(f"   действия: {', '.join(r['handlers'])}")
        asking = CORE_EXAMPLE.get(r["id"]) or (f"статус проекта {r['id'][5:]}"
                                              if r["id"].startswith("proj-") else f"статус {r['id']}")
        out.append(f"   написать в чат: «{asking}»")
        out.append("")
    return "\n".join(out).rstrip()


def projects() -> str:
    """Projects and whether their checkout is actually on this node."""
    core, projs = load_registry()
    if not projs:
        return "📦 Проектных агентов на этом узле нет."
    live = [p for p in projs if _exists(p["path"])]
    gone = [p for p in projs if p not in live]
    lines = [f"📦 Проекты под наблюдением: {len(projs)}", ""]
    for p in live:
        lines.append(f"  ✅ {p['id'][5:]} — {p['path']}")
    for p in gone:
        lines.append(f"  ⚠️ {p['id'][5:]} — каталога нет ({p['path'] or 'путь не задан'})")
    lines.append("")
    lines.append("💡 Спросить так: «статус проекта logistics»")
    return "\n".join(lines)
