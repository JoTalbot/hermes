# FINAL REPORT — 2026-09-17 (четвёртая волна: память → алерты → проектные действия → дрилл)

**СТАТУС: READY** (15 PASS · **0 FAIL** · **1 WARNING**: MULTI-SERVER — федерация проверена на шинных узлах, второго физического сервера нет) · узел `arm-server-01` (129.213.177.56), Ubuntu 24.04.4 aarch64, 4 CPU, 23.9 GiB
**Коммиты волны:** `5713e4b`, `3881de1`, `07771af`, `75a5a75`, `8311a2a` (все запушены, дерево чистое)
**Тесты:** `tests/run.sh` **139 passed · 0 failed · 0 skipped** · `agents-selftest` **51/0** · secret-scan clean
**Doctor:** DEGRADED (1 WARNING — чужой контейнер `logistics-recurring-demand-scheduler-1` exited)

## 16 подсистем: PASS / FAIL / WARNING

| № | Подсистема | Итог | Что измерено сейчас |
|---|---|---|---|
| 1 | **HERMES** | ✅ PASS | 9 юнитов active: nats, agents, bus-bridge, telegram-inbox, gateway, shim, serve, metrics, **alert-poller**; `hermes-serve` 200, dashboard за паролем |
| 2 | **LLM** | ✅ PASS | Шим `:9700` — 6 тиров (`fast/reason/code/long/local/auto`); агенты ключей не держат; `ask` отвечает (`hermes-reason`, 1.3 с); политика моделей проверена установщиком (sha256 `acb2a140eaf9`) |
| 3 | **АГЕНТЫ** | ✅ PASS | **27 агентов** (6 специалистов + 21 проектный), **151 обработчик**, 27 чек-скриптов; у каждого проектного агента появился `run` (tests/build/lint/logs/deploy-check) |
| 4 | **AGENT BUS** | ✅ PASS | 3 узла на шине (`arm-server-01` msgs=467, `node-arm-02`, `node-arm-03`); задачи → результат → Telegram проверено живьём; обрезка длинных отчётов заменена доставкой `.txt` документом |
| 5 | **ПРОЕКТЫ** | ✅ PASS | 21 проектный агент, 20 каталогов на диске, `hermes_projects_wired 21`; ложные «проект исчез» устранены (tri-state метрика) |
| 6 | **SKILLS** | ✅ PASS | 12 `SKILL.md` в реестре репозитория; дубликатов и неограниченных прав нет |
| 7 | **MEMORY/KNOWLEDGE** | ✅ PASS | Память с FACT/OBSERVATION/HYPOTHESIS/DECISION/LESSON + инциденты 24–33 этой волны; `#knowledge` и доски пишутся |
| 8 | **GITHUB** | ✅ PASS | 5 коммитов волны запушены, дерево чистое, unpushed = 0, secret-scan clean |
| 9 | **RECOVERY** | ✅ PASS | Бэкап теперь = состояние (568 записей, 71 MiB) + **конфиг узла** (6 файлов) + config; дрилл на `node-arm-03`: 222 файла, 28 профилей, `restore: PLAUSIBLE`, `wired 27 agent config(s)` |
| 10 | **MULTI-SERVER** | ⚠️ WARNING | 3 узла живы (`node-arm-02/03` — контейнерные узлы шины, не отдельные машины); кросс-узельная доставка проверена. Честная оговорка: второй физический сервер отсутствует, поэтому «потеря сервера» проверена не на железе |
| 11 | **ANDROID** | ✅ PASS | Control Plane через Telegram (6 кнопок) и GUI `http://129.213.177.56:9119/` за паролем; тяжёлое исполняется на сервере |
| 12 | **MONITORING** | ✅ PASS | 16 правил в Prometheus (было 10), **1 firing — истинный** (`liza`), 4 новых правила памяти; хост-метрики `mem 33.4 % / swap 59.7 % / load 1.00/ядро` |
| 13 | **AUTORECOVERY** | ✅ PASS | `OOMScoreAdjust` активен (`oom_score 666 → 134` у шины и агентов), лимиты памяти заданы; `Restart=always`; self-heal инвариантов не трогали |
| 14 | **IDEMPOTENCY** | ✅ PASS | Повторные установки: `уже есть` / `keeping existing` (в дрилле allowlist и tg-offset не перезаписаны); `install-protection.sh --check` = PROTECTION: OK, `install-alerting.sh --check` = ALERTING: OK |
| 15 | **SECURITY** | ✅ PASS | Секретов в git нет; права 0600/0755; действия агентов — фиксированные глаголы над проверенными именами (не shell); у проектного запуска — белый список + цитирование, `eval` отсутствует; принятый риск: 9119 без TLS (решение владельца) |
| 16 | **FINAL TEST** | ✅ PASS | `139/0/0` + `51/0`; живые проверки в гейтах [13]/[14] не скипаются; дрилл восстановления пройден; алерт доставлен владельцу (message_id=176) |

## Что сделано по согласованному порядку 1→4

**1. Защита памяти (от OOM).** Измерено: `octopus-browser-chromium` держал 16.6 из 23.4 GiB, swap 99 %, свободно 3.4 GiB, а юниты Hermes шли с `OOMScoreAdjust=0` и `MemoryMax=infinity` — ядро убивало шину наравне с вкладкой браузера.
Сделано: `scripts/install-protection.sh` (idempotent, `--check`, `--revert`) — 8 юнитов с приоритетом (`-800…-600`) и потолками памяти (4× от измеренного); экспортёр получил `probe_host_pressure` (RAM/swap/load/OOM-score процесса); 4 новых правила. Результат: `oom_score 666 → 134`, `mem 84 % → 33 %`, всё в метриках. Чужие контейнеры **не тронуты** — лимит для браузера ждёт вашего «да» (команда напечатана установщиком).

**2. Алерты → Telegram.** Правил 10 и 5 firing, но Alertmanager не стоял: алерты уходили в тишину. Сделано: поллер `scripts/hermes-alert-poller.py` (группировка по правилу, дедуп через `alert-state.json`, повтор ≤ раз в 6 ч, отдельное сообщение о закрытии, подсказка «что делать» в каждом), `install-alerting.sh` (+`--check`, `--test`), длинные отчёты — **`.txt` документом** вместо обрезки 1200 знаков и пути на сервере (живая проверка: `telegram: sent document proj-hermes-os-run-….log (2 KiB)`).
Побочно найдено и исправлено два источника лжи: ложные `HermesProjectTreeMissing` (экспортёр не видел `/home/ubuntu` — «не вижу» выдавалось за «нет») и фильтр, который глушил настоящий отчёт из-за слова `selftest` в выводе тестов.

**3. Проектные агенты — реальные действия.** `agents/checks/project-run.sh`: команда берётся из маркеров самого проекта (цель Makefile, скрипт `package.json`, pytest-конфиг, `tests/run.sh`, `go.mod`, `Cargo.toml`, compose-файл, объявленный юнит, `*.log`), иначе — честный отказ. Живьём: `прогони тесты в hermes-os` → `bash tests/run.sh`, 72 с, exit 0, отчёт документом; `покажи логи octopus` → журнал юнита проекта; `проверь деплой octopus` → **dry-run**, ничего не разворачивал; `прогони тесты в browser` → `make test` (реальный exit 2 — то есть настоящая правда проекта, а не вежливое «всё ок»). Чужие проекты не менялись: `deploy-check` только показывает план.

**4. Дрилл restore + дыры установки.** Дрилл на `node-arm-03` вскрыл четыре молчаливых дефекта: (а) `restore.sh` не экспортировал `REPO_DIR` — шаг установки выполнялся кодом самого узла, то есть «дрилл на новом коде» проверял старый; (б) `wire-agents.sh` падал на отсутствии PyYAML и **молча** пропускал все 21 проектных агента (`wired 0`); (в) `tar … | head` под `pipefail` обрывал восстановление без сообщения; (г) бэкап не содержал конфиг узла — восстановленный узел вернулся бы **без allowlist Telegram**, то есть бот игнорировал бы владельца. Все четыре закрыты, плюс: истечение просроченных задач (`pending.json` больше не растёт вечно, `sweep_pending` + алерт `HermesPendingOverdue`), logrotate для журналов агентов и шины (33 файла / 136K без ротации), `config/models.yaml` теперь проверяется установщиками (раньше узел молча жил на встроенных умолчаниях).

**Найдено и исправлено в волне: 10 ошибок** (incidents 24–33): generic-отчёт по именованному объекту, отсутствие действий, ложный алерт из-за прав экспортёра, `pipefail`+`grep -q`/`head` (трижды), фильтр `selftest`, `ARG_ACTION`/`ARG_WHAT` под разными именами, `mark test` ≠ makedev, неразрешимый PyYAML, неэкспортированный `REPO_DIR`, бэкап без конфига узла.

## Количества

- **Серверы:** 3 (`arm-server-01` + шинные узлы `node-arm-02`, `node-arm-03`)
- **Агенты:** 27 (6 специалистов + 21 проектный), **обработчиков 151**, чек-скриптов 27
- **Проекты:** 21 под наблюдением (20 каталогов на диске)
- **Skills:** 12 `SKILL.md` (10 категорий каталога `skills/`)
- **Правила алертов:** 16 (из них 1 горит — истинный)

## Остатки (нужны решения владельца)

1. **`liza`** — единственный горящий алерт и он настоящий: репозиторий `JoTalbot/liza` есть на GitHub, локальную копию `/home/ubuntu/liza` снесли в прошлом дрилле (`DISASTER_RECOVERY.md`). Скажите «клонируй liza» — склонирую заново; или «убери агента liza» — уберу.
2. **Лимит памяти `octopus-browser-chromium`** — сейчас коробка свободна (mem 33 %), но браузер снова может съесть 16 GiB. Команда готова: `docker update --memory 8g --memory-swap 8g octopus-browser-chromium` — чужой проект, делаю только после вашего «да».
3. **Swap 59.7 %** — при 33 % занятой RAM это не срочно, но это тот же симптом нехватки реальной памяти у соседних проектов.
4. `logistics-recurring-demand-scheduler-1` (чужой контейнер) — exited, не трогаю (единственный WARNING доктора).

## Следующие улучшения (предлагаю, в порядке пользы)

1. **Клонирование/восстановление проектов из чата** как управляемое действие (`clone-project <repo>`) — закроет класс «проект есть, каталога нет» и пункт 1 остатков.
2. **Память агентов о результатах прогонов**: сохранять «тесты падали 3 раза подряд по этой же причине» в `memory/incidents`, чтобы `ask` отвечал с историей, а не с нуля.
3. **Alertmanager-совместимый webhook** (на случай, если в кластер добавят чужие алерты) — сейчас поллер достаточно прост, но webhook снимет зависимость от API-обхода.
4. **Плановая ротация и проверка бэкапа в Telegram**: раз в сутки «бэкап 71 MiB, проверен, восстановление PLAUSIBLE» — чтобы RECOVERY не зависел от того, что кто-то заглянет в `/var/backups`.
5. **Второй настоящий сервер** (не контейнер) — MULTI-SERVER останется «PASS с оговоркой», пока федерация живёт только на шинных узлах одного хоста.
6. **Метрика «сколько владелец ждал ответа»** (p50/p95 по задачам) — прямое измерение того, что для вас важно в чате.

## Batch after the report (same day, one pass)

The owner asked for the whole improvement plan at once. Delivered on the same node, with gates:

1. **Agents remember their runs** — `history.jsonl` + `agents/checks/history.sh`, model tier and
   fallback per `ask`, `HermesAgentFailing` alert. Before: an agent failing on every run looked healthy.
2. **Evidence in reports** — `report_proof` / `report_unknown`; the class of bug that produced 14
   false "clean tree" reports is now closed structurally.
3. **Project journal** — every project has a JOURNAL.md; status shows the last five events.
4. **Lookup by name** — «что там с octopus-multisync» answers about that unit, not about the host.
5. **Scoped actions with confirmation** — backup/cleanup refuse until the owner says «подтверждаю …»;
   `verify-action.sh` re-checks the result afterwards.
6. **Model telemetry** — tiers, fallbacks and latency per tier in metrics and in the history report.
7. **Priorities** — background runs cannot hold the owner's questions; long waits are announced.
8. **Daily digest 09:00** — first one delivered (message_id=187).
9. **Skills audit** — 260 SKILL.md inventoried: 4 duplicate titles, 12 full copies, none deleted.

Verification: `tests/run.sh` **194 passed · 0 failed · 0 skipped**, `agents-selftest` 51/0,
JOURNAL/DIGEST/GIT-SAFETY/PROTECTION/ALERTING all OK, wiring in sync (27 agents), 19 alert rules live.

Six real bugs were found and fixed on the way — the routing pattern `top` matching "oc**top**us",
`pgrep -f` matching the check's own process, the digest's alert section failing inside an f-string,
the digest importing the bus differently from the alert poller, two test-suite defects (relative paths
after other sections changed directory; a stub that claimed every unit existed).


## Batch 1–8 — owner's list, same day, third pass

Eight items, all eight shipped with gates; the last wave's numbers are superseded by the ones below.

| # | Item | Result on the node |
|---|---|---|
| 1 | container-guard | `CONTAINER-GUARD: OK` — 1 container checked, 0 drift, 0 restored; `docker update`, never a restart; timer 15 min |
| 2 | copy behind upstream | `hermes_project_behind`: `fs 641`, `transcribe 340`, `ukraine 273`, `game 238`, `logistics 228` (two paths), `madworld 26`, rest 0 — visible for the first time; rule `HermesProjectStaleCopy` |
| 3 | backup freshness | `hermes_backup_count 5` · `age 2.57 h` · `bytes 341 846 923`; rule `HermesBackupStale` (>48 h critical) |
| 4 | wiring drift | `WIRING-GUARD: OK` — 0 drift, timer 30 min, `hermes_wiring_drift 0` |
| 5 | clone/pull from chat | guarded verbs `clone-project` / `pull-project` (`JoTalbot` only, `/opt` and `/home/ubuntu` only, ff-only, confirmation for pull) |
| 6 | ratings + mini-eval | 👍/👎 under every reply → `feedback.jsonl`; `eval-agents.sh` **20 из 20** (was 17/20 on the first run) |
| 7 | journals | `journal-top`: 482.3 MB used, ceiling 500 MB, loudest `octopus.service` 12.7 MiB + 5×`octopus-child@` 12.5 MiB |
| 8 | skills | 261 SKILL.md audited; plan written to `docs/SKILLS-TODO.md`; **nothing deleted** |

**Tests:** `tests/run.sh` **234 passed · 0 failed · 0 skipped** (gate [17] = 30 static + 3 live).
**Alert rules:** 25 live in Prometheus (6 new: container drift, guard stale, wiring drift, project
stale copy, backup stale, journal growing).
**Status:** READY — 15 PASS · 0 FAIL · 1 WARNING (MULTI-SERVER: no second physical host).

**Four silent defects found by running the batch on the node and fixed:** the git-safety installer
checked one user while the metric exporter runs as another (staleness metrics empty for every copy
but one); the backup directory was traversable (`--x`) but not listable for the exporter, so
`hermes_backup_count` reported 0 while 5 backups and 341 MB sat there; the routing alias «hermes»
turned «статус hermes» (the stack) into a question about the `hermes-os` project; and the ratings
report printed no `ИТОГ` until the first rating existed, which made the live gate blind to the empty
state (the check now runs on a fixture and on the node's file).

**Still open, waiting for the owner:** rating buttons have not been pressed in Telegram yet (the
code path is verified on the node: both 👍 and 👎 record the question and answer and clear the tag);
the 12 skills of ours declare no capability/bounds (`docs/SKILLS-TODO.md`); items 9 (TLS on 9119)
and 10 (second server) were not part of this batch.

**Live proof of the last two items** (after the fixes were committed as `d464024` and the working
tree was clean): the owner's own question was posted on the bus exactly as the Telegram bridge does
(`hermes-bus post --channel orchestrator --kind task "@orchestrator статус hermes"`) and the run
history recorded `agent=server-guardian · handler=hermes` — the stack question is answered by the
host agent, not by the `hermes-os` project agent, which is what the old alias did. Rating buttons
were sent to the owner in Telegram (message_id=210) so the last live check — a real tap — can be
made by hand.

## LLM check of the agents (same day): which model really answers

The owner asked for a check of the agents' LLM path. Result: the path works, the routing does not.

* **Works:** `hermes-shim` on 127.0.0.1:9700 answers (200 on `/v1/models`), the Octopus AIOS
  balancer is healthy with 11 providers and all of them `healthy`, agents name a TIER and hold no
  provider keys (`/etc/hermes/shim.env` 0600 root, the shim key in `/home/hermes/.hermes/config.yaml`
  600), live answers arrive in 0.3–1.7 s with no fallbacks in 24 h (2 model calls, 0 fallbacks,
  p95 1.7 s), and the deterministic handlers keep working without a model at all.
* **Does not work:** the AIOS bridge ignores the `tier` field — `{"tier":"reasoning"}` was answered
  by `tier=fast, provider=groq-gpt-oss-20b`; and the balancer's cache key has no tier in it, so the
  same prompt with `{"tier":"local"}` returned the cached cloud answer instead of a local model.
  The owner's rule "models by function, no loss of smartness" was therefore satisfied by accident:
  our escalation keywords coincide with the balancer's own classifier keywords, `hermes-local` is
  never honoured, and a cross-tier cache hit can serve the cheap model to a "smart" request.
* **Fixed:** the shim now reports and counts the tier/provider that actually answered, agents record
  it in `history.jsonl`, the exporter publishes `hermes_model_served_1h` and
  `hermes_model_tier_mismatch_1h`, the answer footer shows
  `модель hermes-reason · groq-gpt-oss-20b [fast] ⚠️ ответил не тот тир`, and gate [18] checks it
  statically and live. Measured after the fix on the live path: history record
  `tier=hermes-reason · served_tier=code · provider=groq-gpt-oss-20b · tier_mismatch=True`.
* **Open:** the real fix is a 2-line additive change in the AIOS bridge (another project) — waiting
  for the owner's decision.

**Lesson from the batch:** after deploying agent code the unit must be restarted (Python caches
imports at start); a fixed `routing.py` keeps answering by the old rules otherwise. `hermes-agents`
had been running since 06:01:27 while the fixed routing landed at 06:17:30.
