#!/usr/bin/env python3
"""Password verification and credential AEAD. Secrets enter only through stdin.
Requirement refs: task:create_account, task:authenticate_user,
property:stored_provider_keys_are_encrypted.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ITERATIONS = 310_000
AAD_PREFIX = b"leanfm.chatui.credentials.v1\0"


def derive(password, salt, iterations):
    if iterations != ITERATIONS or len(salt) != 16:
        raise ValueError("unsupported KDF parameters")
    return hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen=32)


def encode(value):
    return base64.b64encode(value).decode("ascii")


def decode(value):
    return base64.b64decode(value, validate=True)


def encrypt(password, secret, username):
    salt, nonce = os.urandom(16), os.urandom(12)
    key = derive(password, salt, ITERATIONS)
    ciphertext = AESGCM(key).encrypt(nonce, secret, AAD_PREFIX + username.encode("utf-8"))
    return dict(version=1, algorithm="aes-256-gcm", kdf="pbkdf2-hmac-sha256",
                iterations=ITERATIONS, salt_b64=encode(salt), nonce_b64=encode(nonce),
                ciphertext_b64=encode(ciphertext))


def decrypt(password, record, username):
    if record.get("version") != 1 or record.get("algorithm") != "aes-256-gcm" or record.get("kdf") != "pbkdf2-hmac-sha256":
        raise ValueError("unsupported credential format")
    key = derive(password, decode(record["salt_b64"]), record["iterations"])
    nonce = decode(record["nonce_b64"])
    if len(nonce) != 12:
        raise ValueError("invalid nonce")
    return AESGCM(key).decrypt(nonce, decode(record["ciphertext_b64"]), AAD_PREFIX + username.encode("utf-8"))


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"hash", "verify", "encrypt", "decrypt"}:
        return 2
    try:
        request = json.loads(sys.stdin.buffer.read())
        password = decode(request["password_b64"])
        mode = sys.argv[1]
        if mode == "hash":
            salt = os.urandom(16)
            result = dict(algorithm="pbkdf2-hmac-sha256", iterations=ITERATIONS,
                          salt_b64=encode(salt), digest_b64=encode(derive(password, salt, ITERATIONS)))
            print(json.dumps(result, separators=(",", ":")))
        elif mode == "verify":
            actual = derive(password, decode(request["salt_b64"]), request["iterations"])
            print("ok" if hmac.compare_digest(actual, decode(request["digest_b64"])) else "rejected")
        elif mode == "encrypt":
            print(json.dumps(encrypt(password, decode(request["secret_b64"]), request["username"]), separators=(",", ":")))
        else:
            print(encode(decrypt(password, request["record"], request["username"])))
        return 0
    except Exception:
        # Never emit request contents, decrypted credentials, or crypto tracebacks.
        print("credential operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
