# Multi-server

```
                    CENTRAL CONTROL (orchestrator on the control server)
                     servers · projects · agents · tasks · skills · memory · health
                          │                                   │
                     Server 01 (srv-oci-arm-01)          Server 02 (new)
                     hermes node :9119                   hermes node :9119
                       │        │                          │
                  agents…   balancer:9600            agents… → central balancer
```

## Identity

`server.id` is minted once by `scripts/register-server.sh` (`srv-<sha1(hostname)[:8]>`, or reused from
the existing manifest) and **never re-derived**. A hostname change, an IP change, or a re-imaged box
keeps its id — otherwise one server forks into two in the central view and its history splits. If you
replace a box deliberately, delete the old manifest; do not edit its id.

## Joining

```bash
git clone https://github.com/JoTalbot/hermes && cd hermes && sudo ./scripts/bootstrap.sh
```
Bootstrap probes the balancer on `:9600`. On a non-control server that is usually absent, and
bootstrap says so and continues — a node with no provider is a valid, incomplete state, not an error to
hide. Then either point `model.base_url` at a reachable balancer, or run a local one and have the shim
front it.

## What syncs through GitHub, and what must not

| | `config/agents`, `config/policies`, `config/skills`, `docs`, `scripts` | GitHub, every change |
| servers/<host>.yaml manifest | GitHub on registration |
| sessions, state.db, kanban.db, memories | **never** — per-server backup target |
| provider keys, /etc/octopus/*, *.pem | **never**, not even private-repo-only |

## Central control plane — honest status

The §24 panel (Servers 4 / Online 4 / Agents 27 / Healthy 26 …) is **not built**. `hermes serve` gives
per-node WebUI; there is no cross-node aggregate yet. Until then the numbers come from running
`doctor.sh` on each node and reading the shim's `/metrics` in Prometheus. Anyone claiming a working
multi-server dashboard today is reading a diagram, not a system.

Two prerequisites before a second node is worth adding: the balancer has no authentication (fine on
loopback, unacceptable across a VPN), and C1 in SECURITY.md means local code execution as root is
available to any user on this box — which is a poor place to put a central control plane.
