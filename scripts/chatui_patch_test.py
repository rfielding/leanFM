#!/usr/bin/env python3
"""Local patch boundary checks; no provider calls or live account data.
Requirement refs: recoverable_failures_are_fixed_before_return,
third_party_commands_cross_one_whitelist, equivalent_project_paths_do_not_false_escape.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DISPATCHER = ROOT / "scripts/chatui_command.sh"
PATCH = "--- a/spec/note.txt\n+++ b/spec/note.txt\n@@ -1,90 +1,90 @@\n-before\n+after\n unrelated\n"


class PatchBoundary(unittest.TestCase):
    def setUp(self):
        (ROOT / ".cache").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="patch-check-", dir=ROOT / ".cache")
        self.fixture = Path(self.temp.name)
        # No nested Git repository: this is the same layout as hosted projects.
        self.project = self.fixture / "project with spaces"
        (self.project / "spec").mkdir(parents=True)
        self.note = self.project / "spec/note.txt"
        self.note.write_text("before\nunrelated\n")

    def tearDown(self):
        self.temp.cleanup()

    def run_patch(self, operation, patch):
        return subprocess.run(["bash", str(DISPATCHER), operation, str(self.project)],
                              input=patch, text=True, capture_output=True)

    def test_recounts_hunks_and_really_changes_nested_project(self):
        checked = self.run_patch("git-apply-check", PATCH)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(self.note.read_text(), "before\nunrelated\n")
        applied = self.run_patch("git-apply", PATCH)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertEqual(self.note.read_text(), "after\nunrelated\n")

    def test_malformed_empty_or_mismatched_patch_never_mutates(self):
        for patch in ("", "*** Begin Patch\n*** End Patch\n", PATCH.replace("-before", "-absent")):
            with self.subTest(patch=patch):
                checked = self.run_patch("git-apply-check", patch)
                self.assertNotEqual(checked.returncode, 0)
                self.assertNotIn("absent", checked.stderr, "raw searched-for patch content leaked")
                self.assertNotEqual(self.run_patch("git-apply", patch).returncode, 0)
                self.assertEqual(self.note.read_text(), "before\nunrelated\n")

    def test_invalid_second_file_leaves_first_unchanged(self):
        patch = PATCH + PATCH.replace("spec/note.txt", "spec/missing.txt")
        self.assertNotEqual(self.run_patch("git-apply", patch).returncode, 0)
        self.assertEqual(self.note.read_text(), "before\nunrelated\n")
        self.assertFalse((self.project / "spec/missing.txt").exists())

    def test_parent_traversal_and_symlink_escape_are_rejected(self):
        outside = self.fixture / "outside"
        outside.mkdir()
        sentinel = outside / "note.txt"
        sentinel.write_text("before\nunrelated\n")
        (self.project / "spec/link").symlink_to(outside, target_is_directory=True)
        for path in ("../outside/note.txt", "spec/link/note.txt", str(sentinel)):
            with self.subTest(path=path):
                patch = PATCH.replace("spec/note.txt", path)
                self.assertNotEqual(self.run_patch("git-apply-check", patch).returncode, 0)
                self.assertNotEqual(self.run_patch("git-apply", patch).returncode, 0)
                self.assertEqual(sentinel.read_text(), "before\nunrelated\n")
                # A skipped/unsafe second target must not let the first apply.
                self.assertNotEqual(self.run_patch("git-apply", PATCH + patch).returncode, 0)
                self.assertEqual(self.note.read_text(), "before\nunrelated\n")

    def test_oversized_patch_is_rejected_without_mutation(self):
        self.assertNotEqual(self.run_patch("git-apply", "x" * 2_000_001).returncode, 0)
        self.assertEqual(self.note.read_text(), "before\nunrelated\n")


if __name__ == "__main__":
    unittest.main()
