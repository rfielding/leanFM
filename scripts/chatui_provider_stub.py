#!/usr/bin/env python3
"""Local deterministic OpenAI-shaped stub for LeanFM ChatUI conformance tests."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    def _authorized(self):
        return self.headers.get("Authorization") == "Bearer test-user-key"

    def do_GET(self):
        if self.path == "/v1/models" and self._authorized():
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"object":"list","data":[{"id":"test-model"}]}')
        else:
            self.send_response(401)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        if self.path == "/v1/responses" and self._authorized():
            body = {
                "output_text": "The deterministic provider response includes a diagram.\n```mermaid\nstateDiagram-v2\n  [*] --> specified\n```",
                "usage": {
                    "input_tokens": 11,
                    "input_tokens_details": {"cached_tokens": 3},
                    "output_tokens": 7,
                    "total_tokens": 18,
                },
            }
            payload = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_response(401)
            self.end_headers()

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
