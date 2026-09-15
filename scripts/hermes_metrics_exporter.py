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
    ]
    try:
        d = _get_json(BRIDGE_URL + "/health")
        provs = (d.get("llm_balancer") or {}).get("providers") or []
        bad = sum(1 for p in provs if not p.get("healthy"))
        out.append("hermes_llm_balancer_up 1")
        out.append(f"hermes_llm_providers {len(provs)}")
        out.append(f"hermes_llm_providers_unhealthy {bad}")
        for p in provs:
            name = str(p.get("name", "?"))
            out.append(f'hermes_llm_provider_healthy{{provider="{name}",tier="{p.get("tier","?")}"}} '
                       f'{1 if p.get("healthy") else 0}')
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


PROBES = (probe_units, probe_shim, probe_balancer, probe_agents, probe_bus,
          probe_github, probe_tailscale)


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
