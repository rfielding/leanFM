import LeanFM.ChatUI.Store

open LeanFM.ChatUI.Store

-- Requirement refs: one_password_unlocks_all_provider_keys,
-- selected_model_determines_provider_credential, stored_provider_keys_are_encrypted.
example : !validCredentialPairs [("other", "key")] := by native_decide
example : !validCredentialPairs [("openai", "one"), ("openai", "two")] := by native_decide
example : !validCredentialPairs [("anthropic", "key\nInjected: header")] := by native_decide

def check (ok : Bool) (name : String) : IO Unit :=
  unless ok do throw (IO.userError name)

def failed (result : Except String α) : Bool :=
  match result with | .error _ => true | .ok _ => false

def main : IO Unit := do
  let root ← dataRoot
  check (root.contains "/.cache/" && root.endsWith "/credential-unit/.leanfm") "unexpected credential test root"
  let .ok _ ← createAccount "multi" "test-password-long" "openai" "openai-unit-key" [("anthropic", "anthropic-unit-key")]
    | throw (IO.userError "multi-provider account creation failed")
  let .ok token ← login "multi" "test-password-long"
    | throw (IO.userError "multi-provider password unlock failed")
  check ((← sessionCredential? token "multi" "openai") == some "openai-unit-key") "OpenAI key mismatch"
  check ((← sessionCredential? token "multi" "anthropic") == some "anthropic-unit-key") "Anthropic key mismatch"
  check ((← sessionCredential? token "other" "anthropic").isNone) "cross-account key access"
  check (failed (← login "multi" "wrong-password")) "wrong password accepted"
  let bundle ← readOr (root ++ "/accounts/multi/credentials/providers.json") ""
  check (!bundle.contains "unit-key") "plaintext keys retained"
  let .ok _ ← updateCredentialBundle "multi" "test-password-long" [("openai", "replacement-openai-key")]
    | throw (IO.userError "provider bundle rotation failed")
  check ((← sessionCredential? token "multi" "openai").isNone) "stale session retained keys"
  let .ok rotated ← login "multi" "test-password-long"
    | throw (IO.userError "rotated bundle unlock failed")
  check ((← sessionCredential? rotated "multi" "anthropic") == some "anthropic-unit-key") "rotation lost the other provider"
  check ((← sessionCredential? rotated "multi" "openai") == some "replacement-openai-key") "rotation did not replace its provider"
  let .ok _ ← createAccount "other" "test-password-long" "openai" "other-unit-key"
    | throw (IO.userError "second account failed")
  writeAtomic (root ++ "/accounts/other/credentials/providers.json") bundle
  check (failed (← login "other" "test-password-long")) "cross-account ciphertext swap accepted"
  let .ok _ ← createAccount "multi" "test-password-long" "anthropic" "updated-anthropic-key"
    | throw (IO.userError "matching-password account update failed")
  check (failed (← createAccount "multi" "wrong-password" "openai" "attacker-key")) "account update accepted the wrong password"
  let originalVerifier ← readOr (root ++ "/accounts/multi/password.json") ""
  let .ok _ ← changeAccountPassword "multi" "test-password-long" "changed-password-long"
    | throw (IO.userError "password change failed")
  check (failed (← login "multi" "test-password-long")) "old password remained valid"
  check (!(← sessionActive? rotated "multi")) "password change kept an older session"
  -- Simulate a crash before updating the optional legacy verifier mirror.
  writeAtomic (root ++ "/accounts/multi/password.json") originalVerifier
  let .ok changed ← login "multi" "changed-password-long"
    | throw (IO.userError "atomic password bundle was not authoritative")
  check ((← sessionCredential? changed "multi" "openai") == some "replacement-openai-key") "password change lost OpenAI"
  check ((← sessionCredential? changed "multi" "anthropic") == some "updated-anthropic-key") "password change lost Anthropic"
  let .ok _ ← updateCredentialBundle "multi" "changed-password-long" [("anthropic", "updated-again-key")]
    | throw (IO.userError "key rotation lost password-change metadata")
  check (failed (← login "multi" "test-password-long")) "key update revived old password"
  let .ok live ← login "multi" "changed-password-long"
    | throw (IO.userError "key update lost new password")
  let envelopePath := root ++ "/accounts/multi/credentials/providers.json"
  let .ok envelope := Lean.Json.parse (← readOr envelopePath "")
    | throw (IO.userError "updated bundle was not JSON")
  let .ok cipher := envelope.getObjVal? "encrypted" | throw (IO.userError "missing encrypted keys")
  let .ok verifier := envelope.getObjVal? "password_verifier" | throw (IO.userError "missing authoritative verifier")
  -- A second service can rotate this atomically without touching this IO.Ref.
  writeAtomic envelopePath ((Lean.Json.mkObj [("version", Lean.toJson (2 : Nat)),
    ("encrypted", cipher), ("password_verifier", verifier),
    ("session_revision", Lean.toJson "another-service-revision")]).compress ++ "\n")
  check (!(← sessionActive? live "multi")) "another service's rotation left the old session active"
  check ((← userForSession? live).isNone) "another service's rotation retained HTTP authentication"
  let .ok _ ← login "multi" "changed-password-long"
    | throw (IO.userError "cross-service revision lost encrypted credentials")
  IO.println "ok: one password unlocks both providers; no plaintext, cross-account access, corrupt-bundle fallback or stale session after key rotation"
