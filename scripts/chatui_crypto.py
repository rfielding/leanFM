#!/usr/bin/env python3
"""LeanFM ChatUI password verifier adapter.

Requirement references: task:create_account, task:authenticate_user.
Secrets are read from stdin and never accepted as command-line arguments.
"""

import base64
import hashlib
import hmac
import json
import os
import sys

ITERATIONS = 310_000


def derive(password: bytes, salt: bytes, iterations: int) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen=32)


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"hash", "verify"}:
        print("usage: chatui_crypto.py hash|verify", file=sys.stderr)
        return 2
    request = json.loads(sys.stdin.buffer.read())
    password = base64.b64decode(request["password_b64"], validate=True)
    if sys.argv[1] == "hash":
        salt = os.urandom(16)
        digest = derive(password, salt, ITERATIONS)
        print(json.dumps({
            "algorithm": "pbkdf2-hmac-sha256",
            "iterations": ITERATIONS,
            "salt_b64": base64.b64encode(salt).decode("ascii"),
            "digest_b64": base64.b64encode(digest).decode("ascii"),
        }, separators=(",", ":")))
        return 0
    iterations = int(request["iterations"])
    salt = base64.b64decode(request["salt_b64"], validate=True)
    expected = base64.b64decode(request["digest_b64"], validate=True)
    actual = derive(password, salt, iterations)
    print("ok" if hmac.compare_digest(actual, expected) else "rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
