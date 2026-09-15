# The port was open. Nothing could reach it. Two firewalls, and the cloud one decides.

FACT — 2026-09-15 the dashboard was moved to `0.0.0.0:9119` with its auth provider enabled, and
`ufw allow 9119/tcp` was added. Every local check passed: `ss` showed the socket bound, `/` returned
`302 → /login`, `/api/sessions` returned `401`, the login flow worked end to end on loopback.
FACT — from the internet, 9119 was **unreachable for about an hour**. Six independent external probe
nodes all reported "connection timed out"; a control check on port 22 from the same nodes reported
open, so the nodes were fine and the target was filtered.
FACT — two firewalls sit in this path and the **outer** one is authoritative:
(1) the **OCI security list** on the subnet, which decides whether the packet reaches the instance at
all, and (2) **ufw** on the host. The security list permitted only `22, 80, 443, 8080, 5434` and ICMP.
A perfect ufw rule cannot compensate for a packet that never arrives.
FACT — two traps sat inside that trap. First, `/home/ubuntu/.oci/config` **authenticates**
(`oci iam region list` succeeds) but belongs to a **different tenancy** and returns
`NotAuthenticated`/401 for this instance; only `/root/.oci/config` controls this box. A credential that
works is not automatically a credential that is authorised for *your* machine. Second, reachability
tests run from this agent's own sandbox are worthless here: its egress goes through an HTTP proxy that
"reaches" every port, including ports that are in fact filtered — it reported 22/80/443/8080/8095/9600/
9119 all open while third-party nodes showed only 22. Self-tests from the wrong vantage point produced
confident, wrong answers in both directions.
FACT — the OCI API cannot append one rule: `security-list update` **replaces the entire ingress set**,
so a malformed payload can cut off SSH and lock the operator out of the box.

LESSON — "the port is open" is a claim about the whole path, not about a process, a bind or one
firewall. Enumerate the layers before believing a timeout.
LESSON — test from where the user sits. Loopback proves nothing about ingress; a sandbox behind a
proxy proves nothing about the internet. Use an independent vantage point and always include a
known-good control port, or a green result is unreadable.
LESSON — the acceptance test for a network change is an external one, and it must be re-run after the
change, not before.

FIX (2026-09-15) — `scripts/oci-open-port.sh`: backs the current rules up to
`/root/oci-security-list-ingress-*.json` (0600), deep-copies the existing SSH rule as a schema template
rather than hand-writing JSON, applies with `--force`, then **re-verifies that every original rule
survived** (8 → 9, none lost) and restarts nothing. A fresh SSH connection was opened immediately after
to prove the change was not a lockout. `scripts/oci-firewall.sh` inspects the cloud rules read-only.
RESULT — from six independent external nodes: `6/6 open`; `http://129.213.177.56:9119/` serves the
login page and rejects unauthenticated API calls with `401`.
NOTE — skill promoted: `skills/server/oci-cloud-firewall.md`.
