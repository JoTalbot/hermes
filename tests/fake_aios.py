"""Fake octopus-aios bridge reproducing the MEASURED contract on arm-server-01.

Routes and validation errors were copied from live responses on 2026-09-15:
  POST /api/v1/aios/ask      {"goal": str, "tier"?: str}   → 422 if goal missing
  POST /api/v1/aios/execute  {"goal": str}                 → 422 if goal missing
  GET  /health                                            → the 11-provider payload
Anything else 404s, exactly like the real service.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PROVIDERS = [
    ("cerebras-llama3.3-70b","fast",2,3),("groq-gpt-oss-20b","fast",1,13),
    ("groq-qwen3.8-27b","fast",2,13),("groq-gpt-oss-120b","reasoning",3,13),
    ("mistral-small","code",7,1),("gemini-gemini-2.5-flash","long_context",10,2),
    ("hf-Qwen2.5-72B-Instruct","code",15,1),("liza-rpa-gemini-web","long_context",18,0),
    ("ollama-qwen2.5:1.5b","local",20,0),("ollama-llama3.2:3b","local",25,0),
    ("autonomous_heuristic_engine","local",999,0),
]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path == "/health":
            return self._j(200, {"ok":True,"service":"octopus-aios-bridge","version":"1.1.0",
                "aios_kernel_state":"running","total_tasks_processed":0,
                "llm_balancer":{"total_providers":len(PROVIDERS),"cache_size":0,
                    "providers":[{"name":n,"tier":t,"healthy":True,"weight":w,"calls":0,
                                  "avg_latency_ms":0.0,"keys_count":k} for n,t,w,k in PROVIDERS]}})
        return self._j(404, {"detail":"Not Found"})
    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length","0"))) or b"{}")
        except ValueError:
            return self._j(400, {"detail":"invalid json"})
        if self.path in ("/api/v1/aios/ask","/api/v1/aios/execute"):
            if "goal" not in body:                       # real FastAPI 422 shape
                return self._j(422, {"detail":[{"type":"missing","loc":["body","goal"],
                                                "msg":"Field required","input":body}]})
            return self._j(200, {"answer": f"FAKE_OK[{body.get('tier','any')}]",
                                 "provider":"groq-qwen3.8-27b","tier":body.get("tier"),"ok":True})
        return self._j(404, {"detail":"Not Found"})

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 9699), H).serve_forever()
