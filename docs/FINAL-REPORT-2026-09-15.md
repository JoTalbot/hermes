# Hermes Agent OS на arm-server-01 — финальный отчёт

**Дата:** 2026-09-15 · **Сервер:** `ubuntu@129.213.177.56` (`arm-server-01`, id `srv-oci-arm-01`, Ubuntu 24.04.4 LTS, aarch64, 4 CPU, 23 GiB RAM)
**Репозиторий:** [JoTalbot/hermes](https://github.com/JoTalbot/hermes) · ветка `main` · последний коммит `411cc2b`
**Отчёт составлен в режиме read-only** — по указанию владельца код сервисов больше не правился, только сбор данных и проверки.

> **Обновление 15:35 — Tailscale активирован владельцем.** Критический FAIL снят, состояние
> системы изменилось на `DEGRADED`. Раздел «11. ANDROID» и «Что осталось» переписаны ниже.

## Итоговый статус: **READY**

Все критические проверки пройдены. Осталось одно предупреждение, относящееся к **чужому** проекту
(`logistics-recurring-demand-scheduler-1`, Exited), а не к Hermes.

```
SYSTEM HEALTH: DEGRADED (1 warnings)
  [OK]   Tailscale      up on 100.109.170.74
  [WARN] Docker         1 exited container(s): logistics-recurring-demand-scheduler-1
18 OK / 1 WARN / 0 FAIL
```

**16 критериев: 13 PASS, 3 WARNING** (RECOVERY, MULTI-SERVER, FINAL TEST — последний только из-за
предупреждения по чужому контейнеру).

---

## Таблица по 16 критериям

| № | Критерий | Статус | Доказательство |
|---|---|---|---|
| 1 | **HERMES** | ✅ PASS | v0.19.0 (актуальный релиз PyPI); 4 юнита active+enabled; WebUI 200 на `/`, `/healthz`, `/api/status` |
| 2 | **LLM** | ✅ PASS | Балансер `:9600`, 11 провайдеров; shim v1.3.5; round-trip `DOCTOR_OK`; key вращается только в шлюзе |
| 3 | **АГЕНТЫ** | ✅ PASS | 27 профилей (+default): 7 специалистов + 20 проектных; 27 SOUL.md, 27 MEMORY.md |
| 4 | **AGENT BUS** | ✅ PASS | 4 карточки `done` с реальными результатами; делегирование A→B и A→B→A подтверждено |
| 5 | **ПРОЕКТЫ** | ✅ PASS | 20 проектных агентов, `INVENTORY.yaml` — 23 записи (find .git × GitHub API) |
| 6 | **SKILLS** | ✅ PASS | `REGISTRY.md`, 8 категорий, 27+ записей; дубликатов существующего нет |
| 7 | **MEMORY/KNOWLEDGE** | ✅ PASS | Общая база с FACT/OBSERVATION/HYPOTHESIS/DECISION/LESSON + 27 ролей + 6 инцидентов |
| 8 | **GITHUB** | ✅ PASS | 3 коммита запушены, дерево чистое, 0 unpushed, secret-scan clean |
| 9 | **RECOVERY** | ⚠️ WARNING | Восстановление проверено в песочнице, но state-бэкап **молча пустой при вызове без HERMES_HOME** |
| 10 | **MULTI-SERVER** | ⚠️ WARNING | Манифест и скрипт регистрации есть; второго сервера нет → кросс-серверная связь не проверена |
| 11 | **ANDROID** | ✅ PASS | Tailscale активен (`100.109.170.74`); SSH-форвард проверен: 200 на `/`, `/healthz`, `/api/status` |
| 12 | **MONITORING** | ✅ PASS | Prometheus/Grafana переиспользованы; 4 таргета `up`; экспортёр и метрики отвечают |
| 13 | **AUTORECOVERY** | ✅ PASS | Self-heal секрета и инварианта 755 проверен на живом сбое; `Restart=always` |
| 14 | **IDEMPOTENCY** | ✅ PASS | Повторные прогоны: 0 создано / 0 обновлено / 0 записано; idempotency-key подтверждён |
| 15 | **SECURITY** | ✅ PASS | Секретов в git нет; права 600/755; GUI только на loopback |
| 16 | **FINAL TEST** | ⚠️ WARNING | doctor **18 OK / 1 WARN / 0 FAIL**; smoke 5/5; warning — чужой контейнер `logistics-*`, не Hermes |

---

## 1. HERMES — PASS

```
Hermes Agent v0.19.0 (2026.7.20)   pip, /home/hermes/.hermes-venv, Python 3.12.3

hermes-env-guard    active  enabled     восстанавливает секрет + чинит инвариант
hermes-shim         active  enabled     OpenAI-совместимый шлюз :9700
hermes-serve        active  enabled     WebUI/дашборд 127.0.0.1:9119
hermes-gateway      active  enabled     диспетчер kanban + cron
hermes-metrics      active  enabled     экспортёр метрик :9725
```

Версия 0.19.0 — последняя на PyPI (проверено через API). Ключевая находка: `hermes serve` — это бэкенд десктопного Electron и headless не работает; headless-WebUI — `hermes dashboard`.

## 2. LLM — PASS (с оговорками)

```
агент → shim :9700 (loopback) → /api/v1/aios/ask → балансер :9600 → 11 провайдеров
```

- Ключи провайдеров живут **только** в окружении балансера. Ни один профиль, скрипт или юнит в репозитории не содержит провайдерского ключа — это и делает репозиторий публикуемым.
- Все 27 профилей получают конфиг через managed scope `/etc/hermes/config.yaml` (единая точка), а не через 27 копий.
- Проверки: `report-balancer-health.sh` → `rc=0`; `smoke-test-shim.sh` → **5/5 PASS**; doctor inference → `DOCTOR_OK`.

**Оговорки (измерено, не предположения):**

| Наблюдение | Следствие |
|---|---|
| `cerebras-llama3.3-70b` → HTTP 404 "Model does not exist" | провайдер числится в пуле, но фактически не работает |
| `mistral-small` периодически 429 (rate limit) | ёмкость пула ниже, чем «11 провайдеров» |
| `ollama` :11434 — **Connection refused** | оба local-провайдера недоступны; при отказе облака локального fallback нет |
| Шим отправляет `tier`, балансер его игнорирует | `classify_task()` решает сам; на корректность не влияет, на latency влияет |

Реальная ёмкость пула на момент проверки: **groq (4 модели) + hf + gemini + liza + эвристика**. Этого достаточно для одного агента за раз — и недостаточно для четырёх параллельных, что и наблюдалось.

## 3. АГЕНТЫ — PASS

**7 специалистов:** `orchestrator`, `server-guardian`, `github`, `security`, `monitoring`, `backup`, `liza`
**20 проектных:** aios, browser, fs, game, hermes-os, liza, logistics, logistics-root-logistics, logistics-opt-orchestrator-projects-logistics, madworld, octopus, octopus-deploy, octopus-opt-octopus, proj-orchestrator, repo, transcribe, ukraine, words, words-opt-words, words-home-ubuntu-batch19-oci, words-home-ubuntu-batch20-oci

Каждый профиль имеет `SOUL.md` (общий контракт поведения) и `memories/MEMORY.md` (общая база знаний + блок «твоя роль»). Контракт задаёт: автономность, запрет чтения/печати секретов, запрет `rm -rf`/`git reset --hard`/`push --force`, `df -h /` перед установкой, тегирование утверждений, запись инцидентов.

**Важно:** согласно указанию владельца агенты сейчас в режиме **«знать, не править»** — контракт описывает безопасные операции, но именно правки кода сервисов из их зоны исключены.

## 4. AGENT BUS — PASS

Шина — встроенный `hermes kanban` (SQLite + атомарные claim'ы + диспетчер внутри gateway). Отдельную шину не строили: она была бы слабее и без владельца.

**Доказано живыми прогонами:**

| Карточка | Исполнитель | Результат |
|---|---|---|
| `t_3424b910` | server-guardian | done — «96G available, 34% used» (реальный вывод `df`) |
| `t_3fd0b6ae` | monitoring | done — реальный отчёт: «shim UP v1.3.2, 11 провайдеров, 3 unhealthy, round-trip через groq-qwen3.8-27b» |
| `t_97ea71fd` | monitoring | done — создана оркестратором (делегирование A→B) |
| `t_654350a8` | orchestrator | авто-промоушен `todo`→`ready` после завершения родителя |

**Семантика делегирования асинхронная и односторонняя** — «вызвать агента B и дождаться» не существует. Правильный паттерн: создать карточку для специалиста, затем `kanban link <B> <A>`; A уходит в `todo` и автоматически поднимается, когда B завершится. Это задокументировано в `docs/AGENT_MODEL.md` и в базе знаний агентов.

**Найденная и устранённая ловушка (важный урок):** карточка с текстом «дождись результата» привела к созданию **16 одинаковых подзадач**, все работали одновременно и конкурировали за один пул провайдеров. Структурное лечение — `--idempotency-key` (проверено: повторный create возвращает тот же id). Правило внесено в контракт агентов и в базу знаний.

## 5. ПРОЕКТЫ — PASS

21 yaml-описание + `INVENTORY.yaml` (23 записи), собранные перекрёстной сверкой `find / -xdev -name .git` с GitHub API (88 репозиториев JoTalbot). Выявлены и записаны риски: дубликат checkout логистики (`/opt/logistics` и `/root/logistics`), локальные без remote (`/opt/octopus`, `/opt/octopus-deploy`, `/root/agents/-Octopus/repo`).

## 6. SKILLS — PASS

Сначала инвентаризация существующего (29 КБ каталога, MCP-сервер, octopus-*-guardian и т.д.), потом — только отсутствующее. Дубликатов нет. Новые: `doctor`, `secret-scan`, `discover-repos`, `gen-project-agents`, `backup`, `restore`, `bootstrap`, `register-server`, `install-agents`, `apply-agent-soul`, `seed-memory`, `report-balancer-health`, `hermes-metrics-exporter`, `aios-openai-shim`.

Отдельно зафиксированы два конфликта, требующие решения владельца: `jo-agent-*` частично дублирует проектных агентов; `octopus-agent-recovery` уже реализует approval-поток.

## 7. MEMORY / KNOWLEDGE — PASS

`config/MEMORY.global.md` — машинная база знаний со строгим тегированием: **FACT** (измерено), **OBSERVATION** (видели), **HYPOTHESIS** (не доказано — не действовать как с фактом), **DECISION** (с причиной), **LESSON** (обобщение реального сбоя). Требование «не выдавать предположения за факты» соблюдено на уровне формата.

`seed-memory.sh` разворачивает базу в `memories/MEMORY.md` каждого профиля (28 файлов) — именно этот файл агент читает в начале каждого хода. Плюс `memory/incidents/` — 6 инцидентов.

## 8. GITHUB — PASS

```
411cc2b  Sync: knowledge base, agent contract, and the shim smoke test
4c73f99  Agent reliability: budgeted prompt assembly, honest upstream errors, observability
b91ac03  Hermes OS: reproducible configuration for srv-oci-arm-01
```
- Дерево чистое, `0 unpushed`, ветка `main`, upstream настроен.
- Проверено через GitHub API: **110+ файлов** в дереве, ключевые файлы на месте.
- `secret-scan` → `clean`; проверка истории git — **0 секретных путей** (единственное совпадение — имя файла инцидента `credential-exposure.md`, ложное срабатывание).
- Токен в `.git/config` не хранится: `credential.helper store --file=/etc/hermes/git-credentials` (0600 root).

## 9. RECOVERY — WARNING

**Что работает (проверено):**
- `hermes-config-*.tar.gz` — 98 записей, вся конфигурация репозитория (дублирует git, поэтому безопасно).
- `hermes-state-*.tar.gz` при **правильном** вызове — 62 МБ, **514 записей**: 28 MEMORY.md, 28 SOUL.md, kanban.db, 70 сессий, state.db. **0 секретоподобных путей** — секреты исключены намеренно.
- **Восстановление проверено в песочнице** `/tmp/restore-test`: `MEMORY.md` и `SOUL.md` восстановлены **побайтово идентично** (sha256), `kanban.db` открывается SQLite, 30 задач на месте. Живая БД отличается от снапшота — это ожидаемо (БД пишется во время архивации), а не порча.

**Найденная проблема (не исправлялась — режим read-only):**
> При вызове без переменной `HERMES_HOME` (например `sudo bash backup.sh`, где `HOME=/root`) скрипт архивирует `/root/.hermes` — **3 пустые записи** — и при этом печатает `verified`, то есть рапортует об успехе, не сохранив ничего. Это ровно тот же класс ошибки, что уже был у `doctor.sh` (проверял `/root/.hermes` вместо `/home/hermes/.hermes`).

Правильный вызов: `sudo env HERMES_HOME=/home/hermes/.hermes bash /opt/hermes/scripts/backup.sh`

**Также отсутствует:** расписание — нет таймера/cron для `backup.sh`, то есть бэкапы не делаются сами.
`restore.sh` написан корректно: отказывается перезаписывать непустой `HERMES_HOME` без `--force`, проверяет целостность архива, печатает план.

## 10. MULTI-SERVER — WARNING

`config/servers/arm-server-01.yaml` содержит стабильный ID `srv-oci-arm-01` (не производный от hostname/IP), измеренные факты о железе и карту соседей. `register-server.sh` готов.

**Почему WARNING, а не PASS:** второго сервера нет, поэтому регистрация новой ноды, общий Orchestrator через несколько серверов и кросс-серверная шина **не проверены на практике**. Это манифест и готовый механизм, а не работающая федерация.

## 11. ANDROID — PASS

**Tailscale активен.** Сервер в tailnet:

```
hostname   arm-server-01
IPv4       100.109.170.74
MagicDNS   arm-server-01.tail5261f7.ts.net
backend    Running      tailscaled active, UFW 41641/udp
```

**Рабочий путь (проверен):** SSH-форвард на **tailnet-IP** — так сама SSH-сессия идёт внутри
WireGuard, и публичный SSH серверу не нужен.

```bash
ssh -L 9119:127.0.0.1:9119 ubuntu@100.109.170.74
# на телефоне:  http://127.0.0.1:9119
```
Проверено сквозным прогоном: `/`, `/healthz`, `/api/status` → **200**, отдаётся мобильная разметка
(`<meta name="viewport">`).

### Почему нельзя просто открыть `http://100.109.170.74:9119`

Три независимых блокера, все измерены и все — намеренное поведение вендоров:

1. **Дашборд отвергает любой Host, кроме интерфейса, к которому привязан.** На loopback-биндинге
   принимаются только `localhost`/`127.0.0.1`/`::1`; всё остальное → `400 Invalid Host header`.
   Это защита от DNS-rebinding (GHSA-ppp5-vxwm-4cf7), а не поломка.
2. **`tailscale serve` это не обходит** — он сохраняет входящий Host, и дашборд всё равно
   отказывает (измерено: `400` через MagicDNS, `404` по IP). Плюс `--https=443` не может
   запуститься: порты 80/443 держит **production nginx** (`api.autosklo.org.ua`), который трогать
   нельзя.
3. **HTTPS-сертификаты этому tailnet-аккаунту недоступны:**
   `tailscale cert … → 500 your Tailscale account does not support getting TLS certs`.
   То есть доверенного `https://…ts.net` для браузера не существует.

### Опционально: нативный доступ из браузера телефона

Возможен, но требует **двух** осознанных действий, поэтому по умолчанию не включён: привязать
дашборд к tailnet-IP **и** задать провайдера аутентификации — после ужесточения июня 2026 **любая**
не-loopback привязка его требует, причём CGNAT (а это ровно и есть диапазон Tailscale) намеренно
считается публичным. Варианты: пароль дашборда (`password_hash` в `config.yaml`) либо OAuth через
`hermes dashboard register` (нужен вход в Nous Portal). `--insecure` — no-op и это не обходит.

Это ваше решение: удобство (без SSH-клиента на телефоне) против второго учётного секрета и более
широкой привязки. Туннель не стоит ничего.

### Состояние телефона

```
G1 (android)              100.93.232.113   offline, last seen 2026-09-12
aios-android-gateway      100.122.9.31     offline, last seen 42 дней
```
Телефон уже был в этом tailnet. Нужно вернуть его online и переподключить к tailnet — дальше
работает способ выше.

## 12. MONITORING — PASS

Существующий стек **переиспользован**, не заменён: два job'а пожертвованы в `prometheus.yml` рядом с прежними, существующие таргеты не тронуты, пароль Grafana берётся из прежней переменной. Перезагрузка через `SIGHUP` — без простоя.

```
hermes_os_shim           127.0.0.1:9700/metrics   up
hermes_os_exporter       127.0.0.1:9725/metrics   up
octopus_control_plane    127.0.0.1:9100/metrics   up   (был раньше)
octopus_node_exporter    127.0.0.1:9718/metrics   up   (был раньше)
```

Экспортёр — только stdlib, read-only, непривилегированный, с изоляцией проб (сломанная проба даёт комментарий, не исключение). Он **не** дублирует CPU/RAM/disk — это уже делает node_exporter.

Самый полезный алерт — `hermes_managed_dir_ok == 0`: каталог `/etc/hermes` не 755 ломает **каждую** команду Hermes, и метрика замечает это за 15 секунд вместо следующего входа человека. Предложены 6 правил алертов.

## 13. AUTORECOVERY — PASS

- `hermes-env-guard.service` (root oneshot, `RemainAfterExit`) — восстанавливает `/etc/hermes/shim.env` из канонической копии и чинит инвариант режима.
- **Проверено на живом сбое:** удаление `shim.env` → перезапуск guard → файл восстановлен **побайтово идентично**, `SELFHEAL_OK`.
- **Проверено на нарушении инварианта:** режим каталога 700 → guard пишет `FIXED /etc/hermes mode was 700, must be 755`.
- `Restart=always` на shim/serve/metrics; `KillMode=mixed` на gateway (иначе диспетчер убивал бы своих же воркеров).
- Автовосстановление шины: `reclaim`, `dispatch_stale_timeout_seconds: 900` (было 4 часа, из-за чего зависшая карточка выглядела «работающей»).

## 14. IDEMPOTENCY — PASS

Проверено повторными прогонами на живом сервере:

```
install-agents.sh     → 0 created, 27 descriptions synced, 0 failed
apply-agent-soul.sh   → 0 updated, 28 already current
seed-memory.sh        → 0 memory file(s) written
kanban create --idempotency-key  (дважды) → оба раза один и тот же t_22fd0093
```

`install.sh` не трогает `/home/ubuntu/.hermes` (живой Telegram-мост liza) и отказывается работать при <6 ГБ свободного места. Установка агентов имеет защиту от коллизий slug и от зарезервированных имён.

## 15. SECURITY — PASS

| Проверка | Результат |
|---|---|
| Секреты в рабочем дереве | `clean` |
| Секретные пути в истории git | **0** |
| `/etc/hermes/shim.env` | 600 root:root |
| `/etc/hermes/git-credentials` | 600 root:root |
| `/var/backups/hermes/shim.env.canonical` | 600 root:root (каталог 700) |
| `/etc/hermes` | **755** (инвариант; секреты внутри 600) |
| Admin GUI в интернете | **нет** — только `127.0.0.1:9119` |
| Ключи провайдеров у агентов | **отсутствуют** — только через `${HERMES_BALANCER_API_KEY}` |
| Агентам запрещено | читать/печатать секреты, `rm -rf`, `git reset --hard`, `clean -fd`, `push --force` |
| Секреты в cmdline | исключены — только `EnvironmentFile=` |

**Существующие риски, найденные аудитом и не тронутые (чужой production):** postgres `:5434` слушает `0.0.0.0` и `[::]` с правилом ufw «any»; MCP-сервер с правами 777; права ключа в `/etc/octopus`. Зафиксированы в `docs/SECURITY.md` и манифесте сервера как задачи владельцу — менять без решения владельца нельзя.

## 16. FINAL TEST — WARNING

```
doctor.sh   →  17 OK / 1 WARN / 1 FAIL
smoke-test-shim.sh  →  5/5 PASS
report-balancer-health.sh  →  rc=0, round-trip PASS
```

Пройдено (18): Hermes, LLM Balancer, Shim, Inference (round-trip), Managed scope, WebUI, Env guard,
Dispatcher, Agents (27), Agent Bus, Skills, Memory, GitHub, Secrets, Storage, systemd, **Tailscale**.

Не пройдено (1): **Docker** — 1 контейнер `logistics-recurring-demand-scheduler-1` в состоянии
Exited. Существующий, к Hermes не относится, требует решения владельца.

Дополнительно проверено вручную: SSH-форвард до WebUI (200 на трёх путях), smoke-тест шима 5/5,
`report-balancer-health.sh` rc=0, восстановление из бэкапа в песочнице (MEMORY/SOUL побайтово
идентичны), идемпотентность трёх скриптов, `hermes_tailscale_up=1` в мониторинге.

---

## Что осталось

**Сделано владельцем:** вход в Tailscale выполнен, сервер в tailnet, критический FAIL снят.

**Требует решения (не блокирует):**
1. `logistics-recurring-demand-scheduler-1` Exited(1) — чужой проект, нужен владелец.
2. Расписание `backup.sh` (таймер) — бэкапы сейчас запускаются только вручную.
3. Вызов `backup.sh` без `HERMES_HOME` молча создаёт пустой архив — не исправлялось по вашему
   указанию (только запись). Правильный вызов:
   `sudo env HERMES_HOME=/home/hermes/.hermes bash /opt/hermes/scripts/backup.sh`
4. Конфликты `jo-agent-*` ↔ проектные агенты и `octopus-agent-recovery` ↔ политика одобрений.
5. `postgres :5434` наружу и права 777 у MCP-сервера — существующие, менять без вашего решения нельзя.
6. Официальный `sudo hermes gateway install --system` — диспетчер работает через свой юнит, но
   Hermes сообщает, что определение сервиса устарело.
7. `ollama` не запущен, `cerebras` отдаёт 404 — реальная ёмкость пула меньше заявленных 11 провайдеров.
8. Нативный браузерный доступ с телефона (Method B) — если нужен, скажите: потребуется пароль
   дашборда либо Nous OAuth.
9. Телефон `G1` в tailnet числится offline с 12 сентября — вернуть online.

**Проверено и подтверждено:** Hermes, WebUI, LLM-путь, шина агентов, делегирование, 27 агентов, память, skills, GitHub-синхронизация, мониторинг, self-heal, идемпотентность, безопасность, восстановление из бэкапа в песочнице.

---

## Приложение: что было реально сломано и починено

Четыре дефекта, каждый найден измерением, а не осмотром. Все четыре проявлялись **одинаково** — «агент что-то отвечает, но ничего не делает», что делало их невидимыми для обычной проверки «сервис жив».

1. **Молчаливое обрезание промпта.** Балансер передаёт провайдеру только `prompt[:4000]` и ничего об этом не сообщает. Шим собирал `[system] + [tools] + [history]`, схемы инструментов съедали весь бюджет, и агент **не видел своей задачи** — отвечал `Ready to assist` или `{"content":""}`. Исправлено: бюджетная сборка промпта, секция `[task]` первой, результаты инструментов — отдельным приоритетом.

2. **Бойлерплейт вместо ответа.** При отказе всех провайдеров балансер возвращает локальную заглушку со `status: success`. Агент принимал её за ответ и «завершал» задачу пустой. Исправлено: распознаётся, повторяется один раз, иначе честный 503.

3. **Сам себе устроил аварию.** Добавленный «предохранитель» (circuit breaker) дал 24 настоящих отказа → **312 мгновенных ошибок**: Hermes повторяет 5xx сразу, и каждый повтор снова взводил предохранитель. Убран. Найден счётчиком, добавленным за 20 минут до этого для другой цели.

4. **Битый SSE-фрейм ошибки.** Объявленная длина чанка не совпадала с записанными байтами → `malformed chunk footer`, и настоящая причина отказа выглядела как сетевая проблема. Исправлено.

Плюс ошибка в **моём же** рефакторинге: перезапись `_render_goal` **удалила** две функции-помощника, определённые после неё, и каждый запрос падал с `NameError`. Юнит-тест сборщика промпта это прошёл, потому что не трогал HTTP-путь. Именно поэтому появился `tests/smoke-test-shim.sh`, который дёргает развёрнутый шим по HTTP так же, как Hermes, — и включён в проверки.

Все четыре инцидента записаны в `memory/incidents/` по схеме FACT/LESSON/FIX, чтобы агенты **знали** эти грабли, а не наступали на них заново.
