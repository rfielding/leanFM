#!/usr/bin/env python3
"""No credential loss, cross-root deletion, or unknown-entry cleanup."""
from pathlib import Path
import tempfile
import unittest
from reset_leanfm_workspace import reset, inventory

ROOT = Path(__file__).resolve().parents[1]


class Reset(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="workspace-reset-", dir=ROOT / ".cache")
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Path(self.temporary.name)
        self.root = self.fixture / "workspace"
        for path in ["book", "LeanFM/LLMGenerated", "projects/example", "data/accounts/alice/credentials", "data/accounts/alice/projects/legacy", "data/accounts/empty/projects/scaffold/source"]:
            (self.root / path).mkdir(parents=True)
        for path, text in [("AGENTS.md", "preserve agent instructions"), ("book/main.pdf", "preserve book bytes"),
                           ("LeanFM/LLMGenerated/Requirements.lean", "preserve requirements"), ("projects/example/project.json", '{}'),
                           ("data/accounts/alice/projects/legacy/manifest.json", '{}'), ("data/accounts/alice/password.json", "verifier"),
                           ("data/accounts/alice/credentials/providers.json", "encrypted credential bytes")]:
            (self.root / path).write_text(text)
            (self.root / path).chmod(0o600)

    def test_reset_preserves_credential_bytes_and_selfhosting_inputs(self):
        credentials = (self.root / "data/accounts/alice/credentials/providers.json").read_bytes()
        preview = reset(self.root)
        self.assertEqual(len(preview["project_roots"]), 2)
        self.assertTrue((self.root / "data").exists())
        reset(self.root, apply=True)
        self.assertFalse((self.root / "data").exists())
        self.assertEqual(list((self.root / "projects").iterdir()), [])
        self.assertEqual((self.root / ".leanfm/accounts/alice/credentials/providers.json").read_bytes(), credentials)
        self.assertEqual((self.root / ".leanfm/accounts/alice/credentials/providers.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "book/main.pdf").read_text(), "preserve book bytes")
        self.assertEqual(reset(self.root, apply=True)["project_roots"], [])

    def test_symlink_collision_and_unknown_entries_fail_before_deletion(self):
        outside = self.fixture / "outside"
        outside.mkdir()
        (outside / "private").write_text("keep")
        malicious = self.root / "projects/escape"
        malicious.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            reset(self.root, apply=True)
        self.assertTrue((outside / "private").exists())
        self.assertTrue((self.root / "projects/example").exists())
        malicious.unlink()
        (self.root / "data/unknown").write_text("keep")
        with self.assertRaises(ValueError):
            reset(self.root, apply=True)
        self.assertTrue((self.root / "data/accounts/alice/projects/legacy").exists())


if __name__ == "__main__":
    unittest.main()
