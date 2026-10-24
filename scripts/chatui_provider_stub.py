#!/usr/bin/env python3
"""Local deterministic provider protocols; never contacts a real provider."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import base64
import io
import re
import time
from threading import Lock
from PIL import Image
from chatui_specification_fixture import REQUIREMENTS as SPECIFICATION_FIXTURE, PROTO as SPECIFICATION_PROTO, IMPLEMENTATION as SPECIFICATION_IMPLEMENTATION
from chatui_specification_fixture import SERVER_SOURCE, SERVER_TEST


def content_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(part.get("text", "") for part in content if part.get("type") in {"text", "input_text"})


def image_reply(content, provider):
    images = [part for part in content if part.get("type") == ("image" if provider == "anthropic" else "input_image")]
    assert images, "image turn arrived without native image content"
    colors = []
    for part in images:
        if provider == "anthropic":
            assert part["source"]["type"] == "base64" and part["source"]["media_type"] == "image/png"
            data = part["source"]["data"]
        else:
            assert part["image_url"].startswith("data:image/png;base64,")
            data = part["image_url"].split(",", 1)[1]
        with Image.open(io.BytesIO(base64.b64decode(data, validate=True))) as image:
            assert image.format == "PNG"
            colors.append(",".join(map(str, image.convert("RGB").getpixel((0, 0)))))
    return "Image pixels received: " + "; ".join(colors)


PATCH_SCENARIOS = {"TEST_PATCH_RECOUNT", "TEST_PATCH_WRITE_RECOVERY", "TEST_PATCH_RETRY_GUARD",
                   "TEST_CHECK_RETRY_GUARD", "TEST_CHECK_FIX", "TEST_DECIDE_DEFAULTS",
                   "TEST_SPECIFY_SERVER", "TEST_SPECIFY_STARTUP_FAILURE", "TEST_SPECIFY_INVALID", "TEST_SPECIFY_REPAIR", "TEST_SPECIFY_IMPLEMENTATION", "TEST_SPECIFY_WITH_BOOK"}

FAILING_CHECK = "check:\n\t@echo 'E_FIXTURE: compile failed at line 17' >&2\n\t@exit 7\n"


def fixture_repair_line(prompt):
    excerpt = prompt.rsplit("Numbered excerpt:\n", 1)[-1]
    match = re.search(r"(?m)^(\d+): .*A & B", excerpt)
    assert match, "repair fixture did not receive the failing numbered line"
    return int(match.group(1))


def verify_decision_contract(instructions, prompt):
    assert instructions.count("CONSEQUENTIAL DECISIONS POLICY") == 1
    for obligation in ["Zero clarification questions is the normal outcome",
                       "Never invent acceptance", "Preserve the exact exit code",
                       "why the recorded decisions or a reversible default cannot resolve it"]:
        assert obligation in instructions, obligation
    assert "question-triggering instruction" not in instructions
    assert "by asking unresolved choices such as" not in prompt
    assert "Return ONLY one JSON object with exactly these string fields" not in prompt
    assert "A full-book JSON rewrite is not required for other turns" in prompt or not isinstance(prompt, str) or "Working mode:" not in prompt


def consequential_question():
    return ('The requested spectator links conflict with the recorded private-room access boundary.\n'
            '```leanfm-questions\n' + json.dumps({"questions": [{
                "id": "test_spectator_privacy",
                "prompt": "May invitation holders view private games, or must existing private access be preserved?",
                "options": [{"value": "private", "label": "Preserve private access", "recommended": True},
                            {"value": "invitation", "label": "Allow invitation holders"}]}]}) + '\n```')


def patch_action(marker, step):
    """Exercise the real tool boundary, including changed malformed arguments."""
    wrong_counts = ("--- a/spec/patch-note.txt\n+++ b/spec/patch-note.txt\n"
                    "@@ -1,90 +1,90 @@\n-before\n+after\n unrelated\n")
    malformed = "*** Begin Patch\n*** Update File: spec/patch-note.txt\n@@\n-before\n+after\n*** End Patch\n"
    if marker == "TEST_SPECIFY_REPAIR":
        bad_markdown = SPECIFICATION_FIXTURE.replace('markdown := []', 'markdown := ["Reduced server"]')
        incomplete = SPECIFICATION_FIXTURE.replace('def spec :', 'def complete :').replace(
            'end Fixture', 'def spec : RequirementSpec := {complete with tasks := [], grammars := [], '
            'processes := [], properties := [], requiredProofs := [], desiredOutputs := []}\nend Fixture')
        actions = [("leanfm_reference", {"section": "requirements"}),
                   ("workspace_write", {"path": "spec/Requirements.proto", "content": SPECIFICATION_PROTO}),
                   ("workspace_write", {"path": "spec/Requirements.lean", "content": bad_markdown}),
                   ("leanfm_check", {"requirement": "Fixture.spec"}), None,
                   ("workspace_write", {"path": "spec/Requirements.lean", "content": incomplete}),
                   ("leanfm_check", {"requirement": "Fixture.spec"}), None,
                   ("workspace_write", {"path": "spec/Requirements.lean", "content": SPECIFICATION_FIXTURE}),
                   ("leanfm_check", {"requirement": "Fixture.spec"})]
        return actions[step] if step < len(actions) else None
    if marker.startswith("TEST_SPECIFY_"):
        if marker == "TEST_SPECIFY_IMPLEMENTATION":
            actions = [("workspace_read", {"path": "spec/Implementation.lean"}),
                       ("workspace_write", {"path": "spec/Implementation.lean", "content": SPECIFICATION_IMPLEMENTATION}),
                       ("leanfm_check", {"requirement": "Fixture.spec", "implementation": "Fixture.implementation"})]
            return actions[step] if step < len(actions) else None
        source = SPECIFICATION_FIXTURE + ("\ndef broken : Nat := false\n" if marker.endswith("INVALID") else "")
        if marker.endswith("STARTUP_FAILURE"):
            # Exercise the unavailable-worker boundary without failing or
            # changing the real host compiler or process limits.
            source += '\n#eval (throw (IO.userError "failed to create thread") : IO Unit)\n'
        actions = [("leanfm_reference", {"section": "requirements"}),
                   ("workspace_read", {"path": "spec/Requirements.lean"}),
                   ("workspace_write", {"path": "spec/Requirements.lean", "content": source}),
                   ("workspace_write", {"path": "spec/Requirements.proto", "content": SPECIFICATION_PROTO}),
                   ("leanfm_check", {"requirement": "Fixture.spec"})]
        return actions[step] if step < len(actions) else None
    actions = {
        "TEST_PATCH_RECOUNT": [("workspace_patch", {"patch": wrong_counts})],
        "TEST_PATCH_WRITE_RECOVERY": [("workspace_patch", {"patch": malformed}),
            ("workspace_read", {"path": "spec/patch-note.txt"}),
            ("workspace_write", {"path": "spec/patch-note.txt", "content": "after\nunrelated\n"})],
        "TEST_PATCH_RETRY_GUARD": [("workspace_patch", {"patch": malformed}),
            ("workspace_patch", {"patch": malformed.replace("+after", "+different")})],
        "TEST_CHECK_RETRY_GUARD": [("workspace_check", {"target": "check"}),
            ("workspace_write", {"path": "Makefile", "content": FAILING_CHECK.replace("line 17", "line 18")}),
            ("workspace_check", {"target": "check"})],
        "TEST_CHECK_FIX": [("workspace_check", {"target": "check"}),
            ("workspace_write", {"path": "Makefile", "content": "check:\n\t@echo check-recovered\n"}),
            ("workspace_check", {"target": "check"})],
        "TEST_DECIDE_DEFAULTS": [("workspace_write", {"path": "spec/default-decisions.md",
            "content": "Decisions: follow existing project conventions; use a readable layout and bounded local checks. Formal acceptance remains pending.\n"})],
    }[marker]
    return actions[step] if step < len(actions) else None


def verify_specification_feedback(marker, step, feedback):
    if marker != "TEST_SPECIFY_REPAIR":
        return
    if step in {5, 8}:
        assert "LeanFM completion validation:" in feedback
        assert "do not ask the user to approve formalization" in feedback
        expected = ["Application type mismatch", "RequirementMarkdown"] if step == 5 else [
            "no task FSMs", "no multiparty grammars", "no communicating sequential processes",
            "no temporal/property annotations", "no required proof obligations", "no prompt-derived outputs"]
        for diagnostic in expected:
            assert diagnostic in feedback, (step, diagnostic, feedback)


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
            initial = request.get("input", "")
            current_input = initial if isinstance(initial, str) else "\n".join(
                content_text(item.get("content", [])) for item in initial if item.get("role") == "user")
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
            previous = request.get("previous_response_id", "")
            if marker in PATCH_SCENARIOS or previous.startswith("patch-fixture:"):
                step = 0
                if previous.startswith("patch-fixture:"):
                    _, marker, number = previous.split(":")
                    step = int(number) + 1
                if marker == "TEST_DECIDE_DEFAULTS":
                    verify_decision_contract(request.get("instructions", ""), current_input)
                if marker == "TEST_SPECIFY_REPAIR" and step == 0 and "PDF_FIRST" in current_input:
                    assert "Durable chat book update marker." in current_input
                verify_specification_feedback(marker, step, current_input)
                if marker == "TEST_SPECIFY_REPAIR" and step in {5, 8}:
                    assert request["input"][0]["role"] == "user"
                if marker.startswith("TEST_CHECK_") and step == 1:
                    output = request["input"][0]["output"]
                    assert output.startswith("ERROR:") and "exit_code=2" in output and "E_FIXTURE" in output
                action = patch_action(marker, step)
                body = {"id": f"patch-fixture:{marker}:{step}", "usage": usage}
                if action:
                    name, arguments = action
                    body["output"] = [{"type": "function_call", "call_id": f"patch-{step}",
                                       "name": name, "arguments": json.dumps(arguments)}]
                else:
                    body["output_text"] = "Completed patch fixture with preserved unrelated content."
                    if marker == "TEST_SPECIFY_WITH_BOOK":
                        body["output_text"] = json.dumps({"reply": "Specification and book updated.", "book_source": "\\documentclass{article}\n\\begin{document}\nCurrent checked server specification.\n\\end{document}\n"})
            elif marker == "TEST_IMAGE_INPUT":
                body = {"output_text": image_reply(initial[0]["content"], "openai"), "usage": usage}
            elif marker == "TEST_READY_DEFAULTS":
                verify_decision_contract(request.get("instructions", ""), current_input)
                body = {"output_text": "Routine choices are settled. The draft is ready for requirements review; formal acceptance remains pending.", "usage": usage}
            elif marker == "TEST_DURABLE_RESUME":
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
            elif marker == "TEST_TOOL_BUDGET":
                body = {"id": "budget-response", "usage": {"input_tokens": 999990,
                        "output_tokens": 10, "total_tokens": 1000000}, "output": [
                    {"type": "function_call", "call_id": "budget-write", "name": "workspace_write",
                     "arguments": json.dumps({"path": "spec/budget-note.txt", "content": "Completed before budget stop.\n"})}]}
            elif marker == "TEST_REPEATED_TOOL_FAILURE" or request.get("previous_response_id") == "repeat-failed-read":
                body = {"id": "repeat-failed-read", "usage": usage, "output": [
                    {"type": "function_call", "call_id": "failed-read", "name": "workspace_read",
                     "arguments": json.dumps({"path": "spec/never-existed.txt"})}]}
            elif marker == "TEST_RECOVER_JSON_MATH":
                edit = {"reply": "Updated the book with deterministic JSON recovery.",
                        "book_source": "\\documentclass{article}\n\\begin{document}\nThe value is \\(x+1\\).\n\\end{document}\n"}
                # Reproduce the real failure: legal LaTeX, illegal JSON escapes.
                text = json.dumps(edit).replace(r"\\(", r"\(").replace(r"\\)", r"\)")
                body = {"output_text": text, "usage": usage}
            elif "Current user message:\nTEST_RETURN_STRUCTURED_QUESTION" in current_input:
                body = {"output_text": consequential_question(), "usage": usage}
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
                edit = {"line_number": fixture_repair_line(current_input), "replacement": "Still broken: C & D. TEST_REPEAT_BOOK"}
                body = {"output_text": json.dumps(edit), "usage": usage}
            elif "You repair exactly one failing line" in request_text and "TEST_REPAIR_BOOK" in request_text:
                time.sleep(1)
                edit = {"line_number": fixture_repair_line(current_input), "replacement": "Repaired durable book: A \\& B. TEST\\_REPAIR\\_BOOK"}
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
                            "content": SERVER_SOURCE,
                        }),
                    }, {
                        "type": "function_call", "call_id": "write-source-tests", "name": "workspace_write",
                        "arguments": json.dumps({"path": "source/main_test.go", "content": SERVER_TEST}),
                    }, {
                        "type": "function_call", "call_id": "write-source-module", "name": "workspace_write",
                        "arguments": json.dumps({"path": "source/go.mod", "content": "module example.com/fixture\n\ngo 1.23\n"}),
                    }],
                    "usage": usage,
                }
            elif request.get("previous_response_id") == "source-write-response":
                time.sleep(1)
                body = {
                    "id": "source-checked-response",
                    "output": [{"type": "function_call", "call_id": "check-source", "name": "workspace_check", "arguments": json.dumps({"target": "go-test"})}],
                    "usage": usage,
                }
            elif request.get("previous_response_id") == "source-checked-response":
                body = {"output_text": "Created and checked source/main.go.", "usage": usage}
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
        text = content_text(messages[0].get("content", "")) if messages else ""
        marker = text.rsplit("Current user message:\n", 1)[-1].split(" ", 1)[0].split("\n", 1)[0]
        system = request.get("system", "")
        repair = "You repair exactly one failing line" in system
        if (request.get("model") not in {"claude-test", "claude-test-fast"}
                or "input" in request or "previous_response_id" in request
                or request.get("max_tokens", 0) > (16384 if request.get("model") == "claude-test" else 4096)
                or (not repair and not request.get("tools"))
                or (not repair and request.get("cache_control") != {"type": "ephemeral"})):
            self._increment("invalid_messages")
            return self._json(400, {"error": {"type": "invalid_request_error", "message": "Invalid Messages protocol"}})
        usage = {"input_tokens": 7, "cache_creation_input_tokens": 2,
                 "cache_read_input_tokens": 3, "output_tokens": 5}
        stop = "end_turn"
        text_block = lambda value: {"type": "text", "text": value}
        if marker == "TEST_IMAGE_INPUT":
            return self._json(200, {"content": [text_block(image_reply(messages[0]["content"], "anthropic"))],
                                   "stop_reason": "end_turn", "usage": usage})
        content = [text_block("Anthropic credential " + (
            "alice" if self.headers.get("x-api-key") == "anthropic-user-key" else "bob") +
            " model " + request.get("model", "missing"))]
        if marker in PATCH_SCENARIOS:
            step = len(messages) // 2
            verify_specification_feedback(marker, step, content_text(messages[-1]["content"]))
            if marker == "TEST_DECIDE_DEFAULTS":
                verify_decision_contract(system, text)
            if marker.startswith("TEST_CHECK_") and step == 1:
                result = messages[-1]["content"][0]
                assert result["is_error"] is True
                assert "exit_code=2" in result["content"] and "E_FIXTURE" in result["content"]
            action = patch_action(marker, step)
            if action:
                name, arguments = action
                stop, content = "tool_use", [{"type": "tool_use", "id": f"patch-{step}",
                    "name": name, "input": arguments}]
            else:
                content = [text_block("Completed patch fixture with preserved unrelated content.")]
                if marker == "TEST_SPECIFY_WITH_BOOK":
                    content = [text_block(json.dumps({"reply": "Specification and book updated.", "book_source": "\\documentclass{article}\n\\begin{document}\nCurrent checked server specification.\n\\end{document}\n"}))]
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
        if marker == "TEST_ANTHROPIC_WRAPPED_BOOK":
            envelope = json.dumps({"reply": "Recovered complete book without another request.",
                "book_source": "\\documentclass{article}\n\\begin{document}\nWrapped book marker.\n\\end{document}\n"})
            content = [text_block("Here is the updated book:"), text_block("```json\n" + envelope + "\n```"), text_block("Done.")]
        if marker == "TEST_ANTHROPIC_AMBIGUOUS_BOOK":
            envelope = json.dumps({"reply": "HIDDEN_AMBIGUOUS_REPLY", "book_source": "HIDDEN_AMBIGUOUS_SOURCE"})
            content = [text_block("Two alternatives:\n" + envelope + "\n" + envelope)]
        if marker == "TEST_ANTHROPIC_TOOL_BUDGET":
            usage = {"input_tokens": 999990, "output_tokens": 10}
            stop, content = "tool_use", [{"type": "tool_use", "id": "budget-write", "name": "workspace_write",
                "input": {"path": "spec/budget-note.txt", "content": "Completed before budget stop.\n"}}]
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
        if marker in {"TEST_ANTHROPIC_REPAIR", "TEST_ANTHROPIC_REJECTED_REPAIR"} and not repair:
            content = [text_block(json.dumps({"reply": "Repair this book through the selected provider.",
                "book_source": "\\documentclass{article}\n\\usepackage{underscore}\n\\begin{document}\nBroken A & B. " + marker + "\n\\end{document}\n"}))]
        if repair:
            content = [text_block(json.dumps({"line_number": 10000 if "TEST_ANTHROPIC_REJECTED_REPAIR" in text else fixture_repair_line(text),
                                             "replacement": "Repaired A \\& B."}))]
        if marker == "TEST_READY_DEFAULTS":
            verify_decision_contract(system, text)
            content = [text_block("Routine choices are settled. The draft is ready for requirements review; formal acceptance remains pending.")]
        if marker == "TEST_RETURN_STRUCTURED_QUESTION":
            content = [text_block(consequential_question())]
        self._json(200, {"id": "anthropic-response", "type": "message", "role": "assistant",
                         "content": content, "model": request["model"], "stop_reason": stop, "usage": usage})

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
