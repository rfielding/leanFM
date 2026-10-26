#!/usr/bin/env python3
"""Shared project identity, private keys, origin admission and writer exclusion."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from chatui_multi_provider_test import Client, BASE, ROOT, stats


class SharedProjects(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.anonymous = Client()
        cls.alice = Client().register("shared_alice", openai_api_key="test-user-key")
        cls.bob = Client().register("shared_bob", openai_api_key="second-user-key")

    def test_anonymous_projects_and_accounts_share_identity_but_never_keys(self):
        project = self.anonymous.project()
        for client in [self.anonymous, self.alice, self.bob]:
            status, listing = client.request("/api/projects")
            self.assertEqual(status, 200)
            self.assertIn(project, [p["project_id"] for p in listing["projects"]])
            self.assertEqual(client.request(f"/api/projects/{project}/book")[0], 200)
        self.assertTrue((ROOT / "projects" / project / "book/main.pdf").is_file())
        self.assertFalse((ROOT / ".leanfm/accounts/shared_alice/projects").exists())
        before = stats()
        path = f"/api/projects/{project}"
        self.assertEqual(self.anonymous.request(path + "/chat", {"prompt": "must not bill", "model": "test-model"})[0], 401)
        self.assertEqual(stats(), before)
        self.assertEqual(self.anonymous.request(path + "/conversation")[1]["messages"], [])
        for suffix in ["/files/../../.leanfm/accounts/shared_alice/password.json", "/source/../../.leanfm/accounts/shared_alice/password.json"]:
            self.assertIn(self.anonymous.request(path + suffix)[0], [403, 404])
        self.assertEqual(self.anonymous.request("/api/me")[0], 401)
        self.assertEqual(self.alice.request("/api/projects/leanfm-workspace/chat", {"prompt": "read the credential vault", "model": "test-model"})[0], 403)
        for client, expected in [(self.alice, "alice response"), (self.bob, "bob response")]:
            status, reply = client.chat(project, "shared credential routing", "test-model")
            self.assertEqual(status, 200, reply)
            self.assertIn(expected, reply["text"])

    def test_cross_site_and_rebinding_requests_cannot_mutate_or_bill(self):
        before = {p.name for p in (ROOT / "projects").iterdir()}
        provider_before = stats()
        for headers in [{"Origin": "https://attacker.invalid"}, {"Host": "attacker.invalid"}, {"Sec-Fetch-Site": "cross-site"}]:
            request = urllib.request.Request(BASE + "/api/projects", data=urllib.parse.urlencode({"display_name": "must not exist"}).encode(), headers=headers)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=10)
            self.assertEqual(caught.exception.code, 403)
        self.assertEqual(before, {p.name for p in (ROOT / "projects").iterdir()})
        self.assertEqual(stats(), provider_before)

    def test_readable_creation_and_renamed_root_preserve_open_and_confirmed_delete(self):
        status, created = self.anonymous.request("/api/projects", {"display_name": "Readable GoServer"})
        self.assertEqual(status, 201, created)
        project = created["project_id"]
        self.assertEqual(project, "Readable-GoServer")
        original = ROOT / "projects" / project
        manifest = (original / "manifest.json").read_bytes()
        book = (original / "book/main.pdf").read_bytes()
        gate_before = self.anonymous.request(f"/api/projects/{project}/specification")[1]
        renamed = original.with_name("GoServer-readable-moved")
        original.rename(renamed)
        self.assertEqual((renamed / "manifest.json").read_bytes(), manifest)
        for client in [self.anonymous, self.alice, self.bob]:
            self.assertIn(project, [p["project_id"] for p in client.request("/api/projects")[1]["projects"]])
            self.assertEqual(client.request(f"/api/projects/{project}/book")[0], 200)
        self.assertEqual(self.anonymous.request(f"/api/projects/{project}/specification")[1], gate_before)
        status, other = self.anonymous.request("/api/projects", {"display_name": "Readable GoServer"})
        self.assertEqual(status, 201, other)
        self.assertEqual(other["project_id"], "Readable-GoServer-2", "a moved legacy identity must remain reserved")
        self.assertEqual((renamed / "book/main.pdf").read_bytes(), book)
        self.assertEqual(self.anonymous.request(f"/api/projects/{project}", {"confirmation": "wrong"}, method="DELETE")[0], 400)
        self.assertTrue(renamed.exists())
        self.assertEqual(self.anonymous.request(f"/api/projects/{project}", {"confirmation": "Readable GoServer"}, method="DELETE")[0], 200)
        self.assertFalse(renamed.exists())
        self.assertTrue((ROOT / "projects" / other["project_id"] / "book/main.pdf").is_file())

    def test_project_writer_and_cancellation_are_bound_to_initiating_session(self):
        project = self.anonymous.project()
        path = f"/api/projects/{project}"
        initial_requests = stats()["requests"]
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(self.alice.chat, project, "TEST_CANCEL_AGENT", "test-model")
            for _ in range(100):
                status, current = self.anonymous.request(path + "/chat/status")
                if current.get("stage") == "model" and stats()["requests"] > initial_requests:
                    break
                time.sleep(.01)
            before = stats()
            self.assertEqual(self.bob.chat(project, "must not bill", "test-model")[0], 409)
            self.assertEqual(self.anonymous.request(path + "/book", {"source": "must not replace book"})[0], 409)
            self.assertEqual(stats(), before)
            self.assertEqual(self.bob.request(path + "/chat/cancel", {})[0], 403)
            self.assertEqual(self.anonymous.request(path + "/chat/cancel", {})[0], 401)
            self.assertEqual(self.alice.request(path + "/chat/cancel", {})[0], 202)
            status, answer = pending.result(timeout=15)
            self.assertEqual(status, 200, answer)
            self.assertTrue(answer["cancelled"])
        self.assertEqual(list((ROOT / "projects" / project / "source").iterdir()), [])

    def test_source_writes_need_no_approval_record(self):
        # Review happens in git; LeanFM neither blocks source on an approval nor records one.
        project = self.anonymous.project()
        status, answer = self.alice.chat(project, "TEST_WRITE_SOURCE implement the server now", "test-model")
        self.assertEqual(status, 200, answer)
        self.assertNotEqual(list((ROOT / "projects" / project / "source").iterdir()), [])
        self.assertFalse((ROOT / "projects" / project / ".leanfm/acceptance.json").exists())
        self.assertEqual(self.alice.request(f"/api/projects/{project}/specification/requirements/x/accept", {})[0], 410)


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)
