#!/usr/bin/env python3
"""Check canonical project Lean in isolation and atomically derive task views.

Requirement refs: web_ui_replaces_external_coding_session,
chat_layers_mutate_only_their_artifacts, diagram_is_task_local,
selected_project_context_drives_chat, feature_completion_pairs_positive_and_negative_invariants.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import tempfile

INSTALLATION = Path(__file__).resolve().parents[1]
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*\Z")


class CheckerUnavailable(ValueError):
    """Local worker failure that another paid model round cannot repair."""


def confined(root, relative, directory=False):
    path = root
    for part in Path(relative).parts:
        if part in {"..", "/"}:
            raise ValueError("path escapes project")
        path = path / part
        if path.is_symlink():
            raise ValueError("symlink is not permitted: " + relative)
    if directory:
        path.mkdir(parents=True, exist_ok=True)
    return path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (3 * 1024**3, 3 * 1024**3))
    resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
    resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024**2, 8 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def atomic(path, body):
    with tempfile.NamedTemporaryFile(dir=path.parent, mode="w", encoding="utf-8", delete=False) as output:
        temporary = Path(output.name)
        output.write(body)
    try:
        os.chmod(temporary, 0o600)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def check(root_name, requirement, implementation="", constraints=""):
    for value in [requirement, implementation, constraints]:
        if value and not IDENTIFIER.fullmatch(value):
            raise ValueError("expected a dotted Lean constant name")
    if not requirement:
        raise ValueError("a RequirementSpec constant is required")
    supplied = Path(root_name).absolute()
    if supplied.is_symlink():
        raise ValueError("project root is a symlink")
    root = supplied.resolve(strict=True)
    requirements = confined(root, "spec/Requirements.lean")
    proto = confined(root, "spec/Requirements.proto")
    inputs = [requirements, proto]
    book = confined(root, "book/main.tex")
    if book.is_file():
        inputs.append(book)
    if implementation:
        inputs.append(confined(root, "spec/Implementation.lean"))
    for path in inputs:
        if not path.is_file() or path.stat().st_size > 2_000_000:
            raise ValueError("missing or oversized canonical input: " + path.name)
    if shutil.which("bwrap") is None:
        raise CheckerUnavailable("Required bwrap executable is missing. Install the bubblewrap package and run make sandbox-check; canonical Lean is never run without isolation.")
    scratch_root = confined(root, ".leanfm/checks", directory=True)
    report_root = confined(root, "reports/specification-check", directory=True)
    catalog_path = confined(root, "spec/tasks.json")
    report_path = confined(root, "reports/specification-check/validation.json")
    log_path = confined(root, "reports/specification-check/compiler.log")
    lock_path = confined(root, ".leanfm/checks/specification.lock")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        revisions = {str(path.relative_to(root)): digest(path) for path in inputs}
        toolchain_result = subprocess.run(["elan", "which", "lean"], cwd=INSTALLATION,
                                          capture_output=True, text=True, timeout=10, check=True)
        toolchain = Path(toolchain_result.stdout.strip()).resolve().parent.parent
        library = INSTALLATION / ".lake/build/lib/lean"
        if not (library / "LeanFM/ChatUI/Server.olean").is_file():
            raise ValueError("LeanFM installation needs make build before project validation")
        with tempfile.TemporaryDirectory(prefix="specification-", dir=scratch_root) as temporary:
            scratch = Path(temporary)
            (scratch / "spec").mkdir()
            relative = str(scratch.relative_to(root))
            sandbox_scratch = "/work/" + relative
            prefix = ["bwrap", "--die-with-parent", "--new-session", "--unshare-all", "--cap-drop", "ALL"]
            for system in ["/usr", "/bin", "/lib", "/lib64"]:
                prefix += ["--ro-bind", system, system]
            prefix += ["--ro-bind", str(toolchain), "/toolchain",
                       "--ro-bind", str(library), "/leanfm-lib", "--ro-bind", str(root), "/work",
                       "--bind", str(scratch), sandbox_scratch,
                       "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", "/work",
                       "--clearenv", "--setenv", "HOME", "/tmp", "--setenv", "PATH", "/toolchain/bin:/usr/bin:/bin",
                       "--setenv", "LEAN_PATH", sandbox_scratch + ":/leanfm-lib:/toolchain/lib/lean",
                       # Lean otherwise sizes its worker pool from host CPUs.
                       # Thread stacks/allocator arenas can exhaust RLIMIT_AS
                       # before elaboration even for an empty project module.
                       "--", "/toolchain/bin/lean", "-j2", "-M2048"]

            def run(arguments, name):
                output_path = scratch / (name + ".log")
                with output_path.open("wb") as output:
                    try:
                        result = subprocess.run(prefix + arguments, stdout=output, stderr=subprocess.STDOUT,
                                                timeout=75, preexec_fn=limits)
                    except subprocess.TimeoutExpired:
                        raise CheckerUnavailable("specification check exceeded its 75-second deadline") from None
                confined(root, str(output_path.relative_to(root)))
                output = output_path.read_text(errors="replace")
                with log_path.open("a", encoding="utf-8") as journal:
                    journal.write(name + " exit_code=" + str(result.returncode) + "\n" + output + "\n")
                if result.returncode:
                    if "failed to create thread" in output or output.startswith("bwrap:"):
                        raise CheckerUnavailable(name + " exit_code=" + str(result.returncode) + "\n" + output[-12000:])
                    raise ValueError(name + " exit_code=" + str(result.returncode) + "\n" + output[-12000:])
                return output

            atomic(log_path, "Canonical project specification check\n")
            run(["-R", "/work", "/work/spec/Requirements.lean", "-o", sandbox_scratch + "/spec/Requirements.olean"], "requirements")
            if implementation:
                run(["-R", "/work", "/work/spec/Implementation.lean", "-o", sandbox_scratch + "/spec/Implementation.olean"], "implementation")
            driver = "import spec.Requirements\nimport LeanFM.ChatUI.Server\n"
            if implementation:
                driver += "import spec.Implementation\n"
            driver += "def main : IO Unit := do\n  let requirements : LeanFM.RequirementSpec := " + requirement + "\n"
            driver += "  let errors := LeanFM.validateRequirementSpec requirements\n"
            driver += '    ++ LeanFM.validateRequirementProtoFile requirements (include_str "/work/spec/Requirements.proto")\n'
            if implementation:
                driver += "    ++ LeanFM.validateImplementationSpec requirements " + implementation + "\n"
            driver += '  unless errors.isEmpty do\n    throw (IO.userError (LeanFM.joinWithNewline errors))\n'
            driver += '  if requirements.tasks.isEmpty then throw (IO.userError "No task grammar has been specified")\n'
            driver += '  IO.println (LeanFM.ChatUI.Server.tasksJson "spec/Requirements.lean" requirements ' + (constraints or "[]") + ')\n'
            (scratch / "Review.lean").write_text(driver)
            output = run(["--run", sandbox_scratch + "/Review.lean"], "derived-views")
            catalog = json.loads(output.strip().splitlines()[-1])
            if catalog.get("validation", {}).get("errors") != 0 or not catalog.get("tasks"):
                raise ValueError("derived catalog is empty or invalid")
            if any(not task.get("grammar") or "missing task grammar" in task.get("interaction_mermaid", "") for task in catalog["tasks"]):
                raise ValueError("derived catalog contains a missing task grammar")
            if revisions != {str(path.relative_to(root)): digest(path) for path in inputs}:
                raise ValueError("canonical inputs changed during validation; views were not promoted")
            report = {"status": "validated", "requirement": requirement, "implementation": implementation or None,
                      "prompt": "Make the selected project's current specification usable in ChatUI",
                      "question": "Does the canonical typed specification validate and yield its own task views?",
                      "event_source": "spec/Requirements.lean and spec/Requirements.proto",
                      "reducer": "validateRequirementSpec; optional validateImplementationSpec; tasksJson using the same RequirementSpec",
                      "unit": "task grammars", "boundary": ".", "artifacts": revisions,
                      "task_count": len(catalog["tasks"]), "acceptance": "unchanged"}
            catalog["provenance"] = report
            atomic(catalog_path, json.dumps(catalog, ensure_ascii=False) + "\n")
            atomic(report_path, json.dumps(report, indent=2) + "\n")
            print("ok: canonical project specification and " + str(len(catalog["tasks"])) + " generated task views")
            print("Catalog: spec/tasks.json; evidence: reports/specification-check/validation.json")
            print("Acceptance unchanged. This is elaboration and structural validation, not a deployed-code proof.")


if __name__ == "__main__":
    try:
        check(*sys.argv[1:])
    except CheckerUnavailable as error:
        print("ERROR: local_checker_unavailable: " + str(error), file=sys.stderr)
        sys.exit(78)
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
