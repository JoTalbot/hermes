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

## Restore drill on the current code (2026-09-17) and the gaps it found

The drill ran on the spare node (`hermes-node-03` container, hostname `node-arm-03`), from a
fresh archive into a scratch home, using the code that was being tested:

```bash
# on the control host
HERMES_HOME=/home/hermes/.hermes bash scripts/backup.sh         # state + node config arch
tar -czf /tmp/hermes-newcode.tgz agents bus scripts deploy tests docs config skills memory
docker cp /tmp/hermes-newcode.tgz hermes-node-03:/tmp/
docker cp /var/backups/hermes/hermes-state-<stamp>.tar.gz hermes-node-03:/tmp/
# in the node
docker exec hermes-node-03 bash -lc 'export HERMES_HOME=/tmp/restored/.hermes; \
  cd /tmp/hermes-newcode && bash scripts/restore.sh /tmp/hermes-state-<stamp>.tar.gz --force --no-systemd'
```

Result: `restored 222 files`, `profiles 28 / skills / kanban / memories / config.yaml` all
present, `restore: PLAUSIBLE`, bus wiring `wired 27 agent config(s)` (6 core + 21 project).

**What the drill broke open** — every one of these was a silent failure before:

| defect | what it looked like | fix |
|---|---|---|
| `backup.sh` archived only `$HERMES_HOME` | a restored node came back without `/etc/hermes/telegram.chats.json` (the bot would ignore its owner), `node.env` and the bus state | new `hermes-nodecfg-*.tar.gz` (explicit include list, secrets excluded) and a restore step that never overwrites existing files |
| `restore.sh` did not export `REPO_DIR` | step 3 ran the node's OWN `/opt/hermes` code, so a "drill on the new code" tested the old code | `export REPO_DIR HERMES_HOME` |
| `tar … | sed | head -N` under `set -o pipefail` | the script aborted mid-step with no message (SIGPIPE) | `awk 'NR <= N'` |
| `wire-agents.sh` used system `python3` | without PyYAML it printed `skip … unparseable YAML` 21 times and `wired 0` — a node with no project handlers that still looked installed | use the bus venv, `FATAL` if no YAML-capable interpreter |
| `install-agent-runtime.sh` hardcoded `server-guardian` | in node scope the id is `<node>/server-guardian`, so its own selftest printed `no agent 'server-guardian'` on a healthy node | resolve the first agent id once and use it |
| `install-model-policy.sh` used system `python3` | no PyYAML → "файл не читается" although the file was fine | pick the interpreter like `wire-agents.sh`, and report `UNKNOWN` when the checker itself lacks YAML |

## Pending tasks now expire (2026-09-17)

`pending.json` only ever grew: a task was removed when its result arrived, so an agent that
died on a task left it "in flight" forever. Now the runtime sweeps every 5 minutes and at
startup (`HERMES_PENDING_TTL`, default 6 h), reports each expiry to `#incidents` (which
reaches Telegram), exports `hermes_agents_pending_overdue`, and the alert
`HermesPendingOverdue` fires if anything stays overdue for 15 minutes. `/pending` marks them
`⏰` instead of showing them as work in progress.

## Project agents and other people's repositories (2026-09-17)

FACT: 14 of the 21 project agents could not read their own repository. The trees belong to
`ubuntu` / `opc` while the agents run as `root`, so git refused every command with
`detected dubious ownership` — and `project-check.sh` turned the empty output into
**«✅ дерево чистое · ✅ всё отправлено · ✅ не отстаёт»**. The agent claimed it had verified
something it had not read a single byte of. Checked after the fix: `proj-octopus` reports
branch `ops/browser-aios-adapter-deploy` with **3 unpushed commits** — information that had
been silently replaced by «всё отправлено» for weeks.

```bash
bash /opt/hermes/scripts/install-git-safety.sh            # выдать доступ (идемпотентно)
bash /opt/hermes/scripts/install-git-safety.sh --check    # GIT-SAFETY: OK
```

It adds each project `local_path` to `safe.directory` for every account that reads git —
the agent unit's user, `root`, and the metrics exporter's user (`git config --global --add`,
nothing else is touched). A repository that stays unreadable for a *different* reason (e.g.
`.git` without `HEAD`) is reported as a warning, not as a failure: access cannot fix it, and
the honest answer is `НЕИЗВЕСТНО`, which `project-check.sh` now prints with the reason and
the exact command that would help.

`install-agent-runtime.sh` runs this step, so a new node wires it correctly the first time.

## What the agents actually did (2026-09-17)

Per-run logs were always written (`/var/lib/hermes-agents/logs/`), but nothing tied them together:
"has this agent ever failed?" could only be answered by reading dozens of log files by hand, and a
handler that failed on every single run looked exactly like a healthy one — no metric moved, no
alert fired. Every run now also appends one line to `/var/lib/hermes-agents/history.jsonl`:
agent, handler, who asked, exit code, duration, log path, first line of output. The file is
append-only, rotated at 5 MiB (`history.jsonl.1…3`), and never records what the owner typed
(`message`/`text`/`prompt`/`token`/`password` are dropped).

```bash
bash /opt/hermes/agents/checks/history.sh          # runs, failures, p50/p95 per agent
ARG_AGENT=proj-liza ARG_N=200 bash /opt/hermes/agents/checks/history.sh   # one agent
```

In Telegram: «что делали агенты». The exporter turns the same file into
`hermes_agent_runs_total`, `hermes_agent_failures_1h`, `hermes_agent_duration_p95_ms`,
`hermes_agent_last_run_timestamp_seconds`, and the rule `HermesAgentFailing` fires when an agent
fails three times in an hour. This doubles as the audit trail for actions: «перезапусти
octopus-browser» is recorded with the actor and the exit code, not just printed in the chat.

**Evidence lines.** The same day's incident (14 project agents reporting a clean tree nobody could
read) is closed structurally: `lib/report.sh` gained `report_proof "<command>"` — the command a
claim came from — and `report_unknown "<what could not be read>"`, so "I could not look" is a
first-class answer instead of an empty report. `project-check.sh` already cites its git commands.

## Batch of 2026-09-17: journal, lookup, scoped actions, telemetry, digest

Everything the owner asked for in one pass, each piece with a gate in `tests/run.sh`.

**Journal.** `journal_write <slug> <kind> <text>` (agents/checks/lib/journal.sh) appends one line to
`memory/projects/<slug>/JOURNAL.md`; `journal_slug_for <unit|container|path>` maps a name back to its
project. Only things that change state write (act.sh, project-run.sh); status reports read. The
project report now ends with «📌 ЧТО БЫЛО С ПРОЕКТОМ», so "why was liza touched yesterday" is one
answer away. `scripts/install-journal.sh --check` keeps all 21 journals present.

**Lookup.** `bash agents/checks/lookup.sh` with `ARG_NAME=<name>` searches systemd units, containers,
processes, project configs, listening ports and directories, and ends with the journal lines for that
name. routing.py sends any untyped object name there («что там с octopus-multisync»).

**Scoped actions.** act.sh gained `rotate-logs`, `backup-now`, `clean-old-logs <days>`; the last two
refuse to run without «подтверждаю …» (the confirmation travels through routing as ARG_CONFIRM).
`verify-action.sh` re-checks the object afterwards — the executor is no longer the only witness.

**Telemetry.** Every agent run is in `history.jsonl`; `ask` records additionally carry tier/model/
fallback, so a degraded balancer is visible instead of merely being slower. Metrics:
`hermes_model_requests_1h`, `hermes_model_fallbacks_1h`, `hermes_model_latency_p95_ms`,
`hermes_queue_wait_p95_ms`. Alerts: `HermesAgentFailing`, `HermesModelFallbackStorm`,
`HermesQueueBacklog`.

**Queue.** Interactive and background tasks use separate semaphores (2 / 1); if any task waits more
than 120 s the owner gets one message saying so.

**Digest.** `bash scripts/install-digest.sh` installs `hermes-digest.timer` (09:00, persistent) which
runs `scripts/hermes-digest.py`: the 10–15 line summary (agents, alerts, projects, backup, queue)
delivered through the same Telegram channel as the alerts. `--test` sends it now.

**Skills.** `bash scripts/audit-skills.sh` inventories every SKILL.md under /opt/hermes/skills and
/root/agents, reports duplicate titles and full copies, and flags skills with no declared capability
or bounds. It never deletes anything: 260 skills are somebody's work and the decision is the owner's.


## Owner batch 1–8: guards, staleness, ratings, skills (2026-09-17, third pass)

Eight items the owner listed in one line, each with a gate in `tests/run.sh` (§[17]).

**Container limits as a checked invariant.** `bash scripts/install-container-guard.sh` writes
`/etc/hermes/container-limits.conf` (`<container> <memory> <swap>`) and installs
`hermes-container-guard.timer` (15 min). `bash scripts/container-guard.sh` compares the live
`docker inspect` values with the file, restores drift with `docker update` (never restarts a
container, never touches one that is not in the file) and prints `CONTAINER-GUARD: OK|DRIFT`.
`--seed` fills the file from what is running now; `--check` tells whether it is installed.
State: `/var/lib/hermes-bus/container-guard.json`.

**Wiring as a checked invariant.** `bash scripts/install-wiring-guard.sh` +
`bash scripts/wiring-guard.sh` (timer 30 min) verify that every agent in
`config/agents/*.yaml` is present in the running registry, that its check scripts exist and are
executable, and that project agents point at existing paths. Output `WIRING-GUARD: OK|DRIFT`,
state `/var/lib/hermes-bus/wiring-guard.json`.

**Staleness that used to be invisible.** The exporter now reports `hermes_project_behind` /
`hermes_project_ahead` per project, and freshness of everything else:
`hermes_backup_age_hours`, `hermes_backup_count`, `hermes_backup_bytes`, `hermes_journal_bytes`,
`hermes_feedback_total{verdict=...}`, `hermes_container_guard_age_seconds`,
`hermes_wiring_guard_age_seconds`, `hermes_container_limit_drift`, `hermes_wiring_drift`.
Six new alert rules: `HermesContainerLimitDrift`, `HermesGuardStale`, `HermesWiringDrift`,
`HermesProjectStaleCopy` (>50 commits behind for 6 h), `HermesBackupStale` (>48 h, critical),
`HermesJournalGrowing`. Reload rules only through `bash scripts/install-monitoring.sh`
(it backs up and SIGHUPs; the Prometheus container's `/-/reload` answers 403).

```bash
# why is a copy behind?  (641 at the time of writing, on a copy nobody looked at)
curl -s localhost:9725/metrics | grep hermes_project_behind
# is the guard still running?
curl -s localhost:9725/metrics | grep -E 'guard_age|_drift'
```

**Project copies from the chat.** `clone-project` and `pull-project` are guarded verbs in
`agents/checks/act.sh`: only `github.com/JoTalbot/*`, destination only under `/opt/*` or
`/home/ubuntu/*`, clone refuses if the copy already exists, pull is fast-forward only and refuses
on a dirty tree and asks for «подтверждаю …» first. routing.py understands
«склонируй проект liza», «подтяни копию fs» — the target is taken from «проект/копию X».

**Ratings under every answer.** Every Telegram reply carries «👍 точный / 👎 мимо»
(`fb|up|down|<tag>`); the bus honours `callback_query`, records the question and the answer that
were rated into `/var/lib/hermes-agents/feedback.jsonl` (tags in
`/var/lib/hermes-agents/feedback-tags.json`, ≤200), answers the tap and drops the buttons so the
same reply cannot be rated twice. A 👎 also lands in the log. Reports:
`bash agents/checks/feedback.sh` (totals, 24 h, share of exact answers, list of 👎, frequent words)
and the digest's «🗳 ОЦЕНКИ ОТВЕТОВ» section.

**Journals.** `bash agents/checks/journal-top.sh` — how much the journal takes, the ceiling
(500 MiB), the ten loudest units over 24 h and the single loudest writer by name, so «why is the
disk full» is one command. (Here the loudest are `octopus.service` and five `octopus-child@` units —
someone else's project, rotation for them only with the owner's agreement.)

**Understanding, measured.** `bash scripts/eval-agents.sh` asks 20 real owner questions and checks
capability, handler and subject; `--json` for machines, `--live` to also run the node's registry.
It caught two real routing defects (below). `bash scripts/audit-skills.sh --strict` exits non-zero
for *our* skills without declared capability/bounds, `--plan` writes `docs/SKILLS-TODO.md` — a plan
for the owner, it deletes nothing.

**Fixed while running the batch on the node** (all four were silent lies):
1. `install-git-safety.sh` only checked the agent user, while the metric exporter runs as its own
   user — `hermes_project_behind` stayed empty for every copy but one. Now every user that reads git.
2. `install-monitoring.sh` gave the exporter `--x` on `/var/backups/hermes`: it could enter the
   directory but not list it, so `glob()` found nothing and `hermes_backup_count` reported 0 / −1 h
   for a directory holding 5 files and 341 MB. Now `r-x` (file contents stay root-only).
3. routing.py: the Latin alias «hermes» mapped to the project `hermes-os`, so «статус hermes»
   (the stack) answered about a project. Aliases that are system words are ignored, and aliases no
   longer match inside a word («топологистика» ≠ «логистик»).
4. The eval expected a subject where the question has none («какие агенты?») — a test defect, not
   a routing one; and the ratings report printed no `ИТОГ` line until the first rating existed, so
   the live gate could not see the empty state. Both fixed; the live ratings check now runs on a
   fixture and on the node's file.

## Seeing the LLM: which models answer, and who is alive (2026-09-17, second pass)

`bash agents/checks/models.sh` answers «какие модели отвечают» in one command, and it spends no
model requests: it reads `history.jsonl` plus the balancer's own health. Sections: what was asked
per tier and how much of it was answered by the same tier (with p95 and cache hits), which
provider actually served each answer, provider health and key counts from the balancer, what is
missing right now (ollama off, a tier whose providers are down), and the shim's own counters.

```bash
bash agents/checks/models.sh                 # отчёт для владельца
ARG_HOURS=1 bash agents/checks/models.sh     # только последний час
curl -s localhost:9725/metrics | grep '^hermes_llm_'   # то же, но числами для правил
```

Telegram/routing: «какие модели отвечают», «какие провайдеры llm живы» → server-guardian,
handler `models` (declared in scripts/wire-agents.sh, so `wire-agents.sh --check` fails if it ever
drifts). The 09:00 digest carries a short «🧠 МОДЕЛИ» line: requests, tier mismatches, top
providers.

Metrics added on top of the existing `probe_balancer` (same names, no duplicates — two functions
emitting one metric name with different HELP lines make Prometheus drop the whole scrape):
`hermes_llm_provider_keys{provider}`, `hermes_llm_tier_healthy_providers{tier}`,
`hermes_llm_cache_size`. Two new rules: `HermesLLMTierNoProvider` (a tier has no healthy provider
for 15 min) and `HermesLLMHealthUnreachable` (`hermes_llm_balancer_up == 0` for 10 min — before
this, a blind exporter looked exactly like a healthy one).

**Measured while building this** (so nobody repeats the mistakes): `hf-Qwen2.5-72B-Instruct` HAS a
key but an empty `base_url` — it can never answer; `mistral-small` answers `HTTP 429` while its
quota is exhausted; `liza-rpa-gemini-web` and the ollama providers report zero keys. A provider
marked healthy in `/health` is therefore not proof that it can answer — only a live call is.

## Which model actually answered (2026-09-17)

The owner asked to check the LLM path of the agents. The path works — the shim is up, the
balancer is healthy (11 providers), agents ask by TIER and hold no provider keys, answers come
back in 0.3–1.7 s and no request fell back. But the check found that **the requested tier was not
what answered**, and the system could not see it:

* the AIOS bridge accepts a `tier` field in the body of `/api/v1/aios/ask`, but the handler never
  passes it to `llm_balancer.ask()`, so the tier is chosen by the balancer's own keyword classifier
  over the prompt text. Measured: a request with `"tier": "reasoning"` came back as
  `tier=fast, provider=groq-gpt-oss-20b` (the cheap 20B model);
* the balancer's answer cache key is `task_type::cloud_only::json_mode::system::prompt` — no tier
  in it. Measured: the same prompt asked with `"tier": "local"` returned the cached cloud answer
  (`provider=groq-gpt-oss-20b (cached)`), so an "escalate to a smarter model" step can be served
  by the cheap one within the 5-minute TTL;
* our own telemetry recorded the tier we ASKED for as the model that answered, so reports said
  `hermes-reason` while a fast model had served the request.

```bash
# what the balancer does with a tier (never cached: unique prompt)
curl -s -X POST localhost:9600/api/v1/aios/ask -H 'Content-Type: application/json' \
  -d '{"goal":"проба '"$(date +%s%N)"': назови столицу Франции","tier":"reasoning"}' | python3 -m json.tool
# what our agents were told, and how often the tiers disagree
curl -s localhost:9700/metrics | grep -E 'llm_tier_mismatch_total|llm_served_tier_total'
curl -s localhost:9725/metrics | grep -E 'hermes_model_served_1h|hermes_model_tier_mismatch_1h'
```

**Fixed on our side (this is what the metrics above are for):** the shim now returns, and counts,
the tier and provider that actually answered (`aios.tier`, `aios.provider`, `aios.cached`,
`llm_tier_mismatch_total`, `llm_served_tier_total{tier=...}`, plus a rate-limited log line
`tier mismatch: asked X, balancer served Y`); `models.ask` records `served_tier` / `provider` /
`cached` / `tier_mismatch`; the run history keeps them; the exporter exposes
`hermes_model_served_1h` and `hermes_model_tier_mismatch_1h`; and the answer footer shows
`модель hermes-reason · groq-gpt-oss-20b [fast] ⚠️ ответил не тот тир`. A green metric no longer
means "we asked the smart model" — it means "the smart model answered".

**The tier is real now (2026-09-17, with the owner's consent).** The AIOS bridge carries
`tier: Optional[str]` in `GoalRequest` and passes `task_type=(req.tier or "auto")` into
`llm_balancer.ask`; without a tier the behaviour is exactly as before, so other consumers are
untouched. Backup, unified diff and rollback live in `/var/backups/hermes/`:

```bash
cp -a /var/backups/hermes/octopus-aios-server.py.<stamp>.bak /opt/octopus-aios-server.py
systemctl restart octopus-aios.service
# проверка после отката: curl -s localhost:9600/health
```

Measured after the change (unique prompts, no cache): `fast → groq-gpt-oss-20b`,
`reasoning → groq-gpt-oss-120b`, `long_context → gemini-2.5-flash`, and a request without a tier
still lands on the old classifier (`tier=fast`). Gate [18] re-checks this live, so a revert of the
bridge fails the tests instead of silently costing smartness.

**Two tiers are still broken for reasons outside our control** (the telemetry now says so instead
of hiding it — `⚠️ ответил не тот тир` in the answer, `HermesModelTierMismatch` alert):

* **code** — `mistral-small` answers `HTTP 429 (Rate limited)` and `hf-Qwen2.5-72B-Instruct` has an empty
  `base_url` in the balancer (a key is present, but there is no host to call — `[Errno -5] No
  address associated with hostname`). A `hermes-code` request is therefore served by `groq-gpt-oss-20b` (fast tier).
  Needs a working key or another code provider in the balancer.
* **local** — the `ollama` service on this box is inactive, so the local tier returns the
  balancer's boilerplate, which the shim refuses (502) and the agent answers with facts alone.
  `systemctl start ollama` would restore the free on-box path (a 3B model, ~2 GB RAM on first use).

**After deploying agent code, restart the unit.** Python caches imports at start, so a fixed
`agents/routing.py` keeps answering by the old rules until `hermes-agents` is restarted (same for
`bus/bus_bridge.py` and `hermes-bus-bridge`). Measured during this batch: `routing.py` was deployed
at 06:17:30 while the running `hermes-agents` had started at 06:01:27; the live task «статус hermes»
only reached the fixed routing after `systemctl restart hermes-agents`. Check with
`systemctl show -p ExecMainStartTimestamp --value hermes-agents` against the file mtime.
