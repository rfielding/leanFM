#!/usr/bin/env python3
"""Local deterministic OpenAI-shaped stub for LeanFM ChatUI conformance tests."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time
from threading import Lock


class Handler(BaseHTTPRequestHandler):
    request_count = 0
    count_lock = Lock()
    def _authorized(self):
        return self.headers.get("Authorization") in {"Bearer test-user-key", "Bearer second-user-key"}

    def do_GET(self):
        if self.path == "/test/requests" and self._authorized():
            with self.count_lock:
                payload = json.dumps({"requests": Handler.request_count}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
        elif self.path == "/v1/models" and self._authorized():
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
            with self.count_lock:
                Handler.request_count += 1
            request = json.loads(raw_request or b"{}")
            request_text = json.dumps(request)
            usage = {
                "input_tokens": 11,
                "input_tokens_details": {"cached_tokens": 3},
                "output_tokens": 7,
                "total_tokens": 18,
            }
            current_input = request.get("input", "") if isinstance(request.get("input", ""), str) else ""
            marker = current_input.rsplit("Current user message:\n", 1)[-1].split(" ", 1)[0].split("\n", 1)[0]
            response_status = 200
            error_cases = {
                "TEST_CREDIT_EXHAUSTED": ("credit_balance_exhausted", "insufficient_quota"),
                "TEST_PROJECT_SPEND": ("project_spend_limit_exceeded", "insufficient_quota"),
                "TEST_ORGANIZATION_SPEND": ("organization_spend_limit_exceeded", "insufficient_quota"),
                "TEST_ORGANIZATION_USAGE": ("organization_usage_limit_exceeded", "insufficient_quota"),
                "TEST_LEGACY_QUOTA": ("insufficient_quota", "insufficient_quota"),
                "TEST_RATE_LIMIT": ("rate_limit_exceeded", "rate_limit_error"),
                "TEST_UNKNOWN_PROVIDER_ERROR": ("sk-HIDDEN_PROVIDER_SECRET", "HIDDEN_PROVIDER_TYPE"),
            }
            if marker in error_cases:
                code, error_type = error_cases[marker]
                response_status = 429
                body = {"error": {"code": code, "type": error_type,
                                  "message": "HIDDEN_PROVIDER_BODY must never reach chat or diagnostics"}}
            elif marker in {"TEST_INCOMPLETE_TEXT", "TEST_INCOMPLETE_TOOL"}:
                body = {
                    "id": "incomplete-response",
                    "status": "incomplete",
                    "incomplete_details": {"reason": "max_output_tokens"},
                    "usage": usage,
                }
                if marker == "TEST_INCOMPLETE_TOOL":
                    body["output"] = [{"type": "function_call", "call_id": "must-not-run",
                                       "name": "workspace_write", "arguments": json.dumps({
                                           "path": "source/incomplete-must-not-exist.go",
                                           "content": "HIDDEN_INCOMPLETE_TOOL"})}]
                else:
                    body["output_text"] = json.dumps({"reply": "HIDDEN_INCOMPLETE_REPLY",
                                                       "book_source": "HIDDEN_INCOMPLETE_BOOK"})
            elif marker == "TEST_MALFORMED_BOOK_ENVELOPE":
                body = {"output_text": '{"reply":"Not a successful update","book_source":"HIDDEN_BOOK_SOURCE ```leanfm-questions',
                        "usage": usage}
            elif marker == "TEST_RECOVER_JSON_MATH":
                edit = {"reply": "Updated the book with deterministic JSON recovery.",
                        "book_source": "\\documentclass{article}\n\\begin{document}\nThe value is \\(x+1\\).\n\\end{document}\n"}
                # Reproduce the real failure: legal LaTeX, illegal JSON escapes.
                text = json.dumps(edit).replace(r"\\(", r"\(").replace(r"\\)", r"\)")
                body = {"output_text": text, "usage": usage}
            elif "Current user message:\nTEST_RETURN_STRUCTURED_QUESTION" in current_input:
                body = {
                    "output_text": (
                        "How many MCTS playouts should be used?\n"
                        "```leanfm-questions\n"
                        "{\"questions\":[{\"id\":\"test_mcts_budget\",\"prompt\":\"How many MCTS playouts should be used?\",\"options\":[{\"value\":\"1000\",\"label\":\"1000\"}]}]}\n"
                        "```"
                    ),
                    "usage": usage,
                }
            elif "TEST_MISSING_IMAGE_REPEAT" in request_text and "single bounded recovery attempt" in request_text:
                body = {"output_text": "Image created: [preview](spec/images/never-created-twice.png)", "usage": usage}
            elif "Current user message:\nTEST_MISSING_IMAGE_REPEAT" in current_input:
                body = {"output_text": "Image created: [preview](spec/images/never-created-twice.png)", "usage": usage}
            elif "TEST_MISSING_IMAGE_REFERENCE" in request_text and "single bounded recovery attempt" in request_text:
                edit = {
                    "reply": "Replaced the nonexistent image link with a self-contained vector illustration in the PDF source.",
                    "book_source": (
                        "\\documentclass{article}\n"
                        "\\usepackage{tikz}\n"
                        "\\begin{document}\n"
                        "\\begin{center}\\begin{tikzpicture}\\draw[fill=blue!20] (0,0) circle (1cm);\\end{tikzpicture}\\end{center}\n"
                        "\\end{document}\n"
                    ),
                }
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "Current user message:\nTEST_MISSING_IMAGE_REFERENCE" in current_input:
                body = {
                    "output_text": "Image created: [preview](spec/images/never-created.png)",
                    "usage": usage,
                }
            elif "Current user message:\nTEST_MODEL_SELECTION" in current_input:
                body = {
                    "output_text": "selected model: " + request.get("model", "missing"),
                    "usage": usage,
                }
            elif "You repair exactly one failing line" in request_text and "TEST_REPEAT_BOOK" in request_text:
                edit = {"line_number": 4, "replacement": "Still broken: C & D. TEST_REPEAT_BOOK"}
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "You repair exactly one failing line" in request_text and "TEST_REPAIR_BOOK" in request_text:
                time.sleep(1)
                edit = {"line_number": 4, "replacement": "Repaired durable book: A \\& B. TEST\\_REPAIR\\_BOOK"}
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
                        "Math subscript regression: $E_a$.\n"
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
            if response_status == 200:
                body.setdefault("status", "completed")
            payload = json.dumps(body).encode()
            self.send_response(response_status)
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
