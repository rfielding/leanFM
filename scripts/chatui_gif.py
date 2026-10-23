#!/usr/bin/env python3
"""Run project media code with only isolated scratch write authority.
Requirement refs: shared_project_paths_never_reach_credentials,
third_party_commands_cross_one_whitelist, feature_completion_pairs_positive_and_negative_invariants.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from PIL import Image
from chatui_specification import confined, limits
from chatui_project_state import authorize_path


def main(root_name, script_name, output_name):
    root = Path(root_name).resolve(strict=True)
    script = confined(root, script_name)
    output = confined(root, output_name)
    authorize_path(root, output_name)
    if not script_name.endswith(".py") or not output_name.lower().endswith(".gif"):
        raise ValueError("Expected a project Python script and GIF output")
    scratch_root = confined(root, ".leanfm/checks", directory=True)
    with tempfile.TemporaryDirectory(prefix="gif-", dir=scratch_root) as temporary:
        temporary = Path(temporary)
        command = ["bwrap", "--die-with-parent", "--new-session", "--unshare-all", "--cap-drop", "ALL"]
        for path in ["/usr", "/usr/local", "/bin", "/lib", "/lib64"]:
            command += ["--ro-bind", path, path]
        command += ["--ro-bind", str(root), "/work", "--bind", str(temporary), "/generated", "--proc", "/proc", "--dev", "/dev",
                    "--tmpfs", "/tmp", "--chdir", "/work", "--clearenv", "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/tmp",
                    "--", "/usr/bin/python3", "/work/" + script_name, "/generated/result.gif"]
        with (temporary / "generator.log").open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=60, preexec_fn=limits)
        if result.returncode:
            raise ValueError("GIF generator failed: " + (temporary / "generator.log").read_text(errors="replace")[-6000:])
        candidate = temporary / "result.gif"
        if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size > 8 * 1024**2:
            raise ValueError("Missing, unsafe or oversized GIF output")
        limits()
        with Image.open(candidate) as image:
            if image.format != "GIF" or max(image.size) > 4096 or not 2 <= image.n_frames <= 500:
                raise ValueError("Expected a bounded animated GIF")
            image.load()
        confined(root, output_name)
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as target:
            target.write(candidate.read_bytes())
            staged = Path(target.name)
        os.chmod(staged, 0o600)
        staged.replace(output)
    print("OK: validated animated GIF " + output_name)


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
