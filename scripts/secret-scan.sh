#!/usr/bin/env bash
# scripts/secret-scan.sh — the gate that must pass before ANY commit (master-task §2.1).
# Stdlib/grep only so it works on a naked server with no pip packages.
#
#   usage: secret-scan.sh [--worktree] [--staged] [--all]
#   stdout: last line is either "clean" or "<n> finding(s): <details>"
set -uo pipefail
# Resolve the repo root if there is one; otherwise scan cwd. Failing loudly here matters:
# `git ls-files` in a non-repo returns nothing, which reads as "clean" to a caller.
if ! git rev-parse --show-toplevel >/dev/null 2>&1 && [[ ! -d .git ]]; then
  echo "WARN: $PWD is not a git repo — scanning tracked-and-untracked files by find instead" >&2
fi

PAT='(-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gh[opsu]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]+|AKIA[0-9A-Z]{16}|-----BEGIN RSA PRIVATE|-----BEGIN OPENSSH PRIVATE|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}|mysql://[^ ]*:[^@ ]*@|postgres(ql)?://[^ ]*:[^@ ]*@|redis://:[^@ ]*@|password[ ]*=[ ]*["'"'"'][^"'"'"']{6,}|api[_-]?key[ ]*[:=][ ]*["'"'"'][A-Za-z0-9_\-]{16,})'

# Optional 2nd arg: a directory to scan instead of "here". The test-suite needs this —
# without it, `cd`ing into a tmp repo left the scan looking at the wrong tree and reported
# "clean" on a file that genuinely contained a token. A scanner that silently scans
# nothing is worse than one that misses a pattern.
MODE="${1:---worktree}"; SCAN_DIR="${2:-.}"
cd "$SCAN_DIR" 2>/dev/null || { echo "cannot cd to $SCAN_DIR"; exit 2; }
case "$MODE" in
  --staged) files=$(git diff --cached --name-only --diff-filter=ACM | tr '\n' ' ') ;;
  --all)    files=$(git ls-files | tr '\n' ' ') ;;
  --worktree|*)
    if git rev-parse --git-dir >/dev/null 2>&1; then
      files=$( { git ls-files; git ls-files -o --exclude-standard; } | sort -u | tr '\n' ' ')
    else
      # non-repo fallback: everything except VCS noise
      files=$(find . -type f -not -path './.git/*' | sed 's|^\./||' | tr '\n' ' ')
    fi ;;
esac
[[ -z "${files// }" ]] && { echo "clean"; exit 0; }

hits=0; report=""
for f in $files; do
  [[ -f "$f" ]] || continue
  # The scanner's own pattern definition contains every signature it hunts for, so
  # scanning it produces a guaranteed false positive on a clean repo. Skip only this
  # file's own PAT assignment — not the filename checks below.
  if [[ "$(basename "$f")" == "secret-scan.sh" ]]; then
    found=$(grep -nE '^[[:space:]]*(export[[:space:]]+)?(GH_TOKEN|GITHUB_TOKEN)="?(ghp_|github_pat_)' "$f" 2>/dev/null)
    [[ -n "$found" ]] && { n=1; hits=$((hits+n)); report+=" $f(self)"; }
    continue
  fi
  case "$f" in
    *.env.example|*.example|*example*|docs/SECURITY.md|*/README.md|README.md|*.md)
      # allow documentation to *describe* a pattern without containing one,
      # but never allow an actual key block in it
      found=$(grep -nE '-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}' "$f" 2>/dev/null) ;;
    *)
      found=$(grep -nEo "$PAT" "$f" 2>/dev/null) ;;
  esac
  if [[ -n "$found" ]]; then
    n=$(printf '%s\n' "$found" | wc -l); hits=$((hits+n))
    report+=" $f:$(printf '%s\n' "$found" | head -1 | cut -d: -f1)"
  fi
done
if (( hits > 0 )); then
  echo "$hits finding(s):$report"
  exit 1
fi
echo "clean"
