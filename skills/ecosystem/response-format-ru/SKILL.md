---
name: response-format-ru
description: The owner-mandated answer format for this ecosystem - bullet lists, section order, the emoji dictionary and the agent report template. Use when producing any report, status or answer for the owner.
---
# Why
Two standing directives, both marked "ОБЯЗАТЕЛЬНАЯ СИСТЕМНАЯ ДИРЕКТИВА ДЛЯ ВСЕХ ИИ-АГЕНТОВ": `#70` (format: bullet lists + emoji) and `/root/agents/001-GENERAL.md` (+ `TEMPLATE.md` as the reference example). They came from the owner directly and apply to every agent and every project of the Octopus/AIOS ecosystem — ChatGPT, Claude, Gemini, Codex, Arena and the Hermes profiles alike.
# Answer shape
1. **Вывод / итог** — one or two lines, up front.
2. **Что сделано** — evidence, not intentions.
3. **Как проверить** — the exact command or step.
4. **Что дальше / замечания** — risks, blockers, decisions needed.
Bullets (`-`), headings (`##`), tables and code blocks instead of paragraphs. One idea per bullet, no restating the same thought in different words. Russian when the owner writes Russian; English technical terms are fine.
# Emoji dictionary
| | | | |
|---|---|---|---|
| 🔐 секреты | 🛡️ защита/аудит | 🚀 деплой/запуск | ✅ успех/готово |
| ❌ ошибка/запрет | ⚠️ внимание/риск | 📌 важно/уточнение | 📚 документация |
| 🤖 ИИ/агент | 📊 статус/метрики | 🔄 синхронизация | 🧪 тесты |
Emoji are **anchors at the start of a line or block**, never decoration inside a sentence ("не эмодзи-салат").
# Report template
```markdown
- 🤖 **Статус:** выполняется / выполнено / блок
- 📌 **Задача:** одна строка
- ✅ **Сделано:** …
- 🔍 **Как проверить:** …
- ⚠️ **Замечания:** …
- 🚀 **Что дальше:** …
```
# Do not
- Do not answer a multi-step action with a wall of text: number the steps.
- Do not use emoji as a substitute for the substance of the answer.
- Do not apply the format to machine-parsed output — `#70 §3` explicitly exempts raw output requested for parsing (JSON, TSV, logs).
- Do not let formatting override safety: the format rule does not cancel secret handling, `#13` (no unsupervised autoloops) or platform limits.
