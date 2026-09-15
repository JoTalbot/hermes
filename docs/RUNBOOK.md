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
