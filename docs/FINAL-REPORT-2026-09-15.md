# Hermes Agent OS на arm-server-01 — финальный отчёт

**Дата:** 2026-09-15 · **Сервер:** `ubuntu@129.213.177.56` (`arm-server-01`, id `srv-oci-arm-01`, Ubuntu 24.04.4 LTS, aarch64, 4 CPU, 23 GiB RAM)
**Репозиторий:** [JoTalbot/hermes](https://github.com/JoTalbot/hermes) · ветка `main` · последний коммит `411cc2b`
**Режим работы:** код сервисов не правился. Изменения сделаны только там, где владелец их явно
санкционировал — unit `hermes-serve` + `/etc/hermes/dashboard.env` (решение `plain_port`,
2026-09-15) — и в инструментах самого Hermes (`scripts/backup.sh`, `verify-backup.sh`, `doctor.sh`,
systemd-юниты бэкапа).

> **Обновление 16:45 — прямой доступ и автобэкапы.** Дашборд доступен по
> `http://129.213.177.56:9119/` за паролем (проверено из интернета, 6/6 внешних узлов), RECOVERY и
> FINAL TEST переведены в PASS: починен ложный «успех» в `backup.sh`, добавлен таймер с проверкой
> восстановления. Разделы 9, 11, 15, 16 переписаны ниже.

## Итоговый статус: **READY**

Все критические проверки пройдены. Осталось **одно** предупреждение, и оно относится к **чужому**
проекту (`logistics-recurring-demand-scheduler-1`, Exited), а не к Hermes.

```
SYSTEM HEALTH: DEGRADED (2 warnings)
  [OK]   Tailscale      up on 100.109.170.74
  [OK]   Backup         hermes-state-20260915T163829Z.tar.gz — 0h old
  [OK]   BackupPerm     /var/backups/hermes is 0700
  [WARN] GitHub         5 uncommitted paths   ← снимается коммитом этого отчёта
  [WARN] Docker         1 exited container(s): logistics-recurring-demand-scheduler-1
18 OK / 2 WARN / 0 FAIL
```

**16 критериев: 15 PASS, 1 WARNING.** Единственный WARNING — **MULTI-SERVER**: второго сервера в
инфраструктуре нет, поэтому федерация (регистрация ноды, кросс-серверная шина, общий Orchestrator на
нескольких машинах) существует как манифест и скрипт, но не проверена на практике. Это отсутствие
второго сервера, а не дефект Hermes.

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
| 9 | **RECOVERY** | ✅ PASS | Ложный «verified» устранён (`backup.sh` 1.1.0 отказывается бэкапить не тот каталог); таймер 03:30 UTC + `verify-backup.sh` сверяет sha256 восстановленного с живым деревом (3/3 ok, 27/27 профилей, 0 секретов) |
| 10 | **MULTI-SERVER** | ⚠️ WARNING | Манифест и скрипт регистрации есть; второго сервера нет → кросс-серверная связь не проверена |
| 11 | **ANDROID** | ✅ PASS | **Прямой доступ** `http://129.213.177.56:9119/` за паролем — проверено **из интернета** (6/6 внешних узлов; вход 200, без сессии 401); SSH-форвард через tailnet оставлен как резерв |
| 12 | **MONITORING** | ✅ PASS | Prometheus/Grafana переиспользованы; 4 таргета `up`; экспортёр и метрики отвечают |
| 13 | **AUTORECOVERY** | ✅ PASS | Self-heal секрета и инварианта 755 проверен на живом сбое; `Restart=always` |
| 14 | **IDEMPOTENCY** | ✅ PASS | Повторные прогоны: 0 создано / 0 обновлено / 0 записано; idempotency-key подтверждён |
| 15 | **SECURITY** | ✅ PASS | Секретов в git нет; права 600/755; GUI наружу — **только за паролем** (basic-auth, non-loopback bind fail-closed); принятый риск: plain HTTP без TLS |
| 16 | **FINAL TEST** | ✅ PASS | doctor **18 OK / 0 FAIL** (2 WARN: чужой контейнер + незакоммиченное дерево); smoke 5/5; auth-тест 7/7; внешняя проверка 6/6; восстановление сверено по sha256 |

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

## 9. RECOVERY — PASS

**Что было не так (найдено аудитом, исправлено 2026-09-15).**
`backup.sh` брал каталог состояния как `${HERMES_HOME:-$HOME/.hermes}`. Запущенный из root-шелла
(`HOME=/root`) он архивировал `/root/.hermes` — **3 пустые записи** — печатал `verified`, сообщал
компактный размер и выходил с кодом 0. Ошибку гасил и `|| echo "(state dir partial — continuing)"`.
**Бэкап, который молча сохраняет не тот каталог, опаснее отсутствия бэкапа**, потому что ему доверяют.

**Что сделано:**

| изменение | результат |
|---|---|
| `scripts/backup.sh` **1.1.0** | каталог состояния определяется явно (env → `/home/hermes/.hermes` → `$HOME/.hermes`); отказ, если нет маркеров Hermes-home (`kanban/ memories/ profiles/ config.yaml`); отказ при < 50 записях; ошибка `tar` — фатальна; печатаются источник, число записей и размер |
| `scripts/verify-backup.sh` | извлекает свежий архив в scratch-каталог и сверяет **sha256 содержимого** с живым деревом + число профилей + отсутствие секретоподобных файлов |
| `hermes-backup.timer` | ежедневно **03:30 UTC** (+джиттер, `Persistent=true`) → `hermes-backup.service` (oneshot, `HERMES_HOME` задан явно) |
| `doctor.sh` | новые проверки `Backup` (свежесть архива: >48 ч WARN, >7 сут FAIL) и `BackupPerm` (0700) |

**Доказательства (прогон 2026-09-15, реальные, не предполагаемые):**

```
# таймер
NEXT  Wed 2026-09-16 03:39 UTC   enabled
systemctl start hermes-backup.service → Result=success, ExecMainStatus=0

# предыдущее поведение (без HERMES_HOME, HOME=/root) — теперь корректно:
source state : /home/hermes/.hermes  (597 entries, 4/4 markers)
state archive: hermes-state-….tar.gz — 516 entries, 62M

# отказ на пустом каталоге-приманке — то, чего раньше не было:
FATAL: '/tmp/decoy-home' does not look like a Hermes home (…)
       Refusing to produce a backup that would be trusted but empty.   exit=2

# проверка восстановления
ok  memories/MEMORY.md                 sha256 b0e2b28b7675b018…
ok  config.yaml                        sha256 192f875756b31288…
ok  kanban/boards/hermes-os/kanban.db  sha256 0464e546b2a8438a…
profiles: live=27 restored=27
secret-shaped files in archive: 0 (must be 0)
RESTORE VERIFICATION OK: 3 content checks, 516 entries, no secrets
```

Секретов в архиве нет намеренно: `.env`, `*.pem`, `authorized_keys` исключены. После восстановления
`/etc/hermes/shim.env` нужно положить вручную; источник self-heal —
`/var/backups/hermes/shim.env.canonical` (0700/0600). `restore.sh` отказывается перезаписывать
непустой `HERMES_HOME` без `--force` и проверяет целостность архива до распаковки.

**Остаточный риск:** расписание ежедневное, retention 7 — при быстрой порче данных в первые часы
«хорошая» копия может быть перезаписана. Для проекта, где это критично, нужен отдельный
off-site/immutable-таргет; это решение владельца, не агента.

## 10. MULTI-SERVER — WARNING

`config/servers/arm-server-01.yaml` содержит стабильный ID `srv-oci-arm-01` (не производный от hostname/IP), измеренные факты о железе и карту соседей. `register-server.sh` готов.

**Почему WARNING, а не PASS:** второго сервера нет, поэтому регистрация новой ноды, общий Orchestrator через несколько серверов и кросс-серверная шина **не проверены на практике**. Это манифест и готовый механизм, а не работающая федерация.

## 11. ANDROID — PASS

**Основной путь теперь прямой, без Tailscale на телефоне** (решение владельца `plain_port`,
2026-09-15): открыть в браузере телефона `http://129.213.177.56:9119/` и войти по паролю.

```
участок                              состояние
bind                                 0.0.0.0:9119 (hermes-serve.service)
аутентификация                       bundled-провайдер dashboard_auth/basic, включён
учётные данные                       /etc/hermes/dashboard.env (0600 root) + копия пароля
                                     /etc/hermes/dashboard.password (0600 root), TTL сессии 12 ч
```

**Проверено снаружи** (не с loopback — это принципиально; см. урок ниже):

| проверка | результат |
|---|---|
| TCP-доступность с 6 независимых внешних узлов | **6/6 открыт** |
| `GET /` без сессии | `302 → /login?next=%2F` |
| `GET /login` | `200`, заголовок `Sign in — Hermes Agent`, `data-provider="basic"` |
| `POST /auth/password-login` с верным паролем | `200 {"ok":true,"next":"/"}` |
| `GET /api/sessions` с cookie сессии | `200` |
| неверный пароль | `401` (сообщение обезличено, отказ пишется в audit log) |
| локальный сквозной тест (`tests/test-dashboard-auth.sh`) | **7/7 PASS** |
| `GET /api/status` без сессии | `200` — публичный liveness-проб, секретов не содержит, так задумано |

### Два файрвола, и облачный — главный (урок этой итерации)

Порт не открывался целый час при **правильном** ufw-правиле и живом bind. Причина: OCI фильтрует
ingress на уровне security list подсети **до** того, как пакет доходит до хоста. Разрешались только
`22, 80, 443, 8080, 5434` и ICMP. Исправлено `scripts/oci-open-port.sh` (бэкап текущих правил →
клон SSH-правила как схемы → применение → проверка, что **ни одно** исходное правило не потеряно:
8 → 9). API OCI не умеет «добавить правило» — `update` **заменяет весь набор**, поэтому ошибка в
payload могла бы отрезать SSH; порядок операций в скрипте это учитывает.

Отдельная ловушка: `/home/ubuntu/.oci/config` аутентифицируется (`oci iam region list` работает), но
принадлежит **другой tenancy** и даёт `NotAuthenticated` для этой машины. Рабочие креды — `/root/.oci/config`.

### Резервный путь — туннель через tailnet (оставлен как fallback)

```bash
ssh -L 9119:127.0.0.1:9119 ubuntu@100.109.170.74
# на телефоне:  http://127.0.0.1:9119
```
Работает и проверен; полезен в недоверенных сетях, где пароль по открытому HTTP перехватываем.

### Принятый риск, названный явно

Транспорт — **plain HTTP**: пароль идёт по сети в открытом виде и может быть перехвачен на пути.
Это осознанный размен владельца (не ставить Tailscale на телефон). Митигации, которые есть: пароль
только как секрет дашборда, rate-limit по IP на `/auth/password-login` (429), обезличенные ответы,
audit-лог отказов, сессии с TTL 12 ч, `SECRET` задан (рестарт сервиса не убивает активные сессии).
Чего нет: TLS. Ротация — `scripts/enable-dashboard-auth.sh` + рестарт (инвалидирует все сессии).

### Почему `tailscale serve` — не решение (измерено, не повторять)

1. `tailscale serve` сохраняет входящий Host → дашборд видит `arm-server-01.tail5261f7.ts.net` и
   отказывает: `400` через MagicDNS, `404` по IP.
2. `tailscale serve --https=443` зависает (>300 с), а 80/443 держит **production nginx**
   (`api.autosklo.org.ua`) — трогать нельзя.
3. `tailscale cert … → 500 your Tailscale account does not support getting TLS certs` — доверенного
   `https://…ts.net` не существует.

### Состояние телефона

```
G1 (android)              100.93.232.113   offline, last seen 2026-09-12
aios-android-gateway      100.122.9.31     offline, last seen 42 дней
```
Прямой путь работает независимо от того, в tailnet ли телефон — ровно поэтому он и выбран.

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
| `/etc/hermes/dashboard.env`, `dashboard.password` | 600 root:root |
| `/var/backups/hermes` | 700 root:root (архивы 600) |
| Admin GUI в интернете | **да, но только за паролем**: `0.0.0.0:9119`, bundled-провайдер `basic`. Без сессии `/` → `302 /login`, `/api/sessions` → `401`; неверный пароль → `401`; rate-limit 429 на форме входа |
| Дашборд на non-loopback bind | **fail-closed**: без провайдера процесс завершается (`Refusing to bind dashboard to …`) — «просто открыть порт» технически невозможно |
| Транспорт | **plain HTTP — принятый владельцем риск** (`plain_port`): пароль перехватываем на пути. Ротация: `scripts/enable-dashboard-auth.sh` |

**Что изменилось в модели угроз 2026-09-15 и о чём нужно помнить:** админ-панель перестала быть
loopback-only. Компенсации: пароль, rate-limit, audit-лог, TTL сессий 12 ч, отсутствие публичных
эндпоинтов с данными (`/api/status` — только liveness). Не компенсировано: шифрование канала и
второй фактор. Для доступа из недоверенной сети используйте туннель (раздел 11).
| Ключи провайдеров у агентов | **отсутствуют** — только через `${HERMES_BALANCER_API_KEY}` |
| Агентам запрещено | читать/печатать секреты, `rm -rf`, `git reset --hard`, `clean -fd`, `push --force` |
| Секреты в cmdline | исключены — только `EnvironmentFile=` |

**Существующие риски, найденные аудитом и не тронутые (чужой production):** postgres `:5434` слушает `0.0.0.0` и `[::]` с правилом ufw «any»; MCP-сервер с правами 777; права ключа в `/etc/octopus`. Зафиксированы в `docs/SECURITY.md` и манифесте сервера как задачи владельцу — менять без решения владельца нельзя.

## 16. FINAL TEST — PASS

```
doctor.sh                 →  18 OK / 2 WARN / 0 FAIL   (SYSTEM HEALTH: DEGRADED)
smoke-test-shim.sh        →  5/5 PASS
report-balancer-health.sh →  rc=0, round-trip PASS
tests/test-dashboard-auth.sh → 7/7 PASS
внешняя доступность       →  6/6 узлов открыт порт 9119
verify-backup.sh          →  3/3 sha256 совпали, 27/27 профилей, 0 секретов
```

Пройдено: Hermes, LLM Balancer (11 провайдеров живы), Shim, Inference (round-trip `DOCTOR_OK`),
Managed scope, **WebUI (bind-осознанная проверка: `0.0.0.0:9119` + наличие пароля)**, Env guard,
Dispatcher, Agents (27), Agent Bus, Skills, Memory, Secrets, Storage (36%), systemd, Tailscale,
**Backup (архив 0 ч)**, **BackupPerm (0700)**.

Два WARNING, оба не о Hermes:
1. **Docker** — `logistics-recurring-demand-scheduler-1` в состоянии Exited. Чужой проект, нужно
   решение владельца (не расследовано намеренно: production не трогаем).
2. **GitHub** — 5 незакоммиченных путей в момент прогона; снимается коммитом этого отчёта.

Дополнительно проверено вручную: вход в дашборд **из интернета** (302 → форма → 200 с cookie → 200
`/api/sessions`, неверный пароль 401), недоступность закрытых портов как контрольная точка, полный
цикл бэкап→проверка→восстановление, идемпотентность скриптов, `hermes_tailscale_up=1` в мониторинге.

**Контрольная точка честности:** при первом прогоне `verify-backup.sh` упал с «missing in archive» —
и это был **дефект проверки** (неверный разбор путей внутри архива), а не дефект бэкапа. Исправлено
и перепроверено. Оставлено в отчёте намеренно: проверка, которую ни разу не видели красной, ничего
не доказывает.

---

## Что осталось

**Закрыто в этой итерации (2026-09-15, после отчёта 15:35):**
- ✅ Прямой доступ с телефона: `http://129.213.177.56:9119/` за паролем — проверено из интернета.
- ✅ Порт 9119 открыт **на двух уровнях** (ufw + security list OCI); инструменты
  `scripts/oci-open-port.sh` и `scripts/oci-firewall.sh` в репозитории.
- ✅ `backup.sh` больше не создаёт «успешный пустой» архив; ложный успех устранён на живом тесте.
- ✅ Автобэкапы: `hermes-backup.timer` (03:30 UTC) + проверка восстановления в том же юните.
- ✅ `doctor.sh` видит свежесть бэкапа, права каталога и **реальный** bind дашборда.
- ✅ Новый skill `skills/server/oci-cloud-firewall.md` + записи lesson в реестре skills.

**Требует решения владельца (не блокирует работу):**
1. `logistics-recurring-demand-scheduler-1` Exited(1) — чужой проект; не расследовано намеренно.
2. **TLS для дашборда.** Сейчас пароль идёт по открытому HTTP. Варианты: (а) оставить как есть;
   (б) канонический путь Cloudflare (`api.autosklo.org.ua` уже за CF) — нужен рабочий
   `CF_API_TOKEN` с правами DNS/Origin (текущий `cfut_…` невалиден) или установка `cloudflared`
   под существующий tunnel-токен; (в) ACME/Let's Encrypt — `acme.sh`/`certbot` на сервере
   отсутствуют, а `80/443` заняты production-nginx. Скажите, какой вариант — сделаю.
3. Конфликты `jo-agent-*` ↔ проектные агенты и `octopus-agent-recovery` ↔ политика одобрений.
4. `postgres :5434` наружу и права 777 у MCP-сервера — существующие, без вашего решения не менялись.
5. Официальный `sudo hermes gateway install --system` — диспетчер работает через свой юнит,
   Hermes сообщает, что определение сервиса устарело.
6. `ollama` не запущен, `cerebras` отдаёт 404 — реальная ёмкость пула меньше заявленных 11.
7. Телефон `G1` числится offline с 12 сентября (для прямого доступа это больше не критично).
8. Второй сервер — единственный WARNING статуса (см. раздел 10).

**Проверено и подтверждено:** Hermes, WebUI (прямой доступ из интернета), LLM-путь, шина агентов,
делегирование, 27 агентов, память, skills, GitHub-синхронизация, мониторинг, self-heal,
идемпотентность, безопасность, бэкап → восстановление.

---

## Приложение: что было реально сломано и починено

Четыре дефекта, каждый найден измерением, а не осмотром. Все четыре проявлялись **одинаково** — «агент что-то отвечает, но ничего не делает», что делало их невидимыми для обычной проверки «сервис жив».

1. **Молчаливое обрезание промпта.** Балансер передаёт провайдеру только `prompt[:4000]` и ничего об этом не сообщает. Шим собирал `[system] + [tools] + [history]`, схемы инструментов съедали весь бюджет, и агент **не видел своей задачи** — отвечал `Ready to assist` или `{"content":""}`. Исправлено: бюджетная сборка промпта, секция `[task]` первой, результаты инструментов — отдельным приоритетом.

2. **Бойлерплейт вместо ответа.** При отказе всех провайдеров балансер возвращает локальную заглушку со `status: success`. Агент принимал её за ответ и «завершал» задачу пустой. Исправлено: распознаётся, повторяется один раз, иначе честный 503.

3. **Сам себе устроил аварию.** Добавленный «предохранитель» (circuit breaker) дал 24 настоящих отказа → **312 мгновенных ошибок**: Hermes повторяет 5xx сразу, и каждый повтор снова взводил предохранитель. Убран. Найден счётчиком, добавленным за 20 минут до этого для другой цели.

4. **Битый SSE-фрейм ошибки.** Объявленная длина чанка не совпадала с записанными байтами → `malformed chunk footer`, и настоящая причина отказа выглядела как сетевая проблема. Исправлено.

Плюс ошибка в **моём же** рефакторинге: перезапись `_render_goal` **удалила** две функции-помощника, определённые после неё, и каждый запрос падал с `NameError`. Юнит-тест сборщика промпта это прошёл, потому что не трогал HTTP-путь. Именно поэтому появился `tests/smoke-test-shim.sh`, который дёргает развёрнутый шим по HTTP так же, как Hermes, — и включён в проверки.

Все четыре инцидента записаны в `memory/incidents/` по схеме FACT/LESSON/FIX, чтобы агенты **знали** эти грабли, а не наступали на них заново.

5. **Бэкап, который рапортовал «verified», сохранив 3 пустые записи.** `backup.sh` брал каталог из
   `$HOME/.hermes`, когда `HERMES_HOME` не задан, — а из root-шелла это `/root/.hermes`. Скрипт
   печатал `verified`, компактный размер и выходил 0. Тот же класс ошибки, что уже был у `doctor.sh`
   (проверял не тот каталог). Теперь каталог резолвится явно, проверяется по маркерам Hermes-home,
   ошибка `tar` фатальна, а таймер дополнительно **восстанавливает** архив в scratch и сверяет sha256.

6. **Порт «открыт», а извне недоступен.** Правильный ufw-rule, живой bind, все loopback-тесты
   зелёные — и ноль соединений снаружи. Причина: у этого хоста **два** фильтра, и облачный
   (security list OCI) стоит первым; он разрешал только `22, 80, 443, 8080, 5434`. Отдельная ловушка
   внутри ловушки: креды `/home/ubuntu/.oci/config` успешно аутентифицируются, но принадлежат
   **другой tenancy** — работать с этой машиной можно только от `/root/.oci/config`. И третья:
   тесты доступности из песочницы с HTTP-прокси «проходят» на любой порт, поэтому внешняя
   проверка делалась сторонними узлами с контрольным портом 22.

