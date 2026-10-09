#!/usr/bin/env python3
"""Requirement: stored_provider_keys_are_encrypted; no credential-file bypass."""
import copy
import json
import subprocess
import sys
import unittest
from chatui_crypto import encrypt, decrypt, encode, decode, derive, ITERATIONS

class Credentials(unittest.TestCase):
    def setUp(self):
        self.password = b"correct horse battery staple"
        self.secret = b"test-provider-secret"
        self.record = encrypt(self.password, self.secret, "alice")

    def test_roundtrip_and_no_reversible_plaintext(self):
        self.assertEqual(decrypt(self.password, self.record, "alice"), self.secret)
        serialized = json.dumps(self.record)
        self.assertNotIn(self.secret.decode(), serialized)
        self.assertNotIn(encode(self.secret), serialized)
        for field in ("salt_b64", "nonce_b64", "ciphertext_b64"):
            self.assertNotIn(self.secret, decode(self.record[field]))

    def test_wrong_password_and_account_swap(self):
        for password, username in ((b"wrong-password", "alice"), (self.password, "bob")):
            with self.assertRaises(Exception):
                decrypt(password, self.record, username)

    def test_tamper_and_truncation(self):
        for field in ("salt_b64", "nonce_b64", "ciphertext_b64"):
            record = copy.deepcopy(self.record)
            value = bytearray(decode(record[field])); value[0] ^= 1
            record[field] = encode(value)
            with self.assertRaises(Exception):
                decrypt(self.password, record, "alice")
        record = copy.deepcopy(self.record); record["ciphertext_b64"] = encode(b"short")
        with self.assertRaises(Exception): decrypt(self.password, record, "alice")

    def test_independent_salts_and_nonces(self):
        other = encrypt(self.password, self.secret, "alice")
        for field in ("salt_b64", "nonce_b64", "ciphertext_b64"):
            self.assertNotEqual(self.record[field], other[field])
        verifier = derive(self.password, b"v" * 16, ITERATIONS)
        with self.assertRaises(Exception): decrypt(verifier, self.record, "alice")

    def test_metadata_limits_and_versions(self):
        for field, value in (("version", 2), ("algorithm", "base64"), ("kdf", "none"), ("iterations", 10**12)):
            record = copy.deepcopy(self.record); record[field] = value
            with self.assertRaises(Exception): decrypt(self.password, record, "alice")

    def test_cli_errors_redact_secrets(self):
        result = subprocess.run([sys.executable, "scripts/chatui_crypto.py", "decrypt"],
          input=json.dumps(dict(password_b64=encode(b"wrong"), username="alice", record=self.record)),
          text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "credential operation failed\n")

if __name__ == "__main__": unittest.main()
