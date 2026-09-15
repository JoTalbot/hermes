# What this audit got wrong, and the rule each error produced

Recorded because a lesson nobody can audit is a mood. Every entry: the wrong claim, the probe that
disproved it, the rule.

1. "`/root` was wiped (4.0K)." → `sudo du` says **3.3G**. I ran `du -xsh /root` unprivileged.
   **Rule:** a size from a directory you cannot read is a permission error wearing a number.
2. "`JoTalbot/liza` was deleted (404)." → authenticated `200`, `visibility: private`.
   **Rule:** to an unauthenticated caller, private and deleted are the same response. Never report a
   deletion from a 404; the earlier public-API list also hid that `octopus` is private — which is why
   `gen-project-agents.sh` refuses to depend on GitHub metadata.
3. "`/opt/octopus` is clean, 0 dirty files." → as root: **8** uncommitted paths. Unprivileged
   `git status` fails, and a failure and an empty tree both look like success to a naive parser.
   **Rule:** tools must distinguish "nothing" from "could not look" → the `git_ok` column and the
   generator's refusal.
4. "Disk is 98% full." True at 09:46, **34% at 11:36** — someone cleaned it, not me.
   **Rule:** volatile facts get re-read at execution time. Hence the gate in `install.sh`.
5. "`octopus-devpanel` errors stopped." → likely correlated with #4 (my journal filter caught
   `Failed to start` lines that no longer matched). **Rule:** state a mechanism, not an absence.
6. Three valid project profiles (aios, madworld, octopus) silently dropped by a slug case bug.
   **Rule:** when a generation step changes a count, diff the sets and print both sides — `kept`/`removed`.
7. My own discovery script deadlocked for 300s emitting **zero rows**: `while read` fed by a pipe hands
   its stdin to `git status`, which blocks. Exit 0 with an empty result is the worst failure shape.
   **Rule:** bound every probe (`timeout`), close inherited stdin (`</dev/null`), and treat "empty output
   with exit 0" as suspicious until proven otherwise.
