# Disk pressure (resolved by someone else, not by me)

FACT 09:46 UTC — `df /`: 145G, 141G used, **3.8G free (98%)**; `du`: `/var`=88G, `/usr`=19G,
`/opt`=16G, `/root`=6.7G. Gate on installs; `install.sh` now refuses under 6G free.
FACT 09:58 — pre-existing `octopus-slo-checker` fails 1/15 checks: `disk_root_lt_85_percent`. The box
was already alarming on this; Hermes found nothing new, only confirmed it.
OBSERVATION 10:36–11:39 — `sudo rm -rf` of npm/go/hf caches in sudoers log; disk 94%.
FACT 11:36 — `df /`: 49G used, **97G free (34%)**; SLO check now passes.

DECISION: proceed with install work only after re-reading `df` at execution time.
LESSON: a disk number measured at 09:46 is not a fact at 11:36. Every script that depends on capacity
must measure at run time — hence the gate, rather than my prose.
HYPOTHESIS: the reclaim was human cleanup, not a rotation job; unverified, and it does not need to be
for us (we do not own it).
