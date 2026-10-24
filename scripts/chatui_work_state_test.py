#!/usr/bin/env python3
"""Real project checkpoint transactions: replay, ownership, isolation and pause.
Refs: leanfm.resumable-work; all three resumable-work negative proof obligations.
"""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from chatui_work_state import execute, Rejected, WorkStore

ROOT = Path(__file__).resolve().parents[1]


class WorkState(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="work-state-", dir=ROOT / ".cache")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "spec").mkdir()
        (self.root / "spec/Requirements.lean").write_text("preserve requirements")
        self.identity = {"account": "alice", "owner": hashlib.sha256(b"session-one").hexdigest(),
                         "credential": hashlib.sha256(b"fixture-provider-key").hexdigest(),
                         "provider": "openai", "model": "fixture-model"}

    def call(self, operation, **request):
        return execute(operation, self.root, {"identity": self.identity, **request})

    def start(self):
        return self.call("start", request_id="initial-request-0001", prompt="Produce the requested artifact")["job"]

    def save(self, job, **overrides):
        return self.call("save", work_id=job["id"], claim=job["claim"], **{
            "state": "checkpointed", "provider_state": {"previous_id": "response-1", "pending": ["already executed tools"]},
            "task_state": {"failed_tools": ["retained failure"], "tokens": 71},
            "made_progress": True, "progress": "One artifact checked", "response": {"text": "Progress saved"}, **overrides})

    def test_atomic_checkpoint_replay_and_exactly_one_claim(self):
        job = self.start()
        first = self.save(job)["response"]
        checkpoint = first["work"]["checkpoint"]
        claimed = self.call("claim", work_id=job["id"], checkpoint=checkpoint)["job"]
        with self.assertRaises(Rejected):
            self.call("claim", work_id=job["id"], checkpoint=checkpoint)
        final = self.save(claimed, state="completed", response={"text": "Artifact complete"})["response"]
        replay = self.call("claim", work_id=job["id"], checkpoint=checkpoint)
        self.assertEqual(replay["cached"], final)
        self.assertFalse(final["work"]["continue"])
        self.assertIsNone(WorkStore(self.root).active())
        duplicate_start = self.call("start", request_id="initial-request-0001", prompt="Do not repeat")
        self.assertEqual(duplicate_start["cached"], final)

    def test_cross_identity_or_model_cannot_claim_and_new_login_needs_explicit_resume(self):
        job = self.start()
        checkpoint = self.save(job)["work"]["checkpoint"]
        original = dict(self.identity)
        for key, value in [("account", "bob"), ("credential", "b" * 64), ("provider", "anthropic"), ("model", "other-model")]:
            with self.subTest(key=key):
                self.identity = {**original, key: value}
                with self.assertRaises(Rejected):
                    self.call("claim", work_id=job["id"], checkpoint=checkpoint, explicit_resume=True)
        self.identity = {**original, "owner": "c" * 64}
        self.assertTrue(self.call("status", work_id=job["id"])["work"]["requires_resume"])
        with self.assertRaises(Rejected):
            self.call("claim", work_id=job["id"], checkpoint=checkpoint)
        claimed = self.call("claim", work_id=job["id"], checkpoint=checkpoint, explicit_resume=True)["job"]
        self.assertEqual(claimed["owner"], self.identity["owner"])
        self.assertEqual(claimed["task_state"]["tokens"], 71)
        self.assertEqual(claimed["task_state"]["failed_tools"], ["retained failure"])

    def test_inter_batch_writer_reservation_expires_but_changed_inputs_require_restart(self):
        job = self.start()
        checkpoint = self.save(job)["work"]["checkpoint"]
        with self.assertRaises(Rejected):
            self.call("guard", work_id="another-work-item")
        self.assertTrue(self.call("guard", work_id=job["id"], chat=True)["allowed"])
        with self.assertRaises(Rejected):
            self.call("guard", work_id=job["id"], chat=False)
        with self.assertRaises(Rejected):
            self.call("guard", work_id=job["id"], chat=True, identity={**self.identity, "account": "another-account"})
        active = self.root / ".leanfm/work/active.json"
        active.write_text(json.dumps({"id": job["id"], "expires": 0}))
        self.assertTrue(self.call("guard", work_id="another-work-item")["allowed"])
        (self.root / "spec/Requirements.lean").write_text("authorized intervening edit")
        with self.assertRaises(Rejected):
            self.call("claim", work_id=job["id"], checkpoint=checkpoint)
        restarted = self.call("claim", work_id=job["id"], checkpoint=checkpoint, restart=True)["job"]
        self.assertEqual(restarted["provider_state"], {"restart": True})

    def test_cancel_and_no_progress_are_real_stops_and_large_context_is_compacted(self):
        job = self.start()
        checkpoint = self.save(job, provider_state={"large": "x" * (1024 * 1024 + 1)})["work"]["checkpoint"]
        claimed = self.call("claim", work_id=job["id"], checkpoint=checkpoint)["job"]
        self.assertEqual(claimed["provider_state"], {"restart": True})
        checkpoint = self.save(claimed, made_progress=False)["work"]["checkpoint"]
        claimed = self.call("claim", work_id=job["id"], checkpoint=checkpoint)["job"]
        blocked = self.save(claimed, made_progress=False)["response"]
        self.assertEqual(blocked["work"]["state"], "blocked")
        self.assertFalse(blocked["work"]["continue"])
        self.assertIn("without useful new progress", blocked["text"])
        job = self.call("start", request_id="second-request-0001", prompt="A different task")["job"]
        checkpoint = self.save(job)["work"]["checkpoint"]
        self.call("cancel", work_id=job["id"])
        replay = self.call("claim", work_id=job["id"], checkpoint=checkpoint)
        self.assertTrue(replay["cached"]["cancelled"])
        self.assertFalse(replay["cached"]["work"]["continue"])

    def test_paths_and_project_binding_do_not_allow_checkpoint_forgery(self):
        job = self.start()
        for value in ["../../outside", "/tmp/outside", "short"]:
            with self.assertRaises(Rejected):
                self.call("status", work_id=value)
        copy = self.root / "other-project"
        (copy / ".leanfm/work").mkdir(parents=True)
        (copy / ".leanfm/work" / (job["id"] + ".json")).write_bytes((self.root / ".leanfm/work" / (job["id"] + ".json")).read_bytes())
        with self.assertRaises(Rejected):
            execute("status", copy, {"identity": self.identity, "work_id": job["id"]})
        (self.root / ".leanfm/work/active.json").unlink()
        (self.root / ".leanfm/work/active.json").symlink_to(copy / "private")
        with self.assertRaises(ValueError):
            self.call("guard")
        disk = b"".join(path.read_bytes() for path in (self.root / ".leanfm/work").glob("*.json") if not path.is_symlink())
        self.assertNotIn(b"fixture-provider-key", disk)
        self.assertNotIn(b"session-one", disk)


if __name__ == "__main__":
    unittest.main()
