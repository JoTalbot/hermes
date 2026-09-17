# 2026-09-17 — a task typed in the chat was read by nobody (and two smaller traps)

## FACT — what the owner saw

At 03:08–03:09 local time the owner typed, in the bot chat:

```
Проверить загрузку сервера        →  EVENT #general · root@arm-server-01
/task Проверить загрузку сервера  →  TASK #orchestrator · root@arm-server-01
```

Both answers looked like success ("агенты увидят это на шине"). Nothing happened after
either of them. No agent ran, no result came back, and the task sat in `#orchestrator`
unread. The owner's verdict was correct and blunt: *"Что то не работает."*

## ROOT CAUSE — three separate defects

1. **A channel message is a broadcast; agents act on direct messages and on mentions.**
   `runtime.on_channel` accepted a message only when the text contained `@<agent_id>` or the
   envelope was addressed to that agent. The inbox published the task to `#orchestrator`
   without addressing anyone, so **no agent's callback ever fired**. The bus mirrored it,
   the board recorded it, the chat displayed it — and the task was inert.

2. **A free-text task had no route.** `dispatch()` required an explicit
   `capability=…`. Without one it fell through to `scored.sort(reverse=True)` on a list where
   every agent scored `0` — i.e. **the first agent alphabetically** (`backup` would have been
   asked about disk load). It never happened in practice only because defect 1 meant
   `dispatch()` was never called at all.

3. **Free text in a private owner chat was published as an `event` to `#general`.** It looked
   like an action and was a footnote.

### Two more traps found while fixing (both by testing, not by reading)

4. **The phone shortcut for buttons swallowed tasks.** The first attempt at a keyboard
   accepted any text *containing* "статус" as the `/status` command — so
   `статус проекта hermes-os`, a perfectly good task, returned the node status instead of
   reaching the project agent. Fixed by matching the normalized **label** ("📊 Статус" →
   `статус`), never a substring.

5. **Test traffic reached the owner's phone.** `tests/bus-selftest.sh` publishes real
   messages to real channels (that is how it proves mirroring and priorities), and the bridge
   forwarded them: the owner's chat received "prio selftest-001750 normal/high/urgent".
   Filtered by the `selftest` tag in `should_forward` — the suite still exercises the live
   path, the phone stays quiet.

## FIX

* `bus_bridge._publish` addresses the orchestrator by name for tasks
  (`@orchestrator <text>`), and free text in the owner's private chat is now a **task**, not
  an event (`/note` publishes a plain event).
* `runtime.on_channel` treats any `task` published into `#orchestrator` as an ask to route
  (and keeps the `from == self` guard, so the orchestrator's own dispatch cannot loop).
* `runtime.route_by_text` — deterministic routing, no model, no tokens:
  1. a project named in the task (exact name first, longest match; then the *shortest*
     project whose stem matches, so "words" does not resolve to
     `words-home-ubuntu-batch20-oci`; plus a small Russian alias table — «логистика»,
     «октопус», «слова», «перевод», «украин»…),
  2. intent keywords, specific before generic ("бэкап" beats "сервер"),
  3. the agent's own name.
  An task that matches nothing is **refused with a suggestion list**, never handed to a
  random agent.
* Every reply and forward is HTML-formatted with a readable header
  (`🧩 ЗАДАЧА · #orchestrator`, `✅ РЕЗУЛЬТАТ`, `❌ ОШИБКА`), monospace blocks for agent
  output, and a persistent keyboard (Статус / Сводка / Узлы / Помощь).
* Agent-to-agent DMs are no longer pushed to the owner's phone (errors always are): the
  channel traffic already tells the story.

## EVIDENCE

```
$ hermes-bus read --channel orchestrator -n 3
task/normal root            @orchestrator Проверить загрузку сервера
task/normal orchestrator    задача → server-guardian: Проверить загрузку сервера (handler=status, corr=484a592e4a6d)
result/normal orchestrator  результат от server-guardian по задаче «...» (status): OK
server-guardian.status → OK (1.09s)   HOST arm-server-01 ... load=12.38 11.44 11.71 cores=4 ...

$ journalctl -u hermes-bus-bridge | grep telegram
telegram: sent message_id=78   ← 🧩 Задача принята
telegram: sent message_id=79   ← 🧩 ЗАДАЧА · #orchestrator → server-guardian
telegram: sent message_id=80   ← ✅ РЕЗУЛЬТАТ · #orchestrator
```

Tests that now guard all of it: `tests/run.sh` gate [11] via `tests/probe-chat.py`
(routing, project disambiguation, refusal, HTML escaping, header, DM filter).

## LESSON

* **"Published to the bus" is not "delivered to an agent."** A broadcast needs an address;
  the system must not report success for a message no one can act on.
* **Success-shaped replies are worse than errors.** "агенты увидят это на шине" was true and
  useless. The reply now states the route and promises the result — and the promise is kept
  by a test.
* **A shortcut that matches a substring will eat a command.** Match labels exactly.
* **Anything that publishes to real channels will reach the owner** the moment forwarding
  works; test traffic needs an explicit filter, found by reading the phone, not the log.

---

## Follow-up (same day) — the refusal the owner hit next

With routing in place, the owner asked the chat **"Какие агенты есть и их функции"** and got:

```
❌ ОШИБКА · #orchestrator
не понял задачу «Какие агенты есть и их функции» — не нашёл ни проекта, ни ключевого слова.
Известные возможности: alerts, backup, ci, commit, container-state, coordination, disk,
docker, exposure, firewall, git, github, grafana, host-health, journal, load, metrics, …
```

The system was not wrong — it was unhelpful. Three things were wrong with that answer:

1. **A question about the system was treated as a task for a specialist.** "Who is on the team"
   is answered by the registry, and every agent YAML already carried a human `purpose` in
   Russian. Nobody ever rendered it for a human.
2. **The failure text dumped 30 capability tokens** — machine vocabulary handed to a person
   on a phone, and it did not even name the agents.
3. **Nothing to tap.** The owner had to invent the wording; the keyboard only reported state.

Fixed by: `agents/roster.py` (one renderer, shared by the chat and the bus, so they cannot
disagree), `/agents` + `/projects` and the meta questions *какие агенты / что ты умеешь /
какие проекты*, a refusal in plain language with four example tasks, and a six-button
keyboard where 🤖 Агенты and 📦 Проекты answer, while 💻 Сервер and 💾 Бэкап send real tasks.

**LESSON (additional):** an error message is a user interface. "Не понял" plus a vocabulary
dump tells the owner what the *machine* knows, not what to do next; a good refusal names the
next action, and a good system answers questions about itself.

**EVIDENCE (server, after the fix):**

```
$ hermes-bus read --channel orchestrator -n 2
task/normal   root          @orchestrator какие агенты есть и их функции
result/normal orchestrator  🤖 Моя команда: 27 агентов
                            🛠 Специалисты (6): 🖥 server-guardian — Здоровье узла, 💾 backup — …

$ hermes-bus read --channel orchestrator -n 1
error/normal orchestrator   🤔 Не понял: «приготовить кофе»
                            Уточни направление — например:
                            • проверить загрузку сервера
                            • сделать бэкап
                            • аудит безопасности
                            • статус проекта logistics
```
