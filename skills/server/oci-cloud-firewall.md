---
name: oci-cloud-firewall
purpose: open/verify an inbound port on an OCI instance — the cloud gate, not just ufw
scope: any port on arm-server-01 reachable from outside; empty subnet security list; pre-flight for "the port is open but nothing can reach it"
inputs: scripts/oci-open-port.sh <port>, scripts/oci-firewall.sh inspect, /root/.oci/config, region iad
outputs: ingress rule added to the subnet's security list + proof from an external vantage point; exit 0/1
permissions: writes the OCI tenancy security list (root; replaces the whole rule set — read the Do-not)
dependencies: /home/ubuntu/oci-venv/bin/oci (3.93.0), python3
projects: all
version: 1.0.0
last_updated: 2026-09-15
---
# Why
Setting the dashboard to `0.0.0.0:9119` and adding `ufw allow 9119/tcp` was **not enough**, and the
port stayed dead for an hour while every loopback test passed. There are two firewalls in this path and
the inner one is not the authoritative one:

1. **OCI security list** (VCN level) — decides whether the packet reaches the instance at all.
2. **ufw** on the host — decides what the host accepts.

OCI drops the packet first, so a perfect ufw rule and an unfiltered bind still yield a timeout. Measured
2026-09-15: the security list permitted only **22, 80, 443, 8080, 5434** and ICMP — everything else,
including 9119, was filtered before reaching the box. Six independent external probe nodes confirmed it.
And a timeout looks exactly like a firewall on the host, which is what makes this expensive.
# Use
```bash
bash scripts/oci-firewall.sh inspect          # what the cloud currently permits
sudo bash scripts/oci-open-port.sh 9119       # add one ingress rule (backs up first, verifies after)
```
Then prove it from **outside** the server's own network — loopback success proves nothing about ingress.
`check-host.net/check-tcp` accepts a host:port and reports per-node results; always include a port known
to work (22) as a control, otherwise a green result is unreadable.
# Do not
- **Never** `security-list update` with a hand-written rule array. The OCI API has no "append": it
  **replaces the whole ingress set**, so one malformed field can cut off SSH and lock you out of the box.
  `oci-open-port.sh` deep-copies the existing SSH rule as a schema template and re-verifies that every
  original rule survived; keep that property if you touch the script.
- Do not use `/home/ubuntu/.oci/config`. It authenticates (`oci iam region list` works) but belongs to a
  **different tenancy** and returns `NotAuthenticated`/401 for this instance. Use `/root/.oci/config`.
  A credential that authenticates is not automatically a credential that is authorised for your box.
- Do not trust a reachability test from a sandbox whose egress goes through an HTTP proxy — it "reaches"
  closed ports. That mistake produced a contradictory all-open result on 2026-09-15.
- Do not remove the backup file `/root/oci-security-list-ingress-*.json`.
# Lesson
"Port is open" is a claim about the whole path, not about one process, one bind or one firewall. When a
network change is the deliverable, the acceptance test must run from where the user actually sits.
