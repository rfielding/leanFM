#!/usr/bin/env python3
"""Real checks, independent gates, stale refusal and reserved-path controls."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from chatui_project_state import current, accept, authorize_path
from chatui_specification_fixture import REQUIREMENTS, PROTO, IMPLEMENTATION

ROOT = Path(__file__).resolve().parents[1]


class Gates(unittest.TestCase):
    def setUp(self):
        (ROOT / ".cache").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="project-gates-", dir=ROOT / ".cache")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ["book", "spec", "source"]:
            (self.root / directory).mkdir()
        (self.root / "book/main.tex").write_text("Book revision one")
        for name, value in [("Requirements.lean", REQUIREMENTS), ("Requirements.proto", PROTO), ("Implementation.lean", IMPLEMENTATION)]:
            (self.root / "spec" / name).write_text(value)

    def check(self, implementation=False):
        result = subprocess.run(["python3", str(ROOT / "scripts/chatui_specification.py"), str(self.root), "Fixture.spec", "Fixture.implementation" if implementation else ""],
                                capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_independent_current_gates_and_no_model_acceptance(self):
        self.assertFalse(current(self.root)["ready"])
        with self.assertRaises(ValueError):
            authorize_path(self.root, "source/main.go")
        self.check()
        state = current(self.root)
        self.assertTrue(state["requirements"]["checked"])
        self.assertFalse(state["implementation"]["checked"])
        accept(self.root, "requirements", state["requirements"]["revision"])
        accepted_snapshot = self.root / ".leanfm/accepted/requirements" / state["requirements"]["revision"] / "spec/tasks.json"
        snapshot_bytes = accepted_snapshot.read_bytes()
        with self.assertRaises(ValueError):
            authorize_path(self.root, "source/main.go")
        self.check(implementation=True)
        state = current(self.root)
        self.assertTrue(state["requirements"]["accepted"], "implementation checking reopened an unchanged requirements gate")
        accept(self.root, "implementation", state["implementation"]["revision"])
        self.assertTrue(current(self.root)["ready"])
        authorize_path(self.root, "source/main.go")
        accept(self.root, "requirements", state["requirements"]["revision"])
        self.assertTrue(current(self.root)["ready"], "duplicate acceptance revoked a current later gate")
        self.assertEqual(accepted_snapshot.read_bytes(), snapshot_bytes, "duplicate acceptance rewrote an immutable accepted snapshot")
        for path in ["manifest.json", "project.json", ".leanfm/acceptance.json", ".leanfm/accepted/forged", "reports/specification-check/validation.json", "../outside"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                authorize_path(self.root, path)
        previous = (self.root / ".leanfm/acceptance.json").read_bytes()
        (self.root / "book/main.tex").write_text("Book revision two")
        self.assertFalse(current(self.root)["ready"])
        with self.assertRaises(ValueError):
            accept(self.root, "requirements", state["requirements"]["revision"])
        self.assertEqual(previous, (self.root / ".leanfm/acceptance.json").read_bytes())


if __name__ == "__main__":
    unittest.main()
