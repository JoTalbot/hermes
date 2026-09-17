# Скиллы: что нужно доделать (сгенерировано scripts/audit-skills.sh --plan)

Всего SKILL.md: 261 (наших 12, под /root/agents 249). Ничего не удалено — это план для решения владельца.

## Полные копии (одно и то же тело в разных местах)

- `c6c561c31ba5e4bdd38c69f1f8efe1e151fabd45` — 2 копии:
  - /root/agents/-Octopus/skills/core/_archived_dupes/persistent_terminal_manager/SKILL.md
  - /root/agents/-Octopus/skills/core/persistent-terminal-manager/SKILL.md

## Совпадающие заголовки

- «review api design (psenger adapted)» — 2 файла(ов): /root/agents/-Octopus/instructions/skills/per-skill-research/review-api-design/SKILL.md, /root/agents/-Octopus/skills/core/review-api-design/SKILL.md
- «skill: persistent terminal manager» — 2 файла(ов): /root/agents/-Octopus/skills/core/_archived_dupes/persistent_terminal_manager/SKILL.md, /root/agents/-Octopus/skills/core/persistent-terminal-manager/SKILL.md
- «skill: unused-resource-reclaimer» — 2 файла(ов): /root/agents/-Octopus/skills/core/unused-resource-reclaimer/SKILL.md, /root/agents/-Octopus/skills/_backup_desc_frontmatter_20260902T085504Z/SKILL.md
- «why» — 9 файла(ов): /opt/hermes/skills/ecosystem/response-format-ru/SKILL.md, /opt/hermes/skills/multiagent/agent-chat-rooms/SKILL.md, /opt/hermes/skills/multiagent/skills-first/SKILL.md

## Наши скиллы без объявленных прав

- /opt/hermes/skills/ecosystem/response-format-ru/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/federation-node-join/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/multiagent/agent-chat-rooms/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/multiagent/skills-first/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/multiagent/octopus-skill-catalog/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/multiagent/step-status-protocol/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/backup/disk-gate/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/agent-bus/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/agent-handlers/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/server/oci-cloud-firewall/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/chatgpt/chatgpt-ui-driver/SKILL.md — нет: capability, bounds
- /opt/hermes/skills/chatgpt/chatgpt-backend-export/SKILL.md — нет: capability, bounds

## Скиллы под /root/agents без объявленных прав

Их 249 из 249: добавлять поля имеет смысл только тем, что реально используются.

## Шаблон объявления прав

```markdown
## Возможности
capability: <что скилл делает>
bounds: <чего он не делает>
```
