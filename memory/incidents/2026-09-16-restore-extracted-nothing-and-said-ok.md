# 2026-09-16 — restore.sh extracted nothing and reported success

## FACT
The recovery drill (restore the nightly archive into a clean container, `HERMES_HOME=/tmp/restored/.hermes`)
produced zero profiles, zero boards, zero memories — while printing `extracted`.

## Why
The archive stores paths with tar's stripped leading slash: `home/hermes/.hermes/...`.
`restore.sh` extracted into `dirname($HERMES_HOME)`, which only lines up when the target path
is exactly the path the backup came from. `verify-backup.sh` had already learned this (it
locates the state dir by basename) — restore.sh had not, and nothing tested it end to end.

## Fix
restore.sh now extracts to a scratch dir, finds the state directory by its CONTENT
(profiles/kanban/skills/memories/config.yaml), moves it into place, and then reports what
came back: `restore: PLAUSIBLE` or `restore: INCOMPLETE` (exit 1). `--no-systemd` mode added
so a container/rescue host can restore too.

## Verified
183 files, 27 profiles, board `hermes-os`, `config.yaml` mode 0600 — in a container that had
nothing. Skills are 0 by design: runtime skills live in the repo (`/opt/hermes/skills`),
which the restore path pulls from GitHub.

## LESSON
An untested restore is a story, not a backup. "It printed no error" is not evidence; a
rehearsal that counts what came back is.
