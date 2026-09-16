#!/usr/bin/env bash
# scripts/register-skills.sh — make Hermes load the repo's skills.
#
# WHY THIS IS A SCRIPT AND NOT A LINE IN THE MANAGED CONFIG:
#   `agent/skill_utils.py` resolves external skill dirs by reading
#   `skills.external_dirs` from `get_config_path()` — which is
#   **$HERMES_HOME/config.yaml**, parsed directly by `_load_raw_config()`.
#   It never consults the managed scope in /etc/hermes.
#   Verified 2026-09-16: with the entry present ONLY in /etc/hermes/config.yaml,
#   `hermes skills list` still reported 0 skills; adding it to the user config
#   made all 9 appear at once.
#   Consequence: the value lives in runtime state (HERMES_HOME), so any rebuild
#   loses it. That is exactly the kind of gap that makes a "recovered" node look
#   healthy while every agent silently has no skills. Hence: idempotent script,
#   called from install.sh and bootstrap.sh.
#
# Idempotent: re-running changes nothing if the entry is already there.
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
SKILLS_DIR="${HERMES_SKILLS_DIR:-/opt/hermes/skills}"
CFG="/home/$HERMES_USER/.hermes/config.yaml"

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

[[ -d "$SKILLS_DIR" ]] || { echo "no such skills dir: $SKILLS_DIR" >&2; exit 2; }
# A directory holding no SKILL.md would register silently and then show up as
# "0 local" in hermes — refuse instead of writing a registry entry that does nothing.
if ! find "$SKILLS_DIR" -name SKILL.md -print -quit 2>/dev/null | grep -q .; then
    echo "no SKILL.md under $SKILLS_DIR — refusing to register an empty skills dir" >&2
    exit 2
fi
mkdir -p "$(dirname "$CFG")"
[[ -f "$CFG" ]] || install -m 0600 -o "$HERMES_USER" -g "$HERMES_USER" /dev/null "$CFG"

# Back up before editing: this file is runtime state with no other copy
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$CFG" "$CFG.bak.$STAMP" 2>/dev/null || true

python3 - "$CFG" "$SKILLS_DIR" <<'PY'
import re, sys, pathlib
cfg, skills_dir = pathlib.Path(sys.argv[1]), sys.argv[2]
text = cfg.read_text() if cfg.exists() else ""
entry = f"    - {skills_dir}"

if "external_dirs" in text:
    if skills_dir in text:
        print(f"  already registered: {skills_dir}")
        raise SystemExit(0)
    # external_dirs exists but without our path — insert after the key line
    text = re.sub(r"(external_dirs:\s*\n)", r"\1" + entry + "\n", text, count=1)
    if skills_dir not in text:
        print("  external_dirs present but could not be extended — edit manually", file=sys.stderr)
        raise SystemExit(1)
elif re.search(r"^skills:\s*$", text, re.M):
    text = re.sub(r"^skills:\s*$",
                  "skills:\n  external_dirs:\n" + entry, text, count=1)
else:
    text = text.rstrip("\n") + (
        "\n\n# Skills Hermes should load. Read from THIS file only — the managed\n"
        "# scope in /etc/hermes is not consulted by the skill loader.\n"
        "skills:\n  external_dirs:\n" + entry + "\n")

cfg.write_text(text)
print(f"  registered {skills_dir} in {cfg}")
PY

chown "$HERMES_USER:$HERMES_USER" "$CFG"; chmod 0600 "$CFG"

# Prove it actually took effect — a config edit nobody verified is a rumour.
# NOTE: run hermes via `env`, not `bash -lc "..."`. Nesting quotes inside a
# sudo-invoked script is how the first version of this check reported
# "<could not query>" on a perfectly good config — a broken check is worse than
# no check, because it turns success into a warning.
cd "/home/$HERMES_USER" 2>/dev/null || cd /

# Read the SUMMARY line, not the last line. Measured 2026-09-16: this command
# ends with a trailing blank line, so the obvious `| tail -1` yields an empty
# string and the check below then reports "<could not query>" on a perfectly
# healthy config — a broken check is worse than no check, because it turns
# success into a warning. Match the summary by content instead.
OUT="$(mktemp)"
sudo -u "$HERMES_USER" env HERMES_HOME="/home/$HERMES_USER/.hermes" HOME="/home/$HERMES_USER" \
    "/home/$HERMES_USER/.hermes-venv/bin/hermes" skills list >"$OUT" 2>/dev/null || true
COUNT="$(grep -E 'hub-installed' "$OUT" | tail -1)"
[[ -n "$COUNT" ]] || COUNT="$(tail -2 "$OUT" | head -1)"
rm -f "$OUT"
case "$COUNT" in
  *"0 local"*|"") echo "  WARNING: Hermes still sees no skills — check $CFG" >&2; exit 1 ;;
esac
echo "skills registered."
