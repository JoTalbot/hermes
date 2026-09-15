#!/usr/bin/env bash
# scripts/seed-memory.sh — install the shared knowledge base as Hermes memory.
#
# WHY: Hermes keeps built-in memory per profile at $HERMES_HOME[/profiles/<p>]/memories/
# MEMORY.md, which is what the agent actually reads at the start of every turn. The
# repo's memory/ directory is the durable, reviewable, git-tracked record — but an
# agent that only has the repo copy will not read it. This script joins the two:
#
#   1. the machine-wide FACT/OBSERVATION/HYPOTHESIS/DECISION/LESSON knowledge base
#      goes into the default profile's memory (so ad-hoc runs see it), and
#   2. every agent profile gets that same file PLUS a short role section built from
#      its own config/agents/*.yaml duties, so a specialist wakes up knowing its job.
#
# Idempotent: regenerates the whole file each run from its sources. Never contains a
# secret — it is written from repo files only.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HH="${HERMES_HOME:-/home/hermes/.hermes}"
GLOBAL="$REPO_DIR/config/MEMORY.global.md"
[[ -s "$GLOBAL" ]] || { echo "FATAL: missing $GLOBAL" >&2; exit 1; }

python3 - "$REPO_DIR" "$HH" <<'PY'
import os, sys, textwrap
repo, hh = sys.argv[1], sys.argv[2]
global_md = open(os.path.join(repo, "config", "MEMORY.global.md")).read()

try:
    import yaml
except Exception:
    yaml = None


def role_section(agent_yaml_path: str, slug: str) -> str:
    """Build a short 'your role on this machine' block from the agent definition."""
    if yaml is None:
        return ""
    try:
        d = yaml.safe_load(open(agent_yaml_path)) or {}
    except Exception:
        return ""
    lines = ["", "---", "", f"## Your role: `{slug}`", ""]
    desc = (d.get("profile") or {}).get("description")
    if desc:
        lines += [textwrap.fill(" ".join(str(desc).split()), 96), ""]
    duties = d.get("duties")
    if isinstance(duties, list) and duties:
        lines.append("Standing duties:")
        lines += [f"- {str(x).strip()}" for x in duties[:10]]
        lines.append("")
    deleg = d.get("delegation") or {}
    asks = deleg.get("asks") if isinstance(deleg, dict) else None
    if isinstance(asks, dict) and asks:
        lines.append("Delegate to (via `hermes kanban create --assignee <profile>`):")
        lines += [f"- `{k}` — {str(v).strip()}" for k, v in list(asks.items())[:10]]
        lines.append("")
    rules = d.get("hard_rules") or d.get("rules")
    if isinstance(rules, list) and rules:
        lines.append("Hard rules for this role:")
        lines += [f"- {str(x).strip()}" for x in rules[:10]]
        lines.append("")
    return "\n".join(lines)


def write(target_dir: str, extra: str = ""):
    os.makedirs(target_dir, exist_ok=True)
    path = os.path.join(target_dir, "MEMORY.md")
    body = global_md.rstrip() + "\n" + extra + "\n"
    old = open(path).read() if os.path.exists(path) else None
    if old != body:
        with open(path, "w") as fh:
            fh.write(body)
        return True
    return False


# index of specialist + project agent definitions by slug
defs = {}
for sub in ("agents", os.path.join("agents", "projects")):
    d = os.path.join(repo, "config", sub)
    if not os.path.isdir(d):
        continue
    for f in sorted(os.listdir(d)):
        if f.endswith(".yaml"):
            defs.setdefault(f[:-5], os.path.join(d, f))

changed = 0
if write(os.path.join(hh, "memories")):
    changed += 1
    print("  ~ default profile memory")

pdir = os.path.join(hh, "profiles")
for slug in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
    tgt = os.path.join(pdir, slug)
    if not os.path.isdir(tgt):
        continue
    extra = role_section(defs[slug], slug) if slug in defs else ""
    if write(os.path.join(tgt, "memories"), extra):
        changed += 1
        print(f"  ~ {slug}")

print(f"seed-memory: {changed} memory file(s) written, {len(defs)} agent definitions known")
PY

chown -R hermes:hermes "$HH" 2>/dev/null || true
echo "Agents read $HH[/profiles/<p>]/memories/MEMORY.md automatically at every turn."
