---
name: step-status-protocol
description: Record step-level status so parallel agents on different machines can see what is happening right now. Use at the start and end of every substantive step in the Octopus/AIOS ecosystem, or whenever more than one agent may be editing the same repo or server.
capability: Писать статус шага в общие поверхности, чтобы параллельные агенты с разных машин видели, что происходит прямо сейчас.
bounds: Не подменяет журнал проекта и не является доской задач; секреты и внутренние рассуждения моделей в статус не пишутся.
---
# Why
This ecosystem is worked on **concurrently by heterogeneous agents** — ChatGPT, Claude, Gemini, Codex, Arena, local runtimes — from different machines. Undocumented local progress is invisible progress: nothing in a repo tells you that another agent is halfway through an edit. The owner made step status a **mandatory directive**, not a nicety: instruction `#57 §2` ("ПОШАГОВОЕ СОХРАНЕНИЕ СТАТУСА РАБОТЫ") and `/root/agents/005-MULTIAGENT-PARALLEL-SKILLS.md §2`.
# Where to write (measured 2026-09-16)
| surface | path | what belongs there |
|---|---|---|
| machine-readable step | `/root/agents/STEP_STATUS.json` | one line, e.g. `{"status": "IN_PROGRESS", "step_id": "step_90_<slug>"}` |
| human-readable log | `/root/agents/STATUS.md` | newest entry **on top**, never delete history |
| repo contract | `<repo>/AGENTS.md` | rules for agents in that repo (e.g. `/opt/orchestrator/projects/fs/AGENTS.md`) |
| repo status | `<repo>/AGENT_STATUS.md` | "update at every substantive step boundary" |
| Hermes-native bus | `hermes kanban --board hermes-os` | durable task + `comment` events, author = `$HERMES_PROFILE` |
`/mnt/agents` is a **symlink to `/root/agents`** — older instructions say `/mnt/agents/...`; it is the same tree (`/mnt/agents -> /root/agents`).
# Entry format
```markdown
- 🤖 **Статус:** выполняется / выполнено / блок
- 📌 **Задача:** одна строка
- ✅ **Сделано:** ...
- 🔍 **Как проверить:** команда или шаг
- ⚠️ **Замечания:** риски, уточнения
- 🚀 **Что дальше:** следующий шаг
```
`#57` additionally requires: agent/model/machine id, current step **and** goal, progress (done / doing / next), and errors together with the verification result.
# Use
```bash
# 1. read the picture BEFORE touching anything
sudo cat /root/agents/STEP_STATUS.json
sudo head -40 /root/agents/STATUS.md
git -C <repo> fetch && git -C <repo> log --oneline -5    # another agent may have pushed

# 2. write the machine-readable step (files are root-owned)
printf '{"status": "IN_PROGRESS", "step_id": "step_90_<slug>"}\n' | sudo tee /root/agents/STEP_STATUS.json
sudoedit /root/agents/STATUS.md                          # new entry at the top

# 3. Hermes-native alternative when you are a profile (no root needed)
hermes kanban --board hermes-os comment <task_id> "step: … | doing: … | next: …"
```
# Do not
- Do not claim a shared resource (branch `main`, the server, a secret) silently — write the intent into the status **first**.
- Do not rewrite, reorder or prune history in `STATUS.md`; append.
- Do not log an intention as an achievement: a green local test is a claim, so record the command and its output.
- Do not treat the top entry of `STATUS.md` as current to the minute — it is written at step boundaries.
# Lesson
Two agents editing one file from stale context is the most expensive failure mode this ecosystem has, and the cheapest defence is a status line written *before* the edit, not after.
