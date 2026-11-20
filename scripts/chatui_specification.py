#!/usr/bin/env python3
"""Check canonical project Lean in isolation and atomically derive task views.

Requirement refs: web_ui_replaces_external_coding_session,
chat_layers_mutate_only_their_artifacts, diagram_is_task_local,
selected_project_context_drives_chat, feature_completion_pairs_positive_and_negative_invariants,
clause:selfhost.project.implementations.

A project may carry several implementations of one specification. manifest.json lists them as
"implementations": [{"name", "implementation", "source"}] with "default_implementation"; without
that list the project has one implementation, "default", in spec/Implementation.lean. Every
implementation is checked against the same RequirementSpec, one at a time in its own driver, so
each may declare the same namespace. Only the default implementation can fail the check: another
implementation's errors are recorded in the report, so a port in progress never blocks the
specification or its views.
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
IMPLEMENTATION_NAME = re.compile(r"[a-z][a-z0-9_]{0,31}\Z")
MODULE_PART = re.compile(r"[A-Za-z_][A-Za-z_0-9]*\Z")
MAX_IMPLEMENTATIONS = 8


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
    # Lean 4.35 reserves ~4.5 GiB of address space (not resident memory) when importing LeanFM.
    resource.setrlimit(resource.RLIMIT_AS, (6 * 1024**3, 6 * 1024**3))
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


def implementation_entries(root, implementation):
    """The project's implementations, default first: [{name, implementation, source, module, default}]."""
    if not implementation:
        return []
    manifest_path = confined(root, "manifest.json")
    manifest = {}
    if manifest_path.is_file():
        if manifest_path.stat().st_size > 1_000_000:
            raise ValueError("oversized manifest.json")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError("manifest.json must be an object")
    listed = manifest.get("implementations")
    if listed is None:
        listed = [{"name": "default", "implementation": "spec/Implementation.lean",
                   "source": manifest.get("source", "source/")}]
        default = "default"
    else:
        default = manifest.get("default_implementation")
        if not isinstance(listed, list) or not listed or len(listed) > MAX_IMPLEMENTATIONS:
            raise ValueError("manifest implementations must list 1 to " + str(MAX_IMPLEMENTATIONS) + " implementations")
    entries = []
    for item in listed:
        if not isinstance(item, dict) or set(item) - {"name", "implementation", "source"}:
            raise ValueError("an implementation is {name, implementation, source}")
        name, path, source = item.get("name"), item.get("implementation"), item.get("source")
        if not isinstance(name, str) or not IMPLEMENTATION_NAME.fullmatch(name):
            raise ValueError("implementation name must match [a-z][a-z0-9_]*: " + repr(name))
        if not isinstance(path, str) or not isinstance(source, str) or not path.endswith(".lean"):
            raise ValueError("implementation " + name + " needs an implementation .lean path and a source directory")
        parts = Path(path).with_suffix("").parts
        if not parts or any(not MODULE_PART.fullmatch(part) for part in parts) or parts[0] in {"source", "reports"}:
            raise ValueError("implementation " + name + ": every path component must be a Lean identifier: " + path)
        confined(root, path)
        confined(root, source)
        entries.append({"name": name, "implementation": path, "source": source,
                        "module": ".".join(parts), "default": name == default})
    names = [entry["name"] for entry in entries]
    modules = [entry["module"] for entry in entries]
    if len(set(names)) != len(names) or len(set(modules)) != len(modules):
        raise ValueError("implementation names and files must be distinct")
    if default not in names:
        raise ValueError("default_implementation must name a listed implementation")
    if "spec.Requirements" in modules:
        raise ValueError("an implementation cannot be spec/Requirements.lean")
    return sorted(entries, key=lambda entry: not entry["default"])


def same_directory(left, right):
    return left.strip().strip("/") == right.strip().strip("/")


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
    entries = implementation_entries(root, implementation)
    for entry in entries:
        inputs.append(confined(root, entry["implementation"]))
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
                       # Lean 4.35 reserves 1 GiB of address space per thread
                       # stack by default; 64 MiB keeps -j2 inside RLIMIT_AS.
                       "--", "/toolchain/bin/lean", "-j2", "-M2048", "--tstack=65536"]

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
            driver = "import spec.Requirements\nimport LeanFM.ChatUI.Server\n"
            driver += "def main : IO Unit := do\n  let requirements : LeanFM.RequirementSpec := " + requirement + "\n"
            driver += "  let errors := LeanFM.validateRequirementSpec requirements\n"
            driver += '    ++ LeanFM.validateRequirementProtoFile requirements (include_str "/work/spec/Requirements.proto")\n'
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
            implementations = {}
            for entry in entries:
                implementations[entry["name"]] = check_implementation(
                    entry, requirement, implementation, run, scratch, sandbox_scratch, len(entries) > 1 or entry["name"] != "default")
            if revisions != {str(path.relative_to(root)): digest(path) for path in inputs}:
                raise ValueError("canonical inputs changed during validation; views were not promoted")
            default_name = entries[0]["name"] if entries else None
            report = {"status": "validated", "requirement": requirement, "implementation": implementation or None,
                      "default_implementation": default_name, "implementations": implementations,
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
            for name, result in implementations.items():
                line = "implementation " + name + (" (default)" if result["default"] else "") + ": " + result["status"]
                if result.get("target"):
                    line += ", target " + result["target"]
                print(line)
                for error in result.get("errors", [])[:20]:
                    print("  " + error)
            print("Catalog: spec/tasks.json; evidence: reports/specification-check/validation.json")
            print("Acceptance unchanged. This is elaboration and structural validation, not a deployed-code proof.")


def check_implementation(entry, requirement, implementation, run, scratch, sandbox_scratch, listed):
    """Compile one implementation and validate it against the requirements in its own driver."""
    name, module = entry["name"], entry["module"]
    result = {"implementation": entry["implementation"], "source": entry["source"], "module": module,
              "default": entry["default"], "status": "validated", "target": None, "errors": []}
    olean = Path(*module.split(".")).with_suffix(".olean")
    (scratch / olean).parent.mkdir(parents=True, exist_ok=True)
    try:
        run(["-R", "/work", "/work/" + entry["implementation"], "-o", sandbox_scratch + "/" + str(olean)],
            "implementation" if name == "default" else "implementation-" + name)
        driver = "import spec.Requirements\nimport LeanFM.Artifacts\nimport Lean.Data.Json\nimport " + module + "\n"
        driver += "def main : IO Unit := do\n  let requirements : LeanFM.RequirementSpec := " + requirement + "\n"
        driver += "  let implementation : LeanFM.ImplementationSpec := " + implementation + "\n"
        driver += "  let errors := LeanFM.validateImplementationSpec requirements implementation\n"
        driver += "  IO.println (Lean.Json.compress (Lean.Json.mkObj [(\"target\", Lean.toJson (toString (repr implementation.target))),"
        driver += " (\"outputDirectory\", Lean.toJson implementation.outputDirectory), (\"errors\", Lean.toJson errors)]))\n"
        (scratch / ("Implementation-" + name + ".lean")).write_text(driver)
        output = run(["--run", sandbox_scratch + "/Implementation-" + name + ".lean"], "validate-" + name)
        answer = json.loads(output.strip().splitlines()[-1])
    except ValueError as error:
        if entry["default"]:
            raise
        result.update(status="does_not_compile", errors=[str(error)[-4000:]])
        return result
    result["target"] = str(answer.get("target", "")).rsplit(".", 1)[-1]
    errors = [str(error) for error in answer.get("errors", [])]
    if listed and not same_directory(answer.get("outputDirectory", ""), entry["source"]):
        errors.append("implementation outputDirectory " + repr(answer.get("outputDirectory")) +
                      " is not the manifest source " + repr(entry["source"]))
    if errors:
        if entry["default"]:
            raise ValueError("implementation " + name + " is invalid:\n" + "\n".join(errors))
        result.update(status="invalid", errors=errors)
    return result


if __name__ == "__main__":
    try:
        check(*sys.argv[1:])
    except CheckerUnavailable as error:
        print("ERROR: local_checker_unavailable: " + str(error), file=sys.stderr)
        sys.exit(78)
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
