#!/usr/bin/env python3
"""models.py — which model each agent uses, and how an agent asks it.

The owner's requirement, in one line: *prefer free/cheap models, but do not lose smartness
where smartness is the point.* The LLM Balancer already exposes tier aliases that map onto
its 11 provider keys (Groq / Cerebras / Gemini Flash / Mistral / local Ollama):

    hermes-fast   → fast tier        (groq-gpt-oss-20b, groq-qwen3.8-27b, cerebras-llama3.3-70b)
    hermes-reason → reasoning tier   (groq-gpt-oss-120b)
    hermes-code   → code tier        (mistral-small, hf-Qwen2.5-72B-Instruct)
    hermes-long   → long_context     (gemini-2.5-flash)
    hermes-local  → local tier       (ollama qwen2.5:1.5b / llama3.2:3b — free, on this box)
    hermes-auto   → balancer decides by weight and health

So an agent does not pick a provider or hold a key: it picks a TIER, and the balancer does
the rest. This module is the policy:

* every agent has a default tier (routine work stays on the free fast tier),
* **escalation** is explicit and logged: analysis/reasoning questions go to `hermes-reason`,
  code work to `hermes-code`, long documents to `hermes-long`,
* if the balancer is unreachable the agent degrades in this order:
  local model → the deterministic facts alone (never a failed task, never a hang).

Cost note: the fast and reasoning tiers are served by free-tier keys, `hermes-long` by a
cheap Gemini Flash key, `hermes-local` costs nothing. Nothing here uses a paid-only model,
and no agent ever sees a provider key — only the gateway URL and its single client key.
"""
from __future__ import annotations

import json
import sys
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import yaml
except Exception:                                   # pragma: no cover
    yaml = None

POLICY_FILE = Path(os.environ.get("HERMES_MODELS_FILE", "/opt/hermes/config/models.yaml"))
SHIM_URL = os.environ.get("HERMES_SHIM_URL", "http://127.0.0.1:9700/v1/chat/completions")
SHIM_ENV = Path(os.environ.get("HERMES_SHIM_ENV", "/etc/hermes/shim.env"))

TIER_ALIASES = {"hermes-fast", "hermes-reason", "hermes-code", "hermes-long", "hermes-local",
                "hermes-auto"}

# Как тот же тир называется на стороне балансировщика — для сверки «просили / ответили».
TIER_SERVED_NAME = {"hermes-fast": "fast", "hermes-reason": "reasoning", "hermes-code": "code",
                    "hermes-long": "long_context", "hermes-local": "local"}

# DECISION (2026-09-17, владелец «1»): если основной тир не ответил — сначала УМНЫЙ резерв, и
# только потом локальная модель и «просто факты». Порядок важен: тир code мёртв, и раньше
# «кодовый» запрос тихо уезжал на fast-модель вместо gemini.
# Цепочки ацикличны: code → long → reason → (конец), fast → reason, local → fast, auto → long.
ESCALATE_TO: dict[str, str] = {
    "hermes-code": "hermes-long",      # кода нет — gemini-flash заметно умнее fast для кода
    "hermes-fast": "hermes-reason",
    "hermes-long": "hermes-reason",
    "hermes-local": "hermes-fast",
    "hermes-auto": "hermes-long",
}


def escalation_target(model: str) -> str:
    """Куда идти, если этот тир не ответил. Пустая строка — резерва нет (конец цепочки)."""
    return ESCALATE_TO.get(model, "")

# Built-in defaults: the policy file may override any of them, but the system behaves
# sensibly if the file is missing (e.g. inside a recovery container).
DEFAULT_POLICY = {
    "default": "hermes-fast",
    "smart": "hermes-reason",
    "code": "hermes-code",
    "long": "hermes-long",
    "local": "hermes-local",
    "agents": {
        # planning, routing and risk judgements deserve the stronger (still free) model
        "orchestrator": "hermes-reason",
        "security": "hermes-reason",
        # diffs and code reading
        "github": "hermes-code",
        # logs, journals, long reports
        "server-guardian": "hermes-fast",
        "monitoring": "hermes-fast",
        "backup": "hermes-fast",
        # project agents answer questions about their own tree: fast is enough, escalate on
        # analysis via the shared rules below
    },
    "escalate": {
        "analysis": "hermes-reason",     # why/explain/advise/plan
        "code": "hermes-code",           # diff, refactor, review, test
        "long": "hermes-long",           # summaries over logs or many files
    },
}


_POLICY_WARNED = False
POLICY_STATE = {"source": "defaults", "file": str(POLICY_FILE), "note": ""}


def policy_status() -> str:
    """Откуда взята политика: «file:<путь>» или «defaults:<причина>».

    Нужно тестам и диагностике: молчаливый откат на встроенные умолчания — это не
    «всё в порядке», это потеря политики владельца (см. scripts/install-model-policy.sh).
    """
    policy()
    return (f"file:{POLICY_STATE['file']}" if POLICY_STATE["source"] == "file"
            else f"defaults:{POLICY_STATE['note'] or 'unknown'}")


def policy() -> dict:
    global _POLICY_WARNED
    data = json.loads(json.dumps(DEFAULT_POLICY))       # deep copy
    if yaml is None:
        POLICY_STATE.update(source="defaults", note="PyYAML отсутствует")
    elif not POLICY_FILE.exists():
        POLICY_STATE.update(source="defaults", note=f"нет файла {POLICY_FILE}")
    else:
        try:
            loaded = yaml.safe_load(POLICY_FILE.read_text()) or {}
            data.update({k: v for k, v in loaded.items() if k != "agents"})
            data["agents"] = {**DEFAULT_POLICY["agents"], **(loaded.get("agents") or {})}
            data["escalate"] = {**DEFAULT_POLICY["escalate"], **(loaded.get("escalate") or {})}
            POLICY_STATE.update(source="file", note="")
        except Exception as e:
            POLICY_STATE.update(source="defaults",
                                note=f"{POLICY_FILE} не разбирается: {type(e).__name__}: {e}")
    if POLICY_STATE["source"] != "file" and not _POLICY_WARNED:
        _POLICY_WARNED = True
        # Один раз за процесс: иначе шум в каждом ответе.
        print(f"models: политика НЕ прочитана ({POLICY_STATE['note']}) — работаю на "
              f"встроенных умолчаниях; починить: scripts/install-model-policy.sh",
              file=sys.stderr, flush=True)
    return data


def model_for(agent_id: str, task: str = "", analysis: bool = False,
              prefer: str = "") -> tuple[str, str]:
    """Return (model alias, reason). Deterministic, so the chat can show why."""
    pol = policy()
    if prefer in TIER_ALIASES:
        return prefer, "явно задано"
    low = (task or "").lower()
    if re.search(r"diff|патч|рефактор|ревью|тест[ыа]? |код|скрипт|функци|ошибка в коде", low):
        return pol["escalate"]["code"], "код"
    if re.search(r"за неделю|за месяц|весь журнал|много файлов|сводка по логам|длинн", low):
        return pol["escalate"]["long"], "длинный контекст"
    if analysis or re.search(r"почему|проанализ|объясн|рекоменд|план|риск|оцени|совет", low):
        return pol["escalate"]["analysis"], "анализ"
    return pol["agents"].get(agent_id) or pol["default"], "профиль агента"


def _client_key() -> str:
    """The gateway's own client key (0600). Agents never hold provider keys."""
    env = os.environ.get("HERMES_BALANCER_API_KEY", "")
    if env:
        return env
    try:
        for line in SHIM_ENV.read_text().splitlines():
            line = line.strip()
            if line.startswith("HERMES_BALANCER_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return ""


def available() -> bool:
    try:
        req = urllib.request.Request(SHIM_URL.replace("/chat/completions", "/models"))
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status == 200
    except Exception:
        return False


SYSTEM = ("Ты — {agent}, агент узла {node} в системе Hermes OS. Твоя роль: {purpose}\n"
          "Отвечай по-русски, коротко и по делу. Формат ответа:\n"
          "1) вывод в 1-2 строки с эмодзи;\n"
          "2) при необходимости 3-5 пунктов «• …» с конкретными числами из фактов;\n"
          "3) последняя строка «💡 » — что делать дальше.\n"
          "Опирайся ТОЛЬКО на факты ниже. Если данных не хватает — скажи, чего не хватает. "
          "Не выдумывай числа. Не используй markdown (**жирный**, ## заголовки, "
          "`код`) — только обычный текст, эмодзи в начале строки и «• » для пунктов.")


def ask(question: str, facts: str, agent_id: str, purpose: str = "", node: str = "узел",
        model: str = "hermes-auto", timeout: int = 45, _depth: int = 0) -> tuple[str, dict]:
    """Ask the agent's model to explain the facts. Returns (text, meta).

    Порядок деградации (2026-09-17): запрошенный тир → умный резерв → локальная модель →
    только факты. `_depth` ограничивает длину цепочки резервов, чтобы отказ балансировщика
    не превращался в серию дорогих попыток.
    """
    meta = {"model": model, "ok": False, "latency_ms": 0, "fallback": ""}
    key = _client_key()
    prompt = SYSTEM.format(agent=agent_id, node=node, purpose=purpose or "диагностика узла")
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": f"ФАКТЫ:\n{facts[:6000]}\n\nВОПРОС: {question}"},
        ],
        "temperature": 0.2,
        "max_tokens": 700,
    }
    req = urllib.request.Request(
        SHIM_URL, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {key}"} if key else {})})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read())
        text = (data["choices"][0]["message"]["content"] or "").strip()
        # FACT (2026-09-17): балансировщик может ответить не тем тиром, который просили
        # (мост игнорирует поле tier, а его кэш не различает тиры). Раньше мы записывали
        # в телеметрию запрошенный тир — то есть отчёт «ответила hermes-reason» был
        # утверждением о намерении, а не о факте. Теперь берём факт из ответа shim.
        served = data.get("aios") if isinstance(data.get("aios"), dict) else {
            "tier": data.get("aios_tier") or "",
            "provider": data.get("aios_provider") or "",
            "cached": bool(data.get("aios_cached")),
        }
        meta.update(ok=bool(text), model=data.get("model") or model,
                    latency_ms=int((time.time() - started) * 1000),
                    usage=data.get("usage") or {},
                    served_tier=str(served.get("tier") or ""),
                    provider=str(served.get("provider") or ""),
                    cached=bool(served.get("cached")))
        meta["provider_tier"] = str(served.get("provider_tier") or "")
        want = TIER_SERVED_NAME.get(model)
        # Расхождение бывает двух видов: ответил другой бакет и ответил провайдер другого
        # тира (тогда бакет совпадает, а модель — дешёвая). Оба означают потерю умности.
        if want and ((meta["served_tier"] and want != meta["served_tier"])
                     or (meta["provider_tier"] and want != meta["provider_tier"])):
            meta["tier_mismatch"] = True
        if text:
            return text, meta
        meta["fallback"] = "пустой ответ"
    except urllib.error.HTTPError as e:
        meta["fallback"] = f"HTTP {e.code}"
    except Exception as e:
        meta["fallback"] = type(e).__name__
    # 2. Резервный тир раньше локальной модели: «умный» ответ важнее дешёвой деградации.
    if _depth < 2:
        alt = escalation_target(model)
        if alt and alt != model:
            text2, meta2 = ask(question, facts, agent_id, purpose, node, model=alt,
                               timeout=min(timeout, 25), _depth=_depth + 1)
            if meta2.get("ok"):
                meta2["escalated_from"] = model
                meta2["escalated_to"] = alt
                meta2["latency_ms"] = int((time.time() - started) * 1000)
                return text2, meta2
            meta["fallback"] = meta["fallback"] or meta2.get("fallback", "")
    # Degrade, never fail the task: local model first (free, on this box), then facts alone.
    if model != policy()["local"]:
        text, meta2 = ask(question, facts, agent_id, purpose, node, model=policy()["local"],
                          timeout=min(timeout, 25), _depth=_depth + 1)
        if meta2.get("ok"):
            meta2["escalated_from"] = model
            meta2["latency_ms"] = int((time.time() - started) * 1000)
            return text, meta2
        meta["fallback"] = meta["fallback"] or meta2.get("fallback", "")
    return "", meta
