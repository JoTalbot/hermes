---
name: chatgpt-ui-driver
description: Drive the ChatGPT web UI over Chrome DevTools Protocol to keep a project moving autonomously, including the reconnect and protocol rules that took 13 hours of silent failure to learn. Use for browser-based agent drivers, not for API calls.
capability: Вести диалог в веб-интерфейсе ChatGPT через Chrome DevTools Protocol, включая правила переподключения к браузеру и проверки, что ответ действительно пришёл.
bounds: Не обходит и не решает Turnstile/капчу силой, не подделывает proof-of-work; не работает без живого браузера с профилем; чужие аккаунты не трогает.
---
# Why
`POST /backend-api/conversation` requires proof-of-work plus a Cloudflare Turnstile that only a real browser can satisfy from a datacenter IP, so the driver **types into the web UI** over CDP — exactly what a human does. That decision is why this stack exists; an API-based rewrite is not a simplification, it is the failure mode that was already ruled out.
# Where / measured state (2026-09-16)
```
/opt/orchestrator/agent_jo/
  jo_driver.py         loop, state, repo reading       chatgpt_ui.py  input/send/read
  cdp.py               minimal page-level CDP client   jo_style.py    message templates + decision heuristics
  projects_registry.json  project folders (never create new ones)     state_<project>.json  chat id, cycles, tail
  jo-agent-<project>.service  systemd units (fs, game, logistics, transcribe, ukraine)
units:  all 5 active; fs/logistics/transcribe/ukraine enabled, game active-but-disabled
CDP:    127.0.0.1:9222 via docker-proxy -> container `octopus-browser-chromium` (Chrome 152), logged-in session
NOTE:   agent_jo/README.md still says container `liza-browser` — measured truth is `octopus-browser-chromium`.
        Check with `docker ps | grep -i browser` before trusting either name.
.secrets/github_pat.txt  0600 — the PAT the driver hands to the agent inside the chat
```
# Run / inspect
```bash
cd /opt/orchestrator
.venv/bin/python agent_jo/jo_driver.py --project ukraine \
    --repo-path /opt/orchestrator/projects/ukraine --once      # one test cycle
sudo systemctl restart jo-agent-ukraine && journalctl -u jo-agent-ukraine -f
.venv/bin/python agent_jo/jo_driver.py --project ukraine --repo-path /opt/orchestrator/projects/ukraine --restart-project
```
Work protocol (owner's request, 2026-09-15): during normal work the driver writes only **«+»**; a message from the assistant ending in **«КОНЕЦ»** means the project is finished or the agent cannot continue → `state: finished: true`, heartbeat once an hour, service stays up. A new chat (start or handoff) opens with `@GitHub JoTalbot/<project>` + the PROTOCOL + repository + state.
# Do not
- Do not drop the reconnect logic. The 2026-09-14 incident: Chromium in the container restarted under a watchdog, each restart killed the CDP websocket **without a close frame**, the driver never reconnected, and all 5 agents spun "ошибка цикла … всего циклов: 0" for **13 hours / 251 errors**. The fix that must stay: `is_open` / `last_error` tracking, `CDPConnectionLost` on any command over a dead ws, one own tab per driver (`tab_id` persisted in `state_<project>.json`) with `ensure_alive()` called at the top of **every** cycle, and `--max-errors` (default 5) so the process exits and systemd restarts it instead of looping quietly.
- Do not close other drivers' tabs — each project owns its own tab precisely so agents do not fight.
- Do not use the **browser-level** CDP websocket: Chrome exposes one per process and other services on this host hold it. Page-level only.
- Do not create new ChatGPT project folders: the registry/sidebar folders are found, never created.
- Do not print `.secrets/github_pat.txt`; it is a live credential passed inside the chat by design.
- Do not restart two drivers at once while debugging — they share one browser session and one account.
# Lesson
"Agent is running" is not the same as "agent is progressing". A silent reconnect failure looks exactly like a healthy process: the fix is not more retries but a **loud error path** (counted errors → exit → systemd restart) plus a state field that proves forward motion (`cycles`, `finished`).
