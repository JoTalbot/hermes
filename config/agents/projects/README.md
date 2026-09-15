# Project agents

One file per project **that has a working copy on srv-oci-arm-01**. Generated from the live
filesystem + GitHub API (`scripts/gen-project-agents.sh`); do not hand-write identity facts here.

The gate is existence on disk, not existence on GitHub. 30 of JoTalbot's repos are public; 12
have a checkout on this server. Creating an agent for a repo the server cannot read produces an
agent that answers confidently about code it has never seen — which is worse than no agent.
The other 18 are recorded in `memory/projects/INVENTORY.yaml` as clone-on-demand candidates.

| Project | Path on server | Branch | Uncommitted files at audit |
|---|---|---|---|
| aios | /opt/aios | main | **42** |
| MadWorld | /opt/madworld | main | **68** |
| orchestrator | /opt/orchestrator | main | **18** |
| octopus | /opt/octopus | arena/tg-bot-aios-fix-and-multisync-selfloop | **7** |
| logistics | /opt/logistics | main | 0 |
| browser | /opt/octopus-browser | main | 0 |
| fs | /opt/orchestrator/projects/fs | main | 0 |
| game | /opt/orchestrator/projects/game | main | 0 |
| transcribe | /opt/orchestrator/projects/transcribe | main | 0 |
| ukraine | /opt/orchestrator/projects/ukraine | main | 0 |
| words | /opt/words | main | 0 |
| liza | /home/ubuntu/liza | main | 0 |

142 dirty files in total. Every project agent inherits one non-negotiable rule from
`config/policies/agent-policy.yaml`: an uncommitted file is somebody's work. Commit it, or leave
it. Never `reset --hard`, never `checkout --`, never `clean -fd`, regardless of how "stale" it looks.

Note `octopus` is on an `arena/*` branch, not `main` — it carries the in-flight Telegram/AIOS +
multisync self-loop fix. That is live work, not drift.
