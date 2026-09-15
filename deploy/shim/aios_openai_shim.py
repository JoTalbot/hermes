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

SHIM_VERSION = "1.2.0"

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
}


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
TOOL_PROTOCOL_HEADER = """[TOOL PROTOCOL — READ CAREFULLY]
You can call functions. Reply with EXACTLY ONE JSON object and nothing else.
No prose, no markdown fences, no commentary before or after.

To call one or more functions:
{"tool_calls":[{"name":"<function_name>","arguments":{<json object>}}]}

To answer the user without calling a function:
{"content":"<your full answer as a plain string>"}

Rules:
- "arguments" must be a JSON object matching the function's parameters.
- Emit only function names from the list below; never invent one.
- If you already have the answer, use the {"content":...} form.
- Never wrap the JSON in ``` fences.

AVAILABLE FUNCTIONS:
"""


def _render_tools(tools: list) -> str:
    """Compact, deterministic rendering of OpenAI tool schemas for the prompt."""
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
        if len(desc) > MAX_TOOL_DESC:
            desc = desc[:MAX_TOOL_DESC] + "…"
        params = fn.get("parameters") or {}
        props = params.get("properties") or {}
        required = set(params.get("required") or [])
        arg_bits = []
        for pname, pspec in list(props.items())[:25]:
            ptype = (pspec or {}).get("type", "any") if isinstance(pspec, dict) else "any"
            mark = "" if pname in required else "?"
            arg_bits.append(f"{pname}{mark}:{ptype}")
        sig = ", ".join(arg_bits)
        lines.append(f"{i + 1}. {name}({sig}) — {desc}")
    if len(tools) > MAX_TOOLS_RENDERED:
        lines.append(f"... ({len(tools) - MAX_TOOLS_RENDERED} more tools omitted)")
    return "\n".join(lines)


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


def _render_goal(messages: list, system_extra=None, tool_block: str = "") -> str:
    """Flatten an OpenAI message list into the single `goal` string AIOS wants.

    Deliberately lossy: AIOS /ask has no notion of multi-turn. We keep tool
    results and the system prompt so Hermes still gets its context, but the
    balancer sees one instruction. If your agents need true multi-turn with
    provider-side history, front Hermes with a real OpenAI-compatible
    provider instead of this shim (see docs/BALANCER.md "Known lossy path").
    """
    parts = []
    if system_extra:
        parts.append(f"[system] {system_extra}")
    if tool_block:
        parts.append(tool_block)
    for m in messages:
        chunk = _render_history_message(m)
        if chunk:
            parts.append(chunk)
    return "\n".join(parts).strip() or "(empty)"


# ---------------------------------------------------------- SSE re-emitter
def _sse_chunks_for_content(cid: str, model: str, created: int, text: str,
                            usage: dict | None = None):
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
    yield f"data: {json.dumps({'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': model, **final}, ensure_ascii=False)}\n\n".encode()
    yield b"data: [DONE]\n\n"


def _sse_chunks_for_tool_calls(cid: str, model: str, created: int, calls: list[dict],
                               usage: dict | None = None):
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

    def _authorized(self) -> bool:
        if ALLOW_ANON or not API_KEY:
            return True
        got = self.headers.get("Authorization", "")
        return got.strip() == f"Bearer {API_KEY}"

    # -- routes ----------------------------------------------------------
    def do_GET(self):
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
            ]
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
            tool_block = TOOL_PROTOCOL_HEADER + _render_tools(tools)

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
        code, data = _post_json("/api/v1/aios/ask", payload)
        latency = round((time.monotonic() - t0) * 1000, 1)
        STATS["last_latency_ms"] = latency
        STATS["latency_sum_ms"] += latency

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
            # surface it as a single SSE error event when stream was requested.
            if stream:
                payload_err = json.dumps(err, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                try:
                    self.wfile.write(b"%X\r\n" % len(payload_err) + b"data: " + payload_err + b"\r\n\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            return self._send(502, err)

        text = flatten_upstream(data)
        calls: list[dict] = []
        if tool_block:
            calls, content = _parse_model_reply(text, allowed_names)
            if not calls and not content:
                STATS["tool_parse_fallbacks_total"] += 1
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
                return self._send_sse(_sse_chunks_for_tool_calls(cid, model, created, calls, usage))
            return self._send_sse(_sse_chunks_for_content(cid, model, created, content or "", usage))

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
