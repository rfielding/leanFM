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
  IO.println "ok: one password unlocks both providers; no plaintext, cross-account access, corrupt-bundle fallback or stale session after key rotation"
