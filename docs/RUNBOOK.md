# Runbook

All commands run on `arm-server-01` unless stated. Nothing here is secret; secrets are referenced by
path only.

## Daily state

```bash
bash /opt/hermes/scripts/doctor.sh            # one-line verdict, exit 1 if critical
journalctl -u hermes-shim -u hermes-serve --since -1h --no-pager | tail -40
```

## Start / stop / restart

```bash
sudo systemctl restart hermes-shim      # the balancer translator (must be up before agents)
sudo systemctl restart hermes-serve     # WebUI + JSON-RPC on 0.0.0.0:9119, password-gated
sudo -u hermes HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes gateway   # messaging
```

## Android control

Two independent routes exist. **Route 1 is what we use now**; Route 2 is the fallback and is the only
one that works when the public port is closed again.

```
Route 1 (DEFAULT)  direct   http://129.213.177.56:9119        password login, no apps on the phone
Route 2 (FALLBACK) tunnel   ssh -L 9119:127.0.0.1:9119 ubuntu@100.109.170.74   → http://127.0.0.1:9119
```

### Route 1 — direct browser access (IMPLEMENTED 2026-09-15, owner decision)

Open `http://129.213.177.56:9119/` in the phone browser, log in with the dashboard password. Nothing
to install, works on mobile data, no tunnel.

Verified end to end from **outside** the server's own network (not from loopback):

| check | result |
|---|---|
| TCP reachability from 6 independent external nodes | 6/6 **open** |
| `GET /` unauthenticated | `302 → /login?next=%2F` |
| `GET /login` | `200`, title `Sign in — Hermes Agent`, `data-provider="basic"` |
| `POST /auth/password-login` with the real password | `200 {"ok":true,"next":"/"}` |
| `GET /api/sessions` with the session cookie | `200` |
| wrong password | `401` (generic message, logged) |
| `GET /api/status` unauthenticated | `200` — public liveness probe, no secrets, by design |

Credentials and configuration:

```
/etc/hermes/dashboard.env        0600 root — HERMES_DASHBOARD_BASIC_AUTH_{USERNAME,PASSWORD_HASH,SECRET}
/etc/hermes/dashboard.password   0600 root — the plaintext copy, for the human to read
user: jotalbot                   session TTL 43200s (12h); SECRET is set, so restarts keep sessions
```

The service reads that file via `EnvironmentFile=-/etc/hermes/dashboard.env`; the bind is
`--host 0.0.0.0` in `hermes-serve.service`. **Both must stay in place** — the dashboard fails closed
(`SystemExit: Refusing to bind dashboard to …`) if a non-loopback bind has no auth provider.

> **Transport is plain HTTP.** The password crosses the network unencrypted and can be captured by
> anyone on the path. This was an explicit owner decision (2026-09-15) in exchange for not needing
> Tailscale on the phone. Treat the password as a low-value credential, rotate it if it ever leaks,
> and prefer Route 2 when on an untrusted network.

**There are two firewalls and the cloud one is authoritative.** ufw alone is not enough:

```bash
sudo ufw allow 9119/tcp                       # host firewall
sudo bash scripts/oci-open-port.sh 9119       # OCI security list — without this the port stays dead
bash scripts/oci-firewall.sh inspect          # show what the cloud currently permits
```

Measured 2026-09-15: the security list permitted only 22, 80, 443, 8080, 5434 and ICMP, so 9119 was
unreachable even with a correct ufw rule and an unfiltered bind. `oci-open-port.sh` backs up the
current rules to `/root/oci-security-list-ingress-*.json` first, clones the SSH rule for its schema,
and re-verifies that every original rule survived — the OCI API replaces the whole rule set, so a
bad payload there can lock you out of the box.

Rotating the password (do **not** run this casually — it invalidates the current one):

```bash
bash scripts/enable-dashboard-auth.sh && sudo systemctl restart hermes-serve
sudo cat /etc/hermes/dashboard.password
```

### Route 2 — SSH tunnel over the tailnet (fallback)

```bash
ssh -L 9119:127.0.0.1:9119 ubuntu@100.109.170.74     # keep open, or autossh -M 0
# on the phone:  http://127.0.0.1:9119
```

Connect to the **tailnet IP**, not the public one, so the SSH session itself is inside WireGuard.
The Host header stays `127.0.0.1`, which is the only thing a loopback bind accepts.

### Why `tailscale serve` is not the answer (verified, do not retry)

1. `tailscale serve` preserves the incoming Host header, so the dashboard sees
   `arm-server-01.tail5261f7.ts.net` and refuses: `400` via MagicDNS, `404` via the raw IP.
2. `tailscale serve --https=443` hangs (>300 s) and 80/443 are held by the production nginx
   (`api.autosklo.org.ua`), which must not be disturbed.
3. The tailnet account cannot get TLS certificates:
   `tailscale cert … → 500 your Tailscale account does not support getting TLS certs`,
   so no trusted `https://…ts.net` URL can exist.

### Android device status

```
G1 (android)              100.93.232.113   offline, last seen 2026-09-12
aios-android-gateway      100.122.9.31     offline, last seen 42 days ago
```

Route 1 works whether or not the phone is in the tailnet, which is exactly why it was chosen.

## Tasks and delegation

```bash
H=/home/hermes/.hermes-venv/bin/hermes
sudo -u hermes HERMES_HOME=/home/hermes/.hermes $H kanban boards list
sudo -u hermes ... $H kanban create "audit exposed listeners" --board hermes-os --assignee security
sudo -u hermes ... $H kanban dispatch --board hermes-os          # run claimed tasks
sudo -u hermes ... $H kanban tail --board hermes-os              # live watch
```

## Add a project agent

```bash
ssh root@129.213.177.56 'bash -s' < scripts/discover-repos.sh > /tmp/repos.tsv
bash scripts/gen-project-agents.sh /tmp/repos.tsv          # refuses on unreadable git state
bash scripts/install-agents.sh
```
A project with no server checkout gets **no agent**. Clone it first, then re-run discovery.

## Recovering a provider-less Hermes

Symptom: agents answer nothing / shim returns `502 upstream_unreachable`.
1. `curl -s http://127.0.0.1:9600/health` — if that fails, the balancer is down; fix that first, the shim is innocent.
2. `curl -s http://127.0.0.1:9700/health` — if that fails, `sudo systemctl status hermes-shim`.
3. `401` from the shim = key mismatch between `/etc/hermes/shim.env` and `~/.hermes/.env`. Re-copy; do not paste the value into a shell.
4. `200` with empty content = balancer answered with a shape we don't flatten. `deploy/shim/aios_openai_shim.py:flatten_upstream` lists the accepted keys.

## Skills: where they live, and how they load

```bash
# what Hermes currently sees
sudo -u hermes env HERMES_HOME=/home/hermes/.hermes HOME=/home/hermes \
  /home/hermes/.hermes-venv/bin/hermes skills list

# re-register after a rebuild (idempotent; install.sh and bootstrap.sh call it too)
sudo bash /opt/hermes/scripts/register-skills.sh
```

Skills are authored in this repo as `skills/<category>/<name>/SKILL.md` (frontmatter `name` +
`description`, then Why / Use / Do not / Lesson) and loaded from there — the repo stays the single
source of truth, nothing is copied into `HERMES_HOME`.

**The skill loader reads `$HERMES_HOME/config.yaml` ONLY.** `agent/skill_utils.py` resolves
`skills.external_dirs` through `get_config_path()` and parses that file directly; it never consults
the managed scope in `/etc/hermes`. Verified 2026-09-16: with the entry only in
`/etc/hermes/config.yaml`, `hermes skills list` reported **0**; adding it to the user config made all
nine appear at once. That is why registration is a script and why `install.sh`/`bootstrap.sh` call it.

Cost matters: every enabled skill's name + description goes into **every** prompt. Measured with
`hermes prompt-size` — 0 skills: 11,845 B system prompt, skills index 0 B; 9 skills: 14,279 B, index
870 B. Before adding a large set, measure. The Octopus catalogue (243 skills) stays a pointer
(`octopus-skill-catalog`), not an import.

Authoring rules: one skill = one repeatable operation; `description` says **when** to use it, not what
it is; always include a "Do not" section, because the expensive mistakes are the ones a future agent
repeats. New skills are committed like code.

## Talking to other agents (shared rooms)

Hermes has no chat server; the kanban bus is the chat. A **room** is an unassigned task on board
`agents-chat` whose comments are messages:

```bash
sudo bash /opt/hermes/scripts/agents-chat.sh rooms
sudo bash /opt/hermes/scripts/agents-chat.sh say general "текст"          # --as <profile> to sign
sudo bash /opt/hermes/scripts/agents-chat.sh read general 20
sudo bash /opt/hermes/scripts/agents-chat.sh tail general
```

**Safety invariant** (verified, do not break): the dispatcher only claims tasks with
`status='ready' AND assignee IS NOT NULL`, and no `kanban.default_assignee` is configured, so an
**unassigned** room is never executed. Assigning a room to a profile would launch that profile to
"work" the conversation and burn quota. A worker reads the room through its own `kanban_show` call,
so messages reach agents without any push channel.

Read them from the phone: the dashboard has a bundled **Kanban** tab at `/kanban` (same session as the
login) — board `agents-chat`, room cards, comment threads, live updates over `/events`. Verified
2026-09-16: `/api/plugins/kanban/boards` lists `agents-chat` and `/api/plugins/kanban/tasks/<id>?board=agents-chat`
returns the room, so no extra tooling is needed for the human side.

For a human-visible group chat outside the dashboard, enable a messaging platform (`hermes gateway setup`), then either
`hermes send -t telegram:<chat> "…"` or per-task pushes with
`hermes kanban --board agents-chat notify-subscribe <id> --platform telegram --chat-id <chat>`.
`channel_directory.json` currently reports no configured platforms, so this needs a bot token first.

## Backups and recovery

Scheduled since 2026-09-15: `hermes-backup.timer` runs `hermes-backup.service` daily at **03:30 UTC**
(+ up to 15 min jitter, `Persistent=true`) — a nightly state archive **and** a restore verification.

```bash
systemctl list-timers hermes-backup.timer           # when it fires next
systemctl start hermes-backup.service              # run it now
journalctl -u hermes-backup.service --since -1d -o cat | tail -30
sudo ls -lh /var/backups/hermes/                   # archives live here (0700 root), keep=7
sudo bash /opt/hermes/scripts/verify-backup.sh     # re-prove the newest archive
```

Two things are deliberately not in the archive: **secrets** (`.env`, `*.pem`, `authorized_keys`) and
project databases. After a restore you must place `/etc/hermes/shim.env` yourself; the runbook has no
copy of it on purpose, and `/var/backups/hermes/shim.env.canonical` is the self-heal source.

> **A backup that silently captures the wrong directory is worse than no backup**, because it is
> trusted. That is not hypothetical here: `backup.sh` used to fall back to `$HOME/.hermes`, so a root
> shell archived `/root/.hermes` (3 entries), printed `verified`, and exited 0. It now resolves the
> state dir explicitly, refuses a directory without Hermes-home markers, treats a tar failure as fatal,
> and prints the source path and entry counts. `verify-backup.sh` goes further: it extracts the archive
> into a scratch dir and compares content hashes and profile counts against the live tree.

Restore onto a fresh box (see also `scripts/bootstrap.sh`):

```bash
git clone https://github.com/JoTalbot/hermes /opt/hermes && cd /opt/hermes
sudo env HERMES_HOME=/home/hermes/.hermes bash scripts/restore.sh /var/backups/hermes/hermes-state-<stamp>.tar.gz --force
sudo bash scripts/doctor.sh
```

Manual one-off backup (interactive; the timer is the normal path):

```bash
sudo env HERMES_HOME=/home/hermes/.hermes HERMES_BACKUP_DIR=/opt/hermes/state/backups bash scripts/backup.sh
```

## The disk rule

`df -h /` before **any** install, `docker pull`, or `pip install`. This box spent this audit at 98%→33%
as someone cleaned it; a venv or image that dies mid-write at ENOSPC is far worse than one never started.
`scripts/install.sh` refuses below 6 GB and says so.

## Known-broken things (so nobody re-discovers them)

| thing | symptom | why |
|---|---|---|
| `octopus-slo-checker` | `fail: disk_root_lt_85_percent` every ~30s | real alert about the old 98% disk; currently green |
| cron restart of `octopus-devpanel.service` | "Unit not found" every 2 min | timer for a removed unit |
| `logistics-recurring-demand-scheduler-1` | `Exited (1) 23 hours ago` | pre-existing; not Hermes' |
| `/root/agents/-Octopus/repo` | `fatal: not a git repository` | `.git/HEAD` missing, objects intact |

## Agent Bus + agents (2026-09-16)

```bash
# state
hermes-bus channels | nodes | digest -n 5          # rooms, federation members, one-screen chat
hermes-bus-bridge status                           # stream size + per-node consumer backlog
systemctl status nats-server hermes-bus-bridge hermes-agents
journalctl -u hermes-agents -n 50 -o cat           # what agents did

# talk
hermes-bus post --channel incidents --kind error --priority urgent "текст"
hermes-bus request --to server-guardian --timeout 60 status
hermes-bus dm --to github-agent --kind task "проверь репозиторий"

# a new capability for an agent (never hand-edit the YAML block)
sudo bash scripts/wire-agents.sh && sudo systemctl restart hermes-agents

# tests that actually exercise the bus
sudo bash tests/bus-selftest.sh                    # 10 checks, single node
sudo NODE2=hermes-node-02 bash tests/federation-selftest.sh   # 10 checks, two nodes

# if the bus looks dead
curl -s http://127.0.0.1:8222/healthz               # nats itself
systemctl restart nats-server hermes-bus-bridge hermes-agents
hermes-bus-bridge discover                          # (Telegram) find a chat to talk to

# join a new node (container/VM): only the repo URL and NATS_TOKEN travel
git clone https://github.com/JoTalbot/hermes && cd hermes && sudo ./scripts/bootstrap.sh --no-systemd
```

**Telegram (Global Chat on the phone) — both directions.** A BOT cannot create a group and
cannot start a DM: a human sends `/start` to @OctopusSwwarmBot (or adds it to a group), then

```bash
hermes-bus-bridge discover      # persists the chat (chat_id) — this is also the allow-list
hermes-bus-bridge status        # telegram: chat_id=... confirms it
systemctl status hermes-telegram-inbox    # the inbound half (commands -> bus)
```

*Out (bus → phone):* the bridge forwards **meaningful** messages — kinds
event/decision/task/result/error/status, priority ≠ low, max 20/min, authored by this node
(so an N-node federation sends one copy, not N), **channel messages only** (agent-to-agent
DMs are internal wiring; errors are forwarded whatever their routing), and nothing tagged
`selftest` (the test suite publishes to real channels and must not ping the owner).
Agent output is sent as monospace; forum groups can map channels to topics via
`/etc/hermes/telegram.chats.json` (`topics: {"security": 4}`).

*In (phone → agents):* `hermes-telegram-inbox.service` runs `bus_bridge.py poll` (long poll,
persistent offset in `/var/lib/hermes-bus/tg-offset.json`). The chat has a keyboard —
**📊 Статус · 🗞 Сводка · 🖧 Узлы · ❓ Помощь** — and these commands:

| what you type | what happens |
|---|---|
| any text, e.g. *проверить загрузку сервера* | **task** for the agents: routed to a specialist, result comes back in the chat |
| *какие агенты есть и их функции* | answered immediately from the registry (`agents/roster.py`) — it is a question, not a task |
| *какие проекты* | the projects, their paths and which checkouts are missing |
| `/agents [имя]` | the whole team in one screen, or everything about one agent |
| `/projects` | projects under watch |
| `/task <текст>` | a task, explicitly |
| `/status` | units, bus stream/consumers, agents, nodes, projects |
| `/digest [N]` | one-screen summary of the last N messages per channel |
| `/servers` | who is on the bus |
| `/note <текст>` | a plain event on `#general` (no execution) |
| `/help` | the command list |

The keyboard under the message box is the fastest way in — tapping a button is exactly the
same as typing its label:

| button | effect |
|---|---|
| 🤖 Агенты | who is on the team and what each one does |
| 📦 Проекты | projects, paths, missing checkouts |
| 💻 Сервер | sends the task *проверить загрузку сервера* |
| 💾 Бэкап | sends the task *проверить бэкапы* |
| 📊 Статус | node state |
| ❓ Помощь | the command list |

*What reaches the phone:* channel traffic only (agent-to-agent DMs are internal wiring;
errors are always forwarded), one copy per message across the federation, ≤20/min, nothing
tagged `selftest`, and the owner's own task is acknowledged once instead of echoed back.
Agent output is shown in monospace with a `📎 Полный вывод:` link to the raw log.

**How a task finds its agent** (`runtime.route_by_text`, deterministic — no model, no
tokens): 1) a project named in the task (exact name first, longest match; then the *shortest*
project whose stem matches, plus Russian aliases «логистика/октопус/слова/перевод/…»),
2) intent keywords, specific before generic (`бэкап` beats `сервер`), 3) the agent's own
name. A task that matches nothing is **refused with a suggestion list** rather than handed to
a random agent. The orchestrator must be addressed (`@orchestrator`) — a bare broadcast in a
channel is read by nobody, which is the incident of 2026-09-17.

Safety properties, enforced in code: only chats persisted by `discover` may command the node
(anything else is logged and ignored), the command set is a fixed dispatch table, and owner
text is never interpolated into a shell — free text is only ever *published*.`doctor` gate 18 fails if a chat is configured but nothing polls it.

## What the agents can actually do (2026-09-17)

The question "Что грузит сервер?" used to return the generic host report. Now a sentence is
routed to the handler that answers it (`agents/routing.py`, deterministic, no model):

| you write | capability | handler | answer |
|---|---|---|---|
| что грузит сервер / тормозит | host-health | `top` | топ-процессы за секунду, load, swap, кто из кого состоит |
| сколько места на диске | host-health | `disk` | тома, inodes, крупные каталоги, docker |
| память / swap | host-health | `memory` | RAM/swap, топ по памяти, группы |
| контейнеры | host-health | `docker` | запущено/остановлено/unhealthy, место |
| логи / ошибки | host-health | `logs` | падавшие юниты, топ источников, последние 5 |
| сервисы / юниты | host-health | `services` | упавшие, самые перезапускаемые, таймеры |
| кто слушает порты | security | `ports` | что наружу, что локально, ufw |
| секреты / права | security | `secrets` | права 0600, поиск открытых, скан git |
| обновления | security | `updates` | пакеты, индекс apt, нужна ли перезагрузка |
| алерты | monitoring | `alerts` | что горит, правила, цели |
| цели prometheus | monitoring | `targets` | up/down по заданиям с ошибками |
| бэкап / целостность | backup | `status`, `list`, `verify` | свежесть, состав, gzip-проверка |
| github / репозитории | github | `status`, `repos`, `secret-scan` | ветки, изменения, сканер |
| что в работе | orchestration | `pending` | шина, узлы, зависшие задачи |
| **почему / проанализируй / рекомендации** | тот же домен | **`ask`** | агент собирает факты своим обработчиком и просит модель объяснить их |

Every report uses one format (`agents/checks/lib/report.sh`): a header with a date, sections
with emoji, ✅/⚠️/🔴 verdicts, and a final **💡 ЧТО ДЕЛАТЬ**. A report without advice is a
bug — `tests/agents-selftest.sh` fails on it.

## Models: cheap by default, smart where it matters

Agents never hold provider keys: they name a **tier**, the LLM Balancer picks the provider
(`config/models.yaml`, policy in `agents/models.py`).

| tier | providers behind it | used for |
|---|---|---|
| `hermes-fast` | groq-gpt-oss-20b, groq-qwen3.8-27b, cerebras-llama3.3-70b | routine work: statuses, triage, diagnosis |
| `hermes-reason` | groq-gpt-oss-120b | analysis, planning, risk (orchestrator, security, «почему…») |
| `hermes-code` | mistral-small, hf-Qwen2.5-72B | diffs, review, refactors (github) |
| `hermes-long` | gemini-2.5-flash | summaries over journals and many files |
| `hermes-local` | ollama qwen2.5:1.5b / llama3.2:3b (on this box) | degradation when the balancer is down |

Escalation is a decision, not a default: every use is logged with the model alias and the
reason (`journalctl -u hermes-agents | grep ask:`), so cost drift is visible. When the
balancer is unreachable the agent answers with the measured facts and says plainly that the
model was unavailable — a question never fails because a model did.

## Named subjects and guarded actions (2026-09-17, second pass)

### A question about a *specific thing*

`«Сервер что с процессом chromium»` used to return the generic host report: the sentence
contains «сервер», nothing else matched, and every agent answered with its `status` handler.
Now the subject is extracted (`routing.subject`) and the agent investigates **that** object:

| you write | facts | answer |
|---|---|---|
| что с процессом chromium | `proc` — экземпляры, CPU/RSS, потоки, дети, порты, контейнер, журнал | отчёт + (если вопрос «почему») объяснение моделью |
| почему контейнер octopus упал | `docker` с фильтром по имени — статистика и логи контейнера | разбор причины моделью |
| что с сервисом nats-server | `services` с фильтром — состояние юнита и его журнал | — |

And **an unmatched question is no longer a generic report**: if nothing matches but the text
is a question (`почему/стоит ли/сколько/…?`), the agent gathers host facts and lets its model
answer — `handler=ask`. The generic status dump is now a fallback, not the default.

### Actions: what "give the agent access" means here

The owner asked whether the agent should get full access to the system. It should get real
**capability**, not a shell — a chat message must never become an arbitrary root command,
because the bot token and the phone are weaker secrets than an SSH key, and one leak would
hand over the whole box (including other teams' projects running on it).

So `agents/checks/act.sh` implements a fixed verb list over named objects:

| you write | what runs | guards |
|---|---|---|
| перезапусти контейнер `<имя>` | `docker restart <имя>` | имя обязано существовать; имя проверяется `^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$` |
| запусти контейнер `<имя>` | `docker start <имя>` | то же |
| перезапусти сервис `<имя>` | `systemctl restart <имя>.service` | префиксы `hermes-*`, `octopus*`, `nats-server`, `logistics*`, `madworld*`, `transcribe*`, `aios*` |
| почисти docker | `docker image prune -f` | только dangling-образы, работающие контейнеры не затрагиваются |
| сжать журнал | `journalctl --vacuum-size=500M` | остаются последние 500 MiB |

Impossible by construction: stop/kill of anything, restart of core units (ssh, networking),
package management, `docker run`, arbitrary paths or shell arguments. Every action prints
what it did and is logged by the runtime with the actor
(`journalctl -u hermes-agents | grep act:` — an audit trail), and each refusal explains the
allowed set. A too-broad sentence («перезапусти сервер») is refused rather than guessed.

`tests/agents-selftest.sh` asserts the refusals, not just the successes: disallowed unit,
missing container, a name carrying `; rm -rf /`, an unknown verb, and the absence of `eval`
or `bash -c` in the script.

## Staying alive when the box runs out of memory (2026-09-17)

FACT: on 2026-09-17 `octopus-browser-chromium` (another project) held **16.6 of 23.4 GiB**,
swap was **99 % full** and only ~3.4 GiB was available. The Hermes units had
`OOMScoreAdjust=0` and `MemoryMax=infinity` — i.e. the kernel was exactly as willing to kill
`nats-server` as a browser tab. Losing the bus loses the chat, the agents and the mirror at once.

```bash
# what is in force right now (sizes, priorities, and whether they are applied yet)
bash /opt/hermes/scripts/install-protection.sh --check     # PROTECTION: OK

# apply / re-apply after adding a unit (idempotent; OOMScoreAdjust needs the next start)
bash /opt/hermes/scripts/install-protection.sh

# undo everything (drop-ins removed, values return at the next restart of each unit)
bash /opt/hermes/scripts/install-protection.sh --revert
```

| unit | OOMScoreAdjust | MemoryHigh | MemoryMax | measured usage |
|---|---|---|---|---|
| nats-server | -800 | 384M | 768M | ~30 MiB |
| hermes-bus-bridge | -800 | 384M | 768M | ~90 MiB |
| hermes-telegram-inbox | -800 | 256M | 512M | ~60 MiB |
| hermes-agents | -800 | 1024M | 2048M | ~250 MiB (runs project tests inside) |
| hermes-gateway | -700 | 768M | 1536M | ~300 MiB |
| hermes-metrics | -700 | 256M | 512M | ~40 MiB |
| hermes-shim | -700 | 256M | 512M | ~40 MiB |
| hermes-serve | -600 | 1024M | 2048M | dashboard, user-facing |

Sizing rule: 4× measured usage. High enough never to interfere, low enough that one runaway
handler cannot take the box. Observed result after the change: `oom_score` 666 → 134 for the
bus, agents and inbox; 202 for the gateway. `hermes_proc_oom_score{unit=…}` is exported so
`HermesUnprotectedFromOOM` fires if this ever regresses.

Other projects' containers are **not** touched: the alert names the offender and the exact
command (`docker update --memory 8g --memory-swap 8g <container>`) is printed, and the owner
decides.

## Alerts that actually reach the owner (2026-09-17)

OBSERVATION: 10 rules existed and 5 were firing for hours, but nothing reached a human —
Alertmanager was never installed and no webhook was configured. An alert nobody sees is a
config file, not monitoring.

DECISION: no Alertmanager. `scripts/hermes-alert-poller.py` polls the Prometheus API every
60 s and writes to the same Telegram chat the bus already uses (same token file — no second
copy of the secret). Grouped by rule name (one noisy rule = one message, not five),
deduplicated through `/var/lib/hermes-bus/alert-state.json`, repeated at most every 6 h,
and every resolution is reported.

```bash
bash /opt/hermes/scripts/install-alerting.sh          # install/refresh the unit
bash /opt/hermes/scripts/install-alerting.sh --check  # ALERTING: OK (also used by tests)
bash /opt/hermes/scripts/install-alerting.sh --test   # send a test alert to the chat
journalctl -u hermes-alert-poller -n 20 -o cat        # what it decided and when
```

Each message carries an actionable hint, not just a rule name (e.g. a missing project tree
means «каталог проекта удалён или не клонирован — скажи „клонируй <проект>“»).

Long reports are no longer cut at 1200 characters with a server path the owner cannot open
from a phone: a reply or forwarded report longer than 3200 characters leaves as a **`.txt`
document** with a one-line caption (`sendDocument`, multipart written by hand — no extra
dependency in the bus venv). If the upload fails, the text path is still tried: silence is
never an option.

## Project agents: real actions, not descriptions (2026-09-17)

Before this, a project agent had exactly one handler — `status` — so «почему падают тесты»
returned a directory listing. Now every project agent has `run`, and the router understands
the verb in the sentence:

| what the owner types | handler | what actually happens |
|---|---|---|
| `прогони тесты в logistics` | `run` (`ARG_WHAT=tests`) | test command of THAT project |
| `собери madworld` | `run` (`build`) | build command of that project |
| `линт octopus` | `run` (`lint`) | lint command of that project |
| `покажи логи octopus` | `run` (`logs`) | `docker compose logs`, the project's systemd unit, or its `*.log` |
| `проверь деплой octopus` | `run` (`deploy-check`) | **dry-run plan only** — `make -n deploy` / `docker compose config`, nothing is deployed |
| `как дела в logistics` | `status` | the previous read-only report |

The command is **never guessed**: `agents/checks/project-run.sh` looks for a real marker in
the repository — a `test`/`build`/`lint`/`deploy` target in the `Makefile`, a script in
`package.json`, `pytest.ini`/`[tool.pytest]`/`tests/test_*.py`, `tests/run.sh`,
`go.mod`, `Cargo.toml`, a compose file, a declared unit, a `*.log`. If nothing matches, the
agent refuses and names what it looked for; a plausible-but-wrong command in someone
else's repository is worse than a refusal.

FACT (2026-09-17): neither `pytest` nor `ruff` is installed system-wide on arm-server-01, so
for `/opt/logistics` and `/opt/octopus` the answer is «в проекте есть тесты, но в
/usr/bin/python3 нет pytest» plus the exact command to fix it — instead of a fake green run.
`/opt/hermes` runs its own `tests/run.sh`, which is how `прогони тесты в hermes-os` really
executes the 112-check suite (measured: 72 s, exit 0). Project Python is preferred when the
project has a venv (`.venv/bin/python`); object names taken from a project's own compose file
are validated against `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$` and quoted, so nothing from a
repository can become shell code.

Two consequences worth knowing:

* A report longer than 1200 characters now leaves as a **`.txt` document** (measured live:
  `telegram: sent document proj-hermes-os-run-….log (2 KiB)`), not as the first 900
  characters plus a server path. Short answers stay messages.
* The Telegram noise filter matches the bus selftest **tag** (`selftest-HHMMSS`), not the bare
  word `selftest`: a real report containing the line `ok agents selftest` used to be
  swallowed, so the owner never saw the result of the task he had just asked for.
