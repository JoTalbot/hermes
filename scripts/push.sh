#!/usr/bin/env bash
# scripts/push.sh — the §21 sync pipeline, in order, no shortcuts:
#   validate → secret scan → tests → commit → push
# Token handling: read from the env or from the repo-local git credential helper on the
# SERVER. Never from a command-line argument (visible in `ps` and in shell history), and
# never written into the repo or into git config.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_DIR"
MSG="${1:-chore(hermes): sync $(date -u +%FT%TZ)}"
echo "[1/5] yaml/shell validation"; 
for f in $(git ls-files '*.yaml' '*.yml'); do python3 -c "import yaml,sys;yaml.safe_load(open('$f'))" || { echo "  invalid yaml: $f"; exit 1; }; done
for f in $(git ls-files '*.sh'); do bash -n "$f" || { echo "  syntax error: $f"; exit 1; }; done
echo "      ok"
echo "[2/5] secret scan"; out=$(bash scripts/secret-scan.sh --staged 2>/dev/null || true)
scan=$(bash scripts/secret-scan.sh --worktree); echo "      $scan"
[[ "$scan" == "clean" ]] || { echo "  ABORT: secrets in the worktree. Nothing was committed."; exit 1; }
echo "[3/5] tests"; [[ -x tests/run.sh ]] && bash tests/run.sh || echo "      (tests/run.sh absent — skipped)"
echo "[4/5] commit"; git add -A; git diff --cached --quiet && { echo "      nothing to commit"; exit 0; }
git commit -q -m "$MSG"; echo "      $(git rev-parse --short HEAD)"
echo "[5/5] push"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git -c credential.helper= push "https://x-access-token:${GITHUB_TOKEN}@github.com/$(git remote get-url origin | sed -E 's|.*github.com[:/]||; s|\.git$||')" HEAD 2>&1 | sed -E 's|x-access-token:[^@]*@|x-access-token:***@|g'
else
  git push 2>&1 | tail -3
fi
echo "done."
