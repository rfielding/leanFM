#!/usr/bin/env python3
"""Projects outside the LeanFM checkout (clause selfhost.project.external, decision project-external).

Builds a scratch checkout (a projects/Cage child) and, in another temporary directory, a project
root Ext outside it, then starts leanfm-server with LEANFM_PROJECTS naming Ext and checks over /mcp:
project_view lists Ext; session_check with project Ext and file spec/Ping.leanfm checks its
protocol; server_logs lists Ext/events and session_conform reads it by serverLog; a protocol file in
Ext that is a symlink out of the root is not read. Then each bad LEANFM_PROJECTS (relative, missing,
no manifest, inside the checkout, nested roots, a name already taken, an unsafe name) stops
leanfm-server and leanfm-mcp at startup naming LEANFM_PROJECTS and the root. Ext's files are
unchanged by the servers. Last, the project's own spec check runs from outside the checkout on a
copy of projects/Maqam's specification, writing only below that copy.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepalive_check import BIN, ROOT, spare_port, until_listening  # noqa: E402

PING = "protocol Pinger (A, B) {\n  Ping from A to B;\n}\n"


def call(port, name, args):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), {"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=60).read())["result"]
    return r.get("isError", False), r["content"][0]["text"], r.get("structuredContent")


def project(root, name, protocol=True):
    os.makedirs(os.path.join(root, "spec"), exist_ok=True)
    os.makedirs(os.path.join(root, "logs"), exist_ok=True)
    m = {"display_name": name}
    if protocol:
        m["protocol"] = "spec/Ping.leanfm"
        open(os.path.join(root, "spec", "Ping.leanfm"), "w").write(PING)
    open(os.path.join(root, "manifest.json"), "w").write(json.dumps(m))


def event(i):
    return '{"type":"leanFM",' + json.dumps({"id": f"a:{i}", "session": f"s{i}", "from": "A", "to": "B", "label": "Ping", "ts": str(i)})[1:]


def digest(root):
    h = hashlib.sha256()
    for d, _, fs in sorted(os.walk(root)):
        for f in sorted(fs):
            p = os.path.join(d, f)
            h.update(p.encode())
            if not os.path.islink(p):
                h.update(open(p, "rb").read())
    return h.hexdigest()


def refused(checkout, value, needle):
    """Both servers stop at startup, naming LEANFM_PROJECTS and the root."""
    env = {**os.environ, "LEANFM_PROJECTS": value, "LEANFM_PORT": str(spare_port()), "LEANFM_MCP_PORT": str(spare_port())}
    for exe, args in [("leanfm-server", []), ("leanfm-mcp", ["--stdio"])]:
        p = subprocess.run([os.path.join(BIN, exe)] + args, cwd=checkout, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=60)
        err = p.stdout + p.stderr
        assert p.returncode != 0 and "LEANFM_PROJECTS" in err and needle in err, (exe, value, p.returncode, err[-400:])


def main():
    checkout = tempfile.mkdtemp(prefix="leanfm-checkout-")
    outside = tempfile.mkdtemp(prefix="leanfm-external-")
    try:
        project(os.path.join(checkout, "projects", "Cage"), "Cage")
        ext = os.path.join(outside, "ext")
        project(ext, "Ext")
        with open(os.path.join(ext, "logs", "events.log"), "w") as f:
            f.write("\n".join(event(i) for i in range(3)) + "\n")
        secret = os.path.join(outside, "secret.leanfm")
        open(secret, "w").write("protocol Secret (A, B) {\n  Leak from A to B;\n}\n")
        os.symlink(secret, os.path.join(ext, "spec", "Escape.leanfm"))
        before = digest(ext)

        port = spare_port()
        srv = subprocess.Popen([os.path.join(BIN, "leanfm-server")], cwd=checkout,
                               env={**os.environ, "LEANFM_PORT": str(port), "LEANFM_PROJECTS": ext},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            until_listening(srv)
            err, text, _ = call(port, "project_view", {})
            assert not err and "Ext" in text and "Cage" in text, text[:400]
            print("ok: project_view lists Ext, the project outside the checkout, beside projects/Cage")
            err, text, sc = call(port, "session_check", {"project": "Ext", "file": "spec/Ping.leanfm"})
            assert not err, text[:400]
            print("ok: session_check with project Ext and file spec/Ping.leanfm checks the external protocol")
            err, text, _ = call(port, "session_check", {"project": "Ext", "file": "spec/Escape.leanfm"})
            assert err and "Leak" not in text, text[:400]
            print("ok: a protocol file in Ext that is a symlink out of its root is not read")
            err, text, _ = call(port, "server_logs", {})
            assert not err and "Ext/events" in text, text[:600]
            err, text, sc = call(port, "session_conform", {"project": "Ext", "file": "spec/Ping.leanfm", "serverLog": "Ext/events"})
            assert not err and sc["verdict"] == "conforms" and sc["source"]["log"] == "Ext/events", (text[:400], sc and sc.get("source"))
            print("ok: server_logs lists Ext/events, and session_conform reads it by serverLog: 3 sessions conform")
        finally:
            srv.kill(); srv.wait()
        assert digest(ext) == before, "the server changed a file in the external root"
        print("ok: nothing in the external root changed")

        inside = os.path.join(checkout, "inside"); project(inside, "Inside")
        nested = os.path.join(ext, "sub"); project(nested, "Sub")
        taken = os.path.join(outside, "taken"); project(taken, "Cage")
        unsafe = os.path.join(outside, "unsafe"); project(unsafe, "two words")
        bare = os.path.join(outside, "bare"); os.makedirs(bare)
        refused(checkout, "ext", "is not an absolute path")
        refused(checkout, os.path.join(outside, "missing"), "is not an existing directory")
        refused(checkout, bare, "has no manifest.json")
        refused(checkout, inside, "is inside the LeanFM checkout")
        refused(checkout, f"{ext}:{nested}", "overlaps the project root")
        refused(checkout, taken, "which another project already has")
        refused(checkout, unsafe, "not only letters, digits")
        refused(checkout, f"{ext}:{ext}", "overlaps the project root")
        print("ok: a relative, missing, manifest-less, inside, nested, repeated, taken or unsafe root stops leanfm-server and leanfm-mcp at startup, naming LEANFM_PROJECTS and the root")

        # the project's own checks run from outside the checkout against this installation
        maqam = os.path.join(ROOT, "projects", "Maqam")
        copy = os.path.join(outside, "maqam")
        os.makedirs(copy)
        shutil.copy(os.path.join(maqam, "manifest.json"), copy)
        shutil.copytree(os.path.join(maqam, "spec"), os.path.join(copy, "spec"))
        for impl in os.listdir(os.path.join(maqam, "impl")):
            os.makedirs(os.path.join(copy, "impl", impl))
            shutil.copy(os.path.join(maqam, "impl", impl, "Implementation.lean"), os.path.join(copy, "impl", impl))
        status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
        p = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "chatui_specification.py"), copy,
                            "Project.Requirements.requirements", "Project.Implementation.implementation"],
                           cwd=copy, capture_output=True, text=True, timeout=900)
        assert p.returncode == 0 and "validated" in p.stdout, p.stdout[-600:] + p.stderr[-600:]
        assert os.path.exists(os.path.join(copy, "reports", "specification-check", "validation.json"))
        after = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
        assert after == status, "the external spec check changed the LeanFM checkout:\n" + after
        print("ok: the spec check of a project outside the checkout passes from its own root, writing only below it")
    finally:
        shutil.rmtree(checkout, ignore_errors=True)
        shutil.rmtree(outside, ignore_errors=True)


if __name__ == "__main__":
    main()
