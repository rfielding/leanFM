#!/usr/bin/env python3
"""Allowlisted project builds with no credentials, outside files or network."""
import os
from pathlib import Path
import resource
import re
import subprocess
import sys

INSTALLATION = Path(__file__).resolve().parents[1]


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (3 * 1024**3, 3 * 1024**3))
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    resource.setrlimit(resource.RLIMIT_FSIZE, (32 * 1024**2, 32 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main(operation, root_name):
    root = Path(root_name).resolve(strict=True)
    if operation in {"build", "check", "http-check"}:
        makefile = next((root / name for name in ["GNUmakefile", "makefile", "Makefile"] if (root / name).is_file()), None)
        if makefile is None:
            raise ValueError("Project has no Makefile and does not provide the '" + operation +
                             "' check. Use leanfm_check for canonical requirements and implementation specifications; do not substitute an application build.")
        if makefile.is_symlink() or makefile.stat().st_size > 2_000_000:
            raise ValueError("Project Makefile must be a bounded ordinary project file")
        source = makefile.read_text()
        if not re.search(r"(?m)^(?:[A-Za-z0-9_.-]+[ \t]+)*" + re.escape(operation) + r"(?:[ \t]+[A-Za-z0-9_.-]+)*[ \t]*:(?!=)", source):
            raise ValueError("Project Makefile does not explicitly declare the '" + operation +
                             "' target. Use a check provided by this project; use leanfm_check for specifications.")
    cache = root / ".cache"
    if cache.is_symlink():
        raise ValueError("Project cache cannot be a symlink")
    cache.mkdir(exist_ok=True)
    prefix = ["bwrap", "--die-with-parent", "--new-session", "--unshare-all", "--cap-drop", "ALL"]
    for path in ["/usr", "/bin", "/lib", "/lib64"]:
        prefix += ["--ro-bind", path, path]
    for path in ["/etc/fonts", "/etc/texmf", "/var/lib/texmf", "/etc/alternatives", "/etc/ld.so.cache"]:
        if Path(path).exists():
            prefix += ["--ro-bind", path, path]
    toolchain = Path(subprocess.check_output(["elan", "which", "lean"], cwd=INSTALLATION, text=True).strip()).resolve().parent.parent
    prefix += ["--ro-bind", str(toolchain), "/toolchain", "--ro-bind", str(INSTALLATION / ".lake/build/lib/lean"), "/leanfm-lib"]
    go = INSTALLATION / ".toolchains/go"
    if go.is_dir():
        prefix += ["--ro-bind", str(go), "/go"]
    prefix += ["--ro-bind", str(root), "/work", "--bind", str(cache), "/work/.cache"]
    if operation == "book":
        book = root / "book"
        if book.is_symlink() or book.resolve().parent != root:
            raise ValueError("Book directory escapes project")
        prefix += ["--bind", str(book), "/work/book"]
    prefix += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
               "--chdir", "/work", "--clearenv", "--setenv", "HOME", "/tmp", "--setenv", "PATH", "/go/bin:/toolchain/bin:/usr/bin:/bin",
               "--setenv", "LEAN_PATH", "/leanfm-lib:/toolchain/lib/lean", "--setenv", "GOCACHE", "/work/.cache/go-build",
               "--setenv", "GOMODCACHE", "/work/.cache/go-mod", "--setenv", "GOTOOLCHAIN", "local", "--setenv", "GOPROXY", "off", "--"]
    if operation == "go":
        commands = ["/go/bin/go", "-C", "/work/source" if (root / "source/go.mod").is_file() else "/work", "test", "./..."]
    elif operation in {"build", "check", "http-check"}:
        commands = ["/usr/bin/make", "-C", "/work", operation]
    elif operation == "book":
        commands = ["/usr/bin/make", "-C", "/work/book"]
    else:
        raise ValueError("Unknown project check")
    output = cache / "last-check.log"
    if output.is_symlink():
        raise ValueError("Check output cannot be a symlink")
    with output.open("wb") as log:
        result = subprocess.run(prefix + commands, stdout=log, stderr=subprocess.STDOUT, preexec_fn=limits, timeout=300)
    if output.is_symlink():
        raise ValueError("Check output was replaced by a symlink")
    print(output.read_text(errors="replace")[-20000:], end="")
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
