#!/usr/bin/env bash
# scripts/discover-repos.sh — run ON a server, emit TSV of every git repo.
#   ssh root@host 'bash -s' < scripts/discover-repos.sh > /tmp/repos.tsv
#   (or as a sudo-capable user; see the privilege note below)
#
# Slug is the origin repo name when present, else the directory name — that is what
# keeps a private repo (invisible to the public API) from silently losing its agent.
#
# RUN AS ROOT. Measured on srv-oci-arm-01: unprivileged `find` returned 18 repos,
# `sudo find` returned 20 (/root/logistics, /root/agents/-Octopus/repo are invisible).
# Worse, unprivileged `git -C /opt/octopus status` FAILS — and a failed status looks
# identical to a clean tree. So every row carries git_ok: 1 = trustworthy counts,
# 0 = unreadable. gen-project-agents.sh refuses to proceed on any git_ok=0 row.
set -uo pipefail
if [[ "$(id -u)" != 0 ]]; then
  echo "WARN: not root — inventory will under-report and root-owned trees will be unreadable" >&2
fi
tmpseen=$(mktemp); trap 'rm -f "$tmpseen"' EXIT
printf 'slug\tpath\tbranch\torigin\tdirty\tlang\tgit_ok\n'
# Process substitution, NOT a pipe: `while read` over a pipe hands the loop's stdin
# to every command inside it, and `git status` will then block waiting on that pipe.
# That deadlock cost ~300s of silence and produced zero rows.
while read -r p; do
  origin=$(timeout 10 git -C "$p" config --get remote.origin.url </dev/null 2>/dev/null | sed -E 's|.*/||; s|\.git$||')
  slug="${origin:-$(basename "$p")}"
  # Unique slug. Two checkouts of one remote (there are THREE /…/logistics trees here)
  # must not collide, or the last one silently overwrites the first profiles.
  # Suffix on the *path*, not the basename: basename(origin)==basename(path) is exactly
  # the case that produced three identical "logistics-logistics" slugs.
  base="$slug"; n=1
  while grep -qx "slug=${slug}" "$tmpseen" 2>/dev/null; do
    slug="${base}-$(printf '%s' "${p#/}" | tr '/' '-' | sed 's/^-//')"
    n=$((n+1))
    [[ $n -gt 40 ]] && break
  done
  echo "slug=${slug}" >> "$tmpseen"
  if raw=$(timeout 25 git -C "$p" status --porcelain </dev/null 2>/dev/null); then
    git_ok=1
    [[ -n "$raw" ]] && dirty=$(printf '%s\n' "$raw" | wc -l | tr -d ' ') || dirty=0
    branch=$(timeout 10 git -C "$p" rev-parse --abbrev-ref HEAD </dev/null 2>/dev/null)
  else
    git_ok=0; dirty=-1; branch="UNREADABLE"
  fi
  lang="?"
  if   [ -f "$p/go.mod" ]; then lang="go"
  elif [ -f "$p/Cargo.toml" ]; then lang="rust"
  elif [ -f "$p/package.json" ]; then lang="node"
  elif [ -f "$p/pyproject.toml" ] || [ -f "$p/requirements.txt" ] || [ -f "$p/setup.py" ]; then lang="python"
  elif [ -d "$p/app/src/main" ]; then lang="android"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$p" "${branch:-detached}" "$origin" "$dirty" "$lang" "$git_ok"
done < <(find / -xdev -type d -name .git 2>/dev/null | sed 's|/\.git$||' | sort)
