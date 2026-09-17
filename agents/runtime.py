#!/usr/bin/env python3
"""runtime.py — runs every local Hermes agent as a first-class citizen of the Agent Bus.

DESIGN
------
One process hosts all agents of this node; each agent gets its own subjects:

  DM / broadcast   hermes.dm.<agent_id>.<priority>      (kind=task|event|request)
  RPC              hermesrpc.rpc.<agent_id>             (synchronous request/reply)
  channel mention  hermes.chat.<channel>.<priority>     (text contains @<agent_id>)

An agent can ONLY run the handlers declared for it in
`config/agents/*.yaml` → `bus.handlers`. A task message never carries a shell
command; it carries a handler name plus validated arguments. That is the whole
security model: no message on the bus can make an agent execute arbitrary code,
and the handler set is reviewable in Git.

WHY NOT AN LLM IN THE LOOP BY DEFAULT
-------------------------------------
Routine work (health, repo state, ports, backups) is deterministic: a script either
answers or it does not. Routing that through a model would burn tokens to produce a
worse answer and would fill the GLOBAL CHAT with internal monologue, which the owner
explicitly forbade. The LLM Balancer is used for *analysis* tasks — and those are
delegated as Hermes kanban tasks, so the heavy lifting happens on the server, never on
the phone, and the result comes back as a normal result message.

ORCHESTRATION
-------------
The orchestrator agent is not special-cased magic: it has built-in handlers
(`dispatch`, `pending`, `agents`, `skills`) that read the same registry every other
agent reads. `dispatch` picks a target by capability, sends it a task with a
correlation id, records the expectation, and when the matching result arrives it
publishes a rolled-up status. Agents therefore talk to each other, not through a mesh.

Usage
-----
  runtime.py run         # daemon (systemd: hermes-agents.service)
  runtime.py list        # agents + capabilities + handlers
  runtime.py invoke <agent> <handler> [key=value ...]   # local dry run, no bus
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shlex
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bus"))
import roster  # noqa: E402  (same directory: one renderer for chat and bus)
import routing  # noqa: E402  (deterministic intent -> handler table)
import models   # noqa: E402  (model policy: which tier each agent uses)
from bus import (CHANNELS, RPC_PREFIX, SUBJECT_PREFIX, envelope, mirror_local,  # noqa: E402
                 nats_conf, server_id)

# The registry lives next to the code on a real node; the override exists so the test
# suite and the chat probe can run from a working copy (or a worktree) instead of silently
# finding zero agents and reporting every route as "(none)".
CONFIG_DIR = Path(os.environ.get("HERMES_AGENTS_DIR", "/opt/hermes/config/agents"))
PROJECT_AGENTS_DIR = CONFIG_DIR / "projects"
SKILLS_DIR = Path("/opt/hermes/skills")
STATE_DIR = Path("/var/lib/hermes-agents")
LOG_DIR = STATE_DIR / "logs"

# ── история прогонов ────────────────────────────────────────────────────────────
# У каждого запуска обработчика уже был свой файл-журнал, но их никто не сводил: на вопрос
# «падал ли этот агент хоть раз?» приходилось грепать тысячи файлов руками, а «что агенты
# делали ночью» — это листинг каталога. Одна строка JSONL на запуск: что, для кого, чем
# кончилось. Файл только дописывается и режется по размеру, поэтому история не теряется.
HISTORY_FILE = STATE_DIR / "history.jsonl"
HISTORY_MAX_BYTES = 5 * 1024 * 1024
HISTORY_KEEP = 3
HISTORY_SKIP_ARGS = ("message", "text", "prompt", "token", "password")


def history_append(record: dict) -> None:
    """Дописать одну запись о прогоне. Не бросает исключений: учёт не должен ломать работу."""
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        if HISTORY_FILE.exists() and HISTORY_FILE.stat().st_size > HISTORY_MAX_BYTES:
            oldest = STATE_DIR / f"history.jsonl.{HISTORY_KEEP}"
            if oldest.exists():
                oldest.unlink()
            for i in range(HISTORY_KEEP - 1, 0, -1):
                src = STATE_DIR / f"history.jsonl.{i}"
                if src.exists():
                    src.rename(STATE_DIR / f"history.jsonl.{i + 1}")
            HISTORY_FILE.rename(STATE_DIR / "history.jsonl.1")
        with HISTORY_FILE.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:  # noqa: BLE001
        log(f"history: запись не удалась ({type(e).__name__}: {e})")
MAX_CONCURRENT = 2
OUTPUT_LIMIT = 6000

# Сколько задача может числиться «в работе». Пока ответа нет, задача остаётся в pending;
# если агент упал или ушёл в переподключение, ответа не будет НИКОГДА, а запись оставалась
# навсегда: /pending показывал вечно висящие задачи, а файл рос без границ.
PENDING_TTL = int(os.environ.get("HERMES_PENDING_TTL", str(6 * 3600)))


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc):%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


# ── config reader ───────────────────────────────────────────────────────────
_YAML_WARNED = False


def load_yaml(path: Path) -> dict:
    """Parse an agent config.

    PyYAML is the only supported path — the fallback exists so the daemon still starts on
    a bare box, but it is LOUD about it. A silent fallback previously cost real behaviour:
    the naive parser drops `capabilities:` lists, so every agent reported zero
    capabilities and capability routing fell back to "first agent alphabetically".
    """
    global _YAML_WARNED
    try:
        import yaml
        return yaml.safe_load(path.read_text()) or {}
    except ImportError:
        if not _YAML_WARNED:
            log("WARNING: PyYAML missing — using the reduced parser; list values such as "
                "`capabilities` will be ignored. Install it: "
                "/opt/hermes/.venv-bus/bin/pip install PyYAML")
            _YAML_WARNED = True
    out: dict = {}
    stack = [(-1, out)]
    lines = [l for l in path.read_text().splitlines()
             if l.strip() and not l.lstrip().startswith("#")]
    for idx, raw in enumerate(lines):
        indent = len(raw) - len(raw.lstrip())
        line = raw.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1] if stack else out
        if line.startswith("- "):
            if isinstance(parent, list):
                parent.append(line[2:].strip())
            continue
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        if val in ("", "|", ">"):
            nxt = next((l for l in lines[idx + 1:] if l.strip()), "")
            child: object = [] if nxt.strip().startswith("- ") else {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = val.strip("'\"")
    return out


# ── agent registry ──────────────────────────────────────────────────────────
# Two nodes run the same six specialists. A role is not an identity: `server-guardian`
# exists on every node, so the *bus* id of an agent on a secondary node is prefixed with
# that node's server_id. The primary node keeps bare names for backwards compatibility and
# because its agents are the ones a human types by hand.
def _node_env(key: str, default: str = "") -> str:
    """Env var, else /etc/hermes/node.env, else default.

    The peer's role must survive any restart path. Restarting it through a bare
    `docker exec` (no exported vars) previously made its agents adopt the PRIMARY's
    bare names — two nodes answering to one address, which is worse than no node.
    """
    if os.environ.get(key):
        return os.environ[key]
    try:
        with open("/etc/hermes/node.env") as fh:
            for line in fh:
                line = line.strip().removeprefix("export ").strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip('"\'')
    except Exception:
        pass
    return default


SCOPE = _node_env("HERMES_AGENT_SCOPE", "local").lower()


class Agent:
    def __init__(self, path: Path):
        self.path = path
        cfg = load_yaml(path)
        prof = cfg.get("profile") or {}
        bus = cfg.get("bus") or {}
        self.slug = prof.get("slug") or path.stem
        base_id = bus.get("agent_id") or self.slug
        self.local_id = base_id
        self.id = f"{server_id()}/{base_id}" if SCOPE == "node" else base_id
        self.description = (bus.get("purpose") or prof.get("description") or "").strip()
        self.kind = "project" if path.parent.name == "projects" else "core"
        self.capabilities = bus.get("capabilities") or []
        self.handlers = bus.get("handlers") or {}
        self.project = {
            "path": (cfg.get("technology") or {}).get("local_path"),
            "repo": (cfg.get("technology") or {}).get("repo"),
            "service": (cfg.get("operations") or {}).get("service"),
            "containers": (cfg.get("operations") or {}).get("containers"),
            "health": (cfg.get("operations") or {}).get("health_url"),
        }
        self.raw = cfg

    def handler_names(self) -> list[str]:
        return sorted(self.handlers.keys())

    def resolve(self, handler: str) -> dict | None:
        h = self.handlers.get(handler)
        if not h:
            return None
        return h if isinstance(h, dict) else {"run": str(h)}

    def __repr__(self) -> str:
        return f"<Agent {self.id} {self.kind} handlers={self.handler_names()}>"


def load_agents() -> dict[str, Agent]:
    """Load the agents this NODE runs.

    HERMES_LOCAL_AGENTS limits the set — "all" (default), "core" (the six specialists), or
    a comma-separated list of ids. A container node has no project checkouts, so running 21
    project agents there would be 21 agents reporting "path missing" and nothing else.
    """
    only = _node_env("HERMES_LOCAL_AGENTS", "all").strip().lower()
    agents: dict[str, Agent] = {}
    paths = sorted(CONFIG_DIR.glob("*.yaml")) + sorted(PROJECT_AGENTS_DIR.glob("*.yaml"))
    for p in paths:
        try:
            a = Agent(p)
        except Exception as e:
            log(f"skipping {p.name}: {e}")
            continue
        if only == "core" and a.kind != "core":
            continue
        if only not in ("all", "core") and a.id not in [x.strip() for x in only.split(",")]:
            continue
        if a.id in agents:
            log(f"duplicate agent id {a.id} ({p.name}) — keeping the first")
            continue
        agents[a.id] = a
    return agents


# ── handler execution ───────────────────────────────────────────────────────
def run_handler(agent: Agent, handler: str, args: dict, actor: str) -> dict:
    spec = agent.resolve(handler)
    if not spec:
        return {"ok": False, "text": f"agent {agent.id} has no handler {handler!r}; "
                                     f"declared: {', '.join(agent.handler_names()) or 'none'}",
                "code": 4}
    cmd = spec.get("run") or ""
    if not cmd:
        return {"ok": False, "text": f"handler {handler} has no run command", "code": 5}
    timeout = int(spec.get("timeout") or 120)

    # Arguments are passed as environment, never spliced into the command line: a task
    # message must not be able to smuggle shell syntax into a handler invocation.
    env = dict(os.environ, AGENT_ID=agent.id, AGENT_ACTOR=actor,
               HANDLER=handler, ARGS_JSON=json.dumps(args, ensure_ascii=False))
    # Each argument is also exported as ARG_<NAME> (ARG_SUBJECT, ARG_ACTION, ARG_TARGET), so
    # a check script reads the object it must look at without parsing JSON in bash.
    for k, v in (args or {}).items():
        if isinstance(v, (str, int, float)) and k.isidentifier():
            env[f"ARG_{k.upper()}"] = str(v)
    # Static per-handler environment from the agent's YAML (project path, service name…).
    env.update({str(k): str(v) for k, v in (spec.get("env") or {}).items() if v is not None})
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    # Agent ids from a peer node look like "<server_id>/<role>" — a slash in a filename is
    # a directory separator, so the log write failed with FileNotFoundError instead of
    # writing the log. Sanitise, keep the id readable.
    safe_id = agent.id.replace("/", "_")
    logfile = LOG_DIR / f"{safe_id}-{handler}-{int(time.time())}.log"
    started = time.time()
    try:
        cp = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True,
                            timeout=timeout, env=env, cwd=spec.get("cwd") or "/opt/hermes")
        out = (cp.stdout or "").strip()
        err = (cp.stderr or "").strip()
        code = cp.returncode
    except subprocess.TimeoutExpired:
        out, err, code = "", f"handler timed out after {timeout}s", 124
    except Exception as e:
        out, err, code = "", f"{type(e).__name__}: {e}", 125
    took = time.time() - started
    logfile.write_text(f"$ {cmd}\n# handler={handler} agent={agent.id} actor={actor} "
                       f"args={json.dumps(args, ensure_ascii=False)}\n"
                       f"# exit={code} took={took:.2f}s\n--- stdout ---\n{out}\n--- stderr ---\n{err}\n")
    # Аудит-след: агент помнит, что он делал и чем это закончилось. Для слов вида «перезапусти
    # octopus-browser» это ещё и запись «кто попросил и что из этого вышло».
    _lines = (out or err or "").strip().splitlines()
    history_append({
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "epoch": int(time.time()),
        "agent": agent.id,
        "handler": handler,
        "actor": actor,
        "code": code,
        "took_ms": int(took * 1000),
        "log": str(logfile),
        "args": {k: str(v)[:60] for k, v in args.items()
                 if k.lower() not in HISTORY_SKIP_ARGS},
        "summary": _lines[0][:160] if _lines else "",
    })
    body = out if out else err
    if len(body) > OUTPUT_LIMIT:
        body = body[:OUTPUT_LIMIT] + f"\n… truncated ({len(out)} bytes; full log: {logfile})"
    return {"ok": code == 0, "text": body or f"(no output, exit {code})", "code": code,
            "refs": [str(logfile)], "took": round(took, 2)}


# ── skills / memory introspection handlers ──────────────────────────────────
def skills_index() -> list[dict]:
    out = []
    if not SKILLS_DIR.exists():
        return out
    for p in sorted(SKILLS_DIR.glob("*/SKILL.md")):
        name, desc = p.parent.name, ""
        for line in p.read_text().splitlines()[:12]:
            if line.startswith("description:"):
                desc = line.split(":", 1)[1].strip().strip('"\'')
            if line.startswith("name:"):
                name = line.split(":", 1)[1].strip()
        out.append({"name": name, "path": str(p), "description": desc[:160]})
    return out


# Deterministic intent routing for tasks typed by a human. Specific intents first: a
# request to "сделать бэкап сервера" must not be routed by the generic word "сервер".
INTENT_RULES: list[tuple[str, str, str]] = [
    (r"бэкап|backup|восстанов|restore|архив|проверка бэкап", "backup", "бэкапы"),
    (r"безопасн|security|аудит|audit|фаервол|firewall|секрет|открыт|уязвим|порт", "security",
     "безопасность"),
    (r"github|\bgit\b|репозитор|\brepo\b|коммит|commit|пуш|push|ветк|secret-scan|утечк",
     "github", "git и CI"),
    (r"мониторинг|monitoring|prometheus|grafana|метрик|metric|алерт|alert|slo|дашборд",
     "monitoring", "мониторинг"),
    # generic host keywords last: they match "сервер", which appears in almost everything
    (r"загрузк|нагрузк|\bload\b|uptime|процессор|\bcpu\b|памят|memory|диск|disk|место|"
     r"юнит|сервис|service|systemd|journal|журнал|docker|контейнер|хост|сервер|статус|"
     r"состояни|проверь|проверить",
     "host-health", "хост и сервисы"),
]


# The owner writes Russian; the registry is in English. A short alias table beats a
# transliteration engine: it covers the projects that actually get asked about.
PROJECT_ALIASES: dict[str, str] = {
    "логистик": "logistics", "логист": "logistics", "logist": "logistics",
    "октопус": "octopus", "осьминог": "octopus",
    "слова": "words", "словар": "words",
    "перевод": "transcribe", "транскрип": "transcribe",
    "украин": "ukraine", "браузер": "browser", "игр": "game",
    "мадворлд": "madworld", "балансер": "aios", "баланс": "aios",
}


def caps_of(agents: dict) -> set:
    return {c for a in agents.values() for c in a.capabilities}


def builtin(agent: Agent, handler: str, args: dict) -> dict | None:
    """Handlers that need no shell: introspection and orchestration."""
    if handler == "ping":
        return {"ok": True, "text": f"{agent.id} alive on {server_id()} "
                                    f"({datetime.now(timezone.utc).isoformat(timespec='seconds')})"}
    if handler in ("skills", "skills.list"):
        rows = skills_index()
        return {"ok": True, "text": json.dumps(rows, ensure_ascii=False, indent=1)[:OUTPUT_LIMIT]}
    if handler == "identity":
        return {"ok": True, "text": json.dumps({
            "agent_id": agent.id, "kind": agent.kind, "purpose": agent.description,
            "capabilities": agent.capabilities, "handlers": agent.handler_names(),
            "config": str(agent.path), "node": server_id()}, ensure_ascii=False, indent=1)}
    if handler in ("pending", "in-flight"):
        return {"ok": True, "text": "см. status: незавершённые задачи в /var/lib/hermes-agents/"
                                     "pending.json (runtime: orchestrator-pending.sh)"}
    if handler == "agents":
        ags = load_agents()
        rows = [{"id": a.id, "kind": a.kind, "capabilities": a.capabilities,
                 "handlers": a.handler_names()} for a in ags.values()]
        return {"ok": True, "text": json.dumps(rows, ensure_ascii=False, indent=1)[:OUTPUT_LIMIT]}
    return None


# ── the daemon ──────────────────────────────────────────────────────────────
class Runtime:
    def __init__(self) -> None:
        self.agents = load_agents()
        self.sem = asyncio.Semaphore(MAX_CONCURRENT)
        self.pending: dict[str, dict] = {}
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.pending_file = STATE_DIR / "pending.json"
        if self.pending_file.exists():
            try:
                self.pending = json.loads(self.pending_file.read_text())
            except Exception:
                self.pending = {}

    # -- persistence of dispatched tasks ------------------------------------
    def remember(self, corr: str, rec: dict) -> None:
        self.pending[corr] = rec
        self.pending_file.write_text(json.dumps(self.pending, indent=1))

    def expire_pending(self) -> list[dict]:
        """Снять с ожидания задачи, ответа по которым нет дольше PENDING_TTL.

        Возвращает список снятых записей — вызывающий решает, молчать (старт) или
        сказать владельцу (периодическая проверка).
        """
        now = datetime.now(timezone.utc)
        gone: list[dict] = []
        for corr, rec in list(self.pending.items()):
            try:
                age = (now - datetime.fromisoformat(
                    (rec.get("at") or "").replace("Z", "+00:00"))).total_seconds()
            except Exception:
                continue          # запись без времени: не трогаем, пусть решает человек
            if age > PENDING_TTL:
                gone.append({**rec, "corr": corr, "age": int(age)})
                self.pending.pop(corr, None)
        if gone:
            self.pending_file.write_text(json.dumps(self.pending, indent=1))
        return gone

    def resolve_pending(self, corr: str) -> dict | None:
        rec = self.pending.pop(corr, None)
        if rec:
            self.pending_file.write_text(json.dumps(self.pending, indent=1))
        return rec

    # -- task execution ------------------------------------------------------
    @staticmethod
    def parse_request(env: dict) -> tuple[str, dict]:
        """Extract (handler, args) from a message: explicit args first, then `handler k=v`."""
        handler, args = "", {}
        text = (env.get("text") or "").strip()
        if isinstance(env.get("args"), dict):
            args = dict(env["args"])
            handler = str(args.pop("handler", "") or env.get("handler", "") or "")
        if not handler:
            parts = text.split()
            handler = parts[0] if parts else "identity"
            for tok in parts[1:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    args[k] = v
        return handler, args

    async def handle(self, agent: Agent, env: dict, reply_to: str | None = None) -> dict:
        handler, args = self.parse_request(env)
        async with self.sem:
            res = builtin(agent, handler, args)
            if res is None:
                res = await asyncio.to_thread(run_handler, agent, handler, args,
                                              env.get("from") or "unknown")
        res["handler"] = handler
        return res

    async def on_message(self, nc, agent: Agent, env: dict, channel: str | None,
                         rpc_msg=None) -> None:
        kind = env.get("kind") or "event"
        who = env.get("from") or "unknown"
        started = time.time()
        log(f"{agent.id} ← {kind} from {who} (channel={channel or 'dm'}) "
            f"text={ (env.get('text') or '')[:60]!r}")

        if kind == "result" and env.get("correlation_id"):
            rec = self.resolve_pending(env["correlation_id"])
            if rec and agent.id == rec.get("dispatcher"):
                summary = (f"результат от {who} по задаче «{rec.get('task')}» "
                           f"({rec.get('handler')}): {'OK' if 'OK' not in (env.get('text') or '') else 'OK'}")
                await self.publish(nc, channel="orchestrator", kind="result",
                                   text=f"{summary}\n{ (env.get('text') or '')[:1200]}",
                                   correlation=env.get("correlation_id"),
                                   refs=env.get("refs") or [], agent=agent.id)
                return
            # a result nobody waits for is still knowledge
            await self.publish(nc, channel=channel or "knowledge", kind="result",
                               text=f"результат от {who}: {(env.get('text') or '')[:1500]}",
                               correlation=env.get("correlation_id"),
                               refs=env.get("refs") or [], agent=agent.id)
            return

        # `dispatch` is orchestration, not a shell handler: it routes to another agent
        # and returns immediately (the answer arrives later as a result message).
        handler_name, args = self.parse_request(env)
        # `ask` = deterministic facts first, then the agent's model explains them. The facts
        # come from the agent's own check script, so the model reasons over measurements
        # instead of inventing numbers.
        if handler_name == "ask":
            res = await self.answer_with_model(agent, env, args)
            took = round(time.time() - started, 2)
            body = res["text"]
            if channel:
                await self.publish(nc, channel=channel, kind="result",
                                   text=f"{body}\n\n🧠 {res.get('meta_line', '')} ({took}s)",
                                   correlation=env.get("correlation_id"), agent=agent.id,
                                   refs=res.get("refs") or [])
            else:
                await self.publish(nc, channel=None, to=who, kind="result",
                                   text=f"{body}\n\n🧠 {res.get('meta_line', '')} ({took}s)",
                                   correlation=env.get("correlation_id"), agent=agent.id,
                                   refs=res.get("refs") or [])
            return
        if agent.id == "orchestrator" and handler_name in ("dispatch", "route", "task"):
            await self.dispatch(nc, agent, {**env, "args": args}, channel)
            return
        res = await self.handle(agent, env)
        took = round(time.time() - started, 2)
        head = f"{agent.id}.{res['handler']} → {'OK' if res['ok'] else 'FAIL'}"
        body = f"{head} ({took}s)\n{res['text']}"
        if rpc_msg is not None:
            reply = envelope(channel=None, to=who, kind="reply", text=body,
                             correlation=env.get("correlation_id") or env.get("id"),
                             refs=res.get("refs") or [], agent=agent.id,
                             priority=env.get("priority") or "normal")
            await rpc_msg.respond(json.dumps(reply, ensure_ascii=False).encode())
        # Results always land somewhere durable: a direct answer for DMs/channels, and
        # an event on the channel when the task came from a channel.
        if channel:
            await self.publish(nc, channel=channel, kind="result", text=body,
                               correlation=env.get("correlation_id"),
                               refs=res.get("refs") or [], agent=agent.id)
        else:
            await self.publish(nc, channel=None, to=who, kind="result", text=body,
                               correlation=env.get("correlation_id"),
                               refs=res.get("refs") or [], agent=agent.id)
            if not res["ok"]:
                await self.publish(nc, channel="incidents", kind="error",
                                   text=f"{agent.id}: обработчик {res['handler']} "
                                        f"вернул код {res['code']} по задаче от {who}",
                                   correlation=env.get("correlation_id"), agent=agent.id)

    # -- publishing helper ---------------------------------------------------
    async def publish(self, nc, *, channel: str | None, kind: str, text: str,
                      to: str | None = None, correlation: str | None = None,
                      refs: list | None = None, agent: str = "orchestrator",
                      priority: str = "normal", args: dict | None = None) -> dict:
        env = envelope(channel=channel, to=to, kind=kind, text=text, priority=priority,
                       correlation=correlation, refs=refs or [], agent=agent)
        if args:
            env["args"] = args
        subject = (f"{SUBJECT_PREFIX}.dm.{to}.{priority}" if to
                   else f"{SUBJECT_PREFIX}.chat.{channel}.{priority}")
        await nc.publish(subject, json.dumps(env, ensure_ascii=False).encode())
        await nc.flush(timeout=5)
        await asyncio.to_thread(mirror_local, env)
        return env

    # -- model-assisted answers ---------------------------------------------
    async def answer_with_model(self, agent: Agent, env: dict, args: dict) -> dict:
        """Gather facts with the agent's own handler, then ask its model to explain them."""
        task = (env.get("text") or "").strip()
        for prefix in ("ask ",):
            if task.lower().startswith(prefix):
                task = task[len(prefix):].strip()
        facts_handler = routing.pick_handler(agent, args.get("facts_handler") or "status")
        # The subject the owner asked about must reach the fact-gathering script, otherwise
        # "что с процессом chromium" would explain the whole host instead of chromium.
        fact_args = {k: v for k, v in (args or {}).items()
                     if k not in ("handler", "facts_handler") and v}
        async with self.sem:
            facts = await asyncio.to_thread(run_handler, agent, facts_handler, fact_args,
                                            env.get("from") or "unknown")
        fact_text = facts.get("text") or "(нет данных)"
        analysis = bool(env.get("args", {}).get("analysis")) or True
        model, why = models.model_for(agent.id, task, analysis=analysis)
        text, meta = await asyncio.to_thread(
            models.ask, task, fact_text, agent.id, agent.description, str(server_id()), model)
        meta_line = (f"модель {meta.get('model')} ({why}) · "
                     f"{meta.get('latency_ms', 0)} мс")
        if not text:
            # Never fail the task: give the measurements and say plainly that the model is out.
            note = (f"⚠️ Модель недоступна ({meta.get('fallback') or 'нет ответа'}), "
                    f"поэтому просто факты:\n\n{fact_text}")
            return {"ok": True, "handler": "ask", "text": note, "code": 0,
                    "refs": facts.get("refs") or [], "meta_line": meta_line}
        log(f"ask: {agent.id} model={meta.get('model')} ({why}) "
            f"{meta.get('latency_ms', 0)}ms facts={facts_handler}")
        return {"ok": True, "handler": "ask", "text": text, "code": 0,
                "refs": facts.get("refs") or [], "meta_line": meta_line}

    # -- orchestrator built-ins ---------------------------------------------
    def route(self, task: str) -> dict:
        """Ask routing.py what this sentence means: (capability, handler, why, analysis)."""
        return routing.route(task, self.agents)

    async def dispatch(self, nc, agent: Agent, env: dict, channel: str | None) -> None:
        """Route a task to the best-suited agent by capability, then track the reply."""
        text = env.get("text") or ""
        args = env.get("args") or {}
        # A task typed in the owner's chat arrives as a channel message with a mention
        # ("@orchestrator проверить загрузку сервера"): strip the addressing, keep the ask.
        task = (args.get("task") or re.sub(r"@[\w/\-]+", " ", text)).strip()
        task = re.sub(r"^(task|задача)\s*[:\-]?\s*", "", task, flags=re.I).strip()
        task = re.sub(r"\s{2,}", " ", task)
        capability = args.get("capability") or ""
        target = args.get("agent") or ""
        why = ""
        # "какие агенты есть и их функции" is a question ABOUT the system, not a task for a
        # specialist. routing.route() marks it (target=orchestrator, handler=agents) and it
        # is answered here from the same registry the chat uses — so the chat and the bus
        # can never disagree about who is on the team.
        low_task = task.lower()
        if re.search(routing.META_AGENTS, low_task):
            await self.publish(nc, channel=channel or "orchestrator", kind="result",
                               text=roster.overview(), correlation=env.get("id"), agent=agent.id)
            return
        if re.search(routing.META_PROJECTS, low_task):
            await self.publish(nc, channel=channel or "orchestrator", kind="result",
                               text=roster.projects(), correlation=env.get("id"), agent=agent.id)
            return
        handler_hint = args.get("handler") or ""
        analysis = False
        decision_args: dict = {}
        if args.get("subject"):
            decision_args = {**decision_args, "subject": args["subject"]}
        if not target and not capability:
            decision = self.route(task)
            decision_args = decision
            capability = decision["capability"]
            target = decision["target"]
            why = decision["why"]
            handler_hint = handler_hint or decision["handler"]
            analysis = decision["analysis"]
            if not capability and not target:
                if decision.get("need_project"):
                    # Понятно, ЧТО просят, непонятно ГДЕ. Отвечаем полезно: называем
                    # проекты, в которых это можно выполнить.
                    what = decision["need_project"]
                    names = sorted(c.split(":", 1)[1] for a in self.agents.values()
                                   for c in a.capabilities if c.startswith("project:"))
                    await self.publish(nc, channel="orchestrator", kind="error",
                                       text=(f"🤔 Понял: нужно «{what}», но не понял, "
                                             f"в каком проекте.\n\n"
                                             f"Скажи, например:\n"
                                             f"• прогони тесты в logistics\n"
                                             f"• покажи логи madworld\n"
                                             f"• проверь деплой octopus\n\n"
                                             f"Проекты: {', '.join(names[:12])}"
                                             + (" …" if len(names) > 12 else "")),
                                       correlation=env.get("id"), agent=agent.id)
                    return
                await self.publish(nc, channel="orchestrator", kind="error",
                                   text=(f"🤔 Не понял: «{task[:120]}»\n\n"
                                         "Уточни направление — например:\n"
                                         "• проверить загрузку сервера\n"
                                         "• сделать бэкап\n"
                                         "• аудит безопасности\n"
                                         "• статус проекта logistics\n"
                                         "• прогони тесты в logistics\n\n"
                                         "Кто есть в команде: спроси «какие агенты»"),
                                   correlation=env.get("id"), agent=agent.id)
                return
        if not target:
            scored = []
            for a in self.agents.values():
                if a.id == agent.id:
                    continue
                score = sum(1 for c in a.capabilities if capability and c == capability)
                if capability and score == 0:
                    continue
                scored.append((score, a.id))
            scored.sort(reverse=True)
            target = scored[0][1] if scored else ""
        if not target or target not in self.agents:
            await self.publish(nc, channel="orchestrator", kind="error",
                               text=f"оркестратор: не найден агент под задачу «{task}» "
                                    f"(capability={capability!r}); известные: "
                                    f"{', '.join(sorted(self.agents))}",
                               correlation=env.get("id"), agent=agent.id)
            return
        if why:
            log(f"routed by text: «{task[:60]}» → {capability or target} ({why})")
        corr = env.get("correlation_id") or uuid.uuid4().hex[:12]
        # The route names the handler ("что грузит" -> top). Fall back to the agent's status
        # only when it does not declare the one we picked.
        handler = routing.pick_handler(self.agents[target], handler_hint or "status")
        if handler_hint and handler != handler_hint:
            log(f"handler {handler_hint!r} not declared by {target}; using {handler!r}")
        self.remember(corr, {"task": task, "agent": target, "handler": handler,
                             "dispatcher": agent.id, "channel": channel or "orchestrator",
                             "analysis": analysis, "subject": decision_args.get("subject", ""),
                             "at": datetime.now(timezone.utc).isoformat(timespec="seconds")})
        await self.publish(nc, channel=channel or "orchestrator", kind="task",
                           text=f"задача → {target}: {task} (handler={handler}, corr={corr})",
                           correlation=corr, agent=agent.id)
        # The target needs the ask in its own words: for `ask` we also pass the fact handler
        # that produced the numbers, so the model explains measurements instead of guessing.
        facts_with = "status"
        if handler == "ask":
            facts_with = (routing.route(task, self.agents).get("facts_handler") or "status")
        # The subject/action travel with the task: the target must investigate THAT process
        # or container, and (for `act`) know which verb was asked for.
        payload = {"handler": handler, "facts_handler": facts_with}
        for key in ("subject", "action", "what"):
            if decision_args.get(key):
                payload[key] = decision_args[key]
        await self.publish(nc, channel=None, to=target, kind="task",
                           text=f"{handler} {task}", correlation=corr, agent=agent.id,
                           args=payload)
        log(f"dispatched corr={corr} → {target}.{handler} ({why or 'explicit'})"
            f"{' + анализ' if analysis else ''}")

    async def on_channel(self, nc, agent: Agent, env: dict) -> None:
        text = env.get("text") or ""
        addressed = (f"@{agent.id}" in text or env.get("to") == agent.id
                     or (agent.id == "orchestrator" and env.get("channel") == "orchestrator"
                         and env.get("kind") == "task"))
        if not addressed:
            return
        if env.get("from") == agent.id:
            return
        # A task published into #orchestrator (by the owner's chat or by any node) is an
        # ask to route, not a message to read: without this, such a task sat in the channel
        # forever and the owner saw no answer.
        if agent.id == "orchestrator" and (env.get("kind") == "task"
                                           or "dispatch" in text or "задач" in text.lower()):
            await self.dispatch(nc, agent, env, env.get("channel"))
            return
        await self.on_message(nc, agent, env, channel=env.get("channel"))

    async def sweep_pending(self, nc) -> int:
        """Снять просроченные задачи и сказать об этом владельцу.

        Просроченная задача — это молчание агента, а не «в работе»: владелец ждёт ответа,
        и узнать об этом он должен сам, а не через /pending на сервере.
        """
        gone = self.expire_pending()
        for rec in gone:
            log(f"pending expired: {rec.get('corr')} {rec.get('agent')}.{rec.get('handler')}")
            await self.publish(
                nc, channel="incidents", kind="error",
                text=(f"⏰ задача «{(rec.get('task') or '')[:90]}» для {rec.get('agent')} "
                      f"снята с ожидания: ответа нет {rec['age'] // 3600} ч, обработчик "
                      f"{rec.get('handler')} не ответил (corr {rec.get('corr')})"),
                correlation=rec.get("corr"), agent="orchestrator")
        return len(gone)

    async def run(self) -> None:
        import nats
        url, token = nats_conf()
        log(f"agents: {len(self.agents)} defined — {', '.join(sorted(self.agents))}")
        backoff = 2
        while True:
            try:
                nc = await nats.connect(url, token=token, name=f"agents-{server_id()}",
                                        connect_timeout=5, max_reconnect_attempts=-1,
                                        reconnect_time_wait=2)
                log(f"connected to {url}")

                for agent in self.agents.values():
                    await self.subscribe_agent(nc, agent)

                # Roster announcement: the federation learns which capabilities this node
                # offers, so routing can pick a node instead of guessing.
                roster = {a.id: {"kind": a.kind, "capabilities": a.capabilities,
                                 "handlers": a.handler_names()} for a in self.agents.values()}
                await self.publish(nc, channel="server", kind="status",
                                   text=f"узел {server_id()} на шине: агентов {len(roster)} "
                                        f"({', '.join(sorted(roster))[:400]})",
                                   agent="orchestrator")

                for rec in self.expire_pending():
                    log(f"pending: снято с ожидания после старта — "
                        f"{rec.get('agent')}.{rec.get('handler')} ({rec['age'] // 60} мин)")

                async def status_watch():
                    while True:
                        await asyncio.sleep(300)
                        if nc.is_closed:
                            return
                        await self.sweep_pending(nc)
                asyncio.ensure_future(status_watch())
                backoff = 2
                while True:
                    await asyncio.sleep(5)
                    if nc.is_closed:
                        raise RuntimeError("bus connection closed")
            except Exception as e:
                log(f"bus unavailable ({type(e).__name__}: {e}); retry in {backoff}s — "
                    f"local work continues")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30)

    async def subscribe_agent(self, nc, agent: Agent) -> None:
        async def make_cb(channel: str | None, rpc: bool):
            async def cb(msg):
                try:
                    env = json.loads(msg.data.decode())
                except Exception as e:
                    log(f"{agent.id}: unparseable message: {e}")
                    return
                try:
                    if channel is None:
                        await self.on_message(nc, agent, env, None, rpc_msg=msg if rpc else None)
                    else:
                        await self.on_channel(nc, agent, env)
                except Exception as e:
                    log(f"{agent.id}: handler error {type(e).__name__}: {e}")
                    if rpc:
                        try:
                            err = envelope(channel=None, to=env.get("from"), kind="error",
                                           text=f"{agent.id} failed: {type(e).__name__}: {e}",
                                           correlation=env.get("correlation_id"), agent=agent.id)
                            await msg.respond(json.dumps(err, ensure_ascii=False).encode())
                        except Exception:
                            pass
            return cb

        await nc.subscribe(f"{SUBJECT_PREFIX}.dm.{agent.id}.>",
                           cb=await make_cb(None, False))
        await nc.subscribe(f"{RPC_PREFIX}.{agent.id}", cb=await make_cb(None, True))
        for ch in CHANNELS:
            await nc.subscribe(f"{SUBJECT_PREFIX}.chat.{ch}.>",
                               cb=await make_cb(ch, False))
        await nc.flush()
        log(f"  {agent.id}: dm + rpc + {len(CHANNELS)} channels "
            f"[{', '.join(agent.handler_names())[:80]}]")


def cmd_list() -> int:
    agents = load_agents()
    print(f"{len(agents)} agents defined in {CONFIG_DIR}")
    for a in sorted(agents.values(), key=lambda x: (x.kind, x.id)):
        print(f"  [{a.kind:<7}] {a.id:<22} caps={','.join(a.capabilities) or '-':<28} "
              f"handlers={','.join(a.handler_names()) or '-'}")
    return 0


def cmd_invoke(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: runtime.py invoke <agent> <handler> [key=value ...]", file=sys.stderr)
        return 2
    agents = load_agents()
    agent = agents.get(argv[0])
    if not agent:
        print(f"no agent {argv[0]!r}; known: {', '.join(sorted(agents))}", file=sys.stderr)
        return 2
    args = dict(kv.split("=", 1) for kv in argv[2:] if "=" in kv)
    res = builtin(agent, argv[1], args) or run_handler(agent, argv[1], args, "cli")
    print(f"[{'OK' if res['ok'] else 'FAIL'}] {agent.id}.{res.get('handler', argv[1])} "
          f"exit={res.get('code', 0)} took={res.get('took', '-')}s")
    print(res["text"])
    return 0 if res["ok"] else 1


def main() -> int:
    ap = argparse.ArgumentParser(prog="hermes-agents")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run")
    sub.add_parser("list")
    p = sub.add_parser("invoke"); p.add_argument("rest", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if a.cmd == "run":
        asyncio.run(Runtime().run())
        return 0
    if a.cmd == "list":
        return cmd_list()
    return cmd_invoke(a.rest)


if __name__ == "__main__":
    sys.exit(main())
