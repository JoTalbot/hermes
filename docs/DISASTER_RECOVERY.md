# Disaster Recovery

## The premise this doc rejects

"GitHub is the backup" is true for **configuration** and false for everything else. Cloning this repo
rebuilds agents, skills, policies and scripts. It does **not** rebuild: databases, provider keys,
`/etc/octopus/secrets.env`, the octopus swarm state, `~/.hermes/state.db`, sessions, memories, or the
143 dirty files sitting in project trees right now.

That last category is the one people lose. A tree that is dirty on a server and absent from GitHub has
exactly one copy — the one a `rm -rf` deletes in one line. This box demonstrated it during this audit
(`rm -rf /home/ubuntu/liza` at 11:07 while the local copy was the only one anyone had checked).

## Recovery levels

| level | trigger | procedure | time |
|---|---|---|---|
| **L1** unit failure | shim/serve down | `systemctl restart hermes-shim hermes-serve`, re-run doctor | minutes |
| **L2** bad config change | doctor regressed after a commit | `git -C /opt/hermes revert HEAD` → `install.sh` → doctor | minutes |
| **L3** Hermes state loss | `~/.hermes` gone/corrupt | `restore.sh <hermes-state-*.tar.gz> --force` | < 1 h |
| **L4** whole server gone | new instance | `bootstrap.sh` + `restore.sh` + secret placement | 1–3 h |
| **L5** + project data gone | as L4, plus per-project dumps | L4 then each project's own restore | varies |

## L4 on a naked server

```bash
git clone https://github.com/JoTalbot/hermes && cd hermes && sudo ./scripts/bootstrap.sh
```
`bootstrap.sh` is 11 numbered steps: probe OS/arch → **disk gate** → install (idempotent, refuses if no
room) → check `/etc/hermes/shim.env` exists → probe the balancer → start shim + serve → install agent
profiles → init the kanban bus → register the server (stable `srv-*` id) → report unit state → doctor.
It **deliberately exits without inventing secrets**: if `/etc/hermes/shim.env` is missing it fails with
instructions instead of generating a throwaway key that would then need rotating everywhere.

On a non-`arm-server-01` machine there is no balancer on :9600. Bootstrap detects that and says so
plainly: Hermes will start with no usable provider until `model.base_url` is pointed somewhere real.
It does not pretend the install succeeded.

## What you must restore by hand (never in git, by design)

- `/etc/hermes/shim.env` — regenerate, then update `~/.hermes/.env` to match
- `/etc/octopus/secrets.env` — 11 providers' keys; only you have these
- provider OAuth/`hermes auth` entries
- Telegram bot token **if `telegram-hermes` is meant to come back** — it lived at
  `/opt/liza-mock/.telegram.env` and was deleted with the rest of `/opt/liza-mock`; a new token requires
  BotFather
- database dumps from the backup target (not GitHub)

## Drills

An untested backup is a story, not a backup.

```bash
bash scripts/backup.sh                                   # must print "verified:" per archive
mkdir -p /tmp/drill && tar -xzf state/backups/hermes-state-*.tar.gz -C /tmp/drill   # prove it opens
docker run --rm -v $PWD:/h -w /h ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq git && ./scripts/bootstrap.sh'
```
The `backup.sh` integrity loop `tar -tzf`s every archive and exits 1 on a corrupt one — a failure in
that loop is a **backup failure**, not a warning.

## Deletion hazard (this box specifically)

Autonomous agents with `rm` on a shared root, plus `docker run -v` mounts, plus one sudo-capable user,
means accidental deletion is the most likely disaster here — more likely than disk failure. Two
consequences:
1. **No Hermes agent gets `rm`** in its allowlist (`agent-policy.yaml` denylists it for every role).
2. Any agent task that "cleans up" must move to a quarantine path and record a kanban event, not delete.
   Deletion is a human act on this machine.
