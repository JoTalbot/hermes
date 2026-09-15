# A backup that verified itself while capturing nothing

FACT — `scripts/backup.sh` resolved the state directory as `"${HERMES_HOME:-$HOME/.hermes}"`.
FACT — run from a root shell (`sudo bash backup.sh`, `HOME=/root`) it therefore archived
`/root/.hermes`: **3 entries**, a few kilobytes. It then printed `verified`, a compact size, and
**exited 0**. The tar itself was intact — the archive was simply of the wrong directory.
FACT — the same class of bug had already occurred in `doctor.sh`, which checked `/root/.hermes`
instead of `/home/hermes/.hermes` and reported healthy while looking at nothing.
FACT — the swallow made it invisible: `tar … || echo "  (state dir partial — continuing)"` turned a
failure into reassuring prose, which is exactly where a backup's trustworthiness comes from.

OBSERVATION — a backup is the one artefact nobody inspects until they need it, and by then the only
copy is the bad one. A wrong-but-valid archive is strictly worse than a missing archive, because a
missing one is noticed by the scheduler and a wrong one is noticed by a restore that comes up empty.
LESSON — a backup must fail LOUD and must state what it backed up. "verified" may only ever mean
"the thing I claim I saved, I saved".
LESSON — for scheduled jobs, never let `$HOME` or any other inherited variable pick the source
directory; a service manager's environment is not a shell's.

FIX (2026-09-15) — `backup.sh` 1.1.0: explicit resolution order (`HERMES_HOME` → `/home/hermes/.hermes`
→ `$HOME/.hermes`); refuses a directory without Hermes-home markers (`kanban/ memories/ profiles/
config.yaml`); refuses fewer than 50 entries; a tar failure is fatal; prints the source path, entry
count and size. Verified both directions — a decoy `HERMES_HOME=/tmp/decoy-home` now exits 2, and the
old broken invocation finds `/home/hermes/.hermes` (597 entries, 516 archived, 62 MB).
FIX — `verify-backup.sh` extracts the newest archive into a scratch dir and compares **content
hashes** and profile counts against the live tree; it runs as `ExecStartPost` of
`hermes-backup.service`, so a backup that cannot be restored turns the unit red.
FIX — `hermes-backup.timer`, daily 03:30 UTC, `Persistent=true`.
NOTE — `verify-backup.sh` itself failed its first run ("missing in archive") because it assumed the
extracted tree kept its top level; tar strips the leading `/`, so `/home/hermes/.hermes` unpacks as
`<tmp>/home/hermes/.hermes`. The check was wrong, not the backup. A verification nobody has ever seen
fail has not been tested — this one has.
