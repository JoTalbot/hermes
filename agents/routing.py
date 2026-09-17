#!/usr/bin/env python3
"""routing.py — turn a sentence typed by a human into (agent capability, handler).

Before this module, routing knew four intents (`бэкап`, `безопасность`, `github`,
`мониторинг`) and every agent answered with its `status` handler no matter what was asked.
So "Что грузит сервер?" produced the generic host report and the owner saw a wall of
numbers instead of the answer to the question.

Rules of the game:

* **Deterministic.** No model, no tokens: pattern → (capability, handler). A wrong route is
  a bug to fix, not a dice roll.
* **A handler hint travels with the route.** "что грузит" means the `top` handler, "диск"
  means `disk`, "почему" means "gather the facts, then let the agent's model explain them".
* **The most specific rule wins.** Rules are ordered, first match wins, and the specific
  domains (disk, docker) sit above the generic host ones (load, сервер).
* **Nothing is executed from text.** The handler name comes from this table, never from the
  message; an unknown handler falls back to the agent's `status`.
"""
from __future__ import annotations

import re

# (regex, capability, label, handler) — order matters: specific before generic.
INTENT_RULES: list[tuple[str, str, str, str]] = [
    # ── backups ─────────────────────────────────────────────────────────────
    (r"целостн|провер[а-я]* бэкап|verify.?backup|восстанов", "backup", "бэкапы", "verify"),
    (r"бэкап|backup|архив", "backup", "бэкапы", "status"),
    # ── security ────────────────────────────────────────────────────────────
    (r"порт|фаервол|firewall|открыт|наружу|exposure", "security", "сеть и порты", "ports"),
    (r"секрет|права|доступ|chmod|0600|key|токен", "security", "секреты и права", "secrets"),
    (r"обновлен|патч|upgrade|apt|версия пакет", "security", "обновления", "updates"),
    (r"безопасн|security|аудит|audit|уязвим|скан", "security", "безопасность", "audit"),
    # ── github ──────────────────────────────────────────────────────────────
    (r"секрет.*git|secret-scan|утечк|ключ.*коммит", "github", "утечки в git", "secret-scan"),
    (r"github|репозитор|git|коммит|commit|пуш|push|ветк|diff|изменени", "github", "git и CI",
     "status"),
    # ── monitoring ──────────────────────────────────────────────────────────
    (r"алерт|alert|сработал|горит", "monitoring", "алерты", "alerts"),
    (r"таргет|target|экспорт|скрейп|scrape", "monitoring", "цели Prometheus", "targets"),
    (r"мониторинг|monitoring|prometheus|grafana|метрик|metric|slo|дашборд", "monitoring",
     "мониторинг", "health"),
    # ── host: specific resources first ──────────────────────────────────────
    (r"что грузит|кто грузит|что ест|жр[её]т|топ процесс|top|процессор|cpu|загрузк|нагрузк|"
     r"load|тормоз|лаг|тяжел|тяжёл", "host-health", "загрузка CPU", "top"),
    (r"диск|место|df|inode|забит|переполн", "host-health", "диски", "disk"),
    (r"контейнер|докер|docker", "host-health", "контейнеры", "docker"),
    (r"логи|журнал|ошибк|error|падени|crash", "host-health", "журналы", "logs"),
    (r"своп|swap|память|memory|ram|oom", "host-health", "память", "memory"),
    (r"сервис|юнит|systemd|упал|failed|не работа|остановлен", "host-health", "сервисы",
     "services"),
    (r"hermes|гермес|шина|bus|агент", "host-health", "стек Hermes", "hermes"),
    (r"хост|сервер|состояни|статус|проверь|проверить|здоровь", "host-health", "хост и сервисы",
     "status"),
    # ── orchestrator's own bookkeeping ──────────────────────────────────────
    (r"что в работе|в работе|очеред|pending|незаверш", "orchestration", "текущие задачи",
     "pending"),
    (r"скилл|skill|умени", "orchestration", "скиллы", "skills"),
]

# Cues that the human does not want a raw report but an explanation of it. The domain rule
# still decides WHICH facts are gathered (top/disk/services…); these cues only add "ask".
ANALYSIS_CUES = (r"почему|отчего|проанализ|объясн|разбер|рекоменд|совет|диагноз|что не так|"
                 r"причин|риск|план|оцени|предложи|стоит ли|что делать|улучш|"
                 # code work: the facts are the tree, the answer is judgement → code tier
                 r"ревью|review|дифф|\bdiff\b|патч|рефактор|почини|исправ")

# Handlers that exist as runtime built-ins (no script needed) — kept here so routing never
# points at something the runtime cannot serve.
BUILTIN_HANDLERS = {"identity", "ping", "dispatch", "agents", "skills", "pending", "ask"}

PROJECT_ALIASES: dict[str, str] = {
    "логистик": "logistics", "логист": "logistics", "logist": "logistics",
    "октопус": "octopus", "осьминог": "octopus",
    "слова": "words", "словар": "words",
    "перевод": "transcribe", "транскрип": "transcribe",
    "украин": "ukraine", "браузер": "browser", "игр": "game",
    "мадворлд": "madworld", "балансер": "aios", "баланс": "aios",
    "гермес": "hermes-os", "hermes": "hermes-os",
}


def _caps(agents: dict) -> set[str]:
    return {c for a in agents.values() for c in a.capabilities}


def pick_handler(agent, handler: str) -> str:
    """The handler must exist on the target: an invented name would run nothing."""
    if handler and handler in agent.handlers:
        return handler
    if "status" in agent.handlers:
        return "status"
    return agent.handlers[0] if agent.handlers else "identity"


META_AGENTS = (r"какие агент|список агент|агенты и их|кто умеет|что ты умеешь|что умеешь|"
               r"кто есть в команде|состав команды|какие функции|кто может|моя команда")
META_PROJECTS = (r"какие проект|список проект|что за проект|проекты под наблюдением")


def route(task: str, agents: dict) -> dict:
    """Return {capability, target, why, handler, facts_handler, analysis}."""
    low = (task or "").lower()
    caps = _caps(agents)
    out = {"capability": "", "target": "", "why": "", "handler": "status",
           "facts_handler": "status", "analysis": False}

    # A question about the system itself is not a task for a specialist: the orchestrator
    # answers it from the registry. Checked first so "какие агенты" never becomes "hermes".
    if re.search(META_AGENTS, low):
        out.update(target="orchestrator", handler="agents", why="вопрос о команде")
        return out
    if re.search(META_PROJECTS, low):
        out.update(target="orchestrator", handler="projects", why="вопрос о проектах")
        return out

    # 1. a project named in the task is the most specific signal
    projects = sorted(((c, c.split(":", 1)[1]) for c in caps if c.startswith("project:")),
                      key=lambda p: -len(p[1]))
    for cap, name in projects:
        if re.search(rf"\b{re.escape(name.lower())}\b", low):
            out.update(capability=cap, why=f"проект «{name}»", handler="status",
                       facts_handler="status")
            return _finish(out, low)
    for alias, target in PROJECT_ALIASES.items():
        if alias in low:
            hits = [n for _, n in projects if n.lower().startswith(target)]
            if hits:
                name = min(hits, key=len)
                out.update(capability=f"project:{name}", why=f"проект «{name}» (синоним)",
                           handler="status", facts_handler="status")
                return _finish(out, low)
    for cap, name in sorted(((c, c.split(":", 1)[1]) for c in caps
                             if c.startswith("project:")), key=lambda p: len(p[1])):
        stem = name.split("-")[0]
        if len(stem) > 4 and stem.lower() in low:
            out.update(capability=cap, why=f"проект «{name}»", handler="status",
                       facts_handler="status")
            return _finish(out, low)

    # 2. intent table, first match wins
    for rx, cap, label, handler in INTENT_RULES:
        if re.search(rx, low) and (not cap or cap in caps):
            out.update(capability=cap, why=label, handler=handler, facts_handler=handler)
            return _finish(out, low)

    # 3. maybe the task simply names an agent
    for tok in re.findall(r"[a-z0-9][a-z0-9\-]{2,}", low):
        if tok in agents and tok != "orchestrator":
            out.update(target=tok, why=f"агент «{tok}»", handler="status", facts_handler="status")
            return _finish(out, low)
    return out


def _finish(out: dict, low: str) -> dict:
    """Add the analysis flag: keep the fact handler, ask the agent's model to explain."""
    if re.search(ANALYSIS_CUES, low):
        out["analysis"] = True
        out["handler"] = "ask"
    return out


def describe() -> str:
    """Human-readable list of what the system understands — used by /help and the refusal."""
    lines = []
    for rx, cap, label, handler in INTENT_RULES:
        first = rx.split("|")[0].replace("\\b", "")
        lines.append(f"• «{first}» → {label} ({handler})")
    return "\n".join(lines[:6])
