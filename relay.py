#!/usr/bin/env python3
"""
Lightweight relay: sits between Claude Code (at ANTHROPIC_BASE_URL=http://localhost:8765)
and the upstream proxy (cc.honoursoft.cn).
Rewrites model names from Anthropic canonical names to the upstream's aliases.
"""
import http.server
import json
import urllib.request
import urllib.error
import sys

UPSTREAM = "https://cc.honoursoft.cn"
PORT = 8765

# Map Anthropic canonical model names -> upstream alias that exists on the relay
MODEL_MAP = {
    "claude-sonnet-4-5": "claude-sonnet-4-6",
    "claude-sonnet-4-5-20250929": "claude-sonnet-4-6",
    "claude-sonnet-4-6": "claude-sonnet-4-6",
    "claude-sonnet-4-6-thinking": "claude-sonnet-4-6-thinking",
    "claude-opus-4-7": "claude-opus-4-7",
    "claude-opus-4-8": "claude-opus-4-8",
    "claude-haiku-4-5": "claude-haiku-4-5-20251001",
}

def rewrite_model(obj):
    if isinstance(obj, dict):
        if "model" in obj and isinstance(obj["model"], str):
            m = obj["model"]
            for k, v in MODEL_MAP.items():
                if m == k or m.startswith(k + "["):
                    obj["model"] = v + m[len(k):]
                    break
        for v in obj.values():
            rewrite_model(v)
    elif isinstance(obj, list):
        for item in obj:
            rewrite_model(item)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[relay] " + (fmt % args) + "\n")

    def do_GET(self):
        # Forward /v1/models so Claude Code discovery works
        url = UPSTREAM + self.path
        try:
            req = urllib.request.Request(url, headers=self._forward_headers(skip_body=True))
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
                if self.path.endswith("/models"):
                    try:
                        data = json.loads(body)
                        if "data" in data:
                            for entry in data["data"]:
                                if entry.get("id") in MODEL_MAP.values():
                                    entry["display_name"] = entry["id"]
                                    entry["id"] = [k for k, v in MODEL_MAP.items() if v == entry["id"]][0]
                        body = json.dumps(data).encode()
                    except Exception:
                        pass
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in ("transfer-encoding", "connection"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(body.decode("utf-8"))
            rewrite_model(payload)
            body = json.dumps(payload).encode("utf-8")
        except Exception as e:
            sys.stderr.write(f"[relay] body parse error: {e}\n")

        url = UPSTREAM + self.path
        try:
            req = urllib.request.Request(
                url, data=body, method="POST",
                headers=self._forward_headers(skip_body=False)
            )
            with urllib.request.urlopen(req, timeout=300) as resp:
                resp_body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in ("transfer-encoding", "connection"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)
        except urllib.error.HTTPError as e:
            err_body = e.read()
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(err_body)

    def _forward_headers(self, skip_body):
        h = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in ("host", "content-length", "connection"):
                continue
            if skip_body and lk == "content-type":
                continue
            h[k] = v
        return h

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"[relay] listening on 127.0.0.1:{PORT} -> {UPSTREAM}\n")
    server.serve_forever()
