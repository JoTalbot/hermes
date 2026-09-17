#!/usr/bin/env python3
"""OpenAI-compatible shim in front of the Octopus AIOS LLM balancer.

WHY THIS FILE EXISTS
--------------------
The master plan said "point Hermes at the existing LLM Balancer via its
OpenAI-compatible endpoint". That endpoint does not exist. Measured on
arm-server-01 (2026-09-15):

    octopus-aios.service -> /opt/aios-venv/bin/python3 /opt/octopus-aios-server.py
    listen 0.0.0.0:9600
    routes: /health, /api/v1/aios/status,
            POST /api/v1/aios/ask   {"goal": "..."}
            POST /api/v1/aios/execute  {"goal": "..."}
            GET  /api/v1/aios/tasks/{id}
            POST /api/v1/aios/debate
    -> POST /v1/chat/completions returns HTTP 404

So rather than editing a 35-unit production service, this shim translates the
OpenAI chat-completions contract Hermes expects into the `goal`-based contract
the balancer actually offers. It is stateless, stdlib-only, loopback-only.

SECURITY
--------
* Binds 127.0.0.1 only. Never change to 0.0.0.0.
* Requires `Authorization: Bearer $HERMES_BALANCER_API_KEY` unless
  HERMES_SHIM_ALLOW_ANONYMOUS=1.
* Holds NO provider keys. The 11 provider keys stay inside the balancer /
  /etc/octopus/secrets.env. This process only talks to 127.0.0.1:9600.

Model routing: OpenAI `model` field is interpreted as a balancer tier hint.
  hermes-fast        -> tier=fast
  hermes-code        -> tier=code
  hermes-reason      -> tier=reasoning
  hermes-long        -> tier=long_context
  hermes-local       -> tier=local
  hermes-auto        -> no tier (balancer decides by weight/health)

CHANGELOG
---------
1.0.0  initial translation layer.
1.1.0  SSE streaming. Hermes' OpenAI client always asks for `stream: true`;
       1.0.0 answered with a plain JSON body, which the client reported as
       "Provider returned an empty stream with no finish_reason" and the agent
       loop never completed. The balancer has no streaming of its own, so we
       call it once and re-emit the finished text as a well-formed SSE stream.
1.2.0  Tool-call bridge. The balancer offers no `tools` support, so an agent
       pointed straight at it can chat but can never *act*. When the caller
       sends `tools[]` we inject a compact text protocol into the system
       prompt, parse the model's reply into OpenAI `tool_calls`, and render
       prior tool results back into the goal string. Text-only reply is
       returned as ordinary content, so non-tool callers are unaffected.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid as _uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BRIDGE = os.environ.get("AIOS_BRIDGE_URL", "http://127.0.0.1:9600").rstrip("/")
API_KEY = os.environ.get("HERMES_BALANCER_API_KEY", "")
ALLOW_ANON = os.environ.get("HERMES_SHIM_ALLOW_ANONYMOUS", "0") == "1"
BIND = os.environ.get("HERMES_SHIM_BIND", "127.0.0.1")
PORT = int(os.environ.get("HERMES_SHIM_PORT", "9700"))
TIMEOUT = float(os.environ.get("HERMES_SHIM_TIMEOUT", "120"))

SHIM_VERSION = "1.3.5"

TIER_BY_MODEL = {
    "hermes-fast": "fast",
    "hermes-code": "code",
    "hermes-reason": "reasoning",
    "hermes-long": "long_context",
    "hermes-local": "local",
    "hermes-auto": None,
}
VALID_TIERS = {"fast", "code", "reasoning", "long_context", "local"}

# Cap the rendered tool catalogue so a 40-tool agent doesn't blow the prompt.
MAX_TOOLS_RENDERED = 40
MAX_TOOL_DESC = 160
MAX_STRING_IN_HISTORY = 6000

# The AIOS balancer hands the provider only `prompt[:4000]`
# (llm_balancer.OpenAICompatibleCloudProvider.generate). Everything we render past
# that is invisible to the model, so the goal is assembled against an explicit
# budget with the most important section first. See _render_goal for why the order
# is not cosmetic.
GOAL_BUDGET = 3900
TOOLS_BUDGET = 1300
# A card read back with kanban_show is ~1.8 KB, mostly the Body and the completion
# summary. Anything smaller than that silently hides the answer.
RECENT_BUDGET = 2600

# The balancer's last resort when every provider fails is a local "reasoning"
# fallback that emits canned boilerplate ("AIOS Reasoner: <запрос> проанализирован
# автономным ядром кластера…"). It is not an answer, and an agent that receives it
# as if it were one derails: it "completes" cards with an empty result and burns the
# provider pool retrying. We detect it, retry once, and otherwise fail loudly.
FALLBACK_MARKERS = ("AIOS Reasoner:", "проанализирован автономным", "автономным ядром кластера")
FALLBACK_PROVIDERS = ("emergency_engine", "autonomous_heuristic_engine", "local_autonomous")

# ---------------------------------------------------------------- telemetry
STATS = {
    "requests_total": 0,
    "requests_failed": 0,
    "upstream_errors_total": 0,
    "auth_rejections_total": 0,
    "last_latency_ms": 0.0,
    "latency_sum_ms": 0.0,
    "streaming_requests_total": 0,
    "tool_bridge_requests_total": 0,
    "tool_calls_emitted_total": 0,
    "tool_parse_fallbacks_total": 0,
    "empty_reply_retries_total": 0,
    "tool_block_degraded_total": 0,
    "goal_budget_exhausted_total": 0,
    "upstream_fallback_total": 0,
    "upstream_short_circuit_total": 0,
    # Сколько раз просили один тир, а ответил другой — это и есть «потеря умности».
    "tier_mismatch_total": 0,
}

# Что реально ответило (тир балансировщика) за время жизни процесса.
SERVED_TIERS: dict[str, int] = {}
_TIER_MISMATCH_LAST_LOG = [0.0]


def _post_json(path: str, payload: dict) -> tuple[int, dict]:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        BRIDGE + path,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()[:2000]
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"upstream_raw": raw}
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return 502, {"error": "upstream_unreachable", "detail": str(e)}


def flatten_upstream(data: dict) -> str:
    """AIOS /ask returns an ad-hoc object; pull the text out defensively."""
    for key in ("answer", "response", "result", "output", "text", "content", "message"):
        v = data.get(key)
        if isinstance(v, str) and v.strip():
            return v
        if isinstance(v, dict):
            inner = flatten_upstream(v)
            if inner:
                return inner
    # last resort: dump whatever came back so the model can still reason on it
    return json.dumps(data, ensure_ascii=False)[:8000]


# ------------------------------------------------------------ tool bridging
TOOL_PROTOCOL_HEADER = """[TOOL PROTOCOL] Reply with EXACTLY ONE JSON object, nothing else.
No prose, no markdown fences.
Call a function: {"tool_calls":[{"name":"<fn>","arguments":{<json object>}}]}
Answer directly: {"content":"<your full answer as a plain string>"}
Emit only names from the list below; never invent one. If you already know the
answer, use the {"content":...} form rather than calling a function.
AVAILABLE FUNCTIONS:
"""


def _render_tools(tools: list, desc_limit: int = MAX_TOOL_DESC,
                 arg_detail: bool = True) -> str:
    """Compact, deterministic rendering of OpenAI tool schemas for the prompt.

    `desc_limit=0` drops descriptions and `arg_detail=False` drops the argument
    list — used by _build_tool_block to degrade gracefully instead of silently
    making tools uncallable when the tool set is large.
    """
    lines = []
    for i, t in enumerate(tools[:MAX_TOOLS_RENDERED]):
        if not isinstance(t, dict):
            continue
        fn = t.get("function") if t.get("type") == "function" else t
        if not isinstance(fn, dict):
            continue
        name = fn.get("name") or ""
        if not name:
            continue
        desc = (fn.get("description") or "").strip().replace("\n", " ")
        if desc_limit <= 0:
            desc = ""
        elif len(desc) > desc_limit:
            desc = desc[:desc_limit] + "…"
        sig = ""
        if arg_detail:
            params = fn.get("parameters") or {}
            props = params.get("properties") or {}
            required = set(params.get("required") or [])
            arg_bits = []
            for pname, pspec in list(props.items())[:25]:
                ptype = (pspec or {}).get("type", "any") if isinstance(pspec, dict) else "any"
                mark = "" if pname in required else "?"
                arg_bits.append(f"{pname}{mark}:{ptype}")
            sig = ", ".join(arg_bits)
        lines.append(f"{i + 1}. {name}({sig}) — {desc}" if desc else f"{i + 1}. {name}({sig})")
    if len(tools) > MAX_TOOLS_RENDERED:
        lines.append(f"... ({len(tools) - MAX_TOOLS_RENDERED} more tools omitted)")
    return "\n".join(lines)


def _build_tool_block(tools: list, budget: int = TOOLS_BUDGET) -> str:
    """Header + function list, degraded as needed to fit `budget` characters.

    A tool the model cannot see is a tool it cannot call, so a truncated list is a
    correctness bug, not a formatting detail. We therefore try progressively
    terser renderings and, only if even bare names do not fit, keep as many names
    as the budget allows — always recording the degradation in /metrics.
    """
    for desc_limit, arg_detail in ((60, True), (0, True), (0, False)):
        body = _render_tools(tools, desc_limit=desc_limit, arg_detail=arg_detail)
        block = TOOL_PROTOCOL_HEADER + body
        if len(block) <= budget:
            if (desc_limit, arg_detail) != (60, True):
                STATS["tool_block_degraded_total"] += 1
            return block
    STATS["tool_block_degraded_total"] += 1
    names, used = [], len(TOOL_PROTOCOL_HEADER)
    for t in tools[:MAX_TOOLS_RENDERED]:
        fn = t.get("function") if isinstance(t, dict) and t.get("type") == "function" else t
        nm = fn.get("name") if isinstance(fn, dict) else None
        if nm and used + len(nm) + 2 <= budget:
            names.append(nm)
            used += len(nm) + 2
    return TOOL_PROTOCOL_HEADER + ", ".join(names)


def _extract_json_object(text: str) -> dict | None:
    """Pull the first JSON object out of a model reply, tolerating fences/prose.

    Models routinely add ```json fences or a sentence before the object even
    when told not to. We scan for the first balanced brace pair rather than
    trusting the reply to be clean.
    """
    if not text:
        return None
    s = text.strip()
    s = re.sub(r"^```(?:json)?\s*", "", s)
    s = re.sub(r"\s*```$", "", s)
    s = s.strip()
    try:
        v = json.loads(s)
        return v if isinstance(v, dict) else None
    except json.JSONDecodeError:
        pass
    start = s.find("{")
    while start != -1:
        depth = 0
        in_str = False
        esc = False
        for i in range(start, len(s)):
            ch = s[i]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    try:
                        v = json.loads(s[start:i + 1])
                        if isinstance(v, dict):
                            return v
                    except json.JSONDecodeError:
                        break
        start = s.find("{", start + 1)
    return None


def _to_tool_calls(obj: dict, allowed: set[str]) -> list[dict]:
    """Normalise several plausible model shapes into OpenAI tool_calls."""
    raw = obj.get("tool_calls")
    if raw is None and isinstance(obj.get("function_call"), dict):
        raw = [obj["function_call"]]
    if isinstance(raw, dict):
        raw = [raw]
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        fn = item.get("function") if isinstance(item.get("function"), dict) else item
        name = fn.get("name") or ""
        if not name or (allowed and name not in allowed):
            continue
        args = fn.get("arguments", {})
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                args = {}
        if not isinstance(args, dict):
            args = {}
        out.append({
            "id": f"call_{_uuid.uuid4().hex[:24]}",
            "type": "function",
            "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)},
        })
    return out


def _parse_model_reply(text: str, allowed: set[str]) -> tuple[list[dict], str | None]:
    """Return (tool_calls, content). Exactly one of the two is meaningful."""
    obj = _extract_json_object(text)
    if obj is not None:
        calls = _to_tool_calls(obj, allowed)
        if calls:
            return calls, None
        c = obj.get("content")
        if isinstance(c, str) and c.strip():
            return [], c
        # Well-formed protocol object with an empty content field. Distinct from
        # "no JSON at all": this is the model saying nothing, and the caller
        # treats it as a reason to re-ask rather than as an answer.
        if "content" in obj:
            return [], None
    return [], text


def _render_history_message(m) -> str:
    """Render one OpenAI message. Keeps tool_call / tool-result round trips."""
    if not isinstance(m, dict):
        return ""
    role = m.get("role", "user")
    content = m.get("content", "")
    if isinstance(content, list):
        content = " ".join(
            p.get("text", "") for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        )
    if not isinstance(content, str):
        content = "" if content is None else str(content)
    if len(content) > MAX_STRING_IN_HISTORY:
        content = content[:MAX_STRING_IN_HISTORY] + "…[truncated]"

    out = []
    if role == "assistant":
        for tc in (m.get("tool_calls") or []):
            if not isinstance(tc, dict):
                continue
            fn = tc.get("function") or {}
            out.append(
                f"[assistant->tool_call] {fn.get('name')} {fn.get('arguments') or '{}'}"
            )
    if role == "tool":
        name = m.get("name") or m.get("tool_call_id") or "tool"
        return f"[tool_result:{name}] {content}"
    if content:
        out.append(f"[{role}] {content}")
    return "\n".join(out)


def _clip(text: str, limit: int) -> str:
    """Truncate to `limit` characters, marking that we did."""
    text = text.strip()
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text
    return text[: max(limit - 1, 0)].rstrip() + "…"


def _render_goal(messages: list, system_extra=None, tool_block: str = "",
                 budget: int = GOAL_BUDGET) -> str:
    """Flatten the OpenAI message list into the one `goal` string AIOS wants.

    ORDER AND BUDGET BOTH MATTER. The balancer forwards only the first ~4000 chars
    of this string, so everything the model is allowed to see has to fit inside
    `budget`, and the sections have to be sized according to what the agent needs.

    The first version of this gave each section a fixed cap. Measured on a real
    kanban worker request (system 6704 chars, user 61 chars, 17 tools) that wasted
    ~40% of the budget: the task line is tiny, so the caps left 1670 characters
    unused while still cutting the system prompt — which is where the agent's
    "call kanban_complete or the run counts as failed" contract lives. Fixed caps on
    variable-length inputs are just a different way to lose the important part.

    Sections, in priority order, each with a floor and a ceiling:
        [task]    the latest user turn — what to do
        [system]  operating contract / worker protocol — how to behave
        [tools]   tool protocol + callable signatures — how to act
        [recent]  messages after the task (tool results, prior tool calls)
        [earlier] older turns, newest first

    Floors are guaranteed for the first three; whatever is left after that is
    shared out in proportion to how much each section still wants, so no budget is
    wasted on a section that has nothing to say. Output order is task-first as a
    safety margin, though nothing should be truncated once the total fits.
    """
    sys_msgs: list[str] = []
    convo: list = []
    for m in messages:
        if isinstance(m, dict) and m.get("role") == "system":
            c = m.get("content")
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c
                             if isinstance(p, dict) and p.get("type") == "text")
            if c:
                sys_msgs.append(str(c))
        else:
            convo.append(m)

    task_idx = None
    for i in range(len(convo) - 1, -1, -1):
        if isinstance(convo[i], dict) and convo[i].get("role") == "user":
            task_idx = i
            break
    if task_idx is None:
        task_raw = _render_history_message(convo[-1]) if convo else ""
        context_msgs, earlier_msgs = [], convo[:-1] if convo else []
    else:
        task_raw = _render_history_message(convo[task_idx])
        context_msgs, earlier_msgs = convo[task_idx + 1:], convo[:task_idx]

    if system_extra:
        sys_msgs.insert(0, str(system_extra))

    history = [_clip(_render_history_message(m), 400)
               for m in earlier_msgs[-12:]]
    history = [h for h in history if h]

    # [recent] holds tool results, and a tool result is the agent's working
    # memory: the card it just read, the command output it is about to report.
    # Rendered the obvious way — join then clip — the NEWEST message is cut first
    # and the agent loops, calling the same tool again with the same invisible
    # answer (observed: 46 consecutive kanban_show calls, 90-turn budget spent).
    # So it is sized by what the payload actually is (~1.8 KB for a card with a
    # completion summary) and the newest message is placed FIRST with its own
    # allocation, not merely at the end of a shared string.
    recent_parts: list[str] = []
    recent_room = RECENT_BUDGET
    for m in reversed(context_msgs[-4:]):
        chunk = _render_history_message(m)
        if not chunk:
            continue
        allow = min(len(chunk), recent_room)
        if allow <= 20:
            break
        recent_parts.append(_clip(chunk, allow))
        recent_room -= len(recent_parts[-1]) + 1
    recent_body = "\n".join(reversed(recent_parts))

    # (label, body, floor, ceiling) in priority order
    specs = [
        ("[task]", task_raw,
         120, 700),
        ("[recent]", recent_body,
         900, 2600),
        ("[system]", "\n".join(sys_msgs),
         700, 1500),
        ("[tools]", tool_block,
         500, 1300),
        ("[earlier]", "\n".join(reversed(history)) if history else "",
         0, 300),
    ]

    # Reserve room for the "[label] " prefixes we are about to prepend.
    inner = budget - sum(len(lbl) + 1 for lbl, body, _f, _c in specs if (body or "").strip())
    if inner < 200:  # pathological caller: fall back to one bare section
        return _clip(task_raw or "\n".join(sys_msgs) or "(empty)", max(budget, 200))

    grants: list[int] = []
    remaining = inner
    for lbl, body, floor, ceil in specs:
        want = min(len((body or "").strip()), ceil)
        give = min(floor, want, remaining)
        grants.append(give)
        remaining -= give

    needs = [min(len((b or "").strip()), c) - g for (_l, b, _f, c), g in zip(specs, grants)]
    total_need = sum(max(n, 0) for n in needs)
    if total_need > 0 and remaining > 0:
        for i, need in enumerate(needs):
            if need <= 0:
                continue
            extra = min(need, int(remaining * need / total_need))
            grants[i] += extra

    parts: list[str] = []
    for (lbl, body, _f, _c), grant in zip(specs, grants):
        body = (body or "").strip()
        if not body or grant <= 0:
            continue
        parts.append(f"{lbl} {_clip(body, grant)}")

    if not parts:
        return "(empty)"
    out = "\n".join(parts)
    if len(out) > budget:
        # Should not happen; if it ever does, the task section must survive.
        out = _clip(out, budget)
    if len(out) >= budget - 20:
        STATS["goal_budget_exhausted_total"] += 1
    return out


# ------------------------------------------------- upstream health (fallback)
def _is_fallback(data: dict, text: str) -> bool:
    """True when the balancer handed back its local boilerplate instead of a model.

    When every provider fails, the balancer's last resort is
    LocalAutonomousReasoningFallback, which answers with
    "AIOS Reasoner: <запрос> проанализирован автономным ядром кластера…" and
    reports status: success. Treated as a completion, that makes an agent finish a
    task with no content — observed as cards completing with an empty result.
    """
    prov = str((data or {}).get("provider") or "").lower()
    if any(p in prov for p in FALLBACK_PROVIDERS):
        return True
    head = (text or "").strip()[:160]
    return any(marker in head for marker in FALLBACK_MARKERS)


def _served_info(data: dict) -> dict:
    """Кто действительно ответил: тир и провайдер балансировщика.

    FACT (2026-09-17): AIOS-мост принимает поле tier в теле запроса, но обработчик
    /api/v1/aios/ask не передаёт его в llm_balancer.ask — тир выбирает классификатор по
    тексту промпта. Без этой функции агент считал отвечавшую модель той, которую просил.
    """
    d = data or {}
    return {"tier": str(d.get("tier") or ""), "provider": str(d.get("provider") or ""),
            "cached": bool(d.get("cached"))}


def note_served(tier_asked: str | None, served: dict) -> None:
    """Учесть факт ответа и сказать громко, если ответил не тот тир, что просили."""
    st = served.get("tier") or "?"
    SERVED_TIERS[st] = SERVED_TIERS.get(st, 0) + 1
    if tier_asked and served.get("tier") and tier_asked != served["tier"]:
        STATS["tier_mismatch_total"] += 1
        now = time.time()
        if now - _TIER_MISMATCH_LAST_LOG[0] > 60:          # не спамить журнал
            _TIER_MISMATCH_LAST_LOG[0] = now
            print(f"tier mismatch: asked {tier_asked}, balancer served {st} "
                  f"via {served.get('provider') or '?'}", file=sys.stderr, flush=True)


def _ask_balancer(payload: dict, attempts: int = 1) -> tuple[int, dict, str]:
    """POST /ask, reporting the emergency fallback as a failure rather than an answer.

    `attempts` defaults to 1 on purpose. The balancer already walks its whole
    provider list before falling back, so a second call here is pure amplification
    against a pool that is, by definition, already failing. Extra attempts are
    available to callers that genuinely need them (the /selfcheck probe); the
    request path does not use them.

    Returns (status_code, upstream_json, extracted_text).
    """
    last_code, last_data = 0, {}
    for i in range(max(attempts, 1)):
        code, data = _post_json("/api/v1/aios/ask", payload)
        text = flatten_upstream(data) if code < 400 else ""
        if code < 400 and not _is_fallback(data, text):
            return code, data, text
        last_code, last_data = code, data
        STATS["upstream_fallback_total"] += 1
        if i + 1 < attempts:
            time.sleep(1.2 * (i + 1))
    return last_code, last_data, ""


# ---------------------------------------------------------- SSE re-emitter
def _sse_chunks_for_content(cid: str, model: str, created: int, text: str,
                            usage: dict | None = None, served: dict | None = None):
    """Well-formed OpenAI chat.completion.chunk SSE stream for plain content."""
    def frame(delta: dict, finish=None) -> bytes:
        obj = {
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
        return f"data: {json.dumps(obj, ensure_ascii=False)}\n\n".encode()

    yield frame({"role": "assistant", "content": ""})
    # Re-chunk the finished text so clients that render progressively still do,
    # and so no single frame is unreasonably large for a mobile connection.
    step = 96
    for i in range(0, len(text), step):
        yield frame({"content": text[i:i + step]})
    final = {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
    if usage:
        final["usage"] = usage
    if served:                       # кто ответил на самом деле, а не кого просили
        final["aios"] = served
    yield f"data: {json.dumps({'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': model, **final}, ensure_ascii=False)}\n\n".encode()
    yield b"data: [DONE]\n\n"


def _sse_chunks_for_tool_calls(cid: str, model: str, created: int, calls: list[dict],
                               usage: dict | None = None, served: dict | None = None):
    """SSE stream carrying tool_calls, as the OpenAI SDK expects them."""
    def frame(delta: dict, finish=None) -> bytes:
        obj = {
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
        return f"data: {json.dumps(obj, ensure_ascii=False)}\n\n".encode()

    yield frame({"role": "assistant", "content": None})
    for i, c in enumerate(calls):
        yield frame({"tool_calls": [{
            "index": i, "id": c["id"], "type": "function",
            "function": {"name": c["function"]["name"],
                         "arguments": c["function"]["arguments"]},
        }]})
    final = {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
    if usage:
        final["usage"] = usage
    if served:                       # кто ответил на самом деле, а не кого просили
        final["aios"] = served
    yield f"data: {json.dumps({'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': model, **final}, ensure_ascii=False)}\n\n".encode()
    yield b"data: [DONE]\n\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hermes-aios-shim/" + SHIM_VERSION

    def log_message(self, fmt, *args):  # quieter journald
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- helpers ---------------------------------------------------------
    def _send(self, code: int, obj: dict):
        raw = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _send_sse(self, frames):
        """Chunked text/event-stream. No Content-Length: the stream is open-ended."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for fr in frames:
                self.wfile.write(b"%X\r\n" % len(fr) + fr + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Client hung up (Hermes cancel / mobile network drop). Not an error.
            pass

    def _send_sse_error(self, err: dict) -> None:
        """Deliver an error inside an SSE stream.

        Hermes always streams, so a bare 5xx JSON body reaches it as an empty
        stream ("Provider returned an empty stream with no finish_reason") and the
        real cause is lost. Sending the error as an in-band SSE event keeps it.
        """
        payload = json.dumps(err, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        frame = b"data: " + payload + b"\r\n\r\n"
        try:
            self.wfile.write(b"%X\r\n" % len(frame) + frame + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _authorized(self) -> bool:
        if ALLOW_ANON or not API_KEY:
            return True
        got = self.headers.get("Authorization", "")
        return got.strip() == f"Bearer {API_KEY}"

    # -- routes ----------------------------------------------------------
    def do_GET(self):
        if self.path.startswith("/selfcheck"):
            # End-to-end proof that the LLM path works, WITHOUT handing the caller
            # the API key. Agents run as an unprivileged user that deliberately
            # cannot read /etc/hermes/shim.env, yet they still need to answer "can
            # I think right now?". The shim already holds the key, so the round trip
            # happens here and only the verdict travels back.
            probe = f"SHIM_SELFCHECK_{int(time.time())}"
            ok, detail, provider = False, "", None
            try:
                code_r, data_r, text_r = _ask_balancer(
                    {"goal": f"Reply with exactly: {probe}"}, attempts=2)
                if code_r < 400 and text_r:
                    provider = (data_r or {}).get("provider")
                    ok = probe in text_r
                    detail = text_r.strip()[:200]
                else:
                    detail = f"upstream {code_r}"
            except Exception as exc:
                detail = f"{type(exc).__name__}: {exc}"
            return self._send(200 if ok else 503, {
                "ok": ok, "probe": probe, "provider": provider,
                "reply": detail, "version": SHIM_VERSION,
            })

        if self.path in ("/health", "/"):
            n = max(STATS["requests_total"], 1)
            return self._send(200, {
                "ok": True,
                "service": "hermes-aios-shim",
                "version": SHIM_VERSION,
                "upstream": BRIDGE,
                "models": list(TIER_BY_MODEL),
                "auth_required": not (ALLOW_ANON or not API_KEY),
                "features": {"streaming": True, "tool_bridge": True},
                "metrics": {**STATS, "avg_latency_ms": round(STATS["latency_sum_ms"] / n, 1)},
                "served_tiers": SERVED_TIERS,
            })
        if self.path == "/metrics":
            # Prometheus text format for the observability requirement
            lines = [
                f"agent_llm_requests_total {STATS['requests_total']}",
                f"llm_requests_total {STATS['requests_total']}",
                f"llm_errors_total {STATS['requests_failed']}",
                f"llm_upstream_errors_total {STATS['upstream_errors_total']}",
                f"llm_latency_ms_last {STATS['last_latency_ms']:.1f}",
                f"llm_latency_ms_avg {STATS['latency_sum_ms'] / max(STATS['requests_total'],1):.1f}",
                f"agent_llm_auth_rejections_total {STATS['auth_rejections_total']}",
                f"llm_streaming_requests_total {STATS['streaming_requests_total']}",
                f"llm_tool_bridge_requests_total {STATS['tool_bridge_requests_total']}",
                f"llm_tool_calls_emitted_total {STATS['tool_calls_emitted_total']}",
                f"llm_tool_parse_fallbacks_total {STATS['tool_parse_fallbacks_total']}",
                f"llm_empty_reply_retries_total {STATS['empty_reply_retries_total']}",
                f"llm_tool_block_degraded_total {STATS['tool_block_degraded_total']}",
                f"llm_goal_budget_exhausted_total {STATS['goal_budget_exhausted_total']}",
                f"llm_upstream_fallback_total {STATS['upstream_fallback_total']}",
                f"llm_upstream_short_circuit_total {STATS['upstream_short_circuit_total']}",
                f"llm_tier_mismatch_total {STATS['tier_mismatch_total']}",
            ]
            lines += [f'llm_served_tier_total{{tier="{t}"}} {n}'
                      for t, n in sorted(SERVED_TIERS.items())]
            raw = ("\n".join(lines) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            return self.wfile.write(raw)
        if self.path == "/v1/models":
            data = [{"id": m, "object": "model", "owned_by": "aios-balancer"} for m in TIER_BY_MODEL]
            return self._send(200, {"object": "list", "data": data})
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            return self._send(404, {"error": "not_found", "hint": "only /v1/chat/completions is served"})
        if not self._authorized():
            STATS["auth_rejections_total"] += 1
            return self._send(401, {"error": {"message": "missing or invalid bearer token", "type": "auth_error"}})

        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length).decode() or "{}")
        except (ValueError, json.JSONDecodeError) as e:
            return self._send(400, {"error": {"message": f"bad request body: {e}", "type": "invalid_request_error"}})

        messages = req.get("messages")
        if not isinstance(messages, list) or not messages:
            return self._send(400, {"error": {"message": "messages[] required", "type": "invalid_request_error"}})

        STATS["requests_total"] += 1
        model = req.get("model") or "hermes-auto"
        tier = TIER_BY_MODEL.get(model)
        if tier is None and model in VALID_TIERS:      # allow raw tier names too
            tier = model

        stream = bool(req.get("stream"))
        tools = req.get("tools") if isinstance(req.get("tools"), list) else []
        tool_block = ""
        allowed_names: set[str] = set()
        if tools:
            STATS["tool_bridge_requests_total"] += 1
            for t in tools:
                fn = t.get("function") if isinstance(t, dict) and t.get("type") == "function" else t
                if isinstance(fn, dict) and fn.get("name"):
                    allowed_names.add(fn["name"])
            tool_block = _build_tool_block(tools)

        goal = _render_goal(
            messages,
            req.get("instructions") or req.get("system"),
            tool_block=tool_block,
        )

        payload = {"goal": goal}
        if tier:
            payload["tier"] = tier
        if req.get("temperature") is not None:
            payload["temperature"] = req["temperature"]
        if tool_block:
            # Tool replies must be machine-parseable; ask the balancer for JSON
            # where it honours the flag (cloud_only path) and as a hint elsewhere.
            payload["json_mode"] = True

        t0 = time.monotonic()
        code, data, text = _ask_balancer(payload)  # one shot; see _ask_balancer
        latency = round((time.monotonic() - t0) * 1000, 1)
        STATS["last_latency_ms"] = latency
        STATS["latency_sum_ms"] += latency

        if code < 400 and not text:
            # The balancer answered with its local boilerplate, i.e. every provider
            # failed. Surface that as an error: an agent handed boilerplate as if it
            # were a completion will "finish" a task with nothing in it.
            code, data = 503, {"error": "all upstream providers unavailable (emergency fallback)"}

        if code >= 400:
            STATS["requests_failed"] += 1
            if code >= 500:
                STATS["upstream_errors_total"] += 1
            err = {
                "error": {
                    "message": f"AIOS balancer returned {code}: {json.dumps(data)[:500]}",
                    "type": "upstream_error",
                    "upstream_status": code,
                }
            }
            # A streaming client cannot read a JSON error body cleanly, so
            # surface it as a single SSE event when a stream was requested.
            if stream:
                return self._send_sse_error(err)
            return self._send(502, err)

        served = _served_info(data)
        note_served(tier, served)
        text = flatten_upstream(data)
        calls: list[dict] = []
        if tool_block:
            calls, content = _parse_model_reply(text, allowed_names)
            if not calls and not (content or "").strip():
                # Signature of a model that never saw the request: a well-formed but
                # empty protocol object ({"content":""}). Re-ask once with nothing but
                # the task and the tool list, which is the shape that reproduces best
                # on the small fast-tier models the balancer prefers.
                STATS["empty_reply_retries_total"] += 1
                retry_goal = _render_goal(messages, None, tool_block=tool_block, budget=2200)
                code2, data2, text2 = _ask_balancer(
                    {"goal": retry_goal, "json_mode": True}, attempts=1)
                if code2 < 400 and text2:
                    calls2, content2 = _parse_model_reply(text2, allowed_names)
                    if calls2 or (content2 or "").strip():
                        calls, content, text = calls2, content2, text2
                        served = _served_info(data2)   # ответила, возможно, другая модель
                        note_served(tier, served)
                if not calls and not (content or "").strip():
                    STATS["tool_parse_fallbacks_total"] += 1
                    # Never return an empty assistant turn: the agent would
                    # silently do nothing (and the kanban worker would exit
                    # without completing its task).
                    content = ('The language model returned an empty response. '
                               'State what you know and name what is unverified.')
            STATS["tool_calls_emitted_total"] += len(calls)
        else:
            content = text

        cid = f"chatcmpl-shim-{int(time.time()*1000)}-{_uuid.uuid4().hex[:8]}"
        created = int(time.time())
        usage = {
            "prompt_tokens": max(len(goal) // 4, 1),
            "completion_tokens": max(len(text) // 4, 1),
            "total_tokens": max((len(goal) + len(text)) // 4, 1),
        }

        if stream:
            STATS["streaming_requests_total"] += 1
            if calls:
                return self._send_sse(_sse_chunks_for_tool_calls(cid, model, created, calls,
                                                                 usage, served))
            return self._send_sse(_sse_chunks_for_content(cid, model, created, content or "",
                                                           usage, served))

        # Non-streaming OpenAI response shape.
        if calls:
            msg: dict = {"role": "assistant", "content": None, "tool_calls": calls}
            finish = "tool_calls"
        else:
            msg = {"role": "assistant", "content": content or ""}
            finish = "stop"
        return self._send(200, {
            "id": cid,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
            "usage": usage,
            # Кто ответил на самом деле (клиенты OpenAI лишние поля игнорируют).
            "aios": served,
            "aios_tier": served["tier"],
            "aios_provider": served["provider"],
            "aios_cached": served["cached"],
        })


def main() -> int:
    if not API_KEY and not ALLOW_ANON:
        print("FATAL: HERMES_BALANCER_API_KEY is unset. Refusing to start an "
              "unauthenticated shim. Set the key or HERMES_SHIM_ALLOW_ANONYMOUS=1 "
              "for a throwaway test.", file=sys.stderr)
        return 2
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    print(f"hermes-aios-shim {SHIM_VERSION} listening on http://{BIND}:{PORT}/v1 -> {BRIDGE} "
          f"(streaming=on tool_bridge=on)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
