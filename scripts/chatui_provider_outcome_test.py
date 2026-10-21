#!/usr/bin/env python3
"""Provider outcome and hidden-envelope conformance against the local test stub.

Requirement refs: provider_outcomes_are_distinguishable,
book_envelopes_never_leak_into_chat, every_project_error_is_durably_diagnosable.
No real provider calls or user credentials are used.
"""

import http.cookiejar
import json
from pathlib import Path
import sys
import unittest
import urllib.parse
import urllib.request


base_url, cookie_path, project_id, project_root = sys.argv[1:]
assert urllib.parse.urlparse(base_url).hostname == "127.0.0.1"
cookies = http.cookiejar.MozillaCookieJar(cookie_path)
cookies.load(ignore_discard=True, ignore_expires=True)
# curl's Netscape jar represents session cookies with expiration zero; Python
# otherwise treats them as expired and drops authentication on every request.
for cookie in cookies:
    if cookie.expires == 0:
        cookie.expires = None
        cookie.discard = True
client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))
root = Path(project_root)


def get(path):
    with client.open(base_url + path, timeout=30) as response:
        return json.load(response)


def provider_requests():
    request = urllib.request.Request("http://127.0.0.1:18080/test/requests",
                                     headers={"Authorization": "Bearer test-user-key"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)["requests"]


class ProviderOutcomes(unittest.TestCase):
    def chat(self, marker, failed=True):
        before_count = provider_requests()
        before_source = (root / "book/main.tex").read_bytes()
        before_usage = get("/api/me")["billing"]["tokens_used"]
        request = urllib.request.Request(
            f"{base_url}/api/projects/{project_id}/chat",
            data=urllib.parse.urlencode({"prompt": marker}).encode(), method="POST")
        with client.open(request, timeout=60) as response:
            body = json.load(response)
        self.assertEqual(provider_requests(), before_count + 1, "unexpected paid retry")
        self.assertIn('"status":"fail"' if failed else '"status":"success"', body["text"])
        self.assertNotIn('"book_source"', body["text"])
        self.assertNotIn("HIDDEN_", body["text"])
        if failed:
            self.assertFalse(body["book_updated"])
            self.assertEqual((root / "book/main.tex").read_bytes(), before_source)
        self.assertEqual(get("/api/me")["billing"]["tokens_used"] - before_usage,
                         body["usage"]["total_tokens"])
        return body

    def test_credits_and_limits_remain_distinct(self):
        for marker, detail in [
            ("TEST_CREDIT_EXHAUSTED", "API credit balance exhausted"),
            ("TEST_PROJECT_SPEND", "project spend limit reached"),
            ("TEST_ORGANIZATION_SPEND", "organization spend limit reached"),
            ("TEST_ORGANIZATION_USAGE", "organization usage limit reached"),
            ("TEST_LEGACY_QUOTA", "quota exhausted"),
            ("TEST_RATE_LIMIT", "rate limit reached"),
        ]:
            with self.subTest(marker=marker):
                body = self.chat(marker)
                self.assertIn(detail, body["text"])
                self.assertEqual(body["usage"]["total_tokens"], 0)

    def test_incomplete_text_is_not_applied_and_usage_is_retained(self):
        body = self.chat("TEST_INCOMPLETE_TEXT")
        self.assertIn("openai_output_limit:", body["text"])
        self.assertEqual(body["usage"]["total_tokens"], 18)

    def test_incomplete_tools_are_never_executed(self):
        body = self.chat("TEST_INCOMPLETE_TOOL")
        self.assertIn("openai_output_limit:", body["text"])
        self.assertEqual(body["usage"]["total_tokens"], 18)
        self.assertFalse((root / "source/incomplete-must-not-exist.go").exists())

    def test_malformed_envelope_never_becomes_prose_or_a_question(self):
        body = self.chat("TEST_MALFORMED_BOOK_ENVELOPE")
        self.assertIn("leanfm_malformed_book_reply:", body["text"])
        self.assertIn("offset", body["text"])
        self.assertNotIn("structured question(s)", body["text"])
        self.assertEqual(body["usage"]["total_tokens"], 18)

    def test_recover_json_math_without_another_provider_call(self):
        body = self.chat("TEST_RECOVER_JSON_MATH", failed=False)
        self.assertTrue(body["book_updated"])
        self.assertIn("Recovered JSON escaping", body["text"])
        self.assertEqual(body["usage"]["total_tokens"], 18)
        self.assertIn(r"\(x+1\)", (root / "book/main.tex").read_text())
        self.assertGreater((root / "book/main.pdf").stat().st_size, 100)

    def test_unknown_provider_fields_cannot_disclose_secrets(self):
        self.chat("TEST_UNKNOWN_PROVIDER_ERROR")
        diagnostic = (root / "logs/runtime-diagnostics.jsonl").read_text()
        conversation = json.dumps(get(f"/api/projects/{project_id}/conversation"))
        self.assertNotIn("HIDDEN_", diagnostic)
        self.assertNotIn("HIDDEN_", conversation)


unittest.main(argv=[sys.argv[0]])
