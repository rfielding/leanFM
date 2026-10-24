#!/usr/bin/env python3
"""Readable roots preserve identities and never overwrite or escape projects.

Refs: shared_projects_have_one_root, shared_storage_preserves_project_identity,
migration_never_overwrites_or_loses_state, shared_project_paths_never_reach_credentials.
"""
from concurrent.futures import ThreadPoolExecutor
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from chatui_workspace import main, project, reserve

ROOT = Path(__file__).resolve().parents[1]


class Workspace(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="project-names-", dir=ROOT / ".cache")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / "projects"
        self.base.mkdir()

    def fixture(self, directory, identity, portable=False):
        path = self.base / directory
        path.mkdir()
        key = "id" if portable else "project_id"
        (path / ("project.json" if portable else "manifest.json")).write_text(json.dumps(
            {key: identity, "display_name": "GoServer", "root": ".", "book": "book/main.pdf"}))
        return path

    def listing(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            main("list", str(self.root))
        return json.loads(output.getvalue())

    def test_readable_atomic_reservations_never_adopt_existing_directories(self):
        first, identity = reserve(self.root, "GoServer")
        self.assertEqual((first.name, identity), ("GoServer", "GoServer"))
        (first / "sentinel").write_bytes(b"preserve existing project")
        with ThreadPoolExecutor(max_workers=6) as pool:
            created = list(pool.map(lambda _: reserve(self.root, "GoServer"), range(6)))
        self.assertEqual({path.name for path, _ in created}, {f"GoServer-{i}" for i in range(2, 8)})
        self.assertEqual((first / "sentinel").read_bytes(), b"preserve existing project")
        self.assertEqual(reserve(self.root, "A useful project")[0].name, "A-useful-project")

    def test_renamed_roots_keep_identity_portable_paths_and_every_byte(self):
        original = self.fixture("e7fdeae8572f7c9f", "e7fdeae8572f7c9f")
        for name in ["source/server.go", ".leanfm/acceptance.json", "conversations/default.jsonl", "cache/opaque.bin"]:
            path = original / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"unchanged owned state\x00\xff")
        before = {str(p.relative_to(original)): p.read_bytes() for p in original.rglob("*") if p.is_file()}
        renamed = original.with_name("GoServer")
        original.rename(renamed)
        self.assertEqual(project(self.root, "e7fdeae8572f7c9f")[0], renamed)
        self.assertEqual({str(p.relative_to(renamed)): p.read_bytes() for p in renamed.rglob("*") if p.is_file()}, before)
        self.assertEqual(self.listing()[0]["project_id"], "e7fdeae8572f7c9f")
        self.assertEqual(reserve(self.root, "GoServer")[1], "GoServer-2")
        portable = self.fixture("Portable-name", "portable-stable-id", portable=True)
        self.assertEqual(project(self.root, "portable-stable-id")[0], portable)
        with self.assertRaises(ValueError):
            project(self.root, "GoServer")

    def test_duplicate_identities_fail_closed_and_cannot_be_reused(self):
        self.fixture("First", "same")
        self.fixture("Second", "same")
        with self.assertRaises(ValueError):
            project(self.root, "same")
        self.assertEqual(self.listing(), [])
        self.assertEqual(reserve(self.root, "same")[1], "same-2")

    def test_unsafe_names_remain_bounded_children_and_reserved_host_is_excluded(self):
        for name in ["../../.leanfm/accounts", "$(touch INJECTED); hi", "...", "🪨", "A" * 10000, "leanfm-workspace"]:
            with self.subTest(name=name[:80]):
                path, identity = reserve(self.root, name)
                self.assertEqual(path.parent, self.base)
                self.assertLessEqual(len(identity), 64)
                self.assertNotEqual(identity, "leanfm-workspace")
                self.assertTrue(all(c.isascii() and (c.isalnum() or c in "-_") for c in identity))
        self.assertFalse((self.root / ".leanfm").exists())
        self.assertFalse((self.root / "INJECTED").exists())
        for identity in ["..", "../outside", "/tmp", "leanfm-workspace", "x" * 65]:
            with self.assertRaises(ValueError):
                project(self.root, identity)

    def test_symlink_roots_manifests_and_configured_path_escapes_are_rejected(self):
        outside = self.root / "vault"
        outside.mkdir()
        (self.base / "Link").symlink_to(outside, target_is_directory=True)
        self.assertEqual(reserve(self.root, "Link")[1], "Link-2")
        linked = self.base / "Linked-manifest"
        linked.mkdir()
        manifest = outside / "manifest.json"
        manifest.write_text(json.dumps({"project_id": "secret", "root": "."}))
        (linked / "manifest.json").symlink_to(manifest)
        escaped = self.fixture("Escaping-path", "escape")
        (escaped / "manifest.json").write_text(json.dumps({"project_id": "escape", "book": "../../vault/private"}))
        for identity in ["secret", "escape"]:
            with self.assertRaises(ValueError):
                project(self.root, identity)
        self.assertEqual(self.listing(), [])
        self.base.rename(self.root / "old-projects")
        self.base.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            reserve(self.root, "must-not-write")
        self.assertFalse((outside / "must-not-write").exists())


if __name__ == "__main__":
    unittest.main()
