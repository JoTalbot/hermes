#!/usr/bin/env bash
# scripts/wire-agents.sh — give every agent a bus identity (agent_id, capabilities, handlers).
#
# WHY A GENERATOR AND NOT HAND-EDITED YAML: the bus wiring must be identical on every
# node, re-appliable after `git pull`, and impossible to drift. The block is delimited by
# a marker, so re-running replaces it and nothing else — human edits above the marker
# (identity, duties, safety) survive untouched.
#
# Every handler maps to a script in agents/checks/ or a runtime built-in. An agent can
# ONLY run what is declared here: a message on the bus names a handler, never a shell
# command. That is what keeps "minimal privileges" true in practice.
#
#   sudo bash scripts/wire-agents.sh            # wire core + project agents
#   sudo bash scripts/wire-agents.sh --check    # report drift, change nothing (exit 3 if drift)
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
export REPO_DIR CHECK
python3 - <<'PY'
import glob, os, re, subprocess, sys

REPO = os.environ["REPO_DIR"]
CHECK = os.environ.get("CHECK") == "1"
CHECKS = f"{REPO}/agents/checks"
MARK = "# --- agent bus wiring (managed by scripts/wire-agents.sh — do not hand-edit) ---"

def sysd_units(slug: str) -> list[str]:
    try:
        out = subprocess.run(["systemctl", "list-unit-files", "--type=service",
                              "--no-legend", "--plain"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return []
    hits = []
    for line in out.splitlines():
        name = line.split()[0] if line.split() else ""
        if not name:
            continue
        stem = name.removesuffix(".service")
        if slug in stem and "hermes" not in stem and "octopus-child" not in stem:
            hits.append(name)
    return sorted(set(hits))[:3]

def containers(slug: str) -> list[str]:
    try:
        out = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return []
    return sorted({n for n in out.split() if slug.split("-")[0] in n})[:4]

# ── core specialists ────────────────────────────────────────────────────────
CORE = {
    "orchestrator": dict(
        purpose="Единая точка маршрутизации: принимает задачу, выбирает агента по "
                "возможностям, отслеживает correlation_id и собирает результат.",
        capabilities=["orchestration", "routing", "coordination", "planning"],
        handlers={"status": f"bash {CHECKS}/orchestrator-status.sh",
                  "dispatch": None, "agents": None, "skills": None,
                  "identity": None, "ping": None}),
    "server-guardian": dict(
        purpose="Здоровье узла: systemd, docker, диск, память, загрузка, журнал ошибок.",
        capabilities=["host-health", "services", "docker", "disk", "load", "journal"],
        handlers={"status": f"bash {CHECKS}/guardian-status.sh",
                  "services": f"bash {CHECKS}/guardian-services.sh",
                  "hermes": f"bash {CHECKS}/hermes-status.sh",
                  "identity": None, "ping": None}),
    "github": dict(
        purpose="GitHub как источник истины: состояние репозиториев, CI, коммиты, "
                "отсутствие секретов в истории.",
        capabilities=["git", "github", "ci", "repo-state", "commit", "push"],
        handlers={"status": f"bash {CHECKS}/github-status.sh",
                  "secret-scan": f"bash {REPO}/scripts/secret-scan.sh --worktree",
                  "identity": None, "ping": None}),
    "security": dict(
        purpose="Безопасность: firewall, выставленные порты, права секретов, "
                "обновления, сканирование секретов.",
        capabilities=["security", "firewall", "secrets", "permissions", "exposure"],
        handlers={"audit": f"bash {CHECKS}/security-audit.sh",
                  "identity": None, "ping": None}),
    "monitoring": dict(
        purpose="Наблюдаемость: Prometheus targets, экспортеры, Grafana, правила "
                "алертов, состояние шины агентов.",
        capabilities=["monitoring", "prometheus", "grafana", "metrics", "alerts"],
        handlers={"health": f"bash {CHECKS}/monitoring-health.sh",
                  "identity": None, "ping": None}),
    "backup": dict(
        purpose="Резервные копии и восстановление: свежесть, целостность, "
                "репетиция восстановления.",
        capabilities=["backup", "restore", "recovery", "verify"],
        handlers={"status": f"bash {CHECKS}/backup-status.sh",
                  "verify": f"bash {CHECKS}/backup-verify.sh",
                  "identity": None, "ping": None}),
}

def block(agent_id, purpose, capabilities, handlers, extra_lines=()):
    """Render the managed bus block.

    `handlers` maps name -> None (runtime built-in) or a dict with run/timeout/env. The
    env of a handler is nested UNDER that handler — putting it after the loop made PyYAML
    read it as a handler named "env", which is exactly the kind of silent mis-wiring this
    generator exists to prevent.
    """
    import json
    lines = [MARK, "bus:", f"  agent_id: {agent_id}",
             f"  purpose: {json.dumps(purpose, ensure_ascii=False)}",
             "  capabilities:"]
    if capabilities:
        for c in capabilities:
            lines.append(f"  - {c}")
    else:
        lines.append("  - unassigned")
    lines.append("  handlers:")
    for name, spec in handlers.items():
        if not spec:
            lines.append(f"    {name}: {{}}          # runtime built-in")
            continue
        lines.append(f"    {name}:")
        lines.append(f"      run: {spec['run'] if isinstance(spec, dict) else spec}")
        lines.append("      timeout: 180")
        env = (spec or {}).get("env") if isinstance(spec, dict) else None
        if env:
            lines.append("      env:")
            for k, v in env.items():
                lines.append(f"        {k}: {json.dumps(str(v), ensure_ascii=False)}")
    for l in extra_lines:
        lines.append(l)
    return "\n".join(lines) + "\n"


def read_bus(path):
    txt = open(path).read()
    m = re.search(re.escape(MARK) + r".*", txt, re.S)
    return txt, (m.group(0) if m else None)

drift, written = [], []
for slug, spec in CORE.items():
    f = f"{REPO}/config/agents/{slug}.yaml"
    if not os.path.exists(f):
        print(f"  MISSING core agent file: {f}"); drift.append(slug); continue
    txt, old = read_bus(f)
    new = block(slug, spec["purpose"], spec["capabilities"], spec["handlers"])
    if old == new:
        continue
    if CHECK:
        drift.append(f"core:{slug}"); continue
    txt = txt.replace(old, "") if old else txt
    txt = txt.rstrip() + "\n\n" + new
    open(f, "w").write(txt)
    written.append(f"core:{slug}")

proj_dir = f"{REPO}/config/agents/projects"
for f in sorted(glob.glob(f"{proj_dir}/*.yaml")):
    slug = os.path.basename(f)[:-5]
    if slug == "README":
        continue
    try:
        import yaml
        d = yaml.safe_load(open(f)) or {}
    except Exception as e:
        print(f"  skip {slug}: unparseable YAML ({e})"); continue
    agent_id = slug if slug.startswith("proj-") else f"proj-{slug}"
    path = (d.get("technology") or {}).get("local_path") or ""
    repo = (d.get("technology") or {}).get("repo") or ""
    ops = d.get("operations") or {}
    # Real facts only: services and containers are discovered, never invented.
    units = sysd_units(slug) or ([ops["service"]] if ops.get("service") and ops["service"] != "DETECT" else [])
    ctns = containers(slug) or ([ops["containers"]] if ops.get("containers") and ops["containers"] != "DETECT" else [])
    health = [ops["health_url"]] if ops.get("health_url") else []
    caps = [f"project:{slug}", "repo-state"]
    if units: caps.append("service-state")
    if ctns: caps.append("container-state")
    env = {"PROJECT_SLUG": slug, "PROJECT_PATH": path, "PROJECT_REPO": repo}
    if units:  env["PROJECT_SERVICE"] = " ".join(units)
    if ctns:   env["PROJECT_CONTAINERS"] = " ".join(ctns)
    if health: env["PROJECT_HEALTH_URL"] = " ".join(health)
    h = {"status": {"run": f"bash {CHECKS}/project-check.sh", "env": env},
         "identity": None, "ping": None}
    purpose = (f"Project agent для {slug}: {path or 'путь не найден'} "
               f"({repo or 'remote не определён'})")
    b = block(agent_id, purpose, caps, h)
    txt, old = read_bus(f)
    if old == b:
        continue
    if CHECK:
        drift.append(f"project:{slug}"); continue
    txt = txt.replace(old, "") if old else txt
    open(f, "w").write(txt.rstrip() + "\n\n" + b)
    written.append(f"project:{slug}")

if CHECK:
    if drift:
        print(f"DRIFT: {len(drift)} agent(s) need re-wiring: {', '.join(drift[:12])}"
              + (" …" if len(drift) > 12 else ""))
        sys.exit(3)
    print("agent wiring: in sync")
else:
    print(f"wired {len(written)} agent config(s)"
          + (f": {', '.join(written[:8])}" + (" …" if len(written) > 8 else "") if written else ""))
PY
