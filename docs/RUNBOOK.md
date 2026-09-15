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

### Where things stand (measured 2026-09-15)

```
server is IN the tailnet:
  hostname   arm-server-01
  IPv4       100.109.170.74
  MagicDNS   arm-server-01.tail5261f7.ts.net
  backend    Running        tailscaled active, UFW 41641/udp

WebUI        127.0.0.1:9119   (loopback only — deliberate)
```

### Method A — SSH tunnel over the tailnet (WORKS TODAY, use this)

Two changes from the old instruction: connect to the **tailnet IP**, not the public one, so the
SSH session itself is inside WireGuard and the server needs no public SSH exposure.

```bash
ssh -L 9119:127.0.0.1:9119 ubuntu@100.109.170.74     # keep open, or autossh -M 0
# on the phone:  http://127.0.0.1:9119
```
Verified end to end: `/`, `/healthz`, `/api/status` all return **200** through the forward, and the
page served is the mobile-ready dashboard (`<meta name="viewport">` present).

The Host header stays `127.0.0.1`, which is the only thing the dashboard accepts on a loopback bind —
see below.

### Why NOT to "just open the Tailscale IP"

Three independent blockers, all verified, all deliberate on the vendors' side:

1. **The dashboard rejects any Host that is not the interface it bound to.** On a loopback bind only
   `localhost` / `127.0.0.1` / `::1` are accepted; anything else gets
   `400 Invalid Host header`. This is DNS-rebinding protection (GHSA-ppp5-vxwm-4cf7), not a bug.
2. **`tailscale serve` cannot bridge it.** It preserves the incoming Host header, so the dashboard
   sees `arm-server-01.tail5261f7.ts.net` and refuses. Measured: `400` via MagicDNS, `404` via IP.
   Also `tailscale serve --https=443` cannot start here — see (3) — and ports 80/443 are held by the
   production nginx (`api.autosklo.org.ua`), which must not be disturbed.
3. **HTTPS certificates are not available to this tailnet account:**
   `tailscale cert … → 500 your Tailscale account does not support getting TLS certs`.
   So browsers cannot be given a trusted `https://…ts.net` URL at all.

### Method B — native browser access (OPTIONAL, needs an owner decision)

Possible, but it requires **two** deliberate acts, which is why it is not the default:

1. Bind the dashboard to the tailnet IP:
   `hermes dashboard --host 100.109.170.74 --port 9119 --skip-build --no-open`
2. Supply an auth provider, because since the June 2026 hardening **any** non-loopback bind requires
   one — and CGNAT space (100.64.0.0/10, i.e. Tailscale) is deliberately classified as public:
   either a dashboard password (`password_hash` in `config.yaml`) or OAuth via
   `hermes dashboard register` (needs a Nous Portal login). `--insecure` is a no-op and will not
   bypass this.

Method B buys convenience (no tunnel app on the phone) at the cost of a second credential to manage
and a wider bind. Method A costs a tunnel and nothing else.

### Android device status

```
G1 (android)              100.93.232.113   offline, last seen 2026-09-12
aios-android-gateway      100.122.9.31     offline, last seen 42 days ago
```

The phone has been in this tailnet before. Bring it online and join the tailnet again, then Method A
works from the phone's own SSH client.

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
