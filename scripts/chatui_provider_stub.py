#!/usr/bin/env python3
"""Local deterministic provider protocols; never contacts a real provider."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time
from threading import Lock


class Handler(BaseHTTPRequestHandler):
    request_count = 0
    stats = {"openai_models": 0, "anthropic_models": 0, "anthropic_requests": 0,
             "wrong_headers": 0, "invalid_messages": 0}
    count_lock = Lock()

    def _increment(self, name):
        with self.count_lock:
            Handler.stats[name] += 1

    def _authorized(self):
        if self.headers.get("x-api-key") or self.headers.get("anthropic-version"):
            self._increment("wrong_headers")
            return False
        return self.headers.get("Authorization") in {"Bearer test-user-key", "Bearer second-user-key",
                                                      "Bearer rotated-openai-key"}

    def _anthropic_authorized(self):
        if self.headers.get("Authorization") or self.headers.get("anthropic-version") != "2023-06-01":
            self._increment("wrong_headers")
            return False
        return self.headers.get("x-api-key") in {"anthropic-user-key", "anthropic-second-key",
                                                "anthropic-rotated-key"}

    def _json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/test/requests" and self._authorized():
            with self.count_lock:
                payload = json.dumps({"requests": Handler.request_count, **Handler.stats}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
        elif self.path == "/v1/models" and self._authorized():
            self._increment("openai_models")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"object":"list","data":[{"id":"test-model"},{"id":"test-model-fast"},{"id":"text-embedding-test"},{"id":"gpt-test-audio"}]}')
        elif self.path.split("?", 1)[0] == "/anthropic/v1/models" and self._anthropic_authorized():
            self._increment("anthropic_models")
            self._json(200, {"has_more": False, "data": [
                {"id": "claude-test", "display_name": "Claude Test", "max_tokens": 16384,
                 "max_input_tokens": 200000,
                 "capabilities": {"server_tools": {"web_search": {"supported": True}}}},
                {"id": "claude-test-fast", "display_name": "Claude Test Fast", "max_tokens": 4096},
                {"id": "claude-retired", "lifecycle": "retired"}]})
        else:
            self.send_response(401)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw_request = self.rfile.read(length)
        if self.path == "/anthropic/v1/messages" and self._anthropic_authorized():
            self._increment("anthropic_requests")
            return self._anthropic_message(json.loads(raw_request or b"{}"))
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
            if marker == "TEST_DURABLE_RESUME":
                required = ["DURABLE RESUME INPUTS", "durable-book-marker", "durable-requirements-marker",
                            "DurableProtocolMarker", "durable-implementation-marker", "resume_marker.txt",
                            "durable-acceptance-marker"]
                forbidden = ["ERASED_CHAT_SENTINEL", "FOREIGN_PROJECT_SENTINEL"]
                missing = [value for value in required if value not in current_input]
                leaked = [value for value in forbidden if value in current_input]
                body = {"output_text": "Durable resume verified without chat history." if not missing and not leaked
                        else "RESET_CONTEXT_FAILURE: missing=" + repr(missing) + " leaked=" + repr(leaked), "usage": usage}
            elif marker in error_cases:
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
            elif marker == "TEST_PROVIDER_ROUTE":
                body = {"output_text": "OpenAI credential " + (
                    "alice" if self.headers.get("Authorization") == "Bearer test-user-key" else "bob") +
                    " model " + request.get("model", "missing"), "usage": usage}
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

    def _anthropic_message(self, request):
        messages = request.get("messages", [])
        text = str(messages[0].get("content", "")) if messages else ""
        marker = text.rsplit("Current user message:\n", 1)[-1].split(" ", 1)[0].split("\n", 1)[0]
        system = request.get("system", "")
        repair = "You repair exactly one failing line" in system
        if (request.get("model") not in {"claude-test", "claude-test-fast"}
                or "input" in request or "previous_response_id" in request
                or request.get("max_tokens", 0) > (16384 if request.get("model") == "claude-test" else 4096)
                or (not repair and not request.get("tools"))):
            self._increment("invalid_messages")
            return self._json(400, {"error": {"type": "invalid_request_error", "message": "Invalid Messages protocol"}})
        usage = {"input_tokens": 7, "cache_creation_input_tokens": 2,
                 "cache_read_input_tokens": 3, "output_tokens": 5}
        stop = "end_turn"
        text_block = lambda value: {"type": "text", "text": value}
        content = [text_block("Anthropic credential " + (
            "alice" if self.headers.get("x-api-key") == "anthropic-user-key" else "bob") +
            " model " + request.get("model", "missing"))]
        if marker == "TEST_ANTHROPIC_BILLING":
            return self._json(402, {"error": {"type": "billing_error",
                                             "message": "HIDDEN_ANTHROPIC_BODY"}})
        if marker == "TEST_ANTHROPIC_PAUSE":
            if len(messages) == 1:
                stop, content = "pause_turn", [text_block("Working on server tools.")]
            else:
                assert messages[-1] == {"role": "assistant", "content": [text_block("Working on server tools.")]}
                content = [text_block("Completed paused turn.")]
        if marker == "TEST_ANTHROPIC_UNFINISHED":
            stop, content = "tool_use", [text_block("Not a completed answer.")]
        if marker in {"TEST_ANTHROPIC_TOOL", "TEST_ANTHROPIC_INCOMPLETE", "TEST_ANTHROPIC_CANCEL", "TEST_ANTHROPIC_DUPLICATE"}:
            if len(messages) == 1:
                if marker == "TEST_ANTHROPIC_CANCEL":
                    time.sleep(2)
                stop = "max_tokens" if marker == "TEST_ANTHROPIC_INCOMPLETE" else "tool_use"
                path = "spec/anthropic-note.txt" if marker == "TEST_ANTHROPIC_TOOL" else "spec/must-not-exist.txt"
                content = [{"type": "tool_use", "id": "native-write", "name": "workspace_write",
                            "input": {"path": path, "content": "Native Anthropic workspace note.\n"}}]
                if marker == "TEST_ANTHROPIC_DUPLICATE":
                    content = content * 2
            else:
                # Tool results must refer to the exact native assistant tool ID.
                valid = (len(messages) == 3 and messages[1]["role"] == "assistant"
                         and messages[1]["content"][0]["id"] == "native-write"
                         and messages[2]["role"] == "user"
                         and messages[2]["content"][0]["type"] == "tool_result"
                         and messages[2]["content"][0]["tool_use_id"] == "native-write"
                         and messages[2]["content"][0]["is_error"] is False)
                if not valid:
                    self._increment("invalid_messages")
                    return self._json(400, {"error": {"type": "invalid_request_error"}})
                content = [text_block("Saved spec/anthropic-note.txt through the native tool protocol.")]
        if marker == "TEST_ANTHROPIC_BOOK":
            content = [text_block(json.dumps({"reply": "Updated the book through Anthropic.",
                "book_source": "\\documentclass{article}\n\\begin{document}\nAnthropic durable book.\n\\end{document}\n"}))]
        if marker == "TEST_ANTHROPIC_REPAIR" and not repair:
            content = [text_block(json.dumps({"reply": "Repair this book through the selected provider.",
                "book_source": "\\documentclass{article}\n\\usepackage{underscore}\n\\begin{document}\nBroken A & B.\n\\end{document}\n"}))]
        if repair:
            content = [text_block(json.dumps({"line_number": 4, "replacement": "Repaired A \\& B."}))]
        self._json(200, {"id": "anthropic-response", "type": "message", "role": "assistant",
                         "content": content, "model": request["model"], "stop_reason": stop, "usage": usage})

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
