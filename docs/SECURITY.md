# Security

Findings below are **measured on arm-server-01, 2026-09-15**, each with the command that proves it.
This repo does not auto-remediate — the `security` agent is read-only by design (`agent-policy.yaml`)
because an agent that can both find and "fix" an exposure is how outages get invented.

## C1 — Unauthenticated root-capable code path (fix first)

```
stat -c '%a %U:%G' /root/agents/-Octopus/skills/mcp/tcp_mcp_server.py   → 777 root:root
find /root/agents -maxdepth 4 -perm -0002 -type d                        → 1472 world-writable dirs
systemctl show -p ExecStart --value octopus-skills-mcp-server.service
  → /usr/bin/python3 /root/agents/-Octopus/skills/mcp/tcp_mcp_server.py
  → running since 2026-09-14, as root
```

**A root-owned service executes a world-writable Python file.** Any local process or user that can
write that path has code execution as root on the box — no exploit needed, just a file write. With
`jo-agent-*`, `logistics-agent`, `madworld-remote-operator` and browser-driving chromium all running as
autonomous local processes, "any local user" is not a hypothetical.

```
sudo chmod 0755 /root/agents/-Octopus/skills/mcp/tcp_mcp_server.py
sudo find /root/agents -type d -perm -0002 -exec chmod o-w {} +
sudo find /root/agents -type f -perm -0002 -exec chmod o-w {} +
systemctl restart octopus-skills-mcp-server && systemctl is-active octopus-skills-mcp-server
```
Restart last and check it comes back — the service is live today.

## C2 — Chrome DevTools Protocol and noVNC on a public IP

```
ss -lntp → 0.0.0.0:9222 (HTTP 200), 0.0.0.0:6080 (HTTP 200)
```

`9222` is CDP of a chromium running with `--remote-debugging-port` and `--remote-allow-origins=*`,
against a profile that holds a logged-in Google/Gemini session. CDP has no authentication: an attacker
who reaches it reads cookies, drives the session, and exfiltrates whatever that account can see. `6080`
is the noVNC view of the same desktop. Whether they are reachable from outside is decided by the **OCI
security list** — `sudo ufw status` does not list these ports, so ufw is not what is permitting them.
Check the OCI console, then rebind to `127.0.0.1` or add a ufw deny. Note `/opt/chrome_profiles` was
`rm -rf`'d at 11:26 while `9222` still answers: the listener outlived its own profile directory.

## H1 — Postgres on a public listener

```
ss -lntp → 0.0.0.0:5434 and [::]:5434     # "logistics control plane postgres (TLS only)"
ufw      → 5434/tcp LIMIT IN Anywhere
```
`LIMIT` rate-limits; it does not restrict source. If OCI allows 5434 inbound, this is a database on the
internet. Bind to the docker bridge only, or restrict ufw to the peer's /32.

## H2 — Credentials that appeared in a chat context

A GitHub PAT with `admin:org, admin:repo_hook, delete_repo, repo, workflow, user` and an **OpenSSH
private key** were pasted into a conversation. Consequences to accept and act on:

- The PAT can delete or rewrite every repo on the account, not just these. Revoke it and reissue
  **fine-grained, repo-scoped** to only what the agents need (`JoTalbot/hermes` read+write to start).
- The private key is a *login*, not a secret to keep. Mint a new key, install it in
  `authorized_keys`, then remove the old line. Rotation is cheap; recovery of a hijacked OCI tenancy is not.
- Anything pasted into a chat context should be assumed to have left your machine. Rotate, don't ration.

This repo is clean by construction: `.gitignore` excludes `.env`, `*.pem`, `*.key`, `id_rsa*`, keys, and
`scripts/secret-scan.sh` blocks the push pipeline. Verified: `bash scripts/secret-scan.sh --worktree`
→ `clean`. The scanner is the gate in `scripts/push.sh` step 2, and it rejects `ghp_…`, `github_pat_…`,
`sk-…`, AWS ids, JWTs, DSN passwords and both PEM header forms.

## M1 — Corrupt git repo hosting live services

```
ls -d /root/agents/-Octopus/repo/.git   → exists
git -C …/repo rev-parse HEAD            → fatal: not a git repository
stat → .git/HEAD missing; objects/ (146 dirs) and refs/ present
```
Objects are intact, so `git init` + a restored `HEAD` recovers it. It is also the *only* repo on the box
that returns unreadable to every discovery pass, so `gen-project-agents.sh` refuses to record it as
clean — a false `dirty=0` would invite an agent to reset a tree with real work in it.

## M2 — The health check that cannot see the outage

Legacy Hermes pointed `base_url` at `127.0.0.1:8000` (liza mock). `liza-mock` and `telegram-hermes`
are now `inactive/dead`, port 8000 is gone, and `hermes doctor` still reported **`[OK] Hermes`** at
audit time. Reason: `doctor` verifies the binary, never the provider. Consequence for agent design —
a config check proves configuration *parses*, not that inference *works*. That is why `scripts/doctor.sh`
here ends every run with a live inference round-trip and fails the run if the token does not come back.

## Standing policy

- Secrets live in `/etc/hermes/shim.env` (0600 root), `~/.hermes/.env` (0600), or `/etc/octopus/secrets.env`.
  Never in git, never in a systemd `Environment=` line, never in a command-line argument (visible in `ps`).
- `install.sh` generates the shim secret with `head -c 24 /dev/urandom` and never echoes it.
- Agents: `network_egress: deny`, `secrets.read: false`, `echo_in_output: forbidden`, force-push forbidden,
  `main` and `release/*` protected, destructive ops require a human.
- Nothing listens on a non-loopback address for Hermes components. `hermes serve --insecure` is a no-op
  since the June 2026 hardening; a public bind demands an auth provider we have not configured, so we
  bind `127.0.0.1` and tunnel.
