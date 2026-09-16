#!/usr/bin/env bash
# GitHub source-of-truth report: every git repo on this box, then the GitHub view.
set -uo pipefail
REPOS="${REPOS:-/opt/hermes /opt/aios /opt/logistics /opt/madworld /opt/octopus-browser /opt/orchestrator /opt/words}"
echo "LOCAL REPOS"
for r in $REPOS; do
  [ -d "$r/.git" ] || continue
  cd "$r" || continue
  br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  head=$(git rev-parse --short HEAD 2>/dev/null)
  dirty=$(git status --porcelain 2>/dev/null | wc -l)
  ab=$(git rev-list --left-right --count "@{u}...HEAD" 2>/dev/null | awk '{print "behind="$1" ahead="$2}')
  last=$(git log -1 --format=%cd --date=short 2>/dev/null)
  printf "  %-24s %-10s %-9s dirty=%-4s %s last=%s\n" "$(basename "$r")" "$br" "$head" "$dirty" "${ab:-no-upstream}" "$last"
done
echo
echo "GITHUB (JoTalbot/hermes)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh repo view JoTalbot/hermes --json name,pushedAt,defaultBranchRef,isPrivate 2>/dev/null | sed 's/^/  /'
  gh run list -R JoTalbot/hermes -L 3 2>/dev/null | sed 's/^/  /'
else
  echo "  gh unavailable/unauthenticated — falling back to git ls-remote"
  git ls-remote --heads https://github.com/JoTalbot/hermes 2>/dev/null | head -3 | sed 's/^/  /'
fi
echo
echo "SECRET SCAN (working tree)"
if [ -x /opt/hermes/tests/secret-scan.sh ]; then
  bash /opt/hermes/tests/secret-scan.sh --worktree 2>&1 | tail -5 | sed 's/^/  /'
else
  echo "  (secret-scan.sh not found at /opt/hermes/tests/secret-scan.sh)"
fi
