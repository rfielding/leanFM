#!/usr/bin/env python3
"""Project-owned image attachments. Refs: media, Multimodal round trip,
Concurrent BYOK isolation, project_containment. Never fetch external resources."""
import base64
import fcntl
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import sys
import tempfile
import uuid
import warnings

from PIL import Image, ImageOps

MAX_BYTES = 2 * 1024 * 1024
MAX_PIXELS = 16_000_000
MAX_PREVIEW = 4 * 1024 * 1024
MAX_STORAGE = 128 * 1024 * 1024
MAX_IMAGES = 4
ID = re.compile(r"^[a-f0-9]{32}$")
MIMES = {"PNG": "image/png", "JPEG": "image/jpeg", "GIF": "image/gif"}
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
warnings.simplefilter("error", Image.DecompressionBombWarning)


class MediaError(ValueError):
    pass


def directory(root, relative, create=False):
    current = root
    for part in relative.split("/"):
        if not part or part in {".", ".."}:
            raise MediaError("Invalid attachment path.")
        current = current / part
        if current.is_symlink():
            raise MediaError("Attachment storage cannot contain symlinks.")
        if create:
            current.mkdir(mode=0o700, exist_ok=True)
        if not current.is_dir():
            raise MediaError("Attachment not found in this project.")
    return current


def bounded_read(path, limit):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise MediaError("Attachment is missing, oversized, or unsafe.")
    with path.open("rb") as stream:
        body = stream.read(limit + 1)
    if len(body) > limit:
        raise MediaError("Attachment exceeds its byte limit.")
    return body


def svg_png(raw):
    from defusedxml import ElementTree as ET
    from cairosvg.surface import PNGSurface
    tags = {"svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline",
            "polygon", "text", "tspan", "defs", "clipPath", "linearGradient",
            "radialGradient", "stop", "mask", "pattern", "symbol", "use", "title", "desc"}
    document = ET.fromstring(raw, forbid_dtd=True)
    if document.tag != "{http://www.w3.org/2000/svg}svg":
        raise MediaError("Expected an SVG drawing.")
    for element in document.iter():
        if element.tag.split("}")[-1] not in tags:
            raise MediaError("SVG must contain only static drawing elements.")
        for key, value in element.attrib.items():
            name = key.split("}")[-1].lower()
            if (name.startswith("on") or name in {"src", "base"} or
                    (name == "href" and not re.fullmatch(r"#[A-Za-z0-9_.:-]+", value)) or
                    re.search(r"@|expression\s*\(|https?:|file:|data:", value, re.I) or
                    any(not re.fullmatch(r"\s*#[A-Za-z0-9_.:-]+\s*", ref)
                        for ref in re.findall(r"url\s*\((.*?)\)", value, re.I))):
                raise MediaError("SVG external resources and executable content are forbidden.")
    view = document.get("viewBox", "").replace(",", " ").split()
    fallback = view[2:] if len(view) == 4 else ["300", "150"]
    dimensions = []
    for name, default in zip(("width", "height"), fallback):
        value = document.get(name, default).removesuffix("px")
        dimensions.append(float(value))
    width, height = dimensions
    if not all(math.isfinite(v) and 0 < v <= 8192 for v in dimensions) or width * height > MAX_PIXELS:
        raise MediaError("Image exceeds the 16 megapixel or 8192 pixel edge limit.")
    scale = min(1, 2048 / max(width, height))
    def deny_fetch(*_args, **_kwargs):
        raise MediaError("SVG external resources are forbidden.")
    return PNGSurface.convert(bytestring=ET.tostring(document),
                              output_width=max(1, round(width * scale)),
                              output_height=max(1, round(height * scale)),
                              url_fetcher=deny_fetch)


def normalize(raw, declared):
    if declared == "image/svg+xml":
        source = svg_png(raw)
        media_type, extension = declared, "svg"
    else:
        source = raw
        with Image.open(io.BytesIO(raw)) as probe:
            media_type = MIMES.get(probe.format)
            if media_type is None or media_type != declared:
                raise MediaError("File content must match its PNG, JPEG, GIF, or SVG media type.")
            probe.verify()
        extension = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif"}[media_type]
    with Image.open(io.BytesIO(source)) as image:
        if image.width > 8192 or image.height > 8192 or image.width * image.height > MAX_PIXELS:
            raise MediaError("Image exceeds the 16 megapixel or 8192 pixel edge limit.")
        image.seek(0)
        image = ImageOps.exif_transpose(image).convert("RGBA")
        image.thumbnail((2048, 2048))
        clean = Image.new("RGBA", image.size)
        clean.paste(image)
        output = io.BytesIO()
        clean.save(output, format="PNG")
        preview = output.getvalue()
        if len(preview) > MAX_PREVIEW:
            raise MediaError("Normalized image exceeds the 4 MiB preview limit.")
        return media_type, extension, preview, image.width, image.height


def upload(root, request):
    declared = request.get("media_type", "")
    encoded = request.get("content", "")
    if not isinstance(encoded, str) or len(encoded) > (MAX_BYTES + 2) // 3 * 4:
        raise MediaError("Images must be at most 2 MiB each.")
    raw = base64.b64decode(encoded, validate=True)
    if not raw or len(raw) > MAX_BYTES:
        raise MediaError("Images must be nonempty and at most 2 MiB each.")
    media_type, extension, preview, width, height = normalize(raw, declared)
    store = directory(root, "artifacts/attachments", create=True)
    lock = os.open(store / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "w") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        children = list(store.iterdir())
        if len(children) > 513 or any(p.is_symlink() for p in children):
            raise MediaError("Attachment storage is full or unsafe.")
        files = list(store.glob("*/*"))
        if len(files) > 1536 or any(p.is_symlink() for p in files):
            raise MediaError("Attachment storage is full or unsafe.")
        used = sum(p.stat().st_size for p in files if p.is_file())
        if used + len(raw) + len(preview) + 4096 > MAX_STORAGE:
            raise MediaError("This project has reached its 128 MiB attachment limit.")
        artifact_id = uuid.uuid4().hex
        relative = f"artifacts/attachments/{artifact_id}"
        name = str(request.get("filename", "Attached image"))[:200]
        name = "".join(c for c in name if c.isprintable())
        manifest = {"artifact_id": artifact_id, "revision": 1, "name": name,
                    "media_type": media_type, "bytes": len(raw), "width": width, "height": height,
                    "path": relative + "/image.png", "original_path": relative + "/original." + extension,
                    "preview_sha256": hashlib.sha256(preview).hexdigest(),
                    "source_sha256": hashlib.sha256(raw).hexdigest(),
                    "frame": "first" if media_type == "image/gif" else "still"}
        temporary = Path(tempfile.mkdtemp(prefix=".pending-", dir=store))
        try:
            (temporary / ("original." + extension)).write_bytes(raw)
            (temporary / "image.png").write_bytes(preview)
            (temporary / "manifest.json").write_text(json.dumps(manifest) + "\n")
            os.rename(temporary, store / artifact_id)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        return manifest


def resolve(root, request):
    ids = request.get("attachment_ids", [])
    if (not isinstance(ids, list) or len(ids) > MAX_IMAGES or
            any(not isinstance(value, str) or not ID.fullmatch(value) for value in ids) or
            len(set(ids)) != len(ids)):
        raise MediaError("Supply at most four distinct project attachment IDs.")
    images = []
    for artifact_id in ids:
        folder = directory(root, f"artifacts/attachments/{artifact_id}")
        manifest = json.loads(bounded_read(folder / "manifest.json", 4096))
        preview = bounded_read(folder / "image.png", MAX_PREVIEW)
        if manifest["artifact_id"] != artifact_id or hashlib.sha256(preview).hexdigest() != manifest["preview_sha256"]:
            raise MediaError("Attachment integrity check failed.")
        with Image.open(io.BytesIO(preview)) as image:
            if image.format != "PNG" or max(image.size) > 2048:
                raise MediaError("Stored preview is not a bounded PNG image.")
            image.verify()
        images.append({"data": base64.b64encode(preview).decode(), "media_type": "image/png",
                       "label": f"Attachment {artifact_id}, {manifest['frame']} frame"})
    return {"images": images}


def main():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CPU, (15, 15))
    try:
        request = json.loads(sys.stdin.buffer.read(4 * 1024 * 1024))
        root = Path(sys.argv[2]).resolve(strict=True)
        result = {"upload": upload, "resolve": resolve}[sys.argv[1]](root, request)
        print(json.dumps(result))
    except MediaError as error:
        print(json.dumps({"error": str(error)}))
    except Exception:
        print(json.dumps({"error": "Image could not be validated. Use a valid PNG, JPEG, GIF, or static SVG."}))


if __name__ == "__main__":
    main()
