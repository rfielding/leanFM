#!/usr/bin/env python3
"""Real compiler, project isolation and last-good-view regression checks."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import socket
import tempfile
import unittest

from chatui_specification_fixture import REQUIREMENTS, PROTO

ROOT = Path(__file__).resolve().parents[1]


class Specification(unittest.TestCase):
    def setUp(self):
        (ROOT / ".cache").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="specification-test-", dir=ROOT / ".cache")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "spec").mkdir()
        (self.root / "source").mkdir()
        (self.root / "spec/Requirements.lean").write_text(REQUIREMENTS)
        (self.root / "spec/Requirements.proto").write_text(PROTO)
        (self.root / "manifest.json").write_text('{"acceptance":{"requirements":"pending","implementation":"pending"}}')
        (self.root / "source/preserved.txt").write_text("preserve source")

    def run_check(self, requirement="Fixture.spec", implementation="", ok=True):
        result = subprocess.run(["python3", str(ROOT / "scripts/chatui_specification.py"), str(self.root), requirement, implementation],
                                cwd=ROOT, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_current_project_views_and_revisions_without_gate_or_source_changes(self):
        before = [(self.root / p).read_bytes() for p in ["manifest.json", "source/preserved.txt"]]
        self.run_check()
        catalog = json.loads((self.root / "spec/tasks.json").read_text())
        self.assertIn("Client->>FixtureServer: FixtureRequest", catalog["tasks"][0]["interaction_mermaid"])
        self.assertNotIn("ChatPromptSubmitted", json.dumps(catalog))
        self.assertEqual(catalog["provenance"]["acceptance"], "unchanged")
        revised = REQUIREMENTS.replace("Project-specific request", "Revised project request")
        (self.root / "spec/Requirements.lean").write_text(revised)
        self.run_check()
        catalog = json.loads((self.root / "spec/tasks.json").read_text())
        self.assertEqual(catalog["tasks"][0]["title"], "Revised project request")
        self.assertEqual(catalog["provenance"]["artifacts"]["spec/Requirements.lean"], hashlib.sha256(revised.encode()).hexdigest())
        self.assertEqual(before, [(self.root / p).read_bytes() for p in ["manifest.json", "source/preserved.txt"]])

    def test_compile_proto_and_grammar_failures_preserve_last_good_catalog(self):
        self.run_check()
        before = (self.root / "spec/tasks.json").read_bytes()
        for source, proto in [(REQUIREMENTS + "\ndef broken : Nat := false\n", PROTO),
                              (REQUIREMENTS, 'syntax = "proto3";'),
                              (REQUIREMENTS.replace('terminals := ["done"]', 'terminals := ["missing"]'), PROTO)]:
            with self.subTest(source=source[-50:], proto=proto):
                (self.root / "spec/Requirements.lean").write_text(source)
                (self.root / "spec/Requirements.proto").write_text(proto)
                self.run_check(ok=False)
                self.assertEqual(before, (self.root / "spec/tasks.json").read_bytes())

    def test_executable_lean_has_no_outside_environment_or_write_authority(self):
        outside = self.root.parent / (self.root.name + "-private")
        outside.write_text("PRIVATE_SENTINEL")
        self.addCleanup(lambda: outside.unlink(missing_ok=True))
        (self.root / "spec/Requirements.lean").write_text(REQUIREMENTS + '''
#eval (do
  if (← IO.getEnv "LEANFM_TEST_SECRET").isSome then throw (IO.userError "environment leaked")
  let outside := System.FilePath.mk "''' + str(outside) + '''"
  if (← outside.pathExists) then throw (IO.userError "outside file leaked")
  let wrote ← try IO.FS.writeFile "/work/source/preserved.txt" "changed"; pure true catch _ => pure false
  if wrote then throw (IO.userError "project source was writable")
  : IO Unit)
''')
        previous = os.environ.get("LEANFM_TEST_SECRET")
        os.environ["LEANFM_TEST_SECRET"] = "PRIVATE_SENTINEL"
        try:
            self.run_check()
        finally:
            if previous is None:
                os.environ.pop("LEANFM_TEST_SECRET")
            else:
                os.environ["LEANFM_TEST_SECRET"] = previous
        self.assertEqual((self.root / "source/preserved.txt").read_text(), "preserve source")

    def test_executable_lean_cannot_connect_to_the_host_network(self):
        listener = socket.socket()
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        program = f"import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(1 if s.connect_ex(('127.0.0.1',{port})) == 0 else 0)"
        (self.root / "spec/Requirements.lean").write_text(REQUIREMENTS + '''
#eval (do
  let result ← IO.Process.output {cmd := "/usr/bin/python3", args := #["-c", ''' + json.dumps(program) + ''']}
  if result.exitCode != 0 then throw (IO.userError "host network was reachable")
  : IO Unit)
''')
        self.run_check()

    def test_symlink_inputs_outputs_and_identifier_injection_are_rejected(self):
        self.run_check("Fixture.spec\n#eval IO.println 1", ok=False)
        source = self.root / "spec/Requirements.lean"
        original = source.read_text()
        source.unlink()
        source.symlink_to(ROOT / "LeanFM/ChatUI/Requirements.lean")
        self.assertIn("symlink", self.run_check(ok=False).stderr)
        source.unlink()
        source.write_text(original)
        (self.root / "spec/tasks.json").symlink_to(self.root / "manifest.json")
        self.assertIn("symlink", self.run_check(ok=False).stderr)

    def test_prose_only_implementation_cannot_validate_as_typed_mapping(self):
        (self.root / "spec/Implementation.lean").write_text("-- Implement a server with bounded queues.\n")
        self.assertIn("unknown identifier", self.run_check(implementation="Fixture.implementation", ok=False).stderr.lower())


if __name__ == "__main__":
    unittest.main()
