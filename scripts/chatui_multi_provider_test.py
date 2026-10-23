#!/usr/bin/env python3
"""Two-provider BYOK conformance. All API calls go to local deterministic stubs.

Requirement refs: one_password_unlocks_all_provider_keys,
selected_model_determines_provider_credential, provider_protocols_preserve_workspace_controls,
stored_provider_keys_are_encrypted, provider_outcomes_are_distinguishable.
"""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import base64
import io
import random
import http.cookiejar
import json
from pathlib import Path
import socket
import sys
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from PIL import Image


BASE, DATA = sys.argv[1:3]
AFTER_RESTART = "--after-restart" in sys.argv[3:]
assert urllib.parse.urlparse(BASE).hostname == "127.0.0.1"
ROOT = Path(DATA)
PASSWORD = "multi provider test password"
CLAUDE = "anthropic:claude-test"


class Client:
    def __init__(self):
        self.cookies = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookies))

    def request(self, path, form=None, json_body=None):
        request = urllib.request.Request(BASE + path, data=None if form is None else
                                         urllib.parse.urlencode(form).encode())
        if json_body is not None:
            request.data = json.dumps(json_body).encode()
            request.add_header("Content-Type", "application/json")
        try:
            with self.opener.open(request, timeout=90) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def login(self, username, **keys):
        return self.request("/api/login", {"username": username, "password": PASSWORD, **keys})

    def register(self, username, **keys):
        status, body = self.request("/api/accounts", {"username": username, "password": PASSWORD, **keys})
        assert status == 201, (status, body)
        return self

    def project(self):
        status, body = self.request("/api/projects", {"display_name": "Provider conformance"})
        assert status == 201, (status, body)
        return body["project_id"]

    def chat(self, project, marker, model=CLAUDE):
        return self.request(f"/api/projects/{project}/chat", {"prompt": marker, "model": model})


def stats():
    request = urllib.request.Request("http://127.0.0.1:18080/test/requests",
                                     headers={"Authorization": "Bearer test-user-key"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


def fingerprint(key):
    return hashlib.sha256(key.encode()).hexdigest()[:12]


class MultiProvider(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.alice = Client().register("multi_primary", openai_api_key="test-user-key",
                                      anthropic_api_key="anthropic-user-key")
        cls.bob = Client().register("multi_secondary", openai_api_key="second-user-key",
                                    anthropic_api_key="anthropic-second-key")
        cls.project = cls.alice.project()
        cls.other_project = cls.bob.project()
        cls.root = ROOT / "projects" / cls.project

    def test_image_upload_pixels_followup_resend_and_project_isolation(self):
        project = self.alice.project()
        path = f"/api/projects/{project}"
        output = io.BytesIO()
        Image.new("RGB", (12, 8), "red").save(output, format="PNG")
        upload = {"media_type": "image/png", "content": base64.b64encode(output.getvalue()).decode(),
                  "filename": "../../untrusted.png"}
        before = stats()
        self.assertEqual(self.bob.request(path + "/markerboard/media", json_body=upload)[0], 201)
        status, image = self.alice.request(path + "/markerboard/media", json_body=upload)
        self.assertEqual(status, 201, image)
        ids = json.dumps([image["artifact_id"]])
        for model in ["test-model", CLAUDE]:
            status, answer = self.alice.request(path + "/chat", {"prompt": "TEST_IMAGE_INPUT", "model": model,
                                                                "attachment_ids": ids})
            self.assertEqual(status, 200, answer)
            self.assertIn("Image pixels received: 255,0,0", answer["text"])
            self.assertIn('"status":"success"', answer["text"])
        with self.alice.opener.open(BASE + path + "/files/" + image["path"]) as response:
            self.assertEqual(response.read(), (ROOT / "projects" / project / image["path"]).read_bytes())
        history = self.alice.request(path + "/conversation")[1]["messages"]
        user = next(message for message in history if message["role"] == "user")
        self.assertIn(image["path"], user["text"])
        self.assertNotIn("data:image", json.dumps(history))
        # Resend of the persisted message and ordinary follow-up both retain pixels.
        self.assertIn("255,0,0", self.alice.chat(project, user["text"], "test-model")[1]["text"])
        self.assertIn("255,0,0", self.alice.chat(project, "TEST_IMAGE_INPUT follow-up", CLAUDE)[1]["text"])
        other = self.alice.project()
        count = stats()
        for bad_ids in [[image["artifact_id"]], ["../secret"], ["a" * 32] * 5]:
            status, _ = self.alice.request(f"/api/projects/{other}/chat", {
                "prompt": "TEST_IMAGE_INPUT", "model": "test-model", "attachment_ids": json.dumps(bad_ids)})
            self.assertEqual(status, 400)
        self.assertEqual(stats(), count, "invalid/foreign images must fail before provider work")
        self.assertEqual(self.alice.request(path + "/markerboard/media", json_body={**upload, "media_type": "image/jpeg"})[0], 400)
        self.assertEqual(stats()["requests"] - before["requests"], 2)
        self.assertEqual(stats()["anthropic_requests"] - before["anthropic_requests"], 2)

    def test_four_large_images_survive_http_framing_and_provider_encoding(self):
        project = self.alice.project()
        output = io.BytesIO()
        picture = Image.frombytes("RGB", (512, 512), random.Random(23).randbytes(512 * 512 * 3))
        picture.putpixel((0, 0), (9, 8, 7))
        picture.save(output, format="PNG")
        self.assertGreater(len(output.getvalue()), 700000)
        ids = []
        for _ in range(4):
            status, uploaded = self.alice.request(f"/api/projects/{project}/markerboard/media",
                json_body={"media_type": "image/png", "content": base64.b64encode(output.getvalue()).decode()})
            self.assertEqual(status, 201, uploaded)
            ids.append(uploaded["artifact_id"])
        status, answer = self.alice.request(f"/api/projects/{project}/chat", {
            "prompt": "TEST_IMAGE_INPUT", "model": "test-model", "attachment_ids": json.dumps(ids)})
        self.assertEqual(status, 200, answer)
        self.assertIn("Image pixels received: " + "; ".join(["9,8,7"] * 4), answer["text"])

    def test_catalog_identity_and_single_password(self):
        status, body = self.alice.request("/api/me")
        self.assertEqual(status, 200)
        billing = body["billing"]
        self.assertEqual(billing["models"], ["test-model", "test-model-fast", CLAUDE, "anthropic:claude-test-fast"])
        for model in billing["model_details"]:
            key = "anthropic-user-key" if model["provider"] == "anthropic" else "test-user-key"
            self.assertEqual(model["key_fingerprint"], fingerprint(key))
        self.assertEqual(billing["model_details"][2]["context_window_tokens"], 200000)
        account = ROOT / ".leanfm/accounts/multi_primary/credentials"
        self.assertTrue((account / "providers.json").exists())
        self.assertEqual((account / "providers.json").stat().st_mode & 0o777, 0o600)
        self.assertFalse((account / "default.json").exists())
        before = stats()
        fresh = Client()
        self.assertEqual(fresh.login("multi_primary")[0], 200)
        self.assertEqual(fresh.request("/api/me")[1]["billing"]["models"], billing["models"])
        self.assertEqual(stats(), before, "ordinary password login need not reverify provider keys")

    def test_defaults_and_readiness_do_not_force_questions_or_accept_gates(self):
        for model, counter in [("test-model", "requests"), (CLAUDE, "anthropic_requests")]:
            for marker, rounds in [("TEST_DECIDE_DEFAULTS", 2), ("TEST_READY_DEFAULTS", 1),
                                   ("TEST_RETURN_STRUCTURED_QUESTION", 1)]:
                with self.subTest(model=model, marker=marker):
                    project = self.alice.project()
                    root = ROOT / "projects" / project
                    before = stats()[counter]
                    status, body = self.alice.chat(project, marker, model)
                    self.assertEqual(status, 200, body)
                    self.assertEqual(stats()[counter] - before, rounds)
                    if marker == "TEST_RETURN_STRUCTURED_QUESTION":
                        self.assertIn("test_spectator_privacy", body["text"])
                        self.assertIn('"status":"warn"', body["text"])
                    else:
                        self.assertNotIn("```leanfm-questions", body["text"])
                        self.assertIn('"status":"success"', body["text"])
                    if marker == "TEST_DECIDE_DEFAULTS":
                        self.assertIn("Formal acceptance remains pending", (root / "spec/default-decisions.md").read_text())
                    self.assertFalse(any((root / "source").rglob("*.*")), "routine default authority fabricated gate acceptance")

    def test_specification_turn_compiles_real_project_views_and_rejects_unchecked_success(self):
        for model, counter in [("test-model", "requests"), (CLAUDE, "anthropic_requests")]:
            for marker in ["TEST_SPECIFY_SERVER", "TEST_SPECIFY_INVALID", "TEST_SPECIFY_WITH_BOOK"]:
                with self.subTest(model=model, marker=marker):
                    project = self.alice.project()
                    root = ROOT / "projects" / project
                    book = (root / "book/main.tex").read_bytes()
                    manifest = (root / "manifest.json").read_bytes()
                    catalog_path = root / "spec/tasks.json"
                    catalog = catalog_path.read_bytes() if catalog_path.exists() else None
                    before = stats()[counter]
                    status, body = self.alice.chat(project, marker, model)
                    self.assertEqual(status, 200, body)
                    self.assertEqual(stats()[counter] - before, 6, body)
                    if marker != "TEST_SPECIFY_WITH_BOOK":
                        self.assertEqual((root / "book/main.tex").read_bytes(), book)
                    self.assertEqual((root / "manifest.json").read_bytes(), manifest)
                    self.assertEqual(body["book_updated"], marker == "TEST_SPECIFY_WITH_BOOK")
                    self.assertFalse(any((root / "source").rglob("*.*")))
                    if marker.endswith("INVALID"):
                        self.assertIn('"status":"fail"', body["text"])
                        self.assertIn("have not passed", body["text"])
                        self.assertEqual(catalog_path.read_bytes() if catalog_path.exists() else None, catalog)
                    else:
                        self.assertIn('"status":"success"', body["text"])
                        self.assertNotIn("```leanfm-questions", body["text"])
                        status, tasks = self.alice.request(f"/api/projects/{project}/tasks")
                        self.assertEqual(status, 200, tasks)
                        self.assertEqual(tasks["tasks"][0]["id"], "fixture_request")
                        self.assertIn("Client->>FixtureServer: FixtureRequest", tasks["tasks"][0]["interaction_mermaid"])
                        self.assertTrue(self.alice.request(f"/api/projects/{project}/specification")[1]["requirements"]["checked"], "book commit left the just-checked specification stale")

    def test_routes_concurrently_without_cross_user_or_provider_fallback(self):
        operations = [(self.alice, self.project, "test-model", "OpenAI credential alice"),
                      (self.alice, self.project, CLAUDE, "Anthropic credential alice"),
                      (self.bob, self.other_project, "test-model-fast", "OpenAI credential bob"),
                      (self.bob, self.other_project, CLAUDE, "Anthropic credential bob")]
        # Each actor uses a different project so no test relies on concurrent
        # mutation of one conversation file.
        operations[1] = (self.alice, self.alice.project(), CLAUDE, operations[1][3])
        operations[3] = (self.bob, self.bob.project(), CLAUDE, operations[3][3])
        before = stats()
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(client.chat, project, "TEST_PROVIDER_ROUTE", model)
                       for client, project, model, _ in operations]
            for future, (_, _, model, expected) in zip(futures, operations):
                status, body = future.result()
                self.assertEqual(status, 200, body)
                self.assertIn(expected, body["text"])
                self.assertEqual(body["model"], model)
                self.assertEqual(body["provider"], "anthropic" if model.startswith("anthropic:") else "openai")
        after = stats()
        self.assertEqual(after["requests"] - before["requests"], 2)
        self.assertEqual(after["anthropic_requests"] - before["anthropic_requests"], 2)
        self.assertEqual(after["wrong_headers"], 0)

    def test_native_tools_book_and_bounded_repair(self):
        before = stats()
        status, body = self.alice.chat(self.project, "TEST_ANTHROPIC_TOOL")
        self.assertEqual(status, 200)
        self.assertIn('"status":"success"', body["text"])
        self.assertEqual((self.root / "spec/anthropic-note.txt").read_text(), "Native Anthropic workspace note.\n")
        self.assertEqual(body["usage"]["input_tokens"], 24)
        self.assertEqual(body["usage"]["cached_input_tokens"], 6)
        self.assertEqual(body["usage"]["total_tokens"], 34)
        self.assertEqual(stats()["anthropic_requests"] - before["anthropic_requests"], 2)
        self.assertEqual(stats()["requests"], before["requests"])
        for marker in ["TEST_ANTHROPIC_BOOK", "TEST_ANTHROPIC_REPAIR"]:
            status, body = self.alice.chat(self.project, marker)
            self.assertEqual(status, 200)
            self.assertTrue(body["book_updated"], body["text"])
            self.assertIn('"status":"success"', body["text"])
            self.assertGreater((self.root / "book/main.pdf").stat().st_size, 100)
        self.assertIn(r"Repaired A \& B.", (self.root / "book/main.tex").read_text())
        self.assertEqual(stats()["invalid_messages"], 0)

    def test_patch_counts_recover_locally_and_changed_bad_patches_cannot_loop(self):
        # property:recoverable_failures_are_fixed_before_return; unchanged
        # diagnostics cannot buy another round by merely changing patch text.
        for model, counter in [("test-model", "requests"), (CLAUDE, "anthropic_requests")]:
            for marker, rounds in [("TEST_PATCH_RECOUNT", 2),
                                   ("TEST_PATCH_WRITE_RECOVERY", 4),
                                   ("TEST_PATCH_RETRY_GUARD", 2)]:
                with self.subTest(model=model, marker=marker):
                    note = self.root / "spec/patch-note.txt"
                    note.write_text("before\nunrelated\n")
                    before = stats()[counter]
                    status, body = self.alice.chat(self.project, marker, model)
                    self.assertEqual(status, 200, body)
                    self.assertEqual(stats()[counter] - before, rounds, body["text"])
                    if marker == "TEST_PATCH_RETRY_GUARD":
                        self.assertEqual(note.read_text(), "before\nunrelated\n")
                        self.assertIn('"status":"fail"', body["text"])
                        self.assertIn("failed again without verified recovery", body["text"])
                        self.assertNotIn("16-step", body["text"])
                    else:
                        self.assertEqual(note.read_text(), "after\nunrelated\n")
                        expected = "warn" if marker == "TEST_PATCH_WRITE_RECOVERY" else "success"
                        self.assertIn(f'"status":"{expected}"', body["text"])

    def test_failed_checks_keep_codes_and_require_verified_recovery(self):
        for model, counter in [("test-model", "requests"), (CLAUDE, "anthropic_requests")]:
            for marker, rounds in [("TEST_CHECK_RETRY_GUARD", 3), ("TEST_CHECK_FIX", 4)]:
                with self.subTest(model=model, marker=marker):
                    project = self.alice.project()
                    root = ROOT / "projects" / project
                    (root / "Makefile").write_text("check:\n\t@echo 'E_FIXTURE: compile failed at line 17' >&2\n\t@exit 7\n")
                    before = stats()[counter]
                    status, body = self.alice.chat(project, marker, model)
                    self.assertEqual(status, 200, body)
                    self.assertEqual(stats()[counter] - before, rounds, body["text"])
                    journal = (root / "logs/runtime-diagnostics.jsonl").read_text()
                    self.assertIn("exit_code=2", journal)
                    self.assertIn("E_FIXTURE", journal)
                    self.assertIn("Error 7", journal)
                    if marker == "TEST_CHECK_RETRY_GUARD":
                        self.assertIn('"status":"fail"', body["text"])
                        self.assertIn("correction reproduced the same failure", journal)
                    else:
                        self.assertNotIn('"status":"fail"', body["text"])
                        self.assertIn("Finished check: check (exit 0)", body["text"])

    def test_failed_book_worker_keeps_stderr_and_exit_status(self):
        project = self.alice.project()
        root = ROOT / "projects" / project
        (root / "book/Makefile").write_text("all:\n\t@echo E_BOOK_WORKER_STDERR >&2\n\t@exit 7\n")
        before = stats()["requests"]
        status, body = self.alice.chat(project, "TEST_UPDATE_BOOK", "test-model")
        self.assertEqual(status, 200)
        self.assertEqual(stats()["requests"] - before, 1, "must not attempt blind paid repair")
        journal = (root / "logs/runtime-diagnostics.jsonl").read_text()
        self.assertIn("E_BOOK_WORKER_STDERR", journal)
        self.assertIn("Book build failed: exit_code=2", journal)

    def test_book_palette_normalization_keeps_editor_revision_valid(self):
        project = self.alice.project()
        path = f"/api/projects/{project}/book"
        status, current = self.alice.request(path)
        self.assertEqual(status, 200)
        source = "\\documentclass{article}\n\\begin{document}\nReadable book.\n\\end{document}\n"
        status, saved = self.alice.request(path, {"source": source, "source_revision": current["source_revision"]})
        self.assertEqual(status, 200)
        self.assertEqual(self.alice.request(path + "/build", {})[0], 200)
        status, built = self.alice.request(path)
        self.assertEqual(status, 200)
        self.assertEqual(built["source_revision"], saved["source_revision"], "building invalidated the editor's saved revision")
        status, again = self.alice.request(path, {"source": built["source"].replace("Readable book.", "Readable edited book."), "source_revision": saved["source_revision"]})
        self.assertEqual(status, 200, again)
        self.assertEqual(self.alice.request(path + "/build", {})[0], 200)
        self.assertEqual(self.alice.request(path)[1]["source"].count("\\AtBeginDocument"), 1)

    def test_wrapped_book_is_recovered_locally_and_ambiguous_books_are_rejected(self):
        before = stats()["anthropic_requests"]
        used = self.alice.request("/api/me")[1]["billing"]["tokens_used"]
        status, body = self.alice.chat(self.project, "TEST_ANTHROPIC_WRAPPED_BOOK")
        self.assertEqual(status, 200)
        self.assertTrue(body["book_updated"], body["text"])
        self.assertIn("Recovered one complete book JSON object", body["text"])
        self.assertEqual(stats()["anthropic_requests"] - before, 1)
        self.assertEqual(body["usage"]["total_tokens"], 17)
        self.assertEqual(self.alice.request("/api/me")[1]["billing"]["tokens_used"] - used, 17)
        self.assertIn("Wrapped book marker", (self.root / "book/main.tex").read_text())
        source = (self.root / "book/main.tex").read_bytes()
        before = stats()["anthropic_requests"]
        _, body = self.alice.chat(self.project, "TEST_ANTHROPIC_AMBIGUOUS_BOOK")
        self.assertIn("leanfm_malformed_book_reply:", body["text"])
        self.assertNotIn("HIDDEN_", body["text"])
        self.assertEqual(stats()["anthropic_requests"] - before, 1)
        self.assertEqual((self.root / "book/main.tex").read_bytes(), source)
        journal = (self.root / "logs/runtime-diagnostics.jsonl").read_text()
        self.assertIn("Provider round 1 (anthropic, claude-test)", journal)
        self.assertIn("input=12 cached=3 output=5", journal)
        self.assertIn("leading_token=other unique_complete_object=false", journal)
        self.assertNotIn("HIDDEN_AMBIGUOUS", journal)

    def test_budget_is_checked_between_paid_rounds_for_both_providers(self):
        for username, marker, model, counter in [
            ("round_budget_openai", "TEST_TOOL_BUDGET", "test-model", "requests"),
            ("round_budget_anthropic", "TEST_ANTHROPIC_TOOL_BUDGET", CLAUDE, "anthropic_requests"),
        ]:
            with self.subTest(model=model):
                client = Client().register(username, openai_api_key="test-user-key", anthropic_api_key="anthropic-user-key")
                project = client.project()
                before = stats()[counter]
                status, body = client.chat(project, marker, model)
                self.assertEqual(status, 200)
                self.assertIn("leanfm_session_token_budget_exhausted:", body["text"])
                self.assertIn('"status":"fail"', body["text"])
                self.assertEqual(stats()[counter] - before, 1, "must not send a continuation after exhaustion")
                self.assertEqual(body["usage"]["total_tokens"], 1000000)
                billing = client.request("/api/me")[1]["billing"]
                self.assertEqual(billing["tokens_used"], 1000000, "charge reported usage exactly once")
                self.assertEqual(billing["tokens_remaining"], 0)
                self.assertEqual((ROOT / "projects" / project / "spec/budget-note.txt").read_text(), "Completed before budget stop.\n")
                self.assertEqual(client.chat(project, "must not call provider", model)[0], 409)
                self.assertEqual(stats()[counter] - before, 1)

    def test_rejected_repair_and_failed_openai_loop_keep_all_reported_usage(self):
        for marker, model, counter, expected_tokens, detail in [
            ("TEST_ANTHROPIC_REJECTED_REPAIR", CLAUDE, "anthropic_requests", 34, "outside the bounded diagnostic neighborhood"),
            ("TEST_REPEATED_TOOL_FAILURE", "test-model", "requests", 36, "failed again without verified recovery"),
        ]:
            with self.subTest(marker=marker):
                used = self.alice.request("/api/me")[1]["billing"]["tokens_used"]
                before = stats()[counter]
                source = (self.root / "book/main.tex").read_bytes()
                status, body = self.alice.chat(self.project, marker, model)
                self.assertEqual(status, 200)
                self.assertFalse(body["book_updated"])
                self.assertIn(detail, body["text"])
                self.assertEqual(body["usage"]["total_tokens"], expected_tokens)
                self.assertEqual(self.alice.request("/api/me")[1]["billing"]["tokens_used"] - used, expected_tokens)
                self.assertEqual(stats()[counter] - before, 2)
                self.assertEqual((self.root / "book/main.tex").read_bytes(), source)

    def test_local_checker_failure_stops_both_providers_without_an_extra_paid_round(self):
        for model, counter in [("test-model", "requests"), (CLAUDE, "anthropic_requests")]:
            with self.subTest(model=model):
                project = self.alice.project()
                before = stats()[counter]
                status, body = self.alice.chat(project, "TEST_SPECIFY_STARTUP_FAILURE", model)
                self.assertEqual(status, 200)
                self.assertIn("local_checker_unavailable", body["text"])
                self.assertIn("stopped before another paid request", body["text"])
                self.assertEqual(stats()[counter] - before, 5)
                self.assertFalse((ROOT / "projects" / project / "spec/tasks.json").exists())

    def test_paused_turn_continues_but_unfinished_tool_response_does_not_claim_success(self):
        before = stats()
        status, body = self.alice.chat(self.project, "TEST_ANTHROPIC_PAUSE")
        self.assertEqual(status, 200)
        self.assertIn("Completed paused turn", body["text"])
        self.assertEqual(body["usage"]["total_tokens"], 34)
        self.assertEqual(stats()["anthropic_requests"] - before["anthropic_requests"], 2)
        before = stats()
        status, body = self.alice.chat(self.project, "TEST_ANTHROPIC_UNFINISHED")
        self.assertEqual(status, 200)
        self.assertIn('"status":"fail"', body["text"])
        self.assertNotIn("Not a completed answer", body["text"])
        self.assertEqual(stats()["anthropic_requests"] - before["anthropic_requests"], 1)

    def test_incomplete_and_billing_failures_stop_before_mutations_or_retries(self):
        for marker, detail, tokens in [("TEST_ANTHROPIC_INCOMPLETE", "anthropic_output_limit:", 17),
                                       ("TEST_ANTHROPIC_DUPLICATE", "malformed or duplicate tool calls", 17),
                                       ("TEST_ANTHROPIC_BILLING", "billing or payment restriction", 0)]:
            with self.subTest(marker=marker):
                before = stats()
                source = (self.root / "book/main.tex").read_bytes()
                used = self.alice.request("/api/me")[1]["billing"]["tokens_used"]
                status, body = self.alice.chat(self.project, marker)
                self.assertEqual(status, 200)
                self.assertIn('"status":"fail"', body["text"])
                self.assertIn(detail, body["text"])
                self.assertNotIn("HIDDEN_", body["text"])
                self.assertEqual(body["usage"]["total_tokens"], tokens)
                self.assertEqual(body["usage"]["context_window_tokens"], 200000)
                self.assertEqual(self.alice.request("/api/me")[1]["billing"]["tokens_used"] - used, tokens)
                self.assertEqual((self.root / "book/main.tex").read_bytes(), source)
                self.assertFalse((self.root / "spec/must-not-exist.txt").exists())
                self.assertEqual(stats()["anthropic_requests"] - before["anthropic_requests"], 1)
                self.assertEqual(stats()["requests"], before["requests"])
        conversation = self.alice.request(f"/api/projects/{self.project}/conversation")[1]["messages"]
        self.assertEqual(next(message for message in reversed(conversation) if message["role"] == "assistant")["usage"]["context_window_tokens"], 200000)

    def test_single_provider_missing_model_and_wrong_password_fail_closed(self):
        only = Client().register("multi_only_openai", openai_api_key="test-user-key")
        project = only.project()
        only.request("/api/me")  # Prime the free catalog before counting requests.
        before = stats()
        self.assertEqual(only.chat(project, "MUST_NOT_PERSIST", CLAUDE)[0], 409)
        self.assertEqual(only.chat(project, "MUST_NOT_PERSIST", "not-a-model")[0], 400)
        self.assertEqual(only.request("/api/login", {"username": "multi_only_openai", "password": "wrong",
                                                   "anthropic_api_key": "anthropic-user-key"})[0], 403)
        self.assertEqual(stats(), before, "missing authorization must not reach either provider")
        self.assertNotIn("MUST_NOT_PERSIST", json.dumps(only.request(f"/api/projects/{project}/conversation")[1]))
        self.assertEqual(only.login("multi_only_openai", anthropic_api_key="anthropic-user-key")[0], 200)
        self.assertIn(CLAUDE, only.request("/api/me")[1]["billing"]["models"])
        claude_only = Client().register("multi_only_claude", anthropic_api_key="anthropic-user-key")
        project = claude_only.project()
        self.assertTrue(all(name.startswith("anthropic:") for name in claude_only.request("/api/me")[1]["billing"]["models"]))
        before = stats()
        self.assertEqual(claude_only.chat(project, "MUST_NOT_PERSIST", "test-model")[0], 400)
        self.assertEqual(stats(), before)
        self.assertIn("Anthropic credential alice", claude_only.chat(project, "TEST_PROVIDER_ROUTE")[1]["text"])

    def test_rotation_retains_other_provider_and_cancels_old_agent(self):
        old = Client().register("multi_rotation", openai_api_key="test-user-key", anthropic_api_key="anthropic-user-key")
        project = old.project()
        old.request("/api/me")
        before = stats()["anthropic_requests"]
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(old.chat, project, "TEST_ANTHROPIC_CANCEL")
            deadline = time.monotonic() + 10
            while stats()["anthropic_requests"] == before and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertEqual(stats()["anthropic_requests"], before + 1)
            new = Client()
            self.assertEqual(new.login("multi_rotation", anthropic_api_key="anthropic-rotated-key")[0], 200)
            self.assertEqual(old.request("/api/me")[0], 401)
            pending.result()
        root = ROOT / "projects" / project
        self.assertFalse((root / "spec/must-not-exist.txt").exists())
        metadata = new.request("/api/me")[1]["billing"]["model_details"]
        self.assertEqual(next(m for m in metadata if m["id"] == "test-model")["key_fingerprint"], fingerprint("test-user-key"))
        self.assertEqual(next(m for m in metadata if m["id"] == CLAUDE)["key_fingerprint"], fingerprint("anthropic-rotated-key"))

    def test_concurrent_provider_updates_do_not_lose_keys(self):
        Client().register("multi_concurrent", openai_api_key="test-user-key", anthropic_api_key="anthropic-user-key")
        with ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(Client().login, "multi_concurrent", openai_api_key="rotated-openai-key")
            b = pool.submit(Client().login, "multi_concurrent", anthropic_api_key="anthropic-rotated-key")
            self.assertEqual(a.result()[0], 200)
            self.assertEqual(b.result()[0], 200)
        current = Client()
        self.assertEqual(current.login("multi_concurrent")[0], 200)
        metadata = current.request("/api/me")[1]["billing"]["model_details"]
        self.assertEqual(next(m for m in metadata if m["id"] == "test-model")["key_fingerprint"], fingerprint("rotated-openai-key"))
        self.assertEqual(next(m for m in metadata if m["id"] == CLAUDE)["key_fingerprint"], fingerprint("anthropic-rotated-key"))

    def test_tcp_framing_waits_for_body_and_utf8_and_rejects_ambiguous_input(self):
        port = urllib.parse.urlparse(BASE).port
        path = f"/api/projects/{self.project}/chat"
        cookie = "; ".join(f"{value.name}={value.value}" for value in self.alice.cookies)
        body = "prompt=TEST_PROVIDER_ROUTE+café&model=anthropic%3Aclaude-test".encode()

        def headers(fields):
            return (f"POST {path} HTTP/1.1\r\nHost: localhost:{port}\r\nCookie: {cookie}\r\n"
                    "Content-Type: application/x-www-form-urlencoded\r\n" + fields + "\r\n").encode()

        def receive(connection):
            parts = []
            while True:
                part = connection.recv(65536)
                if not part:
                    break
                parts.append(part)
            raw = b"".join(parts)
            head, content = raw.split(b"\r\n\r\n", 1)
            return int(head.split(b" ", 2)[1]), json.loads(content)

        before = stats()
        with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
            connection.sendall(headers(f"Content-Length: {len(body)}\r\n")[:-1])
            connection.settimeout(.15)
            with self.assertRaises(TimeoutError, msg="must not dispatch an incomplete header"):
                connection.recv(1)
            connection.sendall(b"\n")
            with self.assertRaises(TimeoutError, msg="must not dispatch before body arrives"):
                connection.recv(1)
            split = body.index("é".encode()) + 1
            connection.sendall(body[:split])
            with self.assertRaises(TimeoutError, msg="must not decode a split UTF-8 code point"):
                connection.recv(1)
            connection.sendall(body[split:])
            connection.settimeout(30)
            status, answer = receive(connection)
            self.assertEqual(status, 200, answer)
            self.assertIn("Anthropic credential alice", answer["text"])
        self.assertEqual(stats()["anthropic_requests"] - before["anthropic_requests"], 1)
        before = stats()
        for fields, content, expected, eof in [
                ("Content-Length: 2\r\nContent-Length: 2\r\n", b"ab", 400, False),
                ("Content-Length: 0\r\nTransfer-Encoding: chunked\r\n", b"", 400, False),
                ("Content-Length : 2\r\n", b"ab", 400, False),
                ("Content-Length: 8388609\r\n", b"", 413, False),
                ("Content-Length: 1\r\n", b"\xff", 400, False),
                ("Content-Length: 99\r\n", b"truncated", 400, True),
                ("Content-Length: 0\r\n", b"pipelined", 400, False)]:
            with self.subTest(fields=fields):
                with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                    connection.sendall(headers(fields) + content)
                    if eof:
                        connection.shutdown(socket.SHUT_WR)
                    status, answer = receive(connection)
                    self.assertEqual(status, expected, answer)
                    self.assertEqual(answer["code"], "leanfm_http_frame_invalid")
                    self.assertNotIn(cookie, json.dumps(answer))
        self.assertEqual(stats(), before, "malformed frames must not reach either provider")

    def test_no_plaintext_keys_or_raw_error_body_on_disk(self):
        for path in (ROOT / ".leanfm/accounts").rglob("*"):
            if path.is_file() and path.suffix in {".json", ".jsonl", ".log", ".b64"}:
                contents = path.read_bytes()
                for secret in [b"test-user-key", b"second-user-key", b"anthropic-user-key",
                               b"anthropic-second-key", b"anthropic-rotated-key", PASSWORD.encode(), b"HIDDEN_ANTHROPIC_BODY"]:
                    self.assertNotIn(secret, contents, str(path))


if __name__ == "__main__":
    if AFTER_RESTART:
        current = Client()
        assert current.login("multi_primary")[0] == 200
        billing = current.request("/api/me")[1]["billing"]
        assert CLAUDE in billing["models"] and "test-model" in billing["models"]
        assert stats()["wrong_headers"] == stats()["invalid_messages"] == 0
        print("ok: one password unlocks both provider keys after server restart")
    else:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
