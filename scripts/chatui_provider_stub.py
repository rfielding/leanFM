#!/usr/bin/env python3
"""Local deterministic OpenAI-shaped stub for LeanFM ChatUI conformance tests."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


class Handler(BaseHTTPRequestHandler):
    def _authorized(self):
        return self.headers.get("Authorization") in {"Bearer test-user-key", "Bearer second-user-key"}

    def do_GET(self):
        if self.path == "/v1/models" and self._authorized():
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"object":"list","data":[{"id":"test-model"},{"id":"test-model-fast"},{"id":"text-embedding-test"},{"id":"gpt-test-audio"}]}')
        else:
            self.send_response(401)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw_request = self.rfile.read(length)
        if self.path == "/v1/responses" and self._authorized():
            request = json.loads(raw_request or b"{}")
            request_text = json.dumps(request)
            usage = {
                "input_tokens": 11,
                "input_tokens_details": {"cached_tokens": 3},
                "output_tokens": 7,
                "total_tokens": 18,
            }
            current_input = request.get("input", "") if isinstance(request.get("input", ""), str) else ""
            if "Current user message:\nTEST_MODEL_SELECTION" in current_input:
                body = {
                    "output_text": "selected model: " + request.get("model", "missing"),
                    "usage": usage,
                }
            elif "You repair exactly one failing line" in request_text and "TEST_REPEAT_BOOK" in request_text:
                edit = {"line_number": 3, "replacement": "Still broken: C & D. TEST_REPEAT_BOOK"}
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "You repair exactly one failing line" in request_text and "TEST_REPAIR_BOOK" in request_text:
                time.sleep(1)
                edit = {"line_number": 3, "replacement": "Repaired durable book: A \\& B. TEST\\_REPAIR\\_BOOK"}
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "TEST_CANCEL_AGENT" in request_text:
                time.sleep(1)
                body = {
                    "id": "cancelled-source-write-response",
                    "output": [{
                        "type": "function_call",
                        "call_id": "cancelled-write-1",
                        "name": "workspace_write",
                        "arguments": json.dumps({
                            "path": "source/must-not-exist.go",
                            "content": "package cancelled\n",
                        }),
                    }],
                    "usage": usage,
                }
            elif "Current user message:\nTEST_UNDERSCORE_BOOK" in current_input:
                edit = {
                    "reply": "The screenshot path was repaired deterministically.",
                    "book_source": (
                        "\\documentclass{book}\n"
                        "\\begin{document}\n"
                        "Screenshot: spec/images/goban_frame_001.png TEST_UNDERSCORE_BOOK\n"
                        "\\end{document}\n"
                    ),
                }
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "Current user message:\nTEST_REPEAT_BOOK" in current_input:
                edit = {
                    "reply": "The repeated diagnostic fixture must stop after one repair.",
                    "book_source": (
                        "\\documentclass{book}\n"
                        "\\begin{document}\n"
                        "Broken durable book: A & B. TEST_REPEAT_BOOK\n"
                        "\\end{document}\n"
                    ),
                }
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "Current user message:\nTEST_REPAIR_BOOK" in current_input:
                edit = {
                    "reply": "Requested MCP animation remains visible after internal repair.",
                    "book_source": (
                        "\\documentclass{book}\n"
                        "\\begin{document}\n"
                        "Broken durable book: A & B. TEST_REPAIR_BOOK\n"
                        "\\end{document}\n"
                    ),
                }
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "TEST_WRITE_SOURCE" in request_text and "previous_response_id" not in request:
                body = {
                    "id": "source-write-response",
                    "output": [{
                        "type": "function_call",
                        "call_id": "write-source-1",
                        "name": "workspace_write",
                        "arguments": json.dumps({
                            "path": "source/main.go",
                            "content": "package main\n\nfunc main() {}\n",
                        }),
                    }],
                    "usage": usage,
                }
            elif request.get("previous_response_id") == "source-write-response":
                time.sleep(1)
                body = {
                    "output_text": "Created and checked source/main.go.",
                    "usage": usage,
                }
            elif "TEST_UPDATE_BOOK" in request_text:
                edit = {
                    "reply": "Updated the durable project book.",
                    "book_source": (
                        "\\documentclass{book}\n"
                        "\\begin{document}\n"
                        "Durable chat book update marker.\n"
                        "\\end{document}\n"
                    ),
                }
                body = {"output_text": json.dumps(edit), "usage": usage}
            else:
                body = {
                "output_text": ("alice response: " if self.headers.get("Authorization") == "Bearer test-user-key" else "bob response: ") + "The deterministic provider response includes a diagram.\n```mermaid\nstateDiagram-v2\n  [*] --> specified\n```",
                    "usage": usage,
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
