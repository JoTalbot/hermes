#!/usr/bin/env python3
"""Prometheus exporter for the Hermes OS layer.

REUSE, NOT REPLACEMENT
----------------------
This box already runs a Prometheus + Grafana stack (octopus-monitoring, host
network, :9090 / :3000) and a node exporter. This exporter adds ONLY the things
those cannot see: whether the Hermes layer itself is alive — the units, the
shim, the agent profiles, the kanban bus, and the managed-scope invariant. It
does not re-export CPU/RAM/disk and it does not touch the existing scrape
targets; it just adds one more target next to them.

Deliberately stdlib-only and read-only: it runs as an unprivileged user, never
writes anything, and never prints a secret.

Port: 9725 (loopback). Metrics prefixed `hermes_`.
"""
from __future__ import annotations

import json
import os
from datetime import datetime
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("HERMES_METRICS_BIND", "127.0.0.1")
PORT = int(os.environ.get("HERMES_METRICS_PORT", "9725"))
HERMES_HOME = os.environ.get("HERMES_HOME", "/home/hermes/.hermes")
SHIM_URL = os.environ.get("HERMES_SHIM_URL", "http://127.0.0.1:9700")
BRIDGE_URL = os.environ.get("AIOS_BRIDGE_URL", "http://127.0.0.1:9600")

CACHE: dict[str, tuple[float, list[str]]] = {}
CACHE_TTL = 10.0


def _lines(key: str, fn) -> list[str]:
    now = time.time()
    hit = CACHE.get(key)
    if hit and now - hit[0] < CACHE_TTL:
        return hit[1]
    try:
        out = fn()
    except Exception as exc:  # a broken probe must never take the exporter down
        out = [f"# probe {key} failed: {type(exc).__name__}"]
    CACHE[key] = (now, out)
    return out


def _get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=4) as r:
        return json.loads(r.read().decode() or "{}")


def _systemctl_active(unit: str) -> int:
    try:
        p = subprocess.run(["systemctl", "is-active", "--quiet", unit], timeout=5)
        return 1 if p.returncode == 0 else 0
    except Exception:
        return 0


# --------------------------------------------------------------------- probes
def probe_host_pressure() -> list[str]:
    """Host memory/swap/load — the metrics that decide whether Hermes survives.

    There is no node_exporter on this box, and the pressure that matters (another project's
    browser automation holding 16 of 23 GiB) is exactly what can OOM-kill nats and the
    agents. Measured here from /proc so alert rules can fire on it.
    """
    out = [
        "# HELP hermes_host_mem_used_pct Host RAM used, percent",
        "# TYPE hermes_host_mem_used_pct gauge",
        "# HELP hermes_host_mem_avail_bytes Host RAM available, bytes",
        "# TYPE hermes_host_mem_avail_bytes gauge",
        "# HELP hermes_host_swap_used_pct Host swap used, percent",
        "# TYPE hermes_host_swap_used_pct gauge",
        "# HELP hermes_host_load_per_core 1-minute load average divided by CPU count",
        "# TYPE hermes_host_load_per_core gauge",
        "# HELP hermes_proc_oom_score Current OOM score of a Hermes process (lower = safer)",
        "# TYPE hermes_proc_oom_score gauge",
    ]
    info = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            info[k.strip()] = float(v.strip().split()[0]) * 1024        # kB -> bytes
    except Exception:
        pass
    total = info.get("MemTotal") or 0
    avail = info.get("MemAvailable") or 0
    used = max(0.0, total - avail)
    swap_total = info.get("SwapTotal") or 0
    swap_free = info.get("SwapFree") or 0
    out.append(f"hermes_host_mem_used_pct {100 * used / total:.1f}" if total else
               "hermes_host_mem_used_pct 0")
    out.append(f"hermes_host_mem_avail_bytes {int(avail)}")
    out.append(f"hermes_host_swap_used_pct "
               f"{100 * (swap_total - swap_free) / swap_total:.1f}" if swap_total else
               "hermes_host_swap_used_pct 0")
    try:
        load1 = float(open("/proc/loadavg").read().split()[0])
        cores = os.cpu_count() or 1
        out.append(f"hermes_host_load_per_core {load1 / cores:.2f}")
    except Exception:
        out.append("hermes_host_load_per_core 0")

    # Are the Hermes processes actually protected from the OOM killer? A score of 0 means
    # "kill me as readily as anything else", which is what this probe was added to catch.
    for unit, score in _oom_scores(("nats-server", "hermes-agents", "hermes-bus-bridge",
                                    "hermes-gateway")):
        out.append(f'hermes_proc_oom_score{{unit="{unit}"}} {score}')
    return out


def _oom_scores(units: tuple[str, ...]) -> list[tuple[str, int]]:
    rows = []
    for unit in units:
        score = -1
        try:
            pid = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value", unit],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
            if pid and pid != "0":
                score = int(open(f"/proc/{pid}/oom_score").read().strip())
        except Exception:
            score = -1
        rows.append((unit, score))
    return rows


def probe_units() -> list[str]:
    out = [
        "# HELP hermes_unit_active 1 if the systemd unit is active",
        "# TYPE hermes_unit_active gauge",
    ]
    for unit in (
        "hermes-env-guard.service",
        "hermes-shim.service",
        "hermes-serve.service",
        "hermes-gateway.service",
    ):
        safe = unit.replace(".", "_").replace("-", "_")
        out.append(f'hermes_unit_active{{unit="{unit}",slug="{safe}"}} {_systemctl_active(unit)}')
    return out


def probe_shim() -> list[str]:
    out = [
        "# HELP hermes_shim_up 1 if the loopback OpenAI-compat shim answers /health",
        "# TYPE hermes_shim_up gauge",
        "# HELP hermes_shim_requests_total Requests handled by the shim",
        "# TYPE hermes_shim_requests_total counter",
        "# HELP hermes_shim_errors_total Failed shim requests",
        "# TYPE hermes_shim_errors_total counter",
        "# HELP hermes_shim_latency_ms_avg Mean upstream latency seen by the shim",
        "# TYPE hermes_shim_latency_ms_avg gauge",
    ]
    try:
        d = _get_json(SHIM_URL + "/health")
        m = d.get("metrics") or {}
        out.append("hermes_shim_up 1")
        out.append(f"hermes_shim_requests_total {int(m.get('requests_total') or 0)}")
        out.append(f"hermes_shim_errors_total {int(m.get('requests_failed') or 0)}")
        out.append(f"hermes_shim_latency_ms_avg {float(m.get('avg_latency_ms') or 0):.1f}")
        out.append(f'hermes_shim_info{{version="{d.get("version", "?")}"}} 1')
    except Exception:
        out.append("hermes_shim_up 0")
    return out


def probe_balancer() -> list[str]:
    out = [
        "# HELP hermes_llm_balancer_up 1 if the Octopus AIOS LLM balancer answers /health",
        "# TYPE hermes_llm_balancer_up gauge",
        "# HELP hermes_llm_providers Number of configured LLM providers",
        "# TYPE hermes_llm_providers gauge",
        "# HELP hermes_llm_providers_unhealthy Providers currently reporting unhealthy",
        "# TYPE hermes_llm_providers_unhealthy gauge",
        "# HELP hermes_llm_provider_healthy 1 if this provider is healthy, 0 if not",
        "# TYPE hermes_llm_provider_healthy gauge",
        "# HELP hermes_llm_provider_keys API keys configured for this provider",
        "# TYPE hermes_llm_provider_keys gauge",
        "# HELP hermes_llm_tier_healthy_providers Healthy providers per tier",
        "# TYPE hermes_llm_tier_healthy_providers gauge",
        "# HELP hermes_llm_cache_size Answers held in the balancer cache (tier-blind key)",
        "# TYPE hermes_llm_cache_size gauge",
    ]
    try:
        d = _get_json(BRIDGE_URL + "/health")
        provs = (d.get("llm_balancer") or {}).get("providers") or []
        bad = sum(1 for p in provs if not p.get("healthy"))
        out.append("hermes_llm_balancer_up 1")
        out.append(f"hermes_llm_providers {len(provs)}")
        out.append(f"hermes_llm_providers_unhealthy {bad}")
        out.append(f"hermes_llm_cache_size {int((d.get('llm_balancer') or {}).get('cache_size') or 0)}")
        tiers: dict[str, int] = {}
        for p in provs:
            name = str(p.get("name", "?")).replace('"', "")
            tier = str(p.get("tier", "?")).replace('"', "")
            out.append(f"hermes_llm_provider_healthy{{provider=\"{name}\",tier=\"{tier}\"}} "
                       f"{1 if p.get('healthy') else 0}")
            # FACT (2026-09-17): провайдер без ключа выглядит «здоровым», но ответить не может —
            # именно так тир code молча обслуживался fast-моделью.
            out.append(f'hermes_llm_provider_keys{{provider="{name}"}} {int(p.get("keys_count") or 0)}')
            tiers[tier] = tiers.get(tier, 0) + (1 if p.get("healthy") else 0)
        for tier, n in sorted(tiers.items()):
            out.append(f'hermes_llm_tier_healthy_providers{{tier="{tier}"}} {n}')
    except Exception:
        out.append("hermes_llm_balancer_up 0")
    return out


def probe_agents() -> list[str]:
    out = [
        "# HELP hermes_agent_profiles Number of registered Hermes agent profiles",
        "# TYPE hermes_agent_profiles gauge",
    ]
    pdir = os.path.join(HERMES_HOME, "profiles")
    n = 0
    if os.path.isdir(pdir):
        n = sum(1 for e in os.listdir(pdir) if os.path.isdir(os.path.join(pdir, e)))
    out.append(f"hermes_agent_profiles {n}")

    # managed-scope invariant: a non-755 /etc/hermes breaks every hermes command
    out += [
        "# HELP hermes_managed_dir_ok 1 if /etc/hermes is mode 755 (0750/0700 breaks Hermes)",
        "# TYPE hermes_managed_dir_ok gauge",
    ]
    try:
        out.append("hermes_managed_dir_ok 1" if (os.stat("/etc/hermes").st_mode & 0o777) == 0o755
                   else "hermes_managed_dir_ok 0")
    except Exception:
        out.append("hermes_managed_dir_ok 0")

    out += [
        "# HELP hermes_secret_env_present 1 if the loopback secret file exists (readable as root only)",
        "# TYPE hermes_secret_env_present gauge",
    ]
    out.append(f"hermes_secret_env_present {1 if os.path.exists('/etc/hermes/shim.env') else 0}")
    return out


def probe_bus() -> list[str]:
    """Task counts per status straight from the kanban SQLite board (read-only)."""
    out = [
        "# HELP hermes_kanban_tasks Tasks on the agent bus by status",
        "# TYPE hermes_kanban_tasks gauge",
        "# HELP hermes_kanban_db_present 1 if a kanban board database exists",
        "# TYPE hermes_kanban_db_present gauge",
    ]
    dbs = []
    root = os.path.join(HERMES_HOME, "kanban")
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if f == "kanban.db":
                dbs.append(os.path.join(dirpath, f))
    if not dbs:
        out.append("hermes_kanban_db_present 0")
        return out
    out.append("hermes_kanban_db_present 1")
    for db in dbs:
        board = os.path.basename(os.path.dirname(db))
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=4)
            rows = con.execute("SELECT status, COUNT(*) FROM tasks GROUP BY status").fetchall()
            con.close()
        except Exception:
            continue
        for status, cnt in rows:
            out.append(f'hermes_kanban_tasks{{board="{board}",status="{status}"}} {int(cnt)}')
    return out


def probe_github() -> list[str]:
    """Is the reproducible config committed and pushed? (local git only)"""
    out = [
        "# HELP hermes_repo_dirty Uncommitted paths in the Hermes config repo",
        "# TYPE hermes_repo_dirty gauge",
        "# HELP hermes_repo_unpushed Commits ahead of the tracked upstream",
        "# TYPE hermes_repo_unpushed gauge",
    ]
    repo = os.environ.get("HERMES_REPO", "/opt/hermes")
    if not os.path.isdir(os.path.join(repo, ".git")):
        out += ["hermes_repo_dirty 0", "hermes_repo_unpushed 0"]
        return out
    try:
        d = subprocess.run(["git", "-C", repo, "status", "--porcelain"],
                           capture_output=True, text=True, timeout=8).stdout
        out.append(f"hermes_repo_dirty {len([l for l in d.splitlines() if l.strip()])}")
    except Exception:
        out.append("hermes_repo_dirty -1")
    try:
        a = subprocess.run(["git", "-C", repo, "rev-list", "--count", "@{u}..HEAD"],
                           capture_output=True, text=True, timeout=8).stdout.strip()
        out.append(f"hermes_repo_unpushed {int(a or 0)}")
    except Exception:
        out.append("hermes_repo_unpushed 0")
    return out


def probe_tailscale() -> list[str]:
    out = [
        "# HELP hermes_tailscale_up 1 if the box is logged in to the tailnet",
        "# TYPE hermes_tailscale_up gauge",
    ]
    try:
        p = subprocess.run(["tailscale", "status", "--json"], capture_output=True,
                           text=True, timeout=6)
        if p.returncode == 0 and p.stdout.strip():
            st = json.loads(p.stdout)
            up = 1 if st.get("BackendState") == "Running" else 0
        else:
            up = 0
    except Exception:
        up = 0
    out.append(f"hermes_tailscale_up {up}")
    return out


# --------------------------------------------------------------------- bus/agents
# Added 2026-09-16 with the distributed Agent Bus. Before this, the exporter watched the
# kanban board only; the transport that actually carries cross-node traffic (NATS), the
# agents attached to it, and the peer nodes were invisible to Prometheus — so an alert
# could not exist for any of them.
def probe_agent_bus() -> list[str]:
    """NATS transport + JetStream stream + this node's consumer backlog."""
    out = [
        "# HELP hermes_bus_up 1 if the local NATS server answers its monitoring endpoint",
        "# TYPE hermes_bus_up gauge",
        "# HELP hermes_bus_connections Current client connections",
        "# TYPE hermes_bus_connections gauge",
        "# HELP hermes_bus_stream_messages Messages retained in the AGENT_BUS stream",
        "# TYPE hermes_bus_stream_messages gauge",
        "# HELP hermes_bus_consumer_ack_pending Unacked messages for this node's consumer",
        "# TYPE hermes_bus_consumer_ack_pending gauge",
        "# HELP hermes_bus_stream_bytes Bytes stored in the stream",
        "# TYPE hermes_bus_stream_bytes gauge",
    ]
    try:
        varz = _get_json("http://127.0.0.1:8222/varz")
    except Exception:
        out.append("hermes_bus_up 0")
        return out
    out.append("hermes_bus_up 1")
    out.append(f"hermes_bus_connections {int(varz.get('connections', 0))}")
    try:
        tok = ""
        try:
            with open("/etc/hermes/nats.env") as fh:
                for line in fh:
                    if line.startswith("NATS_TOKEN="):
                        tok = line.split("=", 1)[1].strip()
        except Exception:
            pass
        if tok:
            import nats  # type: ignore  # only in the bus venv; guarded below
    except Exception:
        pass
    # Read the stream via the bus CLI (it already knows the token handling) rather than
    # duplicating the client here.
    try:
        env = dict(os.environ)
        try:
            with open("/etc/hermes/nats.env") as fh:
                for line in fh:
                    if "=" in line and not line.startswith("#"):
                        k, v = line.strip().split("=", 1)
                        env.setdefault(k, v)
        except Exception:
            pass
        res = subprocess.run(["/usr/local/bin/hermes-bus-bridge", "status"],
                             capture_output=True, text=True, timeout=12, env=env)
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.startswith("stream"):
                m = re.search(r"msgs=(\d+) bytes=(\d+)", line)
                if m:
                    out.append(f"hermes_bus_stream_messages {int(m.group(1))}")
                    out.append(f"hermes_bus_stream_bytes {int(m.group(2))}")
            if "ack_pending=" in line:
                m = re.search(r"ack_pending=(\d+)", line)
                if m:
                    out.append(f"hermes_bus_consumer_ack_pending {int(m.group(1))}")
    except Exception:
        pass
    return out


def probe_bus_agents() -> list[str]:
    """Are the agents attached, and how many are defined/serving?"""
    out = [
        "# HELP hermes_agents_defined Agents wired in config/agents (agent_id + handlers)",
        "# TYPE hermes_agents_defined gauge",
        "# HELP hermes_agents_runtime_up 1 if an agents runtime process is alive",
        "# TYPE hermes_agents_runtime_up gauge",
        "# HELP hermes_agents_handlers_total Declared handlers across all agents",
        "# TYPE hermes_agents_handlers_total gauge",
        "# HELP hermes_agents_dispatched_pending Tasks the orchestrator is still waiting on",
        "# TYPE hermes_agents_dispatched_pending gauge",
        "# HELP hermes_nodes_known Nodes that have ever spoken on this bus",
        "# TYPE hermes_nodes_known gauge",
    ]
    try:
        import glob
        import yaml  # type: ignore
        defined = handlers = 0
        for f in (glob.glob("/opt/hermes/config/agents/*.yaml")
                  + glob.glob("/opt/hermes/config/agents/projects/*.yaml")):
            try:
                d = yaml.safe_load(open(f)) or {}
            except Exception:
                continue
            b = d.get("bus") or {}
            if b.get("agent_id"):
                defined += 1
                handlers += len(b.get("handlers") or {})
        out.append(f"hermes_agents_defined {defined}")
        out.append(f"hermes_agents_handlers_total {handlers}")
    except Exception:
        pass

    alive = 0
    for cmd in (["systemctl", "is-active", "--quiet", "hermes-agents"],):
        try:
            alive = 1 if subprocess.run(cmd, timeout=5).returncode == 0 else alive
        except Exception:
            pass
    if not alive:
        try:
            alive = 1 if subprocess.run(["pgrep", "-f", "agents/runtime.py run"],
                                        timeout=5).returncode == 0 else 0
        except Exception:
            alive = 0
    out.append(f"hermes_agents_runtime_up {alive}")

    try:
        ttl = int(os.environ.get("HERMES_PENDING_TTL", str(6 * 3600)))
        now = time.time()
        with open("/var/lib/hermes-agents/pending.json") as fh:
            pending = json.load(fh)
        overdue = 0
        for rec in (pending.values() if isinstance(pending, dict) else []):
            try:
                ts = datetime.fromisoformat(
                    (rec.get("at") or "").replace("Z", "+00:00")).timestamp()
            except Exception:
                continue
            if now - ts > ttl:
                overdue += 1
        out.append(f"hermes_agents_dispatched_pending {len(pending)}")
        out.append("# HELP hermes_agents_pending_overdue Задачи без ответа дольше PENDING_TTL")
        out.append("# TYPE hermes_agents_pending_overdue gauge")
        out.append(f"hermes_agents_pending_overdue {overdue}")
    except Exception:
        out.append("hermes_agents_dispatched_pending 0")
        out.append("hermes_agents_pending_overdue 0")

    try:
        with open("/var/lib/hermes-bus/nodes.json") as fh:
            nodes = json.load(fh)
        out.append(f"hermes_nodes_known {len(nodes)}")
        for name, rec in nodes.items():
            safe = re.sub(r"[^A-Za-z0-9_-]", "_", name)
            msgs = int(rec.get("msgs") or 0)
            out.append(f'hermes_node_messages_total{{node="{safe}"}} {msgs}')
    except Exception:
        out.append("hermes_nodes_known 0")
    return out


def _path_state(path: str) -> int:
    """0 = нет на диске, 1 = есть, 2 = есть, но не видно этому пользователю.

    OBSERVATION 2026-09-17: экспортёр работает под юзером hermes, а /home/ubuntu — 0750
    ubuntu:ubuntu, поэтому четыре ЖИВЫХ проекта (words, octopus, batch19, batch20)
    показывались как отсутствующие и сутки горел HermesProjectTreeMissing. os.path.isdir()
    глотает PermissionError и возвращает False, то есть «не вижу» превращалось в «нет» —
    ложный алерт хуже отсутствия алерта.
    """
    import stat as _stat
    try:
        return 1 if _stat.S_ISDIR(os.stat(path).st_mode) else 0
    except FileNotFoundError:
        return 0
    except PermissionError:
        return 2
    except OSError:
        return 2


def probe_projects() -> list[str]:
    """Project agents: how many projects are represented, and is their tree still there?
    A project agent whose local_path vanished is a silent, permanent lie in the registry."""
    out = [
        "# HELP hermes_projects_wired Project agents defined",
        "# TYPE hermes_projects_wired gauge",
        "# HELP hermes_project_path_present 1 if the project's local_path exists, 0 if absent,"
        " 2 if it exists but this user cannot see it (permissions)",
        "# TYPE hermes_project_path_present gauge",
        "# HELP hermes_project_dirty Uncommitted paths in the project repo",
        "# TYPE hermes_project_dirty gauge",
    ]
    try:
        import glob
        import yaml  # type: ignore
        n = 0
        for f in glob.glob("/opt/hermes/config/agents/projects/*.yaml"):
            try:
                d = yaml.safe_load(open(f)) or {}
            except Exception:
                continue
            tech = d.get("technology") or {}
            path = tech.get("local_path")
            if not path:
                continue
            n += 1
            slug = re.sub(r"[^A-Za-z0-9_-]", "_", os.path.basename(f)[:-5])
            state = _path_state(path)
            out.append(f'hermes_project_path_present{{project="{slug}"}} {state}')
            if state == 1 and os.path.isdir(os.path.join(path, ".git")):
                try:
                    r = subprocess.run(["git", "-C", path, "status", "--porcelain"],
                                       capture_output=True, text=True, timeout=10)
                    dirty = len([l for l in r.stdout.splitlines() if l.strip()])
                    out.append(f'hermes_project_dirty{{project="{slug}"}} {dirty}')
                except Exception:
                    pass
        out.append(f"hermes_projects_wired {n}")
    except Exception:
        pass
    return out


def probe_agent_history() -> list[str]:
    """Что агенты реально сделали: запуски, ошибки и p95 по каждому агенту.

    До этого экспортёр видел только процесс runtime (жив/мёртв) и ничего о его работе:
    обработчик мог падать на каждом запуске, и ни одна метрика не двигалась. Счётчики
    берутся из истории прогонов, которую пишет сам runtime (строка JSON на запуск).
    """
    path = os.environ.get("HERMES_HISTORY_FILE", "/var/lib/hermes-agents/history.jsonl")
    out = [
        "# HELP hermes_agent_history_present 1 if the agent run history is readable",
        "# TYPE hermes_agent_history_present gauge",
        "# HELP hermes_agent_history_records Handler runs in the retained history",
        "# TYPE hermes_agent_history_records gauge",
        "# HELP hermes_agent_runs_total Handler runs per agent (retained window)",
        "# TYPE hermes_agent_runs_total counter",
        "# HELP hermes_agent_failures_1h Failed handler runs per agent in the last hour",
        "# TYPE hermes_agent_failures_1h gauge",
        "# HELP hermes_agent_duration_p95_ms 95th percentile handler duration per agent",
        "# TYPE hermes_agent_duration_p95_ms gauge",
        "# HELP hermes_agent_last_run_timestamp_seconds Unix time of the agent's last run",
        "# TYPE hermes_agent_last_run_timestamp_seconds gauge",
    ]
    per: dict[str, dict] = {}
    total = 0
    now = time.time()
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                name = str(r.get("agent", "?"))
                a = per.setdefault(name, {"runs": 0, "fail1h": 0, "dur": [], "last": 0})
                a["runs"] += 1
                total += 1
                a["dur"].append(int(r.get("took_ms") or 0))
                epoch = int(r.get("epoch") or 0)
                a["last"] = max(a["last"], epoch)
                if int(r.get("code") or 0) != 0 and now - epoch <= 3600:
                    a["fail1h"] += 1
    except OSError:
        out.append("hermes_agent_history_present 0")
        return out
    out.append("hermes_agent_history_present 1")
    out.append(f"hermes_agent_history_records {total}")
    for name, a in sorted(per.items()):
        lbl = '{agent="%s"}' % name.replace('\\', '').replace('"', '')
        d = sorted(a["dur"])
        p95 = d[max(0, min(len(d) - 1, int(round(0.95 * (len(d) - 1)))))] if d else 0
        out.append(f"hermes_agent_runs_total{lbl} {a['runs']}")
        out.append(f"hermes_agent_failures_1h{lbl} {a['fail1h']}")
        out.append(f"hermes_agent_duration_p95_ms{lbl} {p95}")
        out.append(f"hermes_agent_last_run_timestamp_seconds{lbl} {a['last']}")
    return out


def probe_model_telemetry() -> list[str]:
    """Какие тиры моделей отвечают, как часто срываются и сколько ждёт очередь.

    Разбирается та же история прогонов, что пишет runtime: записи с handler=ask несут
    tier/model/fallback/latency, фоновые прогоны — queue_ms. До этого деградация балансера
    была невидима: система продолжала отвечать, просто дороже и медленнее.
    """
    path = os.environ.get("HERMES_HISTORY_FILE", "/var/lib/hermes-agents/history.jsonl")
    out = [
        "# HELP hermes_model_requests_1h Model requests per tier in the last hour",
        "# TYPE hermes_model_requests_1h gauge",
        "# HELP hermes_model_fallbacks_1h Requests a tier could not answer (fallback to local)",
        "# TYPE hermes_model_fallbacks_1h gauge",
        "# HELP hermes_model_latency_p95_ms 95th percentile model latency per tier",
        "# TYPE hermes_model_latency_p95_ms gauge",
        "# HELP hermes_queue_wait_p95_ms 95th percentile queue wait before a handler started",
        "# TYPE hermes_queue_wait_p95_ms gauge",
        "# HELP hermes_model_served_1h Actually served tier/provider in the last hour",
        "# TYPE hermes_model_served_1h gauge",
        "# HELP hermes_model_tier_mismatch_1h Answers served by a different tier than requested",
        "# TYPE hermes_model_tier_mismatch_1h gauge",
    ]
    now = time.time()
    tiers: dict[str, dict] = {}
    served_counts: dict[tuple[str, str], int] = {}
    queue: list[int] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                epoch = int(r.get("epoch") or 0)
                if r.get("queue_ms"):
                    queue.append(int(r["queue_ms"]))
                if r.get("handler") != "ask":
                    continue
                tier = str(r.get("tier") or "?")
                t = tiers.setdefault(tier, {"n": 0, "fb": 0, "lat": []})
                t["lat"].append(int(r.get("took_ms") or 0))
                if now - epoch <= 3600:
                    t["n"] += 1
                    if r.get("fallback"):
                        t["fb"] += 1
                    served = str(r.get("served_tier") or "")
                    if served:
                        key = (served, str(r.get("provider") or "?"))
                        served_counts[key] = served_counts.get(key, 0) + 1
                    if r.get("tier_mismatch"):
                        served_counts[("mismatch", tier)] = \
                            served_counts.get(("mismatch", tier), 0) + 1
    except OSError:
        return out
    for tier, t in sorted(tiers.items()):
        lbl = '{tier="%s"}' % tier.replace('"', '')
        d = sorted(t["lat"])
        p95 = d[max(0, min(len(d) - 1, int(round(0.95 * (len(d) - 1)))))] if d else 0
        out.append(f"hermes_model_requests_1h{lbl} {t['n']}")
        out.append(f"hermes_model_fallbacks_1h{lbl} {t['fb']}")
        out.append(f"hermes_model_latency_p95_ms{lbl} {p95}")
    for (served, provider), n in sorted(served_counts.items()):
        if served == "mismatch":
            out.append(f'hermes_model_tier_mismatch_1h{{tier="{provider}"}} {n}')
        else:
            out.append('hermes_model_served_1h{tier="%s",provider="%s"} %d'
                       % (served.replace('"', ""), provider.replace('"', ""), n))
    if queue:
        q = sorted(queue)
        out.append("hermes_queue_wait_p95_ms "
                   f"{q[max(0, min(len(q) - 1, int(round(0.95 * (len(q) - 1)))))]}")
    return out


def _guard_state(path: str) -> dict:
    try:
        return json.loads(open(path, encoding="utf-8").read())
    except Exception:
        return {}


def probe_guard_state() -> list[str]:
    """Сторожа: лимиты контейнеров и разводка агентов.

    Числа берутся из состояния, которое пишут scripts/container-guard.sh и
    scripts/wiring-guard.sh (у экспортёра нет прав docker, и не нужно их давать ради метрики).
    Раньше обе защиты могли исчезнуть молча: лимит снимается вместе с пересозданием
    контейнера, разводка уезжает от чужого контейнера — и ни одна метрика не двигалась.
    """
    out = [
        "# HELP hermes_container_limit_drift Containers whose live memory limit differs from the",
        "#   approved one at the last guard run",
        "# TYPE hermes_container_limit_drift gauge",
        "# HELP hermes_container_guard_age_seconds Seconds since the container guard last ran",
        "# TYPE hermes_container_guard_age_seconds gauge",
        "# HELP hermes_wiring_drift 1 if agent wiring differed from the generator at the last check",
        "# TYPE hermes_wiring_drift gauge",
        "# HELP hermes_wiring_guard_age_seconds Seconds since the wiring guard last ran",
        "# TYPE hermes_wiring_guard_age_seconds gauge",
    ]
    now = time.time()
    cg = _guard_state(os.environ.get("HERMES_CONTAINER_GUARD_STATE",
                                     "/var/lib/hermes-bus/container-guard.json"))
    if cg:
        out.append(f"hermes_container_limit_drift {int(cg.get('drift') or 0)}")
        out.append(f"hermes_container_guard_age_seconds {max(0, int(now - int(cg.get('ts') or 0)))}")
    else:
        out.append("hermes_container_guard_age_seconds -1")
    wg = _guard_state(os.environ.get("HERMES_WIRING_GUARD_STATE",
                                     "/var/lib/hermes-bus/wiring-guard.json"))
    if wg:
        out.append(f"hermes_wiring_drift {int(wg.get('drift') or 0)}")
        out.append(f"hermes_wiring_guard_age_seconds {max(0, int(now - int(wg.get('ts') or 0)))}")
    else:
        out.append("hermes_wiring_guard_age_seconds -1")
    return out


def probe_project_staleness() -> list[str]:
    """Насколько локальная копия проекта отстала от GitHub.

    FACT (2026-09-17): копии пяти проектов были трёхдневной давности (fs — на 641 коммит
    позади), а метрик на это не было: экспортёр отдавал только dirty. Оркестратор при этом
    работал на устаревшем коде, и ни одно правило об этом не сказало.
    """
    out = [
        "# HELP hermes_project_behind Commits the local copy is behind its upstream",
        "# TYPE hermes_project_behind gauge",
        "# HELP hermes_project_ahead Commits the local copy has not pushed to upstream",
        "# TYPE hermes_project_ahead gauge",
    ]
    import glob
    try:
        import yaml  # type: ignore
    except Exception:
        return out
    for f in glob.glob("/opt/hermes/config/agents/projects/*.yaml"):
        try:
            d = yaml.safe_load(open(f)) or {}
        except Exception:
            continue
        tech = d.get("technology") or {}
        path = tech.get("local_path")
        if not path or not os.path.isdir(os.path.join(path, ".git")):
            continue
        slug = re.sub(r"[^A-Za-z0-9_-]", "_", os.path.basename(f)[:-5])
        for label, rev in (("behind", "HEAD..@{u}"), ("ahead", "@{u}..HEAD")):
            try:
                r = subprocess.run(["git", "-C", path, "rev-list", "--count", rev],
                                   capture_output=True, text=True, timeout=10)
                if r.returncode != 0 or not r.stdout.strip().isdigit():
                    continue
                out.append(f'hermes_project_{label}{{project="{slug}"}} {int(r.stdout.strip())}')
            except Exception:
                continue
    return out



def probe_backup() -> list[str]:
    """Свежесть бэкапа: расписание есть, а если таймер отвалится — никто не заметит."""
    out = [
        "# HELP hermes_backup_age_hours Hours since the newest state backup",
        "# TYPE hermes_backup_age_hours gauge",
        "# HELP hermes_backup_count State backups kept on disk",
        "# TYPE hermes_backup_count gauge",
        "# HELP hermes_backup_bytes Total size of the backup directory",
        "# TYPE hermes_backup_bytes gauge",
    ]
    import glob
    root = os.environ.get("HERMES_BACKUP_DIR", "/var/backups/hermes")
    files = glob.glob(os.path.join(root, "hermes-state-*.tar.gz"))
    out.append(f"hermes_backup_count {len(files)}")
    if not files:
        out.append("hermes_backup_age_hours -1")
        return out
    newest = max(files, key=lambda p: os.path.getmtime(p))
    out.append(f"hermes_backup_age_hours {(time.time() - os.path.getmtime(newest)) / 3600:.2f}")
    total = 0
    for p in files:
        try:
            total += os.path.getsize(p)
        except OSError:
            pass
    out.append(f"hermes_backup_bytes {total}")
    return out


def probe_journal() -> list[str]:
    """Размер системного журнала: 1.0 GiB при потолке 500M говорит, что ротация не успевает."""
    out = [
        "# HELP hermes_journal_bytes Bytes used by the systemd journal",
        "# TYPE hermes_journal_bytes gauge",
    ]
    total = 0
    try:
        for dirpath, _dirs, files in os.walk("/var/log/journal"):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(dirpath, f))
                except OSError:
                    pass
    except OSError:
        pass
    out.append(f"hermes_journal_bytes {total}")
    return out


def probe_feedback() -> list[str]:
    """Оценки владельца: 👍/👎 под ответами агентов. Качество измеряется, а не предполагается."""
    out = [
        "# HELP hermes_feedback_total Owner ratings of agent answers (verdict=up|down)",
        "# TYPE hermes_feedback_total counter",
        "# HELP hermes_feedback_24h Ratings in the last 24 hours",
        "# TYPE hermes_feedback_24h gauge",
    ]
    path = os.environ.get("HERMES_FEEDBACK_FILE", "/var/lib/hermes-agents/feedback.jsonl")
    up = down = up24 = down24 = 0
    now = time.time()
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                fresh = now - int(r.get("epoch") or 0) <= 86400
                if r.get("verdict") == "up":
                    up += 1
                    up24 += 1 if fresh else 0
                elif r.get("verdict") == "down":
                    down += 1
                    down24 += 1 if fresh else 0
    except OSError:
        pass
    out.append(f'hermes_feedback_total{{verdict="up"}} {up}')
    out.append(f'hermes_feedback_total{{verdict="down"}} {down}')
    out.append(f"hermes_feedback_24h {up24 + down24}")
    return out


PROBES = (probe_units, probe_host_pressure, probe_shim, probe_balancer, probe_agents, probe_bus,
          probe_github, probe_tailscale, probe_agent_bus, probe_bus_agents,
          probe_projects, probe_agent_history, probe_model_telemetry,
          probe_guard_state, probe_project_staleness, probe_backup, probe_journal,
          probe_feedback)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        if self.path not in ("/metrics", "/"):
            body = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        lines: list[str] = []
        for fn in PROBES:
            lines += _lines(fn.__name__, fn)
        raw = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main() -> int:
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    print(f"hermes-metrics-exporter listening on http://{BIND}:{PORT}/metrics", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
