#!/usr/bin/env python3
"""probe-models.py — guards the model policy and the `ask` degradation path.

What must stay true:

* **Every agent has a model**, either explicitly or through the default: an agent without a
  policy would silently fall back to "whatever the balancer feels like".
* **Only real tiers are named.** A typo like `hermes-smart` would fail at request time, in
  production, on the owner's question.
* **Cheap by default, smart on purpose.** Routine work stays on the free fast tier; the
  stronger (still free-tier) model is used for analysis/code/long context, and the reason is
  reported so cost drift is visible in the logs.
* **No provider keys anywhere in the agents.** The policy names tiers; the balancer holds
  keys. This probe fails if a key-looking value appears in the policy file.
* **Degradation works.** With the balancer unreachable, `ask` must return a clear
  "facts only" answer instead of hanging or failing the task.

Prints key=value lines; tests/run.sh asserts on them.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "agents"))
sys.path.insert(0, str(ROOT / "bus"))
if (ROOT / "config" / "agents").is_dir():
    os.environ.setdefault("HERMES_AGENTS_DIR", str(ROOT / "config" / "agents"))
if (ROOT / "config" / "models.yaml").exists():
    os.environ.setdefault("HERMES_MODELS_FILE", str(ROOT / "config" / "models.yaml"))

import models    # noqa: E402
import roster    # noqa: E402

pol = models.policy()
core, projects = roster.load_registry()

# every agent resolves to a real tier
uncovered, bad_tier = [], []
for rec in core + projects:
    model, _why = models.model_for(rec["id"], "проверить статус", analysis=False)
    if model not in models.TIER_ALIASES:
        bad_tier.append(f"{rec['id']}={model}")
    if rec["id"] not in pol["agents"] and pol.get("default") not in models.TIER_ALIASES:
        uncovered.append(rec["id"])
print("agents=%d" % (len(core) + len(projects)))
print("uncovered=%s" % (len(uncovered)))
print("bad_tier=%s" % (len(bad_tier)))

# escalation is what buys smartness without paying for it everywhere
print("escalate-analysis=%s" % models.model_for("server-guardian", "почему сервер тормозит",
                                                analysis=True)[0])
print("escalate-code=%s" % models.model_for("github", "сделай ревью диффа")[0])
print("escalate-long=%s" % models.model_for("knowledge", "сводка за неделю по журналу")[0])
print("routine=%s" % models.model_for("monitoring", "проверить алерты")[0])
print("reason-class=%s" % ("ok" if pol["escalate"]["analysis"] in
                           ("hermes-reason", "hermes-code", "hermes-long") else "unexpected"))

# the policy file must not carry credentials
policy_text = ""
try:
    policy_text = (ROOT / "config" / "models.yaml").read_text()
except Exception:
    pass
leaky = [w for w in ("gsk_", "sk-", "AIza", "Bearer ", "api_key:", "api-key:")
         if w in policy_text]
print("policy-clean=%s" % (not leaky))

# degradation: point the shim at a closed port and make the timeout tiny
models.SHIM_URL = "http://127.0.0.1:9/v1/chat/completions"
models.SHIM_ENV = Path("/nonexistent")
os.environ["HERMES_BALANCER_API_KEY"] = ""
text, meta = models.ask("тест", "факты: всё в порядке", "server-guardian", "тест узла",
                        "node", "hermes-fast", timeout=2)
print("degrade-no-hang=%s" % (not text and not meta["ok"]))
print("degrade-reports-reason=%s" % bool(meta.get("fallback")))
