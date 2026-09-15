#!/usr/bin/env bash
# scripts/gen-project-agents.sh — regenerate config/agents/projects/*.yaml
#
# Ground truth order of authority:
#   1. the server filesystem  (a repo that isn't here gets no agent)
#   2. `git remote get-url origin` on that repo  (private repos are invisible to the
#      public GitHub API — do NOT treat a 404/missing entry as "repo does not exist")
#   3. GitHub API metadata  (optional, enriches language/description; never required)
#
# Run the discovery pass from the server, feed it in as a TSV, and it writes profiles.
#   ssh ubuntu@host 'bash -s' < scripts/discover-repos.sh > /tmp/repos.tsv
#   GITHUB_TOKEN=... scripts/gen-project-agents.sh /tmp/repos.tsv
#
# Idempotent: existing profile files are updated in place (status/workdir/dirty counts),
# hand-written mission text is preserved. Nothing is deleted unless --prune is given.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
TSV="${1:-/tmp/repos.tsv}"
PRUNE=0
[[ "${2:-}" == "--prune" ]] && PRUNE=1
[[ -s "$TSV" ]] || { echo "ERROR: need a non-empty TSV of discovered repos (arg 1)"; exit 2; }

mkdir -p config/agents/projects memory/projects
python3 - "$TSV" "$PRUNE" <<'PY'
import csv, json, os, subprocess, sys, yaml
tsv, prune = sys.argv[1], sys.argv[2] == "1"
allow_unreadable = os.environ.get("ALLOW_UNREADABLE") == "1"
DISK, bad, dupes, seen = {}, [], [], set()
with open(tsv) as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        slug = row["slug"].strip().lower()
        if not slug:
            continue
        if slug in seen:
            dupes.append((slug, row.get("path", "?")))
        seen.add(slug)
        if str(row.get("git_ok", "1")) != "1":
            bad.append((slug, row.get("path", "?")))
            if not allow_unreadable:
                continue
            row["_unreadable"] = True
        DISK[slug] = row
if dupes:
    print("REFUSING: duplicate slugs would silently overwrite each other's profile:")
    for slug, path in dupes:
        print(f"    {slug:<20} {path}")
    print("  Fix discover-repos.sh slug uniquification; do not hand-edit profiles to work around it.")
    sys.exit(3)
if bad and not allow_unreadable:
    print("REFUSING to write profiles — %d repo(s) had unreadable git state, so their" % len(bad))
    print("dirty-file counts are UNKNOWN and must not be recorded as 0 (a false 'clean'")
    print("invites an agent to reset a tree that has real work in it):")
    for slug, path in bad:
        print(f"    {slug:<16} {path}")
    print("  Fix: run scripts/discover-repos.sh as root, then re-run this script.")
    print("  Deliberate exception: ALLOW_UNREADABLE=1 records those repos as unknown-dirty.")
    sys.exit(3)

token = os.environ.get("GITHUB_TOKEN", "")
def gh_meta(slug):
    """Best-effort enrichment. A private/missing/403 result must never abort generation."""
    if not token:
        return {}
    try:
        out = subprocess.run(["curl", "-sS", "--max-time", "15",
                              f"https://api.github.com/repos/JoTalbot/{slug}",
                              "-H", f"Authorization: Bearer {token}"],
                             capture_output=True, text=True, timeout=25).stdout
        d = json.loads(out)
        if not isinstance(d, dict) or "full_name" not in d:
            return {}
        return {"description": (d.get("description") or "").strip(),
                "language": d.get("language") or "unknown",
                "default_branch": d.get("default_branch", "main"),
                "private": d.get("private", False),
                "size_kb": d.get("size", 0),
                "pushed": (d.get("pushed_at") or "")[:10]}
    except Exception:
        return {}

# --- slug reservation (real bug, 2026-09-15) --------------------------------
# A project checkout of the JoTalbot/orchestrator repo produced slug
# "orchestrator", which is ALSO the slug of the specialist control agent in
# config/agents/. Both map to one Hermes profile, so the generated project
# profile silently overwrote the Orchestrator's description. Specialist agent
# names are reserved; a colliding project is namespaced as proj-<slug>.
RESERVED = {os.path.splitext(f)[0] for f in os.listdir("config/agents")
            if f.endswith(".yaml")}
namespaced = []
for _s in list(DISK):
    if _s in RESERVED:
        DISK["proj-" + _s] = DISK.pop(_s)
        namespaced.append(_s)
if namespaced:
    print("NOTE: namespaced project slug(s) that collide with specialist agents: "
          + ", ".join(sorted(namespaced)) + " -> proj-<slug>")

seen = []
for slug, row in sorted(DISK.items()):
    path, branch, dirty = row["path"], row.get("branch", "") or "(detached)", int(row.get("dirty") or 0)
    origin = (row.get("origin") or "").strip()
    lang = (row.get("lang") or "").strip()
    if lang in ("", "?", "unknown"):
        lang = "unknown"
    meta = gh_meta(slug)
    if row.get("_unreadable"):
        dirty = 0
    f = f"config/agents/projects/{slug}.yaml"
    d = yaml.safe_load(open(f)) if os.path.exists(f) else None
    repo_url = f"https://github.com/JoTalbot/{origin or slug}" if origin or True else ""
    base = dict(
        profile=dict(slug=slug,
            description=(f"Project agent for {repo_url}. Local copy at {path}. Owns this repo's "
                         "code, tests, CI status and docs. Never touches another project's tree."),
            default_model="hermes-code", toolsets="git, terminal, file, kanban", workdir=path),
        status="active",
        mission=dict(purpose=meta.get("description") or "(no GitHub description — read the README on disk and record what it actually does as an OBSERVATION)",
                     current_goal="Ground truth first: does the local copy match GitHub, does it build, do tests pass."),
        technology=dict(language=meta.get("language", lang), framework="detect", database="detect",
                        infrastructure="deployed on srv-oci-arm-01 (see config/servers/arm-server-01.yaml)",
                        default_branch=meta.get("default_branch", branch),
                        local_path=path, branch_on_server=branch, repo=repo_url,
                        repo_private=meta.get("private"), last_pushed=meta.get("pushed", "")),
        operations=dict(start="DETECT", stop="DETECT", restart="DETECT", health="DETECT",
                        logs="DETECT", test="DETECT", deploy="DETECT",
                        _note="Agents obey placeholder commands. Replace every DETECT with a verified command, or delete it."),
        development=dict(tests="DETECT", lint="DETECT", typecheck="DETECT", build="DETECT"),
        safety=dict(protected_files=[".env", "*.pem", "authorized_keys"],
                    protected_services=["postgresql", "nginx", "docker", f"{slug}*"],
                    destructive_operations=["rm -rf", "git push --force", "drop table", "docker volume rm",
                                            "git reset --hard", "git clean -fd"],
                    uncommitted_files_at_audit=(None if row.get("_unreadable") else dirty),
                    git_state=(("UNRESOLVABLE — .git exists but git rejects it (missing HEAD). "
                                "Treat as unknown, not as clean.") if row.get("_unreadable") else "ok"),
                    uncommitted_warning=(f"{dirty} modified/untracked paths existed in {path} at audit time. "
                                         "Do NOT reset, checkout, stash or clean — commit deliberately or leave alone."
                                         if dirty else f"{path} was clean at audit; re-verify before any write.")),
        knowledge=dict(architecture=f"memory/projects/{slug}.md", roadmap="unset",
                       decisions=f"memory/decisions/ (grep for project: {slug})", incidents="memory/incidents/"),
    )
    if d:  # preserve human edits to identity/mission beyond the description
        for k in ("identity",):
            if k in d: base[k] = d[k]
        if d.get("mission", {}).get("purpose") and not meta.get("description"):
            base["mission"]["purpose"] = d["mission"]["purpose"]
    if not base.get("identity"):
        base["identity"] = (f"You are the {slug} project agent of the Hermes OS.\n\n"
          f"You own exactly one codebase: {repo_url}, checked out at {path} on branch {branch}.\n"
          "You are a maintainer of that project, not a general-purpose assistant. Server-wide questions\n"
          "go to server-guardian; CI/PR mechanics to github; exposure questions to security.\n"
          "Everything you write to memory is tagged FACT / OBSERVATION / HYPOTHESIS / DECISION / LESSON.")
    hdr = ("# GENERATED by scripts/gen-project-agents.sh — identity facts come from the live\n"
           "# filesystem + git remote. Re-run the script instead of hand-editing measured fields.\n")
    open(f, "w").write(hdr + yaml.safe_dump(base, sort_keys=False, width=110, allow_unicode=True))
    mf = f"memory/projects/{slug}.yaml"
    if not os.path.exists(mf):
        yaml.safe_dump(dict(project=slug, status="unaudited",
            facts=[dict(kind="FACT", note=f"checked out at {path} on branch {branch}; remote {repo_url}; {dirty} uncommitted paths at audit")],
            observations=[], hypotheses=[], decisions=[], incidents=[], lessons=[],
            unknowns=["build command", "test command", "deploy path", "runtime dependencies"]),
            open(mf, "w"), sort_keys=False, width=110, allow_unicode=True)
    seen.append(slug)

print(f"generated {len(seen)} project agents: {', '.join(seen)}")
if prune:
    for p in os.listdir("config/agents/projects"):
        if p.endswith(".yaml") and p[:-5] not in seen:
            print(f"  PRUNE candidate (not on disk): {p}")
PY
bash scripts/secret-scan.sh --worktree >/dev/null && echo "secret scan: clean"
