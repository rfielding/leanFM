#!/usr/bin/env python3
"""Allowlisted project builds with no credentials, outside files or network."""
import os
from pathlib import Path
import resource
import re
import subprocess
import sys
import json
from chatui_runtime import contract, revision
from chatui_specification import atomic, confined

INSTALLATION = Path(__file__).resolve().parents[1]


def limits():
    # Lean 4.35 reserves ~4.5 GiB of address space (not resident memory) when importing LeanFM.
    resource.setrlimit(resource.RLIMIT_AS, (6 * 1024**3, 6 * 1024**3))
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    resource.setrlimit(resource.RLIMIT_FSIZE, (32 * 1024**2, 32 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main(operation, root_name):
    root = Path(root_name).resolve(strict=True)
    application = (root / 'source/Makefile').is_file() and (root / 'spec/runtime.json').is_file()
    make_root = confined(root, 'source') if application else root
    if operation in {"build", "check", "http-check", "test"}:
        makefile = next((make_root / name for name in ["GNUmakefile", "makefile", "Makefile"] if (make_root / name).is_file()), None)
        if makefile is None:
            raise ValueError("Project has no Makefile and does not provide the '" + operation +
                             "' check. Use leanfm_check for canonical requirements and implementation specifications; do not substitute an application build.")
        if makefile.is_symlink() or makefile.stat().st_size > 2_000_000:
            raise ValueError("Project Makefile must be a bounded ordinary project file")
        source = makefile.read_text()
        if not re.search(r"(?m)^(?:[A-Za-z0-9_.-]+[ \t]+)*" + re.escape(operation) + r"(?:[ \t]+[A-Za-z0-9_.-]+)*[ \t]*:(?!=)", source):
            raise ValueError("Project Makefile does not explicitly declare the '" + operation +
                             "' target. Use a check provided by this project; use leanfm_check for specifications.")
    runtime_revision = None
    if operation == "runtime":
        contract(root)
        runtime_revision = revision(root)
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
    if operation == "runtime":
        prefix += ["--ro-bind", str(INSTALLATION / "scripts"), "/runtime"]
    prefix += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
               "--chdir", "/work", "--clearenv", "--setenv", "HOME", "/tmp", "--setenv", "PATH", "/go/bin:/toolchain/bin:/usr/bin:/bin",
               "--setenv", "LEAN_PATH", "/leanfm-lib:/toolchain/lib/lean", "--setenv", "GOCACHE", "/work/.cache/go-build",
               "--setenv", "GOMODCACHE", "/work/.cache/go-mod", "--setenv", "GOTOOLCHAIN", "local", "--setenv", "GOPROXY", "off", "--"]
    if operation == "runtime":
        commands = ["/usr/bin/python3", "/runtime/chatui_runtime.py", "probe", "/work"]
    elif operation == "go":
        commands = ["/go/bin/go", "-C", "/work/source" if (root / "source/go.mod").is_file() else "/work", "test", "./..."]
    elif operation in {"build", "check", "http-check", "test"}:
        commands = ["/usr/bin/make", "-C", "/work/source" if application else "/work", operation]
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
    text = output.read_text(errors="replace")[-20000:]
    if operation == "runtime":
        evidence = confined(root, "reports/runtime-check", directory=True)
        receipt = {"status":"failed", "revision":runtime_revision, "exit_code":result.returncode}
        if result.returncode == 0:
            observed = json.loads(text)
            if observed.get("status") != "validated" or revision(root) != runtime_revision:
                raise ValueError("Runtime inputs changed during verification or probe failed")
            receipt.update(observed)
        else:
            receipt["diagnostic"] = text[-12000:]
        atomic(confined(root,"reports/runtime-check/validation.json"),json.dumps(receipt,sort_keys=True)+"\n")
    print(text, end="")
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
