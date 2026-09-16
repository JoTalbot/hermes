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
import shlex
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bus"))
from bus import (CHANNELS, RPC_PREFIX, SUBJECT_PREFIX, envelope, mirror_local,  # noqa: E402
                 nats_conf, server_id)

CONFIG_DIR = Path("/opt/hermes/config/agents")
PROJECT_AGENTS_DIR = CONFIG_DIR / "projects"
SKILLS_DIR = Path("/opt/hermes/skills")
STATE_DIR = Path("/var/lib/hermes-agents")
LOG_DIR = STATE_DIR / "logs"
MAX_CONCURRENT = 2
OUTPUT_LIMIT = 6000


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
class Agent:
    def __init__(self, path: Path):
        self.path = path
        cfg = load_yaml(path)
        prof = cfg.get("profile") or {}
        bus = cfg.get("bus") or {}
        self.id = bus.get("agent_id") or prof.get("slug") or path.stem
        self.slug = prof.get("slug") or path.stem
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
    import os as _os
    only = (_os.environ.get("HERMES_LOCAL_AGENTS") or "all").strip().lower()
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
    # Static per-handler environment from the agent's YAML (project path, service name…).
    env.update({str(k): str(v) for k, v in (spec.get("env") or {}).items() if v is not None})
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logfile = LOG_DIR / f"{agent.id}-{handler}-{int(time.time())}.log"
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
                      priority: str = "normal") -> dict:
        env = envelope(channel=channel, to=to, kind=kind, text=text, priority=priority,
                       correlation=correlation, refs=refs or [], agent=agent)
        subject = (f"{SUBJECT_PREFIX}.dm.{to}.{priority}" if to
                   else f"{SUBJECT_PREFIX}.chat.{channel}.{priority}")
        await nc.publish(subject, json.dumps(env, ensure_ascii=False).encode())
        await nc.flush(timeout=5)
        await asyncio.to_thread(mirror_local, env)
        return env

    # -- orchestrator built-ins ---------------------------------------------
    async def dispatch(self, nc, agent: Agent, env: dict, channel: str | None) -> None:
        """Route a task to the best-suited agent by capability, then track the reply."""
        text = env.get("text") or ""
        args = env.get("args") or {}
        task = args.get("task") or text
        capability = args.get("capability") or ""
        target = args.get("agent") or ""
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
        corr = env.get("correlation_id") or uuid.uuid4().hex[:12]
        handler = args.get("handler") or "status"
        self.remember(corr, {"task": task, "agent": target, "handler": handler,
                             "dispatcher": agent.id, "channel": channel or "orchestrator",
                             "at": datetime.now(timezone.utc).isoformat(timespec="seconds")})
        await self.publish(nc, channel=channel or "orchestrator", kind="task",
                           text=f"задача → {target}: {task} (handler={handler}, corr={corr})",
                           correlation=corr, agent=agent.id)
        await self.publish(nc, channel=None, to=target, kind="task",
                           text=f"{handler} {task}", correlation=corr, agent=agent.id)
        log(f"dispatched corr={corr} → {target}.{handler}")

    async def on_channel(self, nc, agent: Agent, env: dict) -> None:
        text = env.get("text") or ""
        if f"@{agent.id}" not in text and not env.get("to") == agent.id:
            return
        if env.get("from") == agent.id:
            return
        if agent.id == "orchestrator" and ("dispatch" in text or "задач" in text.lower()):
            await self.dispatch(nc, agent, env, env.get("channel"))
            return
        await self.on_message(nc, agent, env, channel=env.get("channel"))

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

                async def status_watch():
                    while True:
                        await asyncio.sleep(300)
                        if nc.is_closed:
                            return
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
