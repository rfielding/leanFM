#!/usr/bin/env python3
"""Project-owned, caller-bound work checkpoints. Never receives raw credentials.

Requirement refs: leanfm.resumable-work; proof:No replay or cross-caller continuation;
proof:No reset of safety or acceptance across batches; proof:No continuation without useful progress.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
import time

from chatui_specification import atomic, confined

ID = re.compile(r"[A-Za-z0-9_-]{16,80}\Z")
TAG = re.compile(r"[0-9a-f]{64}\Z")
LEASE_SECONDS = 30
MAX_STATE_BYTES = 2 * 1024 * 1024


class Rejected(ValueError):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


def revision(root):
    """Observe inputs, not logs/checkpoint bookkeeping or dependency caches."""
    entries = []
    for name in ["manifest.json", "project.json", "Makefile", "GNUmakefile", "makefile", "book", "spec", "source", "artifacts", "renders"]:
        base = root / name
        if not base.exists() and not base.is_symlink():
            continue
        if base.is_dir() and not base.is_symlink():
            paths = []
            for parent, directories, files in os.walk(base, followlinks=False):
                directories[:] = sorted(d for d in directories if d not in {".cache", ".git", ".lake", "node_modules", "__pycache__"})
                paths.extend(Path(parent) / f for f in sorted(files))
                paths.extend(Path(parent) / d for d in directories if (Path(parent) / d).is_symlink())
        else:
            paths = [base]
        for path in paths:
            relative = str(path.relative_to(root))
            if path.suffix in {".aux", ".log", ".out", ".toc", ".bcf", ".run.xml"}:
                continue
            if path.is_symlink():
                entries.append([relative, "symlink", os.readlink(path)])
            else:
                stat = path.stat()
                entries.append([relative, stat.st_size, stat.st_mtime_ns, stat.st_ino])
    return hashlib.sha256(json.dumps(sorted(entries), separators=(",", ":")).encode()).hexdigest()


class WorkStore:
    def __init__(self, root):
        supplied = Path(root).absolute()
        if supplied.is_symlink():
            raise Rejected(400, "Work project root cannot be a symlink")
        self.root = supplied.resolve(strict=True)
        self.directory = confined(self.root, ".leanfm/work", directory=True)
        os.chmod(self.directory, 0o700)
        self.root_tag = hashlib.sha256(str(self.root).encode()).hexdigest()

    def path(self, identifier):
        if not ID.fullmatch(identifier):
            raise Rejected(400, "Invalid work/checkpoint identifier")
        return confined(self.root, ".leanfm/work/" + identifier + ".json")

    def read(self, identifier):
        path = self.path(identifier)
        if not path.is_file():
            raise Rejected(404, "No such project work item")
        if path.stat().st_size > MAX_STATE_BYTES:
            raise Rejected(409, "Work checkpoint is oversized; start again from current project files")
        value = json.loads(path.read_text())
        if value.get("root_tag") != self.root_tag:
            raise Rejected(403, "Work checkpoint belongs to another project root")
        return value

    def write(self, job):
        # Provider context is replaceable by current durable context at a safe
        # tool-result boundary. It is never a reason for a total task-step cap.
        if len(json.dumps(job.get("provider_state", {})).encode()) > 1024 * 1024:
            job["provider_state"] = {"restart": True}
        job["receipts"] = job.get("receipts", [])[-4:]
        body = json.dumps(job, separators=(",", ":"))
        while len(body.encode()) > MAX_STATE_BYTES and len(job["receipts"]) > 1:
            job["receipts"].pop(0)
            body = json.dumps(job, separators=(",", ":"))
        if len(body.encode()) > MAX_STATE_BYTES:
            job["provider_state"] = {"restart": True}
            job.get("task_state", {}).pop("trace", None)
            body = json.dumps(job, separators=(",", ":"))
        if len(body.encode()) > MAX_STATE_BYTES:
            raise Rejected(409, "Work checkpoint metadata exceeded its bounded storage; progress remains in project files")
        atomic(self.path(job["id"]), body + "\n")

    def active(self):
        path = confined(self.root, ".leanfm/work/active.json")
        try:
            value = json.loads(path.read_text())
            return value if value.get("expires", 0) > time.time() else None
        except FileNotFoundError:
            return None

    def reserve(self, job):
        atomic(confined(self.root, ".leanfm/work/active.json"), json.dumps({"id": job["id"], "expires": time.time() + LEASE_SECONDS}) + "\n")

    def release(self, job):
        path = confined(self.root, ".leanfm/work/active.json")
        try:
            if json.loads(path.read_text()).get("id") == job["id"]:
                path.unlink()
        except FileNotFoundError:
            pass

    @staticmethod
    def authorize(job, identity, allow_new_session=False):
        for key in ["account", "credential", "provider", "model"]:
            if not identity.get(key) or job.get(key) != identity[key]:
                raise Rejected(403, "Work belongs to another caller, credential or model")
        if job["owner"] != identity.get("owner") and not allow_new_session:
            raise Rejected(403, "The initiating login ended. Sign in and explicitly resume this work")

    @staticmethod
    def public(job, identity):
        return {"id": job["id"], "state": job["state"], "checkpoint": job.get("checkpoint", ""),
                "batch": job.get("batch", 0), "continue": job["state"] == "checkpointed",
                "progress": job.get("progress", ""), "cancelled": job.get("cancelled", False),
                "requires_resume": job["owner"] != identity.get("owner")}

    def operate(self, operation, request):
        identity = {key: request.get("identity", {}).get(key, "") for key in ["account", "owner", "credential", "provider", "model"]}
        if operation == "guard":
            active = self.active()
            if active:
                allowed_id = request.get("work_id", "")
                request_id = request.get("request_id", "")
                if not allowed_id and ID.fullmatch(request_id):
                    index = confined(self.root, ".leanfm/work/request-" + request_id + ".json")
                    if index.is_file():
                        allowed_id = json.loads(index.read_text()).get("id", "")
                current = self.read(active["id"])
                same_owner = identity.get("owner") == current["owner"] and identity.get("account") == current["account"]
                explicit_owner = bool(request.get("explicit_resume")) and identity.get("account") == current["account"]
                if not (request.get("chat") and allowed_id == active["id"] and (same_owner or explicit_owner)):
                    raise Rejected(409, "A project task is continuing between batches. Cancel it or wait before editing")
            return {"allowed": True}
        required_tags = ["owner"] if operation in {"status", "cancel"} else ["owner", "credential"]
        if not all(TAG.fullmatch(identity.get(key, "")) for key in required_tags):
            raise Rejected(401, "A current authenticated work identity is required")
        if operation == "start":
            request_id = request.get("request_id", "") or secrets.token_hex(16)
            if not ID.fullmatch(request_id):
                raise Rejected(400, "Invalid initial work request identifier")
            index = confined(self.root, ".leanfm/work/request-" + request_id + ".json")
            if index.is_file():
                job = self.read(json.loads(index.read_text())["id"])
                self.authorize(job, identity)
                if job.get("receipts"):
                    return {"cached": job["receipts"][-1]["response"], "work": self.public(job, identity)}
                raise Rejected(409, "This submitted task is still running or its result is uncertain; inspect its work status")
            active = self.active()
            if active:
                raise Rejected(409, "Another task has an active project reservation")
            identifier = secrets.token_hex(16)
            job = {"id": identifier, "request_id": request_id, "root_tag": self.root_tag, **identity, "state": "running", "batch": 0,
                   "batch_size": 4 if request.get("batch_size", 4) == 4 else 16,
                   "checkpoint": "", "claim": secrets.token_hex(16), "consumed": "start",
                   "provider_state": {}, "task_state": {}, "receipts": [], "no_progress": 0,
                   "cancelled": False, "revision": revision(self.root), "progress": "Starting requested work"}
            prompt_path = confined(self.root, ".leanfm/work/" + identifier + ".prompt")
            atomic(prompt_path, request.get("prompt", ""))
            self.write(job)
            atomic(index, json.dumps({"id": identifier}) + "\n")
            self.reserve(job)
            return {"job": job, "prompt": request.get("prompt", "")}
        identifier = request.get("work_id", "")
        if identifier == "active":
            identifier = ""
        if not identifier and operation in {"status", "cancel"}:
            active = self.active()
            if operation == "cancel" and active is None:
                try:
                    active = json.loads(confined(self.root, ".leanfm/work/active.json").read_text())
                except FileNotFoundError:
                    pass
            if not active:
                if operation == "cancel":
                    return {"work": None}
                # Reconstruct paused work after reservation expiry or a page
                # reload. The only index is below this project root.
                candidates = []
                for path in self.directory.glob("*.json"):
                    if not re.fullmatch(r"[0-9a-f]{32}", path.stem) or path.is_symlink():
                        continue
                    candidate = self.read(path.stem)
                    if candidate.get("account") == identity.get("account") and candidate.get("state") in {"running", "checkpointed"}:
                        candidates.append((path.stat().st_mtime_ns, candidate["id"]))
                if not candidates:
                    return {"work": None}
                active = {"id": max(candidates)[1]}
            identifier = active["id"]
        if operation == "status" and ID.fullmatch(identifier) and not self.path(identifier).is_file():
            index = confined(self.root, ".leanfm/work/request-" + identifier + ".json")
            if index.is_file():
                identifier = json.loads(index.read_text())["id"]
        job = self.read(identifier)
        if operation in {"status", "cancel"}:
            identity.update({key: job[key] for key in ["credential", "provider", "model"]})
        self.authorize(job, identity, allow_new_session=operation == "status" or bool(request.get("explicit_resume")))
        if operation == "status":
            return {"work": self.public(job, identity), "response": job["receipts"][-1]["response"] if job.get("receipts") else None,
                    "request": {"id": job.get("request_id", job["id"]), "model": job["model"],
                                "prompt": confined(self.root, ".leanfm/work/" + identifier + ".prompt").read_text()}}
        if operation == "cancel":
            job["cancelled"] = True
            newly_cancelled = job["state"] == "checkpointed"
            if job["state"] == "checkpointed":
                job["state"] = "cancelled"
                self.release(job)
                response = {"text": '```leanfm-result\n{"status":"warn"}\n```\n\nTask cancelled. Earlier checked edits remain in Project memory.',
                            "model": job["model"], "cancelled": True, "book_updated": False,
                            "usage": job.get("task_state", {}).get("usage", {}), "work": self.public(job, identity)}
                job["receipts"].append({"consumed": job["checkpoint"], "response": response})
            self.write(job)
            return {"work": self.public(job, identity), "newly_cancelled": newly_cancelled,
                    "response": job["receipts"][-1]["response"] if job.get("receipts") else None}
        if operation == "claim":
            checkpoint = request.get("checkpoint", "")
            if not ID.fullmatch(checkpoint):
                raise Rejected(400, "Invalid continuation checkpoint")
            for receipt in job.get("receipts", []):
                if receipt["consumed"] == checkpoint:
                    return {"cached": receipt["response"], "work": self.public(job, identity)}
            if job.get("cancelled"):
                raise Rejected(409, "This work was cancelled; no continuation was sent")
            if job["state"] != "checkpointed" or job.get("checkpoint") != checkpoint:
                raise Rejected(409, "Stale, running or uncertain checkpoint; inspect work status before continuing")
            active = self.active()
            if active and active["id"] != job["id"]:
                raise Rejected(409, "Another task currently owns this project's writer reservation")
            if job.get("revision") != revision(self.root):
                if not request.get("restart"):
                    raise Rejected(409, "Project files changed since this checkpoint. Explicitly restart from the current project files")
                job["provider_state"] = {"restart": True}
            job.update(owner=identity["owner"], state="running", claim=secrets.token_hex(16), consumed=checkpoint)
            self.write(job)
            self.reserve(job)
            return {"job": job, "prompt": confined(self.root, ".leanfm/work/" + identifier + ".prompt").read_text()}
        if operation == "save":
            if job["state"] != "running" or job.get("claim") != request.get("claim"):
                raise Rejected(409, "The work claim is stale; no receipt was replaced")
            state = request.get("state", "blocked")
            if state not in {"checkpointed", "completed", "blocked", "gate", "cancelled"}:
                raise Rejected(400, "Invalid work terminal/checkpoint state")
            job["batch"] += 1
            job["provider_state"] = request.get("provider_state", {})
            job["task_state"] = request.get("task_state", {})
            job["no_progress"] = 0 if request.get("made_progress") else job.get("no_progress", 0) + 1
            if job.get("cancelled"):
                state = "cancelled"
            if state == "checkpointed" and job["no_progress"] >= 2:
                state = "blocked"
                job["progress"] = "Two batches repeated work without useful new progress. Stopped before another paid request"
            else:
                job["progress"] = request.get("progress", "Progress saved")[:2000]
            job["state"] = state
            job["checkpoint"] = secrets.token_hex(16) if state == "checkpointed" else ""
            job["revision"] = revision(self.root)
            response = dict(request.get("response", {}))
            response["work"] = self.public(job, identity)
            if state == "blocked" and request.get("state") == "checkpointed":
                response["text"] = '```leanfm-result\n{"status":"warn"}\n```\n\n' + job["progress"]
            job["receipts"].append({"consumed": job["consumed"], "response": response})
            self.write(job)
            self.reserve(job) if state == "checkpointed" else self.release(job)
            return {"response": response, "work": self.public(job, identity)}
        raise Rejected(400, "Unknown work operation")


def execute(operation, root, request):
    store = WorkStore(root)
    lock_path = confined(store.root, ".leanfm/work/control.lock")
    with lock_path.open("a") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        return store.operate(operation, request)


if __name__ == "__main__":
    try:
        print(json.dumps(execute(sys.argv[1], sys.argv[2], json.load(sys.stdin)), separators=(",", ":")))
    except Rejected as error:
        print(json.dumps({"error": str(error), "status": error.status}))
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": "Invalid or unavailable project work state: " + str(error), "status": 409}))
        sys.exit(1)
