# Live services deleted mid-audit (external action)

FACT 11:07:43 UTC (sudoers log) — `rm -rf /opt/liza-mock /opt/liza_data /opt/liza_chrome_profile
/home/ubuntu/liza /tmp/liza-backup-20260915.tar.gz`; again 11:26:49 minus the tarball, plus
`rm -rf /opt/chrome_profiles /opt/octopus_rpa_screenshots`.

FACT — consequences now true: `liza-mock.service` and `telegram-hermes.service` are `inactive/dead`;
port 8000 no longer listens; `/opt/liza-mock/telegram_hermes_bridge.py` and `.telegram.env` are gone;
`/home/ubuntu/.hermes/config.yaml` still points at the dead `:8000` endpoint.
FACT — `find / -xdev -name 'liza-backup*'` returns nothing: the backup tarball was deleted in the same
command that created it as the destination. Local copy of `liza` is gone; **`JoTalbot/liza` exists as a
private repo**, so the code is recoverable by clone.
FACT — the balancer still reports `liza-rpa-gemini-web` **healthy**: it probes the Chromium CDP port
(:9222/:9223, still listening), not the deleted profile dir. A health check that passes against deleted
inputs.
FACT — `/home/ubuntu/liza` was profiled as a project agent at 10:0x and its path was gone by 11:36.

DECISION: the `liza` project agent stays in the repo, marked against a deleted path, because the repo
defines desired state and recovery re-creates it.
LESSON 1: the profile generator must run immediately before use; a measured snapshot ages in minutes.
LESSON 2: health probes must test the *dependency*, not the port. Applied in `doctor.sh` step 4 — it
issues a real inference request and fails if the token does not come back.
LESSON 3: deletion is the top failure mode on this box (autonomous agents + shared root + docker `-v`).
Hence: no `rm` in any agent allowlist; cleanup means quarantine + a kanban event.
