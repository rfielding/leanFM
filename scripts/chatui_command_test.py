#!/usr/bin/env python3
"""Project-authored checks cannot access host data, keys, gates or network."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Commands(unittest.TestCase):
    def test_unavailable_build_targets_are_rejected_before_make_execution(self):
        with tempfile.TemporaryDirectory(prefix="command-targets-", dir=ROOT / ".cache") as fixture:
            root = Path(fixture)
            for source in [None, "$(shell touch should-not-run)\nbook:\n\t@true\n"]:
                if source is not None:
                    (root / "Makefile").write_text(source)
                result = subprocess.run(["python3", str(ROOT / "scripts/chatui_command_runner.py"), "build", str(root)],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("leanfm_check", result.stderr)
                self.assertNotIn("No rule to make target", result.stdout + result.stderr)
                self.assertFalse((root / "should-not-run").exists())

    def test_media_generation_and_conversion_cannot_forge_project_gates(self):
        with tempfile.TemporaryDirectory(prefix="media-isolation-", dir=ROOT / ".cache") as fixture:
            root = Path(fixture)
            (root / ".leanfm").mkdir()
            gate = root / ".leanfm/acceptance.json"
            gate.write_text("preserve gate")
            (root / "generator.py").write_text('''from PIL import Image
import pathlib,sys
try:
    pathlib.Path(".leanfm/acceptance.json").write_text("forged")
except OSError:
    pass
else:
    raise RuntimeError("gate was writable")
a=Image.new("RGB",(16,16),"red"); b=Image.new("RGB",(16,16),"blue")
a.save(sys.argv[1],save_all=True,append_images=[b],duration=100,loop=0)
''')
            for arguments in [["generate-gif", str(root), "generator.py", "renders/demo.gif"],
                              ["transcode-mp4", str(root), str(root / "renders/demo.gif"), str(root / "renders/demo.mp4")]]:
                result = subprocess.run(["bash", str(ROOT / "scripts/chatui_command.sh")] + arguments, capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(gate.read_text(), "preserve gate")
            self.assertEqual((root / "renders/demo.mp4").read_bytes()[4:8], b"ftyp")

    def test_check_has_only_cache_and_temporary_write_authority(self):
        with tempfile.TemporaryDirectory(prefix="command-isolation-", dir=ROOT / ".cache") as fixture:
            fixture = Path(fixture)
            root = fixture / "project"
            (root / ".leanfm").mkdir(parents=True)
            (root / ".leanfm/acceptance.json").write_text("preserve gate")
            outside = fixture / "secret"
            outside.write_text("outside")
            with socket.socket() as server:
                server.bind(("127.0.0.1", 0))
                server.listen(1)
                program = f'''import os, pathlib, socket
assert os.getenv("LEANFM_TEST_SECRET") is None
assert not pathlib.Path({str(outside)!r}).exists()
s=socket.socket(); s.settimeout(1)
assert s.connect_ex(("127.0.0.1",{server.getsockname()[1]})) != 0
try:
    pathlib.Path(".leanfm/acceptance.json").write_text("forged")
except OSError:
    pass
else:
    raise AssertionError("gate was writable")
pathlib.Path(".cache/check-passed").write_text("passed")
'''
                (root / "test.py").write_text(program)
                (root / "Makefile").write_text("check:\n\tpython3 test.py\n")
                env = dict(os.environ, LEANFM_TEST_SECRET="must not cross the process boundary")
                result = subprocess.run(["bash", str(ROOT / "scripts/chatui_command.sh"), "check-check", str(root)], env=env,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / ".leanfm/acceptance.json").read_text(), "preserve gate")
            self.assertEqual((root / ".cache/check-passed").read_text(), "passed")


if __name__ == "__main__":
    unittest.main()
