#!/usr/bin/env bash
# Generic per-project check. Everything comes from the project's own agent YAML via env:
#   PROJECT_PATH PROJECT_REPO PROJECT_SERVICE PROJECT_CONTAINERS PROJECT_HEALTH_URL
# Report facts only; never modify the project.
set -uo pipefail
P="${PROJECT_PATH:-}"
echo "PROJECT ${PROJECT_SLUG:-?}  path=$P  node=$(hostname)"
if [ -n "$P" ] && [ -d "$P" ]; then
  if [ -d "$P/.git" ]; then
    cd "$P" || true
    printf "  git: branch=%s head=%s dirty=%s last=%s\n" \
      "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" "$(git rev-parse --short HEAD 2>/dev/null)" \
      "$(git status --porcelain 2>/dev/null | wc -l)" "$(git log -1 --format=%cd --date=short 2>/dev/null)"
    printf "  remote: %s\n" "$(git remote get-url origin 2>/dev/null)"
  else
    echo "  no .git in $P"
  fi
  echo "  size: $(du -sh "$P" 2>/dev/null | cut -f1)  files: $(find "$P" -type f 2>/dev/null | wc -l)"
  for f in README.md package.json requirements.txt pyproject.toml docker-compose.yml Makefile; do
    [ -e "$P/$f" ] && echo "  marker: $f"
  done
else
  echo "  path missing or unset (${P:-unset})"
fi
echo
echo "SERVICE"
if [ -n "${PROJECT_SERVICE:-}" ]; then
  for u in ${PROJECT_SERVICE}; do printf "  %-30s %s\n" "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
else
  echo "  (no service declared)"
fi
echo
echo "CONTAINERS"
if [ -n "${PROJECT_CONTAINERS:-}" ]; then
  for c in ${PROJECT_CONTAINERS}; do
    st=$(docker ps -a --filter "name=^/${c}$" --format '{{.Status}}' 2>/dev/null | head -1)
    printf "  %-30s %s\n" "$c" "${st:-not found}"
  done
else
  echo "  (none declared)"
fi
echo
echo "HEALTH"
if [ -n "${PROJECT_HEALTH_URL:-}" ]; then
  for u in ${PROJECT_HEALTH_URL}; do
    printf "  %-40s HTTP %s\n" "$u" "$(curl -s -m 6 -o /dev/null -w '%{http_code}' "$u")"
  done
else
  echo "  (no health url declared)"
fi
echo
echo "PORTS BOUND BY THIS PROJECT (best effort)"
if [ -n "$P" ]; then
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -i "$(basename "$P")" | sed 's/^/  /' || echo "  (no matching container)"
fi
