#!/usr/bin/env python3
"""Real checks, git commit status, no approval step, and reserved-path controls."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from chatui_project_state import current, authorize_path, main
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

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.root), *arguments], check=True, capture_output=True)

    def test_checks_and_git_status_without_approvals(self):
        state = current(self.root)
        self.assertTrue(state["ready"], "LeanFM must not block on an approval")
        self.assertFalse(state["requirements"]["checked"])
        authorize_path(self.root, "source/main.go")  # source writes never wait for an approval
        self.check()
        self.check(implementation=True)
        state = current(self.root)
        self.assertTrue(state["requirements"]["checked"] and state["implementation"]["checked"])
        self.assertFalse(state["git"]["repository"])
        self.assertIsNone(state["requirements"]["committed"])
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-q", "-m", "spec")
        state = current(self.root)
        self.assertTrue(state["requirements"]["committed"] and state["implementation"]["committed"])
        (self.root / "book/main.tex").write_text("Book revision two")
        state = current(self.root)
        self.assertFalse(state["requirements"]["checked"], "a changed book needs a fresh check")
        self.assertFalse(state["requirements"]["committed"])
        self.assertIn("book/main.tex", state["git"]["uncommitted"])
        self.assertTrue(state["ready"])
        for path in ["manifest.json", "project.json", "reports/specification-check/validation.json", "../outside"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                authorize_path(self.root, path)

    def test_repository_config_cannot_run_code(self):
        self.git("init", "-q")
        marker = self.root / "pwned"
        hook = self.root / "fsmonitor.sh"
        hook.write_text("#!/bin/sh\ntouch " + str(marker) + "\n")
        hook.chmod(0o700)
        self.git("config", "core.fsmonitor", str(hook))
        self.git("config", "diff.external", str(hook))
        current(self.root)
        self.assertFalse(marker.exists(), "project git config executed code")

    def test_accept_is_gone(self):
        with self.assertRaises(ValueError):
            main("accept", str(self.root), "requirements", "x")




if __name__ == "__main__":
    unittest.main()
