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
sudo systemctl restart hermes-serve     # WebUI + JSON-RPC on 127.0.0.1:9119
sudo -u hermes HERMES_HOME=/home/hermes/.hermes /home/hermes/.hermes-venv/bin/hermes gateway   # messaging
```

## Android control

**Today (no Tailscale).** SSH tunnel to loopback, then the phone's browser:
```bash
ssh -L 9119:127.0.0.1:9119 ubuntu@129.213.177.56   # keep open, or autossh
# → http://127.0.0.1:9119  (localhost on the *phone*, forwarded to the server)
```
**Preferred (after Tailscale).** `tailscale up` on the server, install the Android client, join the
tailnet, then reach `http://<tailscale-ip>:9119` over the encrypted mesh. Never `--host 0.0.0.0`: the
public bind wants an OAuth/password provider, and a tunnel costs nothing.

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
