---
name: chatgpt-backend-export
description: Export every ChatGPT conversation of an account through the private backend-api, including the TLS-fingerprint trick that defeats Cloudflare 403 on datacenter IPs. Use to archive, mine or re-index chat history.
---
# Why
The official OpenAI export cannot be automated (Settings → Data controls → Export is manual), so the working path is the same backend-api the web UI uses. The non-obvious part, and the reason this is a skill rather than a script dump: **from a datacenter IP, chatgpt.com answers 403 to any plain-HTTP client**. Requests must be sent with a browser TLS fingerprint — `curl_cffi` with `impersonate="chrome"`. Without that detail, every naive attempt looks like "the API is closed".
# Where / measured state (2026-09-16)
```
/opt/orchestrator/chatgpt_export/
  export_chats.py   # pagination, fetch, retries, resume, atomic writes
  verify_data.py    # integrity check of collected data
  run_export.sh     # background run with a timestamped log in logs/
data/  chats/ 469 MB (raw mapping tree) · light/ (role/text/time only) · index.json ·
       chat_list.json · errors.json · summary.json · chat_index.db (45 MB)
.secrets/chatgpt_token.txt   0600 ubuntu:ubuntu — access token, git-ignored
.venv/                       curl_cffi 0.16.3 present
First full collection (2026-09-14): 274 conversations listed, 273 fetched, 47,554 messages.
```
# Use
```bash
cd /opt/orchestrator
# token: env CHATGPT_ACCESS_TOKEN, or --token, or .secrets/chatgpt_token.txt (pick one)
# open https://chatgpt.com/api/auth/session in the SAME logged-in browser and copy "accessToken"

.venv/bin/python chatgpt_export/export_chats.py --limit 5 --force   # smoke test first
bash chatgpt_export/run_export.sh                                   # full run, background
tail -f logs/export_*.log
.venv/bin/python chatgpt_export/verify_data.py                       # integrity afterwards
```
Properties worth relying on: resumable (already-downloaded conversations are skipped by `update_time`), index saved every 25 conversations, **atomic file writes** (`tmp` + rename) so an interrupt never leaves a half file, retries with exponential backoff honouring `Retry-After` on 429/5xx/403.
# Do not
- Do not "fix" a 403 by retrying harder or adding proxies: the answer is the TLS fingerprint (`impersonate="chrome"`), not persistence.
- Do not print, log or commit the token; it is a live session credential (`chmod 600`, `data/` and `.secrets/` are git-ignored).
- Do not re-run a full export to pick up a few new conversations — it is resumable, so just run it; `--force` re-downloads and is the expensive branch.
- Do not treat `errors.json` entries as fatal: `conversation_inaccessible` means the chat was deleted or shared with the account, not that the export is broken.
- Do not run this while the `jo-agent-*` drivers are active if the browser session matters — the export uses a token, the drivers use the browser; both belong to the same account.
