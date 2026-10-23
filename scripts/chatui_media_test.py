#!/usr/bin/env python3
"""Negative controls for existing multimodal, confinement and resource requirements."""
import base64
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
import chatui_media as media

REPO = Path(__file__).resolve().parent.parent


def raster(kind="PNG", color="red", size=(12, 8)):
    output = io.BytesIO()
    Image.new("RGB", size, color).save(output, format=kind)
    return output.getvalue()


def request(raw, mime="image/png"):
    return {"media_type": mime, "content": base64.b64encode(raw).decode(),
            "filename": "../../untrusted-name.png"}


class Images(unittest.TestCase):
    def setUp(self):
        (REPO / ".cache").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="media-test-", dir=REPO / ".cache")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def worker(self, operation, body):
        result = subprocess.run(["scripts/chatui_command.sh", "media-" + operation, str(self.root)],
                                input=json.dumps(body), text=True, capture_output=True,
                                timeout=25, cwd=REPO, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_native_pixels_originals_and_immutable_ids(self):
        for kind, mime in [("PNG", "image/png"), ("JPEG", "image/jpeg"), ("GIF", "image/gif")]:
            raw = raster(kind)
            uploaded = self.worker("upload", request(raw, mime))
            self.assertNotIn("error", uploaded, uploaded)
            self.assertEqual((self.root / uploaded["original_path"]).read_bytes(), raw)
            self.assertEqual((self.root / uploaded["path"]).stat().st_mode & 0o777, 0o600)
            resolved = self.worker("resolve", {"attachment_ids": [uploaded["artifact_id"]]})
            pixels = base64.b64decode(resolved["images"][0]["data"])
            with Image.open(io.BytesIO(pixels)) as image:
                self.assertEqual(image.format, "PNG")
                self.assertEqual(image.size, (12, 8))
                self.assertEqual(image.getpixel((0, 0))[:3], (255, 0, 0) if kind != "JPEG" else (254, 0, 0))
            self.assertEqual(uploaded["revision"], 1)
            if kind == "GIF":
                self.assertIn("first frame", resolved["images"][0]["label"])
        self.assertFalse((self.root.parent / "untrusted-name.png").exists())

    def test_safe_svg_raster_and_no_active_or_external_content(self):
        good = b'<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8" fill="red"/></svg>'
        self.assertNotIn("error", self.worker("upload", request(good, "image/svg+xml")))
        for payload in [
            b'<script>alert(1)</script>', b'<rect onload="alert(1)"/>',
            b'<image href="http://127.0.0.1/private"/>',
            b'<use href="file:///etc/passwd"/>',
            b'<rect style="fill:url(http://127.0.0.1/private)"/>',
            b'<foreignObject><p>HTML</p></foreignObject>',
        ]:
            with self.subTest(payload=payload):
                unsafe = good.replace(b'<rect width="12" height="8" fill="red"/>', payload)
                self.assertIn("error", self.worker("upload", request(unsafe, "image/svg+xml")))
        dtd = b'<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]>' + good
        self.assertIn("error", self.worker("upload", request(dtd, "image/svg+xml")))

    def test_corrupt_mislabeled_oversized_and_disk_bound(self):
        for body in [request(b"<html>not an image</html>"), request(raster(), "image/jpeg"),
                     request(raster()[:20]), request(b"x" * (media.MAX_BYTES + 1)),
                     request(raster(size=(8193, 1))), {"content": "not base64", "media_type": "image/png"}]:
            with self.subTest(body_keys=list(body)):
                self.assertIn("error", self.worker("upload", body))
        with patch.object(media, "MAX_STORAGE", 1):
            with self.assertRaises(media.MediaError):
                media.upload(self.root, request(raster()))
        self.assertEqual(list(self.root.glob("artifacts/attachments/[a-f0-9]*")), [])

    def test_traversal_foreign_root_symlink_and_integrity_fail_closed(self):
        uploaded = self.worker("upload", request(raster()))
        identity = uploaded["artifact_id"]
        for ids in [["../secret"], ["/etc/passwd"], ["a" * 32] * 5, [identity, identity]]:
            self.assertIn("error", self.worker("resolve", {"attachment_ids": ids}))
        other = self.root / "other"
        other.mkdir()
        with self.assertRaises(media.MediaError):
            media.resolve(other, {"attachment_ids": [identity]})
        preview = self.root / uploaded["path"]
        preview.write_bytes(b"changed")
        self.assertIn("error", self.worker("resolve", {"attachment_ids": [identity]}))
        preview.unlink()
        preview.symlink_to(REPO / "README.md")
        self.assertIn("error", self.worker("resolve", {"attachment_ids": [identity]}))
        store = other / "artifacts"
        store.symlink_to(self.root / "artifacts", target_is_directory=True)
        self.assertIn("error", json.loads(subprocess.run(
            ["scripts/chatui_command.sh", "media-upload", str(other)], input=json.dumps(request(raster())),
            text=True, capture_output=True, cwd=REPO, check=True).stdout))


if __name__ == "__main__":
    unittest.main(verbosity=2)
