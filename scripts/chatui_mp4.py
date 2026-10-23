#!/usr/bin/env python3
"""Confined media conversion; untrusted inputs cannot open host paths/network.
Requirement refs: shared_project_paths_never_reach_credentials,
third_party_commands_cross_one_whitelist, feature_completion_pairs_positive_and_negative_invariants.
"""
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
from chatui_specification import confined, limits
from chatui_project_state import authorize_path


def main(root_name, input_name, output_name):
    root = Path(root_name).resolve(strict=True)
    input_relative = str(Path(input_name).relative_to(root)) if Path(input_name).is_absolute() else input_name
    output_relative = str(Path(output_name).relative_to(root)) if Path(output_name).is_absolute() else output_name
    source = confined(root, input_relative)
    destination = confined(root, output_relative)
    authorize_path(root, output_relative)
    if source.suffix.lower() not in {".gif", ".webm"} or destination.suffix.lower() != ".mp4":
        raise ValueError("Expected project-local GIF/WebM input and MP4 output")
    scratch = confined(root, ".leanfm/checks", directory=True)
    with tempfile.TemporaryDirectory(prefix="mp4-", dir=scratch) as temporary:
        temporary = Path(temporary)
        command = ["bwrap", "--die-with-parent", "--new-session", "--unshare-all", "--cap-drop", "ALL"]
        for path in ["/usr", "/bin", "/lib", "/lib64"]:
            command += ["--ro-bind", path, path]
        for path in ["/etc/alternatives", "/etc/ld.so.cache"]:
            if Path(path).exists():
                command += ["--ro-bind", path, path]
        command += ["--ro-bind", str(root), "/work", "--bind", str(temporary), "/generated", "--proc", "/proc", "--dev", "/dev",
                    "--tmpfs", "/tmp", "--clearenv", "--setenv", "PATH", "/usr/bin:/bin", "--",
                    "/usr/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe",
                    "-i", "/work/" + input_relative, "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-an", "-c:v", "libx264",
                    "-preset", "medium", "-crf", "20", "-profile:v", "high", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "/generated/result.mp4"]
        with (temporary / "conversion.log").open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120, preexec_fn=limits)
        if result.returncode:
            raise ValueError("MP4 conversion failed: " + (temporary / "conversion.log").read_text(errors="replace")[-6000:])
        candidate = temporary / "result.mp4"
        if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size > 536870912:
            raise ValueError("Missing or oversized MP4 output")
        with candidate.open("rb") as stream:
            if stream.read(12)[4:8] != b"ftyp":
                raise ValueError("Invalid MP4 output")
        confined(root, output_relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as target:
            target.write(candidate.read_bytes())
            staged = Path(target.name)
        os.chmod(staged, 0o600)
        staged.replace(destination)
    print("OK: validated MP4 " + output_relative)


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
